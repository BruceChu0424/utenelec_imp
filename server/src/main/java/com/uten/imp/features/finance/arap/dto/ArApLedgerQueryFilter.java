package com.uten.imp.features.finance.arap.dto;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 应收应付台账查询条件。
 *
 * <p>{@code partyId} 智能匹配：direction=AR 时落 client_id，AP 时落 supplier_id；
 * 同时给 direction+partyId 即可精确定位（前端按 tab 切换）。
 * billNo/salesOrderNos=单据号列表头值筛选（2026-09-25 单号列统一，精确匹配）。
 */
public record ArApLedgerQueryFilter(
        String keyword,           // bill_no / source_doc_no 模糊
        String direction,         // AR / AP
        String sourceDocType,     // SALES_SHIPMENT / PURCHASE_RECEIPT / ...
        UUID partyId,             // AR→client_id，AP→supplier_id
        UUID clientId,            // 显式按 client_id
        UUID supplierId,          // 显式按 supplier_id
        UUID currencyId,
        Boolean settled,          // 是否结清
        Short status,             // 0/1/-1（默认查全部；老库迁移可能带 -1）
        LocalDate dateFrom,
        LocalDate dateTo,
        String sourceDocNo,       // 立帐单号精确
        String billNo,            // 台账单据号精确（2026-09-25 单号列统一）
        String salesOrderNos) {   // 关联销售单号精确（聚合列，EXISTS 匹配）

    /** 兼容旧签名（无单号筛选）。 */
    public ArApLedgerQueryFilter(
            String keyword, String direction, String sourceDocType, UUID partyId,
            UUID clientId, UUID supplierId, UUID currencyId, Boolean settled,
            Short status, LocalDate dateFrom, LocalDate dateTo, String sourceDocNo) {
        this(keyword, direction, sourceDocType, partyId, clientId, supplierId,
                currencyId, settled, status, dateFrom, dateTo, sourceDocNo, null, null);
    }
}
