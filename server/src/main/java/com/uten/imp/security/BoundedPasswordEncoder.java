package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.util.Objects;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

/**
 * 给内存密集型密码哈希加进程级并发闸门 (security-03, ADR-110)。
 *
 * <p>Argon2id 每次约占 19 MiB 堆且吃满一个 CPU 核。未认证的并发登录 (含未知账号的 dummy 哈希)
 * 如果不设上限, 200 个 Tomcat 线程同时哈希就能把 4 GiB 堆打满。所有 {@code matches/encode}
 * 统一经过本装饰器: 同时最多 {@code permits} 个 (默认 CPU 核数), 其余最多排队
 * {@code acquireTimeoutMillis}, 仍拿不到就立刻返回 503 {@link ErrorCode#AUTH_BUSY}
 * (带 Retry-After), 请求线程不会无限堆积。调用方应在事务外调用, 避免排队时占住数据库连接。</p>
 */
public final class BoundedPasswordEncoder implements PasswordEncoder {

    private final PasswordEncoder delegate;
    private final Semaphore permits;
    private final long acquireTimeoutMillis;

    public BoundedPasswordEncoder(PasswordEncoder delegate, int permits, long acquireTimeoutMillis) {
        if (permits < 1) {
            throw new IllegalArgumentException("permits must be positive");
        }
        if (acquireTimeoutMillis < 0) {
            throw new IllegalArgumentException("acquireTimeoutMillis must not be negative");
        }
        this.delegate = Objects.requireNonNull(delegate, "delegate");
        this.permits = new Semaphore(permits, true);
        this.acquireTimeoutMillis = acquireTimeoutMillis;
    }

    @Override
    public String encode(CharSequence rawPassword) {
        acquire();
        try {
            return delegate.encode(rawPassword);
        } finally {
            permits.release();
        }
    }

    @Override
    public boolean matches(CharSequence rawPassword, String encodedPassword) {
        acquire();
        try {
            return delegate.matches(rawPassword, encodedPassword);
        } finally {
            permits.release();
        }
    }

    @Override
    public boolean upgradeEncoding(String encodedPassword) {
        return delegate.upgradeEncoding(encodedPassword);
    }

    /** 当前空闲的哈希名额 (测试与监控用)。 */
    public int availablePermits() {
        return permits.availablePermits();
    }

    private void acquire() {
        boolean acquired;
        try {
            acquired = permits.tryAcquire(acquireTimeoutMillis, TimeUnit.MILLISECONDS);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new ApiException(ErrorCode.AUTH_BUSY);
        }
        if (!acquired) {
            throw new ApiException(ErrorCode.AUTH_BUSY);
        }
    }
}
