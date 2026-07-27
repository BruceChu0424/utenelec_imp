package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import io.github.bucket4j.Bandwidth;
import io.github.bucket4j.Bucket;
import io.github.bucket4j.Refill;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 登录限流：每 IP 每分钟 N 次（Bucket4j，per-IP 防爆破登录）。
 *
 * <p>阈值 N 从系统设置 {@code login_rate_limit_per_minute} 动态读取（管理员可在「系统设置」页调整，
 * 立即生效——阈值变更后下次 check 重建桶）。
 */
@Component
public class LoginRateLimiter {

    private final SystemSettingsService settings;
    private final ConcurrentHashMap<String, Entry> buckets = new ConcurrentHashMap<>();

    private record Entry(Bucket bucket, int perMinute) {}

    private static final int MAX_BUCKETS = 50_000;

    public LoginRateLimiter(SystemSettingsService settings) {
        this.settings = settings;
    }

    public void check(String ip) {
        int cur = Math.max(1, settings.readInt("login_rate_limit_per_minute", 5));
        // 防御性：超出容量则整体重置（接受短暂放开，杜绝内存耗尽）
        if (buckets.size() > MAX_BUCKETS) {
            buckets.clear();
        }
        Entry e = buckets.computeIfAbsent(ip, k -> new Entry(newBucket(cur), cur));
        if (e.perMinute() != cur) { // 阈值被管理员改过 → 重建桶
            e = new Entry(newBucket(cur), cur);
            buckets.put(ip, e);
        }
        if (!e.bucket().tryConsume(1)) {
            throw new ApiException(ErrorCode.RATE_LIMITED);
        }
    }

    private Bucket newBucket(int perMinute) {
        Bandwidth limit = Bandwidth.classic(perMinute, Refill.greedy(perMinute, Duration.ofMinutes(1)));
        return Bucket.builder().addLimit(limit).build();
    }
}
