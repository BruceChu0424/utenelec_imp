-- A disabled storage location may still contain real stock. Its status must not
-- erase that stock from a main-warehouse budget or prevent consumption of an
-- existing proven allocation. Deleted/unknown/non-accountable/non-leaf locations,
-- other main-warehouse public stock, physical capacity and all source guards remain.
-- No balances, reservations, plans, statuses, source events or costs are rewritten.

CREATE OR REPLACE FUNCTION fn_check_main_warehouse_public_stock_budget()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE target stock_reservations%ROWTYPE; old_committed NUMERIC:=0;
        main_id UUID; free_public NUMERIC; safety NUMERIC; qualified NUMERIC;
BEGIN
    IF NEW.owner_type IS DISTINCT FROM 'PRODUCTION_MATERIAL_DEMAND' THEN RETURN NULL; END IF;
    IF TG_OP='UPDATE' THEN
        old_committed:=CASE WHEN OLD.is_deleted THEN 0 ELSE OLD.qty-OLD.released_qty END;
    END IF;
    -- Consumption/return of already admitted material is still protected by the
    -- original physical/demand checks; it is not a new public allocation.
    IF (CASE WHEN NEW.is_deleted THEN 0 ELSE NEW.qty-NEW.released_qty END) <= old_committed THEN RETURN NULL; END IF;
    SELECT * INTO target FROM stock_reservations WHERE id=NEW.id;
    IF NOT FOUND OR target.is_deleted OR target.qty-target.released_qty<=old_committed THEN RETURN NULL; END IF;
    qualified:=fn_production_qualified_formal_qty(target.id);
    IF qualified>=target.qty-target.released_qty THEN RETURN NULL; END IF;

    SELECT fn_warehouse_main_id(demand.warehouse_id) INTO main_id
    FROM production_material_demands demand WHERE demand.id=target.demand_id;
    IF NOT EXISTS(SELECT 1 FROM warehouses warehouse WHERE warehouse.id=target.warehouse_id
        AND NOT warehouse.is_deleted AND warehouse.is_accountable AND NOT warehouse.is_defective
        AND fn_warehouse_main_id(warehouse.id)=main_id
        AND NOT EXISTS(SELECT 1 FROM warehouses child WHERE child.parent_id=warehouse.id AND NOT child.is_deleted)) THEN
        RAISE EXCEPTION 'public production stock requires a normal leaf in its main warehouse'
            USING ERRCODE='23514',CONSTRAINT='production_main_public_warehouse_guard';
    END IF;
    SELECT GREATEST(COALESCE(goods.min_qty,0)::numeric,0) INTO safety FROM goods WHERE id=target.goods_id;
    SELECT COALESCE(SUM(GREATEST(balance.qty-COALESCE(held.qty,0),0)),0) INTO free_public
    FROM stock_balances balance JOIN warehouses warehouse ON warehouse.id=balance.warehouse_id
    LEFT JOIN LATERAL (
        SELECT SUM(reservation.qty-reservation.consumed_qty-reservation.released_qty) AS qty
        FROM stock_reservations reservation
        WHERE NOT reservation.is_deleted AND reservation.status=0
          AND reservation.goods_id=balance.goods_id AND reservation.color_id IS NOT DISTINCT FROM balance.color_id
          AND (reservation.warehouse_id IS NULL OR reservation.warehouse_id=balance.warehouse_id)
    ) held ON TRUE
    WHERE balance.goods_id=target.goods_id AND balance.color_id IS NOT DISTINCT FROM target.color_id
      AND NOT warehouse.is_deleted AND warehouse.is_accountable AND NOT warehouse.is_defective
      AND fn_warehouse_main_id(warehouse.id)=main_id
      AND NOT EXISTS(SELECT 1 FROM warehouses child WHERE child.parent_id=warehouse.id AND NOT child.is_deleted);
    IF free_public<safety THEN
        RAISE EXCEPTION 'production public allocation exceeds main warehouse safety budget'
            USING ERRCODE='23514',CONSTRAINT='production_main_public_safety_guard';
    END IF;
    RETURN NULL;
END $$;


-- An automatic advance is a system action, never an impersonated employee.
-- Human actors remain required for every other entitlement event.
ALTER TABLE preplan_stock_entitlement_events ADD COLUMN system_reason TEXT;
ALTER TABLE preplan_stock_entitlement_events ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE preplan_stock_entitlement_events ADD CONSTRAINT preplan_entitlement_actor_kind_check CHECK (
    (created_by IS NOT NULL AND system_reason IS NULL)
    OR (created_by IS NULL AND event_type='FORMALIZE' AND system_reason IS NOT NULL
        AND system_reason='AUTOMATIC_READINESS_RECHECK')
);

CREATE FUNCTION fn_guard_system_readiness_formalize_actor()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.created_by IS NOT NULL THEN RETURN NEW; END IF;
    IF NEW.event_type IS DISTINCT FROM 'FORMALIZE'
       OR NEW.system_reason IS DISTINCT FROM 'AUTOMATIC_READINESS_RECHECK'
       OR current_setting('app.production_readiness_reconcile',true) IS DISTINCT FROM 'v1'
       OR NULLIF(current_setting('app.actor_id',true),'') IS NOT NULL
       OR current_setting('app.actor_account',true) IS DISTINCT FROM '系统自动核对备料'
       OR NOT EXISTS (
           SELECT 1 FROM production_material_demands demand
           JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
             AND segment.status='WAITING' AND segment.auto_promote_when_ready AND NOT segment.is_deleted
           JOIN production_planning_packages package ON package.id=demand.package_id
             AND package.id=NEW.target_package_id AND package.status='CONFIRMED'
             AND package.execution_model_version=1 AND NOT package.is_deleted
           JOIN production_plans plan ON plan.id=demand.plan_id AND plan.id=segment.plan_id
             AND plan.status=1 AND NOT plan.is_deleted AND NOT COALESCE(plan.is_closed,FALSE)
             AND NOT COALESCE(plan.is_canceled,FALSE) AND NOT COALESCE(plan.is_stopped,FALSE)
             AND plan.material_analysis_id=NEW.beneficiary_analysis_id
           JOIN stock_reservations target ON target.id=NEW.target_stock_reservation_id
             AND target.demand_id=demand.id AND target.owner_type='PRODUCTION_MATERIAL_DEMAND'
             AND NOT target.is_deleted
           JOIN stock_reservations source ON source.id=NEW.stock_reservation_id
             AND source.owner_type='PREPLAN_ANALYSIS' AND NOT source.is_deleted
             AND source.warehouse_id=target.warehouse_id AND source.goods_id=target.goods_id
             AND source.color_id IS NOT DISTINCT FROM target.color_id
           JOIN preplan_stock_entitlement_events origin ON origin.id=NEW.source_entitlement_event_id
             AND origin.stock_reservation_id=source.id
             AND origin.beneficiary_analysis_id=NEW.beneficiary_analysis_id
             AND origin.beneficiary_analysis_material_id=NEW.beneficiary_analysis_material_id
           WHERE demand.id=NEW.target_demand_id AND NOT demand.is_deleted
             AND fn_analysis_plan_material_matches(plan.material_analysis_item_id,NEW.beneficiary_analysis_material_id)
       ) THEN
        RAISE EXCEPTION 'system FORMALIZE requires the controlled automatic-readiness transaction and exact approved waiting task'
          USING ERRCODE='23514',CONSTRAINT='preplan_system_formalize_actor_guard';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_00_system_readiness_formalize_actor
    BEFORE INSERT OR UPDATE ON preplan_stock_entitlement_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_system_readiness_formalize_actor();
COMMENT ON COLUMN preplan_stock_entitlement_events.system_reason IS
    'Only AUTOMATIC_READINESS_RECHECK permits a null human creator; original source actor, task responsibility and append-only facts remain traceable.';
