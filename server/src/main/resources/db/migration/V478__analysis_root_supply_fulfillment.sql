-- V478: root-product supply nodes and append-only output handoff.
-- Existing analyses keep their original source and route until an authorized refresh.
ALTER TABLE production_material_analysis_items
    ADD COLUMN root_material_id UUID,
    ADD COLUMN root_fulfilled_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD CONSTRAINT analysis_root_fulfilled_qty_chk CHECK (
        root_fulfilled_qty >= 0
        AND submitted_qty + approved_qty + root_fulfilled_qty <= requested_qty),
    ADD CONSTRAINT analysis_root_material_fk FOREIGN KEY (root_material_id)
        REFERENCES production_material_analysis_materials(id)
        DEFERRABLE INITIALLY DEFERRED;
CREATE UNIQUE INDEX uq_analysis_root_material
    ON production_material_analysis_items(root_material_id)
    WHERE root_material_id IS NOT NULL;

ALTER TABLE production_material_analysis_materials
    ADD COLUMN node_role TEXT NOT NULL DEFAULT 'BOM_COMPONENT',
    DROP CONSTRAINT production_material_analysis_material_depth_chk,
    ADD CONSTRAINT production_material_analysis_material_depth_chk CHECK (
        (node_role='ROOT_SUPPLY' AND depth=0 AND parent_node_key IS NULL AND bom_item_id IS NULL)
        OR (node_role='BOM_COMPONENT' AND depth BETWEEN 1 AND 10)),
    ADD CONSTRAINT analysis_material_node_role_chk
        CHECK (node_role IN ('ROOT_SUPPLY','BOM_COMPONENT')),
    DROP CONSTRAINT pma_material_tree_shape_chk,
    ADD CONSTRAINT pma_material_tree_shape_chk CHECK (
        (node_role='ROOT_SUPPLY' AND depth=0 AND parent_node_key IS NULL)
        OR (node_role='BOM_COMPONENT' AND ((depth=1 AND parent_node_key IS NULL)
             OR (depth>1 AND parent_node_key IS NOT NULL))));

CREATE TABLE preplan_root_output_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id UUID NOT NULL REFERENCES production_material_analyses(id),
    analysis_item_id UUID NOT NULL REFERENCES production_material_analysis_items(id),
    root_material_id UUID NOT NULL REFERENCES production_material_analysis_materials(id),
    route TEXT NOT NULL DEFAULT 'BUY' CHECK (route IN ('BUY','SUBCONTRACT')),
    reason TEXT,
    event_kind TEXT NOT NULL CHECK (event_kind IN ('FULFILL','REVERSE')),
    reversed_event_id UUID REFERENCES preplan_root_output_events(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    qty_base NUMERIC(18,4) NOT NULL CHECK (qty_base>0),
    source_reservation_id UUID REFERENCES stock_reservations(id),
    release_entitlement_event_id UUID REFERENCES preplan_stock_entitlement_events(id),
    sales_order_item_id UUID REFERENCES sales_order_items(id),
    sales_reservation_id UUID REFERENCES stock_reservations(id),
    source_receipt_type TEXT CHECK (source_receipt_type IN ('PURCHASE','SUBCONTRACT')),
    source_receipt_id UUID,
    idempotency_key TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES users(id),
    CONSTRAINT root_output_event_shape_chk CHECK (
        (event_kind='FULFILL' AND reversed_event_id IS NULL)
        OR (event_kind='REVERSE' AND reversed_event_id IS NOT NULL)),
    CONSTRAINT root_output_receipt_shape_chk CHECK (
        (source_reservation_id IS NULL AND release_entitlement_event_id IS NULL
         AND source_receipt_type IS NULL AND source_receipt_id IS NULL)
        OR (source_reservation_id IS NOT NULL AND release_entitlement_event_id IS NOT NULL
            AND source_receipt_type IS NOT NULL AND source_receipt_id IS NOT NULL)),
    CONSTRAINT root_output_new_manual_supply_chk CHECK (
        source_reservation_id IS NOT NULL OR sales_order_item_id IS NOT NULL),
    CONSTRAINT root_output_sales_shape_chk CHECK (
        (sales_order_item_id IS NULL AND sales_reservation_id IS NULL)
        OR (sales_order_item_id IS NOT NULL AND sales_reservation_id IS NOT NULL)));
CREATE UNIQUE INDEX uq_root_output_reversal
    ON preplan_root_output_events(reversed_event_id) WHERE event_kind='REVERSE';
CREATE UNIQUE INDEX uq_root_output_release_event ON preplan_root_output_events(release_entitlement_event_id)
    WHERE event_kind='FULFILL' AND release_entitlement_event_id IS NOT NULL;
CREATE UNIQUE INDEX uq_root_output_sales_reservation ON preplan_root_output_events(sales_reservation_id)
    WHERE event_kind='FULFILL' AND sales_reservation_id IS NOT NULL;
CREATE INDEX idx_root_output_item ON preplan_root_output_events(analysis_item_id, created_at, id);
CREATE INDEX idx_root_output_receipt
    ON preplan_root_output_events(source_receipt_type, source_receipt_id)
    WHERE source_receipt_id IS NOT NULL;

CREATE OR REPLACE FUNCTION fn_guard_root_output_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    source_item production_material_analysis_items%ROWTYPE;
    material production_material_analysis_materials%ROWTYPE;
    original preplan_root_output_events%ROWTYPE;
    net_base NUMERIC;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'root output events are append-only' USING ERRCODE='23514';
    END IF;
    SELECT * INTO STRICT source_item FROM production_material_analysis_items
      WHERE id=NEW.analysis_item_id FOR UPDATE;
    SELECT * INTO STRICT material FROM production_material_analysis_materials
      WHERE id=NEW.root_material_id;
    IF source_item.analysis_id<>NEW.analysis_id
       OR source_item.root_material_id IS DISTINCT FROM NEW.root_material_id
       OR material.node_role<>'ROOT_SUPPLY'
       OR material.analysis_item_id<>source_item.id
       OR material.goods_id<>NEW.goods_id
       OR material.color_id IS DISTINCT FROM NEW.color_id
       OR source_item.sales_order_item_id IS DISTINCT FROM NEW.sales_order_item_id
       OR NOT EXISTS (SELECT 1 FROM production_material_analyses a
           WHERE a.id=NEW.analysis_id AND a.warehouse_id=NEW.warehouse_id) THEN
        RAISE EXCEPTION 'root output source identity mismatch' USING ERRCODE='23514';
    END IF;
    IF NEW.event_kind='REVERSE' THEN
        SELECT * INTO STRICT original FROM preplan_root_output_events
          WHERE id=NEW.reversed_event_id AND event_kind='FULFILL' FOR UPDATE;
        IF original.analysis_item_id<>NEW.analysis_item_id
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
        IF NEW.source_reservation_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM preplan_stock_entitlement_events released
            JOIN stock_reservations r ON r.id=released.stock_reservation_id
            WHERE released.id=NEW.release_entitlement_event_id
              AND released.event_type='RELEASE'
              AND released.stock_reservation_id=NEW.source_reservation_id
              AND released.beneficiary_analysis_id=NEW.analysis_id
              AND released.beneficiary_analysis_material_id=NEW.root_material_id
              AND released.qty=NEW.qty_base
              AND r.source_doc_type=NEW.source_receipt_type||'_RECEIPT'
              AND r.source_doc_id=NEW.source_receipt_id
              AND r.warehouse_id=NEW.warehouse_id) THEN
            RAISE EXCEPTION 'root output lacks the matching exact release'
              USING ERRCODE='23514';
        END IF;
        IF NEW.sales_reservation_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM stock_reservations r
            WHERE r.id=NEW.sales_reservation_id AND r.order_item_id=NEW.sales_order_item_id
              AND r.owner_type='SALES_ORDER_ITEM' AND r.warehouse_id=NEW.warehouse_id
              AND r.goods_id=NEW.goods_id AND r.color_id IS NOT DISTINCT FROM NEW.color_id
              AND r.qty=NEW.qty_base AND r.consumed_qty=0 AND r.released_qty=0) THEN
            RAISE EXCEPTION 'root output lacks its sales reservation' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_root_output_event BEFORE INSERT OR UPDATE OR DELETE
    ON preplan_root_output_events FOR EACH ROW EXECUTE FUNCTION fn_guard_root_output_event();

CREATE OR REPLACE FUNCTION fn_root_fulfilled_source_qty(item_id UUID)
RETURNS NUMERIC LANGUAGE SQL STABLE AS $$
    SELECT LEAST(GREATEST(item.requested_qty-item.submitted_qty-item.approved_qty,0),
           GREATEST(TRUNC(COALESCE(SUM(CASE WHEN event.event_kind='FULFILL'
                     THEN event.qty_base ELSE -event.qty_base END),0)
                 / COALESCE(NULLIF(root.per_product_qty,0),1),4),0))
    FROM production_material_analysis_items item
    LEFT JOIN production_material_analysis_materials root ON root.id=item.root_material_id
    LEFT JOIN preplan_root_output_events event ON event.analysis_item_id=item.id
    WHERE item.id=item_id
    GROUP BY item.id,root.per_product_qty;
$$;

CREATE OR REPLACE FUNCTION fn_project_root_output_quantity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE production_material_analysis_items item
    SET root_fulfilled_qty=fn_root_fulfilled_source_qty(item.id),
        ready_now_qty=0, ready_by_date_qty=0, ready_start_qty=0,
        ready_finish_qty=0, ready_ship_qty=0, updated_at=now()
    WHERE item.id=NEW.analysis_item_id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_project_root_output_quantity AFTER INSERT ON preplan_root_output_events
    FOR EACH ROW EXECUTE FUNCTION fn_project_root_output_quantity();

CREATE OR REPLACE FUNCTION fn_check_root_output_quantity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE expected NUMERIC; actual NUMERIC;
BEGIN
    SELECT root_fulfilled_qty INTO actual FROM production_material_analysis_items WHERE id=NEW.id;
    SELECT fn_root_fulfilled_source_qty(NEW.id) INTO expected;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'root fulfilled quantity must equal output event ledger'
          USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_check_root_output_quantity
    AFTER INSERT OR UPDATE ON production_material_analysis_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_root_output_quantity();
CREATE TRIGGER trg_audit_preplan_root_output_events AFTER INSERT OR UPDATE OR DELETE
    ON preplan_root_output_events FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE FUNCTION fn_guard_root_supply_route()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='production_material_analysis_materials' THEN
        IF NEW.node_role='ROOT_SUPPLY'
           AND COALESCE(NEW.confirmed_route,'MAKE') IS DISTINCT FROM COALESCE(OLD.confirmed_route,'MAKE')
           AND (EXISTS (
             SELECT 1 FROM production_material_analysis_plan_links link
             WHERE link.analysis_item_id=NEW.analysis_item_id
               AND link.allocation_status IN ('SUBMITTED','APPROVED'))
             OR EXISTS (
             SELECT 1 FROM preplan_supply_action_allocations allocation
             JOIN preplan_supply_actions action ON action.id=allocation.action_id
             JOIN production_material_analysis_materials source ON source.id=allocation.analysis_material_id
             WHERE source.analysis_item_id=NEW.analysis_item_id AND action.status<>'CANCELLED')
             OR EXISTS (SELECT 1 FROM production_material_analysis_items item
               WHERE item.id=NEW.analysis_item_id AND item.root_fulfilled_qty>0)
             OR EXISTS (SELECT 1 FROM preplan_root_output_events e
               WHERE e.analysis_item_id=NEW.analysis_item_id AND e.event_kind='FULFILL'
                 AND NOT EXISTS (SELECT 1 FROM preplan_root_output_events rev WHERE rev.reversed_event_id=e.id))) THEN
            RAISE EXCEPTION 'root route is frozen by active plans, supply or fulfillment'
              USING ERRCODE='23514';
        END IF;
    ELSE
        IF NEW.material_analysis_item_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM production_material_analysis_items item
            JOIN production_material_analysis_materials root ON root.id=item.root_material_id
            WHERE item.id=NEW.material_analysis_item_id
              AND COALESCE(root.confirmed_route,'MAKE')<>'MAKE') THEN
            RAISE EXCEPTION 'external root supply cannot create a manufacturing plan'
              USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_root_supply_route BEFORE UPDATE OF confirmed_route
    ON production_material_analysis_materials FOR EACH ROW EXECUTE FUNCTION fn_guard_root_supply_route();
CREATE TRIGGER trg_guard_root_supply_plan BEFORE INSERT OR UPDATE OF material_analysis_item_id
    ON production_plans FOR EACH ROW EXECUTE FUNCTION fn_guard_root_supply_route();

-- Confirmed route memory remains available when a root route deactivates its old BOM.
CREATE INDEX idx_analysis_material_confirmed_route_history
    ON production_material_analysis_materials(goods_id,color_id,unit_id,route_confirmed_at DESC,id)
    WHERE confirmed_route IS NOT NULL;

-- Preserve the application's existing reset function; only extend its explicit CLEAR list.
DO $$
DECLARE definition TEXT; needle TEXT := '(''preplan_public_supply_events'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN
        RAISE EXCEPTION 'V478 reset policy anchor missing';
    END IF;
    definition := replace(definition,needle,
      '(''preplan_root_output_events'', ''CLEAR''), '||needle);
    EXECUTE definition;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_root_material_identity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='production_material_analysis_items' THEN
        IF OLD.root_material_id IS NOT NULL AND NEW.root_material_id IS DISTINCT FROM OLD.root_material_id THEN
            RAISE EXCEPTION 'root supply material identity is immutable' USING ERRCODE='23514';
        END IF;
    ELSIF OLD.node_role='ROOT_SUPPLY' AND ROW(
        NEW.analysis_id,NEW.analysis_item_id,NEW.node_role,NEW.depth,NEW.goods_id,NEW.color_id,
        NEW.unit_id,NEW.per_product_qty,NEW.node_key,NEW.path)
        IS DISTINCT FROM ROW(
        OLD.analysis_id,OLD.analysis_item_id,OLD.node_role,OLD.depth,OLD.goods_id,OLD.color_id,
        OLD.unit_id,OLD.per_product_qty,OLD.node_key,OLD.path) THEN
        RAISE EXCEPTION 'root supply dimension and conversion are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_root_material_pointer BEFORE UPDATE OF root_material_id
    ON production_material_analysis_items FOR EACH ROW EXECUTE FUNCTION fn_guard_root_material_identity();
CREATE TRIGGER trg_guard_root_material_identity BEFORE UPDATE
    ON production_material_analysis_materials FOR EACH ROW EXECUTE FUNCTION fn_guard_root_material_identity();

CREATE OR REPLACE FUNCTION fn_check_root_material_owner()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE item production_material_analysis_items%ROWTYPE;
BEGIN
    SELECT * INTO item FROM production_material_analysis_items WHERE id=NEW.id;
    IF item.root_material_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM production_material_analysis_materials m WHERE m.id=item.root_material_id
          AND m.analysis_id=item.analysis_id AND m.analysis_item_id=item.id AND m.node_role='ROOT_SUPPLY'
          AND m.goods_id=item.goods_id AND m.color_id IS NOT DISTINCT FROM item.color_id) THEN
        RAISE EXCEPTION 'root material must belong to its exact source item' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_check_root_material_owner AFTER INSERT OR UPDATE
    ON production_material_analysis_items DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_root_material_owner();

ALTER TABLE production_material_analysis_commands
    DROP CONSTRAINT production_material_analysis_command_operation_chk,
    ADD CONSTRAINT production_material_analysis_command_operation_chk CHECK (operation IN (
      'PREVIEW','ROUTE','REALLOCATE','NOTIFY','GENERATE_PLAN','CANCEL_ANALYSIS','CANCEL_ACTION',
      'BORROW','BORROW_REVOKE','CROSS_REALLOCATE','CROSS_REALLOCATE_REVOKE','CLAIM_SHARED_FUTURE',
      'ROOT_OUTPUT_REVOKE'));

CREATE OR REPLACE FUNCTION fn_check_root_sales_reservation_release()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
      SELECT 1 FROM preplan_root_output_events e
      JOIN stock_reservations r ON r.id=e.sales_reservation_id
      WHERE e.event_kind='FULFILL' AND r.id=NEW.id
        AND (r.released_qty>0 OR r.is_deleted=TRUE)
        AND NOT EXISTS(SELECT 1 FROM preplan_root_output_events rev WHERE rev.reversed_event_id=e.id)
    ) THEN
        RAISE EXCEPTION 'root sales reservation must be released through root output reversal'
          USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_check_root_sales_reservation_release
    AFTER UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_root_sales_reservation_release();

-- Root supply targets are not manufacturing BOM edges. Preserve every original
-- tree/quantity check, excluding only the new role from the old traversal.
DO $$
DECLARE definition TEXT;
        anchor TEXT := '    SELECT COALESCE(SUM(requested_qty - submitted_qty - approved_qty),0),';
        root_projection TEXT := $patch$
    UPDATE production_material_analysis_materials root
    SET required_qty=CEIL(GREATEST(item.requested_qty-item.submitted_qty-item.approved_qty,0)
                           *root.per_product_qty*10000)/10000,
        allocated_available_qty=0,allocated_start_qty=0,allocated_finish_qty=0,allocated_ship_qty=0,
        shortage_qty=CEIL(GREATEST(item.requested_qty-item.submitted_qty-item.approved_qty,0)
                          *root.per_product_qty*10000)/10000,
        updated_at=now()
    FROM production_material_analysis_items item
    WHERE item.id=NEW.analysis_item_id AND root.id=item.root_material_id
      AND root.node_role='ROOT_SUPPLY';

$patch$;
BEGIN
    SELECT pg_get_functiondef('fn_sync_material_analysis_plan_link_qty()'::regprocedure) INTO definition;
    IF position('material analysis snapshot tree is incomplete' IN definition)=0
       OR position(anchor IN definition)=0 THEN
        RAISE EXCEPTION 'V478 analysis plan-link function shape changed';
    END IF;
    definition := replace(definition,'AND material.active = TRUE',
       'AND material.active = TRUE AND material.node_role = ''BOM_COMPONENT''');
    definition := replace(definition,'AND child.active = TRUE',
       'AND child.active = TRUE AND child.node_role = ''BOM_COMPONENT''');
    definition := replace(definition,'AND active = TRUE',
       'AND active = TRUE AND node_role = ''BOM_COMPONENT''');
    definition := replace(definition,anchor,root_projection||anchor);
    definition := replace(definition,'SUM(requested_qty - submitted_qty - approved_qty)',
       'SUM(requested_qty - submitted_qty - approved_qty - root_fulfilled_qty)');
    definition := replace(definition,'SUM(submitted_qty + approved_qty)',
       'SUM(submitted_qty + approved_qty + root_fulfilled_qty)');
    EXECUTE definition;
END;
$$;
