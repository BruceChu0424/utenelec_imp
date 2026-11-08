package com.uten.imp.businesschain;

import org.hibernate.resource.jdbc.spi.StatementInspector;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertTrue;

/** Persistence transport for the version-pinned inventory scenarios before V1108/V1109.
 * PostgreSQL still executes the original writes, locks and catalog guards. */
public final class HistoricalInventoryPlanningSql implements StatementInspector {
    static final String PROPERTY =
            "spring.jpa.properties.hibernate.session_factory.statement_inspector="
                    + "com.uten.imp.businesschain.HistoricalInventoryPlanningSql";
    static final String BEFORE_V1097_PROPERTY = PROPERTY + "$BeforeV1097";
    private static final String ROOT_SUPPLY_STATEMENT =
            "4072299f5e9898ab161e1e71ae5c52b633b53bda759dcec1d9f45a4436ae4050";

    private static final String ABSENT_SALES_CLAIMS = """
            SELECT root_material_id, requested_qty FROM production_material_analysis_items
            WHERE analysis_id=? AND FALSE
            """;
    private static final String NO_PRIVATE_SALES_STOCK = """
            SELECT CAST('Unexpected private sales stock in original planning scenario: ' || reservation.id::text AS uuid)
            FROM production_material_analysis_items item
            JOIN stock_reservations reservation ON reservation.order_item_id=item.sales_order_item_id
              AND reservation.owner_type='SALES_ORDER_ITEM' AND reservation.owner_id=item.sales_order_item_id
              AND reservation.goods_id=item.goods_id AND reservation.color_id IS NOT DISTINCT FROM item.color_id
              AND reservation.source_doc_type IN('SALES_ORDER','SALES_ORDER_CHANGE')
              AND reservation.status=0 AND NOT reservation.is_deleted
            WHERE item.analysis_id=? AND NOT item.is_deleted AND item.root_material_id IS NOT NULL
              AND reservation.qty>reservation.consumed_qty+reservation.released_qty
            """;

    // These scenarios exercise MAKE only. Check the exact real historical source
    // scope and fail if a live subcontract action would need modern projection.
    private static final String NO_SUBCONTRACT_SOURCE = """
            SELECT CAST('Unexpected subcontract action in original MAKE scenario: ' || action.id::text AS uuid)
            FROM preplan_supply_actions action
            WHERE action.analysis_id=ALL(ARRAY[?::uuid,?::uuid,?::uuid,?::uuid,?::uuid,?::uuid])
              AND action.route='SUBCONTRACT' AND action.operation_type='SUPPLY'
              AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
              AND action.external_document_type='SUBCONTRACT_APPLICATION'
              AND (action.requested_qty>0 OR action.public_surplus_qty>0)
            """;
    private static final Map<String,String> PRE_V1097 = Map.of(
            "02867918d5820df3915c963d2b73f4cc21e4f6e7e03ef2264e610692be6c706b", NO_SUBCONTRACT_SOURCE,
            "24f9bbb4502153ac3e9f180b2849586865703927ce707332fc3530d711345560", NO_SUBCONTRACT_SOURCE);

    private static final Map<String,String> ORIGINAL = Map.of(
            // The original source INSERT from 396baff53 keeps every JDBC operand.
            "c63a7c108a9304086004ca49aaf4ae20645826d147c2b3ec3eda3ab7bb8ddae4", """
                    INSERT INTO production_material_analysis_items (
                        id, analysis_id, source_type, sales_order_item_id,
                        goods_id, color_id, unit_id, source_ref, source_reason,
                        requested_qty, delivery_date, line_priority,
                        created_by, updated_by
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
            // Neither a same-sales adoption nor a coverage-total source was
            // representable. Guard against supplying current same-sales stock.
            "f98501e91cb422f33652222b6d050447ad7004531fc819ddef2642063911caff", ABSENT_SALES_CLAIMS,
            "6cc0c19f9f23f02ec42c8f4b521f1538660c0ed789c57b503d95fe0762c1a018", NO_PRIVATE_SALES_STOCK,
            "59b0298724eafb9832922715f66c0df3f3704e867c7ff9d1b9a2b07e126cdbb0", NO_PRIVATE_SALES_STOCK
                    + "AND item.root_material_id=? ORDER BY reservation.id FOR UPDATE OF reservation",
            // The formalization flag stays a typed JDBC operand. Only original
            // reservation facts participate; the newer handoff ledger is absent.
            "23f2ab6c61167bd6148491eeb611ccde2f3c119cb0bf63b23d1d66db7105a5a3", """
                    WITH request AS (SELECT CAST(? AS boolean) formalized, CAST(? AS uuid) analysis_id)
                    SELECT reservation.supply_id, SUM(GREATEST(
                        reservation.qty-reservation.consumed_qty-reservation.released_qty,0))
                    FROM stock_reservations reservation
                    JOIN production_material_analyses analysis ON analysis.id=reservation.owner_id
                    CROSS JOIN request
                    WHERE request.formalized IS NOT NULL
                      AND reservation.owner_type='PREPLAN_ANALYSIS' AND reservation.owner_id=request.analysis_id
                      AND reservation.source_doc_type='PREPLAN_STOCK_BALANCE' AND reservation.supply_type='STOCK_BALANCE'
                      AND reservation.source_doc_id=reservation.supply_id
                      AND reservation.status=0 AND NOT reservation.is_deleted
                      AND NOT analysis.is_deleted AND analysis.status<>'CANCELLED'
                    GROUP BY reservation.supply_id
                    """,
            "6d704f99d11f0f4470db7573ad004f1243bdeca4d3eb7cfa572a50cd5f64917b", """
                    SELECT id FROM production_material_analysis_items WHERE analysis_id=? AND FALSE
                    """);

    // 9a73f9584 的「到货优先补原父层」投影自 V1118 起存在，历史架构（<=1099）没有这些
    // 函数和优先分配表。历史场景继续按原承诺口径证明 V1100/V1113 的续跑语义，这里把带
    // 优先投影的语句还原成无该投影的等价 SQL：列数与 ? 占位符个数保持不变，优先能力在
    // 旧架构上恰好退化为不存在（headroom 列为 NULL、优先 planning_qty 恒等于 pending_qty、
    // 优先阻塞守卫恒不成立），与引入该提交之前的行为一致。
    private static final Pattern RECEIPT_PRIORITY_PLANNING_LATERAL = Pattern.compile(
            "CROSS JOIN LATERAL \\(\\s*SELECT CASE WHEN action\\.route IN \\('BUY','SUBCONTRACT'\\)\\s*"
                    + "AND action\\.operation_type='SUPPLY' AND pending_qty\\.qty>0\\s*"
                    + "THEN fn_preplan_receipt_priority_planning_qty\\(allocation\\.id,pending_qty\\.qty\\)\\s*"
                    + "ELSE pending_qty\\.qty END AS qty\\s*\\) planning_qty");
    private static final Pattern RECEIPT_PRIORITY_INTENT_PENDING = Pattern.compile(
            "CASE WHEN raw\\.pending_qty>0 AND fn_preplan_receipt_priority_enabled\\(raw\\.analysis_material_id\\)\\s*"
                    + "THEN fn_preplan_receipt_priority_planning_qty\\(raw\\.id,raw\\.pending_qty\\)\\s*"
                    + "ELSE raw\\.pending_qty END AS pending_qty");
    private static final Pattern RECEIPT_PRIORITY_CLAIMANT_HEADROOM = Pattern.compile(
            "CASE WHEN action\\.operation_type='SUPPLY'\\s*"
                    + "THEN fn_preplan_receipt_priority_order_headroom\\(material\\.id\\)\\s*"
                    + "END AS priority_headroom");
    private static final Pattern RECEIPT_PRIORITY_BLOCKED_MATERIAL = Pattern.compile(
            "CASE WHEN EXISTS \\(\\s*SELECT 1 FROM preplan_supply_action_allocations allocation\\s*"
                    + "JOIN preplan_receipt_priority_allocations priority ON priority\\.allocation_id=allocation\\.id\\s*"
                    + "JOIN preplan_supply_actions action ON action\\.id=allocation\\.action_id\\s*"
                    + "WHERE allocation\\.analysis_material_id=child\\.id.*?child\\.id::text\\) END\\s*END",
            Pattern.DOTALL);

    private static boolean mentionsReceiptPriority(String sql) {
        return sql.contains("fn_preplan_receipt_priority") || sql.contains("preplan_receipt_priority_allocations");
    }

    /** @return 无优先投影的等价语句；不认识带优先标记的语句或占位符数变化时返回 null 原样放行。 */
    private static String revertReceiptPriorityProjections(String sql) {
        if (!mentionsReceiptPriority(sql)) return null;
        String reverted = sql;
        Matcher lateral = RECEIPT_PRIORITY_PLANNING_LATERAL.matcher(reverted);
        if (lateral.find()) {
            reverted = new StringBuilder(reverted).delete(lateral.start(), lateral.end()).toString()
                    .replace("planning_qty.qty", "pending_qty.qty");
        }
        reverted = RECEIPT_PRIORITY_INTENT_PENDING.matcher(reverted).replaceFirst("raw.pending_qty AS pending_qty");
        reverted = RECEIPT_PRIORITY_CLAIMANT_HEADROOM.matcher(reverted).replaceFirst("NULL::numeric AS priority_headroom");
        reverted = RECEIPT_PRIORITY_BLOCKED_MATERIAL.matcher(reverted).replaceFirst("NULL::text");
        // 未消除干净或占位符被改动时不得猜测改写：按原语句放行，让数据库报出确切缺失对象。
        if (mentionsReceiptPriority(reverted)
                || reverted.chars().filter(ch -> ch == '?').count() != sql.chars().filter(ch -> ch == '?').count()) {
            return null;
        }
        return reverted;
    }

    static void requireOriginalPlanningSchema(JdbcTemplate jdbc) {
        assertTrue(jdbc.queryForObject("""
                SELECT to_regclass('public.preplan_sales_stock_adoptions') IS NULL
                  AND to_regclass('public.preplan_physical_stock_formalizations') IS NULL
                  AND to_regprocedure('public.fn_preplan_adopted_sales_stock_base(uuid)') IS NULL
                  AND NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
                    AND table_name='production_material_analysis_items' AND column_name='planning_quantity_mode')
                  AND NOT EXISTS(SELECT 1 FROM stock_reservations WHERE source_doc_type='PREPLAN_STOCK_BALANCE')
                """, Boolean.class));
    }

    @Override
    public String inspect(String sql) {
        // Revert the newest projection first, then let the older planning reverts see the
        // statement in the shape their fingerprints were taken from.
        String withoutReceiptPriority = revertReceiptPriorityProjections(sql);
        if (withoutReceiptPriority != null) sql = withoutReceiptPriority;
        if (!sql.contains("planning_quantity_mode") && !sql.contains("fn_preplan_adopted_sales_stock_base")
                && !sql.contains("preplan_physical_stock_formalizations")) {
            return sql;
        }
        String fingerprint = HistoricalSubcontract1032SqlTransport.fingerprint(sql);
        if (ROOT_SUPPLY_STATEMENT.equals(fingerprint)) {
            // 396baff53 counted the persisted output events before there was a separate adoption fact.
            return sql.replace("+fn_preplan_adopted_sales_stock_base(item.id)", "");
        }
        return ORIGINAL.getOrDefault(fingerprint, sql);
    }

    public static final class BeforeV1097 implements StatementInspector {
        private final HistoricalInventoryPlanningSql planning = new HistoricalInventoryPlanningSql();

        @Override
        public String inspect(String sql) {
            if (sql.contains("fn_subcontract_actual_receipt_material_qty")) {
                var historical = PRE_V1097.get(HistoricalSubcontract1032SqlTransport.fingerprint(sql));
                if (historical != null) return historical;
            }
            return planning.inspect(sql);
        }
    }
}
