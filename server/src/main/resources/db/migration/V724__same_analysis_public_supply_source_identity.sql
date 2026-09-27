-- Public supply belongs to a physical action, not to the entire analysis.
-- A different original demand in the same multi-product analysis may adopt it.
-- The action's own demand and its exact aggregate aliases must never claim it again.
-- NULL means an old aggregate did not record complete original private shares.
-- An empty array is a proven wholly-public source, with no private beneficiary.
CREATE FUNCTION fn_preplan_public_private_source_ids(p_action UUID)
RETURNS UUID[] LANGUAGE plpgsql STABLE AS $$
DECLARE selected_batch UUID; requested NUMERIC; complete BOOLEAN; proof_total NUMERIC; result UUID[];
BEGIN
    SELECT batch.id,action.requested_qty INTO selected_batch,requested
    FROM preplan_supply_actions action LEFT JOIN preplan_aggregate_batches batch ON batch.action_id=action.id
    WHERE action.id=p_action;
    IF selected_batch IS NULL THEN
        RETURN ARRAY(SELECT DISTINCT analysis_material_id FROM preplan_supply_action_allocations WHERE action_id=p_action);
    END IF;
    SELECT count(*)>0 AND bool_and(jsonb_typeof(intent_snapshot->'sourcePrivateQtyByMaterialLineId') IS NOT DISTINCT FROM 'object')
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
        AND entry.value::numeric>0 AND (material.id IS NULL OR origin.source_type='AGGREGATE_MAKE'
          OR material.analysis_id<>source.analysis_id
          OR (material.goods_id,material.color_id,material.unit_id) IS DISTINCT FROM (source.goods_id,source.color_id,source.unit_id))) THEN
        RETURN NULL;
    END IF;
    SELECT ARRAY(SELECT entry.key::uuid FROM preplan_aggregate_batch_events event
      CROSS JOIN LATERAL jsonb_each_text(event.intent_snapshot->'sourcePrivateQtyByMaterialLineId') entry
      WHERE event.batch_id=selected_batch AND event.event_type IN('CREATE','APPEND')
      GROUP BY entry.key HAVING sum(entry.value::numeric)>0) INTO result;
    RETURN result;
END;
$$;

CREATE FUNCTION fn_preplan_public_target_is_source(p_action UUID,p_target_material UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE origins UUID[]; found BOOLEAN;
BEGIN
    IF p_action IS NULL OR p_target_material IS NULL THEN RETURN TRUE; END IF;
    origins:=fn_preplan_public_private_source_ids(p_action);
    IF origins IS NULL THEN
        -- An unproved historical aggregate keeps the previous conservative boundary.
        WITH RECURSIVE equivalent(material_id) AS (
          SELECT p_target_material UNION
          SELECT CASE WHEN alias.source_material_id=equivalent.material_id THEN alias.aggregate_material_id ELSE alias.source_material_id END
          FROM equivalent JOIN preplan_aggregate_material_aliases alias
            ON alias.source_material_id=equivalent.material_id OR alias.aggregate_material_id=equivalent.material_id
        ) SELECT EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation WHERE allocation.action_id=p_action
            AND allocation.analysis_material_id IN(SELECT material_id FROM equivalent)) INTO found;
    ELSE
        WITH RECURSIVE downstream(material_id) AS (
          SELECT unnest(origins) UNION
          SELECT alias.aggregate_material_id FROM downstream
          JOIN preplan_aggregate_material_aliases alias ON alias.source_material_id=downstream.material_id
        ) SELECT EXISTS(SELECT 1 FROM downstream WHERE material_id=p_target_material) INTO found;
    END IF;
    RETURN found;
END;
$$;

-- Ordinary MAKE and proven aggregate MAKE use the same original-beneficiary rule.
-- Replacing this function here preserves the already-installed V722 bytes.
CREATE OR REPLACE FUNCTION fn_preplan_make_public_target_is_source(p_plan_item UUID,p_target_material UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE action_id UUID; origins UUID[]; found BOOLEAN;
BEGIN
    IF p_plan_item IS NULL OR p_target_material IS NULL THEN RETURN TRUE; END IF;
    SELECT batch.action_id INTO action_id FROM production_plan_items item
      JOIN preplan_aggregate_batches batch ON batch.plan_id=item.plan_id WHERE item.id=p_plan_item;
    IF action_id IS NOT NULL THEN
        RETURN fn_preplan_public_target_is_source(action_id,p_target_material);
    END IF;
    SELECT array_remove(ARRAY[source.root_material_id,source.parent_analysis_material_id],NULL) INTO origins
      FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id
      JOIN production_material_analysis_items source ON source.id=plan.material_analysis_item_id WHERE item.id=p_plan_item;
    WITH RECURSIVE downstream(material_id) AS (
      SELECT unnest(origins) UNION
      SELECT alias.aggregate_material_id FROM downstream
      JOIN preplan_aggregate_material_aliases alias ON alias.source_material_id=downstream.material_id
    ) SELECT EXISTS(SELECT 1 FROM downstream WHERE material_id=p_target_material) INTO found;
    RETURN found;
END;
$$;

DO $source_identity$
DECLARE definition TEXT;
        old_guard CONSTANT TEXT := 'OR source_action.analysis_id=claim_action.analysis_id';
        old_capacity CONSTANT TEXT := E'OR fn_preplan_public_source_planning_capacity(\n              source_action.id,expected_item) <= 0';
BEGIN
    SELECT pg_get_functiondef('fn_validate_preplan_shared_future_claim()'::regprocedure)
      INTO definition;
    IF strpos(definition,old_guard)=0 THEN
        RAISE EXCEPTION 'V724 shared public claim source identity contract changed';
    END IF;
    IF strpos(definition,'validate_open BOOLEAN := TRUE;')=0
        OR strpos(definition,'IF TG_TABLE_NAME=''preplan_supply_action_allocations'' THEN')=0 THEN
        RAISE EXCEPTION 'V724 shared public claim transition contract changed';
    END IF;
    definition:=replace(definition,'validate_open BOOLEAN := TRUE;',
        'validate_open BOOLEAN := TRUE; validate_source_identity BOOLEAN := TRUE;');
    definition:=replace(definition,'IF TG_TABLE_NAME=''preplan_supply_action_allocations'' THEN',
        'IF TG_OP=''UPDATE'' THEN
          IF TG_TABLE_NAME=''preplan_supply_actions'' THEN
            validate_source_identity := NEW.claim_source_action_id IS DISTINCT FROM OLD.claim_source_action_id
              OR NEW.analysis_id IS DISTINCT FROM OLD.analysis_id
              OR NEW.action_group_key IS DISTINCT FROM OLD.action_group_key
              OR NEW.requested_qty>OLD.requested_qty
              OR (OLD.status=''CANCELLED'' AND NEW.status<>''CANCELLED'');
          ELSIF TG_TABLE_NAME=''preplan_supply_action_allocations'' THEN
            validate_source_identity := NEW.action_id IS DISTINCT FROM OLD.action_id
              OR NEW.analysis_material_id IS DISTINCT FROM OLD.analysis_material_id
              OR NEW.external_item_id IS DISTINCT FROM OLD.external_item_id
              OR NEW.allocated_qty>OLD.allocated_qty;
          END IF;
        END IF;
        IF TG_TABLE_NAME=''preplan_supply_action_allocations'' THEN');
    definition:=replace(definition,old_guard,
        'OR (validate_source_identity AND EXISTS(SELECT 1 FROM preplan_supply_action_allocations target_allocation
            WHERE target_allocation.action_id=claim_action.id
              AND fn_preplan_public_target_is_source(source_action.id,target_allocation.analysis_material_id)))');
    IF strpos(definition,old_capacity)=0 THEN
        RAISE EXCEPTION 'V724 shared public claim nonzero capacity contract changed';
    END IF;
    definition:=replace(definition,old_capacity,
        'OR (claim_action.status<>''CANCELLED'' AND fn_preplan_public_source_planning_capacity(source_action.id,expected_item)<=0)');
    -- Cancelling an entire analysis releases its claims before retiring the source.
    -- At deferred validation the source capacity is legitimately zero. The total
    -- active-claim capacity check still prevents leaving another beneficiary behind.
    -- A later legal parent merge can connect two formerly distinct original rows.
    -- Do not retroactively invalidate a historical claim during receipt/cancellation.
    -- New rows, changed identities, growth and reactivation must prove identity again.
    -- Preserve the installed warehouse, route, document, capacity and reversal checks.
    -- This is the same deferred validator for both the action and allocation rows.
    EXECUTE definition;
END;
$source_identity$;
