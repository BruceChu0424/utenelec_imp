package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
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

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class JwtAuthorizationVersionTest {

    private final JwtService jwtService = mock(JwtService.class);
    private final UserAccountRepository userRepo = mock(UserAccountRepository.class);
    private final VisitorAccountRepository visitorRepo = mock(VisitorAccountRepository.class);
    private final JwtAuthFilter filter =
            new JwtAuthFilter(
                    jwtService,
                    userRepo,
                    visitorRepo,
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
    }

    @Test
    void rejectsAccessTokenWhenSharedAuthorizationEpochChanged() throws Exception {
        UUID userId = UUID.randomUUID();
        when(jwtService.parse("stale-token")).thenReturn(claims(userId, 5, 8));
        UserAccountRepository.AccountState accountState = state(5, 9);
        when(userRepo.findAccountStateById(userId)).thenReturn(Optional.of(accountState));

        MockHttpServletRequest request = bearerRequest("stale-token");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, response, chain);

        assertEquals(401, response.getStatus());
        assertNull(request.getAttribute(AuditRequestContext.VERIFIED_ACTOR_ATTRIBUTE));
        verify(chain, never()).doFilter(request, response);
    }

    @Test
    void acceptsOnlyMatchingAuthorizationSnapshot() throws Exception {
        UUID userId = UUID.randomUUID();
        when(jwtService.parse("current-token")).thenReturn(claims(userId, 5, 9));
        UserAccountRepository.AccountState accountState = state(5, 9);
        when(userRepo.findAccountStateById(userId)).thenReturn(Optional.of(accountState));

        MockHttpServletRequest request = bearerRequest("current-token");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, response, chain);

        verify(chain).doFilter(request, response);
        AuthUser principal = assertInstanceOf(
                AuthUser.class,
                SecurityContextHolder.getContext().getAuthentication().getPrincipal());
        assertEquals(userId, principal.getId());
        assertEquals(List.of("employee:view"), principal.getPermissions().stream().toList());
        assertNotNull(request.getAttribute(AuditRequestContext.VERIFIED_ACTOR_ATTRIBUTE));
    }

    private Claims claims(UUID userId, long authVersion, long authorizationEpoch) {
        return Jwts.claims()
                .subject(userId.toString())
                .add("typ", "staff")
                .add("emp", UUID.randomUUID().toString())
                .add("acc", "E1001")
                .add("roles", List.of("employee"))
                .add("perms", List.of("employee:view"))
                .add("av", authVersion)
                .add("ae", authorizationEpoch)
                .build();
    }

    private UserAccountRepository.AccountState state(
            long authVersion,
            long authorizationEpoch) {
        UserAccountRepository.AccountState state =
                mock(UserAccountRepository.AccountState.class);
        when(state.getStatus()).thenReturn("active");
        when(state.isDeleted()).thenReturn(false);
        when(state.isMustChangePassword()).thenReturn(false);
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
