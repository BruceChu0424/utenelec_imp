package com.uten.imp.features.clientupdates;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
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
import java.nio.file.Path;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class WindowsSignaturePublicationTest {
    @TempDir Path directory;
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
    private final ClientUpdateProperties properties = new ClientUpdateProperties();
    private final SecurityContextCurrentUser users = mock(SecurityContextCurrentUser.class);
    private final WindowsPublisherSignatures signatures = mock(WindowsPublisherSignatures.class);
    private ClientReleaseCatalog catalog;

    @BeforeEach void prepare() {
        properties.setDirectory(directory.toString());
        var actor = mock(AuthUser.class);
        when(actor.getPermissions()).thenReturn(Set.of(ClientReleaseService.PUBLISH_PERMISSION));
        when(actor.getEmployeeId()).thenReturn(UUID.randomUUID());
        when(actor.getId()).thenReturn(UUID.randomUUID());
        when(actor.getLoginAccount()).thenReturn("publisher");
        when(users.get()).thenReturn(Optional.of(actor));
        catalog = new ClientReleaseCatalog(properties, new StorageProperties(), mapper);
    }

    @Test void productionUploadRejectsUnsignedPackageAndKeepsDraftUnpublished() throws Exception {
        var service = service(new WindowsPublisherSignatures(properties));
        byte[] bytes = ClientReleaseFixtures.windows(mapper, 2545, "x64", "2.5.45");
        var release = draft(service, bytes);
        assertThatThrownBy(() -> service.upload(release.id(), new ByteArrayInputStream(bytes), bytes.length))
                .isInstanceOf(ApiException.class).hasMessageContaining("UTEN_WINDOWS_PUBLISHER_SHA256");
        assertThat(service.get(release.id()).state()).isEqualTo("DRAFT");
        assertThat(service.get(release.id()).sha256()).isNull();
    }

    @Test void publishRechecksActualBytesEvenAfterUploadWasPreviouslyAccepted() throws Exception {
        var service = service(signatures);
        byte[] bytes = ClientReleaseFixtures.windows(mapper, 2545, "x64", "2.5.45");
        var release = draft(service, bytes);
        service.upload(release.id(), new ByteArrayInputStream(bytes), bytes.length);
        doThrow(new ApiException(ErrorCode.VALIDATION_FAILED, "签名已撤销")).when(signatures).inspect(any(), any());
        assertThatThrownBy(() -> service.publish(release.id())).isInstanceOf(ApiException.class).hasMessageContaining("签名已撤销");
        assertThat(service.get(release.id()).state()).isEqualTo("DRAFT");
    }

    @Test void slowSignatureVerificationDoesNotHoldCatalogLock() throws Exception {
        var service = service(signatures);
        byte[] bytes = ClientReleaseFixtures.windows(mapper, 2545, "x64", "2.5.45");
        var release = draft(service, bytes);
        service.upload(release.id(), new ByteArrayInputStream(bytes), bytes.length);
        var entered = new CountDownLatch(1); var resume = new CountDownLatch(1);
        doAnswer(invocation -> { entered.countDown(); assertThat(resume.await(10, TimeUnit.SECONDS)).isTrue(); return null; })
                .when(signatures).inspect(any(), any());
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var publishing = executor.submit(() -> service.publish(release.id()));
            try {
                assertThat(entered.await(5, TimeUnit.SECONDS)).isTrue();
                assertThat(executor.submit(() -> service.get(release.id())).get(2, TimeUnit.SECONDS).state()).isEqualTo("DRAFT");
            } finally { resume.countDown(); }
            assertThat(publishing.get(5, TimeUnit.SECONDS).state()).isEqualTo("PUBLISHED");
        }
    }

    @Test void changesDuringVerificationConflictWithoutPublishingOrReplaying() throws Exception {
        var service = service(signatures);
        byte[] bytes = ClientReleaseFixtures.windows(mapper, 2545, "x64", "2.5.45");
        var release = draft(service, bytes);
        service.upload(release.id(), new ByteArrayInputStream(bytes), bytes.length);
        var entered = new CountDownLatch(1); var resume = new CountDownLatch(1);
        doAnswer(invocation -> { entered.countDown(); assertThat(resume.await(10, TimeUnit.SECONDS)).isTrue(); return null; })
                .when(signatures).inspect(any(), any());
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var publishing = executor.submit(() -> service.publish(release.id()));
            try {
                assertThat(entered.await(5, TimeUnit.SECONDS)).isTrue();
                assertThat(service.withdraw(release.id()).state()).isEqualTo("WITHDRAWN");
            } finally { resume.countDown(); }
            assertThatThrownBy(() -> publishing.get(5, TimeUnit.SECONDS)).hasCauseInstanceOf(ApiException.class)
                    .hasRootCauseMessage("发布信息在签名校验期间发生变化，请刷新后重试");
            assertThat(service.get(release.id()).state()).isEqualTo("WITHDRAWN");
        }
    }

    @Test void historicalPublishedRetryRemainsRecoverableWithoutNewSigningConfiguration() throws Exception {
        var historical = service(signatures);
        byte[] bytes = ClientReleaseFixtures.windows(mapper, 2545, "x64", "2.5.45");
        var release = draft(historical, bytes);
        historical.upload(release.id(), new ByteArrayInputStream(bytes), bytes.length);
        var published = historical.publish(release.id());
        var strict = service(new WindowsPublisherSignatures(properties));
        assertThat(strict.publish(release.id())).isEqualTo(published);
        assertThat(strict.get(release.id()).state()).isEqualTo("PUBLISHED");
    }

    private ClientReleaseService service(WindowsPublisherSignatures verifier) {
        return new ClientReleaseService(catalog, new ClientPackageInspector(mapper, verifier), properties, users, mock(AuditService.class));
    }
    private ClientReleaseDto.Release draft(ClientReleaseService service, byte[] bytes) {
        return service.create(new ClientReleaseDto.Create(UUID.randomUUID(), "windows", "x64", "2.5.45", 2545,
                "signed release", false, "UTEN-2.5.45-Windows-x64-update.zip", ClientReleaseFixtures.sha(bytes), null, "update", "flutter"));
    }
}
