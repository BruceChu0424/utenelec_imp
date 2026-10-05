package com.uten.imp.common.storage;

import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.api.io.TempDir;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.Random;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.zip.GZIPOutputStream;
import static org.junit.jupiter.api.Assertions.*;

class InternalStorageServiceTest {
    @TempDir Path directory;
    private static final String KEY="0123456789abcdef0123456789abcdef.txt";

    @Test void presignedObjectsUsePrivateBusinessAndMonthPartitionsAndExactDeletion() throws Exception {
        var store=store();byte[] bytes="original private attachment".getBytes(StandardCharsets.UTF_8);
        var grant=store.presignUpload(new StorageService.UploadRequest("EMPLOYEE","original.txt","text/plain",bytes.length));
        assertTrue(grant.storageKey().matches("i1_EMPLOYEE_[0-9]{6}_[a-f0-9]{32}\\.txt"));
        var object=upload(store,grant.storageKey(),bytes);
        String month=grant.storageKey().split("_")[2];
        Path finalObject=directory.resolve("final/EMPLOYEE").resolve(month).resolve(grant.storageKey());
        assertTrue(Files.isRegularFile(finalObject));
        store.delete(grant.storageKey(),object.versionId());assertFalse(Files.exists(finalObject));
        assertTrue(store.describe(grant.storageKey()).exists());
    }

    @Test void compressesOnlyInternallyAndDownloadsTheExactOriginalAfterVerification() throws Exception {
        var store=store();byte[] bytes="中文原始档案内容 abcdefghijklmnopqrstuvwxyz\n".repeat(4000).getBytes(StandardCharsets.UTF_8);
        var object=upload(store,KEY,bytes);
        assertEquals(bytes.length,object.size());assertEquals("GZIP",object.encoding());
        assertTrue(object.storedSize()<bytes.length/4);
        assertEquals(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)),object.contentSha256());
        assertEquals("/attachments/raw/"+KEY,store.presignDownload(KEY,object.versionId()).url());
        try(var input=store.read(KEY,object.versionId())) { assertArrayEquals(bytes,input.readAllBytes()); }
        assertEquals(0,scratchCount());
        assertTrue(Files.exists(directory.resolve("staging").resolve(KEY)));
    }

    @Test void precompressedFormatsAndIncompressibleBytesStayIdentity() throws Exception {
        var store=store();byte[] bytes=new byte[160000];new Random(913).nextBytes(bytes);
        String png="1123456789abcdef0123456789abcdef.png";
        byte[] signature={(byte)137,80,78,71,13,10,26,10};System.arraycopy(signature,0,bytes,0,signature.length);
        var pngObject=upload(store,png,bytes);assertEquals("IDENTITY",pngObject.encoding());
        new Random(117).nextBytes(bytes);bytes[0]=(byte)0xab;
        var randomObject=upload(store,KEY,bytes);assertEquals("IDENTITY",randomObject.encoding());
        try(var input=store.read(KEY,randomObject.versionId())) { assertArrayEquals(bytes,input.readAllBytes()); }
        assertEquals(bytes.length+57,randomObject.storedSize());assertEquals(0,scratchCount());
    }

    @Test void refusesLengthMismatchWithoutPublishingOrReadingAnUnboundedBody() throws Exception {
        var store=store();AtomicInteger reads=new AtomicInteger();
        InputStream endless=new InputStream() {
            @Override public int read() { reads.incrementAndGet();return 65; }
        };
        assertThrows(IllegalStateException.class,()->store.store(KEY,endless,10,"text/plain"));
        assertEquals(11,reads.get());assertFalse(store.describe(KEY).exists());assertEquals(0,scratchCount());
        assertThrows(IllegalStateException.class,()->store.store(KEY,new ByteArrayInputStream(new byte[2]),10,"text/plain"));
        assertFalse(store.describe(KEY).exists());
    }

    @Test void refusesOverwriteWrongVersionTraversalAndUnconfirmedDownload() throws Exception {
        var store=store();byte[] bytes="actual".getBytes(StandardCharsets.UTF_8);
        store.store(KEY,new ByteArrayInputStream(bytes),bytes.length,"text/plain");
        assertThrows(IllegalStateException.class,()->store.read(KEY,store.describe(KEY).versionId()));
        assertThrows(IllegalStateException.class,()->store.store(KEY,new ByteArrayInputStream(bytes),bytes.length,"text/plain"));
        var object=store.promoteToFinal(KEY,store.describe(KEY));
        assertThrows(IllegalArgumentException.class,()->store.read(KEY));
        assertThrows(IllegalStateException.class,()->store.read(KEY,"internal-v1:"+"0".repeat(64)));
        assertThrows(IllegalStateException.class,()->store.delete(KEY,"wrong"));
        assertThrows(IllegalArgumentException.class,()->store.describe("../"+KEY));
        try(var input=store.read(KEY,object.versionId())) { assertArrayEquals(bytes,input.readAllBytes()); }
        store.delete(KEY,object.versionId());store.delete(KEY,object.versionId());
    }

    @Test void corruptedCompressedObjectFailsBeforeReturningAnyDownloadStream() throws Exception {
        var store=store();var object=upload(store,KEY,"stable original\n".repeat(12000).getBytes(StandardCharsets.UTF_8));
        Path file=directory.resolve("final").resolve(KEY);byte[] saved=Files.readAllBytes(file);saved[saved.length-5]^=0x7f;Files.write(file,saved);
        assertThrows(IllegalStateException.class,()->store.read(KEY,object.versionId()));assertEquals(0,scratchCount());
    }

    @Test void databaseOriginalAndPhysicalMetadataMustMatchBeforeDownload() throws Exception {
        var store=store();var object=upload(store,KEY,new byte[]{1,2,3});
        assertThrows(IllegalStateException.class,()->store.readVerified(KEY,object.versionId(),4,
                object.contentSha256(),object.storedSize(),object.encoding()));
        assertThrows(IllegalStateException.class,()->store.readVerified(KEY,object.versionId(),3,
                object.contentSha256(),object.storedSize()+1,object.encoding()));
        assertEquals(0,scratchCount());
    }

    @Test void capsDecompressionAtDeclaredOriginalSizeAndCleansFailedSpool() throws Exception {
        var store=store();byte[] original="plain".repeat(200).getBytes(StandardCharsets.UTF_8);var object=upload(store,KEY,original);
        ByteArrayOutputStream compressed=new ByteArrayOutputStream();
        try(var gzip=new GZIPOutputStream(compressed)) { gzip.write(new byte[1000000]); }
        byte[] payload=compressed.toByteArray(),sha=MessageDigest.getInstance("SHA-256").digest(original);
        ByteBuffer envelope=ByteBuffer.allocate(57+payload.length).put(new byte[]{'U','T','E','N','I','N','T',1})
                .put((byte)1).putLong(original.length).putLong(payload.length).put(sha).put(payload);
        Files.write(directory.resolve("final").resolve(KEY),envelope.array());
        assertThrows(IllegalStateException.class,()->store.read(KEY,object.versionId()));assertEquals(0,scratchCount());
    }

    @Test void ioSlotsApplyBackpressureUntilStreamsCloseAndRecoverAfterFailure() throws Exception {
        var props=properties();props.getInternal().setMaxConcurrentIo(1);var store=store(props);
        byte[] bytes="bounded".getBytes(StandardCharsets.UTF_8);var object=upload(store,KEY,bytes);
        try(var held=store.openForValidation(KEY,object.versionId())) {
            assertThrows(StorageResourceUnavailableException.class,()->store.describe(KEY));
        }
        try(var input=store.read(KEY,object.versionId())) {
            assertThrows(StorageResourceUnavailableException.class,()->store.describe(KEY));
        }
        assertTrue(store.describe(KEY).exists());assertEquals(0,scratchCount());
        assertThrows(IllegalStateException.class,()->store.openForValidation(KEY,"bad-version"));
        assertTrue(store.describe(KEY).exists());
    }

    @Test void lowDiskSpaceAndOversizedDeclarationsFailBeforeIntake() throws Exception {
        var props=properties();props.getInternal().setMinFreeBytes(Long.MAX_VALUE);var store=store(props);
        assertThrows(StorageResourceUnavailableException.class,()->store.store(KEY,new ByteArrayInputStream(new byte[]{1}),1,"text/plain"));
        assertThrows(IllegalArgumentException.class,()->store.presignUpload(new StorageService.UploadRequest("EMPLOYEE","x.txt","text/plain",props.getMaxBytes()+1)));
        assertEquals(0,scratchCount());
    }

    @Test void inventoryIsExplicitAndBoundedAndReturnsPinnedObjects() throws Exception {
        var props=properties();var store=store(props);var object=upload(store,KEY,new byte[]{1,2,3});
        assertThrows(UnsupportedOperationException.class,store::inventory);
        props.getReconciliation().setEnabled(true);assertEquals(2,store.inventory().size());
        assertTrue(store.inventory().stream().allMatch(row->row.versionId().equals(object.versionId())));
        props.getInternal().setMaxInventoryObjects(1);assertThrows(StorageResourceUnavailableException.class,store::inventory);
    }

    @Test void productionDurabilityFailureDoesNotSilentlySelectAWeakerPublisher() {
        var store=new InternalStorageService(properties(),path->{throw new IOException("directory flush rejected");});
        assertThrows(IOException.class,store::init);
    }

    @Test void absentObjectsHaveTypedMissingButDirectoriesAndBrokenEnvelopesDoNot() throws Exception {
        var store=store();
        var missingFinal=assertThrows(IllegalStateException.class,()->store.openFinal(KEY,"internal-v1:"+"a".repeat(64)));
        assertInstanceOf(NoSuchFileException.class,missingFinal.getCause());
        var missingStaging=assertThrows(IllegalStateException.class,()->store.openForValidation(KEY,null));
        assertInstanceOf(NoSuchFileException.class,missingStaging.getCause());
        Path invalid=directory.resolve("final").resolve(KEY);Files.createDirectory(invalid);
        var nonRegular=assertThrows(IllegalStateException.class,()->store.openFinal(KEY,"internal-v1:"+"a".repeat(64)));
        assertFalse(nonRegular.getCause() instanceof NoSuchFileException);
        Files.delete(invalid);Files.write(invalid,new byte[]{1,2,3});
        var corrupted=assertThrows(IllegalStateException.class,()->store.openFinal(KEY,"internal-v1:"+"a".repeat(64)));
        assertFalse(corrupted.getCause() instanceof NoSuchFileException);
        String partitioned=store.presignUpload(new StorageService.UploadRequest("SALES_QUOTE","absent.txt","text/plain",1)).storageKey();
        assertFalse(store.describe(partitioned).exists());
        assertInstanceOf(NoSuchFileException.class,assertThrows(IllegalStateException.class,()->store.openFinal(partitioned,"internal-v1:"+"a".repeat(64))).getCause());
        store.delete(partitioned,"internal-v1:"+"a".repeat(64));
        Path saved=directory.resolve("saved-final");Files.move(directory.resolve("final"),saved);
        assertThrows(StorageResourceUnavailableException.class,()->store.openFinal(KEY,"internal-v1:"+"a".repeat(64)));
        assertThrows(StorageResourceUnavailableException.class,()->store.describe(KEY));
        assertThrows(StorageResourceUnavailableException.class,()->store.delete(KEY,"internal-v1:"+"a".repeat(64)));
        Files.move(saved,directory.resolve("final"));
        String category=partitioned.substring(3,partitioned.lastIndexOf('_',partitioned.lastIndexOf('_')-1));Files.createFile(directory.resolve("staging").resolve(category));
        assertThrows(StorageResourceUnavailableException.class,()->store.describe(partitioned));
    }

    @EnabledOnOs(OS.LINUX)
    @Test void realLinuxFsyncDeletionProducesTypedFinalAndStagingAbsenceWithoutFollowingSymlinks() throws Exception {
        var store=new InternalStorageService(properties());store.init();var object=upload(store,KEY,new byte[]{10,20,30});
        store.delete(KEY,object.versionId());store.deleteStaging(KEY,object.versionId());
        assertInstanceOf(NoSuchFileException.class,assertThrows(IllegalStateException.class,()->store.openFinal(KEY,object.versionId())).getCause());
        assertInstanceOf(NoSuchFileException.class,assertThrows(IllegalStateException.class,()->store.openForValidation(KEY,object.versionId())).getCause());
        String linked=StorageService.generateStorageKey("linked.txt");Path link=directory.resolve("final").resolve(linked);
        Files.createSymbolicLink(link,directory.resolve("missing-target"));
        var symbolic=assertThrows(IllegalStateException.class,()->store.openFinal(linked,object.versionId()));
        assertFalse(symbolic.getCause() instanceof NoSuchFileException);assertTrue(Files.isSymbolicLink(link));
    }

    @EnabledOnOs(OS.LINUX)
    @Test void realLinuxDirectoryFsyncAndCreateOnlyPublicationRoundTrip() throws Exception {
        var store=new InternalStorageService(properties());store.init();var object=upload(store,KEY,new byte[]{10,20,30});
        try(var input=store.read(KEY,object.versionId())) { assertArrayEquals(new byte[]{10,20,30},input.readAllBytes()); }
    }

    @EnabledOnOs(OS.LINUX)
    @Test void restoredPrivateObjectAndOriginalMetadataRoundTripAfterAColdStart() throws Exception {
        var store=new InternalStorageService(properties());store.init();
        byte[] original="原始备份对象 不变更字节\n".repeat(6000).getBytes(StandardCharsets.UTF_8);
        var object=upload(store,KEY,original);
        Path backup=directory.resolve("backup-envelope");Files.copy(directory.resolve("final").resolve(KEY),backup);
        store.delete(KEY,object.versionId());
        Path restoredRoot=directory.resolve("restored-store");Files.createDirectory(restoredRoot);
        var restoredProperties=properties();restoredProperties.getInternal().setRoot(restoredRoot.toString());
        var restored=new InternalStorageService(restoredProperties);restored.init();
        Path restoredFile=restoredRoot.resolve("final").resolve(KEY);Files.copy(backup,restoredFile);
        try(var file=java.nio.channels.FileChannel.open(restoredFile,StandardOpenOption.WRITE)) { file.force(true); }
        try(var parent=java.nio.channels.FileChannel.open(restoredFile.getParent(),StandardOpenOption.READ)) { parent.force(true); }
        var coldStarted=new InternalStorageService(restoredProperties);coldStarted.init();
        try(var input=coldStarted.readVerified(KEY,object.versionId(),object.size(),object.contentSha256(),object.storedSize(),object.encoding())) {
            assertArrayEquals(original,input.readAllBytes());
        }
    }

    private StorageProperties properties() {
        var props=new StorageProperties();props.setProvider("internal");props.getInternal().setRoot(directory.toString());
        props.getInternal().setMinFreeBytes(0);return props;
    }
    @Test void inspectObjectReadsOnlyTheHeaderAndClassifiesEveryLocationState() throws Exception {
        var store=store();byte[] bytes="header only inspection".getBytes(StandardCharsets.UTF_8);
        var object=upload(store,KEY,bytes);
        var finalObject=store.inspectObject(StorageService.ObjectLocation.FINAL,KEY);
        assertTrue(finalObject.exists());assertEquals(object.versionId(),finalObject.versionId());assertEquals(bytes.length,finalObject.size());
        assertTrue(store.inspectObject(StorageService.ObjectLocation.STAGING,KEY).exists());
        store.delete(KEY,object.versionId());
        assertFalse(store.inspectObject(StorageService.ObjectLocation.FINAL,KEY).exists(),"absent is not an error");
        String never="i1_SALES_QUOTE_202610_0123456789abcdef0123456789abcdef.pdf";
        assertFalse(store.inspectObject(StorageService.ObjectLocation.FINAL,never).exists(),"a never-created partition is absent");

        String directoryKey="1123456789abcdef0123456789abcdef.txt";
        Files.createDirectory(directory.resolve("final").resolve(directoryKey));
        var notFile=assertThrows(StorageObjectProblem.class,()->store.inspectObject(StorageService.ObjectLocation.FINAL,directoryKey));
        assertEquals(StorageObjectProblem.Kind.NOT_REGULAR_FILE,notFile.kind());

        String foreignKey="2123456789abcdef0123456789abcdef.txt";
        Files.write(directory.resolve("final").resolve(foreignKey),"not an envelope".getBytes(StandardCharsets.UTF_8));
        var foreign=assertThrows(StorageObjectProblem.class,()->store.inspectObject(StorageService.ObjectLocation.FINAL,foreignKey));
        assertEquals(StorageObjectProblem.Kind.UNRECOGNIZED_HEADER,foreign.kind());
        String shortKey="3123456789abcdef0123456789abcdef.txt";
        Files.write(directory.resolve("final").resolve(shortKey),new byte[]{'U','T','E','N','I','N','T',1,0});
        assertEquals(StorageObjectProblem.Kind.UNRECOGNIZED_HEADER,
                assertThrows(StorageObjectProblem.class,()->store.inspectObject(StorageService.ObjectLocation.FINAL,shortKey)).kind());

        Files.move(directory.resolve("final"),directory.resolve("final-offline"));
        assertThrows(StorageResourceUnavailableException.class,()->store.inspectObject(StorageService.ObjectLocation.FINAL,KEY),
                "a missing namespace is never proof that one object was deleted");
    }

    @Test void inspectPathTreatsAConcurrentDeleteAsAbsent() throws Exception {
        var store=store();
        // The path passed the namespace checks; the file disappears before its header is read.
        Path vanished=directory.resolve("final").resolve("4123456789abcdef0123456789abcdef.txt");
        assertFalse(store.inspectPath(vanished).exists());
        assertFalse(store.describe("5123456789abcdef0123456789abcdef.txt").exists());
    }

    private InternalStorageService store() throws Exception { return store(properties()); }
    private InternalStorageService store(StorageProperties properties) throws Exception {
        // Codec/resource unit tests are portable; the separate Linux test uses
        // real directory fsync. No production property can select this test double.
        var store=new InternalStorageService(properties,path->{});store.init();return store;
    }
    private StorageService.StoredObject upload(InternalStorageService store,String key,byte[] bytes) {
        store.store(key,new ByteArrayInputStream(bytes),bytes.length,"text/plain");
        return store.promoteToFinal(key,store.describe(key));
    }
    private long scratchCount() throws IOException { try(var paths=Files.list(directory.resolve("scratch"))) { return paths.count(); } }
}
