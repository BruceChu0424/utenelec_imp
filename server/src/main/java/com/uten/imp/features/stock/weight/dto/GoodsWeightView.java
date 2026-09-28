package com.uten.imp.features.stock.weight.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 货品单重学习概况 (GET /api/stock/weight/goods/{goodsId}, 称样/设置/排除等写操作也返回刷新后的它)。
 *
 * @param goodsId             货品
 * @param profile             称重设置 (没有设置行时为缺省值, exists=false)
 * @param resolved            当前生效的单重参数 (与 /params 的元素同形, 不带供应商)
 * @param goodsRow            货品级学习结果 (没有时 null)
 * @param supplierRows        各供应商学习结果
 * @param supplierNamesMasked 供应商名称已隐藏 (需要 stock_report:view 或 stock:weight:manage)
 * @param drawBiasPct         领料实发比应发 (%)
 * @param regimeStartedAt     当前批次起点
 * @param regimeChangedAt     自动检测到的最近一次单重突变 (任一分组, 无则 null)
 * @param outliers            离群观测
 * @param counts              观测计数
 */
public record GoodsWeightView(
        UUID goodsId,
        Profile profile,
        WeightParams resolved,
        EstimateRowView goodsRow,
        List<SupplierRow> supplierRows,
        boolean supplierNamesMasked,
        Double drawBiasPct,
        OffsetDateTime regimeStartedAt,
        OffsetDateTime regimeChangedAt,
        List<Outlier> outliers,
        Counts counts) {

    /**
     * 称重设置 (缺省值已代入)。
     *
     * @param exists              已有设置行
     * @param manualActive        人工单重生效中 (设定时的基本单位与现在一致)
     * @param manualSetByName     设定人姓名
     * @param version             乐观锁版本 (没有设置行时 0)
     */
    public record Profile(
            boolean exists,
            BigDecimal defaultTareKg,
            BigDecimal tolerancePct,
            BigDecimal pieceCvPct,
            BigDecimal manualUnitWeightKg,
            boolean manualActive,
            String manualReason,
            UUID manualSetBy,
            String manualSetByName,
            OffsetDateTime manualSetAt,
            boolean learningEnabled,
            String regimeMode,
            OffsetDateTime manualRegimeStartAt,
            long version,
            OffsetDateTime updatedAt) {
    }

    /** 一行学习结果 (货品级)。 */
    public record EstimateRowView(
            String evidence,
            BigDecimal unitWeightKg,
            Double logMean,
            Double logSe,
            Double tauLot,
            Double tauBetween,
            @JsonProperty("nObs") Integer nObs,
            @JsonProperty("nRef") Integer nRef,
            @JsonProperty("nInliers") Integer nInliers,
            @JsonProperty("nEff") Double nEff,
            Double relHalfWidth,
            String tier,
            Double drawBiasPct,
            Double drawBiasSePct,
            @JsonProperty("nDraw") Integer nDraw,
            OffsetDateTime regimeStartedAt,
            OffsetDateTime regimeChangedAt,
            OffsetDateTime lastObservedAt,
            OffsetDateTime asOf,
            Integer suggestedSampleSize,
            Short algorithmVersion,
            OffsetDateTime computedAt) {
    }

    /**
     * 一个供应商的单重。
     *
     * @param supplierName  供应商名称 (无权限时 null)
     * @param diffPct       与货品级单重的差异 (%)
     * @param shrinkWeight  向货品级收缩后自身数据所占权重 (越接近 1 越说明本供应商数据充足)
     * @param labelBiasPct  到货按标签数量 vs 称样的系统偏差 (%, 显著时才有: 标签数可能不准)
     */
    public record SupplierRow(
            UUID supplierId,
            String supplierName,
            BigDecimal unitWeightKg,
            Double diffPct,
            @JsonProperty("nRef") Integer nRef,
            @JsonProperty("nInliers") Integer nInliers,
            OffsetDateTime lastObservedAt,
            String tier,
            Double relHalfWidth,
            Double shrinkWeight,
            Double labelBiasPct,
            OffsetDateTime regimeStartedAt,
            OffsetDateTime regimeChangedAt) {
    }

    /** 离群观测与提示 (UNIT_10/UNIT_100/UNIT_1000/JIN_KG/LB_KG/DEVIATION)。 */
    public record Outlier(UUID observationId, double z, String hint) {
    }

    /** 观测计数: 全部 / 有效 / 已红冲 / 已排除 / 参照类有效 / 核对类有效 / 离群。 */
    public record Counts(long total, long active, long reversed, long excluded, long reference, long check,
                         long outliers) {
    }
}
