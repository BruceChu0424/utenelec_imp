-- Additional actual-output plans share material only through the immutable,
-- approved V700 proof. This creates no material demand, DRAW, ISSUE or consumption.
CREATE OR REPLACE FUNCTION fn_production_material_usage_source_segments(p_target UUID)
RETURNS TABLE(segment_id UUID) LANGUAGE sql STABLE AS $$
    WITH RECURSIVE targets(id) AS (
        SELECT p_target
        UNION
        SELECT proof.source_execution_segment_id
        FROM targets target JOIN production_actual_output_supplement_proofs proof
          ON proof.supplement_execution_segment_id=target.id
        WHERE NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id)
    )
    SELECT target.id FROM targets scope JOIN production_execution_segments target ON target.id=scope.id
    WHERE NOT target.is_deleted AND EXISTS(
        SELECT 1 FROM production_material_demands demand
        JOIN production_material_stock_postings issue ON issue.demand_id=demand.id AND issue.posting_type='ISSUE'
        WHERE demand.execution_segment_id=target.id AND NOT demand.is_deleted)
    UNION
    SELECT source.id FROM targets scope JOIN production_execution_segments target ON target.id=scope.id
    CROSS JOIN LATERAL jsonb_array_elements(target.split_material_snapshot) requirement
    JOIN production_material_demands demand ON demand.split_root_demand_id=(requirement->>'rootDemandId')::uuid
        AND NOT demand.is_deleted
    JOIN production_execution_segments source ON source.id=demand.execution_segment_id
        AND source.split_root_segment_id=target.split_root_segment_id
        AND source.split_start_qty+COALESCE(source.material_snapshot_product_qty,source.planned_qty)<=target.split_start_qty
        AND source.status NOT IN('CANCELLED','REVERSED') AND NOT source.is_deleted
    JOIN production_material_stock_postings issue ON issue.demand_id=demand.id AND issue.posting_type='ISSUE'
    WHERE NOT target.is_deleted AND target.source_segment_id IS NOT NULL
        AND (requirement->>'requiresPrior')::boolean
$$;

CREATE OR REPLACE FUNCTION fn_production_execution_cost_scope(p_segment UUID) RETURNS UUID
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE lineage AS (
        SELECT segment.id,segment.source_segment_id,segment.split_root_segment_id,ARRAY[segment.id] AS visited
        FROM production_execution_segments segment WHERE segment.id=p_segment
        UNION ALL
        SELECT parent.id,parent.source_segment_id,parent.split_root_segment_id,child.visited||parent.id
        FROM lineage child
        CROSS JOIN LATERAL (
            SELECT proof.source_segment_id AS id FROM production_execution_segment_splits proof
            WHERE proof.source_segment_id=child.source_segment_id
              AND child.id IN(proof.batch_segment_id,proof.remaining_segment_id)
            UNION ALL
            SELECT proof.source_execution_segment_id FROM production_actual_output_supplement_proofs proof
            WHERE proof.supplement_execution_segment_id=child.id
        ) edge
        JOIN production_execution_segments parent ON parent.id=edge.id
        WHERE NOT parent.id=ANY(child.visited)
    ), roots AS (
        SELECT DISTINCT root.id FROM lineage root
        WHERE root.source_segment_id IS NULL AND root.split_root_segment_id IS NULL
          AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof
                         WHERE proof.supplement_execution_segment_id=root.id)
    )
    SELECT CASE WHEN COUNT(*)=1 THEN MIN(id::text)::uuid END FROM roots
$$;

CREATE FUNCTION fn_production_execution_cost_members(p_scope UUID)
RETURNS TABLE(segment_id UUID) LANGUAGE sql STABLE AS $$
    WITH RECURSIVE family(id) AS (
        SELECT p_scope
        UNION
        SELECT edge.id FROM family parent
        CROSS JOIN LATERAL (
            SELECT child.id FROM production_execution_segment_splits proof
            JOIN production_execution_segments child ON child.id IN(proof.batch_segment_id,proof.remaining_segment_id)
              AND child.source_segment_id=proof.source_segment_id
            WHERE proof.source_segment_id=parent.id
            UNION
            SELECT proof.supplement_execution_segment_id FROM production_actual_output_supplement_proofs proof
            WHERE proof.source_execution_segment_id=parent.id
        ) edge
    )
    SELECT id FROM family WHERE fn_production_execution_cost_scope(id)=p_scope
$$;

CREATE OR REPLACE FUNCTION fn_production_execution_cost_target(p_scope UUID) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM((CASE WHEN EXISTS(SELECT 1 FROM production_execution_segment_splits retired
                        WHERE retired.source_segment_id=member.id)
                        OR EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof
                            JOIN production_actual_output_supplement_reversals reversed ON reversed.proof_id=proof.id
                            WHERE proof.supplement_execution_segment_id=member.id)
                        THEN 0 ELSE member.planned_qty END
                    + fn_execution_actual_surplus_qty(member.id,FALSE))*member.product_unit_rate),0)
    FROM fn_production_execution_cost_members(p_scope) family
    JOIN production_execution_segments member ON member.id=family.segment_id
$$;

CREATE FUNCTION fn_actual_supplement_material_ready(p_segment UUID) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE AS $$
DECLARE proven_source UUID; source_mode TEXT;
BEGIN
    SELECT proof.source_execution_segment_id,source.material_requirement_mode INTO proven_source,source_mode
    FROM production_actual_output_supplement_proofs proof
    JOIN production_execution_segments source ON source.id=proof.source_execution_segment_id
    WHERE proof.supplement_execution_segment_id=p_segment
      AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id);
    IF NOT FOUND OR fn_production_execution_cost_scope(p_segment) IS NULL THEN RETURN FALSE; END IF;
    IF source_mode<>'ZERO_MATERIAL' AND COALESCE(fn_execution_material_output_capacity(proven_source,TRUE),0)<=0 THEN RETURN FALSE; END IF;
    RETURN EXISTS(
        SELECT 1 FROM production_actual_output_supplement_proofs proof
        JOIN production_execution_segments target ON target.id=proof.supplement_execution_segment_id
        JOIN production_execution_segments source ON source.id=proof.source_execution_segment_id
        JOIN production_planning_packages source_package ON source_package.id=source.package_id
        JOIN production_plans source_plan ON source_plan.id=source.plan_id
        JOIN production_planning_packages target_package ON target_package.id=target.package_id
        JOIN production_plans target_plan ON target_plan.id=target.plan_id
        WHERE target.id=p_segment AND target.plan_id=proof.supplement_plan_id
          AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id)
          AND target.source_plan_item_id=proof.supplement_plan_item_id AND target.planned_qty=proof.supplement_qty
          AND NOT target.is_deleted AND NOT source.is_deleted
          AND source.status IN('IN_PROGRESS','COMPLETED')
          AND source_plan.status=1 AND NOT source_plan.is_deleted AND NOT source_plan.is_stopped AND NOT source_plan.is_canceled
          AND target_plan.status=1 AND NOT target_plan.is_deleted AND NOT target_plan.is_stopped AND NOT target_plan.is_canceled
          AND source_package.status='CONFIRMED' AND NOT source_package.is_deleted
          AND target_package.status='CONFIRMED' AND NOT target_package.is_deleted
          AND (source.product_goods_id,source.product_color_id,source.product_unit_id,source.product_unit_rate,
               source.bom_fingerprint,source.workshop_department_id)
              IS NOT DISTINCT FROM
              (target.product_goods_id,target.product_color_id,target.product_unit_id,target.product_unit_rate,
               target.bom_fingerprint,target.workshop_department_id)
          AND fn_execution_material_custody_valid(target.id)
          AND (source.material_requirement_mode='ZERO_MATERIAL'
               OR (
                   EXISTS(SELECT 1 FROM fn_production_material_usage_source_segments(target.id) material_source
                       JOIN production_material_demands demand ON demand.execution_segment_id=material_source.segment_id
                       JOIN production_material_stock_postings issue ON issue.demand_id=demand.id AND issue.posting_type='ISSUE'
                       WHERE NOT demand.is_deleted AND fn_material_issue_available(issue.id,NULL)>0)
                   OR EXISTS(SELECT 1 FROM production_daily_report_items output
                       JOIN production_daily_reports report ON report.id=output.report_id AND report.status=1 AND NOT report.is_deleted
                       JOIN production_material_settlement_events event ON event.daily_report_id=report.id AND event.event_type='POST'
                       JOIN production_material_settlement_postings posting ON posting.event_id=event.id AND posting.settlement_type='CONSUMED'
                       JOIN production_material_demands demand ON demand.id=posting.demand_id
                       WHERE output.execution_segment_id=target.id AND NOT output.is_deleted
                         AND posting.qty_base>COALESCE((SELECT SUM(reversed.qty_base) FROM production_material_settlement_postings reversed
                                                       WHERE reversed.source_posting_id=posting.id),0)
                         AND demand.execution_segment_id IN(SELECT segment_id FROM fn_production_material_usage_source_segments(target.id)))
               ))
          AND NOT EXISTS(SELECT 1 FROM production_material_demands own
                         WHERE own.execution_segment_id=target.id AND NOT own.is_deleted)
          AND NOT EXISTS(SELECT 1 FROM production_planning_package_documents own
                         WHERE own.execution_segment_id=target.id AND own.document_type='DRAW')
    );
END;
$$;

CREATE FUNCTION fn_assert_actual_supplement_segment_integrity(p_segment UUID) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE target production_execution_segments%ROWTYPE; source production_execution_segments%ROWTYPE;
        proof production_actual_output_supplement_proofs%ROWTYPE;
BEGIN
    SELECT * INTO target FROM production_execution_segments WHERE id=p_segment AND NOT is_deleted;
    IF NOT FOUND THEN RETURN; END IF;
    IF NOT EXISTS(SELECT 1 FROM production_planning_packages WHERE id=target.package_id AND status='CONFIRMED' AND NOT is_deleted) THEN RETURN; END IF;
    SELECT * INTO proof FROM production_actual_output_supplement_proofs WHERE supplement_execution_segment_id=p_segment;
    SELECT * INTO source FROM production_execution_segments WHERE id=proof.source_execution_segment_id;
    IF proof.id IS NULL OR target.plan_id<>proof.supplement_plan_id OR target.source_plan_item_id<>proof.supplement_plan_item_id
        OR target.planned_qty<>proof.supplement_qty OR target.source_segment_id IS NOT NULL
        OR target.split_root_segment_id IS NOT NULL OR target.status IN('CANCELLED','REVERSED')
        OR target.material_requirement_mode IS DISTINCT FROM source.material_requirement_mode
        OR (source.product_goods_id,source.product_color_id,source.product_unit_id,source.product_unit_rate,
            source.bom_fingerprint,source.workshop_department_id)
            IS DISTINCT FROM (target.product_goods_id,target.product_color_id,target.product_unit_id,target.product_unit_rate,
            target.bom_fingerprint,target.workshop_department_id)
        OR (target.zero_material_reason,target.zero_material_analysis_id,target.zero_material_exception_reason,target.zero_material_authorized_by)
            IS DISTINCT FROM (source.zero_material_reason,source.zero_material_analysis_id,source.zero_material_exception_reason,source.zero_material_authorized_by)
        OR EXISTS(SELECT 1 FROM production_material_demands WHERE execution_segment_id=p_segment AND NOT is_deleted)
        OR EXISTS(SELECT 1 FROM production_planning_package_documents WHERE execution_segment_id=p_segment AND document_type='DRAW')
        OR EXISTS(SELECT 1 FROM execution_segment_sales_allocations WHERE execution_segment_id=p_segment) THEN
        RAISE EXCEPTION 'Additional actual output requires its exact approved public plan and shared material proof'
            USING ERRCODE='23514',CONSTRAINT='actual_supplement_segment_identity_guard';
    END IF;
    IF target.status IN('READY','DISPATCHED','IN_PROGRESS','COMPLETED') AND NOT fn_actual_supplement_material_ready(p_segment) THEN
        RAISE EXCEPTION 'Additional actual output has no valid original workshop material backing'
            USING ERRCODE='23514',CONSTRAINT='actual_supplement_material_guard';
    END IF;
    IF target.status='COMPLETED' AND NOT fn_actual_supplement_material_cleared(p_segment) THEN
        RAISE EXCEPTION 'Additional production cannot complete before its proven shared material is cleared'
            USING ERRCODE='23514',CONSTRAINT='actual_supplement_shared_clearance_guard';
    END IF;
END;
$$;

CREATE FUNCTION fn_actual_supplement_material_cleared(p_segment UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof
        WHERE proof.supplement_execution_segment_id=p_segment
          AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id))
      AND NOT EXISTS(SELECT 1 FROM fn_production_material_usage_source_segments(p_segment) source
          JOIN production_material_demands demand ON demand.execution_segment_id=source.segment_id
          LEFT JOIN v_production_material_clearance clearance ON clearance.demand_id=demand.id
          WHERE NOT demand.is_deleted AND demand.status NOT IN('RELEASED','REVERSED')
            AND NOT COALESCE(clearance.can_close,FALSE))
$$;

CREATE FUNCTION fn_assert_actual_supplement_proof_material_identity() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM production_execution_segments target
        JOIN production_planning_packages package ON package.id=target.package_id AND package.status='CONFIRMED' AND NOT package.is_deleted
        JOIN production_plans plan ON plan.id=target.plan_id AND plan.status=1 AND NOT plan.is_deleted
        JOIN production_plan_items item ON item.id=target.source_plan_item_id AND item.plan_id=plan.id AND NOT item.is_deleted
        WHERE target.id=NEW.supplement_execution_segment_id AND NOT target.is_deleted
          AND plan.id=NEW.supplement_plan_id AND item.id=NEW.supplement_plan_item_id
          AND item.qty=NEW.supplement_qty AND target.planned_qty=NEW.supplement_qty
          AND fn_production_execution_cost_scope(target.id) IS NOT NULL
          AND fn_production_execution_cost_scope(target.id)=fn_production_execution_cost_scope(NEW.source_execution_segment_id)) THEN
        RAISE EXCEPTION 'Actual-output supplement proof requires its independently approved exact plan and package'
            USING ERRCODE='23514',CONSTRAINT='actual_supplement_approved_plan_guard';
    END IF;
    PERFORM fn_assert_actual_supplement_segment_integrity(NEW.supplement_execution_segment_id);
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_actual_supplement_proof_material_identity AFTER INSERT ON production_actual_output_supplement_proofs
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_actual_supplement_proof_material_identity();

DO $guard_extensions$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_execution_segment_requirement_shape()'::regprocedure) INTO definition;
    needle := E'BEGIN\n';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V701 frozen zero-material evidence anchor changed'; END IF;
    EXECUTE replace(definition,needle,needle||'
    IF TG_OP=''INSERT'' AND NEW.material_requirement_mode=''ZERO_MATERIAL'' AND NEW.status=''READY''
       AND EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof
           JOIN production_execution_segments source ON source.id=proof.source_execution_segment_id
           JOIN production_planning_packages package ON package.id=source.package_id AND package.status=''CONFIRMED'' AND NOT package.is_deleted
           WHERE proof.supplement_execution_segment_id=NEW.id AND proof.supplement_plan_id=NEW.plan_id
             AND proof.supplement_plan_item_id=NEW.source_plan_item_id AND proof.supplement_qty=NEW.planned_qty
             AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id)
             AND NOT source.is_deleted AND source.status IN(''IN_PROGRESS'',''COMPLETED'')
             AND source.material_requirement_mode=''ZERO_MATERIAL''
             AND (NEW.product_goods_id,NEW.product_color_id,NEW.product_unit_id,NEW.product_unit_rate,NEW.bom_fingerprint,
                  NEW.workshop_department_id,NEW.zero_material_reason,NEW.zero_material_analysis_id,
                  NEW.zero_material_exception_reason,NEW.zero_material_authorized_by)
                 IS NOT DISTINCT FROM
                 (source.product_goods_id,source.product_color_id,source.product_unit_id,source.product_unit_rate,source.bom_fingerprint,
                  source.workshop_department_id,source.zero_material_reason,source.zero_material_analysis_id,
                  source.zero_material_exception_reason,source.zero_material_authorized_by)) THEN
        RETURN NEW;
    END IF;
');
    SELECT pg_get_functiondef('fn_assert_execution_segment_integrity(uuid)'::regprocedure) INTO definition;
    needle := 'IF EXISTS(SELECT 1 FROM production_execution_segment_splits WHERE source_segment_id=p_segment_id) THEN';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V701 execution integrity anchor changed'; END IF;
    EXECUTE replace(definition,needle,
        'IF EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs WHERE supplement_execution_segment_id=p_segment_id) THEN
            PERFORM fn_assert_actual_supplement_segment_integrity(p_segment_id); RETURN;
        END IF;
    '||needle);
    SELECT pg_get_functiondef('fn_execution_material_output_capacity(uuid,boolean)'::regprocedure) INTO definition;
    needle := 'WHEN segment.material_requirement_mode=''ZERO_MATERIAL'' THEN segment.planned_qty';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V701 material output capacity anchor changed'; END IF;
    EXECUTE replace(definition,needle,
        'WHEN EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof WHERE proof.supplement_execution_segment_id=segment.id)
                    THEN CASE WHEN fn_actual_supplement_material_ready(segment.id) THEN segment.planned_qty ELSE 0 END
                '||needle);
    SELECT pg_get_functiondef('fn_guard_cost_business_refresh_source()'::regprocedure) INTO definition;
    needle := 'OR EXISTS(SELECT 1 FROM production_daily_reports report';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V701 cost refresh source anchor changed'; END IF;
    EXECUTE replace(definition,needle,
        'OR EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof
            WHERE proof.id=NEW.business_refresh_event_id AND proof.created_by=NEW.business_refresh_actor_id
              AND fn_production_execution_cost_scope(proof.source_execution_segment_id)=NEW.execution_segment_id)
        OR EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed
            JOIN production_actual_output_supplement_proofs proof ON proof.id=reversed.proof_id
            WHERE reversed.id=NEW.business_refresh_event_id AND reversed.created_by=NEW.business_refresh_actor_id
              AND fn_production_execution_cost_scope(proof.source_execution_segment_id)=NEW.execution_segment_id)
        '||needle);

    SELECT pg_get_functiondef('fn_reconcile_execution_segment_completion(uuid)'::regprocedure) INTO definition;
    needle := 'IF v_status = ''COMPLETED'' THEN';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V701 shared completion anchor changed'; END IF;
    EXECUTE replace(definition,needle,
        'IF EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof WHERE proof.supplement_execution_segment_id=p_segment_id) THEN
            v_clear := v_clear AND fn_actual_supplement_material_cleared(p_segment_id);
        END IF;
    '||needle);

    SELECT pg_get_functiondef('fn_guard_production_plan_material_close()'::regprocedure) INTO definition;
    needle := 'AND segment.material_requirement_mode = ''DEMANDED''';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V701 shared plan close anchor changed'; END IF;
    EXECUTE replace(definition,needle,needle||'
                         AND NOT fn_actual_supplement_material_cleared(segment.id)');

    SELECT pg_get_functiondef('fn_reconcile_segment_from_material_posting()'::regprocedure) INTO definition;
    needle := 'PERFORM fn_reconcile_execution_segment_completion(v_segment_id);';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V701 material completion propagation anchor changed'; END IF;
    EXECUTE replace(definition,needle,needle||'
        PERFORM fn_reconcile_actual_supplements_from_source(v_segment_id);');

    SELECT pg_get_functiondef('fn_is_material_completion_reopen_authorized(uuid,bigint)'::regprocedure) INTO definition;
    needle := 'segment.plan_id=settlement.plan_id AND segment.id=p_segment';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V701 material reopening source anchor changed'; END IF;
    EXECUTE replace(definition,needle,
        'segment.id=p_segment AND (segment.plan_id=settlement.plan_id OR EXISTS(
            SELECT 1 FROM fn_production_material_usage_source_segments(p_segment) shared
            JOIN production_execution_segments original ON original.id=shared.segment_id WHERE original.plan_id=settlement.plan_id))');
    SELECT pg_get_functiondef('fn_check_material_completion_reopen()'::regprocedure) INTO definition;
    needle := 'demand.execution_segment_id=NEW.execution_segment_id';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V701 material reopening exact posting anchor changed'; END IF;
    EXECUTE replace(definition,needle,
        '(demand.execution_segment_id=NEW.execution_segment_id OR demand.execution_segment_id IN(
            SELECT segment_id FROM fn_production_material_usage_source_segments(NEW.execution_segment_id)))');
END;
$guard_extensions$;

CREATE FUNCTION fn_reconcile_actual_supplements_from_source(p_source UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE target UUID;
BEGIN
    FOR target IN SELECT proof.supplement_execution_segment_id FROM production_actual_output_supplement_proofs proof
        WHERE NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id)
          AND p_source IN(SELECT segment_id FROM fn_production_material_usage_source_segments(proof.supplement_execution_segment_id))
        ORDER BY proof.supplement_execution_segment_id
    LOOP PERFORM fn_reconcile_execution_segment_completion(target); END LOOP;
END;
$$;

CREATE FUNCTION fn_queue_actual_supplement_cost_target() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE proof production_actual_output_supplement_proofs%ROWTYPE;
BEGIN
    IF TG_TABLE_NAME='production_actual_output_supplement_proofs' THEN proof:=NEW;
    ELSE
        SELECT * INTO proof FROM production_actual_output_supplement_proofs WHERE id=NEW.proof_id;
        IF EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs dependent
            WHERE dependent.source_execution_segment_id=proof.supplement_execution_segment_id
              AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=dependent.id)) THEN
            RAISE EXCEPTION 'Reverse dependent additional production plans before their original shared-material proof'
                USING ERRCODE='23514',CONSTRAINT='actual_supplement_active_dependents_guard';
        END IF;
    END IF;
    UPDATE stock_value_production_cost_objects
    SET business_refresh_event_id=NEW.id,business_refresh_actor_id=NEW.created_by,business_refresh_pending=TRUE
    WHERE execution_segment_id=fn_production_execution_cost_scope(proof.source_execution_segment_id)
      AND source_kind='PRODUCTION_EXECUTION';
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_actual_supplement_cost_target AFTER INSERT ON production_actual_output_supplement_proofs
    FOR EACH ROW EXECUTE FUNCTION fn_queue_actual_supplement_cost_target();
CREATE TRIGGER trg_actual_supplement_reversed_cost_target AFTER INSERT ON production_actual_output_supplement_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_queue_actual_supplement_cost_target();

-- Resolve one task before invoking another task's capacity. SQL WHERE/AND
-- evaluation order is not an execution barrier: an inlined CASE over the whole
-- segment relation could evaluate a sibling supplement before filtering its id.
CREATE OR REPLACE FUNCTION fn_execution_material_output_capacity(p_segment UUID,p_issued_only BOOLEAN DEFAULT TRUE)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE segment production_execution_segments%ROWTYPE; result NUMERIC;
BEGIN
    SELECT * INTO segment FROM production_execution_segments WHERE id=p_segment AND NOT is_deleted;
    IF NOT FOUND THEN RETURN 0; END IF;
    IF NOT fn_execution_material_custody_valid(segment.id) THEN RETURN 0; END IF;
    IF EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof WHERE proof.supplement_execution_segment_id=segment.id) THEN
        IF fn_actual_supplement_material_ready(segment.id) THEN RETURN segment.planned_qty; END IF;
        RETURN 0;
    END IF;
    IF segment.material_requirement_mode='ZERO_MATERIAL' OR fn_split_batch_empty_issued(segment.id) THEN RETURN segment.planned_qty; END IF;
    SELECT MIN(fn_demand_material_output_capacity(demand.id,
        CASE WHEN p_issued_only THEN fn_execution_material_net_issued_qty(demand.id)
             ELSE COALESCE((SELECT SUM(reservation.qty-reservation.released_qty) FROM stock_reservations reservation
                 WHERE reservation.demand_id=demand.id AND NOT reservation.is_deleted),0) END)) INTO result
    FROM production_material_demands demand
    WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted
      AND demand.status NOT IN('RELEASED','REVERSED');
    RETURN COALESCE(result,0);
END;
$$;
