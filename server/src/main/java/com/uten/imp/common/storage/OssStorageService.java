package com.uten.imp.common.storage;

import com.aliyun.oss.HttpMethod;
import com.aliyun.oss.OSS;
import com.aliyun.oss.OSSClientBuilder;
import com.aliyun.oss.OSSException;
import com.aliyun.oss.common.auth.Credentials;
import com.aliyun.oss.common.auth.CredentialsProvider;
import com.aliyun.oss.common.auth.DefaultCredentialProvider;
import com.aliyun.oss.common.auth.InstanceProfileCredentialsProvider;
import com.aliyun.oss.model.BucketVersioningConfiguration;
import com.aliyun.oss.model.CopyObjectRequest;
import com.aliyun.oss.model.CopyObjectResult;
import com.aliyun.oss.model.GeneratePresignedUrlRequest;
import com.aliyun.oss.model.GetObjectRequest;
import com.aliyun.oss.model.ListObjectsRequest;
import com.aliyun.oss.model.ObjectMetadata;
import com.aliyun.oss.model.ObjectListing;
import com.aliyun.oss.model.OSSObjectSummary;
import com.aliyun.oss.model.ListVersionsRequest;
import com.aliyun.oss.model.OSSVersionSummary;
import com.aliyun.oss.model.PolicyConditions;
import com.aliyun.oss.model.VersionListing;
import com.uten.imp.config.props.StorageProperties;
import jakarta.annotation.PreDestroy;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

import java.io.InputStream;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.URL;
import java.time.Instant;
import java.util.Date;
import java.util.ArrayList;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

/** Aliyun OSS attachment storage with upload-only staging and scanned final namespaces. */
@Slf4j
@Component
@ConditionalOnProperty(prefix = "uten.storage", name = "provider", havingValue = "oss")
public class OssStorageService implements StorageService {

    private static final String FORBID_OVERWRITE = "x-oss-forbid-overwrite";
    private static final String STAGING_PREFIX = "staging/";
    private static final String FINAL_PREFIX = "final/";

    private final StorageProperties properties;
    private final OSS client;
    private final CredentialsProvider credentialsProvider;
    private final String stagingBucket;
    private final String finalBucket;
    private final String keyPrefix;
    private final URI endpoint;

    public OssStorageService(StorageProperties properties) {
        this(properties, createClientBundle(properties));
    }

    private OssStorageService(StorageProperties properties, ClientBundle bundle) {
        this(properties, bundle.client(), bundle.credentialsProvider());
    }

    OssStorageService(StorageProperties properties, OSS client) {
        this(properties, client, null);
    }

    OssStorageService(StorageProperties properties, OSS client,
                      CredentialsProvider credentialsProvider) {
        this.properties = properties;
        this.client = client;
        this.credentialsProvider = credentialsProvider;
        StorageProperties.Oss oss = properties.getOss();
        this.endpoint = requireHttpsEndpoint(oss.getEndpoint());
        this.stagingBucket = requireConfigured(
                "UTEN_OSS_STAGING_BUCKET", oss.getStagingBucket());
        this.finalBucket = requireConfigured(
                "UTEN_OSS_FINAL_BUCKET", oss.getFinalBucket());
        if (stagingBucket.equals(finalBucket)) {
            throw new IllegalStateException(
                    "OSS staging and final Buckets must be different");
        }
        this.keyPrefix = canonicalPrefix(oss.getKeyPrefix());
        verifyProductionSafety(oss);
        log.info("OSS attachment storage enabled stagingBucket={} finalBucket={} prefix={}",
                stagingBucket, finalBucket, keyPrefix);
    }

    @Override
    public PresignedUpload presignUpload(UploadRequest request) {
        if (request.contentLength() <= 0) {
            throw new IllegalArgumentException("Attachment content length must be positive");
        }
        String key = StorageService.generateStorageKey(request.fileName());
        String physicalKey = stagingKey(key);
        String contentType = StringUtils.hasText(request.contentType())
                ? request.contentType() : "application/octet-stream";
        Date expiration = expiryDate();

        PolicyConditions conditions = new PolicyConditions();
        conditions.addConditionItem(PolicyConditions.COND_KEY, physicalKey);
        conditions.addConditionItem(PolicyConditions.COND_CONTENT_TYPE, contentType);
        conditions.addConditionItem(PolicyConditions.COND_SUCCESS_ACTION_STATUS, "201");
        conditions.addConditionItem(
                PolicyConditions.COND_CONTENT_LENGTH_RANGE,
                request.contentLength(), request.contentLength());
        conditions.addConditionItem(FORBID_OVERWRITE, "true");

        Credentials credentials = requireCredentials();
        String policy = client.generatePostPolicy(expiration, conditions);
        String signature = client.calculatePostSignature(policy);
        Map<String, String> fields = new LinkedHashMap<>();
        fields.put("key", physicalKey);
        fields.put("policy", policy);
        fields.put("OSSAccessKeyId", credentials.getAccessKeyId());
        fields.put("Signature", signature);
        fields.put("success_action_status", "201");
        fields.put("Content-Type", contentType);
        fields.put(FORBID_OVERWRITE, "true");
        if (credentials.useSecurityToken()) {
            fields.put("x-oss-security-token", credentials.getSecurityToken());
        }

        return new PresignedUpload(
                key,
                postOrigin(),
                "POST",
                Map.of(),
                Map.copyOf(fields),
                expiration.toInstant());
    }

    @Override
    public StoredObject describe(String storageKey) {
        try {
            ObjectMetadata metadata = client.getObjectMetadata(
                    stagingBucket, stagingKey(storageKey));
            requireUnversionedStaging(metadata.getVersionId());
            return new StoredObject(
                    true,
                    metadata.getContentLength(),
                    metadata.getContentType(),
                    null,
                    metadata.getETag());
        } catch (OSSException e) {
            if ("NoSuchKey".equals(e.getErrorCode())) {
                return new StoredObject(false, 0, null, null, null);
            }
            throw e;
        }
    }

    @Override
    public InputStream openForValidation(String storageKey, String versionId) {
        requireUnversionedStaging(versionId);
        GetObjectRequest request = new GetObjectRequest(
                stagingBucket, stagingKey(storageKey));
        return client.getObject(request).getObjectContent();
    }

    @Override
    public StoredObject promoteToFinal(String storageKey, StoredObject stagingObject) {
        requireUnversionedStaging(stagingObject.versionId());
        StoredObject existing = describeFinal(storageKey);
        if (existing.exists()) {
            if (existing.size() == stagingObject.size()
                    && StringUtils.hasText(existing.eTag())
                    && StringUtils.hasText(stagingObject.eTag())
                    && stripQuotes(existing.eTag())
                    .equals(stripQuotes(stagingObject.eTag()))) {
                return existing;
            }
            throw new IllegalStateException(
                    "OSS final object already exists with different immutable metadata");
        }
        CopyObjectRequest request = new CopyObjectRequest(
                stagingBucket,
                stagingKey(storageKey),
                null,
                finalBucket,
                finalKey(storageKey));
        if (StringUtils.hasText(stagingObject.eTag())) {
            request.setMatchingETagConstraints(java.util.List.of(stagingObject.eTag()));
        }
        CopyObjectResult copied = client.copyObject(request);
        requirePinnedVersion(copied.getVersionId());
        if (StringUtils.hasText(stagingObject.eTag())
                && StringUtils.hasText(copied.getETag())
                && !stripQuotes(stagingObject.eTag()).equals(stripQuotes(copied.getETag()))) {
            throw new IllegalStateException("OSS copy ETag differs from inspected staging object");
        }
        return new StoredObject(
                true,
                stagingObject.size(),
                stagingObject.contentType(),
                copied.getVersionId(),
                copied.getETag());
    }

    private StoredObject describeFinal(String storageKey) {
        try {
            ObjectMetadata metadata = client.getObjectMetadata(
                    finalBucket, finalKey(storageKey));
            requirePinnedVersion(metadata.getVersionId());
            return new StoredObject(
                    true,
                    metadata.getContentLength(),
                    metadata.getContentType(),
                    metadata.getVersionId(),
                    metadata.getETag());
        } catch (OSSException e) {
            if ("NoSuchKey".equals(e.getErrorCode())) {
                return new StoredObject(false, 0, null, null, null);
            }
            throw e;
        }
    }

    @Override
    public PresignedDownload presignDownload(String storageKey, String versionId) {
        requirePinnedVersion(versionId);
        Date expiration = expiryDate();
        GeneratePresignedUrlRequest request = new GeneratePresignedUrlRequest(
                finalBucket, finalKey(storageKey), HttpMethod.GET);
        request.setExpiration(expiration);
        if (StringUtils.hasText(versionId)) {
            request.addQueryParameter("versionId", versionId);
        }
        // 强制下载语义：预签名 URL 一旦外泄，浏览器打开也不得内联渲染
        // （档案文件含合同/证件/发票图片，PDF 内嵌 JS 与 MIME 嗅探攻击面一律关闭）。
        // 客户端为应用内 Dio 字节下载，文件名由附件元数据决定，不依赖浏览器。
        request.addQueryParameter("response-content-disposition", "attachment");
        request.addQueryParameter("response-content-type", "application/octet-stream");
        URL url = client.generatePresignedUrl(request);
        return new PresignedDownload(url.toString(), expiration.toInstant());
    }

    @Override
    public void delete(String storageKey, String versionId) {
        requirePinnedVersion(versionId);
        deleteAt(finalBucket, finalKey(storageKey), versionId, "final");
    }

    @Override
    public void deleteStaging(String storageKey, String versionId) {
        requireUnversionedStaging(versionId);
        deleteAt(stagingBucket, stagingKey(storageKey), null, "staging");
    }

    @Override
    public List<StoredObjectRef> inventory() {
        if (!properties.getReconciliation().isEnabled()) {
            throw new UnsupportedOperationException(
                    "OSS attachment inventory grant is not enabled");
        }
        List<StoredObjectRef> result = new ArrayList<>();
        listStagingObjects(keyPrefix + STAGING_PREFIX, result);
        listFinalVersions(keyPrefix + FINAL_PREFIX, result);
        return List.copyOf(result);
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
        client.shutdown();
    }

    private void deleteAt(String targetBucket, String physicalKey,
                          String versionId, String location) {
        try {
            if (StringUtils.hasText(versionId)) {
                client.deleteVersion(targetBucket, physicalKey, versionId);
            } else {
                client.deleteObject(targetBucket, physicalKey);
            }
        } catch (Exception e) {
            log.warn("OSS attachment delete failed location={} type={}",
                    location, e.getClass().getSimpleName());
            throw new IllegalStateException("Unable to delete OSS attachment", e);
        }
    }

    private void listFinalVersions(String namespace,
                                   List<StoredObjectRef> destination) {
        String keyMarker = null;
        String versionMarker = null;
        while (true) {
            ListVersionsRequest request = new ListVersionsRequest(
                    finalBucket, namespace, keyMarker, versionMarker, null, 1000);
            VersionListing page = client.listVersions(request);
            for (OSSVersionSummary summary : page.getVersionSummaries()) {
                if (summary.isDeleteMarker()) {
                    continue;
                }
                String physicalKey = summary.getKey();
                if (!physicalKey.startsWith(namespace)) {
                    throw new IllegalStateException("OSS inventory escaped its approved prefix");
                }
                String storageKey = physicalKey.substring(namespace.length());
                validateStorageKey(storageKey);
                requirePinnedVersion(summary.getVersionId());
                destination.add(new StoredObjectRef(
                        ObjectLocation.FINAL,
                        storageKey,
                        summary.getVersionId(),
                        summary.getSize(),
                        summary.getLastModified() == null
                                ? null : summary.getLastModified().toInstant()));
                requireInventoryBelowCap(destination);
            }
            if (!page.isTruncated()) {
                return;
            }
            String nextKey = page.getNextKeyMarker();
            String nextVersion = page.getNextVersionIdMarker();
            if (!StringUtils.hasText(nextKey)
                    || Objects.equals(keyMarker, nextKey)
                    && Objects.equals(versionMarker, nextVersion)) {
                throw new IllegalStateException(
                        "OSS final inventory returned an unsafe pagination marker");
            }
            keyMarker = nextKey;
            versionMarker = nextVersion;
        }
    }

    private void listStagingObjects(String namespace,
                                    List<StoredObjectRef> destination) {
        String marker = null;
        while (true) {
            ObjectListing page = client.listObjects(new ListObjectsRequest(
                    stagingBucket, namespace, marker, null, 1000));
            for (OSSObjectSummary summary : page.getObjectSummaries()) {
                String physicalKey = summary.getKey();
                if (!physicalKey.startsWith(namespace)) {
                    throw new IllegalStateException(
                            "OSS staging inventory escaped its approved prefix");
                }
                String storageKey = physicalKey.substring(namespace.length());
                validateStorageKey(storageKey);
                destination.add(new StoredObjectRef(
                        ObjectLocation.STAGING,
                        storageKey,
                        null,
                        summary.getSize(),
                        summary.getLastModified() == null
                                ? null : summary.getLastModified().toInstant()));
                requireInventoryBelowCap(destination);
            }
            if (!page.isTruncated()) {
                return;
            }
            String next = page.getNextMarker();
            if (!StringUtils.hasText(next) || Objects.equals(marker, next)) {
                throw new IllegalStateException(
                        "OSS staging inventory returned an unsafe pagination marker");
            }
            marker = next;
        }
    }

    private String stagingKey(String storageKey) {
        return keyPrefix + STAGING_PREFIX + validateStorageKey(storageKey);
    }

    private String finalKey(String storageKey) {
        return keyPrefix + FINAL_PREFIX + validateStorageKey(storageKey);
    }

    private String postOrigin() {
        String host = endpoint.getHost();
        if (!host.equalsIgnoreCase(stagingBucket)
                && !host.toLowerCase(java.util.Locale.ROOT)
                .startsWith(stagingBucket.toLowerCase(java.util.Locale.ROOT) + ".")) {
            host = stagingBucket + "." + host;
        }
        try {
            return new URI(endpoint.getScheme(), null, host, endpoint.getPort(),
                    "/", null, null).toString();
        } catch (URISyntaxException e) {
            throw new IllegalStateException("Unable to construct OSS POST origin", e);
        }
    }

    private Date expiryDate() {
        return Date.from(Instant.now().plusSeconds(properties.getPresignedExpirySeconds()));
    }

    private Credentials requireCredentials() {
        if (credentialsProvider == null) {
            throw new IllegalStateException("OSS POST policy credentials provider is unavailable");
        }
        Credentials credentials = credentialsProvider.getCredentials();
        if (credentials == null || !StringUtils.hasText(credentials.getAccessKeyId())) {
            throw new IllegalStateException("OSS POST policy credentials are unavailable");
        }
        if (credentials.useSecurityToken()
                && !StringUtils.hasText(credentials.getSecurityToken())) {
            throw new IllegalStateException("OSS session credentials have no security token");
        }
        return credentials;
    }

    private void requirePinnedVersion(String versionId) {
        if (properties.getOss().isRequireVersioning()
                && (!StringUtils.hasText(versionId)
                || "null".equalsIgnoreCase(versionId.trim()))) {
            throw new IllegalStateException(
                    "OSS versionId is required when Bucket versioning is enforced");
        }
    }

    private static void requireUnversionedStaging(String versionId) {
        if (StringUtils.hasText(versionId)
                && !"null".equalsIgnoreCase(versionId.trim())) {
            throw new IllegalStateException(
                    "OSS staging Bucket unexpectedly returned a versionId");
        }
    }

    private static void requireInventoryBelowCap(List<StoredObjectRef> destination) {
        if (destination.size() > 1_000_000) {
            throw new IllegalStateException("OSS attachment inventory exceeds safety cap");
        }
    }

    private void verifyProductionSafety(StorageProperties.Oss oss) {
        if (!oss.isRequireVersioning()) {
            return;
        }
        try {
            BucketVersioningConfiguration staging =
                    client.getBucketVersioning(stagingBucket);
            BucketVersioningConfiguration destination =
                    client.getBucketVersioning(finalBucket);
            if (staging == null
                    || !BucketVersioningConfiguration.OFF.equals(staging.getStatus())) {
                throw new IllegalStateException(
                        "OSS staging Bucket versioning must be Off");
            }
            if (destination == null
                    || !BucketVersioningConfiguration.ENABLED.equals(destination.getStatus())) {
                throw new IllegalStateException(
                        "OSS final Bucket versioning must be Enabled");
            }
        } catch (IllegalStateException e) {
            throw e;
        } catch (Exception e) {
            throw new IllegalStateException(
                    "Unable to verify both OSS Bucket versioning states; grant GetBucketVersioning",
                    e);
        }
    }

    private static ClientBundle createClientBundle(StorageProperties properties) {
        StorageProperties.Oss oss = properties.getOss();
        requireHttpsEndpoint(oss.getEndpoint());
        CredentialsProvider provider;
        if (oss.isUseInstanceRole()) {
            provider = new InstanceProfileCredentialsProvider(
                    requireConfigured("UTEN_OSS_ROLE_NAME", oss.getRoleName()));
        } else {
            provider = new DefaultCredentialProvider(
                    requireConfigured("UTEN_OSS_ACCESS_KEY_ID", oss.getAccessKeyId()),
                    requireConfigured("UTEN_OSS_ACCESS_KEY_SECRET", oss.getAccessKeySecret()));
        }
        try {
            return new ClientBundle(
                    new OSSClientBuilder().build(oss.getEndpoint(), provider), provider);
        } catch (Exception e) {
            throw new IllegalStateException("Unable to initialize Aliyun OSS client", e);
        }
    }

    private static String canonicalPrefix(String value) {
        if (!StringUtils.hasText(value)) {
            return "";
        }
        String prefix = value.trim();
        if (prefix.startsWith("/") || prefix.contains("//") || prefix.contains("..")) {
            throw new IllegalStateException("UTEN_OSS_KEY_PREFIX is not canonical");
        }
        return prefix.endsWith("/") ? prefix : prefix + "/";
    }

    private static String validateStorageKey(String value) {
        if (value == null || !value.matches("[A-Za-z0-9][A-Za-z0-9._-]{0,254}")
                || ".".equals(value) || "..".equals(value)) {
            throw new IllegalArgumentException("Invalid attachment storage key");
        }
        return value;
    }

    private static String stripQuotes(String value) {
        String result = value.trim();
        return result.length() >= 2 && result.startsWith("\"") && result.endsWith("\"")
                ? result.substring(1, result.length() - 1) : result;
    }

    private static String requireConfigured(String name, String value) {
        if (!StringUtils.hasText(value)) {
            throw new IllegalStateException(name + " must be configured for OSS storage");
        }
        return value.trim();
    }

    private static URI requireHttpsEndpoint(String value) {
        requireConfigured("UTEN_OSS_ENDPOINT", value);
        try {
            URI endpoint = URI.create(value.trim());
            if (!"https".equalsIgnoreCase(endpoint.getScheme())
                    || !StringUtils.hasText(endpoint.getHost())
                    || endpoint.getUserInfo() != null
                    || endpoint.getQuery() != null
                    || endpoint.getFragment() != null
                    || endpoint.getPath() != null && !endpoint.getPath().isEmpty()
                    && !"/".equals(endpoint.getPath())) {
                throw new IllegalStateException(
                        "UTEN_OSS_ENDPOINT must be a plain HTTPS OSS origin");
            }
            return endpoint;
        } catch (IllegalArgumentException e) {
            throw new IllegalStateException("UTEN_OSS_ENDPOINT must be a valid HTTPS origin", e);
        }
    }

    private record ClientBundle(OSS client, CredentialsProvider credentialsProvider) {
    }
}
