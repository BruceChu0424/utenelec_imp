-- Book balances remain original evidence. A master-unit edit cannot establish the
-- measurement basis of an already imported number. Capture that cohort separately.
CREATE TABLE stock_measurement_holds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stock_balance_id UUID NOT NULL REFERENCES stock_balances(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    captured_qty NUMERIC NOT NULL,
    captured_amount_local NUMERIC,
    captured_weight NUMERIC,
    captured_weight_estimated BOOLEAN NOT NULL,
    reason TEXT NOT NULL DEFAULT 'LEGACY_QUANTITY_BASIS_UNPROVEN'
        CHECK (reason = 'LEGACY_QUANTITY_BASIS_UNPROVEN'),
    captured_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    released_at TIMESTAMPTZ,
    verified_unit_id UUID REFERENCES units(id),
    verified_by UUID REFERENCES users(id),
    evidence_reference TEXT,
    evidence_sha256 TEXT,
    resolution_note TEXT,
    UNIQUE NULLS NOT DISTINCT (warehouse_id, goods_id, color_id),
    CHECK ((released_at IS NULL AND verified_unit_id IS NULL AND verified_by IS NULL
            AND evidence_reference IS NULL AND evidence_sha256 IS NULL AND resolution_note IS NULL)
        OR (released_at IS NOT NULL AND verified_unit_id IS NOT NULL AND verified_by IS NOT NULL
            AND length(btrim(evidence_reference)) BETWEEN 1 AND 1000
            AND evidence_sha256 ~ '^[0-9a-f]{64}$'
            AND length(btrim(resolution_note)) BETWEEN 10 AND 2000))
);
CREATE INDEX ix_stock_measurement_holds_pending ON stock_measurement_holds(goods_id, color_id, warehouse_id)
    WHERE released_at IS NULL;
COMMENT ON TABLE stock_measurement_holds IS
    'Persistent unresolved original quantity basis; never subtract, rewrite or delete original book qty/value/weight. Master-unit completion does not release this hold.';

CREATE FUNCTION fn_stock_has_resolved_base_unit(p_goods UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT EXISTS (
        SELECT 1 FROM goods g JOIN units u ON
            (u.id = g.unit_id OR (g.unit_id IS NULL AND u.legacy_id = NULLIF(g.unit_legacy_id, 0)))
        WHERE g.id = p_goods AND NOT g.is_deleted AND NOT COALESCE(g.auto_created, FALSE) AND NOT u.is_deleted
          AND NULLIF(btrim(u.name), '') IS NOT NULL)
$$;

CREATE FUNCTION fn_stock_measurement_usable(p_warehouse UUID, p_goods UUID, p_color UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT fn_stock_has_resolved_base_unit(p_goods) AND NOT EXISTS (
        SELECT 1 FROM stock_measurement_holds h
        WHERE h.goods_id = p_goods AND h.warehouse_id = p_warehouse
          AND h.color_id IS NOT DISTINCT FROM p_color AND h.released_at IS NULL)
$$;

-- Restore-only data copying can run with triggers disabled in an offline owned
-- candidate. The owner MUST call this again after copying and before CONNECT.
CREATE FUNCTION fn_capture_stock_measurement_holds()
RETURNS BIGINT LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE captured BIGINT;
BEGIN
    IF session_user = 'uten' OR NOT pg_has_role(session_user,
        (SELECT relowner FROM pg_class WHERE oid = 'public.stock_measurement_holds'::regclass), 'MEMBER') THEN
        RAISE EXCEPTION 'Only schema maintenance may capture original measurement cohorts' USING ERRCODE = '42501';
    END IF;
    INSERT INTO stock_measurement_holds(stock_balance_id, warehouse_id, goods_id, color_id,
        captured_qty, captured_amount_local, captured_weight, captured_weight_estimated)
    SELECT b.id, b.warehouse_id, b.goods_id, b.color_id, b.qty, b.amount_local, b.weight,
        COALESCE(b.weight_estimated, FALSE)
    FROM stock_balances b
    WHERE (b.qty <> 0 OR COALESCE(b.amount_local, 0) <> 0)
      AND NOT fn_stock_has_resolved_base_unit(b.goods_id)
    ON CONFLICT (warehouse_id, goods_id, color_id) DO NOTHING;
    GET DIAGNOSTICS captured = ROW_COUNT;
    RETURN captured;
END
$$;
REVOKE ALL ON FUNCTION fn_capture_stock_measurement_holds() FROM PUBLIC;
SELECT fn_capture_stock_measurement_holds();

-- Only ORIGINAL basis verification with NO quantity conversion is implemented.
-- This does not fill a master unit, approve a count, change a balance, start value
-- opening, invent physical stock, or post GL. Unknown/rebased quantities require
-- a separately reviewed reconstruction plan; ordinary stock-count differences
-- cannot safely subtract numbers with an unknown original dimension.
CREATE FUNCTION fn_verify_stock_original_measurement_basis(p_hold UUID, p_unit UUID, p_reviewer UUID,
    p_evidence_reference TEXT, p_evidence_sha256 TEXT, p_resolution_note TEXT)
RETURNS VOID LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE held stock_measurement_holds%ROWTYPE; current_balance stock_balances%ROWTYPE;
BEGIN
    IF session_user = 'uten' OR NOT pg_has_role(session_user,
        (SELECT relowner FROM pg_class WHERE oid = 'public.stock_measurement_holds'::regclass), 'MEMBER') THEN
        RAISE EXCEPTION 'Original quantity basis verification requires reviewed schema maintenance' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO STRICT held FROM stock_measurement_holds WHERE id = p_hold FOR UPDATE;
    IF held.released_at IS NOT NULL THEN
        RAISE EXCEPTION 'Original quantity basis has already been verified' USING ERRCODE = '23514';
    END IF;
    PERFORM 1 FROM goods g JOIN units u ON u.id = g.unit_id
        WHERE g.id = held.goods_id AND g.unit_id = p_unit AND NOT g.is_deleted
          AND NOT COALESCE(g.auto_created, FALSE) AND NOT u.is_deleted AND NULLIF(btrim(u.name), '') IS NOT NULL
        FOR UPDATE OF g;
    IF NOT FOUND OR p_reviewer IS NULL OR p_evidence_reference IS NULL
        OR length(btrim(p_evidence_reference)) NOT BETWEEN 1 AND 1000
        OR p_evidence_sha256 IS NULL OR p_evidence_sha256 !~ '^[0-9a-f]{64}$'
        OR p_resolution_note IS NULL OR length(btrim(p_resolution_note)) NOT BETWEEN 10 AND 2000 THEN
        RAISE EXCEPTION 'Require verified real master, unchanged original unit basis, reviewer and immutable evidence' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT current_balance FROM stock_balances WHERE id = held.stock_balance_id FOR UPDATE;
    IF (current_balance.warehouse_id, current_balance.goods_id, current_balance.color_id,
        current_balance.qty, current_balance.amount_local, current_balance.weight, current_balance.weight_estimated)
        IS DISTINCT FROM (held.warehouse_id, held.goods_id, held.color_id,
        held.captured_qty, held.captured_amount_local, held.captured_weight, held.captured_weight_estimated) THEN
        RAISE EXCEPTION 'Original balance changed; a quantity reconstruction review is required' USING ERRCODE = '23514';
    END IF;
    UPDATE stock_measurement_holds SET released_at = now(), verified_unit_id = p_unit, verified_by = p_reviewer,
        evidence_reference = btrim(p_evidence_reference), evidence_sha256 = p_evidence_sha256,
        resolution_note = btrim(p_resolution_note) WHERE id = p_hold;
END
$$;
REVOKE ALL ON FUNCTION fn_verify_stock_original_measurement_basis(UUID, UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC;

CREATE FUNCTION fn_guard_stock_measurement_hold_evidence()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
    IF session_user = 'uten' OR TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Original stock measurement evidence is maintenance-only and cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'UPDATE' AND (OLD.id, OLD.stock_balance_id, OLD.warehouse_id, OLD.goods_id, OLD.color_id,
        OLD.captured_qty, OLD.captured_amount_local, OLD.captured_weight, OLD.captured_weight_estimated, OLD.reason, OLD.captured_at)
        IS DISTINCT FROM (NEW.id, NEW.stock_balance_id, NEW.warehouse_id, NEW.goods_id, NEW.color_id,
        NEW.captured_qty, NEW.captured_amount_local, NEW.captured_weight, NEW.captured_weight_estimated, NEW.reason, NEW.captured_at) THEN
        RAISE EXCEPTION 'Original stock measurement snapshot is immutable' USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.released_at IS NOT NULL AND OLD IS DISTINCT FROM NEW THEN
        RAISE EXCEPTION 'Verified measurement evidence is immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER trg_stock_measurement_hold_evidence BEFORE INSERT OR UPDATE OR DELETE ON stock_measurement_holds
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_measurement_hold_evidence();
ALTER TABLE stock_measurement_holds ENABLE ALWAYS TRIGGER trg_stock_measurement_hold_evidence;
CREATE FUNCTION fn_guard_stock_measurement_hold_truncate()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Original stock measurement evidence cannot be truncated' USING ERRCODE = '23514';
END
$$;
CREATE TRIGGER trg_stock_measurement_hold_truncate BEFORE TRUNCATE ON stock_measurement_holds
    FOR EACH STATEMENT EXECUTE FUNCTION fn_guard_stock_measurement_hold_truncate();

-- Preserve the balance row shape for operational allocation readers which also
-- need its physical ID. Ledger/report/instant-inventory readers keep the raw table.
CREATE VIEW v_stock_operable_balances AS
SELECT b.* FROM stock_balances b
WHERE fn_stock_measurement_usable(b.warehouse_id, b.goods_id, b.color_id);

-- Keep every intervening workflow patch. Only replace the one physical-supply
-- relation in each verified read function; stop if its authoritative shape drifts.
DO $supply_readers$
DECLARE target TEXT; definition TEXT; updated TEXT; occurrences INT;
BEGIN
    FOREACH target IN ARRAY ARRAY[
        'fn_demand_has_direct_supply_on_hand(uuid)',
        'fn_execution_start_material_ready_before_discovery(uuid)',
        'fn_workshop_material_bin_position(uuid)'] LOOP
        definition := pg_get_functiondef(target::regprocedure);
        occurrences := (length(definition) - length(replace(definition, 'stock_balances', ''))) / length('stock_balances');
        IF occurrences <> 1 THEN
            RAISE EXCEPTION 'V928: % expected one physical supply balance reference, found %', target, occurrences;
        END IF;
        updated := replace(replace(definition, 'FROM stock_balances', 'FROM v_stock_operable_balances'),
            'JOIN stock_balances', 'JOIN v_stock_operable_balances');
        IF updated = definition THEN RAISE EXCEPTION 'V928: % physical supply anchor drifted', target; END IF;
        EXECUTE updated;
    END LOOP;
    target := 'fn_subcontract_component_entitled_lots(uuid)';
    definition := pg_get_functiondef(target::regprocedure);
    occurrences := (length(definition) - length(replace(definition, 'fn_warehouse_counts_as_usable(warehouse.id)', '')))
        / length('fn_warehouse_counts_as_usable(warehouse.id)');
    IF occurrences <> 1 THEN RAISE EXCEPTION 'V928: % exact-lot supply anchor drifted', target; END IF;
    EXECUTE replace(definition, 'fn_warehouse_counts_as_usable(warehouse.id)',
        'fn_warehouse_counts_as_usable(warehouse.id) AND fn_stock_measurement_usable(reservation.warehouse_id,reservation.goods_id,reservation.color_id)');
END
$supply_readers$;

CREATE OR REPLACE VIEW v_stock_usable AS
SELECT balance.warehouse_id, balance.goods_id, balance.color_id,
       balance.qty AS on_hand_qty, balance.weight AS on_hand_weight,
       COALESCE(local_reserved.qty, 0) AS reserved_qty,
       balance.qty - COALESCE(local_reserved.qty, 0) AS available_qty
FROM stock_balances balance
JOIN warehouses warehouse ON warehouse.id = balance.warehouse_id
LEFT JOIN LATERAL (
    SELECT SUM(reservation.qty - reservation.consumed_qty - reservation.released_qty) AS qty
    FROM stock_reservations reservation
    WHERE NOT reservation.is_deleted AND reservation.status = 0
      AND reservation.goods_id = balance.goods_id
      AND reservation.color_id IS NOT DISTINCT FROM balance.color_id
      AND reservation.warehouse_id = balance.warehouse_id
) local_reserved ON TRUE
WHERE fn_warehouse_counts_as_usable(warehouse.id)
  AND fn_stock_measurement_usable(balance.warehouse_id, balance.goods_id, balance.color_id);

-- Older allocation readers intentionally retain their existing warehouse/global
-- reservation arithmetic; add the same measurement qualification only.
CREATE OR REPLACE VIEW v_stock_available AS
SELECT b.warehouse_id, b.goods_id, b.color_id, b.qty AS on_hand_qty,
       b.weight AS on_hand_weight, COALESCE(r.reserved_qty, 0) AS reserved_qty,
       b.qty - COALESCE(r.reserved_qty, 0) AS available_qty
FROM stock_balances b
LEFT JOIN LATERAL (
    SELECT SUM(sr.qty - sr.consumed_qty - sr.released_qty) AS reserved_qty
    FROM stock_reservations sr WHERE NOT sr.is_deleted AND sr.status = 0
      AND sr.goods_id = b.goods_id AND sr.color_id IS NOT DISTINCT FROM b.color_id
      AND (sr.warehouse_id IS NULL OR sr.warehouse_id = b.warehouse_id)
) r ON TRUE
WHERE fn_stock_measurement_usable(b.warehouse_id, b.goods_id, b.color_id);

CREATE FUNCTION fn_guard_stock_measurement_operability()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
    IF TG_TABLE_NAME = 'stock_balances' THEN
        IF TG_OP = 'DELETE' THEN
            IF EXISTS (SELECT 1 FROM stock_measurement_holds WHERE stock_balance_id = OLD.id) THEN
                RAISE EXCEPTION 'Original stock measurement evidence cannot be deleted' USING ERRCODE = '23514';
            END IF;
            RETURN OLD;
        END IF;
        IF TG_OP = 'UPDATE' AND (OLD.warehouse_id, OLD.goods_id, OLD.color_id, OLD.qty, OLD.amount_local, OLD.weight, OLD.weight_estimated)
            IS NOT DISTINCT FROM (NEW.warehouse_id, NEW.goods_id, NEW.color_id, NEW.qty, NEW.amount_local, NEW.weight, NEW.weight_estimated) THEN
            RETURN NEW;
        END IF;
        IF TG_OP = 'INSERT' AND NEW.qty = 0 AND COALESCE(NEW.amount_local, 0) = 0 AND COALESCE(NEW.weight, 0) = 0 THEN
            RETURN NEW;
        END IF;
        IF TG_OP = 'UPDATE' AND NOT fn_stock_measurement_usable(OLD.warehouse_id, OLD.goods_id, OLD.color_id) THEN
            RAISE EXCEPTION '历史库存计量待核，账面数仅供核对；补主档单位不能解除原数量待核' USING ERRCODE = '23514', CONSTRAINT = 'stock_measurement_pending';
        END IF;
    END IF;
    IF NOT fn_stock_measurement_usable(NEW.warehouse_id, NEW.goods_id, NEW.color_id) THEN
        RAISE EXCEPTION '库存计量待核，须先核实原数量单位及量纲；本次未出入库、未修改原账' USING ERRCODE = '23514', CONSTRAINT = 'stock_measurement_pending';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER trg_stock_movement_measurement_operability BEFORE INSERT ON stock_movements
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_measurement_operability();
CREATE TRIGGER trg_stock_balance_measurement_operability BEFORE INSERT OR UPDATE OR DELETE ON stock_balances
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_measurement_operability();
ALTER TABLE stock_movements ENABLE ALWAYS TRIGGER trg_stock_movement_measurement_operability;
ALTER TABLE stock_balances ENABLE ALWAYS TRIGGER trg_stock_balance_measurement_operability;

-- A release/cancellation is always allowed. A new/increased physical commitment,
-- warehouse retarget, reactivation or consumption cannot use an unresolved basis.
CREATE FUNCTION fn_guard_stock_reservation_measurement_operability()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND
        (NEW.goods_id, NEW.color_id, NEW.warehouse_id, NEW.supply_type, NEW.supply_id)
          IS NOT DISTINCT FROM (OLD.goods_id, OLD.color_id, OLD.warehouse_id, OLD.supply_type, OLD.supply_id)
        AND NEW.qty - NEW.released_qty <= OLD.qty - OLD.released_qty
        AND NEW.consumed_qty <= OLD.consumed_qty
        AND NOT (NEW.status = 0 AND OLD.status <> 0) AND NOT (NOT NEW.is_deleted AND OLD.is_deleted) THEN
        RETURN NEW;
    END IF;
    IF NOT fn_stock_has_resolved_base_unit(NEW.goods_id) OR
        (NEW.warehouse_id IS NOT NULL AND NOT fn_stock_measurement_usable(NEW.warehouse_id, NEW.goods_id, NEW.color_id)) OR
        (NEW.warehouse_id IS NULL AND COALESCE(NEW.supply_type, 'STOCK_BALANCE') = 'STOCK_BALANCE'
          AND EXISTS (SELECT 1 FROM stock_measurement_holds h WHERE h.goods_id = NEW.goods_id
                AND h.color_id IS NOT DISTINCT FROM NEW.color_id AND h.released_at IS NULL)
          AND NOT EXISTS (SELECT 1 FROM v_stock_usable s WHERE s.goods_id = NEW.goods_id
                AND s.color_id IS NOT DISTINCT FROM NEW.color_id AND s.on_hand_qty > 0)) THEN
        RAISE EXCEPTION '计量待核库存不能新增预留或消耗；原账保留供核对' USING ERRCODE = '23514', CONSTRAINT = 'stock_measurement_pending';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER trg_stock_reservation_measurement_operability BEFORE INSERT OR UPDATE ON stock_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_reservation_measurement_operability();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_stock_reservation_measurement_operability;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'uten') THEN
        GRANT SELECT ON stock_measurement_holds TO uten;
        GRANT SELECT ON v_stock_operable_balances TO uten;
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON stock_measurement_holds FROM uten;
    END IF;
END $$;
