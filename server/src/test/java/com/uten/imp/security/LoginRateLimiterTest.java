package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class LoginRateLimiterTest {

    private LoginRateLimiter limiter;

    @BeforeEach
    void setUp() {
        SystemSettingsService settings = mock(SystemSettingsService.class);
        when(settings.readInt("login_rate_limit_per_minute", 5)).thenReturn(5);
        when(settings.readInt("login_ip_rate_limit_per_minute", 300))
                .thenReturn(300);
        limiter = new LoginRateLimiter(settings);
    }

    @Test
    void repeatedAttemptsForOneSubjectHitTheLowThreshold() {
        for (int attempt = 0; attempt < 5; attempt++) {
            limiter.check(
                    LoginRateLimiter.Scope.STAFF_LOGIN,
                    "203.0.113.10",
                    "same-account");
        }

        assertThrows(
                ApiException.class,
                () -> limiter.check(
                        LoginRateLimiter.Scope.STAFF_LOGIN,
                        "203.0.113.10",
                        "same-account"));
    }

    @Test
    void manyDifferentUsersBehindOneNatDoNotShareTheLowBucket() {
        assertDoesNotThrow(() -> {
            for (int subject = 0; subject < 120; subject++) {
                limiter.check(
                        LoginRateLimiter.Scope.STAFF_LOGIN,
                        "203.0.113.20",
                        "account-" + subject);
            }
        });
    }

    @Test
    void staffAndVisitorAuthenticationUseIndependentNamespaces() {
        for (int attempt = 0; attempt < 5; attempt++) {
            limiter.check(
                    LoginRateLimiter.Scope.STAFF_LOGIN,
                    "203.0.113.30",
                    "13800138000");
        }

        assertDoesNotThrow(() -> limiter.check(
                LoginRateLimiter.Scope.VISITOR_LOGIN,
                "203.0.113.30",
                "13800138000"));
        assertDoesNotThrow(() -> limiter.check(
                LoginRateLimiter.Scope.VISITOR_SEND_CODE,
                "203.0.113.30",
                "13800138000"));
    }
}
