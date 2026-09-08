-- Only explicitly started work is reportable; historical start events are preserved.
CREATE OR REPLACE FUNCTION fn_is_execution_manual_start_authorized(
    p_segment_id UUID, p_expected_version BIGINT
) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE(current_setting('app.production_execution_start_segment_id',true)
                       = p_segment_id::text,FALSE)
       AND COALESCE(NULLIF(current_setting(
                       'app.production_execution_start_expected_version',true),'')::bigint
                       = p_expected_version,FALSE);
$$;

DO $migration$
DECLARE definition TEXT; updated TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_validate_production_execution_segment()'::regprocedure)
      INTO definition;
    updated := replace(definition,'fn_is_execution_report_auto_start_authorized(',
                                   'fn_is_execution_manual_start_authorized(');
    IF updated=definition THEN
        RAISE EXCEPTION 'V491 could not replace the report auto-start transition guard';
    END IF;
    EXECUTE updated;
END;
$migration$;

CREATE OR REPLACE VIEW v_production_execution_workbench_segments AS
WITH RECURSIVE plan_lineage(plan_id, root_plan_id, path) AS (
    SELECT plan.id, plan.id, ARRAY[plan.id]
    FROM production_plans plan
    WHERE plan.is_deleted = FALSE
      AND NOT EXISTS (
          SELECT 1 FROM subplan_links parent_link
          WHERE parent_link.subplan_id = plan.id
            AND parent_link.is_deleted = FALSE)
    UNION ALL
    SELECT child.id, lineage.root_plan_id, lineage.path || child.id
    FROM plan_lineage lineage
    JOIN subplan_links link
      ON link.plan_id = lineage.plan_id AND link.is_deleted = FALSE
    JOIN production_plans child
      ON child.id = link.subplan_id AND child.is_deleted = FALSE
    WHERE NOT child.id = ANY(lineage.path)
), rooted_plan AS (
    SELECT plan.id AS plan_id,
           COALESCE((
               SELECT lineage.root_plan_id
               FROM plan_lineage lineage
               WHERE lineage.plan_id = plan.id
               ORDER BY lineage.root_plan_id
               LIMIT 1), plan.id) AS root_plan_id
    FROM production_plans plan
    WHERE plan.is_deleted = FALSE
)
SELECT segment.id AS segment_id,
       segment.package_id,
       segment.plan_id,
       plan.bill_no AS plan_no,
       plan.maker_id AS plan_maker_id,
       CASE WHEN root_plan.material_analysis_id IS NOT NULL
                  OR plan.material_analysis_id IS NOT NULL
            THEN 'ANALYSIS' ELSE 'PLAN' END AS root_type,
       COALESCE(root_plan.material_analysis_id, plan.material_analysis_id,
                rooted.root_plan_id, plan.id) AS root_id,
       rooted.root_plan_id,
       segment.source_plan_item_id,
       segment.segment_no,
       segment.segment_code,
       orders.order_nos AS sales_order_nos,
       COALESCE(orders.order_count, 0)::integer AS sales_order_count,
       segment.workshop_department_id,
       segment.workshop_name,
       segment.team_department_id,
       segment.team_name,
       segment.responsible_employee_id,
       segment.responsible_employee_name,
       segment.product_goods_id,
       segment.product_code,
       segment.product_name,
       color.name AS product_color_name,
       unit.name AS product_unit_name,
       segment.planned_qty,
       COALESCE(progress.effective_reported_qty, 0)::numeric AS reported_qty,
       GREATEST(segment.planned_qty
                - COALESCE(progress.gross_reported_qty, 0), 0)::numeric
           + COALESCE(recovery.available_qty, 0)::numeric AS remaining_qty,
       segment.status AS segment_status,
       CASE WHEN segment.material_ready THEN 'KIT_READY'
            ELSE 'KIT_SHORT' END AS material_status,
       CASE WHEN segment.material_requirement_mode = 'ZERO_MATERIAL'
                  OR (material.demand_count > 0
                      AND material.fulfilled_count = material.demand_count)
            THEN 'PREPARED' ELSE 'PREPARING' END AS preparation_status,
       COALESCE(draw.draw_ready, FALSE) AS warehouse_ready,
       CASE WHEN segment.material_requirement_mode = 'ZERO_MATERIAL'
                  OR (material.demand_count > 0
                      AND material.fulfilled_count = material.demand_count)
            THEN TRUE ELSE FALSE END AS issued,
       CASE WHEN segment.status = 'IN_PROGRESS'
                  AND segment.workshop_department_id IS NOT NULL
                  AND segment.responsible_employee_id IS NOT NULL
                  AND (
                      segment.status = 'IN_PROGRESS'
                      OR segment.material_requirement_mode = 'ZERO_MATERIAL'
                      OR (material.demand_count > 0
                          AND material.fulfilled_count = material.demand_count)
                  )
                  AND (GREATEST(segment.planned_qty
                                - COALESCE(progress.gross_reported_qty, 0), 0)
                       + COALESCE(recovery.available_qty, 0)) > 0
            THEN TRUE ELSE FALSE END AS reportable,
       GREATEST(COALESCE(orders.source_count, 0), 1)::integer
           AS report_source_count,
       CASE
           WHEN segment.workshop_department_id IS NULL
                  OR segment.responsible_employee_id IS NULL
             THEN '尚未指定车间或负责人'
           WHEN segment.status IN ('WAITING','READY','DISPATCHED')
             THEN '请先在我的车间任务中开工，开工后才能报工'
           WHEN segment.status <> 'IN_PROGRESS'
             THEN '工单状态不允许报工'
           WHEN segment.status <> 'IN_PROGRESS'
                  AND NOT segment.material_ready THEN '物料尚未齐套'
           WHEN segment.status <> 'IN_PROGRESS'
                  AND NOT (segment.material_requirement_mode = 'ZERO_MATERIAL'
                     OR (material.demand_count > 0
                         AND material.fulfilled_count = material.demand_count))
             THEN '仓库尚未完成全部备料出库'
           WHEN (GREATEST(segment.planned_qty
                          - COALESCE(progress.gross_reported_qty, 0), 0)
                 + COALESCE(recovery.available_qty, 0)) <= 0
             THEN '本工单已无可报数量'
           ELSE NULL
       END AS blocked_reason,
       segment.plan_begin_date,
       segment.plan_end_date,
       segment.lock_version,
       COALESCE(fqc.pending_qty, 0)::numeric AS fqc_pending_qty,
       COALESCE(fqc.passed_qty, 0)::numeric AS fqc_passed_qty,
       COALESCE(fqc.failed_qty, 0)::numeric AS fqc_failed_qty,
       COALESCE(finished.pending_qty, 0)::numeric
           AS finished_inbound_pending_qty,
       COALESCE(finished.inbound_qty, 0)::numeric AS inbound_qty,
       FALSE AS can_dispatch_fact,
       FALSE AS can_start_fact,
       segment.material_requirement_mode = 'ZERO_MATERIAL' AS zero_material
FROM v_production_execution_segments segment
JOIN production_planning_packages package
  ON package.id = segment.package_id AND package.is_deleted = FALSE
JOIN production_plans plan
  ON plan.id = segment.plan_id AND plan.is_deleted = FALSE
JOIN rooted_plan rooted ON rooted.plan_id = plan.id
LEFT JOIN production_plans root_plan ON root_plan.id = rooted.root_plan_id
LEFT JOIN colors color ON color.id = segment.product_color_id
LEFT JOIN units unit ON unit.id = segment.product_unit_id
LEFT JOIN LATERAL (
    SELECT (SELECT COUNT(DISTINCT sales_order.id)
            FROM execution_segment_sales_allocations allocation
            JOIN sales_order_items sales_item
              ON sales_item.id = allocation.sales_order_item_id
             AND sales_item.is_deleted = FALSE
            JOIN sales_orders sales_order
              ON sales_order.id = sales_item.order_id
             AND sales_order.is_deleted = FALSE
            WHERE allocation.execution_segment_id = segment.id)::integer
               AS order_count,
           (SELECT COUNT(DISTINCT allocation.id)
            FROM execution_segment_sales_allocations allocation
            WHERE allocation.execution_segment_id = segment.id)::integer
               AS source_count,
           (SELECT string_agg(preview.bill_no, ' / ' ORDER BY preview.bill_no)
            FROM (SELECT DISTINCT sales_order.bill_no
                  FROM execution_segment_sales_allocations allocation
                  JOIN sales_order_items sales_item
                    ON sales_item.id = allocation.sales_order_item_id
                   AND sales_item.is_deleted = FALSE
                  JOIN sales_orders sales_order
                    ON sales_order.id = sales_item.order_id
                   AND sales_order.is_deleted = FALSE
                  WHERE allocation.execution_segment_id = segment.id
                  ORDER BY sales_order.bill_no LIMIT 3) preview) AS order_nos
) orders ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*)::integer AS demand_count,
           COUNT(*) FILTER (WHERE demand.status = 'FULFILLED')::integer
               AS fulfilled_count
    FROM production_material_demands demand
    WHERE demand.execution_segment_id = segment.id
      AND demand.is_deleted = FALSE
      AND demand.status NOT IN ('RELEASED', 'REVERSED')
) material ON TRUE
LEFT JOIN LATERAL (
    SELECT SUM(item.qty) AS gross_reported_qty,
           SUM(item.qty)
             - COALESCE(SUM((
                 SELECT SUM(adjustment.adjusted_qty)
                 FROM production_fqc_contribution_adjustments adjustment
                 WHERE adjustment.source_report_item_id = item.id)), 0)
               AS effective_reported_qty
    FROM production_daily_report_items item
    JOIN production_daily_reports report
      ON report.id = item.report_id
     AND report.is_deleted = FALSE AND report.status = 1
    WHERE item.execution_segment_id = segment.id
      AND item.is_deleted = FALSE
) progress ON TRUE
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(GREATEST(balance.available_qty, 0)), 0)
               AS available_qty
    FROM v_production_fqc_recovery_balance balance
    WHERE balance.execution_segment_id = segment.id
      AND balance.cancelled = FALSE AND balance.available_qty > 0
) recovery ON TRUE
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(GREATEST(inspection.reported_qty
               - inspection.passed_qty - inspection.failed_qty, 0)), 0)
               AS pending_qty,
           COALESCE(SUM(inspection.passed_qty), 0) AS passed_qty,
           COALESCE(SUM(inspection.failed_qty), 0) AS failed_qty
    FROM production_fqc_inspections inspection
    WHERE inspection.execution_segment_id = segment.id
      AND inspection.status <> 'CANCELLED'
) fqc ON TRUE
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(item.qty) FILTER (WHERE document.status = 0), 0)
               AS pending_qty,
           COALESCE(SUM(item.qty) FILTER (WHERE document.status = 1), 0)
               AS inbound_qty
    FROM stock_document_items item
    JOIN stock_documents document
      ON document.id = item.doc_id
     AND document.doc_type = 'FINISHED_IN'
     AND document.is_deleted = FALSE
    WHERE item.execution_segment_id = segment.id AND item.is_deleted = FALSE
) finished ON TRUE
LEFT JOIN LATERAL (
    SELECT EXISTS (
        SELECT 1
        FROM production_planning_package_documents mapping
        JOIN stock_documents document ON document.id = mapping.document_id
        WHERE mapping.execution_segment_id = segment.id
          AND mapping.document_type = 'DRAW'
          AND document.doc_type = 'DRAW'
          AND document.is_deleted = FALSE AND document.status IN (0, 1)
    ) AS draw_ready
) draw ON TRUE;
