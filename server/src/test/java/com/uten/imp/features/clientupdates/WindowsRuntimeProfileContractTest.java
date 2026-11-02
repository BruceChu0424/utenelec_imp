package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class WindowsRuntimeProfileContractTest {
    @TempDir Path directory;
    private final ObjectMapper mapper = new ObjectMapper();
    private final ClientPackageInspector inspector = new ClientPackageInspector(mapper);
    private static final String HASH = "a".repeat(64);

    @Test void newFormalPayloadNeedsMatchingActualPeMetadataAndInstallerBinding() throws Exception {
        byte[] bytes = archive("2.5.44", 2544, Map.of("UtenBuildProfile", "formal"), profile(), HASH);
        Path zip = write(bytes);
        inspector.inspect(zip, release("2.5.44", 2544));
        assertThat(inspector.installerBinding(zip, release("2.5.44", 2544))).isEqualTo(HASH);
    }

    @Test void olderFormalPackagesRetainTheirEstablishedContractWithoutNewMetadata() throws Exception {
        Path zip = write(archive("2.5.43", 2543, Map.of(), null, null));
        inspector.inspect(zip, release("2.5.43", 2543));
        assertThat(inspector.installerBinding(zip, release("2.5.43", 2543))).isNull();
    }

    @Test void newMetadataCannotBeRemovedOrUsedToCoverAnUnprofiledProgram() throws Exception {
        rejects(archive("2.5.44", 2544, Map.of("UtenBuildProfile", "formal"), null, HASH), "2.5.44", 2544);
        rejects(archive("2.5.44", 2544, Map.of(), profile(), HASH), "2.5.44", 2544);
        rejects(archive("2.5.44", 2544, Map.of("UtenBuildProfile", "formal"), profile(), null), "2.5.44", 2544);
        rejects(archive("2.5.43", 2543, Map.of("UtenBuildProfile", "formal"), null, null), "2.5.43", 2543);
    }

    @Test void actualLocalTestPeIsRejectedDespiteFormalNameUrlsAndLegacyVersionClaim() throws Exception {
        for (String version : List.of("2.5.43", "2.5.44")) {
            long build = version.endsWith("43") ? 2543 : 2544;
            rejects(archive(version, build, Map.of("UtenBuildProfile", "local_test"), profile(), HASH), version, build);
            rejects(archive(version, build, Map.of("ProductName", "UTEN Local Test"), profile(), HASH), version, build);
        }
        rejects(archive("2.5.43", 2543, Map.of("UtenBuildProfile", "local_test"), null, null), "2.5.43", 2543);
    }

    @Test void everyRuntimeIdentityFieldIsAuthoritativeAndDuplicateJsonIsRejected() throws Exception {
        for (var change : List.<Map.Entry<String, Object>>of(Map.entry("buildProfile", "local_test"),
                Map.entry("applicationId", "com.uten.uten_imp.local_test"), Map.entry("nativeProductName", "UTEN Local Test"),
                Map.entry("displayName", "UTEN 本地测试"), Map.entry("networkScope", "loopback-only"),
                Map.entry("selfUpdatesAllowed", false), Map.entry("selfUpdatesAllowed", "true"),
                Map.entry("runtimeFamily", "wpf_legacy"), Map.entry("schemaVersion", "1"), Map.entry("unknown", "formal"))) {
            var values = new HashMap<>(WindowsRuntimeProfileFixture.formal());
            values.put(change.getKey(), change.getValue());
            rejects(archive("2.5.44", 2544, Map.of("UtenBuildProfile", "formal"), mapper.writeValueAsBytes(values), HASH), "2.5.44", 2544);
        }
        String duplicate = new String(profile(), StandardCharsets.UTF_8).replace("\"buildProfile\":\"formal\"",
                "\"buildProfile\":\"formal\",\"buildProfile\":\"local_test\"");
        rejects(archive("2.5.44", 2544, Map.of("UtenBuildProfile", "formal"), duplicate.getBytes(StandardCharsets.UTF_8), HASH), "2.5.44", 2544);
    }

    @Test void actualDartGeneratedNativeHeaderAndMetadataCarryTheSameIdentity() throws Exception {
        for (String name : List.of("formal", "local_test")) {
            var values = WindowsRuntimeProfileFixture.generated(name);
            try (var input = getClass().getResourceAsStream("/clientupdates/runtime-profile-v1/" + name + ".g.h")) {
                assertThat(input).isNotNull();
                String header = new String(input.readAllBytes(), StandardCharsets.UTF_8);
                assertThat(header).contains("#define UTEN_BUILD_PROFILE " + mapper.writeValueAsString(values.get("buildProfile")),
                        "#define UTEN_NATIVE_PRODUCT_NAME " + mapper.writeValueAsString(values.get("nativeProductName")),
                        "#define UTEN_APPLICATION_ID " + mapper.writeValueAsString(values.get("applicationId")),
                        "#define UTEN_DISPLAY_NAME " + mapper.writeValueAsString(values.get("displayName")));
            }
        }
        rejects(archive("2.5.44", 2544, Map.of("UtenBuildProfile", "formal"),
                mapper.writeValueAsBytes(WindowsRuntimeProfileFixture.generated("local_test")), HASH), "2.5.44", 2544);
    }

    private byte[] profile() throws Exception { return mapper.writeValueAsBytes(WindowsRuntimeProfileFixture.formal()); }
    private byte[] archive(String version, long build, Map<String, String> pe, byte[] profile, String hash) throws Exception {
        return WindowsRuntimeProfileFixture.archive(mapper, version, build, pe, profile, hash);
    }
    private Path write(byte[] bytes) throws Exception { return Files.write(directory.resolve(UUID.randomUUID() + ".zip"), bytes); }
    private void rejects(byte[] bytes, String version, long build) throws Exception {
        Path zip = write(bytes);
        assertThatThrownBy(() -> inspector.inspect(zip, release(version, build))).isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
    }
    private static ClientReleaseDto.Release release(String version, long build) {
        return new ClientReleaseDto.Release(UUID.randomUUID(), "windows", "x64", version, build, "", false,
                "renamed-formal.zip", null, null, 0, "windows_archive", null, null, "DRAFT", Instant.now(), null,
                "update", "flutter", ClientDeliveryContract.PAIRED_WINDOWS);
    }
}
