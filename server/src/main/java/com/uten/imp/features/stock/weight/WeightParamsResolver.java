package com.uten.imp.features.stock.weight;

import com.uten.imp.common.measure.WeightUnit;
import com.uten.imp.features.stock.weight.EstimateResult.Evidence;
import com.uten.imp.features.stock.weight.EstimateResult.Tier;
import com.uten.imp.features.stock.weight.GoodsWeightFacts.EstimateRow;
import com.uten.imp.features.stock.weight.GoodsWeightFacts.Profile;
import com.uten.imp.features.stock.weight.dto.WeightParams;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.Objects;
import java.util.Optional;

/**
 * 读时解析单重 (ADR-135 §5): EXACT &gt; MANUAL &gt; LEARNED &gt; MASTER_PRIOR &gt; NONE。纯函数。
 *
 * <ul>
 *   <li>EXACT: 基本单位本身是重量单位, 重量 = 数量 × 换算系数, 不学习也不核对;</li>
 *   <li>MANUAL: 人工设定且设定时的基本单位与现在一致; 先验 P = τ_lot² (有学习结果时取其批间差异, 否则 1%²),
 *       可靠度按半宽算而不是直接给 GREEN; 与学到的单重差异明显时给出 manualConflictPct;</li>
 *   <li>LEARNED: 请求带供应商且该供应商有自己的行时用供应商行, 否则货品级行; 超过 365 天没有新称重时
 *       可靠度最多 YELLOW; CONFLICT 不给单重 (落到下一级);</li>
 *   <li>MASTER_PRIOR: 货品档案设计单重 × 其重量单位换算, P = 5%², 固定 RED;</li>
 *   <li>NONE: 什么都没有。</li>
 * </ul>
 * 偏差告警只对 MANUAL 与「有独立点数依据」的 LEARNED 开放, 且请求可靠度不是 RED。
 */
public final class WeightParamsResolver {

    public static final String BASIS_EXACT = "EXACT";
    public static final String BASIS_MANUAL = "MANUAL";
    public static final String BASIS_LEARNED = "LEARNED";
    public static final String BASIS_MASTER_PRIOR = "MASTER_PRIOR";
    public static final String BASIS_NONE = "NONE";

    /** 人工单重与学到的单重「差异明显」的下限 (对数 2%), 同时要超过 3 倍标准误。 */
    private static final double MANUAL_CONFLICT_MIN = 0.02;
    private static final int MANUAL_CONFLICT_MIN_INLIERS = 5;
    private static final int UNIT_WEIGHT_SCALE = 12;

    private WeightParamsResolver() {
    }

    /**
     * 解析结果。
     *
     * @param params        接口返回的参数
     * @param predictor     计算用参数; EXACT/NONE 为 null
     * @param tier          可靠度 (存储口径 + 陈旧封顶)
     * @param alertsAllowed 该依据是否允许偏差告警 (还要看请求可靠度)
     * @param config        该货品的估算参数 (γ、容差按货品设置)
     */
    public record Resolution(WeightParams params, ApwPredictor.Params predictor, Tier tier,
                             boolean alertsAllowed, EstimatorConfig config) {

        public String basis() {
            return params.basis();
        }
    }

    /**
     * @param facts       货品事实
     * @param supplierRow 该供应商的学习行 (可空)
     * @param key         请求行 key
     * @param now         当前时间 (判断陈旧)
     * @param scaleResKg  秤分辨率 kg
     */
    public static Resolution resolve(GoodsWeightFacts facts, EstimateRow supplierRow, String key,
                                     Instant now, double scaleResKg) {
        Objects.requireNonNull(facts, "facts");
        Profile profile = facts.profile();
        EstimatorConfig cfg = EstimatorConfig.forProfile(profile.pieceCvPct(), profile.tolerancePct(), scaleResKg);
        Builder b = new Builder(key, facts, cfg);
        if (!facts.exists()) {
            return b.none();
        }
        Optional<WeightUnit> goodsMass = WeightUnit.tryParse(facts.goodsMassCode());
        if (goodsMass.isPresent()) {
            return b.exact(goodsMass.get().kgPerUnit());
        }
        EstimateRow pool = facts.pool();
        Evidence poolEvidence = evidence(pool);
        boolean poolReference = poolEvidence == Evidence.REFERENCE && pool.logMean() != null;
        double poolDf = poolDf(pool, poolEvidence, cfg);

        BigDecimal manual = profile.manualUnitWeightKg();
        if (manual != null && manual.signum() > 0 && facts.goodsUnitId() != null
                && facts.goodsUnitId().equals(profile.manualUnitId())) {
            double mu = StrictMath.log(manual.doubleValue());
            double tauLot = poolReference && pool.tauLot() != null ? pool.tauLot() : cfg.tau0();
            double prior = tauLot * tauLot;
            double df = poolReference ? poolDf : cfg.nu0();
            Tier tier = ApwEstimator.tierOf(StudentT.t975(df) * Math.sqrt(prior), cfg);
            Double conflictPct = null;
            if (poolReference && pool.nInliers() != null && pool.nInliers() >= MANUAL_CONFLICT_MIN_INLIERS) {
                double diff = mu - pool.logMean();
                double se = pool.logSe() == null ? 0.0 : pool.logSe();
                if (Math.abs(diff) > Math.max(MANUAL_CONFLICT_MIN, 3 * se)) {
                    conflictPct = 100.0 * StrictMath.expm1(diff);
                }
            }
            return b.learnedLike(BASIS_MANUAL, false, manual, mu, prior, df, tier, pool,
                    pool == null ? null : pool.nInliers(), conflictPct, false, true);
        }

        if (pool != null && pool.logMean() != null
                && (poolEvidence == Evidence.REFERENCE || poolEvidence == Evidence.DRAW_ONLY)) {
            boolean supplierSpecific = poolEvidence == Evidence.REFERENCE && supplierRow != null
                    && supplierRow.logMean() != null;
            EstimateRow row = supplierSpecific ? supplierRow : pool;
            double mu = row.logMean();
            double se = row.logSe() == null ? 0.0 : row.logSe();
            double tauLot = row.tauLot() == null ? cfg.tau0() : row.tauLot();
            double prior = se * se + tauLot * tauLot;
            if (!supplierSpecific && row.tauBetween() != null) {
                prior += row.tauBetween() * row.tauBetween();
            }
            Tier tier = row.tier() == null ? Tier.RED : Tier.valueOf(row.tier());
            OffsetDateTime last = row.lastObservedAt() != null ? row.lastObservedAt() : pool.lastObservedAt();
            boolean stale = last != null && now != null
                    && last.toInstant().isBefore(now.minus(Duration.ofDays(cfg.staleDays())));
            if (stale && tier == Tier.GREEN) {
                tier = Tier.YELLOW;
            }
            BigDecimal unitWeight = row.unitWeightKg() != null ? row.unitWeightKg() : kg(StrictMath.exp(mu));
            return b.learnedLike(BASIS_LEARNED, supplierSpecific, unitWeight, mu, prior, poolDf, tier, row,
                    row.nInliers(), null, stale, poolEvidence == Evidence.REFERENCE);
        }

        Optional<WeightUnit> masterUnit = WeightUnit.tryParse(facts.masterWeightMassCode());
        if (facts.masterWeight() != null && facts.masterWeight().signum() > 0 && masterUnit.isPresent()) {
            BigDecimal kgPerBase = facts.masterWeight().multiply(masterUnit.get().kgPerUnit())
                    .setScale(UNIT_WEIGHT_SCALE, RoundingMode.HALF_EVEN);
            if (kgPerBase.signum() > 0) {
                double prior = cfg.masterPriorSd() * cfg.masterPriorSd();
                return b.learnedLike(BASIS_MASTER_PRIOR, false, kgPerBase, StrictMath.log(kgPerBase.doubleValue()),
                        prior, cfg.nu0(), Tier.RED, pool, null, null, false, false);
            }
        }
        return b.none();
    }

    /** 把解析结果的单重换成 kg/基本单位的 BigDecimal (12 位)。 */
    static BigDecimal kg(double value) {
        if (!Double.isFinite(value) || value <= 0) {
            return null;
        }
        BigDecimal kg = BigDecimal.valueOf(value).setScale(UNIT_WEIGHT_SCALE, RoundingMode.HALF_EVEN);
        return kg.signum() > 0 ? kg : null;
    }

    private static Evidence evidence(EstimateRow row) {
        if (row == null || row.evidence() == null) {
            return null;
        }
        try {
            return Evidence.valueOf(row.evidence());
        } catch (IllegalArgumentException unknown) {
            return null;
        }
    }

    /** 自由度: 有参照时 = 有效观测数 - 1 + ν0; 只有领料时 = 领料次数 - 1 + ν0; 否则 ν0。 */
    private static double poolDf(EstimateRow pool, Evidence evidence, EstimatorConfig cfg) {
        if (evidence == Evidence.REFERENCE && pool.nInliers() != null && pool.nInliers() > 0) {
            return pool.nInliers() - 1 + cfg.nu0();
        }
        if (evidence == Evidence.DRAW_ONLY && pool.nDraw() != null && pool.nDraw() > 0) {
            return pool.nDraw() - 1 + cfg.nu0();
        }
        return cfg.nu0();
    }

    private static final class Builder {
        private final String key;
        private final GoodsWeightFacts facts;
        private final EstimatorConfig cfg;

        Builder(String key, GoodsWeightFacts facts, EstimatorConfig cfg) {
            this.key = key;
            this.facts = facts;
            this.cfg = cfg;
        }

        Resolution none() {
            EstimateRow pool = facts.pool();
            Profile profile = facts.profile();
            WeightParams params = new WeightParams(key, facts.goodsId(), BASIS_NONE, false,
                    pool == null ? null : pool.evidence(), null, null, null, cfg.gamma(), null, null, null,
                    pool == null ? null : pool.nInliers(), ApwEstimator.suggestedSampleSize(cfg, null), null,
                    profile.effectiveTolerancePct(), profile.defaultTareKg(), facts.lastTareKg(), null, false,
                    pool == null ? null : pool.lastObservedAt(), drawBiasPct(pool), null,
                    facts.baseUnitDimension(), profile.learningEnabled(), cfg.scaleResKg());
            return new Resolution(params, null, null, false, cfg);
        }

        Resolution exact(BigDecimal factor) {
            Profile profile = facts.profile();
            WeightParams params = new WeightParams(key, facts.goodsId(), BASIS_EXACT, false, null, factor,
                    StrictMath.log(factor.doubleValue()), 0.0, cfg.gamma(), null, Tier.GREEN.name(), 0.0,
                    null, null, null, profile.effectiveTolerancePct(), profile.defaultTareKg(),
                    facts.lastTareKg(), factor, false, null, null, null, facts.baseUnitDimension(),
                    profile.learningEnabled(), cfg.scaleResKg());
            return new Resolution(params, null, Tier.GREEN, false, cfg);
        }

        Resolution learnedLike(String basis, boolean supplierSpecific, BigDecimal unitWeight, double mu,
                               double prior, double df, Tier tier, EstimateRow row, Integer nInliers,
                               Double manualConflictPct, boolean stale, boolean alertsAllowed) {
            Profile profile = facts.profile();
            EstimateRow pool = facts.pool();
            double qq = StudentT.t975(df);
            double hw = qq * Math.sqrt(prior);
            double exactUpTo = ApwPredictor.exactUpToQty(prior, cfg.gamma(), qq);
            Long exactUpToQty = Double.isFinite(exactUpTo) ? (long) Math.floor(exactUpTo) : null;
            WeightParams params = new WeightParams(key, facts.goodsId(), basis, supplierSpecific,
                    pool == null ? null : pool.evidence(), unitWeight, mu, prior, cfg.gamma(), df, tier.name(),
                    StrictMath.expm1(hw), nInliers,
                    ApwEstimator.suggestedSampleSize(cfg, unitWeight == null ? null : unitWeight.doubleValue()),
                    exactUpToQty, profile.effectiveTolerancePct(), profile.defaultTareKg(), facts.lastTareKg(),
                    null, stale, row == null ? null : row.lastObservedAt(), drawBiasPct(pool), manualConflictPct,
                    facts.baseUnitDimension(), profile.learningEnabled(), cfg.scaleResKg());
            ApwPredictor.Params predictor = new ApwPredictor.Params(mu, prior, df, cfg.gamma(), cfg.scaleResKg());
            return new Resolution(params, predictor, tier, alertsAllowed, cfg);
        }

        private static Double drawBiasPct(EstimateRow pool) {
            return pool == null || pool.drawBiasLog() == null ? null : 100.0 * StrictMath.expm1(pool.drawBiasLog());
        }
    }
}
