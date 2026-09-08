-- A shared trigger must select its row type before accessing table-specific fields.
-- PostgreSQL resolves NEW fields when preparing an expression; a boolean AND
-- does not protect movement_id when this invocation is a cost revision row.

CREATE OR REPLACE FUNCTION fn_check_subcontract_cost_scope_facts() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE object stock_value_production_cost_objects%ROWTYPE;expected_qty NUMERIC;complete BOOLEAN;approval UUID;
BEGIN
    SELECT * INTO object FROM stock_value_production_cost_objects WHERE execution_segment_id=NEW.execution_segment_id;
    IF object.source_kind='PRODUCTION_EXECUTION' THEN
        IF TG_TABLE_NAME='stock_value_production_cost_outputs' THEN
            IF NOT EXISTS(
                SELECT 1 FROM stock_movements movement JOIN stock_document_items item ON item.id=movement.source_item_id
                JOIN stock_documents document ON document.id=item.doc_id AND document.id=movement.source_doc_id
                WHERE movement.id=NEW.movement_id AND movement.source_doc_type='STOCK_DOC' AND document.doc_type='FINISHED_IN'
                    AND item.execution_segment_id=NEW.execution_segment_id) THEN
                RAISE EXCEPTION 'production output scope must match its actual finished-in document execution source' USING ERRCODE='23514';
            END IF;
        END IF;
        RETURN NULL;
    END IF;
    IF TG_TABLE_NAME='stock_value_production_cost_revisions' THEN
        IF object.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS' THEN
            SELECT target_qty_base,classification_complete,approval_case_id INTO expected_qty,complete,approval FROM v_subcontract_normal_loss_basis WHERE order_item_id=object.execution_segment_id;
            IF approval IS NOT NULL AND NEW.approval_evidence_id<>approval THEN
                RAISE EXCEPTION 'normal-loss allocation must identify the current financial target approval' USING ERRCODE='23514';
            END IF;
        ELSE
            SELECT COALESCE(SUM(base_qty),0) INTO expected_qty FROM procurement_receipt_consideration_parts
                WHERE receipt_type='SUBCONTRACT' AND receipt_item_id=object.execution_segment_id AND billing_mode='STANDARD';
            SELECT expected_qty>0 AND expected_qty=(SELECT COALESCE(SUM(qty_base),0) FROM subcontract_receipt_material_consumptions c
                WHERE c.receipt_item_id=object.execution_segment_id AND c.reversal_of IS NULL
                  AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions reversed WHERE reversed.reversal_of=c.id))
                AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions c WHERE c.receipt_item_id=object.execution_segment_id
                    AND c.reversal_of IS NULL AND c.consumption_basis<>'DIRECT_TARGET') INTO complete;
        END IF;
        IF expected_qty IS NULL OR NEW.target_qty_base<>expected_qty OR (NEW.scope_complete AND complete IS DISTINCT FROM TRUE) THEN
            RAISE EXCEPTION 'subcontract cost basis must use approved target quantity and explicitly classified original materials' USING ERRCODE='23514';
        END IF;
    ELSE
        IF NOT EXISTS(SELECT 1 FROM procurement_iqc_stock_in_batch_items item
            JOIN procurement_iqc_stock_consideration_parts stocked ON stocked.stock_in_item_id=item.id
            JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=stocked.quality_part_id
            JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
            LEFT JOIN procurement_iqc_funding_slices funding ON funding.id=part.funding_slice_id
            JOIN subcontract_receipt_items original ON original.id=CASE WHEN part.billing_mode='STANDARD' THEN part.receipt_item_id ELSE funding.root_receipt_item_id END
            WHERE item.stock_movement_id=NEW.movement_id AND part.receipt_type='SUBCONTRACT'
              AND CASE WHEN object.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS' THEN original.order_item_id ELSE original.id END=object.execution_segment_id)
        OR EXISTS(SELECT 1 FROM procurement_iqc_stock_in_batch_items item
            JOIN procurement_iqc_stock_consideration_parts stocked ON stocked.stock_in_item_id=item.id
            JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=stocked.quality_part_id
            JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
            LEFT JOIN procurement_iqc_funding_slices funding ON funding.id=part.funding_slice_id
            JOIN subcontract_receipt_items original ON original.id=CASE WHEN part.billing_mode='STANDARD' THEN part.receipt_item_id ELSE funding.root_receipt_item_id END
            WHERE item.stock_movement_id=NEW.movement_id
              AND CASE WHEN object.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS' THEN original.order_item_id ELSE original.id END IS DISTINCT FROM object.execution_segment_id) THEN
            RAISE EXCEPTION 'subcontract output must retain the exact original receipt and normal-loss order scopes' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
