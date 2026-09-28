package com.uten.imp.features.stock.weight;

import java.math.BigDecimal;

/**
 * 单重估算器参数 (ADR-135 §5, 取值见统计评审「Corrected section 4.3」表)。
 *
 * @param gamma          单件重量离散 (相对 sd), 货品设置 piece_cv_pct/100, 默认 0.02, 最小 0.001
 * @param tau0           批间差异先验 sd
 * @param nu0            批间差异先验伪自由度
 * @param tauSup0        供应商间差异先验 sd
 * @param m0             供应商间差异先验伪个数
 * @param scaleResKg     秤的分辨率 (kg), 配置项 uten.stock.weight.scale-resolution-kg
 * @param halfLifeDays   时间衰减半衰期 (天)
 * @param zCut           离群判定阈值 (稳健 z)
 * @param bFloor         稳健筛选批间方差下限 (sd)
 * @param cusumK         CUSUM 参考值 k
 * @param cusumH         CUSUM 报警阈值 h
 * @param clip           CUSUM 单步截断 |z|, 同时是「尖峰不进基线」的门槛
 * @param warmup         CUSUM 预热观测数
 * @param green          GREEN 的对数半宽上限
 * @param yellow         YELLOW 的对数半宽上限
 * @param tolerance      核对容差 (相对), 货品设置 tolerance_pct/100, 默认 0.03
 * @param refWindow      参与学习的 REFERENCE 观测窗口 (最近 N 条)
 * @param drawWindow     参与领料偏差的 DRAW 观测窗口 (最近 N 条)
 * @param drawOnlyBias   只有领料时 (按过往领料推算) 额外计入的偏差 sd
 * @param drawOnlyMinDraws 只有领料时最多给到 YELLOW 所需的最少领料次数
 * @param masterPriorSd  货品档案设计单重的先验 sd
 * @param staleDays      最近一次观测超过多少天算陈旧 (请求可靠度最多 YELLOW)
 */
public record EstimatorConfig(
        double gamma,
        double tau0,
        double nu0,
        double tauSup0,
        double m0,
        double scaleResKg,
        double halfLifeDays,
        double zCut,
        double bFloor,
        double cusumK,
        double cusumH,
        double clip,
        int warmup,
        double green,
        double yellow,
        double tolerance,
        int refWindow,
        int drawWindow,
        double drawOnlyBias,
        int drawOnlyMinDraws,
        double masterPriorSd,
        int staleDays) {

    public static final double DEFAULT_GAMMA = 0.02;
    public static final double MIN_GAMMA = 0.001;
    public static final double DEFAULT_TOLERANCE = 0.03;
    public static final double DEFAULT_SCALE_RES_KG = 0.00005;
    public static final BigDecimal DEFAULT_TOLERANCE_PCT = new BigDecimal("3.000");
    public static final BigDecimal DEFAULT_PIECE_CV_PCT = new BigDecimal("2.000");

    public EstimatorConfig {
        if (!(gamma > 0) || !(scaleResKg > 0) || !(tolerance > 0) || warmup < 1
                || refWindow < 1 || drawWindow < 1 || !(halfLifeDays > 0)) {
            throw new IllegalArgumentException("invalid estimator config");
        }
    }

    public static EstimatorConfig defaults() {
        return new EstimatorConfig(DEFAULT_GAMMA, 0.01, 4.0, 0.03, 2.0, DEFAULT_SCALE_RES_KG, 180.0,
                3.5, 0.005, 0.5, 5.0, 3.0, 3, 0.01, 0.05, DEFAULT_TOLERANCE, 300, 200,
                0.02, 10, 0.05, 365);
    }

    /**
     * 按货品设置换 γ 与容差; null 用默认值。γ 下限 0.001, 容差按 (0, 1] 处理。
     */
    public static EstimatorConfig forProfile(BigDecimal pieceCvPct, BigDecimal tolerancePct, double scaleResKg) {
        EstimatorConfig base = defaults();
        double gamma = pieceCvPct == null ? DEFAULT_GAMMA
                : Math.max(MIN_GAMMA, pieceCvPct.doubleValue() / 100.0);
        double tolerance = tolerancePct == null || tolerancePct.signum() <= 0 ? DEFAULT_TOLERANCE
                : Math.min(1.0, tolerancePct.doubleValue() / 100.0);
        double resolution = scaleResKg > 0 ? scaleResKg : DEFAULT_SCALE_RES_KG;
        return new EstimatorConfig(gamma, base.tau0, base.nu0, base.tauSup0, base.m0, resolution,
                base.halfLifeDays, base.zCut, base.bFloor, base.cusumK, base.cusumH, base.clip, base.warmup,
                base.green, base.yellow, tolerance, base.refWindow, base.drawWindow, base.drawOnlyBias,
                base.drawOnlyMinDraws, base.masterPriorSd, base.staleDays);
    }
}
