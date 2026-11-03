package com.uten.imp.features.clientupdates;

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
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Real inspector/catalog/service exercise both publication orders and retention isolation. */
class WindowsRuntimeProfilePublicationTest {
    @TempDir Path directory;
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
    private ClientReleaseService service;

    @BeforeEach void setUp() {
        var properties = new ClientUpdateProperties();
        properties.setDirectory(directory.toString());
        var users = mock(SecurityContextCurrentUser.class);
        var actor = mock(AuthUser.class);
        when(actor.getPermissions()).thenReturn(Set.of(ClientReleaseService.PUBLISH_PERMISSION));
        when(actor.getEmployeeId()).thenReturn(UUID.randomUUID());
        when(actor.getId()).thenReturn(UUID.randomUUID());
        when(actor.getLoginAccount()).thenReturn("profile-test-publisher");
        when(users.get()).thenReturn(Optional.of(actor));
        var catalog = new ClientReleaseCatalog(properties, new StorageProperties(), mapper);
        service = new ClientReleaseService(catalog, ClientReleaseFixtures.structuralInspector(mapper), properties, users, mock(AuditService.class));
    }

    @Test void matchingNewPairBecomesVisibleOnlyTogetherAndThenRetiresTheOldGroup() throws Exception {
        var old = legacyPair();
        byte[] setupBytes = WindowsSetupFixture.bytes(2544, "x64", "2.5.44");
        var setup = upload("installer", "2.5.44", 2544, setupBytes);
        var update = upload("update", "2.5.44", 2544, formalUpdate(ClientReleaseFixtures.sha(setupBytes)));
        service.publish(update.id());
        assertOldAvailable(old);
        service.publish(setup.id());
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(setup.id());
        assertThat(service.check("windows", "x64", 2543).release().id()).isEqualTo(update.id());
        assertThat(Files.exists(binary(old.getFirst()))).isFalse();
        assertThat(Files.exists(binary(old.getLast()))).isFalse();
    }

    @Test void wrongActualInstallerDigestRejectsTheSecondPublishAndPreservesThePreviousPair() throws Exception {
        for (boolean updateFirst : List.of(true, false)) {
            // Each publication order gets its own independent durable catalog.
            if (updateFirst) setUp();
            var old = legacyPair();
            byte[] setupBytes = WindowsSetupFixture.bytes(2544, "x64", "2.5.44");
            var setup = upload("installer", "2.5.44", 2544, setupBytes);
            var update = upload("update", "2.5.44", 2544, formalUpdate("b".repeat(64)));
            var first = updateFirst ? update : setup;
            var second = updateFirst ? setup : update;
            service.publish(first.id());
            assertThatThrownBy(() -> service.publish(second.id())).isInstanceOfSatisfying(ApiException.class,
                    failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
            assertThat(service.get(second.id()).state()).isEqualTo("DRAFT");
            assertOldAvailable(old);
            if (updateFirst) {
                // Start the next order in a fresh child catalog, preserving this failure evidence.
                directory = Files.createDirectory(directory.resolve("second-order"));
                setUp();
            }
        }
    }

    @Test void localTestBytesNeverBecomeUploadedOrPublishedUnderAFormalFilename() throws Exception {
        var old = legacyPair();
        var profile = WindowsRuntimeProfileFixture.generated("local_test");
        byte[] zip = WindowsRuntimeProfileFixture.archive(mapper, "2.5.44", 2544,
                Map.of("UtenBuildProfile", "local_test", "ProductName", "UTEN Local Test"), mapper.writeValueAsBytes(profile), "a".repeat(64));
        var draft = create("update", "2.5.44", 2544, zip);
        assertThatThrownBy(() -> service.upload(draft.id(), new ByteArrayInputStream(zip), zip.length))
                .isInstanceOfSatisfying(ApiException.class, failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        assertThat(Files.exists(binary(draft))).isFalse();
        assertThat(service.get(draft.id()).sha256()).isNull();
        assertOldAvailable(old);
    }

    private List<ClientReleaseDto.Release> legacyPair() throws Exception {
        var setup = upload("installer", "2.5.43", 2543, WindowsSetupFixture.bytes(2543, "x64", "2.5.43"));
        var update = upload("update", "2.5.43", 2543, ClientReleaseFixtures.windows(mapper, 2543, "x64", "2.5.43"));
        service.publish(setup.id()); service.publish(update.id());
        return List.of(setup, update);
    }
    private void assertOldAvailable(List<ClientReleaseDto.Release> old) {
        assertThat(Files.exists(binary(old.getFirst()))).isTrue();
        assertThat(Files.exists(binary(old.getLast()))).isTrue();
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(old.getFirst().id());
        assertThat(service.check("windows", "x64", 2542).release().id()).isEqualTo(old.getLast().id());
    }
    private byte[] formalUpdate(String hash) throws Exception {
        return WindowsRuntimeProfileFixture.archive(mapper, "2.5.44", 2544, Map.of("UtenBuildProfile", "formal"),
                mapper.writeValueAsBytes(WindowsRuntimeProfileFixture.formal()), hash);
    }
    private ClientReleaseDto.Release create(String kind, String version, long build, byte[] bytes) {
        return service.create(new ClientReleaseDto.Create(UUID.randomUUID(), "windows", "x64", version, build, "", false,
                "formal-name." + ("installer".equals(kind) ? "exe" : "zip"), ClientReleaseFixtures.sha(bytes), null, kind, "flutter"));
    }
    private ClientReleaseDto.Release upload(String kind, String version, long build, byte[] bytes) {
        var draft = create(kind, version, build, bytes);
        return service.upload(draft.id(), new ByteArrayInputStream(bytes), bytes.length);
    }
    private Path binary(ClientReleaseDto.Release release) { return directory.resolve(release.id().toString()).resolve("package.bin"); }
}
