package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import org.junit.jupiter.api.Test;

import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** 导出限流（令牌桶 per-userId，阈值读系统设置）：验证上限拦截、用户隔离、null 放行。 */
class ExportRateLimiterTest {

    // stub：readInt 返回指定每分钟上限（绕过 DB），其余方法本测试不触达。
    private ExportRateLimiter limiter(int perMinute) {
        SystemSettingsService settings = org.mockito.Mockito.mock(SystemSettingsService.class);
        org.mockito.Mockito.when(settings.readInt(
                com.uten.imp.features.admin.systemsetting.SystemSettingKey.EXPORT_RATE_LIMIT_PER_MINUTE))
                .thenReturn(perMinute);
        return new ExportRateLimiter(settings);
    }

    @Test
    void allowsUpToLimitThenBlocks() {
        ExportRateLimiter l = limiter(3);
        UUID u = UUID.randomUUID();
        assertDoesNotThrow(() -> l.check(u));
        assertDoesNotThrow(() -> l.check(u));
        assertDoesNotThrow(() -> l.check(u));
        // 第 4 次：超每分钟上限 → ApiException(RATE_LIMITED/429)
        assertThrows(ApiException.class, () -> l.check(u));
    }

    @Test
    void perUserIsolated() {
        ExportRateLimiter l = limiter(2);
        UUID a = UUID.randomUUID();
        UUID b = UUID.randomUUID();
        l.check(a);
        l.check(a); // a 用尽本分钟配额
        assertThrows(ApiException.class, () -> l.check(a)); // a 被限
        assertDoesNotThrow(() -> l.check(b)); // b 独立桶，不受 a 影响
    }

    @Test
    void nullUserPasses() {
        ExportRateLimiter l = limiter(1);
        // 未认证（userId 为空）放行，交由后续鉴权 401/403 处理（限流只拦已认证用户）
        assertDoesNotThrow(() -> l.check(null));
    }

    @Test
    void aFloodOfOtherUsersCannotRestoreAnExhaustedUsersQuota() {
        ExportRateLimiter limiter = limiter(1);
        UUID exhausted = UUID.randomUUID();
        limiter.check(exhausted);
        assertThrows(ApiException.class, () -> limiter.check(exhausted));

        for (int i = 0; i < 10_010; i++) {
            try {
                limiter.check(UUID.randomUUID());
            } catch (ApiException full) {
                assertEquals(com.uten.imp.common.web.ErrorCode.RATE_LIMITED, full.getCode());
            }
        }

        assertThrows(ApiException.class, () -> limiter.check(exhausted));
    }

    @Test
    void idleFullBucketsAreReclaimedWithoutResettingActiveBuckets() {
        var settings = org.mockito.Mockito.mock(SystemSettingsService.class);
        org.mockito.Mockito.when(settings.readInt(
                com.uten.imp.features.admin.systemsetting.SystemSettingKey.EXPORT_RATE_LIMIT_PER_MINUTE))
                .thenReturn(1);
        AtomicLong now = new AtomicLong();
        var limiter = new ExportRateLimiter(settings, now::get, 2);
        UUID active = UUID.randomUUID();
        limiter.check(active);
        limiter.check(UUID.randomUUID());
        now.set(ExportRateLimiter.IDLE_EXPIRY.toNanos() / 2);
        assertThrows(ApiException.class, () -> limiter.check(active));
        now.set(ExportRateLimiter.IDLE_EXPIRY.toNanos() + 1);

        assertDoesNotThrow(() -> limiter.check(UUID.randomUUID()));
        assertThrows(ApiException.class, () -> limiter.check(active));
        assertEquals(2, limiter.size());
    }

    @Test
    void configuredLimitChangesStillRebuildOnlyThatUsersBucket() {
        var settings = org.mockito.Mockito.mock(SystemSettingsService.class);
        AtomicInteger configured = new AtomicInteger(1);
        org.mockito.Mockito.when(settings.readInt(
                com.uten.imp.features.admin.systemsetting.SystemSettingKey.EXPORT_RATE_LIMIT_PER_MINUTE))
                .thenAnswer(ignored -> configured.get());
        var limiter = new ExportRateLimiter(settings);
        UUID user = UUID.randomUUID();
        limiter.check(user);
        assertThrows(ApiException.class, () -> limiter.check(user));
        configured.set(3);

        for (int i = 0; i < 3; i++) limiter.check(user);
        assertThrows(ApiException.class, () -> limiter.check(user));
        assertEquals(1, limiter.size());
    }
}
