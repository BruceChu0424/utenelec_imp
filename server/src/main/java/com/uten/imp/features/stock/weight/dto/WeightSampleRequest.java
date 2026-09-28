package com.uten.imp.features.stock.weight.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 称样校准 (POST /api/stock/weight/goods/{goodsId}/samples)。
 *
 * @param qty            数了多少个 (基本单位)
 * @param weight         已扣皮重的净重 (weightUnit 计); tareKg 只作留痕, 毛重 = 净重 + 皮重
 * @param weightUnit     重量单位代码 G/KG/T/JIN/LB/OZ (也认符号与中文名)
 * @param tareKg         皮重 kg (可空)
 * @param supplierId     这批货的供应商 (可空)
 * @param warehouseId    仓库 (可空)
 * @param newRegime      从本次起作为新批次 (之前的称重不再参与)
 * @param remark         备注
 * @param idempotencyKey 客户端幂等键 (重试时不重复登记)
 */
public record WeightSampleRequest(
        @NotNull @DecimalMin(value = "0", inclusive = false) @Digits(integer = 14, fraction = 4) BigDecimal qty,
        @NotNull @DecimalMin(value = "0", inclusive = false) @Digits(integer = 14, fraction = 6) BigDecimal weight,
        @NotBlank @Size(max = 8) String weightUnit,
        @DecimalMin("0") @Digits(integer = 14, fraction = 6) BigDecimal tareKg,
        UUID supplierId,
        UUID warehouseId,
        Boolean newRegime,
        @Size(max = 200) String remark,
        @Size(max = 100) String idempotencyKey) {
}
