package com.uten.imp.audit;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import java.util.Optional;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class UserOperationAuditInterceptorTest {

    private AuditService auditService;
    private UserOperationAuditInterceptor interceptor;
    private SecurityContextCurrentUser currentUser;
    private UUID userId;

    @BeforeEach
    void setUp() {
        currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser user = mock(AuthUser.class);
        auditService = mock(AuditService.class);
        userId = UUID.randomUUID();

        when(user.getId()).thenReturn(userId);
        when(user.getLoginAccount()).thenReturn("auditor");
        when(currentUser.get()).thenReturn(Optional.of(user));
        interceptor = new UserOperationAuditInterceptor(currentUser, auditService);
    }

    @Test
    void recordsAuthenticatedMutationWithoutRequestBody() {
        MockHttpServletRequest request =
                new MockHttpServletRequest("PATCH", "/api/sales/orders/123");
        MockHttpServletResponse response = new MockHttpServletResponse();
        response.setStatus(409);

        interceptor.preHandle(request, response, new Object());
        interceptor.afterCompletion(request, response, new Object(), null);

        verify(auditService).logHttpOperation(
                eq(userId),
                eq("auditor"),
                eq("PATCH"),
                eq("/api/sales/orders/123"),
                eq("api/sales/orders"),
                eq(409),
                org.mockito.ArgumentMatchers.longThat(value -> value >= 0));
    }

    @Test
    void recordsAuthenticatedReadWithoutQueryValuesOrBody() {
        MockHttpServletRequest request =
                new MockHttpServletRequest("GET", "/api/sales/orders/123");
        MockHttpServletResponse response = new MockHttpServletResponse();

        interceptor.preHandle(request, response, new Object());
        interceptor.afterCompletion(request, response, new Object(), null);

        verify(auditService).logHttpOperation(
                eq(userId),
                eq("auditor"),
                eq("GET"),
                eq("/api/sales/orders/123"),
                eq("api/sales/orders"),
                eq(200),
                org.mockito.ArgumentMatchers.longThat(value -> value >= 0));
    }

    @Test
    void recordsAnonymousMalformedLoginWithoutCredentialsOrQueryValues() {
        when(currentUser.get()).thenReturn(Optional.empty());
        MockHttpServletRequest request =
                new MockHttpServletRequest("POST", "/api/auth/login");
        request.setQueryString("debug=secret-query-value");
        request.setContent("password=must-not-be-audited".getBytes());
        MockHttpServletResponse response = new MockHttpServletResponse();
        response.setStatus(400);

        interceptor.preHandle(request, response, new Object());
        interceptor.afterCompletion(request, response, new Object(), null);

        verify(auditService).logHttpOperation(
                isNull(),
                isNull(),
                eq("POST"),
                eq("/api/auth/login"),
                eq("api/auth/login"),
                eq(400),
                org.mockito.ArgumentMatchers.longThat(value -> value >= 0));
    }

    @Test
    void skipsSuccessfulReviewedAutomaticAuthRead() {
        MockHttpServletRequest request =
                new MockHttpServletRequest("GET", "/api/auth/me");
        request.setQueryString("include=private-query-value");
        MockHttpServletResponse response = new MockHttpServletResponse();

        interceptor.preHandle(request, response, new Object());
        interceptor.afterCompletion(request, response, new Object(), null);

        verifyNoInteractions(auditService);
    }

    @Test
    void skipsSuccessfulReviewedBadgePollButRetainsItsFailure() {
        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/api/production/schedule/pending-count");
        MockHttpServletResponse response = new MockHttpServletResponse();

        interceptor.preHandle(request, response, new Object());
        interceptor.afterCompletion(request, response, new Object(), null);
        verifyNoInteractions(auditService);

        response.setStatus(503);
        interceptor.preHandle(request, response, new Object());
        interceptor.afterCompletion(request, response, new Object(), null);
        verify(auditService).logHttpOperation(
                eq(userId), eq("auditor"), eq("GET"),
                eq("/api/production/schedule/pending-count"),
                eq("api/production/schedule"), eq(503),
                org.mockito.ArgumentMatchers.longThat(value -> value >= 0));
    }

    @Test
    void ordinaryBusinessWriteCannotBeSuppressedAsBackgroundNoise() {
        MockHttpServletRequest request =
                new MockHttpServletRequest("POST", "/api/sales/orders");
        MockHttpServletResponse response = new MockHttpServletResponse();

        interceptor.preHandle(request, response, new Object());
        interceptor.afterCompletion(request, response, new Object(), null);

        verify(auditService).logHttpOperation(
                eq(userId), eq("auditor"), eq("POST"),
                eq("/api/sales/orders"), eq("api/sales/orders"), eq(200),
                org.mockito.ArgumentMatchers.longThat(value -> value >= 0));
    }

    @Test
    void recordsUnhandledMvcExceptionAsServerFailureBeforeStatusIsRendered() {
        MockHttpServletRequest request =
                new MockHttpServletRequest("POST", "/api/orders");
        MockHttpServletResponse response = new MockHttpServletResponse();

        interceptor.preHandle(request, response, new Object());
        interceptor.afterCompletion(
                request,
                response,
                new Object(),
                new IllegalStateException("controller failed"));

        verify(auditService).logHttpOperation(
                eq(userId),
                eq("auditor"),
                eq("POST"),
                eq("/api/orders"),
                eq("api/orders"),
                eq(500),
                org.mockito.ArgumentMatchers.longThat(value -> value >= 0));
    }
}
