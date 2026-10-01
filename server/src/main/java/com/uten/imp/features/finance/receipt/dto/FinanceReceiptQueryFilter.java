package com.uten.imp.features.finance.receipt.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售收款单查询条件（keyword + 客户/账户/状态/收款类型精确 + 日期范围）。
 *  billNo=单据号表头值筛选（2026-09-25 单号列统一，精确匹配）。 */
public record FinanceReceiptQueryFilter(
        String keyword,
        UUID clientId,
        UUID accountId,
        Short status,
        String receiptKind,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo,
        boolean includeDeleted, boolean onlyDeleted,
        com.uten.imp.common.web.HeaderColumnFilter headerFilters) {
    public FinanceReceiptQueryFilter {
        headerFilters = headerFilters == null ? com.uten.imp.common.web.HeaderColumnFilter.EMPTY : headerFilters;
    }
    public FinanceReceiptQueryFilter(String keyword,
        UUID clientId,
        UUID accountId,
        Short status,
        String receiptKind,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
        this(keyword, clientId, accountId, status, receiptKind, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, com.uten.imp.common.web.HeaderColumnFilter.EMPTY);
    }
    public FinanceReceiptQueryFilter withHeaders(com.uten.imp.common.web.HeaderColumnFilter headers) {
        return new FinanceReceiptQueryFilter(keyword, clientId, accountId, status, receiptKind, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, headers);
    }

    public FinanceReceiptQueryFilter(
        String keyword,
        UUID clientId,
        UUID accountId,
        Short status,
        String receiptKind,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo) { this(keyword, clientId, accountId, status, receiptKind, dateFrom, dateTo, billNo, false, false); }
    public FinanceReceiptQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new FinanceReceiptQueryFilter(keyword, clientId, accountId, status, receiptKind, dateFrom, dateTo, billNo, includeDeleted || onlyDeleted, onlyDeleted, headerFilters);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public FinanceReceiptQueryFilter(
            String keyword, UUID clientId, UUID accountId, Short status,
            String receiptKind, LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, clientId, accountId, status, receiptKind, dateFrom, dateTo, null);
    }
}
