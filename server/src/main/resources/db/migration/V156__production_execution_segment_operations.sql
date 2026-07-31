-- V156: executable production segments and exact report/inbound attribution.
--
-- Historical rows remain nullable.  Once a plan item belongs to a V155
-- execution package, every new report and finished-in line must identify the
-- exact segment; guessing by goods or by plan item is forbidden.

ALTER TABLE production_daily_report_items
    ADD COLUMN execution_segment_id UUID
        REFERENCES production_execution_segments(id);

CREATE INDEX idx_pdri_execution_segment
    ON production_daily_report_items(execution_segment_id)
    WHERE execution_segment_id IS NOT NULL;

ALTER TABLE stock_document_items
    ADD COLUMN execution_segment_id UUID
        REFERENCES production_execution_segments(id);

CREATE INDEX idx_sdi_execution_segment
    ON stock_document_items(execution_segment_id)
    WHERE execution_segment_id IS NOT NULL;

CREATE TABLE production_execution_segment_events (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    execution_segment_id UUID NOT NULL
        REFERENCES production_execution_segments(id),
    action             TEXT NOT NULL
        CHECK (action IN (
            'ASSIGNMENT', 'DISPATCH', 'START', 'CANCEL', 'REVERSE'
        )),
    idempotency_key    TEXT NOT NULL,
    request_hash       TEXT NOT NULL
        CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    expected_version   BIGINT NOT NULL,
    resulting_version  BIGINT NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         UUID,
    CONSTRAINT uq_production_execution_segment_event_key
        UNIQUE (execution_segment_id, action, idempotency_key)
);

CREATE INDEX idx_production_execution_segment_event_created
    ON production_execution_segment_events(
        execution_segment_id, created_at DESC, id DESC);

CREATE OR REPLACE FUNCTION fn_validate_daily_report_execution_segment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment production_execution_segments%ROWTYPE;
BEGIN
    IF NEW.execution_segment_id IS NOT NULL THEN
        SELECT * INTO v_segment
        FROM production_execution_segments
        WHERE id = NEW.execution_segment_id
          AND is_deleted = FALSE;
        IF NOT FOUND
           OR NEW.plan_item_id IS DISTINCT FROM v_segment.source_plan_item_id
           OR NEW.goods_id IS DISTINCT FROM v_segment.product_goods_id
           OR NEW.color_id IS DISTINCT FROM v_segment.product_color_id
           OR NEW.unit_id IS DISTINCT FROM v_segment.product_unit_id THEN
            RAISE EXCEPTION
                'daily report line is mapped to a different execution segment'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_daily_report_execution_segment_guard';
        END IF;
    ELSIF NEW.plan_item_id IS NOT NULL
       AND EXISTS (
           SELECT 1
           FROM production_execution_segments s
           JOIN production_planning_packages p ON p.id = s.package_id
           WHERE s.source_plan_item_id = NEW.plan_item_id
             AND s.is_deleted = FALSE
             AND p.is_deleted = FALSE
             AND p.status = 'CONFIRMED'
             AND p.execution_model_version = 1
       ) THEN
        RAISE EXCEPTION
            'execution segment is required for this daily report line'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_daily_report_execution_segment_required';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_daily_report_execution_segment
    BEFORE INSERT OR UPDATE OF
        execution_segment_id, plan_item_id, goods_id, color_id, unit_id
    ON production_daily_report_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_daily_report_execution_segment();

CREATE OR REPLACE FUNCTION fn_validate_finished_in_execution_segment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment production_execution_segments%ROWTYPE;
BEGIN
    IF NEW.bill_type IS DISTINCT FROM 'FINISHED_IN' THEN
        IF NEW.execution_segment_id IS NOT NULL THEN
            RAISE EXCEPTION
                'execution segment is only valid on finished-in stock lines'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'stock_document_execution_segment_type_guard';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.execution_segment_id IS NOT NULL THEN
        SELECT * INTO v_segment
        FROM production_execution_segments
        WHERE id = NEW.execution_segment_id
          AND is_deleted = FALSE;
        IF NOT FOUND
           OR NEW.upstream_item_id IS DISTINCT FROM
              v_segment.source_plan_item_id
           OR NEW.goods_id IS DISTINCT FROM v_segment.product_goods_id
           OR NEW.color_id IS DISTINCT FROM v_segment.product_color_id
           OR NEW.unit_id IS DISTINCT FROM v_segment.product_unit_id THEN
            RAISE EXCEPTION
                'finished-in line is mapped to a different execution segment'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'stock_document_execution_segment_guard';
        END IF;
    ELSIF NEW.upstream_item_id IS NOT NULL
       AND EXISTS (
           SELECT 1
           FROM production_execution_segments s
           JOIN production_planning_packages p ON p.id = s.package_id
           WHERE s.source_plan_item_id = NEW.upstream_item_id
             AND s.is_deleted = FALSE
             AND p.is_deleted = FALSE
             AND p.status = 'CONFIRMED'
             AND p.execution_model_version = 1
       ) THEN
        RAISE EXCEPTION
            'execution segment is required for this finished-in line'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'stock_document_execution_segment_required';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_finished_in_execution_segment
    BEFORE INSERT OR UPDATE OF
        execution_segment_id, bill_type, upstream_item_id,
        goods_id, color_id, unit_id
    ON stock_document_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_finished_in_execution_segment();

CREATE TRIGGER trg_audit_production_execution_segment_events
    AFTER INSERT OR UPDATE OR DELETE
    ON production_execution_segment_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_production_daily_report_items
    AFTER INSERT OR UPDATE OR DELETE
    ON production_daily_report_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_stock_document_items
    AFTER INSERT OR UPDATE OR DELETE
    ON stock_document_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON COLUMN production_daily_report_items.execution_segment_id IS
    'Exact V155 execution segment; NULL only for historical/legacy plans.';
COMMENT ON COLUMN stock_document_items.execution_segment_id IS
    'Exact finished-product execution segment for FINISHED_IN lines.';
COMMENT ON TABLE production_execution_segment_events IS
    'Idempotent semantic command log for assignment and lifecycle changes.';

-- A finished-product posting is exact to one segment.  Approval is the
-- accounting boundary: drafts do not count, approved rows do, reversals stop
-- counting.  The guard serializes with the segment row so two warehouse users
-- cannot approve the last capacity concurrently.
CREATE OR REPLACE FUNCTION fn_guard_execution_segment_finished_in()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_row RECORD;
    v_existing NUMERIC(18,4);
    v_current NUMERIC(18,4);
BEGIN
    IF NEW.doc_type IS DISTINCT FROM 'FINISHED_IN' THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 1 AND NEW.status = -1
       AND EXISTS (
           SELECT 1
           FROM stock_document_items item
           JOIN production_execution_segments segment
             ON segment.id = item.execution_segment_id
           WHERE item.doc_id = NEW.id
             AND item.is_deleted = FALSE
             AND segment.is_deleted = FALSE
             AND segment.status = 'COMPLETED'
       ) THEN
        RAISE EXCEPTION
            'completed execution segment requires explicit reverse-completion workflow before finished-in reversal'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'stock_document_completed_segment_reverse_guard';
    END IF;

    IF NEW.status IS DISTINCT FROM 1
       OR OLD.status IS NOT DISTINCT FROM 1 THEN
        RETURN NEW;
    END IF;

    FOR v_row IN
        SELECT item.execution_segment_id AS segment_id,
               SUM(item.qty) AS qty
        FROM stock_document_items item
        WHERE item.doc_id = NEW.id
          AND item.bill_type = 'FINISHED_IN'
          AND item.execution_segment_id IS NOT NULL
          AND item.is_deleted = FALSE
        GROUP BY item.execution_segment_id
        ORDER BY item.execution_segment_id
    LOOP
        PERFORM 1
        FROM production_execution_segments segment
        WHERE segment.id = v_row.segment_id
          AND segment.is_deleted = FALSE
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'finished-in execution segment is unavailable'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'stock_document_execution_segment_available_guard';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM production_execution_segments segment
            WHERE segment.id = v_row.segment_id
              AND segment.status = 'IN_PROGRESS'
        ) THEN
            RAISE EXCEPTION
                'finished-in requires an in-progress execution segment'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'stock_document_execution_segment_status_guard';
        END IF;

        SELECT COALESCE(SUM(item.qty), 0)
        INTO v_existing
        FROM stock_document_items item
        JOIN stock_documents document ON document.id = item.doc_id
        WHERE item.execution_segment_id = v_row.segment_id
          AND item.bill_type = 'FINISHED_IN'
          AND item.is_deleted = FALSE
          AND document.is_deleted = FALSE
          AND document.doc_type = 'FINISHED_IN'
          AND document.status = 1
          AND document.id <> NEW.id;
        v_current := COALESCE(v_row.qty, 0);

        IF v_existing + v_current > (
            SELECT segment.planned_qty
            FROM production_execution_segments segment
            WHERE segment.id = v_row.segment_id
        ) THEN
            RAISE EXCEPTION
                'approved finished-in quantity exceeds execution segment plan'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'stock_document_execution_segment_quantity_guard';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_execution_segment_finished_in
    BEFORE UPDATE OF status ON stock_documents
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_execution_segment_finished_in();

CREATE OR REPLACE FUNCTION fn_reconcile_execution_segment_completion(
    p_segment_id UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_planned NUMERIC(18,4);
    v_inbound NUMERIC(18,4);
    v_status TEXT;
    v_clear BOOLEAN;
BEGIN
    SELECT planned_qty, status
    INTO v_planned, v_status
    FROM production_execution_segments
    WHERE id = p_segment_id
      AND is_deleted = FALSE
    FOR UPDATE;
    IF NOT FOUND
       OR v_status NOT IN ('IN_PROGRESS', 'COMPLETED') THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(item.qty), 0)
    INTO v_inbound
    FROM stock_document_items item
    JOIN stock_documents document ON document.id = item.doc_id
    WHERE item.execution_segment_id = p_segment_id
      AND item.bill_type = 'FINISHED_IN'
      AND item.is_deleted = FALSE
      AND document.is_deleted = FALSE
      AND document.doc_type = 'FINISHED_IN'
      AND document.status = 1;

    SELECT NOT EXISTS (
        SELECT 1
        FROM production_material_demands demand
        LEFT JOIN v_production_material_clearance clearance
          ON clearance.demand_id = demand.id
        WHERE demand.execution_segment_id = p_segment_id
          AND demand.is_deleted = FALSE
          AND demand.status NOT IN ('RELEASED', 'REVERSED')
          AND COALESCE(clearance.can_close, FALSE) = FALSE
    ) INTO v_clear;

    IF v_status = 'COMPLETED' THEN
        IF v_inbound <> v_planned OR NOT v_clear THEN
            RAISE EXCEPTION
                'completed execution segment facts cannot be made uncleared'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_execution_segment_completed_fact_guard';
        END IF;
        RETURN;
    END IF;

    IF v_inbound = v_planned AND v_clear THEN
        /*
         * Release only the still-unissued balance. consumed_qty remains the
         * immutable issue fact; a fully returned reservation can be retired,
         * while a consumed reservation remains visible with zero open stock.
         */
        UPDATE stock_reservations reservation
        SET released_qty =
                reservation.qty - reservation.consumed_qty,
            status = CASE
                WHEN reservation.consumed_qty = 0 THEN -1
                ELSE 1
            END,
            is_deleted = reservation.consumed_qty = 0,
            deleted_at = CASE
                WHEN reservation.consumed_qty = 0 THEN now()
                ELSE NULL
            END,
            release_reason = 'EXECUTION_SEGMENT_COMPLETED_UNUSED',
            lock_version = reservation.lock_version + 1,
            updated_at = now()
        WHERE reservation.demand_id IN (
                SELECT demand.id
                FROM production_material_demands demand
                WHERE demand.execution_segment_id = p_segment_id
                  AND demand.is_deleted = FALSE
            )
          AND reservation.owner_type =
              'PRODUCTION_MATERIAL_DEMAND'
          AND reservation.is_deleted = FALSE
          AND reservation.qty
                - reservation.consumed_qty
                - reservation.released_qty > 0;

        UPDATE production_execution_segments
        SET status = 'COMPLETED', updated_at = now()
        WHERE id = p_segment_id
          AND status = 'IN_PROGRESS';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_reconcile_segments_from_finished_in()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment_id UUID;
BEGIN
    IF NEW.doc_type IS DISTINCT FROM 'FINISHED_IN'
       OR NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;
    FOR v_segment_id IN
        SELECT DISTINCT item.execution_segment_id
        FROM stock_document_items item
        WHERE item.doc_id = NEW.id
          AND item.execution_segment_id IS NOT NULL
          AND item.is_deleted = FALSE
        ORDER BY item.execution_segment_id
    LOOP
        PERFORM fn_reconcile_execution_segment_completion(v_segment_id);
    END LOOP;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reconcile_segments_from_finished_in
    AFTER UPDATE OF status ON stock_documents
    FOR EACH ROW EXECUTE FUNCTION
        fn_reconcile_segments_from_finished_in();

CREATE OR REPLACE FUNCTION fn_reconcile_segment_from_material_posting()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_demand_id UUID;
    v_segment_id UUID;
BEGIN
    v_demand_id := COALESCE(NEW.demand_id, OLD.demand_id);
    SELECT execution_segment_id INTO v_segment_id
    FROM production_material_demands
    WHERE id = v_demand_id;
    IF v_segment_id IS NOT NULL THEN
        PERFORM fn_reconcile_execution_segment_completion(v_segment_id);
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reconcile_segment_from_stock_posting
    AFTER INSERT OR DELETE ON production_material_stock_postings
    FOR EACH ROW EXECUTE FUNCTION
        fn_reconcile_segment_from_material_posting();

CREATE TRIGGER trg_reconcile_segment_from_settlement_posting
    AFTER INSERT OR DELETE ON production_material_settlement_postings
    FOR EACH ROW EXECUTE FUNCTION
        fn_reconcile_segment_from_material_posting();
