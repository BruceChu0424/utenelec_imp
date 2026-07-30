-- V142: database-level backstops for posting idempotency and cumulative
-- quantity updates.
--
-- Service-level row/advisory locks serialize the normal approval paths. These
-- constraints and triggers are deliberately kept as a second line of defence
-- for imports, maintenance scripts, and future code paths.

-- One effective business document may create at most one AR/AP posting. The
-- posting service physically removes a row when an un-settled document is
-- reversed, so a partial active-row index preserves the intended lifecycle.
CREATE UNIQUE INDEX uq_arap_active_source
    ON ar_ap_ledger (source_doc_type, source_doc_id)
    WHERE source_doc_id IS NOT NULL
      AND is_deleted = FALSE;

-- Reconciliation posting is idempotent per source document and account.
-- BANK_TRANSFER intentionally aggregates multiple inbound lines that target
-- the same account into a single reconciliation row.
CREATE UNIQUE INDEX uq_finance_reconciliation_active_source_account
    ON finance_reconciliations (source_doc_type, source_doc_id, account_id)
    WHERE source_doc_id IS NOT NULL
      AND account_id IS NOT NULL
      AND is_deleted = FALSE;

-- Account totals are denormalized for fast reporting, but they must always
-- reconcile to the current balance. Fail the migration if an import violates
-- the invariant instead of letting an incorrect financial opening go live.
ALTER TABLE accounts
    ADD CONSTRAINT accounts_balance_consistency_chk
        CHECK (
            balance_current
                = init_balance + receipts_total - payments_total
        );

-- Legacy stock imports contain zero/negative historical quantities. Do not
-- rewrite those audit rows here, but reject every new or modified invalid row.
ALTER TABLE stock_movements
    ADD CONSTRAINT stock_movements_positive_qty_chk
        CHECK (qty > 0) NOT VALID;

-- PostgreSQL serializes concurrent UPDATEs of the same row. The common
-- fn_guard_processed_quantity trigger (introduced in V132) therefore evaluates
-- each increment against the latest committed cumulative value. Historical
-- overages may be reduced, but can never be increased further.
CREATE TRIGGER trg_production_plan_finished_guard
    BEFORE INSERT OR UPDATE OF fqty
    ON production_plan_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'fqty', 'qty', '');

CREATE TRIGGER trg_production_plan_inbound_guard
    BEFORE INSERT OR UPDATE OF iqty
    ON production_plan_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'iqty', 'qty', '');

CREATE TRIGGER trg_plan_order_link_produced_guard
    BEFORE INSERT OR UPDATE OF produced_qty
    ON plan_order_item_links
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'produced_qty', 'allocated_qty', '');

CREATE TRIGGER trg_plan_order_link_inbound_guard
    BEFORE INSERT OR UPDATE OF inbound_qty
    ON plan_order_item_links
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'inbound_qty', 'allocated_qty', '');

COMMENT ON CONSTRAINT accounts_balance_consistency_chk ON accounts IS
    'Current balance must equal opening balance plus receipts minus payments.';

COMMENT ON CONSTRAINT stock_movements_positive_qty_chk ON stock_movements IS
    'All newly written stock movements use a positive magnitude; direction carries the sign.';
