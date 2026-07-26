package com.uten.imp.features.sales.report;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 销售待交货订货汇总行（sales_order_pending_v：货品 × 颜色 × 客户；名称前端解析）。 */
@Getter
@AllArgsConstructor
public class PendingRow {
    private UUID goodsId;
    private UUID colorId;
    private UUID clientId;
    private BigDecimal pendingQty;
    private BigDecimal pendingAmt;
}
