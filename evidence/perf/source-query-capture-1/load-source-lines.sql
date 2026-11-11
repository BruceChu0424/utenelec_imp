WITH subcontract_budget_allocations AS MATERIALIZED (SELECT source.*,
    SUM(source.allocated_qty) OVER(PARTITION BY source.action_id ORDER BY source.id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS planned_through_qty,
    COALESCE(SUM(source.allocated_qty) OVER(PARTITION BY source.action_id ORDER BY source.id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS planned_before_qty
FROM preplan_supply_action_allocations source WHERE source.analysis_id=:id
)
SELECT ai.id, ai.source_type, ai.sales_order_item_id,
       so.id, so.bill_no, so.bill_date,
       ai.delivery_date, c.name,
       ai.goods_id, g.code, g.name, g.spec,
       ai.color_id, col.name, ai.unit_id, u.name,
       COALESCE(soi.unit_rate,1), ai.requested_qty,
       ai.submitted_qty, ai.approved_qty,
       COALESCE(soi.qty, ai.requested_qty),
       COALESCE(soi.shipped_qty,0), COALESCE(soi.returned_qty,0),
       COALESCE(soi.flag_qty,0), COALESCE(soi.reserved_qty,0),
       COALESCE(soi.planned_qty,0), COALESCE(soi.produced_qty,0),
       COALESCE(draft.qty,0), so.status, so.is_stopped,
       so.is_closed, so.is_deleted, soi.is_deleted,
       ai.source_ref, ai.source_reason, ai.line_priority,
       ai.ready_now_qty, ai.ready_by_date_qty,
       ai.ready_start_qty, ai.ready_finish_qty, ai.ready_ship_qty,
       parent_item.id, parent_goods.name,
       COALESCE(so.finance_confirmed, FALSE),
       ai.root_material_id, CASE WHEN ai.source_type='AGGREGATE_MAKE' THEN COALESCE((
         SELECT SUM(shared_item.iqty*shared_item.unit_rate)
         FROM (SELECT * FROM production_plan_items archive_origin WHERE archive_origin.legacy_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='production_plan_items' AND archive_registry.row_id=archive_origin.id)) shared_item JOIN (SELECT * FROM production_plans archive_origin WHERE archive_origin.legacy_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='production_plans' AND archive_registry.row_id=archive_origin.id)) shared_plan ON shared_plan.id=shared_item.plan_id
         WHERE shared_plan.material_analysis_item_id=ai.id AND NOT shared_plan.is_deleted
           AND shared_plan.status=1 AND NOT shared_plan.is_canceled AND NOT shared_item.is_deleted),0)
         ELSE ai.root_fulfilled_qty END, root_material.confirmed_route,
       g.owning_warehouse_id, owning_warehouse.name,
       g.owning_workshop_department_id, owning_workshop.name,
       COALESCE(planned_surplus.qty, 0),
       COALESCE(root_subcontract.qty, 0), ai.delivery_plan_snapshot::text
FROM production_material_analysis_items ai
JOIN goods g ON g.id = ai.goods_id
JOIN units u ON u.id = ai.unit_id
LEFT JOIN LATERAL (
    -- ADR-143 §4.5：顶层委外件(顶层供给行确认为委外)的计划产出 = 它那几笔未结
    -- 委外申请的申请量 + 公共超量 − 合格入库回厂量(只算我方领料发外的份额,
    -- 基本单位)。第 1 层直属物料按来源行展开、不经 parentSupply, 所以并到这里。
    SELECT SUM(
(SELECT ROUND(COALESCE((
    SELECT CASE
        WHEN split.ordered_open_qty + split.unordered_qty > 0
        THEN quantity.qty * (split.ordered_open_qty + CASE WHEN split.drawable_now
                 THEN split.unordered_qty ELSE 0 END)
             / (split.ordered_open_qty + split.unordered_qty)
        WHEN split.drawable_now THEN quantity.qty ELSE 0 END
    FROM (
        SELECT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(application_item.goods_id))
                   AS drawable_now,
               GREATEST(application_item.qty * COALESCE(application_item.unit_rate,1)
                   - COALESCE(SUM(ordered.ordered_base),0), 0) AS unordered_qty,
               COALESCE(SUM(ordered.open_qty), 0) AS ordered_open_qty
        FROM LATERAL (
            WITH selected_draw_application AS MATERIALIZED (
                SELECT candidate.* FROM subcontract_application_items candidate
                WHERE candidate.id = allocation.external_item_id
            )
            SELECT archive_origin.* FROM selected_draw_application archive_origin
            WHERE archive_origin.legacy_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='subcontract_application_items' AND archive_registry.row_id=archive_origin.id)
        ) application_item
        LEFT JOIN LATERAL (
            SELECT src.alloc_qty * COALESCE(order_item.unit_rate,1) AS ordered_base,
                   fn_procurement_order_source_remaining_qty(
                       'SUBCONTRACT', order_item.id, src.application_item_id) AS open_qty
            FROM subcontract_order_item_sources src
            JOIN LATERAL (
                WITH selected_draw_order_item AS MATERIALIZED (
                    SELECT candidate.* FROM subcontract_order_items candidate
                    WHERE candidate.id = src.order_item_id AND src.application_item_id = application_item.id
                )
                SELECT archive_origin.* FROM selected_draw_order_item archive_origin
                WHERE archive_origin.legacy_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='subcontract_order_items' AND archive_registry.row_id=archive_origin.id)
            ) order_item
              ON order_item.id = src.order_item_id
             AND order_item.is_deleted = FALSE
            JOIN LATERAL (
                WITH selected_draw_order AS MATERIALIZED (
                    SELECT candidate.* FROM subcontract_orders candidate
                    WHERE candidate.id = order_item.order_id
                )
                SELECT archive_origin.* FROM selected_draw_order archive_origin
                WHERE archive_origin.legacy_id IS NULL AND archive_origin.legacy_import_run_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='subcontract_orders' AND archive_registry.row_id=archive_origin.id)
            ) subcontract_order
              ON subcontract_order.id = order_item.order_id
             AND subcontract_order.status = 1
             AND subcontract_order.is_deleted = FALSE
            WHERE src.application_item_id = application_item.id
        ) ordered ON TRUE
        WHERE application_item.id = allocation.external_item_id
        GROUP BY application_item.id, application_item.goods_id,
                 application_item.qty, application_item.unit_rate
    ) split),
    CASE WHEN EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(action.goods_id))
         THEN quantity.qty ELSE 0 END),4)
 FROM (SELECT ((SELECT COALESCE(
    ROUND(budget.qty*allocation.planned_through_qty/NULLIF(action.requested_qty,0),4)
    - ROUND(budget.qty*allocation.planned_before_qty/NULLIF(action.requested_qty,0),4),0)
 FROM (SELECT ROUND(GREATEST((action.requested_qty + action.public_surplus_qty - (COALESCE((
    SELECT SUM(fn_subcontract_order_source_share(item.id,source.application_item_id,
        GREATEST(COALESCE((
    SELECT SUM(CASE WHEN inspection.id IS NULL
                    THEN receipt_item.qty*COALESCE(receipt_item.unit_rate,1)
                WHEN inspection.status IN ('PARTIAL','RESOLVED')
                    THEN COALESCE(inspection.warehouse_stocked_base_qty,0)
                ELSE 0 END)
    FROM LATERAL (
        WITH selected_stock_receipt_item AS MATERIALIZED (
            SELECT candidate.* FROM subcontract_receipt_items candidate
            WHERE candidate.order_item_id = item.id
        )
        SELECT archive_origin.* FROM selected_stock_receipt_item archive_origin
        WHERE archive_origin.legacy_id IS NULL AND archive_origin.legacy_import_run_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='subcontract_receipt_items' AND archive_registry.row_id=archive_origin.id)
    ) receipt_item
    JOIN LATERAL (
        WITH selected_stock_receipt AS MATERIALIZED (
            SELECT candidate.* FROM subcontract_receipts candidate
            WHERE candidate.id = receipt_item.receipt_id
        )
        SELECT archive_origin.* FROM selected_stock_receipt archive_origin
        WHERE archive_origin.legacy_id IS NULL AND archive_origin.legacy_import_run_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='subcontract_receipts' AND archive_registry.row_id=archive_origin.id)
    ) receipt ON receipt.id=receipt_item.receipt_id
      AND receipt.status=1 AND NOT receipt.is_deleted
    LEFT JOIN procurement_inspection_items inspection ON inspection.receipt_type='SUBCONTRACT'
      AND inspection.receipt_item_id=receipt_item.id
    WHERE receipt_item.order_item_id=item.id AND NOT receipt_item.is_deleted),0)
  -(COALESCE(item.returned_qty,0)*COALESCE(item.unit_rate,1)),0)
))
    FROM subcontract_order_item_sources source
    JOIN LATERAL (
        WITH selected_stock_order_item AS MATERIALIZED (
            SELECT candidate.* FROM subcontract_order_items candidate
            WHERE candidate.id = source.order_item_id AND source.alloc_qty>0 AND source.application_item_id IN (
            SELECT allocation.external_item_id FROM preplan_supply_action_allocations allocation
            WHERE allocation.action_id=action.id AND allocation.external_item_id IS NOT NULL
            UNION
            SELECT action.public_surplus_external_item_id
            WHERE action.public_surplus_external_item_id IS NOT NULL)
        )
        SELECT archive_origin.* FROM selected_stock_order_item archive_origin
        WHERE archive_origin.legacy_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='subcontract_order_items' AND archive_registry.row_id=archive_origin.id)
    ) item ON item.id=source.order_item_id AND NOT item.is_deleted
    JOIN LATERAL (
        WITH selected_stock_order AS MATERIALIZED (
            SELECT candidate.* FROM subcontract_orders candidate
            WHERE candidate.id = item.order_id
        )
        SELECT archive_origin.* FROM selected_stock_order archive_origin
        WHERE archive_origin.legacy_id IS NULL AND archive_origin.legacy_import_run_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='subcontract_orders' AND archive_registry.row_id=archive_origin.id)
    ) document ON document.id=item.order_id
      AND document.status=1 AND NOT document.is_deleted
    WHERE source.alloc_qty>0 AND source.application_item_id IN (
        SELECT allocation.external_item_id FROM preplan_supply_action_allocations allocation
        WHERE allocation.action_id=action.id AND allocation.external_item_id IS NOT NULL
        UNION
        SELECT action.public_surplus_external_item_id
        WHERE action.public_surplus_external_item_id IS NOT NULL)
),0)
)),0),4) AS qty) budget)
)::numeric AS qty) quantity)
           ) AS qty
    FROM production_material_analysis_materials root
    JOIN subcontract_budget_allocations allocation
      ON allocation.analysis_material_id = root.id
    JOIN preplan_supply_actions action
      ON action.id = allocation.action_id
    WHERE root.analysis_id = ai.analysis_id
      AND root.analysis_item_id = ai.id
      AND root.node_role = 'ROOT_SUPPLY'
      AND action.operation_type = 'SUPPLY'
      AND action.route = 'SUBCONTRACT'
      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
      AND action.requested_qty > 0
) root_subcontract ON TRUE
LEFT JOIN LATERAL (
    -- 计划量单一入口(ADR-099)：本来源行已下达且仍有效的计划里
    -- 超出需求的公共备货产出合计。它与 submitted/approved 一起
    -- 构成「计划产出量」，下层物料按计划产出量展开。
    SELECT SUM(link.public_surplus_qty) AS qty
    FROM production_material_analysis_plan_links link
    WHERE link.analysis_id = ai.analysis_id
      AND link.analysis_item_id = ai.id
      AND link.allocation_status IN ('SUBMITTED','APPROVED')
) planned_surplus ON TRUE
LEFT JOIN warehouses owning_warehouse
  ON owning_warehouse.id = g.owning_warehouse_id
LEFT JOIN departments owning_workshop
  ON owning_workshop.id = g.owning_workshop_department_id
 AND owning_workshop.is_deleted = FALSE
LEFT JOIN colors col ON col.id = ai.color_id
LEFT JOIN (SELECT * FROM sales_order_items archive_origin WHERE archive_origin.legacy_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='sales_order_items' AND archive_registry.row_id=archive_origin.id)) soi ON soi.id = ai.sales_order_item_id
LEFT JOIN (SELECT * FROM sales_orders archive_origin WHERE archive_origin.legacy_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='sales_orders' AND archive_registry.row_id=archive_origin.id)) so ON so.id = soi.order_id
LEFT JOIN clients c ON c.id = so.client_id
LEFT JOIN LATERAL (
    -- 2026-09-15（V588 单计划超量）：分析来源的草稿计划只把
    -- 「归本需求的量」（plan link 的 submitted_qty）计入销售
    -- 容量占用——公共备货产出（public_surplus_qty）不占订单
    -- 可排量，否则「需求 1000 实下 5000」会在自身审核的二次
    -- 校验里把剩余可排算成负数（available = 需求 − 超量）。
    -- 非分析的手工草稿照旧整行计入（1:1 销售来源）。
    SELECT SUM(CASE
        WHEN link.id IS NOT NULL THEN link.submitted_qty
        ELSE pi.qty END) AS qty
    FROM (SELECT * FROM production_plan_items archive_origin WHERE archive_origin.legacy_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='production_plan_items' AND archive_registry.row_id=archive_origin.id)) pi
    JOIN (SELECT * FROM production_plans archive_origin WHERE archive_origin.legacy_id IS NULL AND NOT EXISTS(SELECT 1 FROM imported_document_registry archive_registry WHERE archive_registry.table_name='production_plans' AND archive_registry.row_id=archive_origin.id)) p ON p.id = pi.plan_id
    LEFT JOIN production_material_analysis_plan_links link
      ON link.plan_id = p.id
     AND link.analysis_id = p.material_analysis_id
     AND link.analysis_item_id = p.material_analysis_item_id
    WHERE pi.sales_order_item_id = soi.id
      AND pi.is_deleted = FALSE
      AND p.is_deleted = FALSE AND p.status = 0
      AND p.is_canceled = FALSE
) draft ON TRUE
LEFT JOIN production_material_analysis_materials parent_material
  ON parent_material.id = ai.parent_analysis_material_id
LEFT JOIN production_material_analysis_items parent_item
  ON parent_item.id = parent_material.analysis_item_id
LEFT JOIN goods parent_goods ON parent_goods.id = parent_item.goods_id
LEFT JOIN production_material_analysis_materials root_material ON root_material.id=ai.root_material_id
WHERE ai.analysis_id = :id AND ai.is_deleted = FALSE
ORDER BY ai.line_priority, ai.delivery_date NULLS LAST, ai.id
