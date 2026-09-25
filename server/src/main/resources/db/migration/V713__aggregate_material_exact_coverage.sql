-- Shared manufacturing keeps one physical batch while each original parent
-- retains an exact output slice. Existing origins are immutable; aliases move
-- their beneficiaries through the established append-only delegation ledger.
ALTER TABLE preplan_make_entitlement_delegations
    ADD COLUMN aggregate_alias_id UUID REFERENCES preplan_aggregate_material_aliases(id);
ALTER TABLE preplan_make_entitlement_delegations DROP CONSTRAINT uq_preplan_make_delegate_source_action;
CREATE UNIQUE INDEX uq_preplan_make_delegate_source_action ON preplan_make_entitlement_delegations
    (supply_action_id,source_entitlement_event_id,target_analysis_material_id) WHERE aggregate_alias_id IS NULL;
CREATE INDEX idx_preplan_make_delegate_aggregate_alias ON preplan_make_entitlement_delegations(aggregate_alias_id,id)
    WHERE aggregate_alias_id IS NOT NULL;

CREATE FUNCTION fn_preplan_aggregate_alias_identity_valid(p_alias UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM preplan_aggregate_material_aliases alias
      JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id
      JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
      JOIN production_material_analysis_items child ON child.id=batch.anchor_analysis_item_id
        AND child.analysis_id=batch.analysis_id AND child.source_type='AGGREGATE_MAKE' AND NOT child.is_deleted
      JOIN production_material_analysis_materials parent ON parent.id=alias.source_parent_material_id
      JOIN production_material_analysis_materials source ON source.id=alias.source_material_id
      JOIN production_material_analysis_materials target ON target.id=alias.aggregate_material_id
      WHERE alias.id=p_alias AND source.analysis_id=batch.analysis_id AND parent.analysis_id=batch.analysis_id
        AND target.analysis_id=batch.analysis_id AND target.analysis_item_id=child.id
        AND (source.goods_id,source.color_id,source.unit_id) IS NOT DISTINCT FROM (target.goods_id,target.color_id,target.unit_id)
        AND alias.relative_bom_path=fn_aggregate_relative_bom_path(source.id,parent.id)
        AND alias.relative_bom_path=fn_aggregate_relative_bom_path(target.id,NULL)
        AND EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation WHERE allocation.action_id=action.id
            AND allocation.analysis_material_id=parent.id AND allocation.external_item_id=child.id));
$$;

CREATE FUNCTION fn_preplan_aggregate_alias_valid(p_alias UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT fn_preplan_aggregate_alias_identity_valid(p_alias)
      AND fn_preplan_aggregate_alias_qty(p_alias)>0 AND EXISTS(SELECT 1 FROM preplan_aggregate_material_aliases alias
        JOIN production_material_analysis_materials target ON target.id=alias.aggregate_material_id AND target.active WHERE alias.id=p_alias);
$$;

CREATE FUNCTION fn_preplan_aggregate_make_origin(p_child UUID,p_allocation UUID,p_material UUID,p_plan UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
      JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.route='MAKE'
        AND action.external_document_type='PREPLAN_MAKE_TASK' AND action.external_document_id=p_child
      JOIN preplan_supply_action_allocations allocation ON allocation.id=p_allocation AND allocation.action_id=action.id
      WHERE batch.anchor_analysis_item_id=p_child AND batch.plan_id=p_plan AND batch.route='MAKE'
        AND allocation.external_item_id=p_child AND allocation.analysis_material_id=p_material
        AND allocation.analysis_id=batch.analysis_id);
$$;

CREATE FUNCTION fn_preplan_aggregate_delegation_active_qty(p_delegation UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH RECURSIVE positive(id) AS (
        SELECT id FROM preplan_stock_entitlement_events WHERE event_group_id=p_delegation AND event_type='MAKE_DELEGATE_IN'
        UNION
        SELECT child.id FROM positive parent JOIN preplan_stock_entitlement_events counter ON counter.source_entitlement_event_id=parent.id
          JOIN preplan_stock_entitlement_events child ON child.counter_event_id=counter.id
          WHERE child.event_type IN('MAKE_DELEGATE_IN','REALLOCATE_IN','PRIORITY_IN','RESTORE')
    )
    SELECT COALESCE((SELECT GREATEST(LEAST(delegation.qty,delegation.qty
        -COALESCE((SELECT sum(negative.qty) FROM preplan_stock_entitlement_events negative
            WHERE negative.event_type='RELEASE' AND negative.source_entitlement_event_id IN(SELECT id FROM positive)),0)
        +COALESCE((SELECT sum(restored.qty) FROM preplan_stock_entitlement_events restored
            JOIN preplan_stock_entitlement_events counter ON counter.id=restored.counter_event_id
            WHERE restored.event_type='RESTORE' AND restored.id IN(SELECT id FROM positive)
              AND counter.event_type<>'FORMALIZE'),0)),0)
        FROM preplan_make_entitlement_delegations delegation WHERE delegation.id=p_delegation),0);
$$;

CREATE FUNCTION fn_preplan_aggregate_alias_delegated_qty(p_alias UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(fn_preplan_aggregate_delegation_active_qty(id)),0)
    FROM preplan_make_entitlement_delegations WHERE aggregate_alias_id=p_alias;
$$;

CREATE FUNCTION fn_preplan_aggregate_target_committed_qty(p_material UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT sum(balance.effective_qty) FROM v_preplan_stock_entitlement_beneficiary_balance balance
        WHERE balance.beneficiary_analysis_material_id=p_material),0)
      +COALESCE((SELECT sum(formal.qty-COALESCE((SELECT sum(restored.qty) FROM preplan_stock_entitlement_events restored
            WHERE restored.event_type='RESTORE' AND restored.counter_event_id=formal.id),0))
        FROM preplan_stock_entitlement_events formal WHERE formal.beneficiary_analysis_material_id=p_material
          AND formal.event_type='FORMALIZE'),0);
$$;

CREATE FUNCTION fn_preplan_aggregate_source_capacity(p_material UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT GREATEST(COALESCE((SELECT required_qty FROM production_material_analysis_materials WHERE id=p_material),0)
        +COALESCE((SELECT SUM(fn_preplan_aggregate_alias_qty(alias.id)) FROM preplan_aggregate_material_aliases alias
            WHERE alias.source_material_id=p_material AND fn_preplan_aggregate_alias_identity_valid(alias.id)),0),
        COALESCE((SELECT MAX(fn_preplan_aggregate_alias_source_capacity(alias.id)) FROM preplan_aggregate_material_aliases alias
            WHERE alias.source_material_id=p_material AND fn_preplan_aggregate_alias_identity_valid(alias.id)),0));
$$;

CREATE FUNCTION fn_preplan_aggregate_source_retained_qty(p_material UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT GREATEST(fn_preplan_aggregate_source_capacity(p_material)
        -COALESCE((SELECT SUM(fn_preplan_aggregate_alias_qty(alias.id)) FROM preplan_aggregate_material_aliases alias
            WHERE alias.source_material_id=p_material AND fn_preplan_aggregate_alias_identity_valid(alias.id)),0),
        COALESCE((SELECT required_qty FROM production_material_analysis_materials WHERE id=p_material),0));
$$;

CREATE FUNCTION fn_preplan_aggregate_source_delegate_available_qty(p_material UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT GREATEST(fn_preplan_aggregate_target_committed_qty(p_material)-fn_preplan_aggregate_source_retained_qty(p_material),0);
$$;

-- A shared parent makes the old display demand zero; that must not erase an
-- already-approved old child plan's private output admission.
CREATE OR REPLACE FUNCTION fn_preplan_direct_make_admitted_qty(p_child UUID,p_material UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT LEAST(child.requested_qty,fn_preplan_aggregate_source_capacity(material.id)+COALESCE((
        SELECT SUM(supplement.qty) FROM preplan_reallocation_make_supplements supplement
        WHERE supplement.child_analysis_item_id=child.id AND supplement.source_analysis_material_id=material.id),0))
    FROM production_material_analysis_items child
    JOIN production_material_analysis_materials material ON material.id=child.parent_analysis_material_id AND material.analysis_id=child.analysis_id
    WHERE child.id=p_child AND material.id=p_material AND child.source_type='MAKE_COMPONENT' AND NOT child.is_deleted),0)::numeric;
$$;

-- Preserve all existing checks and widen only the proven many-parent relation.
DO $exact_make$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('fn_check_preplan_analysis_stock_exact_peg()'::regprocedure),chr(13),'') INTO definition;
    needle:=E'OR child_item.source_type <> ''MAKE_COMPONENT''\n           OR child_item.parent_analysis_material_id\n                <> NEW.origin_analysis_material_id';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V713 MAKE exact source guard anchor changed'; END IF;
    definition:=replace(definition,needle,'OR ((child_item.source_type IS DISTINCT FROM ''MAKE_COMPONENT''
           OR child_item.parent_analysis_material_id IS DISTINCT FROM NEW.origin_analysis_material_id)
           AND NOT fn_preplan_aggregate_make_origin(child_item.id,allocation.id,NEW.origin_analysis_material_id,production_plan.id))
           OR fn_finished_in_is_public_output(stock_item.id)');
    EXECUTE definition;

    SELECT replace(pg_get_functiondef('fn_preplan_reservation_has_qualified_origin(uuid)'::regprocedure),chr(13),'') INTO definition;
    needle:=E'AND make_source.source_type=''MAKE_COMPONENT''\n                   AND make_source.analysis_id=exact.origin_analysis_id\n                   AND make_source.parent_analysis_material_id=exact.origin_analysis_material_id';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V713 qualified MAKE origin guard anchor changed'; END IF;
    EXECUTE replace(definition,needle,'AND make_source.analysis_id=exact.origin_analysis_id
                   AND ((make_source.source_type=''MAKE_COMPONENT'' AND make_source.parent_analysis_material_id=exact.origin_analysis_material_id)
                       OR fn_preplan_aggregate_make_origin(make_source.id,exact.supply_action_allocation_id,exact.origin_analysis_material_id,plan.id))
                   AND NOT fn_finished_in_is_public_output(stock_item.id)');
END $exact_make$;

DO $delegation_guard$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('fn_check_preplan_make_entitlement_delegation()'::regprocedure),chr(13),'') INTO definition;
    needle:='expected_source_type := CASE action.route';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V713 delegation source kind anchor changed'; END IF;
    definition:=replace(definition,needle,'expected_source_type := CASE WHEN NEW.aggregate_alias_id IS NOT NULL THEN ''AGGREGATE_MAKE'' ELSE CASE action.route');
    needle:=E'WHEN ''SUBCONTRACT'' THEN ''SUBCONTRACT_MAKE''\n        ELSE NULL END;';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V713 delegation source case anchor changed'; END IF;
    definition:=replace(definition,needle,E'WHEN ''SUBCONTRACT'' THEN ''SUBCONTRACT_MAKE''\n        ELSE NULL END END;');
    needle:='OR child_item.parent_analysis_material_id IS DISTINCT FROM parent_material.id';
    definition:=replace(definition,needle,'OR (NEW.aggregate_alias_id IS NULL AND child_item.parent_analysis_material_id IS DISTINCT FROM parent_material.id)');
    definition:=replace(definition,'OR analysis.status NOT IN (''ACTIVE'', ''PARTIALLY_PLANNED'')',
        'OR (analysis.status NOT IN (''ACTIVE'', ''PARTIALLY_PLANNED'') AND NOT (NEW.aggregate_alias_id IS NOT NULL AND analysis.status=''COMPLETED''))');
    definition:=replace(definition,'OR reservation.warehouse_id IS DISTINCT FROM analysis.warehouse_id',
        'OR (reservation.warehouse_id IS DISTINCT FROM analysis.warehouse_id AND NOT (NEW.aggregate_alias_id IS NOT NULL AND fn_preplan_reservation_has_qualified_origin(reservation.id)))');
    definition:=replace(definition,'target_material.required_qty',
        '(CASE WHEN NEW.aggregate_alias_id IS NULL THEN target_material.required_qty ELSE fn_preplan_aggregate_material_capacity(target_material.id) END)');
    needle:=E'    RETURN NEW;\nEND;';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V713 delegation quota anchor changed'; END IF;
    definition:=replace(definition,needle,E'    IF NEW.aggregate_alias_id IS NOT NULL AND (
        NOT fn_preplan_aggregate_alias_valid(NEW.aggregate_alias_id)
        OR NOT EXISTS(SELECT 1 FROM preplan_aggregate_material_aliases alias JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id
            WHERE alias.id=NEW.aggregate_alias_id AND batch.action_id=NEW.supply_action_id
              AND batch.anchor_analysis_item_id=NEW.child_analysis_item_id
              AND alias.source_parent_material_id=NEW.parent_analysis_material_id
              AND alias.source_material_id=NEW.source_analysis_material_id AND alias.aggregate_material_id=NEW.target_analysis_material_id)
        OR fn_preplan_aggregate_alias_delegated_qty(NEW.aggregate_alias_id)+NEW.qty>fn_preplan_aggregate_alias_qty(NEW.aggregate_alias_id)
        OR NEW.qty>fn_preplan_aggregate_source_delegate_available_qty(NEW.source_analysis_material_id)
        OR fn_preplan_aggregate_target_committed_qty(NEW.target_analysis_material_id)+NEW.qty>fn_preplan_aggregate_material_capacity(target_material.id)
    ) THEN RAISE EXCEPTION ''Aggregate delegation exceeds its exact alias or canonical requirement'' USING ERRCODE=''23514''; END IF;
    RETURN NEW;\nEND;');
    EXECUTE definition;
END $delegation_guard$;

CREATE FUNCTION fn_preplan_aggregate_material_targets(p_material UUID)
RETURNS TABLE(material_id UUID) LANGUAGE sql STABLE AS $$
    WITH RECURSIVE targets(id) AS (
        SELECT p_material UNION
        SELECT alias.aggregate_material_id FROM targets source JOIN preplan_aggregate_material_aliases alias ON alias.source_material_id=source.id
          WHERE fn_preplan_aggregate_alias_valid(alias.id)
    ) SELECT id FROM targets;
$$;

CREATE FUNCTION fn_preplan_aggregate_material_has_waiting_demand(p_material UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM fn_preplan_aggregate_material_targets(p_material) target
      JOIN production_material_analysis_materials material ON material.id=target.material_id AND material.active
      JOIN production_material_analysis_plan_links link ON link.analysis_item_id=material.analysis_item_id AND link.allocation_status='APPROVED'
      JOIN production_plans plan ON plan.id=link.plan_id AND plan.material_analysis_id=material.analysis_id
        AND plan.material_analysis_item_id=material.analysis_item_id AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_canceled
      JOIN production_execution_segments segment ON segment.plan_id=plan.id AND NOT segment.is_deleted
        AND segment.status='WAITING' AND segment.auto_promote_when_ready
      JOIN production_material_demands demand ON demand.execution_segment_id=segment.id AND NOT demand.is_deleted
        AND demand.status NOT IN('RELEASED','REVERSED')
        AND (demand.goods_id,demand.color_id,demand.unit_id) IS NOT DISTINCT FROM (material.goods_id,material.color_id,material.unit_id));
$$;

-- An action is one promise. Its remaining quantity is sliced by exact
-- allocation, never copied wholesale to every historical/current group alias.
CREATE FUNCTION fn_preplan_aggregate_allocation_pending_qty(p_allocation UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE allocation preplan_supply_action_allocations%ROWTYPE; action preplan_supply_actions%ROWTYPE;
    own_capacity NUMERIC; total_pending NUMERIC; preceding_capacity NUMERIC;
BEGIN
    SELECT * INTO allocation FROM preplan_supply_action_allocations WHERE id=p_allocation;
    IF NOT FOUND THEN RETURN 0; END IF;
    SELECT * INTO action FROM preplan_supply_actions WHERE id=allocation.action_id;
    IF action.status NOT IN('OPEN','CREATED','IN_PROGRESS') THEN RETURN 0; END IF;
    IF action.operation_type='FUTURE_TRANSFER' OR fn_preplan_action_has_future_transfer(action.id)
        OR fn_preplan_action_has_shared_claim_history(action.id) THEN RETURN fn_preplan_future_allocation_pending_qty(allocation.id); END IF;
    IF action.operation_type='SHARED_FUTURE_CLAIM' THEN
        total_pending:=fn_preplan_shared_action_pending_qty(action.id);
    ELSIF action.route='BUY' THEN
        SELECT CASE WHEN demand_source_valid THEN LEAST(GREATEST(demand_requested_qty-demand_qualified_qty,0),demand_future_qty) ELSE 0 END
          INTO total_pending FROM v_preplan_buy_action_slice_progress WHERE action_id=action.id;
    ELSIF action.external_document_type IN('PREPLAN_MAKE_TASK','SUBCONTRACT_MAKE_TASK') THEN
        IF NOT EXISTS(SELECT 1 FROM production_material_analysis_items child WHERE child.id=action.external_document_id AND NOT child.is_deleted
            AND (child.requested_qty>child.approved_qty OR EXISTS(SELECT 1 FROM production_material_analysis_plan_links link
              JOIN production_plans plan ON plan.id=link.plan_id AND plan.status IN(0,1) AND NOT plan.is_deleted
                AND NOT plan.is_canceled AND NOT plan.is_closed WHERE link.analysis_item_id=child.id AND link.allocation_status IN('SUBMITTED','APPROVED')))) THEN RETURN 0; END IF;
        total_pending:=GREATEST(fn_preplan_action_admitted_qty(action.id)-fn_preplan_action_received_qty(action.id),0);
    ELSIF action.external_document_type='SUBCONTRACT_APPLICATION' AND EXISTS(SELECT 1 FROM subcontract_applications application
        WHERE application.id=action.external_document_id AND NOT application.is_deleted AND application.status IN(0,1)) THEN
        total_pending:=GREATEST(fn_preplan_action_admitted_qty(action.id)-fn_preplan_action_received_qty(action.id),0);
    ELSE RETURN 0;
    END IF;
    own_capacity:=GREATEST(fn_preplan_allocation_admitted_qty(allocation.id)-fn_preplan_allocation_received_qty(allocation.id),0);
    SELECT COALESCE(sum(GREATEST(fn_preplan_allocation_admitted_qty(prior.id)-fn_preplan_allocation_received_qty(prior.id),0)),0)
      INTO preceding_capacity FROM preplan_supply_action_allocations prior WHERE prior.action_id=action.id
        AND (prior.created_at,prior.id)<(allocation.created_at,allocation.id);
    RETURN LEAST(own_capacity,GREATEST(COALESCE(total_pending,0)-preceding_capacity,0));
END $$;

CREATE FUNCTION fn_preplan_aggregate_direct_make_sources(p_material UUID)
RETURNS TABLE(source_id UUID,arranged_qty NUMERIC,pending_qty NUMERIC) LANGUAGE sql STABLE AS $$
    SELECT plan_item.id,LEAST(link.submitted_qty-link.public_surplus_qty,plan_item.qty*plan_item.unit_rate),
        CASE WHEN plan.is_closed THEN 0 ELSE GREATEST(LEAST(link.submitted_qty-link.public_surplus_qty,plan_item.qty*plan_item.unit_rate)
            -COALESCE(received.qty,0),0) END
    FROM production_material_analysis_materials material
    JOIN production_material_analysis_items child ON child.parent_analysis_material_id=material.id
      AND child.source_type='MAKE_COMPONENT' AND NOT child.is_deleted
    JOIN production_material_analysis_plan_links link ON link.analysis_item_id=child.id AND link.allocation_status IN('SUBMITTED','APPROVED')
    JOIN production_plans plan ON plan.id=link.plan_id AND plan.status IN(0,1) AND NOT plan.is_deleted AND NOT plan.is_canceled
    JOIN production_plan_items plan_item ON plan_item.plan_id=plan.id AND NOT plan_item.is_deleted
      AND (plan_item.goods_id,plan_item.color_id,plan_item.unit_id) IS NOT DISTINCT FROM (material.goods_id,material.color_id,material.unit_id)
    LEFT JOIN LATERAL(SELECT sum(item.base_qty) AS qty FROM stock_document_items item
      JOIN stock_documents document ON document.id=item.doc_id AND document.doc_type='FINISHED_IN' AND document.status=1 AND NOT document.is_deleted
      WHERE item.upstream_item_id=plan_item.id AND NOT item.is_deleted AND NOT fn_finished_in_is_public_output(item.id)) received ON TRUE
    WHERE material.id=p_material AND NOT EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation
      JOIN preplan_supply_actions action ON action.id=allocation.action_id AND action.status<>'CANCELLED'
      WHERE allocation.analysis_material_id=material.id AND allocation.external_item_id=child.id
        AND action.external_document_type='PREPLAN_MAKE_TASK');
$$;

CREATE FUNCTION fn_preplan_aggregate_material_pending_qty(p_material UUID,p_path UUID[] DEFAULT '{}'::uuid[])
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE total NUMERIC; alias RECORD; source_pending NUMERIC; previous NUMERIC; remaining NUMERIC;
BEGIN
    IF p_material=ANY(p_path) OR cardinality(p_path)>=32 THEN
        RAISE EXCEPTION 'Aggregate supply alias cycle or excessive depth' USING ERRCODE='23514';
    END IF;
    SELECT COALESCE(sum(fn_preplan_aggregate_allocation_pending_qty(id)),0) INTO total
      FROM preplan_supply_action_allocations WHERE analysis_material_id=p_material;
    total:=total+COALESCE((SELECT sum(pending_qty) FROM fn_preplan_aggregate_direct_make_sources(p_material)),0);
    FOR alias IN SELECT bridge.* FROM preplan_aggregate_material_aliases bridge WHERE bridge.aggregate_material_id=p_material
        AND fn_preplan_aggregate_alias_valid(bridge.id) ORDER BY bridge.created_at,bridge.id LOOP
        source_pending:=fn_preplan_aggregate_material_pending_qty(alias.source_material_id,p_path||p_material);
        source_pending:=GREATEST(source_pending-GREATEST(fn_preplan_aggregate_source_retained_qty(alias.source_material_id)
            -fn_preplan_aggregate_target_committed_qty(alias.source_material_id),0),0);
        remaining:=GREATEST(fn_preplan_aggregate_alias_qty(alias.id)-fn_preplan_aggregate_alias_delegated_qty(alias.id),0);
        SELECT COALESCE(sum(GREATEST(fn_preplan_aggregate_alias_qty(prior.id)-fn_preplan_aggregate_alias_delegated_qty(prior.id),0)),0)
          INTO previous FROM preplan_aggregate_material_aliases prior WHERE prior.source_material_id=alias.source_material_id
            AND fn_preplan_aggregate_alias_valid(prior.id) AND (prior.created_at,prior.id)<(alias.created_at,alias.id);
        total:=total+LEAST(remaining,GREATEST(source_pending-previous,0));
    END LOOP;
    RETURN total;
END $$;

CREATE FUNCTION fn_preplan_aggregate_source_future_available_qty(p_material UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT GREATEST(fn_preplan_aggregate_material_pending_qty(p_material)
        -GREATEST(fn_preplan_aggregate_source_retained_qty(p_material)-fn_preplan_aggregate_target_committed_qty(p_material),0),0);
$$;

CREATE FUNCTION fn_preplan_aggregate_alias_supply_sources(p_material UUID)
RETURNS TABLE(alias_id UUID,source_material_id UUID,aggregate_material_id UUID,allocated_qty NUMERIC,pending_qty NUMERIC,related_supply_sources JSONB)
LANGUAGE sql STABLE AS $$
    SELECT alias.id,alias.source_material_id,alias.aggregate_material_id,fn_preplan_aggregate_alias_qty(alias.id),
        LEAST(GREATEST(fn_preplan_aggregate_alias_qty(alias.id)-fn_preplan_aggregate_alias_delegated_qty(alias.id),0),
            GREATEST(fn_preplan_aggregate_source_future_available_qty(alias.source_material_id)-COALESCE((SELECT sum(GREATEST(
                fn_preplan_aggregate_alias_qty(prior.id)-fn_preplan_aggregate_alias_delegated_qty(prior.id),0))
                FROM preplan_aggregate_material_aliases prior WHERE prior.source_material_id=alias.source_material_id
                  AND fn_preplan_aggregate_alias_valid(prior.id) AND (prior.created_at,prior.id)<(alias.created_at,alias.id)),0),0)),
        COALESCE((SELECT jsonb_agg(jsonb_build_object('sourceKind',sources.kind,'sourceId',sources.id,'quantity',sources.qty) ORDER BY sources.kind,sources.id)
          FROM (SELECT 'ACTION'::text AS kind,action.id,allocation.allocated_qty AS qty
            FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id AND action.status<>'CANCELLED'
            WHERE allocation.analysis_material_id=alias.source_material_id
            UNION ALL SELECT 'PLAN_ITEM',source_id,arranged_qty FROM fn_preplan_aggregate_direct_make_sources(alias.source_material_id)) sources),'[]'::jsonb)
    FROM preplan_aggregate_material_aliases alias WHERE alias.aggregate_material_id=p_material AND fn_preplan_aggregate_alias_valid(alias.id);
$$;

CREATE FUNCTION fn_preplan_aggregate_alias_coverage(p_analysis UUID)
RETURNS TABLE(analysis_material_id UUID,inherited_pending_qty NUMERIC,inherited_arranged_qty NUMERIC,inherited_received_qty NUMERIC,source_aliases JSONB)
LANGUAGE sql STABLE AS $$
    WITH selected AS MATERIALIZED (
        SELECT DISTINCT alias.aggregate_material_id FROM preplan_aggregate_batches batch
        JOIN preplan_aggregate_material_aliases alias ON alias.batch_id=batch.id
        WHERE batch.analysis_id=p_analysis
    ), slices AS MATERIALIZED (
        SELECT source.*,fn_preplan_aggregate_alias_delegated_qty(source.alias_id) AS received
        FROM selected CROSS JOIN LATERAL fn_preplan_aggregate_alias_supply_sources(selected.aggregate_material_id) source
    )
    SELECT aggregate_material_id,SUM(pending_qty),SUM(LEAST(allocated_qty,received+pending_qty)),SUM(received),
        jsonb_agg(jsonb_build_object('relationType','ALIAS','aliasId',alias_id,'sourceMaterialId',source_material_id,
            'quota',allocated_qty,'inheritedQuantity',LEAST(allocated_qty,received+pending_qty),'pendingQuantity',pending_qty,
            'receivedQuantity',received,'relatedSupplySources',related_supply_sources) ORDER BY alias_id)
    FROM slices GROUP BY aggregate_material_id;
$$;

CREATE FUNCTION fn_guard_aggregate_source_cancellation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status='CANCELLED' AND OLD.status<>'CANCELLED' AND EXISTS(
        SELECT 1 FROM preplan_aggregate_batches batch WHERE batch.action_id=NEW.id) AND EXISTS(
        SELECT 1 FROM preplan_make_entitlement_delegations delegation WHERE delegation.supply_action_id=NEW.id
          AND fn_preplan_aggregate_delegation_active_qty(delegation.id)>0) THEN
        RAISE EXCEPTION '共享批次的原路径投入权益尚未归还；先处理领料、正式占用和后续依赖后再撤销'
            USING ERRCODE='23514',CONSTRAINT='aggregate_material_cancellation_dependency';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_aggregate_source_cancellation BEFORE UPDATE OF status ON preplan_supply_actions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_source_cancellation();

-- Deliberate planner boundaries. The set-returning coverage API is called
-- with outer predicates by refresh/preview; recursively inlining its alias,
-- entitlement-view and admission queries produced a >100-second plan for a
-- tiny shared-batch append. Keep each exact lookup as a cached parameterized
-- statement instead of expanding the ownership graph into every caller.
-- No search_path, timeout, identity or quantity rule is changed here.
DO $planning_boundaries$
DECLARE signature TEXT; function_row RECORD; body TEXT;
BEGIN
    FOREACH signature IN ARRAY ARRAY[
        'fn_preplan_aggregate_alias_identity_valid(uuid)',
        'fn_preplan_aggregate_alias_valid(uuid)',
        'fn_preplan_aggregate_make_origin(uuid,uuid,uuid,uuid)',
        'fn_preplan_aggregate_delegation_active_qty(uuid)',
        'fn_preplan_aggregate_alias_delegated_qty(uuid)',
        'fn_preplan_aggregate_target_committed_qty(uuid)',
        'fn_preplan_aggregate_source_capacity(uuid)',
        'fn_preplan_aggregate_source_retained_qty(uuid)',
        'fn_preplan_aggregate_source_delegate_available_qty(uuid)',
        'fn_preplan_aggregate_source_future_available_qty(uuid)',
        'fn_preplan_aggregate_material_targets(uuid)',
        'fn_preplan_aggregate_material_has_waiting_demand(uuid)',
        'fn_preplan_aggregate_direct_make_sources(uuid)',
        'fn_preplan_aggregate_alias_supply_sources(uuid)',
        'fn_preplan_aggregate_alias_coverage(uuid)'
    ] LOOP
        SELECT procedure.proname,procedure.prosrc,procedure.proretset,
            pg_get_function_arguments(procedure.oid) AS arguments,pg_get_function_result(procedure.oid) AS result,
            language.lanname INTO function_row
          FROM pg_proc procedure JOIN pg_language language ON language.oid=procedure.prolang
          WHERE procedure.oid=signature::regprocedure;
        IF function_row.lanname IS DISTINCT FROM 'sql' THEN
            RAISE EXCEPTION 'V713 planner-boundary source changed: %',signature;
        END IF;
        body:=regexp_replace(btrim(function_row.prosrc),';\s*$','');
        body:=CASE WHEN function_row.proretset THEN E'BEGIN\n RETURN QUERY\n'||body||E';\nEND'
                   ELSE E'BEGIN\n RETURN (\n'||body||E'\n);\nEND' END;
        EXECUTE format('CREATE OR REPLACE FUNCTION public.%I(%s) RETURNS %s LANGUAGE plpgsql STABLE AS %L',
            function_row.proname,function_row.arguments,function_row.result,body);
    END LOOP;
END $planning_boundaries$;
