package com.uten.imp.common.web;

import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;

/**
 * 分页构造统一入口：对外页码从 1 起，每页 1..{@link #MAX_PAGE_SIZE} 条。
 * 2026-11-08：客户端完整读取按 {@link CompleteReadBatchPlan#PROGRESSIVE}（首批 50，
 * 之后对齐增长）分批，单次页上限随之统一；仍是有界内部批量，不是整表上限。
 * 2026-11-09：单次页上限经用户确认由 200 上调至 1000（{@link CompleteReadBatchPlan#MAX_BATCH_SIZE}）。
 */
public final class Pageables {

    public static final int MAX_PAGE_SIZE = CompleteReadBatchPlan.MAX_BATCH_SIZE;

    private Pageables() {}

    public static PageRequest of(int page, int size) {
        return PageRequest.of(Math.max(1, page) - 1, Math.min(Math.max(1, size), MAX_PAGE_SIZE));
    }

    public static PageRequest of(int page, int size, Sort sort) {
        return PageRequest.of(
                Math.max(1, page) - 1,
                Math.min(Math.max(1, size), MAX_PAGE_SIZE),
                sort);
    }

    /**
     * JPA's first-result contract is an int, even when a Pageable exposes a long
     * offset. Preserve the caller's page-size policy and reject an unrepresentable
     * page instead of overflowing or silently selecting a different page.
     * SQL LIMIT/OFFSET readers can continue using their existing long contract.
     */
    public static int checkedOffset(long page, long size) {
        long offset;
        try {
            offset = Math.multiplyExact(Math.max(1L, page) - 1, Math.max(1L, size));
        } catch (ArithmeticException overflow) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "页码超出范围");
        }
        if (offset > Integer.MAX_VALUE) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "页码超出范围");
        }
        return (int) offset;
    }
}
