package com.uten.imp.config;

import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.audit.AuditRequestContextFilter;
import com.uten.imp.audit.AuditService;
import com.uten.imp.audit.UserOperationAuditInterceptor;
import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.visitor.VisitorAccountRepository;
import com.uten.imp.security.ExportRateLimitInterceptor;
import com.uten.imp.security.JwtAuthFilter;
import com.uten.imp.security.JwtService;
import com.uten.imp.security.SecurityContextCurrentUser;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
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
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.ArgumentMatchers.longThat;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@WebMvcTest(
        controllers = CorsAuditProbeController.class,
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
        JwtAuthFilter.class
})
class SecurityCorsAuditIntegrationTest {

    @Autowired
    private FilterChainProxy springSecurityFilterChain;

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
        int jwtIndex = indexOf(filters, JwtAuthFilter.class);
        assertTrue(auditIndex >= 0);
        assertTrue(corsIndex > auditIndex);
        assertTrue(jwtIndex > corsIndex);

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
        when(jwtService.parse("valid-token"))
                .thenReturn(claims(userId));
        UserAccountRepository.AccountState accountState =
                org.mockito.Mockito.mock(UserAccountRepository.AccountState.class);
        when(accountState.getStatus()).thenReturn("active");
        when(accountState.isDeleted()).thenReturn(false);
        when(accountState.isMustChangePassword()).thenReturn(false);
        when(accountState.isSuperAdmin()).thenReturn(false);
        when(accountState.getAuthVersion()).thenReturn(7L);
        when(accountState.getAuthorizationEpoch()).thenReturn(11L);
        when(userRepo.findAccountStateById(userId))
                .thenReturn(Optional.of(accountState));

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

    private static Claims claims(UUID userId) {
        return Jwts.claims()
                .subject(userId.toString())
                .add("typ", "staff")
                .add("emp", UUID.randomUUID().toString())
                .add("acc", "E1001")
                .add("roles", List.of("employee"))
                .add("perms", List.of("employee:view"))
                .add("av", 7L)
                .add("ae", 11L)
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
