package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.storage.StorageResourceUnavailableException;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.HexFormat;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class AttachmentDownloadVerifierTest {
    @Test void legacyReadPreservesBytesAndChecksThePinnedBackendVersion() throws Exception {
        var provider=mock(StorageService.class);var registry=mock(StorageProviderRegistry.class);
        when(registry.require("oss")).thenReturn(provider);byte[] bytes={10,20,30};var metadata=metadata(bytes);
        when(provider.openFinal("old.pdf","original-version")).thenReturn(new ByteArrayInputStream(bytes));
        var verifier=new AttachmentDownloadVerifier(registry,properties());
        try(var input=verifier.open(metadata)){assertArrayEquals(bytes,input.readAllBytes());}
        verify(provider).openFinal("old.pdf","original-version");
    }
    @Test void corruptAndTruncatedLegacyObjectsNeverExposeAnInputStream() throws Exception {
        var provider=mock(StorageService.class);var registry=mock(StorageProviderRegistry.class);
        when(registry.require("oss")).thenReturn(provider);var metadata=metadata(new byte[]{1,2,3});
        when(provider.openFinal("old.pdf","original-version")).thenReturn(new ByteArrayInputStream(new byte[]{1,2,4}),new ByteArrayInputStream(new byte[]{1,2}));
        var verifier=new AttachmentDownloadVerifier(registry,properties());
        assertThrows(ApiException.class,()->verifier.open(metadata));
        assertThrows(ApiException.class,()->verifier.open(metadata));
    }
    @Test void verifiedDownloadSlotsAreHeldUntilCloseAndNotLeakedByFailure() throws Exception {
        var provider=mock(StorageService.class);var registry=mock(StorageProviderRegistry.class);
        when(registry.require("oss")).thenReturn(provider);var metadata=metadata(new byte[]{1,2,3});
        when(provider.openFinal("old.pdf","original-version")).thenAnswer(ignored->new ByteArrayInputStream(new byte[]{1,2,3}));
        var properties=properties();properties.getInternal().setMaxConcurrentIo(1);var verifier=new AttachmentDownloadVerifier(registry,properties);
        try(var held=verifier.open(metadata)){assertThrows(StorageResourceUnavailableException.class,()->verifier.open(metadata));}
        try(var reopened=verifier.open(metadata)){assertEquals(3,reopened.readAllBytes().length);}
    }
    private static StorageProperties properties(){var properties=new StorageProperties();properties.getInternal().setMinFreeBytes(0);return properties;}
    private static Attachment metadata(byte[] bytes) throws Exception {
        var metadata=new Attachment();metadata.setStorageProvider("oss");metadata.setStorageKey("old.pdf");
        metadata.setStorageVersion("original-version");metadata.setStorageEncoding("IDENTITY");metadata.setSizeBytes(bytes.length);
        metadata.setSha256(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)));return metadata;
    }
}
