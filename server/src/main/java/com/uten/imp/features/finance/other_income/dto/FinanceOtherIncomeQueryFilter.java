package com.uten.imp.features.finance.other_income.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 其它收入单查询条件。 */
public record FinanceOtherIncomeQueryFilter(
        String keyword,
        UUID accountId,
        UUID departmentId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}
