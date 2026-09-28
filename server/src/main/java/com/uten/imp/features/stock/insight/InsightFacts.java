package com.uten.imp.features.stock.insight;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 库存分析 SQL 一次取回的原始事实 (派生口径全在 {@link WarehouseInsightDefinitions})。 */
final class InsightFacts {

    private InsightFacts() {
    }

    /**
     * 货品 × 颜色 (范围内合计) 的余额、库龄分配、消耗与 ABC 排名原料。
     *
     * @param goodsPicks     该货品 (各颜色合计) 近 90 天出库次数
     * @param picksCumBefore 按出库次数倒序排名时排在它前面的货品的次数之和
     * @param picksTotal     范围内全部货品的出库次数之和
     */
    record Health(
            UUID goodsId, UUID colorId, String code, String name, UUID categoryId, String model,
            String colorName, String unitName,
            BigDecimal qty, BigDecimal weightKg, boolean weightEstimated, BigDecimal amountLocal,
            OffsetDateTime lastMovementAt, long dims, long dimsWeighed,
            BigDecimal age0to30, BigDecimal age31to90, BigDecimal age91to180, BigDecimal age181to365,
            BigDecimal ageOver365, BigDecimal allocated, OffsetDateTime newestIn,
            BigDecimal out30, BigDecimal out90, BigDecimal out365, long picks90, OffsetDateTime lastOutAt,
            long goodsPicks, long picksCumBefore, long picksTotal) {
    }

    /** 仓库 × 货品 × 颜色的盘点建议原料。 */
    record Cycle(
            UUID warehouseId, String warehouseName, UUID goodsId, String code, String name, UUID colorId,
            String colorName, String unitName,
            BigDecimal qty, BigDecimal weightKg, boolean weightEstimated,
            LocalDate lastCountedOn, LocalDate firstMovementOn, LocalDate firstBalanceOn,
            long residuals90, boolean active30, String estimateTier, String estimateEvidence, boolean exact,
            long goodsPicks, long picksCumBefore, long picksTotal) {
    }

    /** 称重异常的原料 (称重记录快照或单重变化)。 */
    record Alert(
            String rowType, UUID id, OffsetDateTime observedAt, UUID goodsId, String code, String name,
            String unitName, String baseUnitDimension, String colorName, UUID warehouseId, String warehouseName, String sourceKind,
            UUID supplierId, String supplierName, String counterpartKind, UUID counterpartId,
            String counterpartName, String sourceDocType, UUID sourceDocId, String sourceDocCode, String billNo,
            BigDecimal qtyBase, BigDecimal weightKg, BigDecimal expectedUnitWeightKg, BigDecimal expectedWeightKg,
            BigDecimal deviationPct, String alertLevel, String estimateTierUsed, String estimateBasisUsed,
            BigDecimal unitWeightKg) {
    }

    /**
     * 单重学习清单候选货品。
     *
     * @param nRef  货品总体学习结果的参考称重次数 (没有学习结果为 null)
     * @param nDraw 货品总体学习结果的领料称重次数
     */
    record Learning(
            UUID goodsId, String code, String name, String model, String unitName, BigDecimal masterKg,
            long movements90d, OffsetDateTime lastMovementAt, long observations, BigDecimal qty,
            Integer nRef, Integer nDraw) {
    }
}
