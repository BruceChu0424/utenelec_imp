CREATE TABLE preplan_subcontract_make_batch_reversals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL UNIQUE REFERENCES preplan_subcontract_make_task_batches(id) ON DELETE RESTRICT,
    task_id UUID NOT NULL REFERENCES preplan_subcontract_make_tasks(id) ON DELETE RESTRICT,
    qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
    reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 2 AND 1000),
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_preplan_subcontract_make_batch_reversals_task
    ON preplan_subcontract_make_batch_reversals(task_id);
CREATE INDEX idx_preplan_subcontract_make_batches_application
    ON preplan_subcontract_make_task_batches(application_id,task_id,id);
CREATE INDEX idx_subcontract_prepared_receipt_capacity
    ON stock_reservations(supply_id,source_doc_id) INCLUDE(qty,released_qty)
    WHERE supply_type='PRODUCTION_FINISHED_IN' AND is_deleted=FALSE
      AND owner_type IN ('SUBCONTRACT_PREPARE_TASK','SUBCONTRACT_OUTBOUND');

-- A prepared receipt can feed multiple orders. All remaining task reservations
-- plus issued/unreleased outbound reservations share its one physical quantity.
CREATE FUNCTION fn_assert_subcontract_prepared_source_capacity(p_reservation_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_source UUID; v_document UUID; v_received NUMERIC; v_committed NUMERIC;
BEGIN
    SELECT supply_id,source_doc_id INTO v_source,v_document FROM stock_reservations
    WHERE id=p_reservation_id AND owner_type IN ('SUBCONTRACT_PREPARE_TASK','SUBCONTRACT_OUTBOUND')
      AND supply_type='PRODUCTION_FINISHED_IN' AND is_deleted=FALSE;
    IF v_source IS NULL THEN RETURN; END IF;
    SELECT qty*COALESCE(unit_rate,1) INTO v_received FROM stock_document_items
    WHERE id=v_source AND doc_id=v_document AND is_deleted=FALSE FOR UPDATE;
    SELECT COALESCE(SUM(qty-released_qty),0) INTO v_committed FROM stock_reservations
    WHERE supply_type='PRODUCTION_FINISHED_IN' AND supply_id=v_source
      AND source_doc_id=v_document AND is_deleted=FALSE
      AND owner_type IN ('SUBCONTRACT_PREPARE_TASK','SUBCONTRACT_OUTBOUND');
    IF v_committed>0 AND (v_received IS NULL OR v_committed>v_received) THEN
        RAISE EXCEPTION 'subcontract prepared reservations exceed their finished receipt source'
            USING ERRCODE='23514', CONSTRAINT='subcontract_prepared_source_capacity_guard';
    END IF;
END;
$$;
CREATE FUNCTION fn_check_subcontract_prepared_source_capacity()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP<>'INSERT' AND OLD.owner_type='SUBCONTRACT_PREPARE_TASK' THEN
        PERFORM fn_assert_subcontract_prepared_source_capacity(OLD.id);
    END IF;
    IF TG_OP<>'DELETE' AND NEW.owner_type='SUBCONTRACT_PREPARE_TASK' THEN
        PERFORM fn_assert_subcontract_prepared_source_capacity(NEW.id);
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_prepared_source_capacity
    AFTER INSERT OR UPDATE OR DELETE ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_prepared_source_capacity();
DO $$
DECLARE definition TEXT; patched TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_assert_subcontract_preparation_finished_source(uuid)'::regprocedure)
      INTO definition;
    patched:=replace(definition,
        'AND reservation.qty = stock_item.qty * COALESCE(stock_item.unit_rate, 1)',
        'AND (reservation.qty = stock_item.qty * COALESCE(stock_item.unit_rate, 1)
          OR (plan_item.flow_mode = ''PREPARED_OUTBOUND''
              AND reservation.qty <= stock_item.qty * COALESCE(stock_item.unit_rate, 1)))');
    IF patched=definition THEN RAISE EXCEPTION 'V496 preparation source guard does not match expected lineage'; END IF;
    patched:=regexp_replace(patched,'BEGIN[[:space:]]*',
        E'BEGIN\n    PERFORM fn_assert_subcontract_prepared_source_capacity(p_reservation_id);\n');
    IF position('PERFORM fn_assert_subcontract_prepared_source_capacity' IN patched)=0 THEN
        RAISE EXCEPTION 'V496 cannot install prepared receipt capacity validation';
    END IF;
    EXECUTE patched;
END;
$$;

CREATE FUNCTION fn_guard_subcontract_make_batch_history()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'subcontract make notification facts are append-only'
        USING ERRCODE='23514', CONSTRAINT='subcontract_make_batch_history_guard';
END;
$$;
CREATE TRIGGER trg_subcontract_make_batch_history
    BEFORE UPDATE OR DELETE ON preplan_subcontract_make_task_batches
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_make_batch_history();
CREATE TRIGGER trg_subcontract_make_batch_reversal_history
    BEFORE UPDATE OR DELETE ON preplan_subcontract_make_batch_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_make_batch_history();

CREATE FUNCTION fn_guard_subcontract_make_batch_reversal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_batch preplan_subcontract_make_task_batches%ROWTYPE;
BEGIN
    SELECT * INTO v_batch FROM preplan_subcontract_make_task_batches
    WHERE id=NEW.batch_id FOR UPDATE;
    PERFORM 1 FROM preplan_subcontract_make_tasks WHERE id=v_batch.task_id FOR UPDATE;
    IF v_batch.id IS NULL OR NEW.task_id IS DISTINCT FROM v_batch.task_id
       OR NEW.qty IS DISTINCT FROM v_batch.notify_qty THEN
        RAISE EXCEPTION 'subcontract notification reversal must match its original batch'
            USING ERRCODE='23514', CONSTRAINT='subcontract_make_batch_reversal_lineage_guard';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM subcontract_applications application
        WHERE application.id=v_batch.application_id
          AND (application.status=-1 OR application.is_deleted=TRUE))
       OR EXISTS (
        SELECT 1 FROM subcontract_application_items item
        WHERE item.id=v_batch.application_item_id AND COALESCE(item.ordered_qty,0)<>0)
       OR EXISTS (
        SELECT 1 FROM subcontract_order_item_sources source
        JOIN subcontract_order_items item ON item.id=source.order_item_id
        JOIN subcontract_orders orders ON orders.id=item.order_id
        WHERE source.application_item_id=v_batch.application_item_id
          AND orders.is_deleted=FALSE AND orders.status<>-1)
       OR EXISTS (
        SELECT 1 FROM subcontract_order_item_sources source
        JOIN subcontract_material_plan_items plan_item ON plan_item.order_item_id=source.order_item_id
        JOIN stock_reservations reservation ON reservation.owner_type='SUBCONTRACT_OUTBOUND'
          AND reservation.owner_id=plan_item.id AND reservation.is_deleted=FALSE
        WHERE source.application_item_id=v_batch.application_item_id
          AND (reservation.consumed_qty>0 OR reservation.qty-reservation.released_qty>0)) THEN
        RAISE EXCEPTION 'subcontract notification still has active commercial or physical execution'
            USING ERRCODE='23514', CONSTRAINT='subcontract_make_batch_reversal_downstream_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_subcontract_make_batch_reversal_guard
    BEFORE INSERT ON preplan_subcontract_make_batch_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_make_batch_reversal();

CREATE OR REPLACE FUNCTION fn_assert_subcontract_make_task_batches(p_task_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_status TEXT; v_notified NUMERIC(18,4); v_batches NUMERIC(18,4);
BEGIN
    IF p_task_id IS NULL THEN RETURN; END IF;
    SELECT status,notified_qty INTO v_status,v_notified
    FROM preplan_subcontract_make_tasks WHERE id=p_task_id FOR UPDATE;
    IF v_status IS DISTINCT FROM 'ACTIVE' THEN RETURN; END IF;
    SELECT COALESCE(SUM(batch.notify_qty-COALESCE(reversal.qty,0)),0) INTO v_batches
    FROM preplan_subcontract_make_task_batches batch
    LEFT JOIN preplan_subcontract_make_batch_reversals reversal ON reversal.batch_id=batch.id
    WHERE batch.task_id=p_task_id;
    IF v_notified IS DISTINCT FROM v_batches THEN
        RAISE EXCEPTION 'subcontract make task notified qty lacks exact batch coverage'
            USING ERRCODE='23514', CONSTRAINT='subcontract_make_task_batch_conservation_guard';
    END IF;
END;
$$;
CREATE OR REPLACE FUNCTION fn_assert_subcontract_make_task_batches()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM preplan_subcontract_make_tasks task
        WHERE task.status='ACTIVE' AND task.notified_qty<>(
            SELECT COALESCE(SUM(batch.notify_qty-COALESCE(reversal.qty,0)),0)
            FROM preplan_subcontract_make_task_batches batch
            LEFT JOIN preplan_subcontract_make_batch_reversals reversal ON reversal.batch_id=batch.id
            WHERE batch.task_id=task.id)) THEN
        RAISE EXCEPTION 'subcontract make task notified qty lacks exact batch coverage'
            USING ERRCODE='23514', CONSTRAINT='subcontract_make_task_batch_conservation_guard';
    END IF;
END;
$$;
CREATE OR REPLACE FUNCTION fn_check_subcontract_make_task_batches()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_old_task UUID; v_new_task UUID; v_task UUID;
BEGIN
    IF TG_TABLE_NAME IN ('preplan_subcontract_make_task_batches','preplan_subcontract_make_batch_reversals') THEN
        IF TG_OP<>'INSERT' THEN v_old_task:=OLD.task_id; END IF;
        IF TG_OP<>'DELETE' THEN v_new_task:=NEW.task_id; END IF;
    ELSE
        IF TG_OP<>'INSERT' THEN v_old_task:=OLD.id; END IF;
        IF TG_OP<>'DELETE' THEN v_new_task:=NEW.id; END IF;
    END IF;
    FOR v_task IN SELECT DISTINCT task_id FROM unnest(ARRAY[v_old_task,v_new_task]) AS changed(task_id)
                  WHERE task_id IS NOT NULL ORDER BY task_id
    LOOP
        PERFORM fn_assert_subcontract_make_task_batches(v_task);
    END LOOP;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_make_batch_reversal_conservation
    AFTER INSERT ON preplan_subcontract_make_batch_reversals
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_make_task_batches();
CREATE TRIGGER trg_audit_preplan_subcontract_make_batch_reversals
    AFTER INSERT OR UPDATE OR DELETE ON preplan_subcontract_make_batch_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

SELECT fn_assert_subcontract_make_task_batches();
DO $$
DECLARE definition TEXT; needle TEXT := '(''preplan_subcontract_make_task_batches'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN
        RAISE EXCEPTION 'V496 cannot extend business_data_reset policy safely';
    END IF;
    definition:=replace(definition,needle,
        needle || E',\n            (''preplan_subcontract_make_batch_reversals'', ''CLEAR'')');
    EXECUTE definition;
END;
$$;
