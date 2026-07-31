package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** 导出限流（令牌桶 per-userId，阈值读系统设置）：验证上限拦截、用户隔离、null 放行。 */
class ExportRateLimiterTest {

    // stub：readInt 返回指定每分钟上限（绕过 DB），其余方法本测试不触达。
    private ExportRateLimiter limiter(int perMinute) {
        SystemSettingsService settings =
                new SystemSettingsService(null, null, null, null, null) {
            @Override public int readInt(String key, int def) { return perMinute; }
        };
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
}
