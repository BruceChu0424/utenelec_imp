package com.uten.imp.common.storage;

import com.uten.imp.config.props.StorageProperties;
import jakarta.annotation.PostConstruct;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

import java.io.*;
import java.nio.ByteBuffer;
import java.nio.channels.Channels;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;

/**
 * Private durable object storage. Files are envelopes, never public downloads.
 * Original bytes are immutable and versioned by SHA-256; compression is an
 * internal representation and never changes the attachment's size or digest.
 */
@Component
@ConditionalOnProperty(prefix = "uten.storage", name = "provider", havingValue = "internal")
public class InternalStorageService implements StorageService, BlobStore {
    private static final byte[] MAGIC = new byte[]{'U','T','E','N','I','N','T',1};
    private static final int HEADER_BYTES = 57;
    private static final int BUFFER_BYTES = 65536;
    private static final String VERSION_PREFIX = "internal-v1:";
    private static final Set<String> PRECOMPRESSED = Set.of("jpg","jpeg","png","gif","webp",
            "zip","gz","7z","rar","docx","xlsx","pptx","pdf","mp4","mp3");
    private final StorageProperties properties;
    private final DirectorySync directorySync;
    private Path root, staging, finals, scratch;
    private Semaphore permits;

    @FunctionalInterface
    interface DirectorySync { void force(Path directory) throws IOException; }

    @Autowired
    public InternalStorageService(StorageProperties properties) {
        this(properties, directory -> {
            // Durability is required, not silently downgraded if the filesystem
            // cannot sync directory entries (e.g. Java's Windows provider).
            try (FileChannel channel = FileChannel.open(directory, StandardOpenOption.READ)) {
                channel.force(true);
            }
        });
    }

    /** Unit tests may inject filesystem failure/synchronization; there is no runtime bypass switch. */
    InternalStorageService(StorageProperties properties, DirectorySync directorySync) {
        this.properties = properties;
        this.directorySync = directorySync;
    }

    @PostConstruct
    void init() throws IOException {
        validateConfiguration(properties);
        root = Path.of(properties.getInternal().getRoot()).normalize();
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)
                || !root.equals(root.toRealPath()) || !Files.isWritable(root)) {
            throw new IllegalStateException("Internal storage requires an existing writable real directory");
        }
        staging = privateDirectory(root.resolve("staging"));
        finals = privateDirectory(root.resolve("final"));
        scratch = privateDirectory(root.resolve("scratch"));
        permits = new Semaphore(properties.getInternal().getMaxConcurrentIo(), true);
        Path probe = Files.createTempFile(scratch, "durability-", ".part");
        Path published = staging.resolve(probe.getFileName());
        try {
            forceFile(probe);
            publish(probe, published); // Also proves create-only hard links on this filesystem.
            Files.delete(published);
            directorySync.force(staging);
            Path finalProbe = finals.resolve(probe.getFileName());
            try { publish(probe, finalProbe); }
            finally { Files.deleteIfExists(finalProbe); directorySync.force(finals); }
        } finally {
            Files.deleteIfExists(probe);
            Files.deleteIfExists(published);
        }
    }

    public static void validateConfiguration(StorageProperties properties) {
        var config = properties.getInternal();
        if (config == null || config.getRoot() == null || config.getRoot().isBlank())
            throw new IllegalStateException("Internal storage requires an explicit durable root");
        Path path = Path.of(config.getRoot());
        if (!path.isAbsolute() || path.normalize().getParent() == null)
            throw new IllegalStateException("Internal storage root must be an absolute dedicated directory");
        if (config.getMaxConcurrentIo() < 1 || config.getMaxConcurrentIo() > 32
                || config.getMaxObjectBytes() < properties.getMaxBytes()
                || config.getMaxObjectBytes() < 1 || config.getMaxObjectBytes() > 1073741824L
                || config.getMinFreeBytes() < 0
                || config.getOperationTimeoutSeconds() < 1 || config.getOperationTimeoutSeconds() > 300
                || config.getCompressionMinBytes() < 1 || config.getCompressionMinSavingsBytes() < 1
                || config.getCompressionMinSavingsPercent() < 1 || config.getCompressionMinSavingsPercent() > 90
                || config.getMaxInventoryObjects() < 1 || config.getMaxInventoryObjects() > 100000)
            throw new IllegalStateException("Internal storage resource limits are invalid");
    }

    @Override public PresignedUpload presignUpload(UploadRequest request) {
        requireLength(request.contentLength(), properties.getMaxBytes());
        if(request.category()==null || !request.category().matches("[A-Z][A-Z0-9_]{0,63}"))
            throw new IllegalArgumentException("Internal attachments require their registered business owner type");
        String key = "i1_"+request.category()+"_"+DateTimeFormatter.ofPattern("yyyyMM")
                .withZone(ZoneOffset.UTC).format(Instant.now())+"_"+StorageService.generateStorageKey(request.fileName());
        return new PresignedUpload(key, "/attachments/raw/" + key, "PUT",
                Map.of("Content-Type", request.contentType() == null ? "application/octet-stream" : request.contentType()),
                Map.of(), Instant.now().plusSeconds(properties.getPresignedExpirySeconds()));
    }

    @Override public void store(String key, InputStream input, long length, String contentType) {
        requireLength(length, properties.getMaxBytes());
        Path target = resolve(staging, key);
        try (Lease lease = lease()) {
            createPartition(staging,target.getParent());
            if(Files.exists(target,LinkOption.NOFOLLOW_LINKS))throw new IllegalStateException("Staged object already exists");
            requireSpace(length + HEADER_BYTES);
            Path temporary = temporary();
            try {
                byte[] hash;
                try (FileChannel channel = FileChannel.open(temporary, StandardOpenOption.WRITE)) {
                    channel.position(HEADER_BYTES);
                    hash = copyExact(input, Channels.newOutputStream(channel), length, lease, null);
                    channel.position(0);
                    writeHeader(channel,new Header(0, length, length, hash));
                    channel.force(true);
                }
                publish(temporary, target);
            } finally { Files.deleteIfExists(temporary); }
        } catch (IOException error) { throw storageFailure("Unable to store internal attachment", error); }
    }

    @Override public StoredObject describe(String key) {
        Path path = resolve(staging, key);
        try (Lease lease = lease()) {
            if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return new StoredObject(false,0,null,null,null);
            try (Envelope envelope = envelope(path)) { return describe(envelope.header); }
        } catch (IOException error) { throw storageFailure("Unable to inspect internal attachment", error); }
    }

    @Override public InputStream openForValidation(String key, String versionId) {
        Lease lease = lease();
        try {
            Envelope envelope = envelope(resolve(staging, key));
            try {
                requireVersion(envelope.header, versionId);
                return new CheckedInput(envelope.payload(), envelope.header, lease, null);
            } catch (RuntimeException | IOException error) { envelope.close(); throw error; }
        } catch (RuntimeException | IOException error) {
            lease.close();
            if (error instanceof RuntimeException runtime) throw runtime;
            throw storageFailure("Unable to validate internal attachment", (IOException) error);
        }
    }

    @Override public StoredObject promoteToFinal(String key, StoredObject inspected) {
        Path source = resolve(staging, key), target = resolve(finals, key);
        try (Lease lease = lease()) {
            createPartition(finals,target.getParent());
            Header original;
            try (Envelope envelope = envelope(source)) {
                original = envelope.header;
                requireVersion(original, inspected.versionId());
                if (original.originalSize != inspected.size()) throw new IllegalStateException("Staged attachment changed");
            }
            if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
                try (Envelope existing = envelope(target)) {
                    requireVersion(existing.header, original.version());
                    copyExact(existing.payload(), OutputStream.nullOutputStream(), original.originalSize, lease, original.sha);
                    forceFile(target);
                    directorySync.force(finals);
                    return describe(existing.header);
                }
            }
            requireSpace(original.originalSize * 2 + HEADER_BYTES);
            Path compressed = null, completed = temporary();
            try {
                Header chosen = original;
                if (compressible(key, source, original)) {
                    compressed = temporary();
                    try (Envelope envelope = envelope(source);
                         OutputStream file = Files.newOutputStream(compressed);
                         GZIPOutputStream gzip = new FastGzip(new CompressionLimit(file,original.originalSize))) {
                        copyExact(envelope.payload(), gzip, original.originalSize, lease, original.sha);
                    } catch (CompressionNotUseful noSavings) {
                        Files.deleteIfExists(compressed);
                        compressed = null;
                    }
                    long compressedBytes = compressed == null ? original.originalSize : Files.size(compressed);
                    long savings = Math.max(properties.getInternal().getCompressionMinSavingsBytes(),
                            original.originalSize * properties.getInternal().getCompressionMinSavingsPercent() / 100);
                    if (compressedBytes <= original.originalSize - savings)
                        chosen = new Header(1, original.originalSize, compressedBytes, original.sha);
                }
                try (FileChannel channel = FileChannel.open(completed, StandardOpenOption.WRITE)) {
                    writeHeader(channel,chosen);
                    if (chosen.codec == 1) {
                        try (InputStream payload = Files.newInputStream(compressed)) {
                            copyExact(payload, Channels.newOutputStream(channel), chosen.payloadSize, lease, null);
                        }
                    } else {
                        try (Envelope envelope = envelope(source)) {
                            copyExact(envelope.payload(), Channels.newOutputStream(channel), original.originalSize, lease, original.sha);
                        }
                    }
                    channel.force(true);
                }
                // Creation is atomic and refuses an existing identity, unlike
                // ATOMIC_MOVE whose target-replacement behavior is provider-specific.
                publish(completed, target);
                return describe(chosen);
            } finally {
                Files.deleteIfExists(completed);
                if (compressed != null) Files.deleteIfExists(compressed);
            }
        } catch (IOException error) { throw storageFailure("Unable to promote internal attachment", error); }
    }

    @Override public PresignedDownload presignDownload(String key, String versionId) {
        try (Lease lease = lease(); Envelope envelope = envelope(resolve(finals, key))) {
            requireVersion(envelope.header, versionId);
            return new PresignedDownload("/attachments/raw/" + key,
                    Instant.now().plusSeconds(properties.getPresignedExpirySeconds()));
        } catch (IOException error) { throw storageFailure("Internal attachment is unavailable", error); }
    }

    @Override public InputStream read(String key) {
        throw new IllegalArgumentException("Internal attachment downloads require their pinned version");
    }

    @Override public InputStream read(String key, String versionId) {
        return readVerified(key,versionId,-1,null,null,null);
    }

    /** Match the database's original and physical identities before returning verified original bytes. */
    public InputStream readVerified(String key,String versionId,long originalSize,String sha256,
                                    Long storedSize,String encoding) {
        Lease lease = lease();
        Path verified = null;
        try {
            try (Envelope envelope = envelope(resolve(finals, key))) {
                requireVersion(envelope.header, versionId);
                if ((originalSize>=0 && originalSize!=envelope.header.originalSize)
                        || (sha256!=null && !sha256.equals(HexFormat.of().formatHex(envelope.header.sha)))
                        || (storedSize!=null && storedSize!=HEADER_BYTES+envelope.header.payloadSize)
                        || (encoding!=null && !encoding.equals(envelope.header.codec==1?"GZIP":"IDENTITY")))
                    throw new IllegalStateException("Internal attachment metadata differs from its confirmed identity");
                requireSpace(envelope.header.originalSize);
                verified = temporary();
                try (OutputStream output = Files.newOutputStream(verified)) {
                    copyExact(envelope.payload(), output, envelope.header.originalSize, lease, envelope.header.sha);
                }
                // Nothing is sent before full original-size and SHA verification.
                return new CheckedInput(Files.newInputStream(verified), envelope.header, lease, verified);
            }
        } catch (RuntimeException | IOException error) {
            if (verified != null) deleteQuietly(verified);
            lease.close();
            if (error instanceof RuntimeException runtime) throw runtime;
            throw storageFailure("Internal attachment failed integrity verification", (IOException) error);
        }
    }

    @Override public InputStream openFinal(String key,String versionId) { return read(key,versionId); }

    @Override public void delete(String key, String versionId) { deleteAt(finals, key, versionId); }
    @Override public void deleteStaging(String key, String versionId) { deleteAt(staging, key, versionId); }
    @Override public boolean isEnabled() { return true; }
    @Override public String backend() { return "internal"; }

    /** Only provider-owned abandoned private temp files; no database object is selected for deletion. */
    public int cleanupAbandonedScratch() {
        int visited=0,deleted=0;Instant cutoff=Instant.now().minusSeconds(86400);
        try(Lease lease=lease();DirectoryStream<Path> files=Files.newDirectoryStream(scratch)) {
            for(Path file:files) {
                if(++visited>1000)break;lease.check();String name=file.getFileName().toString();
                if(!name.matches("(?:object|durability)-[0-9]+\\.part")
                        || !Files.isRegularFile(file,LinkOption.NOFOLLOW_LINKS))continue;
                if(Files.getLastModifiedTime(file,LinkOption.NOFOLLOW_LINKS).toInstant().isBefore(cutoff)) {
                    Files.delete(file);deleted++;
                }
            }
            if(deleted>0)directorySync.force(scratch);
            return deleted;
        } catch(IOException error) { throw storageFailure("Unable to clean abandoned internal scratch files",error); }
    }

    @Override public List<StoredObjectRef> inventory() {
        if (!properties.getReconciliation().isEnabled())
            throw new UnsupportedOperationException("Internal attachment inventory is not enabled");
        List<StoredObjectRef> result = new ArrayList<>();
        try (Lease lease = lease()) {
            for (ObjectLocation location : ObjectLocation.values()) {
                Path namespace = location == ObjectLocation.STAGING ? staging : finals;
                try (var files = Files.walk(namespace,3)) {
                    var iterator=files.iterator();int visited=0;
                    while(iterator.hasNext()) {
                        Path file=iterator.next();
                        lease.check();
                        if(++visited>properties.getInternal().getMaxInventoryObjects()*4+8)
                            throw new StorageResourceUnavailableException("附件目录超过单批核对上限");
                        if(Files.isDirectory(file,LinkOption.NOFOLLOW_LINKS))continue;
                        if (result.size() == properties.getInternal().getMaxInventoryObjects())
                            throw new StorageResourceUnavailableException("附件清单超出单批上限，请使用受控分批核对");
                        String key = file.getFileName().toString();
                        if(!resolve(namespace,key).equals(file))throw new IOException("Object is outside its declared category partition");
                        try (Envelope envelope = envelope(file)) {
                            result.add(new StoredObjectRef(location,key,envelope.header.version(),
                                    envelope.header.originalSize,Files.getLastModifiedTime(file,LinkOption.NOFOLLOW_LINKS).toInstant()));
                        }
                    }
                }
            }
            return List.copyOf(result);
        } catch (IOException error) { throw storageFailure("Unable to inventory internal attachments", error); }
    }

    private void deleteAt(Path namespace, String key, String versionId) {
        Path path = resolve(namespace,key);
        try (Lease lease = lease()) {
            if (!Files.exists(path,LinkOption.NOFOLLOW_LINKS)) {
                Path parent=path.getParent();while(!Files.exists(parent,LinkOption.NOFOLLOW_LINKS))parent=parent.getParent();
                directorySync.force(parent);return;
            }
            try (Envelope envelope = envelope(path)) { requireVersion(envelope.header,versionId); }
            Files.delete(path);
            directorySync.force(path.getParent());
        } catch (IOException error) { throw storageFailure("Unable to delete internal attachment", error); }
    }

    private static StoredObject describe(Header header) {
        String hash = HexFormat.of().formatHex(header.sha);
        return new StoredObject(true,header.originalSize,null,header.version(),hash,
                HEADER_BYTES+header.payloadSize,header.codec==1?"GZIP":"IDENTITY",hash);
    }

    private boolean compressible(String key, Path source, Header header) throws IOException {
        if (header.originalSize < properties.getInternal().getCompressionMinBytes()) return false;
        int dot=key.lastIndexOf('.');
        if (dot>=0 && PRECOMPRESSED.contains(key.substring(dot+1).toLowerCase(Locale.ROOT))) return false;
        try (Envelope envelope=envelope(source)) {
            byte[] prefix=envelope.payload().readNBytes(12);
            return !(prefix.length>=2 && ((prefix[0]=='P' && prefix[1]=='K')
                    || (prefix[0]==(byte)0x1f && prefix[1]==(byte)0x8b)
                    || (prefix[0]==(byte)0xff && prefix[1]==(byte)0xd8)))
                    && !(prefix.length>=4 && ((prefix[0]==(byte)0x89 && prefix[1]=='P' && prefix[2]=='N' && prefix[3]=='G')
                    || (prefix[0]=='R' && prefix[1]=='I' && prefix[2]=='F' && prefix[3]=='F')
                    || (prefix[0]=='G' && prefix[1]=='I' && prefix[2]=='F' && prefix[3]=='8')));
        }
    }

    private Envelope envelope(Path path) throws IOException {
        if (!Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS)) throw new IOException("Object is not a regular file");
        FileChannel channel=FileChannel.open(path,StandardOpenOption.READ,LinkOption.NOFOLLOW_LINKS);
        try {
            DataInputStream input=new DataInputStream(Channels.newInputStream(channel));
            if (!Arrays.equals(input.readNBytes(MAGIC.length),MAGIC)) throw new IOException("Unknown object envelope");
            int codec=input.readUnsignedByte(); long original=input.readLong(), stored=input.readLong(); byte[] sha=input.readNBytes(32);
            if ((codec!=0 && codec!=1) || original<=0 || original>properties.getInternal().getMaxObjectBytes()
                    || stored<=0 || stored>properties.getInternal().getMaxObjectBytes() || sha.length!=32
                    || channel.size()!=HEADER_BYTES+stored || (codec==0 && stored!=original))
                throw new IOException("Invalid object envelope bounds");
            return new Envelope(new Header(codec,original,stored,sha),input);
        } catch (RuntimeException | IOException error) { channel.close(); throw error; }
    }

    private record Header(int codec,long originalSize,long payloadSize,byte[] sha) {
        String version() { return VERSION_PREFIX+HexFormat.of().formatHex(sha); }
    }
    private static final class Envelope implements AutoCloseable {
        private final Header header; private final InputStream input; private InputStream decoded;
        Envelope(Header header,InputStream input) { this.header=header;this.input=input; }
        InputStream payload() throws IOException {
            if(decoded==null) decoded=header.codec==1?new GZIPInputStream(input,BUFFER_BYTES):input;
            return decoded;
        }
        @Override public void close() throws IOException { if(decoded!=null)decoded.close();else input.close(); }
    }
    private static byte[] headerBytes(Header h) {
        return ByteBuffer.allocate(HEADER_BYTES).put(MAGIC).put((byte)h.codec)
                .putLong(h.originalSize).putLong(h.payloadSize).put(h.sha).array();
    }
    private static void writeHeader(FileChannel channel,Header header) throws IOException {
        ByteBuffer bytes=ByteBuffer.wrap(headerBytes(header));
        while(bytes.hasRemaining())channel.write(bytes);
    }
    private static final class CompressionNotUseful extends IOException {}
    private static final class FastGzip extends GZIPOutputStream {
        FastGzip(OutputStream output) throws IOException { super(output,BUFFER_BYTES);def.setLevel(1); }
    }
    private static final class CompressionLimit extends FilterOutputStream {
        private final long maximum;private long written;
        CompressionLimit(OutputStream output,long maximum) { super(output);this.maximum=maximum; }
        @Override public void write(int value) throws IOException {
            if(++written>maximum)throw new CompressionNotUseful();out.write(value);
        }
        @Override public void write(byte[] bytes,int offset,int length) throws IOException {
            if(length>maximum-written)throw new CompressionNotUseful();written+=length;out.write(bytes,offset,length);
        }
    }
    private static void requireVersion(Header header,String version) {
        if (version==null || !header.version().equals(version))
            throw new IllegalStateException("Internal attachment version does not match the confirmed identity");
    }
    private static void requireLength(long length,long maximum) {
        if (length<=0 || length>maximum) throw new IllegalArgumentException("Attachment length is outside storage limits");
    }
    private Path resolve(Path namespace,String key) {
        if(key!=null && key.matches("[a-f0-9]{32}(\\.[a-z0-9]{1,8})?"))return namespace.resolve(key);
        if(key!=null) {
            var match=java.util.regex.Pattern.compile("i1_([A-Z][A-Z0-9_]{0,63})_([0-9]{4}(?:0[1-9]|1[0-2]))_([a-f0-9]{32}(?:\\.[a-z0-9]{1,8})?)").matcher(key);
            if(match.matches())return namespace.resolve(match.group(1)).resolve(match.group(2)).resolve(key);
        }
        throw new IllegalArgumentException("Invalid internal attachment key");
    }
    private void createPartition(Path namespace,Path parent) throws IOException {
        if(parent.equals(namespace))return;
        privateDirectory(parent.getParent());privateDirectory(parent);
    }
    private Path privateDirectory(Path path) throws IOException {
        boolean created=false;
        if (!Files.exists(path,LinkOption.NOFOLLOW_LINKS)) {
            try {
                if(Files.getFileStore(path.getParent()).supportsFileAttributeView("posix"))
                    Files.createDirectory(path,PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
                else Files.createDirectory(path);
                created=true;
            } catch(FileAlreadyExistsException raced) { /* another bounded upload created the same partition */ }
        }
        if (!Files.isDirectory(path,LinkOption.NOFOLLOW_LINKS) || !path.equals(path.toRealPath()))
            throw new IOException("Internal namespace cannot be a symbolic link");
        if (Files.getFileStore(path).supportsFileAttributeView("posix"))
            Files.setPosixFilePermissions(path,PosixFilePermissions.fromString("rwx------"));
        if(created)directorySync.force(path.getParent());
        return path;
    }
    private Path temporary() throws IOException { return Files.createTempFile(scratch,"object-",".part"); }
    private static void forceFile(Path file) throws IOException {
        try (FileChannel channel=FileChannel.open(file,StandardOpenOption.WRITE)) { channel.force(true); }
    }
    private void publish(Path source,Path target) throws IOException {
        Files.createLink(target,source);
        directorySync.force(target.getParent());
    }
    private void requireSpace(long required) throws IOException {
        long usable=Files.getFileStore(root).getUsableSpace();
        if (usable<required || usable-required<properties.getInternal().getMinFreeBytes())
            throw new StorageResourceUnavailableException("附件存储可用空间不足，请稍后重试或联系管理员");
    }
    private Lease lease() {
        if (!permits.tryAcquire()) throw new StorageResourceUnavailableException("附件读写繁忙，请稍后重试");
        return new Lease();
    }
    private final class Lease implements AutoCloseable {
        private final AtomicBoolean closed=new AtomicBoolean();
        private final long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(properties.getInternal().getOperationTimeoutSeconds());
        void check() {
            if (closed.get() || System.nanoTime()-deadline>=0) throw new StorageResourceUnavailableException("附件处理超过时限，请重新请求");
        }
        @Override public void close() { if(closed.compareAndSet(false,true)) permits.release(); }
    }
    private static byte[] copyExact(InputStream input,OutputStream output,long expected,Lease lease,byte[] expectedHash) throws IOException {
        MessageDigest digest=sha256();byte[] buffer=new byte[BUFFER_BYTES];long copied=0;
        while (true) {
            lease.check();
            int count=input.read(buffer,0,(int)Math.min(buffer.length,expected-copied+1));
            if(count<0)break;
            if(count==0)continue;
            copied+=count;
            if(copied>expected)throw new IOException("Object exceeds original byte bound");
            output.write(buffer,0,count);digest.update(buffer,0,count);
        }
        byte[] hash=digest.digest();
        if(copied!=expected || (expectedHash!=null && !MessageDigest.isEqual(hash,expectedHash)))
            throw new IOException("Object original length or SHA-256 differs");
        return hash;
    }
    private final class CheckedInput extends FilterInputStream {
        private final Header header; private final Lease lease; private final Path temporary;
        private final MessageDigest digest=sha256(); private long count; private boolean verified; private boolean closed;
        CheckedInput(InputStream input,Header header,Lease lease,Path temporary) { super(input);this.header=header;this.lease=lease;this.temporary=temporary; }
        @Override public int read() throws IOException { byte[] one=new byte[1];return read(one,0,1)<0?-1:one[0]&255; }
        @Override public int read(byte[] bytes,int offset,int length) throws IOException {
            Objects.checkFromIndexSize(offset,length,bytes.length);
            if(length==0)return 0;
            try {
                lease.check();int n=in.read(bytes,offset,(int)Math.min(length,header.originalSize-count+1));
                if(n<0) {
                    if(!verified && (count!=header.originalSize || !MessageDigest.isEqual(digest.digest(),header.sha)))
                        throw new IOException("Object original checksum differs");
                    verified=true;return -1;
                }
                count+=n;if(count>header.originalSize)throw new IOException("Object exceeds original byte bound");
                digest.update(bytes,offset,n);return n;
            } catch(RuntimeException | IOException error) { close();throw error; }
        }
        @Override public long skip(long count) throws IOException {
            long skipped=0;byte[] buffer=new byte[BUFFER_BYTES];
            while(skipped<count) { int n=read(buffer,0,(int)Math.min(buffer.length,count-skipped));if(n<0)break;skipped+=n; }
            return skipped;
        }
        @Override public boolean markSupported() { return false; }
        @Override public synchronized void reset() throws IOException { throw new IOException("Object stream cannot reset"); }
        @Override public void close() throws IOException {
            if(closed)return;closed=true;
            try { super.close(); } finally { if(temporary!=null)deleteQuietly(temporary);lease.close(); }
        }
    }
    private static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch(NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }
    private static void deleteQuietly(Path path) { try { Files.deleteIfExists(path); } catch(IOException ignored) { /* bounded orphan reconciliation */ } }
    private static IllegalStateException storageFailure(String message,IOException cause) { return new IllegalStateException(message,cause); }
}
