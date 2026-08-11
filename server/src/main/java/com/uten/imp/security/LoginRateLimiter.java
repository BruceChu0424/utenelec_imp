package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import io.github.bucket4j.Bucket;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 鉴权入口双层限流：每主体低阈值 + 每 IP 高阈值。
 *
 * <p>主体桶防单账号/手机号爆破；IP 桶以更高阈值防账号喷洒，又不会让园区 NAT 或运营商
 * CGNAT 下少量不同用户共享一个 5 次/分钟的桶。员工登录、访客发码和访客登录使用独立
 * namespace，互不挤占。
 *
 * <p>主体阈值从 {@code login_rate_limit_per_minute} 动态读取；IP 粗桶由
 * {@code login_ip_rate_limit_per_minute} 独立配置，默认 300 次/分钟。
 * 当前桶是单实例内存态，多实例生产仍需共享限流存储或网关兜底。
 */
@Component
public class LoginRateLimiter {

    public enum Scope {
        STAFF_LOGIN,
        VISITOR_SEND_CODE,
        VISITOR_LOGIN
    }

    private final SystemSettingsService settings;
    private final ConcurrentHashMap<String, Entry> buckets = new ConcurrentHashMap<>();

    private record Entry(Bucket bucket, int perMinute) {}

    private static final int MAX_BUCKETS = 50_000;

    public LoginRateLimiter(SystemSettingsService settings) {
        this.settings = settings;
    }

    public void check(Scope scope, String ip, String subject) {
        int subjectLimit = Math.max(
                1,
                settings.readInt("login_rate_limit_per_minute", 5));
        int ipLimit = Math.max(
                subjectLimit,
                settings.readInt("login_ip_rate_limit_per_minute", 300));
        // 防御性：超出容量则整体重置（接受短暂放开，杜绝内存耗尽）
        if (buckets.size() > MAX_BUCKETS) {
            buckets.clear();
        }

        // 先消耗主体桶：持续轰炸一个账号不会把共享 IP 桶耗尽，降低 NAT 用户互相误伤。
        consume("subject:" + scope + ':' + subjectKey(subject), subjectLimit);
        consume("ip:" + scope + ':' + normalizeIp(ip), ipLimit);
    }

    private void consume(String key, int perMinute) {
        Entry entry = buckets.computeIfAbsent(
                key,
                ignored -> new Entry(newBucket(perMinute), perMinute));
        if (entry.perMinute() != perMinute) {
            entry = new Entry(newBucket(perMinute), perMinute);
            buckets.put(key, entry);
        }
        if (!entry.bucket().tryConsume(1)) {
            throw new ApiException(ErrorCode.RATE_LIMITED);
        }
    }

    private static String subjectKey(String subject) {
        String normalized = subject == null
                ? "unknown"
                : subject.strip().toLowerCase(Locale.ROOT);
        // 不把账号或手机号明文长期留在限流 Map key 中。
        return com.uten.imp.common.util.HashUtil.sha256(normalized);
    }

    private static String normalizeIp(String ip) {
        return ip == null || ip.isBlank() ? "unknown" : ip.strip();
    }

    private static Bucket newBucket(int perMinute) {
        return Bucket.builder()
                .addLimit(limit -> limit.capacity(perMinute)
                        .refillGreedy(perMinute, Duration.ofMinutes(1)))
                .build();
    }
}
