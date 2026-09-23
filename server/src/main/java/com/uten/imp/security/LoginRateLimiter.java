package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import io.github.bucket4j.Bucket;
import org.springframework.stereotype.Component;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.time.Duration;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.LongSupplier;

/**
 * 鉴权入口双层限流: 先扣每 IP 粗桶, 再扣每主体细桶 (security-13, ADR-110)。
 *
 * <p>IP 桶是「小容量 + 平滑回填」: 瞬间最多放行 {@value #IP_BURST_CAPACITY} 次, 之后按
 * {@code login_ip_rate_limit_per_minute} 每分钟匀速回填, 挡住瞬时并发洪峰, 又不让园区 NAT 下
 * 陆续登录的同事互相误伤。IP 超限直接拒绝, 不会为随机账号创建主体条目。主体桶按
 * {@code login_rate_limit_per_minute} 防单账号/手机号爆破。员工登录、访客发码、访客登录、
 * 官网询盘错误密钥各用独立 namespace。</p>
 *
 * <p>条目按访问过期: 超过 {@link #IDLE_EXPIRY} 没被访问的桶早已回满, 删除它等价于新建, 不丢状态。
 * 条目总数到上限时先清过期条目; 仍满说明正遭受海量新键攻击, 此时只拒绝需要新建条目的请求
 * (已有条目照常计数), 绝不整表清空重置全部限流状态。IPv6 按 /64 聚合。
 * 当前桶是单实例内存态, 本地与云端两个实例各算各的; 账号锁定计数在数据库, 两边共享。</p>
 */
@Component
public class LoginRateLimiter {

    public enum Scope {
        STAFF_LOGIN,
        VISITOR_SEND_CODE,
        VISITOR_LOGIN,
        /** 官网询盘推送的错误密钥 (只对失败计数)。 */
        WEBSITE_INGEST_FAILURE
    }

    static final int IP_BURST_CAPACITY = 20;
    static final int MAX_ENTRIES = 50_000;
    static final Duration IDLE_EXPIRY = Duration.ofMinutes(2);
    /** 官网询盘错误密钥: 每 IP 每分钟最多错 5 次。 */
    static final int INGEST_FAILURES_PER_MINUTE = 5;

    private final SystemSettingsService settings;
    private final LongSupplier nanoTime;
    private final int maxEntries;
    private final ConcurrentHashMap<String, Entry> buckets = new ConcurrentHashMap<>();

    private static final class Entry {
        private final Bucket bucket;
        private final int capacity;
        private final int perMinute;
        private volatile long lastAccessNanos;

        private Entry(int capacity, int perMinute, long now) {
            this.bucket = Bucket.builder()
                    .addLimit(limit -> limit.capacity(capacity)
                            .refillGreedy(perMinute, Duration.ofMinutes(1)))
                    .build();
            this.capacity = capacity;
            this.perMinute = perMinute;
            this.lastAccessNanos = now;
        }
    }

    @org.springframework.beans.factory.annotation.Autowired
    public LoginRateLimiter(SystemSettingsService settings) {
        this(settings, System::nanoTime, MAX_ENTRIES);
    }

    LoginRateLimiter(SystemSettingsService settings, LongSupplier nanoTime, int maxEntries) {
        this.settings = settings;
        this.nanoTime = nanoTime;
        this.maxEntries = maxEntries;
    }

    /** 登录/发码入口: IP 粗桶放行后才扣主体桶; 任一耗尽抛 429。 */
    public void check(Scope scope, String ip, String subject) {
        int subjectLimit = Math.max(1, settings.readInt(SystemSettingKey.LOGIN_RATE_LIMIT_PER_MINUTE));
        int ipLimit = Math.max(subjectLimit,
                settings.readInt(SystemSettingKey.LOGIN_IP_RATE_LIMIT_PER_MINUTE));
        consume("ip:" + scope + ':' + ipKey(ip), Math.min(IP_BURST_CAPACITY, ipLimit), ipLimit);
        consume("subject:" + scope + ':' + subjectKey(subject), subjectLimit, subjectLimit);
    }

    /** 该 IP 在这个失败计数空间里还有没有余量 (不扣减)。没有余量时连正确的请求也先挡住。 */
    public void requireNotExhausted(Scope scope, String ip) {
        Entry entry = buckets.get("ip:" + scope + ':' + ipKey(ip));
        if (entry != null && entry.bucket.getAvailableTokens() < 1) {
            throw new ApiException(ErrorCode.RATE_LIMITED);
        }
    }

    /** 记一次失败 (只对失败计数的空间用); 超限抛 429。 */
    public void recordFailure(Scope scope, String ip) {
        consume("ip:" + scope + ':' + ipKey(ip), INGEST_FAILURES_PER_MINUTE, INGEST_FAILURES_PER_MINUTE);
    }

    private void consume(String key, int capacity, int perMinute) {
        long now = nanoTime.getAsLong();
        Entry entry = buckets.get(key);
        if (entry == null || entry.capacity != capacity || entry.perMinute != perMinute) {
            if (entry == null && buckets.size() >= maxEntries) {
                evictIdle(now);
                if (buckets.size() >= maxEntries) {
                    // 海量新键攻击: 拒绝新建条目, 保住已有条目的计数。
                    throw new ApiException(ErrorCode.RATE_LIMITED);
                }
            }
            Entry fresh = new Entry(capacity, perMinute, now);
            entry = entry == null
                    ? buckets.computeIfAbsent(key, ignored -> fresh)
                    : buckets.merge(key, fresh, (current, replacement) ->
                            current.capacity == capacity && current.perMinute == perMinute
                                    ? current : replacement);
        }
        entry.lastAccessNanos = now;
        if (!entry.bucket.tryConsume(1)) {
            throw new ApiException(ErrorCode.RATE_LIMITED);
        }
    }

    private void evictIdle(long now) {
        long expiry = IDLE_EXPIRY.toNanos();
        buckets.entrySet().removeIf(e -> now - e.getValue().lastAccessNanos > expiry);
    }

    int size() {
        return buckets.size();
    }

    private static String subjectKey(String subject) {
        String normalized = subject == null
                ? "unknown"
                : subject.strip().toLowerCase(Locale.ROOT);
        // 不把账号或手机号明文长期留在限流 Map key 中。
        return com.uten.imp.common.util.HashUtil.sha256(normalized);
    }

    /** IPv4 原样; IPv6 取 /64 前缀 (同一用户/家庭通常拥有整个 /64)。只解析数字字面量, 不做 DNS。 */
    static String ipKey(String ip) {
        if (ip == null || ip.isBlank()) {
            return "unknown";
        }
        String value = ip.strip();
        if (!value.contains(":") || !value.matches("[0-9A-Fa-f:.%]+")) {
            return value;
        }
        String literal = value.contains("%") ? value.substring(0, value.indexOf('%')) : value;
        try {
            byte[] bytes = InetAddress.getByName(literal).getAddress();
            if (bytes.length != 16) {
                return value;
            }
            StringBuilder prefix = new StringBuilder("v6:");
            for (int i = 0; i < 8; i += 2) {
                prefix.append(String.format("%02x%02x", bytes[i], bytes[i + 1]));
                if (i < 6) prefix.append(':');
            }
            return prefix.append("::/64").toString();
        } catch (UnknownHostException invalid) {
            return value;
        }
    }
}
