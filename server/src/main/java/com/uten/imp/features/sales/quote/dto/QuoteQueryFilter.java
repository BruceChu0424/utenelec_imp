package com.uten.imp.features.sales.quote.dto;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 销售报价列表查询条件。billNo=单据号表头值筛选(2026-09-25 单号列统一, 精确匹配);
 * bucket=列表分段(DRAFT / PENDING_FINANCE / FINANCE_REJECTED / APPROVED / REVERSED, 与分段计数同口径);
 * 另有只作筛选的 AWAITING_CONVERSION(已核价、还没转订货单, 与徽章「报价已核价待转订货」同口径)。
 */
public record QuoteQueryFilter(
        String keyword,
        UUID clientId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo,
        String bucket,
        boolean includeDeleted, boolean onlyDeleted) {
    public QuoteQueryFilter(
        String keyword,
        UUID clientId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo,
        String bucket) { this(keyword, clientId, status, dateFrom, dateTo, billNo, bucket, false, false); }
    public QuoteQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new QuoteQueryFilter(keyword, clientId, status, dateFrom, dateTo, billNo, bucket, includeDeleted || onlyDeleted, onlyDeleted);
    }


    /** 兼容旧签名(无分段)。 */
    public QuoteQueryFilter(
            String keyword, UUID clientId, Short status, LocalDate dateFrom, LocalDate dateTo, String billNo) {
        this(keyword, clientId, status, dateFrom, dateTo, billNo, null);
    }

    /** 兼容旧签名(无单号筛选)。 */
    public QuoteQueryFilter(
            String keyword, UUID clientId, Short status, LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, clientId, status, dateFrom, dateTo, null, null);
    }
}
