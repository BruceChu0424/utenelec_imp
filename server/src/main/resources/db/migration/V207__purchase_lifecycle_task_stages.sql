-- V207: 采购任务中心扩展为多生命周期阶段（申请待分解 / 财务已批准·待采购完成 / 已完成）。
--
-- V199 的投影只把采购申请行标成 WAITING_ORDER，且 open_qty > 0 把已完成的订单过滤掉，
-- 任务台只能看到「待分解」一档。本迁移 CREATE OR REPLACE 同名视图，新增 purchase_order_rows
-- CTE：把已生效采购订单（status=1）的明细行按 is_closed 分到 FINANCE_APPROVED（待采购完成）
-- 与 COMPLETED（已完成）两档，与原 purchase_rows / subcontract_rows 同列同序 UNION ALL，
-- 使 FulfillmentWorkbenchQueryService 的 statusCounts 自然出现新桶、列表可按状态筛选。
--
-- 已完成档设 30 天保留窗（按订单 updated_at），避免历史无限堆积。
-- 列名/类型/顺序必须与 purchase_rows 完全一致（mapRow 按固定列位读 31 列）。

CREATE OR REPLACE VIEW v_procurement_decomposition_tasks AS
WITH purchase_pending AS (
    SELECT oi.request_item_id AS source_item_id, SUM(COALESCE(oi.qty, 0)) AS pending_qty
    FROM procurement_order_approval_cases approval
    JOIN purchase_orders po
      ON approval.order_type = 'PURCHASE'
     AND approval.order_id = po.id
     AND approval.status = 'PENDING'
    JOIN purchase_order_items oi ON oi.order_id = po.id
    WHERE po.status = 0
      AND po.is_deleted = FALSE
      AND oi.is_deleted = FALSE
      AND oi.request_item_id IS NOT NULL
    GROUP BY oi.request_item_id
),
subcontract_pending AS (
    SELECT oi.application_item_id AS source_item_id, SUM(COALESCE(oi.qty, 0)) AS pending_qty
    FROM procurement_order_approval_cases approval
    JOIN subcontract_orders so
      ON approval.order_type = 'SUBCONTRACT'
     AND approval.order_id = so.id
     AND approval.status = 'PENDING'
    JOIN subcontract_order_items oi ON oi.order_id = so.id
    WHERE so.status = 0
      AND so.is_deleted = FALSE
      AND oi.is_deleted = FALSE
      AND oi.application_item_id IS NOT NULL
    GROUP BY oi.application_item_id
),
purchase_rows AS (
    SELECT
        'PURCHASE'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.production_plan_no, ''), NULLIF(item.source_doc_no, ''),
                 NULLIF(request.source_doc_no, ''), request.bill_no) AS plan_no,
        request.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'BUY'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.ordered_qty, 0) + COALESCE(pending.pending_qty, 0) AS allocated_qty,
        COALESCE(item.ordered_qty, 0) AS fulfilled_qty,
        COALESCE(item.ordered_qty, 0) + COALESCE(pending.pending_qty, 0) AS supply_pegged_qty,
        GREATEST(COALESCE(item.qty, 0) - COALESCE(item.ordered_qty, 0)
                 - COALESCE(pending.pending_qty, 0), 0) AS open_qty,
        'WAITING_ORDER'::TEXT AS task_status,
        COALESCE(item.deliver_date, request.need_date) AS need_date,
        COALESCE(item.deliver_date, request.need_date) AS expected_date,
        CASE
            WHEN COALESCE(item.deliver_date, request.need_date) < CURRENT_DATE
                THEN 'OVERDUE'
            ELSE NULL
        END::TEXT AS exception_code,
        GREATEST(item.updated_at, request.updated_at) AS updated_at,
        'PURCHASE_REQUEST'::TEXT AS action_doc_type,
        request.id AS action_doc_id,
        request.bill_no AS action_doc_no,
        item.id AS action_item_id,
        request.status::TEXT AS action_doc_status
    FROM purchase_request_items item
    JOIN purchase_requests request ON request.id = item.request_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = request.warehouse_id
    LEFT JOIN purchase_pending pending ON pending.source_item_id = item.id
    WHERE request.status = 1
      AND request.is_deleted = FALSE
      AND request.is_closed = FALSE
      AND item.is_deleted = FALSE
),
purchase_order_rows AS (
    SELECT
        'PURCHASE'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), NULLIF(item.production_plan_no, ''),
                 po.bill_no) AS plan_no,
        po.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'BUY'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.qty, 0) AS allocated_qty,
        GREATEST(COALESCE(item.received_qty, 0) - COALESCE(item.returned_qty, 0), 0) AS fulfilled_qty,
        COALESCE(item.qty, 0) AS supply_pegged_qty,
        GREATEST(COALESCE(item.qty, 0) - COALESCE(item.received_qty, 0)
                 + COALESCE(item.returned_qty, 0), 0) AS open_qty,
        CASE WHEN po.is_closed THEN 'COMPLETED' ELSE 'FINANCE_APPROVED' END::TEXT AS task_status,
        COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS need_date,
        COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS expected_date,
        CASE
            WHEN NOT po.is_closed
                 AND COALESCE(item.deliver_date, po.deliver_date) < CURRENT_DATE
                THEN 'OVERDUE'
            ELSE NULL
        END::TEXT AS exception_code,
        GREATEST(item.updated_at, po.updated_at) AS updated_at,
        'PURCHASE_ORDER'::TEXT AS action_doc_type,
        po.id AS action_doc_id,
        po.bill_no AS action_doc_no,
        item.id AS action_item_id,
        po.status::TEXT AS action_doc_status
    FROM purchase_order_items item
    JOIN purchase_orders po ON po.id = item.order_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = po.warehouse_id
    WHERE po.status = 1
      AND po.is_deleted = FALSE
      AND item.is_deleted = FALSE
      AND (NOT po.is_closed OR po.updated_at >= CURRENT_DATE - INTERVAL '30 days')
),
purchase_rejected_rows AS (
    -- 财务驳回：订货单提交财务审核后被驳回（status 仍为 0 草稿），且当前无新的待审核
    -- 案件（已驳回未重新提交）。EXISTS/NOT EXISTS 避免多次审核历史导致的行重复。
    SELECT
        'PURCHASE'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), NULLIF(item.production_plan_no, ''),
                 po.bill_no) AS plan_no,
        po.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'BUY'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.qty, 0) AS allocated_qty,
        GREATEST(COALESCE(item.received_qty, 0) - COALESCE(item.returned_qty, 0), 0) AS fulfilled_qty,
        COALESCE(item.qty, 0) AS supply_pegged_qty,
        COALESCE(item.qty, 0) AS open_qty,
        'FINANCE_REJECTED'::TEXT AS task_status,
        COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS need_date,
        COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS expected_date,
        NULL::TEXT AS exception_code,
        GREATEST(item.updated_at, po.updated_at) AS updated_at,
        'PURCHASE_ORDER'::TEXT AS action_doc_type,
        po.id AS action_doc_id,
        po.bill_no AS action_doc_no,
        item.id AS action_item_id,
        po.status::TEXT AS action_doc_status
    FROM purchase_order_items item
    JOIN purchase_orders po ON po.id = item.order_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = po.warehouse_id
    WHERE po.status = 0
      AND po.is_deleted = FALSE
      AND item.is_deleted = FALSE
      AND EXISTS (
          SELECT 1 FROM procurement_order_approval_cases rej
          WHERE rej.order_type = 'PURCHASE' AND rej.order_id = po.id
            AND rej.status = 'REJECTED'
      )
      AND NOT EXISTS (
          SELECT 1 FROM procurement_order_approval_cases pend
          WHERE pend.order_type = 'PURCHASE' AND pend.order_id = po.id
            AND pend.status = 'PENDING'
      )
),
subcontract_rows AS (
    SELECT
        'SUBCONTRACT'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), NULLIF(application.source_doc_no, ''),
                 application.bill_no) AS plan_no,
        application.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'SUBCONTRACT'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.ordered_qty, 0) + COALESCE(pending.pending_qty, 0) AS allocated_qty,
        COALESCE(item.ordered_qty, 0) AS fulfilled_qty,
        COALESCE(item.ordered_qty, 0) + COALESCE(pending.pending_qty, 0) AS supply_pegged_qty,
        GREATEST(COALESCE(item.qty, 0) - COALESCE(item.ordered_qty, 0)
                 - COALESCE(pending.pending_qty, 0), 0) AS open_qty,
        'WAITING_ORDER'::TEXT AS task_status,
        application.need_date AS need_date,
        application.need_date AS expected_date,
        CASE
            WHEN application.need_date < CURRENT_DATE THEN 'OVERDUE'
            ELSE NULL
        END::TEXT AS exception_code,
        GREATEST(item.updated_at, application.updated_at) AS updated_at,
        'SUBCONTRACT_APPLICATION'::TEXT AS action_doc_type,
        application.id AS action_doc_id,
        application.bill_no AS action_doc_no,
        item.id AS action_item_id,
        application.status::TEXT AS action_doc_status
    FROM subcontract_application_items item
    JOIN subcontract_applications application ON application.id = item.application_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = application.warehouse_id
    LEFT JOIN subcontract_pending pending ON pending.source_item_id = item.id
    WHERE application.status = 1
      AND application.is_deleted = FALSE
      AND application.is_closed = FALSE
      AND item.is_deleted = FALSE
),
subcontract_order_rows AS (
    -- 委外对齐采购：已生效委外订货单(status=1)的明细行，按 is_closed 分到
    -- FINANCE_APPROVED(待采购完成) / COMPLETED(已完成，近30天)。
    SELECT
        'SUBCONTRACT'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), so.bill_no) AS plan_no,
        so.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'SUBCONTRACT'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.qty, 0) AS allocated_qty,
        GREATEST(COALESCE(item.received_qty, 0) - COALESCE(item.returned_qty, 0), 0) AS fulfilled_qty,
        COALESCE(item.qty, 0) AS supply_pegged_qty,
        GREATEST(COALESCE(item.qty, 0) - COALESCE(item.received_qty, 0)
                 + COALESCE(item.returned_qty, 0), 0) AS open_qty,
        CASE WHEN so.is_closed THEN 'COMPLETED' ELSE 'FINANCE_APPROVED' END::TEXT AS task_status,
        COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS need_date,
        COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS expected_date,
        CASE
            WHEN NOT so.is_closed
                 AND COALESCE(item.deliver_date, so.deliver_date) < CURRENT_DATE
                THEN 'OVERDUE'
            ELSE NULL
        END::TEXT AS exception_code,
        GREATEST(item.updated_at, so.updated_at) AS updated_at,
        'SUBCONTRACT_ORDER'::TEXT AS action_doc_type,
        so.id AS action_doc_id,
        so.bill_no AS action_doc_no,
        item.id AS action_item_id,
        so.status::TEXT AS action_doc_status
    FROM subcontract_order_items item
    JOIN subcontract_orders so ON so.id = item.order_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = so.warehouse_id
    WHERE so.status = 1
      AND so.is_deleted = FALSE
      AND item.is_deleted = FALSE
      AND (NOT so.is_closed OR so.updated_at >= CURRENT_DATE - INTERVAL '30 days')
),
subcontract_rejected_rows AS (
    -- 委外财务驳回：订货单提交财务审核后被驳回(status 仍 0)，且当前无新的待审核案件。
    SELECT
        'SUBCONTRACT'::TEXT AS department,
        item.id AS task_id,
        NULL::UUID AS package_id,
        NULL::UUID AS plan_id,
        COALESCE(NULLIF(item.source_doc_no, ''), so.bill_no) AS plan_no,
        so.warehouse_id,
        warehouse.name AS warehouse_name,
        item.goods_id,
        goods.code AS goods_code,
        goods.name AS goods_name,
        goods.spec,
        item.color_id,
        color.name AS color_name,
        item.unit_id,
        unit.name AS unit_name,
        'SUBCONTRACT'::TEXT AS supply_route,
        COALESCE(item.qty, 0) AS required_qty,
        COALESCE(item.qty, 0) AS allocated_qty,
        GREATEST(COALESCE(item.received_qty, 0) - COALESCE(item.returned_qty, 0), 0) AS fulfilled_qty,
        COALESCE(item.qty, 0) AS supply_pegged_qty,
        COALESCE(item.qty, 0) AS open_qty,
        'FINANCE_REJECTED'::TEXT AS task_status,
        COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS need_date,
        COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS expected_date,
        NULL::TEXT AS exception_code,
        GREATEST(item.updated_at, so.updated_at) AS updated_at,
        'SUBCONTRACT_ORDER'::TEXT AS action_doc_type,
        so.id AS action_doc_id,
        so.bill_no AS action_doc_no,
        item.id AS action_item_id,
        so.status::TEXT AS action_doc_status
    FROM subcontract_order_items item
    JOIN subcontract_orders so ON so.id = item.order_id
    JOIN goods ON goods.id = item.goods_id
    LEFT JOIN colors color ON color.id = item.color_id
    LEFT JOIN units unit ON unit.id = item.unit_id
    LEFT JOIN warehouses warehouse ON warehouse.id = so.warehouse_id
    WHERE so.status = 0
      AND so.is_deleted = FALSE
      AND item.is_deleted = FALSE
      AND EXISTS (
          SELECT 1 FROM procurement_order_approval_cases rej
          WHERE rej.order_type = 'SUBCONTRACT' AND rej.order_id = so.id
            AND rej.status = 'REJECTED'
      )
      AND NOT EXISTS (
          SELECT 1 FROM procurement_order_approval_cases pend
          WHERE pend.order_type = 'SUBCONTRACT' AND pend.order_id = so.id
            AND pend.status = 'PENDING'
      )
)
SELECT * FROM purchase_rows WHERE open_qty > 0
UNION ALL
SELECT * FROM purchase_order_rows
UNION ALL
SELECT * FROM purchase_rejected_rows
UNION ALL
SELECT * FROM subcontract_rows WHERE open_qty > 0
UNION ALL
SELECT * FROM subcontract_order_rows
UNION ALL
SELECT * FROM subcontract_rejected_rows;

COMMENT ON VIEW v_procurement_decomposition_tasks IS
    '采购/委外任务中心权威投影（设计对齐）：采购与委外均含 申请待分解(WAITING_ORDER,申请行剩余量,黄) / 财务已通过·待采购完成(FINANCE_APPROVED,已生效订单未收完,蓝) / 财务驳回(FINANCE_REJECTED,审核未过未重提,红) / 已完成(COMPLETED,近30天收完,绿) 四档；均扣除已生效和待财务订单占用';
