-- Whole assembled products needing extra work keep their original SALES_ORDER_ITEM reservation.
-- These are subclaims, not additional stock reservations and not a release into public stock.
-- New source facts freeze the actual row credit given by the existing capped root-output curve.
-- Old append-only facts remain unknown: no invented historical backfill.
ALTER TABLE preplan_root_output_events ADD COLUMN qty_source numeric(18,4) CHECK(qty_source>=0);
CREATE FUNCTION fn_root_fulfilled_source_qty_with_delta(item_id uuid,delta_base numeric)
RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT LEAST(GREATEST(item.requested_qty-item.submitted_qty-item.approved_qty,0),
   CASE WHEN item.delivery_plan_snapshot->>'mode'='BOM' THEN
      GREATEST(COALESCE((SELECT sum(CASE WHEN event.event_type='FULFILL' THEN event.order_qty ELSE -event.order_qty END)
        FROM sales_delivery_fulfillment_events event JOIN sales_delivery_fulfillment_allocations allocation ON allocation.id=event.allocation_id
        WHERE allocation.analysis_item_id=item.id),0),0)
   ELSE GREATEST(TRUNC((COALESCE(sum(CASE WHEN output.event_kind='FULFILL' THEN output.qty_base ELSE -output.qty_base END),0)+delta_base)
      /COALESCE(NULLIF(root.per_product_qty,0),1),4),0) END)
 FROM production_material_analysis_items item
 LEFT JOIN production_material_analysis_materials root ON root.id=item.root_material_id
 LEFT JOIN preplan_root_output_events output ON output.analysis_item_id=item.id
 WHERE item.id=item_id GROUP BY item.id,root.per_product_qty;
$$;
CREATE OR REPLACE FUNCTION fn_root_fulfilled_source_qty(item_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT fn_root_fulfilled_source_qty_with_delta(item_id,0) $$;
CREATE FUNCTION fn_capture_root_output_source_credit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 PERFORM 1 FROM production_material_analysis_items WHERE id=NEW.analysis_item_id FOR UPDATE;
 IF NEW.event_kind='FULFILL' THEN
  NEW.qty_source:=fn_root_fulfilled_source_qty_with_delta(NEW.analysis_item_id,NEW.qty_base)
    -fn_root_fulfilled_source_qty(NEW.analysis_item_id);
 ELSE NEW.qty_source:=NULL; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_zz_capture_root_output_source_credit BEFORE INSERT ON preplan_root_output_events
 FOR EACH ROW EXECUTE FUNCTION fn_capture_root_output_source_credit();

CREATE TABLE sales_delivery_order_claims (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),component_id uuid NOT NULL REFERENCES sales_shipment_delivery_components(id),
 shipment_id uuid NOT NULL REFERENCES sales_shipments(id),order_item_id uuid NOT NULL REFERENCES sales_order_items(id),
 reservation_id uuid NOT NULL REFERENCES stock_reservations(id),warehouse_id uuid NOT NULL REFERENCES warehouses(id),
 goods_id uuid NOT NULL REFERENCES goods(id),color_id uuid REFERENCES colors(id),unit_id uuid NOT NULL REFERENCES units(id),
 quantity numeric(18,4) NOT NULL CHECK(quantity>0),unit_rate numeric NOT NULL CHECK(unit_rate>0),
 source_identity jsonb NOT NULL,source_consumed_baseline numeric(18,4) NOT NULL CHECK(source_consumed_baseline>=0),
 source_output_event_id uuid REFERENCES preplan_root_output_events(id),
 source_base_qty numeric(18,4) NOT NULL CHECK(source_base_qty>0),source_row_cap numeric(18,4) NOT NULL CHECK(source_row_cap>=0),
 request_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 created_by uuid DEFAULT NULLIF(current_setting('app.actor_id',true),'')::uuid,
 UNIQUE(request_id,component_id,reservation_id)
);
CREATE INDEX sales_order_claim_reservation ON sales_delivery_order_claims(reservation_id,warehouse_id);
CREATE INDEX sales_order_claim_component ON sales_delivery_order_claims(component_id);
CREATE TABLE sales_delivery_order_claim_requests (
 request_id uuid NOT NULL,component_id uuid NOT NULL REFERENCES sales_shipment_delivery_components(id),
 warehouse_id uuid NOT NULL REFERENCES warehouses(id),requested_qty numeric(18,4) NOT NULL CHECK(requested_qty>0),
 claimed_qty numeric(18,4) NOT NULL CHECK(claimed_qty>=0 AND claimed_qty<=requested_qty),
 created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(request_id,component_id)
);
CREATE TABLE sales_delivery_order_claim_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),claim_id uuid NOT NULL REFERENCES sales_delivery_order_claims(id),
 event_type text NOT NULL CHECK(event_type IN('CONSUME','CANCEL','REVERSE')),quantity numeric(18,4) NOT NULL CHECK(quantity>0),
 row_credit_qty numeric(18,4) NOT NULL CHECK(row_credit_qty>=0),
 counter_event_id uuid UNIQUE REFERENCES sales_delivery_order_claim_events(id),created_at timestamptz NOT NULL DEFAULT now(),
 created_by uuid DEFAULT NULLIF(current_setting('app.actor_id',true),'')::uuid,
 UNIQUE(claim_id,event_type),CHECK((event_type='REVERSE')=(counter_event_id IS NOT NULL))
);
ALTER TABLE sales_delivery_order_claims ADD CONSTRAINT sales_order_claim_request_fk
 FOREIGN KEY(request_id,component_id) REFERENCES sales_delivery_order_claim_requests(request_id,component_id)
 DEFERRABLE INITIALLY DEFERRED;
CREATE VIEW v_sales_delivery_order_claim_active AS
 SELECT claim.* FROM sales_delivery_order_claims claim WHERE NOT EXISTS(
  SELECT 1 FROM sales_delivery_order_claim_events event WHERE event.claim_id=claim.id AND event.event_type IN('CONSUME','CANCEL'));
CREATE TABLE sales_delivery_order_claim_row_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),component_id uuid NOT NULL REFERENCES sales_shipment_delivery_components(id),
 order_item_id uuid NOT NULL REFERENCES sales_order_items(id),event_type text NOT NULL CHECK(event_type IN('CONSUME','REVERSE')),
 quantity_base numeric(18,4) NOT NULL CHECK(quantity_base>0),quantity_row numeric(18,4) NOT NULL CHECK(quantity_row>=0),
 unit_rate numeric NOT NULL CHECK(unit_rate>0),before_base numeric NOT NULL CHECK(before_base>=0),
 before_row numeric NOT NULL CHECK(before_row>=0),after_base numeric NOT NULL CHECK(after_base>=0),after_row numeric NOT NULL CHECK(after_row>=0),
 precision_policy jsonb NOT NULL,counter_event_id uuid UNIQUE REFERENCES sales_delivery_order_claim_row_events(id),
 created_at timestamptz NOT NULL DEFAULT now(),created_by uuid DEFAULT NULLIF(current_setting('app.actor_id',true),'')::uuid,
 UNIQUE(component_id,event_type),CHECK((event_type='REVERSE')=(counter_event_id IS NOT NULL))
);

CREATE FUNCTION fn_sales_delivery_order_claim_identity(reservation stock_reservations) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
 SELECT jsonb_build_object('orderItem',reservation.order_item_id,'ownerType',reservation.owner_type,'owner',reservation.owner_id,
  'purpose',reservation.purpose,'goods',reservation.goods_id,'color',reservation.color_id,'warehouse',reservation.warehouse_id,
  'qty',reservation.qty,'source',reservation.source,'sourceDocType',reservation.source_doc_type,'sourceDoc',reservation.source_doc_id,
  'supplyType',reservation.supply_type,'supply',reservation.supply_id)
$$;
CREATE FUNCTION fn_sales_delivery_order_claim_held(p_component uuid,p_warehouse uuid DEFAULT NULL) RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT COALESCE(sum(quantity),0) FROM v_sales_delivery_order_claim_active
 WHERE component_id=p_component AND (p_warehouse IS NULL OR warehouse_id=p_warehouse)
$$;

CREATE FUNCTION fn_guard_sales_delivery_order_claim() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE component sales_shipment_delivery_components%ROWTYPE; source stock_reservations%ROWTYPE;
 item sales_order_items%ROWTYPE; at_location numeric; everywhere numeric; pinned numeric;physical numeric;
 output preplan_root_output_events%ROWTYPE;
BEGIN
 SELECT * INTO STRICT component FROM sales_shipment_delivery_components WHERE id=NEW.component_id FOR UPDATE;
 SELECT * INTO STRICT item FROM sales_order_items WHERE id=component.order_item_id FOR UPDATE;
 SELECT * INTO STRICT source FROM stock_reservations WHERE id=NEW.reservation_id FOR UPDATE;
 IF component.bom_path<>'[]'::jsonb OR item.delivery_plan->>'mode'<>'ASSEMBLED' OR component.required_operations='[]'::jsonb
   OR component.movement_id IS NOT NULL OR item.is_deleted
   OR NEW.shipment_id IS DISTINCT FROM component.shipment_id OR NEW.order_item_id IS DISTINCT FROM item.id
   OR NEW.goods_id IS DISTINCT FROM component.goods_id OR NEW.goods_id IS DISTINCT FROM item.goods_id
   OR NEW.color_id IS DISTINCT FROM component.color_id OR NEW.color_id IS DISTINCT FROM item.color_id
   OR NEW.unit_id IS DISTINCT FROM component.unit_id OR NEW.unit_rate IS DISTINCT FROM item.unit_rate
   OR NEW.unit_id IS DISTINCT FROM (SELECT unit_id FROM goods WHERE id=item.goods_id)
   OR NEW.warehouse_id IS DISTINCT FROM component.warehouse_id
   OR source.owner_type<>'SALES_ORDER_ITEM' OR source.order_item_id IS DISTINCT FROM item.id
   OR source.goods_id IS DISTINCT FROM NEW.goods_id OR source.color_id IS DISTINCT FROM NEW.color_id
   OR source.is_deleted OR source.status<>0 OR NEW.source_identity IS DISTINCT FROM fn_sales_delivery_order_claim_identity(source) THEN
  RAISE EXCEPTION 'assembled delivery claim must use the same original order stock identity' USING ERRCODE='23514'; END IF;
 SELECT COALESCE(sum(quantity),0),COALESCE(sum(quantity) FILTER(WHERE warehouse_id=NEW.warehouse_id),0)
  INTO everywhere,at_location FROM v_sales_delivery_order_claim_active WHERE reservation_id=source.id;
 IF everywhere+NEW.quantity>source.qty-source.consumed_qty-source.released_qty
   OR at_location+NEW.quantity>fn_stock_claim_open_at(source.id,NEW.warehouse_id)
   OR fn_sales_delivery_order_claim_held(component.id)+NEW.quantity>component.required_qty
   OR fn_sales_delivery_order_claim_held(component.id)+NEW.quantity+COALESCE((SELECT sum(qty-consumed_qty-released_qty)
      FROM stock_reservations held WHERE held.owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')
        AND held.owner_id=component.id AND held.status=0 AND NOT held.is_deleted),0)>component.required_qty THEN
  RAISE EXCEPTION 'original order stock claim exceeds the physical location or unclaimed source quantity' USING ERRCODE='23514'; END IF;
 physical:=fn_stock_storage_movable(NEW.warehouse_id,NEW.goods_id,NEW.color_id,ARRAY[item.id],true);
 SELECT COALESCE(sum(active.quantity),0) INTO pinned FROM v_sales_delivery_order_claim_active active
  JOIN stock_reservations reservation ON reservation.id=active.reservation_id
  WHERE active.warehouse_id=NEW.warehouse_id AND active.goods_id=NEW.goods_id
    AND active.color_id IS NOT DISTINCT FROM NEW.color_id
    AND (active.order_item_id=item.id OR reservation.warehouse_id IS NULL);
 IF pinned+NEW.quantity>physical THEN
  RAISE EXCEPTION 'original order claim lacks the actual unclaimed physical warehouse quantity' USING ERRCODE='23514'; END IF;
 IF NEW.source_consumed_baseline IS DISTINCT FROM source.consumed_qty-COALESCE((
  SELECT sum(event.quantity*CASE WHEN event.event_type='CONSUME' THEN 1 ELSE -1 END)
  FROM sales_delivery_order_claim_events event JOIN sales_delivery_order_claims claim ON claim.id=event.claim_id
  WHERE claim.reservation_id=source.id AND event.event_type IN('CONSUME','REVERSE')),0) THEN
  RAISE EXCEPTION 'original reservation consumption baseline is not proven' USING ERRCODE='23514'; END IF;
 IF NEW.source_base_qty<>source.qty THEN
  RAISE EXCEPTION 'original order row credit must retain its full original reservation base' USING ERRCODE='23514'; END IF;
 IF NEW.source_output_event_id IS NOT NULL THEN
  SELECT * INTO STRICT output FROM preplan_root_output_events WHERE id=NEW.source_output_event_id;
  IF output.event_kind<>'FULFILL' OR output.sales_reservation_id IS DISTINCT FROM source.id
   OR output.sales_order_item_id IS DISTINCT FROM item.id OR output.qty_source IS NULL
   OR output.qty_base<>NEW.source_base_qty OR output.qty_source<>NEW.source_row_cap
   OR NEW.unit_rate IS DISTINCT FROM (SELECT per_product_qty FROM production_material_analysis_materials WHERE id=output.root_material_id)
   OR EXISTS(SELECT 1 FROM preplan_root_output_events reverse WHERE reverse.reversed_event_id=output.id) THEN
   RAISE EXCEPTION 'original root output row credit is not an unreversed immutable source fact' USING ERRCODE='23514'; END IF;
 ELSIF NEW.unit_rate<>1 OR NEW.source_row_cap<>source.qty
   OR EXISTS(SELECT 1 FROM preplan_root_output_events WHERE sales_reservation_id=source.id AND event_kind='FULFILL') THEN
  RAISE EXCEPTION 'unproven legacy row credit cannot be inferred from a physical adopted quantity' USING ERRCODE='23514'; END IF;
 IF NEW.source_row_cap*NEW.unit_rate<>NEW.source_base_qty THEN
  IF NEW.quantity<>NEW.source_base_qty OR source.consumed_qty<>0 OR everywhere<>0
    OR NEW.source_output_event_id IS NULL
    OR EXISTS(SELECT 1 FROM preplan_root_output_events other WHERE other.analysis_item_id=output.analysis_item_id AND other.id<>output.id) THEN
   RAISE EXCEPTION 'nonlinear root credit requires its entire unique original reservation' USING ERRCODE='23514'; END IF;
 ELSIF trunc(NEW.quantity/NEW.unit_rate,4)*NEW.unit_rate<>NEW.quantity THEN
  RAISE EXCEPTION 'partial original-order credit must convert exactly to its native row precision' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_order_claim_guard BEFORE INSERT ON sales_delivery_order_claims
 FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_delivery_order_claim();

CREATE FUNCTION fn_guard_order_claim_private_priority() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE component sales_shipment_delivery_components%ROWTYPE;own_open numeric;held numeric;
BEGIN
 SELECT * INTO STRICT component FROM sales_shipment_delivery_components WHERE id=NEW.component_id FOR UPDATE;
 SELECT COALESCE(sum(GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty-COALESCE((
   SELECT sum(active.quantity) FROM v_sales_delivery_order_claim_active active
   WHERE active.reservation_id=reservation.id AND active.component_id<>component.id),0),0)),0)
 INTO own_open FROM stock_reservations reservation
 WHERE reservation.order_item_id=component.order_item_id AND reservation.owner_type='SALES_ORDER_ITEM'
   AND reservation.goods_id=component.goods_id AND reservation.color_id IS NOT DISTINCT FROM component.color_id
   AND reservation.status=0 AND NOT reservation.is_deleted;
 held:=fn_sales_delivery_order_claim_held(component.id);
 IF held<LEAST(component.required_qty,own_open) THEN
  RAISE EXCEPTION 'public stock cannot replace this orders existing private stock in another warehouse' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_order_claim_private_priority BEFORE INSERT ON sales_delivery_order_claim_requests
 FOR EACH ROW EXECUTE FUNCTION fn_guard_order_claim_private_priority();

CREATE FUNCTION fn_guard_sales_delivery_order_claim_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE claim sales_delivery_order_claims%ROWTYPE; original sales_delivery_order_claim_events%ROWTYPE;
 expected_credit numeric;
BEGIN
 SELECT * INTO STRICT claim FROM sales_delivery_order_claims WHERE id=NEW.claim_id FOR UPDATE;
 IF NEW.quantity IS DISTINCT FROM claim.quantity THEN RAISE EXCEPTION 'claim event must retain its exact original quantity' USING ERRCODE='23514'; END IF;
 IF NEW.event_type IN('CONSUME','CANCEL') THEN
  IF EXISTS(SELECT 1 FROM sales_delivery_order_claim_events WHERE claim_id=claim.id AND event_type IN('CONSUME','CANCEL')) THEN
   RAISE EXCEPTION 'claim already has a terminal consume or cancellation' USING ERRCODE='23514'; END IF;
  IF NEW.event_type='CANCEL' THEN expected_credit:=0;
  ELSIF claim.source_row_cap*claim.unit_rate=claim.source_base_qty THEN
   expected_credit:=trunc(NEW.quantity/claim.unit_rate,4);
   IF expected_credit*claim.unit_rate<>NEW.quantity THEN RAISE EXCEPTION 'claim credit conversion is inexact' USING ERRCODE='23514'; END IF;
  ELSE
   IF claim.quantity<>claim.source_base_qty OR claim.source_output_event_id IS NULL
     OR EXISTS(SELECT 1 FROM preplan_root_output_events other JOIN preplan_root_output_events source
        ON source.id=claim.source_output_event_id WHERE other.analysis_item_id=source.analysis_item_id AND other.id<>source.id)
     OR (SELECT consumed_qty FROM stock_reservations WHERE id=claim.reservation_id)<>claim.quantity THEN
    RAISE EXCEPTION 'nonlinear source credit requires a full unique source consumption' USING ERRCODE='23514'; END IF;
   expected_credit:=claim.source_row_cap;
  END IF;
  IF NEW.row_credit_qty<>expected_credit THEN RAISE EXCEPTION 'claim row credit differs from its original source cap' USING ERRCODE='23514'; END IF;
 ELSE
  SELECT * INTO STRICT original FROM sales_delivery_order_claim_events WHERE id=NEW.counter_event_id;
  IF original.claim_id<>claim.id OR original.event_type<>'CONSUME' OR original.quantity<>NEW.quantity OR original.row_credit_qty<>NEW.row_credit_qty THEN
   RAISE EXCEPTION 'claim reversal requires its unique original consumption' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_order_claim_event_guard BEFORE INSERT ON sales_delivery_order_claim_events
 FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_delivery_order_claim_event();

CREATE FUNCTION fn_guard_sales_delivery_order_claim_row_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE item sales_order_items%ROWTYPE; component sales_shipment_delivery_components%ROWTYPE;
 original sales_delivery_order_claim_row_events%ROWTYPE; before_base numeric;before_row numeric;used_base numeric;expected numeric;
BEGIN
 SELECT * INTO STRICT item FROM sales_order_items WHERE id=NEW.order_item_id FOR UPDATE;
 SELECT * INTO STRICT component FROM sales_shipment_delivery_components WHERE id=NEW.component_id;
 SELECT COALESCE(sum(quantity_base*CASE WHEN event_type='CONSUME' THEN 1 ELSE -1 END),0),
  COALESCE(sum(quantity_row*CASE WHEN event_type='CONSUME' THEN 1 ELSE -1 END),0)
  INTO before_base,before_row FROM sales_delivery_order_claim_row_events WHERE order_item_id=item.id;
 IF component.order_item_id<>item.id OR NEW.before_base<>before_base OR NEW.before_row<>before_row
   OR NEW.unit_rate IS DISTINCT FROM item.unit_rate THEN
  RAISE EXCEPTION 'order claim row conversion requires the original current cumulative source' USING ERRCODE='23514'; END IF;
 IF NEW.event_type='CONSUME' THEN
  SELECT COALESCE(sum(event.quantity),0),COALESCE(sum(event.row_credit_qty),0) INTO used_base,expected FROM sales_delivery_order_claim_events event
   JOIN sales_delivery_order_claims claim ON claim.id=event.claim_id
   WHERE claim.component_id=component.id AND event.event_type='CONSUME';
  IF NEW.quantity_base<>used_base OR NEW.after_base<>before_base+used_base OR NEW.after_row<>before_row+expected
    OR NEW.quantity_row<>expected THEN
   RAISE EXCEPTION 'order claim row debit differs from its immutable original source credits' USING ERRCODE='23514'; END IF;
 ELSE
  SELECT * INTO STRICT original FROM sales_delivery_order_claim_row_events WHERE id=NEW.counter_event_id;
  IF original.component_id<>component.id OR original.event_type<>'CONSUME'
    OR (NEW.quantity_base,NEW.quantity_row,NEW.unit_rate,NEW.precision_policy)
       IS DISTINCT FROM (original.quantity_base,original.quantity_row,original.unit_rate,original.precision_policy)
    OR NEW.after_base<>before_base-NEW.quantity_base OR NEW.after_row<>before_row-NEW.quantity_row THEN
   RAISE EXCEPTION 'order claim row reversal must mirror its frozen original adoption' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_order_claim_row_guard BEFORE INSERT ON sales_delivery_order_claim_row_events
 FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_delivery_order_claim_row_event();
CREATE FUNCTION fn_project_sales_delivery_order_claim_row() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 UPDATE sales_order_items SET reserved_qty=reserved_qty+CASE WHEN NEW.event_type='CONSUME' THEN -NEW.quantity_row ELSE NEW.quantity_row END,
  updated_at=now() WHERE id=NEW.order_item_id AND reserved_qty+CASE WHEN NEW.event_type='CONSUME' THEN -NEW.quantity_row ELSE NEW.quantity_row END>=0;
 IF NOT FOUND THEN RAISE EXCEPTION 'order reserved quantity cannot cover its exact claimed share' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_order_claim_row_projection AFTER INSERT ON sales_delivery_order_claim_row_events
 FOR EACH ROW EXECUTE FUNCTION fn_project_sales_delivery_order_claim_row();

CREATE FUNCTION fn_check_sales_delivery_order_claim_source(p_reservation uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE source stock_reservations%ROWTYPE; base numeric;distinct_bases integer;used numeric;active numeric;location record;
BEGIN
 SELECT * INTO STRICT source FROM stock_reservations WHERE id=p_reservation;
 SELECT COALESCE(sum(event.quantity*CASE WHEN event.event_type='CONSUME' THEN 1 ELSE -1 END),0)
  INTO used FROM sales_delivery_order_claim_events event JOIN sales_delivery_order_claims claim ON claim.id=event.claim_id
  WHERE claim.reservation_id=source.id AND event.event_type IN('CONSUME','REVERSE');
 SELECT COALESCE(sum(quantity),0) INTO active FROM v_sales_delivery_order_claim_active WHERE reservation_id=source.id;
 IF active>0 OR used>0 THEN
  SELECT min(claim.source_consumed_baseline),count(DISTINCT claim.source_consumed_baseline) INTO base,distinct_bases
   FROM sales_delivery_order_claims claim WHERE claim.reservation_id=source.id
     AND NOT EXISTS(SELECT 1 FROM sales_delivery_order_claim_events terminal WHERE terminal.claim_id=claim.id AND terminal.event_type IN('CANCEL','REVERSE'));
  IF distinct_bases<>1 OR source.consumed_qty<>base+used OR source.is_deleted
   OR source.owner_type<>'SALES_ORDER_ITEM' OR active>source.qty-source.consumed_qty-source.released_qty
   OR EXISTS(SELECT 1 FROM sales_delivery_order_claims claim WHERE claim.reservation_id=source.id
     AND NOT EXISTS(SELECT 1 FROM sales_delivery_order_claim_events terminal WHERE terminal.claim_id=claim.id AND terminal.event_type IN('CANCEL','REVERSE'))
     AND claim.source_identity IS DISTINCT FROM fn_sales_delivery_order_claim_identity(source)) THEN
   RAISE EXCEPTION 'original order reservation identity or consumed shares differ from claim ledger' USING ERRCODE='23514'; END IF;
  FOR location IN SELECT warehouse_id,sum(quantity) quantity FROM v_sales_delivery_order_claim_active WHERE reservation_id=source.id GROUP BY warehouse_id LOOP
   IF fn_stock_claim_open_at(source.id,location.warehouse_id)<location.quantity THEN
    RAISE EXCEPTION 'claimed order stock cannot be moved or released away from its actual warehouse' USING ERRCODE='23514'; END IF;
  END LOOP;
 END IF;
END $$;
CREATE FUNCTION fn_check_sales_delivery_order_claim() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE claim sales_delivery_order_claims%ROWTYPE; event sales_delivery_order_claim_events%ROWTYPE;
 component sales_shipment_delivery_components%ROWTYPE;movement stock_movements%ROWTYPE;used numeric;expected numeric;
BEGIN
 IF TG_TABLE_NAME='stock_reservations' THEN
  IF EXISTS(SELECT 1 FROM sales_delivery_order_claims WHERE reservation_id=NEW.id) THEN PERFORM fn_check_sales_delivery_order_claim_source(NEW.id); END IF; RETURN NULL;
 ELSIF TG_TABLE_NAME='stock_reservation_storage_positions' THEN
  IF EXISTS(SELECT 1 FROM sales_delivery_order_claims WHERE reservation_id=NEW.reservation_id) THEN PERFORM fn_check_sales_delivery_order_claim_source(NEW.reservation_id); END IF; RETURN NULL;
 ELSIF TG_TABLE_NAME='sales_delivery_order_claims' THEN
  PERFORM fn_check_sales_delivery_order_claim_source(NEW.reservation_id); RETURN NULL;
 ELSE
  SELECT * INTO STRICT claim FROM sales_delivery_order_claims WHERE id=NEW.claim_id;
  SELECT * INTO STRICT component FROM sales_shipment_delivery_components WHERE id=claim.component_id;
  PERFORM fn_check_sales_delivery_order_claim_source(claim.reservation_id);
  IF NEW.event_type='CANCEL' THEN
   IF component.movement_id IS NOT NULL OR component.processing_completed_qty>0 OR component.processing_started_at IS NOT NULL
     OR component.processing_issued_at IS NOT NULL THEN
    RAISE EXCEPTION 'processed order stock claim requires actual custody resolution before cancellation' USING ERRCODE='23514'; END IF; RETURN NULL;
  END IF;
  SELECT * INTO STRICT movement FROM stock_movements WHERE id=CASE WHEN NEW.event_type='CONSUME' THEN component.movement_id ELSE component.reversal_movement_id END;
  IF movement.source_doc_type<>'SALES_SHIPMENT' OR movement.source_doc_id<>claim.shipment_id
   OR movement.source_item_id<>component.id OR movement.goods_id<>claim.goods_id
   OR movement.color_id IS DISTINCT FROM claim.color_id OR movement.warehouse_id<>claim.warehouse_id
   OR movement.qty<>component.required_qty OR movement.direction<>(CASE WHEN NEW.event_type='CONSUME' THEN -1 ELSE 1 END) THEN
   RAISE EXCEPTION 'order claim consumption requires its exact actual component shipment movement' USING ERRCODE='23514'; END IF;
  SELECT COALESCE(sum(counter.quantity*CASE WHEN counter.event_type='CONSUME' THEN 1 ELSE -1 END),0)
   INTO used FROM sales_delivery_order_claim_events counter JOIN sales_delivery_order_claims owned ON owned.id=counter.claim_id
   WHERE owned.reservation_id=claim.reservation_id AND counter.event_type IN('CONSUME','REVERSE');
  SELECT consumed_qty INTO expected FROM stock_reservations WHERE id=claim.reservation_id;
  IF expected<>claim.source_consumed_baseline+used THEN
   RAISE EXCEPTION 'order claim source consumption or restoration is not exact' USING ERRCODE='23514'; END IF;
  IF NOT EXISTS(SELECT 1 FROM sales_delivery_order_claim_row_events row_event WHERE row_event.component_id=component.id AND row_event.event_type=NEW.event_type) THEN
   RAISE EXCEPTION 'order claim lacks its exact row-unit reserved quantity counterpart' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER sales_order_claim_source_quantity AFTER INSERT OR UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION fn_check_sales_delivery_order_claim();
CREATE CONSTRAINT TRIGGER sales_order_claim_storage_quantity AFTER INSERT OR UPDATE ON stock_reservation_storage_positions DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION fn_check_sales_delivery_order_claim();
CREATE CONSTRAINT TRIGGER sales_order_claim_quantity AFTER INSERT ON sales_delivery_order_claims DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION fn_check_sales_delivery_order_claim();
CREATE CONSTRAINT TRIGGER sales_order_claim_actual_movement AFTER INSERT ON sales_delivery_order_claim_events DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION fn_check_sales_delivery_order_claim();

CREATE FUNCTION fn_guard_active_order_claim_component() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF (NEW.shipment_id,NEW.shipment_item_id,NEW.order_item_id,NEW.goods_id,NEW.color_id,NEW.unit_id,NEW.required_qty,
     NEW.bom_path,NEW.bom_fingerprint,NEW.required_operations,NEW.warehouse_id)
   IS DISTINCT FROM
    (OLD.shipment_id,OLD.shipment_item_id,OLD.order_item_id,OLD.goods_id,OLD.color_id,OLD.unit_id,OLD.required_qty,
     OLD.bom_path,OLD.bom_fingerprint,OLD.required_operations,OLD.warehouse_id)
  AND EXISTS(SELECT 1 FROM sales_delivery_order_claims claim WHERE claim.component_id=OLD.id
    AND NOT EXISTS(SELECT 1 FROM sales_delivery_order_claim_events terminal WHERE terminal.claim_id=claim.id AND terminal.event_type IN('CANCEL','REVERSE'))) THEN
  RAISE EXCEPTION 'claimed original-order physical source is frozen until actual cancellation or reversal' USING ERRCODE='55000'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_order_claim_component_identity BEFORE UPDATE ON sales_shipment_delivery_components
 FOR EACH ROW EXECUTE FUNCTION fn_guard_active_order_claim_component();

CREATE FUNCTION fn_check_order_claim_row_and_request() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE expected numeric;component sales_shipment_delivery_components%ROWTYPE;actual stock_movements%ROWTYPE;
BEGIN
 IF TG_TABLE_NAME='sales_delivery_order_claim_requests' THEN
  SELECT COALESCE(sum(quantity),0) INTO expected FROM sales_delivery_order_claims WHERE request_id=NEW.request_id AND component_id=NEW.component_id;
  IF NEW.claimed_qty<>expected THEN RAISE EXCEPTION 'claim request result differs from its immutable exact slices' USING ERRCODE='23514'; END IF;
 ELSE
  SELECT * INTO STRICT component FROM sales_shipment_delivery_components WHERE id=NEW.component_id;
  SELECT COALESCE(sum(event.quantity),0) INTO expected FROM sales_delivery_order_claim_events event
   JOIN sales_delivery_order_claims claim ON claim.id=event.claim_id WHERE claim.component_id=component.id AND event.event_type=NEW.event_type;
  SELECT * INTO STRICT actual FROM stock_movements WHERE id=CASE WHEN NEW.event_type='CONSUME' THEN component.movement_id ELSE component.reversal_movement_id END;
  IF NEW.quantity_base<>expected OR NEW.order_item_id<>component.order_item_id OR actual.source_doc_id<>component.shipment_id
    OR actual.source_item_id<>component.id OR actual.source_doc_type<>'SALES_SHIPMENT'
    OR actual.direction<>(CASE WHEN NEW.event_type='CONSUME' THEN -1 ELSE 1 END) THEN
   RAISE EXCEPTION 'order-unit projection lacks the exact component shipment and claim counterpart' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER sales_order_claim_request_result AFTER INSERT ON sales_delivery_order_claim_requests DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION fn_check_order_claim_row_and_request();
CREATE CONSTRAINT TRIGGER sales_order_claim_row_actual AFTER INSERT ON sales_delivery_order_claim_row_events DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION fn_check_order_claim_row_and_request();

-- Keep the existing processing evidence gate and teach it about claims on the original order reservation.
DO $order_claim_custody$
DECLARE definition text;patched text;needle text;
BEGIN
 SELECT pg_get_functiondef('fn_guard_delivery_processing_evidence()'::regprocedure) INTO definition;
 needle:='SELECT COALESCE(sum(held.qty-held.consumed_qty-held.released_qty),0)=NEW.required_qty INTO custody';
 patched:=replace(definition,needle,'SELECT COALESCE(sum(held.qty-held.consumed_qty-held.released_qty),0)+fn_sales_delivery_order_claim_held(NEW.id,NEW.warehouse_id)=NEW.required_qty INTO custody');
 IF patched=definition THEN RAISE EXCEPTION 'Review processing custody calculation before adding original-order claims'; END IF;
 EXECUTE patched;
 SELECT pg_get_functiondef('fn_guard_sales_delivery_processing_reservation()'::regprocedure) INTO definition;
 needle:='IF other_open+NEW.qty-NEW.consumed_qty-NEW.released_qty>component.required_qty THEN';
 patched:=replace(definition,needle,'other_open:=other_open+fn_sales_delivery_order_claim_held(component.id,component.warehouse_id); '||needle);
 IF patched=definition THEN RAISE EXCEPTION 'Review processing remainder quota before adding original-order claims'; END IF;
 EXECUTE patched;
END $order_claim_custody$;

DO $order_claim_history$
DECLARE table_name text;
BEGIN
 FOREACH table_name IN ARRAY ARRAY['sales_delivery_order_claims','sales_delivery_order_claim_requests','sales_delivery_order_claim_events','sales_delivery_order_claim_row_events'] LOOP
  EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_delivery_processing_append_only()',table_name||'_immutable',table_name);
  PERFORM fn_audit_track_table(table_name,'FULL','data_change',false,NULL,true,NULL);
 END LOOP;
END $order_claim_history$;
