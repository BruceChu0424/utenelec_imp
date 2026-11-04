package com.uten.imp.common.storage;

import com.uten.imp.common.files.document.BoundedBodyReader;
import com.uten.imp.common.files.document.DocumentIntakeProfile;
import com.uten.imp.common.files.malware.DocumentSafety;
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
    private final DocumentSafety safety;
    public ImmutableDocumentStore(StorageService active, StorageProviderRegistry providers, DocumentSafety safety) {
        this.active = active; this.providers = providers; this.safety = safety;
    }
    public record Reference(String provider, String key, String version, long size, String sha256) {}
    public Reference save(String category, String filename, String contentType, byte[] bytes) {
        return save(category,filename,contentType,bytes,DocumentIntakeProfile.DEFAULT);
    }
    public Reference save(String category,String filename,String contentType,byte[] bytes,DocumentIntakeProfile profile) {
        if (profile==null || bytes == null || bytes.length == 0 || bytes.length > profile.maxBytes()) throw new IllegalArgumentException("文件大小无效");
        bytes = bytes.clone();
        if (!active.isEnabled() || !(active instanceof BlobStore blobs)
                || !("internal".equals(active.backend()) || "local".equals(active.backend())))
            throw new IllegalStateException("请先启用内部文件存储");
        if(profile==DocumentIntakeProfile.DEFAULT)safety.requireClean(category,bytes);
        else safety.requireClean(category, bytes,profile);
        var upload=new StorageService.UploadRequest(category,filename,contentType,bytes.length);
        String key = (profile==DocumentIntakeProfile.DEFAULT?active.presignUpload(upload):active.presignUpload(upload,profile)).storageKey();
        Reference reference;
        try {
            if(profile==DocumentIntakeProfile.DEFAULT)blobs.store(key,new ByteArrayInputStream(bytes),bytes.length);
            else blobs.store(key,new ByteArrayInputStream(bytes),bytes.length,profile);
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
        return read(reference,DocumentIntakeProfile.DEFAULT);
    }
    public byte[] read(Reference reference,DocumentIntakeProfile profile) {
        if (profile==null || reference.size() <= 0 || reference.size() > profile.maxBytes()) throw new IllegalArgumentException("文件大小无效");
        try (var stream = providers.require(reference.provider()).openFinal(reference.key(), reference.version())) {
            byte[] bytes = BoundedBodyReader.read(stream, reference.size());
            if (bytes.length != reference.size() || !digest(bytes).equals(reference.sha256()))
                throw new IllegalStateException("来源文件校验失败");
            return profile==DocumentIntakeProfile.DEFAULT?safety.requireClean("IMMUTABLE_DOCUMENT_READ",bytes):safety.requireClean("IMMUTABLE_DOCUMENT_READ", bytes,profile);
        } catch (java.io.IOException error) { throw new IllegalStateException("来源文件读取失败", error); }
    }
    public byte[] checkLegacy(String category, byte[] bytes) {
        return safety.requireClean(category, bytes == null ? null : bytes.clone());
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
