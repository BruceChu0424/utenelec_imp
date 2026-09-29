package com.uten.imp.features.stock.weight.dto;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 核重后的库存维度 (POST /api/stock/weight/balances/set 响应)。
 *
 * @param adjustmentId    本次重量调整行
 * @param qty             库存数量 (基本单位)
 * @param weightKg        库存重量 kg (null = 未知)
 * @param weightEstimated 重量是估算
 */
public record BalanceWeightView(
        UUID adjustmentId,
        UUID warehouseId,
        UUID goodsId,
        UUID colorId,
        BigDecimal qty,
        BigDecimal weightKg,
        boolean weightEstimated) {
}
