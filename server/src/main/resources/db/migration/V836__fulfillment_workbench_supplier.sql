-- =====================================================================
-- V836：履约工作台投影补委外商 —— 委外「待处理」列表要显示委外商
-- =====================================================================
-- 用户口径（2026-10-10）：委外任务中心「待处理」拍平表里，委外申请行此前
-- 只能硬编码「—」（委外商下钻详情页看得到，列表接口没给）。权威投影
-- v_procurement_decomposition_tasks 的 SUBCONTRACT 申请段（subcontract_rows，
-- 申请待分解行）LEFT JOIN subcontract_applications→suppliers，把申请头上的
-- 委外商名下发为 supplier_name；未定商为 NULL——那是业务事实，前端照旧
-- 显示「—」。
--
-- 实现：照 V834 重建本视图（V834 的 DRAW_OPEN 档等口径原样保留），唯一增量
-- 是每个行段末尾新增 supplier_name 列：
--   · subcontract_rows（SUBCONTRACT 申请行）：supplier.name，真实值；
--   · 其余七段（采购三段 / 委外订货三段）：NULL::text——本列只服务委外
--     「待处理」申请行，订货单的委外商走 draw-tasks 数据源（已有 supplier_name）。
-- 列加在视图列清单末尾，不动既有列序；视图仅被 FulfillmentWorkbenchQueryService
-- 按列名引用（列表/红数/黄数三处），加列无破坏。
-- =====================================================================

CREATE OR REPLACE VIEW v_procurement_decomposition_tasks AS
 WITH purchase_pending AS (
         SELECT src.request_item_id AS source_item_id,
            sum(COALESCE(src.alloc_qty, 0::numeric)) AS pending_qty
           FROM procurement_order_approval_cases approval
             JOIN purchase_orders po ON approval.order_type = 'PURCHASE'::text AND approval.order_id = po.id AND approval.status = 'PENDING'::text
             JOIN purchase_order_items oi ON oi.order_id = po.id
             JOIN purchase_order_item_sources src ON src.order_item_id = oi.id
          WHERE po.status = 0 AND po.is_deleted = false AND oi.is_deleted = false
          GROUP BY src.request_item_id
        ), subcontract_pending AS (
         SELECT src.application_item_id AS source_item_id,
            sum(COALESCE(src.alloc_qty, 0::numeric)) AS pending_qty
           FROM procurement_order_approval_cases approval
             JOIN subcontract_orders so ON approval.order_type = 'SUBCONTRACT'::text AND approval.order_id = so.id AND approval.status = 'PENDING'::text
             JOIN subcontract_order_items oi ON oi.order_id = so.id
             JOIN subcontract_order_item_sources src ON src.order_item_id = oi.id
          WHERE so.status = 0 AND so.is_deleted = false AND oi.is_deleted = false
          GROUP BY src.application_item_id
        ), purchase_rows AS (
         SELECT 'PURCHASE'::text AS department,
            item.id AS task_id,
            NULL::uuid AS package_id,
            NULL::uuid AS plan_id,
            COALESCE(NULLIF(item.production_plan_no, ''::text), NULLIF(item.source_doc_no, ''::text), NULLIF(request.source_doc_no, ''::text), request.bill_no) AS plan_no,
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
            'BUY'::text AS supply_route,
            COALESCE(item.qty, 0::numeric) AS required_qty,
            COALESCE(item.ordered_qty, 0::numeric) + COALESCE(pending.pending_qty, 0::numeric) AS allocated_qty,
            COALESCE(item.ordered_qty, 0::numeric) AS fulfilled_qty,
            COALESCE(item.ordered_qty, 0::numeric) + COALESCE(pending.pending_qty, 0::numeric) AS supply_pegged_qty,
            GREATEST(COALESCE(item.qty, 0::numeric) - COALESCE(item.ordered_qty, 0::numeric) - COALESCE(pending.pending_qty, 0::numeric), 0::numeric) AS open_qty,
            'WAITING_ORDER'::text AS task_status,
            COALESCE(item.deliver_date, request.need_date) AS need_date,
            COALESCE(item.deliver_date, request.need_date) AS expected_date,
                CASE
                    WHEN COALESCE(item.deliver_date, request.need_date) < CURRENT_DATE THEN 'OVERDUE'::text
                    ELSE NULL::text
                END AS exception_code,
            GREATEST(item.updated_at, request.updated_at) AS updated_at,
            'PURCHASE_REQUEST'::text AS action_doc_type,
            request.id AS action_doc_id,
            request.bill_no AS action_doc_no,
            item.id AS action_item_id,
            request.status::text AS action_doc_status,
            NULL::text AS supplier_name
           FROM purchase_request_items item
             JOIN purchase_requests request ON request.id = item.request_id
             JOIN goods ON goods.id = item.goods_id
             LEFT JOIN colors color ON color.id = item.color_id
             LEFT JOIN units unit ON unit.id = item.unit_id
             LEFT JOIN warehouses warehouse ON warehouse.id = request.warehouse_id
             LEFT JOIN purchase_pending pending ON pending.source_item_id = item.id
          WHERE request.status = 1 AND request.is_deleted = false AND request.is_closed = false AND item.is_deleted = false
        ), purchase_order_pending_rows AS (
         SELECT 'PURCHASE'::text AS department,
            item.id AS task_id,
            NULL::uuid AS package_id,
            NULL::uuid AS plan_id,
            COALESCE(NULLIF(item.source_doc_no, ''::text), NULLIF(item.production_plan_no, ''::text), po.bill_no) AS plan_no,
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
            'BUY'::text AS supply_route,
            COALESCE(item.qty, 0::numeric) AS required_qty,
            COALESCE(item.qty, 0::numeric) AS allocated_qty,
            GREATEST(COALESCE(item.received_qty, 0::numeric) - COALESCE(item.returned_qty, 0::numeric), 0::numeric) AS fulfilled_qty,
            COALESCE(item.qty, 0::numeric) AS supply_pegged_qty,
            COALESCE(item.qty, 0::numeric) AS open_qty,
            'ORDER_PENDING_APPROVAL'::text AS task_status,
            COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS need_date,
            COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS expected_date,
                CASE
                    WHEN COALESCE(item.deliver_date, po.deliver_date) < CURRENT_DATE THEN 'OVERDUE'::text
                    ELSE NULL::text
                END AS exception_code,
            GREATEST(item.updated_at, po.updated_at) AS updated_at,
            'PURCHASE_ORDER'::text AS action_doc_type,
            po.id AS action_doc_id,
            po.bill_no AS action_doc_no,
            item.id AS action_item_id,
            po.status::text AS action_doc_status,
            NULL::text AS supplier_name
           FROM purchase_order_items item
             JOIN purchase_orders po ON po.id = item.order_id
             JOIN goods ON goods.id = item.goods_id
             LEFT JOIN colors color ON color.id = item.color_id
             LEFT JOIN units unit ON unit.id = item.unit_id
             LEFT JOIN warehouses warehouse ON warehouse.id = po.warehouse_id
          WHERE po.status = 0 AND po.is_deleted = false AND item.is_deleted = false AND (EXISTS ( SELECT 1
                   FROM procurement_order_approval_cases pend
                  WHERE pend.order_type = 'PURCHASE'::text AND pend.order_id = po.id AND pend.status = 'PENDING'::text))
        ), purchase_order_rows AS (
         SELECT 'PURCHASE'::text AS department,
            item.id AS task_id,
            NULL::uuid AS package_id,
            NULL::uuid AS plan_id,
            COALESCE(NULLIF(item.source_doc_no, ''::text), NULLIF(item.production_plan_no, ''::text), po.bill_no) AS plan_no,
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
            'BUY'::text AS supply_route,
            COALESCE(item.qty, 0::numeric) AS required_qty,
            COALESCE(item.qty, 0::numeric) AS allocated_qty,
            GREATEST(COALESCE(item.received_qty, 0::numeric) - COALESCE(item.returned_qty, 0::numeric), 0::numeric) AS fulfilled_qty,
            COALESCE(item.qty, 0::numeric) AS supply_pegged_qty,
            GREATEST(COALESCE(item.qty, 0::numeric) - COALESCE(item.received_qty, 0::numeric) + COALESCE(item.returned_qty, 0::numeric), 0::numeric) AS open_qty,
                CASE
                    WHEN po.is_closed THEN 'COMPLETED'::text
                    ELSE 'FINANCE_APPROVED'::text
                END AS task_status,
            COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS need_date,
            COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS expected_date,
                CASE
                    WHEN NOT po.is_closed AND COALESCE(item.deliver_date, po.deliver_date) < CURRENT_DATE THEN 'OVERDUE'::text
                    ELSE NULL::text
                END AS exception_code,
            GREATEST(item.updated_at, po.updated_at) AS updated_at,
            'PURCHASE_ORDER'::text AS action_doc_type,
            po.id AS action_doc_id,
            po.bill_no AS action_doc_no,
            item.id AS action_item_id,
            po.status::text AS action_doc_status,
            NULL::text AS supplier_name
           FROM purchase_order_items item
             JOIN purchase_orders po ON po.id = item.order_id
             JOIN goods ON goods.id = item.goods_id
             LEFT JOIN colors color ON color.id = item.color_id
             LEFT JOIN units unit ON unit.id = item.unit_id
             LEFT JOIN warehouses warehouse ON warehouse.id = po.warehouse_id
          WHERE po.status = 1 AND po.is_deleted = false AND item.is_deleted = false AND (NOT po.is_closed OR po.updated_at >= (CURRENT_DATE - '30 days'::interval))
        ), purchase_rejected_rows AS (
         SELECT 'PURCHASE'::text AS department,
            item.id AS task_id,
            NULL::uuid AS package_id,
            NULL::uuid AS plan_id,
            COALESCE(NULLIF(item.source_doc_no, ''::text), NULLIF(item.production_plan_no, ''::text), po.bill_no) AS plan_no,
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
            'BUY'::text AS supply_route,
            COALESCE(item.qty, 0::numeric) AS required_qty,
            COALESCE(item.qty, 0::numeric) AS allocated_qty,
            GREATEST(COALESCE(item.received_qty, 0::numeric) - COALESCE(item.returned_qty, 0::numeric), 0::numeric) AS fulfilled_qty,
            COALESCE(item.qty, 0::numeric) AS supply_pegged_qty,
            COALESCE(item.qty, 0::numeric) AS open_qty,
            'FINANCE_REJECTED'::text AS task_status,
            COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS need_date,
            COALESCE(item.deliver_date, po.deliver_date, po.bill_date) AS expected_date,
            NULL::text AS exception_code,
            GREATEST(item.updated_at, po.updated_at) AS updated_at,
            'PURCHASE_ORDER'::text AS action_doc_type,
            po.id AS action_doc_id,
            po.bill_no AS action_doc_no,
            item.id AS action_item_id,
            po.status::text AS action_doc_status,
            NULL::text AS supplier_name
           FROM purchase_order_items item
             JOIN purchase_orders po ON po.id = item.order_id
             JOIN goods ON goods.id = item.goods_id
             LEFT JOIN colors color ON color.id = item.color_id
             LEFT JOIN units unit ON unit.id = item.unit_id
             LEFT JOIN warehouses warehouse ON warehouse.id = po.warehouse_id
          WHERE po.status = 0 AND po.is_deleted = false AND item.is_deleted = false AND (EXISTS ( SELECT 1
                   FROM procurement_order_approval_cases rej
                  WHERE rej.order_type = 'PURCHASE'::text AND rej.order_id = po.id AND rej.status = 'REJECTED'::text)) AND NOT (EXISTS ( SELECT 1
                   FROM procurement_order_approval_cases pend
                  WHERE pend.order_type = 'PURCHASE'::text AND pend.order_id = po.id AND pend.status = 'PENDING'::text))
        ), subcontract_rows AS (
         SELECT 'SUBCONTRACT'::text AS department,
            item.id AS task_id,
            NULL::uuid AS package_id,
            NULL::uuid AS plan_id,
            COALESCE(NULLIF(item.source_doc_no, ''::text), NULLIF(application.source_doc_no, ''::text), application.bill_no) AS plan_no,
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
            'SUBCONTRACT'::text AS supply_route,
            COALESCE(item.qty, 0::numeric) AS required_qty,
            COALESCE(item.ordered_qty, 0::numeric) + COALESCE(pending.pending_qty, 0::numeric) AS allocated_qty,
            COALESCE(item.ordered_qty, 0::numeric) AS fulfilled_qty,
            COALESCE(item.ordered_qty, 0::numeric) + COALESCE(pending.pending_qty, 0::numeric) AS supply_pegged_qty,
            GREATEST(COALESCE(item.qty, 0::numeric) - COALESCE(item.ordered_qty, 0::numeric) - COALESCE(pending.pending_qty, 0::numeric), 0::numeric) AS open_qty,
            'WAITING_ORDER'::text AS task_status,
            application.need_date,
            application.need_date AS expected_date,
                CASE
                    WHEN application.need_date < CURRENT_DATE THEN 'OVERDUE'::text
                    ELSE NULL::text
                END AS exception_code,
            GREATEST(item.updated_at, application.updated_at) AS updated_at,
            'SUBCONTRACT_APPLICATION'::text AS action_doc_type,
            application.id AS action_doc_id,
            application.bill_no AS action_doc_no,
            item.id AS action_item_id,
            application.status::text AS action_doc_status,
            supplier.name AS supplier_name
           FROM subcontract_application_items item
             JOIN subcontract_applications application ON application.id = item.application_id
             JOIN goods ON goods.id = item.goods_id
             LEFT JOIN colors color ON color.id = item.color_id
             LEFT JOIN units unit ON unit.id = item.unit_id
             LEFT JOIN warehouses warehouse ON warehouse.id = application.warehouse_id
             LEFT JOIN subcontract_pending pending ON pending.source_item_id = item.id
             LEFT JOIN suppliers supplier ON supplier.id = application.supplier_id
          WHERE application.status = 1 AND application.is_deleted = false AND application.is_closed = false AND item.is_deleted = false
        ), subcontract_order_pending_rows AS (
         SELECT 'SUBCONTRACT'::text AS department,
            item.id AS task_id,
            NULL::uuid AS package_id,
            NULL::uuid AS plan_id,
            COALESCE(NULLIF(item.source_doc_no, ''::text), so.bill_no) AS plan_no,
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
            'SUBCONTRACT'::text AS supply_route,
            COALESCE(item.qty, 0::numeric) AS required_qty,
            COALESCE(item.qty, 0::numeric) AS allocated_qty,
            GREATEST(COALESCE(item.received_qty, 0::numeric) - COALESCE(item.returned_qty, 0::numeric), 0::numeric) AS fulfilled_qty,
            COALESCE(item.qty, 0::numeric) AS supply_pegged_qty,
            COALESCE(item.qty, 0::numeric) AS open_qty,
            'ORDER_PENDING_APPROVAL'::text AS task_status,
            COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS need_date,
            COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS expected_date,
                CASE
                    WHEN COALESCE(item.deliver_date, so.deliver_date) < CURRENT_DATE THEN 'OVERDUE'::text
                    ELSE NULL::text
                END AS exception_code,
            GREATEST(item.updated_at, so.updated_at) AS updated_at,
            'SUBCONTRACT_ORDER'::text AS action_doc_type,
            so.id AS action_doc_id,
            so.bill_no AS action_doc_no,
            item.id AS action_item_id,
            so.status::text AS action_doc_status,
            NULL::text AS supplier_name
           FROM subcontract_order_items item
             JOIN subcontract_orders so ON so.id = item.order_id
             JOIN goods ON goods.id = item.goods_id
             LEFT JOIN colors color ON color.id = item.color_id
             LEFT JOIN units unit ON unit.id = item.unit_id
             LEFT JOIN warehouses warehouse ON warehouse.id = so.warehouse_id
          WHERE so.status = 0 AND so.is_deleted = false AND item.is_deleted = false AND (EXISTS ( SELECT 1
                   FROM procurement_order_approval_cases pend
                  WHERE pend.order_type = 'SUBCONTRACT'::text AND pend.order_id = so.id AND pend.status = 'PENDING'::text))
        ), subcontract_order_rows AS (
         SELECT 'SUBCONTRACT'::text AS department,
            item.id AS task_id,
            NULL::uuid AS package_id,
            NULL::uuid AS plan_id,
            COALESCE(NULLIF(item.source_doc_no, ''::text), so.bill_no) AS plan_no,
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
            'SUBCONTRACT'::text AS supply_route,
            COALESCE(item.qty, 0::numeric) AS required_qty,
            COALESCE(item.qty, 0::numeric) AS allocated_qty,
            GREATEST(COALESCE(item.received_qty, 0::numeric) - COALESCE(item.returned_qty, 0::numeric), 0::numeric) AS fulfilled_qty,
            COALESCE(item.qty, 0::numeric) AS supply_pegged_qty,
            GREATEST(COALESCE(item.qty, 0::numeric) - COALESCE(item.received_qty, 0::numeric) + COALESCE(item.returned_qty, 0::numeric) - COALESCE(fn_subcontract_settled_loss_qty(item.id), 0::numeric), 0::numeric) AS open_qty,
                CASE
                    WHEN so.is_closed THEN 'COMPLETED'::text
                    WHEN EXISTS (SELECT 1
                                 FROM subcontract_order_items draw_item
                                 JOIN subcontract_material_plans draw_plan ON draw_plan.order_id = so.id AND NOT draw_plan.is_deleted
                                 WHERE draw_item.order_id = so.id
                                   AND NOT draw_item.is_deleted
                                   AND draw_plan.status = 'OPEN'::text
                                   AND EXISTS (SELECT 1
                                               FROM subcontract_material_plan_items open_line
                                               WHERE open_line.plan_id = draw_plan.id
                                                 AND open_line.order_item_id = draw_item.id
                                                 AND NOT open_line.is_deleted
                                                 AND open_line.draw_closed_at IS NULL
                                                 AND open_line.issued_qty < fn_subcontract_draw_needed_qty(
                                                     open_line.order_item_id, open_line.planned_qty, open_line.bom_unit_qty))
                                   AND GREATEST(COALESCE(draw_item.received_qty, 0::numeric) - COALESCE(draw_item.returned_qty, 0::numeric), 0::numeric)
                                       + fn_subcontract_settled_loss_qty(draw_item.id) < draw_item.qty)
                        THEN 'DRAW_OPEN'::text
                    ELSE 'FINANCE_APPROVED'::text
                END AS task_status,
            COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS need_date,
            COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS expected_date,
                CASE
                    WHEN NOT so.is_closed AND COALESCE(item.deliver_date, so.deliver_date) < CURRENT_DATE THEN 'OVERDUE'::text
                    ELSE NULL::text
                END AS exception_code,
            GREATEST(item.updated_at, so.updated_at) AS updated_at,
            'SUBCONTRACT_ORDER'::text AS action_doc_type,
            so.id AS action_doc_id,
            so.bill_no AS action_doc_no,
            item.id AS action_item_id,
            so.status::text AS action_doc_status,
            NULL::text AS supplier_name
           FROM subcontract_order_items item
             JOIN subcontract_orders so ON so.id = item.order_id
             JOIN goods ON goods.id = item.goods_id
             LEFT JOIN colors color ON color.id = item.color_id
             LEFT JOIN units unit ON unit.id = item.unit_id
             LEFT JOIN warehouses warehouse ON warehouse.id = so.warehouse_id
          WHERE so.status = 1 AND so.is_deleted = false AND item.is_deleted = false AND (NOT so.is_closed OR so.updated_at >= (CURRENT_DATE - '30 days'::interval))
        ), subcontract_rejected_rows AS (
         SELECT 'SUBCONTRACT'::text AS department,
            item.id AS task_id,
            NULL::uuid AS package_id,
            NULL::uuid AS plan_id,
            COALESCE(NULLIF(item.source_doc_no, ''::text), so.bill_no) AS plan_no,
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
            'SUBCONTRACT'::text AS supply_route,
            COALESCE(item.qty, 0::numeric) AS required_qty,
            COALESCE(item.qty, 0::numeric) AS allocated_qty,
            GREATEST(COALESCE(item.received_qty, 0::numeric) - COALESCE(item.returned_qty, 0::numeric), 0::numeric) AS fulfilled_qty,
            COALESCE(item.qty, 0::numeric) AS supply_pegged_qty,
            COALESCE(item.qty, 0::numeric) AS open_qty,
            'FINANCE_REJECTED'::text AS task_status,
            COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS need_date,
            COALESCE(item.deliver_date, so.deliver_date, so.bill_date) AS expected_date,
            NULL::text AS exception_code,
            GREATEST(item.updated_at, so.updated_at) AS updated_at,
            'SUBCONTRACT_ORDER'::text AS action_doc_type,
            so.id AS action_doc_id,
            so.bill_no AS action_doc_no,
            item.id AS action_item_id,
            so.status::text AS action_doc_status,
            NULL::text AS supplier_name
           FROM subcontract_order_items item
             JOIN subcontract_orders so ON so.id = item.order_id
             JOIN goods ON goods.id = item.goods_id
             LEFT JOIN colors color ON color.id = item.color_id
             LEFT JOIN units unit ON unit.id = item.unit_id
             LEFT JOIN warehouses warehouse ON warehouse.id = so.warehouse_id
          WHERE so.status = 0 AND so.is_deleted = false AND item.is_deleted = false AND (EXISTS ( SELECT 1
                   FROM procurement_order_approval_cases rej
                  WHERE rej.order_type = 'SUBCONTRACT'::text AND rej.order_id = so.id AND rej.status = 'REJECTED'::text)) AND NOT (EXISTS ( SELECT 1
                   FROM procurement_order_approval_cases pend
                  WHERE pend.order_type = 'SUBCONTRACT'::text AND pend.order_id = so.id AND pend.status = 'PENDING'::text))
        )
 SELECT purchase_rows.department,
    purchase_rows.task_id,
    purchase_rows.package_id,
    purchase_rows.plan_id,
    purchase_rows.plan_no,
    purchase_rows.warehouse_id,
    purchase_rows.warehouse_name,
    purchase_rows.goods_id,
    purchase_rows.goods_code,
    purchase_rows.goods_name,
    purchase_rows.spec,
    purchase_rows.color_id,
    purchase_rows.color_name,
    purchase_rows.unit_id,
    purchase_rows.unit_name,
    purchase_rows.supply_route,
    purchase_rows.required_qty,
    purchase_rows.allocated_qty,
    purchase_rows.fulfilled_qty,
    purchase_rows.supply_pegged_qty,
    purchase_rows.open_qty,
    purchase_rows.task_status,
    purchase_rows.need_date,
    purchase_rows.expected_date,
    purchase_rows.exception_code,
    purchase_rows.updated_at,
    purchase_rows.action_doc_type,
    purchase_rows.action_doc_id,
    purchase_rows.action_doc_no,
    purchase_rows.action_item_id,
    purchase_rows.action_doc_status,
    purchase_rows.supplier_name
   FROM purchase_rows
  WHERE purchase_rows.open_qty > 0::numeric
UNION ALL
 SELECT purchase_order_pending_rows.department,
    purchase_order_pending_rows.task_id,
    purchase_order_pending_rows.package_id,
    purchase_order_pending_rows.plan_id,
    purchase_order_pending_rows.plan_no,
    purchase_order_pending_rows.warehouse_id,
    purchase_order_pending_rows.warehouse_name,
    purchase_order_pending_rows.goods_id,
    purchase_order_pending_rows.goods_code,
    purchase_order_pending_rows.goods_name,
    purchase_order_pending_rows.spec,
    purchase_order_pending_rows.color_id,
    purchase_order_pending_rows.color_name,
    purchase_order_pending_rows.unit_id,
    purchase_order_pending_rows.unit_name,
    purchase_order_pending_rows.supply_route,
    purchase_order_pending_rows.required_qty,
    purchase_order_pending_rows.allocated_qty,
    purchase_order_pending_rows.fulfilled_qty,
    purchase_order_pending_rows.supply_pegged_qty,
    purchase_order_pending_rows.open_qty,
    purchase_order_pending_rows.task_status,
    purchase_order_pending_rows.need_date,
    purchase_order_pending_rows.expected_date,
    purchase_order_pending_rows.exception_code,
    purchase_order_pending_rows.updated_at,
    purchase_order_pending_rows.action_doc_type,
    purchase_order_pending_rows.action_doc_id,
    purchase_order_pending_rows.action_doc_no,
    purchase_order_pending_rows.action_item_id,
    purchase_order_pending_rows.action_doc_status,
    purchase_order_pending_rows.supplier_name
   FROM purchase_order_pending_rows
UNION ALL
 SELECT purchase_order_rows.department,
    purchase_order_rows.task_id,
    purchase_order_rows.package_id,
    purchase_order_rows.plan_id,
    purchase_order_rows.plan_no,
    purchase_order_rows.warehouse_id,
    purchase_order_rows.warehouse_name,
    purchase_order_rows.goods_id,
    purchase_order_rows.goods_code,
    purchase_order_rows.goods_name,
    purchase_order_rows.spec,
    purchase_order_rows.color_id,
    purchase_order_rows.color_name,
    purchase_order_rows.unit_id,
    purchase_order_rows.unit_name,
    purchase_order_rows.supply_route,
    purchase_order_rows.required_qty,
    purchase_order_rows.allocated_qty,
    purchase_order_rows.fulfilled_qty,
    purchase_order_rows.supply_pegged_qty,
    purchase_order_rows.open_qty,
    purchase_order_rows.task_status,
    purchase_order_rows.need_date,
    purchase_order_rows.expected_date,
    purchase_order_rows.exception_code,
    purchase_order_rows.updated_at,
    purchase_order_rows.action_doc_type,
    purchase_order_rows.action_doc_id,
    purchase_order_rows.action_doc_no,
    purchase_order_rows.action_item_id,
    purchase_order_rows.action_doc_status,
    purchase_order_rows.supplier_name
   FROM purchase_order_rows
UNION ALL
 SELECT purchase_rejected_rows.department,
    purchase_rejected_rows.task_id,
    purchase_rejected_rows.package_id,
    purchase_rejected_rows.plan_id,
    purchase_rejected_rows.plan_no,
    purchase_rejected_rows.warehouse_id,
    purchase_rejected_rows.warehouse_name,
    purchase_rejected_rows.goods_id,
    purchase_rejected_rows.goods_code,
    purchase_rejected_rows.goods_name,
    purchase_rejected_rows.spec,
    purchase_rejected_rows.color_id,
    purchase_rejected_rows.color_name,
    purchase_rejected_rows.unit_id,
    purchase_rejected_rows.unit_name,
    purchase_rejected_rows.supply_route,
    purchase_rejected_rows.required_qty,
    purchase_rejected_rows.allocated_qty,
    purchase_rejected_rows.fulfilled_qty,
    purchase_rejected_rows.supply_pegged_qty,
    purchase_rejected_rows.open_qty,
    purchase_rejected_rows.task_status,
    purchase_rejected_rows.need_date,
    purchase_rejected_rows.expected_date,
    purchase_rejected_rows.exception_code,
    purchase_rejected_rows.updated_at,
    purchase_rejected_rows.action_doc_type,
    purchase_rejected_rows.action_doc_id,
    purchase_rejected_rows.action_doc_no,
    purchase_rejected_rows.action_item_id,
    purchase_rejected_rows.action_doc_status,
    purchase_rejected_rows.supplier_name
   FROM purchase_rejected_rows
UNION ALL
 SELECT subcontract_rows.department,
    subcontract_rows.task_id,
    subcontract_rows.package_id,
    subcontract_rows.plan_id,
    subcontract_rows.plan_no,
    subcontract_rows.warehouse_id,
    subcontract_rows.warehouse_name,
    subcontract_rows.goods_id,
    subcontract_rows.goods_code,
    subcontract_rows.goods_name,
    subcontract_rows.spec,
    subcontract_rows.color_id,
    subcontract_rows.color_name,
    subcontract_rows.unit_id,
    subcontract_rows.unit_name,
    subcontract_rows.supply_route,
    subcontract_rows.required_qty,
    subcontract_rows.allocated_qty,
    subcontract_rows.fulfilled_qty,
    subcontract_rows.supply_pegged_qty,
    subcontract_rows.open_qty,
    subcontract_rows.task_status,
    subcontract_rows.need_date,
    subcontract_rows.expected_date,
    subcontract_rows.exception_code,
    subcontract_rows.updated_at,
    subcontract_rows.action_doc_type,
    subcontract_rows.action_doc_id,
    subcontract_rows.action_doc_no,
    subcontract_rows.action_item_id,
    subcontract_rows.action_doc_status,
    subcontract_rows.supplier_name
   FROM subcontract_rows
  WHERE subcontract_rows.open_qty > 0::numeric
UNION ALL
 SELECT subcontract_order_pending_rows.department,
    subcontract_order_pending_rows.task_id,
    subcontract_order_pending_rows.package_id,
    subcontract_order_pending_rows.plan_id,
    subcontract_order_pending_rows.plan_no,
    subcontract_order_pending_rows.warehouse_id,
    subcontract_order_pending_rows.warehouse_name,
    subcontract_order_pending_rows.goods_id,
    subcontract_order_pending_rows.goods_code,
    subcontract_order_pending_rows.goods_name,
    subcontract_order_pending_rows.spec,
    subcontract_order_pending_rows.color_id,
    subcontract_order_pending_rows.color_name,
    subcontract_order_pending_rows.unit_id,
    subcontract_order_pending_rows.unit_name,
    subcontract_order_pending_rows.supply_route,
    subcontract_order_pending_rows.required_qty,
    subcontract_order_pending_rows.allocated_qty,
    subcontract_order_pending_rows.fulfilled_qty,
    subcontract_order_pending_rows.supply_pegged_qty,
    subcontract_order_pending_rows.open_qty,
    subcontract_order_pending_rows.task_status,
    subcontract_order_pending_rows.need_date,
    subcontract_order_pending_rows.expected_date,
    subcontract_order_pending_rows.exception_code,
    subcontract_order_pending_rows.updated_at,
    subcontract_order_pending_rows.action_doc_type,
    subcontract_order_pending_rows.action_doc_id,
    subcontract_order_pending_rows.action_doc_no,
    subcontract_order_pending_rows.action_item_id,
    subcontract_order_pending_rows.action_doc_status,
    subcontract_order_pending_rows.supplier_name
   FROM subcontract_order_pending_rows
UNION ALL
 SELECT subcontract_order_rows.department,
    subcontract_order_rows.task_id,
    subcontract_order_rows.package_id,
    subcontract_order_rows.plan_id,
    subcontract_order_rows.plan_no,
    subcontract_order_rows.warehouse_id,
    subcontract_order_rows.warehouse_name,
    subcontract_order_rows.goods_id,
    subcontract_order_rows.goods_code,
    subcontract_order_rows.goods_name,
    subcontract_order_rows.spec,
    subcontract_order_rows.color_id,
    subcontract_order_rows.color_name,
    subcontract_order_rows.unit_id,
    subcontract_order_rows.unit_name,
    subcontract_order_rows.supply_route,
    subcontract_order_rows.required_qty,
    subcontract_order_rows.allocated_qty,
    subcontract_order_rows.fulfilled_qty,
    subcontract_order_rows.supply_pegged_qty,
    subcontract_order_rows.open_qty,
    subcontract_order_rows.task_status,
    subcontract_order_rows.need_date,
    subcontract_order_rows.expected_date,
    subcontract_order_rows.exception_code,
    subcontract_order_rows.updated_at,
    subcontract_order_rows.action_doc_type,
    subcontract_order_rows.action_doc_id,
    subcontract_order_rows.action_doc_no,
    subcontract_order_rows.action_item_id,
    subcontract_order_rows.action_doc_status,
    subcontract_order_rows.supplier_name
   FROM subcontract_order_rows
UNION ALL
 SELECT subcontract_rejected_rows.department,
    subcontract_rejected_rows.task_id,
    subcontract_rejected_rows.package_id,
    subcontract_rejected_rows.plan_id,
    subcontract_rejected_rows.plan_no,
    subcontract_rejected_rows.warehouse_id,
    subcontract_rejected_rows.warehouse_name,
    subcontract_rejected_rows.goods_id,
    subcontract_rejected_rows.goods_code,
    subcontract_rejected_rows.goods_name,
    subcontract_rejected_rows.spec,
    subcontract_rejected_rows.color_id,
    subcontract_rejected_rows.color_name,
    subcontract_rejected_rows.unit_id,
    subcontract_rejected_rows.unit_name,
    subcontract_rejected_rows.supply_route,
    subcontract_rejected_rows.required_qty,
    subcontract_rejected_rows.allocated_qty,
    subcontract_rejected_rows.fulfilled_qty,
    subcontract_rejected_rows.supply_pegged_qty,
    subcontract_rejected_rows.open_qty,
    subcontract_rejected_rows.task_status,
    subcontract_rejected_rows.need_date,
    subcontract_rejected_rows.expected_date,
    subcontract_rejected_rows.exception_code,
    subcontract_rejected_rows.updated_at,
    subcontract_rejected_rows.action_doc_type,
    subcontract_rejected_rows.action_doc_id,
    subcontract_rejected_rows.action_doc_no,
    subcontract_rejected_rows.action_item_id,
    subcontract_rejected_rows.action_doc_status,
    subcontract_rejected_rows.supplier_name
   FROM subcontract_rejected_rows;
