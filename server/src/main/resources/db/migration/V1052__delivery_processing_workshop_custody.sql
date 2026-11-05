ALTER TABLE sales_shipment_delivery_components
    ADD COLUMN processing_workshop_id uuid REFERENCES departments(id),
    ADD COLUMN processing_responsible_id uuid REFERENCES employees(id),
    ADD COLUMN processing_started_at timestamptz,
    ADD COLUMN processing_started_by uuid REFERENCES employees(id);

CREATE TABLE sales_delivery_processing_actions (
    request_id uuid PRIMARY KEY,
    component_id uuid NOT NULL REFERENCES sales_shipment_delivery_components(id),
    action_type text NOT NULL CHECK(action_type IN ('ASSIGN','START','REPORT','CANCEL_START')),
    request_hash text NOT NULL,
    actor_employee_id uuid NOT NULL REFERENCES employees(id),
    resulting_version bigint NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION fn_guard_delivery_processing_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE total numeric; custody boolean;
BEGIN
 IF TG_OP='UPDATE' AND OLD.processing_started_at IS NOT NULL AND
    (NEW.processing_workshop_id,NEW.processing_responsible_id,NEW.goods_id,NEW.color_id,NEW.unit_id,
     NEW.required_qty,NEW.required_operations,NEW.bom_path,NEW.bom_fingerprint,NEW.warehouse_id)
     IS DISTINCT FROM
    (OLD.processing_workshop_id,OLD.processing_responsible_id,OLD.goods_id,OLD.color_id,OLD.unit_id,
     OLD.required_qty,OLD.required_operations,OLD.bom_path,OLD.bom_fingerprint,OLD.warehouse_id) THEN
   RAISE EXCEPTION 'processing source and assignment are frozen after start' USING ERRCODE='55000';
 END IF;
 IF NEW.processing_completed_qty IS DISTINCT FROM OLD.processing_completed_qty THEN
   SELECT COALESCE(sum(quantity),0) INTO total FROM sales_delivery_processing_events
       WHERE component_id=NEW.id AND operation='LASER';
   SELECT COALESCE(sum(held.qty-held.consumed_qty-held.released_qty),0)=NEW.required_qty INTO custody
       FROM stock_reservations held
       WHERE held.owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT') AND held.owner_id=NEW.id
         AND held.goods_id=NEW.goods_id AND held.color_id IS NOT DISTINCT FROM NEW.color_id
         AND held.warehouse_id=NEW.warehouse_id AND held.status=0 AND NOT held.is_deleted;
   IF NEW.processing_started_at IS NULL OR NEW.processing_started_by IS NULL
      OR NEW.processing_workshop_id IS NULL OR NOT custody
      OR NEW.processing_completed_qty<>total OR NEW.processing_completed_qty<OLD.processing_completed_qty
      OR NOT(NEW.required_operations @> '["LASER"]'::jsonb) THEN
      RAISE EXCEPTION 'processing completion requires exact task events and physical custody' USING ERRCODE='23514';
   END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_processing_evidence BEFORE UPDATE ON sales_shipment_delivery_components
    FOR EACH ROW EXECUTE FUNCTION fn_guard_delivery_processing_evidence();

CREATE FUNCTION fn_delivery_processing_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION 'processing evidence is append-only' USING ERRCODE='55000';
END $$;
CREATE TRIGGER sales_delivery_processing_events_immutable BEFORE UPDATE OR DELETE ON sales_delivery_processing_events
    FOR EACH ROW EXECUTE FUNCTION fn_delivery_processing_append_only();
CREATE TRIGGER sales_delivery_processing_actions_immutable BEFORE UPDATE OR DELETE ON sales_delivery_processing_actions
    FOR EACH ROW EXECUTE FUNCTION fn_delivery_processing_append_only();

SELECT fn_audit_track_table('sales_delivery_processing_actions','COLUMN_SCOPED','data_change',false,
 ARRAY['request_id','component_id','action_type','request_hash','actor_employee_id','resulting_version','occurred_at'],true,NULL);
