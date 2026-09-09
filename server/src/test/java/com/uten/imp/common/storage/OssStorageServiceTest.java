package com.uten.imp.common.storage;

import com.aliyun.oss.OSS;
import com.aliyun.oss.OSSException;
import com.aliyun.oss.HttpMethod;
import com.aliyun.oss.common.auth.BasicCredentials;
import com.aliyun.oss.common.auth.CredentialsProvider;
import com.aliyun.oss.model.BucketVersioningConfiguration;
import com.aliyun.oss.model.CopyObjectRequest;
import com.aliyun.oss.model.CopyObjectResult;
import com.aliyun.oss.model.GeneratePresignedUrlRequest;
import com.aliyun.oss.model.GetObjectRequest;
import com.aliyun.oss.model.ListObjectsRequest;
import com.aliyun.oss.model.ListVersionsRequest;
import com.aliyun.oss.model.OSSObject;
import com.aliyun.oss.model.OSSObjectSummary;
import com.aliyun.oss.model.OSSVersionSummary;
import com.aliyun.oss.model.ObjectMetadata;
import com.aliyun.oss.model.ObjectListing;
import com.aliyun.oss.model.PolicyConditions;
import com.aliyun.oss.model.VersionListing;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.ArgumentCaptor;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.net.URI;
import java.net.URL;
import java.util.Date;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class OssStorageServiceTest {

    @Test
    void historicalAdapterRequiresAnExactVersionAndCannotCreateOrDeleteRemoteObjects() throws Exception {
        OSS client=mock(OSS.class);var properties=properties(false);properties.getOss().setStagingBucket("");
        var storage=new OssStorageService(properties,client,null,true);
        OSSObject object=new OSSObject();InputStream bytes=new ByteArrayInputStream(new byte[]{1,2,3});object.setObjectContent(bytes);
        when(client.getObject(any(GetObjectRequest.class))).thenReturn(object);
        assertThrows(IllegalStateException.class,()->storage.openFinal("old.pdf",null));
        assertSame(bytes,storage.openFinal("old.pdf","original-version"));
        var request=ArgumentCaptor.forClass(GetObjectRequest.class);verify(client).getObject(request.capture());
        assertEquals("original-version",request.getValue().getVersionId());
        verify(client,never()).getBucketVersioning(anyString());
        assertThrows(UnsupportedOperationException.class,()->storage.presignUpload(
                new StorageService.UploadRequest("EMPLOYEE","new.pdf","application/pdf",10)));
        assertThrows(UnsupportedOperationException.class,()->storage.delete("old.pdf","original-version"));
        assertThrows(UnsupportedOperationException.class,()->storage.promoteToFinal("old.pdf",new StorageService.StoredObject(true,10,null,null,null)));
    }

    @Test
    void postPolicyCarriesNoOverwriteAndExactLength() {
        OSS client = mock(OSS.class);
        when(client.generatePostPolicy(any(), any(PolicyConditions.class))).thenReturn("policy");
        when(client.calculatePostSignature("policy")).thenReturn("signature");
        OssStorageService storage = new OssStorageService(
                properties(false), client, credentialsProvider(null));

        StorageService.PresignedUpload upload = storage.presignUpload(
                new StorageService.UploadRequest(
                        "EXPENSE_CLAIM", "receipt.png", "image/png", 8));

        ArgumentCaptor<PolicyConditions> conditions =
                ArgumentCaptor.forClass(PolicyConditions.class);
        verify(client).generatePostPolicy(any(), conditions.capture());
        String policyJson = conditions.getValue().jsonize();
        assertTrue(policyJson.contains("content-length-range"));
        assertTrue(policyJson.contains("8"));
        assertTrue(policyJson.contains(upload.storageKey()));
        assertEquals("attachments/staging/" + upload.storageKey(),
                upload.formFields().get("key"));
        assertEquals("POST", upload.method());
        assertEquals("https://uten-attachments-staging.oss-cn-hangzhou.aliyuncs.com/",
                upload.url());
        assertEquals("true", upload.formFields().get("x-oss-forbid-overwrite"));
        assertEquals("policy", upload.formFields().get("policy"));
        assertEquals("signature", upload.formFields().get("Signature"));
    }

    @Test
    void splitBucketPostPolicyUsesSessionTokenAndStillPreventsReplay() {
        OSS client = versionedClient();
        when(client.generatePostPolicy(any(), any(PolicyConditions.class))).thenReturn("policy");
        when(client.calculatePostSignature("policy")).thenReturn("signature");
        OssStorageService storage = new OssStorageService(
                properties(true), client, credentialsProvider("security-token"));

        StorageService.PresignedUpload upload = storage.presignUpload(
                new StorageService.UploadRequest(
                        "EXPENSE_CLAIM", "receipt.png", "image/png", 8));

        assertEquals("true", upload.formFields().get("x-oss-forbid-overwrite"));
        assertEquals("security-token", upload.formFields().get("x-oss-security-token"));
        assertEquals("test-access-key", upload.formFields().get("OSSAccessKeyId"));
    }

    @Test
    void productionGateRejectsBucketWithoutEnabledVersioning() {
        OSS client = mock(OSS.class);
        when(client.getBucketVersioning("uten-attachments-staging"))
                .thenReturn(new BucketVersioningConfiguration(
                        BucketVersioningConfiguration.OFF));
        when(client.getBucketVersioning("uten-attachments-final"))
                .thenReturn(new BucketVersioningConfiguration(
                        BucketVersioningConfiguration.SUSPENDED));

        assertThrows(IllegalStateException.class,
                () -> new OssStorageService(properties(true), client));
    }

    @Test
    void productionGateRejectsVersionedStagingBucket() {
        OSS client = mock(OSS.class);
        when(client.getBucketVersioning("uten-attachments-staging"))
                .thenReturn(new BucketVersioningConfiguration(
                        BucketVersioningConfiguration.ENABLED));
        when(client.getBucketVersioning("uten-attachments-final"))
                .thenReturn(new BucketVersioningConfiguration(
                        BucketVersioningConfiguration.ENABLED));

        assertThrows(IllegalStateException.class,
                () -> new OssStorageService(properties(true), client));
    }

    @Test
    void stagingAndFinalBucketsMustBeDifferent() {
        StorageProperties properties = properties(false);
        properties.getOss().setFinalBucket(properties.getOss().getStagingBucket());

        assertThrows(IllegalStateException.class,
                () -> new OssStorageService(properties, mock(OSS.class)));
    }

    @ParameterizedTest
    @ValueSource(strings = {"version-1", "unexpected-version"})
    void stagingGateFailsClosedWhenMetadataHasVersionId(String versionId) {
        OSS client = versionedClient();
        ObjectMetadata metadata = mock(ObjectMetadata.class);
        when(metadata.getVersionId()).thenReturn(versionId);
        when(client.getObjectMetadata(
                "uten-attachments-staging", "attachments/staging/object-key"))
                .thenReturn(metadata);
        OssStorageService storage = new OssStorageService(properties(true), client);

        assertThrows(IllegalStateException.class,
                () -> storage.describe("object-key"));
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {" ", "null", "NULL", " null "})
    void versionedOperationsFailClosedWithoutPinnedVersion(String versionId) {
        OSS client = versionedClient();
        OssStorageService storage = new OssStorageService(properties(true), client);

        assertThrows(IllegalStateException.class,
                () -> storage.presignDownload("object-key", versionId));
        assertThrows(IllegalStateException.class,
                () -> storage.delete("object-key", versionId));

        verify(client, never()).generatePresignedUrl(any(GeneratePresignedUrlRequest.class));
        verify(client, never()).deleteVersion(anyString(), anyString(), anyString());
        verify(client, never()).deleteObject(anyString(), anyString());
    }

    @Test
    void validationGetUsesTheImmutableUnversionedStagingObject() throws Exception {
        OSS client = versionedClient();
        OSSObject object = new OSSObject();
        InputStream content = new ByteArrayInputStream(new byte[]{1, 2, 3});
        object.setObjectContent(content);
        when(client.getObject(any(GetObjectRequest.class))).thenReturn(object);
        OssStorageService storage = new OssStorageService(properties(true), client);

        try (InputStream actual = storage.openForValidation("object-key", null)) {
            assertSame(content, actual);
        }

        ArgumentCaptor<GetObjectRequest> request =
                ArgumentCaptor.forClass(GetObjectRequest.class);
        verify(client).getObject(request.capture());
        assertEquals("uten-attachments-staging", request.getValue().getBucketName());
        assertEquals("attachments/staging/object-key", request.getValue().getKey());
        assertNull(request.getValue().getVersionId());
    }

    @Test
    void presignedGetPinsTheRequestedObjectVersion() throws Exception {
        OSS client = versionedClient();
        when(client.generatePresignedUrl(any(GeneratePresignedUrlRequest.class)))
                .thenReturn(new URI("https://bucket.example/object-key?signature=test").toURL());
        OssStorageService storage = new OssStorageService(properties(true), client);

        storage.presignDownload("object-key", "version-42");

        ArgumentCaptor<GeneratePresignedUrlRequest> request =
                ArgumentCaptor.forClass(GeneratePresignedUrlRequest.class);
        verify(client).generatePresignedUrl(request.capture());
        assertEquals(HttpMethod.GET, request.getValue().getMethod());
        assertEquals("uten-attachments-final", request.getValue().getBucketName());
        assertEquals("attachments/final/object-key", request.getValue().getKey());
        assertEquals("version-42",
                request.getValue().getQueryParameter().get("versionId"));
    }

    @Test
    void deletePinsTheRequestedObjectVersion() {
        OSS client = versionedClient();
        OssStorageService storage = new OssStorageService(properties(true), client);

        storage.delete("object-key", "version-42");

        verify(client).deleteVersion(
                "uten-attachments-final", "attachments/final/object-key", "version-42");
        verify(client, never()).deleteObject(
                "uten-attachments-final", "attachments/final/object-key");
    }

    @Test
    void nonVersionedDevelopmentStillAllowsLatestObjectFallback() throws Exception {
        OSS client = mock(OSS.class);
        OSSObject object = new OSSObject();
        object.setObjectContent(new ByteArrayInputStream(new byte[]{1}));
        when(client.getObject(any(GetObjectRequest.class))).thenReturn(object);
        when(client.generatePresignedUrl(any(GeneratePresignedUrlRequest.class)))
                .thenReturn(new URI("https://bucket.example/object-key?signature=test").toURL());
        OssStorageService storage = new OssStorageService(properties(false), client);

        try (InputStream ignored = storage.openForValidation("object-key", null)) {
            storage.presignDownload("object-key", null);
            storage.delete("object-key", null);
        }

        ArgumentCaptor<GetObjectRequest> getRequest =
                ArgumentCaptor.forClass(GetObjectRequest.class);
        verify(client).getObject(getRequest.capture());
        assertNull(getRequest.getValue().getVersionId());
        ArgumentCaptor<GeneratePresignedUrlRequest> presignRequest =
                ArgumentCaptor.forClass(GeneratePresignedUrlRequest.class);
        verify(client).generatePresignedUrl(presignRequest.capture());
        assertFalse(presignRequest.getValue().getQueryParameter().containsKey("versionId"));
        verify(client).deleteObject(
                "uten-attachments-final", "attachments/final/object-key");
        verify(client, never()).deleteVersion(anyString(), anyString(), anyString());
    }

    @Test
    void rejectsPlainHttpEndpoint() {
        OSS client = mock(OSS.class);
        StorageProperties properties = properties(false);
        properties.getOss().setEndpoint("http://oss-cn-hangzhou.aliyuncs.com");

        assertThrows(IllegalStateException.class,
                () -> new OssStorageService(properties, client));
    }

    @Test
    void promotionPinsTheInspectedStagingVersionAndReturnsFinalVersion() {
        OSS client = versionedClient();
        when(client.getObjectMetadata(
                "uten-attachments-final", "attachments/final/object-key"))
                .thenThrow(noSuchKey());
        CopyObjectResult copied = new CopyObjectResult();
        copied.setVersionId("final-version");
        copied.setEtag("etag-1");
        when(client.copyObject(any(CopyObjectRequest.class))).thenReturn(copied);
        OssStorageService storage = new OssStorageService(properties(true), client);

        StorageService.StoredObject promoted = storage.promoteToFinal(
                "object-key",
                new StorageService.StoredObject(
                        true, 8, "image/png", null, "etag-1"));

        ArgumentCaptor<CopyObjectRequest> request =
                ArgumentCaptor.forClass(CopyObjectRequest.class);
        verify(client).copyObject(request.capture());
        assertEquals("uten-attachments-staging", request.getValue().getSourceBucketName());
        assertEquals("attachments/staging/object-key", request.getValue().getSourceKey());
        assertNull(request.getValue().getSourceVersionId());
        assertEquals("uten-attachments-final", request.getValue().getDestinationBucketName());
        assertEquals("attachments/final/object-key", request.getValue().getDestinationKey());
        assertEquals("final-version", promoted.versionId());
    }

    @Test
    void promotionRetryReusesMatchingPinnedFinalVersion() {
        OSS client = versionedClient();
        ObjectMetadata existing = mock(ObjectMetadata.class);
        when(existing.getVersionId()).thenReturn("final-version");
        when(existing.getContentLength()).thenReturn(8L);
        when(existing.getContentType()).thenReturn("image/png");
        when(existing.getETag()).thenReturn("etag-1");
        when(client.getObjectMetadata(
                "uten-attachments-final", "attachments/final/object-key"))
                .thenReturn(existing);
        OssStorageService storage = new OssStorageService(properties(true), client);

        StorageService.StoredObject promoted = storage.promoteToFinal(
                "object-key",
                new StorageService.StoredObject(
                        true, 8, "image/png", null, "etag-1"));

        assertEquals("final-version", promoted.versionId());
        verify(client, never()).copyObject(any(CopyObjectRequest.class));
    }

    @Test
    void inventoryPaginatesBothBucketsWithoutFollowingUntrustedPrefixes() {
        OSS client = versionedClient();
        ObjectListing stagingPageOne = stagingPage(
                true, "next-staging", "attachments/staging/first.png", 1);
        ObjectListing stagingPageTwo = stagingPage(
                false, null, "attachments/staging/second.png", 2);
        when(client.listObjects(any(ListObjectsRequest.class)))
                .thenReturn(stagingPageOne, stagingPageTwo);

        VersionListing finalPage = new VersionListing();
        OSSVersionSummary finalObject = new OSSVersionSummary();
        finalObject.setKey("attachments/final/third.png");
        finalObject.setVersionId("version-3");
        finalObject.setSize(3);
        finalObject.setLastModified(new Date());
        finalPage.setVersionSummaries(List.of(finalObject));
        finalPage.setTruncated(false);
        when(client.listVersions(any(ListVersionsRequest.class))).thenReturn(finalPage);

        StorageProperties properties = properties(true);
        properties.getReconciliation().setEnabled(true);
        OssStorageService storage = new OssStorageService(properties, client);

        List<StorageService.StoredObjectRef> inventory = storage.inventory();

        assertEquals(3, inventory.size());
        assertEquals(StorageService.ObjectLocation.STAGING, inventory.get(0).location());
        assertNull(inventory.get(0).versionId());
        assertEquals(StorageService.ObjectLocation.FINAL, inventory.get(2).location());
        assertEquals("version-3", inventory.get(2).versionId());
        ArgumentCaptor<ListObjectsRequest> requests =
                ArgumentCaptor.forClass(ListObjectsRequest.class);
        verify(client, times(2)).listObjects(requests.capture());
        assertNull(requests.getAllValues().get(0).getMarker());
        assertEquals("next-staging", requests.getAllValues().get(1).getMarker());
    }

    @Test
    void truncatedInventoryWithoutProgressMarkerFailsClosed() {
        OSS client = versionedClient();
        when(client.listObjects(any(ListObjectsRequest.class)))
                .thenReturn(stagingPage(true, null,
                        "attachments/staging/object-key", 1));
        StorageProperties properties = properties(true);
        properties.getReconciliation().setEnabled(true);
        OssStorageService storage = new OssStorageService(properties, client);

        assertThrows(IllegalStateException.class, storage::inventory);
        verify(client, never()).listVersions(any(ListVersionsRequest.class));
    }

    private static StorageProperties properties(boolean requireVersioning) {
        StorageProperties properties = new StorageProperties();
        properties.getOss().setEndpoint("https://oss-cn-hangzhou.aliyuncs.com");
        properties.getOss().setStagingBucket("uten-attachments-staging");
        properties.getOss().setFinalBucket("uten-attachments-final");
        properties.getOss().setKeyPrefix("attachments/");
        properties.getOss().setRequireVersioning(requireVersioning);
        return properties;
    }

    private static OSS versionedClient() {
        OSS client = mock(OSS.class);
        when(client.getBucketVersioning("uten-attachments-staging"))
                .thenReturn(new BucketVersioningConfiguration(
                        BucketVersioningConfiguration.OFF));
        when(client.getBucketVersioning("uten-attachments-final"))
                .thenReturn(new BucketVersioningConfiguration(
                        BucketVersioningConfiguration.ENABLED));
        return client;
    }

    private static OSSException noSuchKey() {
        return new OSSException(
                "missing", "NoSuchKey", "request-id", "host-id",
                null, null, null);
    }

    private static ObjectListing stagingPage(boolean truncated, String nextMarker,
                                             String key, long size) {
        ObjectListing page = new ObjectListing();
        OSSObjectSummary object = new OSSObjectSummary();
        object.setKey(key);
        object.setSize(size);
        object.setLastModified(new Date());
        page.setObjectSummaries(List.of(object));
        page.setTruncated(truncated);
        page.setNextMarker(nextMarker);
        return page;
    }

    private static CredentialsProvider credentialsProvider(String securityToken) {
        CredentialsProvider provider = mock(CredentialsProvider.class);
        when(provider.getCredentials()).thenReturn(
                new BasicCredentials("test-access-key", "test-secret", securityToken));
        return provider;
    }
}
