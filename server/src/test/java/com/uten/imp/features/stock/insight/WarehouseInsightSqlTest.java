package com.uten.imp.features.stock.insight;

import com.uten.imp.common.time.BusinessTime;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 库存分析 SQL 形状: as-of 由参数给 (不用 current_date/now()), 默认范围 = 参与核算、非线边仓;
 * 库龄按来源行冲减红冲、剔除范围内部调拨; 消耗含调往范围外的调拨出; 盘点日期取已审盘点单。
 */
class WarehouseInsightSqlTest {

    private static final LocalDate AS_OF = LocalDate.of(2026, 9, 28);

    @Test
    void everyQueryTakesItsAsOfFromParametersNotTheDatabaseClock() {
        WarehouseInsightSql.Scope scope = WarehouseInsightSql.Scope.defaultScope();
        List<String> sqls = List.of(
                WarehouseInsightSql.health(scope, false), WarehouseInsightSql.health(scope, true),
                WarehouseInsightSql.overview(scope), WarehouseInsightSql.cycleCount(scope),
                WarehouseInsightSql.alerts(true, true, true, true), WarehouseInsightSql.partySummary(true),
                WarehouseInsightSql.learning(true));
        for (String sql : sqls) {
            assertThat(sql.toLowerCase()).doesNotContain("current_date").doesNotContain("now()")
                    .doesNotContain("is not distinct from");
        }
        WarehouseInsightSql.Window window = WarehouseInsightSql.Window.of(AS_OF);
        assertThat(window.t30()).isEqualTo(BusinessTime.startOfDay(AS_OF.minusDays(30)));
        assertThat(window.asOfEnd()).isEqualTo(BusinessTime.startOfDay(AS_OF.plusDays(1)));
        assertThat(WarehouseInsightSql.params(scope, window).getParameterNames())
                .contains("t30", "t90", "t180", "t365", "asOfEnd", "consumption", "agingTypes")
                .doesNotContain("scope");
    }

    @Test
    void scopeDefaultsToAccountableNonLineSideWarehouses() {
        assertThat(WarehouseInsightSql.scopeCte(WarehouseInsightSql.Scope.defaultScope()))
                .contains("NOT is_deleted AND is_accountable AND NOT is_line_side").doesNotContain(":scope");
        assertThat(WarehouseInsightSql.scopeCte(new WarehouseInsightSql.Scope(Set.of(UUID.randomUUID()))))
                .contains("id IN (:scope)").doesNotContain("is_line_side");
        assertThat(WarehouseInsightSql.scopeCte(new WarehouseInsightSql.Scope(Set.of(UUID.randomUUID(),
                UUID.randomUUID())))).contains("id IN (:scope) AND is_accountable AND NOT is_line_side");
        // 「我的仓库」解析成空集合 (登记了负责人、本账号却不负责任何仓): 一个仓也没有, 也不绑定空的 IN 列表。
        WarehouseInsightSql.Scope none = new WarehouseInsightSql.Scope(Set.of());
        assertThat(WarehouseInsightSql.scopeCte(none)).contains("WHERE false").doesNotContain(":scope");
        assertThat(WarehouseInsightSql.params(none, WarehouseInsightSql.Window.of(AS_OF)).getParameterNames())
                .doesNotContain("scope");
    }

    @Test
    void overviewSplitsReceiptShortAndDrawOverLikeTheAlertKinds() {
        String sql = WarehouseInsightSql.overview(WarehouseInsightSql.Scope.defaultScope());
        assertThat(sql).contains("FILTER (WHERE o.source_kind = 'RECEIPT' AND o.deviation_pct < 0)")
                .contains("FILTER (WHERE o.source_kind = 'DRAW' AND NOT COALESCE(o.deviation_pct < 0, false))")
                .contains("AS receipt_short_30d").contains("AS draw_over_30d")
                .contains("al.alerts_30d, al.receipt_short_30d, al.draw_over_30d")
                .doesNotContain("o.warehouse_id IN (SELECT id FROM scope_wh)");
        assertThat(WarehouseInsightSql.overview(new WarehouseInsightSql.Scope(Set.of(UUID.randomUUID()))))
                .contains("o.warehouse_id IN (SELECT id FROM scope_wh)");
    }

    @Test
    void agingNetsReversalsBySourceLineAndSkipsInternalTransfers() {
        String sql = WarehouseInsightSql.health(WarehouseInsightSql.Scope.defaultScope(), false);
        assertThat(sql).contains("GROUP BY 1, 2, 3, 4, 5, 6")
                .contains("HAVING SUM(m.qty * m.direction) > 0")
                .contains("m.movement_type IN (:agingTypes) AND i.source_doc_type IS NULL")
                .contains("WHERE p.movement_type = 8")
                .contains("LEAST(net_qty, bal_qty - (cum_incl - net_qty))")
                .contains("ORDER BY l.in_at DESC")
                // 消耗: 消耗类型 + 对应调入不在范围内的调拨出; 近 365 天。
                .contains("m.movement_type IN (:consumption) OR (m.movement_type = 8 AND in7.source_doc_type IS NULL)")
                .contains("m.transaction_date >= :t365 AND m.transaction_date < :asOfEnd")
                // ABC 排名在整个范围上 (与单货品过滤无关)。
                .contains("SUM(picks) OVER (ORDER BY picks DESC, goods_id ROWS UNBOUNDED PRECEDING) - picks");
        assertThat(WarehouseInsightSql.agingTypes())
                .containsExactly((short) 1, (short) 4, (short) 9, (short) 11, (short) 13, (short) 17, (short) 7);
        String single = WarehouseInsightSql.health(WarehouseInsightSql.Scope.defaultScope(), true);
        assertThat(single).contains("b.goods_id = :goods").contains("p.goods_id = :goods");
        assertThat(single.substring(single.indexOf("flows AS ("))).doesNotContain(":goods");
    }

    @Test
    void cycleCountReadsApprovedCountDocumentsBecauseZeroVarianceCountsPostNoMovement() {
        String sql = WarehouseInsightSql.cycleCount(WarehouseInsightSql.Scope.defaultScope());
        assertThat(sql).contains("d.doc_type = 'CHECK' AND d.status = 1 AND NOT d.is_deleted AND NOT i.is_deleted")
                .contains("MAX(d.bill_date) AS last_counted_on")
                .contains("MIN(m.transaction_date) AS first_at")
                .contains("a.kind = 'RESIDUAL' AND a.transaction_date >= :t90")
                // 仓库 × 货品 × 颜色, 与盘点单明细同粒度 (预填盘点单时颜色不会错)。
                .contains("COALESCE(b.color_id, " + WarehouseInsightSql.ZERO_COLOR + ") AS ck")
                .contains("COALESCE(i.color_id, " + WarehouseInsightSql.ZERO_COLOR + ") AS ck")
                .contains("NULLIF(bal.ck, " + WarehouseInsightSql.ZERO_COLOR + ") AS color_id")
                .contains("AND lc.ck = bal.ck").contains("AND fm.ck = bal.ck").contains("AND r.ck = bal.ck")
                .contains("AND a30.ck = bal.ck")
                .doesNotContain("%1$s");
    }

    @Test
    void weightAlertsReadCaptureTimeSnapshotsAndRegimeChanges() {
        String both = WarehouseInsightSql.alerts(true, false, true, false);
        assertThat(both).contains("o.alert_level <> 'NONE'").contains("o.stage = 'ACTIVE'")
                .contains("o.excluded_reason IS NULL").contains("e.regime_changed_at >= :since")
                .contains("UNION ALL").doesNotContain(":kind").doesNotContain(":supplier");
        String regimeOnly = WarehouseInsightSql.alerts(false, false, true, true);
        assertThat(regimeOnly).startsWith("SELECT 'REGIME' AS row_type").contains("e.supplier_id = :supplier");
        // 两个分支同一位置给基本单位计量维度 (按件计的数量页面取整显示)。
        assertThat(both.split("UNION ALL")).allSatisfy(part -> assertThat(part)
                .contains("u.name AS unit_name, gu.measurement_dimension AS base_unit_dimension,")
                .contains("LEFT JOIN unit_measurement_profiles gu ON gu.unit_id = g.unit_id"));
        assertThat(WarehouseInsightSql.alerts(true, true, false, false)).contains("o.source_kind = :kind")
                .doesNotContain("REGIME");
        assertThat(WarehouseInsightSql.partySummary(false)).contains("o.source_kind = 'RECEIPT'")
                .contains("o.source_kind = 'DRAW' AND o.counterpart_kind = 'WORKSHOP'");
        // 往来方汇总与异常行同一个 days 窗口。
        assertThat(WarehouseInsightSql.partySummary(false))
                .contains("o.observed_at >= :since AND o.observed_at < :asOfEnd").doesNotContain(":t30");
    }

    @Test
    void learningReadsEvidenceCountsFromThePoolEstimate() {
        assertThat(WarehouseInsightSql.learning(false)).contains("pe.n_ref, pe.n_draw")
                .contains("goods_weight_estimates pe ON pe.goods_id = g.id AND pe.supplier_id IS NULL");
    }
}
