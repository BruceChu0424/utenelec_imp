package com.uten.imp.features.finance.arap.dto;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 应收应付台账查询条件。
 *
 * <p>{@code partyId} 智能匹配：direction=AR 时落 client_id，AP 时落 supplier_id；
 * 同时给 direction+partyId 即可精确定位（前端按 tab 切换）。
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
        String sourceDocNo) {     // 立帐单号精确
}
