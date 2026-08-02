package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.audit.AuditRequestContextFilter;
import com.uten.imp.audit.AuditService;
import com.uten.imp.audit.UserOperationAuditInterceptor;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.SecurityConfig;
import com.uten.imp.config.WebMvcConfig;
import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.features.auth.model.RefreshToken;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.visitor.VisitorAccountRepository;
import com.uten.imp.security.ExportRateLimitInterceptor;
import com.uten.imp.security.JwtAuthFilter;
import com.uten.imp.security.JwtService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.StaffAuthorityResolver;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.FilterType;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(
        controllers = {
                AuthController.class,
                AuthLogoutSecurityProbeController.class
        },
        properties = {
                "uten.security.cors-allowed-origins=https://trusted.example.test",
                "uten.security.require-https=false"
        },
        excludeFilters = @ComponentScan.Filter(
                type = FilterType.ASSIGNABLE_TYPE,
                classes = {
                        WebMvcConfig.class,
                        AuditRequestContextFilter.class,
                        UserOperationAuditInterceptor.class,
                        ExportRateLimitInterceptor.class,
                        JwtAuthFilter.class
                }))
@Import({
        SecurityConfig.class,
        SecurityProperties.class,
        AuditDeviceContext.class,
        AuditRequestContextFilter.class,
        JwtAuthFilter.class,
        TokenIssuer.class
})
class AuthLogoutSecurityIntegrationTest {

    @Autowired
    private MockMvc mvc;

    @MockitoBean
    private LoginService loginService;
    @MockitoBean
    private PasswordService passwordService;
    @MockitoBean
    private AuditService auditService;
    @MockitoBean
    private SecurityContextCurrentUser currentUser;
    @MockitoBean
    private JwtService jwtService;
    @MockitoBean
    private UserAccountRepository userRepo;
    @MockitoBean
    private VisitorAccountRepository visitorRepo;
    @MockitoBean
    private StaffAuthorityResolver staffAuthorityResolver;
    @MockitoBean
    private RefreshTokenRepository refreshTokenRepo;
    @MockitoBean
    private RefreshTokenService refreshTokenService;
    @MockitoBean
    private StaffRefreshTransaction refreshTransaction;
    @MockitoBean
    private StaffRefreshCompromiseService compromiseService;
    @MockitoBean
    private StaffTokenResponseFactory responseFactory;

    @BeforeEach
    void setUp() {
        when(currentUser.get()).thenReturn(Optional.empty());
    }

    @Test
    void logoutWithoutAccessTokenRevokesAndAuditsRefreshTokenOwner() throws Exception {
        String rawRefresh = "known-refresh-token";
        RefreshToken token = token(rawRefresh);
        when(refreshTokenRepo.findAndLockByTokenHash(HashUtil.sha256(rawRefresh)))
                .thenReturn(Optional.of(token));

        mvc.perform(post("/api/auth/logout")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"refreshToken\":\"" + rawRefresh + "\"}"))
                .andExpect(status().isOk())
                .andExpect(content().string(""));

        verify(refreshTokenService).revoke(token, null);
        verify(auditService).logExplicit(
                token.getUserId(),
                null,
                "logout",
                "refresh_tokens",
                token.getId().toString(),
                "success");
    }

    @Test
    void unknownRefreshTokenDoesNotDiscloseExistenceOrCreateBusinessAudit() throws Exception {
        String rawRefresh = "unknown-refresh-token";
        when(refreshTokenRepo.findAndLockByTokenHash(HashUtil.sha256(rawRefresh)))
                .thenReturn(Optional.empty());

        mvc.perform(post("/api/auth/logout")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"refreshToken\":\"" + rawRefresh + "\"}"))
                .andExpect(status().isOk())
                .andExpect(content().string(""));

        verifyNoInteractions(refreshTokenService);
        verifyNoExplicitBusinessAudit();
    }

    @Test
    void alreadyRevokedRefreshTokenIsAnIndistinguishableNoOp() throws Exception {
        String rawRefresh = "already-revoked-refresh-token";
        RefreshToken token = token(rawRefresh);
        token.setRevokedAt(OffsetDateTime.parse("2026-08-01T10:15:30+08:00"));
        when(refreshTokenRepo.findAndLockByTokenHash(HashUtil.sha256(rawRefresh)))
                .thenReturn(Optional.of(token));

        mvc.perform(post("/api/auth/logout")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"refreshToken\":\"" + rawRefresh + "\"}"))
                .andExpect(status().isOk())
                .andExpect(content().string(""));

        verifyNoInteractions(refreshTokenService);
        verifyNoExplicitBusinessAudit();
    }

    @Test
    void logoutAuditFailureDoesNotChangeSuccessfulRevocationResponse() throws Exception {
        String rawRefresh = "known-refresh-token-audit-down";
        RefreshToken token = token(rawRefresh);
        when(refreshTokenRepo.findAndLockByTokenHash(HashUtil.sha256(rawRefresh)))
                .thenReturn(Optional.of(token));
        doThrow(new IllegalStateException("audit unavailable"))
                .when(auditService)
                .logExplicit(
                        token.getUserId(),
                        null,
                        "logout",
                        "refresh_tokens",
                        token.getId().toString(),
                        "success");

        mvc.perform(post("/api/auth/logout")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"refreshToken\":\"" + rawRefresh + "\"}"))
                .andExpect(status().isOk())
                .andExpect(content().string(""));

        verify(refreshTokenService).revoke(token, null);
        verify(auditService).logExplicit(
                token.getUserId(),
                null,
                "logout",
                "refresh_tokens",
                token.getId().toString(),
                "success");
    }

    @Test
    void logoutWithoutBodyIsHarmless() throws Exception {
        mvc.perform(post("/api/auth/logout"))
                .andExpect(status().isOk())
                .andExpect(content().string(""));

        verifyNoInteractions(refreshTokenRepo, refreshTokenService);
        verifyNoExplicitBusinessAudit();
    }

    @Test
    void otherAuthEndpointStillRequiresAnAccessToken() throws Exception {
        mvc.perform(get("/api/auth/me"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.code").value(ErrorCode.UNAUTHORIZED.name()));
    }

    @Test
    void nonHealthActuatorEndpointRemainsProtected() throws Exception {
        mvc.perform(get("/actuator/info"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.code").value(ErrorCode.UNAUTHORIZED.name()));
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "/actuator/health",
            "/actuator/health/liveness",
            "/actuator/health/readiness"
    })
    void healthEndpointsArePublic(String path) throws Exception {
        mvc.perform(get(path))
                .andExpect(status().isOk())
                .andExpect(content().string("ok"));
    }

    private void verifyNoExplicitBusinessAudit() {
        verify(auditService, never()).logExplicit(
                any(),
                any(),
                any(),
                any(),
                any(),
                any());
    }

    private static RefreshToken token(String rawRefresh) {
        RefreshToken token = new RefreshToken();
        token.setUserId(UUID.randomUUID());
        token.setTokenHash(HashUtil.sha256(rawRefresh));
        return token;
    }
}

@RestController
class AuthLogoutSecurityProbeController {

    @GetMapping({
            "/actuator/health",
            "/actuator/health/liveness",
            "/actuator/health/readiness"
    })
    String health() {
        return "ok";
    }

    @GetMapping("/actuator/info")
    String info() {
        return "not-public";
    }
}
