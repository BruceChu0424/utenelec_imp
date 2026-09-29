package com.uten.imp.features.stock.weight.dto;

import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;

/**
 * 修改货品称重设置 (PUT /api/stock/weight/goods/{goodsId}/profile, stock:weight:manage)。整份替换: null 表示清空
 * (容差/单件离散清空后按缺省 3% / 2%; learningEnabled、regimeMode 为 null 时按 true / AUTO)。
 *
 * @param expectedVersion    读到的版本 (没有设置行时为 0), 不一致返回 409
 * @param defaultTareKg      默认皮重 kg
 * @param tolerancePct       核对容差 (%)
 * @param pieceCvPct         单件离散 (%)
 * @param manualUnitWeightKg 人工设定单重 kg/基本单位 (清空 = 回到学习结果)
 * @param manualReason       设定原因
 * @param learningEnabled    参与学习
 * @param regimeMode         AUTO (检测到单重突变自动切批次) / MANUAL (只提示, 由人重新开始学习)
 */
public record WeightProfileUpdateRequest(
        @NotNull Long expectedVersion,
        @DecimalMin("0") @Digits(integer = 14, fraction = 6) BigDecimal defaultTareKg,
        @DecimalMin(value = "0", inclusive = false) @DecimalMax("100") @Digits(integer = 3, fraction = 3)
        BigDecimal tolerancePct,
        @DecimalMin(value = "0", inclusive = false) @DecimalMax("50") @Digits(integer = 3, fraction = 3)
        BigDecimal pieceCvPct,
        @DecimalMin(value = "0", inclusive = false) @Digits(integer = 12, fraction = 12) BigDecimal manualUnitWeightKg,
        @Size(max = 200) String manualReason,
        Boolean learningEnabled,
        @Pattern(regexp = "AUTO|MANUAL") String regimeMode) {
}
