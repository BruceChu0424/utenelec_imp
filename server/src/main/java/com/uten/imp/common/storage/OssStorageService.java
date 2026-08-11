package com.uten.imp.common.storage;

import com.aliyun.oss.HttpMethod;
import com.aliyun.oss.OSS;
import com.aliyun.oss.OSSClientBuilder;
import com.aliyun.oss.OSSException;
import com.aliyun.oss.common.auth.CredentialsProvider;
import com.aliyun.oss.common.auth.DefaultCredentialProvider;
import com.aliyun.oss.common.auth.InstanceProfileCredentialsProvider;
import com.aliyun.oss.model.BucketVersioningConfiguration;
import com.aliyun.oss.model.GeneratePresignedUrlRequest;
import com.aliyun.oss.model.GetObjectRequest;
import com.aliyun.oss.model.ObjectMetadata;
import com.uten.imp.config.props.StorageProperties;
import jakarta.annotation.PreDestroy;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

import java.net.URI;
import java.net.URL;
import java.io.InputStream;
import java.time.Instant;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 阿里云 OSS 存储后端。provider=oss 时装配。
 *
 * <p>预签名 URL 直传直下：客户端把字节直接 PUT 到 OSS（不经应用服务器），下载也走预签名 GET。
 * 凭证：云端 ECS 用 RAM 角色（{@code useInstanceRole=true}，{@link InstanceProfileCredentialsProvider}），
 * 免配置 AccessKey；本地服务器用 AK/SK（{@link DefaultCredentialProvider}）。
 * OSSClient 线程安全，生命周期内复用一次（仿 AliyunSmsGateway 的 createClient 范式）。
 *
 * <p>注：客户端（浏览器/App）在公网，预签名 URL 必须用公网 endpoint 解析，故本客户端统一用
 * 公网 {@code endpoint}；{@code internalEndpoint} 暂留作日后「API 调用走内网、预签名走公网」双客户端优化。
 */
@Slf4j
@Component
@ConditionalOnProperty(prefix = "uten.storage", name = "provider", havingValue = "oss")
public class OssStorageService implements StorageService {

    private static final String FORBID_OVERWRITE = "x-oss-forbid-overwrite";

    private final StorageProperties properties;
    private final OSS client;
    private final String bucket;
    private final String keyPrefix;

    public OssStorageService(StorageProperties properties) {
        this(properties, createClient(properties));
    }

    OssStorageService(StorageProperties properties, OSS client) {
        this.properties = properties;
        this.client = client;
        StorageProperties.Oss oss = properties.getOss();
        requireHttpsEndpoint(oss.getEndpoint());
        this.bucket = oss.getBucket();
        this.keyPrefix = oss.getKeyPrefix() == null || oss.getKeyPrefix().isBlank()
                ? "" : oss.getKeyPrefix();
        verifyProductionSafety(oss);
        log.info("OssStorageService 已启用，bucket={} prefix={}", bucket, keyPrefix);
    }

    @Override
    public PresignedUpload presignUpload(UploadRequest request) {
        String key = StorageService.generateStorageKey(request.fileName());
        Date expiration = expiryDate();
        GeneratePresignedUrlRequest req =
                new GeneratePresignedUrlRequest(bucket, physicalKey(key), HttpMethod.PUT);
        req.setExpiration(expiration);
        if (StringUtils.hasText(request.contentType())) {
            req.setContentType(request.contentType());
        }
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Content-Type", request.contentType() == null
                ? "application/octet-stream" : request.contentType());
        // OSS ignores this header while Bucket Versioning is enabled or suspended.
        // It remains useful only for explicitly non-versioned development buckets;
        // production integrity is provided by pinning the inspected versionId.
        if (!properties.getOss().isRequireVersioning()) {
            req.addHeader(FORBID_OVERWRITE, "true");
            headers.put(FORBID_OVERWRITE, "true");
        }
        URL url = client.generatePresignedUrl(req);
        return new PresignedUpload(
                key,
                url.toString(),
                "PUT",
                Map.copyOf(headers),
                expiration.toInstant());
    }

    @Override
    public StoredObject describe(String storageKey) {
        try {
            ObjectMetadata meta = client.getObjectMetadata(bucket, physicalKey(storageKey));
            requirePinnedVersion(meta.getVersionId());
            return new StoredObject(
                    true, meta.getContentLength(), meta.getContentType(),
                    meta.getVersionId(), meta.getETag());
        } catch (OSSException e) {
            if ("NoSuchKey".equals(e.getErrorCode())) {
                return new StoredObject(false, 0, null, null, null);
            }
            throw e;
        }
    }

    @Override
    public InputStream openForValidation(String storageKey, String versionId) {
        requirePinnedVersion(versionId);
        GetObjectRequest request = StringUtils.hasText(versionId)
                ? new GetObjectRequest(bucket, physicalKey(storageKey), versionId)
                : new GetObjectRequest(bucket, physicalKey(storageKey));
        return client.getObject(request).getObjectContent();
    }

    @Override
    public PresignedDownload presignDownload(String storageKey, String versionId) {
        requirePinnedVersion(versionId);
        Date expiration = expiryDate();
        GeneratePresignedUrlRequest req =
                new GeneratePresignedUrlRequest(bucket, physicalKey(storageKey), HttpMethod.GET);
        req.setExpiration(expiration);
        if (StringUtils.hasText(versionId)) {
            req.addQueryParameter("versionId", versionId);
        }
        URL url = client.generatePresignedUrl(req);
        return new PresignedDownload(url.toString(), expiration.toInstant());
    }

    @Override
    public void delete(String storageKey, String versionId) {
        requirePinnedVersion(versionId);
        try {
            if (StringUtils.hasText(versionId)) {
                client.deleteVersion(bucket, physicalKey(storageKey), versionId);
            } else {
                client.deleteObject(bucket, physicalKey(storageKey));
            }
        } catch (Exception e) {
            log.warn("OSS 附件删除失败 key={} type={}", storageKey, e.getClass().getSimpleName());
            // DB 行必须保留，才能让管理员重试并避免形成不可追踪的孤儿对象。
            throw new IllegalStateException("删除 OSS 附件失败", e);
        }
    }

    @Override
    public boolean isEnabled() {
        return true;
    }

    @Override
    public String backend() {
        return "oss";
    }

    @PreDestroy
    void shutdown() {
        if (client != null) {
            client.shutdown();
        }
    }

    private String physicalKey(String storageKey) {
        return keyPrefix + storageKey;
    }

    private Date expiryDate() {
        return Date.from(Instant.now().plusSeconds(properties.getPresignedExpirySeconds()));
    }

    private void requirePinnedVersion(String versionId) {
        if (properties.getOss().isRequireVersioning()
                && (!StringUtils.hasText(versionId)
                || "null".equalsIgnoreCase(versionId.trim()))) {
            throw new IllegalStateException(
                    "OSS versionId is required when Bucket versioning is enforced");
        }
    }

    private void verifyProductionSafety(StorageProperties.Oss oss) {
        if (!oss.isRequireVersioning()) {
            return;
        }
        try {
            BucketVersioningConfiguration versioning = client.getBucketVersioning(bucket);
            if (versioning == null
                    || !BucketVersioningConfiguration.ENABLED.equals(versioning.getStatus())) {
                throw new IllegalStateException(
                        "OSS Bucket versioning must be Enabled when UTEN_OSS_REQUIRE_VERSIONING=true");
            }
        } catch (IllegalStateException e) {
            throw e;
        } catch (Exception e) {
            throw new IllegalStateException(
                    "Unable to verify OSS Bucket versioning; grant GetBucketVersioning and check the Bucket", e);
        }
    }

    private static OSS createClient(StorageProperties properties) {
        StorageProperties.Oss oss = properties.getOss();
        requireConfigured("UTEN_OSS_ENDPOINT", oss.getEndpoint());
        requireConfigured("UTEN_OSS_BUCKET", oss.getBucket());
        try {
            if (oss.isUseInstanceRole()) {
                requireConfigured("UTEN_OSS_ROLE_NAME", oss.getRoleName());
                CredentialsProvider cp = new InstanceProfileCredentialsProvider(oss.getRoleName());
                return new OSSClientBuilder().build(oss.getEndpoint(), cp);
            }
            requireConfigured("UTEN_OSS_ACCESS_KEY_ID", oss.getAccessKeyId());
            requireConfigured("UTEN_OSS_ACCESS_KEY_SECRET", oss.getAccessKeySecret());
            CredentialsProvider cp =
                    new DefaultCredentialProvider(oss.getAccessKeyId(), oss.getAccessKeySecret());
            return new OSSClientBuilder().build(oss.getEndpoint(), cp);
        } catch (Exception e) {
            throw new IllegalStateException("无法初始化阿里云 OSS 客户端", e);
        }
    }

    private static void requireConfigured(String name, String value) {
        if (!StringUtils.hasText(value)) {
            throw new IllegalStateException(name + " must be configured when UTEN_STORAGE_PROVIDER=oss");
        }
    }

    private static void requireHttpsEndpoint(String value) {
        requireConfigured("UTEN_OSS_ENDPOINT", value);
        try {
            URI endpoint = URI.create(value.trim());
            if (!"https".equalsIgnoreCase(endpoint.getScheme())
                    || !StringUtils.hasText(endpoint.getHost())
                    || endpoint.getUserInfo() != null) {
                throw new IllegalStateException("UTEN_OSS_ENDPOINT must be an HTTPS OSS endpoint");
            }
        } catch (IllegalArgumentException e) {
            throw new IllegalStateException("UTEN_OSS_ENDPOINT must be a valid HTTPS OSS endpoint", e);
        }
    }
}
