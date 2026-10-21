package com.uten.imp.config;

import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.audit.AuditRequestContextFilter;
import com.uten.imp.audit.AuditService;
import com.uten.imp.audit.UserOperationAuditInterceptor;
import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.security.ExportRateLimitInterceptor;
import com.uten.imp.security.JwtAuthFilter;
import com.uten.imp.security.JwtService;
import com.uten.imp.security.LocalNetworkAccessPolicy;
import com.uten.imp.security.LocalNetworkGuardFilter;
import com.uten.imp.security.PasswordChangeRequiredFilter;
import com.uten.imp.security.RemoteAccessGuardFilter;
import com.uten.imp.security.RemoteAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.StaffAuthorityResolver;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.FilterType;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpHeaders;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.web.FilterChainProxy;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.filter.CorsFilter;

import java.util.Optional;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.ArgumentMatchers.longThat;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@WebMvcTest(
        controllers = CorsAuditProbeController.class,
        excludeAutoConfiguration = org.springframework.boot.security.autoconfigure.UserDetailsServiceAutoConfiguration.class,
        properties = {
                "uten.security.cors-allowed-origins=https://trusted.example.test",
                "uten.security.require-https=false",
                // 未设 UTEN_PROFILE 时按 prod 启动(故意 fail-closed), 而 prod 要求显式配置内网网段(ADR-110 security-17);
                // CI 没有 server/.env, 这里给出本用例的网段, 不放宽生产启动校验。
                "uten.deployment.local-allowed-cidrs=127.0.0.0/8,::1/128"
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
        com.uten.imp.support.RemoteIngressSecurityTestConfiguration.class,
        SecurityConfig.class,
        SecurityProperties.class,
        DeploymentProperties.class,
        AuditDeviceContext.class,
        AuditRequestContextFilter.class,
        JwtAuthFilter.class,
        LocalNetworkAccessPolicy.class,
        LocalNetworkGuardFilter.class,
        RemoteAccessPolicy.class,
        RemoteAccessGuardFilter.class
})
class SecurityCorsAuditIntegrationTest {

    @Autowired
    private FilterChainProxy springSecurityFilterChain;
    @Autowired
    @Qualifier("localNetworkFilterRegistration")
    private FilterRegistrationBean<?> localNetworkRegistration;
    @Autowired
    @Qualifier("jwtFilterRegistration")
    private FilterRegistrationBean<?> jwtRegistration;
    @Autowired
    @Qualifier("remoteAccessFilterRegistration")
    private FilterRegistrationBean<?> remoteAccessRegistration;
    @Autowired
    @Qualifier("passwordChangeRequiredFilterRegistration")
    private FilterRegistrationBean<?> passwordChangeRequiredRegistration;
    @Autowired
    @Qualifier("remoteMfaFilterRegistration")
    private FilterRegistrationBean<?> remoteMfaRegistration;
    @Autowired
    @Qualifier("remoteBudgetFilterRegistration")
    private FilterRegistrationBean<?> remoteBudgetRegistration;

    @MockitoBean
    private AuditService auditService;
    @MockitoBean
    private SecurityContextCurrentUser currentUser;
    @MockitoBean
    private JwtService jwtService;
    @MockitoBean
    private com.uten.imp.features.auth.AuthSessionService sessions;
    @MockitoBean
    private StaffAuthorityResolver staffAuthorityResolver;

    @BeforeEach
    void setUp() {
        when(currentUser.get()).thenReturn(Optional.empty());
    }

    @Test
    void invalidOriginIsRejectedAndStillAuditedByTheSecurityChain()
            throws Exception {
        var filters = springSecurityFilterChain.getFilters("/api/cors-audit-probe");
        int auditIndex = indexOf(filters, AuditRequestContextFilter.class);
        int corsIndex = indexOf(filters, CorsFilter.class);
        int localNetworkIndex = indexOf(filters, LocalNetworkGuardFilter.class);
        int jwtIndex = indexOf(filters, JwtAuthFilter.class);
        int remoteAccessIndex = indexOf(filters, RemoteAccessGuardFilter.class);
        int remoteMfaIndex = indexOf(filters, com.uten.imp.security.RemoteMfaGuardFilter.class);
        int remoteBudgetIndex = indexOf(filters, com.uten.imp.security.RemoteRequestBudgetFilter.class);
        int passwordChangeRequiredIndex =
                indexOf(filters, PasswordChangeRequiredFilter.class);
        assertTrue(auditIndex >= 0);
        assertTrue(corsIndex > auditIndex);
        assertTrue(localNetworkIndex > corsIndex);
        assertTrue(jwtIndex > localNetworkIndex);
        assertTrue(remoteAccessIndex > jwtIndex);
        assertTrue(remoteBudgetIndex > localNetworkIndex);
        assertTrue(jwtIndex > remoteBudgetIndex);
        assertTrue(remoteMfaIndex > remoteAccessIndex);
        assertTrue(passwordChangeRequiredIndex > remoteMfaIndex);
        assertFalse(localNetworkRegistration.isEnabled());
        assertFalse(jwtRegistration.isEnabled());
        assertFalse(remoteAccessRegistration.isEnabled());
        assertFalse(passwordChangeRequiredRegistration.isEnabled());
        assertFalse(remoteMfaRegistration.isEnabled());
        assertFalse(remoteBudgetRegistration.isEnabled());

        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/api/cors-audit-probe");
        request.addHeader(HttpHeaders.ORIGIN, "https://untrusted.example.test");
        MockHttpServletResponse response = new MockHttpServletResponse();
        boolean[] reachedApplication = {false};

        springSecurityFilterChain.doFilter(request, response, (req, resp) -> {
            reachedApplication[0] = true;
            fail("invalid CORS request must not reach the application");
        });

        assertEquals(403, response.getStatus());
        assertFalse(reachedApplication[0]);
        verify(auditService).logHttpOperation(
                isNull(),
                isNull(),
                eq("GET"),
                eq("/api/cors-audit-probe"),
                eq("api/cors-audit-probe"),
                eq(403),
                longThat(value -> value >= 0));
    }

    @ParameterizedTest
    @CsvSource({"GET,404", "POST,405"})
    void authenticatedFallbackKeepsVerifiedActorAfterSecurityContextCleanup(
            String method,
            int status) throws Exception {
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        when(jwtService.parse("valid-token"))
                .thenReturn(claims(userId));
        java.time.Instant now = java.time.Instant.parse("2026-09-23T02:00:00Z");
        when(sessions.now()).thenReturn(now);
        // ADR-110: 过滤器用一条 SQL 读账号状态与服务端会话。
        when(sessions.loadStaff(userId, SESSION, userId)).thenReturn(Optional.of(
                new com.uten.imp.features.auth.AuthSessionService.StaffState(
                        employeeId, "E1001", "active", false, false, false, false, 7L, 11L,
                        new com.uten.imp.features.auth.AuthSessionService.SessionFacts(
                                now.minusSeconds(10), now.plusSeconds(86_400), null),
                        "30")));
        when(staffAuthorityResolver.resolve(userId, employeeId, false, 7, 11))
                .thenReturn(new PermissionResolver.AuthorizationSnapshot(
                        Set.of("employee:view")));

        MockHttpServletRequest request = new MockHttpServletRequest(
                method, "/api/no-such-handler");
        request.addHeader(HttpHeaders.AUTHORIZATION, "Bearer valid-token");
        MockHttpServletResponse response = new MockHttpServletResponse();

        springSecurityFilterChain.doFilter(
                request,
                response,
                (req, resp) -> response.setStatus(status));

        assertEquals(status, response.getStatus());
        // This bean intentionally returns empty even while a verified JWT was
        // accepted, proving fallback attribution comes from the request snapshot.
        verify(auditService).logHttpOperation(
                eq(userId),
                eq("E1001"),
                eq(method),
                eq("/api/no-such-handler"),
                eq("api/no-such-handler"),
                eq(status),
                longThat(value -> value >= 0));
    }

    @Test
    void bearerPostsKeepTheDefaultCsrfFilterAndNeverCreateAnAuthenticationSession() throws Exception {
        allowBearer();
        var filters = springSecurityFilterChain.getFilters("/api/csrf-probe/write");
        int network = indexOf(filters, LocalNetworkGuardFilter.class);
        int csrf = indexOf(filters, org.springframework.security.web.csrf.CsrfFilter.class);
        assertTrue(network >= 0);
        assertTrue(csrf > network);
        var request = new MockHttpServletRequest("POST", "/api/csrf-probe/write");
        request.addHeader(HttpHeaders.AUTHORIZATION, "Bearer valid-token");
        var response = new MockHttpServletResponse();
        boolean[] reached = {false};
        springSecurityFilterChain.doFilter(request, response, (req, resp) -> {
            reached[0] = true;
            response.setStatus(204);
        });
        assertTrue(reached[0]);
        assertEquals(204, response.getStatus());
        assertStateless(request, response);
    }

    @Test
    void missingMalformedAndExpiredBearerPostsRemainJson401WithoutCreatingSessions() throws Exception {
        when(jwtService.parse("invalid-token")).thenThrow(new io.jsonwebtoken.MalformedJwtException("rejected"));
        when(jwtService.parse("expired-token")).thenThrow(new io.jsonwebtoken.ExpiredJwtException(null, null, "expired"));
        for (String token : List.of("", "invalid-token", "expired-token")) {
            var request = new MockHttpServletRequest("POST", "/api/csrf-probe/write");
            if (!token.isEmpty()) request.addHeader(HttpHeaders.AUTHORIZATION, "Bearer " + token);
            var response = new MockHttpServletResponse();
            springSecurityFilterChain.doFilter(request, response, (req, resp) -> fail("Unauthenticated write reached application"));
            assertJsonError(response, 401, "UNAUTHORIZED");
            assertStateless(request, response);
        }
    }

    @Test
    void ambientCookiesAndForeignOriginsCannotAuthorizeAnApplicationWrite() throws Exception {
        var cookieRequest = new MockHttpServletRequest("POST", "/api/csrf-probe/write");
        cookieRequest.setCookies(new jakarta.servlet.http.Cookie("JSESSIONID", "ambient-session"),
                new jakarta.servlet.http.Cookie("access_token", "ambient-token"));
        var cookieResponse = new MockHttpServletResponse();
        springSecurityFilterChain.doFilter(cookieRequest, cookieResponse,
                (req, resp) -> fail("Cookies must not authenticate this API"));
        assertJsonError(cookieResponse, 401, "UNAUTHORIZED");
        assertTrue(cookieResponse.getHeaders("Set-Cookie").stream().anyMatch(value -> value.startsWith("XSRF-TOKEN=")));
        assertStateless(cookieRequest, cookieResponse);

        var foreign = new MockHttpServletRequest("POST", "/api/csrf-probe/write");
        foreign.addHeader(HttpHeaders.AUTHORIZATION, "Bearer valid-token");
        foreign.addHeader(HttpHeaders.ORIGIN, "https://untrusted.example.test");
        var foreignResponse = new MockHttpServletResponse();
        springSecurityFilterChain.doFilter(foreign, foreignResponse,
                (req, resp) -> fail("Foreign origin reached application"));
        assertEquals(403, foreignResponse.getStatus());
        assertStateless(foreign, foreignResponse);
    }

    @Test
    void exactPublicCredentialPostsKeepTheirStatelessGatewayContract() throws Exception {
        for (String path : List.of("/api/auth/login", "/api/auth/refresh", "/api/auth/logout",
                "/api/visitor/auth/send-code", "/api/visitor/auth/login", "/api/visitor/auth/refresh",
                "/api/visitor/auth/logout", "/api/website-inquiries/ingest")) {
            var request = new MockHttpServletRequest("POST", path);
            var response = new MockHttpServletResponse();
            boolean[] reached = {false};
            springSecurityFilterChain.doFilter(request, response, (req, resp) -> {
                reached[0] = true;
                response.setStatus(204);
            });
            assertTrue(reached[0], path);
            assertEquals(204, response.getStatus());
            assertStateless(request, response);
        }
    }

    @Test
    void authenticatedPermissionDenialRemainsStructured403() throws Exception {
        allowBearer();
        var request = new MockHttpServletRequest("POST", "/api/csrf-probe/write");
        request.addHeader(HttpHeaders.AUTHORIZATION, "Bearer valid-token");
        var response = new MockHttpServletResponse();
        springSecurityFilterChain.doFilter(request, response,
                (req, resp) -> { throw new org.springframework.security.access.AccessDeniedException("denied"); });
        assertJsonError(response, 403, "FORBIDDEN");
        assertStateless(request, response);
    }

    private void allowBearer() {
        UUID userId = UUID.randomUUID(), employeeId = UUID.randomUUID();
        java.time.Instant now = java.time.Instant.parse("2026-09-23T02:00:00Z");
        when(jwtService.parse("valid-token")).thenReturn(claims(userId));
        when(sessions.now()).thenReturn(now);
        when(sessions.loadStaff(userId, SESSION, userId)).thenReturn(Optional.of(
                new com.uten.imp.features.auth.AuthSessionService.StaffState(
                        employeeId, "csrf-staff", "active", false, false, false, false, 7L, 11L,
                        new com.uten.imp.features.auth.AuthSessionService.SessionFacts(
                                now.minusSeconds(10), now.plusSeconds(86_400), null), "30")));
        when(staffAuthorityResolver.resolve(userId, employeeId, false, 7, 11))
                .thenReturn(new PermissionResolver.AuthorizationSnapshot(Set.of("employee:view")));
    }

    private static void assertJsonError(MockHttpServletResponse response, int status, String code) throws java.io.IOException {
        assertEquals(status, response.getStatus());
        assertEquals(code, new com.fasterxml.jackson.databind.ObjectMapper().readTree(response.getContentAsString()).path("code").asText());
        assertTrue(response.getContentType().startsWith("application/json"));
    }

    private static void assertStateless(MockHttpServletRequest request, MockHttpServletResponse response) {
        assertNull(request.getSession(false));
        assertFalse(response.getHeaders("Set-Cookie").stream().anyMatch(value -> value.startsWith("JSESSIONID=")));
    }

    private static final UUID SESSION = UUID.randomUUID();

    private static Claims claims(UUID userId) {
        return Jwts.claims()
                .subject(userId.toString())
                .add("typ", "staff")
                .add("av", 7L)
                .add("ae", 11L)
                .add("sid", SESSION.toString())
                .build();
    }

    private static int indexOf(
            java.util.List<jakarta.servlet.Filter> filters,
            Class<?> type) {
        for (int index = 0; index < filters.size(); index++) {
            if (type.isInstance(filters.get(index))) {
                return index;
            }
        }
        return -1;
    }
}

@RestController
class CorsAuditProbeController {

    @GetMapping("/api/cors-audit-probe")
    String probe() {
        return "ok";
    }
}
