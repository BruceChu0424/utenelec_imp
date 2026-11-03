package com.uten.imp.features.clientupdates;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import java.io.IOException;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.LinkedHashMap;
import java.util.Arrays;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class WindowsPublisherSignaturesTest {
    @TempDir Path directory;
    private static final String PIN = "ab".repeat(32);
    private static final String OK = "Timestamp Server Signature verification: ok\nSignature verification: ok\n";

    @Test void missingCompanyIdentityFailsClosedBeforeExecutingUploadedCode() throws Exception {
        var file = Files.write(directory.resolve("setup.exe"), new byte[] {'M', 'Z'});
        var properties = new ClientUpdateProperties();
        properties.setWindowsSignatureRequire(true);
        var verifier = new WindowsPublisherSignatures(properties, (command, timeout) -> { throw new AssertionError("Must not run"); });
        assertThatThrownBy(() -> verifier.inspect(file, release("installer", "flutter")))
                .isInstanceOf(ApiException.class).hasMessageContaining("UTEN_WINDOWS_PUBLISHER_SHA256");
    }

    @Test void defaultPolicyAcceptsStructurallyValidUnsignedInstallerWithoutTrustConfiguration() throws Exception {
        var properties = new ClientUpdateProperties();
        assertThat(properties.isWindowsSignatureRequire()).isFalse();
        var verifier = new WindowsPublisherSignatures(properties, (command, timeout) -> { throw new AssertionError("Must not run"); });
        var file = Files.write(directory.resolve("setup.exe"), WindowsSetupFixture.bytes(2545, "x64", "2.5.45"));
        new ClientPackageInspector(new ObjectMapper(), verifier).inspectForPublication(file, release("installer", "flutter"));
    }

    @Test void defaultUnsignedArchiveStillChecksCompletePayloadAndRejectsReplacement() throws Exception {
        var files = new LinkedHashMap<String, byte[]>();
        files.put("data/app.so", new byte[] {1,2,3});
        files.put("Uten.Legacy.Desktop.exe", withoutCertificate(boundMain(files)));
        var verifier = new WindowsPublisherSignatures(new ClientUpdateProperties(),
                (command, timeout) -> { throw new AssertionError("No trust tool is configured"); });
        verifier.inspect(Files.write(directory.resolve("unsigned.zip"), ClientReleaseFixtures.zip(files)), release("update", "wpf_legacy"));
        files.put("data/app.so", new byte[] {7,8,9});
        var replaced = Files.write(directory.resolve("replaced-unsigned.zip"), ClientReleaseFixtures.zip(files));
        assertThatThrownBy(() -> verifier.inspect(replaced, release("update", "wpf_legacy")))
                .isInstanceOf(ApiException.class).hasMessageContaining("完整运行文件");
    }

    @Test void defaultUnsignedPolicyNeverBypassesReviewedReleaseEngineAdmission() throws Exception {
        var vectors = new ObjectMapper().readTree(Path.of("../contracts/windows-engine-safety/vectors-v1.json").toFile());
        byte[] unknown = Base64.getDecoder().decode(vectors.path("vectors").get(0).path("peBase64").asText());
        var files = new LinkedHashMap<String, byte[]>();
        files.put("flutter_windows.dll", unknown);
        files.put("uten_imp.exe", unknown);
        var archive = Files.write(directory.resolve("unknown-engine.zip"), ClientReleaseFixtures.zip(files));
        var verifier = new WindowsPublisherSignatures(new ClientUpdateProperties(),
                (command, timeout) -> { throw new AssertionError("No trust tool is configured"); });
        assertThatThrownBy(() -> verifier.inspect(archive, release("update", "flutter")))
                .isInstanceOf(ApiException.class).hasMessageContaining("尚未通过");
    }

    @Test void companyVerificationPinsActualFileAndKeepsChainTimestampAndRevocationChecks() throws Exception {
        var file = Files.write(directory.resolve("uploaded.tmp"), new byte[] {'M', 'Z'});
        List<List<String>> calls = new ArrayList<>();
        var verifier = verifier(settings(), (command, timeout) -> {
            calls.add(command);
            assertThat(timeout).isPositive().isLessThanOrEqualTo(Duration.ofSeconds(30));
            return new WindowsPublisherSignatures.Result(0, OK, false);
        });
        verifier.inspect(file, release("installer", "flutter"));
        assertThat(calls).hasSize(1);
        assertThat(calls.getFirst()).containsSequence("verify", "-index", "0")
                .containsSequence("-require-leaf-hash", "sha256:" + PIN)
                .containsSequence("-in", file.toAbsolutePath().toString())
                .contains("-CAfile", "-TSA-CAfile", "-CRLfile", "-TSA-CRLfile", "-ignore-cdp")
                .doesNotContain("-ignore-crl", "-ignore-timestamp", "-time", "-catalog");
    }

    @Test void wrongPublisherTamperingMissingTimestampAndOversizedOutputAreRejected() throws Exception {
        var file = Files.write(directory.resolve("setup.exe"), new byte[] {'M', 'Z'});
        for (var result : List.of(new WindowsPublisherSignatures.Result(1, OK, false),
                new WindowsPublisherSignatures.Result(0, "Signature verification: ok", false),
                new WindowsPublisherSignatures.Result(0, OK + "Timestamp is not available", false),
                new WindowsPublisherSignatures.Result(0, OK, true))) {
            var verifier = verifier(settings(), (command, timeout) -> result);
            assertThatThrownBy(() -> verifier.inspect(file, release("installer", "flutter")))
                    .isInstanceOf(ApiException.class).hasMessageContaining("签名");
        }
    }

    @Test void rotationTriesOnlyConfiguredPinsAndNeverFallsBackToUnpinnedCompanyTrust() throws Exception {
        var properties = settings();
        String rotated = "cd".repeat(32);
        properties.setWindowsPublisherSha256(PIN + "," + rotated);
        List<List<String>> calls = new ArrayList<>();
        var verifier = verifier(properties, (command, timeout) -> {
            calls.add(command);
            return new WindowsPublisherSignatures.Result(command.contains("sha256:" + rotated) ? 0 : 1, OK, false);
        });
        verifier.inspect(Files.write(directory.resolve("setup.exe"), new byte[] {'M','Z'}), release("installer", "flutter"));
        assertThat(calls).hasSize(2);
        assertThat(calls).allSatisfy(command -> assertThat(command).contains("-require-leaf-hash"));
    }

    @Test void everyExecutableIncludesDisguisedPeAndThirdPartyRetainsIndependentTrustedSignature() throws Exception {
        var files = new LinkedHashMap<String, byte[]>(Map.of("third-party.dll", new byte[] {'M','Z',2},
                "data/disguised.dat", new byte[] {'M','Z',3}, "client_updater/client_updater.ps1", new byte[] {'#','x'},
                "plain.txt", new byte[] {1,2,3}));
        files.put("Uten.Legacy.Desktop.exe", boundMain(files));
        Path archive = Files.write(directory.resolve("update.zip"), ClientReleaseFixtures.zip(files));
        List<List<String>> calls = new ArrayList<>();
        var verifier = verifier(settings(), (command, timeout) -> {
            calls.add(command);
            assertThat(Path.of(command.getLast())).isRegularFile();
            return new WindowsPublisherSignatures.Result(0, OK, false);
        });
        verifier.inspect(archive, release("update", "wpf_legacy"));
        assertThat(calls).hasSize(4);
        assertThat(calls.stream().filter(command -> command.contains("-require-leaf-hash"))).hasSize(2);
        try (var paths = Files.list(directory)) {
            assertThat(paths.filter(path -> path.getFileName().toString().startsWith(".windows-signature-")).toList()).isEmpty();
        }
    }

    @Test void signedMainCannotAuthorizeReplacedNonPePayloadEvenWhenZipHashesAreRecomputed() throws Exception {
        var files = new LinkedHashMap<String, byte[]>(Map.of("data/app.so", new byte[] {1,2,3}, "plain.txt", new byte[] {4,5}));
        files.put("Uten.Legacy.Desktop.exe", boundMain(files));
        files.put("data/app.so", new byte[] {7,8,9});
        Path archive = Files.write(directory.resolve("replaced-aot.zip"), ClientReleaseFixtures.zip(files));
        var verifier = verifier(settings(), (command, timeout) -> new WindowsPublisherSignatures.Result(0, OK, false));
        assertThatThrownBy(() -> verifier.inspect(archive, release("update", "wpf_legacy")))
                .isInstanceOf(ApiException.class).hasMessageContaining("完整运行文件");
    }

    @Test void vulnerableOldNativeVerifierIsRejectedBeforeOpeningUploadedBytes() throws Exception {
        var verifier = new WindowsPublisherSignatures(settings(), (command, timeout) -> {
            assertThat(command).containsExactly(Path.of(System.getProperty("java.home"), "bin", System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java").toString(), "--version");
            return new WindowsPublisherSignatures.Result(0, "osslsigncode 2.5, using:\n", false);
        });
        assertThatThrownBy(() -> verifier.inspect(Files.write(directory.resolve("old-tool.exe"), new byte[] {'M','Z'}), release("installer", "flutter")))
                .isInstanceOf(ApiException.class).hasMessageContaining("版本过旧");
    }

    @Test void verifierFailureCleansExtractedBytesAndDoesNotAcceptToolAvailabilityAsTrust() throws Exception {
        Path archive = Files.write(directory.resolve("update.zip"), ClientReleaseFixtures.zip(Map.of("Uten.Legacy.Desktop.exe", new byte[] {'M','Z'})));
        var verifier = verifier(settings(), (command, timeout) -> { throw new IOException("missing tool"); });
        assertThatThrownBy(() -> verifier.inspect(archive, release("update", "wpf_legacy"))).isInstanceOf(ApiException.class).hasMessageContaining("验证器不可用");
        try (var paths = Files.list(directory)) { assertThat(paths.map(path -> path.getFileName().toString()).toList()).containsExactlyInAnyOrder("update.zip", "trust.pem"); }
    }

    @Test void mappedEngineDigestMatchesAllCrossLanguageVectors() throws Exception {
        var document = new ObjectMapper().readTree(Path.of("../contracts/windows-engine-safety/vectors-v1.json").toFile());
        assertThat(document.path("algorithm").asText()).isEqualTo("mapped-pe-image-sha256-v1");
        int count = 0;
        for (var vector : document.path("vectors")) {
            Path file = Files.write(directory.resolve("vector-" + count++ + ".dll"), Base64.getDecoder().decode(vector.path("peBase64").asText()));
            if (vector.path("rejected").asBoolean()) assertThatThrownBy(() -> WindowsEngineSafety.imageSha256(file)).as(vector.path("name").asText()).isInstanceOf(ApiException.class);
            else assertThat(WindowsEngineSafety.imageSha256(file)).as(vector.path("name").asText()).isEqualTo(vector.path("peImageSha256").asText());
        }
        assertThat(count).isGreaterThanOrEqualTo(21);
    }

    @Test void unknownEngineCannotBecomeApprovedBecauseItsSignatureWasAccepted() throws Exception {
        var vectors = new ObjectMapper().readTree(Path.of("../contracts/windows-engine-safety/vectors-v1.json").toFile());
        Path unknown = Files.write(directory.resolve("unknown.dll"), Base64.getDecoder().decode(vectors.path("vectors").get(0).path("peBase64").asText()));
        assertThatThrownBy(() -> WindowsEngineSafety.requireApproved(unknown, "x86"))
                .isInstanceOf(ApiException.class).hasMessageContaining("尚未通过");
    }

    @Test void nativeProcessOutputIsBoundedAndTimeoutIsEnforced() throws Exception {
        var javaExecutable = Path.of(System.getProperty("java.home"), "bin", System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java");
        var base = List.of(javaExecutable.toString(), "-cp", System.getProperty("java.class.path"), VerifierChild.class.getName());
        var flood = new ArrayList<>(base); flood.add("flood");
        var result = WindowsPublisherSignatures.execute(flood, Duration.ofSeconds(10));
        assertThat(result.outputExceeded()).isTrue();
        assertThat(result.output().getBytes(java.nio.charset.StandardCharsets.UTF_8)).hasSizeLessThanOrEqualTo(65536);
        var hang = new ArrayList<>(base); hang.add("hang");
        assertThatThrownBy(() -> WindowsPublisherSignatures.execute(hang, Duration.ofMillis(150))).isInstanceOf(IOException.class).hasMessageContaining("timeout");
    }

    public static class VerifierChild {
        public static void main(String[] args) throws Exception {
            if ("hang".equals(args[0])) Thread.sleep(30000);
            else { System.out.print("x".repeat(131072)); System.out.flush(); }
        }
    }

    private ClientUpdateProperties settings() throws IOException {
        var result = new ClientUpdateProperties(); result.setWindowsPublisherSha256(PIN);
        result.setWindowsSignatureVerifier(Path.of(System.getProperty("java.home"), "bin", System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java").toString());
        Path trust = directory.resolve("trust.pem"); Files.writeString(trust, "public test trust material");
        result.setWindowsSignatureCaFile(trust.toString()); result.setWindowsSignatureTsaCaFile(trust.toString());
        result.setWindowsSignatureCrlFile(trust.toString()); result.setWindowsSignatureTsaCrlFile(trust.toString());
        return result;
    }

    private byte[] withoutCertificate(byte[] signed) {
        var header = ByteBuffer.wrap(signed).order(ByteOrder.LITTLE_ENDIAN);
        int optional = header.getInt(60) + 24;
        int directories = Short.toUnsignedInt(header.getShort(optional)) == 0x10b ? 96 : 112;
        int certificate = header.getInt(optional + directories + 32);
        header.putInt(optional + directories + 32, 0).putInt(optional + directories + 36, 0);
        return Arrays.copyOf(signed, certificate);
    }

    private WindowsPublisherSignatures verifier(ClientUpdateProperties properties, WindowsPublisherSignatures.VerificationProcess process) {
        return new WindowsPublisherSignatures(properties, (command, timeout) -> command.contains("--version")
                ? new WindowsPublisherSignatures.Result(0, "osslsigncode 2.14\n", false) : process.verify(command, timeout));
    }

    private byte[] boundMain(Map<String, byte[]> files) throws Exception {
        var vectors = new ObjectMapper().readTree(Path.of("../contracts/windows-engine-safety/vectors-v1.json").toFile());
        byte[] base = null;
        for (var vector : vectors.path("vectors")) if ("x64-unsigned".equals(vector.path("name").asText()))
            base = Base64.getDecoder().decode(vector.path("peBase64").asText());
        if (base == null) throw new AssertionError("Missing x64 PE vector");
        var records = new ArrayList<Map<String,Object>>();
        files.entrySet().stream().filter(file -> !file.getKey().startsWith("client_updater/")).sorted(Map.Entry.comparingByKey())
                .forEach(file -> records.add(Map.of("path", file.getKey(), "size", file.getValue().length, "sha256", ClientReleaseFixtures.sha(file.getValue()))));
        byte[] json = new ObjectMapper().writeValueAsBytes(Map.of("schemaVersion", 1, "runtimeFamily", "wpf_legacy", "version", "2.5.45",
                "buildNumber", 2545, "architecture", "x64", "executable", "Uten.Legacy.Desktop.exe", "files", records));
        byte[] magic = "UTEN-PAYLOAD-BINDING-V1\0".getBytes(StandardCharsets.US_ASCII);
        int padding = -(base.length + json.length + 4 + magic.length) & 7;
        int certificate = base.length + padding + json.length + 4 + magic.length;
        var header = ByteBuffer.wrap(base).order(ByteOrder.LITTLE_ENDIAN);
        int optional = header.getInt(60) + 24;
        int directories = Short.toUnsignedInt(header.getShort(optional)) == 0x10b ? 96 : 112;
        header.putInt(optional + directories + 32, certificate).putInt(optional + directories + 36, 8);
        var output = new ByteArrayOutputStream();
        output.write(base); output.write(new byte[padding]); output.write(json);
        output.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(json.length).array()); output.write(magic);
        output.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putInt(8).putShort((short)0x200).putShort((short)2).array());
        return output.toByteArray();
    }

    private ClientReleaseDto.Release release(String kind, String runtime) {
        return new ClientReleaseDto.Release(UUID.randomUUID(), "windows", "x64", "2.5.45", 2545, "", false, "file", "a".repeat(64),
                null, 0, "installer".equals(kind) ? "windows_setup" : "windows_archive", null, "", "DRAFT", Instant.now(), null, kind, runtime);
    }
}
