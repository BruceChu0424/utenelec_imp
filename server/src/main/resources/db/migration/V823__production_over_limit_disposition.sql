-- ADR-167: already-produced output is a fact; planning decides only this batch's release.
-- Historical supplemental plans/proofs remain readable and retain their original workflow.
CREATE TABLE production_over_limit_dispositions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_item_id UUID NOT NULL UNIQUE REFERENCES production_daily_report_items(id) ON DELETE CASCADE,
    report_id UUID NOT NULL REFERENCES production_daily_reports(id),
    execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    plan_id UUID NOT NULL REFERENCES production_plans(id),
    qty NUMERIC(18,4) NOT NULL CHECK(qty>0),
    actual_batch_qty NUMERIC(18,4) NOT NULL CHECK(actual_batch_qty>=qty),
    planned_qty NUMERIC(18,4) NOT NULL CHECK(planned_qty>=0),
    allowed_rate NUMERIC(9,6) NOT NULL CHECK(allowed_rate>=0),
    reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 2 AND 500),
    status TEXT NOT NULL CHECK(status IN('DRAFT','PENDING','HELD','RETURNED','ACCEPTED','WITHDRAWN')),
    row_version BIGINT NOT NULL DEFAULT 0 CHECK(row_version>=0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_decision_id UUID
);
CREATE INDEX idx_production_over_limit_pending ON production_over_limit_dispositions(status,created_at,id);
CREATE INDEX idx_production_over_limit_report ON production_over_limit_dispositions(report_id);
CREATE INDEX idx_production_over_limit_segment_pending
    ON production_over_limit_dispositions(execution_segment_id,created_at DESC,id DESC)
    WHERE status IN('PENDING','HELD','RETURNED');
CREATE TABLE production_over_limit_decisions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    disposition_id UUID NOT NULL REFERENCES production_over_limit_dispositions(id),
    action TEXT NOT NULL CHECK(action IN('ACCEPT_PUBLIC','HOLD','RETURN_FOR_REVIEW')),
    reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 2 AND 500),
    expected_version BIGINT NOT NULL CHECK(expected_version>=0),
    decided_by UUID NOT NULL REFERENCES users(id),
    decided_by_name TEXT NOT NULL,
    decided_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    UNIQUE(disposition_id,expected_version),
    UNIQUE(decided_by,idempotency_key)
);
ALTER TABLE production_over_limit_dispositions ADD CONSTRAINT production_over_limit_last_decision_fk
    FOREIGN KEY(last_decision_id) REFERENCES production_over_limit_decisions(id) DEFERRABLE INITIALLY DEFERRED;

CREATE FUNCTION fn_guard_production_over_limit_disposition() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE source RECORD; decision production_over_limit_decisions%ROWTYPE;
BEGIN
    IF TG_OP='DELETE' THEN
        IF OLD.status<>'DRAFT' OR OLD.last_decision_id IS NOT NULL THEN
            RAISE EXCEPTION 'Reviewed production over-limit history cannot be deleted' USING ERRCODE='23514';
        END IF;
        RETURN OLD;
    END IF;
    SELECT item.*,report.status AS report_status,report.is_deleted AS report_deleted,segment.plan_id
      INTO source FROM production_daily_report_items item
      JOIN production_daily_reports report ON report.id=item.report_id
      JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
      WHERE item.id=NEW.report_item_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Over-limit source missing' USING ERRCODE='23514'; END IF;
    IF TG_OP='INSERT' THEN
        IF NOT source.is_over_limit OR source.fqc_recovery_authorization_id IS NOT NULL
           OR source.is_deleted OR source.report_deleted OR source.report_status NOT IN(0,1)
           OR NEW.report_id IS DISTINCT FROM source.report_id
           OR NEW.execution_segment_id IS DISTINCT FROM source.execution_segment_id
           OR NEW.plan_id IS DISTINCT FROM source.plan_id OR NEW.qty IS DISTINCT FROM source.qty
           OR NEW.actual_batch_qty IS DISTINCT FROM source.output_batch_qty
           OR NEW.planned_qty IS DISTINCT FROM (source.overproduction_authorization_snapshot->>'plannedQty')::numeric
           OR NEW.allowed_rate IS DISTINCT FROM (source.overproduction_authorization_snapshot->>'allowedRate')::numeric
           OR NEW.reason IS DISTINCT FROM source.over_limit_reason
           OR NEW.status IS DISTINCT FROM (CASE WHEN source.report_status=1 THEN 'PENDING' ELSE 'DRAFT' END)
           OR NEW.row_version<>0 OR NEW.last_decision_id IS NOT NULL THEN
            RAISE EXCEPTION 'Over-limit disposition must preserve the exact actual-output source' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF (to_jsonb(NEW)-ARRAY['status','row_version','last_decision_id'])
       IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','row_version','last_decision_id'])
       OR NEW.row_version<>OLD.row_version+1 THEN
        RAISE EXCEPTION 'Over-limit source and authorization snapshot are immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.status='WITHDRAWN' AND (source.is_deleted OR source.report_deleted OR source.report_status<>1)
       AND NEW.last_decision_id IS NOT DISTINCT FROM OLD.last_decision_id THEN RETURN NEW; END IF;
    IF OLD.status='DRAFT' AND NEW.status='PENDING' AND source.report_status=1
       AND NOT source.is_deleted AND NOT source.report_deleted AND NEW.last_decision_id IS NULL THEN RETURN NEW; END IF;
    SELECT * INTO decision FROM production_over_limit_decisions WHERE id=NEW.last_decision_id;
    IF NOT FOUND OR OLD.status NOT IN('PENDING','HELD','RETURNED') OR source.report_status<>1
       OR source.is_deleted OR source.report_deleted OR decision.disposition_id<>OLD.id
       OR decision.expected_version<>OLD.row_version
       OR NEW.status IS DISTINCT FROM (CASE decision.action WHEN 'ACCEPT_PUBLIC' THEN 'ACCEPTED'
            WHEN 'HOLD' THEN 'HELD' ELSE 'RETURNED' END) THEN
        RAISE EXCEPTION 'Over-limit release requires its exact planning decision' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_production_over_limit_disposition BEFORE INSERT OR UPDATE OR DELETE
    ON production_over_limit_dispositions FOR EACH ROW EXECUTE FUNCTION fn_guard_production_over_limit_disposition();

CREATE FUNCTION fn_apply_production_over_limit_decision() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE request production_over_limit_dispositions%ROWTYPE;
BEGIN
    SELECT * INTO request FROM production_over_limit_dispositions WHERE id=NEW.disposition_id FOR UPDATE;
    IF NOT FOUND OR request.status NOT IN('PENDING','HELD','RETURNED')
       OR request.row_version<>NEW.expected_version OR NOT EXISTS(
          SELECT 1 FROM production_daily_reports report JOIN production_daily_report_items item ON item.report_id=report.id
          WHERE item.id=request.report_item_id AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted) THEN
        RAISE EXCEPTION 'Over-limit output has changed or is not approved actual output' USING ERRCODE='23514';
    END IF;
    UPDATE production_over_limit_dispositions SET status=CASE NEW.action WHEN 'ACCEPT_PUBLIC' THEN 'ACCEPTED'
        WHEN 'HOLD' THEN 'HELD' ELSE 'RETURNED' END,row_version=row_version+1,last_decision_id=NEW.id
        WHERE id=NEW.disposition_id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_apply_production_over_limit_decision AFTER INSERT ON production_over_limit_decisions
    FOR EACH ROW EXECUTE FUNCTION fn_apply_production_over_limit_decision();
CREATE FUNCTION fn_immutable_production_over_limit_decision() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Production over-limit decisions are append-only' USING ERRCODE='23514'; END;
$$;
CREATE TRIGGER trg_immutable_production_over_limit_decision BEFORE UPDATE OR DELETE ON production_over_limit_decisions
    FOR EACH ROW EXECUTE FUNCTION fn_immutable_production_over_limit_decision();

CREATE FUNCTION fn_daily_report_output_authorization_root(p_item UUID) RETURNS UUID LANGUAGE sql STABLE AS $$
    WITH RECURSIVE origin AS (
        SELECT id,fqc_recovery_authorization_id FROM production_daily_report_items WHERE id=p_item
        UNION
        SELECT source.id,source.fqc_recovery_authorization_id
        FROM origin JOIN production_fqc_recovery_authorizations recovery ON recovery.id=origin.fqc_recovery_authorization_id
        JOIN production_daily_report_items source ON source.id=recovery.source_report_item_id
    ) SELECT id FROM origin WHERE fqc_recovery_authorization_id IS NULL
$$;

CREATE OR REPLACE FUNCTION fn_daily_report_output_authorized(p_item UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_daily_report_items origin
        WHERE origin.id=fn_daily_report_output_authorization_root(p_item)
        AND (NOT origin.is_over_limit OR EXISTS(
            SELECT 1 FROM production_over_limit_dispositions request
            JOIN production_daily_reports report ON report.id=request.report_id
            JOIN production_daily_report_items item ON item.id=request.report_item_id
            WHERE request.report_item_id=origin.id AND request.status='ACCEPTED'
              AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted)))
$$;

SELECT fn_audit_track_table('production_over_limit_dispositions','FULL','data_change',false);
SELECT fn_audit_track_table('production_over_limit_decisions','NONE','data_change',false);
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V823 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''production_over_limit_dispositions'', ''CLEAR''),\n            (''production_over_limit_decisions'', ''CLEAR'')');
END;
$reset_policy$;
