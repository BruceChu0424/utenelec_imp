-- ============================================================================
-- V405: the functional-currency UUID itself is immutable.
-- ============================================================================

DROP TRIGGER trg_guard_base_currency_authority ON currencies;

CREATE OR REPLACE FUNCTION fn_guard_base_currency_authority()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' AND OLD.is_base_currency THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'functional currency UUID cannot be deleted';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.is_base_currency AND NEW.id IS DISTINCT FROM OLD.id THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'functional currency UUID primary key is immutable';
        END IF;
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
    BEFORE UPDATE OF id, is_base_currency, status, is_deleted OR DELETE
    ON currencies
    FOR EACH ROW EXECUTE FUNCTION fn_guard_base_currency_authority();

COMMENT ON FUNCTION fn_guard_base_currency_authority() IS
    'Prevents primary-key, role, status or delete changes from altering the immutable functional-currency UUID authority';
