-- ============================================================================
-- V401: account-balance reconciliation uses the account's own currency.
--
-- V42 defines currencies.exchange_rate as reference data only.  V400 wrongly
-- coupled a native-currency balance correction to that mutable reference rate.
-- Keep V400 bytes immutable and move new rows to an explicit local-amount basis:
--   * account balance / account statement: always the account currency;
--   * GL projection: CNY is identity, foreign currency uses a finance-approved
--     explicit local-currency delta, and a zero-delta verification needs neither.
-- Existing V400 rows retain their frozen rate/formula and remain replayable.
-- ============================================================================

ALTER TABLE account_balance_adjustment_items
    ADD COLUMN local_amount_basis TEXT NOT NULL DEFAULT 'LEGACY_REFERENCE_RATE';

-- The default above classifies existing immutable rows without firing their
-- append-only UPDATE trigger.  New application writes must always choose a basis.
ALTER TABLE account_balance_adjustment_items
    ALTER COLUMN local_amount_basis DROP DEFAULT,
    ALTER COLUMN exchange_rate_snapshot DROP NOT NULL;

ALTER TABLE account_balance_adjustment_items
    DROP CONSTRAINT account_balance_adjustment_items_rate_chk,
    DROP CONSTRAINT account_balance_adjustment_items_local_chk;

ALTER TABLE account_balance_adjustment_items
    ADD CONSTRAINT account_balance_adjustment_items_local_basis_chk CHECK (
        local_amount_basis IN (
            'LEGACY_REFERENCE_RATE',
            'BASE_CURRENCY_IDENTITY',
            'FINANCE_EXPLICIT_LOCAL',
            'NO_CHANGE'
        )
    ) NOT VALID,
    ADD CONSTRAINT account_balance_adjustment_items_local_evidence_chk CHECK (
        (
            local_amount_basis = 'LEGACY_REFERENCE_RATE'
            AND exchange_rate_snapshot IS NOT NULL
            AND exchange_rate_snapshot > 0
            AND delta_local = round(delta_balance * exchange_rate_snapshot, 4)
        )
        OR (
            local_amount_basis = 'BASE_CURRENCY_IDENTITY'
            AND exchange_rate_snapshot = 1
            AND delta_balance <> 0
            AND delta_local = delta_balance
        )
        OR (
            local_amount_basis = 'FINANCE_EXPLICIT_LOCAL'
            AND exchange_rate_snapshot IS NULL
            AND delta_balance <> 0
            AND delta_local <> 0
            AND sign(delta_local) = sign(delta_balance)
        )
        OR (
            local_amount_basis = 'NO_CHANGE'
            AND exchange_rate_snapshot IS NULL
            AND delta_balance = 0
            AND delta_local = 0
        )
    ) NOT VALID;

ALTER TABLE account_balance_adjustment_items
    VALIDATE CONSTRAINT account_balance_adjustment_items_local_basis_chk;
ALTER TABLE account_balance_adjustment_items
    VALIDATE CONSTRAINT account_balance_adjustment_items_local_evidence_chk;

COMMENT ON COLUMN account_balance_adjustment_items.delta_balance IS
    'Signed account-balance correction in the account currency; never converted for account display or account statements';
COMMENT ON COLUMN account_balance_adjustment_items.delta_local IS
    'Frozen signed functional-currency amount used only by the GL projection; CNY is identity and foreign currency is explicitly approved by finance';
COMMENT ON COLUMN account_balance_adjustment_items.exchange_rate_snapshot IS
    'Legacy V400 reference-rate evidence or CNY identity 1; null for finance-explicit foreign-currency local amounts and zero-delta verification';
COMMENT ON COLUMN account_balance_adjustment_items.local_amount_basis IS
    'Authority for delta_local: legacy reference snapshot, CNY identity, finance-explicit local amount, or no-change verification';

COMMENT ON TABLE account_balance_adjustment_items IS
    'Immutable per-account native-currency balance verification plus separately governed functional-currency GL evidence; zero-delta rows prove verification';
