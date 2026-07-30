package com.uten.imp.features.finance.reconciliation.dto;

import java.time.OffsetDateTime;
import java.util.UUID;

/** 账户流水查询条件。 */
public record FinanceReconciliationQueryFilter(
        String keyword,                // bill_no 模糊
        UUID accountId,                // 按账户过滤（最常用）
        String sourceDocType,          // RECEIPT/PAYMENT/EXPENSE/INCOME/BANK_TRANSFER
        UUID sourceDocId,              // 反查指定单据的流水
        String checkNo,
        OffsetDateTime dateFrom,
        OffsetDateTime dateTo) {
}
