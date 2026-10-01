package com.uten.imp.application.concurrency;

import org.springframework.transaction.TransactionTimedOutException;

import java.time.Duration;
import java.util.concurrent.TimeUnit;
import java.util.function.LongSupplier;

/** A command and all of its transaction attempts share one monotonic deadline. */
public final class FulfillmentCommandDeadline implements AutoCloseable {
    private static final ThreadLocal<FulfillmentCommandDeadline> CURRENT = new ThreadLocal<>();

    private final FulfillmentCommandDeadline previous;
    private final LongSupplier clock;
    private long deadlineNanos;
    private boolean rootTransactionActive;
    private boolean committed;

    private FulfillmentCommandDeadline(Duration budget, LongSupplier clock) {
        this.previous = CURRENT.get();
        this.clock = clock;
        long remaining = budget.toNanos();
        if (previous != null && !previous.committed) remaining = Math.min(remaining, previous.remainingNanos());
        this.deadlineNanos = clock.getAsLong() + remaining;
        CURRENT.set(this);
    }

    static FulfillmentCommandDeadline open(Duration budget, LongSupplier clock) {
        return new FulfillmentCommandDeadline(budget, clock);
    }

    static FulfillmentCommandDeadline current() {
        FulfillmentCommandDeadline deadline = CURRENT.get();
        return deadline == null || deadline.committed ? null : deadline;
    }

    boolean claimRootTransaction() {
        if (rootTransactionActive) return false;
        rootTransactionActive = true;
        return true;
    }

    void rootCommitted() {
        committed = true;
    }

    boolean hasCommitted() {
        return committed;
    }

    void rootTransactionCompleted() {
        rootTransactionActive = false;
    }

    /** A retry may consume only the smaller of the command and retry budgets. */
    void limitRemaining(Duration budget) {
        long now = clock.getAsLong();
        deadlineNanos = now + Math.min(deadlineNanos - now, budget.toNanos());
    }

    long remainingNanos() {
        return deadlineNanos - clock.getAsLong();
    }

    long remainingMillis() {
        long nanos = remainingNanos();
        return nanos <= 0 ? 0 : 1 + (nanos - 1) / TimeUnit.MILLISECONDS.toNanos(1);
    }

    int boundedTimeoutSeconds(int configuredTimeout) {
        check();
        long nanos = remainingNanos();
        if (nanos <= 0) throw timedOut();
        long seconds = 1 + (nanos - 1) / TimeUnit.SECONDS.toNanos(1);
        if (configuredTimeout >= 0) seconds = Math.min(seconds, configuredTimeout);
        return (int) Math.min(seconds, Integer.MAX_VALUE);
    }

    void check() {
        if (remainingNanos() <= 0) throw timedOut();
    }

    /**
     * Spring treats TransactionException during commit differently from a normal
     * runtime failure. Wrapping the timeout makes beforeCommit explicitly roll
     * back; the HTTP handler still recognizes its original timeout cause.
     */
    void checkBeforeCommit() {
        if (remainingNanos() <= 0) throw new BeforeCommitTimeout(timedOut());
    }

    private static TransactionTimedOutException timedOut() {
        return new TransactionTimedOutException("履约命令处理时限已用完");
    }

    @Override
    public void close() {
        if (previous == null) CURRENT.remove();
        else CURRENT.set(previous);
    }

    static final class BeforeCommitTimeout extends RuntimeException {
        BeforeCommitTimeout(TransactionTimedOutException cause) {
            super(cause.getMessage(), cause);
        }
    }
}
