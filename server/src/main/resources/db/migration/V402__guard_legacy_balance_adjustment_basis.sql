-- ============================================================================
-- V402: LEGACY_REFERENCE_RATE is historical evidence, never a new-write mode.
--
-- V401 classifies rows created under immutable V400 without updating them.
-- The value must remain queryable for replay, but allowing a new INSERT to use
-- it would reintroduce the mutable currency-master reference-rate defect.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_guard_new_legacy_balance_adjustment_basis()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.local_amount_basis = 'LEGACY_REFERENCE_RATE' THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'LEGACY_REFERENCE_RATE is historical V400 evidence and cannot be used by new balance-adjustment rows';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_new_legacy_balance_adjustment_basis
    BEFORE INSERT ON account_balance_adjustment_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_new_legacy_balance_adjustment_basis();

COMMENT ON FUNCTION fn_guard_new_legacy_balance_adjustment_basis() IS
    'Preserves V400 replay evidence while preventing new writes from using a mutable currency-master reference rate';
