package com.uten.imp.common.web;

/**
 * Complete-list batch plan shared with the client
 * ({@code lib/shared/paging/complete_paged_snapshot.dart}, 2026-11-08 user decision):
 * the first batch is small so the first screen appears at once, later batches grow
 * to the bounded maximum. Every batch is the exact page of its own size at the rows
 * already read ({@code offset == (page - 1) * size}): 50, 50, 100, 200, 200, ...
 * No row is read twice and none is skipped. Shared vectors:
 * {@code contracts/complete-read-batch-plan-v1.json}.
 */
public record CompleteReadBatchPlan(int firstBatchSize, int maxBatchSize) {
    public static final int FIRST_BATCH_SIZE = 50;
    public static final int MAX_BATCH_SIZE = 200;
    public static final CompleteReadBatchPlan PROGRESSIVE =
            new CompleteReadBatchPlan(FIRST_BATCH_SIZE, MAX_BATCH_SIZE);

    public CompleteReadBatchPlan {
        if (firstBatchSize < 1 || maxBatchSize > 1000 || firstBatchSize > maxBatchSize) {
            throw new IllegalArgumentException("Invalid complete read batch plan");
        }
    }

    /** Every batch has one size (the original fixed-frame contract). */
    public static CompleteReadBatchPlan fixed(int size) {
        return new CompleteReadBatchPlan(size, size);
    }

    /** The size of the batch that starts exactly at {@code offset}. */
    public int sizeAt(long offset) {
        if (offset < 0) throw new IllegalArgumentException("Negative complete read offset");
        if (offset == 0) return firstBatchSize;
        if (offset % maxBatchSize == 0) return maxBatchSize;
        return Math.toIntExact(greatestCommonDivisor(offset, maxBatchSize));
    }

    /** The 1-based page of that batch in its own page size. */
    public int pageAt(long offset) {
        return Math.toIntExact(offset / sizeAt(offset) + 1);
    }

    private static long greatestCommonDivisor(long a, long b) {
        while (b != 0) {
            long rest = a % b;
            a = b;
            b = rest;
        }
        return a;
    }
}
