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
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ClientRuntimeFamilyTest {
    @TempDir Path directory;
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
    private ClientReleaseService service;
    @BeforeEach void setup() {
        var properties = new ClientUpdateProperties(); properties.setDirectory(directory.toString());
        var actor = mock(AuthUser.class); var users = mock(SecurityContextCurrentUser.class);
        when(actor.getPermissions()).thenReturn(Set.of(ClientReleaseService.PUBLISH_PERMISSION));
        when(actor.getId()).thenReturn(UUID.randomUUID()); when(actor.getEmployeeId()).thenReturn(UUID.randomUUID());
        when(actor.getLoginAccount()).thenReturn("publisher"); when(users.get()).thenReturn(Optional.of(actor));
        service = new ClientReleaseService(new ClientReleaseCatalog(properties, new StorageProperties(), mapper),
                new ClientPackageInspector(mapper), properties, users, mock(AuditService.class));
    }

    @Test void oldRequestCatalogAndOverloadsRemainFlutterByDefault() throws Exception {
        var old = new ClientReleaseDto.Create(UUID.randomUUID(), "windows", "x64", "2.5.1", 1, "", false, "setup.exe", "a".repeat(64), null, "installer");
        assertThat(old.runtimeFamily()).isEqualTo("flutter");
        var draft = service.create(old);
        var json = mapper.valueToTree(draft); ((com.fasterxml.jackson.databind.node.ObjectNode)json).remove("runtimeFamily");
        Files.write(directory.resolve(draft.id().toString()).resolve("release.json"), mapper.writeValueAsBytes(json));
        assertThat(service.list()).singleElement().extracting(ClientReleaseDto.Release::runtimeFamily).isEqualTo("flutter");
        assertThat(mapper.readValue(mapper.writeValueAsBytes(old), ClientReleaseDto.Create.class).runtimeFamily()).isEqualTo("flutter");
    }

    @Test void buildOrderingRecommendationsAndDownloadsNeverCrossRuntimeFamilies() throws Exception {
        var flutter = pair("flutter", "x64", 100);
        var wpf = pair("wpf_legacy", "x64", 1);
        assertThat(service.check("windows", "x64", 0).release().id()).isEqualTo(flutter.get(1).id());
        assertThat(service.check("windows", "x64", 0, "wpf_legacy").release().id()).isEqualTo(wpf.get(1).id());
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(flutter.getFirst().id());
        assertThat(service.downloads("wpf_legacy", false)).extracting(ClientReleaseDto.Release::id).containsExactly(wpf.getFirst().id());
        assertThat(service.downloads("flutter", true)).extracting(ClientReleaseDto.Release::id).containsExactlyInAnyOrder(flutter.getFirst().id(), wpf.getFirst().id());
        invalid(() -> service.download(wpf.getFirst().id()), ErrorCode.NOT_FOUND);
        invalid(() -> service.download(flutter.getFirst().id(), "wpf_legacy"), ErrorCode.NOT_FOUND);
        assertThat(wpf.getFirst().downloadUrl()).endsWith("?runtimeFamily=wpf_legacy");
        try(var stream = service.download(wpf.getFirst().id(), "wpf_legacy").stream()) { assertThat(stream.read()).isGreaterThanOrEqualTo(0); }
        var downgrade = uploaded("wpf_legacy", "x64", 1, "update");
        invalid(() -> service.publish(downgrade.id()), ErrorCode.CONFLICT);
    }

    @Test void completeWpfPairCannotRetireFlutterAndCompleteFlutterPairCannotRetireWpf() throws Exception {
        var flutter = pair("flutter", "x64", 10); var wpf = pair("wpf_legacy", "x64", 10);
        var newWpf = pair("wpf_legacy", "x64", 20);
        retired(wpf); retained(flutter); retained(newWpf);
        var first = publish("flutter", "x64", 30, "installer");
        retained(flutter); retained(newWpf);
        var second = publish("flutter", "x64", 30, "update");
        retired(flutter); retained(List.of(first, second)); retained(newWpf);
    }

    @Test void anotherFamilyOrArchitectureCannotCompleteAWpfPairAndDraftIdentityIncludesFamily() throws Exception {
        var old = pair("wpf_legacy", "x64", 10);
        publish("wpf_legacy", "x64", 20, "installer");
        publish("flutter", "x64", 20, "update");
        publish("wpf_legacy", "x86", 20, "update");
        retained(old);
        publish("wpf_legacy", "x64", 20, "update"); retired(old);
        byte[] bytes = WindowsWpfFixture.setup(40, "x64", "2.5.40");
        UUID id = UUID.randomUUID();
        var request = request(id, "wpf_legacy", "x64", 40, "installer", bytes);
        var draft = service.create(request);
        assertThat(service.create(request)).isEqualTo(draft);
        invalid(() -> service.create(request(id, "flutter", "x64", 40, "installer", bytes)), ErrorCode.CONFLICT);
    }

    @Test void invalidFamiliesTargetsAndWpfBundleInstallersAreRejected() {
        for(String family : List.of("unknown", "", "WPF_LEGACY")) {
            invalid(() -> service.check("windows", "x64", 0, family), ErrorCode.VALIDATION_FAILED);
            invalid(() -> service.downloads(family, true), ErrorCode.VALIDATION_FAILED);
        }
        invalid(() -> service.check("windows", "arm64", 0, "wpf_legacy"), ErrorCode.VALIDATION_FAILED);
        var request = new ClientReleaseDto.Create(UUID.randomUUID(), "android", "x64", "2.5.1", 1, "", false,
                "wpf.zip", "a".repeat(64), null, "update", "wpf_legacy");
        invalid(() -> service.create(request), ErrorCode.VALIDATION_FAILED);
        var bundle = new ClientReleaseDto.Create(UUID.randomUUID(), "windows", "x64", "2.5.1", 1, "", false,
                "wpf.zip", "a".repeat(64), null, "installer", "wpf_legacy");
        invalid(() -> service.create(bundle), ErrorCode.VALIDATION_FAILED);
    }
    private List<ClientReleaseDto.Release> pair(String family, String arch, long build) throws Exception {
        return List.of(publish(family, arch, build, "installer"), publish(family, arch, build, "update"));
    }
    private ClientReleaseDto.Release publish(String family, String arch, long build, String kind) throws Exception {
        return service.publish(uploaded(family, arch, build, kind).id());
    }
    private ClientReleaseDto.Release uploaded(String family, String arch, long build, String kind) throws Exception {
        String version="2.5."+build;
        byte[] bytes = "installer".equals(kind)
                ? "flutter".equals(family) ? WindowsSetupFixture.bytes(build, arch, version) : WindowsWpfFixture.setup(build, arch, version)
                : "flutter".equals(family) ? ClientReleaseFixtures.windows(mapper, build, arch, version) : WindowsWpfFixture.update(build, arch, version);
        var draft = service.create(request(UUID.randomUUID(), family, arch, build, kind, bytes));
        return service.upload(draft.id(), new ByteArrayInputStream(bytes), bytes.length);
    }
    private ClientReleaseDto.Create request(UUID id, String family, String arch, long build, String kind, byte[] bytes) {
        return new ClientReleaseDto.Create(id, "windows", arch, "2.5."+build, build, "candidate contract fixture", false,
                "installer".equals(kind)?"setup.exe":"update.zip", WindowsWpfFixture.sha(bytes), null, kind, family);
    }
    private void retained(List<ClientReleaseDto.Release> releases) {
        for(var release:releases) assertThat(directory.resolve(release.id().toString()).resolve("package.bin")).isRegularFile();
    }
    private void retired(List<ClientReleaseDto.Release> releases) throws Exception {
        for(var release:releases) {
            assertThat(directory.resolve(release.id().toString()).resolve("package.bin")).doesNotExist();
            var metadata=mapper.readTree(directory.resolve(release.id().toString()).resolve("release.json").toFile()).path("runtimeFamily").asText();
            assertThat(metadata).isEqualTo(release.runtimeFamily());
        }
    }
    private static void invalid(org.assertj.core.api.ThrowableAssert.ThrowingCallable action, ErrorCode code) {
        assertThatThrownBy(action).isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getCode()).isEqualTo(code));
    }
}
