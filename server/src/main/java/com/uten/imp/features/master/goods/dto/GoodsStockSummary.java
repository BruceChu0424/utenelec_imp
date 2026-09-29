package com.uten.imp.features.master.goods.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.List;

/**
 * 货品即时库存汇总：合计数量/重量 + 按仓库×颜色明细行。
 * 数据源 stock_balances(仅 warehouses.is_accountable 参与核算仓库)，线边仓行列出但不计入合计。
 * 重量合计口径同即时库存合计条(ADR-135)：只加已知重量，未知的行另计行数(前端「另有 N 处未称」)，
 * 绝不把未知当 0；一行已知的有量重量都没有而又有未知行时合计为 null(前端「未称」)。
 */
@Getter
@AllArgsConstructor
public class GoodsStockSummary {
    private BigDecimal totalQty;          // 非线边核算仓余量合计
    private BigDecimal totalWeight;       // 非线边核算仓已知重量合计(千克)；null = 有量的行重量全都未知
    private int weightUnknownRows;        // 非线边行里有数量却重量未知的行数
    private boolean weightEstimated;      // 合计含估算重量
    private List<GoodsStockRow> rows;     // 按仓库×颜色展开(含线边仓行)
}
