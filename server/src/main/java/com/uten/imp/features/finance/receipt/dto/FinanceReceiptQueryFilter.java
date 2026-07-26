package com.uten.imp.features.finance.receipt.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售收款单查询条件（keyword + 客户/账户/状态精确 + 日期范围）。 */
public record FinanceReceiptQueryFilter(
        String keyword,
        UUID clientId,
        UUID accountId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}
