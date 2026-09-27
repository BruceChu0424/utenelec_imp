-- V713 introduced exact, arbitrarily deep BOM aliases, but the older V467
-- delegation header still required both endpoints to be direct children.
-- Keep that shape for ordinary MAKE/SUBCONTRACT delegation. An aggregate
-- delegation instead proves its complete path through the existing immutable
-- alias guard, including the real parent allocation and canonical capacity.
-- No source reservation, origin, available quantity or quota check is removed.
DO $deep_alias_delegation$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_check_preplan_make_entitlement_delegation()'::regprocedure)
      INTO definition;
    needle := 'OR source_material.parent_node_key IS DISTINCT FROM parent_material.node_key';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V728 original direct-child delegation guard changed';
    END IF;
    definition := replace(definition,needle,
        'OR (NEW.aggregate_alias_id IS NULL AND source_material.parent_node_key IS DISTINCT FROM parent_material.node_key)');
    needle := 'OR target_material.depth <> 1';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V728 original target-depth delegation guard changed';
    END IF;
    definition := replace(definition,needle,
        'OR (NEW.aggregate_alias_id IS NULL AND target_material.depth <> 1)');
    IF position('NOT fn_preplan_aggregate_alias_valid(NEW.aggregate_alias_id)' IN definition)=0
       OR position('alias.source_parent_material_id=NEW.parent_analysis_material_id' IN definition)=0
       OR position('fn_preplan_aggregate_alias_delegated_qty(NEW.aggregate_alias_id)+NEW.qty>fn_preplan_aggregate_alias_qty(NEW.aggregate_alias_id)' IN definition)=0
       OR position('fn_preplan_aggregate_target_committed_qty(NEW.target_analysis_material_id)+NEW.qty>fn_preplan_aggregate_material_capacity(target_material.id)' IN definition)=0 THEN
        RAISE EXCEPTION 'V728 exact aggregate identity or quantity guards are missing';
    END IF;
    EXECUTE definition;
END $deep_alias_delegation$;
