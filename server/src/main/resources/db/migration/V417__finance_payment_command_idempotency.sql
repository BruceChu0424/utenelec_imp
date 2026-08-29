-- V417: finance-payment create idempotency and optimistic draft concurrency.
-- Existing rows remain valid with a null command identity. New runtime creates
-- are required by FinancePaymentService to persist a paired key and SHA-256 hash.

ALTER TABLE finance_payments
    ADD COLUMN version BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN create_idempotency_key VARCHAR(128),
    ADD COLUMN create_request_hash VARCHAR(64),
    ADD CONSTRAINT finance_payments_create_command_shape_chk CHECK (
        (create_idempotency_key IS NULL AND create_request_hash IS NULL)
        OR (
            create_idempotency_key IS NOT NULL
            AND char_length(btrim(create_idempotency_key)) BETWEEN 8 AND 128
            AND create_idempotency_key ~ '^[A-Za-z0-9._:-]+$'
            AND create_request_hash IS NOT NULL
            AND create_request_hash ~ '^[0-9a-f]{64}$'
        )
    ) NOT VALID;

ALTER TABLE finance_payments
    VALIDATE CONSTRAINT finance_payments_create_command_shape_chk;

CREATE UNIQUE INDEX uq_finance_payments_create_idempotency
    ON finance_payments(maker_id, create_idempotency_key)
    WHERE create_idempotency_key IS NOT NULL;

CREATE OR REPLACE FUNCTION fn_guard_finance_payment_create_command()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.create_idempotency_key IS NOT NULL
       AND (
           NEW.create_idempotency_key IS DISTINCT FROM OLD.create_idempotency_key
           OR NEW.create_request_hash IS DISTINCT FROM OLD.create_request_hash
       ) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='finance payment create command identity is immutable',
            CONSTRAINT='finance_payments_create_command_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_finance_payment_create_command
    BEFORE UPDATE OF create_idempotency_key, create_request_hash
    ON finance_payments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_payment_create_command();

COMMENT ON COLUMN finance_payments.version IS
    'JPA optimistic version returned to draft editors and required on update';
COMMENT ON COLUMN finance_payments.create_idempotency_key IS
    'Maker-scoped client command key; paired with create_request_hash for safe retry replay';
COMMENT ON COLUMN finance_payments.create_request_hash IS
    'SHA-256 of the canonical server-effective create request';
