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
import static org.mockito.ArgumentMatchers.startsWith;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class UserOperationAuditInterceptorTest {

    private AuditService auditService;
    private UserOperationAuditInterceptor interceptor;
    private UUID userId;

    @BeforeEach
    void setUp() {
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
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

        verify(auditService).logExplicit(
                eq(userId),
                eq("auditor"),
                eq("http_patch"),
                eq("api/sales/orders"),
                eq("/api/sales/orders/123"),
                startsWith("failure:409:"));
    }

    @Test
    void ignoresReadOnlyRequest() {
        MockHttpServletRequest request =
                new MockHttpServletRequest("GET", "/api/sales/orders/123");
        MockHttpServletResponse response = new MockHttpServletResponse();

        interceptor.preHandle(request, response, new Object());
        interceptor.afterCompletion(request, response, new Object(), null);

        verify(auditService, never()).logExplicit(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any());
    }
}
