package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Consumer;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class WindowsSetupInspectorTest {
    @TempDir Path directory;

    @Test void validatesActualFixedVersionAndTargetArchitectureIndependentlyOfX86Loader() throws Exception {
        for (String architecture : List.of("x64", "arm64", "x86")) {
            WindowsSetupInspector.inspect(write(WindowsSetupFixture.bytes(2532, architecture, "2.5.32")), release(2532, architecture, "2.5.32"));
        }
    }

    @Test void rejectsSpoofedProductIdentityVersionBuildAndArchitecture() throws Exception {
        for (Map<String, String> wrong : List.of(Map.of("ProductName", "Other App"), Map.of("OriginalFileName", "uten_imp.exe"),
                Map.of("FileDescription", "Uten IMP Windows Setup (arm64)"), Map.of("FileVersion", "2.5.32.1"),
                Map.of("ProductVersion", "2.5.31.2532"))) {
            rejects(WindowsSetupFixture.bytes(2532, "x64", "2.5.32", wrong), release(2532, "x64", "2.5.32"));
        }
        rejects(WindowsSetupFixture.bytes(2532, "x64", "2.5.32"), release(2533, "x64", "2.5.32"));
        rejects(WindowsSetupFixture.bytes(2532, "x64", "2.5.32"), release(2532, "x64", "2.5.33"));
    }

    @Test void rejectsCaseAliasedDuplicateVersionKeysWhileAcceptingTheOfficialInnoKeySpelling() throws Exception {
        WindowsSetupInspector.inspect(write(WindowsSetupFixture.bytes(2532, "x64", "2.5.32")), release(2532, "x64", "2.5.32"));
        rejects(WindowsSetupFixture.bytes(2532, "x64", "2.5.32", Map.of("OriginalFilename", "UtenIMPSetup.exe")),
                release(2532, "x64", "2.5.32"));
    }

    @Test void acceptsTrailingAsciiSpaceAndNulPaddingFromInnoReservedVersionTextSlots() throws Exception {
        var padded = Map.of("ProductName", "Uten IMP Windows Setup" + " ".repeat(59),
                "OriginalFileName", "UtenIMPSetup.exe" + " ".repeat(49),
                "FileDescription", "Uten IMP Windows Setup (x64)" + " ".repeat(32),
                "FileVersion", "2.5.32.2532         ", "ProductVersion", "2.5.32.2532         ");
        WindowsSetupInspector.inspect(write(WindowsSetupFixture.bytes(2532, "x64", "2.5.32", padded)), release(2532, "x64", "2.5.32"));
        WindowsSetupInspector.inspect(write(WindowsSetupFixture.bytes(2532, "x64", "2.5.32",
                Map.of("ProductName", "Uten IMP Windows Setup\0 \0 "))), release(2532, "x64", "2.5.32"));
    }

    @Test void paddingNormalizationNeverAcceptsPrefixInternalUnicodeOrNumericTampering() throws Exception {
        for (Map<String, String> wrong : List.of(Map.of("ProductName", " Uten IMP Windows Setup   "),
                Map.of("ProductName", "Uten  IMP Windows Setup   "), Map.of("ProductName", "Uten IMP Windows Setup\u00a0   "),
                Map.of("ProductName", "Uten IMP Windows Setup\u2003   "), Map.of("ProductName", "Uten IMP Windows Setup\t   "),
                Map.of("ProductName", "Uten IMP Windows Setup\0suffix   "), Map.of("FileVersion", "2.5.32.2533         "),
                Map.of("FileVersion", " 2.5.32.2532         "), Map.of("FileVersion", "2.5 .32.2532         "))) {
            rejects(WindowsSetupFixture.bytes(2532, "x64", "2.5.32", wrong), release(2532, "x64", "2.5.32"));
        }
    }

    @Test
    void validatesRealInnoCompilerPaddingFixtureAndStillRejectsTheLocalTestProduct() throws Exception {
        Path productionResourceFixture = compilerFixture("uten.inno.paddingFixture", "normal.versioninfo.hex");
        WindowsSetupInspector.inspect(productionResourceFixture, release(2531, "x64", "2.5.31"));
        Path localProductFixture = compilerFixture("uten.inno.localFixture", "local-test.versioninfo.hex");
        assertThatThrownBy(() -> WindowsSetupInspector.inspect(localProductFixture, release(2531, "x64", "2.5.31")))
                .isInstanceOfSatisfying(ApiException.class, failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
    }

    private Path compilerFixture(String overrideProperty, String resourceName) throws Exception {
        String override = System.getProperty(overrideProperty);
        if (override != null) return Path.of(override);
        String root = "/clientupdates/inno-7.1.0/";
        try (var source = getClass().getResourceAsStream(root + resourceName);
             var manifest = getClass().getResourceAsStream(root + "manifest.json")) {
            assertThat(source).as("committed real Inno VERSIONINFO").isNotNull();
            assertThat(manifest).as("reviewed compiler and resource provenance").isNotNull();
            byte[] versionInfo = java.util.HexFormat.of().parseHex(
                    new String(source.readAllBytes(), java.nio.charset.StandardCharsets.US_ASCII).replaceAll("\\s+", ""));
            var expected = new com.fasterxml.jackson.databind.ObjectMapper().readTree(manifest)
                    .path("fixtures").path(resourceName);
            assertThat(versionInfo.length).isEqualTo(expected.path("resourceBytes").asInt());
            assertThat(java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(versionInfo)))
                    .isEqualTo(expected.path("resourceSha256").asText());
            Path fixture = directory.resolve(resourceName + ".fixture");
            return Files.write(fixture, WindowsSetupFixture.withVersionInfo(versionInfo));
        }
    }

    @Test void rejectsTruncatedOrUnboundedPeResourceAndVersionStructuresWithoutExecutingInput() throws Exception {
        var mutations = List.<Consumer<ByteBuffer>>of(
                data -> data.putShort(0, (short) 0), data -> data.putInt(60, Integer.MAX_VALUE),
                data -> data.putInt(128, 0), data -> data.putShort(132, (short) 0x8664),
                data -> data.putShort(134, (short) 97), data -> data.putShort(150, (short) 0),
                data -> data.putInt(264, Integer.MAX_VALUE), data -> data.putInt(268, Integer.MAX_VALUE),
                data -> data.putShort(526, (short) 5000), data -> data.putInt(532, 24),
                data -> data.putInt(580, 0x80000048), data -> data.putInt(588, Integer.MAX_VALUE),
                data -> data.putShort(608, (short) 65535), data -> data.putInt(648, 0),
                data -> data.putInt(660, 1), data -> data.putInt(668, 1));
        for (var mutate : mutations) {
            byte[] bytes = WindowsSetupFixture.bytes(2532, "x64", "2.5.32");
            mutate.accept(ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN));
            rejects(bytes, release(2532, "x64", "2.5.32"));
        }
        rejects(new byte[] {1, 2, 3}, release(2532, "x64", "2.5.32"));
        rejects(java.util.Arrays.copyOf(WindowsSetupFixture.bytes(2532, "x64", "2.5.32"), 1000), release(2532, "x64", "2.5.32"));
    }
    private void rejects(byte[] bytes, ClientReleaseDto.Release release) throws Exception {
        Path file = write(bytes);
        assertThatThrownBy(() -> WindowsSetupInspector.inspect(file, release)).isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
    }
    private Path write(byte[] bytes) throws Exception { return Files.write(directory.resolve(UUID.randomUUID() + ".exe"), bytes); }
    private static ClientReleaseDto.Release release(long build, String architecture, String version) {
        return new ClientReleaseDto.Release(UUID.randomUUID(), "windows", architecture, version, build, "", false,
                "UtenIMPSetup.exe", null, null, 0, "windows_setup", null, null, "DRAFT", Instant.now(), null, "installer");
    }
}
