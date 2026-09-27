-- Forward completion after V724 was installed in the shared business database.
-- Preserve every applied V724 byte; strengthen proof validation and keep issued
-- private promises alive when public claims activate future-supply accounting.

CREATE OR REPLACE FUNCTION fn_preplan_public_private_source_ids(p_action UUID)
RETURNS UUID[] LANGUAGE plpgsql STABLE AS $$
DECLARE selected_batch UUID; requested NUMERIC; complete BOOLEAN; proof_total NUMERIC; result UUID[];
BEGIN
    SELECT batch.id,action.requested_qty INTO selected_batch,requested
    FROM preplan_supply_actions action LEFT JOIN preplan_aggregate_batches batch ON batch.action_id=action.id
    WHERE action.id=p_action;
    IF selected_batch IS NULL THEN
        RETURN ARRAY(SELECT DISTINCT analysis_material_id FROM preplan_supply_action_allocations WHERE action_id=p_action);
    END IF;
    SELECT count(*)>0 AND bool_and(
        jsonb_typeof(intent_snapshot->'sourcePrivateQtyByMaterialLineId') IS NOT DISTINCT FROM 'object'
        AND jsonb_typeof(intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId') IS NOT DISTINCT FROM 'object'
        AND jsonb_typeof(intent_snapshot->'originalMaterialLineIds') IS NOT DISTINCT FROM 'array')
      INTO complete FROM preplan_aggregate_batch_events WHERE batch_id=selected_batch
        AND event_type IN('CREATE','APPEND');
    IF complete IS DISTINCT FROM TRUE THEN RETURN NULL; END IF;
    SELECT COALESCE(sum(entry.value::numeric),0),bool_and(entry.value::numeric>=0)
      INTO proof_total,complete
    FROM preplan_aggregate_batch_events event
    CROSS JOIN LATERAL jsonb_each_text(event.intent_snapshot->'sourcePrivateQtyByMaterialLineId') entry
    WHERE event.batch_id=selected_batch AND event.event_type IN('CREATE','APPEND');
    IF proof_total IS DISTINCT FROM requested OR complete IS FALSE THEN RETURN NULL; END IF;
    IF EXISTS(SELECT 1 FROM preplan_aggregate_batch_events event
      CROSS JOIN LATERAL jsonb_each_text(event.intent_snapshot->'sourcePrivateQtyByMaterialLineId') entry
      LEFT JOIN production_material_analysis_materials material ON material.id=entry.key::uuid
      LEFT JOIN production_material_analysis_items origin ON origin.id=material.analysis_item_id
      JOIN preplan_supply_actions source ON source.id=p_action
      WHERE event.batch_id=selected_batch AND event.event_type IN('CREATE','APPEND')
        AND entry.value::numeric>0 AND (NOT jsonb_exists(event.intent_snapshot->'originalMaterialLineIds',entry.key)
          OR material.id IS NULL OR origin.source_type='AGGREGATE_MAKE'
          OR material.analysis_id<>source.analysis_id
          OR (material.goods_id,material.color_id,material.unit_id) IS DISTINCT FROM (source.goods_id,source.color_id,source.unit_id))) THEN
        RETURN NULL;
    END IF;
    IF EXISTS(SELECT 1 FROM preplan_aggregate_batch_events event
      CROSS JOIN LATERAL jsonb_each(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId') target
      WHERE event.batch_id=selected_batch AND event.event_type IN('CREATE','APPEND')
        AND jsonb_typeof(target.value) IS DISTINCT FROM 'object') THEN RETURN NULL; END IF;
    IF EXISTS(
      WITH flat AS (
        SELECT event.id,entry.key original,entry.value::numeric qty FROM preplan_aggregate_batch_events event
        CROSS JOIN LATERAL jsonb_each_text(event.intent_snapshot->'sourcePrivateQtyByMaterialLineId') entry
        WHERE event.batch_id=selected_batch AND event.event_type IN('CREATE','APPEND')
      ), matrix AS (
        SELECT event.id,origin.key original,SUM(origin.value::numeric) qty
        FROM preplan_aggregate_batch_events event
        CROSS JOIN LATERAL jsonb_each(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId') target
        CROSS JOIN LATERAL jsonb_each_text(target.value) origin
        WHERE event.batch_id=selected_batch AND event.event_type IN('CREATE','APPEND')
        GROUP BY event.id,origin.key
      ) SELECT 1 FROM flat FULL JOIN matrix USING(id,original)
        WHERE COALESCE(flat.qty,0) IS DISTINCT FROM COALESCE(matrix.qty,0)
    ) THEN RETURN NULL; END IF;
    SELECT ARRAY(SELECT entry.key::uuid FROM preplan_aggregate_batch_events event
      CROSS JOIN LATERAL jsonb_each_text(event.intent_snapshot->'sourcePrivateQtyByMaterialLineId') entry
      WHERE event.batch_id=selected_batch AND event.event_type IN('CREATE','APPEND')
      GROUP BY entry.key HAVING sum(entry.value::numeric)>0) INTO result;
    RETURN result;
END;
$$;


-- A public claim must not make its source's unplaced private promise disappear.
-- Keep the approved-only transfer admission function and actual stock semantics.
-- Only planning pending-quantity readers include a real, still-valid request.
DO $private_planning_request$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_preplan_public_source_unplaced_qty(uuid,uuid)'::regprocedure) INTO definition;
    IF strpos(definition,'operation_type=''SUPPLY''')=0 THEN
        RAISE EXCEPTION 'V725 unplaced request source contract changed';
    END IF;
    definition:=replace(definition,'fn_preplan_public_source_unplaced_qty','fn_preplan_external_planning_unplaced_qty');
    definition:=replace(definition,'operation_type=''SUPPLY''',
        'operation_type IN(''SUPPLY'',''FUTURE_TRANSFER'',''SHARED_FUTURE_CLAIM'')');
    EXECUTE definition;
END;
$private_planning_request$;

CREATE FUNCTION fn_preplan_external_planning_expected_qty(p_action UUID,p_item UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT fn_preplan_external_expected_qty(p_action,p_item)
        +fn_preplan_external_planning_unplaced_qty(p_action,p_item)
$$;

DO $private_planning_pending$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_preplan_future_source_private_capacity_qty(uuid)'::regprocedure) INTO definition;
    IF strpos(definition,'fn_preplan_external_exact_approved_qty(action.id,allocation.external_item_id)')=0
        OR strpos(definition,'AND (action.route=''BUY'' OR NOT EXISTS(SELECT 1 FROM goods_bom_items bom WHERE bom.goods_id=action.goods_id AND NOT bom.is_deleted))')=0 THEN
        RAISE EXCEPTION 'V725 private planning capacity contract changed';
    END IF;
    definition:=replace(definition,'fn_preplan_future_source_private_capacity_qty','fn_preplan_future_source_planning_private_capacity_qty');
    definition:=replace(definition,'fn_preplan_external_exact_approved_qty(action.id,allocation.external_item_id)',
        '(fn_preplan_external_exact_approved_qty(action.id,allocation.external_item_id)+fn_preplan_external_planning_unplaced_qty(action.id,allocation.external_item_id))');
    -- BOM restrictions belong to private transfer admission, not to reading a
    -- real issued subcontract request's own unreceived promise.
    definition:=replace(definition,
        'AND (action.route=''BUY'' OR NOT EXISTS(SELECT 1 FROM goods_bom_items bom WHERE bom.goods_id=action.goods_id AND NOT bom.is_deleted))','');
    EXECUTE definition;
    SELECT pg_get_functiondef('fn_preplan_future_source_available_qty(uuid)'::regprocedure) INTO definition;
    IF strpos(definition,'fn_preplan_external_expected_qty')=0
        OR strpos(definition,'fn_preplan_future_source_private_capacity_qty')=0 THEN
        RAISE EXCEPTION 'V725 private planning source contract changed';
    END IF;
    definition:=replace(definition,'fn_preplan_future_source_available_qty','fn_preplan_future_source_planning_available_qty');
    definition:=replace(definition,'fn_preplan_future_source_private_capacity_qty','fn_preplan_future_source_planning_private_capacity_qty');
    definition:=replace(definition,'fn_preplan_external_expected_qty','fn_preplan_external_planning_expected_qty');
    EXECUTE definition;
    SELECT pg_get_functiondef('fn_preplan_future_allocation_pending_qty(uuid)'::regprocedure) INTO definition;
    IF strpos(definition,'fn_preplan_future_source_available_qty')=0
        OR strpos(definition,'fn_preplan_external_expected_qty')=0 THEN
        RAISE EXCEPTION 'V725 private planning allocation contract changed';
    END IF;
    definition:=replace(definition,'fn_preplan_future_source_available_qty','fn_preplan_future_source_planning_available_qty');
    definition:=replace(definition,'fn_preplan_external_expected_qty','fn_preplan_external_planning_expected_qty');
    EXECUTE definition;
END;
$private_planning_pending$;

-- Plan links already store private and public quantities in separate columns.
-- Subtracting public_surplus_qty again loses an oversized ordinary MAKE plan's
-- private promise when its parent is subsequently combined into an aggregate.
DO $private_make_alias$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_preplan_aggregate_direct_make_sources(uuid)'::regprocedure) INTO definition;
    IF strpos(definition,'link.submitted_qty-link.public_surplus_qty')=0 THEN
        RAISE EXCEPTION 'V725 direct MAKE private quantity contract changed';
    END IF;
    definition:=replace(definition,'link.submitted_qty-link.public_surplus_qty',
        'link.submitted_qty*COALESCE(plan_item.unit_rate,1)');
    EXECUTE definition;
END;
$private_make_alias$;
