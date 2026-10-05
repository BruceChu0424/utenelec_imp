package com.uten.imp.features.master.goods.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 货品在某仓库×颜色的即时库存行(stock_balances 一行，仅参与核算仓库)。
 * 用于货品详情「库存量」按仓库展开；线边仓行照常列出但标 lineSide，不计入合计。
 */
@Getter
@AllArgsConstructor
public class GoodsStockRow {
    private UUID warehouseId;
    private String warehouseCode;
    private String warehouseName;
    private UUID colorId;         // 颜色(无色货品为 null)
    private String colorName;     // 颜色名（无色货品为 null）
    private BigDecimal qty;       // 当前余量（基本单位）
    /** 当前库存重量(千克)；null = 不知道(有数量却没有可信重量, 前端「未称」, 绝不当 0)。 */
    private BigDecimal weight;
    /** 库存重量含估算(前端加「≈」)。 */
    private boolean weightEstimated;
    /** 线边仓(V595 车间料架)：不算现实库存，不计入货品合计。 */
    private boolean lineSide;
    /** 不良品仓(ADR-146)：照常列出(前端标「不良品」)，不计入货品合计。 */
    private boolean defective;
}
