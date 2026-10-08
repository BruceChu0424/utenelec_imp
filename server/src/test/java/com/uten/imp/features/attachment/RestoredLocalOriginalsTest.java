package com.uten.imp.features.attachment;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.storage.LocalDiskStorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.test.util.ReflectionTestUtils;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

/** Reads restored originals using real application readers. No source DB/files are modified. */
@EnabledIfEnvironmentVariable(named = "UTEN_RECOVERY_MANIFEST", matches = ".+")
class RestoredLocalOriginalsTest {
    @Test void restoredSnapshotReferencesReadExactBytesAndRejectMismatchedMetadata() throws Exception {
        Path manifestPath = Path.of(System.getenv("UTEN_RECOVERY_MANIFEST")).toRealPath();
        var mapper = new ObjectMapper();
        var manifest = mapper.readTree(manifestPath.toFile());
        assertEquals("uten-local-recovery-v2", manifest.path("format").asText());
        assertEquals("EXACT_DATABASE_AND_LOCAL_ORIGINALS_VERIFIED", manifest.path("outcome").asText());
        Path restored = manifestPath.getParent().resolve("media").toRealPath();
        assertTrue(restored.startsWith(manifestPath.getParent()));
        assertTrue(manifest.path("media").isArray());
        assertFalse(manifest.path("media").isEmpty(), "An empty snapshot cannot prove real original readback");
        var properties = new StorageProperties();
        properties.setLocalDir(restored.toString());
        properties.getInternal().setMinFreeBytes(0);
        var storage = new LocalDiskStorageService(properties);
        ReflectionTestUtils.invokeMethod(storage, "init");
        var registry = new StorageProviderRegistry(storage, properties);
        var privateReader = new ImmutableDocumentStore(storage, registry, com.uten.imp.common.files.malware.DocumentSafetyTestSupport.scanning());
        var ordinaryReader = new AttachmentDownloadVerifier(registry, properties);
        int privateCount = 0, ordinaryCount = 0;
        for (var object : manifest.path("media")) {
            assertEquals("local", object.path("storage_provider").asText());
            assertTrue(object.path("storage_version").isNull());
            String key = object.path("storage_key").asText();
            String hash = object.path("sha256").asText();
            long size = object.path("bytes").asLong();
            Path file = restored.resolve("final").resolve(key).toRealPath();
            assertTrue(file.startsWith(restored.resolve("final")));
            byte[] expected = Files.readAllBytes(file);
            assertEquals(size, expected.length);
            assertEquals(hash, ImmutableDocumentStore.digest(expected));
            if ("private".equals(object.path("kind").asText())) {
                assertArrayEquals(expected, privateReader.read(new ImmutableDocumentStore.Reference("local", key, null, size, hash)));
                assertThrows(IllegalStateException.class, () -> privateReader.read(new ImmutableDocumentStore.Reference("local", key, null, size, "0".repeat(64))));
                privateCount++;
            } else {
                var metadata = new Attachment();
                metadata.setStorageProvider("local"); metadata.setStorageKey(key); metadata.setStorageEncoding("IDENTITY");
                metadata.setSizeBytes(size); metadata.setSha256(hash);
                try (var input = ordinaryReader.open(metadata)) { assertArrayEquals(expected, input.readAllBytes()); }
                metadata.setSha256("0".repeat(64));
                assertThrows(com.uten.imp.common.web.ApiException.class, () -> ordinaryReader.open(metadata));
                ordinaryCount++;
            }
        }
        Map<String, Object> receipt = new LinkedHashMap<>();
        receipt.put("format", "uten-restored-original-application-readback-v1");
        receipt.put("privateOriginals", privateCount); receipt.put("ordinaryOriginals", ordinaryCount);
        receipt.put("corruptMetadataRejected", true); receipt.put("applicationReadersVerified", true);
        receipt.put("httpAuthorizationVerified", false);
        receipt.put("scope", "real restored local originals through production storage readers; other codecs and HTTP permissions have separate regression evidence");
        mapper.writerWithDefaultPrettyPrinter().writeValue(manifestPath.getParent().resolve("application-readback.json").toFile(), receipt);
    }
}
