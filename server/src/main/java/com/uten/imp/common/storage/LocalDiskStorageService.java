package com.uten.imp.common.storage;

import com.uten.imp.config.props.StorageProperties;
import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.channels.FileChannel;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.Map;
import java.util.ArrayList;
import java.util.List;

/** Local development storage with physically separate staging and final namespaces. */
@Slf4j
@Component
@RequiredArgsConstructor
@ConditionalOnProperty(prefix = "uten.storage", name = "provider",
        havingValue = "local", matchIfMissing = true)
public class LocalDiskStorageService implements StorageService, BlobStore {

    private static final String RAW_PATH = "/attachments/raw/";

    private final StorageProperties properties;
    private Path root;
    private Path stagingRoot;
    private Path finalRoot;

    @PostConstruct
    void init() throws IOException {
        root = Paths.get(properties.getLocalDir()).toAbsolutePath().normalize();
        stagingRoot = root.resolve("staging");
        finalRoot = root.resolve("final");
        Files.createDirectories(stagingRoot);
        Files.createDirectories(finalRoot);
        requireNamespaces();
        log.info("Local attachment storage enabled at {}", root);
    }

    @Override
    public PresignedUpload presignUpload(UploadRequest request) {
        String key = StorageService.generateStorageKey(request.fileName());
        Instant expiry = Instant.now().plusSeconds(properties.getPresignedExpirySeconds());
        return new PresignedUpload(
                key,
                RAW_PATH + key,
                "PUT",
                Map.of("Content-Type", request.contentType() == null
                        ? "application/octet-stream" : request.contentType()),
                Map.of(),
                expiry);
    }

    @Override
    public StoredObject describe(String storageKey) {
        Path target = resolveStaging(storageKey);
        if (Files.notExists(target,LinkOption.NOFOLLOW_LINKS)) return new StoredObject(false,0,null,null,null);
        if (!Files.isRegularFile(target,LinkOption.NOFOLLOW_LINKS))
            throw new StorageResourceUnavailableException("本地原件不是普通文件，请核验后重试");
        try {
            return new StoredObject(true, Files.size(target), null, null, null);
        } catch (IOException e) {
            throw new StorageResourceUnavailableException("本地原件状态无法确认，请核验后重试");
        }
    }

    @Override
    public InputStream openForValidation(String storageKey, String versionId) {
        try {
            return openExact(resolveStaging(storageKey));
        } catch (IOException e) {
            throw new IllegalStateException("Unable to read staged attachment: " + storageKey, e);
        }
    }

    @Override
    public StoredObject promoteToFinal(String storageKey, StoredObject stagingObject) {
        Path source = resolveStaging(storageKey);
        Path target = resolveFinal(storageKey);
        Path temporary = null;
        try {
            if (!Files.isRegularFile(source) || Files.size(source) != stagingObject.size()) {
                throw new IllegalStateException("Staged attachment changed before promotion");
            }
            if (Files.exists(target)) {
                if (Files.isRegularFile(target)
                        && Files.size(target) == stagingObject.size()
                        && Files.mismatch(source, target) == -1) {
                    return new StoredObject(true, Files.size(target),
                            stagingObject.contentType(), null, null);
                }
                throw new IllegalStateException("Final attachment key is already occupied");
            }
            temporary = Files.createTempFile(finalRoot, "promote-", ".part");
            Files.copy(source, temporary, StandardCopyOption.REPLACE_EXISTING);
            try (FileChannel channel = FileChannel.open(temporary, StandardOpenOption.WRITE)) {
                channel.force(true);
            }
            try {
                Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, target);
            }
            return new StoredObject(true, Files.size(target), stagingObject.contentType(),
                    null, null);
        } catch (IOException e) {
            throw new IllegalStateException("Unable to promote staged attachment: " + storageKey, e);
        } finally {
            if (temporary != null) {
                try {
                    Files.deleteIfExists(temporary);
                } catch (IOException cleanupFailure) {
                    log.warn("Attachment promotion cleanup failed type={}",
                            cleanupFailure.getClass().getSimpleName());
                }
            }
        }
    }

    @Override
    public PresignedDownload presignDownload(String storageKey, String versionId) {
        return new PresignedDownload(
                RAW_PATH + storageKey,
                Instant.now().plusSeconds(properties.getPresignedExpirySeconds()));
    }

    @Override
    public void delete(String storageKey, String versionId) {
        deleteAt(resolveFinal(storageKey), storageKey, "final");
    }

    @Override
    public void deleteStaging(String storageKey, String versionId) {
        deleteAt(resolveStaging(storageKey), storageKey, "staging");
    }

    @Override
    public List<StoredObjectRef> inventory() {
        if (!properties.getReconciliation().isEnabled()) {
            throw new UnsupportedOperationException(
                    "Local attachment inventory is not enabled");
        }
        List<StoredObjectRef> result = new ArrayList<>();
        collectInventory(ObjectLocation.STAGING, stagingRoot, result);
        collectInventory(ObjectLocation.FINAL, finalRoot, result);
        return List.copyOf(result);
    }

    @Override
    public void store(String storageKey, InputStream in, long contentLength, String contentType) {
        if (contentLength <= 0) {
            throw new IllegalArgumentException("Attachment Content-Length must be positive");
        }
        Path target = resolveStaging(storageKey);
        Path temporary = null;
        try {
            temporary = Files.createTempFile(stagingRoot, "upload-", ".part");
            long copied = Files.copy(in, temporary, StandardCopyOption.REPLACE_EXISTING);
            if (copied != contentLength) {
                throw new IllegalStateException("Attachment bytes differ from Content-Length");
            }
            Files.move(temporary, target);
        } catch (IOException e) {
            throw new IllegalStateException("Unable to write staged attachment: " + storageKey, e);
        } finally {
            if (temporary != null) {
                try {
                    Files.deleteIfExists(temporary);
                } catch (IOException cleanupFailure) {
                    log.warn("Attachment temporary-file cleanup failed type={}",
                            cleanupFailure.getClass().getSimpleName());
                }
            }
        }
    }

    @Override
    public InputStream read(String storageKey) {
        try {
            return openExact(resolveFinal(storageKey));
        } catch (IOException e) {
            throw new IllegalStateException("Unable to read final attachment: " + storageKey, e);
        }
    }

    @Override public InputStream openFinal(String key, String versionId) { return read(key); }

    @Override
    public boolean isEnabled() {
        return true;
    }

    @Override
    public String backend() {
        return "local";
    }

    private void deleteAt(Path target, String storageKey, String location) {
        try {
            requireNamespaces();
            if(Files.notExists(target,LinkOption.NOFOLLOW_LINKS))return;
            if(!Files.isRegularFile(target,LinkOption.NOFOLLOW_LINKS))
                throw new StorageResourceUnavailableException("本地原件不是普通文件，请核验后重试");
            Files.delete(target);
        } catch (IOException e) {
            log.warn("Local attachment delete failed location={} key={} type={}",
                    location, storageKey, e.getClass().getSimpleName());
            throw new IllegalStateException("Unable to delete local attachment", e);
        }
    }

    private static void collectInventory(ObjectLocation location, Path namespace,
                                         List<StoredObjectRef> result) {
        try (var files = Files.list(namespace)) {
            files.forEach(path -> {
                try {
                    if (!Files.isRegularFile(path, java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
                        throw new IllegalStateException(
                                "Unexpected local attachment inventory entry");
                    }
                    String storageKey = path.getFileName().toString();
                    if (!storageKey.matches("[A-Za-z0-9][A-Za-z0-9._-]{0,254}")) {
                        throw new IllegalStateException(
                                "Unexpected local attachment inventory name");
                    }
                    result.add(new StoredObjectRef(
                            location,
                            storageKey,
                            null,
                            Files.size(path),
                            Files.getLastModifiedTime(path).toInstant()));
                } catch (IOException e) {
                    throw new IllegalStateException("Unable to inspect local attachment", e);
                }
            });
        } catch (IOException e) {
            throw new IllegalStateException("Unable to list local attachment namespace", e);
        }
    }

    private Path resolveStaging(String storageKey) {
        requireNamespaces();
        return resolveUnder(stagingRoot, storageKey);
    }

    private Path resolveFinal(String storageKey) {
        requireNamespaces();
        Path finalObject=resolveUnder(finalRoot,storageKey);
        // Neither current nor common-base LocalDisk reads flat root/key objects. Do not silently
        // declare one lost (or delete a guessed layout) when its historical bytes still exist.
        if(Files.notExists(finalObject,LinkOption.NOFOLLOW_LINKS)
            && !Files.notExists(resolveUnder(root,storageKey),LinkOption.NOFOLLOW_LINKS))
            throw new StorageResourceUnavailableException("发现历史本地平铺原件，请先对账确认存储身份");
        return finalObject;
    }

    private void requireNamespaces() {
        if(root==null || stagingRoot==null || finalRoot==null)
            throw new StorageResourceUnavailableException("本地原件存储尚未初始化");
        for(Path directory:List.of(root,stagingRoot,finalRoot)) {
            try {
                if(!Files.isDirectory(directory,LinkOption.NOFOLLOW_LINKS) || !directory.equals(directory.toRealPath()))
                    throw new StorageResourceUnavailableException("本地原件存储目录缺失或身份异常，请核验后重试");
            } catch(IOException unknown) {
                // Missing/unknown root is not a typed missing leaf and cannot create an ABSENT ticket.
                throw new StorageResourceUnavailableException("本地原件存储目录暂不可用，请核验后重试");
            }
        }
    }
    private static InputStream openExact(Path target) throws IOException {
        if(Files.notExists(target,LinkOption.NOFOLLOW_LINKS))throw new NoSuchFileException(target.toString());
        if(!Files.isRegularFile(target,LinkOption.NOFOLLOW_LINKS))throw new IOException("Object is not a regular file");
        return Files.newInputStream(target,LinkOption.NOFOLLOW_LINKS);
    }

    private static Path resolveUnder(Path namespace, String storageKey) {
        Path target = namespace.resolve(storageKey).normalize();
        if (!target.startsWith(namespace)) {
            throw new IllegalArgumentException("Invalid storage key: " + storageKey);
        }
        return target;
    }
}
