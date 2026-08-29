-- V419: maker-scoped, retry-safe warehouse arrival registration commands.
--
-- One authenticated warehouse maker + client key + canonical request hash is
-- bound permanently to one purchase/subcontract receipt result.  The command
-- is inserted as PENDING before any receipt is created, then may transition
-- exactly once to COMPLETED or QUARANTINED in the same transaction.  Existing
-- receipts and arrival exceptions are not guessed or backfilled.

CREATE TABLE warehouse_arrival_registration_commands (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    maker_id                 UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    idempotency_key          VARCHAR(128) NOT NULL,
    request_hash             CHAR(64) NOT NULL,
    order_type               VARCHAR(16) NOT NULL,
    status                   VARCHAR(24) NOT NULL DEFAULT 'PENDING',
    outcome                  VARCHAR(40),
    purchase_receipt_id      UUID REFERENCES purchase_receipts(id) ON DELETE RESTRICT,
    subcontract_receipt_id   UUID REFERENCES subcontract_receipts(id) ON DELETE RESTRICT,
    receipt_bill_no_snapshot VARCHAR(100),
    exception_id             UUID REFERENCES procurement_arrival_exceptions(id) ON DELETE RESTRICT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at             TIMESTAMPTZ,
    CONSTRAINT warehouse_arrival_registration_command_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 128
        AND idempotency_key ~ '^[A-Za-z0-9._:-]+$'
    ),
    CONSTRAINT warehouse_arrival_registration_command_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT warehouse_arrival_registration_command_order_type_chk CHECK (
        order_type IN ('PURCHASE', 'SUBCONTRACT')
    ),
    CONSTRAINT warehouse_arrival_registration_command_receipt_type_chk CHECK (
        (purchase_receipt_id IS NULL AND subcontract_receipt_id IS NULL)
        OR (order_type = 'PURCHASE'
            AND purchase_receipt_id IS NOT NULL
            AND subcontract_receipt_id IS NULL)
        OR (order_type = 'SUBCONTRACT'
            AND purchase_receipt_id IS NULL
            AND subcontract_receipt_id IS NOT NULL)
    ),
    CONSTRAINT warehouse_arrival_registration_command_state_chk CHECK (
        (status = 'PENDING'
            AND outcome IS NULL
            AND purchase_receipt_id IS NULL
            AND subcontract_receipt_id IS NULL
            AND receipt_bill_no_snapshot IS NULL
            AND exception_id IS NULL
            AND completed_at IS NULL)
        OR (status = 'COMPLETED'
            AND outcome = 'SUBMITTED_FOR_INSPECTION'
            AND num_nonnulls(purchase_receipt_id, subcontract_receipt_id) = 1
            AND length(btrim(receipt_bill_no_snapshot)) BETWEEN 1 AND 100
            AND exception_id IS NULL
            AND completed_at IS NOT NULL)
        OR (status = 'QUARANTINED'
            AND outcome = 'EXCESS_QUARANTINED'
            AND num_nonnulls(purchase_receipt_id, subcontract_receipt_id) = 1
            AND length(btrim(receipt_bill_no_snapshot)) BETWEEN 1 AND 100
            AND exception_id IS NOT NULL
            AND completed_at IS NOT NULL)
    ),
    CONSTRAINT uq_warehouse_arrival_registration_maker_key
        UNIQUE (maker_id, idempotency_key)
);

CREATE UNIQUE INDEX uq_warehouse_arrival_registration_purchase_receipt
    ON warehouse_arrival_registration_commands(purchase_receipt_id)
    WHERE purchase_receipt_id IS NOT NULL;

CREATE UNIQUE INDEX uq_warehouse_arrival_registration_subcontract_receipt
    ON warehouse_arrival_registration_commands(subcontract_receipt_id)
    WHERE subcontract_receipt_id IS NOT NULL;

CREATE UNIQUE INDEX uq_warehouse_arrival_registration_exception
    ON warehouse_arrival_registration_commands(exception_id)
    WHERE exception_id IS NOT NULL;

CREATE INDEX idx_warehouse_arrival_registration_created
    ON warehouse_arrival_registration_commands(created_at, id);

CREATE OR REPLACE FUNCTION fn_guard_warehouse_arrival_registration_command()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'PENDING'
           OR NEW.outcome IS NOT NULL
           OR NEW.purchase_receipt_id IS NOT NULL
           OR NEW.subcontract_receipt_id IS NOT NULL
           OR NEW.receipt_bill_no_snapshot IS NOT NULL
           OR NEW.exception_id IS NOT NULL
           OR NEW.completed_at IS NOT NULL THEN
            RAISE EXCEPTION 'warehouse arrival command must start pending'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'warehouse_arrival_registration_command_initial_guard';
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'warehouse arrival registration commands are append-only'
            USING ERRCODE = '55000',
                  CONSTRAINT = 'warehouse_arrival_registration_command_append_only_guard';
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.maker_id IS DISTINCT FROM OLD.maker_id
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
       OR NEW.request_hash IS DISTINCT FROM OLD.request_hash
       OR NEW.order_type IS DISTINCT FROM OLD.order_type
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'warehouse arrival command identity is immutable'
            USING ERRCODE = '55000',
                  CONSTRAINT = 'warehouse_arrival_registration_command_identity_guard';
    END IF;

    IF OLD.status <> 'PENDING' THEN
        RAISE EXCEPTION 'warehouse arrival command terminal result is immutable'
            USING ERRCODE = '55000',
                  CONSTRAINT = 'warehouse_arrival_registration_command_terminal_guard';
    END IF;

    IF NEW.status NOT IN ('COMPLETED', 'QUARANTINED') THEN
        RAISE EXCEPTION 'warehouse arrival command may finalize exactly once'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'warehouse_arrival_registration_command_transition_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_warehouse_arrival_registration_command
    BEFORE INSERT OR UPDATE OR DELETE
    ON warehouse_arrival_registration_commands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_warehouse_arrival_registration_command();

ALTER TABLE warehouse_arrival_registration_commands
    ENABLE ALWAYS TRIGGER trg_guard_warehouse_arrival_registration_command;

CREATE TRIGGER trg_audit_warehouse_arrival_registration_commands
    AFTER INSERT OR UPDATE OR DELETE
    ON warehouse_arrival_registration_commands
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE warehouse_arrival_registration_commands IS
    'Maker-scoped arrival-create command ledger; PENDING may finalize exactly once and terminal results replay verbatim.';
COMMENT ON COLUMN warehouse_arrival_registration_commands.idempotency_key IS
    'Stable client retry key, unique within the authenticated receipt maker.';
COMMENT ON COLUMN warehouse_arrival_registration_commands.request_hash IS
    'SHA-256 of the canonical arrival request, excluding the retry key and server-owned receipt identity.';
