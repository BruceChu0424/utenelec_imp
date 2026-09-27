-- Scope manufacturing sources before receipt/claim aggregation. The original
-- analysis join materialized unrelated plan sources before filtering. Keep its
-- quantity and ownership expressions authoritative; also bound exact point reads.
DO $scoped_make_sources$
DECLARE definition TEXT; source_anchor TEXT; claim_anchor TEXT; columns_definition TEXT;
        consumer RECORD;
BEGIN
    SELECT rtrim(pg_get_viewdef('v_preplan_make_public_supply_state'::regclass,true),E';\n\r ')
      INTO definition;
    source_anchor := 'WHERE (link.allocation_status';
    claim_anchor := E'FROM preplan_make_public_claims\n';
    IF (length(definition)-length(replace(definition,source_anchor,'')))/length(source_anchor)<>1
       OR (length(definition)-length(replace(definition,claim_anchor,'')))/length(claim_anchor)<>1
       OR position('fn_finished_in_is_public_output' IN definition)=0
       OR position('fn_preplan_make_public_claim_pending_qty' IN definition)=0
       OR position('fn_preplan_make_public_produced_qty' IN definition)=0 THEN
        RAISE EXCEPTION 'V732 canonical manufacturing public-source view contract changed';
    END IF;
    definition := replace(definition,source_anchor,$scope$
        WHERE (p_source_plan_item IS NULL OR item.id=p_source_plan_item)
          AND (p_target_analysis IS NULL OR EXISTS (
            SELECT 1 FROM production_material_analyses target_analysis
            JOIN production_material_analysis_materials target_material
              ON target_material.analysis_id=target_analysis.id AND target_material.active
            WHERE target_analysis.id=p_target_analysis AND NOT target_analysis.is_deleted
              AND fn_warehouse_same_main(target_analysis.warehouse_id,analysis.warehouse_id)
              AND target_material.goods_id=item.goods_id
              AND target_material.color_id IS NOT DISTINCT FROM item.color_id
              AND target_material.unit_id=goods.unit_id))
          AND (link.allocation_status
    $scope$);
    definition := replace(definition,claim_anchor,$claim_scope$
        FROM preplan_make_public_claims
        WHERE EXISTS (SELECT 1 FROM plan_source scoped_source
                      WHERE scoped_source.source_plan_item_id=preplan_make_public_claims.source_plan_item_id)
    $claim_scope$);
    SELECT string_agg(format('%I %s',attname,format_type(atttypid,atttypmod)),', ' ORDER BY attnum)
      INTO columns_definition
    FROM pg_attribute WHERE attrelid='v_preplan_make_public_supply_state'::regclass
      AND attnum>0 AND NOT attisdropped;
    EXECUTE format('CREATE FUNCTION fn_preplan_make_public_supply_sources(
        p_target_analysis UUID DEFAULT NULL,p_source_plan_item UUID DEFAULT NULL)
        RETURNS TABLE (%s) LANGUAGE sql STABLE AS %L',columns_definition,definition);
    EXECUTE 'CREATE OR REPLACE VIEW v_preplan_make_public_supply_state AS
        SELECT * FROM fn_preplan_make_public_supply_sources(NULL::uuid,NULL::uuid)';

    -- Point consumers explicitly scope the source CTE as well, preserving their
    -- narrow reads without depending on predicate pushdown through the wrapper.
    FOR consumer IN SELECT * FROM (VALUES
        ('fn_guard_make_public_claim()',
         'FROM v_preplan_make_public_supply_state WHERE source_plan_item_id=NEW.source_plan_item_id',
         'FROM fn_preplan_make_public_supply_sources(NULL::uuid,NEW.source_plan_item_id)'),
        ('fn_check_make_public_exact_peg(uuid)',
         E'FROM v_preplan_make_public_supply_state\n      WHERE source_plan_item_id=source.id',
         'FROM fn_preplan_make_public_supply_sources(NULL::uuid,source.id)'),
        ('fn_check_make_public_plan_closure()',
         'JOIN v_preplan_make_public_supply_state source ON source.source_plan_item_id=item.id',
         'JOIN LATERAL fn_preplan_make_public_supply_sources(NULL::uuid,item.id) source ON TRUE')
    ) AS consumers(signature,old_sql,new_sql) LOOP
        SELECT pg_get_functiondef(consumer.signature::regprocedure) INTO definition;
        IF (length(definition)-length(replace(definition,consumer.old_sql,'')))/length(consumer.old_sql)<>1 THEN
            RAISE EXCEPTION 'V732 manufacturing point-reader contract changed: %',consumer.signature;
        END IF;
        EXECUTE replace(definition,consumer.old_sql,consumer.new_sql);
    END LOOP;
END;
$scoped_make_sources$;

COMMENT ON FUNCTION fn_preplan_make_public_supply_sources(UUID,UUID) IS
    'Canonical manufacturing public supply. Scope by target analysis dimensions and/or exact source plan item before receipt and claim evaluation; both NULL preserve the original view.';
