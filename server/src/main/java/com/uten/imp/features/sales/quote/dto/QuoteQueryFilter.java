package com.uten.imp.features.sales.quote.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售报价列表查询条件。billNo=单据号表头值筛选（2026-09-25 单号列统一，精确匹配）。 */
public record QuoteQueryFilter(
        String keyword,
        UUID clientId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo) {

    /** 兼容旧签名（无单号筛选）。 */
    public QuoteQueryFilter(
            String keyword, UUID clientId, Short status, LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, clientId, status, dateFrom, dateTo, null);
    }
}
