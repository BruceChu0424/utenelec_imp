package com.uten.imp.features.sales.template;

import com.uten.imp.common.storage.BlobStore;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.HexFormat;

/** Generated, sanitized workbooks use the same immutable private objects as business attachments (ADR-074). */
@Component
public class SalesQuoteTemplateStorage {
    static final int MAX_BYTES = 15 * 1024 * 1024;
    private static final String MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    private static final Logger log = LoggerFactory.getLogger(SalesQuoteTemplateStorage.class);
    private final StorageService active;
    private final StorageProviderRegistry providers;

    public SalesQuoteTemplateStorage(StorageService active, StorageProviderRegistry providers) {
        this.active = active;
        this.providers = providers;
    }

    public record ObjectRef(String provider, String key, String version, long size, String sha256) { }

    /** The caller persists this identity and its staging-delete outbox intent in the current transaction. */
    public ObjectRef save(byte[] bytes) {
        if (bytes == null || bytes.length == 0 || bytes.length > MAX_BYTES)
            throw new IllegalArgumentException("报价模板超过文件大小上限");
        if (!active.isEnabled() || !(active instanceof BlobStore blobs)
                || !("internal".equals(active.backend()) || "local".equals(active.backend())))
            throw new IllegalStateException("报价模板需要启用内部文件存储");
        String key = active.presignUpload(new StorageService.UploadRequest("SALES_QUOTE_TEMPLATE", "template.xlsx", MIME, bytes.length)).storageKey();
        ObjectRef reference;
        try {
            blobs.store(key, new ByteArrayInputStream(bytes), bytes.length, MIME);
            StorageService.StoredObject inspected = active.describe(key);
            if (!inspected.exists() || inspected.size() != bytes.length) throw new IllegalStateException("模板文件写入不完整");
            StorageService.StoredObject stored = active.promoteToFinal(key, inspected);
            reference = new ObjectRef(active.backend(), key, stored.versionId(), bytes.length, digest(bytes));
        } catch (RuntimeException failure) {
            cleanup(active, key, null, false);
            throw failure;
        }
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override public void afterCompletion(int status) {
                    if (status == STATUS_ROLLED_BACK) cleanup(active, reference.key(), reference.version(), true);
                }
            });
        }
        return reference;
    }

    public byte[] read(ObjectRef object) {
        if (object == null || object.size() <= 0 || object.size() > MAX_BYTES)
            throw new IllegalArgumentException("报价模板文件大小无效");
        StorageService backend = providers.require(object.provider());
        try (InputStream in = backend.openFinal(object.key(), object.version())) {
            byte[] bytes = in.readNBytes((int) object.size() + 1);
            if (bytes.length != object.size() || !digest(bytes).equals(object.sha256()))
                throw new IllegalStateException("报价模板文件校验失败");
            return bytes;
        } catch (java.io.IOException error) {
            throw new IllegalStateException("报价模板文件读取失败", error);
        }
    }

    static String digest(byte[] bytes) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)); }
        catch (java.security.NoSuchAlgorithmException error) { throw new IllegalStateException(error); }
    }
    private static void cleanup(StorageService storage, String key, String version, boolean deleteFinal) {
        // Failed, uncommitted generated artifacts have no business reference; crashes remain discoverable by reconciliation.
        try { if (deleteFinal) storage.delete(key, version); }
        catch (RuntimeException error) { log.warn("Uncommitted quote template cleanup deferred type={}", error.getClass().getSimpleName()); }
        try { storage.deleteStaging(key, version); }
        catch (RuntimeException error) { log.warn("Quote template staging cleanup deferred type={}", error.getClass().getSimpleName()); }
    }
}
