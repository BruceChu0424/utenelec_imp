-- V694/V700/V701 are restored to the byte-for-byte artifacts already applied
-- to the local database. This forward migration carries their later fixes.
-- Keep V702 increment authorization intact while replacing capacity functions.

CREATE OR REPLACE FUNCTION fn_report_has_prior_same_segment_consumption(p_segment UUID,p_current_report UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(
        SELECT 1 FROM production_daily_reports prior
        JOIN production_material_settlement_events event ON event.daily_report_id=prior.id AND event.event_type='POST'
        JOIN production_material_settlement_postings posting ON posting.event_id=event.id AND posting.settlement_type='CONSUMED'
        JOIN production_material_demands demand ON demand.id=posting.demand_id
        WHERE prior.status=1 AND NOT prior.is_deleted AND prior.id<>p_current_report
          AND EXISTS(SELECT 1 FROM production_daily_report_items item WHERE item.report_id=prior.id
              AND item.execution_segment_id=p_segment AND NOT item.is_deleted AND NOT item.is_actual_surplus
              AND item.fqc_recovery_authorization_id IS NULL)
          AND demand.execution_segment_id IN(SELECT segment_id FROM fn_production_material_usage_source_segments(p_segment))
          AND posting.qty_base>COALESCE((SELECT SUM(reversed.qty_base) FROM production_material_settlement_postings reversed
              JOIN production_material_settlement_events reversal ON reversal.id=reversed.event_id AND reversal.event_type='REVERSE'
              WHERE reversed.source_posting_id=posting.id),0));
$$;

CREATE OR REPLACE FUNCTION fn_assert_actual_report_material_posting(p_report UUID) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM production_daily_reports WHERE id=p_report AND status=1 AND NOT is_deleted) THEN RETURN; END IF;
    IF EXISTS(
        SELECT 1 FROM production_daily_report_items item
        JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
        WHERE item.report_id=p_report AND NOT item.is_deleted AND item.output_batch_id IS NOT NULL
          AND item.fqc_recovery_authorization_id IS NULL AND segment.material_requirement_mode<>'ZERO_MATERIAL'
          AND NOT (NOT item.is_actual_surplus AND (fn_split_batch_empty_issued(segment.id)
              OR fn_report_has_prior_same_segment_consumption(segment.id,p_report)))
          AND NOT EXISTS(
              SELECT 1 FROM production_material_settlement_events event
              JOIN production_material_settlement_postings posting ON posting.event_id=event.id
              JOIN production_material_demands demand ON demand.id=posting.demand_id
              WHERE event.daily_report_id=p_report AND event.event_type='POST'
                AND posting.settlement_type='CONSUMED' AND posting.qty_base>0
                AND demand.execution_segment_id IN (
                    SELECT segment_id FROM fn_production_material_usage_source_segments(segment.id)))) THEN
        RAISE EXCEPTION 'Actual production requires its own positive, exact material consumption posting'
            USING ERRCODE='23514',CONSTRAINT='daily_report_actual_material_posting_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_supplement_plan_approval_context() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.actual_output_supplement_request_id IS NOT NULL
       AND NEW.actual_output_supplement_request_id IS DISTINCT FROM OLD.actual_output_supplement_request_id THEN
        RAISE EXCEPTION 'Supplemental production source identity is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.actual_output_supplement_request_id IS NOT NULL AND NOT EXISTS(
        SELECT 1 FROM production_actual_output_supplement_requests
        WHERE id=NEW.actual_output_supplement_request_id AND supplement_plan_id=NEW.id) THEN
        RAISE EXCEPTION 'Supplemental plan identity must match its exact approved request' USING ERRCODE='23514';
    END IF;
    IF NEW.actual_output_supplement_request_id IS NOT NULL AND NEW.status=1 AND OLD.status IS DISTINCT FROM NEW.status
       AND current_setting('app.actual_output_supplement_request',TRUE) IS DISTINCT FROM NEW.actual_output_supplement_request_id::text THEN
        RAISE EXCEPTION 'Supplemental plans require their complete dedicated approval command' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_actual_output_supplement_plan_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.actual_output_supplement_request_id IS NOT NULL
       AND (NEW.is_deleted OR NEW.is_canceled OR NEW.is_stopped)
       AND current_setting('app.actual_output_supplement_request',TRUE) IS DISTINCT FROM NEW.actual_output_supplement_request_id::text THEN
        RAISE EXCEPTION 'Cancel supplemental production through its exact source request' USING ERRCODE='23514';
    END IF;
    IF (NEW.is_deleted OR NEW.is_canceled OR NEW.is_stopped) AND EXISTS(
        SELECT 1 FROM production_actual_output_supplement_proofs proof WHERE proof.supplement_plan_id=NEW.id
          AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id)) THEN
        RAISE EXCEPTION 'Use the controlled actual-output supplement cancellation after reversing its downstream facts'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_actual_supplement_plan_item_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_id UUID;
BEGIN
    target_id:=CASE WHEN TG_OP='DELETE' THEN OLD.id ELSE NEW.id END;
    IF EXISTS(SELECT 1 FROM production_actual_output_supplement_requests WHERE supplement_plan_item_id=target_id) THEN
        IF TG_OP='DELETE' OR (NEW.plan_id,NEW.goods_id,NEW.color_id,NEW.unit_id,NEW.unit_rate,NEW.qty,NEW.sales_order_item_id,NEW.is_deleted)
            IS DISTINCT FROM (OLD.plan_id,OLD.goods_id,OLD.color_id,OLD.unit_id,OLD.unit_rate,OLD.qty,OLD.sales_order_item_id,OLD.is_deleted) THEN
            RAISE EXCEPTION 'Supplemental plan products and quantities retain their reviewed physical-batch snapshot' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE OR REPLACE FUNCTION fn_actual_supplement_material_ready(p_segment UUID) RETURNS BOOLEAN
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
          AND fn_actual_supplement_increment_identity(target.id)
    );
END;
$$;

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
    WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted AND demand.material_increment_request_id IS NULL
      AND demand.status NOT IN('RELEASED','REVERSED');
    RETURN COALESCE(result,0);
END;
$$;

CREATE UNIQUE INDEX uq_actual_supplement_active_captured_input
    ON production_actual_output_supplement_requests(created_by,(report_context->>'idempotencyKey'),input_line_index)
    WHERE status<>'CANCELLED' AND report_context->>'idempotencyKey' IS NOT NULL AND input_line_index IS NOT NULL;

DROP TRIGGER trg_guard_supplement_plan_approval_context ON production_plans;
CREATE TRIGGER trg_guard_supplement_plan_approval_context
    BEFORE UPDATE OF status,actual_output_supplement_request_id ON production_plans
    FOR EACH ROW EXECUTE FUNCTION fn_guard_supplement_plan_approval_context();

CREATE TRIGGER trg_guard_actual_supplement_plan_item_snapshot
    BEFORE UPDATE OR DELETE ON production_plan_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_actual_supplement_plan_item_snapshot();
