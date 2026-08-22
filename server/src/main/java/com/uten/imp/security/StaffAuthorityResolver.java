package com.uten.imp.security;

import com.uten.imp.features.auth.PermissionResolver;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.function.LongSupplier;

/**
 * Resolves staff authorities from server-side state and caches only immutable,
 * authorization-versioned snapshots.
 *
 * <p>{@link JwtAuthFilter} still reads account status and authorization stamps from
 * the database on every request. A status change therefore fails closed immediately,
 * and a version/epoch change either rejects the old token or selects a different cache
 * key. TTL is only a memory/recovery bound, never the invalidation mechanism.
 */
@Component
public class StaffAuthorityResolver {

    static final Duration DEFAULT_TTL = Duration.ofSeconds(30);
    static final int DEFAULT_MAX_ENTRIES = 2_048;

    private final PermissionResolver permissionResolver;
    private final LongSupplier nanoTime;
    private final long ttlNanos;
    private final int maxEntries;
    private final Map<CacheKey, CacheEntry> cache = new LinkedHashMap<>(64, 0.75f, true);

    @Autowired
    public StaffAuthorityResolver(PermissionResolver permissionResolver) {
        this(permissionResolver, System::nanoTime, DEFAULT_TTL, DEFAULT_MAX_ENTRIES);
    }

    StaffAuthorityResolver(
            PermissionResolver permissionResolver,
            LongSupplier nanoTime,
            Duration ttl,
            int maxEntries) {
        if (ttl == null || ttl.isZero() || ttl.isNegative()) {
            throw new IllegalArgumentException("ttl must be positive");
        }
        if (maxEntries < 1) {
            throw new IllegalArgumentException("maxEntries must be positive");
        }
        this.permissionResolver = permissionResolver;
        this.nanoTime = nanoTime;
        this.ttlNanos = ttl.toNanos();
        this.maxEntries = maxEntries;
    }

    public PermissionResolver.AuthorizationSnapshot resolve(
            UUID userId,
            UUID employeeId,
            boolean superAdmin,
            long authVersion,
            long authorizationEpoch) {
        CacheKey key = new CacheKey(
                userId,
                employeeId,
                superAdmin,
                authVersion,
                authorizationEpoch);
        long now = nanoTime.getAsLong();

        synchronized (cache) {
            CacheEntry cached = cache.get(key);
            if (cached != null) {
                if (now - cached.createdAtNanos() < ttlNanos) {
                    return cached.snapshot();
                }
                cache.remove(key);
            }
        }

        PermissionResolver.AuthorizationSnapshot resolved =
                permissionResolver.authorizationSnapshot(userId, employeeId, superAdmin);
        // Time-bound/manager-status delegation validity is checked live. Do not
        // retain such a snapshot for the ordinary 30-second cache window.
        if (resolved.contextualDelegationPresent()) {
            return resolved;
        }
        synchronized (cache) {
            cache.put(key, new CacheEntry(resolved, now));
            trimToBound();
        }
        return resolved;
    }

    int cacheSize() {
        synchronized (cache) {
            return cache.size();
        }
    }

    private void trimToBound() {
        Iterator<CacheKey> eldestFirst = cache.keySet().iterator();
        while (cache.size() > maxEntries && eldestFirst.hasNext()) {
            eldestFirst.next();
            eldestFirst.remove();
        }
    }

    private record CacheKey(
            UUID userId,
            UUID employeeId,
            boolean superAdmin,
            long authVersion,
            long authorizationEpoch) {
    }

    private record CacheEntry(
            PermissionResolver.AuthorizationSnapshot snapshot,
            long createdAtNanos) {
    }
}
