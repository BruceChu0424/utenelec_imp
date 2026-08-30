package com.uten.imp.security;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.visitor.VisitorAccountRepository;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import jakarta.servlet.FilterChain;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class JwtAuthorizationVersionTest {

    private final JwtService jwtService = mock(JwtService.class);
    private final UserAccountRepository userRepo = mock(UserAccountRepository.class);
    private final VisitorAccountRepository visitorRepo = mock(VisitorAccountRepository.class);
    private final StaffAuthorityResolver staffAuthorityResolver = mock(StaffAuthorityResolver.class);
    private final JwtAuthFilter filter =
            new JwtAuthFilter(
                    jwtService,
                    userRepo,
                    visitorRepo,
                    staffAuthorityResolver,
                    new ObjectMapper(),
                    mock(AuditService.class));

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void rejectsAccessTokenWhenDirectAuthorizationVersionChanged() throws Exception {
        UUID userId = UUID.randomUUID();
        when(jwtService.parse("stale-token")).thenReturn(claims(userId, 4, 9));
        UserAccountRepository.AccountState accountState = state(5, 9);
        when(userRepo.findAccountStateById(userId)).thenReturn(Optional.of(accountState));

        MockHttpServletRequest request = bearerRequest("stale-token");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, response, chain);

        assertEquals(401, response.getStatus());
        assertNull(SecurityContextHolder.getContext().getAuthentication());
        assertNull(request.getAttribute(AuditRequestContext.VERIFIED_ACTOR_ATTRIBUTE));
        verify(chain, never()).doFilter(request, response);
        verifyNoInteractions(staffAuthorityResolver);
    }

    @Test
    void rejectsAccessTokenWhenSharedAuthorizationEpochChanged() throws Exception {
        UUID userId = UUID.randomUUID();
        when(jwtService.parse("stale-token")).thenReturn(claims(userId, 5, 8));
        UserAccountRepository.AccountState accountState = state(5, 9);
        when(userRepo.findAccountStateById(userId)).thenReturn(Optional.of(accountState));

        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);
        filter.doFilter(bearerRequest("stale-token"), response, chain);

        assertEquals(401, response.getStatus());
        verify(chain, never()).doFilter(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any());
        verifyNoInteractions(staffAuthorityResolver);
    }

    @Test
    void acceptsPermissionsResolvedFromCurrentServerState() throws Exception {
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        UUID sessionId = UUID.randomUUID();
        when(jwtService.parse("current-token")).thenReturn(
                claims(userId, 5, 9, sessionId));
        UserAccountRepository.AccountState accountState =
                state(employeeId, "E1001", "active", false, false, 5, 9);
        when(userRepo.findAccountStateById(userId)).thenReturn(Optional.of(accountState));
        when(staffAuthorityResolver.resolve(userId, employeeId, false, 5, 9))
                .thenReturn(new PermissionResolver.AuthorizationSnapshot(
                        Set.of("employee"),
                        Set.of("employee:view")));

        MockHttpServletRequest request = bearerRequest("current-token");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);
        filter.doFilter(request, response, chain);

        verify(chain).doFilter(request, response);
        AuthUser principal = assertInstanceOf(
                AuthUser.class,
                SecurityContextHolder.getContext().getAuthentication().getPrincipal());
        assertEquals(userId, principal.getId());
        assertEquals(employeeId, principal.getEmployeeId());
        assertEquals("E1001", principal.getLoginAccount());
        assertEquals(Set.of("employee:view"), principal.getPermissions());
        assertTrue(principal.getAuthorities().stream()
                .anyMatch(authority -> "employee:view".equals(authority.getAuthority())));
        assertNotNull(request.getAttribute(AuditRequestContext.VERIFIED_ACTOR_ATTRIBUTE));
        assertEquals(
                sessionId,
                request.getAttribute(AuditRequestContext.SESSION_ID_ATTRIBUTE));
    }

    @Test
    void disabledAccountFailsClosedBeforeAuthorityCache() throws Exception {
        UUID userId = UUID.randomUUID();
        when(jwtService.parse("current-token")).thenReturn(claims(userId, 5, 9));
        UserAccountRepository.AccountState accountState =
                state(UUID.randomUUID(), "E1001", "disabled", false, false, 5, 9);
        when(userRepo.findAccountStateById(userId)).thenReturn(Optional.of(accountState));

        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);
        filter.doFilter(bearerRequest("current-token"), response, chain);

        assertEquals(401, response.getStatus());
        verifyNoInteractions(staffAuthorityResolver);
        verify(chain, never()).doFilter(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any());
    }

    @Test
    void deletedAccountFailsClosedBeforeAuthorityCache() throws Exception {
        UUID userId = UUID.randomUUID();
        when(jwtService.parse("current-token")).thenReturn(claims(userId, 5, 9));
        UserAccountRepository.AccountState accountState =
                state(UUID.randomUUID(), "E1001", "active", true, false, 5, 9);
        when(userRepo.findAccountStateById(userId)).thenReturn(Optional.of(accountState));

        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);
        filter.doFilter(bearerRequest("current-token"), response, chain);

        assertEquals(401, response.getStatus());
        verifyNoInteractions(staffAuthorityResolver);
        verify(chain, never()).doFilter(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any());
    }

    @Test
    void passwordResetStateRestrictsNewTokenToPasswordChangeAuthority() throws Exception {
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        when(jwtService.parse("reset-token")).thenReturn(claims(userId, 6, 9));
        UserAccountRepository.AccountState accountState =
                state(employeeId, "E1001", "active", false, true, 6, 9);
        when(userRepo.findAccountStateById(userId)).thenReturn(Optional.of(accountState));
        when(staffAuthorityResolver.resolve(userId, employeeId, false, 6, 9))
                .thenReturn(new PermissionResolver.AuthorizationSnapshot(
                        Set.of("employee"),
                        Set.of("employee:view")));

        MockHttpServletRequest request = bearerRequest("reset-token");
        FilterChain chain = mock(FilterChain.class);
        filter.doFilter(request, new MockHttpServletResponse(), chain);

        AuthUser principal = (AuthUser) SecurityContextHolder.getContext()
                .getAuthentication().getPrincipal();
        assertEquals(
                Set.of("CHANGE_PASSWORD"),
                principal.getAuthorities().stream()
                        .map(authority -> authority.getAuthority())
                        .collect(java.util.stream.Collectors.toSet()));
    }

    @Test
    void authorityResolverFailureReturnsStructured503WithoutInvalidatingSession() throws Exception {
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        when(jwtService.parse("current-token")).thenReturn(claims(userId, 5, 9));
        UserAccountRepository.AccountState accountState =
                state(employeeId, "E1001", "active", false, false, 5, 9);
        when(userRepo.findAccountStateById(userId)).thenReturn(Optional.of(accountState));
        when(staffAuthorityResolver.resolve(userId, employeeId, false, 5, 9))
                .thenThrow(new IllegalStateException("permission database unavailable"));

        MockHttpServletRequest request = bearerRequest("current-token");
        request.setRequestURI("/api/stock/balances");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, response, chain);

        assertStructuredServiceUnavailable(response);
        assertNull(SecurityContextHolder.getContext().getAuthentication());
        verify(chain, never()).doFilter(request, response);
    }

    @Test
    void accountProjectionFailureReturnsStructured503InsteadOf401() throws Exception {
        UUID userId = UUID.randomUUID();
        when(jwtService.parse("current-token")).thenReturn(claims(userId, 5, 9));
        when(userRepo.findAccountStateById(userId))
                .thenThrow(new IllegalStateException("account database unavailable"));

        MockHttpServletRequest request = bearerRequest("current-token");
        request.setRequestURI("/api/stock/balances");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, response, chain);

        assertStructuredServiceUnavailable(response);
        assertNull(SecurityContextHolder.getContext().getAuthentication());
        verify(chain, never()).doFilter(request, response);
        verifyNoInteractions(staffAuthorityResolver);
    }

    @Test
    void publicAuthEndpointIgnoresResidualBearerToken() throws Exception {
        MockHttpServletRequest request = bearerRequest("stale-token");
        request.setRequestURI("/api/auth/refresh");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, response, chain);

        verify(chain).doFilter(request, response);
        verifyNoInteractions(jwtService, userRepo, visitorRepo, staffAuthorityResolver);
    }

    private void assertStructuredServiceUnavailable(MockHttpServletResponse response)
            throws Exception {
        assertEquals(503, response.getStatus());
        JsonNode body = new ObjectMapper().readTree(response.getContentAsString());
        assertEquals(503, body.path("status").asInt());
        assertEquals("SERVICE_UNAVAILABLE", body.path("code").asText());
    }

    private Claims claims(UUID userId, long authVersion, long authorizationEpoch) {
        return claims(userId, authVersion, authorizationEpoch, null);
    }

    private Claims claims(
            UUID userId,
            long authVersion,
            long authorizationEpoch,
            UUID sessionId) {
        var builder = Jwts.claims()
                .subject(userId.toString())
                .add("typ", "staff")
                .add("av", authVersion)
                .add("ae", authorizationEpoch);
        if (sessionId != null) {
            builder.add("sid", sessionId.toString());
        }
        return builder.build();
    }

    private UserAccountRepository.AccountState state(
            long authVersion,
            long authorizationEpoch) {
        return state(
                UUID.randomUUID(),
                "E1001",
                "active",
                false,
                false,
                authVersion,
                authorizationEpoch);
    }

    private UserAccountRepository.AccountState state(
            UUID employeeId,
            String loginAccount,
            String status,
            boolean deleted,
            boolean mustChangePassword,
            long authVersion,
            long authorizationEpoch) {
        UserAccountRepository.AccountState state = mock(UserAccountRepository.AccountState.class);
        when(state.getEmployeeId()).thenReturn(employeeId);
        when(state.getLoginAccount()).thenReturn(loginAccount);
        when(state.getStatus()).thenReturn(status);
        when(state.isDeleted()).thenReturn(deleted);
        when(state.isMustChangePassword()).thenReturn(mustChangePassword);
        when(state.isSuperAdmin()).thenReturn(false);
        when(state.getAuthVersion()).thenReturn(authVersion);
        when(state.getAuthorizationEpoch()).thenReturn(authorizationEpoch);
        return state;
    }

    private MockHttpServletRequest bearerRequest(String token) {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.addHeader("Authorization", "Bearer " + token);
        return request;
    }
}
