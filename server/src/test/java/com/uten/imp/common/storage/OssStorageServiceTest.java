package com.uten.imp.common.storage;

import com.aliyun.oss.OSS;
import com.aliyun.oss.HttpMethod;
import com.aliyun.oss.model.BucketVersioningConfiguration;
import com.aliyun.oss.model.GeneratePresignedUrlRequest;
import com.aliyun.oss.model.GetObjectRequest;
import com.aliyun.oss.model.OSSObject;
import com.aliyun.oss.model.ObjectMetadata;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.ArgumentCaptor;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.net.URL;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class OssStorageServiceTest {

    @Test
    void nonVersionedPresignedPutAtomicallyForbidsSameKeyOverwrite() throws Exception {
        OSS client = mock(OSS.class);
        when(client.generatePresignedUrl(any(GeneratePresignedUrlRequest.class)))
                .thenReturn(new URL("https://bucket.example/fixed.png?signature=test"));
        OssStorageService storage = new OssStorageService(properties(false), client);

        StorageService.PresignedUpload upload = storage.presignUpload(
                new StorageService.UploadRequest(
                        "EXPENSE_CLAIM", "receipt.png", "image/png", 8));

        ArgumentCaptor<GeneratePresignedUrlRequest> request =
                ArgumentCaptor.forClass(GeneratePresignedUrlRequest.class);
        verify(client).generatePresignedUrl(request.capture());
        assertEquals("true", request.getValue().getHeaders().get("x-oss-forbid-overwrite"));
        assertEquals("true", upload.headers().get("x-oss-forbid-overwrite"));
    }

    @Test
    void versionedPresignedPutDoesNotClaimUnsupportedNoOverwriteSemantics() throws Exception {
        OSS client = versionedClient();
        when(client.generatePresignedUrl(any(GeneratePresignedUrlRequest.class)))
                .thenReturn(new URL("https://bucket.example/fixed.png?signature=test"));
        OssStorageService storage = new OssStorageService(properties(true), client);

        StorageService.PresignedUpload upload = storage.presignUpload(
                new StorageService.UploadRequest(
                        "EXPENSE_CLAIM", "receipt.png", "image/png", 8));

        ArgumentCaptor<GeneratePresignedUrlRequest> request =
                ArgumentCaptor.forClass(GeneratePresignedUrlRequest.class);
        verify(client).generatePresignedUrl(request.capture());
        assertFalse(request.getValue().getHeaders().containsKey("x-oss-forbid-overwrite"));
        assertFalse(upload.headers().containsKey("x-oss-forbid-overwrite"));
    }

    @Test
    void productionGateRejectsBucketWithoutEnabledVersioning() {
        OSS client = mock(OSS.class);
        when(client.getBucketVersioning("uten-attachments"))
                .thenReturn(new BucketVersioningConfiguration(
                        BucketVersioningConfiguration.SUSPENDED));

        assertThrows(IllegalStateException.class,
                () -> new OssStorageService(properties(true), client));
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {" ", "null", "NULL"})
    void versioningGateFailsClosedWhenMetadataHasNoVersionId(String versionId) {
        OSS client = versionedClient();
        ObjectMetadata metadata = mock(ObjectMetadata.class);
        when(metadata.getVersionId()).thenReturn(versionId);
        when(client.getObjectMetadata("uten-attachments", "attachments/object-key"))
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
                () -> storage.openForValidation("object-key", versionId));
        assertThrows(IllegalStateException.class,
                () -> storage.presignDownload("object-key", versionId));
        assertThrows(IllegalStateException.class,
                () -> storage.delete("object-key", versionId));

        verify(client, never()).getObject(any(GetObjectRequest.class));
        verify(client, never()).generatePresignedUrl(any(GeneratePresignedUrlRequest.class));
        verify(client, never()).deleteVersion(anyString(), anyString(), anyString());
        verify(client, never()).deleteObject(anyString(), anyString());
    }

    @Test
    void validationGetPinsTheRequestedObjectVersion() throws Exception {
        OSS client = versionedClient();
        OSSObject object = new OSSObject();
        InputStream content = new ByteArrayInputStream(new byte[]{1, 2, 3});
        object.setObjectContent(content);
        when(client.getObject(any(GetObjectRequest.class))).thenReturn(object);
        OssStorageService storage = new OssStorageService(properties(true), client);

        try (InputStream actual = storage.openForValidation("object-key", "version-42")) {
            assertSame(content, actual);
        }

        ArgumentCaptor<GetObjectRequest> request =
                ArgumentCaptor.forClass(GetObjectRequest.class);
        verify(client).getObject(request.capture());
        assertEquals("uten-attachments", request.getValue().getBucketName());
        assertEquals("attachments/object-key", request.getValue().getKey());
        assertEquals("version-42", request.getValue().getVersionId());
    }

    @Test
    void presignedGetPinsTheRequestedObjectVersion() throws Exception {
        OSS client = versionedClient();
        when(client.generatePresignedUrl(any(GeneratePresignedUrlRequest.class)))
                .thenReturn(new URL("https://bucket.example/object-key?signature=test"));
        OssStorageService storage = new OssStorageService(properties(true), client);

        storage.presignDownload("object-key", "version-42");

        ArgumentCaptor<GeneratePresignedUrlRequest> request =
                ArgumentCaptor.forClass(GeneratePresignedUrlRequest.class);
        verify(client).generatePresignedUrl(request.capture());
        assertEquals(HttpMethod.GET, request.getValue().getMethod());
        assertEquals("uten-attachments", request.getValue().getBucketName());
        assertEquals("attachments/object-key", request.getValue().getKey());
        assertEquals("version-42",
                request.getValue().getQueryParameter().get("versionId"));
    }

    @Test
    void deletePinsTheRequestedObjectVersion() {
        OSS client = versionedClient();
        OssStorageService storage = new OssStorageService(properties(true), client);

        storage.delete("object-key", "version-42");

        verify(client).deleteVersion(
                "uten-attachments", "attachments/object-key", "version-42");
        verify(client, never()).deleteObject(
                "uten-attachments", "attachments/object-key");
    }

    @Test
    void nonVersionedDevelopmentStillAllowsLatestObjectFallback() throws Exception {
        OSS client = mock(OSS.class);
        OSSObject object = new OSSObject();
        object.setObjectContent(new ByteArrayInputStream(new byte[]{1}));
        when(client.getObject(any(GetObjectRequest.class))).thenReturn(object);
        when(client.generatePresignedUrl(any(GeneratePresignedUrlRequest.class)))
                .thenReturn(new URL("https://bucket.example/object-key?signature=test"));
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
        verify(client).deleteObject("uten-attachments", "attachments/object-key");
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

    private static StorageProperties properties(boolean requireVersioning) {
        StorageProperties properties = new StorageProperties();
        properties.getOss().setEndpoint("https://oss-cn-hangzhou.aliyuncs.com");
        properties.getOss().setBucket("uten-attachments");
        properties.getOss().setKeyPrefix("attachments/");
        properties.getOss().setRequireVersioning(requireVersioning);
        return properties;
    }

    private static OSS versionedClient() {
        OSS client = mock(OSS.class);
        when(client.getBucketVersioning("uten-attachments"))
                .thenReturn(new BucketVersioningConfiguration(
                        BucketVersioningConfiguration.ENABLED));
        return client;
    }
}
