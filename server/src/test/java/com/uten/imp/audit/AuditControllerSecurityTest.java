package com.uten.imp.audit;

import com.uten.imp.common.export.EncryptedWorkbookService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.config.WebMvcConfig;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ExportRateLimitInterceptor;
import com.uten.imp.security.JwtAuthFilter;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.FilterType;
import org.springframework.context.annotation.Import;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.UserRequestPostProcessor;

import java.lang.reflect.Method;
import java.time.LocalDate;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.nullable;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(
        controllers = AuditController.class,
        excludeFilters = @ComponentScan.Filter(
                type = FilterType.ASSIGNABLE_TYPE,
                classes = {
                        WebMvcConfig.class,
                        AuditRequestContextFilter.class,
                        UserOperationAuditInterceptor.class,
                        ExportRateLimitInterceptor.class,
                        JwtAuthFilter.class
                }))
@Import(AuditControllerSecurityTest.MethodSecurityConfiguration.class)
class AuditControllerSecurityTest {

    private static final String VIEW = "audit_log:view";
    private static final String EXPORT = "audit_log:export";
    private static final UUID ACTOR_ID = UUID.fromString("11111111-1111-1111-1111-111111111111");
    private static final UUID EMPLOYEE_ID = UUID.fromString("22222222-2222-2222-2222-222222222222");
    private static final UUID CLIENT_EVENT_ID =
            UUID.fromString("33333333-3333-3333-3333-333333333333");

    @Autowired
    private MockMvc mvc;

    @MockitoBean
    private AuditQueryService auditQuery;
    @MockitoBean
    private AuditRuntimeSettings runtimeSettings;
    @MockitoBean
    private XlsxExportService xlsxExport;
    @MockitoBean
    private EncryptedWorkbookService encryptedWorkbook;
    @MockitoBean
    private AuditService audit;
    @MockitoBean
    private SecurityContextCurrentUser currentUser;

    @BeforeEach
    void setUp() {
        when(auditQuery.query(
                nullable(String.class),
                nullable(String.class),
                nullable(String.class),
                nullable(String.class),
                nullable(String.class),
                nullable(LocalDate.class),
                nullable(LocalDate.class),
                anyInt(),
                anyInt()))
                .thenReturn(new PageResponse<>(List.of(), 1, 20, 0, 0));
        when(auditQuery.summary(
                nullable(String.class),
                nullable(String.class),
                nullable(String.class),
                nullable(LocalDate.class),
                nullable(LocalDate.class)))
                .thenReturn(new AuditSummary(0, 0, 0, 0, 0, List.of()));
        when(auditQuery.export(
                nullable(String.class),
                nullable(String.class),
                nullable(String.class),
                nullable(String.class),
                nullable(String.class),
                nullable(LocalDate.class),
                nullable(LocalDate.class),
                anyInt()))
                .thenReturn(new ExportPayload(List.of(), List.of(), 0));
        when(runtimeSettings.exportMaxRows()).thenReturn(1_000);
        when(xlsxExport.build(anyList(), anyList())).thenReturn(new byte[]{1});
        when(encryptedWorkbook.encrypt(any(byte[].class), anyString())).thenReturn(new byte[]{9});
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(
                ACTOR_ID,
                EMPLOYEE_ID,
                "investigator",
                Set.of(),
                Set.of(VIEW, EXPORT),
                false,
                true,
                false)));
    }

    @Test
    void ordinaryUserCannotReadAuditLogs() throws Exception {
        mvc.perform(get("/api/admin/audit-logs").with(user("ordinary")))
                .andExpect(status().isForbidden());

        verifyNoInteractions(auditQuery, audit);
    }

    @Test
    void viewPermissionCanReadButCannotExport() throws Exception {
        mvc.perform(get("/api/admin/audit-logs").with(viewUser()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.total").value(0));
        verify(audit).logExplicit(
                ACTOR_ID,
                "investigator",
                "view_audit_log_list",
                "audit_log",
                "returned=0; total=0",
                "success");

        clearInvocations(auditQuery, audit);
        mvc.perform(post("/api/admin/audit-logs/export")
                        .with(viewUser())
                        .with(csrf())
                        .contentType(APPLICATION_JSON)
                        .content("""
                                {"password":"secret12"}
                                """))
                .andExpect(status().isForbidden());
        verifyNoInteractions(auditQuery, audit);
    }

    @Test
    void viewAndExportPermissionsCanExport() throws Exception {
        mvc.perform(post("/api/admin/audit-logs/export")
                        .with(viewAndExportUser())
                        .with(csrf())
                        .contentType(APPLICATION_JSON)
                        .content("""
                                {"password":"secret12"}
                                """))
                .andExpect(status().isOk())
                .andExpect(content().bytes(new byte[]{9}));

        verify(auditQuery).export(
                nullable(String.class),
                nullable(String.class),
                nullable(String.class),
                nullable(String.class),
                nullable(String.class),
                nullable(LocalDate.class),
                nullable(LocalDate.class),
                eq(1_000));
        verify(audit).logExplicit(
                ACTOR_ID,
                "investigator",
                "export_audit_log",
                "audit_log",
                "rows=0; dateFrom=all; dateTo=all; risk=all",
                "success");
    }

    @Test
    void localReceiptVerificationRequiresViewAndWritesExplicitAudit() throws Exception {
        mvc.perform(post("/api/admin/audit-logs/local-receipt-verifications/{clientEventId}",
                        CLIENT_EVENT_ID)
                        .with(user("ordinary"))
                        .with(csrf()))
                .andExpect(status().isForbidden());
        verify(audit, never()).logExplicit(
                any(), any(), any(), any(), any(), any());

        mvc.perform(post("/api/admin/audit-logs/local-receipt-verifications/{clientEventId}",
                        CLIENT_EVENT_ID)
                        .with(viewUser())
                        .with(csrf()))
                .andExpect(status().isNoContent());
        verify(audit).logExplicit(
                ACTOR_ID,
                "investigator",
                "verify_local_audit_receipt",
                "audit_log",
                CLIENT_EVENT_ID.toString(),
                "success");
    }

    @Test
    void localReceiptVerificationRejectsMalformedUuidBeforeAuditing() throws Exception {
        mvc.perform(post("/api/admin/audit-logs/local-receipt-verifications/not-a-uuid")
                        .with(viewUser())
                        .with(csrf()))
                .andExpect(status().isBadRequest());

        verifyNoInteractions(audit);
    }

    @Test
    void summaryAndDetailReadsAreExplicitlyAudited() throws Exception {
        mvc.perform(get("/api/admin/audit-logs/summary").with(viewUser()))
                .andExpect(status().isOk());
        verify(audit).logExplicit(
                ACTOR_ID,
                "investigator",
                "view_audit_log_summary",
                "audit_log",
                "total=0; risk=0",
                "success");

        clearInvocations(audit);
        mvc.perform(get("/api/admin/audit-logs/42").with(viewUser()))
                .andExpect(status().isOk());
        verify(audit).logExplicit(
                ACTOR_ID,
                "investigator",
                "view_audit_log_detail",
                "audit_log",
                "42",
                "success");
    }

    @Test
    void sensitiveReadFailsClosedWhenExplicitAuditWriteFails() throws Exception {
        doThrow(new IllegalStateException("audit store unavailable"))
                .when(audit)
                .logExplicit(
                        ACTOR_ID,
                        "investigator",
                        "view_audit_log_list",
                        "audit_log",
                        "returned=0; total=0",
                        "success");

        mvc.perform(get("/api/admin/audit-logs").with(viewUser()))
                .andExpect(status().isInternalServerError());
    }

    @Test
    void controllerAndServiceKeepTheSameDefenseInDepthExpressions() {
        assertAuthorization(AuditController.class, "list", "hasAuthority('audit_log:view')");
        assertAuthorization(AuditController.class, "summary", "hasAuthority('audit_log:view')");
        assertAuthorization(AuditController.class, "detail", "hasAuthority('audit_log:view')");
        assertAuthorization(
                AuditController.class,
                "verifyLocalReceipt",
                "hasAuthority('audit_log:view')");
        assertAuthorization(
                AuditController.class,
                "export",
                "hasAuthority('audit_log:view') and hasAuthority('audit_log:export')");

        assertAuthorization(AuditQueryService.class, "query", "hasAuthority('audit_log:view')");
        assertAuthorization(AuditQueryService.class, "summary", "hasAuthority('audit_log:view')");
        assertAuthorization(AuditQueryService.class, "detail", "hasAuthority('audit_log:view')");
        assertAuthorization(
                AuditQueryService.class,
                "export",
                "hasAuthority('audit_log:view') and hasAuthority('audit_log:export')");
    }

    private static void assertAuthorization(Class<?> type, String methodName, String expression) {
        Method method = Arrays.stream(type.getDeclaredMethods())
                .filter(candidate -> candidate.getName().equals(methodName))
                .findFirst()
                .orElseThrow();
        assertEquals(expression, method.getAnnotation(PreAuthorize.class).value());
    }

    private static UserRequestPostProcessor viewUser() {
        return user("investigator")
                .authorities(new SimpleGrantedAuthority(VIEW));
    }

    private static UserRequestPostProcessor viewAndExportUser() {
        return user("investigator")
                .authorities(
                        new SimpleGrantedAuthority(VIEW),
                        new SimpleGrantedAuthority(EXPORT));
    }

    @TestConfiguration(proxyBeanMethods = false)
    @EnableMethodSecurity
    static class MethodSecurityConfiguration {
    }
}
