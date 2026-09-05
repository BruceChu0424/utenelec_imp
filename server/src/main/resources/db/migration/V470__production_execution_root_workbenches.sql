-- V470: production root workbench, workshop tasks and controlled issue cancellation.
--
-- Root identity is the immutable outer material-analysis UUID. Historical plans
-- without that anchor are grouped by the outermost subplan UUID. Previews are
-- capped at three values; full work orders and related documents are fetched by
-- separate server-paginated endpoints. No legacy analysis, start time or notice
-- is fabricated.

ALTER TABLE production_material_stock_events
    ADD COLUMN IF NOT EXISTS reason TEXT;

COMMENT ON COLUMN production_material_stock_events.reason IS
    'Reason required by the application for new controlled ISSUE_REVERSE commands; historical rows remain NULL.';

-- New execution: workshop assignment + physical issue make a task eligible;
-- the first report draft advances READY directly (or legacy DISPATCHED) to
-- IN_PROGRESS in the same transaction. Direct READY -> IN_PROGRESS remains
-- fail-closed unless the report guard sets the exact transaction-local marker.
CREATE OR REPLACE FUNCTION fn_is_execution_report_auto_start_authorized(
    p_segment_id UUID,
    p_expected_version BIGINT
) RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
               current_setting(
                   'app.production_report_auto_start_segment_id', true)
                   = p_segment_id::text,
               FALSE)
       AND COALESCE(
               NULLIF(current_setting(
                   'app.production_report_auto_start_expected_version', true), '')
                   ::bigint = p_expected_version,
               FALSE);
$$;

DO $migration$
DECLARE
    definition TEXT;
    updated TEXT;
    old_transition TEXT := $old$OR (OLD.status = 'READY'
                AND NEW.status IN (
                    'WAITING', 'DISPATCHED', 'CANCELLED', 'REVERSED'))$old$;
    new_transition TEXT := $new$OR (OLD.status = 'READY'
                AND NEW.status IN (
                    'WAITING', 'DISPATCHED', 'CANCELLED', 'REVERSED'))
            OR (
                OLD.status = 'READY'
                AND NEW.status = 'IN_PROGRESS'
                AND fn_is_execution_report_auto_start_authorized(
                    OLD.id, OLD.lock_version)
            )$new$;
BEGIN
    SELECT pg_get_functiondef(
        'fn_validate_production_execution_segment()'::regprocedure)
    INTO definition;
    updated := replace(definition, old_transition, new_transition);
    IF updated = definition THEN
        RAISE EXCEPTION
            'V470 could not extend READY automatic report transition';
    END IF;
    EXECUTE updated;
END;
$migration$;

ALTER TABLE production_execution_segment_events
    DROP CONSTRAINT production_execution_segment_events_action_check,
    ADD CONSTRAINT production_execution_segment_events_action_check
        CHECK (action IN (
            'ASSIGNMENT', 'DISPATCH', 'START', 'CANCEL', 'REVERSE',
            'REOPEN_COMPLETION', 'RELEASE_DEFER',
            'AUTO_START_ON_REPORT'
        ));

INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable, bulk_assignable, sensitivity)
VALUES
    ('production_execution:view',
     '查看我的车间任务', '生产管理', '车间任务', 439, 'VIEW',
     '只允许查看本人主职或兼职车间子树、本人负责或本人管理车间的执行任务；不授予跨车间、计划全量或采购委外商业数据查看权',
     TRUE, TRUE, TRUE, 'NORMAL'),
    ('production_execution:overview',
     '查看生产调度进度总览', '生产管理', '生产调度', 438, 'VIEW',
     '查看按最外层物料分析聚合的调度进度；仍受生产计划对象范围约束，跨制单人需 production_plan:view:all',
     TRUE, TRUE, TRUE, 'NORMAL')
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order,
    action_type = EXCLUDED.action_type,
    description = EXCLUDED.description,
    active = EXCLUDED.active,
    assignable = EXCLUDED.assignable,
    bulk_assignable = EXCLUDED.bulk_assignable,
    sensitivity = EXCLUDED.sensitivity;

INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission ON permission.code = 'production_execution:view'
WHERE department.code = 'DEPT_PROD' AND department.is_deleted = FALSE
ON CONFLICT DO NOTHING;


INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission ON permission.code='production_execution:overview'
WHERE department.code='SUB_PLAN' AND department.is_deleted=FALSE
ON CONFLICT DO NOTHING;

-- Preserve effective access when the old progress/start entry points are
-- replaced. Personal revoke wins when several old permissions collapse.
CREATE TEMP TABLE v470_permission_expansion(
    old_code TEXT NOT NULL,
    new_code TEXT NOT NULL,
    PRIMARY KEY(old_code, new_code)
) ON COMMIT DROP;

INSERT INTO v470_permission_expansion(old_code, new_code) VALUES
    ('production_plan:view', 'production_execution:overview'),
    ('production_execution:start', 'production_execution:view'),
    ('production_daily_report:create', 'production_execution:view');

INSERT INTO role_permissions(role_id, permission_id)
SELECT DISTINCT source.role_id, target.id
FROM role_permissions source
JOIN permissions old_permission ON old_permission.id=source.permission_id
JOIN v470_permission_expansion expansion
  ON expansion.old_code=old_permission.code
JOIN permissions target ON target.code=expansion.new_code
ON CONFLICT(role_id, permission_id) DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT DISTINCT source.department_id, target.id
FROM department_permissions source
JOIN permissions old_permission ON old_permission.id=source.permission_id
JOIN v470_permission_expansion expansion
  ON expansion.old_code=old_permission.code
JOIN permissions target ON target.code=expansion.new_code
ON CONFLICT(department_id, permission_id) DO NOTHING;

CREATE TEMP TABLE v470_override_expansion
ON COMMIT DROP AS
SELECT DISTINCT ON (source.user_id, target.id)
       source.user_id, target.id AS permission_id, source.effect,
       source.authority_source, source.source_actor_user_id,
       source.row_version
FROM user_permission_overrides source
JOIN permissions old_permission ON old_permission.id=source.permission_id
JOIN v470_permission_expansion expansion
  ON expansion.old_code=old_permission.code
JOIN permissions target ON target.code=expansion.new_code
WHERE source.active=TRUE
ORDER BY source.user_id, target.id,
         CASE source.effect WHEN 'revoke' THEN 0 ELSE 1 END,
         source.row_version DESC;

INSERT INTO user_permission_overrides AS target(
    user_id, permission_id, effect, authority_source,
    source_actor_user_id, row_version, active)
SELECT user_id, permission_id, effect, authority_source,
       source_actor_user_id, row_version, TRUE
FROM v470_override_expansion
ON CONFLICT(user_id, permission_id) DO UPDATE
SET effect=EXCLUDED.effect,
    authority_source=EXCLUDED.authority_source,
    source_actor_user_id=EXCLUDED.source_actor_user_id,
    row_version=GREATEST(target.row_version, EXCLUDED.row_version)+1,
    active=TRUE
WHERE target.active=FALSE
   OR (target.effect='grant' AND EXCLUDED.effect='revoke');

CREATE INDEX IF NOT EXISTS idx_production_execution_workbench_open
    ON production_execution_segments(
        workshop_department_id, plan_end_date, plan_id, segment_no, id)
    INCLUDE (status, product_goods_id, product_color_id, planned_qty,
             responsible_employee_id, lock_version)
    WHERE is_deleted = FALSE
      AND status NOT IN ('COMPLETED', 'CANCELLED', 'REVERSED');

CREATE INDEX IF NOT EXISTS idx_production_execution_workbench_history
    ON production_execution_segments(plan_id, plan_end_date DESC, segment_no, id)
    INCLUDE (status, workshop_department_id, responsible_employee_id)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_production_plan_analysis_workbench
    ON production_plans(material_analysis_id, is_closed, status, bill_date, id)
    INCLUDE (maker_id, bill_no, department_id)
    WHERE is_deleted = FALSE AND material_analysis_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_preplan_supply_action_analysis_open
    ON preplan_supply_actions(analysis_id, status, route, id)
    WHERE status IN ('OPEN', 'CREATED', 'IN_PROGRESS');

CREATE INDEX IF NOT EXISTS idx_execution_segment_sales_allocations_segment_order
    ON execution_segment_sales_allocations(execution_segment_id, sales_order_item_id, id);

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
       CASE WHEN segment.status IN ('READY','DISPATCHED','IN_PROGRESS')
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
           WHEN segment.status NOT IN ('READY','DISPATCHED','IN_PROGRESS')
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
       FALSE AS can_start_fact
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

CREATE OR REPLACE VIEW v_production_execution_workbench_roots AS
WITH analysis_roots AS (
    SELECT 'ANALYSIS'::text AS root_type,
           analysis.id AS root_id,
           analysis.maker_id AS owner_employee_id,
           '物料分析 ' || left(analysis.id::text, 8) AS root_label,
           analysis.status AS source_status
    FROM production_material_analyses analysis
    WHERE analysis.is_deleted = FALSE AND analysis.status <> 'CANCELLED'
), legacy_roots AS (
    SELECT 'PLAN'::text AS root_type,
           plan.id AS root_id,
           plan.maker_id AS owner_employee_id,
           COALESCE(plan.bill_no,
                    '历史计划 ' || left(plan.id::text, 8)) AS root_label,
           plan.status::text AS source_status
    FROM production_plans plan
    WHERE plan.is_deleted = FALSE AND plan.material_analysis_id IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM subplan_links parent_link
          WHERE parent_link.subplan_id = plan.id
            AND parent_link.is_deleted = FALSE)
), roots AS (
    SELECT * FROM analysis_roots
    UNION ALL
    SELECT * FROM legacy_roots
)
SELECT root.root_type, root.root_id, root.owner_employee_id, root.root_label,
       CASE
           WHEN COALESCE(segment.segment_count, 0) = 0
                AND COALESCE(plan.open_count, 0) > 0 THEN 'PLAN_PENDING'
           WHEN COALESCE(segment.segment_count, 0) = 0
                AND COALESCE(action.open_count, 0) > 0 THEN 'PREPARING'
           WHEN COALESCE(segment.segment_count, 0) = 0 THEN 'ANALYZING'
           WHEN COALESCE(demand.remaining_qty, 0) > 0
             THEN 'PARTIALLY_SCHEDULED'
           WHEN COALESCE(segment.in_progress_count, 0) > 0 THEN 'IN_PROGRESS'
           WHEN COALESCE(segment.issued_count, 0)
                = COALESCE(segment.open_segment_count, 0)
                AND COALESCE(segment.open_segment_count, 0) > 0 THEN 'PREPARED'
           WHEN COALESCE(segment.material_ready_count, 0)
                < COALESCE(segment.open_segment_count, 0) THEN 'KIT_SHORT'
           ELSE 'KIT_READY_PREPARING'
       END AS status,
       sales.preview AS sales_order_preview,
       COALESCE(sales.total, 0)::integer AS sales_order_count,
       COALESCE(sales.total, 0) > 3 AS sales_order_has_more,
       work_order.preview AS work_order_preview,
       COALESCE(work_order.total, 0)::integer AS work_order_count,
       COALESCE(work_order.total, 0) > 3 AS work_order_has_more,
       workshop.preview AS workshop_preview,
       COALESCE(workshop.total, 0)::integer AS workshop_count,
       COALESCE(workshop.total, 0) > 3 AS workshop_has_more,
       product.code_preview AS product_code_preview,
       product.name_preview AS product_name_preview,
       product.color_preview AS product_color_preview,
       COALESCE(product.total, 0)::integer AS product_count,
       COALESCE(product.total, 0) > 3 AS product_has_more,
       quantity.preview AS quantity_summary,
       COALESCE(quantity.total_units, 0) > 1 AS mixed_units,
       COALESCE(quantity.total_units, 0)::integer AS execution_unit_count,
       COALESCE(quantity.total_units, 0) > 3 AS execution_unit_has_more,
       GREATEST(COALESCE(plan.plan_count,0),COALESCE(segment.plan_count,0))::integer AS plan_count,
       COALESCE(segment.segment_count, 0)::integer AS segment_count,
       COALESCE(segment.waiting_count, 0)::integer AS waiting_count,
       COALESCE(segment.ready_count, 0)::integer AS ready_count,
       COALESCE(segment.dispatched_count, 0)::integer AS dispatched_count,
       COALESCE(segment.in_progress_count, 0)::integer AS in_progress_count,
       COALESCE(segment.completed_count, 0)::integer AS completed_count,
       COALESCE(segment.material_ready_count, 0)::integer AS material_ready_count,
       COALESCE(segment.warehouse_ready_count, 0)::integer AS warehouse_ready_count,
       COALESCE(segment.issued_count, 0)::integer AS issued_count,
       COALESCE(segment.reportable_count, 0)::integer AS reportable_count,
       COALESCE(segment.fqc_pending_count, 0)::integer AS fqc_pending_count,
       COALESCE(segment.finished_pending_count, 0)::integer
           AS finished_inbound_pending_count,
       COALESCE(segment.earliest_begin_date, plan.earliest_begin_date)
           AS earliest_begin_date,
       COALESCE(segment.latest_end_date, plan.latest_end_date)
           AS latest_end_date,
       root.source_status,
       COALESCE(demand.remaining_qty, 0)::numeric AS remaining_demand_qty,
       COALESCE(action.open_count, 0)::integer AS open_action_count,
       COALESCE(plan.open_count, 0)::integer AS open_plan_count,
       COALESCE(segment.open_segment_count, 0)::integer AS open_segment_count
FROM roots root
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(GREATEST(item.requested_qty-item.approved_qty,0)),0)
               AS remaining_qty
    FROM production_material_analysis_items item
    WHERE root.root_type = 'ANALYSIS' AND item.analysis_id = root.root_id
      AND item.is_deleted = FALSE
) demand ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*) FILTER (
               WHERE action.status IN ('OPEN','CREATED','IN_PROGRESS'))::integer
               AS open_count
    FROM preplan_supply_actions action
    WHERE root.root_type = 'ANALYSIS' AND action.analysis_id = root.root_id
) action ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*)::integer AS plan_count,
           COUNT(*) FILTER (
               WHERE plan.status = 0 OR (plan.status = 1
                 AND plan.is_closed = FALSE AND plan.is_stopped = FALSE
                 AND plan.is_canceled = FALSE))::integer AS open_count,
           MIN(plan.bill_date) AS earliest_begin_date,
           MAX(plan.delivery_date) AS latest_end_date
    FROM production_plans plan
    WHERE (root.root_type = 'ANALYSIS'
           AND plan.material_analysis_id = root.root_id
           AND plan.is_deleted = FALSE)
       OR (root.root_type = 'PLAN' AND plan.id = root.root_id
           AND plan.is_deleted = FALSE)
) plan ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(DISTINCT task.plan_id)::integer AS plan_count,
           COUNT(*)::integer AS segment_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED'))::integer AS open_segment_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'WAITING')::integer AS waiting_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'READY')::integer AS ready_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'DISPATCHED')::integer AS dispatched_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'IN_PROGRESS')::integer AS in_progress_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'COMPLETED')::integer AS completed_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED')
               AND task.material_status = 'KIT_READY')::integer AS material_ready_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED') AND task.warehouse_ready)::integer
               AS warehouse_ready_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED') AND task.issued)::integer AS issued_count,
           COUNT(*) FILTER (WHERE task.reportable)::integer AS reportable_count,
           COUNT(*) FILTER (WHERE task.fqc_pending_qty > 0)::integer AS fqc_pending_count,
           COUNT(*) FILTER (WHERE task.finished_inbound_pending_qty > 0)::integer
               AS finished_pending_count,
           MIN(task.plan_begin_date) AS earliest_begin_date,
           MAX(task.plan_end_date) AS latest_end_date
    FROM v_production_execution_workbench_segments task
    WHERE task.root_type = root.root_type AND task.root_id = root.root_id
) segment ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*)::integer AS total,
           string_agg(source.bill_no,' / ' ORDER BY source.bill_no)
               FILTER (WHERE source.position <= 3) AS preview
    FROM (
        SELECT distinct_source.order_id, distinct_source.bill_no,
               row_number() OVER (
                   ORDER BY distinct_source.bill_no, distinct_source.order_id) AS position
        FROM (
            SELECT raw.order_id, MIN(raw.bill_no) AS bill_no
            FROM (
                SELECT sales_order.id AS order_id, sales_order.bill_no
                FROM v_production_execution_workbench_segments task
                JOIN execution_segment_sales_allocations allocation
                  ON allocation.execution_segment_id=task.segment_id
                JOIN sales_order_items sales_item
                  ON sales_item.id=allocation.sales_order_item_id
                JOIN sales_orders sales_order ON sales_order.id=sales_item.order_id
                WHERE task.root_type=root.root_type AND task.root_id=root.root_id
                UNION ALL
                SELECT sales_order.id, sales_order.bill_no
                FROM production_material_analysis_items analysis_item
                JOIN sales_order_items sales_item
                  ON sales_item.id=analysis_item.sales_order_item_id
                JOIN sales_orders sales_order ON sales_order.id=sales_item.order_id
                WHERE root.root_type='ANALYSIS'
                  AND analysis_item.analysis_id=root.root_id
                  AND analysis_item.is_deleted=FALSE
            ) raw
            GROUP BY raw.order_id
        ) distinct_source
    ) source
) sales ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*)::integer AS total,
           (SELECT string_agg(x.segment_code,' / ' ORDER BY x.segment_code)
            FROM (SELECT task2.segment_code
                  FROM v_production_execution_workbench_segments task2
                  WHERE task2.root_type=root.root_type AND task2.root_id=root.root_id
                  ORDER BY task2.segment_code LIMIT 3) x) AS preview
    FROM v_production_execution_workbench_segments task
    WHERE task.root_type=root.root_type AND task.root_id=root.root_id
) work_order ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(DISTINCT task.workshop_department_id)::integer AS total,
           (SELECT string_agg(x.workshop_name,' / ' ORDER BY x.workshop_name)
            FROM (SELECT DISTINCT task2.workshop_name
                  FROM v_production_execution_workbench_segments task2
                  WHERE task2.root_type=root.root_type AND task2.root_id=root.root_id
                    AND task2.workshop_name IS NOT NULL
                  ORDER BY task2.workshop_name LIMIT 3) x) AS preview
    FROM v_production_execution_workbench_segments task
    WHERE task.root_type=root.root_type AND task.root_id=root.root_id
) workshop ON TRUE
LEFT JOIN LATERAL (
    WITH raw_product AS (
        SELECT analysis_item.goods_id, goods.code, goods.name,
               color.name AS color_name
        FROM production_material_analysis_items analysis_item
        JOIN goods ON goods.id=analysis_item.goods_id
        LEFT JOIN colors color ON color.id=analysis_item.color_id
        WHERE root.root_type='ANALYSIS'
          AND analysis_item.analysis_id=root.root_id
          AND analysis_item.is_deleted=FALSE
        UNION ALL
        SELECT task.product_goods_id, task.product_code, task.product_name,
               task.product_color_name
        FROM v_production_execution_workbench_segments task
        WHERE task.root_type=root.root_type AND task.root_id=root.root_id
    ), ranked_product AS (
        SELECT grouped.goods_id, grouped.code, grouped.name,
               row_number() OVER (ORDER BY grouped.code,grouped.goods_id) AS position
        FROM (
            SELECT goods_id, MIN(code) AS code, MIN(name) AS name
            FROM raw_product GROUP BY goods_id
        ) grouped
    )
    SELECT (SELECT COUNT(*) FROM ranked_product)::integer AS total,
           (SELECT string_agg(code,' / ' ORDER BY code)
            FROM ranked_product WHERE position<=3) AS code_preview,
           (SELECT string_agg(name,' / ' ORDER BY name)
            FROM ranked_product WHERE position<=3) AS name_preview,
           (SELECT string_agg(color_name,' / ' ORDER BY color_name)
            FROM (SELECT DISTINCT color_name FROM raw_product
                  WHERE color_name IS NOT NULL
                  ORDER BY color_name LIMIT 3) colors) AS color_preview
) product ON TRUE
LEFT JOIN LATERAL (
    WITH unit_totals AS (
        SELECT task.product_unit_name AS unit_name,
               SUM(task.planned_qty) AS planned_qty,
               SUM(task.reported_qty) AS reported_qty,
               SUM(task.fqc_pending_qty) AS fqc_pending_qty,
               SUM(task.fqc_passed_qty) AS fqc_passed_qty,
               SUM(task.fqc_failed_qty) AS fqc_failed_qty,
               SUM(task.finished_inbound_pending_qty) AS inbound_pending_qty,
               SUM(task.inbound_qty) AS inbound_qty
        FROM v_production_execution_workbench_segments task
        WHERE task.root_type=root.root_type AND task.root_id=root.root_id
        GROUP BY task.product_unit_name
        UNION ALL
        SELECT unit.name, SUM(item.requested_qty), 0, 0, 0, 0, 0, 0
        FROM production_material_analysis_items item
        JOIN units unit ON unit.id=item.unit_id
        WHERE root.root_type='ANALYSIS' AND item.analysis_id=root.root_id
          AND item.is_deleted=FALSE
          AND NOT EXISTS (
              SELECT 1 FROM v_production_execution_workbench_segments task
              WHERE task.root_type='ANALYSIS' AND task.root_id=root.root_id)
        GROUP BY unit.name
    ), ranked_unit AS (
        SELECT unit_totals.*,
               row_number() OVER (ORDER BY unit_name) AS position
        FROM unit_totals
    )
    SELECT COUNT(*)::integer AS total_units,
           string_agg(
               COALESCE(unit_name,'单位未维护') || ': 计划 ' || planned_qty::text
               || ' / 报工 ' || reported_qty::text
               || ' / FQC待检 ' || fqc_pending_qty::text
               || ' / 通过 ' || fqc_passed_qty::text
               || ' / 失败 ' || fqc_failed_qty::text
               || ' / 待点收 ' || inbound_pending_qty::text
               || ' / 实收 ' || inbound_qty::text,
               ' / ' ORDER BY unit_name) FILTER (WHERE position<=3) AS preview
    FROM ranked_unit
) quantity ON TRUE
WHERE (root.root_type='ANALYSIS' AND
       (COALESCE(demand.remaining_qty,0)>0 OR COALESCE(action.open_count,0)>0
        OR COALESCE(plan.open_count,0)>0 OR COALESCE(segment.open_segment_count,0)>0))
   OR (root.root_type='PLAN' AND
       (COALESCE(plan.open_count,0)>0 OR COALESCE(segment.open_segment_count,0)>0));

COMMENT ON VIEW v_production_execution_workbench_roots IS
    'One bounded row per outer analysis; legacy plans use the outermost plan UUID.';
COMMENT ON VIEW v_production_execution_workbench_segments IS
    'Exact work orders with effective fqty, FQC, pending inbound and iqty facts.';

INSERT INTO permission_surfaces(id, surface_key, name, sort_order, enabled)
VALUES ('47000000-0000-4000-8000-000000000001',
        'production.workshop-tasks', '我的车间任务', 276, TRUE)
ON CONFLICT (surface_key) DO NOTHING;

DELETE FROM permission_surface_permissions link
USING permission_surfaces surface, permissions permission
WHERE link.surface_id=surface.id AND link.permission_id=permission.id
  AND surface.surface_key='production.progress'
  AND permission.code='production_plan:view';

-- Legacy endpoints remain callable for old deep links, but the current
-- permission workbench must not advertise manual dispatch/start actions.
DELETE FROM permission_surface_permissions link
USING permission_surfaces surface, permissions permission
WHERE link.surface_id=surface.id AND link.permission_id=permission.id
  AND surface.surface_key IN (
      'production.plan', 'production.workshop-tasks')
  AND permission.code IN (
      'production_execution:dispatch', 'production_execution:start');

INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code='production_execution:overview'
WHERE surface.surface_key='production.progress'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN ('production_execution:view',
      'production_daily_report:view','production_daily_report:create')
 AND permission.active=TRUE
WHERE surface.surface_key='production.workshop-tasks'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- Preserve currently enabled manager delegations with fresh identity/version
-- snapshots. Central personal revoke remains authoritative in the resolver.
CREATE TEMP TABLE v470_manager_delegation_expansion
ON COMMIT DROP AS
SELECT DISTINCT ON (
           source.user_id, target.id, source.department_id)
       source.user_id,
       target.id AS permission_id,
       source.department_id,
       CASE target.code
           WHEN 'production_execution:overview'
               THEN 'production.progress'
           ELSE 'production.workshop-tasks'
       END AS surface_key,
       source.granted_by_user_id,
       source.row_version,
       source.created_at,
       source.updated_at,
       source.created_by,
       source.updated_by,
       source.target_employee_generation,
       source.target_department_generation,
       source.grantor_employee_generation,
       source.scope_source,
       source.scope_department_id,
       source.scope_generation,
       source.scope_assignment_id,
       source.scope_assignment_version
FROM manager_permission_delegations source
JOIN permissions old_permission ON old_permission.id=source.permission_id
JOIN v470_permission_expansion expansion
  ON expansion.old_code=old_permission.code
JOIN permissions target ON target.code=expansion.new_code
WHERE source.enabled=TRUE
  AND NOT EXISTS (
      SELECT 1
      FROM manager_permission_delegations existing
      WHERE existing.user_id=source.user_id
        AND existing.permission_id=target.id
        AND existing.department_id=source.department_id)
ORDER BY source.user_id, target.id, source.department_id,
         source.row_version DESC, source.updated_at DESC;

WITH incoming AS (
    SELECT user_id, count(*)::bigint AS auth_bumps
    FROM v470_manager_delegation_expansion
    GROUP BY user_id
)
INSERT INTO manager_permission_delegations(
    user_id, permission_id, department_id, enabled, surface_key,
    granted_by_user_id, row_version, created_at, updated_at,
    created_by, updated_by, target_user_generation,
    target_employee_generation, target_department_generation,
    grantor_user_generation, grantor_employee_generation,
    grantor_auth_version, grantor_authorization_epoch,
    scope_source, scope_department_id, scope_generation,
    scope_assignment_id, scope_assignment_version)
SELECT source.user_id, source.permission_id, source.department_id,
       TRUE, source.surface_key, source.granted_by_user_id,
       source.row_version, source.created_at, source.updated_at,
       source.created_by, source.updated_by,
       target_user.permission_delegation_generation,
       source.target_employee_generation,
       source.target_department_generation,
       grantor_user.permission_delegation_generation,
       source.grantor_employee_generation,
       grantor_user.auth_version + COALESCE(grantor_incoming.auth_bumps,0),
       auth_state.epoch,
       source.scope_source, source.scope_department_id,
       source.scope_generation, source.scope_assignment_id,
       source.scope_assignment_version
FROM v470_manager_delegation_expansion source
JOIN users target_user ON target_user.id=source.user_id
JOIN users grantor_user ON grantor_user.id=source.granted_by_user_id
LEFT JOIN incoming grantor_incoming
  ON grantor_incoming.user_id=source.granted_by_user_id
CROSS JOIN authorization_state auth_state
WHERE auth_state.singleton_id=1
ON CONFLICT(user_id, permission_id, department_id) DO NOTHING;
