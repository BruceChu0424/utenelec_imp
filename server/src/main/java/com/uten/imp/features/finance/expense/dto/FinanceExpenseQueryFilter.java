package com.uten.imp.features.finance.expense.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 一般费用单查询条件。billNo=单据号表头值筛选（2026-09-25 单号列统一，精确匹配）。 */
public record FinanceExpenseQueryFilter(
        String keyword,
        UUID accountId,
        UUID departmentId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo) {

    /** 兼容旧签名（无单号筛选）。 */
    public FinanceExpenseQueryFilter(
            String keyword, UUID accountId, UUID departmentId, Short status,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, accountId, departmentId, status, dateFrom, dateTo, null);
    }
}
