-- Preserve all V154/V489/V535 identity, demand, source and physical-stock guards.
-- A public safety buffer belongs to a main warehouse, not each storage location.
DO $patch$
DECLARE original TEXT; patched TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_stock_allocation()'::regprocedure) INTO original;
    patched := replace(original,
        'v_new_open > GREATEST(v_balance.qty - v_other_reserved - v_safety, 0)',
        'v_new_open > GREATEST(v_balance.qty - v_other_reserved, 0)');
    IF patched=original THEN RAISE EXCEPTION 'V538 physical allocation guard source mismatch'; END IF;
    EXECUTE patched;
END $patch$;

-- The normal-warehouse target can contain qualified and public slices. Derive
-- its qualified quantity from immutable provenance, never a caller boolean.
CREATE FUNCTION fn_production_qualified_formal_qty(p_target UUID)
RETURNS NUMERIC LANGUAGE sql STABLE STRICT AS $$
    SELECT COALESCE(SUM(GREATEST(event.qty-COALESCE(restored.qty,0),0)),0)
    FROM stock_reservations target
    JOIN production_material_demands demand ON demand.id=target.demand_id
    JOIN production_plans plan ON plan.id=demand.plan_id
    JOIN preplan_stock_entitlement_events event
      ON event.event_type='FORMALIZE' AND event.target_stock_reservation_id=target.id
     AND event.target_demand_id=demand.id AND event.target_package_id=demand.package_id
     AND event.beneficiary_analysis_id=plan.material_analysis_id
    JOIN stock_reservations source ON source.id=event.stock_reservation_id
      AND source.owner_type='PREPLAN_ANALYSIS' AND NOT source.is_deleted
      AND source.warehouse_id=target.warehouse_id AND source.goods_id=target.goods_id
      AND source.color_id IS NOT DISTINCT FROM target.color_id
      AND fn_preplan_reservation_has_qualified_origin(source.id)
    JOIN preplan_stock_entitlement_events positive ON positive.id=event.source_entitlement_event_id
      AND positive.stock_reservation_id=source.id
      AND positive.beneficiary_analysis_id=event.beneficiary_analysis_id
      AND positive.beneficiary_analysis_material_id=event.beneficiary_analysis_material_id
    JOIN production_material_analysis_materials material ON material.id=event.beneficiary_analysis_material_id
      AND material.analysis_id=event.beneficiary_analysis_id AND material.goods_id=target.goods_id
      AND material.color_id IS NOT DISTINCT FROM target.color_id AND material.unit_id=demand.unit_id
      AND fn_analysis_plan_material_matches(plan.material_analysis_item_id,material.id)
    LEFT JOIN LATERAL (
        SELECT SUM(counter.qty) AS qty FROM preplan_stock_entitlement_events counter
        WHERE counter.event_type='RESTORE' AND counter.counter_event_id=event.id
    ) restored ON TRUE
    WHERE target.id=p_target AND target.owner_type='PRODUCTION_MATERIAL_DEMAND'
      AND demand.goods_id=target.goods_id AND demand.color_id IS NOT DISTINCT FROM target.color_id
$$;

CREATE FUNCTION fn_check_main_warehouse_public_stock_budget()
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
        AND COALESCE(warehouse.status,'')<>'禁用' AND fn_warehouse_main_id(warehouse.id)=main_id
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
      AND COALESCE(warehouse.status,'')<>'禁用' AND fn_warehouse_main_id(warehouse.id)=main_id
      AND NOT EXISTS(SELECT 1 FROM warehouses child WHERE child.parent_id=warehouse.id AND NOT child.is_deleted);
    IF free_public<safety THEN
        RAISE EXCEPTION 'production public allocation exceeds main warehouse safety budget'
            USING ERRCODE='23514',CONSTRAINT='production_main_public_safety_guard';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_main_warehouse_public_stock_budget
    AFTER INSERT OR UPDATE ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (NEW.owner_type='PRODUCTION_MATERIAL_DEMAND')
    EXECUTE FUNCTION fn_check_main_warehouse_public_stock_budget();

COMMENT ON FUNCTION fn_check_main_warehouse_public_stock_budget() IS
    'Public buffer once per main warehouse/goods/color after all physical reservations and qualified FORMALIZE facts; actual cost and custody remain in each leaf.';
