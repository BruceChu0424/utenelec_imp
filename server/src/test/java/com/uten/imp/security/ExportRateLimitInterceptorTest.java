package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.export.LegacyExportBudget;
import com.uten.imp.common.export.LegacyExportRows;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.method.HandlerMethod;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ExportRateLimitInterceptorTest {

    @Test void theSourceBudgetStartsBeforeControllerBodyHandlingAndClosesOnItsFailure() {
        var users = mock(SecurityContextCurrentUser.class);
        when(users.id()).thenReturn(Optional.of(UUID.randomUUID()));
        var interceptor = new ExportRateLimitInterceptor(mock(ExportRateLimiter.class), users, 1);
        var request = postRequest(); var response = mock(HttpServletResponse.class);
        assertTrue(interceptor.preHandle(request, response, new Object()));
        assertTrue(LegacyExportBudget.active());
        assertThrows(ApiException.class, () -> LegacyExportBudget.requireRows(501));
        interceptor.afterCompletion(request, response, new Object(), new IllegalArgumentException("synthetic malformed body"));
        org.junit.jupiter.api.Assertions.assertFalse(LegacyExportBudget.active());
        interceptor.afterCompletion(request, response, new Object(), null);
        var retry = postRequest();
        assertTrue(interceptor.preHandle(retry, response, new Object()));
        interceptor.afterCompletion(retry, response, new Object(), null);
    }

    static class NaturalDocument {
        @LegacyExportRows(2000) public void export() { }
    }
    @Test void anExplicitExistingNaturalDocumentBoundDoesNotBecomeAnInventedCollectionLimit() throws Exception {
        var users = mock(SecurityContextCurrentUser.class);
        when(users.id()).thenReturn(Optional.of(UUID.randomUUID()));
        var interceptor = new ExportRateLimitInterceptor(mock(ExportRateLimiter.class), users, 1);
        var request = postRequest(); var response = mock(HttpServletResponse.class);
        var handler = new HandlerMethod(new NaturalDocument(), NaturalDocument.class.getMethod("export"));
        assertTrue(interceptor.preHandle(request, response, handler));
        org.junit.jupiter.api.Assertions.assertEquals(2000, LegacyExportBudget.maximumRows(100000));
        LegacyExportBudget.requireRows(2000);
        interceptor.afterCompletion(request, response, handler, null);
    }

    @Test
    void rejectsConcurrentExportAndReleasesPermitAfterCompletion() {
        ExportRateLimiter rateLimiter = mock(ExportRateLimiter.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        UUID userId = UUID.randomUUID();
        when(currentUser.id()).thenReturn(Optional.of(userId));

        ExportRateLimitInterceptor interceptor =
                new ExportRateLimitInterceptor(rateLimiter, currentUser, 1);
        HttpServletRequest first = postRequest();
        HttpServletRequest second = postRequest();
        HttpServletResponse response = mock(HttpServletResponse.class);
        Object handler = new Object();

        assertTrue(interceptor.preHandle(first, response, handler));
        assertThrows(
                ApiException.class,
                () -> interceptor.preHandle(second, response, handler));

        interceptor.afterCompletion(first, response, handler, null);
        assertTrue(interceptor.preHandle(second, response, handler));
        interceptor.afterCompletion(second, response, handler, null);

        verify(rateLimiter, org.mockito.Mockito.times(3)).check(userId);
    }

    private HttpServletRequest postRequest() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setMethod("POST");
        request.setRequestURI("/api/sales/reports/export");
        return request;
    }
}
