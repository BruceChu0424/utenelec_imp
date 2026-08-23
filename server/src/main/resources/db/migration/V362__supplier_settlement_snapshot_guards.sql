-- V362: frozen supplier statement amounts and lines are immutable. Lifecycle
-- columns may advance, but financial snapshots change only through reversal +
-- a new batch. Deferred totals enforce header/line conservation at commit.

CREATE OR REPLACE FUNCTION fn_guard_supplier_settlement_batch_snapshot()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='supplier settlement batches are preserved; use reversal',
            CONSTRAINT='supplier_settlement_batch_snapshot_guard';
    END IF;
    IF NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
       OR NEW.currency_id IS DISTINCT FROM OLD.currency_id
       OR NEW.settlement_method_id IS DISTINCT FROM OLD.settlement_method_id
       OR NEW.period_start IS DISTINCT FROM OLD.period_start
       OR NEW.period_end IS DISTINCT FROM OLD.period_end
       OR NEW.due_date IS DISTINCT FROM OLD.due_date
       OR NEW.opening_balance_original IS DISTINCT FROM OLD.opening_balance_original
       OR NEW.period_posted_original IS DISTINCT FROM OLD.period_posted_original
       OR NEW.period_paid_original IS DISTINCT FROM OLD.period_paid_original
       OR NEW.period_offset_original IS DISTINCT FROM OLD.period_offset_original
       OR NEW.closing_balance_original IS DISTINCT FROM OLD.closing_balance_original
       OR NEW.opening_balance_local IS DISTINCT FROM OLD.opening_balance_local
       OR NEW.period_posted_local IS DISTINCT FROM OLD.period_posted_local
       OR NEW.period_paid_local IS DISTINCT FROM OLD.period_paid_local
       OR NEW.period_offset_local IS DISTINCT FROM OLD.period_offset_local
       OR NEW.closing_balance_local IS DISTINCT FROM OLD.closing_balance_local
       OR NEW.snapshot_hash IS DISTINCT FROM OLD.snapshot_hash
       OR NEW.line_count IS DISTINCT FROM OLD.line_count THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='supplier settlement financial snapshot is immutable; reverse and regenerate',
            CONSTRAINT='supplier_settlement_batch_snapshot_guard';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_supplier_settlement_batch_snapshot
    BEFORE UPDATE OR DELETE ON supplier_settlement_batches
    FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_settlement_batch_snapshot();

CREATE OR REPLACE FUNCTION fn_guard_supplier_settlement_line_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE='55000',
        MESSAGE='supplier settlement snapshot lines are append-only; reverse the batch',
        CONSTRAINT='supplier_settlement_line_append_only_guard';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_supplier_settlement_lines_append_only
    BEFORE UPDATE OR DELETE ON supplier_settlement_batch_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_settlement_line_append_only();

CREATE OR REPLACE FUNCTION fn_validate_supplier_settlement_batch_totals()
RETURNS TRIGGER AS $$
DECLARE
    target_id UUID := COALESCE(
        NULLIF(to_jsonb(NEW)->>'batch_id','')::UUID,
        NULLIF(to_jsonb(NEW)->>'id','')::UUID);
    header supplier_settlement_batches%ROWTYPE;
    line_count_value BIGINT;
    opening_original NUMERIC(18,4);
    posted_original NUMERIC(18,4);
    paid_original NUMERIC(18,4);
    offset_original NUMERIC(18,4);
    closing_original NUMERIC(18,4);
    opening_local NUMERIC(18,4);
    posted_local NUMERIC(18,4);
    paid_local NUMERIC(18,4);
    offset_local NUMERIC(18,4);
    closing_local NUMERIC(18,4);
BEGIN
    SELECT * INTO header FROM supplier_settlement_batches WHERE id=target_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT COUNT(*),
           COALESCE(SUM(opening_balance_original),0),COALESCE(SUM(period_posted_original),0),
           COALESCE(SUM(period_paid_original),0),COALESCE(SUM(period_offset_original),0),
           COALESCE(SUM(closing_balance_original),0),COALESCE(SUM(opening_balance_local),0),
           COALESCE(SUM(period_posted_local),0),COALESCE(SUM(period_paid_local),0),
           COALESCE(SUM(period_offset_local),0),COALESCE(SUM(closing_balance_local),0)
    INTO line_count_value,opening_original,posted_original,paid_original,offset_original,
         closing_original,opening_local,posted_local,paid_local,offset_local,closing_local
    FROM supplier_settlement_batch_lines WHERE batch_id=target_id;
    IF header.line_count<>line_count_value
       OR header.opening_balance_original<>opening_original
       OR header.period_posted_original<>posted_original
       OR header.period_paid_original<>paid_original
       OR header.period_offset_original<>offset_original
       OR header.closing_balance_original<>closing_original
       OR header.opening_balance_local<>opening_local
       OR header.period_posted_local<>posted_local
       OR header.period_paid_local<>paid_local
       OR header.period_offset_local<>offset_local
       OR header.closing_balance_local<>closing_local THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='supplier settlement header totals do not equal frozen lines',
            CONSTRAINT='supplier_settlement_batch_totals_guard';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_validate_supplier_settlement_batch_totals_header
    AFTER INSERT OR UPDATE ON supplier_settlement_batches
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_validate_supplier_settlement_batch_totals();
CREATE CONSTRAINT TRIGGER trg_validate_supplier_settlement_batch_totals_line
    AFTER INSERT ON supplier_settlement_batch_lines
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_validate_supplier_settlement_batch_totals();
