package com.uten.imp.features.stock.insight;

import com.uten.imp.common.report.ReportTotalsCalculator;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.stock.insight.dto.CycleCountRow;
import com.uten.imp.features.stock.insight.dto.GoodsInsight;
import com.uten.imp.features.stock.insight.dto.HealthOverview;
import com.uten.imp.features.stock.insight.dto.HealthRow;
import com.uten.imp.features.stock.insight.dto.LearningRow;
import com.uten.imp.features.stock.insight.dto.WeightAlertRow;
import com.uten.imp.features.stock.weight.dto.WeightParams;
import org.springframework.data.domain.PageRequest;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;

/**
 * 库存分析的口径 (ADR-135 §7.4, 读侧评审 §C-§G, 产品评审 §16), 纯函数: SQL 只取事实, 这里定义派生指标、
 * 筛选、排序、分页与合计, 便于用内存行直接验证。
 *
 * <ul>
 *   <li>ABC: 按近 90 天出库次数 (红冲冲减) 在所选范围的全部货品里倒序排名, 排在它前面的累计 &lt; 80% 为 A、
 *       &lt; 95% 为 B、其余 C; 没有出库为 N。</li>
 *   <li>呆滞: 有库存、近 90 天没有消耗、而且仍有存量的最新入库批次也早于 90 天 (没有入库记录视为很早)。</li>
 *   <li>日均消耗 = 近 90 天消耗 / 90; 约可用天数 = 库存 / 日均 (近 90 天没有消耗时不给)。</li>
 *   <li>盘点建议按仓库 × 货品 × 颜色出行 (与盘点单明细同粒度); 周期按货品 ABC: A 30 / B 90 / C、N 180 天; 优先级 = 到期比例 + 近期尾差 0.5 + 重量为估算 0.3 + 重量未知 0.3
 *       + 近 30 天有动态却单重未学准 0.5; 到期或有加分才建议; 默认每仓最多 20 条。</li>
 * </ul>
 */
final class WarehouseInsightDefinitions {

    static final int DEAD_DAYS = 90;
    static final int CYCLE_CAP_PER_WAREHOUSE = 20;
    static final String REASON_DUE = "DUE";
    static final String REASON_RESIDUAL = "RESIDUAL";
    static final String REASON_ESTIMATED_WEIGHT = "ESTIMATED_WEIGHT";
    static final String REASON_UNKNOWN_WEIGHT = "UNKNOWN_WEIGHT";
    static final String REASON_RED_TIER = "RED_TIER";

    private static final BigDecimal HUNDRED = BigDecimal.valueOf(100);
    private static final BigDecimal NINETY = BigDecimal.valueOf(90);
    private static final int QTY_SCALE = 4;

    private WarehouseInsightDefinitions() {
    }

    // ================================================================== 通用

    /** A / B / C / N。 */
    static String abc(long picks, long cumBefore, long total) {
        if (picks <= 0 || total <= 0) {
            return "N";
        }
        if (cumBefore * 100 < total * 80) {
            return "A";
        }
        if (cumBefore * 100 < total * 95) {
            return "B";
        }
        return "C";
    }

    /** 盘点周期天数。 */
    static int countIntervalDays(String abc) {
        return switch (abc) {
            case "A" -> 30;
            case "B" -> 90;
            default -> 180;
        };
    }

    /** 业务日 (上海时区) 相隔天数, 不为负; at 为 null 返回 null。 */
    static Integer daysSince(OffsetDateTime at, LocalDate asOf) {
        if (at == null) {
            return null;
        }
        return (int) Math.max(0, ChronoUnit.DAYS.between(at.atZoneSameInstant(BusinessTime.ZONE).toLocalDate(), asOf));
    }

    static BigDecimal avgDailyOut90(BigDecimal out90) {
        return nz(out90).divide(NINETY, QTY_SCALE, RoundingMode.HALF_UP);
    }

    static BigDecimal daysOfCover(BigDecimal qty, BigDecimal out90) {
        if (out90 == null || out90.signum() <= 0) {
            return null;
        }
        return nz(qty).multiply(NINETY).divide(out90, 1, RoundingMode.HALF_UP);
    }

    static boolean dead(BigDecimal qty, BigDecimal out90, OffsetDateTime newestIn, LocalDate asOf) {
        if (qty == null || qty.signum() <= 0 || (out90 != null && out90.signum() > 0)) {
            return false;
        }
        return newestIn == null || newestIn.isBefore(BusinessTime.startOfDay(asOf.minusDays(DEAD_DAYS)));
    }

    /** 分不到入库批次的现存量 (期初, 无入库记录)。 */
    static BigDecimal ageUnknown(BigDecimal qty, BigDecimal allocated) {
        BigDecimal rest = nz(qty).subtract(nz(allocated));
        return rest.signum() > 0 ? rest : BigDecimal.ZERO;
    }

    /** 内存分页 (页码从 1 起, 每页最多 100 行)。 */
    static <T> PageResponse<T> page(List<T> all, int page, int size) {
        PageRequest paging = Pageables.of(page, size);
        int from = (int) Math.min(all.size(), paging.getOffset());
        int to = Math.min(all.size(), from + paging.getPageSize());
        int totalPages = (all.size() + paging.getPageSize() - 1) / paging.getPageSize();
        return new PageResponse<>(List.copyOf(all.subList(from, to)), paging.getPageNumber() + 1,
                paging.getPageSize(), all.size(), totalPages);
    }

    // ================================================================== 呆滞与库龄

    static HealthRow healthRow(InsightFacts.Health f, LocalDate asOf, boolean canViewCost) {
        return new HealthRow(f.goodsId(), f.code(), f.name(), f.colorId(), f.colorName(), f.unitName(),
                f.qty(), f.weightKg(), f.weightKg() != null && f.weightEstimated(),
                f.newestIn(), f.lastOutAt(), daysSince(f.lastMovementAt(), asOf),
                nz(f.age0to30()), nz(f.age31to90()), nz(f.age91to180()), nz(f.age181to365()), nz(f.ageOver365()),
                ageUnknown(f.qty(), f.allocated()),
                nz(f.out30()), nz(f.out90()), nz(f.out365()),
                avgDailyOut90(f.out90()), daysOfCover(f.qty(), f.out90()), f.picks90(),
                abc(f.goodsPicks(), f.picksCumBefore(), f.picksTotal()),
                dead(f.qty(), f.out90(), f.newestIn(), asOf),
                canViewCost ? f.amountLocal() : null, !canViewCost);
    }

    /** 顶部指标 (整个范围, 不受表格筛选影响)。 */
    static HealthOverview overview(List<InsightFacts.Health> facts, List<HealthRow> rows, boolean canViewCost,
                                   OverviewCounts counts) {
        BigDecimal knownKg = BigDecimal.ZERO;
        long unknown = 0;
        long dims = 0;
        long weighed = 0;
        for (InsightFacts.Health f : facts) {
            dims += f.dims();
            weighed += f.dimsWeighed();
        }
        BigDecimal qty = BigDecimal.ZERO;
        BigDecimal aged = BigDecimal.ZERO;
        long dead = 0;
        BigDecimal deadAmount = BigDecimal.ZERO;
        for (HealthRow row : rows) {
            if (row.weightKg() == null) {
                unknown++;
            } else {
                knownKg = knownKg.add(row.weightKg());
            }
            qty = qty.add(nz(row.qty()));
            aged = aged.add(row.age181_365()).add(row.ageOver365()).add(row.ageUnknown());
            if (row.dead()) {
                dead++;
                deadAmount = deadAmount.add(nz(row.amountLocal()));
            }
        }
        return new HealthOverview(rows.size(), knownKg, unknown, pct(BigDecimal.valueOf(weighed), BigDecimal.valueOf(dims)),
                dead, pct(aged, qty), counts.movements30d(), counts.alerts30d(), counts.receiptShort30d(),
                counts.drawOver30d(), counts.needsSample(), canViewCost ? deadAmount : null);
    }

    /**
     * 顶部指标里不依赖表格行、由一条 SQL 直接数出来的数 (口径见 {@link WarehouseInsightSql#overview})。
     * 来料少数 / 领料超发与 {@link #alertKind} 的 RECEIPT_SHORT / DRAW_OVER 同一划分。
     */
    record OverviewCounts(long movements30d, long alerts30d, long receiptShort30d, long drawOver30d,
                          long needsSample) {
    }

    /** 表格筛选 (分类子树已展开成集合; 关键字匹配编号/名称/型号, 不分大小写)。 */
    record HealthFilter(Set<UUID> categories, String keyword, String abc, boolean onlyDead, boolean agedOver180) {
    }

    static boolean matches(HealthFilter filter, InsightFacts.Health fact, HealthRow row) {
        if (filter.categories() != null && !filter.categories().contains(fact.categoryId())) {
            return false;
        }
        if (filter.keyword() != null && !filter.keyword().isBlank()) {
            String kw = filter.keyword().strip().toLowerCase(Locale.ROOT);
            if (!contains(fact.code(), kw) && !contains(fact.name(), kw) && !contains(fact.model(), kw)) {
                return false;
            }
        }
        if (filter.abc() != null && !filter.abc().isBlank()
                && !filter.abc().strip().equalsIgnoreCase(row.abc())) {
            return false;
        }
        if (filter.onlyDead() && !row.dead()) {
            return false;
        }
        return !filter.agedOver180()
                || row.age181_365().add(row.ageOver365()).add(row.ageUnknown()).signum() > 0;
    }

    /** 排序白名单 (前端列 key → 取值); 不认识的 key 用默认 (距最后变动天数倒序)。 */
    static final Map<String, Function<HealthRow, ? extends Comparable<?>>> HEALTH_SORT = healthSortKeys();

    private static Map<String, Function<HealthRow, ? extends Comparable<?>>> healthSortKeys() {
        Map<String, Function<HealthRow, ? extends Comparable<?>>> keys = new LinkedHashMap<>();
        keys.put("qty", HealthRow::qty);
        keys.put("weightKg", HealthRow::weightKg);
        keys.put("idleDays", HealthRow::idleDays);
        keys.put("lastInAt", HealthRow::lastInAt);
        keys.put("lastOutAt", HealthRow::lastOutAt);
        keys.put("age0_30", HealthRow::age0_30);
        keys.put("age31_90", HealthRow::age31_90);
        keys.put("age91_180", HealthRow::age91_180);
        keys.put("age181_365", HealthRow::age181_365);
        keys.put("ageOver365", HealthRow::ageOver365);
        keys.put("ageUnknown", HealthRow::ageUnknown);
        keys.put("out30", HealthRow::out30);
        keys.put("out90", HealthRow::out90);
        keys.put("out365", HealthRow::out365);
        keys.put("avgDailyOut90", HealthRow::avgDailyOut90);
        keys.put("daysOfCover", HealthRow::daysOfCover);
        keys.put("picks90", HealthRow::picks90);
        keys.put("abc", HealthRow::abc);
        keys.put("code", HealthRow::code);
        keys.put("name", HealthRow::name);
        keys.put("amountLocal", HealthRow::amountLocal);
        return Map.copyOf(keys);
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    static Comparator<HealthRow> healthOrder(String sort, String order) {
        Function<HealthRow, ? extends Comparable<?>> key = sort == null ? null : HEALTH_SORT.get(sort);
        boolean asc;
        if (key == null) {
            key = HealthRow::idleDays;
            asc = false;
        } else {
            asc = "asc".equalsIgnoreCase(order);
        }
        Comparator<Comparable> natural = Comparator.naturalOrder();
        Comparator<Comparable> direction = asc ? natural : natural.reversed();
        Function<HealthRow, Comparable> extractor = (Function) key;
        return Comparator.comparing(extractor, Comparator.nullsLast(direction))
                .thenComparing(HealthRow::code, Comparator.nullsLast(Comparator.naturalOrder()))
                .thenComparing(HealthRow::colorName, Comparator.nullsFirst(Comparator.naturalOrder()));
    }

    /**
     * 合计声明: 数量与近 90 天消耗按单位分组; 重量千克不分组, 另带未称/估算两个计数伴随项;
     * 金额只在有成本权限时声明。
     */
    static List<ReportTotalsCalculator.Spec> healthTotalSpecs(boolean canViewCost) {
        List<ReportTotalsCalculator.Spec> specs = new ArrayList<>(List.of(
                new ReportTotalsCalculator.Spec("qty", "合计库存数量", ReportTotalsCalculator.TYPE_NUMBER, "unitName"),
                new ReportTotalsCalculator.Spec("weightKg", "合计库存重量", ReportTotalsCalculator.TYPE_WEIGHT, null),
                new ReportTotalsCalculator.Spec("weightKg_unknown_rows", "重量未知",
                        ReportTotalsCalculator.TYPE_COUNT, null),
                new ReportTotalsCalculator.Spec("weightKg_estimated_rows", "重量含估算",
                        ReportTotalsCalculator.TYPE_COUNT, null),
                new ReportTotalsCalculator.Spec("out90", "合计近90天消耗", ReportTotalsCalculator.TYPE_NUMBER,
                        "unitName")));
        if (canViewCost) {
            specs.add(new ReportTotalsCalculator.Spec("amountLocal", "合计库存金额",
                    ReportTotalsCalculator.TYPE_MONEY, null));
        }
        return List.copyOf(specs);
    }

    /** 合计用的行 Map (key 与 {@link #healthTotalSpecs} 一致)。 */
    static Map<String, Object> totalsRow(HealthRow row) {
        Map<String, Object> values = new HashMap<>();
        values.put("qty", row.qty());
        values.put("unitName", row.unitName());
        values.put("weightKg", row.weightKg());
        values.put("weightKg_unknown_rows", row.weightKg() == null ? 1 : 0);
        values.put("weightKg_estimated_rows", row.weightEstimated() ? 1 : 0);
        values.put("out90", row.out90());
        values.put("amountLocal", row.amountLocal());
        return values;
    }

    // ================================================================== 盘点建议

    /** 一行盘点建议; 既没到期也没有加分原因时返回 null (不建议)。 */
    static CycleCountRow cycleRow(InsightFacts.Cycle f, LocalDate asOf) {
        String abc = abc(f.goodsPicks(), f.picksCumBefore(), f.picksTotal());
        LocalDate baseline = f.lastCountedOn() != null ? f.lastCountedOn()
                : f.firstMovementOn() != null ? f.firstMovementOn()
                : f.firstBalanceOn() != null ? f.firstBalanceOn() : asOf;
        long days = Math.max(0, ChronoUnit.DAYS.between(baseline, asOf));
        BigDecimal due = BigDecimal.valueOf(days).divide(BigDecimal.valueOf(countIntervalDays(abc)), 2,
                RoundingMode.HALF_UP);
        List<String> reasons = new ArrayList<>();
        BigDecimal score = due;
        if (due.compareTo(BigDecimal.ONE) >= 0) {
            reasons.add(REASON_DUE);
        }
        if (f.residuals90() > 0) {
            reasons.add(REASON_RESIDUAL);
            score = score.add(new BigDecimal("0.5"));
        }
        if (!f.exact() && f.weightKg() != null && f.weightEstimated()) {
            reasons.add(REASON_ESTIMATED_WEIGHT);
            score = score.add(new BigDecimal("0.3"));
        }
        if (!f.exact() && f.weightKg() == null) {
            reasons.add(REASON_UNKNOWN_WEIGHT);
            score = score.add(new BigDecimal("0.3"));
        }
        if (!f.exact() && f.active30() && ("RED".equals(f.estimateTier()) || "CONFLICT".equals(f.estimateEvidence()))) {
            reasons.add(REASON_RED_TIER);
            score = score.add(new BigDecimal("0.5"));
        }
        if (reasons.isEmpty()) {
            return null;
        }
        return new CycleCountRow(f.warehouseId(), f.warehouseName(), f.goodsId(), f.code(), f.name(),
                f.colorId(), f.colorName(), f.unitName(), abc, f.lastCountedOn(), days, List.copyOf(reasons), score, f.qty(), f.weightKg(),
                f.weightKg() != null && f.weightEstimated());
    }

    /** 优先级分倒序, 再按距上次盘点天数倒序、编号、颜色 (无颜色在前)、仓库。 */
    static final Comparator<CycleCountRow> CYCLE_ORDER = Comparator
            .comparing(CycleCountRow::score, Comparator.reverseOrder())
            .thenComparing(CycleCountRow::daysSince, Comparator.reverseOrder())
            .thenComparing(CycleCountRow::code, Comparator.nullsLast(Comparator.naturalOrder()))
            .thenComparing(CycleCountRow::colorName, Comparator.nullsFirst(Comparator.naturalOrder()))
            .thenComparing(CycleCountRow::warehouseName, Comparator.nullsLast(Comparator.naturalOrder()));

    /** 每仓最多保留 cap 条 (rows 须已按优先级排好)。 */
    static List<CycleCountRow> capPerWarehouse(List<CycleCountRow> sorted, int cap) {
        Map<UUID, Integer> taken = new HashMap<>();
        List<CycleCountRow> kept = new ArrayList<>();
        for (CycleCountRow row : sorted) {
            int n = taken.merge(row.warehouseId(), 1, Integer::sum);
            if (n <= cap) {
                kept.add(row);
            }
        }
        return kept;
    }

    // ================================================================== 称重异常

    static String alertKind(String rowType, String sourceKind, BigDecimal deviationPct) {
        if ("REGIME".equals(rowType)) {
            return "REGIME_CHANGE";
        }
        boolean light = deviationPct != null && deviationPct.signum() < 0;
        return switch (sourceKind == null ? "" : sourceKind) {
            case "RECEIPT" -> light ? "RECEIPT_SHORT" : "RECEIPT_OVER";
            case "DRAW" -> light ? "DRAW_SHORT" : "DRAW_OVER";
            case "RETURN" -> "RETURN_MISMATCH";
            case "COUNT" -> "COUNT_MISMATCH";
            case "FINISHED" -> "FINISHED_MISMATCH";
            case "OTHER_IN" -> "INBOUND_MISMATCH";
            case "SAMPLE" -> "SAMPLE_DEVIATION";
            default -> "OUTBOUND_MISMATCH";
        };
    }

    static String alertLabel(String kind) {
        return switch (kind) {
            case "RECEIPT_SHORT" -> "来料少数";
            case "RECEIPT_OVER" -> "来料多数";
            case "DRAW_OVER" -> "领料超发";
            case "DRAW_SHORT" -> "领料少发";
            case "RETURN_MISMATCH" -> "退料不符";
            case "COUNT_MISMATCH" -> "盘点差异";
            case "FINISHED_MISMATCH" -> "产成品数量不符";
            case "INBOUND_MISMATCH" -> "入库数量不符";
            case "SAMPLE_DEVIATION" -> "称样偏差";
            case "REGIME_CHANGE" -> "单重可能已变化(换批/换料?)";
            default -> "出库数量不符";
        };
    }

    static WeightAlertRow alertRow(InsightFacts.Alert a) {
        String kind = alertKind(a.rowType(), a.sourceKind(), a.deviationPct());
        BigDecimal estimatedQty = a.weightKg() == null || a.expectedUnitWeightKg() == null
                || a.expectedUnitWeightKg().signum() <= 0 ? null
                : a.weightKg().divide(a.expectedUnitWeightKg(), 2, RoundingMode.HALF_UP);
        BigDecimal deviationQty = estimatedQty == null || a.qtyBase() == null ? null
                : estimatedQty.subtract(a.qtyBase());
        return new WeightAlertRow(a.rowType(), a.id(), a.observedAt(), kind, alertLabel(kind), a.goodsId(),
                a.code(), a.name(), a.unitName(), a.baseUnitDimension(), a.colorName(), a.warehouseId(), a.warehouseName(), a.sourceKind(),
                a.supplierId(), a.supplierName(), a.counterpartKind(), a.counterpartId(), a.counterpartName(),
                a.sourceDocType(), a.sourceDocId(), a.sourceDocCode(), a.billNo(), a.qtyBase(), a.weightKg(),
                a.expectedUnitWeightKg(), a.expectedWeightKg(), estimatedQty, deviationQty, a.deviationPct(),
                a.alertLevel(), a.estimateTierUsed(), a.estimateBasisUsed(), a.unitWeightKg());
    }

    /** 最新在前。 */
    static final Comparator<WeightAlertRow> ALERT_ORDER = Comparator
            .comparing(WeightAlertRow::observedAt, Comparator.nullsLast(Comparator.reverseOrder()))
            .thenComparing(WeightAlertRow::id, Comparator.nullsLast(Comparator.naturalOrder()));

    // ================================================================== 单重学习清单

    /** 清单筛选: 需称样 (默认) / 全部 / 与设计单重不符 / 仅按领料推算 / 结论矛盾。 */
    enum LearningFilter {
        NEEDS_SAMPLE, ALL, MASTER_MISMATCH, DRAW_ONLY, CONFLICT;

        static LearningFilter parse(String value) {
            if (value == null || value.isBlank()) {
                return NEEDS_SAMPLE;
            }
            return valueOf(value.strip().toUpperCase(Locale.ROOT));
        }
    }

    /** 学到的单重与设计单重差异超过此比例算「不符」。 */
    static final BigDecimal MASTER_MISMATCH_RATIO = new BigDecimal("0.10");

    static LearningRow learningRow(InsightFacts.Learning f, WeightParams p) {
        return new LearningRow(f.goodsId(), f.code(), f.name(), f.model(), f.unitName(), p.baseUnitDimension(),
                p.basis(), p.evidence(), p.tier(), p.unitWeightKg(), p.relHalfWidth(), p.nInliers(),
                f.nRef(), f.nDraw(), p.lastObservedAt(), p.stale(), p.suggestedSampleSize(), f.masterKg(),
                "LEARNED".equals(p.basis()) ? masterDiffPct(p.unitWeightKg(), f.masterKg()) : null,
                p.drawBiasPct(), f.movements90d(), f.lastMovementAt(), f.qty(), f.observations(),
                p.learningEnabled());
    }

    /** 100 × (学到的 / 设计 − 1), 两者任一缺失返回 null。 */
    static BigDecimal masterDiffPct(BigDecimal learned, BigDecimal master) {
        if (learned == null || master == null || learned.signum() <= 0 || master.signum() <= 0) {
            return null;
        }
        return learned.divide(master, 12, RoundingMode.HALF_UP).subtract(BigDecimal.ONE).multiply(HUNDRED)
                .setScale(2, RoundingMode.HALF_UP);
    }

    static boolean matches(LearningFilter filter, LearningRow row) {
        return switch (filter) {
            case ALL -> true;
            case NEEDS_SAMPLE -> row.movements90d() > 0 && row.learningEnabled()
                    && !"EXACT".equals(row.basis()) && !"MANUAL".equals(row.basis())
                    && (row.tier() == null || "RED".equals(row.tier()) || "CONFLICT".equals(row.evidence()));
            case MASTER_MISMATCH -> "LEARNED".equals(row.basis())
                    && ("GREEN".equals(row.tier()) || "YELLOW".equals(row.tier()))
                    && row.masterDiffPct() != null
                    && row.masterDiffPct().abs().compareTo(MASTER_MISMATCH_RATIO.multiply(HUNDRED)) > 0;
            case DRAW_ONLY -> "DRAW_ONLY".equals(row.evidence());
            case CONFLICT -> "CONFLICT".equals(row.evidence());
        };
    }

    /** 近 90 天动态多的在前, 再按编号。 */
    static final Comparator<LearningRow> LEARNING_ORDER = Comparator
            .comparingLong(LearningRow::movements90d).reversed()
            .thenComparing(LearningRow::code, Comparator.nullsLast(Comparator.naturalOrder()));

    // ================================================================== 单货品指标条

    /** 把一个货品各颜色的事实合成一条指标 (重量任一颜色未知即未知)。 */
    static GoodsInsight goodsInsight(UUID goodsId, String unitName, List<InsightFacts.Health> facts,
                                     WeightParams params, LocalDate asOf) {
        BigDecimal qty = BigDecimal.ZERO;
        BigDecimal weight = BigDecimal.ZERO;
        boolean weightUnknown = false;
        boolean estimated = false;
        BigDecimal a0 = BigDecimal.ZERO;
        BigDecimal a31 = BigDecimal.ZERO;
        BigDecimal a91 = BigDecimal.ZERO;
        BigDecimal a181 = BigDecimal.ZERO;
        BigDecimal a365 = BigDecimal.ZERO;
        BigDecimal unknownAge = BigDecimal.ZERO;
        BigDecimal out90 = BigDecimal.ZERO;
        OffsetDateTime lastIn = null;
        OffsetDateTime lastOut = null;
        OffsetDateTime lastMovement = null;
        String abc = "N";
        for (InsightFacts.Health f : facts) {
            qty = qty.add(nz(f.qty()));
            if (f.weightKg() == null) {
                weightUnknown = true;
            } else {
                weight = weight.add(f.weightKg());
                estimated = estimated || f.weightEstimated();
            }
            a0 = a0.add(nz(f.age0to30()));
            a31 = a31.add(nz(f.age31to90()));
            a91 = a91.add(nz(f.age91to180()));
            a181 = a181.add(nz(f.age181to365()));
            a365 = a365.add(nz(f.ageOver365()));
            unknownAge = unknownAge.add(ageUnknown(f.qty(), f.allocated()));
            out90 = out90.add(nz(f.out90()));
            lastIn = latest(lastIn, f.newestIn());
            lastOut = latest(lastOut, f.lastOutAt());
            lastMovement = latest(lastMovement, f.lastMovementAt());
            abc = abc(f.goodsPicks(), f.picksCumBefore(), f.picksTotal());
        }
        return new GoodsInsight(goodsId, unitName, qty, weightUnknown ? null : weight, !weightUnknown && estimated,
                params == null ? null : params.unitWeightKg(),
                params == null ? null : params.basis(),
                params == null ? null : params.tier(),
                params == null ? null : params.relHalfWidth(),
                lastIn, lastOut, daysSince(lastMovement, asOf), out90, avgDailyOut90(out90),
                daysOfCover(qty, out90), abc, pct(a0, qty), a0, a31, a91, a181, a365, unknownAge);
    }

    // ================================================================== helpers

    static BigDecimal pct(BigDecimal part, BigDecimal whole) {
        if (whole == null || whole.signum() <= 0) {
            return null;
        }
        return nz(part).multiply(HUNDRED).divide(whole, 1, RoundingMode.HALF_UP);
    }

    private static BigDecimal nz(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private static OffsetDateTime latest(OffsetDateTime a, OffsetDateTime b) {
        if (a == null) return b;
        if (b == null) return a;
        return b.isAfter(a) ? b : a;
    }

    private static boolean contains(String text, String lowerKeyword) {
        return text != null && text.toLowerCase(Locale.ROOT).contains(lowerKeyword);
    }
}
