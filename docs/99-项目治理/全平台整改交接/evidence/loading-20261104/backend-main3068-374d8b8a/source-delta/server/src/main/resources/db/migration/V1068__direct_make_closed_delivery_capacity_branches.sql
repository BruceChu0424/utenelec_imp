-- V1058 already proves the exact completed direct-MAKE delivery slices. Add
-- them only to the remaining-demand branch. An aggregate alias may preserve a
-- frozen original capacity that already contains this history; adding the same
-- credit to that maximum again would create additional private admission.
-- Keep the original function's unknown-capacity behavior and all V1058 proofs.
-- A cancelled unprocessed issue can restore that same exact MAKE receipt and
-- reissue it. Its new handoff has a RESTORE source event. Retain every existing
-- receipt/plan/physical movement/order/path/held/counter proof, credit only the
-- current actually fulfilled generation, and never change committed V1058.
DO $restored_make$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_preplan_direct_make_delivery_closed_qty(uuid,uuid)'::regprocedure) INTO definition;
    needle:='AND origin.event_type=''ORIGIN_MAKE'' AND origin.stock_reservation_id=';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V1061 exact direct MAKE delivery source anchor changed'; END IF;
    EXECUTE replace(definition,needle,
        'AND origin.event_type IN (''ORIGIN_MAKE'',''RESTORE'') AND origin.stock_reservation_id=');
END $restored_make$;

CREATE OR REPLACE FUNCTION fn_preplan_direct_make_total_capacity(p_child UUID,p_material UUID)
RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN original.qty IS NULL THEN NULL ELSE GREATEST(original.qty,
   COALESCE((SELECT required_qty FROM production_material_analysis_materials WHERE id=p_material),0)
   +COALESCE((SELECT sum(fn_preplan_aggregate_alias_qty(alias.id))
       FROM preplan_aggregate_material_aliases alias WHERE alias.source_material_id=p_material
         AND fn_preplan_aggregate_alias_identity_valid(alias.id)),0)
   +fn_preplan_direct_make_delivery_closed_qty(p_child,p_material)) END
 FROM (SELECT fn_preplan_aggregate_source_capacity(p_material) AS qty) original;
$$;

COMMENT ON FUNCTION fn_preplan_direct_make_total_capacity(UUID,UUID) IS
 'Direct-MAKE cumulative capacity: exact closed slices rebuild only remaining demand; frozen aggregate maxima and unknown capacity keep their original meaning';
