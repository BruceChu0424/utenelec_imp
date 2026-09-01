package com.uten.imp.audit;

import com.uten.imp.config.WebMvcConfig;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ExportRateLimitInterceptor;
import com.uten.imp.security.JwtAuthFilter;
import com.uten.imp.security.LocalNetworkGuardFilter;
import com.uten.imp.security.RemoteAccessGuardFilter;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.FilterType;
import org.springframework.context.annotation.Import;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(
        controllers = AuditSessionController.class,
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
@Import(AuditSessionControllerSecurityTest.MethodSecurityConfiguration.class)
class AuditSessionControllerSecurityTest {

    private static final String VIEW = "audit_log:view";
    private static final UUID INVESTIGATOR_ID =
            UUID.fromString("11111111-1111-1111-1111-111111111111");
    private static final UUID SELECTED_ACTOR_ID =
            UUID.fromString("22222222-2222-2222-2222-222222222222");
    private static final UUID SESSION_ID =
            UUID.fromString("33333333-3333-3333-3333-333333333333");
    private static final long SNAPSHOT_ID = 99L;

    @Autowired
    private MockMvc mvc;

    @MockitoBean
    private AuditSessionQueryService queryService;

    @MockitoBean
    private AuditService auditService;

    @MockitoBean
    private SecurityContextCurrentUser currentUser;

    private AuditSessionRow row;

    @BeforeEach
    void setUp() {
        row = sessionRow();
        when(queryService.sessions(
                eq(SELECTED_ACTOR_ID),
                eq(java.time.LocalDate.parse("2026-08-01")),
                eq(java.time.LocalDate.parse("2026-08-01")),
                eq(1),
                eq(20),
                eq(null)))
                .thenReturn(new AuditSessionPageResponse(
                        List.of(row), 1, 20, 1, 1, SNAPSHOT_ID));
        when(queryService.session(SESSION_ID, SNAPSHOT_ID)).thenReturn(row);
        when(queryService.events(
                SESSION_ID, null, null, 20, SNAPSHOT_ID))
                .thenReturn(new AuditSessionEventPageResponse(
                        List.of(), 20, null, null, false, SNAPSHOT_ID));
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(
                INVESTIGATOR_ID,
                UUID.randomUUID(),
                "investigator",
                Set.of(),
                Set.of(VIEW),
                false,
                true,
                false)));
    }

    @Test
    void ordinaryUserCannotReadAnySessionEvidence() throws Exception {
        mvc.perform(get("/api/admin/audit-sessions")
                        .with(user("ordinary"))
                        .param("actorId", SELECTED_ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01"))
                .andExpect(status().isForbidden());
        mvc.perform(get("/api/admin/audit-sessions/{sessionId}", SESSION_ID)
                        .with(user("ordinary")))
                .andExpect(status().isForbidden());
        mvc.perform(get("/api/admin/audit-sessions/{sessionId}/events", SESSION_ID)
                        .with(user("ordinary")))
                .andExpect(status().isForbidden());

        verifyNoInteractions(queryService, auditService);
    }

    @Test
    void authorizedListReadWritesAReadableChineseInvestigationReceipt()
            throws Exception {
        mvc.perform(get("/api/admin/audit-sessions")
                        .with(viewUser())
                        .param("actorId", SELECTED_ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.total").value(1))
                .andExpect(jsonPath("$.snapshotAuditId").value(SNAPSHOT_ID));

        verify(auditService).logSuccessfulAuditView(
                eq(INVESTIGATOR_ID),
                eq("investigator"),
                eq("view_audit_session_list"),
                eq("audit_session"),
                argThat(value -> value.contains("人员=" + SELECTED_ACTOR_ID)
                        && value.contains("开始日期=2026-08-01")
                        && value.contains("查询快照=" + SNAPSHOT_ID)),
                eq("张三（zhangsan） · 2026-08-01（北京时间） · 第 1 页（共 1 次登录）"));
    }

    @Test
    void detailAndTimelineDeepLinksAuditTheExactSessionAndSnapshot()
            throws Exception {
        mvc.perform(get("/api/admin/audit-sessions/{sessionId}", SESSION_ID)
                        .with(viewUser())
                        .param("snapshotAuditId", Long.toString(SNAPSHOT_ID)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.sessionId").value(SESSION_ID.toString()));
        verify(auditService).logSuccessfulAuditView(
                eq(INVESTIGATOR_ID),
                eq("investigator"),
                eq("view_audit_session_detail"),
                eq("audit_session"),
                argThat(value -> value.contains("登录会话编号=" + SESSION_ID)
                        && value.contains("查询快照=" + SNAPSHOT_ID)),
                eq("张三（zhangsan） · 登录会话 33333333… · "
                        + "2026-08-01 09:00（北京时间）"));

        clearInvocations(auditService);
        mvc.perform(get("/api/admin/audit-sessions/{sessionId}/events", SESSION_ID)
                        .with(viewUser())
                        .param("snapshotAuditId", Long.toString(SNAPSHOT_ID)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.hasMore").value(false));
        verify(auditService).logSuccessfulAuditView(
                eq(INVESTIGATOR_ID),
                eq("investigator"),
                eq("view_audit_session_events"),
                eq("audit_session"),
                argThat(value -> value.contains("登录会话编号=" + SESSION_ID)
                        && value.contains("本次条数=0")
                        && value.contains("查询快照=" + SNAPSHOT_ID)),
                eq("登录会话 33333333… · 从最新操作查看 · 本次 0 条"));
    }

    @Test
    void verifiedRealAdministratorWinsDuringImpersonation() throws Exception {
        UUID realAdministratorId =
                UUID.fromString("44444444-4444-4444-4444-444444444444");
        mvc.perform(get("/api/admin/audit-sessions")
                        .with(viewUser())
                        .requestAttr(
                                AuditRequestContext.VERIFIED_ACTOR_ATTRIBUTE,
                                new AuditRequestContext.VerifiedActor(
                                        realAdministratorId, "real-admin"))
                        .param("actorId", SELECTED_ACTOR_ID.toString())
                        .param("dateFrom", "2026-08-01")
                        .param("dateTo", "2026-08-01"))
                .andExpect(status().isOk());

        verify(auditService).logSuccessfulAuditView(
                eq(realAdministratorId),
                eq("real-admin"),
                eq("view_audit_session_list"),
                eq("audit_session"),
                org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void malformedSessionUuidIsRejectedBeforeQueryOrAudit() throws Exception {
        mvc.perform(get("/api/admin/audit-sessions/not-a-uuid")
                        .with(viewUser()))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.message")
                        .value("登录会话编号必须为标准 UUID"));

        verifyNoInteractions(queryService, auditService);
    }

    private org.springframework.security.test.web.servlet.request
            .SecurityMockMvcRequestPostProcessors.UserRequestPostProcessor viewUser() {
        return user("investigator")
                .authorities(new SimpleGrantedAuthority(VIEW));
    }

    private AuditSessionRow sessionRow() {
        OffsetDateTime loginAt = OffsetDateTime.parse("2026-08-01T09:00:00+08:00");
        return new AuditSessionRow(
                SESSION_ID,
                SELECTED_ACTOR_ID,
                "zhangsan",
                "张三（zhangsan）",
                "销售部",
                "业务员",
                "login",
                "员工登录",
                loginAt,
                loginAt,
                loginAt.plusMinutes(30),
                null,
                "no_logout_record",
                "未记录退出",
                3,
                2,
                3,
                0,
                0,
                null,
                "Chrome 浏览器",
                "Windows",
                "127.0.0.1",
                null,
                null,
                "no_record",
                "未记录刷新凭证",
                false,
                SNAPSHOT_ID);
    }

    @TestConfiguration(proxyBeanMethods = false)
    @EnableMethodSecurity
    static class MethodSecurityConfiguration {
    }
}
