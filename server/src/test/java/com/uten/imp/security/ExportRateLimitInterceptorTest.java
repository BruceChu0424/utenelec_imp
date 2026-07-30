package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ExportRateLimitInterceptorTest {

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
        return request;
    }
}
