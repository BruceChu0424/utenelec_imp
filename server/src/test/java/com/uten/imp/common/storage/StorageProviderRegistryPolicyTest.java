package com.uten.imp.common.storage;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.test.util.ReflectionTestUtils;

import java.io.ByteArrayInputStream;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class StorageProviderRegistryPolicyTest {
    @TempDir Path directory;

    @Test void historicalProvidersAreClosedUntilExplicitlyEnabled() {
        var active=mock(StorageService.class);when(active.backend()).thenReturn("internal");
        var properties=new StorageProperties();
        var registry=new StorageProviderRegistry(active,properties);
        assertThrows(ApiException.class,()->registry.require("local"));
        assertThrows(ApiException.class,()->registry.require("oss"));
        assertThrows(ApiException.class,()->registry.require("legacy_unknown"));
        assertSame(active,registry.require("internal"));
    }

    @Test void retainedLocalBytesRemainReadableOnlyWithAnExplicitRootAndCapability() throws Exception {
        var properties=new StorageProperties();properties.setLocalDir(directory.toString());properties.getInternal().setMinFreeBytes(0);
        var local=new LocalDiskStorageService(properties);ReflectionTestUtils.invokeMethod(local,"init");
        byte[] bytes={1,2,3};
        var upload=local.presignUpload(new StorageService.UploadRequest("AI_INPUT_ORIGINAL","old.bin","application/octet-stream",bytes.length));
        local.store(upload.storageKey(),new ByteArrayInputStream(bytes),bytes.length,"application/octet-stream");
        var original=local.promoteToFinal(upload.storageKey(),local.describe(upload.storageKey()));
        var active=mock(StorageService.class);when(active.backend()).thenReturn("internal");
        var registry=new StorageProviderRegistry(active,properties);
        assertThrows(ApiException.class,()->registry.require("local"));
        properties.setLegacyLocalReadEnabled(true);
        try(var read=registry.require("local").openFinal(upload.storageKey(),original.versionId())) {assertArrayEquals(bytes,read.readAllBytes());}
        properties.setLegacyLocalReadEnabled(false);
        assertThrows(ApiException.class,()->registry.require("local"),"A cached adapter must not bypass a withdrawn capability");
        try(var read=local.openFinal(upload.storageKey(),original.versionId())) {assertArrayEquals(bytes,read.readAllBytes(),"Changing capability never deletes retained originals");}
    }
}
