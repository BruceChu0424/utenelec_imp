-- V129: pre-launch integrity guards, migration-run audit, and long-term indexes.
--
-- The legacy loader is intentionally destructive. Every invocation is recorded
-- here so a cutover/reconciliation report can identify exactly what ran.
CREATE TABLE legacy_migration_runs (
    run_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target       TEXT NOT NULL,
    status       TEXT NOT NULL
                 CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    started_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at  TIMESTAMPTZ,
    exit_code    INTEGER,
    database_user TEXT NOT NULL DEFAULT CURRENT_USER
);

CREATE INDEX idx_legacy_migration_runs_started
    ON legacy_migration_runs (started_at DESC);

COMMENT ON TABLE legacy_migration_runs IS
    'Destructive legacy bootstrap run history; SUCCESS is not a reconciliation result.';

-- Runtime posting already derives settlement from balance. Bring imported rows
-- onto the same invariant before enforcing it for every future write.
UPDATE ar_ap_ledger
SET is_settled = (amount_balance = 0),
    settled_date = CASE
        WHEN amount_balance = 0 THEN COALESCE(settled_date, bill_date)
        ELSE NULL
    END,
    updated_at = CURRENT_TIMESTAMP
WHERE is_settled IS DISTINCT FROM (amount_balance = 0)
   OR (amount_balance = 0 AND settled_date IS NULL)
   OR (amount_balance <> 0 AND settled_date IS NOT NULL);

ALTER TABLE ar_ap_ledger
    ADD CONSTRAINT ar_ap_ledger_balance_consistency_chk
        CHECK (amount_balance = amount_original_local - amount_settled),
    ADD CONSTRAINT ar_ap_ledger_settled_consistency_chk
        CHECK (
            (is_settled AND amount_balance = 0 AND settled_date IS NOT NULL)
            OR
            (NOT is_settled AND amount_balance <> 0 AND settled_date IS NULL)
        );

-- Existing legacy AR rows with deleted customers are repaired by the revised
-- finance import. NOT VALID protects all new/updated rows immediately while
-- allowing V129 to be applied before that controlled re-import.
ALTER TABLE ar_ap_ledger
    ADD CONSTRAINT ar_ap_ledger_party_shape_chk
        CHECK (
            (direction = 'AR' AND client_id IS NOT NULL AND supplier_id IS NULL)
            OR
            (direction = 'AP' AND supplier_id IS NOT NULL AND client_id IS NULL)
        ) NOT VALID;

DROP INDEX IF EXISTS idx_arap_client;
DROP INDEX IF EXISTS idx_arap_supplier;
DROP INDEX IF EXISTS idx_arap_direction;
DROP INDEX IF EXISTS idx_arap_settled;
DROP INDEX IF EXISTS idx_arap_bill_no;

CREATE INDEX idx_arap_client_date
    ON ar_ap_ledger (client_id, bill_date DESC)
    WHERE direction = 'AR' AND is_deleted = FALSE AND status = 1;
CREATE INDEX idx_arap_supplier_date
    ON ar_ap_ledger (supplier_id, bill_date DESC)
    WHERE direction = 'AP' AND is_deleted = FALSE AND status = 1;
CREATE INDEX idx_arap_open_date
    ON ar_ap_ledger (direction, bill_date DESC)
    WHERE is_deleted = FALSE AND status = 1 AND is_settled = FALSE;

-- Query endpoints filter one dimension and sort by transaction_date. Composite
-- indexes avoid a separate sort and supersede the corresponding single-column
-- indexes while retaining idx_sm_date for date-only reporting.
CREATE INDEX idx_sm_warehouse_date
    ON stock_movements (warehouse_id, transaction_date DESC);
CREATE INDEX idx_sm_goods_date
    ON stock_movements (goods_id, transaction_date DESC);
CREATE INDEX idx_sm_type_date
    ON stock_movements (movement_type, transaction_date DESC);

DROP INDEX IF EXISTS idx_sm_wh;
DROP INDEX IF EXISTS idx_sm_goods;
DROP INDEX IF EXISTS idx_sm_type;

ALTER TABLE stock_movements
    ADD CONSTRAINT stock_movements_direction_chk
        CHECK (direction IN (-1, 1));

-- Keep the high-volume cost table out of the DEFAULT partition for the next
-- two decades. DEFAULT remains the fail-safe for exceptional historical dates.
DO $$
DECLARE
    partition_year INTEGER;
BEGIN
    FOR partition_year IN 2031..2050 LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS production_plan_costs_%s '
            'PARTITION OF production_plan_costs '
            'FOR VALUES FROM (%L) TO (%L)',
            partition_year,
            make_date(partition_year, 1, 1),
            make_date(partition_year + 1, 1, 1)
        );
    END LOOP;
END
$$;

-- uq_ppc_legacy(legacy_id, bill_date) already serves legacy_id prefix lookups.
DROP INDEX IF EXISTS idx_ppc_legacy;

ANALYZE ar_ap_ledger;
ANALYZE stock_movements;
ANALYZE production_plan_costs;
