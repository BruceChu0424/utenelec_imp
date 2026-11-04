-- A current operation adopts a physical base quantity once. Historical picking,
-- dispatch and reversal retain their actual reservation or movement quantity.
ALTER TABLE sales_shipment_items
 ADD COLUMN quantity_adoption_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN quantity_precision_policy jsonb,
 ADD COLUMN adopted_base_qty numeric;
ALTER TABLE sales_shipment_items ALTER COLUMN quantity_adoption_version SET DEFAULT 2;
ALTER TABLE sales_shipment_items ADD CONSTRAINT sales_shipment_quantity_adoption_chk CHECK(
 quantity_adoption_version=1 AND quantity_precision_policy IS NULL AND adopted_base_qty IS NULL
 OR quantity_adoption_version=2 AND quantity_precision_policy IS NOT NULL AND adopted_base_qty IS NOT NULL AND adopted_base_qty>0
  AND fn_financial_amount_is_exact(adopted_base_qty));

CREATE FUNCTION fn_guard_shipment_quantity_adoption() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE operands_changed boolean;adopt boolean;policy jsonb;basic numeric;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.quantity_adoption_version<>2 OR NEW.quantity_precision_policy IS NOT NULL THEN
   RAISE EXCEPTION 'new shipment quantities require the current exact operation' USING ERRCODE='23514';END IF;
  adopt:=true;
 ELSE
  operands_changed:=NEW.qty IS DISTINCT FROM OLD.qty OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
    OR NEW.unit_rate IS DISTINCT FROM OLD.unit_rate;
  adopt:=operands_changed OR OLD.quantity_adoption_version=1 AND NEW.quantity_adoption_version=2;
  IF NEW.quantity_precision_policy IS DISTINCT FROM OLD.quantity_precision_policy
   OR NEW.adopted_base_qty IS DISTINCT FROM OLD.adopted_base_qty
   OR NEW.quantity_adoption_version IS DISTINCT FROM OLD.quantity_adoption_version AND NOT adopt THEN
   RAISE EXCEPTION 'shipment quantity evidence cannot be replaced independently' USING ERRCODE='55000';END IF;
  IF NOT adopt THEN RETURN NEW;END IF;
  IF EXISTS(SELECT 1 FROM stock_movements movement WHERE movement.source_doc_type='SALES_SHIPMENT'
      AND movement.source_item_id=OLD.id AND movement.source_doc_id=OLD.shipment_id)
   OR EXISTS(SELECT 1 FROM stock_reservations reservation WHERE reservation.owner_type='CUSTOMER_SHIPMENT_ITEM'
      AND reservation.owner_id=OLD.id AND NOT reservation.is_deleted
      AND (reservation.consumed_qty>0 OR reservation.status=0 AND reservation.qty-reservation.consumed_qty-reservation.released_qty>0)) THEN
   RAISE EXCEPTION 'actual shipment or picking quantities must be retained' USING ERRCODE='55000';END IF;
 END IF;
 IF NEW.qty IS NULL OR NEW.qty<=0 OR NEW.unit_id IS NULL OR NEW.unit_rate IS NULL OR NEW.unit_rate<=0 THEN
  RAISE EXCEPTION 'shipment quantity requires its actual positive quantity and unit basis' USING ERRCODE='23514';END IF;
 policy:=fn_business_precision_snapshot();
 basic:=fn_document_quantity_to_base(NEW.qty,NEW.unit_rate,policy,true);
 IF TG_OP='INSERT' AND NEW.adopted_base_qty IS NOT NULL AND NEW.adopted_base_qty IS DISTINCT FROM basic THEN
  RAISE EXCEPTION 'shipment supplied quantity differs from its actual adoption' USING ERRCODE='23514';END IF;
 NEW.adopted_base_qty:=basic;NEW.quantity_precision_policy:=policy;NEW.quantity_adoption_version:=2;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00_shipment_quantity_adoption BEFORE INSERT OR UPDATE ON sales_shipment_items
 FOR EACH ROW EXECUTE FUNCTION fn_guard_shipment_quantity_adoption();
ALTER TABLE sales_shipment_items ENABLE ALWAYS TRIGGER trg_00_shipment_quantity_adoption;

CREATE FUNCTION fn_sales_shipment_frozen_base(item sales_shipment_items) RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE basic numeric;
BEGIN
 IF item.qty IS NULL OR item.qty<=0 OR item.unit_id IS NULL OR item.unit_rate IS NULL OR item.unit_rate<=0 THEN
  RAISE EXCEPTION 'shipment source unit basis is unknown' USING ERRCODE='23514';END IF;
 IF item.quantity_adoption_version=1 THEN
  basic:=item.qty*item.unit_rate;
 ELSE
  basic:=fn_document_quantity_to_base(item.qty,item.unit_rate,item.quantity_precision_policy,false);
  IF basic IS DISTINCT FROM item.adopted_base_qty THEN
   RAISE EXCEPTION 'shipment original policy does not prove its saved physical quantity' USING ERRCODE='23514';END IF;
 END IF;
 IF basic<=0 OR NOT fn_financial_amount_is_exact(basic) THEN
  RAISE EXCEPTION 'shipment lacks a native exact physical quantity' USING ERRCODE='23514';END IF;
 RETURN basic;
END $$;

CREATE FUNCTION fn_customer_shipment_picked_base(item sales_shipment_items) RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE count_rows integer;actual numeric;
BEGIN
 IF item.quantity_adoption_version=1 THEN
  SELECT count(*),min(CASE WHEN reservation.consumed_qty>0 THEN reservation.consumed_qty
      ELSE reservation.qty-reservation.released_qty-reservation.consumed_qty END)
    INTO count_rows,actual
   FROM stock_reservations reservation JOIN sales_shipments document ON document.id=item.shipment_id
   WHERE reservation.owner_type='CUSTOMER_SHIPMENT_ITEM' AND reservation.owner_id=item.id
    AND reservation.source_doc_type='SALES_SHIPMENT' AND reservation.source_doc_id=item.shipment_id
    AND reservation.goods_id=item.goods_id AND reservation.color_id IS NOT DISTINCT FROM item.color_id
    AND reservation.warehouse_id=COALESCE(item.warehouse_id,document.warehouse_id)
    AND NOT reservation.is_deleted AND (reservation.consumed_qty>0
      OR reservation.status=0 AND reservation.qty-reservation.consumed_qty-reservation.released_qty>0);
  IF count_rows>1 THEN RAISE EXCEPTION 'historical shipment has ambiguous actual picking quantities' USING ERRCODE='23514';END IF;
  IF count_rows=1 THEN
   IF actual<=0 OR NOT fn_financial_amount_is_exact(actual) THEN
    RAISE EXCEPTION 'historical shipment actual picking quantity is invalid' USING ERRCODE='23514';END IF;
   RETURN actual;
  END IF;
 END IF;
 RETURN fn_sales_shipment_frozen_base(item);
END $$;

CREATE FUNCTION fn_sales_shipment_original_base(item sales_shipment_items) RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE expected numeric;count_original integer;
BEGIN
 SELECT count(*),min(movement.qty) INTO count_original,expected
  FROM stock_movements movement JOIN sales_shipments document ON document.id=item.shipment_id
  WHERE movement.source_doc_type='SALES_SHIPMENT' AND movement.source_doc_id=item.shipment_id
   AND movement.source_item_id=item.id AND movement.movement_type=3
   AND movement.goods_id=item.goods_id AND movement.color_id IS NOT DISTINCT FROM item.color_id
   AND movement.warehouse_id=COALESCE(item.warehouse_id,document.warehouse_id) AND movement.direction=-1;
 IF count_original<>1 OR expected IS NULL OR expected<=0 OR NOT fn_financial_amount_is_exact(expected) THEN
  RAISE EXCEPTION 'shipment reversal requires its unique original physical movement' USING ERRCODE='23514';END IF;
 RETURN expected;
END $$;

CREATE FUNCTION fn_guard_shipment_actual_quantity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE item sales_shipment_items%ROWTYPE;expected numeric;
BEGIN
 IF TG_TABLE_NAME='stock_reservations' THEN
  IF NEW.owner_type IS DISTINCT FROM 'CUSTOMER_SHIPMENT_ITEM' THEN RETURN NEW;END IF;
  SELECT * INTO item FROM sales_shipment_items WHERE id=NEW.owner_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'shipment reservation source is missing' USING ERRCODE='23514';END IF;
  IF item.quantity_adoption_version=1 THEN
   IF TG_OP='INSERT' THEN RAISE EXCEPTION 'new picking requires an explicitly adopted current shipment quantity' USING ERRCODE='23514';END IF;
   IF NEW.qty IS DISTINCT FROM OLD.qty THEN RAISE EXCEPTION 'historical picking quantity cannot be reinterpreted' USING ERRCODE='55000';END IF;
   RETURN NEW;
  END IF;
  expected:=fn_sales_shipment_frozen_base(item);
  IF NEW.source_doc_type IS DISTINCT FROM 'SALES_SHIPMENT' OR NEW.source_doc_id IS DISTINCT FROM item.shipment_id
   OR NEW.goods_id IS DISTINCT FROM item.goods_id OR NEW.color_id IS DISTINCT FROM item.color_id
   OR NEW.qty IS DISTINCT FROM expected THEN
   RAISE EXCEPTION 'picking quantity differs from its frozen shipment source' USING ERRCODE='23514';END IF;
 ELSE
  IF NEW.source_doc_type IS DISTINCT FROM 'SALES_SHIPMENT' OR NEW.movement_type<>3 THEN RETURN NULL;END IF;
  SELECT * INTO item FROM sales_shipment_items WHERE id=NEW.source_item_id AND shipment_id=NEW.source_doc_id;
  IF NOT FOUND OR item.quantity_adoption_version=1 THEN RETURN NULL;END IF;
  IF NEW.direction=-1 THEN expected:=fn_sales_shipment_frozen_base(item);
  ELSE
   expected:=fn_sales_shipment_original_base(item);
  END IF;
  IF NEW.goods_id IS DISTINCT FROM item.goods_id OR NEW.color_id IS DISTINCT FROM item.color_id OR NEW.qty IS DISTINCT FROM expected
   OR NEW.warehouse_id IS DISTINCT FROM COALESCE(item.warehouse_id,(SELECT warehouse_id FROM sales_shipments WHERE id=item.shipment_id)) THEN
   RAISE EXCEPTION 'shipment movement differs from its actual frozen physical source' USING ERRCODE='23514';END IF;
  RETURN NULL;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_shipment_reservation_quantity BEFORE INSERT OR UPDATE ON stock_reservations
 FOR EACH ROW EXECUTE FUNCTION fn_guard_shipment_actual_quantity();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_shipment_reservation_quantity;
CREATE CONSTRAINT TRIGGER trg_shipment_movement_quantity AFTER INSERT ON stock_movements
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_shipment_actual_quantity();
ALTER TABLE stock_movements ENABLE ALWAYS TRIGGER trg_shipment_movement_quantity;
