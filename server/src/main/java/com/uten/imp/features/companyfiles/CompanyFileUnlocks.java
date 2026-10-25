package com.uten.imp.features.companyfiles;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;

import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Semaphore;

/** Single-primary session capabilities. Never holds plaintext or reusable bearer tokens. */
@Component
public class CompanyFileUnlocks {
    private static final Duration TTL = Duration.ofMinutes(15), WINDOW = Duration.ofMinutes(15);
    private static final int MAX_KEYS = 10000;
    private final ConcurrentHashMap<Key, Grant> grants = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<AttemptKey, Attempts> attempts = new ConcurrentHashMap<>();
    private final BCryptPasswordEncoder encoder = new BCryptPasswordEncoder(12);
    private final Semaphore hashing = new Semaphore(2);
    private final Clock clock;

    public CompanyFileUnlocks() {
        this(Clock.systemUTC());
    }

    CompanyFileUnlocks(Clock clock) {
        this.clock = clock;
    }

    String hash(String password) {
        if (password == null) return null;
        if (password.isBlank() || password.codePointCount(0, password.length()) < 8)
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "目录密码至少需要 8 个字符，清除密码请使用清除操作");
        // BCrypt has a 72-byte input limit; reject instead of silently truncating Chinese
        // passwords.
        if (password.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 72)
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "目录密码的 UTF-8 长度不能超过 72 字节");
        return costly(() -> encoder.encode(password));
    }

    public Instant unlock(UUID nodeId, long revision, String hash, String password, AuthUser user) {
        requireSession(user);
        prune();
        if (hash == null) throw new ApiException(ErrorCode.CONFLICT, "这个目录没有密码保护");
        AttemptKey attemptKey = new AttemptKey(user.getId(), nodeId);
        Attempts state =
                attempts.compute(
                        attemptKey,
                        (k, old) ->
                                old == null || old.until().isBefore(clock.instant())
                                        ? new Attempts(0, clock.instant().plus(WINDOW))
                                        : old);
        synchronized (state) {
            if (state.count >= 5)
                throw new ApiException(ErrorCode.RATE_LIMITED, "目录密码输错次数过多，请十五分钟后重试");
            if (password == null
                    || password.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 72
                    || !costly(() -> encoder.matches(password, hash))) {
                state.count++;
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "目录密码不正确");
            }
        }
        // Keep one stable monitor until the window expires. Removing a successful state would let
        // an already waiting request mutate an untracked old object and bypass the attempt limit.
        Instant expires = clock.instant().plus(TTL);
        grants.put(
                new Key(user.getId(), user.getSessionId(), nodeId), new Grant(revision, expires));
        return expires;
    }

    public boolean isUnlocked(UUID nodeId, long revision, AuthUser user) {
        if (user == null || user.getSessionId() == null) return false;
        Key key = new Key(user.getId(), user.getSessionId(), nodeId);
        Grant grant = grants.get(key);
        if (grant == null) return false;
        if (grant.revision() != revision || !grant.expires().isAfter(clock.instant())) {
            grants.remove(key, grant);
            return false;
        }
        return true;
    }

    public void lock(UUID nodeId, AuthUser user) {
        if (user != null) grants.remove(new Key(user.getId(), user.getSessionId(), nodeId));
    }

    public void invalidate(UUID nodeId) {
        grants.keySet().removeIf(k -> k.node().equals(nodeId));
    }

    private void prune() {
        Instant now = clock.instant();
        grants.entrySet().removeIf(e -> !e.getValue().expires().isAfter(now));
        attempts.entrySet().removeIf(e -> !e.getValue().until().isAfter(now));
        if (grants.size() >= MAX_KEYS || attempts.size() >= MAX_KEYS)
            throw new ApiException(ErrorCode.RATE_LIMITED);
    }

    private <T> T costly(java.util.function.Supplier<T> operation) {
        if (!hashing.tryAcquire()) throw new ApiException(ErrorCode.AUTH_BUSY);
        try {
            return operation.get();
        } finally {
            hashing.release();
        }
    }

    private static void requireSession(AuthUser user) {
        if (user == null || user.getSessionId() == null || user.getImpersonatedBy() != null)
            throw new ApiException(ErrorCode.UNAUTHORIZED);
    }

    private record Key(UUID user, UUID session, UUID node) {}

    private record AttemptKey(UUID user, UUID node) {}

    private record Grant(long revision, Instant expires) {}

    private static final class Attempts {
        int count;
        final Instant until;

        Attempts(int count, Instant until) {
            this.count = count;
            this.until = until;
        }

        Instant until() {
            return until;
        }
    }
}
