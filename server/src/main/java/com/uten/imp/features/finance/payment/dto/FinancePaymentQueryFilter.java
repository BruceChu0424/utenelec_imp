package com.uten.imp.features.finance.payment.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 采购付款单查询条件。 */
public record FinancePaymentQueryFilter(
        String keyword,
        UUID supplierId,
        UUID accountId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}
