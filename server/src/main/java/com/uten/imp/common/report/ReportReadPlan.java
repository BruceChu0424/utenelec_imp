package com.uten.imp.common.report;

import java.util.Objects;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import java.util.List;

/**
 * Selects independently requested report metadata without changing the row predicate.
 * Omitted counts are unknown (-1), not an empty result; omitted facets/totals are empty.
 * The default remains ALL for existing callers. A scope is confined to its calling thread.
 */
public record ReportReadPlan(boolean includeCount, boolean includeFacets, boolean includeTotals, String readScopeVersion) {
    public ReportReadPlan(boolean includeCount, boolean includeFacets, boolean includeTotals) {
        this(includeCount,includeFacets,includeTotals,null);
    }
    public static final ReportReadPlan ALL = new ReportReadPlan(true, true, true);
    public static final ReportReadPlan ROWS_ONLY = new ReportReadPlan(false, false, false);
    public static final long UNKNOWN_TOTAL = -1;
    private static final ThreadLocal<ReportReadPlan> CURRENT = new ThreadLocal<>();

    public static ReportReadPlan current() {
        ReportReadPlan plan = CURRENT.get();
        return plan == null ? ALL : plan;
    }

    public static Scope open(ReportReadPlan plan) {
        return new Scope(Objects.requireNonNull(plan));
    }

    public long count(LongSupplier query) {
        return includeCount ? query.getAsLong() : UNKNOWN_TOTAL;
    }

    public <T> List<T> totals(Supplier<List<T>> query) {
        return includeTotals ? query.get() : List.of();
    }

    public static int totalPages(long total, int size) {
        if (total < 0) return -1;
        return (int) Math.min(Integer.MAX_VALUE, total / size + (total % size == 0 ? 0 : 1));
    }
    public static String statisticsGeneratedAt(long total,java.util.Map<?,?> facets,java.util.List<?> totals) {
        return total>=0 || facets!=null&&!facets.isEmpty() || totals!=null&&!totals.isEmpty()
                ? java.time.Instant.now().toString() : null;
    }

    public static final class Scope implements AutoCloseable {
        private final ReportReadPlan previous;
        private final Thread owner = Thread.currentThread();
        private boolean closed;

        private Scope(ReportReadPlan plan) {
            previous = CURRENT.get();
            CURRENT.set(plan);
        }

        @Override
        public void close() {
            if (Thread.currentThread() != owner) throw new IllegalStateException("Report scope belongs to another thread");
            if (closed) return;
            closed = true;
            if (previous == null) CURRENT.remove();
            else CURRENT.set(previous);
        }
    }
}
