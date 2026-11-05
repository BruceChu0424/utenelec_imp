CREATE TABLE sales_delivery_fulfillment_groups (
    id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    shipment_item_id uuid PRIMARY KEY REFERENCES sales_shipment_items(id),
    shipment_id uuid NOT NULL REFERENCES sales_shipments(id),
    order_item_id uuid NOT NULL REFERENCES sales_order_items(id),
    order_qty numeric NOT NULL CHECK(order_qty>0),
    state text NOT NULL CHECK(state IN('PREPARED','COMPLETED','CANCELLED','REVERSED')),
    created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE sales_delivery_fulfillment_allocations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_item_id uuid NOT NULL REFERENCES sales_delivery_fulfillment_groups(shipment_item_id),
    analysis_id uuid NOT NULL REFERENCES production_material_analyses(id),
    analysis_item_id uuid NOT NULL REFERENCES production_material_analysis_items(id),
    position integer NOT NULL CHECK(position>=0),
    order_qty numeric NOT NULL CHECK(order_qty>0),
    created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(shipment_item_id,analysis_item_id),UNIQUE(shipment_item_id,position)
);
CREATE INDEX sales_delivery_fulfillment_source ON sales_delivery_fulfillment_allocations(analysis_item_id,shipment_item_id);
CREATE TABLE sales_delivery_entitlement_handoffs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    component_id uuid NOT NULL REFERENCES sales_shipment_delivery_components(id),
    allocation_id uuid NOT NULL REFERENCES sales_delivery_fulfillment_allocations(id),
    source_analysis_id uuid NOT NULL REFERENCES production_material_analyses(id),
    source_material_id uuid NOT NULL REFERENCES production_material_analysis_materials(id),
    entitlement_analysis_id uuid NOT NULL REFERENCES production_material_analyses(id),
    entitlement_material_id uuid NOT NULL REFERENCES production_material_analysis_materials(id),
    aggregate_alias_id uuid REFERENCES preplan_aggregate_material_aliases(id),
    source_entitlement_event_id uuid NOT NULL REFERENCES preplan_stock_entitlement_events(id),
    source_reservation_id uuid NOT NULL REFERENCES stock_reservations(id),
    target_reservation_id uuid NOT NULL UNIQUE REFERENCES stock_reservations(id),
    release_event_id uuid NOT NULL UNIQUE REFERENCES preplan_stock_entitlement_events(id),
    quantity numeric NOT NULL CHECK(quantity>0),
    created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sales_delivery_entitlement_component ON sales_delivery_entitlement_handoffs(component_id);
CREATE INDEX sales_delivery_entitlement_source ON sales_delivery_entitlement_handoffs(source_reservation_id);
CREATE TABLE sales_delivery_entitlement_restores (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),handoff_id uuid NOT NULL UNIQUE REFERENCES sales_delivery_entitlement_handoffs(id),
    restore_event_id uuid NOT NULL UNIQUE REFERENCES preplan_stock_entitlement_events(id),
    reason text NOT NULL CHECK(reason IN('CANCEL_ISSUE','REVERSE')),
    created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE sales_delivery_fulfillment_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),allocation_id uuid NOT NULL REFERENCES sales_delivery_fulfillment_allocations(id),
    event_type text NOT NULL CHECK(event_type IN('FULFILL','REVERSE')),order_qty numeric NOT NULL CHECK(order_qty>0),
    counter_event_id uuid UNIQUE REFERENCES sales_delivery_fulfillment_events(id),
    created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(allocation_id,event_type),CHECK((event_type='REVERSE')=(counter_event_id IS NOT NULL))
);

CREATE FUNCTION fn_guard_sales_delivery_private_handoff() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(
   SELECT 1 FROM sales_shipment_delivery_components component
   JOIN sales_delivery_fulfillment_allocations allocation ON allocation.id=NEW.allocation_id
   JOIN sales_delivery_fulfillment_groups kit ON kit.shipment_item_id=allocation.shipment_item_id
       AND kit.shipment_item_id=component.shipment_item_id AND kit.order_item_id=component.order_item_id AND kit.state='PREPARED'
   JOIN production_material_analysis_items source ON source.id=allocation.analysis_item_id
       AND source.analysis_id=allocation.analysis_id AND source.sales_order_item_id=component.order_item_id
       AND source.delivery_plan_snapshot->>'mode'='BOM'
       AND source.delivery_plan_snapshot->>'bomFingerprint'=component.bom_fingerprint
   JOIN production_material_analysis_materials material ON material.id=NEW.source_material_id
       AND material.analysis_id=allocation.analysis_id AND material.analysis_item_id=source.id AND material.delivery_frontier
       AND NOT material.delivery_context AND material.goods_id=component.goods_id
       AND material.color_id IS NOT DISTINCT FROM component.color_id AND material.unit_id=component.unit_id
       AND material.node_key=(SELECT string_agg(path.value,'/' ORDER BY path.position)
          FROM jsonb_array_elements_text(component.bom_path) WITH ORDINALITY path(value,position))
   JOIN preplan_stock_entitlement_events origin ON origin.id=NEW.source_entitlement_event_id
       AND origin.beneficiary_analysis_id=NEW.entitlement_analysis_id AND origin.beneficiary_analysis_material_id=NEW.entitlement_material_id
       AND origin.stock_reservation_id=NEW.source_reservation_id
   JOIN preplan_stock_entitlement_events released ON released.id=NEW.release_event_id AND released.event_type='RELEASE'
       AND released.source_entitlement_event_id=origin.id AND released.qty=NEW.quantity
   JOIN stock_reservations physical ON physical.id=NEW.source_reservation_id AND physical.owner_type='PREPLAN_ANALYSIS'
       AND physical.goods_id=component.goods_id AND physical.color_id IS NOT DISTINCT FROM component.color_id
   JOIN stock_reservations target ON target.id=NEW.target_reservation_id
       AND target.owner_type='SALES_DELIVERY_COMPONENT_SHIPMENT' AND target.owner_id=component.id
       AND target.goods_id=component.goods_id AND target.color_id IS NOT DISTINCT FROM component.color_id
       AND target.warehouse_id=physical.warehouse_id AND target.qty=NEW.quantity
   WHERE component.id=NEW.component_id AND material.analysis_id=NEW.source_analysis_id AND
      ((NEW.aggregate_alias_id IS NULL AND NEW.entitlement_analysis_id=material.analysis_id AND NEW.entitlement_material_id=material.id)
       OR EXISTS(SELECT 1 FROM preplan_aggregate_material_aliases alias
           JOIN production_material_analysis_materials canonical ON canonical.id=alias.aggregate_material_id
           WHERE alias.id=NEW.aggregate_alias_id AND alias.source_material_id=material.id
             AND canonical.id=NEW.entitlement_material_id AND canonical.analysis_id=NEW.entitlement_analysis_id
             AND (canonical.goods_id,canonical.color_id,canonical.unit_id) IS NOT DISTINCT FROM (material.goods_id,material.color_id,material.unit_id)
             AND fn_preplan_aggregate_alias_valid(alias.id)
             AND NEW.quantity+COALESCE((SELECT sum(prior.quantity) FROM sales_delivery_entitlement_handoffs prior
               WHERE prior.aggregate_alias_id=alias.id AND NOT EXISTS(SELECT 1 FROM sales_delivery_entitlement_restores restored WHERE restored.handoff_id=prior.id)),0)
               <=fn_preplan_aggregate_alias_qty(alias.id)))
 ) THEN RAISE EXCEPTION 'delivery private stock handoff must retain exact order path and qualified lot' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_private_handoff_guard BEFORE INSERT ON sales_delivery_entitlement_handoffs
    FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_delivery_private_handoff();

CREATE FUNCTION fn_guard_sales_delivery_entitlement_restore() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM sales_delivery_entitlement_handoffs handoff
   JOIN preplan_stock_entitlement_events restored ON restored.id=NEW.restore_event_id
       AND restored.event_type='RESTORE' AND restored.counter_event_id=handoff.release_event_id
       AND restored.qty=handoff.quantity AND restored.stock_reservation_id=handoff.source_reservation_id
       AND restored.beneficiary_analysis_id=handoff.entitlement_analysis_id
       AND restored.beneficiary_analysis_material_id=handoff.entitlement_material_id
   JOIN sales_shipment_delivery_components component ON component.id=handoff.component_id
   JOIN stock_reservations target ON target.id=handoff.target_reservation_id
   WHERE handoff.id=NEW.handoff_id AND
       ((NEW.reason='CANCEL_ISSUE' AND component.movement_id IS NULL AND component.processing_completed_qty=0
          AND target.released_qty=target.qty AND target.consumed_qty=0)
        OR (NEW.reason='REVERSE' AND component.reversal_movement_id IS NOT NULL))) THEN
   RAISE EXCEPTION 'delivery private stock restore requires exact returned or reversed custody' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_entitlement_restore_guard BEFORE INSERT ON sales_delivery_entitlement_restores
    FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_delivery_entitlement_restore();

CREATE TRIGGER sales_delivery_fulfillment_allocations_immutable BEFORE UPDATE OR DELETE ON sales_delivery_fulfillment_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_delivery_processing_append_only();
CREATE TRIGGER sales_delivery_entitlement_handoffs_immutable BEFORE UPDATE OR DELETE ON sales_delivery_entitlement_handoffs
    FOR EACH ROW EXECUTE FUNCTION fn_delivery_processing_append_only();
CREATE TRIGGER sales_delivery_entitlement_restores_immutable BEFORE UPDATE OR DELETE ON sales_delivery_entitlement_restores
    FOR EACH ROW EXECUTE FUNCTION fn_delivery_processing_append_only();
CREATE TRIGGER sales_delivery_fulfillment_events_immutable BEFORE UPDATE OR DELETE ON sales_delivery_fulfillment_events
    FOR EACH ROW EXECUTE FUNCTION fn_delivery_processing_append_only();

CREATE FUNCTION fn_check_sales_delivery_private_reservation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE held stock_reservations%ROWTYPE;
BEGIN
 SELECT * INTO held FROM stock_reservations WHERE id=NEW.id;
 IF held.owner_type<>'SALES_DELIVERY_COMPONENT_SHIPMENT' THEN RETURN NULL; END IF;
 IF NOT EXISTS(SELECT 1 FROM sales_delivery_entitlement_handoffs handoff
   JOIN sales_shipment_delivery_components component ON component.id=handoff.component_id
   WHERE handoff.target_reservation_id=held.id AND handoff.quantity=held.qty AND held.owner_id=component.id
     AND held.source_doc_type='SALES_SHIPMENT' AND held.source_doc_id=component.shipment_id
     AND held.goods_id=component.goods_id AND held.color_id IS NOT DISTINCT FROM component.color_id) THEN
   RAISE EXCEPTION 'private delivery reservation requires its exact source handoff' USING ERRCODE='23514';
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER sales_delivery_private_reservation_evidence AFTER INSERT OR UPDATE ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.owner_type='SALES_DELIVERY_COMPONENT_SHIPMENT')
    EXECUTE FUNCTION fn_check_sales_delivery_private_reservation();

CREATE FUNCTION fn_guard_sales_delivery_fulfillment_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE allocation sales_delivery_fulfillment_allocations%ROWTYPE; kit sales_delivery_fulfillment_groups%ROWTYPE;
        source production_material_analysis_items%ROWTYPE; original sales_delivery_fulfillment_events%ROWTYPE;
BEGIN
 SELECT * INTO allocation FROM sales_delivery_fulfillment_allocations WHERE id=NEW.allocation_id;
 SELECT * INTO kit FROM sales_delivery_fulfillment_groups WHERE shipment_item_id=allocation.shipment_item_id;
 SELECT * INTO source FROM production_material_analysis_items WHERE id=allocation.analysis_item_id;
 IF allocation.id IS NULL OR source.delivery_plan_snapshot->>'mode' IS DISTINCT FROM 'BOM'
    OR source.sales_order_item_id IS DISTINCT FROM kit.order_item_id OR NEW.order_qty<>allocation.order_qty THEN
   RAISE EXCEPTION 'delivery kit fulfillment source mismatch' USING ERRCODE='23514'; END IF;
 IF NEW.event_type='FULFILL' THEN
   IF kit.state<>'PREPARED' OR NEW.counter_event_id IS NOT NULL OR
      NOT EXISTS(SELECT 1 FROM sales_shipment_delivery_components component WHERE component.shipment_item_id=kit.shipment_item_id)
      OR EXISTS(SELECT 1 FROM sales_shipment_delivery_components component WHERE component.shipment_item_id=kit.shipment_item_id
           AND (component.movement_id IS NULL OR component.reversal_movement_id IS NOT NULL))
      OR source.root_fulfilled_qty+NEW.order_qty+source.submitted_qty+source.approved_qty>source.requested_qty THEN
     RAISE EXCEPTION 'delivery kit requires all physical component movements and source capacity' USING ERRCODE='23514'; END IF;
 ELSE
   SELECT * INTO original FROM sales_delivery_fulfillment_events WHERE id=NEW.counter_event_id;
   IF original.event_type<>'FULFILL' OR original.allocation_id<>NEW.allocation_id OR original.order_qty<>NEW.order_qty
      OR EXISTS(SELECT 1 FROM sales_shipment_delivery_components component WHERE component.shipment_item_id=kit.shipment_item_id
         AND component.reversal_movement_id IS NULL) THEN
     RAISE EXCEPTION 'delivery kit reversal must reverse every original component' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_fulfillment_event_guard BEFORE INSERT ON sales_delivery_fulfillment_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_delivery_fulfillment_event();

-- Preserve the established root-conservation entry point, adding real BOM-kit evidence
-- rather than inventing a finished-product output event or movement.
CREATE OR REPLACE FUNCTION fn_root_fulfilled_source_qty(item_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT LEAST(GREATEST(item.requested_qty-item.submitted_qty-item.approved_qty,0),
   CASE WHEN item.delivery_plan_snapshot->>'mode'='BOM' THEN
      GREATEST(COALESCE((SELECT sum(CASE WHEN event.event_type='FULFILL' THEN event.order_qty ELSE -event.order_qty END)
        FROM sales_delivery_fulfillment_events event JOIN sales_delivery_fulfillment_allocations allocation ON allocation.id=event.allocation_id
        WHERE allocation.analysis_item_id=item.id),0),0)
   ELSE GREATEST(TRUNC(COALESCE(sum(CASE WHEN output.event_kind='FULFILL' THEN output.qty_base ELSE -output.qty_base END),0)
      /COALESCE(NULLIF(root.per_product_qty,0),1),4),0) END)
 FROM production_material_analysis_items item
 LEFT JOIN production_material_analysis_materials root ON root.id=item.root_material_id
 LEFT JOIN preplan_root_output_events output ON output.analysis_item_id=item.id
 WHERE item.id=item_id GROUP BY item.id,root.per_product_qty;
$$;
CREATE FUNCTION fn_project_sales_delivery_fulfillment() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 UPDATE production_material_analysis_items source SET root_fulfilled_qty=fn_root_fulfilled_source_qty(source.id),updated_at=now()
 FROM sales_delivery_fulfillment_allocations allocation
 WHERE allocation.id=NEW.allocation_id AND source.id=allocation.analysis_item_id;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_fulfillment_projection AFTER INSERT ON sales_delivery_fulfillment_events
    FOR EACH ROW EXECUTE FUNCTION fn_project_sales_delivery_fulfillment();

CREATE FUNCTION fn_guard_analysis_delivery_custody() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='production_material_analyses' THEN
   IF NEW.status='CANCELLED' AND OLD.status<>'CANCELLED' AND EXISTS(
     SELECT 1 FROM sales_delivery_fulfillment_allocations allocation
     JOIN sales_delivery_fulfillment_groups kit ON kit.shipment_item_id=allocation.shipment_item_id
     WHERE allocation.analysis_id=OLD.id AND kit.state IN('PREPARED','COMPLETED')) THEN
     RAISE EXCEPTION 'analysis has prepared or fulfilled delivery kits; reverse their exact shipment source first' USING ERRCODE='55000'; END IF;
 ELSIF TG_TABLE_NAME='production_material_analysis_materials' THEN
   IF (NEW.analysis_id,NEW.analysis_item_id,NEW.node_key,NEW.goods_id,NEW.color_id,NEW.unit_id)
      IS DISTINCT FROM (OLD.analysis_id,OLD.analysis_item_id,OLD.node_key,OLD.goods_id,OLD.color_id,OLD.unit_id)
      AND EXISTS(SELECT 1 FROM sales_delivery_entitlement_handoffs WHERE source_material_id=OLD.id) THEN
     RAISE EXCEPTION 'delivery private stock source identity is immutable' USING ERRCODE='23514'; END IF;
 ELSE
   IF NEW.requested_qty<NEW.submitted_qty+NEW.approved_qty+NEW.root_fulfilled_qty+COALESCE((
      SELECT sum(allocation.order_qty) FROM sales_delivery_fulfillment_allocations allocation
      JOIN sales_delivery_fulfillment_groups kit ON kit.shipment_item_id=allocation.shipment_item_id
      WHERE allocation.analysis_item_id=OLD.id AND kit.state='PREPARED'
        AND NOT EXISTS(SELECT 1 FROM sales_delivery_fulfillment_events event WHERE event.allocation_id=allocation.id
            AND event.event_type='FULFILL' AND NOT EXISTS(SELECT 1 FROM sales_delivery_fulfillment_events reversed WHERE reversed.counter_event_id=event.id))),0) THEN
      RAISE EXCEPTION 'analysis quantity cannot exclude prepared delivery source kits' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER analysis_delivery_custody_cancel BEFORE UPDATE OF status ON production_material_analyses
    FOR EACH ROW WHEN (NEW.status='CANCELLED' AND OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION fn_guard_analysis_delivery_custody();
CREATE TRIGGER analysis_delivery_material_identity BEFORE UPDATE OF analysis_id,analysis_item_id,node_key,goods_id,color_id,unit_id ON production_material_analysis_materials
    FOR EACH ROW WHEN ((OLD.analysis_id,OLD.analysis_item_id,OLD.node_key,OLD.goods_id,OLD.color_id,OLD.unit_id)
        IS DISTINCT FROM (NEW.analysis_id,NEW.analysis_item_id,NEW.node_key,NEW.goods_id,NEW.color_id,NEW.unit_id))
    EXECUTE FUNCTION fn_guard_analysis_delivery_custody();
CREATE TRIGGER analysis_delivery_prepared_quantity BEFORE UPDATE OF requested_qty,submitted_qty,approved_qty,root_fulfilled_qty
    ON production_material_analysis_items FOR EACH ROW EXECUTE FUNCTION fn_guard_analysis_delivery_custody();

-- A deliberately unassembled delivery ancestor forwards its design demand.
-- Its REFERENCE display stage suppresses assembly; it must not suppress a
-- descendant customer's real private procurement/production entitlement.
CREATE OR REPLACE FUNCTION fn_preplan_original_material_capacity(p_material UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE material production_material_analysis_materials%ROWTYPE;
    source production_material_analysis_items%ROWTYPE; edge RECORD;
    conversion NUMERIC; expected_depth INTEGER:=0; last_depth INTEGER;
    parent_expands BOOLEAN:=TRUE;
BEGIN
    SELECT * INTO material FROM production_material_analysis_materials WHERE id=p_material AND active;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO source FROM production_material_analysis_items WHERE id=material.analysis_item_id
      AND analysis_id=material.analysis_id AND NOT is_deleted AND source_type NOT IN('MAKE_COMPONENT','AGGREGATE_MAKE');
    IF NOT FOUND THEN RETURN NULL; END IF;
    conversion:=1;
    IF source.source_type='SALES_ORDER_ITEM' THEN
      SELECT COALESCE(item.unit_rate,1) INTO conversion FROM sales_order_items item
      JOIN sales_orders header ON header.id=item.order_id AND header.status=1 AND header.finance_confirmed
        AND NOT header.is_deleted AND NOT header.is_closed AND NOT header.is_stopped
      WHERE item.id=source.sales_order_item_id AND NOT item.is_deleted
        AND (item.goods_id,item.color_id,item.unit_id) IS NOT DISTINCT FROM (source.goods_id,source.color_id,source.unit_id);
      IF NOT FOUND OR conversion<=0 THEN RETURN NULL; END IF;
    END IF;
    last_depth:=NULL;
    FOR edge IN WITH RECURSIVE ancestry AS (
      SELECT row.*,ARRAY[row.id] AS visited FROM production_material_analysis_materials row WHERE row.id=p_material AND row.active
      UNION ALL
      SELECT parent.*,child.visited||parent.id FROM ancestry child
      JOIN production_material_analysis_materials parent ON parent.analysis_item_id=child.analysis_item_id
        AND parent.analysis_id=child.analysis_id AND parent.node_key=child.parent_node_key AND parent.active
      WHERE NOT parent.id=ANY(child.visited) AND cardinality(child.visited)<64
    ) SELECT * FROM ancestry ORDER BY depth LOOP
      IF last_depth IS NULL THEN
        IF NOT (edge.depth=0 AND edge.parent_node_key IS NULL OR edge.depth=1 AND edge.parent_node_key IS NULL) THEN RETURN NULL; END IF;
        expected_depth:=edge.depth;
      END IF;
      IF edge.depth<>expected_depth OR edge.bom_qty<=0 OR edge.basis_output_qty<=0 THEN RETURN NULL; END IF;
      IF edge.depth>1 AND NOT parent_expands THEN RETURN NULL; END IF;
      IF edge.consumption_basis NOT IN('PER_UNIT','PER_PACKAGE','FIXED_BATCH') THEN RETURN NULL; END IF;
      last_depth:=edge.depth;expected_depth:=edge.depth+1;
      parent_expands:=(edge.delivery_context AND COALESCE(source.delivery_plan_snapshot->>'mode','ASSEMBLED')='BOM')
          OR (COALESCE(edge.confirmed_route,edge.source_suggestion,'REVIEW') IN('MAKE','SUBCONTRACT') AND edge.control_stage<>'REFERENCE');
    END LOOP;
    IF last_depth IS DISTINCT FROM material.depth THEN RETURN NULL; END IF;
    RETURN GREATEST(material.required_qty+COALESCE((SELECT SUM(fn_preplan_aggregate_alias_qty(alias.id))
      FROM preplan_aggregate_material_aliases alias WHERE alias.source_material_id=p_material
        AND fn_preplan_aggregate_alias_identity_valid(alias.id)),0),0);
END $$;

SELECT fn_audit_track_table('sales_delivery_fulfillment_groups','COLUMN_SCOPED','data_change',false,
 ARRAY['id','shipment_item_id','shipment_id','order_item_id','order_qty','state','created_by','created_at','updated_at'],true,NULL);
SELECT fn_audit_track_table('sales_delivery_fulfillment_allocations','COLUMN_SCOPED','data_change',false,
 ARRAY['id','shipment_item_id','analysis_id','analysis_item_id','position','order_qty','created_by','created_at'],true,NULL);
SELECT fn_audit_track_table('sales_delivery_entitlement_handoffs','COLUMN_SCOPED','data_change',false,
 ARRAY['id','component_id','allocation_id','source_analysis_id','source_material_id','entitlement_analysis_id','entitlement_material_id',
    'aggregate_alias_id','source_entitlement_event_id','source_reservation_id','target_reservation_id','release_event_id','quantity','created_by','created_at'],true,NULL);
SELECT fn_audit_track_table('sales_delivery_entitlement_restores','COLUMN_SCOPED','data_change',false,
 ARRAY['id','handoff_id','restore_event_id','reason','created_by','created_at'],true,NULL);
SELECT fn_audit_track_table('sales_delivery_fulfillment_events','COLUMN_SCOPED','data_change',false,
 ARRAY['id','allocation_id','event_type','order_qty','counter_event_id','created_by','created_at'],true,NULL);
