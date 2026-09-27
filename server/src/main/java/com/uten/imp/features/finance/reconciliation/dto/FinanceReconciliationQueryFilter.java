package com.uten.imp.features.finance.reconciliation.dto;

import java.time.OffsetDateTime;
import java.util.UUID;

/** 账户流水查询条件。entryKind=流水类型表头筛选（2026-09-16：
 * POSTING 入账 / REVERSAL 反向冲销 / ADJUSTMENT 余额调整）。
 * billNo=单据号表头值筛选（2026-09-25 单号列统一，精确匹配）。 */
public record FinanceReconciliationQueryFilter(
        String keyword,                // bill_no 模糊
        UUID accountId,                // 按账户过滤（最常用）
        String sourceDocType,          // RECEIPT/PAYMENT/EXPENSE/INCOME/BANK_TRANSFER
        UUID sourceDocId,              // 反查指定单据的流水
        String checkNo,
        OffsetDateTime dateFrom,
        OffsetDateTime dateTo,
        String entryKind,
        String billNo) {               // 单据号精确（2026-09-25 单号列统一）

    /** 兼容旧调用：不按流水类型过滤。 */
    public FinanceReconciliationQueryFilter(
            String keyword, UUID accountId, String sourceDocType, UUID sourceDocId,
            String checkNo, OffsetDateTime dateFrom, OffsetDateTime dateTo) {
        this(keyword, accountId, sourceDocType, sourceDocId, checkNo, dateFrom, dateTo, null, null);
    }

    /** 兼容旧调用：无单号筛选。 */
    public FinanceReconciliationQueryFilter(
            String keyword, UUID accountId, String sourceDocType, UUID sourceDocId,
            String checkNo, OffsetDateTime dateFrom, OffsetDateTime dateTo, String entryKind) {
        this(keyword, accountId, sourceDocType, sourceDocId, checkNo, dateFrom, dateTo, entryKind, null);
    }
}
