-- V199: request-line task projection for purchase/subcontract decomposition.
--
-- A finance-pending order reserves its source quantity even though the legacy ordered_qty
-- cumulative is intentionally updated only when finance approves and status becomes 1.

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
)
SELECT * FROM purchase_rows WHERE open_qty > 0
UNION ALL
SELECT * FROM subcontract_rows WHERE open_qty > 0;

COMMENT ON VIEW v_procurement_decomposition_tasks IS
    '采购/委外任务中心权威投影：已下达申请行剩余量，扣除已生效和待财务订单占用';

