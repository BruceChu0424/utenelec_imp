package com.uten.imp.features.admin.platformsetting;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditRequestContextFilter;
import com.uten.imp.audit.AuditService;
import com.uten.imp.audit.UserOperationAuditInterceptor;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.SecurityConfig;
import com.uten.imp.config.WebMvcConfig;
import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.features.auth.StepUpService;
import com.uten.imp.security.*;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.boot.security.autoconfigure.UserDetailsServiceAutoConfiguration;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.FilterType;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import java.util.Optional;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@com.uten.imp.testsupport.WithReportReadScopeMvc
@WebMvcTest(controllers = {PlatformSettingsController.class, PublicPlatformBrandingController.class},
        properties = {"uten.security.cors-allowed-origins=https://erp.test", "uten.security.require-https=true",
                "uten.deployment.local-allowed-cidrs=127.0.0.0/8,::1/128"},
        excludeAutoConfiguration = UserDetailsServiceAutoConfiguration.class,
        excludeFilters = @ComponentScan.Filter(type = FilterType.ASSIGNABLE_TYPE, classes = {
                WebMvcConfig.class, UserOperationAuditInterceptor.class, ExportRateLimitInterceptor.class,
                JwtAuthFilter.class, LocalNetworkGuardFilter.class, RemoteAccessGuardFilter.class,
                ImpersonationWriteGuardFilter.class, AuditRequestContextFilter.class}))
@Import({SecurityConfig.class, SecurityProperties.class, StepUpAdvisorConfig.class,
        com.uten.imp.support.RemoteIngressSecurityTestConfiguration.class})
class PlatformSettingsControllerSecurityTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;
    @MockitoBean PlatformSettingsService service;
    @MockitoBean AuditService audit;
    @MockitoBean StepUpService stepUp;
    @MockitoBean JwtAuthFilter jwt;
    @MockitoBean LocalNetworkGuardFilter localNetwork;
    @MockitoBean RemoteAccessGuardFilter remote;
    @MockitoBean ImpersonationWriteGuardFilter impersonation;
    @MockitoBean AuditRequestContextFilter auditContext;

    @BeforeEach void configure() throws Exception {
        for (jakarta.servlet.Filter filter : new jakarta.servlet.Filter[]{jwt, localNetwork, remote, impersonation, auditContext})
            doAnswer(call -> { ((FilterChain) call.getArgument(2)).doFilter(call.getArgument(0), call.getArgument(1)); return null; })
                    .when(filter).doFilter(any(ServletRequest.class), any(ServletResponse.class), any(FilterChain.class));
        when(service.current()).thenReturn(PlatformSettingsServiceTest.dto(4, false));
        when(service.logo(any())).thenReturn(Optional.empty());
        when(service.update(any())).thenReturn(PlatformSettingsServiceTest.dto(5, false));
        doAnswer(call -> {
            if (!"valid-step-up".equals(call.getArgument(1))) throw new ApiException(ErrorCode.REAUTH_REQUIRED);
            return null;
        }).when(stepUp).consume(any(), any());
    }

    @Test void anonymousBrandingHasOnlyPublicProjection() throws Exception {
        mvc.perform(get("https://erp.test/api/platform/branding").secure(true)).andExpect(status().isOk())
                .andExpect(jsonPath("companyName").value("公司"))
                .andExpect(jsonPath("companyAliases").value(""))
                .andExpect(jsonPath("version").value(4)).andExpect(jsonPath("hasLogo").value(false))
                .andExpect(jsonPath("logoBase64").doesNotExist()).andExpect(jsonPath("logo_png").doesNotExist())
                .andExpect(jsonPath("updatedBy").doesNotExist()).andExpect(jsonPath("attachmentStorageBackend").doesNotExist());
    }

    @Test void anonymousWriteAdminAndSimilarPathsAreNotPublic() throws Exception {
        mvc.perform(get("https://erp.test/api/admin/platform-settings").secure(true)).andExpect(status().isUnauthorized());
        mvc.perform(get("https://erp.test/api/admin/platform-settings/status").secure(true)).andExpect(status().isUnauthorized());
        mvc.perform(put("https://erp.test/api/platform/branding").secure(true).contentType("application/json").content("{}"))
                .andExpect(status().isUnauthorized());
        mvc.perform(get("https://erp.test/api/platform/branding/private").secure(true)).andExpect(status().isUnauthorized());
    }

    @Test void ordinaryStaffWithManageAuthorityStillCannotReadAdminSettings() throws Exception {
        mvc.perform(get("https://erp.test/api/admin/platform-settings").secure(true).with(user(PlatformSettingsServiceTest.actor(false, null))))
                .andExpect(status().isForbidden());
        verify(service, never()).current();
    }

    @Test void adminReadWorksAndSaveRequiresConsumedStepUp() throws Exception {
        var admin = PlatformSettingsServiceTest.actor(true, null);
        mvc.perform(get("https://erp.test/api/admin/platform-settings").secure(true).with(user(admin))).andExpect(status().isOk());
        String body = json.writeValueAsString(PlatformSettingsServiceTest.request(4, null, false));
        mvc.perform(put("https://erp.test/api/admin/platform-settings").secure(true).with(user(admin))
                        .with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf().asHeader())
                        .contentType("application/json").content(body))
                .andExpect(status().isForbidden()).andExpect(jsonPath("code").value("REAUTH_REQUIRED"));
        verify(service, never()).update(any());
        mvc.perform(put("https://erp.test/api/admin/platform-settings").secure(true).with(user(admin))
                        .with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf().asHeader())
                        .header(StepUpInterceptor.HEADER, "valid-step-up")
                        .contentType("application/json").content(body))
                .andExpect(status().isOk()).andExpect(jsonPath("version").value(5));
        verify(service).update(any());
    }

    @Test void unauthorizedSaveCannotConsumeStepUp() throws Exception {
        mvc.perform(put("https://erp.test/api/admin/platform-settings").secure(true).with(user(PlatformSettingsServiceTest.actor(false, null)))
                        .with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf().asHeader())
                        .header(StepUpInterceptor.HEADER, "valid-step-up").contentType("application/json")
                        .content(json.writeValueAsString(PlatformSettingsServiceTest.request(4, null, false))))
                .andExpect(status().isForbidden());
        verifyNoInteractions(stepUp); verify(service, never()).update(any());
    }

    @Test void logoHasNoStoreAndNosniffAndOldVersionIsNotServed() throws Exception {
        when(service.logo(4)).thenReturn(Optional.of(new byte[]{1, 2, 3}));
        mvc.perform(get("https://erp.test/api/platform/branding/logo?v=4").secure(true)).andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith("image/png"))
                .andExpect(header().string("X-Content-Type-Options", "nosniff"))
                .andExpect(header().string("Cache-Control", "no-store"));
        mvc.perform(get("https://erp.test/api/platform/branding/logo?v=3").secure(true)).andExpect(status().isNotFound());
    }
}
