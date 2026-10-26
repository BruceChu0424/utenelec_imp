package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class VisitorDirectoryRateLimiterTest {
    @Test
    void rotatingOtherAccountsAndAddressesCannotRestoreAnExhaustedQuota() {
        VisitorDirectoryRateLimiter limiter = new VisitorDirectoryRateLimiter();
        UUID exhausted = UUID.randomUUID();
        for (int i = 0; i < VisitorDirectoryRateLimiter.PER_ACCOUNT_PER_MINUTE; i++) {
            limiter.check(exhausted, "192.0.2.1");
        }
        assertThrows(ApiException.class, () -> limiter.check(exhausted, "192.0.2.1"));

        for (int i = 0; i < 10_010; i++) {
            try {
                limiter.check(UUID.randomUUID(), "address-" + i);
            } catch (ApiException full) {
                assertEquals(ErrorCode.RATE_LIMITED, full.getCode());
            }
        }

        assertThrows(ApiException.class, () -> limiter.check(exhausted, "192.0.2.1"));
    }

    @Test
    void idleReclamationKeepsAccountStateForTheDailyRefillWindow() {
        AtomicLong now = new AtomicLong();
        var limiter = new VisitorDirectoryRateLimiter(now::get, 2);
        UUID account = UUID.randomUUID();
        limiter.check(account, "192.0.2.1");

        for (int i = 1; i < VisitorDirectoryRateLimiter.PER_ACCOUNT_PER_MINUTE; i++) {
            limiter.check(account, "192.0.2.1");
        }
        now.set(Duration.ofHours(23).toNanos());
        assertThrows(ApiException.class, () -> limiter.check(UUID.randomUUID(), "192.0.2.2"));
        assertThrows(ApiException.class, () -> limiter.check(account, "192.0.2.1"));
        assertEquals(2, limiter.size());

        now.addAndGet(VisitorDirectoryRateLimiter.IDLE_EXPIRY.toNanos() + 1);
        assertDoesNotThrow(() -> limiter.check(UUID.randomUUID(), "192.0.2.2"));
        assertEquals(2, limiter.size());
    }
}
