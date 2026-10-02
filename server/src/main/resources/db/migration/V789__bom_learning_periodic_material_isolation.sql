-- ADR-129 / ADR-131: keep ORDER learning independent from PERIODIC recipes.
-- Forward-only repair; historical physical observations remain auditable.

-- V739 predates PERIODIC materials. A manually weighed PERIODIC edge is not an
-- ORDER recipe, and a prior ORDER observation must never create a hard-gated
-- PERIODIC edge. Patch exact anchors and fail on drift rather than replacing
-- an unexpected function body or editing an applied migration.
DO $repair_publisher$
DECLARE definition TEXT; anchor TEXT; replacement TEXT;
BEGIN
    definition := replace(pg_get_functiondef('fn_publish_learned_bom(uuid,boolean)'::regprocedure),chr(13),'');
    anchor := $old$WHERE learned.goods_id=p_goods AND learned.learning_profile_goods_id=p_goods AND NOT learned.is_deleted$old$;
    replacement := anchor || $new$
                 AND EXISTS(SELECT 1 FROM goods material WHERE material.id=learned.component_goods_id
                            AND material.issue_method='ORDER')$new$;
    anchor := replace(anchor,chr(13),'');
    replacement := replace(replacement,chr(13),'');
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V789 publisher learned-edge synchronization anchor changed';
    END IF;
    definition := replace(definition,anchor,replacement);

    anchor := $old$IF p_create AND NOT EXISTS(SELECT 1 FROM goods_bom_items WHERE goods_id=p_goods AND NOT is_deleted
            AND learning_profile_goods_id IS NULL) THEN$old$;
    replacement := $new$IF p_create AND NOT EXISTS(SELECT 1 FROM goods_bom_items manual
            JOIN goods material ON material.id=manual.component_goods_id
            WHERE manual.goods_id=p_goods AND NOT manual.is_deleted
              AND manual.learning_profile_goods_id IS NULL AND material.issue_method='ORDER') THEN$new$;
    anchor := replace(anchor,chr(13),'');
    replacement := replace(replacement,chr(13),'');
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V789 publisher manual ORDER ownership anchor changed';
    END IF;
    definition := replace(definition,anchor,replacement);

    anchor := $old$WHERE usage.goods_id=p_goods AND usage.actual_status='ACTUAL'$old$;
    replacement := anchor || $new$
          AND EXISTS(SELECT 1 FROM goods material WHERE material.id=usage.component_goods_id
                     AND material.issue_method='ORDER')$new$;
    anchor := replace(anchor,chr(13),'');
    replacement := replace(replacement,chr(13),'');
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V789 publisher current ORDER candidate anchor changed';
    END IF;
    definition := replace(definition,anchor,replacement);

    -- Recheck after taking candidate references: switching the issue method can
    -- have completed while the initial candidate query waited for those locks.
    anchor := $old$component.is_deleted OR component.auto_created$old$;
    replacement := anchor || $new$ OR component.issue_method<>'ORDER'$new$;
    anchor := replace(anchor,chr(13),'');
    replacement := replace(replacement,chr(13),'');
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V789 publisher locked material identity anchor changed';
    END IF;
    definition := replace(definition,anchor,replacement);
    EXECUTE definition;
END;
$repair_publisher$;

-- The lock admission and the publisher must agree about manual ownership.
-- Keep the established parent-row -> family -> parent-learning -> graph order.
DO $repair_queue$
DECLARE definition TEXT; anchor TEXT; replacement TEXT;
BEGIN
    definition := replace(pg_get_functiondef('fn_drain_bom_learning_queue()'::regprocedure),chr(13),'');
    anchor := $old$AND edge.learning_profile_goods_id IS NULL))$old$;
    replacement := $new$AND edge.learning_profile_goods_id IS NULL
                       AND EXISTS(SELECT 1 FROM goods material
                                  WHERE material.id=edge.component_goods_id AND material.issue_method='ORDER')))$new$;
    anchor := replace(anchor,chr(13),'');
    replacement := replace(replacement,chr(13),'');
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V789 queue manual ORDER ownership anchor changed';
    END IF;
    EXECUTE replace(definition,anchor,replacement);
END;
$repair_queue$;

-- One date/segment binding definition for repair proof and retained zero bounds.
-- Later PERIODIC output must not mask a reversal of earlier ORDER output.
CREATE OR REPLACE FUNCTION fn_bom_learning_uncovered_output(p_family UUID[], p_material UUID, p_unit UUID)
RETURNS TABLE(uncovered_output_qty NUMERIC, uncovered_defect_qty NUMERIC, total_output_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH outputs AS (
        SELECT item.qty*item.unit_rate AS output_qty, item.defect_qty*item.unit_rate AS defect_qty,
               EXISTS(SELECT 1 FROM production_execution_periodic_materials periodic
                      WHERE periodic.execution_segment_id=item.execution_segment_id
                        AND periodic.material_goods_id=p_material AND periodic.unit_id=p_unit
                        AND report.bill_date>=periodic.effective_from
                        AND report.bill_date<=COALESCE(periodic.effective_to,'infinity'::date)) AS covered
        FROM production_daily_report_items item
        JOIN production_daily_reports report ON report.id=item.report_id
        WHERE item.execution_segment_id=ANY(p_family) AND item.qty>0
          AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted
          AND item.fqc_recovery_authorization_id IS NULL
    )
    SELECT COALESCE(sum(output_qty) FILTER(WHERE NOT covered),0),
           COALESCE(sum(defect_qty) FILTER(WHERE NOT covered),0),COALESCE(sum(output_qty),0)
    FROM outputs
$$;
CREATE OR REPLACE FUNCTION fn_bom_learning_periodic_exposure_is_proven(p_family UUID[], p_material UUID, p_unit UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT total_output_qty>0 AND uncovered_output_qty=0
    FROM fn_bom_learning_uncovered_output(p_family,p_material,p_unit)
$$;

-- A discovery family's missing ORDER material means zero ORDER consumption.
-- A missing PERIODIC material means it came from another physical ledger; its
-- production cannot dilute a prior ORDER observation. Real legacy demands are
-- still read above these anchors, including their subsequent reversal/return.
DO $repair_exposure$
DECLARE definition TEXT; anchor TEXT; replacement TEXT;
BEGIN
    definition := replace(pg_get_functiondef('fn_refresh_bom_learning(uuid,boolean)'::regprocedure),chr(13),'');
    anchor := $old$WHERE usage.goods_id=root.product_goods_id AND usage.output_unit_id=parent.unit_id
                  AND NOT facts ? (usage.component_goods_id::text||'|'||usage.unit_id::text)$old$;
    replacement := $new$WHERE usage.goods_id=root.product_goods_id AND usage.output_unit_id=parent.unit_id
                  AND EXISTS(SELECT 1 FROM goods material WHERE material.id=usage.component_goods_id
                             AND material.issue_method='ORDER')
                  AND NOT facts ? (usage.component_goods_id::text||'|'||usage.unit_id::text)$new$;
    anchor := replace(anchor,chr(13),'');
    replacement := replace(replacement,chr(13),'');
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V789 discovery zero exposure anchor changed';
    END IF;
    definition := replace(definition,anchor,replacement);

    -- Earlier discovery batches may legitimately have used zero of an optional
    -- ORDER material before it switched modes. Keep that old observation unless
    -- the family's exact periodic binding proves that this was PERIODIC use.
    -- It keeps its original exposure; subsequent output adds no new zero use.
    anchor := $old$AND NOT facts ? (usage.component_goods_id::text||'|'||usage.unit_id::text)),'[]'::jsonb);$old$;
    replacement := anchor || $new$
            FOR fact_key, old_entry IN SELECT key,value FROM jsonb_each(old_entries) ORDER BY key LOOP
                IF (old_entry->>'qty')::numeric=0 AND NOT facts ? fact_key
                   AND EXISTS(SELECT 1 FROM goods material
                              WHERE material.id=(old_entry->>'goodsId')::uuid AND material.issue_method='PERIODIC') THEN
                    SELECT CASE WHEN bound.uncovered_output_qty>0 THEN old_entry||jsonb_build_object(
                        'exposure',LEAST((old_entry->>'exposure')::numeric,bound.uncovered_output_qty),
                        'defect',LEAST(COALESCE((old_entry->>'defect')::numeric,0),bound.uncovered_defect_qty)) END
                    INTO fact FROM fn_bom_learning_uncovered_output(family,
                        (old_entry->>'goodsId')::uuid,(old_entry->>'unitId')::uuid) bound;
                    IF fact IS NOT NULL THEN entries:=entries||jsonb_build_array(fact); END IF;
                END IF;
            END LOOP;$new$;
    anchor := replace(anchor,chr(13),'');
    replacement := replace(replacement,chr(13),'');
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V789 historical ORDER zero preservation anchor changed';
    END IF;
    definition := replace(definition,anchor,replacement);

    anchor := $old$IF usage_created THEN$old$;
    replacement := $new$IF usage_created AND EXISTS(SELECT 1 FROM goods material
                    WHERE material.id=delta.goods_id AND material.issue_method='ORDER') THEN$new$;
    anchor := replace(anchor,chr(13),'');
    replacement := replace(replacement,chr(13),'');
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V789 discovery retrospective zero exposure anchor changed';
    END IF;
    definition := replace(definition,anchor,replacement);

    -- A previously learned family can have been reopened. Its real settled
    -- contribution stays, but an unsupported PERIODIC zero is disproven even
    -- while it waits for another report or return.
    anchor := $old$fact:=facts->fact_key;
            IF output_qty>=old_output$old$;
    replacement := $new$fact:=facts->fact_key;
            IF fact IS NULL AND (old_entry->>'qty')::numeric=0
               AND EXISTS(SELECT 1 FROM goods material
                          WHERE material.id=(old_entry->>'goodsId')::uuid AND material.issue_method='PERIODIC') THEN
                IF family_state NOT IN('OUTPUT_IDENTITY_CHANGED','NO_APPROVED_OUTPUT') THEN
                    SELECT CASE WHEN bound.uncovered_output_qty>0 THEN old_entry||jsonb_build_object(
                        'exposure',LEAST((old_entry->>'exposure')::numeric,bound.uncovered_output_qty),
                        'defect',LEAST(COALESCE((old_entry->>'defect')::numeric,0),bound.uncovered_defect_qty)) END
                    INTO fact FROM fn_bom_learning_uncovered_output(family,
                        (old_entry->>'goodsId')::uuid,(old_entry->>'unitId')::uuid) bound;
                    IF fact IS NOT NULL THEN entries:=entries||jsonb_build_array(fact); END IF;
                END IF;
                CONTINUE;
            END IF;
            IF output_qty>=old_output$new$;
    anchor := replace(anchor,chr(13),'');
    replacement := replace(replacement,chr(13),'');
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V789 reopened discovery zero exposure anchor changed';
    END IF;
    EXECUTE replace(definition,anchor,replacement);
END;
$repair_exposure$;

-- Repair only samples reached from a current PERIODIC material's existing
-- usage row (component index) and its parent's samples (goods index). A real
-- historical ORDER demand, including a zero-use demand, is never removed.
-- Require dated PERIODIC output and a retained zero exceeding the uncovered
-- output bound. This includes mixed-date families, while current goods settings
-- alone cannot disprove a zero observed before that material switched modes.
-- The normal delta engine keeps each entry's generation and relearn baseline.
DO $repair_zero_samples$
DECLARE affected RECORD;
BEGIN
    FOR affected IN
        SELECT DISTINCT sample.goods_id, sample.execution_root_id
        FROM goods material
        JOIN goods_bom_actual_usages usage ON usage.component_goods_id=material.id
        JOIN production_bom_learning_samples sample ON sample.goods_id=usage.goods_id AND sample.discovery
        CROSS JOIN LATERAL jsonb_array_elements(sample.materials) entry
        CROSS JOIN LATERAL fn_bom_learning_uncovered_output(
            ARRAY(SELECT segment_id FROM fn_production_execution_cost_members(sample.execution_root_id)),
            usage.component_goods_id,usage.unit_id) bound
        WHERE material.issue_method='PERIODIC'
          AND entry->>'goodsId'=usage.component_goods_id::text AND entry->>'unitId'=usage.unit_id::text
          AND (entry->>'qty')::numeric=0
          AND bound.total_output_qty>bound.uncovered_output_qty
          AND ((entry->>'exposure')::numeric>bound.uncovered_output_qty
               OR COALESCE((entry->>'defect')::numeric,0)>bound.uncovered_defect_qty)
          AND NOT EXISTS(
              SELECT 1 FROM fn_production_execution_cost_members(sample.execution_root_id) family
              JOIN production_material_demands demand ON demand.execution_segment_id=family.segment_id
              WHERE demand.goods_id=usage.component_goods_id AND demand.unit_id=usage.unit_id
                AND (NOT demand.is_deleted OR EXISTS(
                    SELECT 1 FROM production_material_stock_postings posting WHERE posting.demand_id=demand.id)))
        ORDER BY sample.goods_id, sample.execution_root_id
    LOOP
        PERFORM fn_enqueue_bom_learning(affected.execution_root_id);
    END LOOP;
END;
$repair_zero_samples$;
SET CONSTRAINTS trg_drain_bom_learning_queue IMMEDIATE;
SET CONSTRAINTS trg_drain_bom_learning_queue DEFERRED;

-- Completed recipes blocked solely by manual PERIODIC weights have already
-- taught their exact ORDER quantities. Publish those missing edges once; no
-- report, demand, material ledger, frozen task or cost posting is rewritten.
DO $publish_completed_mixed_recipes$
DECLARE parent RECORD;
BEGIN
    FOR parent IN
        SELECT goods.id FROM goods
        WHERE EXISTS(SELECT 1 FROM goods_bom_items edge
                     JOIN goods material ON material.id=edge.component_goods_id AND material.issue_method='PERIODIC'
                     WHERE edge.goods_id=goods.id AND NOT edge.is_deleted AND edge.learning_profile_goods_id IS NULL)
          AND NOT EXISTS(SELECT 1 FROM goods_bom_items edge
                         JOIN goods material ON material.id=edge.component_goods_id AND material.issue_method='ORDER'
                         WHERE edge.goods_id=goods.id AND NOT edge.is_deleted AND edge.learning_profile_goods_id IS NULL)
          AND EXISTS(SELECT 1 FROM production_bom_learning_samples sample
                     WHERE sample.goods_id=goods.id AND sample.state='READY' AND sample.fully_cleared)
          AND EXISTS(SELECT 1 FROM v_goods_bom_actual_usage usage
                     JOIN goods material ON material.id=usage.component_goods_id AND material.issue_method='ORDER'
                     WHERE usage.goods_id=goods.id AND usage.actual_status='ACTUAL'
                       AND NOT EXISTS(SELECT 1 FROM goods_bom_items edge
                                      WHERE edge.goods_id=goods.id AND edge.component_goods_id=usage.component_goods_id
                                        AND (NOT edge.is_deleted OR edge.learning_released_at IS NOT NULL)))
        ORDER BY goods.id FOR NO KEY UPDATE
    LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended('bom-learning-parent:'||parent.id::text,0));
        PERFORM fn_publish_learned_bom(parent.id,TRUE);
    END LOOP;
END;
$publish_completed_mixed_recipes$;
