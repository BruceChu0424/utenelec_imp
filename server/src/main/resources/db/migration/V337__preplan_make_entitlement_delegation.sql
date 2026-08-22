-- V337: exact entitlement hand-off for an in-analysis MAKE_COMPONENT child.
-- Immutable IQC/MAKE origin evidence is never rewritten. The current beneficiary
-- moves through an append-only MAKE_DELEGATE_OUT/MAKE_DELEGATE_IN pair.

CREATE TABLE preplan_make_entitlement_delegations (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id                     UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    supply_action_id                UUID NOT NULL
        REFERENCES preplan_supply_actions(id) ON DELETE RESTRICT,
    parent_analysis_material_id     UUID NOT NULL,
    child_analysis_item_id          UUID NOT NULL
        REFERENCES production_material_analysis_items(id) ON DELETE RESTRICT,
    source_analysis_material_id     UUID NOT NULL,
    target_analysis_material_id     UUID NOT NULL,
    stock_reservation_id            UUID NOT NULL
        REFERENCES stock_reservations(id) ON DELETE RESTRICT,
    source_entitlement_event_id     UUID NOT NULL
        REFERENCES preplan_stock_entitlement_events(id) ON DELETE RESTRICT,
    qty                             NUMERIC(18,4) NOT NULL,
    idempotency_key                 TEXT NOT NULL,
    created_by                      UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT preplan_make_delegate_parent_fk
        FOREIGN KEY (analysis_id, parent_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_make_delegate_source_fk
        FOREIGN KEY (analysis_id, source_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_make_delegate_target_fk
        FOREIGN KEY (analysis_id, target_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_make_delegate_distinct_chk CHECK (
        source_analysis_material_id <> target_analysis_material_id),
    CONSTRAINT preplan_make_delegate_qty_chk CHECK (qty > 0),
    CONSTRAINT preplan_make_delegate_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 200),
    CONSTRAINT uq_preplan_make_delegate_idempotency UNIQUE (idempotency_key),
    CONSTRAINT uq_preplan_make_delegate_source_action UNIQUE (
        supply_action_id, source_entitlement_event_id,
        target_analysis_material_id)
);

CREATE INDEX idx_preplan_make_delegate_analysis_child
    ON preplan_make_entitlement_delegations(
        analysis_id, child_analysis_item_id, created_at, id);
CREATE INDEX idx_preplan_make_delegate_source_material
    ON preplan_make_entitlement_delegations(
        source_analysis_material_id, created_at, id);
CREATE INDEX idx_preplan_make_delegate_target_material
    ON preplan_make_entitlement_delegations(
        target_analysis_material_id, created_at, id);

CREATE OR REPLACE FUNCTION fn_guard_preplan_make_delegation_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'preplan MAKE entitlement delegations are append-only'
        USING ERRCODE = '55000';
END;
$$;
CREATE TRIGGER trg_guard_preplan_make_delegation_mutation
    BEFORE UPDATE OR DELETE ON preplan_make_entitlement_delegations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_make_delegation_mutation();
CREATE TRIGGER trg_audit_preplan_make_entitlement_delegations
    AFTER INSERT OR UPDATE OR DELETE ON preplan_make_entitlement_delegations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

ALTER TABLE preplan_stock_entitlement_events
    DROP CONSTRAINT preplan_entitlement_event_type_chk,
    ADD CONSTRAINT preplan_entitlement_event_type_chk CHECK (event_type IN (
        'ORIGIN_IQC', 'ORIGIN_MAKE',
        'MAKE_DELEGATE_IN', 'MAKE_DELEGATE_OUT',
        'REALLOCATE_IN', 'REALLOCATE_OUT',
        'PRIORITY_IN', 'PRIORITY_OUT',
        'PRIORITY_SATISFIED_IN_PLACE',
        'FORMALIZE', 'RESTORE', 'RELEASE'));

CREATE UNIQUE INDEX uq_preplan_make_delegate_out_group
    ON preplan_stock_entitlement_events(event_group_id)
    WHERE event_type = 'MAKE_DELEGATE_OUT';
CREATE UNIQUE INDEX uq_preplan_make_delegate_in_group
    ON preplan_stock_entitlement_events(event_group_id)
    WHERE event_type = 'MAKE_DELEGATE_IN';
CREATE UNIQUE INDEX uq_preplan_make_delegate_in_counter
    ON preplan_stock_entitlement_events(counter_event_id)
    WHERE counter_event_id IS NOT NULL
      AND event_type = 'MAKE_DELEGATE_IN';
CREATE INDEX idx_preplan_entitlement_make_delegation
    ON preplan_stock_entitlement_events(
        event_group_id, event_type, created_at, id)
    WHERE event_type IN ('MAKE_DELEGATE_OUT', 'MAKE_DELEGATE_IN');

CREATE OR REPLACE VIEW v_preplan_stock_entitlement_lot_balance AS
SELECT positive.id AS entitlement_event_id,
       positive.event_group_id,
       positive.stock_reservation_id,
       positive.beneficiary_analysis_id,
       positive.beneficiary_analysis_material_id,
       positive.event_type AS origin_event_type,
       positive.reallocation_id,
       positive.source_exact_peg_id,
       positive.qty AS granted_qty,
       COALESCE(consumed.consumed_qty, 0)::numeric AS consumed_qty,
       (positive.qty - COALESCE(consumed.consumed_qty, 0))::numeric
           AS remaining_qty,
       positive.created_at,
       positive.id
FROM preplan_stock_entitlement_events positive
LEFT JOIN LATERAL (
    SELECT SUM(negative.qty)::numeric AS consumed_qty
    FROM preplan_stock_entitlement_events negative
    WHERE negative.source_entitlement_event_id = positive.id
      AND negative.event_type IN (
          'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT', 'PRIORITY_OUT',
          'FORMALIZE', 'RELEASE')
) consumed ON TRUE
WHERE positive.event_type IN (
    'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
    'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE');

CREATE OR REPLACE VIEW v_preplan_stock_entitlement_beneficiary_balance AS
SELECT lot.stock_reservation_id,
       lot.beneficiary_analysis_id,
       lot.beneficiary_analysis_material_id,
       SUM(lot.remaining_qty)::numeric AS effective_qty
FROM v_preplan_stock_entitlement_lot_balance lot
GROUP BY lot.stock_reservation_id,
         lot.beneficiary_analysis_id,
         lot.beneficiary_analysis_material_id
HAVING SUM(lot.remaining_qty) > 0;

CREATE OR REPLACE FUNCTION fn_check_preplan_make_entitlement_delegation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    analysis production_material_analyses%ROWTYPE;
    action preplan_supply_actions%ROWTYPE;
    parent_material production_material_analysis_materials%ROWTYPE;
    source_material production_material_analysis_materials%ROWTYPE;
    target_material production_material_analysis_materials%ROWTYPE;
    child_item production_material_analysis_items%ROWTYPE;
    reservation stock_reservations%ROWTYPE;
    source_event preplan_stock_entitlement_events%ROWTYPE;
    source_remaining NUMERIC(18,4);
    target_effective NUMERIC(18,4);
BEGIN
    SELECT * INTO analysis FROM production_material_analyses
    WHERE id = NEW.analysis_id;
    SELECT * INTO action FROM preplan_supply_actions
    WHERE id = NEW.supply_action_id FOR UPDATE;
    SELECT * INTO child_item FROM production_material_analysis_items
    WHERE id = NEW.child_analysis_item_id FOR UPDATE;
    SELECT * INTO parent_material FROM production_material_analysis_materials
    WHERE id = NEW.parent_analysis_material_id FOR UPDATE;
    SELECT * INTO source_material FROM production_material_analysis_materials
    WHERE id = NEW.source_analysis_material_id FOR UPDATE;
    SELECT * INTO target_material FROM production_material_analysis_materials
    WHERE id = NEW.target_analysis_material_id FOR UPDATE;
    SELECT * INTO reservation FROM stock_reservations
    WHERE id = NEW.stock_reservation_id FOR UPDATE;
    SELECT * INTO source_event FROM preplan_stock_entitlement_events
    WHERE id = NEW.source_entitlement_event_id FOR UPDATE;
    source_remaining := source_event.qty - COALESCE((
        SELECT SUM(used.qty)
        FROM preplan_stock_entitlement_events used
        WHERE used.source_entitlement_event_id = source_event.id
          AND used.event_type IN (
              'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT', 'PRIORITY_OUT',
              'FORMALIZE', 'RELEASE')), 0);
    SELECT COALESCE(SUM(balance.effective_qty), 0)
    INTO target_effective
    FROM v_preplan_stock_entitlement_beneficiary_balance balance
    JOIN stock_reservations owned
      ON owned.id = balance.stock_reservation_id
     AND owned.is_deleted = FALSE
     AND owned.status = 0
     AND owned.warehouse_id = analysis.warehouse_id
    WHERE balance.beneficiary_analysis_id = NEW.analysis_id
      AND balance.beneficiary_analysis_material_id = target_material.id;

    IF analysis.id IS NULL
       OR analysis.is_deleted IS DISTINCT FROM FALSE
       OR analysis.status NOT IN ('ACTIVE', 'PARTIALLY_PLANNED')
       OR action.id IS NULL
       OR action.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR action.route IS DISTINCT FROM 'MAKE'
       OR action.status = 'CANCELLED'
       OR action.external_document_type IS DISTINCT FROM 'PREPLAN_MAKE_TASK'
       OR action.external_document_id IS DISTINCT FROM NEW.child_analysis_item_id
       OR parent_material.id IS NULL
       OR parent_material.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR parent_material.active IS DISTINCT FROM TRUE
       OR parent_material.confirmed_route IS DISTINCT FROM 'MAKE'
       OR child_item.id IS NULL
       OR child_item.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR child_item.source_type IS DISTINCT FROM 'MAKE_COMPONENT'
       OR child_item.is_deleted IS DISTINCT FROM FALSE
       OR child_item.parent_analysis_material_id IS DISTINCT FROM parent_material.id
       OR NOT EXISTS (
            SELECT 1 FROM preplan_supply_action_allocations allocation
            WHERE allocation.action_id = action.id
              AND allocation.analysis_id = NEW.analysis_id
              AND allocation.analysis_material_id = parent_material.id)
       OR source_material.id IS NULL
       OR source_material.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR source_material.analysis_item_id
            IS DISTINCT FROM parent_material.analysis_item_id
       OR source_material.parent_node_key IS DISTINCT FROM parent_material.node_key
       OR source_material.active IS DISTINCT FROM TRUE
       OR target_material.id IS NULL
       OR target_material.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR target_material.analysis_item_id IS DISTINCT FROM child_item.id
       OR target_material.depth <> 1
       OR target_material.active IS DISTINCT FROM TRUE
       OR target_material.bom_item_id IS DISTINCT FROM source_material.bom_item_id
       OR target_material.goods_id IS DISTINCT FROM source_material.goods_id
       OR target_material.color_id IS DISTINCT FROM source_material.color_id
       OR target_material.unit_id IS DISTINCT FROM source_material.unit_id
       OR target_material.required_qty <= 0
       OR target_effective + NEW.qty > target_material.required_qty
       OR reservation.id IS NULL
       OR reservation.owner_type IS DISTINCT FROM 'PREPLAN_ANALYSIS'
       OR reservation.owner_id IS DISTINCT FROM NEW.analysis_id
       OR reservation.purpose IS DISTINCT FROM 'PREPLAN_MATERIAL'
       OR reservation.status <> 0
       OR reservation.is_deleted IS DISTINCT FROM FALSE
       OR reservation.warehouse_id IS DISTINCT FROM analysis.warehouse_id
       OR reservation.goods_id IS DISTINCT FROM source_material.goods_id
       OR reservation.color_id IS DISTINCT FROM source_material.color_id
       OR source_event.id IS NULL
       OR source_event.stock_reservation_id IS DISTINCT FROM reservation.id
       OR source_event.beneficiary_analysis_id IS DISTINCT FROM NEW.analysis_id
       OR source_event.beneficiary_analysis_material_id
            IS DISTINCT FROM source_material.id
       OR source_event.event_type NOT IN (
            'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
            'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE')
       OR source_event.source_exact_peg_id IS NULL
       OR NEW.qty > source_remaining THEN
        RAISE EXCEPTION 'invalid preplan MAKE entitlement delegation'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_check_preplan_make_entitlement_delegation
    BEFORE INSERT ON preplan_make_entitlement_delegations
    FOR EACH ROW EXECUTE FUNCTION fn_check_preplan_make_entitlement_delegation();

CREATE OR REPLACE FUNCTION fn_check_preplan_stock_entitlement_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    reservation stock_reservations%ROWTYPE;
    material production_material_analysis_materials%ROWTYPE;
    exact preplan_analysis_stock_exact_pegs%ROWTYPE;
    source_event preplan_stock_entitlement_events%ROWTYPE;
    counter_event preplan_stock_entitlement_events%ROWTYPE;
    reallocation preplan_material_reallocations%ROWTYPE;
    make_delegation preplan_make_entitlement_delegations%ROWTYPE;
    demand production_material_demands%ROWTYPE;
    production_plan production_plans%ROWTYPE;
    target_reservation stock_reservations%ROWTYPE;
    remaining NUMERIC(18,4);
    restored NUMERIC(18,4);
    target_linked NUMERIC(18,4);
BEGIN
    SELECT * INTO reservation FROM stock_reservations
    WHERE id = NEW.stock_reservation_id;
    SELECT * INTO material FROM production_material_analysis_materials
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
        SELECT * INTO reallocation FROM preplan_material_reallocations
        WHERE id = NEW.reallocation_id;
        IF reallocation.id IS NULL
           OR reallocation.warehouse_id <> reservation.warehouse_id
           OR reallocation.goods_id <> reservation.goods_id
           OR reallocation.color_id IS DISTINCT FROM reservation.color_id
           OR reallocation.unit_id <> material.unit_id THEN
            RAISE EXCEPTION 'entitlement reallocation dimension invalid'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.event_type IN ('MAKE_DELEGATE_OUT', 'MAKE_DELEGATE_IN') THEN
        SELECT * INTO make_delegation
        FROM preplan_make_entitlement_delegations
        WHERE id = NEW.event_group_id;
    END IF;

    IF NEW.event_type IN ('ORIGIN_IQC', 'ORIGIN_MAKE') THEN
        SELECT * INTO exact FROM preplan_analysis_stock_exact_pegs
        WHERE id = NEW.source_exact_peg_id;
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
        SELECT * INTO source_event FROM preplan_stock_entitlement_events
        WHERE id = NEW.source_entitlement_event_id FOR UPDATE;
        SELECT source_event.qty - COALESCE(SUM(used.qty), 0)
        INTO remaining
        FROM preplan_stock_entitlement_events used
        WHERE used.source_entitlement_event_id = source_event.id
          AND used.event_type IN (
              'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT', 'PRIORITY_OUT',
              'FORMALIZE', 'RELEASE')
        GROUP BY source_event.qty;
        remaining := COALESCE(remaining, source_event.qty);
        IF source_event.id IS NULL
           OR source_event.event_type NOT IN (
                'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
                'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE')
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
        SELECT * INTO counter_event FROM preplan_stock_entitlement_events
        WHERE id = NEW.counter_event_id FOR UPDATE;
    END IF;

    IF NEW.event_type = 'MAKE_DELEGATE_OUT' THEN
        IF source_event.id IS NULL
           OR make_delegation.id IS NULL
           OR NEW.reallocation_id IS DISTINCT FROM source_event.reallocation_id
           OR NEW.counter_event_id IS NOT NULL
           OR NEW.source_exact_peg_id IS NOT NULL
           OR NEW.stock_reservation_id
                IS DISTINCT FROM make_delegation.stock_reservation_id
           OR NEW.source_entitlement_event_id
                IS DISTINCT FROM make_delegation.source_entitlement_event_id
           OR NEW.beneficiary_analysis_id
                IS DISTINCT FROM make_delegation.analysis_id
           OR NEW.beneficiary_analysis_material_id
                IS DISTINCT FROM make_delegation.source_analysis_material_id
           OR NEW.qty IS DISTINCT FROM make_delegation.qty THEN
            RAISE EXCEPTION 'invalid MAKE_DELEGATE_OUT'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'MAKE_DELEGATE_IN' THEN
        IF NEW.source_entitlement_event_id IS NOT NULL
           OR make_delegation.id IS NULL
           OR counter_event.id IS NULL
           OR counter_event.event_type IS DISTINCT FROM 'MAKE_DELEGATE_OUT'
           OR counter_event.event_group_id IS DISTINCT FROM make_delegation.id
           OR NEW.reallocation_id IS DISTINCT FROM counter_event.reallocation_id
           OR counter_event.stock_reservation_id
                IS DISTINCT FROM make_delegation.stock_reservation_id
           OR counter_event.qty IS DISTINCT FROM make_delegation.qty
           OR NEW.stock_reservation_id
                IS DISTINCT FROM make_delegation.stock_reservation_id
           OR NEW.beneficiary_analysis_id
                IS DISTINCT FROM make_delegation.analysis_id
           OR NEW.beneficiary_analysis_material_id
                IS DISTINCT FROM make_delegation.target_analysis_material_id
           OR NEW.qty IS DISTINCT FROM make_delegation.qty
           OR NEW.source_exact_peg_id IS DISTINCT FROM (
                SELECT source_exact_peg_id
                FROM preplan_stock_entitlement_events
                WHERE id = counter_event.source_entitlement_event_id) THEN
            RAISE EXCEPTION 'invalid MAKE_DELEGATE_IN'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'REALLOCATE_OUT' THEN
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
           OR reallocation.id IS NULL OR counter_event.id IS NULL
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
        IF source_event.id IS NULL OR reallocation.id IS NULL
           OR NEW.counter_event_id IS NOT NULL
           OR NEW.beneficiary_analysis_id <> reallocation.to_analysis_id
           OR NEW.beneficiary_analysis_material_id
                <> reallocation.to_analysis_material_id THEN
            RAISE EXCEPTION 'invalid PRIORITY_OUT' USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'PRIORITY_IN' THEN
        IF NEW.source_entitlement_event_id IS NOT NULL
           OR reallocation.id IS NULL OR counter_event.id IS NULL
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
        IF source_event.id IS NULL OR reallocation.id IS NULL
           OR NEW.counter_event_id IS NOT NULL
           OR NEW.source_exact_peg_id IS NOT NULL
           OR NEW.beneficiary_analysis_id <> reallocation.from_analysis_id
           OR NEW.beneficiary_analysis_material_id
                <> reallocation.from_analysis_material_id THEN
            RAISE EXCEPTION 'invalid priority satisfaction'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'FORMALIZE' THEN
        SELECT * INTO demand FROM production_material_demands
        WHERE id = NEW.target_demand_id;
        SELECT * INTO production_plan FROM production_plans
        WHERE id = demand.plan_id;
        SELECT * INTO target_reservation FROM stock_reservations
        WHERE id = NEW.target_stock_reservation_id;
        SELECT COALESCE(SUM(link.qty), 0) INTO target_linked
        FROM preplan_stock_entitlement_events link
        WHERE link.event_type = 'FORMALIZE'
          AND link.target_stock_reservation_id =
              NEW.target_stock_reservation_id;
        IF source_event.id IS NULL
           OR NEW.counter_event_id IS NOT NULL
           OR NEW.source_exact_peg_id IS NOT NULL
           OR NEW.target_package_id IS NULL
           OR demand.id IS NULL OR target_reservation.id IS NULL
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
           OR target_reservation.owner_type <>
              'PRODUCTION_MATERIAL_DEMAND'
           OR target_reservation.owner_id <> demand.id
           OR target_reservation.demand_id <> demand.id
           OR target_reservation.purpose <> 'PRODUCTION_MATERIAL'
           OR target_reservation.warehouse_id <> reservation.warehouse_id
           OR target_reservation.goods_id <> reservation.goods_id
           OR target_reservation.color_id
                IS DISTINCT FROM reservation.color_id
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
               AND counter_event.event_type <>
                   'PRIORITY_SATISFIED_IN_PLACE') THEN
            RAISE EXCEPTION 'invalid RELEASE' USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'RESTORE' THEN
        SELECT COALESCE(SUM(restored_event.qty), 0) INTO restored
        FROM preplan_stock_entitlement_events restored_event
        WHERE restored_event.counter_event_id = NEW.counter_event_id
          AND restored_event.event_type = 'RESTORE';
        IF NEW.source_entitlement_event_id IS NOT NULL
           OR counter_event.id IS NULL
           OR counter_event.event_type NOT IN (
                'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT', 'PRIORITY_OUT',
                'FORMALIZE', 'RELEASE')
           OR counter_event.stock_reservation_id <>
              NEW.stock_reservation_id
           OR counter_event.beneficiary_analysis_id
                <> NEW.beneficiary_analysis_id
           OR counter_event.beneficiary_analysis_material_id
                <> NEW.beneficiary_analysis_material_id
           OR NEW.reallocation_id
                IS DISTINCT FROM counter_event.reallocation_id
           OR NEW.qty <> counter_event.qty OR restored <> 0
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
        RAISE EXCEPTION 'unsupported entitlement event'
            USING ERRCODE = '23514';
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

CREATE OR REPLACE FUNCTION fn_validate_preplan_make_delegation_totals()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    delegation_id UUID;
    header preplan_make_entitlement_delegations%ROWTYPE;
    out_event_id UUID;
    in_event_id UUID;
    out_qty NUMERIC(18,4);
    in_qty NUMERIC(18,4);
    released_qty NUMERIC(18,4);
    restored_qty NUMERIC(18,4);
BEGIN
    IF TG_TABLE_NAME = 'preplan_make_entitlement_delegations' THEN
        delegation_id := COALESCE(NEW.id, OLD.id);
    ELSIF COALESCE(NEW.event_type, OLD.event_type) IN (
            'MAKE_DELEGATE_OUT', 'MAKE_DELEGATE_IN',
            'RELEASE', 'RESTORE') THEN
        delegation_id := COALESCE(
            NEW.event_group_id, OLD.event_group_id);
    ELSE
        RETURN NEW;
    END IF;
    SELECT * INTO header FROM preplan_make_entitlement_delegations
    WHERE id = delegation_id;
    IF header.id IS NULL THEN RETURN NEW; END IF;
    SELECT id, qty INTO out_event_id, out_qty
    FROM preplan_stock_entitlement_events
    WHERE event_group_id = header.id
      AND event_type = 'MAKE_DELEGATE_OUT';
    SELECT id, qty INTO in_event_id, in_qty
    FROM preplan_stock_entitlement_events
    WHERE event_group_id = header.id
      AND event_type = 'MAKE_DELEGATE_IN';
    IF out_event_id IS NULL OR in_event_id IS NULL
       OR out_qty <> header.qty OR in_qty <> header.qty THEN
        RAISE EXCEPTION
            'MAKE delegation OUT/IN totals must equal header quantity'
            USING ERRCODE = '23514';
    END IF;
    SELECT COALESCE(SUM(event.qty), 0) INTO released_qty
    FROM preplan_stock_entitlement_events event
    WHERE event.event_group_id = header.id
      AND event.event_type = 'RELEASE'
      AND event.source_entitlement_event_id = in_event_id;
    SELECT COALESCE(SUM(event.qty), 0) INTO restored_qty
    FROM preplan_stock_entitlement_events event
    WHERE event.event_group_id = header.id
      AND event.event_type = 'RESTORE'
      AND event.counter_event_id = out_event_id;
    IF released_qty <> restored_qty
       OR released_qty NOT IN (0, header.qty) THEN
        RAISE EXCEPTION
            'MAKE delegation cancellation must RELEASE/RESTORE the full pair'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_validate_preplan_make_delegation_header
    AFTER INSERT ON preplan_make_entitlement_delegations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_preplan_make_delegation_totals();
CREATE CONSTRAINT TRIGGER trg_validate_preplan_make_delegation_events
    AFTER INSERT ON preplan_stock_entitlement_events
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_preplan_make_delegation_totals();

CREATE VIEW v_preplan_make_entitlement_delegation_state AS
SELECT delegation.*,
       COALESCE(restored.restored_qty, 0)::numeric AS restored_qty,
       CASE WHEN COALESCE(restored.restored_qty, 0) = delegation.qty
            THEN 'RESTORED' ELSE 'ACTIVE' END AS state
FROM preplan_make_entitlement_delegations delegation
LEFT JOIN LATERAL (
    SELECT SUM(restore_event.qty)::numeric AS restored_qty
    FROM preplan_stock_entitlement_events outgoing
    JOIN preplan_stock_entitlement_events restore_event
      ON restore_event.counter_event_id = outgoing.id
     AND restore_event.event_group_id = delegation.id
     AND restore_event.event_type = 'RESTORE'
    WHERE outgoing.event_group_id = delegation.id
      AND outgoing.event_type = 'MAKE_DELEGATE_OUT'
) restored ON TRUE;

-- Provable, idempotent repair for existing misalignment. It deliberately
-- excludes planned/formalized children, cross-analysis entitlement and
-- ambiguous multiple MAKE actions.
DO $$
DECLARE
    relation RECORD;
    lot RECORD;
    needed NUMERIC(18,4);
    take_qty NUMERIC(18,4);
    delegation_key TEXT;
    delegation_id UUID;
    out_event_id UUID;
BEGIN
    FOR relation IN
        SELECT analysis.id AS analysis_id,
               chosen.action_id, chosen.actor_id,
               parent_material.id AS parent_material_id,
               child.id AS child_item_id,
               source_material.id AS source_material_id,
               target_material.id AS target_material_id,
               analysis.warehouse_id,
               target_material.goods_id, target_material.color_id,
               target_material.unit_id, target_material.required_qty,
               COALESCE((
                   SELECT SUM(balance.effective_qty)
                   FROM v_preplan_stock_entitlement_beneficiary_balance balance
                   JOIN stock_reservations owned
                     ON owned.id = balance.stock_reservation_id
                    AND owned.warehouse_id = analysis.warehouse_id
                   WHERE balance.beneficiary_analysis_id = analysis.id
                     AND balance.beneficiary_analysis_material_id =
                         target_material.id
               ), 0) AS target_owned_qty
        FROM production_material_analysis_items child
        JOIN production_material_analysis_materials parent_material
          ON parent_material.id = child.parent_analysis_material_id
         AND parent_material.analysis_id = child.analysis_id
         AND parent_material.active = TRUE
         AND parent_material.confirmed_route = 'MAKE'
        JOIN production_material_analysis_materials source_material
          ON source_material.analysis_id = child.analysis_id
         AND source_material.analysis_item_id =
             parent_material.analysis_item_id
         AND source_material.parent_node_key = parent_material.node_key
         AND source_material.active = TRUE
        JOIN production_material_analysis_materials target_material
          ON target_material.analysis_id = child.analysis_id
         AND target_material.analysis_item_id = child.id
         AND target_material.depth = 1
         AND target_material.active = TRUE
         AND target_material.bom_item_id = source_material.bom_item_id
         AND target_material.goods_id = source_material.goods_id
         AND target_material.color_id IS NOT DISTINCT FROM
             source_material.color_id
         AND target_material.unit_id = source_material.unit_id
        JOIN production_material_analyses analysis
          ON analysis.id = child.analysis_id
         AND analysis.is_deleted = FALSE
         AND analysis.status IN ('ACTIVE', 'PARTIALLY_PLANNED')
        JOIN LATERAL (
            SELECT (
                       array_agg(
                           action.id ORDER BY action.created_at, action.id)
                   )[1] AS action_id,
                   (
                       array_agg(
                           action.created_by
                           ORDER BY action.created_at, action.id)
                   )[1] AS actor_id,
                   COUNT(DISTINCT action.id) AS action_count
            FROM preplan_supply_actions action
            JOIN preplan_supply_action_allocations allocation
              ON allocation.action_id = action.id
             AND allocation.analysis_id = action.analysis_id
             AND allocation.analysis_material_id = parent_material.id
            WHERE action.analysis_id = child.analysis_id
              AND action.route = 'MAKE'
              AND action.status <> 'CANCELLED'
              AND action.external_document_type = 'PREPLAN_MAKE_TASK'
              AND action.external_document_id = child.id
        ) chosen ON chosen.action_count = 1
        WHERE child.source_type = 'MAKE_COMPONENT'
          AND child.is_deleted = FALSE
          AND child.submitted_qty = 0
          AND child.approved_qty = 0
          AND target_material.required_qty > 0
          AND NOT EXISTS (
              SELECT 1
              FROM production_material_analysis_plan_links link
              WHERE link.analysis_id = child.analysis_id
                AND link.analysis_item_id = child.id
                AND link.allocation_status IN ('SUBMITTED', 'APPROVED'))
          AND NOT EXISTS (
              SELECT 1
              FROM preplan_stock_entitlement_events formalize
              WHERE formalize.event_type = 'FORMALIZE'
                AND formalize.beneficiary_analysis_id = child.analysis_id
                AND formalize.beneficiary_analysis_material_id =
                    target_material.id)
        ORDER BY analysis.id, child.id, target_material.id
    LOOP
        needed := GREATEST(
            relation.required_qty - relation.target_owned_qty, 0);
        IF needed <= 0 THEN CONTINUE; END IF;
        FOR lot IN
            SELECT balance.entitlement_event_id,
                   balance.stock_reservation_id,
                   balance.source_exact_peg_id,
                   balance.remaining_qty
            FROM v_preplan_stock_entitlement_lot_balance balance
            JOIN preplan_stock_entitlement_events positive
              ON positive.id = balance.entitlement_event_id
            JOIN stock_reservations reservation
              ON reservation.id = balance.stock_reservation_id
             AND reservation.is_deleted = FALSE
             AND reservation.status = 0
            WHERE balance.beneficiary_analysis_id = relation.analysis_id
              AND balance.beneficiary_analysis_material_id =
                  relation.source_material_id
              AND balance.remaining_qty > 0
              AND balance.source_exact_peg_id IS NOT NULL
              AND positive.reallocation_id IS NULL
              AND balance.origin_event_type IN (
                    'ORIGIN_IQC', 'ORIGIN_MAKE',
                    'MAKE_DELEGATE_IN', 'RESTORE')
              AND reservation.warehouse_id = relation.warehouse_id
              AND reservation.goods_id = relation.goods_id
              AND reservation.color_id IS NOT DISTINCT FROM relation.color_id
              AND NOT EXISTS (
                  SELECT 1
                  FROM preplan_material_reallocations reallocation
                  WHERE reallocation.status IN ('OPEN', 'PARTIAL')
                    AND (
                        reallocation.from_analysis_material_id =
                            relation.source_material_id
                        OR reallocation.to_analysis_material_id =
                            relation.source_material_id))
            ORDER BY balance.created_at, balance.entitlement_event_id
            FOR UPDATE OF positive, reservation
        LOOP
            EXIT WHEN needed <= 0;
            take_qty := LEAST(lot.remaining_qty, needed);
            delegation_key := 'MAKE-DELEGATE-BACKFILL:'
                || relation.action_id || ':' || lot.entitlement_event_id
                || ':' || relation.target_material_id;
            INSERT INTO preplan_make_entitlement_delegations (
                id, analysis_id, supply_action_id,
                parent_analysis_material_id, child_analysis_item_id,
                source_analysis_material_id, target_analysis_material_id,
                stock_reservation_id, source_entitlement_event_id,
                qty, idempotency_key, created_by
            ) VALUES (
                gen_random_uuid(), relation.analysis_id, relation.action_id,
                relation.parent_material_id, relation.child_item_id,
                relation.source_material_id, relation.target_material_id,
                lot.stock_reservation_id, lot.entitlement_event_id,
                take_qty, delegation_key, relation.actor_id
            ) ON CONFLICT (idempotency_key) DO NOTHING;
            SELECT id INTO delegation_id
            FROM preplan_make_entitlement_delegations
            WHERE idempotency_key = delegation_key;

            INSERT INTO preplan_stock_entitlement_events (
                id, event_group_id, stock_reservation_id,
                beneficiary_analysis_id,
                beneficiary_analysis_material_id,
                event_type, qty, source_entitlement_event_id,
                idempotency_key, created_by
            ) VALUES (
                gen_random_uuid(), delegation_id, lot.stock_reservation_id,
                relation.analysis_id, relation.source_material_id,
                'MAKE_DELEGATE_OUT', take_qty, lot.entitlement_event_id,
                delegation_key || ':OUT', relation.actor_id
            ) ON CONFLICT (idempotency_key) DO NOTHING;
            SELECT id INTO out_event_id
            FROM preplan_stock_entitlement_events
            WHERE idempotency_key = delegation_key || ':OUT';

            INSERT INTO preplan_stock_entitlement_events (
                id, event_group_id, stock_reservation_id,
                beneficiary_analysis_id,
                beneficiary_analysis_material_id,
                event_type, qty, source_exact_peg_id,
                counter_event_id, idempotency_key, created_by
            ) VALUES (
                gen_random_uuid(), delegation_id, lot.stock_reservation_id,
                relation.analysis_id, relation.target_material_id,
                'MAKE_DELEGATE_IN', take_qty, lot.source_exact_peg_id,
                out_event_id, delegation_key || ':IN', relation.actor_id
            ) ON CONFLICT (idempotency_key) DO NOTHING;
            needed := needed - take_qty;
        END LOOP;
    END LOOP;
END;
$$;

CREATE VIEW v_preplan_make_entitlement_delegation_gaps AS
SELECT analysis.id AS analysis_id,
       child.id AS child_analysis_item_id,
       parent_material.id AS parent_analysis_material_id,
       source_material.id AS source_analysis_material_id,
       target_material.id AS target_analysis_material_id,
       source_balance.effective_qty AS source_effective_qty,
       target_material.required_qty AS target_required_qty,
       target_material.shortage_qty AS target_shortage_qty,
       action_stats.action_count,
       CASE
         WHEN child.submitted_qty > 0 OR child.approved_qty > 0
           THEN 'CHILD_ALREADY_PLANNED'
         WHEN action_stats.action_count <> 1
           THEN 'AMBIGUOUS_MAKE_ACTION'
         WHEN EXISTS (
             SELECT 1
             FROM production_material_analysis_plan_links link
             WHERE link.analysis_id = child.analysis_id
               AND link.analysis_item_id = child.id
               AND link.allocation_status IN ('SUBMITTED', 'APPROVED'))
           THEN 'ACTIVE_PLAN_LINK'
         WHEN EXISTS (
             SELECT 1
             FROM preplan_stock_entitlement_events formalize
             WHERE formalize.event_type = 'FORMALIZE'
               AND formalize.beneficiary_analysis_id = child.analysis_id
               AND formalize.beneficiary_analysis_material_id =
                   target_material.id)
           THEN 'FORMALIZED_ENTITLEMENT'
         WHEN EXISTS (
             SELECT 1
             FROM preplan_material_reallocations reallocation
             WHERE reallocation.status IN ('OPEN', 'PARTIAL')
               AND (
                   reallocation.from_analysis_material_id = source_material.id
                   OR reallocation.to_analysis_material_id =
                       source_material.id))
           THEN 'ACTIVE_CROSS_REALLOCATION'
         ELSE 'UNRESOLVED_PROVENANCE'
       END AS reason
FROM production_material_analysis_items child
JOIN production_material_analysis_materials parent_material
  ON parent_material.id = child.parent_analysis_material_id
 AND parent_material.analysis_id = child.analysis_id
 AND parent_material.active = TRUE
 AND parent_material.confirmed_route = 'MAKE'
JOIN production_material_analysis_materials source_material
  ON source_material.analysis_id = child.analysis_id
 AND source_material.analysis_item_id = parent_material.analysis_item_id
 AND source_material.parent_node_key = parent_material.node_key
 AND source_material.active = TRUE
JOIN production_material_analysis_materials target_material
  ON target_material.analysis_id = child.analysis_id
 AND target_material.analysis_item_id = child.id
 AND target_material.depth = 1
 AND target_material.active = TRUE
 AND target_material.bom_item_id = source_material.bom_item_id
 AND target_material.goods_id = source_material.goods_id
 AND target_material.color_id IS NOT DISTINCT FROM source_material.color_id
 AND target_material.unit_id = source_material.unit_id
JOIN production_material_analyses analysis
  ON analysis.id = child.analysis_id
 AND analysis.is_deleted = FALSE
 AND analysis.status IN ('ACTIVE', 'PARTIALLY_PLANNED')
JOIN LATERAL (
    SELECT COUNT(DISTINCT action.id) AS action_count
    FROM preplan_supply_actions action
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id = action.id
     AND allocation.analysis_id = action.analysis_id
     AND allocation.analysis_material_id = parent_material.id
    WHERE action.analysis_id = child.analysis_id
      AND action.route = 'MAKE'
      AND action.status <> 'CANCELLED'
      AND action.external_document_type = 'PREPLAN_MAKE_TASK'
      AND action.external_document_id = child.id
) action_stats ON TRUE
JOIN LATERAL (
    SELECT COALESCE(SUM(balance.effective_qty), 0)::numeric
               AS effective_qty
    FROM v_preplan_stock_entitlement_beneficiary_balance balance
    JOIN stock_reservations reservation
      ON reservation.id = balance.stock_reservation_id
     AND reservation.is_deleted = FALSE
     AND reservation.status = 0
     AND reservation.warehouse_id = analysis.warehouse_id
     AND reservation.goods_id = source_material.goods_id
     AND reservation.color_id IS NOT DISTINCT FROM source_material.color_id
    WHERE balance.beneficiary_analysis_id = analysis.id
      AND balance.beneficiary_analysis_material_id = source_material.id
) source_balance ON source_balance.effective_qty > 0
WHERE child.source_type = 'MAKE_COMPONENT'
  AND child.is_deleted = FALSE
  AND target_material.shortage_qty > 0
  AND NOT EXISTS (
      SELECT 1
      FROM v_preplan_make_entitlement_delegation_state state
      WHERE state.state = 'ACTIVE'
        AND state.source_analysis_material_id = source_material.id
        AND state.target_analysis_material_id = target_material.id);

COMMENT ON TABLE preplan_make_entitlement_delegations IS
    '同一分析内 MAKE 父路径到 MAKE_COMPONENT 子分析的不可变权益转移头；余额与撤回由 append-only entitlement 事件派生';
COMMENT ON VIEW v_preplan_make_entitlement_delegation_state IS
    'MAKE entitlement 委派的 ACTIVE/RESTORED 只读状态；header 本身不可更新删除';
COMMENT ON VIEW v_preplan_make_entitlement_delegation_gaps IS
    'V337 未自动修复的 MAKE exact 权益错位只读清单及失败关闭原因';
COMMENT ON COLUMN
    preplan_make_entitlement_delegations.source_analysis_material_id IS
    '父树中 child ownership 生效后不再承载需求的原直接子件路径';
COMMENT ON COLUMN
    preplan_make_entitlement_delegations.target_analysis_material_id IS
    'MAKE_COMPONENT child 中同一 BOM edge 的 depth=1 接管路径';
