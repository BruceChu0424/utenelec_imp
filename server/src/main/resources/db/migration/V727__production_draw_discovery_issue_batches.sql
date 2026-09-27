-- Mixed known-material requests and ordinary DRAWs form one immutable atomic command.
-- Quantity authority remains discovery demands, exact reservations and ISSUE postings.
CREATE TABLE production_draw_issue_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    actor_employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    idempotency_key VARCHAR(128) NOT NULL,
    request_hash CHAR(64) NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
    request_snapshot JSONB NOT NULL CHECK(jsonb_typeof(request_snapshot)='object'),
    response_snapshot JSONB NOT NULL CHECK(jsonb_typeof(response_snapshot)='object'),
    document_ids UUID[] NOT NULL CHECK(cardinality(document_ids) BETWEEN 1 AND 50),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(actor_user_id,idempotency_key),
    CHECK(idempotency_key=btrim(idempotency_key) AND length(idempotency_key) BETWEEN 8 AND 128
          AND idempotency_key ~ '^[A-Za-z0-9._:-]+$')
);
CREATE FUNCTION fn_guard_production_draw_issue_batch() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Production draw issue batches are append-only' USING ERRCODE='55000';
END;
$$;
CREATE TRIGGER trg_guard_production_draw_issue_batches BEFORE UPDATE OR DELETE ON production_draw_issue_batches
FOR EACH ROW EXECUTE FUNCTION fn_guard_production_draw_issue_batch();
SELECT fn_audit_track_table('production_draw_issue_batches','FULL','data_change',false);

DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V727 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n (''production_draw_issue_batches'', ''CLEAR'')');
END;
$reset_policy$;
