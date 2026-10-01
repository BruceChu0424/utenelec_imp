package com.uten.imp.features.finance.bank_transfer.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 银行存取款单查询条件。billNo=单据号表头值筛选（2026-09-25 单号列统一，精确匹配）。 */
public record FinanceBankTransferQueryFilter(
        String keyword,
        UUID outAccountId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
    public FinanceBankTransferQueryFilter(
        String keyword,
        UUID outAccountId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo) { this(keyword, outAccountId, status, dateFrom, dateTo, billNo, false, false); }
    public FinanceBankTransferQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new FinanceBankTransferQueryFilter(keyword, outAccountId, status, dateFrom, dateTo, billNo, includeDeleted || onlyDeleted, onlyDeleted);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public FinanceBankTransferQueryFilter(
            String keyword, UUID outAccountId, Short status,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, outAccountId, status, dateFrom, dateTo, null);
    }
}
