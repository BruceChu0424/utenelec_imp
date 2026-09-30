package com.uten.imp.common.storage;

import com.uten.imp.common.files.document.BoundedBodyReader;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.io.ByteArrayInputStream;
import java.security.MessageDigest;
import java.util.HexFormat;

/** Internal version-pinned documents; callers persist the reference and staging-delete outbox atomically. */
@Component
public class ImmutableDocumentStore {
    private final StorageService active;
    private final StorageProviderRegistry providers;
    public ImmutableDocumentStore(StorageService active, StorageProviderRegistry providers) {
        this.active = active; this.providers = providers;
    }
    public record Reference(String provider, String key, String version, long size, String sha256) {}
    public Reference save(String category, String filename, String contentType, byte[] bytes) {
        if (bytes == null || bytes.length == 0 || bytes.length > 15 * 1024 * 1024) throw new IllegalArgumentException("文件大小无效");
        if (!active.isEnabled() || !(active instanceof BlobStore blobs)
                || !("internal".equals(active.backend()) || "local".equals(active.backend())))
            throw new IllegalStateException("请先启用内部文件存储");
        String key = active.presignUpload(new StorageService.UploadRequest(category, filename, contentType, bytes.length)).storageKey();
        Reference reference;
        try {
            blobs.store(key, new ByteArrayInputStream(bytes), bytes.length, contentType);
            var staged = active.describe(key);
            if (!staged.exists() || staged.size() != bytes.length) throw new IllegalStateException("文件写入不完整");
            var stored = active.promoteToFinal(key, staged);
            reference = new Reference(active.backend(), key, stored.versionId(), bytes.length, digest(bytes));
        } catch (RuntimeException error) { cleanup(key, null, false); throw error; }
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override public void afterCompletion(int status) {
                    // Unknown completion may mean the database committed but the reply was lost.
                    // Preserve the object until exact-reference reconciliation proves it orphaned.
                    if (status == STATUS_ROLLED_BACK) cleanup(reference.key(), reference.version(), true);
                }
            });
        }
        return reference;
    }
    public byte[] read(Reference reference) {
        if (reference.size() <= 0 || reference.size() > 15 * 1024 * 1024) throw new IllegalArgumentException("文件大小无效");
        try (var stream = providers.require(reference.provider()).openFinal(reference.key(), reference.version())) {
            byte[] bytes = BoundedBodyReader.read(stream, reference.size());
            if (bytes.length != reference.size() || !digest(bytes).equals(reference.sha256()))
                throw new IllegalStateException("来源文件校验失败");
            return bytes;
        } catch (java.io.IOException error) { throw new IllegalStateException("来源文件读取失败", error); }
    }
    public static String digest(byte[] bytes) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)); }
        catch (java.security.NoSuchAlgorithmException error) { throw new IllegalStateException(error); }
    }
    private void cleanup(String key, String version, boolean finalObject) {
        try { if (finalObject) active.delete(key, version); }
        catch (RuntimeException error) { org.slf4j.LoggerFactory.getLogger(getClass()).warn("Uncommitted document cleanup deferred type={}", error.getClass().getSimpleName()); }
        try { active.deleteStaging(key, version); }
        catch (RuntimeException error) { org.slf4j.LoggerFactory.getLogger(getClass()).warn("Document staging cleanup deferred type={}", error.getClass().getSimpleName()); }
    }
}
