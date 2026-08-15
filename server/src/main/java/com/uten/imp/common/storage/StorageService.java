package com.uten.imp.common.storage;

import java.io.InputStream;
import java.time.Instant;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/**
 * 附件对象存储抽象。业务代码只依赖本接口，后端可换：
 * <ul>
 *   <li>{@code local} —— 本地磁盘（开发/本地测试默认）。</li>
 *   <li>{@code oss} —— 阿里云 OSS，预签名 URL 直传直下。</li>
 * </ul>
 * 上传两阶段：{@link #presignUpload} 返回客户端直传目标 URL + storageKey；
 * 客户端按返回 method/headers/formFields 上传；再由业务层 {@link #describe}
 * 校验隔离区对象、扫描并提升到最终区后落库。
 * 客户端代码在 local/oss 间一致，只是上传/下载 URL 的来源不同。
 */
public interface StorageService {

    /** 一次上传的请求参数。 */
    record UploadRequest(String category, String fileName, String contentType, long contentLength) {
    }

    /** 预签名上传结果：客户端把字节按 {@code method} + {@code headers} 发到 {@code url}。 */
    record PresignedUpload(String storageKey, String url, String method,
                           Map<String, String> headers,
                           Map<String, String> formFields,
                           Instant expiresAt) {
    }

    /** 预签名下载结果。 */
    record PresignedDownload(String url, Instant expiresAt) {
    }

    /** 对象校验/元信息。 */
    record StoredObject(boolean exists, long size, String contentType,
                        String versionId, String eTag) {
    }

    enum ObjectLocation {
        STAGING,
        FINAL
    }

    /**
     * One exact object identity returned only by an explicitly enabled inventory run.
     * Final objects carry a pinned version; immutable unversioned staging objects use null.
     */
    record StoredObjectRef(ObjectLocation location, String storageKey,
                           String versionId, long size, Instant lastModified) {
    }

    /** 为一次上传生成 storageKey + 客户端直传目标 URL。 */
    PresignedUpload presignUpload(UploadRequest request);

    /** 校验对象已上传到位并返回其实际元信息（OSS HEAD / 本地读文件大小）。 */
    StoredObject describe(String storageKey);

    /** Opens the stored bytes so the server can compute a trusted digest/type check at confirm. */
    InputStream openForValidation(String storageKey, String versionId);

    /** Copies or moves one inspected staging object into the final namespace. */
    StoredObject promoteToFinal(String storageKey, StoredObject stagingObject);

    /** 生成下载 URL。 */
    PresignedDownload presignDownload(String storageKey, String versionId);

    /** 删除对象。 */
    void delete(String storageKey, String versionId);

    /** Deletes one exact object from the upload-only staging namespace. */
    void deleteStaging(String storageKey, String versionId);

    /**
     * Lists exact object identities for a controlled orphan-reconciliation job. Runtime
     * implementations fail closed unless their inventory grant is explicitly enabled.
     */
    default List<StoredObjectRef> inventory() {
        throw new UnsupportedOperationException("Attachment inventory is not enabled");
    }

    /** 是否启用（provider=disabled 时为 false）。 */
    boolean isEnabled();

    /** 后端标识，方便日志/调试。 */
    String backend();

    /** 生成不透明存储键：32 位 hex + 可选扩展名，无斜杠，URL 与文件名安全。 */
    static String generateStorageKey(String fileName) {
        String ext = "";
        int dot = fileName == null ? -1 : fileName.lastIndexOf('.');
        if (dot >= 0 && dot < fileName.length() - 1) {
            String candidate = fileName.substring(dot + 1).toLowerCase(Locale.ROOT);
            if (candidate.matches("[a-z0-9]{1,8}")) {
                ext = "." + candidate;
            }
        }
        return UUID.randomUUID().toString().replace("-", "") + ext;
    }
}
