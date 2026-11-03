package com.uten.imp.features.clientupdates;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ClientZipDirectoryTest {
    @TempDir Path directory;

    @Test void sharedCrossLanguageVectorsBoundMetadataBeforeOpeningZipLibrary() throws Exception {
        Path contract = Path.of("..", "contracts", "windows-zip-directory", "vectors-v1.json");
        var vectors = new ObjectMapper().readTree(contract.toFile()).path("vectors");
        assertThat(vectors.size()).isGreaterThan(20);
        Path file = directory.resolve("input.zip");
        for (var vector : vectors) {
            Files.write(file, Base64.getDecoder().decode(vector.path("zipBase64").asText()));
            int count = vector.path("maxEntries").asInt();
            long centralBytes = vector.path("maxCentralBytes").asLong();
            String name = vector.path("name").asText();
            if (vector.path("valid").asBoolean()) {
                var result = ClientZipDirectory.inspect(file, count, centralBytes);
                assertThat(result.entries()).as(name).isEqualTo(vector.path("entries").asInt());
                assertThat(result.centralBytes()).as(name).isEqualTo(vector.path("centralBytes").asLong());
                assertThat(result.centralOffset()).as(name).isEqualTo(vector.path("centralOffset").asLong());
                try (var zip = new java.util.zip.ZipFile(file.toFile())) {
                    assertThat(zip.size()).as(name).isEqualTo(result.entries());
                    var entries = zip.entries();
                    while (entries.hasMoreElements()) try (var input = zip.getInputStream(entries.nextElement())) { input.transferTo(java.io.OutputStream.nullOutputStream()); }
                }
            } else assertThatThrownBy(() -> ClientZipDirectory.inspect(file, count, centralBytes)).as(name).isInstanceOf(ApiException.class);
        }
    }

    @Test void actualJavaStreamingProducerUsesTheSameBoundedContract() throws Exception {
        Path file = directory.resolve("streamed.zip");
        try (var output = new ZipOutputStream(Files.newOutputStream(file))) {
            for (int index = 0; index < 2001; index++) {
                output.putNextEntry(new ZipEntry("assets/entry-" + index + ".bin"));
                output.write("fixed synthetic data".getBytes(java.nio.charset.StandardCharsets.UTF_8));
                output.closeEntry();
            }
        }
        assertThat(ClientZipDirectory.inspect(file, 2001, 1024 * 1024).entries()).isEqualTo(2001);
        assertThatThrownBy(() -> ClientZipDirectory.inspect(file, 2000, 1024 * 1024)).isInstanceOf(ApiException.class);
    }

    @Test void invalidLimitsAreRejectedBeforeFileAccess() {
        assertThatThrownBy(() -> ClientZipDirectory.inspect(directory.resolve("missing.zip"), 65535, 1024)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> ClientZipDirectory.inspect(directory.resolve("missing.zip"), 1, 0)).isInstanceOf(IllegalArgumentException.class);
    }
}
