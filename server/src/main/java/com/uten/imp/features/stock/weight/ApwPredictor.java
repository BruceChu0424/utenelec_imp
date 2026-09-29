package com.uten.imp.features.stock.weight;

import com.uten.imp.features.stock.weight.EstimateResult.Tier;

/**
 * 单重的请求期计算 (ADR-135 §5/§7.2): 称重计数、按数量的应称重量、同批抽样融合、偏差告警。
 *
 * <p>纯函数; Flutter 端 lib/shared/measurement 的 WeightPredictor 与本类逐式对应, 两边共用
 * test/resources/weight/predictor_golden.json 金样 (由参考实现 apw_proto.py 生成)。
 *
 * <p>输入是 /api/stock/weight/params 返回的参数: logMean = ln(单重 kg/基本单位), lotPrior = 请求先验方差 P,
 * df = t 分位数自由度, gamma = 单件离散, scaleResKg = 秤分辨率。
 */
public final class ApwPredictor {

    private ApwPredictor() {
    }

    /** 请求参数。 */
    public record Params(double logMean, double lotPrior, double df, double gamma, double scaleResKg) {
        public Params {
            if (!Double.isFinite(logMean) || !(lotPrior >= 0) || !(df > 0) || !(gamma > 0) || !(scaleResKg > 0)) {
                throw new IllegalArgumentException("invalid predictor params");
            }
        }
    }

    /** 同批抽样: 数 qty 个, 净重 weightKg。 */
    public record Sample(double qty, double weightKg) {
        public Sample {
            if (!(qty > 0) || !(weightKg > 0)) {
                throw new IllegalArgumentException("sample qty and weight must be positive");
            }
        }
    }

    /**
     * 称重计数结果。
     *
     * @param estimatedQty  估算数量 N = W / e^μ*
     * @param qtyLow        95% 区间下限 N·e^-h
     * @param qtyHigh       95% 区间上限 N·e^h
     * @param logHalfWidth  h = t975 × √(P* + γ²/max(N,1) + (r/W)²/3)
     * @param relHalfWidth  e^h - 1
     * @param exactUpToQty  区间在 ±0.5 个以内的最大数量 (不取整)
     * @param fusedLogMean  融合抽样后的 μ*
     * @param fusedLotPrior 融合抽样后的 P*
     */
    public record CountPrediction(double estimatedQty, double qtyLow, double qtyHigh, double logHalfWidth,
                                  double relHalfWidth, double exactUpToQty, double fusedLogMean,
                                  double fusedLotPrior) {
    }

    /** 偏差级别, 与 goods_weight_observations.alert_level 取值一致。 */
    public enum Alert { NONE, WARN, ALERT }

    /**
     * 按数量核对称重的结果。
     *
     * @param expectedWeightKg 应称 E = Q·e^μ
     * @param deviationPct     100 × (W/E - 1)
     * @param z                1.959963985 × ln(W/E) / (t975 × σ)
     * @param alert            |d| &gt; ln(1+2tol) 且 |z| &gt; 3 → ALERT; |d| &gt; ln(1+tol) 且 |z| &gt; 1.96 → WARN
     */
    public record WeightCheck(double expectedWeightKg, double deviationPct, double z, Alert alert) {
    }

    /** 融合同批抽样后的 (μ*, P*); sample 为 null 时原样返回。 */
    public static double[] fuse(Params p, Sample sample) {
        double mu = p.logMean();
        double prior = p.lotPrior();
        if (sample == null) {
            return new double[] {mu, prior};
        }
        double ys = StrictMath.log(sample.weightKg() / sample.qty());
        double res = p.scaleResKg() / sample.weightKg();
        double vs = p.gamma() * p.gamma() / sample.qty() + res * res / 3.0;
        if (!(prior > 0)) {
            return new double[] {mu, prior};
        }
        double fusedMu = (mu / prior + ys / vs) / (1.0 / prior + 1.0 / vs);
        double fusedPrior = 1.0 / (1.0 / prior + 1.0 / vs);
        return new double[] {fusedMu, fusedPrior};
    }

    /** 称重计数: 净重 weightKg 大约是多少个 (基本单位)。 */
    public static CountPrediction countFromWeight(Params p, double weightKg, Sample sample) {
        if (!(weightKg > 0)) {
            throw new IllegalArgumentException("weight must be positive");
        }
        double[] fused = fuse(p, sample);
        double mu = fused[0];
        double prior = fused[1];
        double qq = StudentT.t975(p.df());
        double n = weightKg / StrictMath.exp(mu);
        double res = p.scaleResKg() / weightKg;
        double var = prior + p.gamma() * p.gamma() / Math.max(n, 1.0) + res * res / 3.0;
        double hw = qq * Math.sqrt(var);
        return new CountPrediction(n, n * StrictMath.exp(-hw), n * StrictMath.exp(hw), hw,
                StrictMath.expm1(hw), exactUpToQty(prior, p.gamma(), qq), mu, prior);
    }

    /**
     * 核对一次称重: qty 个应称多少, 实称 weightKg 偏多少, 是否告警。告警是否对用户显示由调用方按依据与
     * 请求可靠度决定 (只对学到的/人工设定的单重, 且可靠度不是 RED)。
     *
     * @param eps          该来源数量相对误差 ({@link SourceKind#eps()} 或观测覆盖值)
     * @param tolerancePct 核对容差 (百分数, 如 3.0)
     */
    public static WeightCheck checkWeight(Params p, double eps, double qty, double weightKg, double tolerancePct) {
        if (!(qty > 0) || !(weightKg > 0)) {
            throw new IllegalArgumentException("qty and weight must be positive");
        }
        double qq = StudentT.t975(p.df());
        double expected = qty * StrictMath.exp(p.logMean());
        double res = p.scaleResKg() / weightKg;
        double var = p.lotPrior() + p.gamma() * p.gamma() / Math.max(qty, 1.0) + eps * eps + res * res / 3.0;
        double sdEff = Math.sqrt(var) * qq / StudentT.Z975;
        double d = StrictMath.log(weightKg / expected);
        double z = d / sdEff;
        double tol = tolerancePct / 100.0;
        Alert alert = Alert.NONE;
        if (Math.abs(d) > StrictMath.log(1 + 2 * tol) && Math.abs(z) > 3.0) {
            alert = Alert.ALERT;
        } else if (Math.abs(d) > StrictMath.log(1 + tol) && Math.abs(z) > StudentT.Z975) {
            alert = Alert.WARN;
        }
        return new WeightCheck(expected, 100.0 * (weightKg / expected - 1.0), z, alert);
    }

    /**
     * 称重计数能数准 (±0.5 个以内) 的最大数量: N²P + Nγ² &lt; (0.5/t975)² 的正根。
     * P ≤ 0 (精确按重量计) 时返回正无穷。
     */
    public static double exactUpToQty(double lotPrior, double gamma, double t975) {
        double a = lotPrior;
        double b = gamma * gamma;
        double cc = (0.5 / t975) * (0.5 / t975);
        if (!(a > 0)) {
            return b > 0 ? cc / b : Double.POSITIVE_INFINITY;
        }
        return (-b + Math.sqrt(b * b + 4 * a * cc)) / (2 * a);
    }

    /** 请求口径可靠度: t975 × √(P + γ²/max(N,1)) 分档 (N 取实际数量, 无数量时按 N→∞)。 */
    public static Tier requestTier(Params p, Double qty, EstimatorConfig cfg) {
        double qq = StudentT.t975(p.df());
        double piece = qty == null || !(qty > 0) ? 0.0 : p.gamma() * p.gamma() / Math.max(qty, 1.0);
        return ApwEstimator.tierOf(qq * Math.sqrt(p.lotPrior() + piece), cfg);
    }
}
