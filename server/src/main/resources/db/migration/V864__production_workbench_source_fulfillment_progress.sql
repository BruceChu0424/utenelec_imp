-- Planning and fulfillment are separate facts. Qualified root-output handoffs
-- (including covered stock) do not need a work order; a submitted plan or an
-- exact pending procurement promise is arranged, but is not finished output.
-- Never use available public stock or an unclaimed future candidate as coverage.
CREATE VIEW v_production_analysis_workbench_item_progress AS
SELECT item.analysis_id, item.id AS analysis_item_id,
       item.goods_id, item.color_id, item.unit_id,
       GREATEST(item.requested_qty - item.submitted_qty - item.approved_qty
                - item.root_fulfilled_qty - COALESCE(component_stock.qty, 0)
                - COALESCE(pending.qty, 0)
                    / COALESCE(NULLIF(root.per_product_qty, 0), 1), 0)::numeric
           AS remaining_schedule_qty,
       GREATEST(item.requested_qty - item.root_fulfilled_qty
                - COALESCE(finished.qty, 0) - COALESCE(component_stock.qty, 0), 0)::numeric
           AS remaining_fulfillment_qty
FROM production_material_analysis_items item
LEFT JOIN production_material_analysis_materials root
  ON root.id = item.root_material_id AND root.active
LEFT JOIN production_material_analysis_materials parent
  ON parent.id = item.parent_analysis_material_id AND parent.active
LEFT JOIN LATERAL (
    -- A MAKE_COMPONENT quota can be covered by another qualified source or by
    -- real stock already formalized to its parent's demand. A public simulation
    -- does not qualify. The child's own finished output is already in iqty.
    SELECT SUM(source.qty) AS qty
    FROM (
        SELECT LEAST(balance.effective_qty,
                     GREATEST(reservation.qty - reservation.consumed_qty - reservation.released_qty, 0)) AS qty
        FROM v_preplan_stock_entitlement_beneficiary_balance balance
        JOIN stock_reservations reservation ON reservation.id = balance.stock_reservation_id
        JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id = reservation.id
        LEFT JOIN preplan_supply_action_allocations origin_allocation ON origin_allocation.id = exact.supply_action_allocation_id
        LEFT JOIN preplan_supply_actions origin_action ON origin_action.id = origin_allocation.action_id
        WHERE balance.beneficiary_analysis_id = item.analysis_id
          AND balance.beneficiary_analysis_material_id = parent.id
          AND reservation.status = 0 AND NOT reservation.is_deleted
          AND fn_preplan_reservation_has_qualified_origin(reservation.id)
          AND exact.make_source_analysis_item_id IS DISTINCT FROM item.id
          AND NOT (COALESCE(origin_action.external_document_type, '') = 'PREPLAN_MAKE_TASK'
                   AND origin_action.external_document_id = item.id)
        UNION ALL
        SELECT GREATEST(LEAST(SUM(GREATEST(formalize.qty - COALESCE((
                   SELECT SUM(restored.qty) FROM preplan_stock_entitlement_events restored
                   WHERE restored.event_type = 'RESTORE' AND restored.counter_event_id = formalize.id), 0), 0)),
                   target.qty - target.released_qty), 0)
        FROM preplan_stock_entitlement_events formalize
        JOIN stock_reservations target ON target.id = formalize.target_stock_reservation_id
        JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id = formalize.stock_reservation_id
        LEFT JOIN preplan_supply_action_allocations origin_allocation ON origin_allocation.id = exact.supply_action_allocation_id
        LEFT JOIN preplan_supply_actions origin_action ON origin_action.id = origin_allocation.action_id
        WHERE formalize.event_type = 'FORMALIZE'
          AND formalize.beneficiary_analysis_id = item.analysis_id
          AND formalize.beneficiary_analysis_material_id = parent.id
          AND NOT target.is_deleted
          AND fn_preplan_reservation_has_qualified_origin(formalize.stock_reservation_id)
          AND exact.make_source_analysis_item_id IS DISTINCT FROM item.id
          AND NOT (COALESCE(origin_action.external_document_type, '') = 'PREPLAN_MAKE_TASK'
                   AND origin_action.external_document_id = item.id)
        GROUP BY target.id, target.qty, target.released_qty
        UNION ALL
        -- A normal-warehouse target can contain both exact-origin and public
        -- stock while requires_qualified_origin is FALSE. Credit only its public
        -- remainder here; the exact FORMALIZE shares belong to the branch above.
        SELECT GREATEST(reservation.qty - reservation.released_qty - COALESCE((
                   SELECT SUM(GREATEST(formalize.qty - COALESCE((
                       SELECT SUM(restored.qty) FROM preplan_stock_entitlement_events restored
                       WHERE restored.event_type = 'RESTORE' AND restored.counter_event_id = formalize.id), 0), 0))
                   FROM preplan_stock_entitlement_events formalize
                   WHERE formalize.event_type = 'FORMALIZE'
                     AND formalize.target_stock_reservation_id = reservation.id), 0), 0)
        FROM stock_reservations reservation
        JOIN production_material_demands demand ON demand.id = reservation.demand_id
        JOIN production_plans plan ON plan.id = demand.plan_id
        WHERE reservation.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
          AND NOT reservation.requires_qualified_origin AND NOT reservation.is_deleted
          AND NOT demand.is_deleted AND demand.status NOT IN ('RELEASED', 'REVERSED')
          AND plan.material_analysis_id = item.analysis_id
          AND plan.status = 1 AND NOT plan.is_deleted AND NOT plan.is_canceled
          AND fn_analysis_plan_material_matches(plan.material_analysis_item_id, parent.id)
          AND demand.goods_id = item.goods_id
          AND demand.color_id IS NOT DISTINCT FROM item.color_id
          AND demand.unit_id = item.unit_id
    ) source
    WHERE item.source_type = 'MAKE_COMPONENT' AND parent.id IS NOT NULL
) component_stock ON TRUE
LEFT JOIN LATERAL (
    -- The plan's public output and excess output do not fulfill its private
    -- analysis source. Read approved physical receipts in the frozen unit,
    -- capped by this source's private plan-link budget (V694/V722 authority).
    SELECT SUM(GREATEST(LEAST(link.submitted_qty,
                   GREATEST(plan_item.qty - COALESCE(batch_action.public_surplus_qty
                       / COALESCE(plan_item.unit_rate, 1), link.public_surplus_qty, 0), 0),
                   COALESCE(received.qty, 0) / COALESCE(plan_item.unit_rate, 1)), 0)) AS qty
    FROM production_plans plan
    JOIN production_plan_items plan_item
      ON plan_item.plan_id = plan.id AND NOT plan_item.is_deleted
    JOIN production_material_analysis_plan_links link
      ON link.plan_id = plan.id AND link.analysis_id = item.analysis_id
     AND link.analysis_item_id = item.id AND link.allocation_status = 'APPROVED'
    LEFT JOIN preplan_aggregate_batches batch ON batch.plan_id = plan.id AND batch.route = 'MAKE'
    LEFT JOIN preplan_supply_actions batch_action
      ON batch_action.id = batch.action_id AND batch_action.status <> 'CANCELLED'
    LEFT JOIN LATERAL (
        SELECT SUM(output.base_qty) AS qty
        FROM stock_document_items output
        JOIN stock_documents document ON document.id = output.doc_id
         AND document.doc_type = 'FINISHED_IN' AND document.status = 1 AND NOT document.is_deleted
        WHERE output.upstream_item_id = plan_item.id AND output.bill_type = 'FINISHED_IN'
          AND NOT output.is_deleted AND NOT fn_finished_in_is_public_output(output.id)
    ) received ON TRUE
    WHERE plan.material_analysis_id = item.analysis_id
      AND plan.material_analysis_item_id = item.id
      AND plan.status = 1 AND NOT plan.is_deleted AND NOT plan.is_canceled
      AND COALESCE(plan_item.unit_rate, 1) > 0
) finished ON TRUE
LEFT JOIN LATERAL (
    -- Same exact pending-allocation authority as MaterialAnalysisService.
    -- MAKE plans are already in submitted_qty/approved_qty; subtracting their
    -- action again would conceal a genuine unarranged remainder.
    SELECT SUM(supply.qty) AS qty FROM (
    SELECT GREATEST(CASE
        WHEN fn_preplan_action_has_future_transfer(action.id)
          OR fn_preplan_action_has_shared_claim_history(action.id)
            THEN fn_preplan_future_allocation_pending_qty(allocation.id)
        WHEN action.operation_type = 'SHARED_FUTURE_CLAIM'
            THEN fn_preplan_shared_allocation_pending_qty(allocation.id)
        ELSE fn_preplan_allocation_admitted_qty(allocation.id)
             - fn_preplan_allocation_effective_exact_qty(allocation.id)
             - COALESCE((
                 SELECT SUM(CASE WHEN output.event_kind = 'FULFILL'
                            THEN output.qty_base ELSE -output.qty_base END)
                 FROM preplan_root_output_events output
                 JOIN preplan_analysis_stock_exact_pegs exact
                   ON exact.stock_reservation_id = output.source_reservation_id
                 WHERE exact.supply_action_allocation_id = allocation.id), 0)
        END, 0) AS qty
    FROM preplan_supply_action_allocations allocation
    JOIN preplan_supply_actions action ON action.id = allocation.action_id
    WHERE allocation.analysis_id = item.analysis_id
      AND allocation.analysis_material_id = COALESCE(item.root_material_id, parent.id)
      AND action.status IN ('OPEN', 'CREATED', 'IN_PROGRESS')
      AND action.external_document_type <> 'PREPLAN_MAKE_TASK'
    UNION ALL
    SELECT fn_preplan_make_public_claim_pending_qty(claim.id)
    FROM preplan_make_public_claims claim
    WHERE claim.target_analysis_id = item.analysis_id
      AND claim.target_material_id = COALESCE(item.root_material_id, parent.id)
    ) supply
) pending ON TRUE
WHERE NOT item.is_deleted AND item.requested_qty > 0;

COMMENT ON VIEW v_production_analysis_workbench_item_progress IS
    'Exact source demand remaining to arrange and fulfill; qualified stock/output, plans and pending supply retain distinct meanings.';

-- Use the same actual fulfillment facts for analysis history and root discovery.
-- Issuing plans, announcing procurement and public stock candidates remain open.
CREATE OR REPLACE FUNCTION fn_material_analysis_fulfillment_status(p_analysis_id UUID)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT CASE
      WHEN analysis.status = 'CANCELLED' THEN 'CANCELLED'
      WHEN NOT EXISTS (
          SELECT 1 FROM v_production_analysis_workbench_item_progress item
          WHERE item.analysis_id = analysis.id AND item.remaining_fulfillment_qty > 0)
        AND NOT EXISTS (
          SELECT 1 FROM preplan_supply_actions action
          WHERE action.analysis_id = analysis.id AND action.status IN ('OPEN', 'CREATED', 'IN_PROGRESS'))
        AND NOT EXISTS (
          SELECT 1 FROM preplan_make_public_claims claim
          WHERE claim.target_analysis_id = analysis.id AND fn_preplan_make_public_claim_pending_qty(claim.id) > 0)
        THEN 'COMPLETED'
      WHEN EXISTS (
          SELECT 1 FROM production_material_analysis_items item
          WHERE item.analysis_id = analysis.id AND NOT item.is_deleted
            AND item.submitted_qty + item.approved_qty + item.root_fulfilled_qty > 0)
        THEN 'PARTIALLY_PLANNED'
      ELSE 'ACTIVE' END
    FROM production_material_analyses analysis WHERE analysis.id = p_analysis_id;
$$;

CREATE OR REPLACE VIEW v_production_execution_workbench_roots AS
WITH analysis_roots AS (
    SELECT 'ANALYSIS'::text AS root_type,
           analysis.id AS root_id,
           analysis.maker_id AS owner_employee_id,
           maker.full_name AS owner_employee_name,
           COALESCE(analysis.analysis_no,
                    '物料分析 ' || left(analysis.id::text, 8)) AS root_label,
           analysis.status AS source_status,
           analysis.analyzed_at
    FROM production_material_analyses analysis
    LEFT JOIN employees maker ON maker.id = analysis.maker_id
    WHERE analysis.is_deleted = FALSE AND analysis.status <> 'CANCELLED'
), legacy_roots AS (
    SELECT 'PLAN'::text AS root_type,
           plan.id AS root_id,
           plan.maker_id AS owner_employee_id,
           maker.full_name AS owner_employee_name,
           COALESCE(plan.bill_no,
                    '历史计划 ' || left(plan.id::text, 8)) AS root_label,
           plan.status::text AS source_status,
           plan.created_at AS analyzed_at
    FROM production_plans plan
    LEFT JOIN employees maker ON maker.id = plan.maker_id
    WHERE plan.is_deleted = FALSE AND plan.material_analysis_id IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM subplan_links parent_link
          WHERE parent_link.subplan_id = plan.id
            AND parent_link.is_deleted = FALSE)
), roots AS (
    SELECT * FROM analysis_roots
    UNION ALL
    SELECT * FROM legacy_roots
),
-- 根分析行（顶层产品）：锚点子件行（MAKE_COMPONENT / SUBCONTRACT_MAKE）与
-- 其余带父行都不是顶层；顶层进度只统计这些行的计划段。
root_analysis_items AS (
    SELECT item.analysis_id, item.id
    FROM production_material_analysis_items item
    WHERE item.is_deleted = FALSE
      AND item.parent_analysis_material_id IS NULL
      AND item.source_type NOT IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE')
),
-- 顶层完工进度：只聚合根分析行（PLAN 根全量）的计划/实收入库数量。
-- 子件锚点段与委外前置段的完工不冒充顶层产品进度。
root_progress_rollup AS (
    SELECT task.root_type, task.root_id,
           SUM(task.planned_qty) AS root_planned_qty,
           SUM(LEAST(task.planned_inbound_qty, task.planned_qty))
               AS root_inbound_qty
    FROM v_production_execution_workbench_segments task
    JOIN production_plans plan
      ON plan.id = task.plan_id AND plan.is_deleted = FALSE
    LEFT JOIN root_analysis_items root_item
      ON root_item.analysis_id = plan.material_analysis_id
     AND root_item.id = plan.material_analysis_item_id
    WHERE task.root_type = 'PLAN'
       OR (task.root_type = 'ANALYSIS' AND root_item.id IS NOT NULL)
    GROUP BY task.root_type, task.root_id
),
-- 单趟段聚合：全部计数与工单号预览来自一次段视图扫描（V470 每根各扫一次）。
segment_rollup AS (
    SELECT task.root_type,
           task.root_id,
           COUNT(DISTINCT task.plan_id)::integer AS plan_count,
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
           MAX(task.plan_end_date) AS latest_end_date,
           string_agg(task.segment_code, ' / ' ORDER BY task.segment_code)
               FILTER (WHERE task.code_position <= 3) AS work_order_preview
    FROM (
        SELECT v_segments.*,
               row_number() OVER (
                   PARTITION BY v_segments.root_type, v_segments.root_id
                   ORDER BY v_segments.segment_code) AS code_position
        FROM v_production_execution_workbench_segments v_segments
    ) task
    GROUP BY task.root_type, task.root_id
),
-- 关联订单：段→销售分摊 + 分析来源行，两路合并后按订单去重、按根聚合。
sales_order_rollup AS (
    SELECT source.root_type, source.root_id,
           COUNT(*)::integer AS total,
           string_agg(source.bill_no, ' / ' ORDER BY source.bill_no)
               FILTER (WHERE source.position <= 3) AS preview
    FROM (
        SELECT grouped.root_type, grouped.root_id, grouped.order_id,
               MIN(grouped.bill_no) AS bill_no,
               row_number() OVER (
                   PARTITION BY grouped.root_type, grouped.root_id
                   ORDER BY MIN(grouped.bill_no), grouped.order_id) AS position
        FROM (
            SELECT task.root_type, task.root_id,
                   sales_order.id AS order_id, sales_order.bill_no
            FROM v_production_execution_workbench_segments task
            JOIN execution_segment_sales_allocations allocation
              ON allocation.execution_segment_id = task.segment_id
            JOIN sales_order_items sales_item
              ON sales_item.id = allocation.sales_order_item_id
            JOIN sales_orders sales_order ON sales_order.id = sales_item.order_id
            UNION ALL
            SELECT 'ANALYSIS', analysis_item.analysis_id,
                   sales_order.id, sales_order.bill_no
            FROM production_material_analysis_items analysis_item
            JOIN sales_order_items sales_item
              ON sales_item.id = analysis_item.sales_order_item_id
            JOIN sales_orders sales_order ON sales_order.id = sales_item.order_id
            WHERE analysis_item.is_deleted = FALSE
        ) grouped
        GROUP BY grouped.root_type, grouped.root_id, grouped.order_id
    ) source
    GROUP BY source.root_type, source.root_id
),
-- 生产车间：计数按车间部门去重；预览按车间名去重取前三个（两套口径与 V470 相同）。
workshop_count_rollup AS (
    SELECT task.root_type, task.root_id,
           COUNT(DISTINCT task.workshop_department_id)::integer AS total
    FROM v_production_execution_workbench_segments task
    GROUP BY task.root_type, task.root_id
), workshop_preview_rollup AS (
    SELECT distinct_ws.root_type, distinct_ws.root_id,
           string_agg(distinct_ws.workshop_name, ' / '
                      ORDER BY distinct_ws.workshop_name)
               FILTER (WHERE distinct_ws.position <= 3) AS preview
    FROM (
        SELECT ranked.root_type, ranked.root_id, ranked.workshop_name,
               row_number() OVER (
                   PARTITION BY ranked.root_type, ranked.root_id
                   ORDER BY ranked.workshop_name) AS position
        FROM (
            SELECT DISTINCT task.root_type, task.root_id, task.workshop_name
            FROM v_production_execution_workbench_segments task
            WHERE task.workshop_name IS NOT NULL
        ) ranked
    ) distinct_ws
    GROUP BY distinct_ws.root_type, distinct_ws.root_id
),
-- 产品颜色：两路原始行合并去重取前三个（V490 前保持与 V470 完全同源）。
color_rollup AS (
    SELECT distinct_colors.root_type, distinct_colors.root_id,
           string_agg(distinct_colors.color_name, ' / '
                      ORDER BY distinct_colors.color_name)
               FILTER (WHERE distinct_colors.position <= 3) AS preview
    FROM (
        SELECT ranked.root_type, ranked.root_id, ranked.color_name,
               row_number() OVER (
                   PARTITION BY ranked.root_type, ranked.root_id
                   ORDER BY ranked.color_name) AS position
        FROM (
            SELECT DISTINCT task.root_type, task.root_id, task.product_color_name AS color_name
            FROM v_production_execution_workbench_segments task
            WHERE task.product_color_name IS NOT NULL
            UNION
            SELECT 'ANALYSIS', analysis_item.analysis_id, color.name
            FROM production_material_analysis_items analysis_item
            JOIN colors color ON color.id = analysis_item.color_id
            WHERE analysis_item.is_deleted = FALSE AND color.name IS NOT NULL
        ) ranked
    ) distinct_colors
    GROUP BY distinct_colors.root_type, distinct_colors.root_id
),
-- 产品：分析来源行 + 段产品两路合并，按货品去重（编码/名称取 MIN，与 V470 相同）。
product_rollup AS (
    SELECT grouped.root_type, grouped.root_id,
           COUNT(*)::integer AS total,
           string_agg(grouped.code, ' / ' ORDER BY grouped.code)
               FILTER (WHERE grouped.position <= 3) AS code_preview,
           string_agg(grouped.name, ' / ' ORDER BY grouped.name)
               FILTER (WHERE grouped.position <= 3) AS name_preview
    FROM (
        SELECT inner_grouped.root_type, inner_grouped.root_id,
               inner_grouped.goods_id, MIN(inner_grouped.code) AS code,
               MIN(inner_grouped.name) AS name,
               row_number() OVER (
                   PARTITION BY inner_grouped.root_type, inner_grouped.root_id
                   ORDER BY MIN(inner_grouped.code), inner_grouped.goods_id) AS position
        FROM (
            SELECT 'ANALYSIS' AS root_type, analysis_item.analysis_id AS root_id,
                   analysis_item.goods_id, goods.code, goods.name
            FROM production_material_analysis_items analysis_item
            JOIN goods ON goods.id = analysis_item.goods_id
            WHERE analysis_item.is_deleted = FALSE
            UNION ALL
            SELECT task.root_type, task.root_id, task.product_goods_id,
                   task.product_code, task.product_name
            FROM v_production_execution_workbench_segments task
        ) inner_grouped
        GROUP BY inner_grouped.root_type, inner_grouped.root_id, inner_grouped.goods_id
    ) grouped
    GROUP BY grouped.root_type, grouped.root_id
),
-- 数量摘要：段按单位聚合；无段的分析根回退按分析行需求聚合（反连已算好的
-- segment_rollup，不再逐行探测段视图）。
quantity_rollup AS (
    SELECT ranked.root_type, ranked.root_id,
           COUNT(*)::integer AS total_units,
           string_agg(
               COALESCE(ranked.unit_name,'单位未维护') || ': 计划 ' || ranked.planned_qty::text
               || ' / 报工 ' || ranked.reported_qty::text
               || ' / FQC待检 ' || ranked.fqc_pending_qty::text
               || ' / 通过 ' || ranked.fqc_passed_qty::text
               || ' / 失败 ' || ranked.fqc_failed_qty::text
               || ' / 待点收 ' || ranked.inbound_pending_qty::text
               || ' / 实收 ' || ranked.inbound_qty::text,
               ' / ' ORDER BY ranked.unit_name) FILTER (WHERE ranked.position <= 3)
               AS preview
    FROM (
        SELECT unit_totals.root_type, unit_totals.root_id,
               unit_totals.unit_name, unit_totals.planned_qty,
               unit_totals.reported_qty, unit_totals.fqc_pending_qty,
               unit_totals.fqc_passed_qty, unit_totals.fqc_failed_qty,
               unit_totals.inbound_pending_qty, unit_totals.inbound_qty,
               row_number() OVER (
                   PARTITION BY unit_totals.root_type, unit_totals.root_id
                   ORDER BY unit_totals.unit_name) AS position
        FROM (
            SELECT task.root_type, task.root_id,
                   task.product_unit_name AS unit_name,
                   SUM(task.planned_qty) AS planned_qty,
                   SUM(task.reported_qty) AS reported_qty,
                   SUM(task.fqc_pending_qty) AS fqc_pending_qty,
                   SUM(task.fqc_passed_qty) AS fqc_passed_qty,
                   SUM(task.fqc_failed_qty) AS fqc_failed_qty,
                   SUM(task.finished_inbound_pending_qty) AS inbound_pending_qty,
                   SUM(task.inbound_qty) AS inbound_qty
            FROM v_production_execution_workbench_segments task
            GROUP BY task.root_type, task.root_id, task.product_unit_name
            UNION ALL
            SELECT 'ANALYSIS', item.analysis_id, unit.name,
                   SUM(item.requested_qty), 0, 0, 0, 0, 0, 0
            FROM production_material_analysis_items item
            JOIN units unit ON unit.id = item.unit_id
            WHERE item.is_deleted = FALSE
              AND NOT EXISTS (
                  SELECT 1 FROM segment_rollup rolled
                  WHERE rolled.root_type = 'ANALYSIS'
                    AND rolled.root_id = item.analysis_id)
            GROUP BY item.analysis_id, unit.name
        ) unit_totals
    ) ranked
    GROUP BY ranked.root_type, ranked.root_id
)
SELECT root.root_type, root.root_id, root.owner_employee_id, root.root_label,
       CASE
           WHEN COALESCE(demand.remaining_qty, 0) > 0
                AND (COALESCE(segment.segment_count, 0) > 0
                     OR COALESCE(action.open_count, 0) > 0)
             THEN 'PARTIALLY_SCHEDULED'
           WHEN COALESCE(segment.segment_count, 0) = 0
                AND COALESCE(plan.open_count, 0) > 0 THEN 'PLAN_PENDING'
           WHEN COALESCE(segment.segment_count, 0) = 0
                AND COALESCE(action.open_count, 0) > 0 THEN 'PREPARING'
           WHEN COALESCE(segment.segment_count, 0) = 0 THEN 'ANALYZING'
           WHEN COALESCE(segment.open_segment_count, 0) = 0
                AND COALESCE(action.open_count, 0) > 0 THEN 'PREPARING'
           WHEN COALESCE(segment.open_segment_count, 0) = 0
                AND COALESCE(plan.open_count, 0) > 0 THEN 'PLAN_PENDING'
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
       segment.work_order_preview AS work_order_preview,
       COALESCE(segment.segment_count, 0)::integer AS work_order_count,
       COALESCE(segment.segment_count, 0) > 3 AS work_order_has_more,
       workshop_preview.preview AS workshop_preview,
       COALESCE(workshop_count.total, 0)::integer AS workshop_count,
       COALESCE(workshop_count.total, 0) > 3 AS workshop_has_more,
       product.code_preview AS product_code_preview,
       product.name_preview AS product_name_preview,
       color.preview AS product_color_preview,
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
       COALESCE(segment.open_segment_count, 0)::integer AS open_segment_count,
       root.owner_employee_name,
       root.analyzed_at,
       COALESCE(progress.root_planned_qty, 0)::numeric AS root_planned_qty,
       COALESCE(progress.root_inbound_qty, 0)::numeric AS root_inbound_qty,
       CASE WHEN COALESCE(progress.root_planned_qty, 0) > 0
            THEN LEAST(COALESCE(progress.root_inbound_qty, 0)
                       / progress.root_planned_qty, 1)
            ELSE NULL END AS root_progress_ratio
FROM roots root
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(item.remaining_schedule_qty),0)
               AS remaining_qty
    FROM v_production_analysis_workbench_item_progress item
    WHERE root.root_type = 'ANALYSIS' AND item.analysis_id = root.root_id
) demand ON TRUE
LEFT JOIN LATERAL (
    SELECT (COUNT(*) FILTER (
               WHERE action.status IN ('OPEN','CREATED','IN_PROGRESS'))
            + (SELECT COUNT(*) FROM preplan_make_public_claims claim
               WHERE root.root_type = 'ANALYSIS' AND claim.target_analysis_id = root.root_id
                 AND fn_preplan_make_public_claim_pending_qty(claim.id) > 0))::integer
               AS open_count
    FROM preplan_supply_actions action
    WHERE root.root_type = 'ANALYSIS' AND action.analysis_id = root.root_id
) action ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*)::integer AS plan_count,
           COUNT(*) FILTER (
               WHERE plan.status = 0 OR (plan.status = 1
                 AND plan.is_closed = FALSE AND plan.is_stopped = FALSE
                 AND plan.is_canceled = FALSE
                 AND EXISTS (
                     SELECT 1 FROM production_plan_items plan_item
                     WHERE plan_item.plan_id = plan.id AND NOT plan_item.is_deleted
                       AND plan_item.qty > COALESCE(plan_item.iqty, 0))))::integer AS open_count,
           MIN(plan.bill_date) AS earliest_begin_date,
           MAX(plan.delivery_date) AS latest_end_date
    FROM production_plans plan
    WHERE (root.root_type = 'ANALYSIS'
           AND plan.material_analysis_id = root.root_id
           AND plan.is_deleted = FALSE)
       OR (root.root_type = 'PLAN' AND plan.id = root.root_id
           AND plan.is_deleted = FALSE)
) plan ON TRUE
LEFT JOIN segment_rollup segment
  ON segment.root_type = root.root_type AND segment.root_id = root.root_id
LEFT JOIN sales_order_rollup sales
  ON sales.root_type = root.root_type AND sales.root_id = root.root_id
LEFT JOIN workshop_count_rollup workshop_count
  ON workshop_count.root_type = root.root_type
 AND workshop_count.root_id = root.root_id
LEFT JOIN workshop_preview_rollup workshop_preview
  ON workshop_preview.root_type = root.root_type
 AND workshop_preview.root_id = root.root_id
LEFT JOIN product_rollup product
  ON product.root_type = root.root_type AND product.root_id = root.root_id
LEFT JOIN color_rollup color
  ON color.root_type = root.root_type AND color.root_id = root.root_id
LEFT JOIN quantity_rollup quantity
  ON quantity.root_type = root.root_type AND quantity.root_id = root.root_id
LEFT JOIN root_progress_rollup progress
  ON progress.root_type = root.root_type AND progress.root_id = root.root_id
WHERE (root.root_type='ANALYSIS' AND
       (COALESCE(demand.remaining_qty,0)>0 OR COALESCE(action.open_count,0)>0
        OR COALESCE(plan.open_count,0)>0 OR COALESCE(segment.open_segment_count,0)>0))
   OR (root.root_type='PLAN' AND
       (COALESCE(plan.open_count,0)>0 OR COALESCE(segment.open_segment_count,0)>0));

COMMENT ON VIEW v_production_execution_workbench_roots IS
    'One bounded row per outer analysis; legacy plans use the outermost plan UUID. V485: single-pass rollups (V470 scanned the segment view once per root per fact). V487: +maker/analyzed_at and top-level root-only completion progress; zero-material flag on the segment view. V719: analysis root_label prefers the WL analysis_no, falling back to the id-8 hex label only when absent.';
