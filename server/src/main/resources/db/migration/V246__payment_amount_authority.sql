-- Payment amounts created before the server-authoritative settlement model cannot be
-- distinguished from client-supplied values. Keep them explicitly unverified; only a
-- successful save through the current service may advance the authority version.
ALTER TABLE finance_payments
    ADD COLUMN amount_authority_version SMALLINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT finance_payments_amount_authority_version_chk
        CHECK (amount_authority_version IN (0, 1));

CREATE INDEX idx_finance_payments_unverified_amounts
    ON finance_payments (bill_date, id)
    WHERE status = 1
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND amount_authority_version = 0;

COMMENT ON COLUMN finance_payments.amount_authority_version IS
    '0=historical or unverified client-era amounts; 1=header and lines recalculated by the current server settlement model';

-- Target-data audit (read-only; run before enabling payment GL regeneration or reversal):
-- SELECT status,
--        COUNT(*) AS payment_count,
--        COUNT(*) FILTER (WHERE legacy_id IS NOT NULL) AS migrated_count,
--        COALESCE(SUM(amount_original), 0) AS amount_original_total,
--        COALESCE(SUM(amount_local), 0) AS amount_local_total,
--        MIN(bill_date) AS first_bill_date,
--        MAX(bill_date) AS last_bill_date
-- FROM finance_payments
-- WHERE COALESCE(is_deleted, FALSE) = FALSE
--   AND amount_authority_version = 0
-- GROUP BY status
-- ORDER BY status;
