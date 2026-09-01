-- V433: retry-safe, all-or-nothing warehouse arrival-exception batch posting.
--
-- A batch submits finance-approved receipt quantities into the existing
-- purchase/subcontract receipt approval and IQC pipeline.  It records command
-- identity and terminal receipt-group results; it does not claim that usable
-- inventory has increased (warehouse confirmation after IQC PASS is the usable-stock gate).

CREATE TABLE warehouse_arrival_exception_stock_in_batches (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id               UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    actor_employee_id           UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    idempotency_key             VARCHAR(128) NOT NULL,
    request_hash                CHAR(64) NOT NULL,
    status                      VARCHAR(16) NOT NULL DEFAULT 'PENDING',
    requested_exception_count   INTEGER NOT NULL,
    receipt_group_count         INTEGER,
    submitted_for_inspection    BOOLEAN NOT NULL DEFAULT FALSE,
    result_snapshot             JSONB,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at                TIMESTAMPTZ,
    CONSTRAINT wh_arrival_stock_in_batch_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 128
        AND idempotency_key ~ '^[A-Za-z0-9._:-]+$'
    ),
    CONSTRAINT wh_arrival_stock_in_batch_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT wh_arrival_stock_in_batch_count_chk CHECK (
        requested_exception_count BETWEEN 1 AND 100
    ),
    CONSTRAINT wh_arrival_stock_in_batch_state_chk CHECK (
        (status = 'PENDING'
            AND receipt_group_count IS NULL
            AND submitted_for_inspection = FALSE
            AND result_snapshot IS NULL
            AND completed_at IS NULL)
        OR
        (status = 'COMPLETED'
            AND receipt_group_count BETWEEN 1 AND requested_exception_count
            AND submitted_for_inspection = TRUE
            AND jsonb_typeof(result_snapshot) = 'object'
            AND completed_at IS NOT NULL)
    ),
    CONSTRAINT uq_wh_arrival_stock_in_actor_key
        UNIQUE (actor_user_id, idempotency_key)
);

CREATE TABLE warehouse_arrival_exception_stock_in_batch_items (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id                    UUID NOT NULL
        REFERENCES warehouse_arrival_exception_stock_in_batches(id) ON DELETE RESTRICT,
    line_no                     INTEGER NOT NULL,
    arrival_exception_id        UUID NOT NULL
        REFERENCES procurement_arrival_exceptions(id) ON DELETE RESTRICT,
    expected_version            BIGINT NOT NULL,
    order_type                  VARCHAR(16) NOT NULL,
    receipt_id                  UUID NOT NULL,
    receipt_bill_no_snapshot    VARCHAR(100) NOT NULL,
    result_status               VARCHAR(32) NOT NULL,
    result_version              BIGINT NOT NULL,
    submitted_for_inspection    BOOLEAN NOT NULL DEFAULT TRUE,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT wh_arrival_stock_in_item_line_chk CHECK (line_no >= 1),
    CONSTRAINT wh_arrival_stock_in_item_version_chk CHECK (
        expected_version >= 1 AND result_version >= expected_version
    ),
    CONSTRAINT wh_arrival_stock_in_item_type_chk CHECK (
        order_type IN ('PURCHASE', 'SUBCONTRACT')
    ),
    CONSTRAINT wh_arrival_stock_in_item_bill_no_chk CHECK (
        length(btrim(receipt_bill_no_snapshot)) BETWEEN 1 AND 100
    ),
    CONSTRAINT wh_arrival_stock_in_item_status_chk CHECK (
        result_status IN ('RECEIPT_POSTED', 'CLOSED')
    ),
    CONSTRAINT wh_arrival_stock_in_item_submission_chk CHECK (
        submitted_for_inspection = TRUE
    ),
    CONSTRAINT uq_wh_arrival_stock_in_batch_line UNIQUE (batch_id, line_no),
    CONSTRAINT uq_wh_arrival_stock_in_batch_exception
        UNIQUE (batch_id, arrival_exception_id)
);

CREATE INDEX idx_wh_arrival_stock_in_batch_created
    ON warehouse_arrival_exception_stock_in_batches(created_at, id);

CREATE INDEX idx_wh_arrival_stock_in_item_exception
    ON warehouse_arrival_exception_stock_in_batch_items(arrival_exception_id, batch_id);

CREATE INDEX idx_wh_arrival_stock_in_item_receipt
    ON warehouse_arrival_exception_stock_in_batch_items(order_type, receipt_id, batch_id);

CREATE OR REPLACE FUNCTION fn_guard_wh_arrival_stock_in_batch()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'warehouse arrival stock-in batches are append-only'
            USING ERRCODE = '55000',
                  CONSTRAINT = 'wh_arrival_stock_in_batch_append_only';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.status <> 'PENDING'
           OR NEW.status <> 'COMPLETED'
           OR NEW.id IS DISTINCT FROM OLD.id
           OR NEW.actor_user_id IS DISTINCT FROM OLD.actor_user_id
           OR NEW.actor_employee_id IS DISTINCT FROM OLD.actor_employee_id
           OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
           OR NEW.request_hash IS DISTINCT FROM OLD.request_hash
           OR NEW.requested_exception_count IS DISTINCT FROM OLD.requested_exception_count
           OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'warehouse arrival stock-in batch identity/result is immutable'
                USING ERRCODE = '55000',
                      CONSTRAINT = 'wh_arrival_stock_in_batch_transition_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_wh_arrival_stock_in_batch
    BEFORE UPDATE OR DELETE
    ON warehouse_arrival_exception_stock_in_batches
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wh_arrival_stock_in_batch();

ALTER TABLE warehouse_arrival_exception_stock_in_batches
    ENABLE ALWAYS TRIGGER trg_guard_wh_arrival_stock_in_batch;

CREATE OR REPLACE FUNCTION fn_guard_wh_arrival_stock_in_batch_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'warehouse arrival stock-in batch items are append-only'
        USING ERRCODE = '55000',
              CONSTRAINT = 'wh_arrival_stock_in_batch_item_append_only';
END;
$$;

CREATE TRIGGER trg_guard_wh_arrival_stock_in_batch_item
    BEFORE UPDATE OR DELETE
    ON warehouse_arrival_exception_stock_in_batch_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_wh_arrival_stock_in_batch_item();

ALTER TABLE warehouse_arrival_exception_stock_in_batch_items
    ENABLE ALWAYS TRIGGER trg_guard_wh_arrival_stock_in_batch_item;

CREATE TRIGGER trg_audit_warehouse_arrival_exception_stock_in_batches
    AFTER INSERT OR UPDATE OR DELETE
    ON warehouse_arrival_exception_stock_in_batches
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_warehouse_arrival_exception_stock_in_batch_items
    AFTER INSERT OR UPDATE OR DELETE
    ON warehouse_arrival_exception_stock_in_batch_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE warehouse_arrival_exception_stock_in_batches IS
    'Actor-scoped idempotent command ledger for atomic finance-approved receipt submission into IQC.';

COMMENT ON TABLE warehouse_arrival_exception_stock_in_batch_items IS
    'Immutable requested exception identities, resolved receipt groups, and terminal exception results for one batch.';

COMMENT ON COLUMN warehouse_arrival_exception_stock_in_batches.submitted_for_inspection IS
    'True only after every receipt group has entered the existing receipt-approval/IQC pipeline; not proof of usable inventory.';
