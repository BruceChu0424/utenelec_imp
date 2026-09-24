-- A component owned by this exact parent demand remains reserved throughout
-- subcontract dispatch. Public availability alone cannot see qualified IQC lots.
-- The outbound identity depends on the parent's immediate input, not on how
-- that input was acquired. A manufactured child may have its own complete BOM.
CREATE OR REPLACE FUNCTION fn_subcontract_sole_component_goods(p_goods_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM goods_bom_items edge
        JOIN goods child ON child.id=edge.component_goods_id AND NOT child.is_deleted
          AND NOT COALESCE(child.auto_created,FALSE)
        WHERE edge.goods_id=p_goods_id AND NOT edge.is_deleted
          AND edge.consumption_basis='PER_UNIT'
          AND edge.control_stage IN ('START','ASSEMBLY','FINISH') AND edge.qty>0
          AND (SELECT COUNT(*) FROM goods_bom_items sibling
               JOIN goods live_child ON live_child.id=sibling.component_goods_id
                 AND NOT live_child.is_deleted AND NOT COALESCE(live_child.auto_created,FALSE)
               WHERE sibling.goods_id=p_goods_id AND NOT sibling.is_deleted)=1
    )
$$;
COMMENT ON FUNCTION fn_subcontract_sole_component_goods(UUID) IS
    'V646: one immediate PER_UNIT productive component; qualified stock of that component unlocks dispatch whether purchased or manufactured.';

CREATE TABLE subcontract_component_stock_handoffs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_item_id UUID NOT NULL REFERENCES subcontract_material_plan_items(id),
    application_item_id UUID NOT NULL REFERENCES subcontract_application_items(id),
    parent_material_id UUID NOT NULL REFERENCES production_material_analysis_materials(id),
    child_material_id UUID NOT NULL REFERENCES production_material_analysis_materials(id),
    source_entitlement_event_id UUID NOT NULL REFERENCES preplan_stock_entitlement_events(id),
    source_reservation_id UUID NOT NULL REFERENCES stock_reservations(id),
    target_reservation_id UUID NOT NULL UNIQUE REFERENCES stock_reservations(id),
    release_event_id UUID NOT NULL UNIQUE REFERENCES preplan_stock_entitlement_events(id),
    qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID NOT NULL REFERENCES users(id)
);
CREATE INDEX idx_subcontract_component_handoff_plan ON subcontract_component_stock_handoffs(plan_item_id);
CREATE INDEX idx_subcontract_component_handoff_source ON subcontract_component_stock_handoffs(source_reservation_id);
CREATE INDEX idx_subcontract_component_handoff_parent ON subcontract_component_stock_handoffs(parent_material_id);
CREATE INDEX idx_subcontract_component_handoff_child ON subcontract_component_stock_handoffs(child_material_id);
CREATE TRIGGER trg_audit_subcontract_component_stock_handoffs
AFTER INSERT OR UPDATE OR DELETE ON subcontract_component_stock_handoffs
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE subcontract_component_stock_handoffs
    ENABLE ALWAYS TRIGGER trg_audit_subcontract_component_stock_handoffs;
COMMENT ON TABLE subcontract_component_stock_handoffs IS
    'Exact child entitlement to subcontract outbound custody. RELEASE/RESTORE events preserve original product, analysis node and receipt lineage.';

-- Cumulative rounding gives every source parent its original allocation share;
-- the stable final allocation absorbs the rounding remainder, never another product.
CREATE FUNCTION fn_subcontract_component_parent_capacity(p_application_item UUID,p_allocation UUID,p_total NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  WITH weights AS (
    SELECT allocation.id,allocation.allocated_qty
    FROM preplan_supply_action_allocations allocation
    JOIN preplan_supply_actions action ON action.id=allocation.action_id
      AND action.route='SUBCONTRACT' AND action.status<>'CANCELLED'
      AND action.external_document_type='SUBCONTRACT_APPLICATION'
    WHERE allocation.external_item_id=p_application_item OR action.public_surplus_external_item_id=p_application_item
  ), portions AS (
    SELECT id,round(p_total*SUM(allocated_qty) OVER(ORDER BY id)/NULLIF(SUM(allocated_qty) OVER(),0),4)
      -round(p_total*COALESCE(SUM(allocated_qty) OVER(ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0)
        /NULLIF(SUM(allocated_qty) OVER(),0),4) AS qty FROM weights
  ) SELECT COALESCE((SELECT qty FROM portions WHERE id=p_allocation),0)
$$;

-- Match an immediate BOM child of the actual source parent node. Matching only
-- analysis+SKU would steal stock from sibling products using the same component.
CREATE FUNCTION fn_subcontract_component_entitled_lots(p_application_item_id UUID, p_order_item_id UUID)
RETURNS TABLE(application_item_id UUID, entitlement_event_id UUID, stock_reservation_id UUID,
    beneficiary_analysis_id UUID, beneficiary_analysis_material_id UUID,
    source_exact_peg_id UUID, reallocation_id UUID, warehouse_id UUID,
    goods_id UUID, color_id UUID, remaining_qty NUMERIC, parent_material_id UUID)
LANGUAGE sql STABLE AS $$
    WITH applications AS (
        SELECT app.id,app.qty*COALESCE(app.unit_rate,1) AS parent_qty
        FROM subcontract_application_items app WHERE app.id=p_application_item_id AND p_order_item_id IS NULL
        UNION
        SELECT source.application_item_id,source.alloc_qty*COALESCE(item.unit_rate,1)
        FROM subcontract_order_item_sources source JOIN subcontract_order_items item ON item.id=source.order_item_id
        WHERE source.order_item_id=p_order_item_id AND source.alloc_qty>0
    ), children AS (
        SELECT DISTINCT app.id AS application_item_id, child.analysis_id, child.id AS material_id,parent.id AS parent_material_id,
               edge.component_goods_id, edge.color_id,
               fn_subcontract_component_parent_capacity(app.id,allocation.id,selected.parent_qty*edge.qty) AS capacity_qty
        FROM applications selected
        JOIN subcontract_application_items app ON app.id=selected.id AND NOT app.is_deleted
        JOIN goods_bom_items edge ON edge.goods_id=app.goods_id AND NOT edge.is_deleted
        JOIN preplan_supply_actions action ON action.external_document_type='SUBCONTRACT_APPLICATION'
          AND action.route='SUBCONTRACT' AND action.status<>'CANCELLED'
        JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
          AND allocation.analysis_id=action.analysis_id
          AND (allocation.external_item_id=app.id OR action.public_surplus_external_item_id=app.id)
        JOIN production_material_analysis_materials parent ON parent.id=allocation.analysis_material_id
          AND parent.analysis_id=allocation.analysis_id AND parent.active
          AND parent.goods_id=app.goods_id AND parent.color_id IS NOT DISTINCT FROM app.color_id
        JOIN production_material_analysis_materials child ON child.analysis_id=parent.analysis_id
          AND child.analysis_item_id=parent.analysis_item_id AND child.parent_node_key=parent.node_key
          AND child.bom_item_id=edge.id AND child.active
          AND child.goods_id=edge.component_goods_id AND child.color_id IS NOT DISTINCT FROM edge.color_id
        WHERE fn_subcontract_sole_component_goods(app.goods_id)
    ), child_capacities AS (
        SELECT application_item_id,analysis_id,material_id,parent_material_id,component_goods_id,color_id,
               SUM(capacity_qty) AS capacity_qty
        FROM children GROUP BY application_item_id,analysis_id,material_id,parent_material_id,component_goods_id,color_id
    ), remaining_capacities AS (
        SELECT child.*,
               GREATEST(child.capacity_qty-COALESCE((
                 SELECT SUM(handoff.qty-target.released_qty)
                 FROM subcontract_component_stock_handoffs handoff
                 JOIN subcontract_material_plan_items pi ON pi.id=handoff.plan_item_id
                 JOIN stock_reservations target ON target.id=handoff.target_reservation_id
                 WHERE p_order_item_id IS NOT NULL AND pi.order_item_id=p_order_item_id
                   AND handoff.application_item_id=child.application_item_id
                   AND handoff.child_material_id=child.material_id),0),0) AS remaining_capacity
        FROM child_capacities child
    ), application_ranges AS (
        SELECT child.*,
               SUM(remaining_capacity) OVER(PARTITION BY material_id ORDER BY application_item_id)
                   -remaining_capacity AS range_start,
               SUM(remaining_capacity) OVER(PARTITION BY material_id ORDER BY application_item_id) AS range_end
        FROM remaining_capacities child WHERE remaining_capacity>0
    ), source_lots AS (
        SELECT DISTINCT ON (lot.entitlement_event_id)
               lot.entitlement_event_id,lot.stock_reservation_id,lot.beneficiary_analysis_id,
               lot.beneficiary_analysis_material_id,lot.source_exact_peg_id,lot.reallocation_id,
               reservation.warehouse_id,reservation.goods_id,reservation.color_id,
               LEAST(lot.remaining_qty,reservation.qty-reservation.consumed_qty-reservation.released_qty) AS remaining_qty
        FROM application_ranges child
        JOIN v_preplan_stock_entitlement_lot_balance lot
          ON lot.beneficiary_analysis_id=child.analysis_id AND lot.beneficiary_analysis_material_id=child.material_id
          AND lot.remaining_qty>0
        JOIN stock_reservations reservation ON reservation.id=lot.stock_reservation_id
          AND reservation.owner_type='PREPLAN_ANALYSIS' AND reservation.status=0 AND NOT reservation.is_deleted
          AND reservation.goods_id=child.component_goods_id AND reservation.color_id IS NOT DISTINCT FROM child.color_id
          AND reservation.qty-reservation.consumed_qty-reservation.released_qty>0
        JOIN warehouses warehouse ON warehouse.id=reservation.warehouse_id
          AND NOT warehouse.is_deleted AND NOT warehouse.is_defective AND NOT warehouse.is_line_side
          AND fn_warehouse_is_operational_leaf(warehouse.id)
        ORDER BY lot.entitlement_event_id
    ), lot_ranges AS (
        SELECT lot.*,
               SUM(remaining_qty) OVER(PARTITION BY beneficiary_analysis_material_id ORDER BY entitlement_event_id)
                   -remaining_qty AS range_start,
               SUM(remaining_qty) OVER(PARTITION BY beneficiary_analysis_material_id ORDER BY entitlement_event_id) AS range_end
        FROM source_lots lot
    )
    -- A single owned lot may cover several applications of the same parent.
    -- Intersect disjoint capacity and stock intervals, rather than duplicating
    -- the lot or allowing the first application to hide the later ones.
    SELECT child.application_item_id,lot.entitlement_event_id,lot.stock_reservation_id,
           lot.beneficiary_analysis_id,lot.beneficiary_analysis_material_id,lot.source_exact_peg_id,
           lot.reallocation_id,lot.warehouse_id,lot.goods_id,lot.color_id,
           LEAST(child.range_end,lot.range_end)-GREATEST(child.range_start,lot.range_start),
           child.parent_material_id
    FROM application_ranges child JOIN lot_ranges lot
      ON lot.beneficiary_analysis_material_id=child.material_id
      AND child.range_start<lot.range_end AND lot.range_start<child.range_end
    ORDER BY child.material_id,child.application_item_id,lot.entitlement_event_id
$$;

CREATE FUNCTION fn_subcontract_component_available_stock(p_application_item_id UUID,p_order_item_id UUID)
RETURNS TABLE(warehouse_id UUID,goods_id UUID,color_id UUID,available_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH target AS (
        SELECT app.goods_id, app.color_id FROM subcontract_application_items app
        WHERE app.id=p_application_item_id AND p_order_item_id IS NULL AND NOT app.is_deleted
        UNION ALL
        SELECT item.goods_id,item.color_id FROM subcontract_order_items item
        WHERE item.id=p_order_item_id AND NOT item.is_deleted
    ), component AS (
        SELECT edge.component_goods_id AS goods_id,edge.color_id
        FROM target JOIN goods_bom_items edge ON edge.goods_id=target.goods_id AND NOT edge.is_deleted
        WHERE fn_subcontract_sole_component_goods(target.goods_id)
    ), owned AS (
        SELECT lot.warehouse_id,lot.goods_id,lot.color_id,SUM(lot.remaining_qty) AS qty
        FROM fn_subcontract_component_entitled_lots(p_application_item_id,p_order_item_id) lot
        GROUP BY lot.warehouse_id,lot.goods_id,lot.color_id
    )
    SELECT stock.warehouse_id,stock.goods_id,stock.color_id,
           GREATEST(stock.available_qty+COALESCE(owned.qty,0),0)
    FROM component JOIN v_stock_available stock ON stock.goods_id=component.goods_id
      AND stock.color_id IS NOT DISTINCT FROM component.color_id
    JOIN warehouses warehouse ON warehouse.id=stock.warehouse_id
      AND NOT warehouse.is_deleted AND NOT warehouse.is_defective AND NOT warehouse.is_line_side
      AND fn_warehouse_is_operational_leaf(warehouse.id)
    LEFT JOIN owned ON owned.warehouse_id=stock.warehouse_id AND owned.goods_id=stock.goods_id
      AND owned.color_id IS NOT DISTINCT FROM stock.color_id
$$;

-- Each owned lot has its own outbound reservation. Its source is never rewritten
-- and is never released to the public pool between the two custody entries.
CREATE FUNCTION fn_subcontract_take_component_entitlements(
    p_plan_item UUID,p_issue UUID,p_warehouse UUID,p_qty NUMERIC,p_actor UUID)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
    plan_item subcontract_material_plan_items%ROWTYPE;
    lot RECORD; source stock_reservations%ROWTYPE;
    take_qty NUMERIC; remaining NUMERIC:=p_qty;
    target_id UUID; release_id UUID; handoff_id UUID; balance_id UUID;
BEGIN
    SELECT * INTO STRICT plan_item FROM subcontract_material_plan_items
      WHERE id=p_plan_item AND flow_mode='COMPONENT_OUTBOUND' AND NOT is_deleted FOR UPDATE;
    IF p_qty<=0 OR p_actor IS NULL OR NOT EXISTS(
        SELECT 1 FROM subcontract_material_issues issue JOIN subcontract_material_issue_items item ON item.issue_id=issue.id
        WHERE issue.id=p_issue AND issue.status=0 AND NOT issue.is_deleted
          AND issue.warehouse_id=p_warehouse AND item.plan_item_id=p_plan_item AND NOT item.is_deleted AND item.qty=p_qty
    ) THEN RAISE EXCEPTION 'invalid component custody handoff' USING ERRCODE='23514'; END IF;
    SELECT id INTO STRICT balance_id FROM stock_balances
      WHERE warehouse_id=p_warehouse AND goods_id=plan_item.goods_id
        AND color_id IS NOT DISTINCT FROM plan_item.color_id;
    FOR lot IN SELECT * FROM fn_subcontract_component_entitled_lots(NULL,plan_item.order_item_id)
               WHERE warehouse_id=p_warehouse ORDER BY entitlement_event_id LOOP
        EXIT WHEN remaining<=0;
        PERFORM 1 FROM preplan_stock_entitlement_events WHERE id=lot.entitlement_event_id FOR UPDATE;
        SELECT * INTO STRICT source FROM stock_reservations WHERE id=lot.stock_reservation_id FOR UPDATE;
        take_qty:=LEAST(remaining,lot.remaining_qty,source.qty-source.consumed_qty-source.released_qty);
        IF take_qty<=0 OR source.status<>0 THEN CONTINUE; END IF;
        handoff_id:=gen_random_uuid(); target_id:=gen_random_uuid(); release_id:=gen_random_uuid();
        INSERT INTO preplan_stock_entitlement_events(id,event_group_id,stock_reservation_id,
            beneficiary_analysis_id,beneficiary_analysis_material_id,event_type,qty,
            source_entitlement_event_id,reallocation_id,idempotency_key,created_by)
        VALUES(release_id,handoff_id,source.id,lot.beneficiary_analysis_id,lot.beneficiary_analysis_material_id,
            'RELEASE',take_qty,lot.entitlement_event_id,lot.reallocation_id,'SC-COMPONENT-OUT:'||handoff_id,p_actor);
        UPDATE stock_reservations SET released_qty=released_qty+take_qty,
            status=CASE WHEN consumed_qty+released_qty+take_qty=qty THEN 1 ELSE 0 END,
            release_reason='TRANSFERRED_TO_SUBCONTRACT',lock_version=lock_version+1,updated_at=now(),updated_by=p_actor
        WHERE id=source.id;
        INSERT INTO stock_reservations(id,goods_id,color_id,warehouse_id,qty,consumed_qty,released_qty,status,source,
            source_doc_type,source_doc_id,owner_type,owner_id,purpose,supply_type,supply_id,idempotency_key,created_by,updated_by)
        VALUES(target_id,source.goods_id,source.color_id,p_warehouse,take_qty,0,0,0,0,
            'SUBCONTRACT_OUTBOUND_DRAFT',p_issue,'SUBCONTRACT_OUTBOUND',p_plan_item,'SUBCONTRACT_OUTBOUND',
            'STOCK_BALANCE',balance_id,'SC-COMPONENT-STOCK:'||handoff_id,p_actor,p_actor);
        INSERT INTO subcontract_component_stock_handoffs(id,plan_item_id,application_item_id,parent_material_id,child_material_id,
            source_entitlement_event_id,source_reservation_id,target_reservation_id,release_event_id,qty,created_by)
        VALUES(handoff_id,p_plan_item,lot.application_item_id,lot.parent_material_id,lot.beneficiary_analysis_material_id,
            lot.entitlement_event_id,source.id,target_id,release_id,take_qty,p_actor);
        remaining:=remaining-take_qty;
    END LOOP;
    RETURN p_qty-remaining;
END $$;

-- Draft replace/delete, order reversal and unused plan closure all release
-- outbound reservations through the same stock table. Restore the exact owner
-- here so none of those callers can silently turn planned supply into public stock.
CREATE FUNCTION fn_restore_subcontract_component_entitlement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE handoff subcontract_component_stock_handoffs%ROWTYPE; origin preplan_stock_entitlement_events%ROWTYPE;
BEGIN
    IF NEW.owner_type<>'SUBCONTRACT_OUTBOUND' OR NEW.released_qty<=OLD.released_qty THEN RETURN NEW; END IF;
    SELECT * INTO handoff FROM subcontract_component_stock_handoffs WHERE target_reservation_id=NEW.id;
    IF NOT FOUND THEN RETURN NEW; END IF;
    IF NEW.consumed_qty<>0 OR NEW.released_qty<>NEW.qty THEN
        RAISE EXCEPTION 'component custody must be released as its unconsumed issue slice' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM preplan_stock_entitlement_events WHERE event_type='RESTORE' AND counter_event_id=handoff.release_event_id)
      THEN RETURN NEW; END IF;
    SELECT * INTO STRICT origin FROM preplan_stock_entitlement_events WHERE id=handoff.source_entitlement_event_id;
    UPDATE stock_reservations SET released_qty=released_qty-handoff.qty,status=0,
        release_reason=CASE WHEN released_qty=handoff.qty THEN NULL ELSE release_reason END,
        lock_version=lock_version+1,updated_at=now(),updated_by=COALESCE(NEW.updated_by,handoff.created_by)
    WHERE id=handoff.source_reservation_id AND released_qty>=handoff.qty AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'original component custody cannot be restored' USING ERRCODE='23514'; END IF;
    INSERT INTO preplan_stock_entitlement_events(id,event_group_id,stock_reservation_id,
        beneficiary_analysis_id,beneficiary_analysis_material_id,event_type,qty,reallocation_id,
        source_exact_peg_id,counter_event_id,idempotency_key,created_by)
    VALUES(gen_random_uuid(),handoff.id,handoff.source_reservation_id,origin.beneficiary_analysis_id,
        origin.beneficiary_analysis_material_id,'RESTORE',handoff.qty,origin.reallocation_id,
        origin.source_exact_peg_id,handoff.release_event_id,'SC-COMPONENT-RESTORE:'||handoff.id,
        COALESCE(NEW.updated_by,handoff.created_by));
    RETURN NEW;
END $$;
CREATE TRIGGER trg_restore_subcontract_component_entitlement AFTER UPDATE ON stock_reservations
FOR EACH ROW EXECUTE FUNCTION fn_restore_subcontract_component_entitlement();

CREATE FUNCTION fn_guard_subcontract_component_handoff() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE target stock_reservations%ROWTYPE; source stock_reservations%ROWTYPE;
        release_event preplan_stock_entitlement_events%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'component custody facts are immutable' USING ERRCODE='23514'; END IF;
    SELECT * INTO STRICT target FROM stock_reservations WHERE id=NEW.target_reservation_id;
    SELECT * INTO STRICT source FROM stock_reservations WHERE id=NEW.source_reservation_id;
    SELECT * INTO STRICT release_event FROM preplan_stock_entitlement_events WHERE id=NEW.release_event_id;
    IF target.owner_type<>'SUBCONTRACT_OUTBOUND' OR target.owner_id<>NEW.plan_item_id
       OR target.qty<>NEW.qty OR target.consumed_qty<>0 OR target.released_qty<>0 OR target.status<>0
       OR target.goods_id<>source.goods_id OR target.color_id IS DISTINCT FROM source.color_id
       OR target.warehouse_id<>source.warehouse_id OR source.owner_type<>'PREPLAN_ANALYSIS'
       OR release_event.event_type<>'RELEASE' OR release_event.qty<>NEW.qty
       OR release_event.stock_reservation_id<>source.id
       OR release_event.source_entitlement_event_id<>NEW.source_entitlement_event_id
       OR release_event.event_group_id<>NEW.id THEN
        RAISE EXCEPTION 'invalid exact component custody bridge' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_subcontract_component_handoff BEFORE INSERT OR UPDATE OR DELETE
ON subcontract_component_stock_handoffs FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_component_handoff();

CREATE FUNCTION fn_assert_subcontract_component_handoff_balance() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE bridge RECORD; selected_id UUID; counter_id UUID;
BEGIN
    IF TG_TABLE_NAME='subcontract_component_stock_handoffs' THEN selected_id:=NEW.target_reservation_id;
    ELSIF TG_TABLE_NAME='stock_reservations' THEN selected_id:=NEW.id;
    ELSE counter_id:=NEW.counter_event_id; END IF;
    FOR bridge IN SELECT handoff.*,target.qty AS target_qty,target.released_qty AS target_released,
        target.is_deleted AS target_deleted,
        COALESCE((SELECT SUM(event.qty) FROM preplan_stock_entitlement_events event
          WHERE event.event_type='RESTORE' AND event.counter_event_id=handoff.release_event_id),0) AS restored
      FROM subcontract_component_stock_handoffs handoff
      JOIN stock_reservations target ON target.id=handoff.target_reservation_id
      WHERE selected_id IS NOT NULL AND target.id=selected_id
         OR counter_id IS NOT NULL AND handoff.release_event_id=counter_id
    LOOP
      IF bridge.target_deleted OR bridge.target_qty<>bridge.qty
         OR bridge.qty-bridge.restored<>bridge.target_qty-bridge.target_released THEN
        RAISE EXCEPTION 'component handoff and outbound reservation must conserve quantity' USING ERRCODE='23514';
      END IF;
    END LOOP;
    RETURN NEW;
END $$;
CREATE CONSTRAINT TRIGGER trg_component_handoff_balance AFTER INSERT ON subcontract_component_stock_handoffs
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_subcontract_component_handoff_balance();
CREATE CONSTRAINT TRIGGER trg_component_handoff_target_balance AFTER INSERT OR UPDATE ON stock_reservations
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_subcontract_component_handoff_balance();
CREATE CONSTRAINT TRIGGER trg_component_handoff_restore_balance AFTER INSERT ON preplan_stock_entitlement_events
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_subcontract_component_handoff_balance();

DO $reset_policy$
DECLARE definition TEXT; needle TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V646 business reset contract changed';
    END IF;
    EXECUTE replace(definition,needle,needle || E',\n            (''subcontract_component_stock_handoffs'', ''CLEAR'')');
END;
$reset_policy$;

-- Immutable custody identity and exact parent-child lineage.
-- A frozen custody bridge must keep referring to the same physical source and owner.
-- Quantities consumed/released remain mutable through normal issue/reverse/restore flows.
CREATE FUNCTION fn_guard_subcontract_component_reservation_identity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE is_target BOOLEAN; is_source BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM subcontract_component_stock_handoffs WHERE target_reservation_id=OLD.id),
           EXISTS(SELECT 1 FROM subcontract_component_stock_handoffs WHERE source_reservation_id=OLD.id)
      INTO is_target,is_source;
    IF NOT is_target AND NOT is_source THEN
        IF TG_OP='DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'subcontract component custody source history cannot be deleted'
            USING ERRCODE='23514',CONSTRAINT='subcontract_component_reservation_identity';
    END IF;
    IF ROW(NEW.owner_type,NEW.owner_id,NEW.purpose,NEW.supply_type,NEW.supply_id,
           NEW.source,NEW.source_doc_type,NEW.source_doc_id,NEW.order_item_id,NEW.demand_id,
           NEW.goods_id,NEW.color_id,NEW.warehouse_id,NEW.is_deleted)
       IS DISTINCT FROM
       ROW(OLD.owner_type,OLD.owner_id,OLD.purpose,OLD.supply_type,OLD.supply_id,
           OLD.source,OLD.source_doc_type,OLD.source_doc_id,OLD.order_item_id,OLD.demand_id,
           OLD.goods_id,OLD.color_id,OLD.warehouse_id,OLD.is_deleted)
       OR (is_target AND NEW.qty IS DISTINCT FROM OLD.qty) THEN
        RAISE EXCEPTION 'subcontract component custody source identity is immutable; release and restore the original slice'
            USING ERRCODE='23514',CONSTRAINT='subcontract_component_reservation_identity';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_subcontract_component_reservation_identity
BEFORE UPDATE OR DELETE ON stock_reservations
FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_component_reservation_identity();

-- Check the exact parent-child path at the write boundary as well as in lot selection.
-- The RELEASE event has already consumed this positive lot by the time the bridge is
-- inserted; testing remaining_qty > 0 here would reject a legitimate full transfer.
CREATE FUNCTION fn_guard_subcontract_component_handoff_lineage()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM subcontract_material_plan_items plan_item
        JOIN subcontract_order_items order_item ON order_item.id=plan_item.order_item_id
          AND NOT order_item.is_deleted
        JOIN subcontract_order_item_sources order_source ON order_source.order_item_id=order_item.id
          AND order_source.application_item_id=NEW.application_item_id AND order_source.alloc_qty>0
        JOIN subcontract_application_items application ON application.id=order_source.application_item_id
          AND NOT application.is_deleted AND application.goods_id=order_item.goods_id
          AND application.color_id IS NOT DISTINCT FROM order_item.color_id
        JOIN production_material_analysis_materials parent ON parent.id=NEW.parent_material_id
          AND parent.active AND parent.goods_id=application.goods_id
          AND parent.color_id IS NOT DISTINCT FROM application.color_id
        JOIN production_material_analysis_materials child ON child.id=NEW.child_material_id
          AND child.active AND child.analysis_id=parent.analysis_id
          AND child.analysis_item_id=parent.analysis_item_id AND child.parent_node_key=parent.node_key
        JOIN goods_bom_items edge ON edge.id=child.bom_item_id AND NOT edge.is_deleted
          AND edge.goods_id=parent.goods_id AND edge.component_goods_id=child.goods_id
          AND edge.color_id IS NOT DISTINCT FROM child.color_id
        JOIN preplan_supply_action_allocations allocation ON allocation.analysis_id=parent.analysis_id
          AND allocation.analysis_material_id=parent.id AND allocation.allocated_qty>0
        JOIN preplan_supply_actions action ON action.id=allocation.action_id
          AND action.analysis_id=parent.analysis_id AND action.route='SUBCONTRACT' AND action.status<>'CANCELLED'
          AND action.external_document_type='SUBCONTRACT_APPLICATION'
          AND action.external_document_id=application.application_id
          AND (allocation.external_item_id=application.id OR action.public_surplus_external_item_id=application.id)
        JOIN preplan_stock_entitlement_events origin ON origin.id=NEW.source_entitlement_event_id
          AND origin.stock_reservation_id=NEW.source_reservation_id
          AND origin.beneficiary_analysis_id=child.analysis_id
          AND origin.beneficiary_analysis_material_id=child.id
        JOIN stock_reservations source ON source.id=origin.stock_reservation_id
          AND source.owner_type='PREPLAN_ANALYSIS' AND NOT source.is_deleted
          AND source.goods_id=child.goods_id AND source.color_id IS NOT DISTINCT FROM child.color_id
        JOIN stock_reservations target ON target.id=NEW.target_reservation_id
          AND target.owner_type='SUBCONTRACT_OUTBOUND' AND target.owner_id=plan_item.id
          AND target.source_doc_type='SUBCONTRACT_OUTBOUND_DRAFT'
          AND target.goods_id=source.goods_id AND target.color_id IS NOT DISTINCT FROM source.color_id
          AND target.warehouse_id=source.warehouse_id
        JOIN subcontract_material_issues issue ON issue.id=target.source_doc_id
          AND issue.status=0 AND NOT issue.is_deleted AND issue.warehouse_id=target.warehouse_id
        JOIN subcontract_material_issue_items issue_item ON issue_item.issue_id=issue.id
          AND issue_item.plan_item_id=plan_item.id AND NOT issue_item.is_deleted
          AND issue_item.qty>=NEW.qty
        WHERE plan_item.id=NEW.plan_item_id AND plan_item.flow_mode='COMPONENT_OUTBOUND'
          AND NOT plan_item.is_deleted AND plan_item.parent_goods_id=parent.goods_id
          AND plan_item.goods_id=child.goods_id AND plan_item.color_id IS NOT DISTINCT FROM child.color_id
          AND plan_item.bom_unit_qty=ROUND(COALESCE(order_item.unit_rate,1)*edge.qty,6)
    ) THEN
        RAISE EXCEPTION 'subcontract component custody must retain the exact application parent and entitled child'
            USING ERRCODE='23514',CONSTRAINT='subcontract_component_handoff_lineage';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_subcontract_component_handoff_lineage
BEFORE INSERT ON subcontract_component_stock_handoffs
FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_component_handoff_lineage();

-- Analysis refresh may recalculate quantities, but historical custody must still
-- identify the same product path and BOM edge after a refresh or cancellation.
CREATE FUNCTION fn_guard_subcontract_component_material_identity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM subcontract_component_stock_handoffs
              WHERE parent_material_id=OLD.id OR child_material_id=OLD.id)
       AND ROW(NEW.analysis_id,NEW.analysis_item_id,NEW.node_key,NEW.parent_node_key,NEW.bom_item_id,
               NEW.goods_id,NEW.color_id,NEW.unit_id)
           IS DISTINCT FROM
           ROW(OLD.analysis_id,OLD.analysis_item_id,OLD.node_key,OLD.parent_node_key,OLD.bom_item_id,
               OLD.goods_id,OLD.color_id,OLD.unit_id) THEN
        RAISE EXCEPTION 'subcontract component custody material path is immutable'
            USING ERRCODE='23514',CONSTRAINT='subcontract_component_material_identity';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_subcontract_component_material_identity
BEFORE UPDATE OF analysis_id,analysis_item_id,node_key,parent_node_key,bom_item_id,goods_id,color_id,unit_id
ON production_material_analysis_materials
FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_component_material_identity();
