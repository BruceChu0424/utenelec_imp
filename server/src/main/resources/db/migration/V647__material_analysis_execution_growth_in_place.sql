-- V647 ADR-104 correction: an untouched workshop task keeps its original ZX identity.
-- Every exception to frozen quantities requires a same-transaction, append-only
-- growth event. Existing consumption rules, reservations and DRAW facts stay put.
-- No historical business row is changed by installing this migration.

CREATE TABLE production_execution_segment_growth_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    plan_id UUID NOT NULL REFERENCES production_plans(id),
    plan_item_id UUID NOT NULL REFERENCES production_plan_items(id),
    before_qty NUMERIC(18,4) NOT NULL CHECK (before_qty > 0),
    added_qty NUMERIC(18,4) NOT NULL CHECK (added_qty > 0),
    after_qty NUMERIC(18,4) NOT NULL CHECK (after_qty = before_qty + added_qty),
    sales_before_qty NUMERIC(18,4) NOT NULL CHECK (sales_before_qty >= 0),
    sales_added_qty NUMERIC(18,4) NOT NULL CHECK (sales_added_qty BETWEEN 0 AND added_qty),
    demand_changes JSONB NOT NULL CHECK (jsonb_typeof(demand_changes) = 'array'),
    transaction_id XID8 NOT NULL DEFAULT pg_current_xact_id(),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_execution_segment_growth_segment
    ON production_execution_segment_growth_events(execution_segment_id, after_qty);
COMMENT ON TABLE production_execution_segment_growth_events IS
    'ADR-104: audited in-place increases of an untouched workshop task, including its exact frozen demand and sales allocation deltas';

CREATE FUNCTION fn_material_analysis_execution_segment_growable(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM production_execution_segments segment
        JOIN production_planning_packages package ON package.id=segment.package_id
        WHERE segment.id=p_segment AND NOT segment.is_deleted
          AND segment.status IN ('WAITING','READY')
          AND segment.source_segment_id IS NULL
          AND segment.material_snapshot_product_qty=segment.planned_qty
          AND package.status='CONFIRMED' AND NOT package.is_deleted
          AND package.execution_model_version=1
          AND NOT EXISTS (SELECT 1 FROM production_execution_segment_events event
                          WHERE event.execution_segment_id=segment.id
                            AND event.action IN ('DRAW_REQUEST','START'))
          AND NOT EXISTS (SELECT 1 FROM production_execution_segment_splits split
                          WHERE split.source_segment_id=segment.id)
          AND NOT EXISTS (SELECT 1 FROM production_daily_report_items report
                          WHERE report.execution_segment_id=segment.id)
          AND NOT EXISTS (SELECT 1 FROM production_workshop_direct_transfer_items transfer
                          WHERE transfer.to_execution_segment_id=segment.id)
          AND NOT EXISTS (SELECT 1 FROM production_material_demands demand
                          JOIN production_material_stock_postings posting ON posting.demand_id=demand.id
                          WHERE demand.execution_segment_id=segment.id)
          AND NOT EXISTS (SELECT 1 FROM production_material_demands demand
                          JOIN production_material_settlement_postings posting ON posting.demand_id=demand.id
                          WHERE demand.execution_segment_id=segment.id)
          AND NOT EXISTS (SELECT 1 FROM production_material_demands demand
                          WHERE demand.execution_segment_id=segment.id
                            AND (demand.is_deleted OR demand.status IN ('RELEASED','REVERSED')
                              OR demand.released_qty<>0 OR demand.consumption_snapshot IS NULL
                              OR demand.required_qty<>fn_material_snapshot_required(
                                   demand.consumption_snapshot,segment.planned_qty)))
          AND ((segment.material_requirement_mode='ZERO_MATERIAL' AND NOT EXISTS (
                  SELECT 1 FROM production_material_demands demand WHERE demand.execution_segment_id=segment.id))
               OR (segment.material_requirement_mode='DEMANDED' AND EXISTS (
                  SELECT 1 FROM production_material_demands demand WHERE demand.execution_segment_id=segment.id)))
          AND NOT EXISTS (
              SELECT 1 FROM production_planning_package_documents mapping
              JOIN stock_documents draw ON draw.id=mapping.document_id
              WHERE mapping.execution_segment_id=segment.id AND mapping.document_type='DRAW'
                AND (draw.is_deleted OR draw.status<>0 OR EXISTS (
                    SELECT 1 FROM stock_document_items item WHERE item.doc_id=draw.id AND item.issued_qty>0)))
    )
$$;
COMMENT ON FUNCTION fn_material_analysis_execution_segment_growable(UUID) IS
    'Unexecuted original task with a valid frozen consumption curve; a workshop DRAW_REQUEST, physical transfer/issue, split, start or report freezes append identity';

-- Keep every V645 lifecycle predicate, adding the actual workshop boundary.
DO $patch$
DECLARE definition TEXT; anchor TEXT := 'AND plan.status IN (0, 1)';
BEGIN
    SELECT pg_get_functiondef('fn_material_analysis_plan_growable(uuid)'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V647 material analysis plan growth anchor changed';
    END IF;
    EXECUTE replace(definition,anchor,anchor || E'\n          AND NOT EXISTS (SELECT 1 FROM production_execution_segments growth_segment\n              WHERE growth_segment.plan_id=plan.id AND NOT growth_segment.is_deleted\n                AND NOT fn_material_analysis_execution_segment_growable(growth_segment.id))');
END;
$patch$;

CREATE FUNCTION fn_material_analysis_execution_growth_demands(p_segment UUID, p_after NUMERIC)
RETURNS JSONB LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', demand.id, 'before', demand.required_qty,
        'after', fn_material_snapshot_required(demand.consumption_snapshot,p_after),
        'basisBefore', demand.required_for_product_qty,
        'basisAfter', CASE WHEN demand.requirement_mode='EXACT_SNAPSHOT' THEN p_after ELSE NULL END
    ) ORDER BY demand.id),'[]'::jsonb)
    FROM production_material_demands demand
    WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
$$;

CREATE FUNCTION fn_guard_material_analysis_execution_growth_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE segment production_execution_segments%ROWTYPE; item_qty NUMERIC; allocated NUMERIC;
        sales_capacity NUMERIC; sales_committed NUMERIC;
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'Execution growth events are append-only' USING ERRCODE='55000';
    END IF;
    SELECT * INTO segment FROM production_execution_segments WHERE id=NEW.execution_segment_id;
    IF NOT FOUND OR current_setting('transaction_isolation')<>'read committed' THEN
        RAISE EXCEPTION 'Execution growth requires an existing task and READ COMMITTED' USING ERRCODE='23514';
    END IF;
    -- The audit INSERT is guarded even when called outside the application
    -- helper. A concurrent workshop request uses the same upstream lock order.
    PERFORM 1 FROM production_plans WHERE id=segment.plan_id FOR UPDATE;
    PERFORM 1 FROM production_planning_packages WHERE id=segment.package_id FOR UPDATE;
    SELECT * INTO segment FROM production_execution_segments WHERE id=NEW.execution_segment_id FOR UPDATE;
    PERFORM 1 FROM production_material_demands WHERE execution_segment_id=segment.id ORDER BY id FOR UPDATE;
    IF NOT fn_material_analysis_plan_growable(segment.plan_id)
       OR NOT fn_material_analysis_execution_segment_growable(segment.id)
       OR NEW.plan_id<>segment.plan_id OR NEW.plan_item_id<>segment.source_plan_item_id
       OR NEW.before_qty<>segment.planned_qty
       OR NEW.transaction_id<>pg_current_xact_id()
       OR NEW.created_by IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')::uuid
       OR NEW.demand_changes IS DISTINCT FROM fn_material_analysis_execution_growth_demands(segment.id,NEW.after_qty) THEN
        RAISE EXCEPTION 'Execution growth event must describe the current untouched task and actor' USING ERRCODE='23514';
    END IF;
    SELECT qty INTO item_qty FROM production_plan_items WHERE id=segment.source_plan_item_id AND NOT is_deleted;
    IF item_qty IS DISTINCT FROM NEW.added_qty + (
        SELECT COALESCE(SUM(planned_qty),0) FROM production_execution_segments
        WHERE source_plan_item_id=segment.source_plan_item_id AND NOT is_deleted
          AND status NOT IN ('CANCELLED','REVERSED')) THEN
        RAISE EXCEPTION 'Execution growth must consume exactly the increased plan item capacity' USING ERRCODE='23514';
    END IF;
    SELECT COALESCE(SUM(allocated_qty),0) INTO allocated FROM execution_segment_sales_allocations
    WHERE execution_segment_id=segment.id;
    IF NEW.sales_before_qty<>allocated OR NEW.sales_before_qty+NEW.sales_added_qty>NEW.after_qty THEN
        RAISE EXCEPTION 'Execution growth sales quantity is inconsistent' USING ERRCODE='23514';
    END IF;
    SELECT COALESCE(SUM(allocated_qty),0) INTO sales_capacity FROM plan_order_item_links
    WHERE plan_item_id=segment.source_plan_item_id AND NOT is_deleted;
    SELECT COALESCE(SUM(allocation.allocated_qty),0) INTO sales_committed
    FROM execution_segment_sales_allocations allocation
    JOIN production_execution_segments allocated_segment ON allocated_segment.id=allocation.execution_segment_id
    WHERE allocated_segment.source_plan_item_id=segment.source_plan_item_id
      AND allocated_segment.status NOT IN ('CANCELLED','REVERSED');
    IF NEW.sales_added_qty IS DISTINCT FROM sales_capacity-sales_committed THEN
        RAISE EXCEPTION 'Execution growth must consume exactly the increased sales capacity' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_execution_segment_growth_event
    BEFORE INSERT OR UPDATE OR DELETE ON production_execution_segment_growth_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_material_analysis_execution_growth_event();
ALTER TABLE production_execution_segment_growth_events ENABLE ALWAYS TRIGGER trg_guard_execution_segment_growth_event;
CREATE TRIGGER trg_audit_production_execution_segment_growth_events
    AFTER INSERT OR UPDATE OR DELETE ON production_execution_segment_growth_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_execution_segment_growth_events ENABLE ALWAYS TRIGGER trg_audit_production_execution_segment_growth_events;

CREATE FUNCTION fn_is_recorded_material_analysis_execution_growth(p_segment UUID, p_before NUMERIC, p_after NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM production_execution_segment_growth_events event
      WHERE event.execution_segment_id=p_segment AND event.before_qty=p_before AND event.after_qty=p_after
        AND event.transaction_id=pg_current_xact_id() AND event.xmin::text=pg_current_xact_id()::text)
$$;
CREATE FUNCTION fn_is_material_analysis_execution_growth(p_segment UUID, p_before NUMERIC, p_after NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT fn_material_analysis_execution_segment_growable(p_segment)
      AND EXISTS (SELECT 1 FROM production_execution_segment_growth_events event
      WHERE event.id::text=current_setting('app.execution_growth_event_id',true)
        AND event.execution_segment_id=p_segment AND event.before_qty=p_before AND event.after_qty=p_after
        AND event.transaction_id=pg_current_xact_id() AND event.xmin::text=pg_current_xact_id()::text)
$$;
CREATE FUNCTION fn_is_material_analysis_execution_demand_growth(p_old JSONB, p_new JSONB)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT (p_old-ARRAY['required_qty','required_for_product_qty','updated_at','updated_by'])
               IS NOT DISTINCT FROM
           (p_new-ARRAY['required_qty','required_for_product_qty','updated_at','updated_by'])
      AND EXISTS (SELECT 1 FROM production_execution_segment_growth_events event
          CROSS JOIN LATERAL jsonb_array_elements(event.demand_changes) change
          WHERE event.id::text=current_setting('app.execution_growth_event_id',true)
            AND event.execution_segment_id=(p_old->>'execution_segment_id')::uuid
            AND event.transaction_id=pg_current_xact_id() AND event.xmin::text=pg_current_xact_id()::text
            AND change->>'id'=p_old->>'id'
            AND (change->>'before')::numeric=(p_old->>'required_qty')::numeric
            AND (change->>'after')::numeric=(p_new->>'required_qty')::numeric
            AND (change->>'basisBefore')::numeric IS NOT DISTINCT FROM (p_old->>'required_for_product_qty')::numeric
            AND (change->>'basisAfter')::numeric IS NOT DISTINCT FROM (p_new->>'required_for_product_qty')::numeric)
$$;
CREATE FUNCTION fn_is_recorded_material_analysis_execution_sales_growth(p_old JSONB, p_new JSONB)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT (p_old-'allocated_qty') IS NOT DISTINCT FROM (p_new-'allocated_qty')
      AND EXISTS (SELECT 1 FROM production_execution_segment_growth_events event
          WHERE event.execution_segment_id=(p_old->>'execution_segment_id')::uuid
            AND event.transaction_id=pg_current_xact_id() AND event.xmin::text=pg_current_xact_id()::text
            AND event.sales_before_qty=(p_old->>'allocated_qty')::numeric
            AND event.sales_added_qty>0
            AND event.sales_before_qty+event.sales_added_qty=(p_new->>'allocated_qty')::numeric)
$$;
CREATE FUNCTION fn_is_material_analysis_execution_sales_growth(p_old JSONB, p_new JSONB)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT fn_is_recorded_material_analysis_execution_sales_growth(p_old,p_new)
      AND EXISTS (SELECT 1 FROM production_execution_segment_growth_events event
          WHERE event.id::text=current_setting('app.execution_growth_event_id',true)
            AND event.execution_segment_id=(p_old->>'execution_segment_id')::uuid
            AND event.sales_before_qty=(p_old->>'allocated_qty')::numeric
            AND event.sales_before_qty+event.sales_added_qty=(p_new->>'allocated_qty')::numeric
            AND event.transaction_id=pg_current_xact_id() AND event.xmin::text=pg_current_xact_id()::text)
$$;

-- A guard exception is exact to an audited before/after pair, never a generic GUC bypass.
DO $patch$
DECLARE definition TEXT; anchor TEXT; replacement TEXT;
BEGIN
    anchor:='OR (OLD.planned_qty IS DISTINCT FROM NEW.planned_qty AND NOT fn_is_final_report_target_change(OLD.id,OLD.planned_qty,NEW.planned_qty))';
    replacement:='OR (OLD.planned_qty IS DISTINCT FROM NEW.planned_qty AND NOT fn_is_final_report_target_change(OLD.id,OLD.planned_qty,NEW.planned_qty) AND NOT fn_is_material_analysis_execution_growth(OLD.id,OLD.planned_qty,NEW.planned_qty))';
    SELECT pg_get_functiondef('fn_validate_production_execution_segment()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V647 execution target guard changed'; END IF;
    EXECUTE replace(definition,anchor,replacement);

    anchor:='ELSIF NEW.material_snapshot_product_qty IS DISTINCT FROM OLD.material_snapshot_product_qty THEN';
    replacement:='ELSIF NEW.material_snapshot_product_qty IS DISTINCT FROM OLD.material_snapshot_product_qty AND NOT (NEW.material_snapshot_product_qty=NEW.planned_qty AND OLD.material_snapshot_product_qty=OLD.planned_qty AND fn_is_material_analysis_execution_growth(OLD.id,OLD.material_snapshot_product_qty,NEW.material_snapshot_product_qty)) THEN';
    SELECT pg_get_functiondef('fn_guard_material_snapshot_product_qty()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V647 material basis guard changed'; END IF;
    EXECUTE replace(definition,anchor,replacement);

    anchor:=E'BEGIN\n    IF (';
    replacement:=E'BEGIN\n    IF fn_is_material_analysis_execution_demand_growth(to_jsonb(OLD),to_jsonb(NEW)) THEN RETURN NEW; END IF;\n    IF (';
    SELECT replace(pg_get_functiondef('fn_guard_exact_production_demand_snapshot()'::regprocedure),E'\r\n',E'\n') INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V647 exact demand guard changed'; END IF;
    EXECUTE replace(definition,anchor,replacement);

    anchor:='IF NEW.planned_qty IS NOT DISTINCT FROM OLD.planned_qty THEN RETURN NULL; END IF;';
    replacement:=anchor || E'\n    IF fn_is_recorded_material_analysis_execution_growth(OLD.id,OLD.planned_qty,NEW.planned_qty) THEN RETURN NULL; END IF;';
    SELECT pg_get_functiondef('fn_check_final_report_target_change()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V647 deferred target guard changed'; END IF;
    EXECUTE replace(definition,anchor,replacement);

    -- Keep V508 READ COMMITTED and identity checks; grow only allocated_qty.
    anchor:='IF TG_OP=''DELETE'' OR (TG_OP=''UPDATE'' AND (';
    replacement:='IF TG_OP=''DELETE'' OR (TG_OP=''UPDATE'' AND NOT fn_is_material_analysis_execution_sales_growth(to_jsonb(OLD),to_jsonb(NEW)) AND (';
    SELECT pg_get_functiondef('fn_validate_execution_segment_sales_allocation()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V647 execution sales guard changed'; END IF;
    EXECUTE replace(definition,anchor,replacement);

    anchor:=E'BEGIN\n    IF NOT EXISTS';
    replacement:=E'BEGIN\n    IF fn_is_recorded_material_analysis_execution_sales_growth(to_jsonb(OLD),to_jsonb(NEW)) THEN RETURN NULL; END IF;\n    IF NOT EXISTS';
    SELECT replace(pg_get_functiondef('fn_check_final_report_allocation_change()'::regprocedure),E'\r\n',E'\n') INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V647 deferred execution sales guard changed'; END IF;
    EXECUTE replace(definition,anchor,replacement);

    -- An audited enlarged task may wait for the added material while retaining
    -- its original unused physical reservations and unrequested DRAW drafts.
    anchor:=E'IF v_segment.status = ''WAITING''\n       AND v_nonzero_count > 0 THEN';
    replacement:=E'IF v_segment.status = ''WAITING''\n       AND v_nonzero_count > 0\n       AND NOT EXISTS (SELECT 1 FROM production_execution_segment_growth_events growth\n           WHERE growth.execution_segment_id=v_segment.id\n             AND growth.after_qty=v_segment.material_snapshot_product_qty) THEN';
    SELECT replace(pg_get_functiondef('fn_assert_execution_segment_integrity_before_v561(uuid)'::regprocedure),E'\r\n',E'\n') INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V647 waiting reservation guard changed'; END IF;
    EXECUTE replace(definition,anchor,replacement);
END;
$patch$;

CREATE FUNCTION fn_check_material_analysis_execution_growth_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE last_event production_execution_segment_growth_events%ROWTYPE;
        segment production_execution_segments%ROWTYPE;
BEGIN
    SELECT * INTO last_event FROM production_execution_segment_growth_events
    WHERE execution_segment_id=NEW.execution_segment_id AND transaction_id=NEW.transaction_id
    ORDER BY after_qty DESC LIMIT 1;
    SELECT * INTO segment FROM production_execution_segments WHERE id=NEW.execution_segment_id;
    IF segment.planned_qty IS DISTINCT FROM last_event.after_qty
       OR segment.material_snapshot_product_qty IS DISTINCT FROM last_event.after_qty
       OR segment.is_deleted
       OR (SELECT COALESCE(SUM(allocated_qty),0) FROM execution_segment_sales_allocations
           WHERE execution_segment_id=segment.id) IS DISTINCT FROM last_event.sales_before_qty+last_event.sales_added_qty
       OR EXISTS (SELECT 1 FROM production_material_demands demand
                  WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted
                    AND (demand.required_qty IS DISTINCT FROM fn_material_snapshot_required(demand.consumption_snapshot,last_event.after_qty)
                      OR (demand.requirement_mode='EXACT_SNAPSHOT' AND demand.required_for_product_qty IS DISTINCT FROM last_event.after_qty)))
       OR (SELECT qty FROM production_plan_items WHERE id=segment.source_plan_item_id AND NOT is_deleted)
          IS DISTINCT FROM (SELECT SUM(planned_qty) FROM production_execution_segments
              WHERE source_plan_item_id=segment.source_plan_item_id AND NOT is_deleted AND status NOT IN ('CANCELLED','REVERSED')) THEN
        RAISE EXCEPTION 'Execution growth event is not reconciled with task, frozen demand, sales and plan quantities' USING ERRCODE='23514';
    END IF;
    PERFORM fn_assert_execution_segment_integrity(segment.id);
    PERFORM fn_assert_execution_segment_sales_allocation(segment.id);
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_growth_event
    AFTER INSERT ON production_execution_segment_growth_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_check_material_analysis_execution_growth_event();
ALTER TABLE production_execution_segment_growth_events ENABLE ALWAYS TRIGGER trg_check_execution_segment_growth_event;

CREATE FUNCTION fn_grow_material_analysis_execution_segment(p_segment UUID, p_added NUMERIC, p_sales_added NUMERIC)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE segment production_execution_segments%ROWTYPE; event_id UUID; previous_event TEXT;
        actor UUID; sales_link plan_order_item_links%ROWTYPE; allocated NUMERIC;
        after_qty NUMERIC; plan_uuid UUID; package_uuid UUID;
BEGIN
    actor:=NULLIF(current_setting('app.actor_id',true),'')::uuid;
    IF actor IS NULL OR p_added IS NULL OR p_added<=0 OR p_added<>round(p_added,4)
       OR p_sales_added IS NULL OR p_sales_added<0 OR p_sales_added>p_added OR p_sales_added<>round(p_sales_added,4)
       OR current_setting('transaction_isolation')<>'read committed' THEN
        RAISE EXCEPTION 'Execution growth requires an actor, positive four-decimal quantity and READ COMMITTED' USING ERRCODE='23514';
    END IF;
    SELECT plan_id,package_id INTO plan_uuid,package_uuid FROM production_execution_segments WHERE id=p_segment;
    IF NOT FOUND THEN RAISE EXCEPTION 'Execution growth task does not exist' USING ERRCODE='23514'; END IF;
    PERFORM 1 FROM production_plans WHERE id=plan_uuid FOR UPDATE;
    PERFORM 1 FROM production_planning_packages WHERE id=package_uuid FOR UPDATE;
    PERFORM 1 FROM production_execution_segments WHERE plan_id=plan_uuid ORDER BY id FOR UPDATE;
    SELECT * INTO segment FROM production_execution_segments WHERE id=p_segment;
    PERFORM 1 FROM production_material_demands WHERE execution_segment_id=p_segment ORDER BY id FOR UPDATE;
    IF NOT fn_material_analysis_plan_growable(plan_uuid)
       OR NOT fn_material_analysis_execution_segment_growable(p_segment) THEN
        RAISE EXCEPTION 'Execution task has begun or lacks a valid frozen material basis; create a new task' USING ERRCODE='23514';
    END IF;
    after_qty:=segment.planned_qty+p_added;
    SELECT COALESCE(SUM(allocated_qty),0) INTO allocated FROM execution_segment_sales_allocations WHERE execution_segment_id=p_segment;
    INSERT INTO production_execution_segment_growth_events(
        execution_segment_id,plan_id,plan_item_id,before_qty,added_qty,after_qty,
        sales_before_qty,sales_added_qty,demand_changes,created_by)
    VALUES(p_segment,segment.plan_id,segment.source_plan_item_id,segment.planned_qty,p_added,after_qty,
        allocated,p_sales_added,fn_material_analysis_execution_growth_demands(p_segment,after_qty),actor)
    RETURNING id INTO event_id;
    previous_event:=current_setting('app.execution_growth_event_id',true);
    PERFORM set_config('app.execution_growth_event_id',event_id::text,true);
    UPDATE production_execution_segments SET planned_qty=after_qty,material_snapshot_product_qty=after_qty,
        lock_version=lock_version+1,updated_at=now(),updated_by=actor WHERE id=p_segment;
    UPDATE production_material_demands SET
        required_qty=fn_material_snapshot_required(consumption_snapshot,after_qty),
        required_for_product_qty=CASE WHEN requirement_mode='EXACT_SNAPSHOT' THEN after_qty ELSE required_for_product_qty END,
        updated_at=now(),updated_by=actor
    WHERE execution_segment_id=p_segment AND NOT is_deleted;
    IF p_sales_added>0 THEN
        IF (SELECT COUNT(*) FROM plan_order_item_links WHERE plan_item_id=segment.source_plan_item_id AND NOT is_deleted)<>1 THEN
            RAISE EXCEPTION 'Analysis execution growth requires exactly one sales source' USING ERRCODE='23514';
        END IF;
        SELECT * INTO sales_link FROM plan_order_item_links
        WHERE plan_item_id=segment.source_plan_item_id AND NOT is_deleted FOR UPDATE;
        UPDATE execution_segment_sales_allocations SET allocated_qty=allocated_qty+p_sales_added
        WHERE execution_segment_id=p_segment AND plan_order_item_link_id=sales_link.id;
        IF NOT FOUND THEN
            INSERT INTO execution_segment_sales_allocations(execution_segment_id,plan_order_item_link_id,sales_order_item_id,allocated_qty,created_by)
            VALUES(p_segment,sales_link.id,sales_link.order_item_id,p_sales_added,actor);
        END IF;
    END IF;
    UPDATE production_execution_segments SET status=CASE
        WHEN material_requirement_mode='ZERO_MATERIAL' THEN 'READY'
        WHEN segment.continuous_supply AND segment.status='READY' THEN 'READY'
        WHEN NOT EXISTS(SELECT 1 FROM fn_execution_segment_material_coverage(p_segment) coverage
                        WHERE coverage.stock_backed<coverage.required_qty OR coverage.draw_backed<coverage.required_qty)
             THEN 'READY' ELSE 'WAITING' END
    WHERE id=p_segment;
    PERFORM set_config('app.execution_growth_event_id',COALESCE(previous_event,''),true);
    RETURN event_id;
END;
$$;
COMMENT ON FUNCTION fn_grow_material_analysis_execution_segment(UUID,NUMERIC,NUMERIC) IS
    'Consume already-increased analysis plan/sales capacity by growing the same untouched ZX task and its frozen demand; caller reconciles added material in the same transaction';

DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V647 missing business reset anchor'; END IF;
    EXECUTE replace(definition,anchor,'(''production_execution_segment_growth_events'', ''CLEAR''),'||anchor);
END;
$reset_policy$;
