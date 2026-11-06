package com.uten.imp.common.read;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.LongSupplier;

/**
 * Bounded, process-memory-only cache of immutable parsed facts, never authority.
 * K must be an immutable value key containing realm, reset generation, exact
 * document ID, document SHA and source fingerprint. Authorize and check current
 * metadata outside this component on EVERY request, including cache hits.
 *
 * Loader runs synchronously on the admitted caller, outside all cache locks.
 * It must retain its existing I/O timeout and cooperate with Cancellation.
 * No executor, logger, disk persistence or implicit retry is created here.
 */
public final class VersionedReadSnapshotCache<K> implements AutoCloseable {
    public record Limits(int maximumEntries, long maximumEntryBytes,
                         long maximumTotalBytes, Duration ttl,
                         int maximumLoads, int maximumWaiters,
                         Duration loadTimeout, int maximumDepth,
                         long maximumTreeNodes) {
        public Limits {
            if (maximumEntries < 1 || maximumEntryBytes < 1 || maximumTotalBytes < 1
                    || maximumLoads < 1 || maximumWaiters < 0 || maximumDepth < 1
                    || maximumTreeNodes < 1) throw new IllegalArgumentException("Invalid snapshot bounds");
            positiveNanos(ttl); positiveNanos(loadTimeout);
        }
    }

    /** sourceUtf8Bytes is the actual decoded source length, not ciphertext size. */
    public record Loaded(Map<String, ?> parsed, long sourceUtf8Bytes) {
        public Loaded {
            Objects.requireNonNull(parsed);
            if (sourceUtf8Bytes < 0) throw new IllegalArgumentException("Missing source size");
        }
    }

    /** retained=false is an explicit complete-value bypass, never row truncation. */
    public record ReadResult(Map<String, Object> value, long weightBytes,
                             boolean retained, boolean joinedFlight) {}
    public record State(int entries, long retainedBytes, int activeLoads,
                        int waitingReaders, boolean closed) {}

    @FunctionalInterface
    public interface Loader { Loaded load(Cancellation cancellation) throws Exception; }

    public static final class Cancellation {
        private final LongSupplier ticker;
        private final long startedAt;
        private final long timeoutNanos;
        private volatile boolean cancelled;
        private Cancellation(LongSupplier ticker, long startedAt, long timeoutNanos) {
            this.ticker = ticker; this.startedAt = startedAt; this.timeoutNanos = timeoutNanos;
        }
        public void checkCurrent() throws InterruptedException {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedException("Snapshot load interrupted");
            if (cancelled || ticker.getAsLong() - startedAt >= timeoutNanos) {
                throw new CancellationException("Snapshot load retired");
            }
        }
    }

    public static final class CapacityException extends IllegalStateException {
        public CapacityException(String message) { super(message); }
    }

    private record Entry(Map<String, Object> value, long weight, long createdAt) {}
    private static final class Flight {
        private final Thread leader = Thread.currentThread();
        private final Cancellation cancellation;
        private final CompletableFuture<ReadResult> result = new CompletableFuture<>();
        private Flight(LongSupplier ticker,long now,long loadNanos) { cancellation = new Cancellation(ticker, now, loadNanos); }
    }

    private final Limits limits;
    private final LongSupplier ticker;
    private final long ttlNanos;
    private final long loadNanos;
    private final LinkedHashMap<K, Entry> entries = new LinkedHashMap<>(16, .75f, true);
    private final Map<K, Flight> flights = new HashMap<>();
    private long retainedBytes;
    private int waiters;
    private boolean closed;

    public VersionedReadSnapshotCache(Limits limits) { this(limits, System::nanoTime); }
    /** Injectable monotonic ticker for deterministic TTL/deadline tests. */
    public VersionedReadSnapshotCache(Limits limits, LongSupplier ticker) {
        this.limits = Objects.requireNonNull(limits);
        this.ticker = Objects.requireNonNull(ticker);
        ttlNanos = positiveNanos(limits.ttl()); loadNanos = positiveNanos(limits.loadTimeout());
    }

    public ReadResult read(K key, Loader loader) throws Exception {
        Objects.requireNonNull(key); Objects.requireNonNull(loader);
        final Flight flight; final boolean leader;
        synchronized (this) {
            if (closed) throw new CancellationException("Snapshot cache closed");
            removeExpired();
            Entry hit = entries.get(key);
            if (hit != null) return new ReadResult(hit.value(), hit.weight(), true, false);
            Flight pending = flights.get(key);
            if (pending != null) {
                if (pending.leader == Thread.currentThread()) throw new IllegalStateException("Recursive snapshot load");
                if (waiters >= limits.maximumWaiters()) throw new CapacityException("Snapshot waiter capacity reached");
                waiters++; flight = pending; leader = false;
            } else {
                if (flights.size() >= limits.maximumLoads()) throw new CapacityException("Snapshot load capacity reached");
                flight = new Flight(ticker,ticker.getAsLong(),loadNanos); flights.put(key, flight); leader = true;
            }
        }
        if (!leader) {
            try {
                long remaining = loadNanos - elapsed(flight.cancellation.startedAt);
                if (remaining <= 0) throw new TimeoutException("Snapshot load deadline reached");
                ReadResult value = flight.result.get(remaining, TimeUnit.NANOSECONDS);
                return new ReadResult(value.value(), value.weightBytes(), value.retained(), true);
            } catch (TimeoutException expired) {
                retire(flight, expired);
                throw expired;
            } catch (ExecutionException failure) {
                throwFailure(failure.getCause()); throw new AssertionError();
            } catch (InterruptedException interrupted) {
                // One disconnected/retired waiter must not cancel other readers.
                Thread.currentThread().interrupt(); throw interrupted;
            } finally {
                synchronized (this) { waiters--; }
            }
        }

        try {
            flight.cancellation.checkCurrent();
            Loaded loaded = Objects.requireNonNull(loader.load(flight.cancellation));
            flight.cancellation.checkCurrent();
            Freeze freeze = new Freeze(flight.cancellation, loaded.sourceUtf8Bytes());
            @SuppressWarnings("unchecked")
            Map<String, Object> immutable = (Map<String, Object>) freeze.copy(loaded.parsed(), 0);
            flight.cancellation.checkCurrent();
            final ReadResult result;
            synchronized (this) {
                if (closed || flights.get(key) != flight || flight.cancellation.cancelled
                        || elapsed(flight.cancellation.startedAt) >= loadNanos) {
                    throw new CancellationException("Snapshot load retired");
                }
                boolean retain = freeze.weight <= limits.maximumEntryBytes()
                        && freeze.weight <= limits.maximumTotalBytes();
                if (retain) {
                    removeExpired();
                    while (entries.size() >= limits.maximumEntries()
                            || retainedBytes > limits.maximumTotalBytes() - freeze.weight) removeEldest();
                    entries.put(key, new Entry(immutable, freeze.weight, ticker.getAsLong()));
                    retainedBytes += freeze.weight;
                }
                result = new ReadResult(immutable, freeze.weight, retain, false);
                // Future is private and has blocking readers only: completion
                // is the publication linearization point before invalidation.
                flight.result.complete(result);
            }
            return result;
        } catch (Throwable failure) {
            flight.result.completeExceptionally(failure);
            if (failure instanceof InterruptedException) Thread.currentThread().interrupt();
            throwFailure(failure); throw new AssertionError();
        } finally {
            // A retired leader retains its slot until its loader actually exits:
            // repeated invalidation cannot create unbounded hidden I/O/threads.
            synchronized (this) { flights.remove(key, flight); }
        }
    }

    public synchronized void invalidate(K key) {
        Entry old = entries.remove(key); if (old != null) retainedBytes -= old.weight();
        Flight pending = flights.get(key);
        if (pending != null) retire(pending, new CancellationException("Snapshot invalidated"));
    }
    public synchronized void clear() {
        entries.clear(); retainedBytes = 0;
        for (Flight flight : flights.values()) retire(flight, new CancellationException("Snapshot cache cleared"));
    }
    @Override public synchronized void close() { closed = true; clear(); }
    public synchronized State state() { removeExpired(); return new State(entries.size(), retainedBytes, flights.size(), waiters, closed); }

    private synchronized void retire(Flight flight, Throwable reason) {
        flight.cancellation.cancelled = true;
        flight.result.completeExceptionally(reason);
    }
    private long elapsed(long start) { return ticker.getAsLong() - start; }
    private void removeExpired() {
        Iterator<Entry> it = entries.values().iterator();
        while (it.hasNext()) {
            Entry entry = it.next();
            if (elapsed(entry.createdAt()) >= ttlNanos) { retainedBytes -= entry.weight(); it.remove(); }
        }
    }
    private void removeEldest() {
        Iterator<Entry> it = entries.values().iterator();
        if (!it.hasNext()) throw new IllegalStateException("Snapshot byte accounting inconsistent");
        retainedBytes -= it.next().weight(); it.remove();
    }
    private static long positiveNanos(Duration value) {
        Objects.requireNonNull(value);
        long nanos = value.toNanos();
        if (nanos <= 0 || nanos > Long.MAX_VALUE / 2) throw new IllegalArgumentException("Invalid duration bound");
        return nanos;
    }
    private static void throwFailure(Throwable failure) throws Exception {
        if (failure instanceof Error error) throw error;
        if (failure instanceof Exception exception) throw exception;
        throw new IllegalStateException("Snapshot load failed", failure);
    }

    private final class Freeze {
        private final Cancellation cancellation;
        private final IdentityHashMap<Object, Boolean> ancestors = new IdentityHashMap<>();
        private long nodes;
        private long weight;
        private Freeze(Cancellation cancellation, long sourceBytes) { this.cancellation = cancellation; weight = sourceBytes; }
        private void add(long bytes) { weight = Math.addExact(weight, bytes); }
        private Object copy(Object value, int depth) throws InterruptedException {
            cancellation.checkCurrent();
            if (++nodes > limits.maximumTreeNodes() || depth > limits.maximumDepth()) {
                throw new CapacityException("Snapshot tree exceeds explicit safety bound");
            }
            if (value == null) { add(8); return null; }
            if (value instanceof String text) { add(Math.addExact(40L, Math.multiplyExact(3L, text.length()))); return text; }
            if (value instanceof Boolean || value instanceof Integer || value instanceof Long
                    || value instanceof Short || value instanceof Byte) { add(24); return value; }
            if (value instanceof BigInteger integer) { add(64L + (integer.bitLength() + 7L) / 8L); return value; }
            if (value instanceof BigDecimal decimal) { add(96L + (decimal.unscaledValue().bitLength() + 7L) / 8L); return value; }
            if (value instanceof Double number && Double.isFinite(number)) { add(24); return value; }
            if (value instanceof Float number && Float.isFinite(number)) { add(24); return value; }
            if (!(value instanceof Map<?, ?>) && !(value instanceof List<?>)) {
                throw new IllegalArgumentException("Only JSON-like immutable snapshot facts are supported");
            }
            if (ancestors.put(value, Boolean.TRUE) != null) throw new IllegalArgumentException("Cyclic snapshot tree");
            try {
                if (value instanceof Map<?, ?> map) {
                    add(64); Map<String, Object> result = new LinkedHashMap<>();
                    for (Map.Entry<?, ?> item : map.entrySet()) {
                        if (!(item.getKey() instanceof String key)) throw new IllegalArgumentException("Snapshot object keys must be strings");
                        add(80); copy(key, depth + 1);
                        result.put(key, copy(item.getValue(), depth + 1));
                    }
                    return Collections.unmodifiableMap(result);
                }
                add(40); List<Object> result = new ArrayList<>();
                for (Object item : (List<?>) value) { add(8); result.add(copy(item, depth + 1)); }
                return Collections.unmodifiableList(result);
            } finally { ancestors.remove(value); }
        }
    }
}
