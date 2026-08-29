-- Forward-only cancellation of FQC projections when their approved source
-- production report is reversed. Decisions and release allocations remain
-- append-only historical evidence; no quantity is rewritten or relabelled.

ALTER TABLE production_fqc_inspections
    DROP CONSTRAINT production_fqc_inspection_status_projection_chk;
ALTER TABLE production_fqc_inspections
    DROP CONSTRAINT production_fqc_inspection_status_chk;

ALTER TABLE production_fqc_inspections
    ADD CONSTRAINT production_fqc_inspection_status_chk CHECK (
        status IN ('PENDING', 'PARTIAL', 'RESOLVED', 'CANCELLED')),
    ADD CONSTRAINT production_fqc_inspection_status_projection_chk CHECK (
        status = 'CANCELLED'
        OR (status = 'PENDING' AND passed_qty + failed_qty = 0)
        OR (status = 'PARTIAL'
            AND passed_qty + failed_qty > 0
            AND passed_qty + failed_qty < reported_qty)
        OR (status = 'RESOLVED'
            AND passed_qty + failed_qty = reported_qty));

CREATE TABLE production_fqc_cancellation_events (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id       UUID NOT NULL UNIQUE
        REFERENCES production_fqc_inspections(id) ON DELETE RESTRICT,
    source_report_id    UUID NOT NULL
        REFERENCES production_daily_reports(id) ON DELETE RESTRICT,
    reason_code         TEXT NOT NULL,
    idempotency_key     TEXT NOT NULL,
    created_by          UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_cancellation_reason_chk CHECK (
        reason_code = 'SOURCE_REPORT_REVERSED'),
    CONSTRAINT production_fqc_cancellation_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 160),
    CONSTRAINT production_fqc_cancellation_key_uk
        UNIQUE (inspection_id, idempotency_key)
);

CREATE OR REPLACE FUNCTION fn_guard_production_fqc_cancellation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    inspection production_fqc_inspections%ROWTYPE;
    report_status SMALLINT;
BEGIN
    SELECT * INTO inspection
    FROM production_fqc_inspections
    WHERE id = NEW.inspection_id
    FOR UPDATE;
    SELECT status INTO report_status
    FROM production_daily_reports
    WHERE id = NEW.source_report_id
      AND is_deleted = FALSE;

    IF inspection.id IS NULL
       OR inspection.source_report_id <> NEW.source_report_id
       OR report_status <> -1 THEN
        RAISE EXCEPTION
            'FQC cancellation requires its exact reversed source report'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_cancellation_source_guard';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM stock_document_items item
        JOIN stock_documents document
          ON document.id = item.doc_id
        WHERE item.source_daily_report_item_id =
              inspection.source_report_item_id
          AND item.is_deleted = FALSE
          AND document.is_deleted = FALSE
          AND document.doc_type = 'FINISHED_IN'
          AND document.status <> -1
    ) THEN
        RAISE EXCEPTION
            'active FINISHED_IN must be reversed or removed before FQC cancellation'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_cancellation_inbound_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_fqc_cancellation
    BEFORE INSERT ON production_fqc_cancellation_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_cancellation();

CREATE OR REPLACE FUNCTION fn_apply_production_fqc_cancellation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM set_config(
        'app.production_fqc_projection_id',
        NEW.inspection_id::text,
        TRUE);
    UPDATE production_fqc_inspections
    SET status = 'CANCELLED',
        updated_at = now()
    WHERE id = NEW.inspection_id;
    PERFORM set_config('app.production_fqc_projection_id', '', TRUE);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_apply_production_fqc_cancellation
    AFTER INSERT ON production_fqc_cancellation_events
    FOR EACH ROW EXECUTE FUNCTION fn_apply_production_fqc_cancellation();

CREATE TRIGGER trg_guard_production_fqc_cancellation_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_cancellation_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_append_only();
ALTER TABLE production_fqc_cancellation_events
    ENABLE ALWAYS TRIGGER
        trg_guard_production_fqc_cancellation_append_only;

CREATE OR REPLACE FUNCTION fn_guard_production_fqc_release_active()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_fqc_inspections
        WHERE id = NEW.inspection_id
          AND status = 'CANCELLED'
    ) THEN
        RAISE EXCEPTION
            'cancelled FQC inspection cannot authorize FINISHED_IN'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_cancelled_release_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_fqc_release_active
    BEFORE INSERT ON production_fqc_release_commands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_fqc_release_active();

CREATE TRIGGER trg_audit_production_fqc_cancellation_events
    AFTER INSERT OR UPDATE OR DELETE
    ON production_fqc_cancellation_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE production_fqc_cancellation_events IS
    'Append-only cancellation evidence for a reversed source report; FQC decisions remain immutable history';
