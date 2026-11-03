package com.uten.imp.features.clientupdates;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Base64;
import java.util.HashMap;
import java.util.UUID;
import java.util.Arrays;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.channels.FileChannel;
import java.nio.file.StandardOpenOption;
import java.io.ByteArrayOutputStream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class WindowsPayloadBindingTest {
    @TempDir Path directory;
    @Test void actualBytesAndSignedEnvelopeMatchAllSharedCrossLanguageVectors() throws Exception {
        var document = new ObjectMapper().readTree(Path.of("../contracts/windows-payload-binding/vectors.json").toFile());
        int count = 0;
        for (var vector : document.path("vectors")) {
            var metadata = vector.path("metadata");
            var release = new ClientReleaseDto.Release(UUID.randomUUID(), "windows", metadata.path("architecture").asText(), metadata.path("version").asText(),
                    metadata.path("buildNumber").asLong(), "", false, "fixture.zip", "0".repeat(64), null, 0,
                    "windows_archive", null, "", "DRAFT", Instant.now(), null, "update", metadata.path("runtimeFamily").asText());
            var proofs = new HashMap<String, WindowsPayloadBinding.FileProof>();
            for (var file : vector.path("records")) proofs.put(file.path("path").asText(),
                    new WindowsPayloadBinding.FileProof(file.path("size").asLong(), file.path("sha256").asText()));
            Path main = Files.write(directory.resolve("vector-" + count++ + ".exe"), Base64.getDecoder().decode(vector.path("mainBase64").asText()));
            if (vector.path("accept").asBoolean()) WindowsPayloadBinding.inspect(main, proofs, release);
            else assertThatThrownBy(() -> WindowsPayloadBinding.inspect(main, proofs, release))
                    .as(vector.path("name").asText()).isInstanceOfAny(ApiException.class, java.io.IOException.class);
        }
        assertThat(count).isGreaterThanOrEqualTo(15);
    }

    @Test void excessiveCertificateTableIsRejectedBeforeIteratingOrAllocatingItsContents() throws Exception {
        byte[] original = validMain();
        ByteBuffer pe = ByteBuffer.wrap(original).order(ByteOrder.LITTLE_ENDIAN);
        int optional = pe.getInt(60) + 24, directories = Short.toUnsignedInt(pe.getShort(optional)) == 0x10b ? 96 : 112;
        int certificate = pe.getInt(optional + directories + 32), oversized = 16777216 + 8;
        pe.putInt(optional + directories + 36, oversized);
        Path file = Files.write(directory.resolve("oversized-certificates.exe"), original);
        try (var channel = FileChannel.open(file, StandardOpenOption.WRITE)) {
            channel.position((long)certificate + oversized - 1);
            channel.write(ByteBuffer.wrap(new byte[] {0}));
        }
        assertThatThrownBy(() -> WindowsPayloadBinding.read(file)).isInstanceOf(ApiException.class).hasMessageContaining("证书表");
    }

    @Test void encodingAndWrappedSchemaNumberCannotLoosenStrictUtf8JsonContract() throws Exception {
        byte[] original = validMain();
        ByteBuffer pe = ByteBuffer.wrap(original).order(ByteOrder.LITTLE_ENDIAN);
        int optional = pe.getInt(60) + 24, directories = Short.toUnsignedInt(pe.getShort(optional)) == 0x10b ? 96 : 112;
        int certificate = pe.getInt(optional + directories + 32), footer = certificate - 28;
        int length = pe.getInt(footer);
        String json = new String(original, footer - length, length, StandardCharsets.UTF_8);
        byte[] canonical = json.getBytes(StandardCharsets.UTF_8);
        var bom = new ByteArrayOutputStream(); bom.write(new byte[] {(byte)0xef,(byte)0xbb,(byte)0xbf}); bom.write(canonical);
        var illegal = canonical.clone(); illegal[10] = (byte)0xc0;
        for (byte[] raw : new byte[][] {bom.toByteArray(), json.getBytes(StandardCharsets.UTF_16), illegal,
                json.replace("\"schemaVersion\":1", "\"schemaVersion\":4294967297").getBytes(StandardCharsets.UTF_8)}) {
            Path file = Files.write(directory.resolve(UUID.randomUUID() + ".exe"), repack(original, raw));
            assertThatThrownBy(() -> WindowsPayloadBinding.read(file)).isInstanceOfAny(ApiException.class, java.io.IOException.class);
        }
    }

    private byte[] validMain() throws Exception {
        var document = new ObjectMapper().readTree(Path.of("../contracts/windows-payload-binding/vectors.json").toFile());
        return Base64.getDecoder().decode(document.path("vectors").get(0).path("mainBase64").asText());
    }

    private byte[] repack(byte[] original, byte[] raw) throws Exception {
        Path source = Files.write(directory.resolve(UUID.randomUUID() + ".exe"), original);
        long mapped;
        try (var channel = FileChannel.open(source, StandardOpenOption.READ)) { mapped = WindowsEngineSafety.layout(channel).mappedEnd(); }
        byte[] base = Arrays.copyOf(original, (int)mapped);
        ByteBuffer pe = ByteBuffer.wrap(base).order(ByteOrder.LITTLE_ENDIAN);
        int optional = pe.getInt(60) + 24, directories = Short.toUnsignedInt(pe.getShort(optional)) == 0x10b ? 96 : 112;
        int originalCertificate = pe.getInt(optional + directories + 32);
        byte[] certificate = Arrays.copyOfRange(original, originalCertificate, original.length);
        int padding = -(base.length + raw.length + 28) & 7;
        pe.putInt(optional + directories + 32, base.length + padding + raw.length + 28);
        var output = new ByteArrayOutputStream(); output.write(base); output.write(new byte[padding]); output.write(raw);
        output.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(raw.length).array());
        output.write("UTEN-PAYLOAD-BINDING-V1\0".getBytes(StandardCharsets.US_ASCII)); output.write(certificate);
        return output.toByteArray();
    }
}
