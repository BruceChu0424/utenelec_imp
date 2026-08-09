package com.uten.imp.security;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class PasswordChangeRequiredFilterTest {

    private static final UUID USER_ID =
            UUID.fromString("11111111-1111-1111-1111-111111111111");
    private static final UUID EMPLOYEE_ID =
            UUID.fromString("22222222-2222-2222-2222-222222222222");

    private final ObjectMapper objectMapper = new ObjectMapper().findAndRegisterModules();
    private final AuditService auditService = mock(AuditService.class);
    private final PasswordChangeRequiredFilter filter =
            new PasswordChangeRequiredFilter(objectMapper, auditService);

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @ParameterizedTest
    @CsvSource({
            "POST, /api/auth/change-password",
            "POST, /api/auth/logout",
            "GET, /api/auth/me"
    })
    void firstLoginUserCanOnlyReachTheCompletionFlow(String method, String path)
            throws Exception {
        authenticate(true);
        MockHttpServletResponse response = new MockHttpServletResponse();
        boolean[] reached = {false};

        filter.doFilter(request(method, path), response, (req, resp) -> reached[0] = true);

        assertTrue(reached[0]);
    }

    @ParameterizedTest
    @CsvSource({
            "GET, /api/dashboard/overview",
            "POST, /api/auth/verify-password",
            "GET, /api/auth/change-password",
            "POST, /api/auth/me",
            "POST, /api/auth/change-password/"
    })
    void firstLoginUserIsDeniedOutsideTheExactAllowlist(String method, String path)
            throws Exception {
        authenticate(true);
        MockHttpServletRequest request = request(method, path);
        MockHttpServletResponse response = new MockHttpServletResponse();
        boolean[] reached = {false};

        filter.doFilter(request, response, (req, resp) -> reached[0] = true);

        assertFalse(reached[0]);
        assertEquals(403, response.getStatus());
        JsonNode body = objectMapper.readTree(response.getContentAsByteArray());
        assertEquals(403, body.path("status").asInt());
        assertEquals(ErrorCode.PASSWORD_CHANGE_REQUIRED.name(), body.path("code").asText());
        assertEquals(
                ErrorCode.PASSWORD_CHANGE_REQUIRED.getDefaultMessage(),
                body.path("message").asText());
        verify(auditService).logSecurityEvent(
                request,
                USER_ID,
                "13800000000",
                "password_change_required",
                "forbidden",
                403);
    }

    @Test
    void completedPasswordChangeRestoresNormalApiAccess() throws Exception {
        authenticate(false);
        boolean[] reached = {false};

        filter.doFilter(
                request("GET", "/api/dashboard/overview"),
                new MockHttpServletResponse(),
                (req, resp) -> reached[0] = true);

        assertTrue(reached[0]);
    }

    @Test
    void auditFailureStillFailsClosed() throws Exception {
        authenticate(true);
        MockHttpServletRequest request = request("POST", "/api/sales/orders");
        MockHttpServletResponse response = new MockHttpServletResponse();
        boolean[] reached = {false};
        doThrow(new IllegalStateException("audit unavailable"))
                .when(auditService)
                .logSecurityEvent(
                        request,
                        USER_ID,
                        "13800000000",
                        "password_change_required",
                        "forbidden",
                        403);

        filter.doFilter(request, response, (req, resp) -> reached[0] = true);

        assertFalse(reached[0]);
        assertEquals(403, response.getStatus());
    }

    private void authenticate(boolean mustChangePassword) {
        AuthUser user = new AuthUser(
                USER_ID,
                EMPLOYEE_ID,
                "13800000000",
                Set.of("admin"),
                Set.of("sales:view", "sales:edit"),
                mustChangePassword,
                true,
                true);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(
                        user, null, user.getAuthorities()));
    }

    private static MockHttpServletRequest request(String method, String path) {
        return new MockHttpServletRequest(method, path);
    }
}
