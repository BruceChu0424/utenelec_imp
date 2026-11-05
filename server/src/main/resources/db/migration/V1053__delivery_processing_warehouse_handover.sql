ALTER TABLE sales_shipment_delivery_components
 ADD COLUMN processing_issued_at timestamptz, ADD COLUMN processing_issued_by uuid REFERENCES employees(id),
 ADD COLUMN processing_received_at timestamptz, ADD COLUMN processing_received_by uuid REFERENCES employees(id);

CREATE TABLE sales_delivery_warehouse_actions (
 request_id uuid PRIMARY KEY,shipment_id uuid NOT NULL REFERENCES sales_shipments(id),
 component_id uuid NOT NULL REFERENCES sales_shipment_delivery_components(id),
 action_type text NOT NULL CHECK(action_type IN('ISSUE','RECEIVE','CANCEL_ISSUE')),
 workshop_id uuid NOT NULL REFERENCES departments(id),responsible_id uuid REFERENCES employees(id),
 request_hash text NOT NULL,evidence text NOT NULL CHECK(length(btrim(evidence))>0),
 actor_employee_id uuid NOT NULL REFERENCES employees(id),occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER sales_delivery_warehouse_actions_immutable BEFORE UPDATE OR DELETE ON sales_delivery_warehouse_actions
 FOR EACH ROW EXECUTE FUNCTION fn_delivery_processing_append_only();
SELECT fn_audit_track_table('sales_delivery_warehouse_actions','COLUMN_SCOPED','data_change',false,
 ARRAY['request_id','shipment_id','component_id','action_type','workshop_id','responsible_id','request_hash','actor_employee_id','occurred_at'],true,NULL);

CREATE FUNCTION fn_guard_delivery_warehouse_assignment_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM sales_shipment_delivery_components component WHERE component.id=NEW.component_id
   AND component.shipment_id=NEW.shipment_id AND component.processing_workshop_id=NEW.workshop_id
   AND component.processing_responsible_id IS NOT DISTINCT FROM NEW.responsible_id) THEN
  RAISE EXCEPTION 'warehouse handover requires its exact workshop and responsible assignment snapshot' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_warehouse_assignment_snapshot BEFORE INSERT ON sales_delivery_warehouse_actions
 FOR EACH ROW EXECUTE FUNCTION fn_guard_delivery_warehouse_assignment_snapshot();

CREATE FUNCTION fn_guard_delivery_processing_handover() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.processing_issued_at IS NOT NULL AND
   (NEW.processing_workshop_id,NEW.processing_responsible_id)
    IS DISTINCT FROM (OLD.processing_workshop_id,OLD.processing_responsible_id) THEN
  RAISE EXCEPTION 'issued physical processing custody cannot change workshop or responsible employee' USING ERRCODE='55000';
 END IF;
 IF NEW.processing_started_at IS NOT NULL AND NEW.processing_issued_at IS NULL THEN
  RAISE EXCEPTION 'workshop processing requires a warehouse physical handover' USING ERRCODE='23514'; END IF;
 IF NEW.processing_received_at IS NOT NULL AND (NEW.processing_completed_qty<>NEW.required_qty
  OR NEW.processing_received_by IS NULL OR NEW.processing_issued_at IS NULL) THEN
  RAISE EXCEPTION 'processing receipt requires completed actual work and a warehouse receiver' USING ERRCODE='23514'; END IF;
 IF NEW.movement_id IS NOT NULL AND NEW.required_operations<>'[]'::jsonb AND NEW.processing_received_at IS NULL THEN
  RAISE EXCEPTION 'processed physical components must be returned to warehouse before shipment' USING ERRCODE='23514'; END IF;
 IF TG_OP='UPDATE' AND OLD.processing_received_at IS NOT NULL AND
  (NEW.processing_issued_at,NEW.processing_issued_by,NEW.processing_received_at,NEW.processing_received_by)
   IS DISTINCT FROM (OLD.processing_issued_at,OLD.processing_issued_by,OLD.processing_received_at,OLD.processing_received_by) THEN
  RAISE EXCEPTION 'completed warehouse processing handover evidence is immutable' USING ERRCODE='55000'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_processing_handover BEFORE INSERT OR UPDATE ON sales_shipment_delivery_components
 FOR EACH ROW EXECUTE FUNCTION fn_guard_delivery_processing_handover();

-- Cancelling an unprocessed handover restores custody, not the identity of the old task.
CREATE FUNCTION fn_guard_delivery_work_source_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM sales_delivery_processing_actions WHERE component_id=OLD.id)
   AND NOT EXISTS(SELECT 1 FROM sales_delivery_warehouse_actions WHERE component_id=OLD.id) THEN
  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
 END IF;
 IF TG_OP='DELETE' THEN
  RAISE EXCEPTION 'delivery work history must be retained with its cancelled draft' USING ERRCODE='55000';
 END IF;
 IF (NEW.shipment_id,NEW.shipment_item_id,NEW.order_item_id,NEW.goods_id,NEW.color_id,NEW.unit_id,
   NEW.required_qty,NEW.original_required_qty,NEW.adoption_scale,NEW.adoption_rounding,
   NEW.bom_path,NEW.bom_fingerprint,NEW.required_operations,NEW.processing_targets)
  IS DISTINCT FROM (OLD.shipment_id,OLD.shipment_item_id,OLD.order_item_id,OLD.goods_id,OLD.color_id,OLD.unit_id,
   OLD.required_qty,OLD.original_required_qty,OLD.adoption_scale,OLD.adoption_rounding,
   OLD.bom_path,OLD.bom_fingerprint,OLD.required_operations,OLD.processing_targets) THEN
  RAISE EXCEPTION 'delivery work source history is immutable; cancel the old draft and create a new one' USING ERRCODE='55000';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_work_source_history BEFORE UPDATE OR DELETE ON sales_shipment_delivery_components
 FOR EACH ROW EXECUTE FUNCTION fn_guard_delivery_work_source_history();

-- Original-order subclaims can hold all physical stock without a new reservation row.
DO $handover_source_guard$
DECLARE definition text;patched text;
BEGIN
 SELECT pg_get_functiondef('fn_guard_processing_delivery_source()'::regprocedure) INTO definition;
 patched:=replace(definition,'AND (c.processing_completed_qty>0 OR EXISTS',
  'AND (c.processing_issued_at IS NOT NULL OR c.processing_started_at IS NOT NULL OR c.processing_completed_qty>0 OR EXISTS');
 IF patched=definition THEN RAISE EXCEPTION 'Review delivery source custody guard before extending warehouse handover'; END IF;
 EXECUTE patched;
END $handover_source_guard$;
