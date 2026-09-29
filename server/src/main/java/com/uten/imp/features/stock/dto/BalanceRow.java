package com.uten.imp.features.stock.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 库存余额查询行（名称由前端按 id 解析）。 */
@Getter
@AllArgsConstructor
public class BalanceRow {
    private UUID id;
    private UUID warehouseId;
    private UUID goodsId;
    private UUID colorId;
    private BigDecimal qty;
    private BigDecimal amountLocal;
    /** 库存重量(千克)；null = 不知道(前端「未称」)。 */
    private BigDecimal weight;
    /** 库存重量含估算(前端加「≈」)。 */
    private boolean weightEstimated;
    private OffsetDateTime lastMovementDate;
    /** 当前用户无 goods:cost:view 时金额已由服务端置空。 */
    private boolean costMasked;
}
