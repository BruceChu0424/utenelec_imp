package com.uten.imp.features.admin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.AuthSessionService;
import com.uten.imp.features.auth.StepUpService;
import com.uten.imp.features.auth.model.UserAccountRepository;
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
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.test.util.AopTestUtils;

import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Exercises the real controller proxy and HTTP interceptor chain; token storage is the only fake. */
class AiPermissionGrantControllerSecurityTest {
    @Configuration
    @EnableMethodSecurity
    @Import(StepUpAdvisorConfig.class)
    static class Config {
        @Bean AiPermissionGrantService business() { return mock(AiPermissionGrantService.class); }
        @Bean AuthSessionService sessions() { return mock(AuthSessionService.class); }
        @Bean StepUpService stepUp(AuthSessionService sessions) {
            return new StepUpService(mock(UserAccountRepository.class), mock(PasswordEncoder.class), sessions,
                    mock(SystemSettingsService.class), mock(NamedParameterJdbcTemplate.class),
                    mock(AuditService.class), mock(SecurityContextCurrentUser.class));
        }
        @Bean AiPermissionGrantController controller(AiPermissionGrantService business) {
            return new AiPermissionGrantController(business);
        }
    }

    private AnnotationConfigApplicationContext context;
    private MockMvc mvc;
    private AiPermissionGrantService business;
    private AuthSessionService sessions;
    private final UUID actorId = UUID.randomUUID(), sessionId = UUID.randomUUID();
    private static final String URL = "/api/ai/chat/permission-grants/confirm";

    @BeforeEach void setUp() {
        context = new AnnotationConfigApplicationContext(Config.class);
        business = AopTestUtils.getUltimateTargetObject(context.getBean(AiPermissionGrantService.class));
        sessions = context.getBean(AuthSessionService.class);
        mvc = MockMvcBuilders.standaloneSetup(context.getBean(AiPermissionGrantController.class))
                .setControllerAdvice(new GlobalExceptionHandler())
                .addFilters(new ImpersonationWriteGuardFilter(new ObjectMapper(), mock(AuditService.class))).build();
    }
    @AfterEach void cleanup() { SecurityContextHolder.clearContext(); if (context != null) context.close(); }
    private AuthUser staff(boolean superAdmin, UUID impersonatedBy) {
        return new AuthUser(actorId, UUID.randomUUID(), "test-admin", Set.of("ai:use", "authorization:manage"),
                false, true, superAdmin, false, impersonatedBy, sessionId);
    }
    private void login(AuthUser actor) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
    }
    @Test void superAdminWithoutStepUpIsRejectedBeforeBusinessWrite() throws Exception {
        login(staff(true, null));
        mvc.perform(post(URL).contentType(MediaType.APPLICATION_JSON).content("{\"proposalId\":\"signed\"}"))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("REAUTH_REQUIRED"));
        verifyNoInteractions(business, sessions);
    }
    @Test void ordinaryStaffCannotUseStrayAuthorizationAuthority() throws Exception {
        login(staff(false, null));
        mvc.perform(post(URL).header(StepUpInterceptor.HEADER, "unused-token")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"proposalId\":\"signed\"}"))
                .andExpect(status().isForbidden());
        verifyNoInteractions(business, sessions);
    }
    @Test void visitorCannotConsumeAConfirmation() throws Exception {
        login(AuthUser.visitor(UUID.randomUUID(), "visitor", "V-1", Set.of("ai:use", "authorization:manage")));
        mvc.perform(post(URL).header(StepUpInterceptor.HEADER, "unused-token")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"proposalId\":\"signed\"}"))
                .andExpect(status().isForbidden());
        verifyNoInteractions(business, sessions);
    }
    @Test void impersonatedSuperAdminIsReadOnlyBeforeTokenConsumption() throws Exception {
        login(staff(true, UUID.randomUUID()));
        mvc.perform(post(URL).header(StepUpInterceptor.HEADER, "unused-token")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"proposalId\":\"signed\"}"))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("IMPERSONATION_READ_ONLY"));
        verifyNoInteractions(business, sessions);
    }
    @Test void successfulTokenIsConsumedBeforeBusinessAndReplayCannotWriteAgain() throws Exception {
        login(staff(true, null));
        when(sessions.consumeStepUp(sessionId, actorId, HashUtil.sha256("one-time-test-token"))).thenReturn(true, false);
        when(business.confirm("signed")).thenReturn(Map.of("status", "GRANTED", "reply", "已授权"));
        mvc.perform(post(URL).header(StepUpInterceptor.HEADER, "one-time-test-token")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"proposalId\":\"signed\"}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("GRANTED"));
        mvc.perform(post(URL).header(StepUpInterceptor.HEADER, "one-time-test-token")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"proposalId\":\"signed\"}"))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("REAUTH_REQUIRED"));
        var order = inOrder(sessions, business);
        order.verify(sessions).consumeStepUp(sessionId, actorId, HashUtil.sha256("one-time-test-token"));
        order.verify(business).confirm("signed");
        verify(business, times(1)).confirm(any());
    }
    @Test void invalidPayloadDoesNotConsumeAValidToken() throws Exception {
        login(staff(true, null));
        mvc.perform(post(URL).header(StepUpInterceptor.HEADER, "unused-token")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"proposalId\":\"\"}"))
                .andExpect(status().isUnprocessableEntity());
        verifyNoInteractions(business, sessions);
    }
}
