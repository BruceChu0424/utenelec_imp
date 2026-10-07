package com.uten.imp.features.ai.usage;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.AuthSessionService;
import com.uten.imp.features.auth.StepUpService;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.*;
import org.junit.jupiter.api.*;
import org.springframework.context.annotation.*;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.test.util.AopTestUtils;
import java.util.Set;
import java.util.UUID;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class AiUsageAuditControllerSecurityTest {
    @Configuration @EnableMethodSecurity @Import(StepUpAdvisorConfig.class)
    static class Config {
        @Bean AiUsageAuditService usage() { return mock(AiUsageAuditService.class); }
        @Bean AiProviderBillingService billing() { return mock(AiProviderBillingService.class); }
        @Bean AiUsageDashboardService dashboard() { return mock(AiUsageDashboardService.class); }
        @Bean AiUsageAdminAccess access() { return new AiUsageAdminAccess(new SecurityContextCurrentUser()); }
        @Bean AuthSessionService sessions() { return mock(AuthSessionService.class); }
        @Bean StepUpService stepUp(AuthSessionService sessions) {
            return new StepUpService(mock(UserAccountRepository.class), mock(PasswordEncoder.class), sessions,
                    mock(SystemSettingsService.class), mock(NamedParameterJdbcTemplate.class), mock(AuditService.class), mock(SecurityContextCurrentUser.class));
        }
        @Bean AiUsageAuditController controller(AiUsageAdminAccess access, AiUsageAuditService usage,
                                               AiProviderBillingService billing, AiUsageDashboardService dashboard) {
            return new AiUsageAuditController(access, usage, billing, dashboard);
        }
    }
    AnnotationConfigApplicationContext context;
    MockMvc mvc;
    AiProviderBillingService billing;
    AiUsageAuditService usage;
    AiUsageDashboardService dashboard;
    AuthSessionService sessions;
    UUID actorId = UUID.randomUUID(), sessionId = UUID.randomUUID(), providerId = UUID.randomUUID();
    @BeforeEach void setup() {
        context = new AnnotationConfigApplicationContext(Config.class);
        billing = AopTestUtils.getUltimateTargetObject(context.getBean(AiProviderBillingService.class));
        usage = AopTestUtils.getUltimateTargetObject(context.getBean(AiUsageAuditService.class));
        dashboard = AopTestUtils.getUltimateTargetObject(context.getBean(AiUsageDashboardService.class));
        sessions = context.getBean(AuthSessionService.class);
        mvc = MockMvcBuilders.standaloneSetup(context.getBean(AiUsageAuditController.class)).setControllerAdvice(new GlobalExceptionHandler())
                .addFilters(new ImpersonationWriteGuardFilter(new ObjectMapper(), mock(AuditService.class))).build();
    }
    @AfterEach void close() { SecurityContextHolder.clearContext(); if (context != null) context.close(); }
    private void login(boolean superAdmin, UUID impersonatedBy) {
        var actor = new AuthUser(actorId, UUID.randomUUID(), "admin", Set.of("authorization:manage"), false, true, superAdmin, false, impersonatedBy, sessionId);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
    }
    @Test void ordinaryStaffCannotReadOtherEmployeesOrPricesEvenWithManageAuthority() throws Exception {
        login(false, null);
        mvc.perform(get("/api/admin/ai/usage-audit")).andExpect(status().isForbidden());
        mvc.perform(get("/api/admin/ai/providers/" + providerId + "/billing")).andExpect(status().isForbidden());
        verifyNoInteractions(usage, billing);
    }
    @Test void impersonationCannotReadCrossEmployeeQuestions() throws Exception {
        login(true, UUID.randomUUID());
        mvc.perform(get("/api/admin/ai/usage-audit")).andExpect(status().isForbidden());
        verifyNoInteractions(usage, billing);
    }
    @Test void superAdminStillNeedsStepUpBeforeSavingPrices() throws Exception {
        login(true, null);
        mvc.perform(put("/api/admin/ai/providers/" + providerId + "/billing").contentType(MediaType.APPLICATION_JSON)
                .content("{\"version\":0,\"billingMode\":\"UNKNOWN\"}"))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("REAUTH_REQUIRED"));
        verifyNoInteractions(billing, sessions);
    }
    @Test void aValidStepUpIsConsumedBeforeTheSingleConfigurationWrite() throws Exception {
        login(true, null);
        when(sessions.consumeStepUp(sessionId, actorId, HashUtil.sha256("one-use-token"))).thenReturn(true, false);
        var request = put("/api/admin/ai/providers/" + providerId + "/billing").header(StepUpInterceptor.HEADER, "one-use-token")
                .contentType(MediaType.APPLICATION_JSON).content("{\"version\":0,\"billingMode\":\"UNKNOWN\"}");
        mvc.perform(request).andExpect(status().isOk());
        mvc.perform(request).andExpect(status().isForbidden());
        verify(billing, times(1)).save(eq(providerId), any());
    }

    // ------------------------------------------------ ADR-164 用量看板三端点
    @Test void ordinaryStaffCannotOpenTheUsageDashboardEvenWithManageAuthority() throws Exception {
        login(false, null);
        mvc.perform(get("/api/admin/ai/usage-dashboard")).andExpect(status().isForbidden());
        mvc.perform(get("/api/admin/ai/usage-people/" + actorId)).andExpect(status().isForbidden());
        mvc.perform(put("/api/admin/ai/usage-people/" + actorId + "/limits").contentType(MediaType.APPLICATION_JSON)
                .content("{\"disabled\":true}")).andExpect(status().isForbidden());
        verifyNoInteractions(usage, billing, dashboard);
    }
    @Test void impersonationCannotReadTheUsageDashboardOrSaveLimits() throws Exception {
        login(true, UUID.randomUUID());
        mvc.perform(get("/api/admin/ai/usage-dashboard")).andExpect(status().isForbidden());
        mvc.perform(get("/api/admin/ai/usage-people/" + actorId)).andExpect(status().isForbidden());
        mvc.perform(put("/api/admin/ai/usage-people/" + actorId + "/limits").contentType(MediaType.APPLICATION_JSON)
                .content("{\"disabled\":true}")).andExpect(status().isForbidden());
        verifyNoInteractions(usage, billing, dashboard);
    }
    @Test void superAdminStillNeedsStepUpBeforeSavingPersonalLimits() throws Exception {
        login(true, null);
        mvc.perform(put("/api/admin/ai/usage-people/" + actorId + "/limits").contentType(MediaType.APPLICATION_JSON)
                .content("{\"disabled\":true,\"dailyTokenLimit\":500000,\"dailyJobLimit\":20}"))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("REAUTH_REQUIRED"));
        verifyNoInteractions(dashboard, sessions);
    }
    @Test void aValidStepUpIsConsumedBeforeTheSingleLimitsWrite() throws Exception {
        login(true, null);
        when(sessions.consumeStepUp(sessionId, actorId, HashUtil.sha256("limits-token"))).thenReturn(true, false);
        when(dashboard.saveLimits(eq(actorId), any(), any()))
                .thenReturn(new AiUserLimitsService.Limits(actorId, true, null, null, 0));
        var request = put("/api/admin/ai/usage-people/" + actorId + "/limits").header(StepUpInterceptor.HEADER, "limits-token")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"disabled\":true,\"dailyTokenLimit\":500000,\"dailyJobLimit\":20}");
        mvc.perform(request).andExpect(status().isOk());
        mvc.perform(request).andExpect(status().isForbidden());
        verify(dashboard, times(1)).saveLimits(eq(actorId), any(), any());
    }
}
