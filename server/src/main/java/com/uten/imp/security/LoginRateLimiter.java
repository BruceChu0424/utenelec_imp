package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SecurityProperties;
import io.github.bucket4j.Bandwidth;
import io.github.bucket4j.Bucket;
import io.github.bucket4j.Refill;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.concurrent.ConcurrentHashMap;

/** 登录限流：每 IP 每分钟 N 次（Bucket4j）。超限返回 RATE_LIMITED。 */
@Component
public class LoginRateLimiter {

    private final ConcurrentHashMap<String, Bucket> buckets = new ConcurrentHashMap<>();
    private final int perMinute;

    public LoginRateLimiter(SecurityProperties props) {
        this.perMinute = Math.max(1, props.getLoginRateLimitPerMinute());
    }

    /** 容量上限：防止被构造大量不同 key 撑爆内存（OOM）。 */
    private static final int MAX_BUCKETS = 50_000;

    public void check(String ip) {
        // 防御性：超出容量则整体重置（接受短暂放开，杜绝内存耗尽）
        if (buckets.size() > MAX_BUCKETS) {
            buckets.clear();
        }
        Bucket bucket = buckets.computeIfAbsent(ip, k -> {
            Bandwidth limit = Bandwidth.classic(perMinute, Refill.greedy(perMinute, Duration.ofMinutes(1)));
            return Bucket.builder().addLimit(limit).build();
        });
        if (!bucket.tryConsume(1)) {
            throw new ApiException(ErrorCode.RATE_LIMITED);
        }
    }
}
