package com.uten.imp.features.stock.weight;

import com.uten.imp.features.stock.weight.ApwPredictor.Alert;
import com.uten.imp.features.stock.weight.EstimateResult.Evidence;
import com.uten.imp.features.stock.weight.EstimateResult.Outlier;
import com.uten.imp.features.stock.weight.EstimateResult.Row;
import com.uten.imp.features.stock.weight.EstimateResult.Tier;
import com.uten.imp.features.stock.weight.GoodsWeightFacts.EstimateRow;
import com.uten.imp.features.stock.weight.GoodsWeightFacts.Profile;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;

/**
 * 单重估算器验收: 统计评审 §8 的 20 个确定性场景 (ADR-135 §5)。
 *
 * <p>期望值全部来自参考实现 apw_proto.py 的全精度输出 (Python 3.13, 三项 t975), 数学量按 1e-8 相对误差比,
 * 分类 (离群、批次、可靠度、告警) 精确比。产品调整 (只有领料最多 YELLOW、CONFLICT、离群提示、
 * 建议称样件数、陈旧封顶) 按 spec_v2 §5 另行断言。
 */
class ApwEstimatorTest {

    private static final EstimatorConfig CFG = EstimatorConfig.defaults();
    private static final double REL = 1e-8;
    private static final UUID SUP_A = new UUID(0xA0L, 1L);
    private static final UUID SUP_B = new UUID(0xB0L, 2L);

    // ------------------------------------------------------------------ 1. 两个供应商

    @Test
    void scenario01_twoSuppliersAreLearnedSeparatelyWithoutOutliers() {
        List<WeightObservation> obs = concat(
                mk("A", SourceKind.RECEIPT, 10, 2.00, 5000, 0.005, 0, 7, SUP_A, 0, 1.0),
                mk("B", SourceKind.RECEIPT, 4, 2.10, 5000, 0.005, 3, 14, SUP_B, 3, 1.0));
        EstimateResult r = estimate(obs);

        assertThat(r.evidence()).isEqualTo(Evidence.REFERENCE);
        assertThat(r.outliers()).isEmpty();
        Row pool = r.pool();
        assertRel(grams(pool), 2.0286364222310653);
        assertRel(pool.logSe(), 0.0031846719501566604);
        assertRel(pool.logHalfWidth(), 0.06834362094215993);
        assertThat(pool.tier()).isEqualTo(Tier.RED);
        assertThat(pool.nInliers()).isEqualTo(14);
        assertRel(pool.tauLot(), 0.005);
        assertRel(pool.tauBetween(), 0.03184644537538188);

        Row a = supplier(r, SUP_A);
        Row b = supplier(r, SUP_B);
        assertRel(grams(a), 2.000659120390365);
        assertRel(StrictMath.exp(a.rawLogMean()) * 1000, 2.000273473142269);
        assertRel(a.shrinkWeight(), 0.9863082803469586);
        assertRel(a.logSe(), 0.003726659324291117);
        assertRel(a.logHalfWidth(), 0.01315673071383725);
        assertThat(a.tier()).isEqualTo(Tier.YELLOW);
        assertRel(grams(b), 2.100941179385745);
        assertRel(b.shrinkWeight(), 0.9654713229023235);
        assertRel(b.logHalfWidth(), 0.016346614246168123);
        assertThat(b.tier()).isEqualTo(Tier.YELLOW);
        assertThat(a.shrinkWeight()).isGreaterThanOrEqualTo(0.96);
        assertThat(b.shrinkWeight()).isGreaterThanOrEqualTo(0.96);

        // 称重计数 10 kg: 供应商 A ≈ 4998 ±1.3%, 不分供应商 ≈ 4929 ±6.8%
        ApwPredictor.CountPrediction countA = ApwPredictor.countFromWeight(predictor(a), 10.0, null);
        assertRel(countA.estimatedQty(), 4998.352741894791);
        assertRel(countA.qtyLow(), 4932.95472368123);
        assertRel(countA.qtyHigh(), 5064.617765995458);
        assertRel(countA.exactUpToQty(), 33.20680524309039);
        ApwPredictor.CountPrediction countPool = ApwPredictor.countFromWeight(predictor(pool), 10.0, null);
        assertRel(countPool.estimatedQty(), 4929.419530485479);
        assertRel(countPool.logHalfWidth(), 0.06834626367285801);
        assertRel(countPool.exactUpToQty(), 7.127857725799902);
    }

    // ------------------------------------------------------------------ 2. 5% 离群 (单位填错)

    @Test
    void scenario02_unitSlipsAreFlaggedWithHintsAndDoNotMoveTheEstimate() {
        List<WeightObservation> obs = mk("X", SourceKind.RECEIPT, 40, 2.00, 5000, 0.005, 0, 3, null, 0, 1.0);
        obs.set(10, scaled(obs.get(10), 1000));
        obs.set(25, scaled(obs.get(25), 1000));
        obs.set(33, scaled(obs.get(33), 1.15));
        EstimateResult r = estimate(obs);

        Map<UUID, Outlier> outliers = r.outliers().stream()
                .collect(Collectors.toMap(Outlier::observationId, o -> o));
        assertThat(outliers.keySet()).containsExactlyInAnyOrder(id("X", 10), id("X", 25), id("X", 33));
        assertRel(outliers.get(id("X", 10)).z(), 617.4719701056526);
        assertRel(outliers.get(id("X", 25)).z(), 618.0073855447845);
        assertRel(outliers.get(id("X", 33)).z(), 11.959128141637256);
        assertThat(outliers.get(id("X", 10)).hint()).isEqualTo("UNIT_1000");
        assertThat(outliers.get(id("X", 25)).hint()).isEqualTo("UNIT_1000");
        assertThat(outliers.get(id("X", 33)).hint()).isEqualTo("DEVIATION");
        assertThat(r.pool().regimeStartedAt()).isNull();
        assertThat(r.pool().regimeChangedAt()).isNull();
        assertThat(r.pool().nInliers()).isEqualTo(37);
        assertRel(grams(r.pool()), 2.000229941486075);
        assertRel(r.pool().logHalfWidth(), 0.007481854301267239);
        assertThat(r.pool().tier()).isEqualTo(Tier.GREEN);

        List<WeightObservation> clean = new ArrayList<>(mk("X", SourceKind.RECEIPT, 40, 2.00, 5000, 0.005, 0, 3,
                null, 0, 1.0));
        clean.remove(33);
        clean.remove(25);
        clean.remove(10);
        assertThat(grams(estimate(clean).pool())).isCloseTo(grams(r.pool()), within(2.0 * 1e-9));
    }

    // ------------------------------------------------------------------ 3. 单重突变

    @Test
    void scenario03_regimeShiftCutsOldObservations() {
        List<WeightObservation> obs = concat(
                mk("R", SourceKind.COUNT, 20, 2.00, 3000, 0.004, 0, 5, null, 0, 1.0),
                mk("S", SourceKind.COUNT, 6, 2.10, 3000, 0.004, 100, 5, null, 2, 1.0));
        EstimateResult r = estimate(obs);

        assertThat(r.pool().regimeStartedAt()).isEqualTo(day(100));
        assertThat(r.pool().regimeChangedAt()).isEqualTo(day(100));
        assertThat(r.outliers()).isEmpty();
        assertThat(r.pool().nInliers()).isEqualTo(6);
        assertThat(r.pool().nRef()).isEqualTo(26);
        assertRel(grams(r.pool()), 2.1014020707473113);
        assertRel(r.pool().logHalfWidth(), 0.017017824207056997);
        assertThat(r.pool().tier()).isEqualTo(Tier.YELLOW);
    }

    @Test
    void scenario03b_manualModeOnlyAlertsAndManualStartReproducesTheCut() {
        List<WeightObservation> obs = concat(
                mk("R", SourceKind.COUNT, 20, 2.00, 3000, 0.004, 0, 5, null, 0, 1.0),
                mk("S", SourceKind.COUNT, 6, 2.10, 3000, 0.004, 100, 5, null, 2, 1.0));

        EstimateResult alertOnly = ApwEstimator.estimate(obs, CFG, null, false);
        assertThat(alertOnly.pool().regimeStartedAt()).isNull();
        assertThat(alertOnly.pool().regimeChangedAt()).isEqualTo(day(100));
        assertThat(grams(alertOnly.pool())).isLessThan(2.05);

        EstimateResult manual = ApwEstimator.estimate(obs, CFG, day(100), false);
        assertThat(manual.pool().regimeStartedAt()).isEqualTo(day(100));
        assertThat(manual.pool().regimeChangedAt()).isNull();
        assertRel(grams(manual.pool()), 2.1014020707473113);
    }

    // ------------------------------------------------------------------ 4. 挂起中的偏移

    @Test
    void scenario04_pendingShiftNeedsThreeConsecutiveObservations() {
        EstimateResult two = estimate(concat(
                mk("R", SourceKind.COUNT, 20, 2.00, 3000, 0.004, 0, 5, null, 0, 1.0),
                mk("S", SourceKind.COUNT, 2, 2.10, 3000, 0.004, 100, 5, null, 2, 1.0)));
        assertThat(two.pool().regimeStartedAt()).isNull();
        assertThat(ids(two.outliers())).containsExactlyInAnyOrder(id("S", 0), id("S", 1));
        assertRel(zOf(two, id("S", 0)), 6.55169279837397);
        assertRel(zOf(two, id("S", 1)), 7.341652515712374);
        assertRel(grams(two.pool()), 1.9998322040042475);
        assertThat(two.pool().tier()).isEqualTo(Tier.GREEN);

        EstimateResult three = estimate(concat(
                mk("R", SourceKind.COUNT, 20, 2.00, 3000, 0.004, 0, 5, null, 0, 1.0),
                mk("S", SourceKind.COUNT, 3, 2.10, 3000, 0.004, 100, 5, null, 2, 1.0)));
        assertThat(three.pool().regimeStartedAt()).isEqualTo(day(100));
        assertThat(three.pool().nInliers()).isEqualTo(3);
        assertRel(grams(three.pool()), 2.1022664941500677);
        assertRel(three.pool().logHalfWidth(), 0.024192295194987876);
        assertThat(three.pool().tier()).isEqualTo(Tier.YELLOW);
    }

    // ------------------------------------------------------------------ 5. 小幅偏移

    @Test
    void scenario05_smallShifts() {
        EstimateResult plus2 = estimate(concat(
                mk("R", SourceKind.COUNT, 20, 2.00, 3000, 0.004, 0, 5, null, 0, 1.0),
                mk("S", SourceKind.COUNT, 8, 2.04, 3000, 0.004, 100, 5, null, 2, 1.0)));
        assertThat(plus2.pool().regimeStartedAt()).isEqualTo(day(100));
        assertThat(plus2.pool().nInliers()).isEqualTo(8);
        assertRel(grams(plus2.pool()), 2.0407978827283992);

        EstimateResult plus1 = estimate(concat(
                mk("R", SourceKind.COUNT, 20, 2.00, 3000, 0.004, 0, 5, null, 0, 1.0),
                mk("S", SourceKind.COUNT, 8, 2.02, 3000, 0.004, 100, 5, null, 2, 1.0)));
        assertThat(plus1.pool().regimeStartedAt()).isNull();
        assertThat(plus1.pool().nInliers()).isEqualTo(28);
        assertRel(grams(plus1.pool()), 2.006986892692601);
        assertThat(plus1.pool().tier()).isEqualTo(Tier.GREEN);
    }

    // ------------------------------------------------------------------ 6. 尖峰

    @Test
    void scenario06_spikesNeverStartARegime() {
        List<WeightObservation> single = mk("P", SourceKind.COUNT, 25, 2.00, 3000, 0.004, 0, 5, null, 0, 1.0);
        single.set(12, scaled(single.get(12), 1.08));
        EstimateResult one = estimate(single);
        assertThat(ids(one.outliers())).containsExactly(id("P", 12));
        assertRel(zOf(one, id("P", 12)), 11.095242159513122);
        assertThat(one.pool().regimeStartedAt()).isNull();
        assertRel(grams(one.pool()), 1.9994832818016075);

        List<WeightObservation> mixed = mk("R", SourceKind.COUNT, 30, 2.00, 3000, 0.004, 0, 5, null, 0, 1.0);
        mixed.set(10, scaled(mixed.get(10), 1.06));
        mixed.set(11, scaled(mixed.get(11), 1.06));
        mixed.set(12, scaled(mixed.get(12), 0.94));
        EstimateResult three = estimate(mixed);
        assertThat(ids(three.outliers())).containsExactlyInAnyOrder(id("R", 10), id("R", 11), id("R", 12));
        assertThat(three.pool().regimeStartedAt()).isNull();
        assertThat(three.pool().regimeChangedAt()).isNull();
        assertRel(grams(three.pool()), 2.000397097909601);
    }

    // ------------------------------------------------------------------ 7. 领料 +2%

    @Test
    void scenario07_drawsOnlyMeasureOverIssueAndNeverTouchTheEstimate() {
        List<WeightObservation> ref = mk("F", SourceKind.RECEIPT, 10, 2.00, 5000, 0.005, 0, 10, null, 0, 1.0);
        List<WeightObservation> draws = mk("D", SourceKind.DRAW, 15, 2.00, 500, 0.004, 1, 6, null, 0, 1.02);
        EstimateResult with = estimate(concat(ref, draws));
        EstimateResult without = estimate(ref);

        assertRel(100 * StrictMath.expm1(with.pool().drawBiasLog()), 1.983990011678305);
        assertRel(100 * with.pool().drawBiasSe(), 0.49231337132045583);
        assertThat(with.pool().nDraw()).isEqualTo(15);
        // 货品级单重与没有领料时逐位相同
        assertThat(with.pool().logMean()).isEqualTo(without.pool().logMean());
        assertThat(with.pool().logSe()).isEqualTo(without.pool().logSe());
        assertThat(with.pool().nEff()).isEqualTo(without.pool().nEff());
        assertThat(with.pool().logHalfWidth()).isEqualTo(without.pool().logHalfWidth());
        assertThat(with.pool().tier()).isEqualTo(without.pool().tier()).isEqualTo(Tier.YELLOW);
        assertRel(grams(with.pool()), 2.000306801638595);
        assertRel(with.pool().logSe(), 0.003932672133218754);
    }

    // ------------------------------------------------------------------ 8. 只有领料

    @Test
    void scenario08_drawOnlyIsLabelledCappedAndNeverAlerts() {
        EstimateResult r = estimate(mk("D", SourceKind.DRAW, 10, 2.00, 500, 0.004, 0, 3, null, 0, 1.02));
        assertThat(r.evidence()).isEqualTo(Evidence.DRAW_ONLY);
        Row pool = r.pool();
        assertThat(pool.evidence()).isEqualTo(Evidence.DRAW_ONLY);
        assertRel(grams(pool), 2.040186523637508);
        assertRel(pool.logSe(), 0.004597818409399265);
        assertRel(pool.lotPrior(), 0.0005211399341258108);
        assertRel(pool.logHalfWidth(), 0.049316587560215265);
        assertThat(pool.df()).isEqualTo(13.0);
        assertThat(pool.nDraw()).isEqualTo(10);
        assertThat(pool.drawBiasLog()).isNull();
        // 产品调整: 至少 10 次领料时最多 YELLOW (绝不 GREEN), 否则 RED
        assertThat(pool.tier()).isEqualTo(Tier.YELLOW);
        EstimateResult nine = estimate(mk("D", SourceKind.DRAW, 9, 2.00, 500, 0.004, 0, 3, null, 0, 1.02));
        assertThat(nine.pool().tier()).isEqualTo(Tier.RED);

        WeightParamsResolver.Resolution resolution = resolve(r, null, null, day(40));
        assertThat(resolution.basis()).isEqualTo(WeightParamsResolver.BASIS_LEARNED);
        assertThat(resolution.params().evidence()).isEqualTo("DRAW_ONLY");
        assertThat(resolution.alertsAllowed()).isFalse();
        assertRel(resolution.params().lotPrior(), 0.0005211399341258108);
        GoodsWeightObservationService.Snapshot snap = GoodsWeightObservationService.snapshot(resolution,
                new BigDecimal("500"), new BigDecimal("0.9000"), SourceKind.DRAW.eps());
        assertThat(snap.alert()).isEqualTo(Alert.NONE);
    }

    // ------------------------------------------------------------------ 9. 单次称样

    @Test
    void scenario09_singleSampleIsUsableAndSameLotSampleTightensTheBand() {
        EstimateResult r = estimate(List.of(obs("s1", 0, SourceKind.SAMPLE, 20, 0.040, 0, null)));
        Row pool = r.pool();
        assertRel(grams(pool), 2.0000000000000004);
        assertRel(pool.tauLot(), 0.01);
        assertRel(pool.logHalfWidth(), 0.041124670059255894);
        assertThat(pool.tier()).as("q>=10 的称样放行 n<3 门槛").isEqualTo(Tier.YELLOW);

        ApwPredictor.CountPrediction plain = ApwPredictor.countFromWeight(predictor(pool), 20.0, null);
        assertRel(plain.estimatedQty(), 9999.999999999998);
        assertRel(plain.qtyLow(), 9597.058959329215);
        assertRel(plain.qtyHigh(), 10419.858877994164);
        assertRel(plain.exactUpToQty(), 11.284988514620727);

        ApwPredictor.CountPrediction fused = ApwPredictor.countFromWeight(predictor(pool), 20.0,
                new ApwPredictor.Sample(30, 0.0603));
        assertRel(fused.estimatedQty(), 9953.124518551453);
        assertRel(fused.logHalfWidth(), 0.009914465419833268);
        assertRel(fused.exactUpToQty(), 37.227091805808506);
        assertThat(ApwEstimator.tierOf(fused.logHalfWidth(), CFG)).isEqualTo(Tier.GREEN);
    }

    // ------------------------------------------------------------------ 10. 太少的称样

    @Test
    void scenario10_tinySampleStaysRed() {
        EstimateResult r = estimate(List.of(obs("t", 0, SourceKind.SAMPLE, 2, 0.004, 0, null)));
        assertRel(r.pool().logHalfWidth(), 0.05888258428444287);
        assertThat(r.pool().tier()).isEqualTo(Tier.RED);
    }

    // ------------------------------------------------------------------ 11. 两次矛盾

    @Test
    void scenario11_conflictingPairPublishesNoUnitWeight() {
        EstimateResult r = estimate(List.of(
                obs("a", 0, SourceKind.RECEIPT, 1000, 2.0, 0, null),
                obs("b", 0, SourceKind.RECEIPT, 1000, 0.002, 5, null)));
        assertThat(r.evidence()).isEqualTo(Evidence.CONFLICT);
        assertThat(r.pool().logMean()).isNull();
        assertThat(r.pool().unitWeightKg()).isNull();
        assertThat(r.pool().tier()).isEqualTo(Tier.RED);
        assertThat(r.pool().suggestedSampleSize()).isEqualTo(16);
        assertThat(r.suppliers()).isEmpty();

        WeightParamsResolver.Resolution resolution = resolve(r, null, null, day(10));
        assertThat(resolution.basis()).isEqualTo(WeightParamsResolver.BASIS_NONE);
        assertThat(resolution.params().evidence()).isEqualTo("CONFLICT");
        assertThat(resolution.params().unitWeightKg()).isNull();
    }

    // ------------------------------------------------------------------ 12. 区间随数量变化

    @Test
    void scenario12_bandNarrowsWithCountUntilLotVarianceDominates() {
        Row pool = estimate(mk("H", SourceKind.RECEIPT, 12, 2.00, 5000, 0.005, 0, 10, null, 0, 1.0)).pool();
        assertRel(grams(pool), 1.9990255743519112);
        double[][] expected = {
                {0.02, 10.004874503160895, 0.019261875687110477},
                {0.2, 100.04874503160895, 0.014077789689800325},
                {2.0, 1000.4874503160894, 0.01348124160378407},
                {20.0, 10004.874503160894, 0.013420442588128844},
                {200.0, 100048.74503160894, 0.013414350673723126}};
        for (double[] e : expected) {
            ApwPredictor.CountPrediction p = ApwPredictor.countFromWeight(predictor(pool), e[0], null);
            assertRel(p.estimatedQty(), e[1]);
            assertRel(p.logHalfWidth(), e[2]);
            assertRel(p.exactUpToQty(), 32.56612991202391);
        }
    }

    // ------------------------------------------------------------------ 13. 确定性

    @Test
    void scenario13_resultIsBitIdenticalRegardlessOfInputOrder() {
        List<WeightObservation> ordered = concat(
                mk("A", SourceKind.RECEIPT, 10, 2.00, 5000, 0.005, 0, 7, SUP_A, 0, 1.0),
                mk("B", SourceKind.RECEIPT, 4, 2.10, 5000, 0.005, 3, 14, SUP_B, 3, 1.0),
                mk("D", SourceKind.DRAW, 12, 2.00, 500, 0.004, 1, 5, null, 0, 1.02));
        List<WeightObservation> shuffled = new ArrayList<>(ordered);
        Collections.shuffle(shuffled, new Random(7));
        EstimateResult a = estimate(ordered);
        EstimateResult b = estimate(shuffled);
        assertThat(b).isEqualTo(a);
        assertThat(estimate(ordered)).isEqualTo(a);
        assertThat(ApwEstimator.ALGORITHM_VERSION).isPositive();
    }

    // ------------------------------------------------------------------ 14. 防循环

    @Test
    void scenario14_circularEvidenceIsNeverLearned() {
        assertThat(GoodsWeightObservationService.skipBeforeLookup(true, BigDecimal.TEN, BigDecimal.ONE))
                .as("数量按称重推算").isTrue();
        assertThat(GoodsWeightObservationService.skipBeforeLookup(false, BigDecimal.ZERO, BigDecimal.ONE)).isTrue();
        assertThat(GoodsWeightObservationService.skipBeforeLookup(false, BigDecimal.TEN, BigDecimal.ZERO)).isTrue();
        assertThat(GoodsWeightObservationService.skipBeforeLookup(false, BigDecimal.TEN, BigDecimal.ONE)).isFalse();

        // 实称等于提示的应称重量 (4 位) → ECHO
        assertThat(GoodsWeightObservationService.exclusionReason(new BigDecimal("5000"), new BigDecimal("9.9951"),
                new BigDecimal("9.995123"), new BigDecimal("0.001999024615")))
                .isEqualTo(GoodsWeightObservationService.EXCLUDED_ECHO);
        // 数量恰好等于 实称/单重 取整且 ≥100 件 → QTY_ECHO
        assertThat(GoodsWeightObservationService.exclusionReason(new BigDecimal("5003"), new BigDecimal("10.0010"),
                new BigDecimal("9.995123"), new BigDecimal("0.001999")))
                .isEqualTo(GoodsWeightObservationService.EXCLUDED_QTY_ECHO);
        // 独立点数、独立称重 → 正常学习
        assertThat(GoodsWeightObservationService.exclusionReason(new BigDecimal("5000"), new BigDecimal("10.0100"),
                new BigDecimal("9.995123"), new BigDecimal("0.001999"))).isNull();
        // 件数少时凑巧相等不算
        assertThat(GoodsWeightObservationService.exclusionReason(new BigDecimal("50"), new BigDecimal("0.1000"),
                null, new BigDecimal("0.002"))).isNull();

        // 基本单位是重量单位 → EXACT, 单重 = 换算系数
        GoodsWeightFacts kgGoods = new GoodsWeightFacts(UUID.randomUUID(), true, UUID.randomUUID(), "G", "MASS",
                null, null, Profile.missing(), null, null);
        WeightParamsResolver.Resolution exact = WeightParamsResolver.resolve(kgGoods, null, "k", Instant.now(),
                CFG.scaleResKg());
        assertThat(exact.basis()).isEqualTo(WeightParamsResolver.BASIS_EXACT);
        assertThat(exact.params().massFactorKg()).isEqualByComparingTo("0.001");
        assertThat(exact.params().unitWeightKg()).isEqualByComparingTo("0.001");
        assertThat(exact.predictor()).isNull();
    }

    // ------------------------------------------------------------------ 15. 时间衰减

    @Test
    void scenario15_oldObservationsDecayWithoutARegime() {
        EstimateResult r = estimate(concat(
                mk("O", SourceKind.RECEIPT, 10, 2.00, 5000, 0.003, 0, 5, null, 0, 1.0),
                mk("N", SourceKind.RECEIPT, 3, 2.02, 5000, 0.003, 400, 5, null, 1, 1.0)));
        assertThat(r.pool().regimeStartedAt()).isNull();
        assertThat(r.pool().nInliers()).isEqualTo(13);
        assertRel(grams(r.pool()), 2.012522835227622);
        assertThat(r.asOf()).isEqualTo(day(410));
    }

    // ------------------------------------------------------------------ 16. 只到过一次货的供应商

    @Test
    void scenario16_singleReceiptSupplierIsShrunkAndStaysRed() {
        EstimateResult r = estimate(concat(
                mk("A", SourceKind.RECEIPT, 10, 2.00, 5000, 0.005, 0, 7, SUP_A, 0, 1.0),
                List.of(obs("B0", 0, SourceKind.RECEIPT, 5000, 10.5, 80, SUP_B))));
        Row a = supplier(r, SUP_A);
        Row b = supplier(r, SUP_B);
        assertRel(grams(b), 2.0891873551239257);
        assertRel(b.shrinkWeight(), 0.8811484036846944);
        assertThat(b.tier()).isEqualTo(Tier.RED);
        assertRel(grams(a), 2.0004400168537666);
        assertThat(a.tier()).isEqualTo(Tier.YELLOW);
        assertRel(grams(r.pool()), 2.0107414161270003);
    }

    // ------------------------------------------------------------------ 17. 人工单重

    @Test
    void scenario17_manualOverrideFlagsConflictAndChecksWithLotPrior() {
        EstimateResult r = estimate(mk("H", SourceKind.RECEIPT, 20, 2.00, 5000, 0.003, 0, 10, null, 0, 1.0));
        assertRel(grams(r.pool()), 1.9998683792590028);
        UUID unit = UUID.randomUUID();
        Profile manual = new Profile(true, null, null, null, new BigDecimal("0.00205"), unit, "设计变更", null, null,
                true, Profile.REGIME_AUTO, null, 1, null, null);
        GoodsWeightFacts goods = new GoodsWeightFacts(UUID.randomUUID(), true, unit, null, "COUNT", null, null,
                manual, toRow(r.pool(), r.asOf()), null);
        WeightParamsResolver.Resolution resolution = WeightParamsResolver.resolve(goods, null, "k", day(200),
                CFG.scaleResKg());
        assertThat(resolution.basis()).isEqualTo(WeightParamsResolver.BASIS_MANUAL);
        assertRel(resolution.params().manualConflictPct(), 2.5067460069333025);
        assertRel(resolution.params().lotPrior(), 1.739130434782609e-05);
        assertThat(resolution.params().df()).isEqualTo(23.0);
        assertThat(resolution.alertsAllowed()).isTrue();

        ApwPredictor.WeightCheck check = ApwPredictor.checkWeight(resolution.predictor(), SourceKind.RECEIPT.eps(),
                10000, 20.0, 3.0);
        assertRel(check.expectedWeightKg(), 20.5);
        assertRel(check.deviationPct(), -2.4390243902439046);
        assertThat(check.z()).isCloseTo(-2.158916767139897, within(1e-6));
        assertThat(check.alert()).isEqualTo(Alert.NONE);

        // 基本单位改过 (manual_unit_id 对不上) → 人工值失效, 回到学习结果
        GoodsWeightFacts unitChanged = new GoodsWeightFacts(goods.goodsId(), true, UUID.randomUUID(), null, "COUNT",
                null, null, manual, goods.pool(), null);
        assertThat(WeightParamsResolver.resolve(unitChanged, null, "k", day(200), CFG.scaleResKg()).basis())
                .isEqualTo(WeightParamsResolver.BASIS_LEARNED);
    }

    // ------------------------------------------------------------------ 18. 到货偏差告警

    @Test
    void scenario18_receiptAlertsAgainstTheSupplierUnitWeight() {
        EstimateResult r = estimate(mk("A", SourceKind.RECEIPT, 12, 2.00, 5000, 0.005, 0, 7, SUP_A, 0, 1.0));
        Row a = supplier(r, SUP_A);
        assertRel(grams(a), 1.999069546645846);
        WeightParamsResolver.Resolution resolution = resolve(r, a, SUP_A, day(100));
        assertThat(resolution.params().supplierSpecific()).isTrue();
        Object[][] expected = {
                {20.0, 0.04654432136768083, Alert.NONE},
                {19.6, -1.9543865650596737, Alert.NONE},
                {19.3, -3.455084729880187, Alert.WARN},
                {19.0, -4.955782894700711, Alert.WARN},
                {18.5, -7.456946502734896, Alert.ALERT},
                {18.0, -9.958110110769091, Alert.ALERT}};
        for (Object[] e : expected) {
            double w = (double) e[0];
            ApwPredictor.WeightCheck check = ApwPredictor.checkWeight(resolution.predictor(),
                    SourceKind.RECEIPT.eps(), 10000, w, 3.0);
            assertRel(check.expectedWeightKg(), 19.990695466458458);
            assertRel(check.deviationPct(), (double) e[1]);
            assertThat(check.alert()).as("W=" + w).isEqualTo(e[2]);
            GoodsWeightObservationService.Snapshot snap = GoodsWeightObservationService.snapshot(resolution,
                    new BigDecimal("10000"), BigDecimal.valueOf(w), SourceKind.RECEIPT.eps());
            assertThat(snap.alert()).as("快照 W=" + w).isEqualTo(e[2]);
        }

        // 设计单重 (MASTER_PRIOR) 只给参考, 永不告警
        GoodsWeightFacts prior = new GoodsWeightFacts(UUID.randomUUID(), true, UUID.randomUUID(), null, "COUNT",
                new BigDecimal("2.0000"), "G", Profile.missing(), null, null);
        WeightParamsResolver.Resolution master = WeightParamsResolver.resolve(prior, null, "k", day(100),
                CFG.scaleResKg());
        assertThat(master.basis()).isEqualTo(WeightParamsResolver.BASIS_MASTER_PRIOR);
        assertThat(master.tier()).isEqualTo(Tier.RED);
        assertThat(master.params().unitWeightKg()).isEqualByComparingTo("0.002");
        GoodsWeightObservationService.Snapshot far = GoodsWeightObservationService.snapshot(master,
                new BigDecimal("10000"), new BigDecimal("15.0000"), SourceKind.RECEIPT.eps());
        assertThat(far.alert()).isEqualTo(Alert.NONE);
        assertThat(far.deviationPct()).isEqualByComparingTo("-25.0000");
    }

    // ------------------------------------------------------------------ 19. 红冲

    @Test
    void scenario19_reversalRestoresTheEstimateAndDrawCancelIsLifo() {
        List<WeightObservation> base = mk("H", SourceKind.RECEIPT, 12, 2.00, 5000, 0.005, 0, 10, null, 0, 1.0);
        WeightObservation extra = obs("Z", 0, SourceKind.RECEIPT, 5000, 10.4, 200, null);
        EstimateResult before = estimate(base);
        EstimateResult withExtra = estimate(concat(base, List.of(extra)));
        assertThat(ids(withExtra.outliers())).containsExactly(extra.id());
        assertRel(zOf(withExtra, extra.id()), 3.50688509769162);
        assertRel(grams(withExtra.pool()), 1.9990255743519112);
        EstimateResult reversed = estimate(new ArrayList<>(base));
        assertThat(reversed).isEqualTo(before);

        UUID r1 = UUID.randomUUID();
        UUID r2 = UUID.randomUUID();
        UUID r3 = UUID.randomUUID();
        List<GoodsWeightObservationService.LifoCandidate> newestFirst = List.of(
                new GoodsWeightObservationService.LifoCandidate(r1, null, new BigDecimal("300")),
                new GoodsWeightObservationService.LifoCandidate(r2, null, new BigDecimal("500")),
                new GoodsWeightObservationService.LifoCandidate(r3, null, new BigDecimal("200")));
        assertThat(GoodsWeightObservationService.lifoToReverse(newestFirst, new BigDecimal("600")))
                .containsExactly(r1, r2);
        assertThat(GoodsWeightObservationService.lifoToReverse(newestFirst, new BigDecimal("300")))
                .containsExactly(r1);
        assertThat(GoodsWeightObservationService.lifoToReverse(newestFirst, new BigDecimal("5000")))
                .containsExactly(r1, r2, r3);
    }

    // ------------------------------------------------------------------ 20. 窗口 + 陈旧

    @Test
    void scenario20_separateWindowsKeepReceiptsAndStaleCapsTheRequestTier() {
        EstimateResult r = estimate(concat(
                mk("F", SourceKind.RECEIPT, 20, 2.00, 5000, 0.005, 0, 10, null, 0, 1.0),
                mk("D", SourceKind.DRAW, 250, 2.00, 500, 0.004, 1, 0.5, null, 0, 1.02)));
        assertThat(r.pool().nRef()).isEqualTo(20);
        assertThat(r.pool().nInliers()).isEqualTo(20);
        assertThat(r.pool().nDraw()).isEqualTo(200);
        assertRel(100 * StrictMath.expm1(r.pool().drawBiasLog()), 2.0127066179529196);
        assertRel(100 * r.pool().drawBiasSe(), 0.2975518877269908);
        assertRel(grams(r.pool()), 1.9997764916818723);

        // 陈旧: 最后一次称重后 400 天请求, GREEN 封顶为 YELLOW; 存储口径不变
        List<WeightObservation> green = mk("X", SourceKind.RECEIPT, 40, 2.00, 5000, 0.005, 0, 3, null, 0, 1.0);
        EstimateResult g = estimate(green);
        assertThat(g.pool().tier()).isEqualTo(Tier.GREEN);
        Instant last = g.pool().lastObservedAt();
        WeightParamsResolver.Resolution fresh = resolve(g, null, null, last.plus(Duration.ofDays(30)));
        assertThat(fresh.params().stale()).isFalse();
        assertThat(fresh.tier()).isEqualTo(Tier.GREEN);
        WeightParamsResolver.Resolution stale = resolve(g, null, null, last.plus(Duration.ofDays(400)));
        assertThat(stale.params().stale()).isTrue();
        assertThat(stale.tier()).isEqualTo(Tier.YELLOW);
        assertThat(g.pool().tier()).isEqualTo(Tier.GREEN);
    }

    // ------------------------------------------------------------------ 其它产品调整

    @Test
    void suggestedSampleSizeAndHints() {
        assertThat(ApwEstimator.suggestedSampleSize(CFG, 0.002)).isEqualTo(16);
        assertThat(ApwEstimator.suggestedSampleSize(CFG, null)).isEqualTo(16);
        // 0.1 mg 的小件: 称样至少要 100 × 分辨率
        assertThat(ApwEstimator.suggestedSampleSize(CFG, 0.0000001)).isEqualTo(200);
        assertThat(ApwEstimator.hint(StrictMath.log(10))).isEqualTo("UNIT_10");
        assertThat(ApwEstimator.hint(-StrictMath.log(100))).isEqualTo("UNIT_100");
        assertThat(ApwEstimator.hint(StrictMath.log(2))).isEqualTo("JIN_KG");
        assertThat(ApwEstimator.hint(StrictMath.log(1 / 0.45359237))).isEqualTo("LB_KG");
        assertThat(ApwEstimator.hint(0.2)).isEqualTo("DEVIATION");
    }

    @Test
    void supplierLabelShortCountIsSeparatedFromTheUnitWeight() {
        // 标签写 1000 个, 箱里其实 970 个 (2.00 g): 到货的 w/q 系统性偏轻 3%, 同供应商的称样才是真单重
        List<WeightObservation> receipts = new ArrayList<>();
        for (int j = 0; j < 5; j++) {
            receipts.add(new WeightObservation(id("R", j), SourceKind.RECEIPT, 1000,
                    970 * 0.002 * (1 + 0.002 * P(j)), day(10.0 * j), SUP_A, null));
        }
        List<WeightObservation> samples = new ArrayList<>();
        for (int j = 0; j < 3; j++) {
            samples.add(new WeightObservation(id("S", j), SourceKind.SAMPLE, 50,
                    50 * 0.002 * (1 + 0.002 * P(j + 3)), day(10.0 * j + 5), SUP_A, null));
        }
        EstimateResult r = estimate(concat(receipts, samples));
        Row a = supplier(r, SUP_A);
        assertThat(a.labelBiasLog()).as("标签偏差可识别且显著").isNotNull();
        assertThat(100 * StrictMath.expm1(a.labelBiasLog())).isCloseTo(-3.0, within(0.3));
        assertThat(StrictMath.exp(a.rawLogMean()) * 1000).as("供应商行改用称样拟合").isCloseTo(2.0, within(0.01));

        EstimateResult noSamples = estimate(receipts);
        assertThat(supplier(noSamples, SUP_A).labelBiasLog()).as("没有称样时不可识别").isNull();
    }

    @Test
    void emptyInputHasNoEvidence() {
        assertThat(estimate(List.of()).evidence()).isEqualTo(Evidence.NONE);
        assertThat(estimate(mk("S", SourceKind.SHIPMENT, 5, 2.0, 100, 0.01, 0, 1, null, 0, 1.0)).evidence())
                .as("其它核对类观测不参与估算").isEqualTo(Evidence.NONE);
    }

    // ================================================================== helpers

    static EstimateResult estimate(List<WeightObservation> obs) {
        return ApwEstimator.estimate(obs, CFG, null, true);
    }

    static double P(int j) {
        return (((j * 7) % 11) - 5) / 5.0;
    }

    /** 与 apw_proto.mk 同式: w = q × apw_g / 1000 × (1 + a·P(j + j0)) × factor, t = t0 + j·dt 天。 */
    static List<WeightObservation> mk(String prefix, SourceKind kind, int n, double apwG, double q, double a,
                                      double t0, double dt, UUID supplier, int j0, double factor) {
        List<WeightObservation> out = new ArrayList<>();
        for (int j = 0; j < n; j++) {
            double w = q * apwG / 1000 * (1 + a * P(j + j0)) * factor;
            out.add(new WeightObservation(id(prefix, j), kind, q, w, day(t0 + j * dt), supplier, null));
        }
        return out;
    }

    static WeightObservation obs(String prefix, int j, SourceKind kind, double q, double w, double t, UUID supplier) {
        return new WeightObservation(id(prefix, j), kind, q, w, day(t), supplier, null);
    }

    static WeightObservation scaled(WeightObservation o, double factor) {
        return new WeightObservation(o.id(), o.kind(), o.qtyBase(), o.weightKg() * factor, o.observedAt(),
                o.supplierId(), o.qtyEps());
    }

    /** id 的无符号顺序与原型的字符串 id 顺序一致 (前缀字符在高位, 序号在低位)。 */
    static UUID id(String prefix, int j) {
        long high = 0;
        for (int i = 0; i < Math.min(prefix.length(), 8); i++) {
            high |= ((long) prefix.charAt(i) & 0xFF) << (8 * (7 - i));
        }
        return new UUID(high, j);
    }

    static Instant day(double days) {
        return Instant.EPOCH.plusMillis(Math.round(days * 86_400_000.0));
    }

    @SafeVarargs
    static List<WeightObservation> concat(List<WeightObservation>... lists) {
        List<WeightObservation> all = new ArrayList<>();
        for (List<WeightObservation> l : lists) all.addAll(l);
        return all;
    }

    static double grams(Row row) {
        return StrictMath.exp(row.logMean()) * 1000;
    }

    static Row supplier(EstimateResult r, UUID supplierId) {
        return r.suppliers().stream().filter(s -> supplierId.equals(s.supplierId())).findFirst().orElseThrow();
    }

    static List<UUID> ids(List<Outlier> outliers) {
        return outliers.stream().map(Outlier::observationId).toList();
    }

    static double zOf(EstimateResult r, UUID id) {
        return r.outliers().stream().filter(o -> o.observationId().equals(id)).findFirst().orElseThrow().z();
    }

    static ApwPredictor.Params predictor(Row row) {
        return new ApwPredictor.Params(row.logMean(), row.lotPrior(), row.df(), CFG.gamma(), CFG.scaleResKg());
    }

    static WeightParamsResolver.Resolution resolve(EstimateResult r, Row supplierRow, UUID supplierId, Instant now) {
        GoodsWeightFacts goods = new GoodsWeightFacts(UUID.randomUUID(), true, UUID.randomUUID(), null, "COUNT",
                null, null, Profile.missing(), toRow(r.pool(), r.asOf()), null);
        return WeightParamsResolver.resolve(goods, supplierRow == null ? null : toRow(supplierRow, r.asOf()),
                supplierId == null ? "k" : supplierId.toString(), now, CFG.scaleResKg());
    }

    /** 模拟落库再读回的一行 (与 GoodsWeightEstimateService.upsert 的列一一对应)。 */
    static EstimateRow toRow(Row row, Instant asOf) {
        return new EstimateRow(row.supplierId(), row.evidence().name(), row.logMean(),
                row.unitWeightKg() == null ? null : WeightParamsResolver.kg(row.unitWeightKg()),
                row.logSe(), row.tauLot(), row.tauBetween(), row.shrinkWeight(), row.rawLogMean(),
                row.nObs(), row.nRef(), row.nInliers(), row.nEff(), row.relHalfWidth(), row.tier().name(),
                row.drawBiasLog(), row.drawBiasSe(), row.nDraw(), row.labelBiasLog(), row.labelBiasSe(),
                odt(row.regimeStartedAt()), odt(row.regimeChangedAt()), odt(row.lastObservedAt()), odt(asOf),
                "[]", row.suggestedSampleSize(), ApwEstimator.ALGORITHM_VERSION, odt(asOf));
    }

    static OffsetDateTime odt(Instant instant) {
        return instant == null ? null : OffsetDateTime.ofInstant(instant, ZoneOffset.UTC);
    }

    static void assertRel(Double actual, double expected) {
        assertThat(actual).isNotNull();
        assertThat(actual).isCloseTo(expected, within(Math.abs(expected) * REL + 1e-15));
    }
}
