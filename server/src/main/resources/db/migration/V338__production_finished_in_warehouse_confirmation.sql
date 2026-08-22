-- V338: production reports declare proposed FINISHED_IN quantities; warehouse
-- physical acceptance is the final inventory/iqty authority.  Short acceptance
-- is split into an approved accepted slice plus a new residual draft.

ALTER TABLE stock_document_items
    ADD COLUMN reported_qty NUMERIC(18,4),
    ADD COLUMN deleted_at TIMESTAMPTZ,
    ADD COLUMN source_daily_report_item_id UUID
        REFERENCES production_daily_report_items(id) ON DELETE RESTRICT;

UPDATE stock_document_items
SET reported_qty = qty
WHERE bill_type = 'FINISHED_IN'
  AND reported_qty IS NULL;

UPDATE stock_document_items item
SET source_daily_report_item_id = (
    SELECT report_item.id
    FROM production_daily_report_items report_item
    WHERE report_item.report_id = document.source_daily_report_id
      AND report_item.is_deleted = FALSE
      AND report_item.plan_item_id IS NOT DISTINCT FROM item.upstream_item_id
      AND report_item.execution_segment_id
            IS NOT DISTINCT FROM item.execution_segment_id
      AND report_item.execution_segment_sales_allocation_id
            IS NOT DISTINCT FROM item.execution_segment_sales_allocation_id
      AND report_item.goods_id = item.goods_id
      AND report_item.color_id IS NOT DISTINCT FROM item.color_id
      AND report_item.unit_id IS NOT DISTINCT FROM item.unit_id
    ORDER BY report_item.id
    LIMIT 1)
FROM stock_documents document
WHERE item.doc_id = document.id
  AND item.bill_type = 'FINISHED_IN'
  AND item.is_deleted = FALSE
  AND document.doc_type = 'FINISHED_IN'
  AND document.source_daily_report_id IS NOT NULL
  AND item.source_daily_report_item_id IS NULL
  AND 1 = (
      SELECT COUNT(*)
      FROM production_daily_report_items report_item
      WHERE report_item.report_id = document.source_daily_report_id
        AND report_item.is_deleted = FALSE
        AND report_item.plan_item_id IS NOT DISTINCT FROM item.upstream_item_id
        AND report_item.execution_segment_id
              IS NOT DISTINCT FROM item.execution_segment_id
        AND report_item.execution_segment_sales_allocation_id
              IS NOT DISTINCT FROM item.execution_segment_sales_allocation_id
        AND report_item.goods_id = item.goods_id
        AND report_item.color_id IS NOT DISTINCT FROM item.color_id
        AND report_item.unit_id IS NOT DISTINCT FROM item.unit_id);

-- The non-empty backfill above queues existing DEFERRABLE stock-item guard
-- events.  Settle those guards before the following ALTER TABLE; no trigger or
-- constraint is disabled, and the migration remains fail-closed on bad rows.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE stock_document_items
    ADD CONSTRAINT stock_document_item_reported_qty_chk CHECK (
        reported_qty IS NULL OR reported_qty > 0);

CREATE INDEX idx_stock_document_item_source_daily_report_item
    ON stock_document_items(source_daily_report_item_id)
    WHERE source_daily_report_item_id IS NOT NULL;

CREATE TABLE production_finished_in_confirmations (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stock_document_id           UUID NOT NULL UNIQUE
        REFERENCES stock_documents(id) ON DELETE RESTRICT,
    residual_stock_document_id  UUID
        REFERENCES stock_documents(id) ON DELETE RESTRICT,
    decision                    TEXT NOT NULL,
    variance_reason             TEXT,
    idempotency_key             TEXT NOT NULL UNIQUE,
    request_hash                TEXT NOT NULL,
    confirmed_by_employee_id    UUID
        REFERENCES employees(id) ON DELETE RESTRICT,
    confirmed_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID REFERENCES users(id) ON DELETE RESTRICT,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_finished_in_confirmation_decision_chk CHECK (
        decision IN ('ACCEPTED', 'PARTIAL', 'REJECTED', 'LEGACY_APPROVED')),
    CONSTRAINT production_finished_in_confirmation_shape_chk CHECK (
        (decision IN ('ACCEPTED', 'LEGACY_APPROVED')
            AND residual_stock_document_id IS NULL)
        OR
        (decision = 'PARTIAL'
            AND residual_stock_document_id IS NOT NULL
            AND NULLIF(btrim(variance_reason), '') IS NOT NULL)
        OR
        (decision = 'REJECTED'
            AND residual_stock_document_id IS NULL
            AND NULLIF(btrim(variance_reason), '') IS NOT NULL)),
    CONSTRAINT production_finished_in_confirmation_distinct_chk CHECK (
        residual_stock_document_id IS NULL
        OR residual_stock_document_id <> stock_document_id),
    CONSTRAINT production_finished_in_confirmation_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 128),
    CONSTRAINT production_finished_in_confirmation_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$')
);

CREATE TABLE production_finished_in_confirmation_items (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    confirmation_id                 UUID NOT NULL
        REFERENCES production_finished_in_confirmations(id) ON DELETE RESTRICT,
    stock_document_item_id          UUID NOT NULL UNIQUE
        REFERENCES stock_document_items(id) ON DELETE RESTRICT,
    residual_stock_document_item_id UUID UNIQUE
        REFERENCES stock_document_items(id) ON DELETE RESTRICT,
    reported_qty                    NUMERIC(18,4) NOT NULL,
    accepted_qty                    NUMERIC(18,4) NOT NULL,
    residual_qty                    NUMERIC(18,4) NOT NULL,
    created_by                      UUID REFERENCES users(id) ON DELETE RESTRICT,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_finished_in_confirmation_item_qty_chk CHECK (
        reported_qty > 0
        AND accepted_qty >= 0
        AND residual_qty >= 0
        AND accepted_qty + residual_qty = reported_qty),
    CONSTRAINT production_finished_in_confirmation_item_residual_chk CHECK (
        (residual_qty = 0 AND residual_stock_document_item_id IS NULL)
        OR
        (accepted_qty = 0 AND residual_qty = reported_qty
            AND residual_stock_document_item_id IS NULL)
        OR
        (residual_qty > 0 AND residual_stock_document_item_id IS NOT NULL)),
    CONSTRAINT uq_production_finished_in_confirmation_item
        UNIQUE (confirmation_id, stock_document_item_id)
);

CREATE TABLE production_finished_in_confirmation_reversals (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    confirmation_id             UUID NOT NULL UNIQUE
        REFERENCES production_finished_in_confirmations(id) ON DELETE RESTRICT,
    reversed_stock_document_id  UUID NOT NULL UNIQUE
        REFERENCES stock_documents(id) ON DELETE RESTRICT,
    replacement_stock_document_id UUID NOT NULL UNIQUE
        REFERENCES stock_documents(id) ON DELETE RESTRICT,
    idempotency_key             TEXT NOT NULL UNIQUE,
    reversed_by_employee_id     UUID
        REFERENCES employees(id) ON DELETE RESTRICT,
    reversed_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID REFERENCES users(id) ON DELETE RESTRICT,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_finished_in_confirmation_reversal_distinct_chk
        CHECK (reversed_stock_document_id <> replacement_stock_document_id),
    CONSTRAINT production_finished_in_confirmation_reversal_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 160)
);

CREATE TABLE production_finished_in_confirmation_reversal_items (
    id                                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reversal_id                         UUID NOT NULL
        REFERENCES production_finished_in_confirmation_reversals(id)
        ON DELETE RESTRICT,
    confirmation_item_id                UUID NOT NULL UNIQUE
        REFERENCES production_finished_in_confirmation_items(id)
        ON DELETE RESTRICT,
    replacement_stock_document_item_id  UUID NOT NULL UNIQUE
        REFERENCES stock_document_items(id) ON DELETE RESTRICT,
    qty                                 NUMERIC(18,4) NOT NULL CHECK (qty > 0),
    created_by                          UUID REFERENCES users(id) ON DELETE RESTRICT,
    created_at                          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_production_finished_in_confirmation_reversal_item
        UNIQUE (reversal_id, confirmation_item_id)
);

-- Historical approved production receipts are recorded as exact legacy
-- confirmations.  Drafts remain pending and must use the new command.
INSERT INTO production_finished_in_confirmations(
    id, stock_document_id, decision, idempotency_key, request_hash,
    confirmed_by_employee_id, confirmed_at, created_by)
SELECT gen_random_uuid(), document.id, 'LEGACY_APPROVED',
       'LEGACY-FINISHED-IN:' || document.id,
       encode(digest(document.id::text, 'sha256'), 'hex'),
       document.approver_id,
       COALESCE(document.updated_at, document.created_at, now()),
       document.updated_by
FROM stock_documents document
WHERE document.doc_type = 'FINISHED_IN'
  AND document.status = 1
  AND document.is_deleted = FALSE
  AND fn_is_production_linked_stock_document(document.id)
ON CONFLICT (stock_document_id) DO NOTHING;

INSERT INTO production_finished_in_confirmation_items(
    id, confirmation_id, stock_document_item_id,
    reported_qty, accepted_qty, residual_qty, created_by)
SELECT gen_random_uuid(), confirmation.id, item.id,
       COALESCE(item.reported_qty, item.qty), item.qty, 0,
       confirmation.created_by
FROM production_finished_in_confirmations confirmation
JOIN stock_document_items item
  ON item.doc_id = confirmation.stock_document_id
 AND item.is_deleted = FALSE
WHERE confirmation.decision = 'LEGACY_APPROVED'
ON CONFLICT (stock_document_item_id) DO NOTHING;

CREATE OR REPLACE FUNCTION fn_guard_production_finished_in_confirmation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'production FINISHED_IN confirmation is append-only'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_guard_production_finished_in_confirmation
    BEFORE UPDATE OR DELETE ON production_finished_in_confirmations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_finished_in_confirmation();
CREATE TRIGGER trg_guard_production_finished_in_confirmation_item
    BEFORE UPDATE OR DELETE ON production_finished_in_confirmation_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_finished_in_confirmation();
CREATE TRIGGER trg_guard_production_finished_in_confirmation_reversal
    BEFORE UPDATE OR DELETE ON production_finished_in_confirmation_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_finished_in_confirmation();
CREATE TRIGGER trg_guard_production_finished_in_confirmation_reversal_item
    BEFORE UPDATE OR DELETE
    ON production_finished_in_confirmation_reversal_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_finished_in_confirmation();
CREATE TRIGGER trg_audit_production_finished_in_confirmations
    AFTER INSERT OR UPDATE OR DELETE ON production_finished_in_confirmations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_finished_in_confirmation_items
    AFTER INSERT OR UPDATE OR DELETE ON production_finished_in_confirmation_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_finished_in_confirmation_reversals
    AFTER INSERT OR UPDATE OR DELETE
    ON production_finished_in_confirmation_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_finished_in_confirmation_reversal_items
    AFTER INSERT OR UPDATE OR DELETE
    ON production_finished_in_confirmation_reversal_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE FUNCTION fn_validate_production_finished_in_confirmation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    confirmation_id UUID;
    confirmation production_finished_in_confirmations%ROWTYPE;
    source_document stock_documents%ROWTYPE;
    residual_document stock_documents%ROWTYPE;
    source_line_count BIGINT;
    confirmation_line_count BIGINT;
    invalid_line_count BIGINT;
    source_plan_id UUID;
    residual_plan_id UUID;
BEGIN
    IF TG_TABLE_NAME = 'production_finished_in_confirmations' THEN
        confirmation_id := COALESCE(NEW.id, OLD.id);
    ELSE
        confirmation_id := COALESCE(NEW.confirmation_id, OLD.confirmation_id);
    END IF;
    SELECT * INTO confirmation
    FROM production_finished_in_confirmations
    WHERE id = confirmation_id;
    IF confirmation.id IS NULL THEN RETURN NEW; END IF;
    SELECT * INTO source_document
    FROM stock_documents WHERE id = confirmation.stock_document_id;
    IF source_document.id IS NULL
       OR source_document.doc_type IS DISTINCT FROM 'FINISHED_IN'
       OR source_document.status IS DISTINCT FROM (CASE
            WHEN confirmation.decision = 'REJECTED' THEN -1 ELSE 1 END)
       OR source_document.is_deleted IS DISTINCT FROM FALSE
       OR NOT fn_is_production_linked_stock_document(source_document.id) THEN
        RAISE EXCEPTION 'invalid confirmed production FINISHED_IN source'
            USING ERRCODE = '23514';
    END IF;
    SELECT COUNT(*) INTO source_line_count
    FROM stock_document_items item
    WHERE item.doc_id = source_document.id;
    SELECT COUNT(*) INTO confirmation_line_count
    FROM production_finished_in_confirmation_items item
    WHERE item.confirmation_id = confirmation.id;
    IF source_line_count = 0 OR source_line_count <> confirmation_line_count THEN
        RAISE EXCEPTION 'warehouse confirmation must cover every source line'
            USING ERRCODE = '23514';
    END IF;

    SELECT COUNT(*) INTO invalid_line_count
    FROM production_finished_in_confirmation_items confirmed
    JOIN stock_document_items source_item
      ON source_item.id = confirmed.stock_document_item_id
    LEFT JOIN production_daily_report_items source_report_item
      ON source_report_item.id = source_item.source_daily_report_item_id
    LEFT JOIN stock_document_items residual_item
      ON residual_item.id = confirmed.residual_stock_document_item_id
    WHERE confirmed.confirmation_id = confirmation.id
      AND (
          source_item.doc_id IS DISTINCT FROM source_document.id
          OR (confirmation.decision = 'REJECTED'
              AND source_item.is_deleted IS DISTINCT FROM FALSE)
          OR (confirmation.decision <> 'REJECTED'
              AND confirmed.accepted_qty = 0
              AND source_item.is_deleted IS DISTINCT FROM TRUE)
          OR (confirmation.decision <> 'REJECTED'
              AND confirmed.accepted_qty > 0
              AND source_item.is_deleted IS DISTINCT FROM FALSE)
          OR source_item.reported_qty IS DISTINCT FROM confirmed.reported_qty
          OR (confirmation.decision = 'REJECTED'
              AND (source_item.qty IS DISTINCT FROM confirmed.reported_qty
                   OR confirmed.accepted_qty <> 0
                   OR confirmed.residual_qty IS DISTINCT FROM confirmed.reported_qty))
          OR (confirmation.decision <> 'REJECTED'
              AND confirmed.accepted_qty > 0
              AND source_item.qty IS DISTINCT FROM confirmed.accepted_qty)
          OR (confirmation.decision <> 'REJECTED'
              AND confirmed.accepted_qty = 0
              AND source_item.qty IS DISTINCT FROM confirmed.reported_qty)
          OR (confirmation.decision <> 'LEGACY_APPROVED'
              AND (source_report_item.id IS NULL
                   OR source_report_item.report_id
                        IS DISTINCT FROM source_document.source_daily_report_id
                   OR source_report_item.goods_id
                        IS DISTINCT FROM source_item.goods_id
                   OR source_report_item.color_id
                        IS DISTINCT FROM source_item.color_id
                   OR source_report_item.unit_id
                        IS DISTINCT FROM source_item.unit_id))
          OR (confirmation.decision <> 'PARTIAL'
              AND residual_item.id IS NOT NULL)
          OR (confirmation.decision = 'PARTIAL'
              AND confirmed.residual_qty > 0 AND (
              residual_item.id IS NULL
              OR residual_item.doc_id
                   IS DISTINCT FROM confirmation.residual_stock_document_id
              OR residual_item.is_deleted IS DISTINCT FROM FALSE
              OR residual_item.reported_qty
                   IS DISTINCT FROM confirmed.residual_qty
              OR residual_item.qty IS DISTINCT FROM confirmed.residual_qty
              OR residual_item.goods_id IS DISTINCT FROM source_item.goods_id
              OR residual_item.color_id IS DISTINCT FROM source_item.color_id
              OR residual_item.unit_id IS DISTINCT FROM source_item.unit_id
              OR residual_item.unit_rate IS DISTINCT FROM source_item.unit_rate
              OR residual_item.upstream_item_id
                   IS DISTINCT FROM source_item.upstream_item_id
              OR residual_item.execution_segment_id
                   IS DISTINCT FROM source_item.execution_segment_id
              OR residual_item.execution_segment_sales_allocation_id
                   IS DISTINCT FROM source_item.execution_segment_sales_allocation_id
              OR residual_item.source_daily_report_item_id
                   IS DISTINCT FROM source_item.source_daily_report_item_id)));
    IF invalid_line_count > 0 THEN
        RAISE EXCEPTION 'warehouse confirmation line provenance is invalid'
            USING ERRCODE = '23514';
    END IF;

    IF confirmation.decision = 'PARTIAL' THEN
        SELECT * INTO residual_document
        FROM stock_documents
        WHERE id = confirmation.residual_stock_document_id;
        IF residual_document.id IS NULL
           OR residual_document.doc_type IS DISTINCT FROM 'FINISHED_IN'
           OR residual_document.status <> 0
           OR residual_document.is_deleted IS DISTINCT FROM FALSE
           OR residual_document.warehouse_id
                IS DISTINCT FROM source_document.warehouse_id
           OR residual_document.source_daily_report_id
                IS DISTINCT FROM source_document.source_daily_report_id THEN
            RAISE EXCEPTION 'invalid residual production FINISHED_IN draft'
                USING ERRCODE = '23514';
        END IF;
        SELECT plan_id INTO source_plan_id
        FROM plan_draw_links
        WHERE draw_id = source_document.id AND is_deleted = FALSE;
        SELECT plan_id INTO residual_plan_id
        FROM plan_draw_links
        WHERE draw_id = residual_document.id AND is_deleted = FALSE;
        IF source_plan_id IS NULL
           OR residual_plan_id IS DISTINCT FROM source_plan_id THEN
            RAISE EXCEPTION 'residual FINISHED_IN must keep the source plan'
                USING ERRCODE = '23514';
        END IF;
    ELSIF confirmation.decision IN ('ACCEPTED', 'LEGACY_APPROVED')
      AND EXISTS (
        SELECT 1 FROM production_finished_in_confirmation_items item
        WHERE item.confirmation_id = confirmation.id
          AND item.residual_qty <> 0) THEN
        RAISE EXCEPTION 'non-partial confirmation cannot retain residual quantity'
            USING ERRCODE = '23514';
    ELSIF confirmation.decision = 'REJECTED' AND EXISTS (
        SELECT 1 FROM production_finished_in_confirmation_items item
        WHERE item.confirmation_id = confirmation.id
          AND (item.accepted_qty <> 0
               OR item.residual_qty <> item.reported_qty
               OR item.residual_stock_document_item_id IS NOT NULL)) THEN
        RAISE EXCEPTION 'rejected confirmation must preserve all quantity for report correction'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_production_finished_in_confirmation
    AFTER INSERT ON production_finished_in_confirmations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_production_finished_in_confirmation();
CREATE CONSTRAINT TRIGGER trg_validate_production_finished_in_confirmation_items
    AFTER INSERT ON production_finished_in_confirmation_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_production_finished_in_confirmation();

CREATE OR REPLACE FUNCTION fn_validate_production_finished_in_confirmation_reversal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    confirmation_id UUID;
    reversal_id UUID;
    confirmation production_finished_in_confirmations%ROWTYPE;
    reversal production_finished_in_confirmation_reversals%ROWTYPE;
    source_document stock_documents%ROWTYPE;
    replacement_document stock_documents%ROWTYPE;
    source_plan_id UUID;
    replacement_plan_id UUID;
    expected_line_count BIGINT;
    actual_line_count BIGINT;
    invalid_line_count BIGINT;
BEGIN
    IF TG_TABLE_NAME = 'stock_documents' THEN
        SELECT id INTO confirmation_id
        FROM production_finished_in_confirmations
        WHERE stock_document_id = COALESCE(NEW.id, OLD.id);
        IF confirmation_id IS NULL THEN RETURN NEW; END IF;
    ELSIF TG_TABLE_NAME =
            'production_finished_in_confirmation_reversals' THEN
        confirmation_id := COALESCE(NEW.confirmation_id, OLD.confirmation_id);
        reversal_id := COALESCE(NEW.id, OLD.id);
    ELSE
        reversal_id := COALESCE(NEW.reversal_id, OLD.reversal_id);
        SELECT reversal_row.confirmation_id INTO confirmation_id
        FROM production_finished_in_confirmation_reversals reversal_row
        WHERE reversal_row.id = reversal_id;
    END IF;

    SELECT * INTO confirmation
    FROM production_finished_in_confirmations
    WHERE id = confirmation_id;
    IF confirmation.id IS NULL THEN RETURN NEW; END IF;
    SELECT * INTO source_document
    FROM stock_documents
    WHERE id = confirmation.stock_document_id;
    SELECT * INTO reversal
    FROM production_finished_in_confirmation_reversals reversal_row
    WHERE reversal_row.confirmation_id = confirmation.id;

    IF confirmation.decision = 'REJECTED' THEN
        IF source_document.status IS DISTINCT FROM -1
           OR reversal.id IS NOT NULL THEN
            RAISE EXCEPTION
                'rejected FINISHED_IN cannot own a confirmation reversal'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF reversal.id IS NULL THEN
        IF source_document.status IS DISTINCT FROM 1 THEN
            RAISE EXCEPTION
                'confirmed FINISHED_IN reversal event is missing'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF confirmation.decision = 'LEGACY_APPROVED' THEN
        RAISE EXCEPTION
            'legacy FINISHED_IN needs explicit provenance repair before reversal'
            USING ERRCODE = '23514';
    END IF;
    IF reversal.reversed_stock_document_id
            IS DISTINCT FROM source_document.id
       OR source_document.status IS DISTINCT FROM -1
       OR source_document.is_deleted IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'invalid reversed FINISHED_IN source state'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO replacement_document
    FROM stock_documents
    WHERE id = reversal.replacement_stock_document_id;
    IF replacement_document.id IS NULL
       OR replacement_document.doc_type IS DISTINCT FROM 'FINISHED_IN'
       OR replacement_document.status IS DISTINCT FROM 0
       OR replacement_document.is_deleted IS DISTINCT FROM FALSE
       OR replacement_document.warehouse_id
            IS DISTINCT FROM source_document.warehouse_id
       OR replacement_document.source_daily_report_id
            IS DISTINCT FROM source_document.source_daily_report_id THEN
        RAISE EXCEPTION 'invalid FINISHED_IN reversal replacement draft'
            USING ERRCODE = '23514';
    END IF;

    SELECT plan_id INTO source_plan_id
    FROM plan_draw_links
    WHERE draw_id = source_document.id AND is_deleted = FALSE
    ORDER BY plan_id LIMIT 1;
    SELECT plan_id INTO replacement_plan_id
    FROM plan_draw_links
    WHERE draw_id = replacement_document.id AND is_deleted = FALSE
    ORDER BY plan_id LIMIT 1;
    IF source_plan_id IS NULL
       OR replacement_plan_id IS DISTINCT FROM source_plan_id
       OR (SELECT COUNT(*) FROM plan_draw_links
           WHERE draw_id = source_document.id AND is_deleted = FALSE) <> 1
       OR (SELECT COUNT(*) FROM plan_draw_links
           WHERE draw_id = replacement_document.id AND is_deleted = FALSE) <> 1 THEN
        RAISE EXCEPTION
            'FINISHED_IN reversal replacement must keep the exact source plan'
            USING ERRCODE = '23514';
    END IF;

    SELECT COUNT(*) INTO expected_line_count
    FROM production_finished_in_confirmation_items item
    WHERE item.confirmation_id = confirmation.id
      AND item.accepted_qty > 0;
    SELECT COUNT(*) INTO actual_line_count
    FROM production_finished_in_confirmation_reversal_items item
    WHERE item.reversal_id = reversal.id;
    IF expected_line_count = 0
       OR actual_line_count <> expected_line_count THEN
        RAISE EXCEPTION
            'FINISHED_IN reversal must replace every accepted slice'
            USING ERRCODE = '23514';
    END IF;

    SELECT COUNT(*) INTO invalid_line_count
    FROM production_finished_in_confirmation_reversal_items reversal_item
    JOIN production_finished_in_confirmation_items confirmed
      ON confirmed.id = reversal_item.confirmation_item_id
    JOIN stock_document_items source_item
      ON source_item.id = confirmed.stock_document_item_id
    JOIN stock_document_items replacement_item
      ON replacement_item.id =
         reversal_item.replacement_stock_document_item_id
    WHERE reversal_item.reversal_id = reversal.id
      AND (confirmed.confirmation_id IS DISTINCT FROM confirmation.id
           OR confirmed.accepted_qty <= 0
           OR reversal_item.qty IS DISTINCT FROM confirmed.accepted_qty
           OR source_item.doc_id IS DISTINCT FROM source_document.id
           OR source_item.is_deleted IS DISTINCT FROM FALSE
           OR source_item.qty IS DISTINCT FROM confirmed.accepted_qty
           OR replacement_item.doc_id
                IS DISTINCT FROM replacement_document.id
           OR replacement_item.is_deleted IS DISTINCT FROM FALSE
           OR replacement_item.qty IS DISTINCT FROM confirmed.accepted_qty
           OR replacement_item.reported_qty
                IS DISTINCT FROM confirmed.accepted_qty
           OR replacement_item.goods_id IS DISTINCT FROM source_item.goods_id
           OR replacement_item.color_id IS DISTINCT FROM source_item.color_id
           OR replacement_item.unit_id IS DISTINCT FROM source_item.unit_id
           OR replacement_item.unit_rate
                IS DISTINCT FROM source_item.unit_rate
           OR replacement_item.upstream_item_id
                IS DISTINCT FROM source_item.upstream_item_id
           OR replacement_item.execution_segment_id
                IS DISTINCT FROM source_item.execution_segment_id
           OR replacement_item.execution_segment_sales_allocation_id
                IS DISTINCT FROM
                   source_item.execution_segment_sales_allocation_id
           OR replacement_item.source_daily_report_item_id
                IS DISTINCT FROM source_item.source_daily_report_item_id);
    IF invalid_line_count > 0 THEN
        RAISE EXCEPTION 'FINISHED_IN reversal replacement provenance is invalid'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_finished_in_confirmation_reversal
    AFTER INSERT ON production_finished_in_confirmation_reversals
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_production_finished_in_confirmation_reversal();
CREATE CONSTRAINT TRIGGER trg_validate_finished_in_confirmation_reversal_items
    AFTER INSERT ON production_finished_in_confirmation_reversal_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_production_finished_in_confirmation_reversal();
CREATE CONSTRAINT TRIGGER trg_validate_finished_in_confirmation_source_state
    AFTER UPDATE OF status ON stock_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION fn_validate_production_finished_in_confirmation_reversal();

CREATE OR REPLACE FUNCTION fn_validate_finished_in_report_item_capacity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    report_item_id UUID := NEW.source_daily_report_item_id;
    report_qty NUMERIC(18,4);
    linked_qty NUMERIC(18,4);
BEGIN
    IF report_item_id IS NULL THEN RETURN NEW; END IF;
    SELECT qty INTO report_qty
    FROM production_daily_report_items
    WHERE id = report_item_id AND is_deleted = FALSE;
    SELECT COALESCE(SUM(item.qty), 0) INTO linked_qty
    FROM stock_document_items item
    JOIN stock_documents document
      ON document.id = item.doc_id
     AND document.doc_type = 'FINISHED_IN'
     AND document.status <> -1
     AND document.is_deleted = FALSE
    WHERE item.source_daily_report_item_id = report_item_id
      AND item.is_deleted = FALSE;
    IF report_qty IS NULL OR linked_qty > report_qty THEN
        RAISE EXCEPTION 'FINISHED_IN quantities exceed source report line capacity'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_finished_in_report_item_capacity
    AFTER INSERT OR UPDATE OF qty, source_daily_report_item_id, is_deleted
    ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_finished_in_report_item_capacity();

-- V164 guard remains the default.  A narrow transaction-local GUC permits only
-- quantity/proportional-value shrink on a production-linked FINISHED_IN draft.
CREATE OR REPLACE FUNCTION fn_guard_production_linked_stock_document_item()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_document_id UUID := COALESCE(OLD.doc_id, NEW.doc_id);
    v_document stock_documents%ROWTYPE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF fn_is_production_linked_stock_document(v_document_id) THEN
            RAISE EXCEPTION 'production-linked stock document item cannot be deleted'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_linked_stock_document_item_delete_guard';
        END IF;
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE'
       AND fn_is_production_report_cleanup_authorized(v_document_id)
       AND OLD.is_deleted = FALSE AND NEW.is_deleted = TRUE
       AND (to_jsonb(NEW) - ARRAY['is_deleted','updated_at','updated_by'])
           = (to_jsonb(OLD) - ARRAY['is_deleted','updated_at','updated_by']) THEN
        RETURN NEW;
    END IF;
    IF fn_is_production_stock_cleanup_authorized(v_document_id)
       AND OLD.is_deleted = FALSE AND NEW.is_deleted = TRUE
       AND (to_jsonb(NEW) - ARRAY['is_deleted','updated_at','updated_by'])
           = (to_jsonb(OLD) - ARRAY['is_deleted','updated_at','updated_by']) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE'
       AND current_setting(
            'app.production_finished_in_confirm_doc_id', TRUE)
            = v_document_id::TEXT
       AND fn_is_production_linked_stock_document(v_document_id) THEN
        SELECT * INTO v_document FROM stock_documents
        WHERE id = v_document_id;
        IF v_document.doc_type = 'FINISHED_IN'
           AND v_document.status = 0
           AND OLD.is_deleted = FALSE
           AND NEW.is_deleted = TRUE
           AND (to_jsonb(NEW) - ARRAY[
                'is_deleted','deleted_at','updated_at','updated_by'])
               = (to_jsonb(OLD) - ARRAY[
                'is_deleted','deleted_at','updated_at','updated_by']) THEN
            RETURN NEW;
        END IF;
        IF v_document.doc_type = 'FINISHED_IN'
           AND v_document.status = 0
           AND OLD.qty > 0
           AND NEW.qty > 0
           AND NEW.reported_qty IS NOT DISTINCT FROM
                COALESCE(OLD.reported_qty, OLD.qty)
           AND NEW.qty <= NEW.reported_qty
           AND NEW.base_qty IS NOT DISTINCT FROM
                round(NEW.qty * NEW.unit_rate, 4)
           AND (to_jsonb(NEW) - ARRAY[
                'qty','base_qty','reported_qty','amount_original','amount_local',
                'weight','gift_qty','updated_at','updated_by'])
               = (to_jsonb(OLD) - ARRAY[
                'qty','base_qty','reported_qty','amount_original','amount_local',
                'weight','gift_qty','updated_at','updated_by'])
           AND NEW.amount_original IS NOT DISTINCT FROM
                (CASE WHEN OLD.amount_original IS NULL THEN NULL
                      ELSE round(OLD.amount_original * NEW.qty / OLD.qty, 4) END)
           AND NEW.amount_local IS NOT DISTINCT FROM
                (CASE WHEN OLD.amount_local IS NULL THEN NULL
                      ELSE round(OLD.amount_local * NEW.qty / OLD.qty, 4) END)
           AND NEW.weight IS NOT DISTINCT FROM
                (CASE WHEN OLD.weight IS NULL THEN NULL
                      ELSE round(OLD.weight * NEW.qty / OLD.qty, 4) END)
           AND NEW.gift_qty IS NOT DISTINCT FROM
                (CASE WHEN OLD.gift_qty IS NULL THEN NULL
                      ELSE round(OLD.gift_qty * NEW.qty / OLD.qty, 4) END) THEN
            RETURN NEW;
        END IF;
    END IF;

    IF fn_is_production_linked_stock_document(v_document_id) THEN
        IF NEW.doc_id IS DISTINCT FROM OLD.doc_id
           OR NEW.bill_type IS DISTINCT FROM OLD.bill_type
           OR NEW.bill_no IS DISTINCT FROM OLD.bill_no
           OR NEW.bill_date IS DISTINCT FROM OLD.bill_date
           OR NEW.line_no IS DISTINCT FROM OLD.line_no
           OR NEW.goods_id IS DISTINCT FROM OLD.goods_id
           OR NEW.color_id IS DISTINCT FROM OLD.color_id
           OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
           OR NEW.unit_rate IS DISTINCT FROM OLD.unit_rate
           OR NEW.qty IS DISTINCT FROM OLD.qty
           OR NEW.reported_qty IS DISTINCT FROM OLD.reported_qty
           OR NEW.base_qty IS DISTINCT FROM OLD.base_qty
           OR NEW.price IS DISTINCT FROM OLD.price
           OR NEW.amount_original IS DISTINCT FROM OLD.amount_original
           OR NEW.amount_local IS DISTINCT FROM OLD.amount_local
           OR NEW.weight IS DISTINCT FROM OLD.weight
           OR NEW.gift_qty IS DISTINCT FROM OLD.gift_qty
           OR NEW.surplus_qty IS DISTINCT FROM OLD.surplus_qty
           OR NEW.count_qty IS DISTINCT FROM OLD.count_qty
           OR NEW.place IS DISTINCT FROM OLD.place
           OR NEW.upstream_item_id IS DISTINCT FROM OLD.upstream_item_id
           OR NEW.execution_segment_id IS DISTINCT FROM OLD.execution_segment_id
           OR NEW.execution_segment_sales_allocation_id IS DISTINCT FROM
                OLD.execution_segment_sales_allocation_id
           OR NEW.source_daily_report_item_id IS DISTINCT FROM
                OLD.source_daily_report_item_id
           OR NEW.source_doc_no IS DISTINCT FROM OLD.source_doc_no
           OR NEW.remark IS DISTINCT FROM OLD.remark
           OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
           OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at THEN
            RAISE EXCEPTION 'production-linked stock document item is immutable'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_linked_stock_document_item_update_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON COLUMN stock_document_items.reported_qty IS
    'FINISHED_IN 报工申报待入库量；仓库点收后 qty 为本单实收量，余量另建草稿';
COMMENT ON COLUMN stock_document_items.source_daily_report_item_id IS
    'FINISHED_IN 明细到生产报工明细的 UUID 真源；编号和相同货品不能建立关系';
COMMENT ON TABLE production_finished_in_confirmations IS
    '生产成品入库的仓库实物点收头；逐单唯一、幂等、append-only';
COMMENT ON TABLE production_finished_in_confirmation_items IS
    '逐行申报/实收/余量守恒及余量草稿明细 UUID 映射';
COMMENT ON TABLE production_finished_in_confirmation_reversals IS
    '已点收生产成品入库的追加式专用红冲；每次必须重建原 accepted slice 待点收草稿';
COMMENT ON TABLE production_finished_in_confirmation_reversal_items IS
    '点收确认正数实收行到红冲替代草稿行的 UUID 与数量守恒映射';
