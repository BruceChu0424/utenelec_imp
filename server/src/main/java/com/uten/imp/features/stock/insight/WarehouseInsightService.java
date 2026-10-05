package com.uten.imp.features.stock.insight;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.report.ReportTotal;
import com.uten.imp.common.report.ReportTotalsCalculator;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.insight.WarehouseInsightSql.Scope;
import com.uten.imp.features.stock.insight.WarehouseInsightSql.Window;
import com.uten.imp.features.stock.insight.dto.CycleCountRow;
import com.uten.imp.features.stock.insight.dto.GoodsInsight;
import com.uten.imp.features.stock.insight.dto.HealthOverview;
import com.uten.imp.features.stock.insight.dto.HealthRow;
import com.uten.imp.features.stock.insight.dto.LearningRow;
import com.uten.imp.features.stock.insight.dto.WarehouseHealthPage;
import com.uten.imp.features.stock.insight.dto.WeightAlertPage;
import com.uten.imp.features.stock.insight.dto.WeightAlertRow;
import com.uten.imp.features.stock.insight.dto.WeightPartySummary;
import com.uten.imp.features.stock.weight.GoodsWeightEstimateService;
import com.uten.imp.features.stock.weight.SourceKind;
import com.uten.imp.features.stock.weight.dto.WeightParams;
import com.uten.imp.features.stock.weight.dto.WeightParamsRequest;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 仓库智能分析 (ADR-135 §7.4, /api/stock/insights): 呆滞与库龄、盘点建议、称重异常、单重学习清单、单货品指标条。
 *
 * <p>每个接口的重查询只跑一次 (所选范围内全部行取回内存), 排序/分页/合计在内存里做
 * ({@link ReportTotalsCalculator#computeFromRows}), 不为计数、合计、筛选桶把重查询再跑一遍;
 * as-of 日期取 {@link BusinessTime#today()} 作参数 (容器时钟不可信, 不用数据库 current_date)。
 * 金额只给 goods:cost:view, 按金额排序而无权限时 403。口径定义见 {@link WarehouseInsightDefinitions}。
 */
@Service
public class WarehouseInsightService {

    private static final int PARTY_SUMMARY_LIMIT = 50;
    private static final String REGIME = "REGIME";

    private final NamedParameterJdbcTemplate db;
    private final StockCostMasker costMasker;
    private final GoodsWeightEstimateService weights;
    private final WarehouseTaskScopePort warehouseScopes;

    public WarehouseInsightService(NamedParameterJdbcTemplate db, StockCostMasker costMasker,
                                   GoodsWeightEstimateService weights, WarehouseTaskScopePort warehouseScopes) {
        this.db = db;
        this.costMasker = costMasker;
        this.weights = weights;
        this.warehouseScopes = warehouseScopes;
    }

    // ================================================================== 呆滞与库龄

    @Transactional(readOnly = true)
    public WarehouseHealthPage health(UUID scopeWarehouseId, UUID categoryId, String keyword,
                                      String abc, boolean onlyDead, boolean agedOver180, int page, int size,
                                      String sort, String order) {
        return health(scopeWarehouseId, categoryId, keyword, abc, onlyDead, agedOver180, page, size,
                sort, order, BusinessTime.today());
    }

    WarehouseHealthPage health(UUID scopeWarehouseId, UUID categoryId, String keyword, String abc,
                               boolean onlyDead, boolean agedOver180, int page, int size, String sort, String order,
                               LocalDate asOf) {
        boolean canViewCost = costMasker.canView();
        if (!canViewCost && "amountLocal".equals(sort)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无查看货品成本权限(" + StockCostMasker.PERMISSION + ")");
        }
        if (abc != null && !abc.isBlank() && !Set.of("A", "B", "C", "N").contains(abc.strip().toUpperCase())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "ABC 分类只能是 A/B/C/N");
        }
        Scope scope = scope(scopeWarehouseId);
        MapSqlParameterSource params = WarehouseInsightSql.params(scope, Window.of(asOf));
        List<InsightFacts.Health> facts = db.query(WarehouseInsightSql.health(scope, false), params,
                (rs, i) -> healthFact(rs));
        List<HealthRow> rows = facts.stream()
                .map(f -> WarehouseInsightDefinitions.healthRow(f, asOf, canViewCost)).toList();
        HealthOverview overview = overview(scope, params, facts, rows, canViewCost);

        WarehouseInsightDefinitions.HealthFilter filter = new WarehouseInsightDefinitions.HealthFilter(
                categoryId == null ? null : categorySubtree(categoryId), keyword, abc, onlyDead, agedOver180);
        List<HealthRow> filtered = new ArrayList<>();
        for (int i = 0; i < facts.size(); i++) {
            if (WarehouseInsightDefinitions.matches(filter, facts.get(i), rows.get(i))) {
                filtered.add(rows.get(i));
            }
        }
        filtered.sort(WarehouseInsightDefinitions.healthOrder(sort, order));
        List<ReportTotal> totals = ReportTotalsCalculator.computeFromRows(
                filtered.stream().map(WarehouseInsightDefinitions::totalsRow).toList(),
                WarehouseInsightDefinitions.healthTotalSpecs(canViewCost));
        return new WarehouseHealthPage(WarehouseInsightDefinitions.page(filtered, page, size), totals, overview);
    }

    private HealthOverview overview(Scope scope, MapSqlParameterSource params, List<InsightFacts.Health> facts,
                                    List<HealthRow> rows, boolean canViewCost) {
        WarehouseInsightDefinitions.OverviewCounts counts = db.queryForObject(WarehouseInsightSql.overview(scope),
                params, (rs, i) -> new WarehouseInsightDefinitions.OverviewCounts(rs.getLong("movements_30d"),
                        rs.getLong("alerts_30d"), rs.getLong("receipt_short_30d"), rs.getLong("draw_over_30d"),
                        rs.getLong("needs_sample")));
        return WarehouseInsightDefinitions.overview(facts, rows, canViewCost,
                counts == null ? new WarehouseInsightDefinitions.OverviewCounts(0, 0, 0, 0, 0) : counts);
    }

    // ================================================================== 盘点建议

    @Transactional(readOnly = true)
    public PageResponse<CycleCountRow> cycleCount(UUID scopeWarehouseId, boolean showAll, int page, int size) {
        return cycleCount(scopeWarehouseId, showAll, page, size, BusinessTime.today());
    }

    PageResponse<CycleCountRow> cycleCount(UUID scopeWarehouseId, boolean showAll, int page, int size,
                                           LocalDate asOf) {
        Scope scope = scope(scopeWarehouseId);
        MapSqlParameterSource params = WarehouseInsightSql.params(scope, Window.of(asOf));
        List<CycleCountRow> rows = new ArrayList<>(db.query(WarehouseInsightSql.cycleCount(scope), params,
                        (rs, i) -> cycleFact(rs)).stream()
                .map(f -> WarehouseInsightDefinitions.cycleRow(f, asOf))
                .filter(Objects::nonNull)
                .toList());
        rows.sort(WarehouseInsightDefinitions.CYCLE_ORDER);
        List<CycleCountRow> shown = showAll ? rows
                : WarehouseInsightDefinitions.capPerWarehouse(rows, WarehouseInsightDefinitions.CYCLE_CAP_PER_WAREHOUSE);
        return WarehouseInsightDefinitions.page(shown, page, size);
    }

    // ================================================================== 称重异常

    @Transactional(readOnly = true)
    public WeightAlertPage weightAlerts(int days, String kind, UUID supplierId, int page, int size) {
        return weightAlerts(days, kind, supplierId, page, size, BusinessTime.today());
    }

    WeightAlertPage weightAlerts(int days, String kind, UUID supplierId, int page, int size, LocalDate asOf) {
        if (days < 1 || days > 365) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "天数只能在 1 到 365 之间");
        }
        Window window = Window.of(asOf);
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("since", window.since(days))
                .addValue("asOfEnd", window.asOfEnd());
        if (supplierId != null) {
            params.addValue("supplier", supplierId);
        }
        boolean regimes = true;
        boolean observations = true;
        boolean kindFilter = false;
        if (kind != null && !kind.isBlank()) {
            if (REGIME.equalsIgnoreCase(kind.strip())) {
                observations = false;
            } else {
                SourceKind parsed;
                try {
                    parsed = SourceKind.parse(kind);
                } catch (IllegalArgumentException unknown) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "不认识的称重来源: " + kind.strip());
                }
                regimes = false;
                kindFilter = true;
                params.addValue("kind", parsed.name());
            }
        }
        List<WeightAlertRow> rows = new ArrayList<>(db.query(
                WarehouseInsightSql.alerts(observations, kindFilter, regimes, supplierId != null), params,
                (rs, i) -> WarehouseInsightDefinitions.alertRow(alertFact(rs))));
        rows.sort(WarehouseInsightDefinitions.ALERT_ORDER);

        List<WeightPartySummary> suppliers = new ArrayList<>();
        List<WeightPartySummary> workshops = new ArrayList<>();
        db.query(WarehouseInsightSql.partySummary(supplierId != null), params, rs -> {
            WeightPartySummary summary = new WeightPartySummary(rs.getObject("party_id", UUID.class),
                    rs.getString("party_name"), rs.getLong("events"), rs.getLong("flagged"),
                    scale2(rs.getBigDecimal("avg_pct")), rs.getBigDecimal("kg"));
            ("SUPPLIER".equals(rs.getString("dim")) ? suppliers : workshops).add(summary);
        });
        Comparator<WeightPartySummary> worstFirst = Comparator.comparingLong(WeightPartySummary::flagged).reversed()
                .thenComparing(WeightPartySummary::kg, Comparator.nullsLast(Comparator.reverseOrder()))
                .thenComparing(WeightPartySummary::partyName, Comparator.nullsLast(Comparator.naturalOrder()));
        suppliers.sort(worstFirst);
        workshops.sort(worstFirst);
        return new WeightAlertPage(WarehouseInsightDefinitions.page(rows, page, size),
                suppliers.subList(0, Math.min(PARTY_SUMMARY_LIMIT, suppliers.size())),
                workshops.subList(0, Math.min(PARTY_SUMMARY_LIMIT, workshops.size())));
    }

    // ================================================================== 单重学习清单

    @Transactional(readOnly = true)
    public PageResponse<LearningRow> learning(String filter, String keyword, int page, int size) {
        return learning(filter, keyword, page, size, BusinessTime.today());
    }

    PageResponse<LearningRow> learning(String filter, String keyword, int page, int size, LocalDate asOf) {
        WarehouseInsightDefinitions.LearningFilter mode;
        try {
            mode = WarehouseInsightDefinitions.LearningFilter.parse(filter);
        } catch (IllegalArgumentException unknown) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不认识的筛选: " + filter);
        }
        Window window = Window.of(asOf);
        boolean hasKeyword = keyword != null && !keyword.isBlank();
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("t90", window.t90())
                .addValue("asOfEnd", window.asOfEnd());
        if (hasKeyword) {
            params.addValue("kw", "%" + keyword.strip() + "%");
        }
        List<InsightFacts.Learning> facts = db.query(WarehouseInsightSql.learning(hasKeyword), params,
                (rs, i) -> learningFact(rs));
        Map<UUID, WeightParams> resolved = resolve(facts.stream().map(InsightFacts.Learning::goodsId).toList());
        List<LearningRow> rows = new ArrayList<>();
        for (InsightFacts.Learning fact : facts) {
            WeightParams p = resolved.get(fact.goodsId());
            if (p == null || "EXACT".equals(p.basis())) {
                continue;
            }
            LearningRow row = WarehouseInsightDefinitions.learningRow(fact, p);
            if (WarehouseInsightDefinitions.matches(mode, row)) {
                rows.add(row);
            }
        }
        rows.sort(WarehouseInsightDefinitions.LEARNING_ORDER);
        return WarehouseInsightDefinitions.page(rows, page, size);
    }

    /** 与 /api/stock/weight/params 同一解析 (货品级, 不带供应商)。 */
    private Map<UUID, WeightParams> resolve(List<UUID> goodsIds) {
        if (goodsIds.isEmpty()) {
            return Map.of();
        }
        List<WeightParamsRequest.Line> lines = goodsIds.stream()
                .map(id -> new WeightParamsRequest.Line(id, null)).toList();
        Map<UUID, WeightParams> byGoods = new HashMap<>();
        for (WeightParams p : weights.params(lines).items()) {
            byGoods.put(p.goodsId(), p);
        }
        return byGoods;
    }

    // ================================================================== 单货品指标条

    @Transactional(readOnly = true)
    public GoodsInsight goods(UUID goodsId) {
        return goods(goodsId, BusinessTime.today());
    }

    GoodsInsight goods(UUID goodsId, LocalDate asOf) {
        List<String> unit = db.query("SELECT u.name FROM goods g\n" + WarehouseInsightSql.unitLateral("g")
                        + "WHERE g.id = :goods", new MapSqlParameterSource("goods", goodsId),
                (rs, i) -> rs.getString(1));
        if (unit.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        }
        Scope scope = Scope.defaultScope();
        MapSqlParameterSource params = WarehouseInsightSql.params(scope, Window.of(asOf)).addValue("goods", goodsId);
        List<InsightFacts.Health> facts = db.query(WarehouseInsightSql.health(scope, true), params,
                (rs, i) -> healthFact(rs));
        WeightParams resolved = resolve(List.of(goodsId)).get(goodsId);
        return WarehouseInsightDefinitions.goodsInsight(goodsId, unit.get(0), facts, resolved, asOf);
    }

    // ================================================================== helpers

    /**
     * 仓库范围(ADR-149, 与仓库任务中心同一判定): 服务端按本人仓库数据范围强制; scopeWarehouseId = 在可选范围
     * 内挑一个仓(含下级), 越界 403。不限范围(主管、或还没登记任何子仓负责人)时 = 默认范围。
     */
    private Scope scope(UUID scopeWarehouseId) {
        WarehouseTaskScopePort.WarehouseTaskScope resolved = warehouseScopes.current(scopeWarehouseId);
        return resolved.active() ? new Scope(Set.copyOf(resolved.warehouseIds())) : Scope.defaultScope();
    }

    private Set<UUID> categorySubtree(UUID categoryId) {
        return new HashSet<>(db.queryForList(WarehouseInsightSql.CATEGORY_SUBTREE,
                new MapSqlParameterSource("categoryId", categoryId), UUID.class));
    }

    private static InsightFacts.Health healthFact(ResultSet rs) throws SQLException {
        return new InsightFacts.Health(
                rs.getObject("goods_id", UUID.class), rs.getObject("color_id", UUID.class),
                rs.getString("code"), rs.getString("name"), rs.getObject("category_id", UUID.class),
                rs.getString("model"), rs.getString("color_name"), rs.getString("unit_name"),
                rs.getBigDecimal("qty"), rs.getBigDecimal("weight_kg"), rs.getBoolean("weight_estimated"),
                rs.getBigDecimal("amount_local"), rs.getObject("last_movement_at", OffsetDateTime.class),
                rs.getLong("dims"), rs.getLong("dims_weighed"),
                rs.getBigDecimal("age_0_30"), rs.getBigDecimal("age_31_90"), rs.getBigDecimal("age_91_180"),
                rs.getBigDecimal("age_181_365"), rs.getBigDecimal("age_over_365"), rs.getBigDecimal("allocated"),
                rs.getObject("newest_in", OffsetDateTime.class),
                rs.getBigDecimal("out_30"), rs.getBigDecimal("out_90"), rs.getBigDecimal("out_365"),
                rs.getLong("picks_90"), rs.getObject("last_out_at", OffsetDateTime.class),
                rs.getLong("goods_picks"), rs.getLong("picks_cum_before"), rs.getLong("picks_total"));
    }

    private static InsightFacts.Cycle cycleFact(ResultSet rs) throws SQLException {
        return new InsightFacts.Cycle(
                rs.getObject("warehouse_id", UUID.class), rs.getString("warehouse_name"),
                rs.getObject("goods_id", UUID.class), rs.getString("code"), rs.getString("name"),
                rs.getObject("color_id", UUID.class), rs.getString("color_name"), rs.getString("unit_name"),
                rs.getBigDecimal("qty"), rs.getBigDecimal("weight_kg"), rs.getBoolean("weight_estimated"),
                rs.getObject("last_counted_on", LocalDate.class), rs.getObject("first_movement_on", LocalDate.class),
                rs.getObject("first_balance_on", LocalDate.class),
                rs.getLong("residuals_90"), rs.getBoolean("active_30"), rs.getString("estimate_tier"),
                rs.getString("estimate_evidence"), rs.getBoolean("exact"),
                rs.getLong("goods_picks"), rs.getLong("picks_cum_before"), rs.getLong("picks_total"));
    }

    private static InsightFacts.Alert alertFact(ResultSet rs) throws SQLException {
        return new InsightFacts.Alert(
                rs.getString("row_type"), rs.getObject("id", UUID.class),
                rs.getObject("observed_at", OffsetDateTime.class), rs.getObject("goods_id", UUID.class),
                rs.getString("code"), rs.getString("name"), rs.getString("unit_name"),
                rs.getString("base_unit_dimension"), rs.getString("color_name"),
                rs.getObject("warehouse_id", UUID.class), rs.getString("warehouse_name"), rs.getString("source_kind"),
                rs.getObject("supplier_id", UUID.class), rs.getString("supplier_name"),
                rs.getString("counterpart_kind"), rs.getObject("counterpart_id", UUID.class),
                rs.getString("counterpart_name"), rs.getString("source_doc_type"),
                rs.getObject("source_doc_id", UUID.class), rs.getString("source_doc_code"), rs.getString("bill_no"),
                rs.getBigDecimal("qty_base"), rs.getBigDecimal("weight_kg"),
                rs.getBigDecimal("expected_unit_weight_kg"), rs.getBigDecimal("expected_weight_kg"),
                rs.getBigDecimal("deviation_pct"), rs.getString("alert_level"), rs.getString("estimate_tier_used"),
                rs.getString("estimate_basis_used"), rs.getBigDecimal("unit_weight_kg"));
    }

    private static InsightFacts.Learning learningFact(ResultSet rs) throws SQLException {
        return new InsightFacts.Learning(
                rs.getObject("goods_id", UUID.class), rs.getString("code"), rs.getString("name"),
                rs.getString("model"), rs.getString("unit_name"), rs.getBigDecimal("master_kg"),
                rs.getLong("movements_90d"), rs.getObject("last_movement_at", OffsetDateTime.class),
                rs.getLong("observations"), rs.getBigDecimal("qty"),
                rs.getObject("n_ref", Integer.class), rs.getObject("n_draw", Integer.class));
    }

    private static BigDecimal scale2(BigDecimal value) {
        return value == null ? null : value.setScale(2, RoundingMode.HALF_UP);
    }
}
