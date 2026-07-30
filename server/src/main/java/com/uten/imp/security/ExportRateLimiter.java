package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import io.github.bucket4j.Bandwidth;
import io.github.bucket4j.Bucket;
import io.github.bucket4j.Refill;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 导出限流：每用户每分钟 N 次（Bucket4j 令牌桶，per-userId）。
 *
 * <p>阈值 N 从系统设置 {@code export_rate_limit_per_minute} 动态读取（管理员可在「系统设置」页调整，
 * 立即生效——阈值变更后下次 check 重建桶）。
 *
 * <p>场景：导出是高成本数据外发，需防被盗账号/脚本短时大量导出（拖库/DoS）。
 */
@Component
public class ExportRateLimiter {

    private final SystemSettingsService settings;
    private final ConcurrentHashMap<UUID, Entry> buckets = new ConcurrentHashMap<>();

    private record Entry(Bucket bucket, int perMinute) {}

    /** 容量上限：防被构造大量不同 userId 撑爆内存。 */
    private static final int MAX_BUCKETS = 10_000;

    public ExportRateLimiter(SystemSettingsService settings) {
        this.settings = settings;
    }

    /** 消费 1 个令牌；不足抛 RATE_LIMITED。userId 为 null（未认证）则放行交由鉴权处理。 */
    public void check(UUID userId) {
        if (userId == null) return;
        int cur = Math.max(1, settings.readInt("export_rate_limit_per_minute", 10));
        if (buckets.size() > MAX_BUCKETS) {
            buckets.clear();
        }
        Entry e = buckets.computeIfAbsent(userId, k -> new Entry(newBucket(cur), cur));
        if (e.perMinute() != cur) { // 阈值被管理员改过 → 丢弃旧桶重建
            e = new Entry(newBucket(cur), cur);
            buckets.put(userId, e);
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
