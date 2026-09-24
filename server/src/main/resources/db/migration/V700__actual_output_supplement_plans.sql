-- A threshold exception is an independently reviewed production plan. The
-- immutable proof relates its real output to the same physical execution and
-- material custody; it is not a V561 split and does not enlarge the old plan.
CREATE TABLE production_actual_output_supplement_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    source_sales_allocation_id UUID REFERENCES execution_segment_sales_allocations(id),
    excluded_report_id UUID REFERENCES production_daily_reports(id),
    report_context JSONB,
    input_line_index INTEGER CHECK(input_line_index>=0),
    supplement_plan_id UUID NOT NULL UNIQUE REFERENCES production_plans(id),
    supplement_plan_item_id UUID NOT NULL UNIQUE REFERENCES production_plan_items(id),
    batch_id UUID NOT NULL UNIQUE,
    actual_batch_qty NUMERIC(18,4) NOT NULL CHECK(actual_batch_qty>0),
    original_report_qty NUMERIC(18,4) NOT NULL CHECK(original_report_qty>=0),
    original_sales_qty NUMERIC(18,4) NOT NULL CHECK(original_sales_qty>=0),
    original_internal_qty NUMERIC(18,4) NOT NULL CHECK(original_internal_qty>=0),
    supplement_qty NUMERIC(18,4) NOT NULL CHECK(supplement_qty>0),
    prior_reported_qty NUMERIC(18,4) NOT NULL CHECK(prior_reported_qty>=0),
    source_planned_qty NUMERIC(18,4) NOT NULL CHECK(source_planned_qty>0),
    allowed_overproduction_rate NUMERIC(9,6) NOT NULL CHECK(allowed_overproduction_rate>=0),
    preview_fingerprint TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'DRAFT' CHECK(status IN('DRAFT','APPROVED','CANCELLED')),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(created_by,idempotency_key),
    CHECK(actual_batch_qty=original_report_qty+supplement_qty),
    CHECK(original_report_qty=original_sales_qty+original_internal_qty),
    CHECK(source_sales_allocation_id IS NOT NULL OR original_sales_qty=0)
);
CREATE TABLE production_actual_output_supplement_proofs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    command_id UUID NOT NULL UNIQUE REFERENCES production_actual_output_supplement_requests(id),
    source_execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    supplement_plan_id UUID NOT NULL REFERENCES production_plans(id),
    supplement_plan_item_id UUID NOT NULL REFERENCES production_plan_items(id),
    supplement_execution_segment_id UUID NOT NULL UNIQUE REFERENCES production_execution_segments(id) DEFERRABLE INITIALLY DEFERRED,
    batch_id UUID NOT NULL,
    actual_batch_qty NUMERIC(18,4) NOT NULL CHECK(actual_batch_qty>0),
    original_report_qty NUMERIC(18,4) NOT NULL CHECK(original_report_qty>=0),
    supplement_qty NUMERIC(18,4) NOT NULL CHECK(supplement_qty>0),
    prior_reported_qty NUMERIC(18,4) NOT NULL CHECK(prior_reported_qty>=0),
    source_planned_qty NUMERIC(18,4) NOT NULL CHECK(source_planned_qty>0),
    allowed_overproduction_rate NUMERIC(9,6) NOT NULL CHECK(allowed_overproduction_rate>=0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(source_execution_segment_id,batch_id),
    CHECK(actual_batch_qty=original_report_qty+supplement_qty)
);
CREATE TABLE production_actual_output_supplement_reversals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    proof_id UUID NOT NULL UNIQUE REFERENCES production_actual_output_supplement_proofs(id),
    reason TEXT NOT NULL CHECK(length(btrim(reason))>0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE production_actual_output_supplement_claims (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    proof_id UUID NOT NULL REFERENCES production_actual_output_supplement_proofs(id),
    report_id UUID NOT NULL REFERENCES production_daily_reports(id),
    event_type TEXT NOT NULL CHECK(event_type IN('CLAIM','RELEASE')),
    source_claim_id UUID UNIQUE REFERENCES production_actual_output_supplement_claims(id),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(proof_id,report_id,event_type),
    CHECK((event_type='CLAIM' AND source_claim_id IS NULL) OR (event_type='RELEASE' AND source_claim_id IS NOT NULL))
);
ALTER TABLE production_daily_report_items ADD COLUMN supplement_proof_id UUID REFERENCES production_actual_output_supplement_proofs(id);
ALTER TABLE production_plans ADD COLUMN actual_output_supplement_request_id UUID UNIQUE REFERENCES production_actual_output_supplement_requests(id);
CREATE INDEX idx_actual_output_supplement_source ON production_actual_output_supplement_requests(source_execution_segment_id,status);
CREATE UNIQUE INDEX uq_actual_supplement_active_captured_input
    ON production_actual_output_supplement_requests(created_by,(report_context->>'idempotencyKey'),input_line_index)
    WHERE status<>'CANCELLED' AND report_context->>'idempotencyKey' IS NOT NULL AND input_line_index IS NOT NULL;
CREATE INDEX idx_actual_output_supplement_report ON production_daily_report_items(supplement_proof_id,report_id) WHERE supplement_proof_id IS NOT NULL;

CREATE OR REPLACE FUNCTION fn_execution_overproduction_policy_applies(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_execution_segments WHERE id=p_segment)
      AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs WHERE supplement_execution_segment_id=p_segment);
$$;

CREATE FUNCTION fn_assert_actual_output_policy_limit_for_report(p_report UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE source RECORD;available NUMERIC;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM production_daily_reports WHERE id=p_report AND status IN(0,1) AND NOT is_deleted) THEN RETURN; END IF;
    FOR source IN SELECT execution_segment_id,SUM(qty) qty FROM production_daily_report_items
        WHERE report_id=p_report AND is_actual_surplus AND fqc_recovery_authorization_id IS NULL AND NOT is_deleted
        GROUP BY execution_segment_id ORDER BY execution_segment_id
    LOOP
        PERFORM id FROM production_execution_segments WHERE id=source.execution_segment_id FOR UPDATE;
        SELECT fn_execution_actual_surplus_available(source.execution_segment_id,p_report) INTO available;
        IF source.qty>available OR NOT fn_execution_overproduction_policy_applies(source.execution_segment_id) THEN
            RAISE EXCEPTION 'Actual surplus exceeds the effective approved rate; create a separate reviewed supplemental plan'
                USING ERRCODE='23514',CONSTRAINT='actual_output_effective_rate_limit';
        END IF;
    END LOOP;
END;
$$;
CREATE FUNCTION fn_check_actual_output_policy_limit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='production_daily_reports' THEN
        PERFORM fn_assert_actual_output_policy_limit_for_report(NEW.id);
    ELSE
        PERFORM fn_assert_actual_output_policy_limit_for_report(NEW.report_id);
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_actual_output_policy_report_status AFTER INSERT OR UPDATE OF status,is_deleted ON production_daily_reports
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_actual_output_policy_limit();
CREATE CONSTRAINT TRIGGER trg_actual_output_policy_report_item AFTER INSERT OR UPDATE OF qty,is_actual_surplus,is_deleted,execution_segment_id,fqc_recovery_authorization_id ON production_daily_report_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_actual_output_policy_limit();

CREATE FUNCTION fn_guard_supplement_target_report_identity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE proof UUID;
BEGIN
    IF NEW.fqc_recovery_authorization_id IS NOT NULL THEN RETURN NEW; END IF;
    SELECT id INTO proof FROM production_actual_output_supplement_proofs WHERE supplement_execution_segment_id=NEW.execution_segment_id;
    IF proof IS NOT NULL AND (NEW.supplement_proof_id IS DISTINCT FROM proof OR NOT NEW.is_public_output OR NEW.is_actual_surplus
        OR NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_claims claim WHERE claim.proof_id=proof
            AND claim.report_id=NEW.report_id AND claim.event_type='CLAIM'
            AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_claims release WHERE release.source_claim_id=claim.id))) THEN
        RAISE EXCEPTION 'Supplemental output must retain its unique approved batch proof and active report claim'
            USING ERRCODE='23514',CONSTRAINT='actual_output_supplement_target_identity';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_supplement_target_report_identity BEFORE INSERT OR UPDATE ON production_daily_report_items
FOR EACH ROW EXECUTE FUNCTION fn_guard_supplement_target_report_identity();

CREATE FUNCTION fn_guard_supplement_plan_approval_context() RETURNS trigger LANGUAGE plpgsql AS $$
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
CREATE TRIGGER trg_guard_supplement_plan_approval_context BEFORE UPDATE OF status,actual_output_supplement_request_id ON production_plans
FOR EACH ROW EXECUTE FUNCTION fn_guard_supplement_plan_approval_context();

CREATE FUNCTION fn_assert_supplement_plan_approval_complete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM production_plans plan WHERE plan.id=NEW.id AND plan.status=1 AND NOT plan.is_deleted
        AND plan.actual_output_supplement_request_id IS NOT NULL AND NOT EXISTS(
            SELECT 1 FROM production_actual_output_supplement_requests request
            JOIN production_actual_output_supplement_proofs proof ON proof.command_id=request.id
            JOIN production_execution_segments segment ON segment.id=proof.supplement_execution_segment_id
            WHERE request.id=plan.actual_output_supplement_request_id AND request.supplement_plan_id=plan.id
              AND request.status IN('APPROVED','CANCELLED') AND segment.plan_id=plan.id)) THEN
        RAISE EXCEPTION 'Approved supplemental plan is missing its atomic source proof or execution segment' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_supplement_plan_approval_complete AFTER UPDATE OF status ON production_plans
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_supplement_plan_approval_complete();

CREATE FUNCTION fn_execution_actual_surplus_available(p_segment UUID,p_exclude_report UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT GREATEST(trunc(segment.planned_qty*segment.allowed_overproduction_rate,4)-COALESCE((
        SELECT SUM(item.qty) FROM production_daily_report_items item
        JOIN production_daily_reports report ON report.id=item.report_id
        WHERE item.execution_segment_id=segment.id AND item.is_actual_surplus
          AND item.fqc_recovery_authorization_id IS NULL AND NOT item.is_deleted AND NOT report.is_deleted
          AND report.status IN(0,1) AND (p_exclude_report IS NULL OR report.id<>p_exclude_report)),0),0)
    FROM production_execution_segments segment WHERE segment.id=p_segment;
$$;
CREATE FUNCTION fn_actual_supplement_reserved_original_qty(p_segment UUID,p_allocation UUID,p_exclude_report UUID DEFAULT NULL,p_excluded_proofs UUID[] DEFAULT '{}')
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(GREATEST(CASE WHEN p_allocation IS NULL THEN request.original_internal_qty ELSE request.original_sales_qty END-COALESCE((
        SELECT SUM(item.qty) FROM production_daily_report_items item
        JOIN production_daily_reports existing ON existing.id=item.report_id
        WHERE existing.id=request.excluded_report_id AND existing.status=0 AND NOT existing.is_deleted
          AND item.execution_segment_id=request.source_execution_segment_id
          AND item.execution_segment_sales_allocation_id IS NOT DISTINCT FROM p_allocation
          AND NOT item.is_deleted AND NOT item.is_actual_surplus AND item.fqc_recovery_authorization_id IS NULL),0),0)),0)
    FROM production_actual_output_supplement_requests request
    LEFT JOIN production_actual_output_supplement_proofs proof ON proof.command_id=request.id
    WHERE request.source_execution_segment_id=p_segment
      AND (p_allocation IS NULL OR request.source_sales_allocation_id=p_allocation)
      AND request.status='APPROVED'
      AND (proof.id IS NULL OR NOT(proof.id=ANY(p_excluded_proofs)))
      AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id)
      AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_claims claim
          JOIN production_daily_reports report ON report.id=claim.report_id
          WHERE claim.proof_id=proof.id AND claim.event_type='CLAIM' AND NOT report.is_deleted
            AND (report.status IN(0,1) OR report.id=p_exclude_report)
            AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_claims release WHERE release.source_claim_id=claim.id));
$$;
CREATE FUNCTION fn_guard_actual_output_supplement_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Actual output supplement evidence is append-only' USING ERRCODE='55000'; END;
$$;
DO $evidence$
DECLARE relation TEXT;
BEGIN
    FOREACH relation IN ARRAY ARRAY['production_actual_output_supplement_proofs','production_actual_output_supplement_reversals','production_actual_output_supplement_claims'] LOOP
        EXECUTE format('CREATE TRIGGER trg_actual_supplement_append_only BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_actual_output_supplement_append_only()',relation);
    END LOOP;
END;
$evidence$;

CREATE FUNCTION fn_guard_actual_supplement_request_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Additional production requests retain their history' USING ERRCODE='55000'; END IF;
    IF TG_OP='UPDATE' THEN
        IF to_jsonb(NEW)-'status' IS DISTINCT FROM to_jsonb(OLD)-'status'
            OR OLD.status NOT IN('DRAFT','APPROVED') OR NEW.status NOT IN('APPROVED','CANCELLED')
            OR OLD.status=NEW.status THEN
            RAISE EXCEPTION 'Additional production request snapshots are immutable' USING ERRCODE='23514';
        END IF;
        IF NEW.status='APPROVED' AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs WHERE command_id=NEW.id) THEN
            RAISE EXCEPTION 'Additional production approval requires its exact execution proof' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NOT EXISTS(SELECT 1 FROM production_execution_segments source
        JOIN production_plan_items target ON target.id=NEW.supplement_plan_item_id AND target.plan_id=NEW.supplement_plan_id AND NOT target.is_deleted
        JOIN production_plans plan ON plan.id=target.plan_id AND plan.status=0 AND NOT plan.is_deleted
        WHERE source.id=NEW.source_execution_segment_id AND source.status IN('IN_PROGRESS','COMPLETED') AND NOT source.is_deleted
          AND target.qty=NEW.supplement_qty AND target.sales_order_item_id IS NULL
          AND (target.goods_id,target.color_id,target.unit_id,COALESCE(target.unit_rate,1))
            IS NOT DISTINCT FROM (source.product_goods_id,source.product_color_id,source.product_unit_id,source.product_unit_rate)) THEN
        RAISE EXCEPTION 'Additional request must reference its exact original product and separate unowned draft plan' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_actual_supplement_request_snapshot BEFORE INSERT OR UPDATE OR DELETE ON production_actual_output_supplement_requests
FOR EACH ROW EXECUTE FUNCTION fn_guard_actual_supplement_request_snapshot();

CREATE FUNCTION fn_guard_actual_supplement_proof_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.created_by::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',TRUE),'')
       OR NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_requests request
         JOIN production_plans plan ON plan.id=request.supplement_plan_id AND plan.status=1 AND NOT plan.is_deleted
         WHERE request.id=NEW.command_id AND request.status='DRAFT'
           AND plan.actual_output_supplement_request_id=request.id
           AND (request.source_execution_segment_id,request.supplement_plan_id,request.supplement_plan_item_id,request.batch_id,
                request.actual_batch_qty,request.original_report_qty,request.supplement_qty,request.prior_reported_qty,request.source_planned_qty,request.allowed_overproduction_rate)
             IS NOT DISTINCT FROM (NEW.source_execution_segment_id,NEW.supplement_plan_id,NEW.supplement_plan_item_id,NEW.batch_id,
                NEW.actual_batch_qty,NEW.original_report_qty,NEW.supplement_qty,NEW.prior_reported_qty,NEW.source_planned_qty,NEW.allowed_overproduction_rate)
           AND current_setting('app.actual_output_supplement_request',TRUE)=request.id::text) THEN
        RAISE EXCEPTION 'Additional execution proof must copy the precisely reviewed request in its approval command' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_actual_supplement_proof_snapshot BEFORE INSERT ON production_actual_output_supplement_proofs
FOR EACH ROW EXECUTE FUNCTION fn_guard_actual_supplement_proof_snapshot();

CREATE FUNCTION fn_guard_actual_output_supplement_claim() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE prior production_actual_output_supplement_claims%ROWTYPE;
BEGIN
    PERFORM id FROM production_actual_output_supplement_proofs WHERE id=NEW.proof_id FOR UPDATE;
    IF NEW.event_type='CLAIM' THEN
        IF EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals WHERE proof_id=NEW.proof_id)
           OR NOT EXISTS(SELECT 1 FROM production_daily_reports WHERE id=NEW.report_id AND status=0 AND NOT is_deleted)
           OR EXISTS(SELECT 1 FROM production_actual_output_supplement_claims claim
             WHERE claim.proof_id=NEW.proof_id AND claim.event_type='CLAIM'
               AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_claims release WHERE release.source_claim_id=claim.id)) THEN
            RAISE EXCEPTION 'This physical supplement batch is cancelled or already claimed by another report' USING ERRCODE='23514';
        END IF;
    ELSE
        SELECT * INTO prior FROM production_actual_output_supplement_claims WHERE id=NEW.source_claim_id;
        IF NOT FOUND OR prior.event_type<>'CLAIM' OR prior.proof_id<>NEW.proof_id OR prior.report_id<>NEW.report_id
           OR EXISTS(SELECT 1 FROM production_daily_reports WHERE id=NEW.report_id AND status IN(0,1) AND NOT is_deleted) THEN
            RAISE EXCEPTION 'Release requires this exact deleted draft or reversed production report' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_actual_output_supplement_claim BEFORE INSERT ON production_actual_output_supplement_claims
FOR EACH ROW EXECUTE FUNCTION fn_guard_actual_output_supplement_claim();

CREATE FUNCTION fn_assert_actual_supplement_proof_claims(p_proof UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE proof production_actual_output_supplement_proofs%ROWTYPE; claim RECORD; original_qty NUMERIC;supplement_qty NUMERIC;
BEGIN
    IF p_proof IS NULL THEN RETURN; END IF;
    SELECT * INTO proof FROM production_actual_output_supplement_proofs WHERE id=p_proof FOR UPDATE;
    IF NOT FOUND THEN RETURN; END IF;
    FOR claim IN SELECT c.* FROM production_actual_output_supplement_claims c
        JOIN production_daily_reports report ON report.id=c.report_id
        WHERE c.proof_id=proof.id AND c.event_type='CLAIM' AND report.status IN(0,1) AND NOT report.is_deleted
          AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_claims released WHERE released.source_claim_id=c.id)
    LOOP
        SELECT COALESCE(SUM(qty) FILTER(WHERE execution_segment_id=proof.source_execution_segment_id),0),
               COALESCE(SUM(qty) FILTER(WHERE execution_segment_id=proof.supplement_execution_segment_id),0)
        INTO original_qty,supplement_qty FROM production_daily_report_items
        WHERE report_id=claim.report_id AND supplement_proof_id=proof.id AND NOT is_deleted;
        IF original_qty<>proof.original_report_qty OR supplement_qty<>proof.supplement_qty
           OR EXISTS(SELECT 1 FROM production_daily_report_items WHERE report_id=claim.report_id AND supplement_proof_id=proof.id
                AND NOT is_deleted AND (execution_segment_id NOT IN(proof.source_execution_segment_id,proof.supplement_execution_segment_id)
                  OR is_actual_surplus OR fqc_recovery_authorization_id IS NOT NULL)) THEN
            RAISE EXCEPTION 'Original and supplemental production must conserve the same unreported physical batch'
                USING ERRCODE='23514',CONSTRAINT='actual_output_supplement_report_conservation';
        END IF;
    END LOOP;
END;
$$;
CREATE FUNCTION fn_assert_actual_supplement_reserved_capacity(p_segment UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE planned NUMERIC;reported NUMERIC;reserved NUMERIC;allocation RECORD;
BEGIN
    IF p_segment IS NULL OR NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_requests WHERE source_execution_segment_id=p_segment AND status='APPROVED') THEN RETURN; END IF;
    IF current_setting('transaction_isolation')<>'read committed' THEN
        RAISE EXCEPTION 'Supplemental source allocation requires READ COMMITTED isolation' USING ERRCODE='25001';
    END IF;
    SELECT planned_qty INTO planned FROM production_execution_segments WHERE id=p_segment FOR UPDATE;
    FOR allocation IN SELECT id,allocated_qty FROM execution_segment_sales_allocations WHERE execution_segment_id=p_segment
      UNION ALL SELECT NULL::uuid,GREATEST(planned-COALESCE(SUM(allocated_qty),0),0) FROM execution_segment_sales_allocations WHERE execution_segment_id=p_segment
    LOOP
        SELECT COALESCE(SUM(item.qty),0) INTO reported FROM production_daily_report_items item
        JOIN production_daily_reports report ON report.id=item.report_id
        WHERE item.execution_segment_id=p_segment AND item.execution_segment_sales_allocation_id IS NOT DISTINCT FROM allocation.id
          AND NOT item.is_actual_surplus AND item.fqc_recovery_authorization_id IS NULL
          AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN(0,1);
        reserved:=fn_actual_supplement_reserved_original_qty(p_segment,allocation.id,NULL);
        IF reported+reserved>allocation.allocated_qty THEN
            RAISE EXCEPTION 'The original quantity is already claimed by another draft or approved supplemental batch'
                USING ERRCODE='23514',CONSTRAINT='actual_supplement_original_capacity_guard';
        END IF;
    END LOOP;
END;
$$;
CREATE FUNCTION fn_assert_actual_output_supplement_report() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE proof UUID;
BEGIN
    IF TG_TABLE_NAME='production_actual_output_supplement_claims' THEN
        PERFORM fn_assert_actual_supplement_proof_claims(NEW.proof_id);
        PERFORM fn_assert_actual_supplement_reserved_capacity((SELECT source_execution_segment_id FROM production_actual_output_supplement_proofs WHERE id=NEW.proof_id));
    ELSIF TG_TABLE_NAME='production_actual_output_supplement_requests' THEN
        PERFORM fn_assert_actual_supplement_reserved_capacity(NEW.source_execution_segment_id);
    ELSIF TG_TABLE_NAME='production_daily_reports' THEN
        FOR proof IN SELECT DISTINCT proof_id FROM production_actual_output_supplement_claims WHERE report_id=NEW.id
        LOOP PERFORM fn_assert_actual_supplement_proof_claims(proof); END LOOP;
        FOR proof IN SELECT DISTINCT execution_segment_id FROM production_daily_report_items WHERE report_id=NEW.id
        LOOP PERFORM fn_assert_actual_supplement_reserved_capacity(proof); END LOOP;
    ELSE
        IF TG_OP<>'INSERT' THEN
            PERFORM fn_assert_actual_supplement_proof_claims(OLD.supplement_proof_id);
            PERFORM fn_assert_actual_supplement_reserved_capacity(OLD.execution_segment_id);
        END IF;
        IF TG_OP<>'DELETE' THEN
            PERFORM fn_assert_actual_supplement_proof_claims(NEW.supplement_proof_id);
            PERFORM fn_assert_actual_supplement_reserved_capacity(NEW.execution_segment_id);
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_actual_supplement_report_items AFTER INSERT OR UPDATE OR DELETE ON production_daily_report_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_actual_output_supplement_report();
CREATE CONSTRAINT TRIGGER trg_assert_actual_supplement_claim_complete AFTER INSERT ON production_actual_output_supplement_claims
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_actual_output_supplement_report();
CREATE CONSTRAINT TRIGGER trg_assert_actual_supplement_report_status AFTER UPDATE OF status,is_deleted ON production_daily_reports
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_actual_output_supplement_report();
CREATE CONSTRAINT TRIGGER trg_assert_actual_supplement_reserved_request AFTER INSERT OR UPDATE OF status ON production_actual_output_supplement_requests
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_actual_output_supplement_report();

CREATE FUNCTION fn_guard_actual_output_supplement_plan_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
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
CREATE TRIGGER trg_guard_actual_supplement_plan_lifecycle BEFORE UPDATE OF is_deleted,is_canceled,is_stopped ON production_plans
FOR EACH ROW EXECUTE FUNCTION fn_guard_actual_output_supplement_plan_lifecycle();

CREATE FUNCTION fn_guard_actual_supplement_plan_item_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
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
CREATE TRIGGER trg_guard_actual_supplement_plan_item_snapshot BEFORE UPDATE OR DELETE ON production_plan_items
FOR EACH ROW EXECUTE FUNCTION fn_guard_actual_supplement_plan_item_snapshot();

SELECT public.fn_audit_track_table('production_actual_output_supplement_requests','FULL','data_change',false);
SELECT public.fn_audit_track_table('production_actual_output_supplement_proofs','NONE','data_change',false);
SELECT public.fn_audit_track_table('production_actual_output_supplement_reversals','NONE','data_change',false);
SELECT public.fn_audit_track_table('production_actual_output_supplement_claims','NONE','data_change',false);

INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy)
VALUES('production_execution:request_supplement_plan','申请实际超产追加计划','生产管理','车间执行',43,'CREATE',
       '仅从本人车间已开工工单的真实超产批次生成固定产品数量的追加草稿，仍须计划部审批，不授予通用计划创建权',ARRAY['NORMAL']::text[])
ON CONFLICT(code) DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id,permission.id FROM permission_surfaces surface CROSS JOIN permissions permission
WHERE surface.surface_key IN('production.workshop-tasks','production.daily-report') AND permission.code='production_execution:request_supplement_plan'
ON CONFLICT DO NOTHING;
INSERT INTO department_permissions(department_id,permission_id)
SELECT granted.department_id,narrow.id FROM department_permissions granted
JOIN permissions original ON original.id=granted.permission_id AND original.code='production_daily_report:create'
CROSS JOIN permissions narrow WHERE narrow.code='production_execution:request_supplement_plan'
ON CONFLICT DO NOTHING;

DO $reset_policy$
DECLARE definition TEXT;anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V700 reset policy anchor changed'; END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''production_actual_output_supplement_requests'', ''CLEAR''),\n            (''production_actual_output_supplement_proofs'', ''CLEAR''),\n            (''production_actual_output_supplement_reversals'', ''CLEAR''),\n            (''production_actual_output_supplement_claims'', ''CLEAR'')');
END;
$reset_policy$;
