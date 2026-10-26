package com.uten.imp.common.concurrency;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.*;

class BoundedIdleStoreTest {
    @Test
    void fullStoreRejectsNewKeysWithoutReplacingExistingState() {
        var store = new BoundedIdleStore<String, Object>(2, Duration.ofMinutes(2), () -> 0);
        Object first = store.compute("a", ignored -> new Object());
        store.compute("b", ignored -> new Object());

        assertNull(store.compute("c", ignored -> fail("a full store must not allocate a new value")));
        assertSame(first, store.get("a"));
        assertEquals(2, store.size());
    }

    @Test
    void onlyIdleEntriesExpireAndAccessRenewsTheirLifetime() {
        AtomicLong now = new AtomicLong();
        var store = new BoundedIdleStore<String, Object>(2, Duration.ofSeconds(10), now::get);
        Object active = store.compute("active", ignored -> new Object());
        store.compute("idle", ignored -> new Object());
        now.set(TimeUnit.SECONDS.toNanos(6));
        assertSame(active, store.get("active"));
        now.set(TimeUnit.SECONDS.toNanos(11));

        assertNotNull(store.compute("new", ignored -> new Object()));
        assertSame(active, store.get("active"));
        assertNull(store.get("idle"));
        assertEquals(2, store.size());
    }

    @Test
    void idleCleanupHasABoundedWorkBatch() {
        AtomicLong now = new AtomicLong();
        var store = new BoundedIdleStore<Integer, Integer>(256, Duration.ofSeconds(1), now::get);
        for (int i = 0; i < 200; i++) {
            int value = i;
            store.compute(i, ignored -> value);
        }
        now.set(TimeUnit.SECONDS.toNanos(2));

        assertEquals(999, store.compute(999, ignored -> 999));
        assertEquals(201 - BoundedIdleStore.MAX_IDLE_REMOVALS, store.size());
        assertNull(store.get(199), "a directly read expired entry is never returned");
    }

    @Test
    void concurrentNewKeysNeverExceedTheCapacity() throws Exception {
        int capacity = 31;
        var store = new BoundedIdleStore<Integer, Integer>(capacity, Duration.ofMinutes(2), () -> 0);
        var start = new CountDownLatch(1);
        var accepted = new AtomicInteger();
        try (var workers = Executors.newFixedThreadPool(8)) {
            var tasks = new ArrayList<Future<?>>();
            for (int i = 0; i < 400; i++) {
                int key = i;
                tasks.add(workers.submit(() -> {
                    assertTrue(start.await(5, TimeUnit.SECONDS));
                    if (store.compute(key, ignored -> key) != null) accepted.incrementAndGet();
                    return null;
                }));
            }
            start.countDown();
            for (Future<?> task : tasks) task.get(10, TimeUnit.SECONDS);
        }
        assertEquals(capacity, accepted.get());
        assertEquals(capacity, store.size());
    }

    @Test
    void rejectedUpdatesKeepExistingStateAndReleaseTheMonitor() {
        AtomicLong now = new AtomicLong();
        var store = new BoundedIdleStore<String, Object>(2, Duration.ofSeconds(10), now::get);
        Object value = store.compute("a", ignored -> new Object());
        store.compute("b", ignored -> new Object());
        now.set(TimeUnit.SECONDS.toNanos(6));
        assertThrows(IllegalStateException.class, () -> store.compute("a", old -> {
            throw new IllegalStateException("rejected");
        }));

        now.set(TimeUnit.SECONDS.toNanos(11));
        assertNotNull(store.compute("c", ignored -> new Object()));
        assertSame(value, store.get("a"));
        assertNull(store.get("b"));
        assertEquals(2, store.size());
    }

    @Test
    void invalidBoundsAreRejected() {
        assertThrows(IllegalArgumentException.class,
                () -> new BoundedIdleStore<>(0, Duration.ofSeconds(1), System::nanoTime));
        assertThrows(IllegalArgumentException.class,
                () -> new BoundedIdleStore<>(1, Duration.ZERO, System::nanoTime));
    }
}
