package com.uten.imp.audit;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.ArgumentMatchers.longThat;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class AuditRequestContextFilterTest {

    private AuditService auditService;
    private SecurityContextCurrentUser currentUser;
    private AuditRequestContextFilter filter;

    @BeforeEach
    void setUp() {
        auditService = mock(AuditService.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.empty());
        filter = new AuditRequestContextFilter(
                new AuditDeviceContext(new ObjectMapper().findAndRegisterModules()),
                currentUser,
                auditService);
    }

    @Test
    void recordsAnonymousRequestRejectedBySecurityBeforeMvc() throws Exception {
        MockHttpServletRequest request =
                new MockHttpServletRequest("GET", "/api/auth/me");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = (req, resp) -> response.setStatus(401);

        filter.doFilter(request, response, chain);

        verify(auditService).logHttpOperation(
                isNull(),
                isNull(),
                eq("GET"),
                eq("/api/auth/me"),
                eq("api/auth/me"),
                eq(401),
                longThat(value -> value >= 0));
    }

    @Test
    void recordsHeadRequestThatNeverReachesMvc() throws Exception {
        MockHttpServletRequest request =
                new MockHttpServletRequest("HEAD", "/api/missing");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = (req, resp) -> response.setStatus(405);

        filter.doFilter(request, response, chain);

        verify(auditService).logHttpOperation(
                isNull(),
                isNull(),
                eq("HEAD"),
                eq("/api/missing"),
                eq("api/missing"),
                eq(405),
                longThat(value -> value >= 0));
    }

    @Test
    void recordsUnhandledPreMvcExceptionAsServerFailure() throws Exception {
        MockHttpServletRequest request =
                new MockHttpServletRequest("POST", "/api/orders");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = (req, resp) -> {
            throw new ServletException("pre-MVC failure");
        };

        assertThrows(
                ServletException.class,
                () -> filter.doFilter(request, response, chain));

        verify(auditService).logHttpOperation(
                isNull(),
                isNull(),
                eq("POST"),
                eq("/api/orders"),
                eq("api/orders"),
                eq(500),
                longThat(value -> value >= 0));
    }

    @Test
    void auditCenterSuccessUsesExplicitControllerEventWithoutGenericHttpDuplicate()
            throws Exception {
        UUID userId = UUID.randomUUID();
        AuthUser user = mock(AuthUser.class);
        when(user.getId()).thenReturn(userId);
        when(user.getLoginAccount()).thenReturn("auditor");
        when(currentUser.get()).thenReturn(Optional.of(user));
        UserOperationAuditInterceptor interceptor =
                new UserOperationAuditInterceptor(currentUser, auditService);
        MockHttpServletRequest request =
                new MockHttpServletRequest("GET", "/api/admin/audit-logs");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = (req, resp) -> {
            interceptor.preHandle(request, response, new Object());
            interceptor.afterCompletion(request, response, new Object(), null);
        };

        filter.doFilter(request, response, chain);

        verifyNoInteractions(auditService);
    }

    @Test
    void successfulHeartbeatIsNoiseButHeartbeatFailureIsRetained() throws Exception {
        MockHttpServletRequest success = new MockHttpServletRequest(
                "POST", "/api/task-claims/EXPENSE_APPROVE/abc/heartbeat");
        MockHttpServletResponse successResponse = new MockHttpServletResponse();
        filter.doFilter(success, successResponse, (req, resp) -> { });
        verifyNoInteractions(auditService);

        MockHttpServletRequest failed = new MockHttpServletRequest(
                "POST", "/api/task-claims/EXPENSE_APPROVE/abc/heartbeat");
        MockHttpServletResponse failedResponse = new MockHttpServletResponse();
        filter.doFilter(failed, failedResponse, (req, resp) -> failedResponse.setStatus(409));
        verify(auditService).logHttpOperation(
                isNull(), isNull(), eq("POST"),
                eq("/api/task-claims/EXPENSE_APPROVE/abc/heartbeat"),
                eq("api/task-claims/EXPENSE_APPROVE"), eq(409),
                longThat(value -> value >= 0));
    }

    @Test
    void reviewedStageCountsAreSuppressedOnlyOnSuccess() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/api/sales/orders/progress/stage-counts");
        MockHttpServletResponse response = new MockHttpServletResponse();
        filter.doFilter(request, response, (req, resp) -> { });
        verifyNoInteractions(auditService);
    }

    @Test
    void auditSinkFailureDoesNotReplaceCompletedBusinessResponse() throws Exception {
        doThrow(new IllegalStateException("audit unavailable"))
                .when(auditService)
                .logHttpOperation(
                        isNull(),
                        isNull(),
                        eq("DELETE"),
                        eq("/api/orders/1"),
                        eq("api/orders/1"),
                        eq(204),
                        longThat(value -> value >= 0));
        MockHttpServletRequest request =
                new MockHttpServletRequest("DELETE", "/api/orders/1");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = (req, resp) -> response.setStatus(204);

        assertDoesNotThrow(() -> filter.doFilter(request, response, chain));
    }

    @Test
    void ignoresNonApiAndUnsupportedMethods() throws Exception {
        MockHttpServletRequest request =
                new MockHttpServletRequest("OPTIONS", "/api/orders");
        MockHttpServletResponse response = new MockHttpServletResponse();

        filter.doFilter(request, response, (req, resp) -> { });

        verifyNoInteractions(auditService);
    }
}
