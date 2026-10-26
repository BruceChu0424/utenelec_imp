package com.uten.imp.common.concurrency;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Objects;
import java.util.function.LongSupplier;
import java.util.function.UnaryOperator;

/** Retains active state at capacity; only idle entries may be reclaimed. */
public final class BoundedIdleStore<K, V> {
    static final int MAX_IDLE_REMOVALS = 64;

    private final LinkedHashMap<K, Entry<V>> entries = new LinkedHashMap<>(16, 0.75f, true);
    private final int capacity;
    private final long idleNanos;
    private final LongSupplier nanoTime;

    public BoundedIdleStore(int capacity, Duration idleExpiry, LongSupplier nanoTime) {
        if (capacity < 1 || idleExpiry == null || idleExpiry.isZero() || idleExpiry.isNegative()) {
            throw new IllegalArgumentException("capacity and idle expiry must be positive");
        }
        this.capacity = capacity;
        this.idleNanos = idleExpiry.toNanos();
        this.nanoTime = Objects.requireNonNull(nanoTime);
    }

    public synchronized V get(K key) {
        long now = nanoTime.getAsLong();
        removeIdle(now);
        Entry<V> entry = current(key, now);
        if (entry == null) return null;
        entry.lastAccess = now;
        return entry.value;
    }

    /**
     * Applies a short in-memory update atomically; null means a new key could not be admitted.
     * The updater receives null for a new entry and must return a non-null value.
     */
    public synchronized V compute(K key, UnaryOperator<V> update) {
        long now = nanoTime.getAsLong();
        removeIdle(now);
        Entry<V> entry = current(key, now);
        if (entry == null && entries.size() >= capacity) return null;
        if (entry != null) entry.lastAccess = now;
        V value = Objects.requireNonNull(update.apply(entry == null ? null : entry.value));
        if (entry == null) entries.put(key, new Entry<>(value, now));
        else entry.value = value;
        return value;
    }

    public synchronized int size() {
        return entries.size();
    }

    private Entry<V> current(K key, long now) {
        Entry<V> entry = entries.get(Objects.requireNonNull(key));
        if (entry != null && now - entry.lastAccess >= idleNanos) {
            entries.remove(key);
            return null;
        }
        return entry;
    }

    private void removeIdle(long now) {
        var oldestFirst = entries.entrySet().iterator();
        for (int removed = 0; removed < MAX_IDLE_REMOVALS && oldestFirst.hasNext(); removed++) {
            Entry<V> entry = oldestFirst.next().getValue();
            if (now - entry.lastAccess < idleNanos) break;
            oldestFirst.remove();
        }
    }

    private static final class Entry<V> {
        private V value;
        private long lastAccess;

        private Entry(V value, long lastAccess) {
            this.value = value;
            this.lastAccess = lastAccess;
        }
    }
}
