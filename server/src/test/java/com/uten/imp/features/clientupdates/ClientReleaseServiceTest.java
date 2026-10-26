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
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.assertj.core.api.ThrowableAssert.ThrowingCallable;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ClientReleaseServiceTest {
    @TempDir Path directory;
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
    private final ClientUpdateProperties properties = new ClientUpdateProperties();
    private final SecurityContextCurrentUser users = mock(SecurityContextCurrentUser.class);
    private final AuthUser publisher = mock(AuthUser.class);
    private ClientReleaseService service;

    @BeforeEach
    void setUp() {
        properties.setDirectory(directory.toString());
        when(publisher.getPermissions()).thenReturn(Set.of(ClientReleaseService.PUBLISH_PERMISSION));
        when(publisher.getEmployeeId()).thenReturn(UUID.randomUUID());
        when(publisher.getId()).thenReturn(UUID.randomUUID());
        when(publisher.getLoginAccount()).thenReturn("publisher");
        when(users.get()).thenReturn(Optional.of(publisher));
        service = newService();
    }

    @Test
    void binaryIsInvisibleUntilPublishedAndSurvivesServiceRestart() throws Exception {
        byte[] zip = windows(28, "x64", null);
        var release = draft(28, zip);
        assertThat(service.check("windows", "x64", 27).updateAvailable()).isFalse();
        service.upload(release.id(), new ByteArrayInputStream(zip), zip.length);
        assertCode(() -> service.download(release.id()), ErrorCode.NOT_FOUND);
        var published = service.publish(release.id());
        service = newService();
        var check = service.check("windows", "x64", 27);
        assertThat(check.updateAvailable()).isTrue();
        assertThat(check.release().id()).isEqualTo(published.id());
        assertThat(check.release().sha256()).isEqualTo(sha(zip));
        assertThat(service.check("windows", "arm64", 27).updateAvailable()).isFalse();
        assertThat(service.check("windows", "x64", 28).release()).isNull();
        try (var input = service.download(release.id()).stream()) { assertThat(input.readAllBytes()).isEqualTo(zip); }
        assertCode(() -> service.upload(release.id(), new ByteArrayInputStream(zip), zip.length), ErrorCode.CONFLICT);
    }

    @Test
    void withdrawalFallsBackToPublishedVersionAndCannotRepublishOlderBuild() {
        var previous = publishStore("android", "universal", 27);
        var latest = publishStore("android", "arm64", 28);
        assertThat(service.check("android", "arm64", 26).release().id()).isEqualTo(latest.id());
        service.withdraw(latest.id());
        assertThat(service.check("android", "arm64", 26).release().id()).isEqualTo(previous.id());
        assertThat(service.check("android", "arm64", 28).updateAvailable()).isFalse();
        var old = service.create(storeRequest("android", "arm64", 28));
        assertCode(() -> service.publish(old.id()), ErrorCode.CONFLICT);
        assertCode(() -> service.download(latest.id()), ErrorCode.NOT_FOUND);
    }

    @Test
    void universalFallbackAndExactArchitectureCanAdvanceIndependently() {
        publishStore("android", "universal", 40);
        var arm = publishStore("android", "arm64", 41);
        var x64 = publishStore("android", "x64", 41);
        assertThat(service.check("android", "arm64", 40).release().id()).isEqualTo(arm.id());
        assertThat(service.check("android", "x64", 40).release().id()).isEqualTo(x64.id());
        assertThat(service.check("android", "armeabi-v7a", 39).release().buildNumber()).isEqualTo(40);
    }

    @Test
    void withdrawnDraftDoesNotConsumeUnpublishedBuildNumber() {
        var unpublished = service.create(storeRequest("ios", "universal", 99));
        service.withdraw(unpublished.id());
        assertThat(publishStore("ios", "universal", 1).state()).isEqualTo("PUBLISHED");
    }

    @Test
    void uploadRejectsChecksumLengthAndStreamingLimitAndLeavesNoTemporaryFile() throws Exception {
        byte[] zip = windows(28, "x64", null);
        var release = draft(28, zip);
        assertCode(() -> service.upload(release.id(), new ByteArrayInputStream(new byte[] {1, 2}), 2), ErrorCode.VALIDATION_FAILED);
        assertCode(() -> service.upload(release.id(), new ByteArrayInputStream(zip), zip.length + 1), ErrorCode.VALIDATION_FAILED);
        properties.setMaxPackageBytes(zip.length - 1);
        assertCode(() -> service.upload(release.id(), new ByteArrayInputStream(zip), zip.length), ErrorCode.PAYLOAD_TOO_LARGE);
        assertCode(() -> service.upload(release.id(), new ByteArrayInputStream(zip), -1), ErrorCode.PAYLOAD_TOO_LARGE);
        try (var files = Files.list(directory.resolve(release.id().toString()))) {
            assertThat(files.map(path -> path.getFileName().toString()).toList()).containsExactly("release.json");
        }
    }

    @Test
    void diskReserveRejectsUploadBeforeConsumingTheRequestOrLeavingTemporaryBytes() throws Exception {
        byte[] zip = windows(28, "x64", null);
        var release = draft(28, zip);
        properties.setMinFreeBytes(Long.MAX_VALUE);
        ByteArrayInputStream input = new ByteArrayInputStream(zip);
        assertCode(() -> service.upload(release.id(), input, zip.length), ErrorCode.PRIMARY_UNAVAILABLE);
        assertThat(input.available()).isEqualTo(zip.length);
        assertThat(Files.exists(directory.resolve(release.id().toString()).resolve("package.bin"))).isFalse();
    }

    @Test
    void slowUploadDoesNotBlockClientChecksAndWithdrawalWinsBeforeTheUploadCanCommit() throws Exception {
        byte[] zip = windows(28, "x64", null);
        var release = draft(28, zip);
        CountDownLatch reading = new CountDownLatch(1);
        CountDownLatch proceed = new CountDownLatch(1);
        ByteArrayInputStream input = new ByteArrayInputStream(zip) {
            @Override public synchronized int read(byte[] bytes, int offset, int length) {
                reading.countDown();
                try {
                    if (!proceed.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Test upload was not released");
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException(interrupted);
                }
                return super.read(bytes, offset, length);
            }
        };
        try (var executor = Executors.newFixedThreadPool(2)) {
            Future<ErrorCode> upload = executor.submit(() -> {
                try { service.upload(release.id(), input, zip.length); return null; }
                catch (ApiException failure) { return failure.getCode(); }
            });
            try {
                assertThat(reading.await(5, TimeUnit.SECONDS)).isTrue();
                var check = executor.submit(() -> service.check("windows", "x64", 27));
                assertThat(check.get(1, TimeUnit.SECONDS).updateAvailable()).isFalse();
                service.withdraw(release.id());
            } finally { proceed.countDown(); }
            assertThat(upload.get(5, TimeUnit.SECONDS)).isEqualTo(ErrorCode.CONFLICT);
        }
        assertThat(Files.exists(directory.resolve(release.id().toString()).resolve("package.bin"))).isFalse();
    }

    @Test
    void publishingRequiresDedicatedPermissionEvenForSuperAdminWithoutMethodSecurityProxy() {
        var release = service.create(storeRequest("ios", "universal", 1));
        for (Set<String> permissions : List.of(Set.<String>of(), Set.of("authorization:manage"), Set.of("server:update"))) {
            when(publisher.getPermissions()).thenReturn(permissions);
            assertPublisherForbidden(release.id());
        }
        when(publisher.isSuperAdmin()).thenReturn(true);
        assertPublisherForbidden(release.id());
        when(publisher.getPermissions()).thenReturn(Set.of(ClientReleaseService.PUBLISH_PERMISSION));
        assertThat(service.publish(release.id()).state()).isEqualTo("PUBLISHED");
    }

    @Test
    void visitorPasswordChangeAndImpersonationCannotPublishEvenWithDedicatedPermission() {
        var release = service.create(storeRequest("ios", "universal", 1));
        when(publisher.isVisitor()).thenReturn(true);
        assertPublisherForbidden(release.id());
        when(publisher.isVisitor()).thenReturn(false);
        when(publisher.isMustChangePassword()).thenReturn(true);
        assertPublisherForbidden(release.id());
        when(publisher.isMustChangePassword()).thenReturn(false);
        when(publisher.getImpersonatedBy()).thenReturn(UUID.randomUUID());
        assertPublisherForbidden(release.id());
        when(users.get()).thenReturn(Optional.empty());
        assertCode(() -> service.check("windows", "x64", 1), ErrorCode.UNAUTHORIZED);
    }

    private void assertPublisherForbidden(UUID id) {
        assertCode(service::list, ErrorCode.FORBIDDEN);
        assertCode(() -> service.create(storeRequest("ios", "universal", 2)), ErrorCode.FORBIDDEN);
        assertCode(() -> service.upload(id, new ByteArrayInputStream(new byte[] {1}), 1), ErrorCode.FORBIDDEN);
        assertCode(() -> service.publish(id), ErrorCode.FORBIDDEN);
        assertCode(() -> service.withdraw(id), ErrorCode.FORBIDDEN);
    }

    @Test
    void ordinaryAuthenticatedUserCanCheckAndDownloadWithoutPublishingPermission() throws Exception {
        byte[] zip = windows(28, "x64", null);
        var release = draft(28, zip);
        service.upload(release.id(), new ByteArrayInputStream(zip), zip.length);
        service.publish(release.id());
        when(publisher.isSuperAdmin()).thenReturn(false);
        when(publisher.getPermissions()).thenReturn(Set.of());
        assertThat(service.check("windows", "x64", 27).updateAvailable()).isTrue();
        try (var stream = service.download(release.id()).stream()) { assertThat(stream.readAllBytes()).isEqualTo(zip); }
        assertCode(() -> service.withdraw(release.id()), ErrorCode.FORBIDDEN);
    }

    @Test
    void storeUrlIsRestrictedToOfficialHttpsPlatformStore() {
        var apple = publishStore("macos", "universal", 1);
        assertThat(apple.installMode()).isEqualTo("store");
        assertThat(apple.downloadUrl()).isNull();
        for (String url : List.of("http://apps.apple.com/us/app/id123", "https://apps.apple.com.evil.test/id123",
                "https://evil.test/", "https://apps.apple.com@evil.test/id1", "https://apps.apple.com:444/id1")) {
            var request = new ClientReleaseDto.Create(UUID.randomUUID(), "ios", "universal", "2.5.28", 2, "", false, null, null, url);
            assertCode(() -> service.create(request), ErrorCode.VALIDATION_FAILED);
        }
        assertCode(() -> service.create(storeRequest("linux", "x64", 1)), ErrorCode.VALIDATION_FAILED);
    }

    @Test
    void idempotencyKeyCannotBeReusedForDifferentMetadata() {
        var request = storeRequest("ios", "universal", 1);
        var first = service.create(request);
        assertThat(service.create(request)).isEqualTo(first);
        var changed = new ClientReleaseDto.Create(request.requestId(), "ios", "universal", "2.5.29", 2, "", false, null, null, request.storeUrl());
        assertCode(() -> service.create(changed), ErrorCode.CONFLICT);
    }

    @Test
    void publishRechecksOnDiskBytesBeforeMakingVersionVisible() throws Exception {
        byte[] zip = windows(28, "x64", null);
        var release = draft(28, zip);
        service.upload(release.id(), new ByteArrayInputStream(zip), zip.length);
        zip[zip.length - 1] ^= 1;
        Files.write(directory.resolve(release.id().toString()).resolve("package.bin"), zip);
        assertCode(() -> service.publish(release.id()), ErrorCode.VALIDATION_FAILED);
        assertThat(service.check("windows", "x64", 27).updateAvailable()).isFalse();
    }

    @Test
    void windowsManifestRejectsWrongBuildWrongDigestAndUnsafeOrConflictingPaths() throws Exception {
        byte[] wrongBuild = windows(27, "x64", null);
        var buildDraft = draft(28, wrongBuild);
        assertCode(() -> service.upload(buildDraft.id(), new ByteArrayInputStream(wrongBuild), wrongBuild.length), ErrorCode.VALIDATION_FAILED);
        for (String fault : List.of("hash", "../escape", "UTEN_IMP.exe", "data", "CON.txt", "client_updater/replace.ps1")) {
            byte[] zip = windows(28, "x64", fault);
            var release = draft(28, zip);
            assertCode(() -> service.upload(release.id(), new ByteArrayInputStream(zip), zip.length), ErrorCode.VALIDATION_FAILED);
        }
    }

    @Test
    void concurrentPublishCannotExposeTwoReleasesWithSameBuild() throws Exception {
        var first = service.create(storeRequest("ios", "universal", 1));
        var second = service.create(storeRequest("ios", "universal", 1));
        try (var executor = Executors.newFixedThreadPool(2)) {
            List<Future<Boolean>> tasks = new ArrayList<>();
            for (var release : List.of(first, second)) tasks.add(executor.submit(() -> {
                try { service.publish(release.id()); return true; }
                catch (ApiException failure) { assertThat(failure.getCode()).isEqualTo(ErrorCode.CONFLICT); return false; }
            }));
            int successes = 0;
            for (Future<Boolean> task : tasks) if (task.get()) successes++;
            assertThat(successes).isEqualTo(1);
        }
    }

    @Test
    void setupsHaveIndependentBuildSequenceAndOnlyLatestAvailableSetupPerArchitectureIsListed() throws Exception {
        byte[] updateZip = windows(28, "x64", null);
        var update = draft(28, updateZip);
        service.upload(update.id(), new ByteArrayInputStream(updateZip), updateZip.length);
        service.publish(update.id());
        var first = publishInstaller(28, "x64");
        var latest = publishInstaller(29, "x64");
        var arm = publishInstaller(10, "arm64");
        publishStore("android", "arm64", 99);
        publishStore("macos", "universal", 99);
        publishStore("ios", "universal", 99);
        assertThat(service.check("windows", "x64", 27).release().id()).isEqualTo(update.id());
        assertThat(service.check("windows", "x64", 28).updateAvailable()).isFalse();
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(arm.id(), latest.id());
        assertThat(latest.installMode()).isEqualTo("windows_setup");
        Path latestBinary = directory.resolve(latest.id().toString()).resolve("package.bin");
        Path unavailableBinary = latestBinary.resolveSibling("unavailable-fixture.bin");
        Files.move(latestBinary, unavailableBinary);
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(arm.id(), first.id());
        Files.move(unavailableBinary, latestBinary);
        service = newService();
        assertThat(service.downloads()).allMatch(release -> "installer".equals(release.packageKind()));

        byte[] oldZip = windows(29, "x64", null, "installer");
        var duplicate = installerDraft(29, "x64", oldZip);
        service.upload(duplicate.id(), new ByteArrayInputStream(oldZip), oldZip.length);
        assertCode(() -> service.publish(duplicate.id()), ErrorCode.CONFLICT);
        service.withdraw(latest.id());
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(arm.id(), first.id());
        assertCode(() -> service.download(latest.id()), ErrorCode.NOT_FOUND);
        Files.delete(directory.resolve(first.id().toString()).resolve("package.bin"));
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(arm.id());
    }

    @Test
    void completeInstallerRequiresMatchingKindAndFixedNonemptyUpdaterAndCannotBecomeAnUpdate() throws Exception {
        byte[] update = windows(28, "x64", null);
        var disguised = installerDraft(28, "x64", update);
        assertCode(() -> service.upload(disguised.id(), new ByteArrayInputStream(update), update.length), ErrorCode.VALIDATION_FAILED);
        for (String fault : List.of("missing-updater", "empty-updater", "missing-kind", "client_updater/replace.ps1", "hash")) {
            byte[] zip = windows(28, "x64", fault, "installer");
            var release = installerDraft(28, "x64", zip);
            assertCode(() -> service.upload(release.id(), new ByteArrayInputStream(zip), zip.length), ErrorCode.VALIDATION_FAILED);
        }
        byte[] installer = windows(28, "x64", null, "installer");
        var wrongPurpose = draft(28, installer);
        assertCode(() -> service.upload(wrongPurpose.id(), new ByteArrayInputStream(installer), installer.length), ErrorCode.VALIDATION_FAILED);
    }

    @Test
    void legacyBundleStaysDownloadableButIsExcludedFromSetupCatalogAndSharesInstallerBuildSequence() throws Exception {
        byte[] zip = windows(28, "x64", null, "installer");
        var legacy = installerDraft(28, "x64", zip);
        service.upload(legacy.id(), new ByteArrayInputStream(zip), zip.length);
        service.publish(legacy.id());
        assertThat(service.downloads()).isEmpty();
        try (var input = service.download(legacy.id()).stream()) { assertThat(input.readAllBytes()).isEqualTo(zip); }
        assertCode(() -> publishInstaller(28, "x64"), ErrorCode.CONFLICT);
        var setup = publishInstaller(29, "x64");
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(setup.id());
    }

    @Test
    void setupUploadRejectsWrongBytesMetadataAndUpdateDisguiseAndPublishRechecksActualPe() throws Exception {
        byte[] fake = new byte[] {1, 2, 3};
        var bad = setupDraft(28, "x64", fake);
        assertCode(() -> service.upload(bad.id(), new ByteArrayInputStream(fake), fake.length), ErrorCode.VALIDATION_FAILED);
        byte[] wrong = WindowsSetupFixture.bytes(27, "x64", "2.5.28");
        var metadata = setupDraft(28, "x64", wrong);
        assertCode(() -> service.upload(metadata.id(), new ByteArrayInputStream(wrong), wrong.length), ErrorCode.VALIDATION_FAILED);
        byte[] setup = WindowsSetupFixture.bytes(28, "x64", "2.5.28");
        assertCode(() -> service.create(new ClientReleaseDto.Create(UUID.randomUUID(), "windows", "x64", "2.5.28", 28,
                "", false, "UtenIMPSetup.exe", sha(setup), null, "update")), ErrorCode.VALIDATION_FAILED);
        var draft = setupDraft(28, "x64", setup);
        service.upload(draft.id(), new ByteArrayInputStream(setup), setup.length);
        setup[660] ^= 1;
        Files.write(directory.resolve(draft.id().toString()).resolve("package.bin"), setup);
        assertCode(() -> service.publish(draft.id()), ErrorCode.VALIDATION_FAILED);
    }

    @Test
    void kindDefaultsToUpdateForOldRequestsAndCatalogFilesAndIsPartOfIdempotentIdentity() throws Exception {
        byte[] zip = windows(28, "x64", null);
        var release = draft(28, zip);
        assertThat(release.packageKind()).isEqualTo("update");
        var oldMetadata = mapper.valueToTree(release);
        ((com.fasterxml.jackson.databind.node.ObjectNode) oldMetadata).remove("packageKind");
        Files.write(directory.resolve(release.id().toString()).resolve("release.json"), mapper.writeValueAsBytes(oldMetadata));
        service = newService();
        assertThat(service.list()).singleElement().extracting(ClientReleaseDto.Release::packageKind).isEqualTo("update");
        var changed = new ClientReleaseDto.Create(release.id(), "windows", "x64", release.version(), release.buildNumber(),
                release.releaseNotes(), release.mandatory(), release.fileName(), release.expectedSha256(), null, "installer");
        assertCode(() -> service.create(changed), ErrorCode.CONFLICT);
        assertThat(new ClientReleaseDto.Create(UUID.randomUUID(), "windows", "x64", "2.5.28", 28, "", false,
                "uten.zip", sha(zip), null, null).packageKind()).isEqualTo("update");
        for (String kind : List.of("", "unknown")) {
            assertCode(() -> service.create(new ClientReleaseDto.Create(UUID.randomUUID(), "windows", "x64", "2.5.28", 28,
                    "", false, "uten.zip", sha(zip), null, kind)), ErrorCode.VALIDATION_FAILED);
        }
        for (String platform : List.of("android", "macos", "ios")) {
            assertCode(() -> service.create(new ClientReleaseDto.Create(UUID.randomUUID(), platform, "arm64", "2.5.28", 28,
                    "", false, "uten.zip", sha(zip), null, "installer")), ErrorCode.VALIDATION_FAILED);
        }
    }

    @Test
    void installerCatalogAndDirectDownloadRequireAuthenticatedStaffWithoutPasswordChange() throws Exception {
        var installer = publishInstaller(28, "x64");
        when(publisher.getPermissions()).thenReturn(Set.of());
        assertThat(service.downloads()).hasSize(1);
        try (var input = service.download(installer.id()).stream()) { assertThat(input.readAllBytes()).isNotEmpty(); }
        when(publisher.isVisitor()).thenReturn(true);
        assertInstallerAccessForbidden(installer.id());
        when(publisher.isVisitor()).thenReturn(false);
        when(publisher.isMustChangePassword()).thenReturn(true);
        assertInstallerAccessForbidden(installer.id());
        when(publisher.isMustChangePassword()).thenReturn(false);
        when(publisher.getEmployeeId()).thenReturn(null);
        assertInstallerAccessForbidden(installer.id());
        when(users.get()).thenReturn(Optional.empty());
        assertCode(service::downloads, ErrorCode.UNAUTHORIZED);
        assertCode(() -> service.download(installer.id()), ErrorCode.UNAUTHORIZED);
    }

    @Test
    void superAdministratorWithoutEmployeeProfileCanReadAndDownloadButRestrictedSessionsRemainForbidden() throws Exception {
        var installer = publishInstaller(28, "x64");
        when(publisher.getPermissions()).thenReturn(Set.of());
        when(publisher.getEmployeeId()).thenReturn(null);
        when(publisher.isSuperAdmin()).thenReturn(true);
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(installer.id());
        try (var input = service.download(installer.id()).stream()) { assertThat(input.readAllBytes()).isNotEmpty(); }
        when(publisher.isSuperAdmin()).thenReturn(false);
        assertInstallerAccessForbidden(installer.id());
        when(publisher.isSuperAdmin()).thenReturn(true);
        when(publisher.isVisitor()).thenReturn(true);
        assertInstallerAccessForbidden(installer.id());
        when(publisher.isVisitor()).thenReturn(false);
        when(publisher.isMustChangePassword()).thenReturn(true);
        assertInstallerAccessForbidden(installer.id());
    }

    private void assertInstallerAccessForbidden(UUID id) {
        assertCode(service::downloads, ErrorCode.FORBIDDEN);
        assertCode(() -> service.download(id), ErrorCode.FORBIDDEN);
    }

    private ClientReleaseDto.Release publishInstaller(long build, String architecture) throws Exception {
        byte[] zip = WindowsSetupFixture.bytes(build, architecture, "2.5.28");
        var release = setupDraft(build, architecture, zip);
        service.upload(release.id(), new ByteArrayInputStream(zip), zip.length);
        return service.publish(release.id());
    }

    private ClientReleaseDto.Release setupDraft(long build, String architecture, byte[] bytes) {
        return service.create(new ClientReleaseDto.Create(UUID.randomUUID(), "windows", architecture, "2.5.28", build,
                "Windows 安装程序", false, "UtenIMPSetup.exe", sha(bytes), null, "installer"));
    }

    private ClientReleaseDto.Release installerDraft(long build, String architecture, byte[] zip) {
        return service.create(new ClientReleaseDto.Create(UUID.randomUUID(), "windows", architecture, "2.5.28", build,
                "完整客户端", false, "uten-full.zip", sha(zip), null, "installer"));
    }

    private ClientReleaseService newService() {
        return new ClientReleaseService(new ClientReleaseCatalog(properties, new StorageProperties(), mapper),
                new ClientPackageInspector(mapper), properties, users, mock(AuditService.class));
    }

    private ClientReleaseDto.Release draft(long build, byte[] zip) {
        return service.create(new ClientReleaseDto.Create(UUID.randomUUID(), "windows", "x64", "2.5.28", build,
                "更新说明", false, "uten.zip", sha(zip), null));
    }

    private ClientReleaseDto.Release publishStore(String platform, String architecture, long build) {
        return service.publish(service.create(storeRequest(platform, architecture, build)).id());
    }

    private ClientReleaseDto.Create storeRequest(String platform, String architecture, long build) {
        return new ClientReleaseDto.Create(UUID.randomUUID(), platform, architecture, "2.5.28", build, "", false, null, null,
                "android".equals(platform) ? "https://play.google.com/store/apps/details?id=com.uten.imp" : "https://apps.apple.com/us/app/id123456");
    }

    private byte[] windows(long build, String architecture, String fault) throws Exception {
        return windows(build, architecture, fault, "update");
    }

    private byte[] windows(long build, String architecture, String fault, String kind) throws Exception {
        Map<String, byte[]> files = new LinkedHashMap<>();
        for (String name : List.of("uten_imp.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin"))
            files.put(name, name.getBytes(StandardCharsets.UTF_8));
        if ("installer".equals(kind) && !"missing-updater".equals(fault))
            files.put("client_updater/client_updater.ps1", "empty-updater".equals(fault) ? new byte[0]
                    : "trusted bootstrap updater".getBytes(StandardCharsets.UTF_8));
        if (fault != null && !Set.of("hash", "missing-updater", "empty-updater", "missing-kind").contains(fault)) files.put(fault, new byte[] {1});
        List<Map<String, Object>> entries = new ArrayList<>();
        files.forEach((name, bytes) -> entries.add(Map.of("path", name, "size", bytes.length,
                "sha256", "hash".equals(fault) ? "0".repeat(64) : sha(bytes))));
        Map<String, Object> metadata = new LinkedHashMap<>(Map.of("schemaVersion", 1, "platform", "windows", "architecture", architecture,
                "buildNumber", build, "executable", "uten_imp.exe", "files", entries));
        if ("installer".equals(kind) && !"missing-kind".equals(fault)) metadata.put("packageKind", "installer");
        byte[] manifest = mapper.writeValueAsBytes(metadata);
        files.put("uten-client-manifest.json", manifest);
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(output)) {
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
}
