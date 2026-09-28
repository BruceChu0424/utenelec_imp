package com.uten.imp.features.stock.weight;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 解析一个货品单重所需的全部事实 (一条 SQL 读出): 货品基本单位是否为重量单位、设计单重、货品称重设置、
 * 货品级学习结果与最近一次皮重。
 *
 * @param goodsId              货品
 * @param exists               货品存在 (未删除)
 * @param goodsUnitId          货品基本单位
 * @param goodsMassCode        基本单位登记的重量单位代码 (有 = 按重量计的货品, EXACT)
 * @param baseUnitDimension    基本单位的计量维度 (未登记为 null)
 * @param masterWeight         货品档案设计单重 (goods.m_weight, 以 m_weight_unit_id 计)
 * @param masterWeightMassCode 设计单重单位的重量单位代码
 * @param profile              货品称重设置 (没有行时为默认值, exists=false)
 * @param pool                 货品级学习结果 (supplier_id 为空的行; 没有时 null)
 * @param lastTareKg           最近一次带皮重的称重记录的皮重 (只看最近 50 条记录)
 */
public record GoodsWeightFacts(
        UUID goodsId,
        boolean exists,
        UUID goodsUnitId,
        String goodsMassCode,
        String baseUnitDimension,
        BigDecimal masterWeight,
        String masterWeightMassCode,
        Profile profile,
        EstimateRow pool,
        BigDecimal lastTareKg) {

    public GoodsWeightFacts {
        profile = profile == null ? Profile.missing() : profile;
    }

    public static GoodsWeightFacts missing(UUID goodsId) {
        return new GoodsWeightFacts(goodsId, false, null, null, null, null, null, Profile.missing(), null, null);
    }

    /** 基本单位本身是重量单位: 重量 = 数量 × 换算系数, 不学习。 */
    public boolean exact() {
        return goodsMassCode != null;
    }

    /** goods_weight_profiles 一行 (缺省值已代入)。 */
    public record Profile(
            boolean exists,
            BigDecimal defaultTareKg,
            BigDecimal tolerancePct,
            BigDecimal pieceCvPct,
            BigDecimal manualUnitWeightKg,
            UUID manualUnitId,
            String manualReason,
            UUID manualSetBy,
            OffsetDateTime manualSetAt,
            boolean learningEnabled,
            String regimeMode,
            OffsetDateTime manualRegimeStartAt,
            long version,
            UUID updatedBy,
            OffsetDateTime updatedAt) {

        public static final String REGIME_AUTO = "AUTO";
        public static final String REGIME_MANUAL = "MANUAL";

        public static Profile missing() {
            return new Profile(false, null, null, null, null, null, null, null, null, true, REGIME_AUTO,
                    null, 0L, null, null);
        }

        /** 生效的容差 (%), 未设置时 3.000。 */
        public BigDecimal effectiveTolerancePct() {
            return tolerancePct == null ? EstimatorConfig.DEFAULT_TOLERANCE_PCT : tolerancePct;
        }

        /** 生效的单件离散 (%), 未设置时 2.000。 */
        public BigDecimal effectivePieceCvPct() {
            return pieceCvPct == null ? EstimatorConfig.DEFAULT_PIECE_CV_PCT : pieceCvPct;
        }

        public boolean autoRegime() {
            return !REGIME_MANUAL.equals(regimeMode);
        }
    }

    /** goods_weight_estimates 一行。 */
    public record EstimateRow(
            UUID supplierId,
            String evidence,
            Double logMean,
            BigDecimal unitWeightKg,
            Double logSe,
            Double tauLot,
            Double tauBetween,
            Double shrinkWeight,
            Double rawLogMean,
            Integer nObs,
            Integer nRef,
            Integer nInliers,
            Double nEff,
            Double relHalfWidth,
            String tier,
            Double drawBiasLog,
            Double drawBiasSe,
            Integer nDraw,
            Double labelBiasLog,
            Double labelBiasSe,
            OffsetDateTime regimeStartedAt,
            OffsetDateTime regimeChangedAt,
            OffsetDateTime lastObservedAt,
            OffsetDateTime asOf,
            String outliersJson,
            Integer suggestedSampleSize,
            Short algorithmVersion,
            OffsetDateTime computedAt) {
    }
}
