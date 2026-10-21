WITH subcontract_budget_allocations AS MATERIALIZED (
SELECT source.*,
    SUM(source.allocated_qty) OVER(PARTITION BY source.action_id ORDER BY source.id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS planned_through_qty,
    COALESCE(SUM(source.allocated_qty) OVER(PARTITION BY source.action_id ORDER BY source.id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS planned_before_qty
FROM preplan_supply_action_allocations source WHERE source.analysis_id=:analysisId
), action_future AS (
    SELECT action.id AS action_id,
           progress.demand_future_qty AS future_qty
    FROM preplan_supply_actions action
    JOIN v_preplan_buy_action_slice_progress progress
      ON progress.action_id = action.id
    WHERE action.analysis_id = :analysisId
      AND action.status = 'CANCELLED'
      AND action.route = 'BUY'
      AND action.cancellation_reason IN (
        '到货质检存在不合格且原采购需求已无在途，需重新通知补采',
        '需求或公共安全补库存在终态不合格且已无未来供给，需按失败切片重新通知')
      AND progress.demand_future_qty > 0
), retained_private AS MATERIALIZED (
    SELECT * FROM fn_preplan_aggregate_retained_private_sources(:analysisId)
), retained_admitted AS MATERIALIZED (
    SELECT allocation_id,SUM(admitted_qty) AS qty,BOOL_AND(source_valid) AS source_valid
    FROM retained_private GROUP BY allocation_id
), allocation_pending_raw AS (
    SELECT allocation.id AS allocation_id,allocation.analysis_material_id,
           pending_qty.qty,
           CASE WHEN action.external_document_type = 'PREPLAN_MAKE_TASK'
                THEN pending_qty.qty
                WHEN action.external_document_type = 'SUBCONTRACT_APPLICATION'
                 AND action.operation_type = 'SUPPLY'
                THEN (
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
        FROM subcontract_application_items application_item
        LEFT JOIN LATERAL (
            SELECT src.alloc_qty * COALESCE(order_item.unit_rate,1) AS ordered_base,
                   fn_procurement_order_source_remaining_qty(
                       'SUBCONTRACT', order_item.id, src.application_item_id) AS open_qty
            FROM subcontract_order_item_sources src
            JOIN subcontract_order_items order_item
              ON order_item.id = src.order_item_id
             AND order_item.is_deleted = FALSE
            JOIN subcontract_orders subcontract_order
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
 FROM (SELECT (pending_qty.qty)::numeric AS qty) quantity)
                )
                ELSE 0::numeric END AS internal_qty
    FROM subcontract_budget_allocations allocation
    JOIN preplan_supply_actions action ON action.id = allocation.action_id
    LEFT JOIN retained_admitted retained_budget ON retained_budget.allocation_id=allocation.id
    CROSS JOIN LATERAL (
       SELECT CASE WHEN fn_preplan_action_has_future_transfer(action.id) OR fn_preplan_action_has_shared_claim_history(action.id) THEN fn_preplan_future_allocation_pending_qty(allocation.id)
           WHEN action.operation_type='SHARED_FUTURE_CLAIM' THEN fn_preplan_shared_allocation_pending_qty(allocation.id)
           ELSE GREATEST((CASE WHEN retained_budget.qty IS NULL OR NOT retained_budget.source_valid
             THEN fn_preplan_allocation_base_admitted_qty(allocation.id)
             ELSE GREATEST(retained_budget.qty,fn_preplan_allocation_received_qty(allocation.id)) END)
             - fn_preplan_allocation_effective_exact_qty(allocation.id)
             - COALESCE((SELECT SUM(CASE WHEN output.event_kind='FULFILL'
                      THEN output.qty_base ELSE -output.qty_base END)
                 FROM preplan_root_output_events output
                 JOIN preplan_analysis_stock_exact_pegs exact
                   ON exact.stock_reservation_id=output.source_reservation_id
                 WHERE exact.supply_action_allocation_id=allocation.id),0),0) END::numeric AS qty
    ) pending_qty
    WHERE action.analysis_id = :analysisId
      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
), allocation_pending AS (
    SELECT raw.analysis_material_id,
        GREATEST(raw.qty-COALESCE(retained.qty,0),0) AS qty,
        GREATEST(raw.internal_qty-COALESCE(retained.internal_qty,0),0) AS internal_qty
    FROM allocation_pending_raw raw
    LEFT JOIN LATERAL (
        SELECT SUM(retained_private.pending_qty) AS qty,
            CASE WHEN raw.qty>0 THEN SUM(retained_private.pending_qty)*raw.internal_qty/raw.qty ELSE 0 END AS internal_qty
        FROM retained_private WHERE retained_private.allocation_id=raw.allocation_id
    ) retained ON TRUE
    UNION ALL
    SELECT retained.original_material_id,retained.pending_qty,
        CASE WHEN raw.qty>0 THEN retained.pending_qty*raw.internal_qty/raw.qty ELSE 0 END
    FROM retained_private retained JOIN allocation_pending_raw raw ON raw.allocation_id=retained.allocation_id
), coverage AS (
    SELECT pending.analysis_material_id, split.supply_kind, split.qty
    FROM allocation_pending pending
    CROSS JOIN LATERAL (VALUES
        ('INTERNAL', pending.internal_qty),
        ('EXTERNAL', pending.qty - pending.internal_qty)
    ) split(supply_kind, qty)
    UNION ALL
    SELECT claim.target_material_id,'EXTERNAL',fn_preplan_make_public_claim_pending_qty(claim.id)::numeric
    FROM preplan_make_public_claims claim WHERE claim.target_analysis_id=:analysisId
    UNION ALL
    SELECT allocation.analysis_material_id, 'EXTERNAL',
(SELECT COALESCE(
    ROUND(budget.qty*allocation.planned_through_qty/NULLIF(action.requested_qty,0),4)
    - ROUND(budget.qty*allocation.planned_before_qty/NULLIF(action.requested_qty,0),4),0)
 FROM (SELECT ROUND(GREATEST((LEAST(future.future_qty,action.requested_qty)),0),4) AS qty) budget)
           ::numeric
    FROM action_future future
    JOIN preplan_supply_actions action ON action.id = future.action_id
    JOIN subcontract_budget_allocations allocation
      ON allocation.action_id = action.id
)
SELECT analysis_material_id, SUM(qty)::numeric,
       COALESCE(SUM(qty) FILTER (WHERE supply_kind = 'EXTERNAL'), 0)::numeric
FROM coverage
GROUP BY analysis_material_id
