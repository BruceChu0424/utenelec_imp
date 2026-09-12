-- IQC terminal cancellation closes a planning action, not the supplier's proven
-- original-order replacement obligation. Keep every old action immutable.
-- Only actual V518 replacement funding/quality/stock parts can continue an origin.
CREATE FUNCTION fn_iqc_cancelled_supply_can_continue(p_action UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT action.status='CANCELLED'
        AND action.operation_type='SUPPLY'
        AND action.cancellation_reason IN (
            '到货质检存在不合格且原采购需求已无在途，需重新通知补采',
            '到货质检存在不合格且原委外需求已无在途，需重新通知补委外',
            '需求或公共安全补库存在终态不合格且已无未来供给，需按失败切片重新通知')
        AND NOT EXISTS (SELECT 1 FROM production_material_analysis_commands command
            WHERE command.analysis_id=action.analysis_id AND command.operation='CANCEL_ACTION'
              AND command.result_payload->'actionIds' ? action.id::text)
        AND (action.route='BUY' AND action.external_document_type='PURCHASE_REQUEST'
            AND EXISTS (SELECT 1 FROM purchase_requests request WHERE request.id=action.external_document_id
                AND request.status IN (0,1) AND NOT request.is_deleted AND NOT request.is_stopped)
          OR action.route='SUBCONTRACT' AND action.external_document_type='SUBCONTRACT_APPLICATION'
            AND EXISTS (SELECT 1 FROM subcontract_applications application WHERE application.id=action.external_document_id
                AND application.status IN (0,1) AND NOT application.is_deleted))
        FROM preplan_supply_actions action WHERE action.id=p_action),FALSE);
$$;

-- The immutable V518 path identifies which PASS quantity actually replaces an
-- already returned failure on this same order/source, including credited rebuy.
CREATE FUNCTION fn_iqc_replacement_origin_parts(p_pass_event UUID,p_allocation UUID)
RETURNS TABLE(quality_part_id UUID,base_qty NUMERIC) LANGUAGE sql STABLE AS $$
    SELECT quality.id,quality.base_qty
    FROM procurement_iqc_quality_consideration_parts quality
    JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id AND event.action='PASS'
    JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id AND inspection.status<>'REVERSED'
    JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
      AND part.receipt_type=inspection.receipt_type AND part.receipt_id=inspection.receipt_id
      AND part.receipt_item_id=inspection.receipt_item_id
      AND part.billing_mode IN ('NO_CHARGE','CREDIT_REPURCHASE')
    JOIN procurement_iqc_replacement_allocations replacement ON replacement.id=part.replacement_allocation_id
      AND replacement.status='ACTIVE' AND replacement.replacement_receipt_type=part.receipt_type
      AND replacement.replacement_receipt_id=part.receipt_id AND replacement.replacement_receipt_item_id=part.receipt_item_id
    JOIN procurement_iqc_rejection_cases rejection ON rejection.id=replacement.case_id
      AND rejection.receipt_type=inspection.receipt_type AND NOT rejection.is_deleted
      AND rejection.return_recorded_at IS NOT NULL
      AND rejection.status IN ('RETURN_RECORDED','CREDIT_CONFIRMED','CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
    JOIN preplan_supply_action_allocations allocation ON allocation.id=p_allocation
    WHERE quality.inspection_event_id=p_pass_event
      AND fn_iqc_cancelled_supply_can_continue(allocation.action_id)
      AND fn_procurement_consideration_active('QUALITY',quality.id)
      AND (inspection.receipt_type='PURCHASE' AND EXISTS (
          SELECT 1 FROM purchase_receipt_items item
          JOIN purchase_receipts receipt ON receipt.id=item.receipt_id AND receipt.status=1 AND NOT receipt.is_deleted
          JOIN purchase_order_item_sources source ON source.order_item_id=item.order_item_id
          WHERE item.id=inspection.receipt_item_id AND NOT item.is_deleted
            AND item.order_item_id=rejection.order_item_id AND source.request_item_id=allocation.external_item_id)
        OR inspection.receipt_type='SUBCONTRACT' AND EXISTS (
          SELECT 1 FROM subcontract_receipt_items item
          JOIN subcontract_receipts receipt ON receipt.id=item.receipt_id AND receipt.status=1 AND NOT receipt.is_deleted
          JOIN subcontract_order_item_sources source ON source.order_item_id=item.order_item_id
          WHERE item.id=inspection.receipt_item_id AND NOT item.is_deleted
            AND item.order_item_id=rejection.order_item_id AND source.application_item_id=allocation.external_item_id));
$$;

CREATE FUNCTION fn_iqc_replacement_quality_origin_qty(p_pass_event UUID,p_allocation UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(part.base_qty),0) FROM fn_iqc_replacement_origin_parts(p_pass_event,p_allocation) part;
$$;

CREATE FUNCTION fn_iqc_replacement_node_capacity(p_allocation UUID,p_exclude_exact UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE a preplan_supply_action_allocations%ROWTYPE;
    m production_material_analysis_materials%ROWTYPE;
    original_used NUMERIC;
    owned NUMERIC; legacy_owned NUMERIC; formal_owned NUMERIC; formal_need NUMERIC; future_qty NUMERIC; priority_due NUMERIC;
BEGIN
    SELECT * INTO a FROM preplan_supply_action_allocations WHERE id=p_allocation;
    SELECT * INTO m FROM production_material_analysis_materials WHERE id=a.analysis_material_id;
    IF a.id IS NULL OR m.id IS NULL OR NOT m.active OR m.analysis_id<>a.analysis_id
       OR NOT fn_iqc_cancelled_supply_can_continue(a.action_id)
       OR NOT EXISTS (SELECT 1 FROM preplan_supply_actions action
           JOIN production_material_analyses analysis ON analysis.id=action.analysis_id
           WHERE action.id=a.action_id AND action.route=m.confirmed_route
             AND NOT analysis.is_deleted AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED','COMPLETED')) THEN RETURN 0; END IF;
    SELECT COALESCE(SUM(CASE WHEN reservation.release_reason='TRANSFERRED_TO_PLAN' THEN exact.qty
        ELSE GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty,0) END),0)
    INTO original_used
    FROM preplan_analysis_stock_exact_pegs exact JOIN stock_reservations reservation ON reservation.id=exact.stock_reservation_id
    WHERE exact.supply_action_allocation_id=a.id AND NOT reservation.is_deleted
      AND (reservation.status=0 OR reservation.release_reason='TRANSFERRED_TO_PLAN')
      AND (p_exclude_exact IS NULL OR exact.id<>p_exclude_exact);
    SELECT COALESCE(SUM(balance.effective_qty),0) INTO owned
    FROM v_preplan_stock_entitlement_beneficiary_balance balance
    WHERE balance.beneficiary_analysis_material_id=m.id;
    -- Old analysis-level pools have no provable node identity. Keep their
    -- coverage reserved conservatively instead of inventing a new allocation.
    SELECT COALESCE(SUM(GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty,0)),0)
      INTO legacy_owned FROM stock_reservations reservation
    WHERE reservation.owner_type='PREPLAN_ANALYSIS' AND reservation.owner_id=m.analysis_id
      AND reservation.status=0 AND NOT reservation.is_deleted
      AND reservation.goods_id=m.goods_id AND reservation.color_id IS NOT DISTINCT FROM m.color_id
      AND NOT EXISTS (SELECT 1 FROM preplan_analysis_stock_exact_pegs exact WHERE exact.stock_reservation_id=reservation.id)
      AND NOT EXISTS (SELECT 1 FROM preplan_stock_entitlement_events event WHERE event.stock_reservation_id=reservation.id);
    -- V495 matches only this plan anchor's direct material; V79 keeps a direct
    -- BOM component unique. Different parent paths retain different anchors.
    SELECT COALESCE(SUM(demand.required_qty-demand.released_qty),0),
           COALESCE(SUM((SELECT COALESCE(SUM(GREATEST(reservation.qty-reservation.released_qty,0)),0)
             FROM stock_reservations reservation WHERE reservation.owner_type='PRODUCTION_MATERIAL_DEMAND'
               AND reservation.owner_id=demand.id AND NOT reservation.is_deleted)),0)
      INTO formal_need,formal_owned
    FROM production_material_demands demand JOIN production_plans plan ON plan.id=demand.plan_id
    WHERE plan.material_analysis_id=m.analysis_id AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_canceled
      AND fn_analysis_plan_material_matches(plan.material_analysis_item_id,m.id)
      AND demand.goods_id=m.goods_id AND demand.color_id IS NOT DISTINCT FROM m.color_id AND demand.unit_id=m.unit_id
      AND NOT demand.is_deleted AND demand.status NOT IN ('RELEASED','REVERSED');
    SELECT COALESCE(SUM(LEAST(GREATEST(other.allocated_qty-fn_preplan_allocation_effective_exact_qty(other.id),0),
        CASE WHEN action.operation_type='SHARED_FUTURE_CLAIM'
               THEN GREATEST(other.allocated_qty-fn_preplan_allocation_effective_exact_qty(other.id),0)
             WHEN action.route='BUY' THEN CASE WHEN progress.demand_source_valid THEN progress.demand_future_qty ELSE 0 END
             WHEN action.route='SUBCONTRACT' AND EXISTS (SELECT 1 FROM subcontract_applications application
                  WHERE application.id=action.external_document_id AND NOT application.is_deleted AND application.status IN (0,1))
               THEN GREATEST(action.requested_qty-fn_preplan_action_effective_exact_qty(action.id),0)
             ELSE 0 END)),0) INTO future_qty
    FROM preplan_supply_action_allocations other JOIN preplan_supply_actions action ON action.id=other.action_id
    LEFT JOIN v_preplan_buy_action_slice_progress progress ON progress.action_id=action.id
    WHERE other.analysis_material_id=m.id AND action.status<>'CANCELLED'
      AND action.id<>a.action_id;
    -- The preparation ledger owns unnotified subcontract work, including
    -- already produced targets still waiting for external processing. Once
    -- notified, the resulting application allocation above owns that quantity.
    SELECT future_qty+COALESCE(SUM(GREATEST(task.required_qty-task.notified_qty,0)),0)
      INTO future_qty FROM preplan_subcontract_make_tasks task
    WHERE task.analysis_material_id=m.id AND task.analysis_id=m.analysis_id AND task.status='ACTIVE';
    -- Reuse the exact pending balance consumed by applyPriorityForOriginEvent.
    -- A recipient may already have enough material after an explicit reallocation;
    -- its own proven new origin must still be able to supplement the source first.
    -- The source side already has a natural shortage and receives no extra budget.
    SELECT COALESCE(SUM(GREATEST(qty-priority_fulfilled_qty,0)),0) INTO priority_due
    FROM preplan_material_reallocations
    WHERE to_analysis_id=m.analysis_id AND to_analysis_material_id=m.id AND status IN ('OPEN','PARTIAL');
    RETURN GREATEST(LEAST(a.allocated_qty-original_used,
        GREATEST(m.required_qty,formal_need)+priority_due-owned-legacy_owned-formal_owned-future_qty),0);
END;
$$;

CREATE FUNCTION fn_iqc_replacement_origin_capacity(
    p_stock_item UUID,p_allocation UUID,p_exclude_exact UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE s procurement_iqc_stock_in_batch_items%ROWTYPE; proven NUMERIC; stock_used NUMERIC;
BEGIN
    SELECT * INTO s FROM procurement_iqc_stock_in_batch_items WHERE id=p_stock_item;
    IF s.id IS NULL OR fn_iqc_replacement_quality_origin_qty(s.pass_event_id,p_allocation)<=0
       OR NOT EXISTS (SELECT 1 FROM preplan_supply_action_allocations allocation
           JOIN production_material_analysis_materials material ON material.id=allocation.analysis_material_id
           WHERE allocation.id=p_allocation AND material.goods_id=s.goods_id
             AND material.color_id IS NOT DISTINCT FROM s.color_id) THEN RETURN 0; END IF;
    SELECT COALESCE(SUM(stock.base_qty),0) INTO proven
    FROM procurement_iqc_stock_consideration_parts stock
    JOIN fn_iqc_replacement_origin_parts(s.pass_event_id,p_allocation) proof ON proof.quality_part_id=stock.quality_part_id
    WHERE stock.stock_in_item_id=s.id
      AND fn_procurement_consideration_active('STOCK',stock.id);
    SELECT COALESCE(SUM(exact.qty),0) INTO stock_used
    FROM preplan_stock_entitlement_events origin
    JOIN preplan_analysis_stock_exact_pegs exact ON exact.id=origin.source_exact_peg_id
    JOIN preplan_supply_action_allocations used ON used.id=exact.supply_action_allocation_id
    WHERE origin.event_group_id=s.id AND origin.event_type='ORIGIN_IQC'
      AND fn_iqc_cancelled_supply_can_continue(used.action_id)
      AND (p_exclude_exact IS NULL OR exact.id<>p_exclude_exact);
    RETURN GREATEST(LEAST(proven-stock_used,fn_iqc_replacement_node_capacity(p_allocation,p_exclude_exact)),0);
END;
$$;

CREATE FUNCTION fn_iqc_replacement_preview_capacity(p_pass_event UUID,p_allocation UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT GREATEST(LEAST(fn_iqc_replacement_node_capacity(p_allocation,NULL),
        fn_iqc_replacement_quality_origin_qty(p_pass_event,p_allocation)-COALESCE((
            SELECT SUM(stock.base_qty) FROM procurement_iqc_stock_consideration_parts stock
            JOIN fn_iqc_replacement_origin_parts(p_pass_event,p_allocation) proof ON proof.quality_part_id=stock.quality_part_id
            WHERE fn_procurement_consideration_active('STOCK',stock.id)),0)),0);
$$;

-- Run before the new ORIGIN is visible in beneficiary balances. The exact peg
-- already exists; exclude only that current peg from its original source cap.
CREATE FUNCTION fn_guard_iqc_replacement_origin_continuation()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE allocation_id UUID; allowed NUMERIC;
BEGIN
    IF NEW.event_type<>'ORIGIN_IQC' OR NEW.source_exact_peg_id IS NULL THEN RETURN NEW; END IF;
    SELECT exact.supply_action_allocation_id INTO allocation_id
    FROM preplan_analysis_stock_exact_pegs exact JOIN preplan_supply_action_allocations allocation ON allocation.id=exact.supply_action_allocation_id
    JOIN preplan_supply_actions action ON action.id=allocation.action_id
    WHERE exact.id=NEW.source_exact_peg_id AND action.status='CANCELLED';
    IF allocation_id IS NULL THEN RETURN NEW; END IF;
    PERFORM 1 FROM production_material_analysis_materials WHERE id=NEW.beneficiary_analysis_material_id FOR UPDATE;
    allowed:=fn_iqc_replacement_origin_capacity(NEW.event_group_id,allocation_id,NEW.source_exact_peg_id);
    IF NEW.qty>allowed OR allowed<=0 THEN
        RAISE EXCEPTION 'IQC replacement origin lacks original returned-source proof or exceeds current demand capacity'
            USING ERRCODE='23514',CONSTRAINT='iqc_original_replacement_origin_capacity_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_iqc_replacement_origin_continuation
    BEFORE INSERT ON preplan_stock_entitlement_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_iqc_replacement_origin_continuation();
ALTER TABLE preplan_stock_entitlement_events ENABLE ALWAYS TRIGGER trg_guard_iqc_replacement_origin_continuation;
