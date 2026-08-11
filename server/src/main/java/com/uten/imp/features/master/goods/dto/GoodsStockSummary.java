package com.uten.imp.features.master.goods.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.List;

/**
 * 货品即时库存汇总：合计数量/重量 + 按仓库（×颜色）明细行。
 * 数据源 stock_balances（仅 warehouses.is_accountable 参与核算仓库），口径同即时库存。
 */
@Getter
@AllArgsConstructor
public class GoodsStockSummary {
    private BigDecimal totalQty;          // 各参与核算仓库余量合计
    private BigDecimal totalWeight;       // 各参与核算仓库重量合计
    private List<GoodsStockRow> rows;     // 按仓库（×颜色）展开
}
