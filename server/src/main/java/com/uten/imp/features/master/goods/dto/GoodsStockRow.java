package com.uten.imp.features.master.goods.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 货品在某仓库（×颜色）的即时库存行（聚合 stock_balances，仅参与核算仓库）。
 * 用于货品详情「库存量」按仓库展开。
 */
@Getter
@AllArgsConstructor
public class GoodsStockRow {
    private UUID warehouseId;
    private String warehouseCode;
    private String warehouseName;
    private String colorName;     // 颜色名（无色货品为 null）
    private BigDecimal qty;       // 当前余量（基本单位）
    private BigDecimal weight;    // 当前库存重量
}
