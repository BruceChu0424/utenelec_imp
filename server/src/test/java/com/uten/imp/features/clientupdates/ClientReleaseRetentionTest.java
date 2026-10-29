package com.uten.imp.features.clientupdates;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.assertj.core.api.ThrowableAssert.ThrowingCallable;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.api.io.TempDir;

class ClientReleaseRetentionTest {
    @TempDir Path directory;
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
    private final ClientUpdateProperties properties = new ClientUpdateProperties();
    private final SecurityContextCurrentUser users = mock(SecurityContextCurrentUser.class);
    private FaultingCatalog catalog;
    private ClientReleaseService service;

    @BeforeEach
    void setUp() {
        properties.setDirectory(directory.toString());
        var actor = mock(AuthUser.class);
        when(actor.getPermissions()).thenReturn(Set.of(ClientReleaseService.PUBLISH_PERMISSION));
        when(actor.getEmployeeId()).thenReturn(UUID.randomUUID());
        when(actor.getId()).thenReturn(UUID.randomUUID());
        when(actor.getLoginAccount()).thenReturn("publisher");
        when(users.get()).thenReturn(Optional.of(actor));
        catalog = new FaultingCatalog(properties, mapper);
        service = new ClientReleaseService(catalog, new ClientPackageInspector(mapper), properties, users, mock(AuditService.class));
    }

    @Test
    void completeNewestPairRemovesOldBytesAndKeepsBoundPublicationHistory() throws Exception {
        var old = pair(10, "x64");
        var setup = publish(20, "x64", "installer", "2.5.20");
        assertRetained(old);
        var update = publish(20, "x64", "update", "2.5.20");
        for (var previous : old) {
            assertRetired(previous);
            assertCode(() -> service.download(previous.id()), ErrorCode.NOT_FOUND);
        }
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(setup.id());
        assertThat(service.check("windows", "x64", 1).release().id()).isEqualTo(update.id());
        assertRetained(List.of(setup, update));
    }

    @Test
    void updateCanArriveFirstWithoutRemovingTheCurrentPair() throws Exception {
        var old = pair(10, "x64");
        publish(20, "x64", "update", "2.5.20");
        assertRetained(old);
        publish(20, "x64", "installer", "2.5.20");
        old.forEach(this::assertRetired);
    }

    @Test
    void invalidSecondPackageDoesNotChangeOldReceiptsOrBytes() throws Exception {
        var old = pair(10, "x64");
        publish(20, "x64", "installer", "2.5.20");
        var update = uploaded(20, "x64", "update", "2.5.20");
        corrupt(update);
        assertCode(() -> service.publish(update.id()), ErrorCode.VALIDATION_FAILED);
        assertRetained(old);
        assertThat(receipt(update).state()).isEqualTo("DRAFT");
    }

    @Test
    void pairedRevalidationFailureLeavesOldVersionIntactAndPublishedRetryFinishesCleanup() throws Exception {
        var old = pair(10, "x64");
        var setup = publish(20, "x64", "installer", "2.5.20");
        var original = Files.readAllBytes(binary(setup));
        corrupt(setup);
        var update = uploaded(20, "x64", "update", "2.5.20");
        assertCode(() -> service.publish(update.id()), ErrorCode.VALIDATION_FAILED);
        assertRetained(old);
        assertThat(receipt(update).state()).isEqualTo("PUBLISHED");
        Files.write(binary(setup), original);
        assertThat(service.publish(update.id()).state()).isEqualTo("PUBLISHED");
        old.forEach(this::assertRetired);
    }

    @Test
    void differentVersionsAreNotACompleteGeneration() throws Exception {
        var old = pair(10, "x64");
        publish(20, "x64", "installer", "2.5.20");
        var mismatch = uploaded(20, "x64", "update", "2.5.21");
        assertCode(() -> service.publish(mismatch.id()), ErrorCode.CONFLICT);
        assertThat(service.get(mismatch.id()).state()).isEqualTo("DRAFT");
        assertRetained(old);
    }

    @Test
    void aNewerPartialGenerationDoesNotAllowAnOlderPairToTriggerCleanup() throws Exception {
        var old = pair(10, "x64");
        var setup = publish(20, "x64", "installer", "2.5.20");
        publish(21, "x64", "installer", "2.5.21");
        publish(20, "x64", "update", "2.5.20");
        service.publish(setup.id());
        assertRetained(old);
        publish(21, "x64", "update", "2.5.21");
        old.forEach(this::assertRetired);
        assertRetired(setup);
    }

    @Test
    void otherArchitecturesPlatformsAndUnpublishedDraftsKeepTheirFiles() throws Exception {
        var old = pair(10, "x64");
        var arm = pair(10, "arm64");
        var draft = uploaded(15, "x64", "update", "2.5.15");
        var apk = AndroidPackageFixture.apk(10, "2.5.10", "arm64", null);
        var android = service.create(new ClientReleaseDto.Create(UUID.randomUUID(), "android", "arm64", "2.5.10", 10,
                "", false, "uten.apk", sha(apk), null, "update"));
        service.upload(android.id(), new ByteArrayInputStream(apk), apk.length);
        android = service.publish(android.id());
        pair(20, "x64");
        old.forEach(this::assertRetired);
        assertRetained(arm);
        assertRetained(List.of(android));
        assertThat(receipt(draft).state()).isEqualTo("DRAFT");
        assertThat(binary(draft)).isRegularFile();
    }

    @Test
    void historicalFullZipInstallerIsRemovedOnlyByANewCompleteSetupGeneration() throws Exception {
        var bytes = windows(5, "x64", "installer");
        var legacy = ClientReleaseFixtures.legacyDraft(properties, mapper, new ClientReleaseDto.Create(UUID.randomUUID(), "windows", "x64", "2.5.5", 5,
                "", false, "uten-full.zip", sha(bytes), null, "installer"), "windows_bundle");
        service.upload(legacy.id(), new ByteArrayInputStream(bytes), bytes.length);
        legacy = service.publish(legacy.id());
        publish(10, "x64", "update", "2.5.10");
        assertRetained(List.of(legacy));
        publish(10, "x64", "installer", "2.5.10");
        assertRetired(legacy);
    }

    @Test
    void metadataCommitFailureIsReportedAndIdempotentPublishRemovesTheLeftoverBinary() throws Exception {
        var old = pair(10, "x64");
        publish(20, "x64", "installer", "2.5.20");
        var update = uploaded(20, "x64", "update", "2.5.20");
        catalog.failAfterRetiring = old.getFirst().id();
        assertCode(() -> service.publish(update.id()), ErrorCode.PRIMARY_UNAVAILABLE);
        // Metadata PUBLISHED is not a receipt for a successful retention operation.
        assertThat(service.get(update.id()).state()).isEqualTo("PUBLISHED");
        assertThat(binary(old.getFirst())).isRegularFile();
        assertThat(receipt(old.getFirst()).state()).isEqualTo("WITHDRAWN");
        assertThat(receipt(old.getFirst()).sha256()).isNull();
        assertThat(binary(old.getFirst())).isRegularFile();
        service.publish(update.id());
        old.forEach(this::assertRetired);
        service.publish(update.id());
        old.forEach(this::assertRetired);
    }

    @Test
    @EnabledOnOs(OS.WINDOWS)
    void deletionDeniedByAnOpenFileIsReportedAndTheSamePublishedIdRetriesAfterItCloses() throws Exception {
        var old = pair(10, "x64");
        publish(20, "x64", "installer", "2.5.20");
        var update = uploaded(20, "x64", "update", "2.5.20");
        try (var ignored = WindowsPackageHold.open(directory, binary(old.getFirst()))) {
            assertCode(() -> service.publish(update.id()), ErrorCode.PRIMARY_UNAVAILABLE);
            assertThat(receipt(old.getFirst()).state()).isEqualTo("WITHDRAWN");
            assertThat(receipt(old.getFirst()).sha256()).isNull();
            assertThat(binary(old.getFirst())).isRegularFile();
        }
        assertThat(service.publish(update.id()).state()).isEqualTo("PUBLISHED");
        old.forEach(this::assertRetired);
    }

    @Test
    void anOldReceiptWithAnIncorrectIdCannotOverwriteOrDeleteTheRetainedPackage() throws Exception {
        var old = pair(10, "x64");
        var setup = publish(20, "x64", "installer", "2.5.20");
        var update = uploaded(20, "x64", "update", "2.5.20");
        var oldMetadata = directory.resolve(old.getFirst().id().toString()).resolve("release.json");
        var damaged = mapper.valueToTree(old.getFirst());
        ((com.fasterxml.jackson.databind.node.ObjectNode) damaged).put("id", setup.id().toString());
        var bytes = mapper.writeValueAsBytes(damaged);
        Files.write(oldMetadata, bytes);
        assertCode(() -> service.publish(update.id()), ErrorCode.PRIMARY_UNAVAILABLE);
        assertThat(Files.readAllBytes(oldMetadata)).isEqualTo(bytes);
        assertThat(binary(old.getFirst())).isRegularFile();
        assertThat(binary(setup)).isRegularFile();
        assertThat(receipt(setup)).isEqualTo(setup);
    }

    @Test
    void retiredRecordsStillPreventBuildReuseAndKeepRequestIdempotency() throws Exception {
        var old = pair(10, "x64");
        pair(20, "x64");
        var retired = receipt(old.getFirst());
        var same = new ClientReleaseDto.Create(retired.id(), retired.platform(), retired.architecture(), retired.version(),
                retired.buildNumber(), retired.releaseNotes(), retired.mandatory(), retired.fileName(), retired.expectedSha256(),
                retired.storeUrl(), retired.packageKind());
        assertThat(service.create(same)).isEqualTo(retired);
        var downgrade = uploaded(19, "x64", "installer", "2.5.19");
        assertCode(() -> service.publish(downgrade.id()), ErrorCode.CONFLICT);
        assertCode(() -> service.publish(retired.id()), ErrorCode.CONFLICT);
    }

    @Test
    void withdrawnCounterpartIsNotACompleteGeneration() throws Exception {
        var old = pair(10, "x64");
        var setup = publish(20, "x64", "installer", "2.5.20");
        service.withdraw(setup.id());
        publish(20, "x64", "update", "2.5.20");
        assertRetained(old);
    }

    @Test
    void anAlreadyOpenedDownloadCanFinishDuringRetirement() throws Exception {
        var old = pair(10, "x64");
        var expected = Files.readAllBytes(binary(old.getFirst()));
        publish(20, "x64", "installer", "2.5.20");
        var update = uploaded(20, "x64", "update", "2.5.20");
        try (var stream = service.download(old.getFirst().id()).stream()) {
            try {
                service.publish(update.id());
            } catch (ApiException failure) {
                // A host that disallows deleting an open file reports failure and retries after the stream closes.
                assertThat(failure.getCode()).isEqualTo(ErrorCode.PRIMARY_UNAVAILABLE);
            }
            assertThat(stream.readAllBytes()).isEqualTo(expected);
        }
        service.publish(update.id());
        old.forEach(this::assertRetired);
    }

    private List<ClientReleaseDto.Release> pair(long build, String architecture) throws Exception {
        return List.of(publish(build, architecture, "installer", "2.5." + build),
                publish(build, architecture, "update", "2.5." + build));
    }

    private ClientReleaseDto.Release publish(long build, String architecture, String kind, String version) throws Exception {
        return service.publish(uploaded(build, architecture, kind, version).id());
    }

    private ClientReleaseDto.Release uploaded(long build, String architecture, String kind, String version) throws Exception {
        var bytes = "installer".equals(kind) ? WindowsSetupFixture.bytes(build, architecture, version)
                : ClientReleaseFixtures.windows(mapper, build, architecture, version);
        var release = service.create(new ClientReleaseDto.Create(UUID.randomUUID(), "windows", architecture, version, build,
                "Windows release", false, "installer".equals(kind) ? "UTEN-Setup.exe" : "UTEN-update.zip", sha(bytes), null, kind));
        return service.upload(release.id(), new ByteArrayInputStream(bytes), bytes.length);
    }

    private void assertRetained(List<ClientReleaseDto.Release> releases) throws IOException {
        for (var release : releases) {
            assertThat(receipt(release)).isEqualTo(release);
            assertThat(binary(release)).isRegularFile();
        }
    }

    private void assertRetired(ClientReleaseDto.Release release) {
        var retired = receipt(release);
        assertThat(retired.state()).isEqualTo("WITHDRAWN");
        assertThat(retired.sha256()).isNull();
        assertThat(retired.sizeBytes()).isZero();
        assertThat(retired.expectedSha256()).isEqualTo(release.expectedSha256());
        assertThat(retired.publishedAt()).isEqualTo(release.publishedAt());
        assertThat(binary(release)).doesNotExist();
    }

    private ClientReleaseDto.Release receipt(ClientReleaseDto.Release release) {
        return catalog.locked(root -> catalog.require(root, release.id()));
    }

    private Path binary(ClientReleaseDto.Release release) { return directory.resolve(release.id().toString()).resolve("package.bin"); }
    private void corrupt(ClientReleaseDto.Release release) throws IOException {
        var bytes = Files.readAllBytes(binary(release));
        bytes[bytes.length / 2] ^= 1;
        Files.write(binary(release), bytes);
    }

    private byte[] windows(long build, String architecture, String kind) throws Exception {
        if ("update".equals(kind)) return ClientReleaseFixtures.windows(mapper, build, architecture, "2.5." + build);
        Map<String, byte[]> files = new LinkedHashMap<>();
        for (String name : List.of("uten_imp.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin"))
            files.put(name, name.getBytes(StandardCharsets.UTF_8));
        if ("installer".equals(kind)) files.put("client_updater/client_updater.ps1", "fixed updater".getBytes(StandardCharsets.UTF_8));
        List<Map<String, Object>> entries = new ArrayList<>();
        files.forEach((name, bytes) -> entries.add(Map.of("path", name, "size", bytes.length, "sha256", sha(bytes))));
        files.put("uten-client-manifest.json", mapper.writeValueAsBytes(Map.of("schemaVersion", 1, "platform", "windows",
                "architecture", architecture, "buildNumber", build, "executable", "uten_imp.exe", "files", entries, "packageKind", kind)));
        return zip(files);
    }

    private static byte[] zip(Map<String, byte[]> files) throws IOException {
        var output = new ByteArrayOutputStream();
        try (var zip = new ZipOutputStream(output)) {
            for (var entry : files.entrySet()) {
                zip.putNextEntry(new ZipEntry(entry.getKey()));
                zip.write(entry.getValue());
                zip.closeEntry();
            }
        }
        return output.toByteArray();
    }

    private static String sha(byte[] bytes) { return HexFormat.of().formatHex(ClientPackageInspector.digest().digest(bytes)); }
    private static void assertCode(ThrowingCallable operation, ErrorCode code) {
        assertThatThrownBy(operation).isInstanceOfSatisfying(ApiException.class, failure -> assertThat(failure.getCode()).isEqualTo(code));
    }

    /** Public Windows file sharing semantics, independent of JDK-internal open options. */
    private static final class WindowsPackageHold implements AutoCloseable {
        private static final String SCRIPT = """
                $ErrorActionPreference = 'Stop'
                $packageHold = $null
                try {
                    $packageHold = [System.IO.File]::Open(
                        $env:UTEN_TEST_PACKAGE_HOLD_TARGET,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::ReadWrite)
                    [System.IO.File]::WriteAllText($env:UTEN_TEST_PACKAGE_HOLD_READY, 'ready')
                    $packageHoldDeadline = [DateTime]::UtcNow.AddSeconds(30)
                    while (-not [System.IO.File]::Exists($env:UTEN_TEST_PACKAGE_HOLD_RELEASE)) {
                        if ([DateTime]::UtcNow -ge $packageHoldDeadline) {
                            throw 'Timed out waiting for the test to release its package handle'
                        }
                        Start-Sleep -Milliseconds 25
                    }
                } finally {
                    if ($null -ne $packageHold) { $packageHold.Dispose() }
                }
                """;
        private final Process process;
        private final Path release;
        private final Path log;

        private WindowsPackageHold(Process process, Path release, Path log) {
            this.process = process;
            this.release = release;
            this.log = log;
        }

        static WindowsPackageHold open(Path testDirectory, Path binary) throws IOException, InterruptedException {
            Path root = testDirectory.toAbsolutePath().normalize();
            Path target = binary.toAbsolutePath().normalize();
            if (!target.startsWith(root) || !Files.isRegularFile(target))
                throw new IOException("Package hold must target this test's existing temporary package");
            Path signals = Files.createTempDirectory(root, "package-hold-");
            Path ready = signals.resolve("ready");
            Path release = signals.resolve("release");
            Path log = signals.resolve("process.log");
            Path powershell = Path.of(System.getenv().getOrDefault("SystemRoot", "C:\\Windows"),
                    "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            var builder = new ProcessBuilder(powershell.toString(), "-NoLogo", "-NoProfile", "-NonInteractive",
                    "-WindowStyle", "Hidden", "-Command", SCRIPT)
                    .redirectErrorStream(true).redirectOutput(log.toFile());
            builder.environment().put("UTEN_TEST_PACKAGE_HOLD_TARGET", target.toString());
            builder.environment().put("UTEN_TEST_PACKAGE_HOLD_READY", ready.toString());
            builder.environment().put("UTEN_TEST_PACKAGE_HOLD_RELEASE", release.toString());
            var hold = new WindowsPackageHold(builder.start(), release, log);
            try {
                hold.process.getOutputStream().close();
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
                while (!Files.isRegularFile(ready)) {
                    if (!hold.process.isAlive() || System.nanoTime() >= deadline)
                        throw new IOException("Windows package hold did not become ready: " + Files.readString(log));
                    Thread.sleep(25);
                }
                return hold;
            } catch (IOException | InterruptedException | RuntimeException | Error failure) {
                try { hold.close(); } catch (Exception cleanup) { failure.addSuppressed(cleanup); }
                throw failure;
            }
        }

        @Override
        public void close() throws IOException, InterruptedException {
            try {
                Files.writeString(release, "release");
                if (!process.waitFor(10, TimeUnit.SECONDS))
                    throw new IOException("Windows package hold did not release in time");
                if (process.exitValue() != 0)
                    throw new IOException("Windows package hold failed: " + Files.readString(log));
            } finally {
                if (process.isAlive()) {
                    process.destroy();
                    if (!process.waitFor(2, TimeUnit.SECONDS)) {
                        process.destroyForcibly();
                        process.waitFor(2, TimeUnit.SECONDS);
                    }
                }
            }
        }
    }

    private static final class FaultingCatalog extends ClientReleaseCatalog {
        private UUID failAfterRetiring;
        private FaultingCatalog(ClientUpdateProperties properties, ObjectMapper mapper) { super(properties, new StorageProperties(), mapper); }
        @Override
        void write(Path root, ClientReleaseDto.Release release) throws IOException {
            super.write(root, release);
            if (release.id().equals(failAfterRetiring) && "WITHDRAWN".equals(release.state()) && release.sha256() == null) {
                failAfterRetiring = null;
                throw new IOException("Simulated uncertain metadata commit before obsolete package removal");
            }
        }
    }
}
