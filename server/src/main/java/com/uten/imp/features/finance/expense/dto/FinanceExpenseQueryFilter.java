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
        String billNo,
        boolean includeDeleted, boolean onlyDeleted,
        com.uten.imp.common.web.HeaderColumnFilter headerFilters, String view) {
    public FinanceExpenseQueryFilter {
        headerFilters = headerFilters == null ? com.uten.imp.common.web.HeaderColumnFilter.EMPTY : headerFilters;
        view = view == null || view.isBlank() ? "ACTIVE" : view.strip().toUpperCase(java.util.Locale.ROOT);
        if (!java.util.Set.of("ACTIVE", "HISTORY").contains(view)) {
            throw new com.uten.imp.common.web.ApiException(
                    com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, "费用单视图不正确");
        }
    }
    public FinanceExpenseQueryFilter(String keyword, UUID accountId, UUID departmentId, Short status,
            LocalDate dateFrom, LocalDate dateTo, String billNo, boolean includeDeleted, boolean onlyDeleted,
            com.uten.imp.common.web.HeaderColumnFilter headerFilters) {
        this(keyword, accountId, departmentId, status, dateFrom, dateTo, billNo,
                includeDeleted, onlyDeleted, headerFilters, "ACTIVE");
    }
    public FinanceExpenseQueryFilter withView(String view) {
        return new FinanceExpenseQueryFilter(keyword, accountId, departmentId, status, dateFrom, dateTo,
                billNo, includeDeleted, onlyDeleted, headerFilters, view);
    }
    public FinanceExpenseQueryFilter(String keyword,
        UUID accountId,
        UUID departmentId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
        this(keyword, accountId, departmentId, status, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, com.uten.imp.common.web.HeaderColumnFilter.EMPTY);
    }
    public FinanceExpenseQueryFilter withHeaders(com.uten.imp.common.web.HeaderColumnFilter headers) {
        return new FinanceExpenseQueryFilter(keyword, accountId, departmentId, status, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, headers, view);
    }

    public FinanceExpenseQueryFilter(
        String keyword,
        UUID accountId,
        UUID departmentId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo) { this(keyword, accountId, departmentId, status, dateFrom, dateTo, billNo, false, false); }
    public FinanceExpenseQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new FinanceExpenseQueryFilter(keyword, accountId, departmentId, status, dateFrom, dateTo, billNo, includeDeleted || onlyDeleted, onlyDeleted, headerFilters, view);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public FinanceExpenseQueryFilter(
            String keyword, UUID accountId, UUID departmentId, Short status,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, accountId, departmentId, status, dateFrom, dateTo, null);
    }
}
