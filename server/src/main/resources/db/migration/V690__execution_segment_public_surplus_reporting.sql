-- A mixed execution segment has two disjoint owners: immutable sales allocations
-- and public surplus = planned_qty - SUM(all sales allocated_qty). Sales closure
-- never transfers that ownership. Existing history, quantities and allocations
-- are deliberately left untouched.

DO $migration$
DECLARE
    v_definition TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_validate_daily_report_execution_segment()'::regprocedure)
    INTO v_definition;
    v_old := 'IF v_has_sales_allocations
           AND NEW.execution_segment_sales_allocation_id IS NULL THEN';
    v_new := 'IF NEW.execution_segment_sales_allocation_id IS NULL
           AND (NEW.sales_order_item_id IS NOT NULL OR v_segment.planned_qty <= (
               SELECT COALESCE(SUM(allocation.allocated_qty), 0)
               FROM execution_segment_sales_allocations allocation
               WHERE allocation.execution_segment_id = NEW.execution_segment_id
           )) THEN';
    IF position(v_old IN v_definition) = 0 THEN
        RAISE EXCEPTION 'V690 daily report ownership guard anchor changed';
    END IF;
    v_definition := replace(v_definition, v_old, v_new);
    v_old := 'OR v_allocation.sales_order_item_id
                  <> NEW.sales_order_item_id';
    IF position(v_old IN v_definition) = 0 THEN
        RAISE EXCEPTION 'V690 daily report sales identity anchor changed';
    END IF;
    EXECUTE replace(v_definition, v_old,
        'OR v_allocation.sales_order_item_id IS DISTINCT FROM NEW.sales_order_item_id');

    SELECT pg_get_functiondef('fn_validate_finished_in_execution_segment()'::regprocedure)
    INTO v_definition;
    v_old := 'IF v_has_sales_allocations
           AND NEW.execution_segment_sales_allocation_id IS NULL THEN';
    v_new := 'IF NEW.execution_segment_sales_allocation_id IS NULL
           AND v_segment.planned_qty <= (
               SELECT COALESCE(SUM(allocation.allocated_qty), 0)
               FROM execution_segment_sales_allocations allocation
               WHERE allocation.execution_segment_id = NEW.execution_segment_id
           ) THEN';
    IF position(v_old IN v_definition) = 0 THEN
        RAISE EXCEPTION 'V690 finished-in ownership guard anchor changed';
    END IF;
    EXECUTE replace(v_definition, v_old, v_new);
END;
$migration$;

CREATE INDEX idx_daily_report_public_execution_fact
    ON production_daily_report_items(execution_segment_id)
    WHERE execution_segment_id IS NOT NULL
      AND execution_segment_sales_allocation_id IS NULL AND NOT is_deleted;
CREATE INDEX idx_finished_in_public_execution_fact
    ON stock_document_items(execution_segment_id)
    WHERE execution_segment_id IS NOT NULL
      AND execution_segment_sales_allocation_id IS NULL AND NOT is_deleted;

CREATE OR REPLACE FUNCTION fn_assert_execution_segment_public_surplus_capacity(p_segment_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_planned NUMERIC(18,4);
    v_public NUMERIC(18,4);
    v_reported NUMERIC(18,4);
    v_approved NUMERIC(18,4);
    v_inbound NUMERIC(18,4);
BEGIN
    IF p_segment_id IS NULL THEN RETURN; END IF;
    IF NOT EXISTS (SELECT 1 FROM production_daily_report_items
            WHERE execution_segment_id = p_segment_id
              AND execution_segment_sales_allocation_id IS NULL AND NOT is_deleted)
       AND NOT EXISTS (SELECT 1 FROM stock_document_items
            WHERE execution_segment_id = p_segment_id
              AND execution_segment_sales_allocation_id IS NULL AND NOT is_deleted) THEN
        RETURN;
    END IF;
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'public surplus capacity writes require READ COMMITTED isolation'
            USING ERRCODE = '25001';
    END IF;
    -- Serialize competing report/stock transactions on the same physical task.
    SELECT planned_qty INTO v_planned FROM production_execution_segments
    WHERE id = p_segment_id FOR UPDATE;
    IF NOT FOUND THEN RETURN; END IF;

    SELECT GREATEST(v_planned - COALESCE(SUM(allocated_qty), 0), 0)
    INTO v_public FROM execution_segment_sales_allocations
    WHERE execution_segment_id = p_segment_id;

    SELECT COALESCE(SUM(item.qty) FILTER (
               WHERE item.fqc_recovery_authorization_id IS NULL), 0),
           COALESCE(SUM(item.qty) FILTER (WHERE report.status = 1), 0)
    INTO v_reported, v_approved
    FROM production_daily_report_items item
    JOIN production_daily_reports report ON report.id = item.report_id
    WHERE item.execution_segment_id = p_segment_id
      AND item.execution_segment_sales_allocation_id IS NULL
      AND item.sales_order_item_id IS NULL
      AND NOT item.is_deleted AND NOT report.is_deleted
      AND report.status IN (0, 1);
    IF v_reported > v_public THEN
        RAISE EXCEPTION 'daily report quantity exceeds its public surplus allocation'
            USING ERRCODE = '23514', CONSTRAINT = 'daily_report_segment_public_capacity_guard';
    END IF;

    SELECT COALESCE(SUM(item.qty), 0) INTO v_inbound
    FROM stock_document_items item
    JOIN stock_documents document ON document.id = item.doc_id
    WHERE item.execution_segment_id = p_segment_id
      AND item.execution_segment_sales_allocation_id IS NULL
      AND NOT item.is_deleted AND NOT document.is_deleted
      AND document.doc_type = 'FINISHED_IN' AND document.status = 1;
    IF v_inbound > LEAST(v_public, v_approved) THEN
        RAISE EXCEPTION 'finished-in quantity exceeds approved public surplus report quantity'
            USING ERRCODE = '23514', CONSTRAINT = 'finished_in_segment_public_report_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_execution_segment_public_surplus_row()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_old UUID;
    v_new UUID;
    v_segment UUID;
BEGIN
    IF TG_TABLE_NAME = 'execution_segment_sales_allocations' THEN
        IF TG_OP <> 'INSERT' THEN v_old := OLD.execution_segment_id; END IF;
        IF TG_OP <> 'DELETE' THEN v_new := NEW.execution_segment_id; END IF;
    ELSE
        IF TG_OP <> 'INSERT' THEN
            IF OLD.execution_segment_sales_allocation_id IS NULL THEN
                v_old := OLD.execution_segment_id;
            END IF;
        END IF;
        IF TG_OP <> 'DELETE' THEN
            IF NEW.execution_segment_sales_allocation_id IS NULL THEN
                v_new := NEW.execution_segment_id;
            END IF;
        END IF;
    END IF;
    FOR v_segment IN SELECT DISTINCT segment FROM unnest(ARRAY[v_old, v_new]) segment
        WHERE segment IS NOT NULL ORDER BY segment
    LOOP
        PERFORM fn_assert_execution_segment_public_surplus_capacity(v_segment);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_assert_daily_report_segment_public_fact
    AFTER INSERT OR UPDATE OR DELETE ON production_daily_report_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_assert_execution_segment_public_surplus_row();
CREATE CONSTRAINT TRIGGER trg_assert_finished_in_segment_public_fact
    AFTER INSERT OR UPDATE OR DELETE ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_assert_execution_segment_public_surplus_row();
CREATE CONSTRAINT TRIGGER trg_assert_sales_allocation_public_capacity
    AFTER INSERT OR UPDATE OR DELETE ON execution_segment_sales_allocations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_assert_execution_segment_public_surplus_row();

CREATE OR REPLACE FUNCTION fn_assert_daily_report_segment_public_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_segment UUID;
BEGIN
    FOR v_segment IN SELECT DISTINCT execution_segment_id
        FROM production_daily_report_items WHERE report_id = NEW.id
          AND execution_segment_id IS NOT NULL
          AND execution_segment_sales_allocation_id IS NULL ORDER BY execution_segment_id
    LOOP
        PERFORM fn_assert_execution_segment_public_surplus_capacity(v_segment);
    END LOOP;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_daily_report_segment_public_status
    AFTER UPDATE OF status, is_deleted ON production_daily_reports
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_assert_daily_report_segment_public_status();

CREATE OR REPLACE FUNCTION fn_assert_stock_document_segment_public_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_segment UUID;
BEGIN
    FOR v_segment IN SELECT DISTINCT execution_segment_id
        FROM stock_document_items WHERE doc_id = NEW.id
          AND execution_segment_id IS NOT NULL
          AND execution_segment_sales_allocation_id IS NULL ORDER BY execution_segment_id
    LOOP
        PERFORM fn_assert_execution_segment_public_surplus_capacity(v_segment);
    END LOOP;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_stock_document_segment_public_status
    AFTER UPDATE OF status, is_deleted ON stock_documents
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_assert_stock_document_segment_public_status();

CREATE OR REPLACE FUNCTION fn_assert_execution_segment_public_capacity_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_assert_execution_segment_public_surplus_capacity(NEW.id);
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_execution_segment_public_capacity_change
    AFTER UPDATE OF planned_qty ON production_execution_segments
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_assert_execution_segment_public_capacity_change();

COMMENT ON FUNCTION fn_assert_execution_segment_public_surplus_capacity(UUID) IS
    'Serializes public surplus report/inbound capacity independently from all frozen sales allocations; recovery stays on its explicit FQC authority.';
