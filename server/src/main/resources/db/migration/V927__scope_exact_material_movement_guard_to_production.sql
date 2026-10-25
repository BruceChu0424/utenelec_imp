-- The generic warehouse workflow also posts DRAW/WDRAW movements (including
-- partial issues and their reversals). Those documents have no production event.
-- Keep the V514 exact-event assertion for every production-owned movement.
-- This forward migration replaces only the function, preserving its OID,
-- constraint triggers, their deferred queues and all existing immutable facts.
CREATE OR REPLACE FUNCTION fn_check_material_movement_link()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE physical_link production_material_movement_links%ROWTYPE;
BEGIN
    IF TG_TABLE_NAME='stock_movements' THEN
        SELECT * INTO physical_link
        FROM production_material_movement_links WHERE movement_id=NEW.id;
        IF physical_link.id IS NULL THEN
            -- A manual movement must still identify the exact current document
            -- and item. Row warehouses and partial quantities are valid here.
            IF EXISTS (
                SELECT 1
                FROM stock_documents document
                JOIN stock_document_items item ON item.doc_id=document.id
                JOIN stock_movements movement ON movement.id=NEW.id
                WHERE document.id=NEW.source_doc_id
                  AND item.id=NEW.source_item_id
                  AND NEW.source_doc_type='STOCK_DOC'
                  AND ((document.doc_type='DRAW' AND NEW.movement_type=5)
                       OR (document.doc_type='WDRAW' AND NEW.movement_type=6))
                  AND NEW.goods_id=item.goods_id
                  AND NEW.color_id IS NOT DISTINCT FROM item.color_id
                  AND NEW.warehouse_id=COALESCE(item.warehouse_id,document.warehouse_id)
                  AND NEW.unit_id IS NOT DISTINCT FROM item.unit_id
                  AND NEW.unit_rate IS NOT DISTINCT FROM item.unit_rate
                  AND NEW.qty>0 AND NEW.direction IN (-1,1)
                  AND movement.source_doc_type=NEW.source_doc_type
                  AND movement.source_doc_id=NEW.source_doc_id
                  AND movement.source_item_id=NEW.source_item_id
                  AND movement.movement_type=NEW.movement_type
                  AND movement.goods_id=NEW.goods_id
                  AND movement.color_id IS NOT DISTINCT FROM NEW.color_id
                  AND movement.warehouse_id=NEW.warehouse_id
                  AND movement.unit_id IS NOT DISTINCT FROM NEW.unit_id
                  AND movement.unit_rate IS NOT DISTINCT FROM NEW.unit_rate
                  AND movement.qty=NEW.qty AND movement.direction=NEW.direction
                  AND NOT fn_is_production_linked_stock_document(document.id)
                  AND NOT fn_stock_document_has_history_provenance(document.id)
                  -- Include inactive/malformed mappings too: unlinking or
                  -- soft-deleting a production mapping cannot make it manual.
                  AND NOT EXISTS (SELECT 1 FROM plan_draw_links plan_link
                                  WHERE plan_link.draw_id=document.id)
                  AND NOT EXISTS (SELECT 1 FROM production_planning_package_documents package_document
                                  WHERE package_document.document_id=document.id)
                  AND NOT EXISTS (SELECT 1 FROM production_planning_package_document_items package_item
                                  WHERE package_item.document_id=document.id
                                     OR package_item.document_item_id=item.id)
                  AND NOT EXISTS (SELECT 1 FROM stock_document_items production_item
                                  WHERE production_item.doc_id=document.id
                                    AND (production_item.execution_segment_id IS NOT NULL
                                         OR production_item.execution_segment_sales_allocation_id IS NOT NULL))
                  AND NOT EXISTS (SELECT 1 FROM production_material_stock_events event
                                  WHERE event.stock_document_id=document.id)
                  AND NOT EXISTS (SELECT 1 FROM production_material_stock_postings posting
                                  JOIN stock_document_items posted_item
                                    ON posted_item.id=posting.stock_document_item_id
                                  WHERE posted_item.doc_id=document.id)
                  AND NOT EXISTS (
                      SELECT 1 FROM business_record_history history
                      WHERE (history.source_table IN (
                                 'production_planning_package_documents',
                                 'production_planning_package_document_items')
                             AND history.payload->>'document_id'=document.id::text)
                         OR (history.source_table='production_planning_package_document_items'
                             AND history.payload->>'document_item_id'=item.id::text)
                         OR (history.source_table='plan_draw_links'
                             AND history.payload->>'draw_id'=document.id::text)
                         OR (history.source_table='stock_document_items'
                             AND history.payload->>'doc_id'=document.id::text
                             AND (history.payload->>'execution_segment_id' IS NOT NULL
                                  OR history.payload->>'execution_segment_sales_allocation_id' IS NOT NULL)))
            ) THEN
                RETURN NULL;
            END IF;
            RAISE EXCEPTION 'production physical movement requires its exact material event'
                USING ERRCODE='23514',CONSTRAINT='production_material_exact_movement_guard';
        END IF;
        PERFORM fn_assert_material_movement_link(physical_link.event_id,physical_link.document_item_id);
    ELSIF TG_TABLE_NAME='production_material_movement_links' THEN
        PERFORM fn_assert_material_movement_link(NEW.event_id,NEW.document_item_id);
    ELSE
        PERFORM fn_assert_material_movement_link(NEW.event_id,NEW.stock_document_item_id);
    END IF;
    RETURN NULL;
END;
$$;
