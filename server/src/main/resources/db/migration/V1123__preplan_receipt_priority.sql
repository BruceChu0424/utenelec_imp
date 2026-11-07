-- An explicitly ordered alternative may serve the same material demand if it
-- arrives first. The normal allocation preserves its actual external source.
CREATE TABLE preplan_receipt_priority_allocations (
    id UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    allocation_id UUID PRIMARY KEY REFERENCES preplan_supply_action_allocations(id),
    priority_qty NUMERIC(18,4) NOT NULL CHECK (priority_qty>0)
);

CREATE FUNCTION fn_guard_preplan_receipt_priority_allocation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'receipt priority allocation intent is immutable'
            USING ERRCODE='23514', CONSTRAINT='preplan_receipt_priority_allocation_guard';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM preplan_supply_action_allocations allocation
        JOIN preplan_supply_actions action ON action.id=allocation.action_id
        WHERE allocation.id=NEW.allocation_id AND allocation.external_item_id IS NOT NULL
          AND action.operation_type='SUPPLY' AND action.route IN ('BUY','SUBCONTRACT')
          AND NEW.priority_qty<=allocation.allocated_qty
    ) THEN
        RAISE EXCEPTION 'receipt priority exceeds the original external supply allocation'
            USING ERRCODE='23514', CONSTRAINT='preplan_receipt_priority_allocation_guard';
    END IF;
    RETURN NEW;
END;
$$;



CREATE TRIGGER trg_preplan_receipt_priority_allocation
    BEFORE INSERT OR UPDATE OR DELETE ON preplan_receipt_priority_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_receipt_priority_allocation();

CREATE TRIGGER trg_audit_preplan_receipt_priority_allocations
    AFTER INSERT OR UPDATE OR DELETE ON preplan_receipt_priority_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE preplan_receipt_priority_allocations
    ENABLE ALWAYS TRIGGER trg_audit_preplan_receipt_priority_allocations;

CREATE FUNCTION fn_preplan_receipt_priority_enabled(p_material UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(
        SELECT 1 FROM preplan_supply_action_allocations allocation
        JOIN preplan_receipt_priority_allocations priority ON priority.allocation_id=allocation.id
        WHERE allocation.analysis_material_id=p_material)
$$;

-- Actual coverage excludes every purchase/outsourcing promise. A formal
-- reservation covers the demand even after issue, and a preplan entitlement
-- ceases to count here once it has been formalized into that reservation.
CREATE FUNCTION fn_preplan_receipt_priority_physical_headroom(p_material UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH material AS MATERIALIZED (
        SELECT * FROM production_material_analysis_materials WHERE id=p_material AND active
    ), formal AS (
        SELECT COALESCE(SUM(GREATEST(demand.required_qty-demand.released_qty,0)),0) AS need,
               COALESCE(SUM(COALESCE(held.qty,0)),0) AS owned
        FROM material
        JOIN production_plans plan ON plan.material_analysis_id=material.analysis_id
          AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_canceled
          AND NOT fn_imported_business_document('production_plans',plan.id)
          AND fn_analysis_plan_material_matches(plan.material_analysis_item_id,material.id)
        JOIN production_material_demands demand ON demand.plan_id=plan.id
          AND NOT demand.is_deleted AND demand.status NOT IN ('RELEASED','REVERSED')
          AND (demand.goods_id,demand.color_id,demand.unit_id)
              IS NOT DISTINCT FROM (material.goods_id,material.color_id,material.unit_id)
        LEFT JOIN LATERAL (
            SELECT SUM(GREATEST(reservation.qty-reservation.released_qty,0)) AS qty
            FROM stock_reservations reservation
            WHERE reservation.owner_type='PRODUCTION_MATERIAL_DEMAND'
              AND reservation.demand_id=demand.id AND NOT reservation.is_deleted
        ) held ON TRUE
    )
    SELECT COALESCE((
        SELECT GREATEST(GREATEST(material.required_qty,formal.need)+COALESCE((
            SELECT SUM(GREATEST(reallocation.qty-reallocation.priority_fulfilled_qty,0))
            FROM preplan_material_reallocations reallocation
            WHERE reallocation.to_analysis_id=material.analysis_id
              AND reallocation.to_analysis_material_id=material.id
              AND reallocation.status IN ('OPEN','PARTIAL')
        ),0)-formal.owned-COALESCE((
            SELECT SUM(balance.effective_qty)
            FROM v_preplan_stock_entitlement_beneficiary_balance balance
            WHERE balance.beneficiary_analysis_material_id=material.id
        ),0)-COALESCE((
            SELECT SUM(CASE WHEN output.event_kind='FULFILL' THEN output.qty_base ELSE -output.qty_base END)
            FROM preplan_root_output_events output WHERE output.root_material_id=material.id
        ),0)-COALESCE((
            SELECT SUM(GREATEST(outbound.qty-outbound.released_qty,0))
            FROM subcontract_component_stock_handoffs handoff
            JOIN stock_reservations outbound ON outbound.id=handoff.target_reservation_id
              AND NOT outbound.is_deleted
            WHERE handoff.child_material_id=material.id
        ),0)-COALESCE((
            SELECT SUM(GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty,0))
            FROM preplan_physical_stock_claim_allocations claim
            JOIN stock_reservations reservation ON reservation.id=claim.stock_reservation_id
              AND reservation.status=0 AND NOT reservation.is_deleted
            WHERE claim.material_id=material.id
        ),0)-COALESCE((
            -- Historical analysis-level holds have no exact node proof. Keep
            -- them conservatively covered, as for original IQC replacement.
            SELECT SUM(GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty,0))
            FROM stock_reservations reservation
            WHERE reservation.owner_type='PREPLAN_ANALYSIS' AND reservation.owner_id=material.analysis_id
              AND reservation.status=0 AND NOT reservation.is_deleted
              AND reservation.goods_id=material.goods_id
              AND reservation.color_id IS NOT DISTINCT FROM material.color_id
              AND NOT EXISTS (SELECT 1 FROM preplan_analysis_stock_exact_pegs exact
                              WHERE exact.stock_reservation_id=reservation.id)
              AND NOT EXISTS (SELECT 1 FROM preplan_stock_entitlement_events event
                              WHERE event.stock_reservation_id=reservation.id)
              AND NOT EXISTS (SELECT 1 FROM preplan_physical_stock_claim_allocations claim
                              WHERE claim.stock_reservation_id=reservation.id)
        ),0),0)
        FROM material CROSS JOIN formal
    ),0)
$$;

-- A separate, explicit claim or transfer already has its own arrival right.
-- Alternative order allocations compete only for the other part of this gap.
CREATE FUNCTION fn_preplan_receipt_priority_supply_headroom(p_material UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT GREATEST(fn_preplan_receipt_priority_physical_headroom(p_material)-COALESCE((
        SELECT SUM(CASE action.operation_type
            WHEN 'SHARED_FUTURE_CLAIM' THEN fn_preplan_shared_allocation_pending_qty(allocation.id)
            WHEN 'FUTURE_TRANSFER' THEN fn_preplan_future_allocation_pending_qty(allocation.id)
        END)
        FROM preplan_supply_action_allocations allocation
        JOIN preplan_supply_actions action ON action.id=allocation.action_id
        WHERE allocation.analysis_material_id=p_material
          AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
          AND action.operation_type IN ('SHARED_FUTURE_CLAIM','FUTURE_TRANSFER')
    ),0),0)
$$;

CREATE FUNCTION fn_preplan_receipt_priority_order_headroom(p_material UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN fn_preplan_receipt_priority_enabled(p_material)
        THEN fn_preplan_receipt_priority_supply_headroom(p_material) END
$$;

-- Limit the sum of alternative and original open commitments for this exact
-- material. Earlier promises cover the shortfall first in the planning view;
-- the warehouse applies the independent physical cap in receipt order.
CREATE FUNCTION fn_preplan_receipt_priority_planning_qty(p_allocation UUID,p_raw_pending NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE current_allocation preplan_supply_action_allocations%ROWTYPE;
        current_action preplan_supply_actions%ROWTYPE;
        earlier_pending NUMERIC;
        own_pending NUMERIC;
BEGIN
    IF COALESCE(p_raw_pending,0)<=0 THEN RETURN p_raw_pending; END IF;
    SELECT * INTO current_allocation FROM preplan_supply_action_allocations WHERE id=p_allocation;
    IF NOT fn_preplan_receipt_priority_enabled(current_allocation.analysis_material_id)
        THEN RETURN p_raw_pending; END IF;
    SELECT * INTO current_action FROM preplan_supply_actions WHERE id=current_allocation.action_id;
    IF current_action.route NOT IN ('BUY','SUBCONTRACT') OR current_action.operation_type<>'SUPPLY'
        THEN RETURN p_raw_pending; END IF;

    SELECT COALESCE(SUM(LEAST(
        GREATEST(fn_preplan_allocation_admitted_qty(earlier.id)-fn_preplan_allocation_received_qty(earlier.id),0),
        fn_preplan_external_planning_expected_qty(action.id,earlier.external_item_id)
    )),0) INTO earlier_pending
    FROM preplan_supply_action_allocations earlier
    JOIN preplan_supply_actions action ON action.id=earlier.action_id
    WHERE earlier.analysis_material_id=current_allocation.analysis_material_id
      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
      AND action.route IN ('BUY','SUBCONTRACT')
      AND action.operation_type='SUPPLY'
      AND (action.created_at,action.id,earlier.id) <
          (current_action.created_at,current_action.id,current_allocation.id);

    own_pending:=LEAST(p_raw_pending,fn_preplan_external_planning_expected_qty(current_action.id,current_allocation.external_item_id));
    RETURN LEAST(own_pending,GREATEST(fn_preplan_receipt_priority_supply_headroom(
        current_allocation.analysis_material_id)-earlier_pending,0));
END;
$$;

-- Alias and workbench readers resolve the same exact pending allocation
-- without advertising a second commitment for the alternative shipment.
DO $priority_pending_projections$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_preplan_aggregate_allocation_pending_qty(uuid)'::regprocedure) INTO definition;
    needle:='RETURN LEAST(own_capacity,GREATEST(COALESCE(total_pending,0)-preceding_capacity,0));';
    IF strpos(definition,needle)=0 OR strpos(definition,'RETURN fn_preplan_future_allocation_pending_qty(allocation.id);')=0 THEN
        RAISE EXCEPTION 'V1123 aggregate pending quantity contract changed';
    END IF;
    definition:=replace(definition,needle,'RETURN fn_preplan_receipt_priority_planning_qty(p_allocation,LEAST(own_capacity,GREATEST(COALESCE(total_pending,0)-preceding_capacity,0)));');
    EXECUTE replace(definition,'RETURN fn_preplan_future_allocation_pending_qty(allocation.id);',
        'RETURN fn_preplan_receipt_priority_planning_qty(p_allocation,fn_preplan_future_allocation_pending_qty(allocation.id));');

    SELECT pg_get_functiondef('fn_production_workbench_component_credits(uuid)'::regprocedure) INTO definition;
    needle:='SELECT allocation.analysis_material_id AS material_id,GREATEST(CASE';
    IF strpos(definition,needle)=0 OR strpos(definition,'END,0) AS qty')=0 THEN
        RAISE EXCEPTION 'V1123 workbench pending quantity contract changed';
    END IF;
    definition:=replace(definition,needle,'SELECT allocation.analysis_material_id AS material_id,fn_preplan_receipt_priority_planning_qty(allocation.id,GREATEST(CASE');
    EXECUTE replace(definition,'END,0) AS qty','END,0)) AS qty');
END;
$priority_pending_projections$;
