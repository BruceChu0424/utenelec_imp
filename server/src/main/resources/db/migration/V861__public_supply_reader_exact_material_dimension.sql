-- A command for one material must not calculate capacity/receipt/ETA for every
-- other dimension in its analysis. Both APIs retain one canonical quantity body;
-- the compatibility API supplies an unrestricted dimension to that body.
DO $dimension_public_sources$
DECLARE definition TEXT; source_anchor TEXT; columns_definition TEXT;
BEGIN
    SELECT prosrc INTO definition FROM pg_proc
      WHERE oid='fn_preplan_public_surplus_sources(uuid)'::regprocedure;
    source_anchor := 'WHERE (p_target_analysis IS NULL OR EXISTS (';
    IF (length(definition)-length(replace(definition,source_anchor,'')))/length(source_anchor)<>1
       OR position('fn_preplan_public_source_planning_capacity' IN definition)=0
       OR position('fn_preplan_public_source_planning_open_qty' IN definition)=0
       OR position('fn_procurement_order_source_pending_qty' IN definition)=0 THEN
        RAISE EXCEPTION 'V861 canonical public-source reader contract changed';
    END IF;
    definition := replace(definition,source_anchor,$dimension_scope$
        WHERE (p_goods IS NULL OR (action.goods_id=p_goods
          AND action.color_id IS NOT DISTINCT FROM p_color AND action.unit_id=p_unit))
          AND (p_target_analysis IS NULL OR EXISTS (
    $dimension_scope$);
    SELECT string_agg(format('%I %s',attname,format_type(atttypid,atttypmod)),', ' ORDER BY attnum)
      INTO columns_definition
    FROM pg_attribute WHERE attrelid='v_preplan_public_surplus_source_state'::regclass
      AND attnum>0 AND NOT attisdropped;
    EXECUTE format('CREATE FUNCTION fn_preplan_public_surplus_sources(p_target_analysis UUID,p_goods UUID,p_color UUID,p_unit UUID)
        RETURNS TABLE (%s) LANGUAGE sql STABLE AS %L',columns_definition,definition);
    EXECUTE format('CREATE OR REPLACE FUNCTION fn_preplan_public_surplus_sources(p_target_analysis UUID DEFAULT NULL)
        RETURNS TABLE (%s) LANGUAGE sql STABLE AS %L',columns_definition,
        'SELECT * FROM fn_preplan_public_surplus_sources(p_target_analysis,NULL::uuid,NULL::uuid,NULL::uuid)');
END;
$dimension_public_sources$;

COMMENT ON FUNCTION fn_preplan_public_surplus_sources(UUID,UUID,UUID,UUID) IS
    'Canonical current public supply state. Restricts exact goods/color/unit before capacity, claims, receipts and ETA; NULL goods preserves all dimensions.';
COMMENT ON FUNCTION fn_preplan_public_surplus_sources(UUID) IS
    'Compatibility entry point for canonical current public supply state, scoped to all active dimensions of the optional target analysis.';

-- MAKE adoption already knows its exact target material IDs. Carry that scope
-- inside the canonical source selector before evaluating receipt/claim totals.
DO $target_make_sources$
DECLARE definition TEXT; target_anchor TEXT; columns_definition TEXT;
BEGIN
    SELECT prosrc INTO definition FROM pg_proc
      WHERE oid='fn_preplan_make_public_supply_sources(uuid,uuid)'::regprocedure;
    target_anchor := 'WHERE target_analysis.id=p_target_analysis AND NOT target_analysis.is_deleted';
    IF (length(definition)-length(replace(definition,target_anchor,'')))/length(target_anchor)<>1
       OR position('fn_finished_in_is_public_output' IN definition)=0
       OR position('fn_preplan_make_public_claim_pending_qty' IN definition)=0
       OR position('fn_preplan_make_public_produced_qty' IN definition)=0 THEN
        RAISE EXCEPTION 'V861 canonical manufacturing public-source reader contract changed';
    END IF;
    definition := replace(definition,target_anchor,target_anchor||
        ' AND (p_target_materials IS NULL OR target_material.id=ANY(p_target_materials))');
    SELECT string_agg(format('%I %s',attname,format_type(atttypid,atttypmod)),', ' ORDER BY attnum)
      INTO columns_definition
    FROM pg_attribute WHERE attrelid='v_preplan_make_public_supply_state'::regclass
      AND attnum>0 AND NOT attisdropped;
    EXECUTE format('CREATE FUNCTION fn_preplan_make_public_supply_sources(p_target_analysis UUID,p_source_plan_item UUID,p_target_materials UUID[])
        RETURNS TABLE (%s) LANGUAGE sql STABLE AS %L',columns_definition,definition);
    EXECUTE format('CREATE OR REPLACE FUNCTION fn_preplan_make_public_supply_sources(p_target_analysis UUID DEFAULT NULL,p_source_plan_item UUID DEFAULT NULL)
        RETURNS TABLE (%s) LANGUAGE sql STABLE AS %L',columns_definition,
        'SELECT * FROM fn_preplan_make_public_supply_sources(p_target_analysis,p_source_plan_item,NULL::uuid[])');
END;
$target_make_sources$;

COMMENT ON FUNCTION fn_preplan_make_public_supply_sources(UUID,UUID,UUID[]) IS
    'Canonical current manufacturing public supply. Exact target material IDs restrict source dimensions before receipt/claim evaluation; NULL target IDs preserves all dimensions.';
