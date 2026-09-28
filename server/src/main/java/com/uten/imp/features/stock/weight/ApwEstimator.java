package com.uten.imp.features.stock.weight;

import com.uten.imp.common.util.PostgresUuidOrder;
import com.uten.imp.features.stock.weight.EstimateResult.Evidence;
import com.uten.imp.features.stock.weight.EstimateResult.Outlier;
import com.uten.imp.features.stock.weight.EstimateResult.Row;
import com.uten.imp.features.stock.weight.EstimateResult.Tier;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 平均单重 (APW) 估算器 (ADR-135 §5): 纯函数, 确定性, 与参考实现 apw_proto.py 逐式对应。
 *
 * <p>模型: y = ln(净重/数量) = ln APW + 批间差异 + 点数误差 + 单件离散/√q + 秤分辨率。步骤:
 * <ol>
 *   <li>窗口: 最近 300 条 REFERENCE + 最近 200 条 DRAW (其它 CHECK 不载入); 全部按 (称重时间, id) 排序;
 *       asOf = 载入观测中最晚的称重时间 (衰减 2^(-(asOf-t)/180天), 不随今天漂移);</li>
 *   <li>批次 (regime): 每个分组 (供应商 / 无供应商 POOL) 在全部观测上跑 CUSUM (单步截断 |z|≤3,
 *       k=0.5, h=5, 预热 3 条, 尖峰不进基线, 进行中的偏移先挂起), 报警时从偏移起点硬切;
 *       手动模式只用手动起点, CUSUM 只用于提示「单重可能已变化」;</li>
 *   <li>稳健筛选: 只在当前批次内、分组内做加权中位数 / MAD, |z| &gt; 3.5 判离群并给出单位填错提示;
 *       不足 3 条的分组对全体中心再放宽供应商间差异; 只有 2 条且互相矛盾时判 CONFLICT;</li>
 *   <li>拟合: 批间差异 τ_lot 用 DerSimonian-Laird 与先验 (ν0=4, τ0=1%) 混合; 分组随机效应均值;
 *       供应商间差异 τ_sup (m0=2, 3%) 与向货品级均值的收缩; 分位数用 t975(有效观测数-1+ν0);</li>
 *   <li>领料: 只作「实发比应发」偏差 (≥3 次领料且 ≥3 次有效参照), 不进单重; 只有领料时按过往领料推算
 *       (额外 2% 偏差, 最多 YELLOW 且至少 10 次领料)。</li>
 * </ol>
 * 内部全部用 double + StrictMath, 只在落库时转 BigDecimal。
 */
public final class ApwEstimator {

    /** 算法版本; 改动估算口径时 +1, 夜间刷新据此重算全部货品。 */
    public static final short ALGORITHM_VERSION = 1;

    private static final double MILLIS_PER_DAY = 86_400_000.0;
    private static final double MAD_SCALE = 1.4826;
    private static final double LN_2 = StrictMath.log(2.0);
    private static final double LN_LB = StrictMath.log(0.45359237);
    /** 标签偏差显著的最小幅度 (相对 1%)。 */
    private static final double LABEL_BIAS_MIN = 0.01;

    private static final Comparator<WeightObservation> ORDER = Comparator
            .comparing(WeightObservation::observedAt)
            .thenComparing(WeightObservation::id, PostgresUuidOrder.INSTANCE);

    private ApwEstimator() {
    }

    /**
     * 估算一个货品的单重。
     *
     * @param observations      该货品 ACTIVE 且未排除的观测 (顺序不限; 超出窗口的会被丢弃)
     * @param cfg               参数
     * @param manualRegimeStart 手动批次起点 (货品设置 manual_regime_start_at), 之前的观测不参与
     * @param autoRegime        true = AUTO (CUSUM 检测到突变即切批次); false = MANUAL (只提示)
     */
    public static EstimateResult estimate(
            List<WeightObservation> observations,
            EstimatorConfig cfg,
            Instant manualRegimeStart,
            boolean autoRegime) {
        Objects.requireNonNull(cfg, "cfg");
        List<WeightObservation> input = observations == null ? List.of() : observations;
        Long manualMillis = manualRegimeStart == null ? null : manualRegimeStart.toEpochMilli();

        List<Prepared> ref = tail(input.stream()
                .filter(o -> o.kind().isReference())
                .sorted(ORDER)
                .map(o -> prepare(o, cfg))
                .toList(), cfg.refWindow());
        List<Prepared> draws = tail(input.stream()
                .filter(o -> o.kind() == SourceKind.DRAW)
                .sorted(ORDER)
                .map(o -> prepare(o, cfg))
                .toList(), cfg.drawWindow());
        if (ref.isEmpty() && draws.isEmpty()) {
            return EstimateResult.none(null);
        }
        long asOf = Long.MIN_VALUE;
        for (Prepared o : ref) asOf = Math.max(asOf, o.t);
        for (Prepared o : draws) asOf = Math.max(asOf, o.t);
        final long asOfMillis = asOf;
        Instant asOfInstant = Instant.ofEpochMilli(asOfMillis);

        // ---- 1. 分组 + 批次 ----
        Map<UUID, Group> groups = new LinkedHashMap<>();
        for (Prepared o : ref) {
            groups.computeIfAbsent(o.group, Group::new).all.add(o);
        }
        for (Group g : groups.values()) {
            int n = g.all.size();
            int manualIdx = 0;
            if (manualMillis != null) {
                while (manualIdx < n && g.all.get(manualIdx).t < manualMillis) manualIdx++;
            }
            int detected = cusumRegimeStart(g.all, cfg, manualIdx);
            int start = autoRegime ? detected : manualIdx;
            g.current = new ArrayList<>(g.all.subList(Math.min(start, n), n));
            if (start > 0 || manualRegimeStart != null) {
                g.regimeStartedAt = start < n ? g.all.get(start).instant() : manualRegimeStart;
            }
            if (detected > manualIdx && detected < n) {
                g.regimeChangedAt = g.all.get(detected).instant();
            }
        }

        // 领料只取手动起点之后 (「从今天起重新学习」同样忘掉旧领料)。
        List<Prepared> drawsInScope = manualMillis == null ? draws
                : draws.stream().filter(o -> o.t >= manualMillis).toList();

        // ---- 2. 稳健筛选 (只在当前批次、分组内) ----
        List<Prepared> curAll = new ArrayList<>();
        for (Group g : groups.values()) curAll.addAll(g.current);
        Map<UUID, Outlier> outliers = new LinkedHashMap<>();
        if (curAll.size() >= 3) {
            double[] uAll = new double[curAll.size()];
            for (int i = 0; i < uAll.length; i++) {
                Prepared o = curAll.get(i);
                uAll[i] = decay(o, asOfMillis, cfg) / (o.v + cfg.tau0() * cfg.tau0());
            }
            double centerAll = weightedMedian(ys(curAll), uAll);
            double betweenAll = between(curAll, centerAll, uAll, cfg);
            for (Group g : groups.values()) {
                List<Prepared> lst = g.current;
                if (lst.size() >= 3) {
                    double[] u = new double[lst.size()];
                    for (int i = 0; i < u.length; i++) {
                        Prepared o = lst.get(i);
                        u[i] = decay(o, asOfMillis, cfg) / (o.v + cfg.tau0() * cfg.tau0());
                    }
                    double m = weightedMedian(ys(lst), u);
                    double b = between(lst, m, u, cfg);
                    for (Prepared o : lst) {
                        double z = (o.y - m) / Math.sqrt(b + o.v);
                        if (Math.abs(z) > cfg.zCut()) {
                            outliers.put(o.src.id(), new Outlier(o.src.id(), z, hint(o.y - m)));
                        }
                    }
                } else {
                    for (Prepared o : lst) {
                        double z = (o.y - centerAll)
                                / Math.sqrt(betweenAll + o.v + cfg.tauSup0() * cfg.tauSup0());
                        if (Math.abs(z) > cfg.zCut()) {
                            outliers.put(o.src.id(), new Outlier(o.src.id(), z, hint(o.y - centerAll)));
                        }
                    }
                }
            }
        } else if (curAll.size() == 2) {
            Prepared a = curAll.get(0);
            Prepared b = curAll.get(1);
            double limit = cfg.zCut() * Math.sqrt(a.v + b.v + 2 * cfg.tau0() * cfg.tau0());
            if (Math.abs(a.y - b.y) > limit) {
                return conflict(ref, draws, groups, asOfInstant, cfg, manualRegimeStart);
            }
        }
        List<Outlier> outlierList = List.copyOf(outliers.values());

        Map<UUID, List<Prepared>> inliers = new LinkedHashMap<>();
        for (Group g : groups.values()) {
            List<Prepared> kept = g.current.stream().filter(o -> !outliers.containsKey(o.src.id())).toList();
            if (!kept.isEmpty()) inliers.put(g.key, kept);
        }
        int nIn = 0;
        for (List<Prepared> l : inliers.values()) nIn += l.size();
        if (nIn == 0) {
            if (drawsInScope.isEmpty()) {
                return EstimateResult.none(asOfInstant);
            }
            return drawOnly(ref, draws, drawsInScope, groups, outlierList, asOfMillis, cfg, manualRegimeStart);
        }

        // ---- 3. 批间差异 τ_lot: 分组内 DerSimonian-Laird, 与先验混合 ----
        double q = 0.0;
        int df = 0;
        double c = 0.0;
        for (List<Prepared> l : inliers.values()) {
            double[] p = new double[l.size()];
            double s1 = 0.0;
            double s2 = 0.0;
            for (int i = 0; i < p.length; i++) {
                p[i] = 1.0 / l.get(i).v;
                s1 += p[i];
                s2 += p[i] * p[i];
            }
            double num = 0.0;
            for (int i = 0; i < p.length; i++) num += p[i] * l.get(i).y;
            double yb = num / s1;
            for (int i = 0; i < p.length; i++) {
                double d = l.get(i).y - yb;
                q += p[i] * (d * d);
            }
            df += l.size() - 1;
            c += s1 - s2 / s1;
        }
        double tauDl2 = df >= 1 && c > 0 ? Math.max(0.0, (q - df) / c) : 0.0;
        double tauLot2 = (cfg.nu0() * cfg.tau0() * cfg.tau0() + df * tauDl2) / (cfg.nu0() + df);

        // ---- 4. 分组拟合 (供应商组可做标签偏差复核) ----
        Map<UUID, Fit> fits = new LinkedHashMap<>();
        Map<UUID, double[]> labelBias = new LinkedHashMap<>();
        for (Map.Entry<UUID, List<Prepared>> entry : inliers.entrySet()) {
            List<Prepared> l = entry.getValue();
            Fit fit = fit(l, tauLot2, asOfMillis, cfg);
            if (entry.getKey() != null) {
                double[] bias = labelBias(l, tauLot2, asOfMillis, cfg);
                if (bias != null) {
                    labelBias.put(entry.getKey(), bias);
                    List<Prepared> nonReceipt = l.stream()
                            .filter(o -> o.src.kind() != SourceKind.RECEIPT).toList();
                    fit = fit(nonReceipt, tauLot2, asOfMillis, cfg);
                }
            }
            fits.put(entry.getKey(), fit);
        }

        // ---- 5. 货品级 (pool) ----
        List<Prepared> allIn = new ArrayList<>();
        for (List<Prepared> l : inliers.values()) allIn.addAll(l);
        Fit pool = fit(allIn, tauLot2, asOfMillis, cfg);
        double muPool = pool.x;
        double sePool2 = pool.se2;

        List<UUID> suppliers = new ArrayList<>();
        for (UUID key : fits.keySet()) if (key != null) suppliers.add(key);
        int supplierCount = suppliers.size();
        double tauSup2;
        if (supplierCount >= 2) {
            double sumX = 0.0;
            for (UUID s : suppliers) sumX += fits.get(s).x;
            double xb = sumX / supplierCount;
            double var = 0.0;
            for (UUID s : suppliers) {
                double d = fits.get(s).x - xb;
                var += d * d;
            }
            var /= (supplierCount - 1);
            double meanSe2 = 0.0;
            for (UUID s : suppliers) meanSe2 += fits.get(s).se2;
            double tauMm2 = Math.max(0.0, var - meanSe2 / supplierCount);
            tauSup2 = (cfg.m0() * cfg.tauSup0() * cfg.tauSup0() + (supplierCount - 1) * tauMm2)
                    / (cfg.m0() + supplierCount - 1);
        } else {
            tauSup2 = cfg.tauSup0() * cfg.tauSup0();
        }
        double dfT = nIn - 1 + cfg.nu0();
        double qq = StudentT.t975(dfT);
        boolean hasSample10 = allIn.stream()
                .anyMatch(o -> o.src.kind() == SourceKind.SAMPLE && o.src.qtyBase() >= 10);
        double poolBetween = supplierCount >= 2 ? tauSup2 : 0.0;
        double poolPrior = sePool2 + tauLot2 + poolBetween;
        double hwPool = qq * Math.sqrt(poolPrior);

        // ---- 6. 领料实发比应发 ----
        Group poolGroup = groups.get(null);
        Instant drawCut = poolGroup != null ? poolGroup.regimeStartedAt : manualRegimeStart;
        List<Prepared> drawsForBias = drawCut == null ? drawsInScope
                : drawsInScope.stream().filter(o -> o.t >= drawCut.toEpochMilli()).toList();
        Double drawBiasLog = null;
        Double drawBiasSe = null;
        if (drawsForBias.size() >= 3 && nIn >= 3) {
            double[] od = new double[drawsForBias.size()];
            double[] ones = new double[od.length];
            for (int i = 0; i < od.length; i++) {
                od[i] = drawsForBias.get(i).y - muPool;
                ones[i] = 1.0;
            }
            double med = weightedMedian(od, ones);
            double[] absDev = new double[od.length];
            for (int i = 0; i < od.length; i++) absDev[i] = Math.abs(od[i] - med);
            double mad = weightedMedian(absDev, ones);
            double scale = Math.max(MAD_SCALE * mad, 0.01);
            double sw = 0.0;
            double swv = 0.0;
            for (int i = 0; i < od.length; i++) {
                if (Math.abs(od[i] - med) / scale <= cfg.zCut()) {
                    double w = 1.0 / (drawsForBias.get(i).v + tauLot2);
                    sw += w;
                    swv += w * od[i];
                }
            }
            if (sw > 0) {
                drawBiasLog = swv / sw;
                drawBiasSe = Math.sqrt(1.0 / sw + sePool2);
            }
        }

        Instant regimeChangedAny = null;
        for (Group g : groups.values()) {
            if (g.regimeChangedAt != null
                    && (regimeChangedAny == null || g.regimeChangedAt.isAfter(regimeChangedAny))) {
                regimeChangedAny = g.regimeChangedAt;
            }
        }
        Row poolRow = new Row(
                null, Evidence.REFERENCE, muPool, Math.sqrt(sePool2), Math.sqrt(tauLot2),
                supplierCount >= 2 ? Math.sqrt(tauSup2) : null, null, null,
                ref.size() + draws.size(), ref.size(), nIn, pool.nEff,
                hwPool, StrictMath.expm1(hwPool), tier(hwPool, nIn, hasSample10, cfg),
                drawBiasLog, drawBiasSe, drawsForBias.size(), null, null,
                poolGroup != null ? poolGroup.regimeStartedAt : manualRegimeStart,
                regimeChangedAny, asOfInstant, outlierList,
                suggestedSampleSize(cfg, StrictMath.exp(muPool)), poolPrior, dfT);

        List<Row> supplierRows = new ArrayList<>();
        for (UUID s : suppliers) {
            Fit f = fits.get(s);
            Group g = groups.get(s);
            double wp = tauSup2 / (tauSup2 + f.se2);
            double mu = wp * f.x + (1 - wp) * muPool;
            double sep2 = wp * f.se2 + (1 - wp) * (1 - wp) * sePool2;
            double prior = sep2 + tauLot2;
            double hw = qq * Math.sqrt(prior);
            double[] bias = labelBias.get(s);
            List<Outlier> groupOutliers = new ArrayList<>();
            for (Prepared o : g.all) {
                Outlier out = outliers.get(o.src.id());
                if (out != null) groupOutliers.add(out);
            }
            supplierRows.add(new Row(
                    s, Evidence.REFERENCE, mu, Math.sqrt(sep2), Math.sqrt(tauLot2), Math.sqrt(tauSup2), wp, f.x,
                    g.all.size(), g.all.size(), inliers.get(s).size(), f.nEff,
                    hw, StrictMath.expm1(hw), tier(hw, f.n, hasSample10, cfg),
                    null, null, null, bias == null ? null : bias[0], bias == null ? null : bias[1],
                    g.regimeStartedAt, g.regimeChangedAt, g.all.get(g.all.size() - 1).instant(), groupOutliers,
                    suggestedSampleSize(cfg, StrictMath.exp(mu)), prior, dfT));
        }
        return new EstimateResult(Evidence.REFERENCE, asOfInstant, poolRow, supplierRows, outlierList);
    }

    /** 建议称样件数: clamp(max(⌈(1.96γ/t)²⌉, ⌈100r/APW⌉), 10, 200), t = min(1%, 容差/3)。 */
    public static int suggestedSampleSize(EstimatorConfig cfg, Double apwKg) {
        double target = Math.min(0.01, cfg.tolerance() / 3.0);
        double byCv = Math.ceil(StrictMath.pow(1.96 * cfg.gamma() / target, 2));
        double byScale = apwKg == null || !(apwKg > 0) ? 0.0 : Math.ceil(100.0 * cfg.scaleResKg() / apwKg);
        double n = Math.max(byCv, byScale);
        if (!Double.isFinite(n)) {
            return 200;
        }
        return (int) Math.max(10, Math.min(200, n));
    }

    /** 存储口径可靠度: 有效观测 &lt;3 且没有 ≥10 件的称样时一律 RED。 */
    static Tier tier(double logHalfWidth, int n, boolean hasSample10, EstimatorConfig cfg) {
        if (n < 3 && !hasSample10) {
            return Tier.RED;
        }
        return tierOf(logHalfWidth, cfg);
    }

    /** 按对数半宽分档。 */
    public static Tier tierOf(double logHalfWidth, EstimatorConfig cfg) {
        if (!Double.isFinite(logHalfWidth)) {
            return Tier.RED;
        }
        if (logHalfWidth <= cfg.green()) return Tier.GREEN;
        if (logHalfWidth <= cfg.yellow()) return Tier.YELLOW;
        return Tier.RED;
    }

    /** 离群提示: 差 10/100/1000 倍 (单位填错), 2 倍 (斤/千克), 0.4536 倍 (磅/千克), 其余为偏差。 */
    static String hint(double deviation) {
        for (int k = 3; k >= 1; k--) {
            double lnPow = k * StrictMath.log(10.0);
            if (Math.abs(deviation - lnPow) < 0.05 || Math.abs(deviation + lnPow) < 0.05) {
                return "UNIT_" + (int) StrictMath.pow(10, k);
            }
        }
        if (Math.abs(deviation - LN_2) < 0.02 || Math.abs(deviation + LN_2) < 0.02) {
            return "JIN_KG";
        }
        if (Math.abs(deviation - LN_LB) < 0.02 || Math.abs(deviation + LN_LB) < 0.02) {
            return "LB_KG";
        }
        return "DEVIATION";
    }

    // ------------------------------------------------------------------ internals

    private static EstimateResult conflict(List<Prepared> ref, List<Prepared> draws, Map<UUID, Group> groups,
                                           Instant asOf, EstimatorConfig cfg, Instant manualRegimeStart) {
        Group poolGroup = groups.get(null);
        Row row = new Row(null, Evidence.CONFLICT, null, null, null, null, null, null,
                ref.size() + draws.size(), ref.size(), 0, null, null, null, Tier.RED,
                null, null, null, null, null,
                poolGroup != null ? poolGroup.regimeStartedAt : manualRegimeStart, null, asOf, List.of(),
                suggestedSampleSize(cfg, null), null, null);
        return new EstimateResult(Evidence.CONFLICT, asOf, row, List.of(), List.of());
    }

    /** 只有领料: 按过往领料的随机效应均值推算 (含超发), 额外计入 2% 偏差, 最多 YELLOW。 */
    private static EstimateResult drawOnly(List<Prepared> ref, List<Prepared> draws, List<Prepared> drawsInScope,
                                           Map<UUID, Group> groups, List<Outlier> outliers, long asOfMillis,
                                           EstimatorConfig cfg, Instant manualRegimeStart) {
        double tau02 = cfg.tau0() * cfg.tau0();
        double sw = 0.0;
        double swy = 0.0;
        double sww = 0.0;
        for (Prepared o : drawsInScope) {
            double w = decay(o, asOfMillis, cfg) / (o.v + tau02);
            sw += w;
            swy += w * o.y;
            sww += w * w;
        }
        double mu = swy / sw;
        double se2 = 1.0 / sw;
        double prior = se2 + tau02 + cfg.drawOnlyBias() * cfg.drawOnlyBias();
        int nd = drawsInScope.size();
        double df = nd - 1 + cfg.nu0();
        double hw = StudentT.t975(df) * Math.sqrt(prior);
        Tier tier = nd >= cfg.drawOnlyMinDraws() && hw <= cfg.yellow() ? Tier.YELLOW : Tier.RED;
        Instant asOf = Instant.ofEpochMilli(asOfMillis);
        Group poolGroup = groups.get(null);
        Row row = new Row(null, Evidence.DRAW_ONLY, mu, Math.sqrt(se2), cfg.tau0(), cfg.drawOnlyBias(), null, null,
                ref.size() + draws.size(), ref.size(), 0, sw * sw / sww, hw, StrictMath.expm1(hw), tier,
                null, null, nd, null, null,
                poolGroup != null ? poolGroup.regimeStartedAt : manualRegimeStart, null, asOf, outliers,
                suggestedSampleSize(cfg, StrictMath.exp(mu)), prior, df);
        return new EstimateResult(Evidence.DRAW_ONLY, asOf, row, List.of(), outliers);
    }

    /**
     * 标签偏差: 供应商组里 ≥2 次称样且 ≥3 次到货时, c = x_到货 - x_称样; 显著 (|c| &gt; 1.96 se 且 &gt; 1%)
     * 时返回 {c, se}, 该供应商行改用非到货观测拟合 (到货数量按标签, 系统性少数会被吸进单重)。
     */
    private static double[] labelBias(List<Prepared> group, double tauLot2, long asOfMillis, EstimatorConfig cfg) {
        List<Prepared> samples = group.stream().filter(o -> o.src.kind() == SourceKind.SAMPLE).toList();
        List<Prepared> receipts = group.stream().filter(o -> o.src.kind() == SourceKind.RECEIPT).toList();
        if (samples.size() < 2 || receipts.size() < 3) {
            return null;
        }
        Fit r = fit(receipts, tauLot2, asOfMillis, cfg);
        Fit s = fit(samples, tauLot2, asOfMillis, cfg);
        double bias = r.x - s.x;
        double se = Math.sqrt(r.se2 + s.se2);
        if (Math.abs(bias) > StudentT.Z975 * se && Math.abs(StrictMath.expm1(bias)) > LABEL_BIAS_MIN) {
            return new double[] {bias, se};
        }
        return null;
    }

    private static Fit fit(List<Prepared> l, double tauLot2, long asOfMillis, EstimatorConfig cfg) {
        double sw = 0.0;
        double swy = 0.0;
        double sww = 0.0;
        for (Prepared o : l) {
            double w = decay(o, asOfMillis, cfg) / (o.v + tauLot2);
            sw += w;
            swy += w * o.y;
            sww += w * w;
        }
        return new Fit(swy / sw, 1.0 / sw, l.size(), sw * sw / sww);
    }

    /**
     * 单分组 CUSUM (一步预测残差), 返回当前批次起点下标。
     * 与 apw_proto.cusum_regime 同式: τ_c² 用分组全部观测的 MAD 估计 (≥5 条), 预热 3 条,
     * 尖峰 (|z|≥3) 不进基线, 进行中的偏移挂起, 偏移归零后才并入基线; 报警后基线从偏移起点重建。
     */
    static int cusumRegimeStart(List<Prepared> obs, EstimatorConfig cfg, int from) {
        int n = obs.size();
        if (n == 0) {
            return 0;
        }
        double tau02 = cfg.tau0() * cfg.tau0();
        double tauC2;
        if (n >= 5) {
            double[] ys = new double[n];
            double[] vs = new double[n];
            for (int i = 0; i < n; i++) {
                ys[i] = obs.get(i).y;
                vs[i] = obs.get(i).v;
            }
            Arrays.sort(ys);
            double med = n % 2 == 1 ? ys[n / 2] : 0.5 * (ys[n / 2 - 1] + ys[n / 2]);
            double[] mad = new double[n];
            for (int i = 0; i < n; i++) mad[i] = Math.abs(obs.get(i).y - med);
            Arrays.sort(mad);
            double madv = n % 2 == 1 ? mad[n / 2] : 0.5 * (mad[n / 2 - 1] + mad[n / 2]);
            Arrays.sort(vs);
            double medv = vs[n / 2];
            double scaled = MAD_SCALE * madv;
            tauC2 = Math.max(tau02, scaled * scaled - medv);
        } else {
            tauC2 = tau02;
        }
        int s = from;
        List<Integer> base = new ArrayList<>();
        List<Integer> pending = new ArrayList<>();
        double cp = 0.0;
        double cn = 0.0;
        Integer runP = null;
        Integer runN = null;
        int i = s;
        while (i < n) {
            Prepared o = obs.get(i);
            if (base.size() < cfg.warmup()) {
                base.add(i);
                i++;
                continue;
            }
            double s0 = 0.0;
            double s1 = 0.0;
            for (int j : base) {
                Prepared b = obs.get(j);
                s0 += 1.0 / (b.v + tauC2);
                s1 += b.y / (b.v + tauC2);
            }
            double mu = s1 / s0;
            double z = (o.y - mu) / Math.sqrt(1.0 / s0 + o.v + tauC2);
            double zc = Math.max(-cfg.clip(), Math.min(cfg.clip(), z));
            double ncp = Math.max(0.0, cp + zc - cfg.cusumK());
            double ncn = Math.max(0.0, cn - zc - cfg.cusumK());
            if (cp == 0 && ncp > 0) runP = i;
            if (cn == 0 && ncn > 0) runN = i;
            cp = ncp;
            cn = ncn;
            Integer alarm = null;
            if (cp > cfg.cusumH()) {
                alarm = runP;
            } else if (cn > cfg.cusumH()) {
                alarm = runN;
            }
            if (alarm != null) {
                s = alarm;
                base = new ArrayList<>();
                for (int k = s; k <= i; k++) base.add(k);
                pending.clear();
                cp = 0.0;
                cn = 0.0;
                runP = null;
                runN = null;
                i++;
                continue;
            }
            boolean spike = Math.abs(z) >= cfg.clip();
            if (cp == 0 && cn == 0) {
                base.addAll(pending);
                pending.clear();
                if (!spike) base.add(i);
            } else if (!spike) {
                pending.add(i);
            }
            i++;
        }
        return s;
    }

    /** 稳健批间方差: max((1.4826 × 加权 MAD)² - 加权中位 V, Bfloor²)。 */
    private static double between(List<Prepared> lst, double center, double[] wts, EstimatorConfig cfg) {
        double[] dev = new double[lst.size()];
        double[] vs = new double[lst.size()];
        for (int i = 0; i < dev.length; i++) {
            dev[i] = Math.abs(lst.get(i).y - center);
            vs[i] = lst.get(i).v;
        }
        double madw = weightedMedian(dev, wts);
        double medv = weightedMedian(vs, wts);
        double scaled = MAD_SCALE * madw;
        return Math.max(scaled * scaled - medv, cfg.bFloor() * cfg.bFloor());
    }

    /** 加权中位数: 按 (值, 权重, 原下标) 排序, 取累计权重首次 ≥ 总权重一半的值。 */
    static double weightedMedian(double[] vals, double[] wts) {
        int n = vals.length;
        Integer[] idx = new Integer[n];
        for (int i = 0; i < n; i++) idx[i] = i;
        Arrays.sort(idx, (a, b) -> {
            int cmp = Double.compare(vals[a], vals[b]);
            if (cmp != 0) return cmp;
            cmp = Double.compare(wts[a], wts[b]);
            return cmp != 0 ? cmp : Integer.compare(a, b);
        });
        double tot = 0.0;
        for (double w : wts) tot += w;
        double c = 0.0;
        for (int k : idx) {
            c += wts[k];
            if (c >= tot / 2.0) {
                return vals[k];
            }
        }
        return vals[idx[n - 1]];
    }

    private static double[] ys(List<Prepared> lst) {
        double[] y = new double[lst.size()];
        for (int i = 0; i < y.length; i++) y[i] = lst.get(i).y;
        return y;
    }

    private static double decay(Prepared o, long asOfMillis, EstimatorConfig cfg) {
        double ageDays = (asOfMillis - o.t) / MILLIS_PER_DAY;
        return StrictMath.pow(2.0, -ageDays / cfg.halfLifeDays());
    }

    private static Prepared prepare(WeightObservation o, EstimatorConfig cfg) {
        double y = StrictMath.log(o.weightKg()) - StrictMath.log(o.qtyBase());
        double eps = o.eps();
        double res = cfg.scaleResKg() / o.weightKg();
        double v = cfg.gamma() * cfg.gamma() / Math.max(o.qtyBase(), 1.0) + eps * eps + res * res / 3.0;
        UUID group = o.kind().isReference() ? o.supplierId() : null;
        return new Prepared(o, o.observedAt().toEpochMilli(), y, v, group);
    }

    private static <T> List<T> tail(List<T> sorted, int window) {
        return sorted.size() <= window ? sorted : sorted.subList(sorted.size() - window, sorted.size());
    }

    /** 预处理后的观测: t = 称重时间 (毫秒), y = ln(w/q), v = 单条方差。 */
    record Prepared(WeightObservation src, long t, double y, double v, UUID group) {
        Instant instant() {
            return src.observedAt();
        }
    }

    private record Fit(double x, double se2, int n, double nEff) {
    }

    private static final class Group {
        final UUID key;
        final List<Prepared> all = new ArrayList<>();
        List<Prepared> current = List.of();
        Instant regimeStartedAt;
        Instant regimeChangedAt;

        Group(UUID key) {
            this.key = key;
        }
    }
}
