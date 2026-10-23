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
        when(publisher.isSuperAdmin()).thenReturn(true);
        when(publisher.getPermissions()).thenReturn(Set.of("authorization:manage"));
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
    void publisherMustBeRealAuthorizedAdministratorEvenWithoutMethodSecurityProxy() {
        when(publisher.isSuperAdmin()).thenReturn(false);
        assertCode(() -> service.create(storeRequest("ios", "universal", 1)), ErrorCode.FORBIDDEN);
        assertCode(service::list, ErrorCode.FORBIDDEN);
        when(publisher.isSuperAdmin()).thenReturn(true);
        when(publisher.getImpersonatedBy()).thenReturn(UUID.randomUUID());
        assertCode(() -> service.create(storeRequest("ios", "universal", 1)), ErrorCode.FORBIDDEN);
        when(users.get()).thenReturn(Optional.empty());
        assertCode(() -> service.check("windows", "x64", 1), ErrorCode.UNAUTHORIZED);
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
        Map<String, byte[]> files = new LinkedHashMap<>();
        for (String name : List.of("uten_imp.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin"))
            files.put(name, name.getBytes(StandardCharsets.UTF_8));
        if (fault != null && !"hash".equals(fault)) files.put(fault, new byte[] {1});
        List<Map<String, Object>> entries = new ArrayList<>();
        files.forEach((name, bytes) -> entries.add(Map.of("path", name, "size", bytes.length,
                "sha256", "hash".equals(fault) ? "0".repeat(64) : sha(bytes))));
        byte[] manifest = mapper.writeValueAsBytes(Map.of("schemaVersion", 1, "platform", "windows", "architecture", architecture,
                "buildNumber", build, "executable", "uten_imp.exe", "files", entries));
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
