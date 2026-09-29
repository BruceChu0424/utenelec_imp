package com.uten.imp.features.stock.weight;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

/**
 * 估算器输出: 货品级 (pool, supplier_id 为空) 一行 + 每个有有效观测的供应商一行,
 * 与 goods_weight_estimates 的列一一对应 (数值仍是 double, 落库时才转 BigDecimal)。
 *
 * @param evidence     依据种类; NONE 表示没有可学的数据 (不落行, 已有行删除)
 * @param asOf         本次用到的观测里最晚的称重时间 (衰减的基准, 不用 now)
 * @param pool         货品级行; evidence = NONE 时为 null
 * @param suppliers    供应商行 (按首次出现顺序)
 * @param outliers     本次判为离群的观测 (全部分组)
 */
public record EstimateResult(
        Evidence evidence,
        Instant asOf,
        Row pool,
        List<Row> suppliers,
        List<Outlier> outliers) {

    public EstimateResult {
        suppliers = suppliers == null ? List.of() : List.copyOf(suppliers);
        outliers = outliers == null ? List.of() : List.copyOf(outliers);
    }

    public static EstimateResult none(Instant asOf) {
        return new EstimateResult(Evidence.NONE, asOf, null, List.of(), List.of());
    }

    /** 依据种类; 前三个是 goods_weight_estimates.evidence 的取值。 */
    public enum Evidence {
        /** 有独立点数的称重 (称样/盘点/到货/产成品/其它入库)。 */
        REFERENCE,
        /** 只有领料称重, 单重含超发, 标注「按过往领料推算」。 */
        DRAW_ONLY,
        /** 只有两次且互相矛盾 (多半单位填错), 不给单重, 请称样。 */
        CONFLICT,
        /** 没有可学的数据。 */
        NONE
    }

    /** 可靠度: 对数半宽 ≤1% GREEN, ≤5% YELLOW, 其余 RED。 */
    public enum Tier {
        GREEN, YELLOW, RED;

        /** 取两者里更差的一个。 */
        public Tier worse(Tier other) {
            if (other == null) {
                return this;
            }
            return ordinal() >= other.ordinal() ? this : other;
        }
    }

    /**
     * 一行估算结果。
     *
     * @param supplierId        供应商; null = 货品级 (pool)
     * @param evidence          依据
     * @param logMean           ln(单重 kg/基本单位); CONFLICT 为 null
     * @param logSe             logMean 的标准误
     * @param tauLot            批间差异 sd (整货品共用)
     * @param tauBetween        pool 行: 计入请求先验的额外 sd (供应商间差异; 只有领料时是领料偏差允许量);
     *                          供应商行: 收缩用的供应商间差异 sd (不计入该行先验)
     * @param shrinkWeight      供应商行的收缩权重 w_p
     * @param rawLogMean        供应商行收缩前的均值 x_p
     * @param nObs              本行分组载入的观测数 (pool 含领料)
     * @param nRef              本行分组的 REFERENCE 观测数
     * @param nInliers          本行当前批次里的有效 (非离群) 观测数
     * @param nEff              有效样本量 (Σw)²/Σw²
     * @param logHalfWidth      存储口径 (N→∞, 无抽样) 的 95% 对数半宽
     * @param relHalfWidth      e^logHalfWidth - 1
     * @param tier              存储口径可靠度
     * @param drawBiasLog       领料实发比应发的对数偏差 (pool 行)
     * @param drawBiasSe        其标准误
     * @param nDraw             参与的领料观测数 (pool 行)
     * @param labelBiasLog      供应商标签偏差 (到货 vs 称样, 显著时才有)
     * @param labelBiasSe       其标准误
     * @param regimeStartedAt   当前批次起点 (该分组第一条参与的观测时间)
     * @param regimeChangedAt   自动检测到的最近一次单重突变起点 (无则 null)
     * @param lastObservedAt    本行分组最近一次称重时间
     * @param outliers          本行分组的离群观测
     * @param suggestedSampleSize 建议称样件数
     * @param lotPrior          请求先验方差 P (pool: se²+τ_lot²+tauBetween²; 供应商: se²+τ_lot²)
     * @param df                t 分位数自由度 (整货品有效观测数 - 1 + ν0)
     */
    public record Row(
            UUID supplierId,
            Evidence evidence,
            Double logMean,
            Double logSe,
            Double tauLot,
            Double tauBetween,
            Double shrinkWeight,
            Double rawLogMean,
            int nObs,
            int nRef,
            int nInliers,
            Double nEff,
            Double logHalfWidth,
            Double relHalfWidth,
            Tier tier,
            Double drawBiasLog,
            Double drawBiasSe,
            Integer nDraw,
            Double labelBiasLog,
            Double labelBiasSe,
            Instant regimeStartedAt,
            Instant regimeChangedAt,
            Instant lastObservedAt,
            List<Outlier> outliers,
            int suggestedSampleSize,
            Double lotPrior,
            Double df) {

        public Row {
            outliers = outliers == null ? List.of() : List.copyOf(outliers);
        }

        /** 单重 kg/基本单位; 没有时为 null。 */
        public Double unitWeightKg() {
            return logMean == null ? null : StrictMath.exp(logMean);
        }
    }

    /**
     * 离群观测。
     *
     * @param observationId 观测 id
     * @param z             稳健 z
     * @param hint          UNIT_10/UNIT_100/UNIT_1000 (差 10 的幂, 多半单位填错), JIN_KG (差 2 倍),
     *                      LB_KG (磅与千克混用), DEVIATION (其它偏差)
     */
    public record Outlier(UUID observationId, double z, String hint) {
    }
}
