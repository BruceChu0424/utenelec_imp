package com.uten.imp.features.stock.ledger;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 流水 SQL 形状 (读侧评审 §A): 结存 = 锚点 − 更新行之和, 窗口按 (业务日期, 记账顺序) 倒序;
 * 类型/方向/截止日期只在窗口之后筛; 条件按需拼接 (没有 ":x IS NULL OR"); 单号/往来方按登记表关联。
 */
class StockLedgerSqlTest {

    private static final UUID GOODS = UUID.randomUUID();
    private static final UUID WAREHOUSE = UUID.randomUUID();
    private static final UUID COLOR = UUID.randomUUID();
    private static final OffsetDateTime FROM = OffsetDateTime.parse("2026-06-30T16:00:00Z");
    private static final OffsetDateTime TO = OffsetDateTime.parse("2026-09-28T16:00:00Z");
    private static final Pattern NULLABLE_PARAMETER = Pattern.compile(":[A-Za-z_]+\\)?\\s+IS\\s+(NOT\\s+)?NULL");

    @Test
    void runningBalanceIsASuffixWindowOverMovementsAndWeightAdjustments() {
        String sql = StockLedgerSql.page(query(null, null, List.of(), false, null, false));

        assertThat(sql).contains("FROM stock_movements m")
                .contains("FROM stock_weight_adjustments a")
                .contains("UNION ALL")
                .contains("ORDER BY r.transaction_date DESC, r.ledger_seq DESC ROWS UNBOUNDED PRECEDING")
                .contains("ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING")
                .contains("a.qty_now - (w.qs - w.qty_signed) AS balance_qty_after")
                .contains("a.weight_now - (COALESCE(w.ws, 0) - COALESCE(w.weight_signed, 0))")
                .contains("WHEN a.weight_now IS NULL OR w.w_unknown_newer THEN NULL")
                // 锚点: 任一有数量的余额行重量未知则当前重量未知。
                .contains("CASE WHEN bool_or(b.qty <> 0 AND b.weight IS NULL) THEN NULL")
                // 老数据有重量没来历按实称读。
                .contains("COALESCE(m.weight_source, 'MEASURED')")
                .contains("ORDER BY w.transaction_date DESC, w.ledger_seq DESC")
                .contains("LIMIT :limit OFFSET :offset");
    }

    @Test
    void displayFiltersApplyOnlyAfterTheWindowWhileScopeAndStartDateBoundTheRows() {
        StockLedgerQuery q = query(Set.of(WAREHOUSE), COLOR, List.of((short) 3), false, (short) -1, false);
        String sql = StockLedgerSql.page(q);
        String rows = sql.substring(sql.indexOf("r AS ("), sql.indexOf("w AS ("));
        String page = sql.substring(sql.indexOf("page AS ("), sql.indexOf("src AS ("));

        // 范围 (仓库含下级 + 颜色) 与起始日期裁在 r 里; 锚点同一范围。
        assertThat(rows).contains("m.warehouse_id IN (:scope)").contains("m.color_id = :color")
                .contains("m.transaction_date >= :from")
                .contains("a.warehouse_id IN (:scope)").contains("a.color_id = :color")
                .doesNotContain(":types").doesNotContain(":direction").doesNotContain(":toExcl");
        assertThat(StockLedgerSql.anchor(q)).contains("b.warehouse_id IN (:scope)").contains("b.color_id = :color");
        // 类型/方向/截止日期只在窗口之后。
        assertThat(page).contains("w.transaction_date < :toExcl")
                .contains("w.movement_type IN (:types)")
                .contains("w.direction = :direction");
    }

    @Test
    void conditionsAreBuiltOnlyWhenPresentAndNeverAsNullableParameters() {
        StockLedgerQuery bare = new StockLedgerQuery(GOODS, null, null, false, null, null, List.of(), false, null,
                false, 50, 0);
        StockLedgerQuery full = query(Set.of(WAREHOUSE), COLOR, List.of((short) 1, (short) 3), true, (short) 1, true);
        for (StockLedgerQuery q : List.of(bare, full)) {
            for (String sql : List.of(StockLedgerSql.page(q), StockLedgerSql.summary(q), StockLedgerSql.facets(q))) {
                assertThat(NULLABLE_PARAMETER.matcher(sql).find()).as(sql).isFalse();
            }
        }
        String bareSql = StockLedgerSql.page(bare) + StockLedgerSql.summary(bare) + StockLedgerSql.facets(bare);
        assertThat(bareSql).doesNotContain(":scope").doesNotContain(":color").doesNotContain(":from")
                .doesNotContain(":toExcl").doesNotContain(":types").doesNotContain(":direction");

        MapSqlParameterSource params = StockLedgerSql.params(bare);
        assertThat(params.getParameterNames()).containsExactlyInAnyOrder("goods", "inTypes", "limit", "offset");
        assertThat(StockLedgerSql.params(full).getParameterNames())
                .contains("scope", "color", "from", "toExcl", "types", "direction");
    }

    @Test
    void weightAdjustmentRowsFollowTheToggleTheWPseudoTypeAndTheDirectionFilter() {
        assertThat(StockLedgerSql.display(query(null, null, List.of(), false, null, false), "w"))
                .isEqualTo("w.transaction_date < :toExcl AND (w.row_kind = 'M')");
        assertThat(StockLedgerSql.display(query(null, null, List.of(), false, null, true), "w"))
                .contains("(w.row_kind = 'M') OR (w.row_kind = 'W')");
        // 按方向筛选时不显示重量调整行。
        assertThat(StockLedgerSql.display(query(null, null, List.of(), false, (short) -1, true), "w"))
                .doesNotContain("row_kind = 'W'");
        // 只点名 W: 只显示重量调整, 本期收入/发出为空。
        StockLedgerQuery onlyAdjustments = query(null, null, List.of(), true, null, false);
        assertThat(StockLedgerSql.display(onlyAdjustments, "w")).endsWith("(w.row_kind = 'W')");
        assertThat(StockLedgerSql.flow(onlyAdjustments)).isEqualTo("FALSE");
        // 点名具体类型: 开关不再起作用。
        assertThat(StockLedgerSql.display(query(null, null, List.of((short) 5), false, null, true), "w"))
                .doesNotContain("row_kind = 'W'");
    }

    @Test
    void summaryExcludesInternalTransfersByScopeAndCountsUnknownWeights() {
        String all = StockLedgerSql.summary(query(null, null, List.of(), false, null, false));
        assertThat(all).contains("(r.movement_type IN (7, 8))").doesNotContain("EXISTS");
        assertThat(all).contains("r.movement_type IN (:inTypes)")
                .contains("AS in_weight_unknown").contains("AS out_weight_unknown")
                .contains("r.adj_kind = 'RESIDUAL'")
                .contains("COUNT(*) FILTER (WHERE r.transaction_date < :toExcl");

        String scoped = StockLedgerSql.summary(query(Set.of(WAREHOUSE), null, List.of(), false, null, false));
        assertThat(scoped).contains("EXISTS (SELECT 1 FROM stock_movements peer")
                .contains("peer.movement_type = 15 - r.movement_type AND peer.direction = -r.direction")
                .contains("peer.warehouse_id IN (:scope)");
    }

    @Test
    void billNumbersCounterpartsAndDocumentCodesComeFromTheSourceRegistry() {
        String sql = StockLedgerSql.page(query(null, null, List.of(), false, null, false));
        for (StockLedgerSource source : StockLedgerSource.values()) {
            assertThat(sql).contains("p.source_doc_type = '" + source.code() + "'");
        }
        assertThat(sql).contains("WHEN 'STOCK_DOC' THEN src_sd.doc_type")
                .contains("LEFT JOIN production_daily_reports src_sd_pdr")
                // 调拨两腿的往来方是对方仓库。
                .contains("q.movement_type = 15 - p.movement_type")
                .contains("THEN CASE WHEN peer.warehouse_id IS NOT NULL THEN 'WAREHOUSE' END")
                // 操作人: created_by → users.employee_id → employees.full_name。
                .contains("LEFT JOIN users usr ON usr.id = src.created_by")
                .contains("LEFT JOIN employees emp ON emp.id = usr.employee_id");
    }

    @Test
    void eachFacetIgnoresItsOwnDimension() {
        String sql = StockLedgerSql.facets(query(Set.of(WAREHOUSE), COLOR, List.of(), false, null, false));
        assertThat(sql).contains("COUNT(*) FILTER (WHERE f.wh_ok AND f.color_ok) AS n")
                .contains("MAX(wh.name), COUNT(*) FILTER (WHERE f.color_ok)")
                .contains("MAX(c.name), COUNT(*) FILTER (WHERE f.wh_ok)")
                .contains("'__null__'")
                .contains("m.transaction_date >= :from").contains("m.transaction_date < :toExcl");
    }

    private static StockLedgerQuery query(Set<UUID> scope, UUID color, List<Short> types, boolean w, Short direction,
                                          boolean adjustments) {
        return new StockLedgerQuery(GOODS, scope, color, false, FROM, TO, types, w, direction, adjustments, 50, 0);
    }
}
