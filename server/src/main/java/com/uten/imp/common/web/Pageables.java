package com.uten.imp.common.web;

import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;

/** 分页构造统一入口：对外页码从 1 起，每页 1..100 条。 */
public final class Pageables {

    private Pageables() {}

    public static PageRequest of(int page, int size) {
        return PageRequest.of(Math.max(1, page) - 1, Math.min(Math.max(1, size), 100));
    }

    public static PageRequest of(int page, int size, Sort sort) {
        return PageRequest.of(
                Math.max(1, page) - 1,
                Math.min(Math.max(1, size), 100),
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
