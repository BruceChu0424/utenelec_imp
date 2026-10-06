package com.uten.imp.features.org.employee.reconcile;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.AuthSessionService;
import com.uten.imp.features.auth.StepUpService;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.ApplyCounts;
import com.uten.imp.features.org.employee.reconcile.dto.ReconcilePlanViews.ApplyResult;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ImpersonationWriteGuardFilter;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.StepUpAdvisorConfig;
import com.uten.imp.security.StepUpInterceptor;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 真实控制器代理 + HTTP 拦截器链的安全测试（照 AiPermissionGrantControllerSecurityTest 的模式）。
 * 未登录在真实链路由 JwtAuthFilter 先行 401；本测试只有方法安全与 StepUp 拦截器，
 * 未登录请求到达 @PreAuthorize 后被拒为 403（同样进不了业务）。
 */
class EmployeeReconcileControllerSecurityTest {
    @Configuration
    @EnableMethodSecurity
    @Import(StepUpAdvisorConfig.class)
    static class Config {
        @Bean ReconcilePlanService plans() { return mock(ReconcilePlanService.class); }
        @Bean ReconcilePlanQueryService queries() { return mock(ReconcilePlanQueryService.class); }
        @Bean ReconcileApplyService applies() { return mock(ReconcileApplyService.class); }
        @Bean AuditService auditService() { return mock(AuditService.class); }
        @Bean com.uten.imp.audit.AuditDetailViewRecorder viewAudit(AuditService auditService) {
            return new com.uten.imp.audit.AuditDetailViewRecorder(auditService, new SecurityContextCurrentUser());
        }
        @Bean AuthSessionService sessions() { return mock(AuthSessionService.class); }
        @Bean StepUpService stepUp(AuthSessionService sessions) {
            return new StepUpService(mock(UserAccountRepository.class), mock(PasswordEncoder.class), sessions,
                    mock(SystemSettingsService.class), mock(NamedParameterJdbcTemplate.class),
                    mock(AuditService.class), mock(SecurityContextCurrentUser.class));
        }
        @Bean ReconcilePlanController controller(ReconcilePlanService plans, ReconcilePlanQueryService queries,
                                                 ReconcileApplyService applies,
                                                 com.uten.imp.audit.AuditDetailViewRecorder viewAudit) {
            return new ReconcilePlanController(plans, queries, applies, new SecurityContextCurrentUser(), viewAudit);
        }
    }

    private AnnotationConfigApplicationContext context;
    private MockMvc mvc;
    private ReconcilePlanService plans;
    private ReconcilePlanQueryService queries;
    private ReconcileApplyService applies;
    private AuthSessionService sessions;
    private final UUID actorId = UUID.randomUUID(), sessionId = UUID.randomUUID();
    private final UUID planId = UUID.randomUUID();
    private static final UUID EMPLOYEE = UUID.fromString("7d3c1f0e-4a8b-4c55-9d2e-1b2c3d4e5f61");

    @BeforeEach
    void setUp() {
        context = new AnnotationConfigApplicationContext(Config.class);
        plans = AopTestUtils.getUltimateTargetObject(context.getBean(ReconcilePlanService.class));
        queries = AopTestUtils.getUltimateTargetObject(context.getBean(ReconcilePlanQueryService.class));
        applies = AopTestUtils.getUltimateTargetObject(context.getBean(ReconcileApplyService.class));
        sessions = context.getBean(AuthSessionService.class);
        mvc = MockMvcBuilders.standaloneSetup(context.getBean(ReconcilePlanController.class))
                .setControllerAdvice(new GlobalExceptionHandler())
                .addFilters(new ImpersonationWriteGuardFilter(new ObjectMapper(), mock(AuditService.class))).build();
    }

    @AfterEach
    void cleanup() {
        SecurityContextHolder.clearContext();
        if (context != null) {
            context.close();
        }
    }

    private AuthUser staff(Set<String> permissions) {
        return new AuthUser(actorId, UUID.randomUUID(), "hr-test", permissions,
                false, true, false, false, null, sessionId);
    }

    private void login(AuthUser actor) {
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
    }

    @Test
    void unauthenticatedRequestIsRejectedWithUnauthorized() throws Exception {
        mvc.perform(post("/api/org/employee-reconcile/plans/id-repair")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"employeeIds\":[\"" + EMPLOYEE + "\"]}"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.code").value("UNAUTHORIZED"));
        verifyNoInteractions(plans, queries, applies);
    }

    @Test
    void viewerWithoutPiiEditCannotCreateAnIdRepairPlan() throws Exception {
        login(staff(Set.of("employee:view")));
        mvc.perform(post("/api/org/employee-reconcile/plans/id-repair")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"employeeIds\":[\"" + EMPLOYEE + "\"]}"))
                .andExpect(status().isForbidden());
        verifyNoInteractions(plans);
    }

    @Test
    void piiEditAloneCannotCrossTheClassLevelViewRequirement() throws Exception {
        login(staff(Set.of("employee:pii:edit")));
        mvc.perform(post("/api/org/employee-reconcile/plans/id-repair")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"employeeIds\":[\"" + EMPLOYEE + "\"]}"))
                .andExpect(status().isForbidden());
        verifyNoInteractions(plans);
    }

    @Test
    void plansListingRequiresEmployeeEdit() throws Exception {
        login(staff(Set.of("employee:view")));
        mvc.perform(get("/api/org/employee-reconcile/plans")).andExpect(status().isForbidden());
        verifyNoInteractions(queries);
    }

    @Test
    void applyWithoutAStepUpReceiptIsRejectedWithReauthRequired() throws Exception {
        login(staff(Set.of("employee:view", "employee:pii:edit")));
        mvc.perform(post("/api/org/employee-reconcile/plans/" + planId + "/apply")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(applyBody()))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("REAUTH_REQUIRED"));
        verifyNoInteractions(applies);
    }

    @Test
    void aValidStepUpReceiptReachesTheBusinessExactlyOnce() throws Exception {
        login(staff(Set.of("employee:view", "employee:pii:edit")));
        when(sessions.consumeStepUp(eq(sessionId), eq(actorId), eq(HashUtil.sha256("one-time-reconcile"))))
                .thenReturn(true, false);
        when(applies.apply(any(), eq(planId), any())).thenReturn(new ApplyResult(
                4, 1, new ApplyCounts(0, 0, 0), List.of(), "本轮没有可执行的更正"));

        mvc.perform(post("/api/org/employee-reconcile/plans/" + planId + "/apply")
                        .header(StepUpInterceptor.HEADER, "one-time-reconcile")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(applyBody()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.summary").value("本轮没有可执行的更正"));
        mvc.perform(post("/api/org/employee-reconcile/plans/" + planId + "/apply")
                        .header(StepUpInterceptor.HEADER, "one-time-reconcile")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(applyBody()))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("REAUTH_REQUIRED"));
        verify(applies, times(1)).apply(any(), eq(planId), any());
    }

    @Test
    void aViewerMayReadASinglePlanTheyCanSee() throws Exception {
        login(staff(Set.of("employee:view")));
        mvc.perform(get("/api/org/employee-reconcile/plans/" + planId))
                .andExpect(status().isOk());
        verify(queries).view(eq(planId), any());
    }

    private static String applyBody() {
        return "{\"planVersion\":3,\"requestId\":\"req-1\","
                + "\"rows\":[{\"rowNo\":1,\"items\":[{\"itemNo\":1}]}]}";
    }
}
