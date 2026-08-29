package com.uten.imp.features.purchase.report;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 采购月度汇总行（上卷货品×供应商×类型，名称前端解析）。 */
@Getter
@AllArgsConstructor
public class MonthlySummaryRow {
    private String docType;
    private LocalDate ym;
    private UUID goodsId;
    private UUID supplierId;
    private BigDecimal qty;
    private BigDecimal amt;
    private Long lines;
    private boolean priceMasked;
}
