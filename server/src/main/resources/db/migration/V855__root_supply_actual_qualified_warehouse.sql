-- A root analysis warehouse is a planning scope. Qualified ownership and sales
-- reservations retain the exact accounting leaf proved by their original stock-in.
-- Forward only: do not rewrite existing output events or applied V478 bytes.
CREATE OR REPLACE FUNCTION fn_guard_root_output_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    source_item production_material_analysis_items%ROWTYPE;
    material production_material_analysis_materials%ROWTYPE;
    original preplan_root_output_events%ROWTYPE;
    analysis_scope UUID;
    net_base NUMERIC;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'root output events are append-only' USING ERRCODE='23514';
    END IF;
    SELECT * INTO STRICT source_item FROM production_material_analysis_items
      WHERE id=NEW.analysis_item_id FOR UPDATE;
    SELECT * INTO STRICT material FROM production_material_analysis_materials
      WHERE id=NEW.root_material_id;
    SELECT warehouse_id INTO STRICT analysis_scope FROM production_material_analyses
      WHERE id=NEW.analysis_id;
    IF source_item.analysis_id<>NEW.analysis_id
       OR source_item.root_material_id IS DISTINCT FROM NEW.root_material_id
       OR material.node_role<>'ROOT_SUPPLY'
       OR material.analysis_item_id<>source_item.id
       OR material.goods_id<>NEW.goods_id
       OR material.color_id IS DISTINCT FROM NEW.color_id
       OR source_item.sales_order_item_id IS DISTINCT FROM NEW.sales_order_item_id THEN
        RAISE EXCEPTION 'root output source identity mismatch' USING ERRCODE='23514';
    END IF;
    IF NEW.event_kind='REVERSE' THEN
        SELECT * INTO STRICT original FROM preplan_root_output_events
          WHERE id=NEW.reversed_event_id AND event_kind='FULFILL' FOR UPDATE;
        IF original.analysis_id<>NEW.analysis_id
           OR original.analysis_item_id<>NEW.analysis_item_id
           OR original.root_material_id<>NEW.root_material_id
           OR original.warehouse_id<>NEW.warehouse_id
           OR original.goods_id<>NEW.goods_id
           OR original.color_id IS DISTINCT FROM NEW.color_id
           OR original.sales_order_item_id IS DISTINCT FROM NEW.sales_order_item_id
           OR original.qty_base<>NEW.qty_base OR original.route<>NEW.route
           OR original.source_reservation_id IS DISTINCT FROM NEW.source_reservation_id
           OR original.release_entitlement_event_id IS DISTINCT FROM NEW.release_entitlement_event_id
           OR original.sales_reservation_id IS DISTINCT FROM NEW.sales_reservation_id
           OR original.source_receipt_type IS DISTINCT FROM NEW.source_receipt_type
           OR original.source_receipt_id IS DISTINCT FROM NEW.source_receipt_id THEN
            RAISE EXCEPTION 'root output reversal must match its original slice'
              USING ERRCODE='23514';
        END IF;
    ELSE
        SELECT COALESCE(SUM(CASE WHEN event_kind='FULFILL' THEN qty_base ELSE -qty_base END),0)
          INTO net_base FROM preplan_root_output_events WHERE analysis_item_id=NEW.analysis_item_id;
        IF net_base+NEW.qty_base>CEIL((source_item.requested_qty-source_item.submitted_qty-source_item.approved_qty)
                                       *material.per_product_qty*10000)/10000 THEN
            RAISE EXCEPTION 'root output exceeds remaining source capacity' USING ERRCODE='23514';
        END IF;
        IF COALESCE(material.confirmed_route,'MAKE') NOT IN ('BUY','SUBCONTRACT')
           OR NEW.route IS DISTINCT FROM material.confirmed_route THEN
            RAISE EXCEPTION 'root output requires an external root route' USING ERRCODE='23514';
        END IF;
        IF NEW.source_reservation_id IS NULL AND (
            NOT fn_warehouse_same_main(analysis_scope,NEW.warehouse_id)
            OR NOT fn_warehouse_is_good_stock_leaf(NEW.warehouse_id)) THEN
            RAISE EXCEPTION 'root public output requires a good accounting leaf within its analysis scope'
              USING ERRCODE='23514';
        END IF;
        IF NEW.source_reservation_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM preplan_stock_entitlement_events released
            JOIN stock_reservations r ON r.id=released.stock_reservation_id
            WHERE released.id=NEW.release_entitlement_event_id
              AND released.event_type='RELEASE'
              AND released.stock_reservation_id=NEW.source_reservation_id
              AND released.beneficiary_analysis_id=NEW.analysis_id
              AND released.beneficiary_analysis_material_id=NEW.root_material_id
              AND released.qty=NEW.qty_base
              AND r.owner_type='PREPLAN_ANALYSIS' AND r.owner_id=NEW.analysis_id
              AND r.goods_id=NEW.goods_id AND r.color_id IS NOT DISTINCT FROM NEW.color_id
              AND r.source_doc_type=NEW.source_receipt_type||'_RECEIPT'
              AND r.source_doc_id=NEW.source_receipt_id
              AND r.warehouse_id=NEW.warehouse_id
              AND NOT EXISTS(SELECT 1 FROM warehouses defective
                  WHERE defective.id=r.warehouse_id AND defective.is_defective)
              AND ((NEW.source_receipt_type='PURCHASE' AND EXISTS(
                      SELECT 1 FROM purchase_receipts receipt WHERE receipt.id=NEW.source_receipt_id
                          AND receipt.status=1 AND NOT receipt.is_deleted))
                   OR (NEW.source_receipt_type='SUBCONTRACT' AND EXISTS(
                      SELECT 1 FROM subcontract_receipts receipt WHERE receipt.id=NEW.source_receipt_id
                          AND receipt.status=1 AND NOT receipt.is_deleted)))
              AND fn_preplan_reservation_has_qualified_origin(r.id)) THEN
            RAISE EXCEPTION 'root output lacks the matching exact qualified release and actual warehouse'
              USING ERRCODE='23514';
        END IF;
        IF NEW.sales_reservation_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM stock_reservations r
            WHERE r.id=NEW.sales_reservation_id AND r.order_item_id=NEW.sales_order_item_id
              AND r.owner_type='SALES_ORDER_ITEM' AND r.owner_id=NEW.sales_order_item_id
              AND r.warehouse_id=NEW.warehouse_id
              AND r.goods_id=NEW.goods_id AND r.color_id IS NOT DISTINCT FROM NEW.color_id
              AND r.source_doc_type='ROOT_SUPPLY_INBOUND' AND r.source_doc_id=NEW.analysis_item_id
              AND r.qty=NEW.qty_base AND r.consumed_qty=0 AND r.released_qty=0) THEN
            RAISE EXCEPTION 'root output lacks its exact same-warehouse sales reservation' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION fn_guard_root_output_event() IS
    'Root scope never replaces physical identity: qualified receipt release, output and sales reservation use their original actual warehouse; reversals mirror every original slice field.';
