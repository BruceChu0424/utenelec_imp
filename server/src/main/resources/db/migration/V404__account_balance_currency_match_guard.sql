-- ============================================================================
-- V404: every new balance-adjustment currency snapshot must match its account.
--
-- V403 validates the basis against the currency UUID but did not prove that the
-- submitted currency UUID is the account's own currency.  Close that direct-SQL
-- bypass while retaining all immutable V400 history.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_guard_new_legacy_balance_adjustment_basis()
RETURNS TRIGGER AS $$
DECLARE
    v_account_currency UUID;
    v_account_status TEXT;
    v_account_deleted BOOLEAN;
    v_currency_status TEXT;
    v_currency_deleted BOOLEAN;
    v_base_currency BOOLEAN;
BEGIN
    SELECT account.currency_id,
           account.status,
           COALESCE(account.is_deleted, FALSE),
           currency.status,
           COALESCE(currency.is_deleted, FALSE),
           currency.is_base_currency
      INTO v_account_currency,
           v_account_status,
           v_account_deleted,
           v_currency_status,
           v_currency_deleted,
           v_base_currency
      FROM accounts account
      JOIN currencies currency ON currency.id = NEW.currency_id
     WHERE account.id = NEW.account_id
     FOR SHARE OF account, currency;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'balance-adjustment account or currency UUID does not exist';
    END IF;
    IF v_account_currency IS DISTINCT FROM NEW.currency_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'balance-adjustment currency UUID must match the account currency UUID';
    END IF;
    IF v_account_status IS DISTINCT FROM '使用' OR v_account_deleted
       OR v_currency_status IS DISTINCT FROM '使用' OR v_currency_deleted THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'balance-adjustment account and currency must be active';
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

COMMENT ON FUNCTION fn_guard_new_legacy_balance_adjustment_basis() IS
    'Rejects legacy reference-rate writes and enforces account/currency UUID equality plus the immutable functional-currency basis';
