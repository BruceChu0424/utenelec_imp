-- V418: an all-zero warehouse confirmation remains an append-only REJECTED
-- fact, but the unconsumed FQC PASS quantity must stay reachable through one
-- same-source residual FINISHED_IN draft. Historical REJECTED rows without a
-- residual remain valid; new service writes use the stronger linked shape.

ALTER TABLE production_finished_in_confirmations
    DROP CONSTRAINT production_finished_in_confirmation_shape_chk;

ALTER TABLE production_finished_in_confirmations
    ADD CONSTRAINT production_finished_in_confirmation_shape_chk CHECK (
        (decision IN ('ACCEPTED', 'LEGACY_APPROVED')
            AND residual_stock_document_id IS NULL)
        OR
        (decision = 'PARTIAL'
            AND residual_stock_document_id IS NOT NULL
            AND NULLIF(btrim(variance_reason), '') IS NOT NULL)
        OR
        (decision = 'REJECTED'
            AND NULLIF(btrim(variance_reason), '') IS NOT NULL));

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
          OR (confirmation.decision NOT IN ('PARTIAL', 'REJECTED')
              AND residual_item.id IS NOT NULL)
          OR ((confirmation.decision = 'PARTIAL'
               OR (confirmation.decision = 'REJECTED'
                   AND confirmation.residual_stock_document_id IS NOT NULL))
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

    IF confirmation.decision = 'PARTIAL'
       OR (confirmation.decision = 'REJECTED'
           AND confirmation.residual_stock_document_id IS NOT NULL) THEN
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
               OR (confirmation.residual_stock_document_id IS NULL
                   AND item.residual_stock_document_item_id IS NOT NULL)
               OR (confirmation.residual_stock_document_id IS NOT NULL
                   AND item.residual_stock_document_item_id IS NULL))) THEN
        RAISE EXCEPTION 'rejected confirmation must preserve all quantity for redelivery'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON CONSTRAINT production_finished_in_confirmation_shape_chk
    ON production_finished_in_confirmations IS
    'REJECTED preserves the warehouse decision and may link one same-source residual draft for redelivery; historical unlinked rejected facts remain valid.';
