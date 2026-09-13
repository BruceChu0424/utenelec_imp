-- Sales may submit commercial quantities before warehouse staff select the
-- physical leaf warehouse. Existing submissions and finance hashes retain
-- their original byte-for-byte warehouse meaning.
ALTER TABLE sales_shipments ADD COLUMN warehouse_chosen_at_pick BOOLEAN NOT NULL DEFAULT FALSE;
-- Existing current-workflow drafts with no warehouse have always frozen a
-- JSON null warehouse. Their new selection policy leaves those hashes intact.
UPDATE sales_shipments SET warehouse_chosen_at_pick=TRUE
WHERE warehouse_id IS NULL AND finance_gate_version>=2 AND shipment_kind IN('ORDER','DIRECT_CUSTOMER')
  AND status=0 AND warehouse_work_status='PENDING_PICK' AND NOT is_deleted;
ALTER TABLE sales_shipment_warehouse_events
    ADD COLUMN warehouse_id UUID REFERENCES warehouses(id),
    ADD COLUMN review_revision BIGINT,
    ADD COLUMN line_stock_places JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD CONSTRAINT sales_shipment_warehouse_places_object_chk CHECK(jsonb_typeof(line_stock_places)='object');

ALTER FUNCTION fn_customer_shipment_commercial_snapshot(UUID)
    RENAME TO fn_customer_shipment_commercial_snapshot_before_v566;
CREATE FUNCTION fn_customer_shipment_commercial_snapshot(p_shipment_id UUID)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN document.warehouse_chosen_at_pick
        THEN jsonb_set(fn_customer_shipment_commercial_snapshot_before_v566(p_shipment_id)::jsonb,
                       '{header,warehouseId}','null'::jsonb)::text
        ELSE fn_customer_shipment_commercial_snapshot_before_v566(p_shipment_id) END
    FROM sales_shipments document WHERE document.id=p_shipment_id
$$;

CREATE FUNCTION fn_guard_sales_shipment_picking_warehouse() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' THEN
        IF NEW.warehouse_chosen_at_pick AND NEW.shipment_kind='LEGACY' THEN
            RAISE EXCEPTION 'Historical shipments cannot change warehouse-selection policy' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.warehouse_chosen_at_pick IS DISTINCT FROM OLD.warehouse_chosen_at_pick THEN
        RAISE EXCEPTION 'Shipment warehouse-selection mode is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.warehouse_chosen_at_pick AND NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id THEN
        IF OLD.status<>0 OR NEW.status<>0 OR OLD.warehouse_work_status<>'PENDING_PICK'
           OR NEW.warehouse_work_status<>'PICKING' OR OLD.finance_audit<>1 OR NEW.finance_audit<>1
           OR NEW.review_revision<>OLD.review_revision OR NEW.warehouse_id IS NULL THEN
            RAISE EXCEPTION 'Physical shipment warehouse is selected only when a finance-released task starts picking' USING ERRCODE='23514';
        END IF;
        IF NOT EXISTS(SELECT 1 FROM warehouses warehouse WHERE warehouse.id=NEW.warehouse_id
            AND NOT warehouse.is_deleted AND warehouse.is_accountable
            AND warehouse.status='使用' AND NOT EXISTS(SELECT 1 FROM warehouses child
                WHERE child.parent_id=warehouse.id AND NOT child.is_deleted)) THEN
            RAISE EXCEPTION 'Shipment picking requires an active actual leaf warehouse' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_sales_shipment_picking_warehouse BEFORE INSERT OR UPDATE ON sales_shipments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_shipment_picking_warehouse();
ALTER TABLE sales_shipments ENABLE ALWAYS TRIGGER trg_guard_sales_shipment_picking_warehouse;

CREATE FUNCTION fn_assert_sales_shipment_picking_warehouse() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE document sales_shipments%ROWTYPE;
BEGIN
    SELECT * INTO document FROM sales_shipments WHERE id=NEW.id;
    IF document.warehouse_chosen_at_pick AND document.warehouse_work_status IN('PICKING','PICKED','SHIPPED') THEN
        IF document.warehouse_id IS NULL OR NOT EXISTS(SELECT 1 FROM sales_shipment_warehouse_events event
            WHERE event.shipment_id=document.id AND event.to_status='PICKING'
              AND event.warehouse_id=document.warehouse_id AND event.review_revision=document.review_revision
              AND event.actor_employee_id=document.picking_started_by AND event.occurred_at=document.picking_started_at) THEN
            RAISE EXCEPTION 'Physical shipment warehouse requires an immutable warehouse picking event' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_assert_sales_shipment_picking_warehouse AFTER INSERT OR UPDATE ON sales_shipments
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_sales_shipment_picking_warehouse();
ALTER TABLE sales_shipments ENABLE ALWAYS TRIGGER trg_assert_sales_shipment_picking_warehouse;

CREATE FUNCTION fn_guard_sales_shipment_picking_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE document sales_shipments%ROWTYPE; entry RECORD;
BEGIN
    IF NEW.to_status<>'PICKING' THEN
        IF NEW.line_stock_places<>'{}'::jsonb THEN
            RAISE EXCEPTION 'Actual stock locations are recorded by the picking transition' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    SELECT * INTO document FROM sales_shipments WHERE id=NEW.shipment_id;
    IF NEW.warehouse_id IS DISTINCT FROM document.warehouse_id OR NEW.review_revision IS DISTINCT FROM document.review_revision
       OR document.warehouse_work_status<>'PICKING' OR document.finance_audit<>1
       OR NEW.actor_employee_id IS DISTINCT FROM document.picking_started_by
       OR NEW.occurred_at IS DISTINCT FROM document.picking_started_at THEN
        RAISE EXCEPTION 'Picking evidence must match the finance-released physical execution' USING ERRCODE='23514';
    END IF;
    FOR entry IN SELECT * FROM jsonb_each(NEW.line_stock_places) LOOP
        IF entry.key !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
           OR jsonb_typeof(entry.value)<>'string' OR length(entry.value#>>'{}')>200 THEN
            RAISE EXCEPTION 'Picking locations require exact shipment item UUIDs and at most 200 characters' USING ERRCODE='23514';
        END IF;
        IF NOT EXISTS(SELECT 1 FROM sales_shipment_items item WHERE item.id=entry.key::uuid
            AND item.shipment_id=document.id AND NOT item.is_deleted) THEN
            RAISE EXCEPTION 'Picking location does not belong to this shipment' USING ERRCODE='23514';
        END IF;
    END LOOP;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_sales_shipment_picking_evidence BEFORE INSERT ON sales_shipment_warehouse_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_shipment_picking_evidence();
ALTER TABLE sales_shipment_warehouse_events ENABLE ALWAYS TRIGGER trg_guard_sales_shipment_picking_evidence;

COMMENT ON COLUMN sales_shipments.warehouse_chosen_at_pick IS 'New sales drafts may leave warehouse choice to finance-released warehouse picking; historic commercial warehouse snapshots remain unchanged.';
COMMENT ON COLUMN sales_shipment_warehouse_events.line_stock_places IS 'Actual picking location text keyed by exact shipment item UUID, separate from current goods placement hints.';
