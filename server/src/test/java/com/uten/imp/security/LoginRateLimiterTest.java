package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** 鉴权入口限流 (security-13, ADR-110): 先 IP 后主体、小容量平滑回填、按访问过期、IPv6 /64 聚合。 */
class LoginRateLimiterTest {

    private SystemSettingsService settings;
    private LoginRateLimiter limiter;

    @BeforeEach
    void setUp() {
        settings = mock(SystemSettingsService.class);
        when(settings.readInt(SystemSettingKey.LOGIN_RATE_LIMIT_PER_MINUTE)).thenReturn(5);
        when(settings.readInt(SystemSettingKey.LOGIN_IP_RATE_LIMIT_PER_MINUTE))
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
    void differentUsersBehindOneNatShareOnlyASmallBurstOfTheIpBucket() {
        // 园区 NAT 下不同同事各有自己的 5 次主体额度; IP 粗桶瞬间只放行 20 次,
        // 之后按每分钟 300 次匀速回填 (挡住瞬时并发洪峰)。
        assertDoesNotThrow(() -> {
            for (int subject = 0; subject < LoginRateLimiter.IP_BURST_CAPACITY; subject++) {
                limiter.check(
                        LoginRateLimiter.Scope.STAFF_LOGIN,
                        "203.0.113.20",
                        "account-" + subject);
            }
        });
        ApiException burst = assertThrows(ApiException.class, () -> limiter.check(
                LoginRateLimiter.Scope.STAFF_LOGIN, "203.0.113.20", "account-next"));
        assertEquals(ErrorCode.RATE_LIMITED, burst.getCode());
    }

    @Test
    void exhaustedIpBucketRejectsBeforeCreatingSubjectEntries() {
        LoginRateLimiter bounded = new LoginRateLimiter(settings, System::nanoTime, 50_000);
        for (int i = 0; i < LoginRateLimiter.IP_BURST_CAPACITY; i++) {
            bounded.check(LoginRateLimiter.Scope.STAFF_LOGIN, "198.51.100.7", "user-" + i);
        }
        int entriesAfterBurst = bounded.size();

        for (int i = 0; i < 1_000; i++) {
            int n = i;
            assertThrows(ApiException.class, () -> bounded.check(
                    LoginRateLimiter.Scope.STAFF_LOGIN, "198.51.100.7", "random-" + n));
        }

        // IP 超限直接拒绝: 1000 个随机账号一个主体条目都没新建
        assertEquals(entriesAfterBurst, bounded.size());
    }

    @Test
    void floodOfNewKeysNeverResetsAnExistingSubjectBucket() {
        AtomicLong now = new AtomicLong(0);
        LoginRateLimiter bounded = new LoginRateLimiter(settings, now::get, 300);
        for (int attempt = 0; attempt < 5; attempt++) {
            bounded.check(LoginRateLimiter.Scope.STAFF_LOGIN, "192.0.2.1", "victim");
        }
        // 攻击者用大量不同 IP + 随机账号填满条目表 (旧实现满 5 万即整表清空, 受害账号额度被重置)
        for (int i = 0; i < 1_000; i++) {
            int n = i;
            try {
                bounded.check(LoginRateLimiter.Scope.STAFF_LOGIN, "10.9." + (n / 250) + "." + (n % 250),
                        "random-" + n);
            } catch (ApiException expectedWhenFull) {
                assertEquals(ErrorCode.RATE_LIMITED, expectedWhenFull.getCode());
            }
        }
        assertTrue(bounded.size() <= 300, "条目表有界");

        ApiException victim = assertThrows(ApiException.class, () -> bounded.check(
                LoginRateLimiter.Scope.STAFF_LOGIN, "192.0.2.1", "victim"));
        assertEquals(ErrorCode.RATE_LIMITED, victim.getCode());
    }

    @Test
    void idleEntriesExpireInsteadOfAWholesaleClear() {
        AtomicLong now = new AtomicLong(0);
        LoginRateLimiter bounded = new LoginRateLimiter(settings, now::get, 4);
        bounded.check(LoginRateLimiter.Scope.STAFF_LOGIN, "192.0.2.10", "a");
        assertEquals(2, bounded.size());
        // 超过 2 分钟没被访问的桶早已回满, 表满时按过期清理, 新请求照常计数
        now.addAndGet(LoginRateLimiter.IDLE_EXPIRY.toNanos() + 1);
        bounded.check(LoginRateLimiter.Scope.STAFF_LOGIN, "192.0.2.11", "b");
        bounded.check(LoginRateLimiter.Scope.STAFF_LOGIN, "192.0.2.12", "c");
        assertEquals(4, bounded.size());
    }

    @Test
    void ipv6AddressesInTheSameSlash64ShareOneBucket() {
        assertEquals(
                LoginRateLimiter.ipKey("2001:db8:1:2:aaaa::1"),
                LoginRateLimiter.ipKey("2001:db8:1:2:bbbb:cccc:dddd:eeee"));
        assertTrue(!LoginRateLimiter.ipKey("2001:db8:1:2::1")
                .equals(LoginRateLimiter.ipKey("2001:db8:1:3::1")));
        assertEquals("203.0.113.9", LoginRateLimiter.ipKey("203.0.113.9"));
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

    @Test
    void ingestFailuresAreLimitedPerSourceIp() {
        for (int failure = 0; failure < LoginRateLimiter.INGEST_FAILURES_PER_MINUTE; failure++) {
            limiter.requireNotExhausted(LoginRateLimiter.Scope.WEBSITE_INGEST_FAILURE, "203.0.113.40");
            limiter.recordFailure(LoginRateLimiter.Scope.WEBSITE_INGEST_FAILURE, "203.0.113.40");
        }
        // 第 6 次 (哪怕这次密钥正确) 先被 429 挡住
        ApiException blocked = assertThrows(ApiException.class, () -> limiter.requireNotExhausted(
                LoginRateLimiter.Scope.WEBSITE_INGEST_FAILURE, "203.0.113.40"));
        assertEquals(ErrorCode.RATE_LIMITED, blocked.getCode());
        assertDoesNotThrow(() -> limiter.requireNotExhausted(
                LoginRateLimiter.Scope.WEBSITE_INGEST_FAILURE, "203.0.113.41"));
    }
}
