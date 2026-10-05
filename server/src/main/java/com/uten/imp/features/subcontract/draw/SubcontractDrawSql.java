package com.uten.imp.features.subcontract.draw;

import com.uten.imp.common.finance.SubcontractLossSettlementSql;

/**
 * ADR-143 委外领料读模型共用的 SQL 片段(全部是服务端常量, 不拼任何用户输入)。
 *
 * <p>数量口径只在数据库函数里算一次: {@code fn_subcontract_draw_summary}(行级已领/待发/可领/还缺)、
 * {@code fn_subcontract_draw_facts}(物料级)、{@code fn_subcontract_draw_line_stock}(逐仓可动用量)。
 * 这里只拼「哪些订货明细算领料任务」与显示用主档。
 */
public final class SubcontractDrawSql {

    private SubcontractDrawSql() {
    }

    /** 订货明细 + 订货单头 + 领料计划 + 显示用主档。别名 oi / o / p / supplier / goods / color / unit。 */
    static final String ITEM_FROM = """
            FROM subcontract_order_items oi
            JOIN subcontract_orders o ON o.id = oi.order_id
            JOIN subcontract_material_plans p ON p.order_id = o.id AND NOT p.is_deleted
            LEFT JOIN suppliers supplier ON supplier.id = o.supplier_id
            LEFT JOIN goods goods ON goods.id = oi.goods_id
            LEFT JOIN colors color ON color.id = oi.color_id
            LEFT JOIN units unit ON unit.id = oi.unit_id
            """;

    /** 已获财务批准、未删除的订货明细(不看计划状态): 任务详情读取用。 */
    static final String APPROVED_ITEM_PREDICATE =
            " NOT oi.is_deleted AND o.status = 1 AND NOT o.is_deleted ";

    /**
     * 领料任务(ADR-143 §4.1): 财务已批准、领料计划 OPEN、订货明细未结清(净回厂 + 已结损耗 &lt; 订货量)、
     * 还有没发完的开放计划行。「没发完」按我方需发量 {@code fn_subcontract_draw_needed_qty}
     * (= LEAST(计划量, f(Qm)), §三.4a: 财务批准的委外商自带料那部分不用我方物料)。别名同 {@link #ITEM_FROM}。
     */
    public static final String OPEN_ITEM_PREDICATE = APPROVED_ITEM_PREDICATE + """
             AND NOT o.is_closed AND p.status = 'OPEN'
             AND EXISTS (
                 SELECT 1 FROM subcontract_material_plan_items open_line
                 WHERE open_line.plan_id = p.id AND open_line.order_item_id = oi.id
                   AND NOT open_line.is_deleted AND open_line.draw_closed_at IS NULL
                   AND open_line.issued_qty < fn_subcontract_draw_needed_qty(
                       open_line.order_item_id, open_line.planned_qty, open_line.bom_unit_qty))
             AND GREATEST(COALESCE(oi.received_qty, 0) - COALESCE(oi.returned_qty, 0), 0)
                 + fn_subcontract_settled_loss_qty(oi.id) < oi.qty
            """;

    /** 行身份与显示列(与 {@link #ITEM_FROM} 搭配)。 */
    static final String ROW_COLUMNS = """
            oi.id AS order_item_id, o.id AS order_id, o.bill_no AS order_bill_no, oi.line_no,
            o.supplier_id, supplier.name AS supplier_name,
            oi.goods_id, COALESCE(oi.goods_code_snapshot, goods.code) AS goods_code,
            COALESCE(oi.goods_name_snapshot, goods.name) AS goods_name,
            oi.color_id, color.name AS color_name, oi.unit_id, unit.name AS unit_name,
            COALESCE(oi.deliver_date, o.deliver_date) AS deliver_date, o.maker_id
            """;

    /** 本订货明细是否挂着仓库还没发出的领料草稿行。 */
    static final String PENDING_DRAFT_EXISTS = """
            EXISTS (
                SELECT 1 FROM subcontract_material_issue_items pending_item
                JOIN subcontract_material_issues pending_issue ON pending_issue.id = pending_item.issue_id
                 AND pending_issue.status = 0 AND NOT pending_issue.is_deleted
                WHERE pending_item.order_item_id = oi.id AND pending_item.plan_item_id IS NOT NULL
                  AND NOT pending_item.is_deleted)
            """;

    /**
     * 行状态(ADR-143 §4.1 优先级: 可领 &gt; 已提交 &gt; 等计划安排 &gt; 等待物料)。
     * 依赖列 drawable_qty / material_qty(我方供料套数 Qm) / complete_qty / has_pending / unplanned_short_kind_count。
     */
    static final String STATUS_CASE = """
            CASE WHEN drawable_qty > 0 AND drawable_qty >= material_qty - complete_qty THEN 'DRAWABLE'
                 WHEN drawable_qty > 0 THEN 'DRAWABLE_PARTIAL'
                 WHEN has_pending THEN 'DRAW_SUBMITTED'
                 WHEN unplanned_short_kind_count > 0 THEN 'WAITING_PLANNING'
                 ELSE 'WAITING_MATERIAL' END
            """;

    /** 与 {@link #STATUS_CASE} 同序的排序键。 */
    static final String STATUS_RANK_CASE = """
            CASE WHEN drawable_qty > 0 AND drawable_qty >= material_qty - complete_qty THEN 0
                 WHEN drawable_qty > 0 THEN 1
                 WHEN has_pending THEN 2
                 WHEN unplanned_short_kind_count > 0 THEN 3
                 ELSE 4 END
            """;

    private static final String OPEN_SUPPLY_TEMPLATE = """
            SELECT 'PURCHASE' AS kind, request.id AS doc_id, request.bill_no AS doc_no,
                   SUM(GREATEST(request_item.qty - COALESCE(request_item.ordered_qty, 0), 0)
                       * COALESCE(request_item.unit_rate, 1)) AS open_qty
            FROM purchase_request_items request_item
            JOIN purchase_requests request ON request.id = request_item.request_id
             AND request.status = 1 AND NOT request.is_closed AND NOT request.is_deleted
            WHERE NOT request_item.is_deleted
              AND request_item.goods_id = {GOODS}
              AND request_item.color_id IS NOT DISTINCT FROM {COLOR}
            GROUP BY request.id, request.bill_no
            HAVING SUM(GREATEST(request_item.qty - COALESCE(request_item.ordered_qty, 0), 0)) > 0
            UNION ALL
            SELECT 'PURCHASE', order_doc.id, order_doc.bill_no,
                   SUM(GREATEST(COALESCE(order_item.qty, 0) * COALESCE(order_item.unit_rate, 1)
                       - COALESCE(stocked.base_qty, 0)
                       + COALESCE(order_item.returned_qty, 0) * COALESCE(order_item.unit_rate, 1), 0))
            FROM purchase_order_items order_item
            JOIN purchase_orders order_doc ON order_doc.id = order_item.order_id
             AND order_doc.status = 1 AND NOT order_doc.is_closed AND NOT order_doc.is_deleted
            LEFT JOIN LATERAL (
                SELECT SUM(CASE WHEN inspection.id IS NULL
                                     THEN receipt_item.qty * COALESCE(receipt_item.unit_rate, 1)
                                WHEN inspection.status = 'REVERSED' THEN 0
                                ELSE inspection.warehouse_stocked_base_qty END) AS base_qty
                FROM purchase_receipt_items receipt_item
                JOIN purchase_receipts receipt_doc ON receipt_doc.id = receipt_item.receipt_id
                 AND receipt_doc.status = 1 AND NOT receipt_doc.is_deleted
                LEFT JOIN procurement_inspection_items inspection
                  ON inspection.receipt_type = 'PURCHASE' AND inspection.receipt_item_id = receipt_item.id
                WHERE receipt_item.order_item_id = order_item.id AND NOT receipt_item.is_deleted
            ) stocked ON TRUE
            WHERE NOT order_item.is_deleted
              AND order_item.goods_id = {GOODS}
              AND order_item.color_id IS NOT DISTINCT FROM {COLOR}
            GROUP BY order_doc.id, order_doc.bill_no
            HAVING SUM(GREATEST(COALESCE(order_item.qty, 0) * COALESCE(order_item.unit_rate, 1)
                       - COALESCE(stocked.base_qty, 0)
                       + COALESCE(order_item.returned_qty, 0) * COALESCE(order_item.unit_rate, 1), 0)) > 0
            UNION ALL
            SELECT 'SUBCONTRACT', order_doc.id, order_doc.bill_no,
                   SUM(GREATEST(COALESCE(order_item.qty, 0) * COALESCE(order_item.unit_rate, 1)
                       - COALESCE(stocked.base_qty, 0)
                       + COALESCE(order_item.returned_qty, 0) * COALESCE(order_item.unit_rate, 1)
                       - {SETTLED_LOSS} * COALESCE(order_item.unit_rate, 1), 0))
            FROM subcontract_order_items order_item
            JOIN subcontract_orders order_doc ON order_doc.id = order_item.order_id
             AND order_doc.status = 1 AND NOT order_doc.is_closed AND NOT order_doc.is_deleted
            LEFT JOIN LATERAL (
                SELECT SUM(CASE WHEN inspection.id IS NULL
                                     THEN receipt_item.qty * COALESCE(receipt_item.unit_rate, 1)
                                WHEN inspection.status = 'REVERSED' THEN 0
                                ELSE inspection.warehouse_stocked_base_qty END) AS base_qty
                FROM subcontract_receipt_items receipt_item
                JOIN subcontract_receipts receipt_doc ON receipt_doc.id = receipt_item.receipt_id
                 AND receipt_doc.status = 1 AND NOT receipt_doc.is_deleted
                LEFT JOIN procurement_inspection_items inspection
                  ON inspection.receipt_type = 'SUBCONTRACT' AND inspection.receipt_item_id = receipt_item.id
                WHERE receipt_item.order_item_id = order_item.id AND NOT receipt_item.is_deleted
            ) stocked ON TRUE
            WHERE NOT order_item.is_deleted
              AND order_item.goods_id = {GOODS}
              AND order_item.color_id IS NOT DISTINCT FROM {COLOR}
            GROUP BY order_doc.id, order_doc.bill_no
            HAVING SUM(GREATEST(COALESCE(order_item.qty, 0) * COALESCE(order_item.unit_rate, 1)
                       - COALESCE(stocked.base_qty, 0)
                       + COALESCE(order_item.returned_qty, 0) * COALESCE(order_item.unit_rate, 1)
                       - {SETTLED_LOSS} * COALESCE(order_item.unit_rate, 1), 0)) > 0
            UNION ALL
            SELECT 'SUBCONTRACT', application.id, application.bill_no,
                   SUM(GREATEST(application_item.qty - COALESCE(application_item.ordered_qty, 0), 0)
                       * COALESCE(application_item.unit_rate, 1))
            FROM subcontract_application_items application_item
            JOIN subcontract_applications application ON application.id = application_item.application_id
             AND application.status = 1 AND NOT application.is_closed AND NOT application.is_deleted
            WHERE NOT application_item.is_deleted
              AND application_item.goods_id = {GOODS}
              AND application_item.color_id IS NOT DISTINCT FROM {COLOR}
            GROUP BY application.id, application.bill_no
            HAVING SUM(GREATEST(application_item.qty - COALESCE(application_item.ordered_qty, 0), 0)) > 0
            UNION ALL
            SELECT 'PRODUCTION', production_plan.id, production_plan.bill_no,
                   SUM(GREATEST(production_item.qty * COALESCE(production_item.unit_rate, 1)
                       - COALESCE(stocked.base_qty, 0), 0))
            FROM production_plan_items production_item
            JOIN production_plans production_plan ON production_plan.id = production_item.plan_id
             AND production_plan.status = 1 AND NOT production_plan.is_deleted
             AND NOT production_plan.is_closed AND NOT production_plan.is_canceled
             AND NOT production_plan.is_stopped
            LEFT JOIN LATERAL (
                SELECT SUM(stock_item.base_qty) AS base_qty
                FROM stock_document_items stock_item
                JOIN stock_documents stock_doc ON stock_doc.id = stock_item.doc_id
                 AND stock_doc.status = 1 AND NOT stock_doc.is_deleted
                WHERE stock_item.upstream_item_id = production_item.id
                  AND stock_item.bill_type = 'FINISHED_IN' AND NOT stock_item.is_deleted
            ) stocked ON TRUE
            WHERE NOT production_item.is_deleted
              AND production_item.goods_id = {GOODS}
              AND production_item.color_id IS NOT DISTINCT FROM {COLOR}
            GROUP BY production_plan.id, production_plan.bill_no
            HAVING SUM(GREATEST(production_item.qty * COALESCE(production_item.unit_rate, 1)
                       - COALESCE(stocked.base_qty, 0), 0)) > 0
            """;

    /**
     * 一种物料(货色)的在途供应来源, 每张单据一行 {@code (kind, doc_id, doc_no, open_qty)},
     * open_qty 为基本单位的未到量: 已审采购申请未下单量、已审未关闭的采购/委外订货未合格入库量(扣退货, 委外再扣已结损耗)、
     * 已审委外申请未下单量、已审有效生产计划未成品入库量。
     *
     * @param goods 货品 UUID 的 SQL 表达式(服务端常量)
     * @param color 颜色 UUID 的 SQL 表达式(服务端常量, 值可为 NULL)
     */
    static String openSupplySources(String goods, String color) {
        return OPEN_SUPPLY_TEMPLATE
                .replace("{SETTLED_LOSS}", SubcontractLossSettlementSql.acceptedLossQty("order_item.id"))
                .replace("{GOODS}", goods)
                .replace("{COLOR}", color);
    }
}
