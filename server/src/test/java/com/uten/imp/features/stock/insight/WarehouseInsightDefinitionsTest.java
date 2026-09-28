package com.uten.imp.features.stock.insight;

import com.uten.imp.common.report.ReportTotal;
import com.uten.imp.common.report.ReportTotalGroup;
import com.uten.imp.common.report.ReportTotalsCalculator;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.insight.dto.CycleCountRow;
import com.uten.imp.features.stock.insight.dto.GoodsInsight;
import com.uten.imp.features.stock.insight.dto.HealthOverview;
import com.uten.imp.features.stock.insight.dto.HealthRow;
import com.uten.imp.features.stock.insight.dto.LearningRow;
import com.uten.imp.features.stock.insight.dto.WeightAlertRow;
import com.uten.imp.features.stock.weight.dto.WeightParams;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 库存分析口径 (ADR-135 §7.4) 用内存行验证: ABC 阈值、呆滞、库龄期初、日均与可用天数、顶部指标、
 * 表格筛选/排序/分页/合计、盘点建议打分与每仓上限、称重异常分类、单重学习清单筛选、单货品指标条合成。
 */
class WarehouseInsightDefinitionsTest {

    private static final LocalDate AS_OF = LocalDate.of(2026, 9, 28);
    private static final UUID CATEGORY = UUID.randomUUID();
    private static final UUID OTHER_CATEGORY = UUID.randomUUID();

    @Test
    void abcRanksByCumulativeShareOfPicksAndZeroPicksAreN() {
        // 出库次数 70 / 20 / 6 / 4 (合计 100): 排在前面的累计 0、70 → A; 90 → B; 96 → C。
        assertThat(WarehouseInsightDefinitions.abc(70, 0, 100)).isEqualTo("A");
        assertThat(WarehouseInsightDefinitions.abc(20, 70, 100)).isEqualTo("A");
        assertThat(WarehouseInsightDefinitions.abc(6, 90, 100)).isEqualTo("B");
        assertThat(WarehouseInsightDefinitions.abc(4, 96, 100)).isEqualTo("C");
        assertThat(WarehouseInsightDefinitions.abc(0, 100, 100)).isEqualTo("N");
        assertThat(WarehouseInsightDefinitions.countIntervalDays("A")).isEqualTo(30);
        assertThat(WarehouseInsightDefinitions.countIntervalDays("B")).isEqualTo(90);
        assertThat(WarehouseInsightDefinitions.countIntervalDays("N")).isEqualTo(180);
    }

    @Test
    void deadStockNeedsNoConsumptionAndAnOldNewestLayer() {
        OffsetDateTime old = at(AS_OF.minusDays(91));
        OffsetDateTime recent = at(AS_OF.minusDays(10));
        assertThat(WarehouseInsightDefinitions.dead(new BigDecimal("5"), BigDecimal.ZERO, old, AS_OF)).isTrue();
        // 上周刚到的货不算呆滞, 即便还没用过。
        assertThat(WarehouseInsightDefinitions.dead(new BigDecimal("5"), BigDecimal.ZERO, recent, AS_OF)).isFalse();
        // 没有入库记录 (期初) 视为很早。
        assertThat(WarehouseInsightDefinitions.dead(new BigDecimal("5"), BigDecimal.ZERO, null, AS_OF)).isTrue();
        assertThat(WarehouseInsightDefinitions.dead(new BigDecimal("5"), new BigDecimal("1"), old, AS_OF)).isFalse();
        assertThat(WarehouseInsightDefinitions.dead(BigDecimal.ZERO, BigDecimal.ZERO, old, AS_OF)).isFalse();
    }

    @Test
    void healthRowDerivesUnknownAgeCoverAndMasksValueWithoutCostPermission() {
        InsightFacts.Health fact = health("G-1", "螺丝", CATEGORY, "100", "2.5000", false, "900",
                "30", "20", "0", "0", "0", "50", at(AS_OF.minusDays(5)), "45", 12, 70, 0, 100);

        HealthRow masked = WarehouseInsightDefinitions.healthRow(fact, AS_OF, false);
        assertThat(masked.ageUnknown()).isEqualByComparingTo("50");
        assertThat(masked.avgDailyOut90()).isEqualByComparingTo("0.5");
        assertThat(masked.daysOfCover()).isEqualByComparingTo("200");
        assertThat(masked.idleDays()).isEqualTo(5);
        assertThat(masked.lastInAt()).isEqualTo(at(AS_OF.minusDays(3)));
        assertThat(masked.abc()).isEqualTo("A");
        assertThat(masked.dead()).isFalse();
        assertThat(masked.amountLocal()).isNull();
        assertThat(masked.costMasked()).isTrue();

        HealthRow visible = WarehouseInsightDefinitions.healthRow(fact, AS_OF, true);
        assertThat(visible.amountLocal()).isEqualByComparingTo("900");

        InsightFacts.Health idle = health("G-2", "垫片", CATEGORY, "8", null, true, "10",
                "0", "0", "0", "0", "8", "8", at(AS_OF.minusDays(400)), "0", 0, 0, 100, 100);
        HealthRow idleRow = WarehouseInsightDefinitions.healthRow(idle, AS_OF, true);
        assertThat(idleRow.daysOfCover()).isNull();
        assertThat(idleRow.dead()).isTrue();
        assertThat(idleRow.abc()).isEqualTo("N");
        // 未知重量不带「≈」标记。
        assertThat(idleRow.weightEstimated()).isFalse();
    }

    @Test
    void overviewCountsScopeWideAndKeepsUnknownWeightOutOfTheKnownTotal() {
        List<InsightFacts.Health> facts = fixture();
        List<HealthRow> rows = facts.stream().map(f -> WarehouseInsightDefinitions.healthRow(f, AS_OF, true)).toList();

        HealthOverview overview = WarehouseInsightDefinitions.overview(facts, rows, true,
                new WarehouseInsightDefinitions.OverviewCounts(42, 3, 2, 1, 7));

        assertThat(overview.skuWithStock()).isEqualTo(3);
        assertThat(overview.knownWeightKg()).isEqualByComparingTo("3.7500");
        assertThat(overview.weightUnknownRows()).isEqualTo(1);
        // 余额行 dims 1+2+1 = 4, 已称且非估算 1+1+0 = 2 → 50%。
        assertThat(overview.weighedCoveragePct()).isEqualByComparingTo("50.0");
        assertThat(overview.deadSku()).isEqualTo(1);
        // 181 天以上 + 期初: (0 + 50) + (0 + 0) + (8 + 0) = 58 / 118 → 49.2%。
        assertThat(overview.aged180QtyPct()).isEqualByComparingTo("49.2");
        assertThat(overview.movements30d()).isEqualTo(42);
        assertThat(overview.alerts30d()).isEqualTo(3);
        // KPI 说明行「来料少数 x / 领料超发 y」随概览下发, 不必等称重异常分段加载。
        assertThat(overview.receiptShort30d()).isEqualTo(2);
        assertThat(overview.drawOver30d()).isEqualTo(1);
        assertThat(overview.needsSample()).isEqualTo(7);
        assertThat(overview.deadAmountLocal()).isEqualByComparingTo("10");
        assertThat(WarehouseInsightDefinitions.overview(facts, rows, false,
                new WarehouseInsightDefinitions.OverviewCounts(0, 0, 0, 0, 0)).deadAmountLocal()).isNull();
    }

    @Test
    void filtersSortPageAndTotalOverTheFilteredRowsOnly() {
        List<InsightFacts.Health> facts = fixture();
        List<HealthRow> rows = facts.stream().map(f -> WarehouseInsightDefinitions.healthRow(f, AS_OF, true)).toList();

        List<HealthRow> inCategory = filter(facts, rows,
                new WarehouseInsightDefinitions.HealthFilter(Set.of(CATEGORY), null, null, false, false));
        assertThat(inCategory).extracting(HealthRow::code).containsExactlyInAnyOrder("G-1", "G-2");
        assertThat(filter(facts, rows, new WarehouseInsightDefinitions.HealthFilter(null, "垫", null, false, false)))
                .extracting(HealthRow::code).containsExactly("G-2");
        assertThat(filter(facts, rows, new WarehouseInsightDefinitions.HealthFilter(null, null, "n", false, false)))
                .extracting(HealthRow::code).containsExactly("G-2");
        assertThat(filter(facts, rows, new WarehouseInsightDefinitions.HealthFilter(null, null, null, true, false)))
                .extracting(HealthRow::code).containsExactly("G-2");
        assertThat(filter(facts, rows, new WarehouseInsightDefinitions.HealthFilter(null, null, null, false, true)))
                .extracting(HealthRow::code).containsExactlyInAnyOrder("G-1", "G-2");

        List<HealthRow> sorted = new ArrayList<>(rows);
        sorted.sort(WarehouseInsightDefinitions.healthOrder("weightKg", "asc"));
        // 未知重量恒排最后 (无论升降序)。
        assertThat(sorted).extracting(HealthRow::code).containsExactly("G-3", "G-1", "G-2");
        sorted.sort(WarehouseInsightDefinitions.healthOrder("weightKg", "desc"));
        assertThat(sorted).extracting(HealthRow::code).containsExactly("G-1", "G-3", "G-2");
        // 默认: 距最后变动天数倒序。
        sorted.sort(WarehouseInsightDefinitions.healthOrder("no-such-column", "asc"));
        assertThat(sorted.getFirst().code()).isEqualTo("G-2");

        PageResponse<HealthRow> page = WarehouseInsightDefinitions.page(sorted, 2, 2);
        assertThat(page.getTotal()).isEqualTo(3);
        assertThat(page.getTotalPages()).isEqualTo(2);
        assertThat(page.getItems()).hasSize(1);

        List<ReportTotal> totals = ReportTotalsCalculator.computeFromRows(
                inCategory.stream().map(WarehouseInsightDefinitions::totalsRow).toList(),
                WarehouseInsightDefinitions.healthTotalSpecs(false));
        assertThat(totals).extracting(ReportTotal::key)
                .containsExactly("qty", "weightKg", "weightKg_unknown_rows", "weightKg_estimated_rows", "out90");
        assertThat(total(totals, "weightKg")).isEqualByComparingTo("2.5");
        assertThat(total(totals, "weightKg_unknown_rows")).isEqualByComparingTo("1");
        assertThat(WarehouseInsightDefinitions.healthTotalSpecs(true))
                .extracting(ReportTotalsCalculator.Spec::key).contains("amountLocal");
    }

    @Test
    void cycleCountScoresDueRatioPlusBoostsAndSkipsQuietRows() {
        UUID warehouse = UUID.randomUUID();
        // A 类 (周期 30 天), 31 天前盘过 → 到期; 近期有尾差 +0.5; 重量未知 +0.3。
        InsightFacts.Cycle due = cycle(warehouse, "G-1", AS_OF.minusDays(31), null, 2, false, null, null, null,
                false, 70, 0, 100);
        CycleCountRow row = WarehouseInsightDefinitions.cycleRow(due, AS_OF);
        assertThat(row.reasons()).containsExactly("DUE", "RESIDUAL", "UNKNOWN_WEIGHT");
        assertThat(row.score()).isEqualByComparingTo("1.83");
        assertThat(row.daysSince()).isEqualTo(31);
        assertThat(row.abc()).isEqualTo("A");

        // 从未盘过: 按第一笔流水起算; 单重未学准只在近 30 天有动态时加分。
        InsightFacts.Cycle redActive = cycle(warehouse, "G-2", null, AS_OF.minusDays(10), 0, true, "RED", "REFERENCE",
                new BigDecimal("1.0000"), false, 0, 100, 100);
        CycleCountRow red = WarehouseInsightDefinitions.cycleRow(redActive, AS_OF);
        assertThat(red.reasons()).containsExactly("RED_TIER");
        assertThat(red.lastCountedOn()).isNull();
        assertThat(red.daysSince()).isEqualTo(10);
        InsightFacts.Cycle redQuiet = cycle(warehouse, "G-3", null, AS_OF.minusDays(10), 0, false, "RED", "REFERENCE",
                new BigDecimal("1.0000"), false, 0, 100, 100);
        assertThat(WarehouseInsightDefinitions.cycleRow(redQuiet, AS_OF)).isNull();

        // 按重量计的货品不因重量未知/估算加分。
        InsightFacts.Cycle exact = cycle(warehouse, "G-4", AS_OF.minusDays(5), null, 0, true, null, null, null, true,
                0, 100, 100);
        assertThat(WarehouseInsightDefinitions.cycleRow(exact, AS_OF)).isNull();
    }

    @Test
    void cycleCountRowsCarryTheColorSoTheCheckPrefillLineIsExact() {
        UUID warehouse = UUID.randomUUID();
        UUID white = UUID.randomUUID();
        InsightFacts.Cycle plain = cycle(warehouse, "G-1", AS_OF.minusDays(200), null, 0, false, null, null,
                new BigDecimal("1"), false, 0, 0, 0);
        InsightFacts.Cycle colored = new InsightFacts.Cycle(plain.warehouseId(), plain.warehouseName(),
                plain.goodsId(), plain.code(), plain.name(), white, "白", plain.unitName(), plain.qty(),
                plain.weightKg(), plain.weightEstimated(), plain.lastCountedOn(), plain.firstMovementOn(),
                plain.firstBalanceOn(), plain.residuals90(), plain.active30(), plain.estimateTier(),
                plain.estimateEvidence(), plain.exact(), plain.goodsPicks(), plain.picksCumBefore(),
                plain.picksTotal());

        CycleCountRow whiteRow = WarehouseInsightDefinitions.cycleRow(colored, AS_OF);
        CycleCountRow plainRow = WarehouseInsightDefinitions.cycleRow(plain, AS_OF);

        assertThat(whiteRow.colorId()).isEqualTo(white);
        assertThat(whiteRow.colorName()).isEqualTo("白");
        assertThat(plainRow.colorId()).isNull();
        // 同分同天数同编号: 无颜色在前, 再按颜色名。
        List<CycleCountRow> sorted = new ArrayList<>(List.of(whiteRow, plainRow));
        sorted.sort(WarehouseInsightDefinitions.CYCLE_ORDER);
        assertThat(sorted).extracting(CycleCountRow::colorId).containsExactly(null, white);
    }

    @Test
    void cycleCountIsCappedPerWarehouse() {
        UUID busy = UUID.randomUUID();
        UUID quiet = UUID.randomUUID();
        List<CycleCountRow> rows = new ArrayList<>();
        for (int i = 0; i < 25; i++) {
            rows.add(WarehouseInsightDefinitions.cycleRow(cycle(busy, "B-" + i, AS_OF.minusDays(200 + i), null, 0,
                    false, null, null, new BigDecimal("1"), false, 0, 0, 0), AS_OF));
        }
        for (int i = 0; i < 3; i++) {
            rows.add(WarehouseInsightDefinitions.cycleRow(cycle(quiet, "Q-" + i, AS_OF.minusDays(190), null, 0,
                    false, null, null, new BigDecimal("1"), false, 0, 0, 0), AS_OF));
        }
        rows.sort(WarehouseInsightDefinitions.CYCLE_ORDER);

        List<CycleCountRow> capped = WarehouseInsightDefinitions.capPerWarehouse(rows, 20);

        assertThat(capped).hasSize(23);
        assertThat(capped.stream().filter(r -> r.warehouseId().equals(busy))).hasSize(20);
        // 保留的是分最高 (最久没盘) 的 20 条。
        assertThat(capped.getFirst().code()).isEqualTo("B-24");
    }

    @Test
    void weightAlertsAreClassifiedByKindAndDirectionOfTheDeviation() {
        assertThat(WarehouseInsightDefinitions.alertKind("OBSERVATION", "RECEIPT", new BigDecimal("-4.2")))
                .isEqualTo("RECEIPT_SHORT");
        assertThat(WarehouseInsightDefinitions.alertKind("OBSERVATION", "RECEIPT", new BigDecimal("3.9")))
                .isEqualTo("RECEIPT_OVER");
        assertThat(WarehouseInsightDefinitions.alertKind("OBSERVATION", "DRAW", new BigDecimal("1.5")))
                .isEqualTo("DRAW_OVER");
        assertThat(WarehouseInsightDefinitions.alertKind("OBSERVATION", "SHIPMENT", new BigDecimal("1.5")))
                .isEqualTo("OUTBOUND_MISMATCH");
        assertThat(WarehouseInsightDefinitions.alertKind("REGIME", null, null)).isEqualTo("REGIME_CHANGE");
        assertThat(WarehouseInsightDefinitions.alertLabel("REGIME_CHANGE")).isEqualTo("单重可能已变化(换批/换料?)");
        assertThat(WarehouseInsightDefinitions.alertLabel("DRAW_OVER")).isEqualTo("领料超发");

        InsightFacts.Alert receipt = new InsightFacts.Alert("OBSERVATION", UUID.randomUUID(), at(AS_OF), UUID.randomUUID(),
                "G-1", "螺丝", "个", "COUNT", null, null, null, "RECEIPT", UUID.randomUUID(), "供应商甲", null, null, null,
                "PURCHASE_RECEIPT", UUID.randomUUID(), null, "PR-1", new BigDecimal("1000"), new BigDecimal("2.4000"),
                new BigDecimal("0.002500000000"), new BigDecimal("2.500000"), new BigDecimal("-4.0000"), "WARN",
                "GREEN", "LEARNED", null);
        WeightAlertRow row = WarehouseInsightDefinitions.alertRow(receipt);
        assertThat(row.alertKind()).isEqualTo("RECEIPT_SHORT");
        assertThat(row.alertLabel()).isEqualTo("来料少数");
        assertThat(row.estimatedQty()).isEqualByComparingTo("960");
        assertThat(row.deviationQty()).isEqualByComparingTo("-40");
        // 按件计的货品: 页面把折算数量取整显示。
        assertThat(row.baseUnitDimension()).isEqualTo("COUNT");
    }

    @Test
    void learningFiltersSelectTheWorklistRows() {
        InsightFacts.Learning active = new InsightFacts.Learning(UUID.randomUUID(), "G-1", "螺丝", null, "个",
                new BigDecimal("0.0020"), 12, at(AS_OF), 3, new BigDecimal("500"), 2, 9);
        LearningRow red = WarehouseInsightDefinitions.learningRow(active,
                params("LEARNED", "REFERENCE", "RED", new BigDecimal("0.0025"), true));
        LearningRow learned = WarehouseInsightDefinitions.learningRow(active,
                params("LEARNED", "REFERENCE", "GREEN", new BigDecimal("0.0025"), true));
        LearningRow manual = WarehouseInsightDefinitions.learningRow(active,
                params("MANUAL", null, "YELLOW", new BigDecimal("0.0021"), true));
        LearningRow master = WarehouseInsightDefinitions.learningRow(active,
                params("MASTER_PRIOR", null, "RED", new BigDecimal("0.0020"), true));
        LearningRow drawOnly = WarehouseInsightDefinitions.learningRow(active,
                params("LEARNED", "DRAW_ONLY", "YELLOW", new BigDecimal("0.0020"), true));
        LearningRow disabled = WarehouseInsightDefinitions.learningRow(active,
                params("NONE", null, null, null, false));
        WarehouseInsightDefinitions.LearningFilter needs = WarehouseInsightDefinitions.LearningFilter.parse(null);

        assertThat(needs).isEqualTo(WarehouseInsightDefinitions.LearningFilter.NEEDS_SAMPLE);
        assertThat(WarehouseInsightDefinitions.matches(needs, red)).isTrue();
        assertThat(WarehouseInsightDefinitions.matches(needs, master)).isTrue();
        assertThat(WarehouseInsightDefinitions.matches(needs, learned)).isFalse();
        assertThat(WarehouseInsightDefinitions.matches(needs, manual)).isFalse();
        assertThat(WarehouseInsightDefinitions.matches(needs, disabled)).isFalse();
        // 学到的 0.0025 比设计单重 0.0020 重 25% → 与设计单重不符。
        assertThat(learned.masterDiffPct()).isEqualByComparingTo("25.00");
        assertThat(WarehouseInsightDefinitions.matches(
                WarehouseInsightDefinitions.LearningFilter.MASTER_MISMATCH, learned)).isTrue();
        assertThat(WarehouseInsightDefinitions.matches(
                WarehouseInsightDefinitions.LearningFilter.MASTER_MISMATCH, red)).isFalse();
        assertThat(master.masterDiffPct()).isNull();
        assertThat(WarehouseInsightDefinitions.matches(
                WarehouseInsightDefinitions.LearningFilter.DRAW_ONLY, drawOnly)).isTrue();
        // 依据次数来自货品总体学习结果: 按过往领料推算时页面显示「领料 N 次」。
        assertThat(drawOnly.nRef()).isEqualTo(2);
        assertThat(drawOnly.nDraw()).isEqualTo(9);
        assertThat(WarehouseInsightDefinitions.LearningFilter.parse("master_mismatch"))
                .isEqualTo(WarehouseInsightDefinitions.LearningFilter.MASTER_MISMATCH);
    }

    @Test
    void goodsInsightCombinesColorsAndLeavesWeightUnknownWhenAnyColorIsUnknown() {
        UUID goods = UUID.randomUUID();
        List<InsightFacts.Health> facts = List.of(
                health("G-1", "螺丝", CATEGORY, "60", "1.5000", true, "0", "30", "30", "0", "0", "0", "60",
                        at(AS_OF.minusDays(2)), "45", 12, 70, 0, 100),
                health("G-1", "螺丝", CATEGORY, "40", null, false, "0", "10", "0", "0", "0", "0", "10",
                        at(AS_OF.minusDays(8)), "0", 0, 70, 0, 100));

        GoodsInsight insight = WarehouseInsightDefinitions.goodsInsight(goods, "个", facts,
                params("LEARNED", "REFERENCE", "GREEN", new BigDecimal("0.0250"), true), AS_OF);

        assertThat(insight.qty()).isEqualByComparingTo("100");
        assertThat(insight.weightKg()).isNull();
        assertThat(insight.weightEstimated()).isFalse();
        assertThat(insight.age0_30()).isEqualByComparingTo("40");
        assertThat(insight.ageUnknown()).isEqualByComparingTo("30");
        assertThat(insight.agePct0_30()).isEqualByComparingTo("40.0");
        assertThat(insight.out90()).isEqualByComparingTo("45");
        assertThat(insight.daysOfCover()).isEqualByComparingTo("200.0");
        assertThat(insight.abc()).isEqualTo("A");
        assertThat(insight.idleDays()).isEqualTo(2);
        assertThat(insight.tier()).isEqualTo("GREEN");
        assertThat(insight.unitWeightKg()).isEqualByComparingTo("0.025");
    }

    // ------------------------------------------------------------------ fixtures

    private static List<InsightFacts.Health> fixture() {
        return List.of(
                // G-1: 有消耗、知道重量、一半期初。
                health("G-1", "螺丝", CATEGORY, "100", "2.5000", false, "900", "30", "20", "0", "0", "0", "50",
                        at(AS_OF.minusDays(5)), "45", 12, 70, 0, 100),
                // G-2: 呆滞、重量未知、全部超过一年。
                health("G-2", "垫片", CATEGORY, "8", null, false, "10", "0", "0", "0", "0", "8", "8",
                        at(AS_OF.minusDays(400)), "0", 0, 0, 100, 100),
                // G-3: 另一分类、重量含估算。
                health("G-3", "弹簧", OTHER_CATEGORY, "10", "1.2500", true, "5", "10", "0", "0", "0", "0", "10",
                        at(AS_OF.minusDays(1)), "9", 3, 30, 70, 100));
    }

    private static List<HealthRow> filter(List<InsightFacts.Health> facts, List<HealthRow> rows,
                                          WarehouseInsightDefinitions.HealthFilter filter) {
        List<HealthRow> out = new ArrayList<>();
        for (int i = 0; i < facts.size(); i++) {
            if (WarehouseInsightDefinitions.matches(filter, facts.get(i), rows.get(i))) {
                out.add(rows.get(i));
            }
        }
        return out;
    }

    private static BigDecimal total(List<ReportTotal> totals, String key) {
        return totals.stream().filter(t -> t.key().equals(key)).findFirst().orElseThrow()
                .groups().stream().map(ReportTotalGroup::value).reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    /**
     * @param age0 库龄 0-30; age31 31-90; age91 91-180; age181 181-365; age365 超过 365; allocated 已分配批次合计
     */
    private static InsightFacts.Health health(String code, String name, UUID category, String qty, String weight,
                                              boolean estimated, String amount, String age0, String age31,
                                              String age91, String age181, String age365, String allocated,
                                              OffsetDateTime lastMovement, String out90, long picks,
                                              long goodsPicks, long cumBefore, long total) {
        boolean known = weight != null;
        long dims = "G-1".equals(code) ? 1 : "G-2".equals(code) ? 2 : 1;
        long weighed = known && !estimated ? 1 : "G-2".equals(code) ? 1 : 0;
        OffsetDateTime newestIn = new BigDecimal(age0).signum() > 0 ? at(AS_OF.minusDays(3))
                : new BigDecimal(age365).signum() > 0 ? at(AS_OF.minusDays(500)) : null;
        return new InsightFacts.Health(UUID.nameUUIDFromBytes(code.getBytes()), null, code, name, category, null,
                null, "个", new BigDecimal(qty), known ? new BigDecimal(weight) : null, estimated,
                new BigDecimal(amount), lastMovement, dims, weighed,
                new BigDecimal(age0), new BigDecimal(age31), new BigDecimal(age91), new BigDecimal(age181),
                new BigDecimal(age365), new BigDecimal(allocated), newestIn,
                new BigDecimal(out90), new BigDecimal(out90), new BigDecimal(out90), picks, null,
                goodsPicks, cumBefore, total);
    }

    private static InsightFacts.Cycle cycle(UUID warehouse, String code, LocalDate lastCounted, LocalDate firstMovement,
                                            long residuals, boolean active30, String tier, String evidence,
                                            BigDecimal weight, boolean exact, long picks, long cumBefore, long total) {
        return new InsightFacts.Cycle(warehouse, "仓" + warehouse.toString().substring(0, 4),
                UUID.nameUUIDFromBytes(code.getBytes()), code, code, null, null, "个", new BigDecimal("10"), weight,
                false, lastCounted, firstMovement, null, residuals, active30, tier, evidence, exact, picks, cumBefore,
                total);
    }

    private static WeightParams params(String basis, String evidence, String tier, BigDecimal unitWeight,
                                       boolean learningEnabled) {
        return new WeightParams("k", UUID.randomUUID(), basis, false, evidence, unitWeight, null, null, 0.02, null,
                tier, 0.03, 5, 20, null, new BigDecimal("3.000"), null, null, null, false, null, null, null, "COUNT",
                learningEnabled, 0.00005);
    }

    private static OffsetDateTime at(LocalDate day) {
        return BusinessTime.startOfDay(day).plusHours(10);
    }
}
