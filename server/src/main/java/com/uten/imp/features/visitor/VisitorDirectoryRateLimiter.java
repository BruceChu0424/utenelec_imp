package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import io.github.bucket4j.Bucket;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 访客搜索接待人的限流(security-08)：访客账号靠短信自助注册，名单查询必须限速，
 * 否则脚本换着两字前缀就能把白名单里的人一个个试出来。
 *
 * <p>两层桶：每个访客账号每分钟 {@value #PER_ACCOUNT_PER_MINUTE} 次、每天 {@value #PER_ACCOUNT_PER_DAY} 次；
 * 每个来源地址每分钟 {@value #PER_IP_PER_MINUTE} 次(防同一台机器换号批量注册后轮流查)。
 * 正常访客填一张申请只搜一两次，远达不到上限。与登录限流一样是单实例内存态(ADR-031 单主库部署)。
 */
@Component
class VisitorDirectoryRateLimiter {

    static final int PER_ACCOUNT_PER_MINUTE = 10;
    static final int PER_ACCOUNT_PER_DAY = 60;
    static final int PER_IP_PER_MINUTE = 30;

    /** 容量上限：防被构造大量不同键撑爆内存(超出即整体重置)。 */
    private static final int MAX_BUCKETS = 20_000;

    private final ConcurrentHashMap<String, Bucket> buckets = new ConcurrentHashMap<>();

    /** 消耗一次查询额度；任一桶耗尽抛 {@link ErrorCode#RATE_LIMITED}。 */
    void check(UUID visitorAccountId, String clientIp) {
        if (buckets.size() > MAX_BUCKETS) {
            buckets.clear();
        }
        consume("account:" + visitorAccountId, this::accountBucket);
        consume("ip:" + (clientIp == null || clientIp.isBlank() ? "unknown" : clientIp.strip()),
                this::ipBucket);
    }

    private void consume(String key, java.util.function.Supplier<Bucket> factory) {
        if (!buckets.computeIfAbsent(key, ignored -> factory.get()).tryConsume(1)) {
            throw new ApiException(ErrorCode.RATE_LIMITED, "查询太频繁了，请稍后再搜接待人");
        }
    }

    private Bucket accountBucket() {
        return Bucket.builder()
                .addLimit(limit -> limit.capacity(PER_ACCOUNT_PER_MINUTE)
                        .refillGreedy(PER_ACCOUNT_PER_MINUTE, Duration.ofMinutes(1)))
                .addLimit(limit -> limit.capacity(PER_ACCOUNT_PER_DAY)
                        .refillIntervally(PER_ACCOUNT_PER_DAY, Duration.ofDays(1)))
                .build();
    }

    private Bucket ipBucket() {
        return Bucket.builder()
                .addLimit(limit -> limit.capacity(PER_IP_PER_MINUTE)
                        .refillGreedy(PER_IP_PER_MINUTE, Duration.ofMinutes(1)))
                .build();
    }
}
