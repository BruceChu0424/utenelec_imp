-- V478 is already applied with Flyway checksum 1310089889. Keep its bytes immutable.
-- Carry the later zero-material correction forward without changing history or business rows.
-- DIRECT_MAKE proves absence of manufacturing BOM edges, not absence of its
-- separate root supply target. Keep plan/item/analysis/unit lineage unchanged.
DO $$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_execution_segment_requirement_shape()'::regprocedure)
      INTO definition;
    IF position('FROM production_material_analysis_materials material' IN definition)=0
       OR position('AND material.active = TRUE' IN definition)=0 THEN
        RAISE EXCEPTION 'V479 zero-material evidence function shape changed';
    END IF;
    definition := replace(definition,'AND material.active = TRUE',
      'AND material.active = TRUE AND material.node_role = ''BOM_COMPONENT''');
    EXECUTE definition;
END;
$$;
