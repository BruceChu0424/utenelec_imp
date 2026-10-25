package com.uten.imp.features.companyfiles;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.audit.AuditLog;
import com.uten.imp.audit.AuditLogRepository;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.companyfiles.CompanyFileDtos.Entry;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.mockito.ArgumentCaptor;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/** The real recorder and serializer must never turn an authorized metadata view into a file export. */
class CompanyFileDetailViewAuditControllerTest {
    private final CompanyFileService service = mock(CompanyFileService.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final AuditLogRepository repository = mock(AuditLogRepository.class);
    private final ObjectMapper json = new ObjectMapper().findAndRegisterModules();
    private final CompanyFileController controller = new CompanyFileController(
            service,
            new AuditDetailViewRecorder(
                    new AuditService(repository, new AuditDeviceContext(json)), currentUser));

    @AfterEach
    void clearRequest() {
        RequestContextHolder.resetRequestAttributes();
    }

    @Test
    void successfulDetailUsesResolvedIdentityAndAuthenticatedViewerWithoutPrivateMetadata()
            throws Exception {
        UUID pathId = UUID.randomUUID();
        Entry entry = privateFile(UUID.randomUUID());
        UUID viewer = UUID.randomUUID();
        AuthUser user = new AuthUser(viewer, UUID.randomUUID(), "metadata-reader",
                Set.of("company_file:view"), false, true, false, false, null, UUID.randomUUID());
        when(currentUser.get()).thenReturn(Optional.of(user));
        when(service.detail(pathId)).thenReturn(entry);
        MockHttpServletRequest request = bindRequest(pathId);

        assertSame(entry, controller.detail(pathId));

        AuditLog saved = savedView();
        assertThat(saved.getActorId()).isEqualTo(viewer);
        assertThat(saved.getActorAccount()).isEqualTo("metadata-reader");
        assertThat(saved.getTargetId()).isEqualTo(entry.id().toString()).isNotEqualTo(pathId.toString());
        assertSafeView(saved, entry);
        assertThat(request.getAttribute("uten.audit.meaningfulEventRecorded")).isEqualTo(true);
        verify(service).detail(pathId);
    }

    @Test
    void verifiedRealActorAndImpersonatedSubjectArePreservedByTheSharedRecorder() throws Exception {
        UUID pathId = UUID.randomUUID();
        Entry entry = privateFile(pathId);
        when(service.detail(pathId)).thenReturn(entry);
        UUID realActor = UUID.randomUUID();
        UUID impersonatedSubject = UUID.randomUUID();
        MockHttpServletRequest request = bindRequest(pathId);
        UUID session = UUID.randomUUID();
        AuditRequestContext.bindVerifiedActor(
                request, realActor, "verified-admin", session, impersonatedSubject);

        controller.detail(pathId);

        AuditLog saved = savedView();
        assertThat(saved.getActorId()).isEqualTo(realActor);
        assertThat(saved.getActorAccount()).isEqualTo("verified-admin");
        assertThat(saved.getOnBehalfOf()).isEqualTo(impersonatedSubject);
        assertThat(saved.getSessionId()).isEqualTo(session);
        assertSafeView(saved, entry);
        verifyNoInteractions(currentUser);
    }

    @ParameterizedTest
    @EnumSource(value = ErrorCode.class, names = {"UNAUTHORIZED", "FORBIDDEN", "NOT_FOUND"})
    void failedResolutionNeverWritesSuccessfulViewOrRequestsAnAuditActor(ErrorCode code) {
        UUID id = UUID.randomUUID();
        ApiException denied = new ApiException(code);
        when(service.detail(id)).thenThrow(denied);
        bindRequest(id);

        assertSame(denied, assertThrows(ApiException.class, () -> controller.detail(id)));

        verifyNoInteractions(repository, currentUser);
    }

    @Test
    void auditPersistenceIsAttemptedOnlyAfterTheDetailWasSuccessfullyResolved() {
        UUID id = UUID.randomUUID();
        Entry entry = privateFile(id);
        UUID viewer = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(viewer, UUID.randomUUID(),
                "metadata-reader", Set.of("company_file:view"), false, true, false, false,
                null, UUID.randomUUID())));
        boolean[] resolved = {false};
        when(service.detail(id)).thenAnswer(invocation -> {
            resolved[0] = true;
            return entry;
        });
        doAnswer(invocation -> {
            assertThat(resolved[0]).isTrue();
            return invocation.getArgument(0);
        }).when(repository).save(org.mockito.ArgumentMatchers.any(AuditLog.class));
        bindRequest(id);

        controller.detail(id);

        savedView();
    }

    @Test
    void auditPersistenceFailureCannotBecomeAnUnauditedSuccessfulResponse() {
        UUID id = UUID.randomUUID();
        Entry entry = privateFile(id);
        when(service.detail(id)).thenReturn(entry);
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),
                UUID.randomUUID(), "metadata-reader", Set.of("company_file:view"),
                false, true, false, false, null, UUID.randomUUID())));
        IllegalStateException failure = new IllegalStateException("audit persistence unavailable");
        doThrow(failure).when(repository).save(org.mockito.ArgumentMatchers.any(AuditLog.class));
        bindRequest(id);

        assertSame(failure, assertThrows(IllegalStateException.class, () -> controller.detail(id)));

        verify(service).detail(id);
        verify(repository).save(org.mockito.ArgumentMatchers.any(AuditLog.class));
    }

    private MockHttpServletRequest bindRequest(UUID id) {
        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/api/company-files/" + id);
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        return request;
    }

    private AuditLog savedView() {
        ArgumentCaptor<AuditLog> saved = ArgumentCaptor.forClass(AuditLog.class);
        verify(repository, times(1)).save(saved.capture());
        return saved.getValue();
    }

    private void assertSafeView(AuditLog saved, Entry entry) throws Exception {
        assertThat(saved.getAction()).isEqualTo("view_company_file_detail");
        assertThat(saved.getTargetType()).isEqualTo("company_file_nodes");
        assertThat(saved.getEventSource()).isEqualTo("business");
        assertThat(saved.getEventCategory()).isEqualTo("business");
        assertThat(saved.getResult()).isEqualTo("success");
        assertThat(saved.getBefore()).isNull();
        var metadata = json.readTree(saved.getAfter());
        assertThat(metadata.size()).isEqualTo(4);
        assertThat(metadata.path("view_metadata_kind").asText()).isEqualTo("business_detail_view");
        assertThat(metadata.path("target_display_name").asText()).isEqualTo("公司资料");
        assertThat(metadata.path("target_business_code").isNull()).isTrue();
        assertThat(metadata.path("target_legacy_code").isNull()).isTrue();
        assertThat(saved.getAfter()).doesNotContain(entry.name(), entry.description(),
                entry.attachmentId().toString(), entry.parentId().toString(),
                "amount", "password", "allowedActions", "storageKey");
    }

    private static Entry privateFile(UUID id) {
        Instant time = Instant.parse("2026-10-25T08:00:00Z");
        return new Entry(id, UUID.randomUUID(), "FILE", "工资金额及客户报价-保密.txt",
                "amount=123456; password=not-for-audit; storageKey=/private/original", 4, 0,
                false, false, false, null, time, time, "创建人", "修改人",
                UUID.randomUUID(), 100L, "text/plain", false, List.of("view"));
    }
}
