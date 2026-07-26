package com.uten.imp.features.finance.report.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 应收应付汇总行（Z/B/D 报表，查 finance_ar_ap_mv 上卷）。
 *
 * <p>按 ym/direction/sourceDocType/partyId/currencyId 分组（MV 维度），partyName/currencyCode 由 JOIN 主档补。
 */
@Getter
@AllArgsConstructor
public class ArApSummaryRow {
    private LocalDate ym;
    private String direction;            // AR / AP
    private String sourceDocType;        // SALES_SHIPMENT / PURCHASE_RECEIPT / ...
    private UUID partyId;                // COALESCE(client_id, supplier_id)
    private String partyName;            // JOIN clients/suppliers
    private UUID currencyId;
    private Long entryCnt;
    private BigDecimal originalLocalSum;
    private BigDecimal settledSum;
    private BigDecimal balanceSum;
}
