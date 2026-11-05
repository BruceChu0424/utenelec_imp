-- Commercial shipment rows retain order units and prices. Physical delivery rows own exact component stock.
CREATE TABLE sales_shipment_delivery_components (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 shipment_id uuid NOT NULL REFERENCES sales_shipments(id),
 shipment_item_id uuid NOT NULL REFERENCES sales_shipment_items(id),
 order_item_id uuid NOT NULL REFERENCES sales_order_items(id),
 bom_path jsonb NOT NULL CHECK(jsonb_typeof(bom_path)='array'),
 bom_fingerprint text NOT NULL,
 goods_id uuid NOT NULL REFERENCES goods(id),
 color_id uuid REFERENCES colors(id),
 unit_id uuid NOT NULL REFERENCES units(id),
 goods_code_snapshot text, goods_name_snapshot text, unit_name_snapshot text,
 required_qty numeric NOT NULL CHECK(required_qty>0),
 original_required_qty numeric NOT NULL CHECK(original_required_qty>0),
 adoption_scale integer CHECK(adoption_scale BETWEEN 0 AND 4),
 adoption_rounding text CHECK(adoption_rounding IN('HALF_UP','DOWN')),
 required_operations jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(required_operations)='array'),
 processing_targets jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(processing_targets)='array'),
 warehouse_id uuid REFERENCES warehouses(id), stock_place text,
 processing_completed_qty numeric NOT NULL DEFAULT 0 CHECK(processing_completed_qty>=0 AND processing_completed_qty<=required_qty),
 processing_evidence text, processing_completed_by uuid, processing_completed_at timestamptz,
 movement_id uuid REFERENCES stock_movements(id),
 reversal_movement_id uuid REFERENCES stock_movements(id),
 revision bigint NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(shipment_item_id,bom_path)
 ,CHECK(required_qty<100000000000000 AND required_qty=trunc(required_qty,4))
 ,CHECK((adoption_scale IS NULL AND adoption_rounding IS NULL AND required_qty=original_required_qty)
  OR (adoption_scale IS NOT NULL AND adoption_rounding IS NOT NULL AND required_qty=
   CASE WHEN adoption_rounding='HALF_UP' THEN round(original_required_qty,adoption_scale)
    ELSE trunc(original_required_qty,adoption_scale) END))
);
CREATE INDEX sales_delivery_components_document ON sales_shipment_delivery_components(shipment_id,shipment_item_id);
CREATE INDEX sales_delivery_components_processing ON sales_shipment_delivery_components(processing_completed_at)
 WHERE required_operations<>'[]'::jsonb AND movement_id IS NULL;

CREATE FUNCTION fn_guard_sales_delivery_component() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE parent sales_shipment_items%ROWTYPE; doc sales_shipments%ROWTYPE;
BEGIN
 IF TG_OP='DELETE' THEN
  SELECT * INTO doc FROM sales_shipments WHERE id=OLD.shipment_id;
  IF OLD.movement_id IS NOT NULL OR OLD.processing_completed_qty>0 OR doc.status<>0
   OR EXISTS(SELECT 1 FROM stock_reservations WHERE owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT') AND owner_id=OLD.id AND status=0 AND NOT is_deleted) THEN
   RAISE EXCEPTION 'physical delivery evidence cannot be removed' USING ERRCODE='55000'; END IF;
  RETURN OLD;
 END IF;
 SELECT * INTO parent FROM sales_shipment_items WHERE id=NEW.shipment_item_id;
 SELECT * INTO doc FROM sales_shipments WHERE id=NEW.shipment_id;
 IF NOT FOUND OR parent.shipment_id IS DISTINCT FROM NEW.shipment_id
  OR parent.order_item_id IS DISTINCT FROM NEW.order_item_id OR parent.is_deleted THEN
  RAISE EXCEPTION 'delivery component is not bound to its shipment source' USING ERRCODE='23514'; END IF;
 IF TG_OP='UPDATE' AND (OLD.movement_id IS NOT NULL OR OLD.processing_completed_qty>0
   OR EXISTS(SELECT 1 FROM stock_reservations WHERE owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT') AND owner_id=OLD.id AND status=0 AND NOT is_deleted)) AND
  (NEW.shipment_id,NEW.shipment_item_id,NEW.order_item_id,NEW.goods_id,NEW.color_id,NEW.unit_id,
   NEW.required_qty,NEW.original_required_qty,NEW.adoption_scale,NEW.adoption_rounding,NEW.bom_path,NEW.bom_fingerprint,NEW.required_operations,NEW.processing_targets)
  IS DISTINCT FROM
  (OLD.shipment_id,OLD.shipment_item_id,OLD.order_item_id,OLD.goods_id,OLD.color_id,OLD.unit_id,
   OLD.required_qty,OLD.original_required_qty,OLD.adoption_scale,OLD.adoption_rounding,OLD.bom_path,OLD.bom_fingerprint,OLD.required_operations,OLD.processing_targets) THEN
  RAISE EXCEPTION 'processed delivery source is immutable' USING ERRCODE='55000'; END IF;
 IF TG_OP='UPDATE' AND OLD.movement_id IS NOT NULL AND
  (to_jsonb(NEW)-'reversal_movement_id'-'updated_at') IS DISTINCT FROM (to_jsonb(OLD)-'reversal_movement_id'-'updated_at') THEN
  RAISE EXCEPTION 'shipped component evidence is immutable' USING ERRCODE='55000'; END IF;
 IF TG_OP='UPDATE' AND OLD.reversal_movement_id IS NOT NULL AND NEW.reversal_movement_id IS DISTINCT FROM OLD.reversal_movement_id THEN
  RAISE EXCEPTION 'component reversal evidence is immutable' USING ERRCODE='55000'; END IF;
 IF NEW.movement_id IS NOT NULL AND NEW.required_operations<>'[]'::jsonb
  AND (NEW.processing_completed_qty<>NEW.required_qty OR NEW.processing_completed_by IS NULL
   OR NEW.processing_completed_at IS NULL OR nullif(btrim(NEW.processing_evidence),'') IS NULL) THEN
  RAISE EXCEPTION 'required component processing is incomplete' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_component_guard BEFORE INSERT OR UPDATE OR DELETE ON sales_shipment_delivery_components
 FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_delivery_component();

CREATE FUNCTION fn_guard_sales_delivery_movement() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE component sales_shipment_delivery_components%ROWTYPE; document sales_shipments%ROWTYPE;
BEGIN
 IF NEW.source_doc_type IS DISTINCT FROM 'SALES_SHIPMENT' OR NEW.movement_type IS DISTINCT FROM 3 THEN RETURN NULL; END IF;
 SELECT * INTO component FROM sales_shipment_delivery_components WHERE id=NEW.source_item_id;
 IF FOUND THEN
  SELECT * INTO document FROM sales_shipments WHERE id=component.shipment_id;
  IF NEW.source_doc_id IS DISTINCT FROM component.shipment_id OR NEW.goods_id IS DISTINCT FROM component.goods_id
   OR NEW.color_id IS DISTINCT FROM component.color_id OR NEW.warehouse_id IS DISTINCT FROM component.warehouse_id
   OR NEW.qty<>component.required_qty OR (CASE WHEN NEW.direction=-1 THEN component.movement_id ELSE component.reversal_movement_id END) IS DISTINCT FROM NEW.id
   OR document.handed_over_at IS NULL OR document.handed_over_by IS NULL THEN
   RAISE EXCEPTION 'component movement differs from frozen delivery evidence' USING ERRCODE='23514'; END IF;
  IF component.required_operations<>'[]'::jsonb AND component.processing_completed_qty<>component.required_qty THEN
   RAISE EXCEPTION 'component processing is not complete' USING ERRCODE='23514'; END IF;
 ELSE
  IF EXISTS(SELECT 1 FROM sales_shipment_items item JOIN sales_order_items sale ON sale.id=item.order_item_id
    WHERE item.id=NEW.source_item_id AND (sale.delivery_plan->>'mode'='BOM'
      OR jsonb_array_length(COALESCE(sale.delivery_plan->'processes','[]'::jsonb))>0)) THEN
   RAISE EXCEPTION 'BOM delivery cannot post a finished-product shipment movement' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER sales_delivery_movement_guard AFTER INSERT ON stock_movements
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_delivery_movement();

CREATE TABLE sales_delivery_processing_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), component_id uuid NOT NULL REFERENCES sales_shipment_delivery_components(id),
 request_id uuid NOT NULL UNIQUE, quantity numeric NOT NULL CHECK(quantity>0),
 operation text NOT NULL CHECK(operation='LASER'), evidence text NOT NULL CHECK(length(btrim(evidence))>0),
 actor_employee_id uuid NOT NULL, occurred_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sales_shipment_delivery_components IS '逐订单BOM路径的冻结实物出货清单；商业套数/金额仍仅在原出货行记一次';

CREATE FUNCTION fn_guard_processing_delivery_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source_id uuid;
BEGIN
 IF TG_TABLE_NAME='sales_shipments' THEN
  source_id:=OLD.id;
  IF (NEW.review_revision,NEW.is_deleted,NEW.rejected,NEW.finance_audit,NEW.sales_confirmed_revision)
    IS NOT DISTINCT FROM (OLD.review_revision,OLD.is_deleted,OLD.rejected,OLD.finance_audit,OLD.sales_confirmed_revision) THEN RETURN NEW; END IF;
 ELSE
  source_id:=OLD.shipment_id;
  IF (NEW.goods_id,NEW.color_id,NEW.unit_id,NEW.unit_rate,NEW.qty,NEW.order_item_id,NEW.is_deleted)
    IS NOT DISTINCT FROM (OLD.goods_id,OLD.color_id,OLD.unit_id,OLD.unit_rate,OLD.qty,OLD.order_item_id,OLD.is_deleted) THEN RETURN NEW; END IF;
 END IF;
 IF EXISTS(SELECT 1 FROM sales_shipment_delivery_components c WHERE c.shipment_id=source_id
    AND (c.processing_completed_qty>0 OR EXISTS(SELECT 1 FROM stock_reservations r WHERE r.owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')
       AND r.owner_id=c.id AND r.status=0 AND NOT r.is_deleted))) THEN
  RAISE EXCEPTION 'processing or processed delivery source requires controlled custody resolution before revision' USING ERRCODE='55000'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER processing_delivery_header_guard BEFORE UPDATE ON sales_shipments
 FOR EACH ROW EXECUTE FUNCTION fn_guard_processing_delivery_source();
CREATE TRIGGER processing_delivery_item_guard BEFORE UPDATE ON sales_shipment_items
 FOR EACH ROW EXECUTE FUNCTION fn_guard_processing_delivery_source();

-- Preserve all existing ownership families. The new processing holder is not a sales root reservation.
DO $delivery_processing_owner$
DECLARE constraint_name text; definition text; extra text;
BEGIN
 FOREACH constraint_name IN ARRAY ARRAY['stock_reservations_owner_type_chk','stock_reservations_purpose_chk','stock_reservations_owner_shape_chk'] LOOP
  SELECT pg_get_expr(conbin,conrelid) INTO definition FROM pg_constraint
   WHERE conrelid='stock_reservations'::regclass AND conname=constraint_name;
  IF definition IS NULL THEN RAISE EXCEPTION 'Reservation owner contract missing: %',constraint_name; END IF;
  extra:=CASE constraint_name
   WHEN 'stock_reservations_owner_type_chk' THEN 'owner_type IN (''SALES_DELIVERY_PROCESSING'',''SALES_DELIVERY_COMPONENT_SHIPMENT'')'
   WHEN 'stock_reservations_purpose_chk' THEN 'purpose IN (''SALES_DELIVERY_PROCESSING'',''SALES_DELIVERY_COMPONENT_SHIPMENT'')'
   ELSE 'owner_type IN (''SALES_DELIVERY_PROCESSING'',''SALES_DELIVERY_COMPONENT_SHIPMENT'') AND purpose=owner_type
     AND owner_id IS NOT NULL AND order_item_id IS NULL AND demand_id IS NULL AND warehouse_id IS NOT NULL
     AND supply_type=''STOCK_BALANCE'' AND supply_id IS NOT NULL
     AND source=0 AND source_doc_type=''SALES_SHIPMENT'' AND source_doc_id IS NOT NULL AND idempotency_key IS NOT NULL
     AND ((status=0 AND consumed_qty=0 AND released_qty=0 AND NOT is_deleted)
       OR (status=1 AND consumed_qty+released_qty=qty AND (consumed_qty=0 OR released_qty=0)))' END;
  EXECUTE format('ALTER TABLE stock_reservations DROP CONSTRAINT %I, ADD CONSTRAINT %I CHECK ((%s) OR (%s))',
    constraint_name,constraint_name,definition,extra);
 END LOOP;
END $delivery_processing_owner$;

CREATE UNIQUE INDEX stock_delivery_processing_one_active ON stock_reservations(owner_id)
 WHERE owner_type='SALES_DELIVERY_PROCESSING' AND status=0 AND NOT is_deleted;

-- Private entitlement slices may precede one public processing remainder. Their sum never exceeds the
-- explicitly adopted frozen quantity; V1054 ties every private slice to its original release event.
-- Release/consume retain the same source identity; ordinary owner types keep their existing contracts.
CREATE FUNCTION fn_guard_sales_delivery_processing_reservation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE component sales_shipment_delivery_components%ROWTYPE; other_open numeric;
BEGIN
 IF TG_OP='UPDATE' AND (OLD.owner_type IN ('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')
    OR NEW.owner_type IN ('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')) AND
   (NEW.owner_type,NEW.owner_id,NEW.purpose,NEW.goods_id,NEW.color_id,NEW.warehouse_id,
    NEW.qty,NEW.source,NEW.supply_type,NEW.supply_id,NEW.source_doc_type,NEW.source_doc_id,NEW.idempotency_key)
   IS DISTINCT FROM
   (OLD.owner_type,OLD.owner_id,OLD.purpose,OLD.goods_id,OLD.color_id,OLD.warehouse_id,
    OLD.qty,OLD.source,OLD.supply_type,OLD.supply_id,OLD.source_doc_type,OLD.source_doc_id,OLD.idempotency_key) THEN
  RAISE EXCEPTION 'delivery processing reservation source is immutable' USING ERRCODE='55000';
 END IF;
 -- Existing reservation INSERTs may be normalized by a later BEFORE trigger.
 -- NULL is outside this new family too; never intercept ordinary/root-supply owners.
 IF NEW.owner_type IS NULL OR NEW.owner_type NOT IN ('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT') THEN RETURN NEW; END IF;
 IF TG_OP='UPDATE' AND (NEW.consumed_qty<OLD.consumed_qty OR NEW.released_qty<OLD.released_qty) THEN
  RAISE EXCEPTION 'delivery processing reservation cannot replay released or consumed quantities' USING ERRCODE='55000';
 END IF;
 SELECT * INTO component FROM sales_shipment_delivery_components WHERE id=NEW.owner_id FOR UPDATE;
 IF NOT FOUND OR NEW.purpose IS DISTINCT FROM NEW.owner_type
   OR NEW.goods_id IS DISTINCT FROM component.goods_id OR NEW.color_id IS DISTINCT FROM component.color_id
   OR NEW.warehouse_id IS DISTINCT FROM component.warehouse_id OR NEW.source_doc_id IS DISTINCT FROM component.shipment_id
   OR NEW.source IS DISTINCT FROM 0 OR NEW.source_doc_type IS DISTINCT FROM 'SALES_SHIPMENT' OR NEW.qty>component.required_qty
   OR NEW.supply_type IS DISTINCT FROM 'STOCK_BALANCE'
   OR NOT EXISTS(SELECT 1 FROM stock_balances balance
     WHERE balance.id=NEW.supply_id AND balance.warehouse_id=NEW.warehouse_id
       AND balance.goods_id=NEW.goods_id AND balance.color_id IS NOT DISTINCT FROM NEW.color_id)
   OR (NEW.status=0 AND NOT EXISTS(SELECT 1 FROM v_stock_operable_balances balance WHERE balance.id=NEW.supply_id))
   OR (NEW.status=0 AND component.movement_id IS NOT NULL) THEN
  RAISE EXCEPTION 'delivery processing reservation differs from exact component source' USING ERRCODE='23514';
 END IF;
 IF NEW.status=0 AND NOT NEW.is_deleted THEN
  SELECT COALESCE(sum(qty-consumed_qty-released_qty),0) INTO other_open FROM stock_reservations held
   WHERE held.owner_type IN ('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')
     AND held.owner_id=NEW.owner_id AND held.id<>NEW.id AND held.status=0 AND NOT held.is_deleted;
  IF other_open+NEW.qty-NEW.consumed_qty-NEW.released_qty>component.required_qty THEN
   RAISE EXCEPTION 'combined delivery entitlements exceed the frozen component quantity' USING ERRCODE='23514';
  END IF;
  IF NEW.owner_type='SALES_DELIVERY_PROCESSING' AND other_open+NEW.qty<>component.required_qty THEN
   RAISE EXCEPTION 'public processing hold must exactly fill the unclaimed component remainder' USING ERRCODE='23514';
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_processing_reservation_guard BEFORE INSERT OR UPDATE ON stock_reservations
 FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_delivery_processing_reservation();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER sales_delivery_processing_reservation_guard;

SELECT fn_audit_track_table('sales_shipment_delivery_components','COLUMN_SCOPED','data_change',false,
 ARRAY['id','shipment_id','shipment_item_id','order_item_id','bom_path','bom_fingerprint','goods_id','color_id','unit_id',
   'required_qty','required_operations','warehouse_id','stock_place','processing_completed_qty','processing_completed_by',
   'processing_completed_at','movement_id','reversal_movement_id','revision'],true,NULL);
SELECT fn_audit_track_table('sales_delivery_processing_events','COLUMN_SCOPED','data_change',false,
 ARRAY['id','component_id','request_id','quantity','operation','actor_employee_id','occurred_at'],true,NULL);
