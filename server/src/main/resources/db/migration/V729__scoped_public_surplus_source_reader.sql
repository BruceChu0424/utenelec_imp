-- Keep one canonical quantity/claim/ETA definition. Materializing the old source
-- CTE before the caller's analysis predicate evaluated every unrelated public
-- source. NOT MATERIALIZED still left capacity and ETA ahead of that predicate.
-- Scope only the source identities; all existing capacity and ownership rules stay.
DO $scoped_public_sources$
DECLARE definition TEXT; source_anchor TEXT; claim_anchor TEXT; columns_definition TEXT;
BEGIN
    SELECT rtrim(pg_get_viewdef('v_preplan_public_surplus_source_state'::regclass,true),E';\n\r ')
      INTO definition;
    source_anchor := 'WHERE action.operation_type = ''SUPPLY''::text';
    claim_anchor := 'WHERE claim_1.operation_type = ''SHARED_FUTURE_CLAIM''::text';
    IF (length(definition)-length(replace(definition,source_anchor,'')))/length(source_anchor)<>1
       OR (length(definition)-length(replace(definition,claim_anchor,'')))/length(claim_anchor)<>1
       OR position('fn_preplan_public_source_planning_capacity' IN definition)=0
       OR position('fn_preplan_public_source_planning_open_qty' IN definition)=0
       OR position('fn_procurement_order_source_pending_qty' IN definition)=0 THEN
        RAISE EXCEPTION 'V729 canonical public-source view contract changed';
    END IF;
    definition := replace(definition,source_anchor,$source_scope$
        WHERE (p_target_analysis IS NULL OR EXISTS (
            SELECT 1 FROM production_material_analyses target_analysis
            JOIN production_material_analysis_materials target_material
              ON target_material.analysis_id=target_analysis.id AND target_material.active
            WHERE target_analysis.id=p_target_analysis AND NOT target_analysis.is_deleted
              AND fn_warehouse_same_main(target_analysis.warehouse_id,action.warehouse_id)
              AND target_material.goods_id=action.goods_id
              AND target_material.color_id IS NOT DISTINCT FROM action.color_id
              AND target_material.unit_id=action.unit_id))
          AND action.operation_type = 'SUPPLY'::text
    $source_scope$);
    -- Restrict whole claim actions by their source, never individual allocations:
    -- min(external_item_id)/item_count=1 must retain the original ambiguity guard.
    definition := replace(definition,claim_anchor,$claim_scope$
        WHERE EXISTS (SELECT 1 FROM source scoped_source
                      WHERE scoped_source.id=claim_1.claim_source_action_id)
          AND claim_1.operation_type = 'SHARED_FUTURE_CLAIM'::text
    $claim_scope$);
    SELECT string_agg(format('%I %s',attname,format_type(atttypid,atttypmod)),', ' ORDER BY attnum)
      INTO columns_definition
    FROM pg_attribute WHERE attrelid='v_preplan_public_surplus_source_state'::regclass
      AND attnum>0 AND NOT attisdropped;
    EXECUTE format('CREATE FUNCTION fn_preplan_public_surplus_sources(p_target_analysis UUID DEFAULT NULL)
        RETURNS TABLE (%s) LANGUAGE sql STABLE AS %L',columns_definition,definition);
    -- The public view is a compatibility wrapper, not a second quantity algorithm.
    EXECUTE 'CREATE OR REPLACE VIEW v_preplan_public_surplus_source_state AS
        SELECT * FROM fn_preplan_public_surplus_sources(NULL::uuid)';
END;
$scoped_public_sources$;

COMMENT ON FUNCTION fn_preplan_public_surplus_sources(UUID) IS
    'Canonical public supply state. Optional target analysis narrows same-main goods/color/unit identities before capacity, claims and ETA evaluation; NULL preserves the original unscoped view.';
