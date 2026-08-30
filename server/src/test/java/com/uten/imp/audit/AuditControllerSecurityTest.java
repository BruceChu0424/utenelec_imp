package com.uten.imp.audit;

import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.config.WebMvcConfig;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ExportRateLimitInterceptor;
import com.uten.imp.security.JwtAuthFilter;
import com.uten.imp.security.LocalNetworkGuardFilter;
import com.uten.imp.security.RemoteAccessGuardFilter;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
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
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
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
                        JwtAuthFilter.class,
                        LocalNetworkGuardFilter.class,
                        RemoteAccessGuardFilter.class
                }))
@Import(AuditControllerSecurityTest.MethodSecurityConfiguration.class)
class AuditControllerSecurityTest {

    private static final String VIEW = "audit_log:view";
    private static final String EXPORT = "audit_log:export";
    private static final UUID ACTOR_ID = UUID.fromString("11111111-1111-1111-1111-111111111111");
    private static final UUID EMPLOYEE_ID = UUID.fromString("22222222-2222-2222-2222-222222222222");
    private static final UUID CLIENT_EVENT_ID =
            UUID.fromString("33333333-3333-3333-3333-333333333333");
    private static final String DEFAULT_FILTER_SCOPE =
            "；动作=全部；操作类型=全部；人员范围=全部；业务对象=全部；风险=全部；结果=全部"
                    + "；事件类型=全部；记录来源=全部；关键字=未使用；对象编号=未使用"
                    + "；操作关联编号=未使用；查询快照=全部；视图=仅人员活动";

    @Autowired
    private MockMvc mvc;

    @MockitoBean
    private AuditQueryService auditQuery;
    @MockitoBean
    private AuditRuntimeSettings runtimeSettings;
    @MockitoBean
    private XlsxExportService xlsxExport;
    @MockitoBean
    private WorkbookDownloadService workbookDownload;
    @MockitoBean
    private AuditService audit;
    @MockitoBean
    private SecurityContextCurrentUser currentUser;

    @BeforeEach
    void setUp() {
        when(auditQuery.query(
                any(AuditSearchCriteria.class),
                anyInt(),
                anyInt()))
                .thenReturn(new AuditPageResponse(List.of(), 1, 20, 0, 0, 0));
        when(auditQuery.summary(any(AuditSearchCriteria.class)))
                .thenReturn(new AuditSummary(0, 0, 0, 0, 0, List.of()));
        when(auditQuery.actors(any(), anyInt(), anyInt()))
                .thenReturn(new PageResponse<>(List.of(), 1, 20, 0, 0));
        when(auditQuery.export(
                any(AuditSearchCriteria.class),
                anyInt()))
                .thenReturn(new ExportPayload(List.of(), List.of(), 0));
        when(auditQuery.detail(42L)).thenReturn(org.mockito.Mockito.mock(AuditLogDetail.class));
        when(runtimeSettings.exportMaxRows()).thenReturn(1_000);
        when(xlsxExport.build(anyList(), anyList())).thenReturn(new byte[]{1});
        when(workbookDownload.protect(any(byte[].class), anyString())).thenReturn(new byte[]{9});
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
        mvc.perform(get("/api/admin/audit-logs")
                        .with(viewUser())
                        .param("actorId", ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.total").value(0));
        verify(audit).logExplicit(
                ACTOR_ID,
                "investigator",
                "view_audit_log_list",
                "audit_log",
                "人员=" + ACTOR_ID
                        + "；开始日期=2026-08-01；结束日期=2026-08-01"
                        + "；页码=1；本页条数=0；总条数=0"
                        + DEFAULT_FILTER_SCOPE,
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
    void listPassesEveryForensicFilterToTheQueryService() throws Exception {
        String requestId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
        mvc.perform(get("/api/admin/audit-logs")
                        .with(viewUser())
                        .param("action", "update")
                        .param("actorAccount", "alice")
                        .param("actorId", ACTOR_ID.toString())
                        .param("actorScope", "user")
                        .param("riskLevel", "high")
                        .param("eventCategory", "data_change")
                        .param("outcome", "success")
                        .param("keyword", "HP0001")
                        .param("targetType", "goods")
                        .param("targetId", "HP0001")
                        .param("eventSource", "database")
                        .param("requestId", requestId)
                        .param("operationKind", "write")
                        .param("snapshotId", "123")
                        .param("dateFrom", "2026-07-01")
                        .param("dateTo", "2026-07-31"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.snapshotId").value(0));

        ArgumentCaptor<AuditSearchCriteria> captor =
                ArgumentCaptor.forClass(AuditSearchCriteria.class);
        verify(auditQuery).query(captor.capture(), eq(1), eq(20));
        AuditSearchCriteria filters = captor.getValue();
        assertEquals("update", filters.action());
        assertEquals("alice", filters.actorAccount());
        assertEquals(ACTOR_ID, filters.actorId());
        assertEquals(true, filters.activityOnly());
        assertEquals("user", filters.actorScope());
        assertEquals("high", filters.riskLevel());
        assertEquals("data_change", filters.eventCategory());
        assertEquals("success", filters.outcome());
        assertEquals("HP0001", filters.keyword());
        assertEquals("goods", filters.targetType());
        assertEquals("HP0001", filters.targetId());
        assertEquals("database", filters.eventSource());
        assertEquals(requestId, filters.requestId());
        assertEquals("write", filters.operationKind());
        assertEquals(123L, filters.snapshotId());
        assertEquals(LocalDate.parse("2026-07-01"), filters.dateFrom());
        assertEquals(LocalDate.parse("2026-07-31"), filters.dateTo());
        ArgumentCaptor<String> scope = ArgumentCaptor.forClass(String.class);
        verify(audit).logExplicit(
                eq(ACTOR_ID), eq("investigator"), eq("view_audit_log_list"),
                eq("audit_log"), scope.capture(), eq("success"));
        assertTrue(scope.getValue().contains("操作类型=写操作"));
        assertTrue(scope.getValue().contains("业务对象=已筛选"));
        assertTrue(scope.getValue().contains("关键字=已使用"));
        assertTrue(scope.getValue().contains("操作关联编号=已使用"));
        assertFalse(scope.getValue().contains("HP0001"));
        assertFalse(scope.getValue().contains(requestId));
    }

    @Test
    void summaryAndExportPassTheSharedSnapshotScope() throws Exception {
        mvc.perform(get("/api/admin/audit-logs/summary")
                        .with(viewUser())
                        .param("actorScope", "system")
                        .param("actorId", ACTOR_ID.toString())
                        .param("dateFrom", "2026-07-01")
                        .param("dateTo", "2026-07-31")
                        .param("keyword", "goods")
                        .param("operationKind", "write")
                        .param("snapshotId", "321"))
                .andExpect(status().isOk());

        ArgumentCaptor<AuditSearchCriteria> summaryCaptor =
                ArgumentCaptor.forClass(AuditSearchCriteria.class);
        verify(auditQuery).summary(summaryCaptor.capture());
        assertEquals("system", summaryCaptor.getValue().actorScope());
        assertEquals("goods", summaryCaptor.getValue().keyword());
        assertEquals("write", summaryCaptor.getValue().operationKind());
        assertEquals(321L, summaryCaptor.getValue().snapshotId());
        assertEquals(null, summaryCaptor.getValue().riskLevel());
        assertEquals(null, summaryCaptor.getValue().outcome());

        clearInvocations(auditQuery);
        mvc.perform(post("/api/admin/audit-logs/export")
                        .with(viewAndExportUser())
                        .with(csrf())
                        .param("actorScope", "user")
                        .param("actorId", ACTOR_ID.toString())
                        .param("dateFrom", "2026-07-01")
                        .param("dateTo", "2026-07-31")
                        .param("targetType", "goods")
                        .param("eventSource", "database")
                        .param("snapshotId", "321")
                        .contentType(APPLICATION_JSON)
                        .content("{'password':'secret12'}"
                                .replace((char) 39, (char) 34)))
                .andExpect(status().isOk());

        ArgumentCaptor<AuditSearchCriteria> exportCaptor =
                ArgumentCaptor.forClass(AuditSearchCriteria.class);
        verify(auditQuery).export(exportCaptor.capture(), eq(1_000));
        assertEquals("user", exportCaptor.getValue().actorScope());
        assertEquals("goods", exportCaptor.getValue().targetType());
        assertEquals("database", exportCaptor.getValue().eventSource());
        assertEquals(321L, exportCaptor.getValue().snapshotId());
    }

    @Test
    void viewAndExportPermissionsCanExport() throws Exception {
        mvc.perform(post("/api/admin/audit-logs/export")
                        .with(viewAndExportUser())
                        .with(csrf())
                        .param("actorId", ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01")
                        .contentType(APPLICATION_JSON)
                        .content("""
                                {"password":"secret12"}
                                """))
                .andExpect(status().isOk())
                .andExpect(content().bytes(new byte[]{9}));

        verify(auditQuery).export(
                any(AuditSearchCriteria.class),
                eq(1_000));
        verify(audit).logExplicit(
                ACTOR_ID,
                "investigator",
                "export_audit_log",
                "audit_log",
                "导出条数=0；人员=" + ACTOR_ID
                        + "；开始日期=2026-08-01；结束日期=2026-08-01；风险=全部"
                        + DEFAULT_FILTER_SCOPE,
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
        mvc.perform(get("/api/admin/audit-logs/summary")
                        .with(viewUser())
                        .param("actorId", ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01"))
                .andExpect(status().isOk());
        verify(audit).logExplicit(
                ACTOR_ID,
                "investigator",
                "view_audit_log_summary",
                "audit_log",
                "人员=" + ACTOR_ID
                        + "；开始日期=2026-08-01；结束日期=2026-08-01"
                        + "；总条数=0；风险条数=0"
                        + DEFAULT_FILTER_SCOPE,
                "success");

        clearInvocations(audit);
        mvc.perform(get("/api/admin/audit-logs/42").with(viewUser()))
                .andExpect(status().isOk());
        verify(audit).logExplicit(
                ACTOR_ID,
                "investigator",
                "view_audit_log_detail",
                "audit_log",
                "审计日志编号=42；原操作关联编号=全部；原操作人编号=全部",
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
                        "人员=" + ACTOR_ID
                                + "；开始日期=2026-08-01；结束日期=2026-08-01"
                                + "；页码=1；本页条数=0；总条数=0"
                                + DEFAULT_FILTER_SCOPE,
                        "success");

        mvc.perform(get("/api/admin/audit-logs")
                        .with(viewUser())
                        .param("actorId", ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01"))
                .andExpect(status().isInternalServerError());
    }

    @Test
    void actorsPickerRequiresViewPermissionAndDoesNotWriteTypingAudit() throws Exception {
        mvc.perform(get("/api/admin/audit-logs/actors")
                        .with(user("ordinary")))
                .andExpect(status().isForbidden());
        verifyNoInteractions(auditQuery, audit);

        mvc.perform(get("/api/admin/audit-logs/actors")
                        .with(viewUser())
                        .param("keyword", "张")
                        .param("page", "2")
                        .param("size", "10"))
                .andExpect(status().isOk());
        verify(auditQuery).actors("张", 2, 10);
        verifyNoInteractions(audit);
    }

    @Test
    void malformedActorIdReturnsChineseBadRequestBeforeQuerying() throws Exception {
        mvc.perform(get("/api/admin/audit-logs")
                        .with(viewUser())
                        .param("actorId", "not-a-uuid")
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.message").value("人员编号 必须为标准 UUID"));
        verifyNoInteractions(auditQuery, audit);
    }

    @Test
    void anonymousInvestigationAuditNamesTheUnidentifiedAccessScope() throws Exception {
        mvc.perform(get("/api/admin/audit-logs/summary")
                        .with(viewUser())
                        .param("actorScope", "anonymous")
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-31"))
                .andExpect(status().isOk());

        verify(audit).logExplicit(
                eq(ACTOR_ID),
                eq("investigator"),
                eq("view_audit_log_summary"),
                eq("audit_log"),
                org.mockito.ArgumentMatchers.argThat(value ->
                        value.contains("人员=全部")
                                && value.contains("人员范围=未识别访问")),
                eq("success"));
    }

    @Test
    void invalidFilterEnumsReturnChineseBadRequestAcrossReadSummaryAndExport()
            throws Exception {
        mvc.perform(get("/api/admin/audit-logs")
                        .with(viewUser())
                        .param("actorId", ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01")
                        .param("riskLevel", "urgent"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.message")
                        .value("风险等级仅支持严重、高、中、低、有风险"));

        mvc.perform(get("/api/admin/audit-logs/summary")
                        .with(viewUser())
                        .param("actorId", ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01")
                        .param("eventCategory", "unknown"))
                .andExpect(status().isBadRequest());

        mvc.perform(post("/api/admin/audit-logs/export")
                        .with(viewAndExportUser())
                        .with(csrf())
                        .param("actorId", ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01")
                        .param("outcome", "maybe")
                        .contentType(APPLICATION_JSON)
                        .content("{\"password\":\"secret12\"}"))
                .andExpect(status().isBadRequest());

        mvc.perform(get("/api/admin/audit-logs")
                        .with(viewUser())
                        .param("actorId", ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01")
                        .param("eventSource", "scheduler"))
                .andExpect(status().isBadRequest());
    }

    @Test
    void controllerAndServiceKeepTheSameDefenseInDepthExpressions() {
        assertAuthorization(AuditController.class, "list", "hasAuthority('audit_log:view')");
        assertAuthorization(AuditController.class, "summary", "hasAuthority('audit_log:view')");
        assertAuthorization(AuditController.class, "actors", "hasAuthority('audit_log:view')");
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
        assertAuthorization(AuditQueryService.class, "actors", "hasAuthority('audit_log:view')");
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
