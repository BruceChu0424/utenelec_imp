-- V313: append-only entitlement guards, formal demand bridge conservation and
-- a provable V307-only initialization. Legacy V298 pool reservations remain
-- legacy and are never guessed into a material line.

CREATE UNIQUE INDEX uq_preplan_entitlement_origin_exact
    ON preplan_stock_entitlement_events(source_exact_peg_id)
    WHERE source_exact_peg_id IS NOT NULL
      AND event_type IN ('ORIGIN_IQC', 'ORIGIN_MAKE');

CREATE UNIQUE INDEX uq_preplan_entitlement_restore_counter
    ON preplan_stock_entitlement_events(counter_event_id)
    WHERE event_type = 'RESTORE';

CREATE OR REPLACE FUNCTION fn_guard_preplan_stock_entitlement_event_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'preplan stock entitlement events are append-only'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_guard_preplan_stock_entitlement_event_mutation
    BEFORE UPDATE OR DELETE ON preplan_stock_entitlement_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_stock_entitlement_event_mutation();

CREATE OR REPLACE FUNCTION fn_check_preplan_stock_entitlement_event()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    reservation stock_reservations%ROWTYPE;
    material production_material_analysis_materials%ROWTYPE;
    exact preplan_analysis_stock_exact_pegs%ROWTYPE;
    source_event preplan_stock_entitlement_events%ROWTYPE;
    counter_event preplan_stock_entitlement_events%ROWTYPE;
    reallocation preplan_material_reallocations%ROWTYPE;
    demand production_material_demands%ROWTYPE;
    production_plan production_plans%ROWTYPE;
    target_reservation stock_reservations%ROWTYPE;
    remaining NUMERIC(18,4);
    restored NUMERIC(18,4);
    target_linked NUMERIC(18,4);
BEGIN
    SELECT * INTO reservation
    FROM stock_reservations WHERE id = NEW.stock_reservation_id;
    SELECT * INTO material
    FROM production_material_analysis_materials
    WHERE id = NEW.beneficiary_analysis_material_id;
    IF reservation.id IS NULL
       OR reservation.owner_type <> 'PREPLAN_ANALYSIS'
       OR reservation.purpose <> 'PREPLAN_MATERIAL'
       OR reservation.is_deleted IS DISTINCT FROM FALSE
       OR material.id IS NULL
       OR material.analysis_id <> NEW.beneficiary_analysis_id
       OR material.goods_id <> reservation.goods_id
       OR material.color_id IS DISTINCT FROM reservation.color_id THEN
        RAISE EXCEPTION 'entitlement beneficiary/dimension invalid'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.reallocation_id IS NOT NULL THEN
        SELECT * INTO reallocation
        FROM preplan_material_reallocations WHERE id = NEW.reallocation_id;
        IF reallocation.id IS NULL
           OR reallocation.warehouse_id <> reservation.warehouse_id
           OR reallocation.goods_id <> reservation.goods_id
           OR reallocation.color_id IS DISTINCT FROM reservation.color_id
           OR reallocation.unit_id <> material.unit_id THEN
            RAISE EXCEPTION 'entitlement reallocation dimension invalid'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF NEW.event_type IN ('ORIGIN_IQC', 'ORIGIN_MAKE') THEN
        SELECT * INTO exact
        FROM preplan_analysis_stock_exact_pegs WHERE id = NEW.source_exact_peg_id;
        IF NEW.source_entitlement_event_id IS NOT NULL
           OR NEW.reallocation_id IS NOT NULL
           OR NEW.counter_event_id IS NOT NULL
           OR exact.id IS NULL
           OR exact.stock_reservation_id <> NEW.stock_reservation_id
           OR exact.origin_analysis_id <> NEW.beneficiary_analysis_id
           OR exact.origin_analysis_material_id
                <> NEW.beneficiary_analysis_material_id
           OR NEW.qty > exact.qty
           OR NEW.qty > GREATEST(
                reservation.qty - reservation.consumed_qty
                    - reservation.released_qty, 0)
           OR NEW.source_receipt_type
                IS DISTINCT FROM exact.source_receipt_type
           OR NEW.source_receipt_id
                IS DISTINCT FROM exact.source_receipt_id
           OR NEW.source_disposition_event_id
                IS DISTINCT FROM exact.source_disposition_event_id
           OR NEW.source_stock_document_id
                IS DISTINCT FROM exact.source_stock_document_id
           OR NEW.source_stock_document_item_id
                IS DISTINCT FROM exact.source_stock_document_item_id
           OR (NEW.event_type = 'ORIGIN_IQC'
               AND exact.source_receipt_type NOT IN ('PURCHASE', 'SUBCONTRACT'))
           OR (NEW.event_type = 'ORIGIN_MAKE'
               AND exact.source_receipt_type IS DISTINCT FROM 'MAKE')
           OR NEW.target_package_id IS NOT NULL
           OR NEW.target_demand_id IS NOT NULL
           OR NEW.target_stock_reservation_id IS NOT NULL THEN
            RAISE EXCEPTION 'invalid entitlement origin'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.source_receipt_type IS NOT NULL
       OR NEW.source_receipt_id IS NOT NULL
       OR NEW.source_disposition_event_id IS NOT NULL
       OR NEW.source_stock_document_id IS NOT NULL
       OR NEW.source_stock_document_item_id IS NOT NULL THEN
        RAISE EXCEPTION 'derived entitlement must follow source lot'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.source_entitlement_event_id IS NOT NULL THEN
        SELECT * INTO source_event
        FROM preplan_stock_entitlement_events
        WHERE id = NEW.source_entitlement_event_id
        FOR UPDATE;
        SELECT source_event.qty - COALESCE(SUM(used.qty), 0)
        INTO remaining
        FROM preplan_stock_entitlement_events used
        WHERE used.source_entitlement_event_id = source_event.id
          AND used.event_type IN (
              'REALLOCATE_OUT', 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
        GROUP BY source_event.qty;
        remaining := COALESCE(remaining, source_event.qty);
        IF source_event.id IS NULL
           OR source_event.event_type NOT IN (
                'ORIGIN_IQC', 'ORIGIN_MAKE', 'REALLOCATE_IN',
                'PRIORITY_IN', 'RESTORE')
           OR source_event.stock_reservation_id <> NEW.stock_reservation_id
           OR source_event.beneficiary_analysis_id
                <> NEW.beneficiary_analysis_id
           OR source_event.beneficiary_analysis_material_id
                <> NEW.beneficiary_analysis_material_id
           OR NEW.qty > remaining THEN
            RAISE EXCEPTION 'event exceeds source entitlement lot'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.counter_event_id IS NOT NULL THEN
        SELECT * INTO counter_event
        FROM preplan_stock_entitlement_events
        WHERE id = NEW.counter_event_id
        FOR UPDATE;
    END IF;

    IF NEW.event_type = 'REALLOCATE_OUT' THEN
        IF source_event.id IS NULL
           OR reallocation.id IS NULL
           OR NEW.counter_event_id IS NOT NULL
           OR NEW.beneficiary_analysis_id <> reallocation.from_analysis_id
           OR NEW.beneficiary_analysis_material_id
                <> reallocation.from_analysis_material_id THEN
            RAISE EXCEPTION 'invalid REALLOCATE_OUT' USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'REALLOCATE_IN' THEN
        IF NEW.source_entitlement_event_id IS NOT NULL
           OR reallocation.id IS NULL
           OR counter_event.id IS NULL
           OR counter_event.event_type <> 'REALLOCATE_OUT'
           OR counter_event.reallocation_id <> NEW.reallocation_id
           OR counter_event.stock_reservation_id <> NEW.stock_reservation_id
           OR counter_event.event_group_id <> NEW.event_group_id
           OR counter_event.qty <> NEW.qty
           OR NEW.beneficiary_analysis_id <> reallocation.to_analysis_id
           OR NEW.beneficiary_analysis_material_id
                <> reallocation.to_analysis_material_id
           OR NEW.source_exact_peg_id IS DISTINCT FROM (
                SELECT source_exact_peg_id
                FROM preplan_stock_entitlement_events
                WHERE id = counter_event.source_entitlement_event_id) THEN
            RAISE EXCEPTION 'invalid REALLOCATE_IN' USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'PRIORITY_OUT' THEN
        IF source_event.id IS NULL
           OR reallocation.id IS NULL
           OR NEW.counter_event_id IS NOT NULL
           OR NEW.beneficiary_analysis_id <> reallocation.to_analysis_id
           OR NEW.beneficiary_analysis_material_id
                <> reallocation.to_analysis_material_id THEN
            RAISE EXCEPTION 'invalid PRIORITY_OUT' USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'PRIORITY_IN' THEN
        IF NEW.source_entitlement_event_id IS NOT NULL
           OR reallocation.id IS NULL
           OR counter_event.id IS NULL
           OR counter_event.event_type <> 'PRIORITY_OUT'
           OR counter_event.reallocation_id <> NEW.reallocation_id
           OR counter_event.stock_reservation_id <> NEW.stock_reservation_id
           OR counter_event.event_group_id <> NEW.event_group_id
           OR counter_event.qty <> NEW.qty
           OR NEW.beneficiary_analysis_id <> reallocation.from_analysis_id
           OR NEW.beneficiary_analysis_material_id
                <> reallocation.from_analysis_material_id
           OR NEW.source_exact_peg_id IS DISTINCT FROM (
                SELECT source_exact_peg_id
                FROM preplan_stock_entitlement_events
                WHERE id = counter_event.source_entitlement_event_id) THEN
            RAISE EXCEPTION 'invalid PRIORITY_IN' USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'PRIORITY_SATISFIED_IN_PLACE' THEN
        IF source_event.id IS NULL
           OR reallocation.id IS NULL
           OR NEW.counter_event_id IS NOT NULL
           OR NEW.source_exact_peg_id IS NOT NULL
           OR NEW.beneficiary_analysis_id <> reallocation.from_analysis_id
           OR NEW.beneficiary_analysis_material_id
                <> reallocation.from_analysis_material_id THEN
            RAISE EXCEPTION 'invalid priority satisfaction'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'FORMALIZE' THEN
        SELECT * INTO demand
        FROM production_material_demands WHERE id = NEW.target_demand_id;
        SELECT * INTO production_plan
        FROM production_plans WHERE id = demand.plan_id;
        SELECT * INTO target_reservation
        FROM stock_reservations WHERE id = NEW.target_stock_reservation_id;
        SELECT COALESCE(SUM(link.qty), 0)
        INTO target_linked
        FROM preplan_stock_entitlement_events link
        WHERE link.event_type = 'FORMALIZE'
          AND link.target_stock_reservation_id = NEW.target_stock_reservation_id;
        IF source_event.id IS NULL
           OR NEW.counter_event_id IS NOT NULL
           OR NEW.source_exact_peg_id IS NOT NULL
           OR NEW.target_package_id IS NULL
           OR demand.id IS NULL
           OR target_reservation.id IS NULL
           OR production_plan.id IS NULL
           OR demand.package_id <> NEW.target_package_id
           OR demand.is_deleted IS DISTINCT FROM FALSE
           OR demand.warehouse_id <> reservation.warehouse_id
           OR production_plan.is_deleted IS DISTINCT FROM FALSE
           OR production_plan.material_analysis_id
                IS DISTINCT FROM NEW.beneficiary_analysis_id
           OR production_plan.material_analysis_item_id
                IS DISTINCT FROM material.analysis_item_id
           OR demand.goods_id <> reservation.goods_id
           OR demand.color_id IS DISTINCT FROM reservation.color_id
           OR demand.unit_id <> material.unit_id
           OR target_reservation.owner_type <> 'PRODUCTION_MATERIAL_DEMAND'
           OR target_reservation.owner_id <> demand.id
           OR target_reservation.demand_id <> demand.id
           OR target_reservation.purpose <> 'PRODUCTION_MATERIAL'
           OR target_reservation.warehouse_id <> reservation.warehouse_id
           OR target_reservation.goods_id <> reservation.goods_id
           OR target_reservation.color_id IS DISTINCT FROM reservation.color_id
           OR target_linked + NEW.qty > target_reservation.qty
           OR target_reservation.consumed_qty <> 0
           OR target_reservation.released_qty <> 0
           OR target_reservation.status <> 0
           OR target_reservation.is_deleted IS DISTINCT FROM FALSE THEN
            RAISE EXCEPTION 'invalid entitlement formal bridge'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'RELEASE' THEN
        IF source_event.id IS NULL
           OR NEW.source_exact_peg_id IS NOT NULL
           OR NEW.target_package_id IS NOT NULL
           OR NEW.target_demand_id IS NOT NULL
           OR NEW.target_stock_reservation_id IS NOT NULL
           OR (NEW.counter_event_id IS NOT NULL
               AND counter_event.event_type <> 'PRIORITY_SATISFIED_IN_PLACE') THEN
            RAISE EXCEPTION 'invalid RELEASE' USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'RESTORE' THEN
        SELECT COALESCE(SUM(restored_event.qty), 0)
        INTO restored
        FROM preplan_stock_entitlement_events restored_event
        WHERE restored_event.counter_event_id = NEW.counter_event_id
          AND restored_event.event_type = 'RESTORE';
        IF NEW.source_entitlement_event_id IS NOT NULL
           OR counter_event.id IS NULL
           OR counter_event.event_type NOT IN (
                'REALLOCATE_OUT', 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
           OR counter_event.stock_reservation_id <> NEW.stock_reservation_id
           OR counter_event.beneficiary_analysis_id
                <> NEW.beneficiary_analysis_id
           OR counter_event.beneficiary_analysis_material_id
                <> NEW.beneficiary_analysis_material_id
           OR NEW.reallocation_id IS DISTINCT FROM counter_event.reallocation_id
           OR NEW.qty <> counter_event.qty
           OR restored <> 0
           OR NEW.source_exact_peg_id IS DISTINCT FROM (
                SELECT source_exact_peg_id
                FROM preplan_stock_entitlement_events
                WHERE id = counter_event.source_entitlement_event_id)
           OR NEW.target_package_id IS NOT NULL
           OR NEW.target_demand_id IS NOT NULL
           OR NEW.target_stock_reservation_id IS NOT NULL THEN
            RAISE EXCEPTION 'invalid RESTORE' USING ERRCODE = '23514';
        END IF;
    ELSE
        RAISE EXCEPTION 'unsupported entitlement event' USING ERRCODE = '23514';
    END IF;

    IF NEW.event_type <> 'FORMALIZE'
       AND (NEW.target_package_id IS NOT NULL
            OR NEW.target_demand_id IS NOT NULL
            OR NEW.target_stock_reservation_id IS NOT NULL) THEN
        RAISE EXCEPTION 'only FORMALIZE has bridge' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_preplan_stock_entitlement_event
    BEFORE INSERT ON preplan_stock_entitlement_events
    FOR EACH ROW EXECUTE FUNCTION fn_check_preplan_stock_entitlement_event();

CREATE OR REPLACE FUNCTION fn_validate_preplan_entitlement_conservation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    reservation_id UUID;
    reservation stock_reservations%ROWTYPE;
    tracked BOOLEAN;
    entitlement_qty NUMERIC(18,4);
    physical_qty NUMERIC(18,4);
    bad UUID;
BEGIN
    IF TG_TABLE_NAME = 'stock_reservations' THEN
        reservation_id := COALESCE(NEW.id, OLD.id);
    ELSE
        reservation_id := COALESCE(NEW.stock_reservation_id, OLD.stock_reservation_id);
    END IF;
    SELECT * INTO reservation
    FROM stock_reservations WHERE id = reservation_id;
    IF reservation.id IS NULL OR reservation.owner_type <> 'PREPLAN_ANALYSIS' THEN
        RETURN NEW;
    END IF;
    SELECT EXISTS(
        SELECT 1 FROM preplan_analysis_stock_exact_pegs exact
        WHERE exact.stock_reservation_id = reservation_id
        UNION ALL
        SELECT 1 FROM preplan_stock_entitlement_events event
        WHERE event.stock_reservation_id = reservation_id
    ) INTO tracked;
    IF NOT tracked THEN RETURN NEW; END IF;
    SELECT entitlement_event_id
    INTO bad
    FROM v_preplan_stock_entitlement_lot_balance
    WHERE stock_reservation_id = reservation_id AND remaining_qty < 0
    ORDER BY entitlement_event_id
    LIMIT 1;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'entitlement lot balance cannot be negative'
            USING ERRCODE = '23514';
    END IF;
    SELECT COALESCE(SUM(remaining_qty), 0)
    INTO entitlement_qty
    FROM v_preplan_stock_entitlement_lot_balance
    WHERE stock_reservation_id = reservation_id;
    physical_qty := CASE
        WHEN reservation.is_deleted = FALSE AND reservation.status = 0
        THEN GREATEST(
            reservation.qty - reservation.consumed_qty
                - reservation.released_qty, 0)
        ELSE 0
    END;
    IF entitlement_qty IS DISTINCT FROM physical_qty THEN
        RAISE EXCEPTION 'entitlement total % must equal physical effective %',
            entitlement_qty, physical_qty
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_entitlement_physical_conservation_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_preplan_entitlement_event_balance
    AFTER INSERT ON preplan_stock_entitlement_events
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_preplan_entitlement_conservation();

CREATE CONSTRAINT TRIGGER trg_validate_preplan_entitlement_reservation_balance
    AFTER INSERT OR UPDATE OR DELETE ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_preplan_entitlement_conservation();

CREATE CONSTRAINT TRIGGER trg_validate_preplan_entitlement_exact_balance
    AFTER INSERT ON preplan_analysis_stock_exact_pegs
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_preplan_entitlement_conservation();

CREATE OR REPLACE FUNCTION fn_validate_preplan_reallocation_event_totals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    reallocation_id UUID;
    header preplan_material_reallocations%ROWTYPE;
    out_qty NUMERIC(18,4);
    in_qty NUMERIC(18,4);
    fulfilled_qty NUMERIC(18,4);
BEGIN
    IF TG_TABLE_NAME = 'preplan_material_reallocations' THEN
        reallocation_id := COALESCE(NEW.id, OLD.id);
    ELSE
        reallocation_id := COALESCE(NEW.reallocation_id, OLD.reallocation_id);
    END IF;
    IF reallocation_id IS NULL THEN RETURN NEW; END IF;
    SELECT * INTO header
    FROM preplan_material_reallocations WHERE id = reallocation_id;
    IF header.id IS NULL THEN RETURN NEW; END IF;
    SELECT COALESCE(SUM(qty), 0) INTO out_qty
    FROM preplan_stock_entitlement_events
    WHERE reallocation_id = header.id AND event_type = 'REALLOCATE_OUT';
    SELECT COALESCE(SUM(qty), 0) INTO in_qty
    FROM preplan_stock_entitlement_events
    WHERE reallocation_id = header.id AND event_type = 'REALLOCATE_IN';
    IF out_qty <> header.qty OR in_qty <> header.qty THEN
        RAISE EXCEPTION 'reallocation OUT/IN totals must equal header quantity'
            USING ERRCODE = '23514';
    END IF;
    SELECT COALESCE(SUM(CASE
               WHEN event.event_type IN (
                    'PRIORITY_IN', 'PRIORITY_SATISFIED_IN_PLACE')
               THEN event.qty
               WHEN event.event_type = 'RESTORE'
                    AND counter.event_type = 'PRIORITY_OUT'
               THEN -event.qty
               WHEN event.event_type = 'RELEASE'
                    AND counter.event_type = 'PRIORITY_SATISFIED_IN_PLACE'
               THEN -event.qty
               ELSE 0
           END), 0)
    INTO fulfilled_qty
    FROM preplan_stock_entitlement_events event
    LEFT JOIN preplan_stock_entitlement_events counter
      ON counter.id = event.counter_event_id
    WHERE event.reallocation_id = header.id;
    IF fulfilled_qty < 0
       OR fulfilled_qty > header.qty
       OR fulfilled_qty IS DISTINCT FROM header.priority_fulfilled_qty THEN
        RAISE EXCEPTION 'priority fulfilled quantity disagrees with events'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_preplan_reallocation_header_totals
    AFTER INSERT OR UPDATE ON preplan_material_reallocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_preplan_reallocation_event_totals();

CREATE CONSTRAINT TRIGGER trg_validate_preplan_reallocation_event_totals
    AFTER INSERT ON preplan_stock_entitlement_events
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_preplan_reallocation_event_totals();

-- Only effective, provably exact V307 rows are initialized. Transferred rows
-- without a formal bridge and all legacy V298 pool rows remain excluded.
INSERT INTO preplan_stock_entitlement_events (
    id, event_group_id, stock_reservation_id,
    beneficiary_analysis_id, beneficiary_analysis_material_id,
    event_type, qty, source_exact_peg_id,
    source_receipt_type, source_receipt_id,
    source_disposition_event_id,
    idempotency_key, created_by, created_at
)
SELECT gen_random_uuid(), gen_random_uuid(), reservation.id,
       exact.origin_analysis_id, exact.origin_analysis_material_id,
       'ORIGIN_IQC',
       GREATEST(
           reservation.qty - reservation.consumed_qty
               - reservation.released_qty, 0),
       exact.id, exact.source_receipt_type, exact.source_receipt_id,
       exact.source_disposition_event_id,
       'ENTITLEMENT-BACKFILL:' || exact.id,
       exact.created_by, exact.created_at
FROM preplan_analysis_stock_exact_pegs exact
JOIN stock_reservations reservation
  ON reservation.id = exact.stock_reservation_id
WHERE exact.source_receipt_type IN ('PURCHASE', 'SUBCONTRACT')
  AND reservation.owner_type = 'PREPLAN_ANALYSIS'
  AND reservation.is_deleted = FALSE
  AND reservation.status = 0
  AND GREATEST(
      reservation.qty - reservation.consumed_qty
          - reservation.released_qty, 0) > 0
  AND NOT EXISTS (
      SELECT 1
      FROM preplan_stock_entitlement_events event
      WHERE event.source_exact_peg_id = exact.id
        AND event.event_type IN ('ORIGIN_IQC', 'ORIGIN_MAKE')
  );

COMMENT ON COLUMN preplan_stock_entitlement_events.source_entitlement_event_id IS
    '负事件唯一消耗的正 entitlement lot；并发写入由源事件行锁串行化';
COMMENT ON COLUMN preplan_stock_entitlement_events.target_stock_reservation_id IS
    'FORMALIZE 建立的正式需求库存预留桥，支持受控逆向恢复';
