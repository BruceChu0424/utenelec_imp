package com.uten.imp.features.finance.expense.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 一般费用单查询条件。 */
public record FinanceExpenseQueryFilter(
        String keyword,
        UUID accountId,
        UUID departmentId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}
