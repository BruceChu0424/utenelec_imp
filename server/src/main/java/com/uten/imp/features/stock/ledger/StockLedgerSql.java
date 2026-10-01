package com.uten.imp.features.stock.ledger;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;

/**
 * 货品出入库流水的 SQL (ADR-135 §7.1, 读侧评审 §A)。条件一律按需拼接并参数化, 不写
 * {@code :x IS NULL OR ...} (空参数类型推断坑); 拼进 SQL 的只有本类常量与登记表常量。
 *
 * <p>结存倒推: 锚点 = 范围内当前余额 (数量, 重量任一有量行未知则未知); 范围内流水 UNION ALL 重量调整按
 * (业务日期倒序, 记账顺序 ledger_seq 倒序) 排, 本行之后的结存 = 锚点 − 比本行更新的各行之和;
 * 更新的行里有未知重量 (NULL) 则本行结存重量未知。类型/方向/截止日期只在窗口之后筛行。
 */
final class StockLedgerSql {

    /** 调拨两腿: 7 调拨入 / 8 调拨出, 对应腿类型 = 15 - 本腿类型、方向相反。 */
    private static final String TRANSFER_TYPES = "(7, 8)";

    private StockLedgerSql() {
    }

    static MapSqlParameterSource params(StockLedgerQuery q) {
        MapSqlParameterSource p = new MapSqlParameterSource("goods", q.goodsId());
        if (q.warehouseScope() != null) p.addValue("scope", q.warehouseScope());
        if (q.colorId() != null) p.addValue("color", q.colorId());
        if (q.from() != null) p.addValue("from", q.from());
        if (q.toExclusive() != null) p.addValue("toExcl", q.toExclusive());
        if (!q.types().isEmpty()) p.addValue("types", q.types());
        if (q.direction() != null) p.addValue("direction", q.direction());
        p.addValue("inTypes", StockMovementTypeCatalog.naturalInCodes());
        p.addValue("limit", q.limit());
        p.addValue("offset", q.offset());
        return p;
    }

    /** 货品存在性 + 基本单位名 + 基本单位登记的重量单位代码 (有 = 按重量计的货品)。 */
    static final String GOODS = """
            SELECT g.id, u.name AS unit_name, up.mass_unit_code
            FROM goods g
            LEFT JOIN LATERAL (
                SELECT un.name FROM units un
                WHERE un.id = g.unit_id OR (g.unit_id IS NULL AND un.legacy_id = NULLIF(g.unit_legacy_id, 0))
                ORDER BY (un.id = g.unit_id) DESC
                LIMIT 1
            ) u ON true
            LEFT JOIN unit_measurement_profiles up ON up.unit_id = g.unit_id
            WHERE g.id = :goods
            """;

    /** 一页流水 (带结存、单号、往来方、名称)。 */
    static String page(StockLedgerQuery q) {
        return "WITH " + anchor(q) + ",\n" + rows(q) + """
                ,
                w AS (
                    SELECT r.*,
                           SUM(r.qty_signed) OVER newer_incl AS qs,
                           SUM(r.weight_signed) OVER newer_incl AS ws,
                           COALESCE(bool_or(r.weight_signed IS NULL) OVER newer_excl, false) AS w_unknown_newer
                    FROM r
                    WINDOW newer_incl AS (ORDER BY r.transaction_date DESC, r.ledger_seq DESC ROWS UNBOUNDED PRECEDING),
                           newer_excl AS (ORDER BY r.transaction_date DESC, r.ledger_seq DESC
                                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
                ),
                page AS (
                    SELECT w.*,
                           a.qty_now - (w.qs - w.qty_signed) AS balance_qty_after,
                           CASE WHEN a.weight_now IS NULL OR w.w_unknown_newer THEN NULL
                                ELSE a.weight_now - (COALESCE(w.ws, 0) - COALESCE(w.weight_signed, 0))
                           END AS balance_weight_after
                    FROM w CROSS JOIN anchor a
                    """ + "WHERE " + display(q, "w") + """

                    ORDER BY w.transaction_date DESC, w.ledger_seq DESC
                    LIMIT :limit OFFSET :offset
                ),
                src AS (
                    SELECT p.*,
                """ + "           " + StockLedgerSource.billNoSelect("p") + " AS bill_no,\n"
                + "           " + StockLedgerSource.docCodeSelect("p") + " AS source_doc_code,\n"
                + "           CASE WHEN p.row_kind = 'W' THEN NULL\n"
                + "                WHEN p.movement_type IN " + TRANSFER_TYPES
                + " THEN CASE WHEN peer.warehouse_id IS NOT NULL THEN 'WAREHOUSE' END\n"
                + "                ELSE " + StockLedgerSource.counterpartKindSelect("p") + " END AS counterpart_kind,\n"
                + "           CASE WHEN p.row_kind = 'W' THEN NULL\n"
                + "                WHEN p.movement_type IN " + TRANSFER_TYPES + " THEN peer.warehouse_id\n"
                + "                ELSE " + StockLedgerSource.counterpartIdSelect("p") + " END AS counterpart_id\n"
                + "    FROM page p\n"
                + StockLedgerSource.joins("p") + """
                    LEFT JOIN LATERAL (
                        SELECT q.warehouse_id
                        FROM stock_movements q
                        WHERE p.row_kind = 'M' AND p.movement_type IN (7, 8)
                          AND q.source_doc_type = p.source_doc_type
                          AND q.source_doc_id = p.source_doc_id
                          AND q.source_item_id = p.source_item_id
                          AND q.movement_type = 15 - p.movement_type
                          AND q.direction = -p.direction
                        ORDER BY q.ledger_seq DESC
                        LIMIT 1
                    ) peer ON true
                )
                SELECT src.row_kind, src.id, src.transaction_date, src.ledger_seq, src.movement_type, src.direction,
                       src.source_doc_type, src.source_doc_id, src.source_doc_code, src.bill_no,
                       src.counterpart_kind,
                       CASE src.counterpart_kind
                           WHEN 'CLIENT' THEN cp_c.name
                           WHEN 'WORKSHOP' THEN cp_d.name
                           WHEN 'WAREHOUSE' THEN cp_w.name
                           WHEN 'SUPPLIER' THEN cp_s.name
                           WHEN 'SUBCONTRACTOR' THEN cp_s.name
                       END AS counterpart_name,
                       src.warehouse_id, wh.name AS warehouse_name, src.color_id, col.name AS color_name,
                       src.qty_signed, src.weight_signed, src.weight_source, src.adj_kind,
                       src.balance_qty_after, src.balance_weight_after,
                       src.remark, emp.full_name AS operator_name, src.amount_local
                FROM src
                LEFT JOIN warehouses wh ON wh.id = src.warehouse_id
                LEFT JOIN colors col ON col.id = src.color_id
                LEFT JOIN users usr ON usr.id = src.created_by
                LEFT JOIN employees emp ON emp.id = usr.employee_id
                LEFT JOIN suppliers cp_s ON src.counterpart_kind IN ('SUPPLIER', 'SUBCONTRACTOR')
                    AND cp_s.id = src.counterpart_id
                LEFT JOIN clients cp_c ON src.counterpart_kind = 'CLIENT' AND cp_c.id = src.counterpart_id
                LEFT JOIN departments cp_d ON src.counterpart_kind = 'WORKSHOP' AND cp_d.id = src.counterpart_id
                LEFT JOIN warehouses cp_w ON src.counterpart_kind = 'WAREHOUSE' AND cp_w.id = src.counterpart_id
                ORDER BY src.transaction_date DESC, src.ledger_seq DESC
                """;
    }

    /**
     * 汇总 + 显示行数 (一条聚合): 期初/期末由 Java 用锚点减去对应区间之后的变动算出;
     * 本期收入/发出按类型/方向筛选、按自然方向归类、剔除范围内部调拨。
     */
    static String summary(StockLedgerQuery q) {
        String period = q.toExclusive() == null ? "" : " AND r.transaction_date < :toExcl";
        String flow = flow(q);
        String natIn = "(r.movement_type IN (:inTypes) OR (r.movement_type = 23 AND r.direction = 1))";
        String internal = internal(q);
        String inFlow = flow + " AND " + natIn + " AND NOT " + internal;
        String outFlow = flow + " AND NOT " + natIn + " AND NOT " + internal;
        String after = q.toExclusive() == null ? null : "r.transaction_date >= :toExcl";
        return "WITH " + anchor(q) + ",\n" + rows(q) + "\n"
                + "SELECT a.qty_now, a.weight_now, s.*\n"
                + "FROM anchor a CROSS JOIN (\n"
                + "    SELECT COALESCE(SUM(r.qty_signed), 0) AS qty_since_from,\n"
                + "           COALESCE(SUM(r.weight_signed), 0) AS weight_since_from,\n"
                + "           COALESCE(bool_or(r.weight_signed IS NULL), false) AS weight_unknown_since_from,\n"
                + (after == null
                ? "           CAST(0 AS numeric) AS qty_since_to,\n"
                + "           CAST(0 AS numeric) AS weight_since_to,\n"
                + "           false AS weight_unknown_since_to,\n"
                : "           COALESCE(SUM(r.qty_signed) FILTER (WHERE " + after + "), 0) AS qty_since_to,\n"
                + "           COALESCE(SUM(r.weight_signed) FILTER (WHERE " + after + "), 0) AS weight_since_to,\n"
                + "           COALESCE(bool_or(r.weight_signed IS NULL) FILTER (WHERE " + after + "), false)"
                + " AS weight_unknown_since_to,\n")
                + "           COUNT(*) FILTER (WHERE " + display(q, "r") + ") AS display_rows,\n"
                + "           COALESCE(SUM(r.qty_signed) FILTER (WHERE " + inFlow + "), 0) AS in_qty,\n"
                + "           COALESCE(SUM(-r.qty_signed) FILTER (WHERE " + outFlow + "), 0) AS out_qty,\n"
                + "           COALESCE(SUM(r.qty_signed) FILTER (WHERE " + flow + " AND " + natIn + " AND "
                + internal + "), 0) AS internal_qty,\n"
                + "           COALESCE(SUM(r.weight_signed) FILTER (WHERE " + inFlow + "), 0) AS in_weight,\n"
                + "           COALESCE(SUM(-r.weight_signed) FILTER (WHERE " + outFlow + "), 0) AS out_weight,\n"
                + "           COUNT(*) FILTER (WHERE " + inFlow + " AND r.weight_signed IS NULL) AS in_weight_unknown,\n"
                + "           COUNT(*) FILTER (WHERE " + outFlow + " AND r.weight_signed IS NULL) AS out_weight_unknown,\n"
                + "           COALESCE(SUM(r.weight_signed) FILTER (WHERE r.row_kind = 'W' AND r.adj_kind = 'RESIDUAL'"
                + period + "), 0) AS residual_kg\n"
                + "    FROM r\n"
                + ") s\n";
    }

    /**
     * 三个筛选桶 (一条语句): 类型桶受仓库+颜色范围, 仓库桶只受颜色, 颜色桶只受仓库; 都只计日期范围内的行。
     */
    static String facets(StockLedgerQuery q) {
        return "WITH f AS (\n"
                + "    SELECT 'M'::text AS row_kind, m.movement_type, m.warehouse_id, m.color_id,\n"
                + "           " + warehouseOk("m", q) + " AS wh_ok, " + colorOk("m", q) + " AS color_ok\n"
                + "    FROM stock_movements m\n"
                + "    WHERE m.goods_id = :goods" + dates("m", q) + "\n"
                + "    UNION ALL\n"
                + "    SELECT 'W', CAST(NULL AS smallint), a.warehouse_id, a.color_id,\n"
                + "           " + warehouseOk("a", q) + ", " + colorOk("a", q) + "\n"
                + "    FROM stock_weight_adjustments a\n"
                + "    WHERE a.goods_id = :goods" + dates("a", q) + "\n"
                + ")\n"
                + "SELECT 'movementType' AS dim,\n"
                + "       CASE WHEN f.row_kind = 'W' THEN 'W' ELSE f.movement_type::text END AS v,\n"
                + "       CAST(NULL AS text) AS label,\n"
                + "       COUNT(*) FILTER (WHERE f.wh_ok AND f.color_ok) AS n\n"
                + "FROM f GROUP BY 2\n"
                + "UNION ALL\n"
                + "SELECT 'warehouse', f.warehouse_id::text, MAX(wh.name), COUNT(*) FILTER (WHERE f.color_ok)\n"
                + "FROM f LEFT JOIN warehouses wh ON wh.id = f.warehouse_id GROUP BY f.warehouse_id\n"
                + "UNION ALL\n"
                + "SELECT 'color', COALESCE(f.color_id::text, '__null__'), MAX(c.name), COUNT(*) FILTER (WHERE f.wh_ok)\n"
                + "FROM f LEFT JOIN colors c ON c.id = f.color_id GROUP BY f.color_id\n";
    }

    // ------------------------------------------------------------------ fragments

    static String anchor(StockLedgerQuery q) {
        return """
                anchor AS (
                    SELECT COALESCE(SUM(b.qty), 0) AS qty_now,
                           CASE WHEN bool_or(b.qty <> 0 AND b.weight IS NULL) THEN NULL
                                ELSE COALESCE(SUM(b.weight), 0) END AS weight_now
                    FROM stock_balances b
                    WHERE b.goods_id = :goods""" + scope("b", q) + "\n)";
    }

    /** 范围内的流水与重量调整 (起始日期可裁; 截止日期不裁, 倒推需要更新的行)。 */
    static String rows(StockLedgerQuery q) {
        String from = q.from() == null ? "" : " AND %s.transaction_date >= :from";
        return """
                r AS (
                    SELECT 'M'::text AS row_kind, m.id, m.transaction_date, m.ledger_seq, m.movement_type, m.direction,
                           m.source_doc_type, m.source_doc_id, m.source_item_id, m.warehouse_id, m.color_id,
                           m.qty * m.direction AS qty_signed,
                           m.weight * m.direction AS weight_signed,
                           CASE WHEN m.weight IS NULL THEN NULL ELSE COALESCE(m.weight_source, 'MEASURED') END
                               AS weight_source,
                           CAST(NULL AS text) AS adj_kind, m.remark, m.created_by, m.amount_local
                    FROM stock_movements m
                    WHERE m.goods_id = :goods""" + scope("m", q) + from.formatted("m") + """

                    UNION ALL
                    SELECT 'W', a.id, a.transaction_date, a.ledger_seq, CAST(NULL AS smallint), CAST(NULL AS smallint),
                           a.source_doc_type, a.source_doc_id, a.source_item_id, a.warehouse_id, a.color_id,
                           CAST(0 AS numeric), a.delta_kg, CAST(NULL AS text), a.kind, a.reason, a.created_by,
                           CAST(NULL AS numeric)
                    FROM stock_weight_adjustments a
                    WHERE a.goods_id = :goods""" + scope("a", q) + from.formatted("a") + "\n)";
    }

    /** 范围条件: 仓库 (含下级) + 颜色。 */
    static String scope(String alias, StockLedgerQuery q) {
        StringBuilder sql = new StringBuilder();
        if (q.warehouseScope() != null) {
            sql.append(" AND ").append(alias).append(".warehouse_id IN (:scope)");
        }
        if (q.colorId() != null) {
            sql.append(" AND ").append(alias).append(".color_id = :color");
        } else if (q.colorNull()) {
            sql.append(" AND ").append(alias).append(".color_id IS NULL");
        }
        return sql.toString();
    }

    /** 显示条件 (窗口之后): 截止日期 + 行种类/类型/方向。 */
    static String display(StockLedgerQuery q, String alias) {
        String a = alias + ".";
        StringBuilder movement = new StringBuilder(a).append("row_kind = 'M'");
        if (!q.types().isEmpty()) {
            movement.append(" AND ").append(a).append("movement_type IN (:types)");
        }
        if (q.direction() != null) {
            movement.append(" AND ").append(a).append("direction = :direction");
        }
        String adjustment = a + "row_kind = 'W'";
        String kinds;
        if (q.showsMovements() && q.showsAdjustments()) {
            kinds = "((" + movement + ") OR (" + adjustment + "))";
        } else if (q.showsMovements()) {
            kinds = "(" + movement + ")";
        } else if (q.showsAdjustments()) {
            kinds = "(" + adjustment + ")";
        } else {
            kinds = "FALSE";
        }
        return q.toExclusive() == null ? kinds : a + "transaction_date < :toExcl AND " + kinds;
    }

    /** 本期收入/发出参与行: 出入库行 + 类型/方向筛选 + 截止日期 (起始日期已在 r 里裁掉)。 */
    static String flow(StockLedgerQuery q) {
        if (q.types().isEmpty() && q.adjustmentsRequested()) {
            return "FALSE";
        }
        StringBuilder sql = new StringBuilder("r.row_kind = 'M'");
        if (!q.types().isEmpty()) sql.append(" AND r.movement_type IN (:types)");
        if (q.direction() != null) sql.append(" AND r.direction = :direction");
        if (q.toExclusive() != null) sql.append(" AND r.transaction_date < :toExcl");
        return "(" + sql + ")";
    }

    /** 范围内部调拨: 不限仓库时所有调拨腿; 限定范围时对应腿也在范围内的调拨腿。 */
    static String internal(StockLedgerQuery q) {
        if (q.warehouseScope() == null) {
            return "(r.movement_type IN " + TRANSFER_TYPES + ")";
        }
        return "(r.movement_type IN " + TRANSFER_TYPES + " AND EXISTS (SELECT 1 FROM stock_movements peer"
                + " WHERE peer.goods_id = :goods AND peer.source_doc_type = r.source_doc_type"
                + " AND peer.source_doc_id = r.source_doc_id AND peer.source_item_id = r.source_item_id"
                + " AND peer.movement_type = 15 - r.movement_type AND peer.direction = -r.direction"
                + " AND peer.warehouse_id IN (:scope)))";
    }

    private static String warehouseOk(String alias, StockLedgerQuery q) {
        return q.warehouseScope() == null ? "TRUE" : "(" + alias + ".warehouse_id IN (:scope))";
    }

    private static String colorOk(String alias, StockLedgerQuery q) {
        if (q.colorId() != null) return "COALESCE(" + alias + ".color_id = :color, false)";
        if (q.colorNull()) return "(" + alias + ".color_id IS NULL)";
        return "TRUE";
    }

    private static String dates(String alias, StockLedgerQuery q) {
        StringBuilder sql = new StringBuilder();
        if (q.from() != null) sql.append(" AND ").append(alias).append(".transaction_date >= :from");
        if (q.toExclusive() != null) sql.append(" AND ").append(alias).append(".transaction_date < :toExcl");
        return sql.toString();
    }
}
