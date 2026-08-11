-- V194: direct MAKE supply provenance and finished-in re-kit lifecycle.
--
-- V179 allowed MAKE in the execution-demand shape constraint, but the V155
-- deferred segment validator still rejected it. This migration removes only
-- that obsolete rejection and adds an exact child-plan-item supply source.
-- Existing facts are never backfilled or rewritten.

ALTER TABLE production_execution_segments
    ADD COLUMN auto_promote_when_ready BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN production_execution_segments.auto_promote_when_ready IS
    'TRUE for supply-waiting segments; FALSE preserves an explicit user defer.';

ALTER TABLE production_execution_segments
    ADD CONSTRAINT production_execution_segment_readiness_policy_chk
        CHECK (
            auto_promote_when_ready
            OR status IN ('WAITING', 'CANCELLED', 'REVERSED')
        );

ALTER TABLE production_execution_segment_events
    DROP CONSTRAINT production_execution_segment_events_action_check,
    ADD CONSTRAINT production_execution_segment_events_action_check
        CHECK (action IN (
            'ASSIGNMENT', 'DISPATCH', 'START', 'CANCEL', 'REVERSE',
            'REOPEN_COMPLETION', 'RELEASE_DEFER'
        ));

CREATE OR REPLACE FUNCTION fn_guard_execution_segment_readiness_policy()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.auto_promote_when_ready
           IS DISTINCT FROM NEW.auto_promote_when_ready THEN
        IF OLD.auto_promote_when_ready = FALSE
           AND NEW.auto_promote_when_ready = TRUE
           AND OLD.status = 'WAITING'
           AND NEW.status = 'WAITING'
           AND OLD.is_deleted = FALSE
           AND NEW.is_deleted = FALSE THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'execution segment readiness policy may only be released once while WAITING'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_readiness_policy_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_execution_segment_readiness_policy
    BEFORE UPDATE OF auto_promote_when_ready
    ON production_execution_segments
    FOR EACH ROW
    EXECUTE FUNCTION fn_guard_execution_segment_readiness_policy();

-- V155 already validates that a team/owner is inside the selected workshop.
-- New V194 writes additionally use the canonical production organization:
-- the workshop must be a direct child of DEPT_PROD and a selected team must
-- be a direct child of that workshop. Existing rows are not scanned/backfilled.
CREATE OR REPLACE FUNCTION fn_guard_production_assignment_scope()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_valid_count BIGINT;
BEGIN
    -- Preserve legacy rows when only owner, dates or status change. The stricter
    -- organization rule governs every new segment and every actual workshop/
    -- team reassignment after V194.
    IF TG_OP = 'UPDATE'
       AND OLD.workshop_department_id
           IS NOT DISTINCT FROM NEW.workshop_department_id
       AND OLD.team_department_id
           IS NOT DISTINCT FROM NEW.team_department_id THEN
        RETURN NEW;
    END IF;

    IF NEW.workshop_department_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_valid_count
        FROM departments workshop
        JOIN departments production_department
          ON production_department.id = workshop.parent_id
         AND production_department.code = 'DEPT_PROD'
         AND production_department.is_deleted = FALSE
        WHERE workshop.id = NEW.workshop_department_id
          AND workshop.is_deleted = FALSE;
        IF v_valid_count <> 1 THEN
            RAISE EXCEPTION 'execution segment workshop must be a direct child of DEPT_PROD'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_execution_segment_production_workshop_guard';
        END IF;
    END IF;

    IF NEW.team_department_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_valid_count
        FROM departments team
        WHERE team.id = NEW.team_department_id
          AND team.parent_id = NEW.workshop_department_id
          AND team.is_deleted = FALSE;
        IF v_valid_count <> 1 THEN
            RAISE EXCEPTION 'execution segment team must be a direct child of its workshop'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_execution_segment_direct_team_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_assignment_scope
    BEFORE INSERT OR UPDATE OF
        workshop_department_id, team_department_id
    ON production_execution_segments
    FOR EACH ROW
    EXECUTE FUNCTION fn_guard_production_assignment_scope();

CREATE OR REPLACE FUNCTION fn_check_execution_segment_defer_release_event()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_version BIGINT;
BEGIN
    SELECT lock_version INTO v_current_version
    FROM production_execution_segments
    WHERE id = NEW.id;

    IF NOT EXISTS (
        SELECT 1
        FROM production_execution_segment_events event
        WHERE event.execution_segment_id = NEW.id
          AND event.action = 'RELEASE_DEFER'
          AND event.expected_version = OLD.lock_version
          AND event.resulting_version = v_current_version
    ) THEN
        RAISE EXCEPTION 'execution segment defer release requires its semantic event'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_defer_release_event_guard';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_check_execution_segment_defer_release_event
    AFTER UPDATE ON production_execution_segments
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (
        OLD.auto_promote_when_ready = FALSE
        AND NEW.auto_promote_when_ready = TRUE
    )
    EXECUTE FUNCTION fn_check_execution_segment_defer_release_event();

ALTER TABLE production_material_supply_pegs
    DROP CONSTRAINT production_material_supply_peg_type_chk,
    ADD CONSTRAINT production_material_supply_peg_type_chk
        CHECK (supply_type IN (
            'PURCHASE_REQUEST_ITEM', 'PURCHASE_ORDER_ITEM',
            'SUBCONTRACT_APPLICATION_ITEM', 'SUBCONTRACT_ORDER_ITEM',
            'PRODUCTION_PLAN_ITEM'
        ));

CREATE OR REPLACE FUNCTION fn_guard_production_material_supply_peg()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_demand                  production_material_demands%ROWTYPE;
    v_source_goods            UUID;
    v_source_color            UUID;
    v_source_unit             UUID;
    v_source_qty              numeric;
    v_source_rate             numeric;
    v_new_source_committed    numeric;
    v_old_source_committed    numeric := 0;
    v_new_demand_effective    numeric;
    v_old_demand_effective    numeric := 0;
    v_other_source            numeric;
    v_other_demand            numeric;
    v_stock_demand            numeric;
BEGIN
    IF TG_OP = 'UPDATE'
       AND (
           NEW.demand_id IS DISTINCT FROM OLD.demand_id
           OR NEW.supply_type IS DISTINCT FROM OLD.supply_type
           OR NEW.supply_item_id IS DISTINCT FROM OLD.supply_item_id
       ) THEN
        RAISE EXCEPTION 'material supply peg identity is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_supply_peg_identity_guard';
    END IF;

    SELECT * INTO v_demand
    FROM production_material_demands
    WHERE id = NEW.demand_id
      AND is_deleted = FALSE
    FOR UPDATE;
    IF NOT FOUND OR v_demand.status IN ('RELEASED', 'REVERSED') THEN
        RAISE EXCEPTION 'material supply peg demand is not active'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_supply_peg_demand_guard';
    END IF;

    IF NOT (
        (v_demand.supply_route = 'BUY'
         AND NEW.supply_type IN (
             'PURCHASE_REQUEST_ITEM', 'PURCHASE_ORDER_ITEM'))
        OR (v_demand.supply_route = 'SUBCONTRACT'
            AND NEW.supply_type IN (
                'SUBCONTRACT_APPLICATION_ITEM',
                'SUBCONTRACT_ORDER_ITEM'))
        OR (v_demand.supply_route = 'MAKE'
            AND NEW.supply_type = 'PRODUCTION_PLAN_ITEM')
    ) THEN
        RAISE EXCEPTION 'material supply peg type does not match demand route'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_supply_peg_route_guard';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'DEMAND:' || NEW.demand_id::text,
            6148615593807138892
        )
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            NEW.supply_type || ':' || NEW.supply_item_id::text,
            6148615593807138892
        )
    );

    CASE NEW.supply_type
        WHEN 'PURCHASE_REQUEST_ITEM' THEN
            SELECT goods_id, color_id, unit_id, qty, unit_rate
            INTO v_source_goods, v_source_color, v_source_unit,
                 v_source_qty, v_source_rate
            FROM purchase_request_items
            WHERE id = NEW.supply_item_id AND is_deleted = FALSE
            FOR UPDATE;
        WHEN 'PURCHASE_ORDER_ITEM' THEN
            SELECT goods_id, color_id, unit_id, qty, unit_rate
            INTO v_source_goods, v_source_color, v_source_unit,
                 v_source_qty, v_source_rate
            FROM purchase_order_items
            WHERE id = NEW.supply_item_id AND is_deleted = FALSE
            FOR UPDATE;
        WHEN 'SUBCONTRACT_APPLICATION_ITEM' THEN
            SELECT goods_id, color_id, unit_id, qty, unit_rate
            INTO v_source_goods, v_source_color, v_source_unit,
                 v_source_qty, v_source_rate
            FROM subcontract_application_items
            WHERE id = NEW.supply_item_id AND is_deleted = FALSE
            FOR UPDATE;
        WHEN 'SUBCONTRACT_ORDER_ITEM' THEN
            SELECT goods_id, color_id, unit_id, qty, unit_rate
            INTO v_source_goods, v_source_color, v_source_unit,
                 v_source_qty, v_source_rate
            FROM subcontract_order_items
            WHERE id = NEW.supply_item_id AND is_deleted = FALSE
            FOR UPDATE;
        WHEN 'PRODUCTION_PLAN_ITEM' THEN
            SELECT item.goods_id, item.color_id, item.unit_id,
                   item.qty, item.unit_rate
            INTO v_source_goods, v_source_color, v_source_unit,
                 v_source_qty, v_source_rate
            FROM production_plan_items item
            JOIN production_plans child
              ON child.id = item.plan_id
             AND child.is_deleted = FALSE
             AND child.status <> -1
            WHERE item.id = NEW.supply_item_id
              AND item.is_deleted = FALSE
              AND EXISTS (
                  SELECT 1
                  FROM subplan_links link
                  WHERE link.subplan_id = item.plan_id
                    AND link.plan_id = v_demand.plan_id
                    AND link.planning_package_id = v_demand.package_id
                    AND link.source = 'EXECUTION_V1'
                    AND link.is_deleted = FALSE
              )
            FOR UPDATE OF item;
    END CASE;

    IF v_source_goods IS NULL
       OR v_source_goods <> v_demand.goods_id
       OR v_source_color IS DISTINCT FROM v_demand.color_id
       OR (NEW.supply_type = 'PRODUCTION_PLAN_ITEM'
           AND v_source_unit IS DISTINCT FROM v_demand.unit_id)
       OR COALESCE(v_source_rate, 0) <= 0
       OR COALESCE(v_source_qty, 0) <= 0 THEN
        RAISE EXCEPTION 'material supply peg source dimension is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_supply_peg_source_guard';
    END IF;

    v_new_source_committed := NEW.allocated_qty - NEW.released_qty;
    v_new_demand_effective :=
        NEW.allocated_qty - NEW.consumed_qty - NEW.released_qty;
    IF TG_OP = 'UPDATE' THEN
        v_old_source_committed := OLD.allocated_qty - OLD.released_qty;
        v_old_demand_effective :=
            OLD.allocated_qty - OLD.consumed_qty - OLD.released_qty;
    END IF;

    IF v_new_source_committed > v_old_source_committed THEN
        SELECT COALESCE(SUM(p.allocated_qty - p.released_qty), 0)
        INTO v_other_source
        FROM production_material_supply_pegs p
        WHERE p.id IS DISTINCT FROM NEW.id
          AND p.supply_type = NEW.supply_type
          AND p.supply_item_id = NEW.supply_item_id;

        IF v_other_source + v_new_source_committed
           > v_source_qty * v_source_rate THEN
            RAISE EXCEPTION 'material supply peg exceeds source quantity'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_supply_peg_capacity_guard';
        END IF;
    END IF;

    IF v_new_demand_effective > v_old_demand_effective THEN
        SELECT COALESCE(SUM(
                   p.allocated_qty - p.consumed_qty - p.released_qty
               ), 0)
        INTO v_other_demand
        FROM production_material_supply_pegs p
        WHERE p.id IS DISTINCT FROM NEW.id
          AND p.demand_id = NEW.demand_id
          AND p.status <> 'REVERSED';

        SELECT COALESCE(SUM(r.qty - r.released_qty), 0)
        INTO v_stock_demand
        FROM stock_reservations r
        WHERE r.demand_id = NEW.demand_id
          AND r.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
          AND r.is_deleted = FALSE;

        IF v_other_demand + v_stock_demand + v_new_demand_effective
           > v_demand.required_qty - v_demand.released_qty THEN
            RAISE EXCEPTION 'material supply peg exceeds demand quantity'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_supply_peg_demand_capacity_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_production_supply_source_item()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_supply_type text;
    v_constraint text;
BEGIN
    IF TG_TABLE_NAME = 'purchase_request_items' THEN
        v_supply_type := 'PURCHASE_REQUEST_ITEM';
        v_constraint := 'production_purchase_request_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'subcontract_application_items' THEN
        v_supply_type := 'SUBCONTRACT_APPLICATION_ITEM';
        v_constraint := 'production_subcontract_application_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'purchase_order_items' THEN
        v_supply_type := 'PURCHASE_ORDER_ITEM';
        v_constraint := 'production_purchase_order_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'subcontract_order_items' THEN
        v_supply_type := 'SUBCONTRACT_ORDER_ITEM';
        v_constraint := 'production_subcontract_order_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'production_plan_items' THEN
        v_supply_type := 'PRODUCTION_PLAN_ITEM';
        v_constraint := 'production_plan_item_supply_guard';
    ELSE
        RAISE EXCEPTION 'unsupported production supply source table'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_supply_source_table_guard';
    END IF;

    IF fn_has_protected_production_supply_peg(v_supply_type, OLD.id) THEN
        RAISE EXCEPTION
            'production-linked supply source item cannot be changed or deleted'
            USING ERRCODE = '23514',
                  CONSTRAINT = v_constraint;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_guard_production_plan_item_supply_update
    AFTER UPDATE OF
        id, plan_id, goods_id, color_id, unit_id,
        unit_rate, qty, is_deleted
    ON production_plan_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_supply_source_item();

CREATE CONSTRAINT TRIGGER trg_guard_production_plan_item_supply_delete
    AFTER DELETE ON production_plan_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_supply_source_item();

CREATE OR REPLACE FUNCTION fn_assert_active_make_supply_source(
    p_child_plan_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_supply_pegs peg
        JOIN production_plan_items source_item
          ON source_item.id = peg.supply_item_id
        JOIN production_material_demands demand
          ON demand.id = peg.demand_id
        WHERE peg.supply_type = 'PRODUCTION_PLAN_ITEM'
          AND peg.status NOT IN ('RELEASED', 'REVERSED')
          AND peg.allocated_qty - peg.released_qty > 0
          AND source_item.plan_id = p_child_plan_id
          AND NOT (
              source_item.is_deleted = FALSE
              AND demand.is_deleted = FALSE
              AND demand.status NOT IN ('RELEASED', 'REVERSED')
              AND demand.supply_route = 'MAKE'
              AND EXISTS (
                  SELECT 1
                  FROM production_plans child
                  WHERE child.id = source_item.plan_id
                    AND child.is_deleted = FALSE
                    AND child.status <> -1
              )
              AND EXISTS (
                  SELECT 1
                  FROM subplan_links link
                  WHERE link.subplan_id = source_item.plan_id
                    AND link.plan_id = demand.plan_id
                    AND link.planning_package_id = demand.package_id
                    AND link.source = 'EXECUTION_V1'
                    AND link.is_deleted = FALSE
              )
          )
    ) THEN
        RAISE EXCEPTION 'active MAKE peg lost its child plan or package link'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_make_supply_source_link_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_active_make_supply_source()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_plan_id uuid;
    v_new_plan_id uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_plan_id := CASE
            WHEN TG_TABLE_NAME = 'subplan_links'
                THEN (to_jsonb(OLD) ->> 'subplan_id')::uuid
            ELSE OLD.id
        END;
        PERFORM fn_assert_active_make_supply_source(v_old_plan_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new_plan_id := CASE
            WHEN TG_TABLE_NAME = 'subplan_links'
                THEN (to_jsonb(NEW) ->> 'subplan_id')::uuid
            ELSE NEW.id
        END;
        IF v_new_plan_id IS DISTINCT FROM v_old_plan_id THEN
            PERFORM fn_assert_active_make_supply_source(v_new_plan_id);
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_guard_active_make_source_plan
    AFTER UPDATE OF status, is_deleted OR DELETE
    ON production_plans
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_active_make_supply_source();

CREATE CONSTRAINT TRIGGER trg_guard_active_make_subplan_link
    AFTER INSERT OR UPDATE OR DELETE
    ON subplan_links
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_active_make_supply_source();

CREATE TABLE production_material_make_receipt_allocations (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_id        UUID NOT NULL REFERENCES stock_documents(id),
    receipt_item_id   UUID NOT NULL REFERENCES stock_document_items(id),
    package_id        UUID NOT NULL REFERENCES production_planning_packages(id),
    demand_id         UUID NOT NULL REFERENCES production_material_demands(id),
    supply_peg_id     UUID NOT NULL REFERENCES production_material_supply_pegs(id),
    reservation_id    UUID NOT NULL REFERENCES stock_reservations(id),
    draw_id           UUID NOT NULL REFERENCES stock_documents(id),
    draw_item_id      UUID NOT NULL REFERENCES stock_document_items(id),
    allocated_qty     NUMERIC(18,4) NOT NULL,
    status            TEXT NOT NULL DEFAULT 'EFFECTIVE',
    idempotency_key   TEXT NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    updated_by        UUID,
    CONSTRAINT production_material_make_receipt_qty_chk
        CHECK (allocated_qty > 0),
    CONSTRAINT production_material_make_receipt_status_chk
        CHECK (status IN ('EFFECTIVE', 'REVERSED')),
    CONSTRAINT production_material_make_receipt_key_chk
        CHECK (length(btrim(idempotency_key)) BETWEEN 8 AND 128)
);

CREATE UNIQUE INDEX uq_production_material_make_receipt_key
    ON production_material_make_receipt_allocations(idempotency_key);
CREATE UNIQUE INDEX uq_production_material_make_receipt_active
    ON production_material_make_receipt_allocations(
        receipt_item_id, supply_peg_id)
    WHERE status = 'EFFECTIVE';
CREATE INDEX idx_production_material_make_receipt_receipt
    ON production_material_make_receipt_allocations(receipt_id, status);
CREATE INDEX idx_production_material_make_receipt_peg
    ON production_material_make_receipt_allocations(supply_peg_id, status);
CREATE INDEX idx_production_material_make_receipt_reservation
    ON production_material_make_receipt_allocations(reservation_id, status);
CREATE INDEX idx_production_material_make_receipt_draw
    ON production_material_make_receipt_allocations(draw_id, status);

CREATE OR REPLACE FUNCTION fn_lock_make_receipt_allocation_capacity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1
    FROM production_planning_packages package
    WHERE package.id = NEW.package_id
    FOR UPDATE;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'MAKE_RECEIPT_ITEM:' || NEW.receipt_item_id::text,
            6148615593807138892
        )
    );
    PERFORM 1
    FROM stock_document_items receipt_item
    WHERE receipt_item.id = NEW.receipt_item_id
    FOR UPDATE;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'MAKE_RESERVATION:' || NEW.reservation_id::text,
            6148615593807138892
        )
    );
    PERFORM 1
    FROM stock_reservations reservation
    WHERE reservation.id = NEW.reservation_id
    FOR UPDATE;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_lock_make_receipt_allocation_capacity
    BEFORE INSERT OR UPDATE
    ON production_material_make_receipt_allocations
    FOR EACH ROW
    EXECUTE FUNCTION fn_lock_make_receipt_allocation_capacity();

CREATE TRIGGER trg_audit_production_material_make_receipts
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_make_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE FUNCTION fn_guard_make_receipt_allocation_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'MAKE receipt allocation is append-only'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_make_receipt_append_only_guard';
    END IF;
    IF NEW.receipt_id IS DISTINCT FROM OLD.receipt_id
       OR NEW.receipt_item_id IS DISTINCT FROM OLD.receipt_item_id
       OR NEW.package_id IS DISTINCT FROM OLD.package_id
       OR NEW.demand_id IS DISTINCT FROM OLD.demand_id
       OR NEW.supply_peg_id IS DISTINCT FROM OLD.supply_peg_id
       OR NEW.reservation_id IS DISTINCT FROM OLD.reservation_id
       OR NEW.draw_id IS DISTINCT FROM OLD.draw_id
       OR NEW.draw_item_id IS DISTINCT FROM OLD.draw_item_id
       OR NEW.allocated_qty IS DISTINCT FROM OLD.allocated_qty
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key THEN
        RAISE EXCEPTION 'MAKE receipt allocation identity is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_make_receipt_identity_guard';
    END IF;
    IF OLD.status = 'REVERSED'
       AND NEW.status IS DISTINCT FROM 'REVERSED' THEN
        RAISE EXCEPTION 'MAKE receipt allocation cannot be reactivated'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_make_receipt_lifecycle_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_make_receipt_no_delete
    BEFORE DELETE ON production_material_make_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_make_receipt_allocation_lifecycle();
CREATE TRIGGER trg_guard_make_receipt_update
    BEFORE UPDATE ON production_material_make_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_make_receipt_allocation_lifecycle();

CREATE OR REPLACE FUNCTION fn_guard_make_receipt_allocation_reversal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_issued numeric;
BEGIN
    IF OLD.status = 'EFFECTIVE' AND NEW.status = 'REVERSED' THEN
        SELECT GREATEST(
                   COALESCE(item.issued_qty, 0),
                   COALESCE((
                       SELECT SUM(CASE posting_type
                           WHEN 'ISSUE' THEN qty_base
                           WHEN 'ISSUE_REVERSE' THEN -qty_base
                           ELSE 0 END)
                       FROM production_material_stock_postings
                       WHERE stock_document_item_id = item.id
                         AND posting_type IN ('ISSUE', 'ISSUE_REVERSE')
                   ), 0)
               )
        INTO v_issued
        FROM stock_document_items item
        WHERE item.id = OLD.draw_item_id
        FOR UPDATE;

        IF COALESCE(v_issued, 0) > 0 THEN
            RAISE EXCEPTION 'MAKE receipt material has already been issued'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_make_receipt_issued_draw_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_make_receipt_reversal
    BEFORE UPDATE OF status
    ON production_material_make_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_make_receipt_allocation_reversal();

CREATE OR REPLACE FUNCTION fn_assert_make_receipt_allocation(
    p_allocation_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_make_receipt_allocations allocation
        WHERE allocation.id = p_allocation_id
          AND allocation.status = 'EFFECTIVE'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM production_material_make_receipt_allocations allocation
        JOIN stock_documents receipt
          ON receipt.id = allocation.receipt_id
        JOIN stock_document_items receipt_item
          ON receipt_item.id = allocation.receipt_item_id
        JOIN production_material_supply_pegs supply_peg
          ON supply_peg.id = allocation.supply_peg_id
        JOIN production_plan_items source_item
          ON source_item.id = supply_peg.supply_item_id
        JOIN production_plans source_plan
          ON source_plan.id = source_item.plan_id
        JOIN production_material_demands demand
          ON demand.id = allocation.demand_id
        JOIN production_planning_packages package
          ON package.id = allocation.package_id
        JOIN stock_reservations reservation
          ON reservation.id = allocation.reservation_id
        JOIN stock_documents draw
          ON draw.id = allocation.draw_id
        JOIN stock_document_items draw_item
          ON draw_item.id = allocation.draw_item_id
        WHERE allocation.id = p_allocation_id
          AND allocation.status = 'EFFECTIVE'
          AND package.status = 'CONFIRMED'
          AND package.execution_model_version = 1
          AND package.is_deleted = FALSE
          AND receipt.doc_type = 'FINISHED_IN'
          AND receipt.status = 1
          AND receipt.is_deleted = FALSE
          AND receipt.warehouse_id = demand.warehouse_id
          AND receipt_item.doc_id = allocation.receipt_id
          AND receipt_item.bill_type = 'FINISHED_IN'
          AND receipt_item.is_deleted = FALSE
          AND receipt_item.upstream_item_id = source_item.id
          AND receipt_item.goods_id = demand.goods_id
          AND receipt_item.color_id IS NOT DISTINCT FROM demand.color_id
          AND receipt_item.unit_id = demand.unit_id
          AND source_item.is_deleted = FALSE
          AND source_plan.is_deleted = FALSE
          AND source_plan.status <> -1
          AND source_item.goods_id = demand.goods_id
          AND source_item.color_id IS NOT DISTINCT FROM demand.color_id
          AND source_item.unit_id = demand.unit_id
          AND supply_peg.supply_type = 'PRODUCTION_PLAN_ITEM'
          AND supply_peg.supply_item_id = source_item.id
          AND supply_peg.demand_id = allocation.demand_id
          AND supply_peg.status NOT IN ('RELEASED', 'REVERSED')
          AND demand.package_id = allocation.package_id
          AND demand.supply_route = 'MAKE'
          AND demand.is_deleted = FALSE
          AND demand.status NOT IN ('RELEASED', 'REVERSED')
          AND EXISTS (
              SELECT 1
              FROM subplan_links link
              WHERE link.subplan_id = source_item.plan_id
                AND link.plan_id = demand.plan_id
                AND link.planning_package_id = allocation.package_id
                AND link.source = 'EXECUTION_V1'
                AND link.is_deleted = FALSE
          )
          AND reservation.demand_id = allocation.demand_id
          AND reservation.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
          AND reservation.owner_id = allocation.demand_id
          AND reservation.purpose = 'PRODUCTION_MATERIAL'
          AND reservation.goods_id = demand.goods_id
          AND reservation.color_id IS NOT DISTINCT FROM demand.color_id
          AND reservation.warehouse_id = demand.warehouse_id
          AND reservation.is_deleted = FALSE
          AND reservation.status = 0
          AND draw.doc_type = 'DRAW'
          AND draw.warehouse_id = demand.warehouse_id
          AND draw.is_deleted = FALSE
          AND draw.status <> -1
          AND draw_item.doc_id = allocation.draw_id
          AND draw_item.goods_id = demand.goods_id
          AND draw_item.color_id IS NOT DISTINCT FROM demand.color_id
          AND draw_item.unit_id = demand.unit_id
          AND COALESCE(
                draw_item.base_qty,
                draw_item.qty * COALESCE(draw_item.unit_rate, 1)
              ) = allocation.allocated_qty
          AND draw_item.is_deleted = FALSE
          AND EXISTS (
              SELECT 1
              FROM plan_draw_links plan_link
              WHERE plan_link.plan_id = demand.plan_id
                AND plan_link.draw_id = allocation.draw_id
                AND plan_link.is_deleted = FALSE
          )
          AND EXISTS (
              SELECT 1
              FROM production_planning_package_documents package_document
              WHERE package_document.package_id = allocation.package_id
                AND package_document.document_type = 'DRAW'
                AND package_document.document_id = allocation.draw_id
                AND package_document.execution_segment_id
                      IS NOT DISTINCT FROM demand.execution_segment_id
          )
          AND EXISTS (
              SELECT 1
              FROM production_planning_package_document_items package_item
              WHERE package_item.package_id = allocation.package_id
                AND package_item.demand_id = allocation.demand_id
                AND package_item.document_type = 'DRAW'
                AND package_item.document_id = allocation.draw_id
                AND package_item.document_item_id = allocation.draw_item_id
          )
    ) THEN
        RAISE EXCEPTION 'MAKE receipt allocation provenance is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_make_receipt_provenance_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_make_receipt_capacity(
    p_receipt_item_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity numeric;
    v_allocated numeric;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'MAKE_RECEIPT_ITEM:' || p_receipt_item_id::text,
            6148615593807138892
        )
    );
    SELECT COALESCE(base_qty, qty * COALESCE(unit_rate, 1))
    INTO v_capacity
    FROM stock_document_items
    WHERE id = p_receipt_item_id
      AND bill_type = 'FINISHED_IN'
      AND is_deleted = FALSE
    FOR UPDATE;

    SELECT COALESCE(SUM(allocated_qty), 0)
    INTO v_allocated
    FROM production_material_make_receipt_allocations
    WHERE receipt_item_id = p_receipt_item_id
      AND status = 'EFFECTIVE';

    IF v_allocated > COALESCE(v_capacity, 0) THEN
        RAISE EXCEPTION 'finished-in item is over-allocated to MAKE demand'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_make_receipt_capacity_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_make_reservation_capacity(
    p_reservation_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity numeric;
    v_allocated numeric;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'MAKE_RESERVATION:' || p_reservation_id::text,
            6148615593807138892
        )
    );
    SELECT qty - released_qty
    INTO v_capacity
    FROM stock_reservations
    WHERE id = p_reservation_id
      AND owner_type = 'PRODUCTION_MATERIAL_DEMAND'
      AND is_deleted = FALSE
    FOR UPDATE;

    SELECT COALESCE(SUM(allocated_qty), 0)
    INTO v_allocated
    FROM production_material_make_receipt_allocations
    WHERE reservation_id = p_reservation_id
      AND status = 'EFFECTIVE';

    IF v_allocated > COALESCE(v_capacity, 0) THEN
        RAISE EXCEPTION 'MAKE receipt allocation exceeds reservation quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_make_receipt_reservation_capacity_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_make_peg_conservation(
    p_peg_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_consumed numeric;
    v_allocated numeric;
BEGIN
    SELECT consumed_qty
    INTO v_consumed
    FROM production_material_supply_pegs
    WHERE id = p_peg_id
      AND supply_type = 'PRODUCTION_PLAN_ITEM';

    SELECT COALESCE(SUM(allocated_qty), 0)
    INTO v_allocated
    FROM production_material_make_receipt_allocations
    WHERE supply_peg_id = p_peg_id
      AND status = 'EFFECTIVE';

    IF v_allocated IS DISTINCT FROM COALESCE(v_consumed, 0) THEN
        RAISE EXCEPTION 'MAKE peg consumption lacks exact receipt provenance'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_make_peg_conservation_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_make_receipt_allocation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM fn_assert_make_receipt_capacity(OLD.receipt_item_id);
        PERFORM fn_assert_make_reservation_capacity(OLD.reservation_id);
        PERFORM fn_assert_make_peg_conservation(OLD.supply_peg_id);
        PERFORM fn_assert_make_receipt_allocation(OLD.id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM fn_assert_make_receipt_capacity(NEW.receipt_item_id);
        PERFORM fn_assert_make_reservation_capacity(NEW.reservation_id);
        PERFORM fn_assert_make_peg_conservation(NEW.supply_peg_id);
        PERFORM fn_assert_make_receipt_allocation(NEW.id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_check_make_receipt_allocation
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_make_receipt_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_allocation();

CREATE OR REPLACE FUNCTION fn_check_make_receipt_source()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_id uuid;
    v_new_id uuid;
    v_allocation_id uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_id := CASE
            WHEN TG_TABLE_NAME = 'plan_draw_links'
                THEN (to_jsonb(OLD) ->> 'draw_id')::uuid
            WHEN TG_TABLE_NAME = 'subplan_links'
                THEN (to_jsonb(OLD) ->> 'subplan_id')::uuid
            WHEN TG_TABLE_NAME = 'production_planning_package_documents'
                THEN (to_jsonb(OLD) ->> 'document_id')::uuid
            WHEN TG_TABLE_NAME = 'production_planning_package_document_items'
                THEN (to_jsonb(OLD) ->> 'document_item_id')::uuid
            ELSE (to_jsonb(OLD) ->> 'id')::uuid
        END;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new_id := CASE
            WHEN TG_TABLE_NAME = 'plan_draw_links'
                THEN (to_jsonb(NEW) ->> 'draw_id')::uuid
            WHEN TG_TABLE_NAME = 'subplan_links'
                THEN (to_jsonb(NEW) ->> 'subplan_id')::uuid
            WHEN TG_TABLE_NAME = 'production_planning_package_documents'
                THEN (to_jsonb(NEW) ->> 'document_id')::uuid
            WHEN TG_TABLE_NAME = 'production_planning_package_document_items'
                THEN (to_jsonb(NEW) ->> 'document_item_id')::uuid
            ELSE (to_jsonb(NEW) ->> 'id')::uuid
        END;
    END IF;

    FOR v_allocation_id IN
        SELECT allocation.id
        FROM production_material_make_receipt_allocations allocation
        JOIN production_material_supply_pegs peg
          ON peg.id = allocation.supply_peg_id
        LEFT JOIN production_plan_items source_item
          ON source_item.id = peg.supply_item_id
        WHERE allocation.status = 'EFFECTIVE'
          AND (
              (TG_TABLE_NAME = 'stock_documents' AND (
                  allocation.receipt_id IN (v_old_id, v_new_id)
                  OR allocation.draw_id IN (v_old_id, v_new_id)))
              OR (TG_TABLE_NAME = 'stock_document_items' AND (
                  allocation.receipt_item_id IN (v_old_id, v_new_id)
                  OR allocation.draw_item_id IN (v_old_id, v_new_id)))
              OR (TG_TABLE_NAME = 'production_material_demands'
                  AND allocation.demand_id IN (v_old_id, v_new_id))
              OR (TG_TABLE_NAME = 'production_material_supply_pegs'
                  AND allocation.supply_peg_id IN (v_old_id, v_new_id))
              OR (TG_TABLE_NAME = 'stock_reservations'
                  AND allocation.reservation_id IN (v_old_id, v_new_id))
              OR (TG_TABLE_NAME = 'production_planning_packages'
                  AND allocation.package_id IN (v_old_id, v_new_id))
              OR (TG_TABLE_NAME = 'production_plan_items'
                  AND peg.supply_item_id IN (v_old_id, v_new_id))
              OR (TG_TABLE_NAME = 'production_plans'
                  AND source_item.plan_id IN (v_old_id, v_new_id))
              OR (TG_TABLE_NAME = 'subplan_links'
                  AND source_item.plan_id IN (v_old_id, v_new_id))
              OR (TG_TABLE_NAME IN (
                      'plan_draw_links',
                      'production_planning_package_documents')
                  AND allocation.draw_id IN (v_old_id, v_new_id))
              OR (TG_TABLE_NAME =
                      'production_planning_package_document_items'
                  AND allocation.draw_item_id IN (v_old_id, v_new_id))
          )
    LOOP
        PERFORM fn_assert_make_receipt_capacity((
            SELECT receipt_item_id
            FROM production_material_make_receipt_allocations
            WHERE id = v_allocation_id));
        PERFORM fn_assert_make_reservation_capacity((
            SELECT reservation_id
            FROM production_material_make_receipt_allocations
            WHERE id = v_allocation_id));
        PERFORM fn_assert_make_peg_conservation((
            SELECT supply_peg_id
            FROM production_material_make_receipt_allocations
            WHERE id = v_allocation_id));
        PERFORM fn_assert_make_receipt_allocation(v_allocation_id);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_make_receipt_stock_document_source
    AFTER INSERT OR UPDATE OR DELETE ON stock_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_stock_item_source
    AFTER INSERT OR UPDATE OR DELETE ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_demand_source
    AFTER INSERT OR UPDATE OR DELETE ON production_material_demands
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_peg_source
    AFTER INSERT OR UPDATE OR DELETE ON production_material_supply_pegs
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_reservation_source
    AFTER INSERT OR UPDATE OR DELETE ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_package_source
    AFTER INSERT OR UPDATE OR DELETE ON production_planning_packages
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_plan_item_source
    AFTER INSERT OR UPDATE OR DELETE ON production_plan_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_plan_source
    AFTER INSERT OR UPDATE OR DELETE ON production_plans
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_subplan_link_source
    AFTER INSERT OR UPDATE OR DELETE ON subplan_links
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_plan_draw_source
    AFTER INSERT OR UPDATE OR DELETE ON plan_draw_links
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_package_draw_source
    AFTER INSERT OR UPDATE OR DELETE
    ON production_planning_package_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();
CREATE CONSTRAINT TRIGGER trg_make_receipt_package_item_source
    AFTER INSERT OR UPDATE OR DELETE
    ON production_planning_package_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_make_receipt_source();

-- Replace the V155 deferred validator. The only semantic change is that MAKE
-- is now a supported authoritative route; all complete-kit guards remain.
CREATE OR REPLACE FUNCTION fn_assert_execution_segment_integrity(
    p_segment_id UUID
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment production_execution_segments%ROWTYPE;
    v_package_status TEXT;
    v_demand_count BIGINT;
    v_bad_count BIGINT;
    v_ready_count BIGINT;
    v_fully_backed_count BIGINT;
    v_nonzero_count BIGINT;
BEGIN
    SELECT * INTO v_segment
    FROM production_execution_segments
    WHERE id = p_segment_id AND is_deleted = FALSE;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    SELECT status INTO v_package_status
    FROM production_planning_packages
    WHERE id = v_segment.package_id AND is_deleted = FALSE;
    IF v_package_status IS DISTINCT FROM 'CONFIRMED' THEN
        RETURN;
    END IF;
    IF v_segment.status IN ('CANCELLED', 'REVERSED') THEN
        RAISE EXCEPTION 'confirmed package cannot contain terminal segment'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_active_guard';
    END IF;

    SELECT COUNT(*),
           COUNT(*) FILTER (
               WHERE required_qty IS DISTINCT FROM
                   ceil((v_segment.planned_qty * per_product_qty) * 10000)
                   / 10000
                  OR package_id <> v_segment.package_id
                  OR plan_id <> v_segment.plan_id
                  OR source_plan_item_id <> v_segment.source_plan_item_id
                  OR warehouse_id IS DISTINCT FROM (
                      SELECT warehouse_id
                      FROM production_planning_packages
                      WHERE id = v_segment.package_id
                  )
           )
    INTO v_demand_count, v_bad_count
    FROM production_material_demands
    WHERE execution_segment_id = v_segment.id
      AND is_deleted = FALSE;
    IF v_demand_count = 0 OR v_bad_count > 0 THEN
        RAISE EXCEPTION 'execution segment demand snapshot is missing or inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_demand_guard';
    END IF;

    WITH coverage AS (
        SELECT d.id,
               d.required_qty,
               COALESCE((
                   SELECT SUM(r.qty - r.released_qty)
                   FROM stock_reservations r
                   WHERE r.demand_id = d.id
                     AND r.is_deleted = FALSE
               ), 0) AS stock_backed,
               COALESCE((
                   SELECT SUM(COALESCE(i.base_qty, i.qty * COALESCE(i.unit_rate, 1)))
                   FROM production_planning_package_document_items m
                   JOIN production_planning_package_documents h
                     ON h.package_id = m.package_id
                    AND h.document_type = m.document_type
                    AND h.document_id = m.document_id
                   JOIN stock_documents sd
                     ON sd.id = m.document_id
                    AND sd.doc_type = 'DRAW'
                    AND sd.is_deleted = FALSE
                    AND sd.status <> -1
                   JOIN stock_document_items i
                     ON i.id = m.document_item_id
                    AND i.doc_id = m.document_id
                   WHERE m.demand_id = d.id
                     AND m.document_type = 'DRAW'
                     AND h.execution_segment_id = v_segment.id
               ), 0) AS draw_backed
        FROM production_material_demands d
        WHERE d.execution_segment_id = v_segment.id
          AND d.is_deleted = FALSE
    )
    SELECT COUNT(*) FILTER (
               WHERE stock_backed >= required_qty
                 AND draw_backed >= required_qty
           ),
           COUNT(*) FILTER (
               WHERE stock_backed >= required_qty
                 AND draw_backed >= required_qty
           ),
           COUNT(*) FILTER (
               WHERE stock_backed > 0 OR draw_backed > 0
           ),
           COUNT(*) FILTER (
               WHERE stock_backed > required_qty
                 OR draw_backed > required_qty
                 OR (
                     v_segment.status <> 'COMPLETED'
                     AND NOT (
                         v_segment.status = 'IN_PROGRESS'
                         AND v_segment.completion_reopened
                     )
                     AND draw_backed > stock_backed
                 )
           )
    INTO v_ready_count, v_fully_backed_count, v_nonzero_count,
         v_bad_count
    FROM coverage;

    IF v_bad_count > 0 THEN
        RAISE EXCEPTION 'execution segment material is over-reserved or over-drawn'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_overallocation_guard';
    END IF;
    IF v_segment.status IN ('READY', 'DISPATCHED', 'IN_PROGRESS')
       AND NOT (
           v_segment.status = 'IN_PROGRESS'
           AND v_segment.completion_reopened
       )
       AND v_ready_count <> v_demand_count THEN
        RAISE EXCEPTION 'READY execution segment is not fully stock/DRAW backed'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_ready_guard';
    END IF;
    IF v_segment.status = 'WAITING'
       AND v_nonzero_count > 0 THEN
        RAISE EXCEPTION 'WAITING execution segment cannot hold partial stock or DRAW'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_waiting_allocation_guard';
    END IF;
    IF v_segment.status = 'WAITING'
       AND v_fully_backed_count = v_demand_count THEN
        RAISE EXCEPTION 'fully backed execution segment must be promoted to READY'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_promotion_guard';
    END IF;
    IF v_segment.status = 'COMPLETED'
       AND (
           EXISTS (
               SELECT 1
               FROM production_material_demands demand
               LEFT JOIN v_production_material_clearance clearance
                 ON clearance.demand_id = demand.id
               WHERE demand.execution_segment_id = v_segment.id
                 AND demand.is_deleted = FALSE
                 AND demand.status NOT IN ('RELEASED', 'REVERSED')
                 AND COALESCE(clearance.can_close, FALSE) = FALSE
           )
           OR EXISTS (
               SELECT 1
               FROM stock_reservations reservation
               JOIN production_material_demands demand
                 ON demand.id = reservation.demand_id
               WHERE demand.execution_segment_id = v_segment.id
                 AND reservation.owner_type =
                     'PRODUCTION_MATERIAL_DEMAND'
                 AND reservation.is_deleted = FALSE
                 AND reservation.qty
                       - reservation.consumed_qty
                       - reservation.released_qty > 0
           )
       ) THEN
        RAISE EXCEPTION
            'completed execution segment has uncleared material or open stock'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_completion_clearance_guard';
    END IF;

    SELECT COUNT(*) INTO v_bad_count
    FROM production_planning_package_document_items m
    JOIN production_material_demands d ON d.id = m.demand_id
    JOIN production_planning_package_documents h
      ON h.package_id = m.package_id
     AND h.document_type = m.document_type
     AND h.document_id = m.document_id
    WHERE d.execution_segment_id = v_segment.id
      AND (
          m.package_id <> v_segment.package_id
          OR h.execution_segment_id IS DISTINCT FROM v_segment.id
      );
    IF v_bad_count > 0 THEN
        RAISE EXCEPTION 'DRAW header/item is mapped to a different execution segment'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_draw_mapping_guard';
    END IF;
END;
$$;

-- End of execution-segment validator replacement.

COMMENT ON TABLE production_material_make_receipt_allocations IS
    'Append-only FINISHED_IN to parent MAKE demand/reservation/DRAW provenance.';
