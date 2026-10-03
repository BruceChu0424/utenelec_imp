package com.uten.imp.features.finance.other_income.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 其它收入单查询条件。billNo=单据号表头值筛选（2026-09-25 单号列统一，精确匹配）。 */
public record FinanceOtherIncomeQueryFilter(
        String keyword,
        UUID accountId,
        UUID departmentId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo,
        boolean includeDeleted, boolean onlyDeleted,
        com.uten.imp.common.web.HeaderColumnFilter headerFilters) {
    public FinanceOtherIncomeQueryFilter {
        headerFilters = headerFilters == null ? com.uten.imp.common.web.HeaderColumnFilter.EMPTY : headerFilters;
    }
    public FinanceOtherIncomeQueryFilter(String keyword,
        UUID accountId,
        UUID departmentId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
        this(keyword, accountId, departmentId, status, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, com.uten.imp.common.web.HeaderColumnFilter.EMPTY);
    }
    public FinanceOtherIncomeQueryFilter withHeaders(com.uten.imp.common.web.HeaderColumnFilter headers) {
        return new FinanceOtherIncomeQueryFilter(keyword, accountId, departmentId, status, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, headers);
    }

    public FinanceOtherIncomeQueryFilter(
        String keyword,
        UUID accountId,
        UUID departmentId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo) { this(keyword, accountId, departmentId, status, dateFrom, dateTo, billNo, false, false); }
    public FinanceOtherIncomeQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new FinanceOtherIncomeQueryFilter(keyword, accountId, departmentId, status, dateFrom, dateTo, billNo, includeDeleted || onlyDeleted, onlyDeleted, headerFilters);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public FinanceOtherIncomeQueryFilter(
            String keyword, UUID accountId, UUID departmentId, Short status,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, accountId, departmentId, status, dateFrom, dateTo, null);
    }
}
