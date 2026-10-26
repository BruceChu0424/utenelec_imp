package com.uten.imp.security;

import com.uten.imp.common.concurrency.BoundedIdleStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import io.github.bucket4j.Bucket;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.UUID;
import java.util.function.LongSupplier;

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
    private final BoundedIdleStore<UUID, Entry> buckets;

    private record Entry(Bucket bucket, int perMinute) {}

    /** 容量上限：防被构造大量不同 userId 撑爆内存。 */
    private static final int MAX_BUCKETS = 10_000;
    static final Duration IDLE_EXPIRY = Duration.ofMinutes(2);

    @org.springframework.beans.factory.annotation.Autowired
    public ExportRateLimiter(SystemSettingsService settings) {
        this(settings, System::nanoTime, MAX_BUCKETS);
    }

    ExportRateLimiter(SystemSettingsService settings, LongSupplier nanoTime, int maxEntries) {
        this.settings = settings;
        this.buckets = new BoundedIdleStore<>(maxEntries, IDLE_EXPIRY, nanoTime);
    }

    /** 消费 1 个令牌；不足抛 RATE_LIMITED。userId 为 null（未认证）则放行交由鉴权处理。 */
    public void check(UUID userId) {
        if (userId == null) return;
        int cur = Math.max(1, settings.readInt(SystemSettingKey.EXPORT_RATE_LIMIT_PER_MINUTE));
        Entry admitted = buckets.compute(userId, current -> {
            Entry entry = current != null && current.perMinute() == cur
                    ? current : new Entry(newBucket(cur), cur);
            if (!entry.bucket().tryConsume(1)) throw new ApiException(ErrorCode.RATE_LIMITED);
            return entry;
        });
        if (admitted == null) {
            throw new ApiException(ErrorCode.RATE_LIMITED);
        }
    }

    int size() {
        return buckets.size();
    }

    private Bucket newBucket(int perMinute) {
        return Bucket.builder()
                .addLimit(limit -> limit.capacity(perMinute)
                        .refillGreedy(perMinute, Duration.ofMinutes(1)))
                .build();
    }
}
