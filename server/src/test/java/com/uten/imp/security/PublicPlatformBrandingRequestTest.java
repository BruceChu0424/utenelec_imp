package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.auth.AuthSessionService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.Set;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class PublicPlatformBrandingRequestTest {
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void allowlistIsExactAndContextAwareAndReadOnly() {
        assertTrue(PublicPlatformBrandingRequest.matches(request("GET", "/api/platform/branding")));
        assertTrue(PublicPlatformBrandingRequest.matches(request("GET", "/api/platform/branding/logo")));
        assertTrue(PublicPlatformBrandingRequest.matches(request("GET", "/%61pi/platform/branding/logo")));
        assertTrue(PublicPlatformBrandingRequest.matches(request("GET", "/api/platform/%62randing")));
        var nested = request("GET", "/erp/api/platform/branding/logo"); nested.setContextPath("/erp");
        assertTrue(PublicPlatformBrandingRequest.matches(nested));
        for (String path : new String[]{"/api/platform/branding/", "/api/platform/branding/logo/extra", "/api/admin/platform-settings"})
            assertFalse(PublicPlatformBrandingRequest.matches(request("GET", path)));
        assertFalse(PublicPlatformBrandingRequest.matches(request("PUT", "/api/platform/branding")));
    }

    @Test void incidentalBearerDoesNotResolveAccountsForPublicLogo() throws Exception {
        var jwt = mock(JwtService.class); var sessions = mock(AuthSessionService.class);
        var resolver = mock(StaffAuthorityResolver.class); var audit = mock(AuditService.class);
        var filter = new JwtAuthFilter(jwt, sessions, resolver, new ObjectMapper(), audit);
        var request = request("GET", "/%61pi/platform/branding/logo"); request.addHeader("Authorization", "Bearer stale-or-foreign");
        boolean[] reached = {false};
        filter.doFilter(request, new MockHttpServletResponse(), (req, resp) -> reached[0] = true);
        assertTrue(reached[0]); verifyNoInteractions(jwt, sessions, resolver, audit);
    }

    @Test void firstPasswordAndCloudAccountRestrictionsDoNotBlockPublicBranding() throws Exception {
        AuthUser user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "admin", Set.of(), true, true, false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
        var audit = mock(AuditService.class); var remotePolicy = mock(RemoteAccessPolicy.class);
        var firstPassword = new PasswordChangeRequiredFilter(new ObjectMapper(), audit);
        var remote = new RemoteAccessGuardFilter(new ObjectMapper(), audit, remotePolicy);
        boolean[] reached = {false};
        var request = request("GET", "/api/platform/branding");
        remote.doFilter(request, new MockHttpServletResponse(), (req, resp) ->
                firstPassword.doFilter(req, resp, (r, s) -> reached[0] = true));
        assertTrue(reached[0]); verifyNoInteractions(audit, remotePolicy);
    }

    private static MockHttpServletRequest request(String method, String path) { return new MockHttpServletRequest(method, path); }
}
