package com.uten.imp.features.stock.weight.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 核重: 只改一个库存维度的重量, 不动数量 (POST /api/stock/weight/balances/set, stock:weight:manage, ADR-135 §3.5)。
 *
 * @param warehouseId      仓库
 * @param goodsId          货品
 * @param colorId          颜色 (可空)
 * @param expectedWeightKg 提交人看到的当前重量 kg (乐观核对; null = 看到的是未知)
 * @param targetWeightKg   核定后的重量 kg (&gt; 0)
 * @param reason           原因 2-200 字
 * @param idempotencyKey   幂等键 (重试不重复登记)
 */
public record SetBalanceWeightRequest(
        @NotNull UUID warehouseId,
        @NotNull UUID goodsId,
        UUID colorId,
        @DecimalMin("0") @Digits(integer = 14, fraction = 4) BigDecimal expectedWeightKg,
        @NotNull @DecimalMin(value = "0", inclusive = false) @Digits(integer = 14, fraction = 4)
        BigDecimal targetWeightKg,
        @NotBlank @Size(min = 2, max = 200) String reason,
        @NotBlank @Size(max = 100) String idempotencyKey) {
}
