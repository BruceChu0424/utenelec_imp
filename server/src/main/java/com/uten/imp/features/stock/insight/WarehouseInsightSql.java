package com.uten.imp.features.stock.insight;

import com.uten.imp.features.stock.ledger.StockLedgerSource;
import com.uten.imp.features.stock.ledger.StockMovementTypeCatalog;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.common.time.BusinessTime.startOfDay;

/**
 * 库存分析 SQL (读侧评审 §C-§G, 已在 PG16 上看过执行计划)。每个接口的重查询一次跑完 (所选范围内全部行),
 * 排序/分页/合计在内存里做。as-of 日期由调用方给 (业务日, 不用数据库的 current_date), 各窗口边界是
 * 上海时区当日零点。颜色键用 COALESCE(color_id, 全零 UUID) 以便哈希/归并连接 (不写 IS NOT DISTINCT FROM)。
 */
final class WarehouseInsightSql {

    static final String ZERO_COLOR = "'00000000-0000-0000-0000-000000000000'::uuid";

    private WarehouseInsightSql() {
    }

    /**
     * 仓库范围。
     *
     * @param warehouseIds 选中仓库 (含下级) 或「我的仓库」展开后的集合; null = 默认范围 (参与核算、非线边、
     *                     未删除的全部仓库); 空集合 = 一个仓也没有 (登记了负责人、本账号却不负责任何仓)
     */
    record Scope(Set<UUID> warehouseIds) {

        static Scope defaultScope() {
            return new Scope(null);
        }

        boolean explicit() {
            return warehouseIds != null;
        }
    }

    /** as-of 窗口边界 (含下界; asOfEnd = as-of 次日零点, 不含)。 */
    record Window(LocalDate asOf, OffsetDateTime t30, OffsetDateTime t90, OffsetDateTime t180, OffsetDateTime t365,
                  OffsetDateTime asOfEnd) {

        static Window of(LocalDate asOf) {
            return new Window(asOf, startOfDay(asOf.minusDays(30)), startOfDay(asOf.minusDays(90)),
                    startOfDay(asOf.minusDays(180)), startOfDay(asOf.minusDays(365)), startOfDay(asOf.plusDays(1)));
        }

        OffsetDateTime since(int days) {
            return startOfDay(asOf.minusDays(days));
        }
    }

    static MapSqlParameterSource params(Scope scope, Window window) {
        MapSqlParameterSource p = new MapSqlParameterSource()
                .addValue("t30", window.t30())
                .addValue("t90", window.t90())
                .addValue("t180", window.t180())
                .addValue("t365", window.t365())
                .addValue("asOfEnd", window.asOfEnd())
                .addValue("consumption", StockMovementTypeCatalog.codesOf(StockMovementTypeCatalog.Category.CONSUMPTION))
                .addValue("agingTypes", agingTypes());
        if (scope.explicit() && !scope.warehouseIds().isEmpty()) {
            p.addValue("scope", scope.warehouseIds());
        }
        return p;
    }

    /** 库龄批次候选类型: 外部来货 + 盘盈, 再加调拨入 (7, 只在对应调出不在范围内时算)。 */
    static List<Short> agingTypes() {
        List<Short> types = new ArrayList<>(StockMovementTypeCatalog.agingInboundCodes());
        types.add(StockMovementTypeCatalog.TRANSFER_IN.code());
        return List.copyOf(types);
    }

    /** 范围仓库: 显式单仓按原样 (含线边仓); 显式多仓与默认范围只算参与核算、非线边的仓库; 显式空集合没有仓。 */
    static String scopeCte(Scope scope) {
        if (!scope.explicit()) {
            return "scope_wh AS (SELECT id FROM warehouses WHERE NOT is_deleted AND is_accountable AND NOT is_line_side)";
        }
        if (scope.warehouseIds().isEmpty()) {
            return "scope_wh AS (SELECT id FROM warehouses WHERE false)";
        }
        if (scope.warehouseIds().size() == 1) {
            return "scope_wh AS (SELECT id FROM warehouses WHERE id IN (:scope))";
        }
        return "scope_wh AS (SELECT id FROM warehouses WHERE id IN (:scope) AND is_accountable AND NOT is_line_side)";
    }

    /** 货品基本单位名 (UUID 关系优先, 缺失时按 legacy 快照), 以 LATERAL 取一条。 */
    static String unitLateral(String goodsAlias) {
        return "LEFT JOIN LATERAL (SELECT un.name FROM units un WHERE un.id = " + goodsAlias + ".unit_id OR ("
                + goodsAlias + ".unit_id IS NULL AND un.legacy_id = NULLIF(" + goodsAlias + ".unit_legacy_id, 0))"
                + " ORDER BY (un.id = " + goodsAlias + ".unit_id) DESC LIMIT 1) u ON true\n";
    }

    /**
     * 消耗与 ABC 原料 (近 365 天, 范围内): 消耗类型 + 调往范围外的调拨出 (对应调入不在范围内); 红冲冲减。
     * picks 按货品合计近 90 天出库次数, ranked 给出排名累计。
     */
    static String flowsCtes() {
        return """
                in7 AS (
                    SELECT DISTINCT p.source_doc_type, p.source_doc_id, p.source_item_id
                    FROM stock_movements p JOIN scope_wh s ON s.id = p.warehouse_id
                    WHERE p.movement_type = 7 AND p.transaction_date >= :t365
                ),
                flows AS (
                    SELECT m.goods_id, COALESCE(m.color_id, %1$s) AS ck,
                           COALESCE(SUM(-m.direction * m.qty) FILTER (WHERE m.transaction_date >= :t30), 0) AS out_30,
                           COALESCE(SUM(-m.direction * m.qty) FILTER (WHERE m.transaction_date >= :t90), 0) AS out_90,
                           COALESCE(SUM(-m.direction * m.qty), 0) AS out_365,
                           GREATEST(COUNT(*) FILTER (WHERE m.direction = -1 AND m.transaction_date >= :t90)
                                  - COUNT(*) FILTER (WHERE m.direction = 1 AND m.transaction_date >= :t90), 0)
                               AS picks_90,
                           MAX(m.transaction_date) FILTER (WHERE m.direction = -1) AS last_out_at
                    FROM stock_movements m
                    JOIN scope_wh s ON s.id = m.warehouse_id
                    LEFT JOIN in7 ON m.movement_type = 8 AND in7.source_doc_type = m.source_doc_type
                        AND in7.source_doc_id = m.source_doc_id AND in7.source_item_id = m.source_item_id
                    WHERE m.transaction_date >= :t365 AND m.transaction_date < :asOfEnd
                      AND (m.movement_type IN (:consumption) OR (m.movement_type = 8 AND in7.source_doc_type IS NULL))
                    GROUP BY 1, 2
                ),
                picks AS (
                    SELECT goods_id, SUM(picks_90) AS picks FROM flows GROUP BY goods_id
                ),
                ranked AS (
                    SELECT goods_id, picks,
                           SUM(picks) OVER (ORDER BY picks DESC, goods_id ROWS UNBOUNDED PRECEDING) - picks AS cum_before
                    FROM picks
                ),
                picks_total AS (
                    SELECT COALESCE(SUM(picks), 0) AS total FROM picks
                )""".formatted(ZERO_COLOR);
    }

    /**
     * 呆滞与库龄 (货品 × 颜色): 余额 + 先进先出库龄分配 + 消耗 + ABC 排名。
     *
     * @param goodsFilter 只取一个货品 (:goods) 的余额与库龄 (ABC 排名仍按整个范围)
     */
    static String health(Scope scope, boolean goodsFilter) {
        String goodsB = goodsFilter ? " AND b.goods_id = :goods" : "";
        String goodsP = goodsFilter ? " AND p.goods_id = :goods" : "";
        return "WITH " + scopeCte(scope) + ",\n" + """
                bal AS (
                    SELECT b.goods_id, COALESCE(b.color_id, %1$s) AS ck,
                           SUM(b.qty) AS qty,
                           CASE WHEN bool_or(b.qty <> 0 AND b.weight IS NULL) THEN NULL
                                ELSE COALESCE(SUM(b.weight), 0) END AS weight_kg,
                           COALESCE(bool_or(b.weight_estimated), false) AS weight_estimated,
                           SUM(b.amount_local) AS amount_local,
                           MAX(b.last_movement_date) AS last_movement_at,
                           COUNT(*) FILTER (WHERE b.qty > 0) AS dims,
                           COUNT(*) FILTER (WHERE b.qty > 0 AND b.weight IS NOT NULL AND NOT b.weight_estimated)
                               AS dims_weighed
                    FROM stock_balances b JOIN scope_wh s ON s.id = b.warehouse_id
                    WHERE TRUE%2$s
                    GROUP BY 1, 2
                    HAVING SUM(b.qty) > 0
                ),
                internal AS (
                    SELECT DISTINCT p.source_doc_type, p.source_doc_id, p.source_item_id
                    FROM stock_movements p JOIN scope_wh s ON s.id = p.warehouse_id
                    WHERE p.movement_type = 8%3$s
                ),
                lines AS (
                    SELECT m.goods_id, COALESCE(m.color_id, %1$s) AS ck,
                           m.source_doc_type, m.source_doc_id, m.source_item_id, m.movement_type,
                           MIN(m.transaction_date) FILTER (WHERE m.direction = 1) AS in_at,
                           SUM(m.qty * m.direction) AS net_qty
                    FROM stock_movements m
                    JOIN scope_wh s ON s.id = m.warehouse_id
                    JOIN (SELECT DISTINCT goods_id FROM bal) bg ON bg.goods_id = m.goods_id
                    LEFT JOIN internal i ON m.movement_type = 7 AND i.source_doc_type = m.source_doc_type
                        AND i.source_doc_id = m.source_doc_id AND i.source_item_id = m.source_item_id
                    WHERE m.movement_type IN (:agingTypes) AND i.source_doc_type IS NULL
                    GROUP BY 1, 2, 3, 4, 5, 6
                    HAVING SUM(m.qty * m.direction) > 0
                       AND MIN(m.transaction_date) FILTER (WHERE m.direction = 1) IS NOT NULL
                ),
                layers AS (
                    SELECT l.goods_id, l.ck, l.in_at, l.net_qty, bal.qty AS bal_qty,
                           SUM(l.net_qty) OVER (PARTITION BY l.goods_id, l.ck
                                                ORDER BY l.in_at DESC, l.source_doc_id DESC, l.source_item_id DESC
                                                ROWS UNBOUNDED PRECEDING) AS cum_incl
                    FROM lines l JOIN bal ON bal.goods_id = l.goods_id AND bal.ck = l.ck
                ),
                aging AS (
                    SELECT alloc.goods_id, alloc.ck,
                           COALESCE(SUM(alloc.qty) FILTER (WHERE alloc.in_at >= :t30), 0) AS age_0_30,
                           COALESCE(SUM(alloc.qty) FILTER (WHERE alloc.in_at >= :t90 AND alloc.in_at < :t30), 0)
                               AS age_31_90,
                           COALESCE(SUM(alloc.qty) FILTER (WHERE alloc.in_at >= :t180 AND alloc.in_at < :t90), 0)
                               AS age_91_180,
                           COALESCE(SUM(alloc.qty) FILTER (WHERE alloc.in_at >= :t365 AND alloc.in_at < :t180), 0)
                               AS age_181_365,
                           COALESCE(SUM(alloc.qty) FILTER (WHERE alloc.in_at < :t365), 0) AS age_over_365,
                           COALESCE(SUM(alloc.qty), 0) AS allocated,
                           MAX(alloc.in_at) AS newest_in
                    FROM (
                        SELECT goods_id, ck, in_at, LEAST(net_qty, bal_qty - (cum_incl - net_qty)) AS qty
                        FROM layers
                        WHERE cum_incl - net_qty < bal_qty
                    ) alloc
                    GROUP BY 1, 2
                ),
                """.formatted(ZERO_COLOR, goodsB, goodsP) + flowsCtes() + """

                SELECT bal.goods_id, NULLIF(bal.ck, %1$s) AS color_id, g.code, g.name, g.category_id, g.model,
                       c.name AS color_name, u.name AS unit_name,
                       bal.qty, bal.weight_kg, bal.weight_estimated, bal.amount_local, bal.last_movement_at,
                       bal.dims, bal.dims_weighed,
                       COALESCE(ag.age_0_30, 0) AS age_0_30, COALESCE(ag.age_31_90, 0) AS age_31_90,
                       COALESCE(ag.age_91_180, 0) AS age_91_180, COALESCE(ag.age_181_365, 0) AS age_181_365,
                       COALESCE(ag.age_over_365, 0) AS age_over_365, COALESCE(ag.allocated, 0) AS allocated,
                       ag.newest_in,
                       COALESCE(fl.out_30, 0) AS out_30, COALESCE(fl.out_90, 0) AS out_90,
                       COALESCE(fl.out_365, 0) AS out_365, COALESCE(fl.picks_90, 0) AS picks_90, fl.last_out_at,
                       COALESCE(rk.picks, 0) AS goods_picks, COALESCE(rk.cum_before, 0) AS picks_cum_before,
                       pt.total AS picks_total
                FROM bal
                JOIN goods g ON g.id = bal.goods_id
                LEFT JOIN colors c ON c.id = NULLIF(bal.ck, %1$s)
                """.formatted(ZERO_COLOR) + unitLateral("g") + """
                LEFT JOIN aging ag ON ag.goods_id = bal.goods_id AND ag.ck = bal.ck
                LEFT JOIN flows fl ON fl.goods_id = bal.goods_id AND fl.ck = bal.ck
                LEFT JOIN ranked rk ON rk.goods_id = bal.goods_id
                CROSS JOIN picks_total pt
                """;
    }

    /**
     * 顶部指标里不依赖表格行的数: 近 30 天流水笔数、称重异常条数 (及其中的来料少数 / 领料超发, 与称重异常
     * 列表的 RECEIPT_SHORT / DRAW_OVER 同一划分)、待称样货品数。
     */
    static String overview(Scope scope) {
        String alertScope = scope.explicit() ? " AND o.warehouse_id IN (SELECT id FROM scope_wh)" : "";
        return "WITH " + scopeCte(scope) + ",\n" + """
                active AS (
                    SELECT DISTINCT m.goods_id
                    FROM stock_movements m JOIN scope_wh s ON s.id = m.warehouse_id
                    WHERE m.transaction_date >= :t90 AND m.transaction_date < :asOfEnd
                ),
                alerts AS (
                    SELECT COUNT(*) AS alerts_30d,
                           COUNT(*) FILTER (WHERE o.source_kind = 'RECEIPT' AND o.deviation_pct < 0)
                               AS receipt_short_30d,
                           COUNT(*) FILTER (WHERE o.source_kind = 'DRAW' AND NOT COALESCE(o.deviation_pct < 0, false))
                               AS draw_over_30d
                    FROM goods_weight_observations o
                    WHERE o.observed_at >= :t30 AND o.observed_at < :asOfEnd AND o.alert_level <> 'NONE'
                      AND o.stage = 'ACTIVE' AND o.excluded_reason IS NULL%1$s
                )
                SELECT
                    (SELECT COUNT(*) FROM stock_movements m JOIN scope_wh s ON s.id = m.warehouse_id
                      WHERE m.transaction_date >= :t30 AND m.transaction_date < :asOfEnd) AS movements_30d,
                    al.alerts_30d, al.receipt_short_30d, al.draw_over_30d,
                    (SELECT COUNT(*) FROM active a
                      JOIN goods g ON g.id = a.goods_id AND NOT g.is_deleted
                      LEFT JOIN unit_measurement_profiles up ON up.unit_id = g.unit_id
                      LEFT JOIN goods_weight_profiles p ON p.goods_id = g.id
                      LEFT JOIN goods_weight_estimates e ON e.goods_id = g.id AND e.supplier_id IS NULL
                      WHERE up.mass_unit_code IS NULL
                        AND COALESCE(p.learning_enabled, true)
                        AND NOT COALESCE(p.manual_unit_weight_kg IS NOT NULL AND p.manual_unit_id = g.unit_id, false)
                        AND (e.goods_id IS NULL OR e.tier = 'RED' OR e.evidence = 'CONFLICT'
                             OR e.unit_weight_kg IS NULL)) AS needs_sample
                FROM alerts al
                """.formatted(alertScope);
    }

    /**
     * 盘点建议 (仓库 × 货品 × 颜色, 与盘点单明细同粒度): 上次盘点、第一笔流水、近期尾差、近 30 天动态都按
     * 这三者对齐; 单重可靠度与 ABC 是货品级。
     */
    static String cycleCount(Scope scope) {
        return "WITH " + scopeCte(scope) + ",\n" + """
                bal AS (
                    SELECT b.warehouse_id, b.goods_id, COALESCE(b.color_id, %1$s) AS ck, SUM(b.qty) AS qty,
                           CASE WHEN bool_or(b.qty <> 0 AND b.weight IS NULL) THEN NULL
                                ELSE COALESCE(SUM(b.weight), 0) END AS weight_kg,
                           COALESCE(bool_or(b.weight_estimated), false) AS weight_estimated,
                           MIN(b.created_at) AS first_balance_at
                    FROM stock_balances b JOIN scope_wh s ON s.id = b.warehouse_id
                    GROUP BY 1, 2, 3
                    HAVING SUM(b.qty) <> 0
                ),
                last_check AS (
                    SELECT d.warehouse_id, i.goods_id, COALESCE(i.color_id, %1$s) AS ck,
                           MAX(d.bill_date) AS last_counted_on
                    FROM stock_documents d
                    JOIN stock_document_items i ON i.doc_id = d.id
                    JOIN scope_wh s ON s.id = d.warehouse_id
                    WHERE d.doc_type = 'CHECK' AND d.status = 1 AND NOT d.is_deleted AND NOT i.is_deleted
                    GROUP BY 1, 2, 3
                ),
                first_mv AS (
                    SELECT m.warehouse_id, m.goods_id, bal.ck, MIN(m.transaction_date) AS first_at
                    FROM stock_movements m
                    JOIN bal ON bal.warehouse_id = m.warehouse_id AND bal.goods_id = m.goods_id
                        AND bal.ck = COALESCE(m.color_id, %1$s)
                    GROUP BY 1, 2, 3
                ),
                resid AS (
                    SELECT a.warehouse_id, a.goods_id, COALESCE(a.color_id, %1$s) AS ck, COUNT(*) AS n
                    FROM stock_weight_adjustments a JOIN scope_wh s ON s.id = a.warehouse_id
                    WHERE a.kind = 'RESIDUAL' AND a.transaction_date >= :t90
                    GROUP BY 1, 2, 3
                ),
                act30 AS (
                    SELECT DISTINCT m.warehouse_id, m.goods_id, COALESCE(m.color_id, %1$s) AS ck
                    FROM stock_movements m JOIN scope_wh s ON s.id = m.warehouse_id
                    WHERE m.transaction_date >= :t30 AND m.transaction_date < :asOfEnd
                ),
                """.formatted(ZERO_COLOR) + flowsCtes() + """

                SELECT bal.warehouse_id, w.name AS warehouse_name, bal.goods_id, g.code, g.name,
                       NULLIF(bal.ck, %1$s) AS color_id, c.name AS color_name, u.name AS unit_name,
                       bal.qty, bal.weight_kg, bal.weight_estimated,
                       lc.last_counted_on,
                       (fm.first_at AT TIME ZONE 'Asia/Shanghai')::date AS first_movement_on,
                       (bal.first_balance_at AT TIME ZONE 'Asia/Shanghai')::date AS first_balance_on,
                       COALESCE(r.n, 0) AS residuals_90, (a30.goods_id IS NOT NULL) AS active_30,
                       e.tier AS estimate_tier, e.evidence AS estimate_evidence,
                       (up.mass_unit_code IS NOT NULL) AS exact,
                       COALESCE(rk.picks, 0) AS goods_picks, COALESCE(rk.cum_before, 0) AS picks_cum_before,
                       pt.total AS picks_total
                FROM bal
                JOIN warehouses w ON w.id = bal.warehouse_id
                JOIN goods g ON g.id = bal.goods_id
                LEFT JOIN colors c ON c.id = NULLIF(bal.ck, %1$s)
                """.formatted(ZERO_COLOR) + unitLateral("g") + """
                LEFT JOIN last_check lc ON lc.warehouse_id = bal.warehouse_id AND lc.goods_id = bal.goods_id
                    AND lc.ck = bal.ck
                LEFT JOIN first_mv fm ON fm.warehouse_id = bal.warehouse_id AND fm.goods_id = bal.goods_id
                    AND fm.ck = bal.ck
                LEFT JOIN resid r ON r.warehouse_id = bal.warehouse_id AND r.goods_id = bal.goods_id AND r.ck = bal.ck
                LEFT JOIN act30 a30 ON a30.warehouse_id = bal.warehouse_id AND a30.goods_id = bal.goods_id
                    AND a30.ck = bal.ck
                LEFT JOIN goods_weight_estimates e ON e.goods_id = bal.goods_id AND e.supplier_id IS NULL
                LEFT JOIN unit_measurement_profiles up ON up.unit_id = g.unit_id
                LEFT JOIN ranked rk ON rk.goods_id = bal.goods_id
                CROSS JOIN picks_total pt
                """;
    }

    /**
     * 称重异常行: 窗口内有效且未排除、记录当时就告警的称重记录, 加上窗口内检测到的单重变化。
     *
     * @param observations 取称重记录分支 (按来源种类筛选为 :kind 时只取这一种)
     * @param kindFilter   称重记录按来源种类筛选
     * @param regimes      取单重变化分支
     * @param supplier     按供应商筛选 (:supplier)
     */
    static String alerts(boolean observations, boolean kindFilter, boolean regimes, boolean supplier) {
        List<String> parts = new ArrayList<>();
        if (observations) {
            parts.add("""
                    SELECT 'OBSERVATION' AS row_type, o.id, o.observed_at, o.goods_id, g.code, g.name,
                           u.name AS unit_name, gu.measurement_dimension AS base_unit_dimension,
                           c.name AS color_name, o.warehouse_id, w.name AS warehouse_name,
                           o.source_kind, o.supplier_id, s.name AS supplier_name, o.counterpart_kind, o.counterpart_id,
                           CASE o.counterpart_kind WHEN 'WORKSHOP' THEN d.name WHEN 'CLIENT' THEN cl.name
                                ELSE cs.name END AS counterpart_name,
                           o.source_doc_type, o.source_doc_id,
                    """ + "       " + StockLedgerSource.docCodeSelect("o")
                    + " AS source_doc_code,\n"
                    + "       " + StockLedgerSource.billNoSelect("o")
                    + " AS bill_no,\n" + """
                           o.qty_base, o.weight_kg, o.expected_unit_weight_kg, o.expected_weight_kg, o.deviation_pct,
                           o.alert_level, o.estimate_tier_used, o.estimate_basis_used,
                           CAST(NULL AS numeric) AS unit_weight_kg
                    FROM goods_weight_observations o
                    JOIN goods g ON g.id = o.goods_id
                    """ + unitLateral("g") + """
                    LEFT JOIN unit_measurement_profiles gu ON gu.unit_id = g.unit_id
                    LEFT JOIN colors c ON c.id = o.color_id
                    LEFT JOIN warehouses w ON w.id = o.warehouse_id
                    LEFT JOIN suppliers s ON s.id = o.supplier_id
                    LEFT JOIN departments d ON o.counterpart_kind = 'WORKSHOP' AND d.id = o.counterpart_id
                    LEFT JOIN clients cl ON o.counterpart_kind = 'CLIENT' AND cl.id = o.counterpart_id
                    LEFT JOIN suppliers cs ON o.counterpart_kind IN ('SUBCONTRACTOR', 'SUPPLIER')
                        AND cs.id = o.counterpart_id
                    """ + StockLedgerSource.joins("o") + """
                    WHERE o.observed_at >= :since AND o.observed_at < :asOfEnd AND o.alert_level <> 'NONE'
                      AND o.stage = 'ACTIVE' AND o.excluded_reason IS NULL"""
                    + (kindFilter ? " AND o.source_kind = :kind" : "")
                    + (supplier ? " AND o.supplier_id = :supplier" : ""));
        }
        if (regimes) {
            parts.add("""
                    SELECT 'REGIME' AS row_type, e.id, e.regime_changed_at AS observed_at, e.goods_id, g.code, g.name,
                           u.name AS unit_name, gu.measurement_dimension AS base_unit_dimension,
                           CAST(NULL AS text) AS color_name, CAST(NULL AS uuid) AS warehouse_id,
                           CAST(NULL AS text) AS warehouse_name, CAST(NULL AS text) AS source_kind,
                           e.supplier_id, s.name AS supplier_name, CAST(NULL AS text) AS counterpart_kind,
                           CAST(NULL AS uuid) AS counterpart_id, CAST(NULL AS text) AS counterpart_name,
                           CAST(NULL AS text) AS source_doc_type, CAST(NULL AS uuid) AS source_doc_id,
                           CAST(NULL AS text) AS source_doc_code, CAST(NULL AS text) AS bill_no,
                           CAST(NULL AS numeric) AS qty_base, CAST(NULL AS numeric) AS weight_kg,
                           CAST(NULL AS numeric) AS expected_unit_weight_kg, CAST(NULL AS numeric) AS expected_weight_kg,
                           CAST(NULL AS numeric) AS deviation_pct, CAST(NULL AS text) AS alert_level,
                           e.tier AS estimate_tier_used, CAST(NULL AS text) AS estimate_basis_used,
                           e.unit_weight_kg
                    FROM goods_weight_estimates e
                    JOIN goods g ON g.id = e.goods_id
                    """ + unitLateral("g") + """
                    LEFT JOIN unit_measurement_profiles gu ON gu.unit_id = g.unit_id
                    LEFT JOIN suppliers s ON s.id = e.supplier_id
                    WHERE e.regime_changed_at >= :since AND e.regime_changed_at < :asOfEnd"""
                    + (supplier ? " AND e.supplier_id = :supplier" : ""));
        }
        return String.join("\nUNION ALL\n", parts);
    }

    /** 供应商来料少数 + 车间领料超发汇总 (一条语句, dim = SUPPLIER / WORKSHOP)。 */
    static String partySummary(boolean supplier) {
        return """
                SELECT 'SUPPLIER' AS dim, o.supplier_id AS party_id, MAX(s.name) AS party_name,
                       COUNT(*) AS events,
                       COUNT(*) FILTER (WHERE o.alert_level <> 'NONE' AND o.deviation_pct < 0) AS flagged,
                       AVG(o.deviation_pct) FILTER (WHERE o.alert_level <> 'NONE' AND o.deviation_pct < 0) AS avg_pct,
                       COALESCE(SUM(o.expected_weight_kg - o.weight_kg)
                                FILTER (WHERE o.alert_level <> 'NONE' AND o.deviation_pct < 0), 0) AS kg
                FROM goods_weight_observations o
                LEFT JOIN suppliers s ON s.id = o.supplier_id
                WHERE o.source_kind = 'RECEIPT' AND o.supplier_id IS NOT NULL AND o.stage = 'ACTIVE'
                  AND o.excluded_reason IS NULL AND o.observed_at >= :since AND o.observed_at < :asOfEnd"""
                + (supplier ? " AND o.supplier_id = :supplier" : "") + """

                GROUP BY o.supplier_id
                UNION ALL
                SELECT 'WORKSHOP', o.counterpart_id, MAX(d.name),
                       COUNT(*),
                       COUNT(*) FILTER (WHERE o.alert_level <> 'NONE' AND o.deviation_pct > 0),
                       AVG(o.deviation_pct) FILTER (WHERE o.alert_level <> 'NONE' AND o.deviation_pct > 0),
                       COALESCE(SUM(o.weight_kg - o.expected_weight_kg)
                                FILTER (WHERE o.alert_level <> 'NONE' AND o.deviation_pct > 0), 0)
                FROM goods_weight_observations o
                LEFT JOIN departments d ON d.id = o.counterpart_id
                WHERE o.source_kind = 'DRAW' AND o.counterpart_kind = 'WORKSHOP' AND o.stage = 'ACTIVE'
                  AND o.excluded_reason IS NULL AND o.observed_at >= :since AND o.observed_at < :asOfEnd
                GROUP BY o.counterpart_id
                """;
    }

    /** 单重学习清单候选: 近 90 天有流水、有称重记录、有称重设置或有学习结果的货品 (按重量计的除外)。 */
    static String learning(boolean keyword) {
        return """
                WITH act AS (
                    SELECT m.goods_id, COUNT(*) AS movements_90d, MAX(m.transaction_date) AS last_movement_at
                    FROM stock_movements m
                    WHERE m.transaction_date >= :t90 AND m.transaction_date < :asOfEnd
                    GROUP BY m.goods_id
                ),
                obs AS (
                    SELECT o.goods_id, COUNT(*) AS n
                    FROM goods_weight_observations o
                    WHERE o.stage = 'ACTIVE' AND o.excluded_reason IS NULL
                    GROUP BY o.goods_id
                ),
                cand AS (
                    SELECT goods_id FROM act
                    UNION SELECT goods_id FROM obs
                    UNION SELECT goods_id FROM goods_weight_profiles
                    UNION SELECT goods_id FROM goods_weight_estimates
                ),
                onhand AS (
                    SELECT b.goods_id, SUM(b.qty) AS qty
                    FROM stock_balances b
                    JOIN warehouses w ON w.id = b.warehouse_id
                    JOIN cand ON cand.goods_id = b.goods_id
                    WHERE w.is_accountable AND NOT w.is_line_side
                    GROUP BY b.goods_id
                )
                SELECT g.id AS goods_id, g.code, g.name, g.model, u.name AS unit_name,
                       g.m_weight * fn_weight_unit_kg_factor(mu.mass_unit_code) AS master_kg,
                       COALESCE(act.movements_90d, 0) AS movements_90d, act.last_movement_at,
                       COALESCE(obs.n, 0) AS observations, COALESCE(onhand.qty, 0) AS qty,
                       pe.n_ref, pe.n_draw
                FROM cand
                JOIN goods g ON g.id = cand.goods_id AND NOT g.is_deleted
                LEFT JOIN unit_measurement_profiles up ON up.unit_id = g.unit_id
                LEFT JOIN unit_measurement_profiles mu ON mu.unit_id = g.m_weight_unit_id
                """ + unitLateral("g") + """
                LEFT JOIN act ON act.goods_id = g.id
                LEFT JOIN obs ON obs.goods_id = g.id
                LEFT JOIN onhand ON onhand.goods_id = g.id
                LEFT JOIN goods_weight_estimates pe ON pe.goods_id = g.id AND pe.supplier_id IS NULL
                WHERE up.mass_unit_code IS NULL"""
                + (keyword ? " AND (g.code ILIKE :kw OR g.name ILIKE :kw OR g.model ILIKE :kw)" : "") + "\n";
    }

    /** 分类子树 (含自身, 未删除)。 */
    static final String CATEGORY_SUBTREE = """
            WITH RECURSIVE cat AS (
                SELECT id FROM material_categories WHERE id = :categoryId AND is_deleted = false
                UNION ALL
                SELECT c.id FROM material_categories c JOIN cat s ON c.parent_id = s.id WHERE c.is_deleted = false
            )
            SELECT id FROM cat
            """;
}
