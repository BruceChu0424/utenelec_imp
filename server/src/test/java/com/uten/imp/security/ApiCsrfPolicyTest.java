package com.uten.imp.security;

import jakarta.servlet.http.Cookie;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ApiCsrfPolicyTest {
    private final ApiCsrfPolicy policy = new ApiCsrfPolicy();

    @Test void onlyExplicitBearerCredentialsExemptAnApplicationMutation() {
        var bearer = new MockHttpServletRequest("POST", "/api/master/goods");
        bearer.addHeader("Authorization", "Bearer explicit-token");
        assertTrue(policy.matches(bearer));
        for (String authorization : List.of("Bearer ", "Bearer \t", "Basic YWJj", "token", "bearer token")) {
            var request = new MockHttpServletRequest("POST", "/api/master/goods");
            request.addHeader("Authorization", authorization);
            assertFalse(policy.matches(request));
        }
        var cookieOnly = new MockHttpServletRequest("POST", "/api/master/goods");
        cookieOnly.setCookies(new Cookie("JSESSIONID", "ambient-session"), new Cookie("access_token", "ambient-token"));
        assertFalse(policy.matches(cookieOnly));
        var outsideApi = new MockHttpServletRequest("POST", "/browser/update");
        outsideApi.addHeader("Authorization", "Bearer explicit-token");
        assertFalse(policy.matches(outsideApi));
    }

    @Test void publicCredentialExchangesAreExactPostContractsRatherThanAnAuthPrefixExemption() {
        for (String path : List.of("/api/auth/login", "/api/auth/refresh", "/api/auth/logout",
                "/api/visitor/auth/send-code", "/api/visitor/auth/login", "/api/visitor/auth/refresh",
                "/api/visitor/auth/logout", "/api/website-inquiries/ingest")) {
            assertTrue(policy.matches(new MockHttpServletRequest("POST", path)));
            assertFalse(policy.matches(new MockHttpServletRequest("PUT", path)));
            assertFalse(policy.matches(new MockHttpServletRequest("POST", path + "/extra")));
        }
        for (String path : List.of("/api/auth/change-password", "/api/auth/step-up",
                "/api/auth/mfa/verify", "/api/visitor/auth/change-permissions", "/api/website-inquiries/status")) {
            assertFalse(policy.matches(new MockHttpServletRequest("POST", path)));
        }
        var nested = new MockHttpServletRequest("POST", "/app/api/auth/refresh");
        nested.setContextPath("/app");
        assertTrue(policy.matches(nested));
    }
}
