package com.uten.imp.features.finance.payment.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 采购付款单查询条件。billNo=单据号表头值筛选（2026-09-25 单号列统一，精确匹配）。 */
public record FinancePaymentQueryFilter(
        String keyword,
        UUID supplierId,
        UUID accountId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo) {

    /** 兼容旧签名（无单号筛选）。 */
    public FinancePaymentQueryFilter(
            String keyword, UUID supplierId, UUID accountId, Short status,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, supplierId, accountId, status, dateFrom, dateTo, null);
    }
}
