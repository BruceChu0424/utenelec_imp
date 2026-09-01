-- V432: one server-side, all-or-nothing command for passing selected production
-- FQC inspections.  The command header owns actor-scoped idempotency; immutable
-- item rows bind the committed batch result to the exact decision events.

CREATE TABLE production_fqc_pass_all_batches (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key     VARCHAR(128) NOT NULL,
    request_hash        CHAR(64) NOT NULL,
    inspection_count    INTEGER NOT NULL,
    created_by          UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_pass_all_batch_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 128
        AND idempotency_key ~ '^[A-Za-z0-9._:-]+$'),
    CONSTRAINT production_fqc_pass_all_batch_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT production_fqc_pass_all_batch_size_chk CHECK (
        inspection_count BETWEEN 1 AND 100),
    CONSTRAINT production_fqc_pass_all_batch_actor_key_uk UNIQUE (
        created_by, idempotency_key)
);

CREATE INDEX idx_production_fqc_pass_all_batch_actor_timeline
    ON production_fqc_pass_all_batches(created_by, created_at, id);

CREATE TABLE production_fqc_pass_all_batch_items (
    batch_id            UUID NOT NULL
        REFERENCES production_fqc_pass_all_batches(id) ON DELETE RESTRICT,
    inspection_id       UUID NOT NULL
        REFERENCES production_fqc_inspections(id) ON DELETE RESTRICT,
    decision_event_id   UUID NOT NULL,
    line_no             INTEGER NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_pass_all_batch_item_pk PRIMARY KEY (
        batch_id, inspection_id),
    CONSTRAINT production_fqc_pass_all_batch_item_line_chk CHECK (
        line_no BETWEEN 1 AND 100),
    CONSTRAINT production_fqc_pass_all_batch_item_line_uk UNIQUE (
        batch_id, line_no),
    CONSTRAINT production_fqc_pass_all_batch_item_decision_uk UNIQUE (
        decision_event_id),
    CONSTRAINT production_fqc_pass_all_batch_item_decision_fk
        FOREIGN KEY (inspection_id, decision_event_id)
        REFERENCES production_fqc_decision_events(inspection_id, id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_production_fqc_pass_all_batch_item_inspection
    ON production_fqc_pass_all_batch_items(inspection_id, batch_id);

CREATE OR REPLACE FUNCTION fn_validate_production_fqc_pass_all_batch_total()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch_id UUID;
    v_expected INTEGER;
    v_actual INTEGER;
BEGIN
    v_batch_id := COALESCE(
        NULLIF(to_jsonb(NEW) ->> 'batch_id', '')::UUID,
        NULLIF(to_jsonb(NEW) ->> 'id', '')::UUID);

    SELECT batch.inspection_count
    INTO v_expected
    FROM production_fqc_pass_all_batches batch
    WHERE batch.id = v_batch_id;

    SELECT COUNT(*)
    INTO v_actual
    FROM production_fqc_pass_all_batch_items item
    WHERE item.batch_id = v_batch_id;

    IF v_expected IS NULL OR v_actual IS DISTINCT FROM v_expected THEN
        RAISE EXCEPTION
            'production FQC pass-all batch items must equal inspection count'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_pass_all_batch_total_guard';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_production_fqc_pass_all_batch_header
    AFTER INSERT ON production_fqc_pass_all_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_production_fqc_pass_all_batch_total();

CREATE CONSTRAINT TRIGGER trg_validate_production_fqc_pass_all_batch_item
    AFTER INSERT ON production_fqc_pass_all_batch_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_production_fqc_pass_all_batch_total();

CREATE TRIGGER trg_guard_production_fqc_pass_all_batch_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_pass_all_batches
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_pass_all_batches
    ENABLE ALWAYS TRIGGER trg_guard_production_fqc_pass_all_batch_append_only;

CREATE TRIGGER trg_guard_production_fqc_pass_all_batch_item_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_pass_all_batch_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_pass_all_batch_items
    ENABLE ALWAYS TRIGGER trg_guard_production_fqc_pass_all_batch_item_append_only;

CREATE TRIGGER trg_audit_production_fqc_pass_all_batches
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_pass_all_batches
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_production_fqc_pass_all_batch_items
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_pass_all_batch_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE production_fqc_pass_all_batches IS
    'Actor-scoped idempotent command for atomically passing 1-100 selected production FQC inspections';
COMMENT ON TABLE production_fqc_pass_all_batch_items IS
    'Immutable committed result mapping from one pass-all batch to its exact FQC decision events';
