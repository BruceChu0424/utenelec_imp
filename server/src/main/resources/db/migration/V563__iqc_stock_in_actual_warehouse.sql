-- Warehouse confirmation chooses each physical destination. Receipt/inspection
-- warehouses remain historical receiving suggestions; PASS, source UUIDs and
-- frozen quantities never change when a different actual leaf is selected.
CREATE FUNCTION fn_procurement_received_in_warehouse(p_type TEXT,p_receipt_item UUID,p_warehouse UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH source AS (
        SELECT item.id,receipt.id receipt_id,receipt.warehouse_id,item.qty*COALESCE(item.unit_rate,1) qty
        FROM purchase_receipt_items item JOIN purchase_receipts receipt ON receipt.id=item.receipt_id
        WHERE p_type='PURCHASE' AND item.id=p_receipt_item AND NOT item.is_deleted
          AND NOT receipt.is_deleted AND receipt.status=1
        UNION ALL
        SELECT item.id,receipt.id,receipt.warehouse_id,item.qty*COALESCE(item.unit_rate,1)
        FROM subcontract_receipt_items item JOIN subcontract_receipts receipt ON receipt.id=item.receipt_id
        WHERE p_type='SUBCONTRACT' AND item.id=p_receipt_item AND NOT item.is_deleted
          AND NOT receipt.is_deleted AND receipt.status=1
    ), inspections AS (
        SELECT inspection.* FROM procurement_inspection_items inspection JOIN source ON source.id=inspection.receipt_item_id
        WHERE inspection.receipt_type=p_type AND inspection.receipt_id=source.receipt_id
    )
    SELECT CASE WHEN EXISTS(SELECT 1 FROM inspections) THEN
        COALESCE((SELECT sum(stock.base_qty) FROM procurement_iqc_stock_in_batch_items stock
            JOIN inspections inspection ON inspection.id=stock.inspection_item_id
            WHERE stock.warehouse_id=p_warehouse AND inspection.status<>'REVERSED'),0)
        +COALESCE((SELECT sum(legacy_stocked_base_qty) FROM inspections
            WHERE warehouse_id=p_warehouse AND status<>'REVERSED'),0)
    ELSE COALESCE((SELECT sum(qty) FROM source WHERE warehouse_id=p_warehouse),0) END;
$$;

CREATE FUNCTION fn_procurement_receipt_stock_warehouses(p_type TEXT,p_receipt UUID)
RETURNS TABLE(warehouse_id UUID) LANGUAGE sql STABLE AS $$
    SELECT stock.warehouse_id FROM procurement_iqc_stock_in_batch_items stock
    JOIN procurement_iqc_stock_in_batches batch ON batch.id=stock.batch_id
    WHERE batch.receipt_type=p_type AND batch.receipt_id=p_receipt
    UNION
    SELECT inspection.warehouse_id FROM procurement_inspection_items inspection
    WHERE inspection.receipt_type=p_type AND inspection.receipt_id=p_receipt
      AND inspection.legacy_stocked_base_qty>0 AND inspection.warehouse_id IS NOT NULL
    UNION
    SELECT receipt.warehouse_id FROM purchase_receipts receipt
    WHERE p_type='PURCHASE' AND receipt.id=p_receipt AND receipt.warehouse_id IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM procurement_inspection_items WHERE receipt_type=p_type AND receipt_id=p_receipt)
    UNION
    SELECT receipt.warehouse_id FROM subcontract_receipts receipt
    WHERE p_type='SUBCONTRACT' AND receipt.id=p_receipt AND receipt.warehouse_id IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM procurement_inspection_items WHERE receipt_type=p_type AND receipt_id=p_receipt);
$$;

CREATE FUNCTION fn_guard_iqc_actual_warehouse_selection() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(
        WITH RECURSIVE ancestry AS (
            SELECT id,parent_id,status,is_deleted,ARRAY[id] path FROM warehouses WHERE id=NEW.warehouse_id
            UNION ALL
            SELECT parent.id,parent.parent_id,parent.status,parent.is_deleted,child.path||parent.id
            FROM ancestry child JOIN warehouses parent ON parent.id=child.parent_id
            WHERE NOT parent.id=ANY(child.path)
        ) SELECT 1 FROM warehouses leaf WHERE leaf.id=NEW.warehouse_id
          AND leaf.is_accountable AND NOT leaf.is_deleted AND leaf.status='使用'
          AND NOT EXISTS(SELECT 1 FROM warehouses child WHERE child.parent_id=leaf.id AND NOT child.is_deleted)
          AND EXISTS(SELECT 1 FROM ancestry WHERE parent_id IS NULL)
          AND NOT EXISTS(SELECT 1 FROM ancestry WHERE is_deleted OR status IS DISTINCT FROM '使用')
    ) THEN
        RAISE EXCEPTION 'IQC stock-in requires an explicitly selected active accounting leaf warehouse'
            USING ERRCODE='23514',CONSTRAINT='iqc_stock_in_actual_warehouse_selection_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_iqc_actual_warehouse_selection BEFORE INSERT ON procurement_iqc_stock_in_batch_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_iqc_actual_warehouse_selection();
ALTER TABLE procurement_iqc_stock_in_batch_items ENABLE ALWAYS TRIGGER trg_iqc_actual_warehouse_selection;

DO $actual_warehouse_authority$
DECLARE definition TEXT;needle TEXT;function_name TEXT;receipt_type TEXT;allocation_table TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_validate_procurement_iqc_stock_in_item()'::regprocedure) INTO definition;
    needle:='       OR v_inspection.warehouse_id <> NEW.warehouse_id';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V563 IQC stock-in identity guard contract changed';
    END IF;
    EXECUTE replace(definition,needle,'       OR NEW.warehouse_id IS NULL');

    SELECT pg_get_functiondef('fn_preplan_reservation_has_qualified_origin(uuid)'::regprocedure) INTO definition;
    needle:='                   AND inspection.warehouse_id=stock_item.warehouse_id';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V563 qualified source warehouse contract changed';
    END IF;
    EXECUTE replace(definition,needle,'');

    SELECT pg_get_functiondef('fn_check_preplan_analysis_stock_exact_peg()'::regprocedure) INTO definition;
    needle:='inspection.warehouse_id <> reservation.warehouse_id';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V563 exact IQC peg warehouse contract changed';
    END IF;
    EXECUTE replace(definition,needle,$proof$(CASE WHEN disposition.requires_warehouse_stock_in THEN NOT EXISTS(
        SELECT 1 FROM procurement_iqc_stock_in_batch_items actual
        JOIN procurement_iqc_stock_in_batches batch ON batch.id=actual.batch_id
        JOIN stock_movements movement ON movement.id=actual.stock_movement_id
        WHERE actual.pass_event_id=disposition.id AND actual.inspection_item_id=inspection.id
          AND batch.receipt_type=NEW.source_receipt_type AND batch.receipt_id=NEW.source_receipt_id
          AND actual.warehouse_id=reservation.warehouse_id AND actual.goods_id=reservation.goods_id
          AND actual.color_id IS NOT DISTINCT FROM reservation.color_id AND actual.base_qty>=NEW.qty
          AND movement.source_doc_type=NEW.source_receipt_type||'_RECEIPT'
          AND movement.source_doc_id=NEW.source_receipt_id AND movement.source_item_id=actual.id
          AND movement.warehouse_id=actual.warehouse_id AND movement.goods_id=actual.goods_id
          AND movement.color_id IS NOT DISTINCT FROM actual.color_id AND movement.direction=1 AND movement.qty=actual.base_qty)
        ELSE inspection.warehouse_id IS DISTINCT FROM reservation.warehouse_id END)$proof$);

    -- Legacy formal supply also uses qualified quantity physically received in
    -- the reservation's actual warehouse, never a receipt header relabel.
    FOREACH receipt_type IN ARRAY ARRAY['PURCHASE','SUBCONTRACT'] LOOP
        function_name:=CASE receipt_type WHEN 'PURCHASE' THEN 'fn_assert_purchase_receipt_allocation'
                         ELSE 'fn_assert_subcontract_receipt_allocation' END;
        allocation_table:=CASE receipt_type WHEN 'PURCHASE' THEN 'production_material_receipt_allocations'
                           ELSE 'production_material_subcontract_receipt_allocations' END;
        SELECT pg_get_functiondef((function_name||'(uuid)')::regprocedure) INTO definition;
        needle:='receipt.warehouse_id = demand.warehouse_id';
        IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
            RAISE EXCEPTION 'V563 formal receipt warehouse contract changed: %',function_name;
        END IF;
        EXECUTE replace(definition,needle,format(
            'fn_procurement_received_in_warehouse(%L,receipt_item.id,reservation.warehouse_id)>=%s',receipt_type,
            '(SELECT COALESCE(SUM(allocated.allocated_qty),0) FROM '||allocation_table||' allocated '
            ||'JOIN stock_reservations actual ON actual.id=allocated.reservation_id '
            ||'WHERE allocated.receipt_item_id=receipt_item.id AND allocated.status=''EFFECTIVE'' '
            ||'AND actual.warehouse_id=reservation.warehouse_id)'));
    END LOOP;
END;
$actual_warehouse_authority$;

COMMENT ON COLUMN procurement_iqc_stock_in_batch_items.warehouse_id IS
    'Actual leaf warehouse explicitly confirmed for this PASS slice; stock movement and qualified entitlement use this UUID, independently of receipt/inspection suggestions.';
