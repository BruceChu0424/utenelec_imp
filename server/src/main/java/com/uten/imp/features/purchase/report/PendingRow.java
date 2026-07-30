package com.uten.imp.features.purchase.report;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 待交货订货汇总行（货品×颜色，名称前端解析）。 */
@Getter
@AllArgsConstructor
public class PendingRow {
    private UUID goodsId;
    private UUID colorId;
    private BigDecimal pendingQty;
    private BigDecimal pendingAmt;
}
