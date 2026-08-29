-- ============================================================================
-- V403: immutable functional-currency authority on the currency UUID.
--
-- Codes and names are editable business labels. They must never decide whether
-- an account balance is in the functional currency. The reviewed legacy source
-- identifies exactly one active RMB row (legacy_id=1); freeze that fact on its
-- UUID and make every application path consume this column.
-- ============================================================================

-- A genuinely empty installation has no imported currency rows. Seed one
-- deterministic functional currency there; a non-empty installation with no
-- reviewed legacy RMB row remains fail-closed for manual reconciliation.
INSERT INTO currencies(
    id, legacy_id, code, name, exchange_rate, status, auto_created, is_deleted)
SELECT
    '40300000-0000-4000-8100-000000000001'::UUID,
    1, 'CNY', '人民币', 1, '使用', TRUE, FALSE
WHERE NOT EXISTS (SELECT 1 FROM currencies);

DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM currencies
    WHERE legacy_id = 1
      AND status = '使用'
      AND COALESCE(is_deleted, FALSE) = FALSE;
    IF v_count <> 1 THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format(
                'functional currency authority requires exactly one active currencies.legacy_id=1 row; found %s',
                v_count);
    END IF;
END;
$$;

ALTER TABLE currencies
    ADD COLUMN is_base_currency BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE currencies
SET is_base_currency = TRUE
WHERE legacy_id = 1
  AND status = '使用'
  AND COALESCE(is_deleted, FALSE) = FALSE;

CREATE UNIQUE INDEX uq_currencies_single_base_currency
    ON currencies(is_base_currency)
    WHERE is_base_currency;

ALTER TABLE currencies
    ADD CONSTRAINT currencies_base_currency_active_chk CHECK (
        NOT is_base_currency
        OR (status = '使用' AND COALESCE(is_deleted, FALSE) = FALSE)
    ) NOT VALID;
ALTER TABLE currencies
    VALIDATE CONSTRAINT currencies_base_currency_active_chk;

CREATE OR REPLACE FUNCTION fn_guard_base_currency_authority()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' AND OLD.is_base_currency THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'functional currency UUID cannot be deleted';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF NEW.is_base_currency IS DISTINCT FROM OLD.is_base_currency THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'functional currency UUID authority is immutable; use a reviewed forward migration';
        END IF;
        IF OLD.is_base_currency
           AND (NEW.status IS DISTINCT FROM '使用'
                OR COALESCE(NEW.is_deleted, FALSE)) THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'functional currency UUID cannot be disabled or deleted';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_base_currency_authority
    BEFORE UPDATE OF is_base_currency, status, is_deleted OR DELETE
    ON currencies
    FOR EACH ROW EXECUTE FUNCTION fn_guard_base_currency_authority();

-- Strengthen the V402 INSERT guard now that a UUID-bound functional-currency
-- authority exists.  A syntactically valid basis must also match the currency.
CREATE OR REPLACE FUNCTION fn_guard_new_legacy_balance_adjustment_basis()
RETURNS TRIGGER AS $$
DECLARE
    v_base_currency BOOLEAN;
BEGIN
    SELECT currency.is_base_currency
      INTO v_base_currency
      FROM currencies currency
     WHERE currency.id = NEW.currency_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'balance-adjustment currency UUID does not exist';
    END IF;
    IF NEW.local_amount_basis = 'LEGACY_REFERENCE_RATE' THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'LEGACY_REFERENCE_RATE is historical V400 evidence and cannot be used by new balance-adjustment rows';
    END IF;
    IF NEW.delta_balance = 0 THEN
        IF NEW.local_amount_basis <> 'NO_CHANGE' THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'zero-delta balance verification must use NO_CHANGE';
        END IF;
    ELSIF v_base_currency THEN
        IF NEW.local_amount_basis <> 'BASE_CURRENCY_IDENTITY' THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'functional-currency balance adjustment must use BASE_CURRENCY_IDENTITY';
        END IF;
    ELSIF NEW.local_amount_basis <> 'FINANCE_EXPLICIT_LOCAL' THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'foreign-currency balance adjustment must use FINANCE_EXPLICIT_LOCAL';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON COLUMN currencies.is_base_currency IS
    'Immutable UUID-bound functional-currency authority; codes, names and reference exchange rates are display/default data only';
COMMENT ON FUNCTION fn_guard_base_currency_authority() IS
    'Prevents mutable labels or ordinary master-data edits from changing the functional-currency identity';
COMMENT ON FUNCTION fn_guard_new_legacy_balance_adjustment_basis() IS
    'Rejects legacy reference-rate writes and enforces each new GL basis against the immutable functional-currency UUID';
