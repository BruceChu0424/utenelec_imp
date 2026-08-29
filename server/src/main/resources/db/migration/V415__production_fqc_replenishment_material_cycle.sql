-- V415: physical-material closure for SCRAP/REJECT FQC replacement attempts.
--
-- A replenishment cycle is independent from the original execution segment's
-- normal kit.  Its demands still belong to the exact original plan/package,
-- but execution_segment_id stays NULL so an already IN_PROGRESS segment can
-- persist a shortage without violating the original READY invariant.  The
-- FQC authorization remains the authoritative product-quantity identity.

ALTER TABLE production_material_demands
    ADD COLUMN fqc_recovery_authorization_id UUID
        REFERENCES production_fqc_recovery_authorizations(id)
        ON DELETE RESTRICT,
    ADD COLUMN fqc_replenishment_cycle_id UUID;

CREATE TABLE production_fqc_replenishment_cycles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    replenishment_task_id UUID NOT NULL
        REFERENCES production_fqc_replenishment_tasks(id) ON DELETE RESTRICT,
    authorization_id UUID NOT NULL
        REFERENCES production_fqc_recovery_authorizations(id) ON DELETE RESTRICT,
    generation INTEGER NOT NULL CHECK (generation > 0),
    package_id UUID NOT NULL
        REFERENCES production_planning_packages(id) ON DELETE RESTRICT,
    plan_id UUID NOT NULL REFERENCES production_plans(id) ON DELETE RESTRICT,
    source_plan_item_id UUID NOT NULL
        REFERENCES production_plan_items(id) ON DELETE RESTRICT,
    source_execution_segment_id UUID NOT NULL
        REFERENCES production_execution_segments(id) ON DELETE RESTRICT,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    product_qty NUMERIC(18,4) NOT NULL CHECK (product_qty > 0),
    planning_snapshot_fingerprint CHAR(64) NOT NULL
        CHECK (planning_snapshot_fingerprint ~ '^[0-9a-f]{64}$'),
    bom_fingerprint CHAR(64) NOT NULL
        CHECK (bom_fingerprint ~ '^[0-9a-f]{64}$'),
    initial_idempotency_key TEXT NOT NULL UNIQUE,
    request_hash CHAR(64) NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_replenishment_cycle_generation_uk
        UNIQUE (authorization_id, generation)
);

ALTER TABLE production_material_demands
    ADD CONSTRAINT fk_production_material_demand_fqc_cycle
    FOREIGN KEY (fqc_replenishment_cycle_id)
    REFERENCES production_fqc_replenishment_cycles(id)
    ON DELETE RESTRICT;

ALTER TABLE production_material_demands
    DROP CONSTRAINT production_material_demand_segment_shape_chk;
ALTER TABLE production_material_demands
    ADD CONSTRAINT production_material_demand_segment_shape_chk CHECK (
        (
            execution_segment_id IS NULL
            AND fqc_replenishment_cycle_id IS NULL
            AND fqc_recovery_authorization_id IS NULL
            AND source_plan_item_id IS NULL
            AND per_product_qty IS NULL
        )
        OR (
            execution_segment_id IS NOT NULL
            AND fqc_replenishment_cycle_id IS NULL
            AND fqc_recovery_authorization_id IS NULL
            AND source_plan_item_id IS NOT NULL
            AND per_product_qty > 0
        )
        OR (
            execution_segment_id IS NULL
            AND fqc_replenishment_cycle_id IS NOT NULL
            AND fqc_recovery_authorization_id IS NOT NULL
            AND source_plan_item_id IS NOT NULL
            AND per_product_qty > 0
        )
    );

DROP INDEX uq_production_material_demand_dimension;
CREATE UNIQUE INDEX uq_production_material_demand_dimension
    ON production_material_demands(
        package_id, execution_segment_id, fqc_replenishment_cycle_id,
        goods_id, color_id, need_date
    ) NULLS NOT DISTINCT
    WHERE is_deleted = FALSE;
CREATE UNIQUE INDEX uq_production_material_demand_fqc_cycle_dimension
    ON production_material_demands(
        fqc_replenishment_cycle_id, goods_id, color_id
    ) NULLS NOT DISTINCT
    WHERE fqc_replenishment_cycle_id IS NOT NULL AND is_deleted = FALSE;

ALTER TABLE production_material_demands
    DROP CONSTRAINT production_material_demand_requirement_snapshot_chk;
ALTER TABLE production_material_demands
    ADD CONSTRAINT production_material_demand_requirement_snapshot_chk CHECK (
        (
            requirement_mode = 'LINEAR'
            AND required_for_product_qty IS NULL
            AND requirement_fingerprint IS NULL
            AND fqc_replenishment_cycle_id IS NULL
            AND fqc_recovery_authorization_id IS NULL
        )
        OR
        (
            requirement_mode = 'EXACT_SNAPSHOT'
            AND source_plan_item_id IS NOT NULL
            AND required_for_product_qty > 0
            AND requirement_fingerprint ~ '^[0-9a-f]{64}$'
            AND (
                (
                    execution_segment_id IS NOT NULL
                    AND fqc_replenishment_cycle_id IS NULL
                    AND fqc_recovery_authorization_id IS NULL
                )
                OR
                (
                    execution_segment_id IS NULL
                    AND fqc_replenishment_cycle_id IS NOT NULL
                    AND fqc_recovery_authorization_id IS NOT NULL
                )
            )
        )
    );

CREATE TABLE production_fqc_replenishment_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cycle_id UUID NOT NULL
        REFERENCES production_fqc_replenishment_cycles(id) ON DELETE RESTRICT,
    authorization_id UUID NOT NULL
        REFERENCES production_fqc_recovery_authorizations(id) ON DELETE RESTRICT,
    idempotency_key TEXT NOT NULL UNIQUE,
    request_hash CHAR(64) NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    outcome TEXT NOT NULL CHECK (outcome IN ('BLOCKED', 'DRAW_PENDING')),
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE production_fqc_replenishment_supply_gaps (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    attempt_id UUID NOT NULL
        REFERENCES production_fqc_replenishment_attempts(id) ON DELETE RESTRICT,
    demand_id UUID NOT NULL
        REFERENCES production_material_demands(id) ON DELETE RESTRICT,
    supply_route TEXT NOT NULL CHECK (supply_route IN ('BUY','MAKE','SUBCONTRACT')),
    required_qty NUMERIC(18,4) NOT NULL CHECK (required_qty > 0),
    allocated_qty NUMERIC(18,4) NOT NULL CHECK (allocated_qty >= 0),
    shortage_qty NUMERIC(18,4) NOT NULL CHECK (shortage_qty > 0),
    blocked_reason TEXT NOT NULL CHECK (btrim(blocked_reason) <> ''),
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_fqc_replenishment_gap_qty_chk CHECK (
        allocated_qty + shortage_qty = required_qty),
    CONSTRAINT production_fqc_replenishment_gap_attempt_demand_uk
        UNIQUE (attempt_id, demand_id)
);

CREATE TABLE production_fqc_replenishment_draw_links (
    cycle_id UUID PRIMARY KEY
        REFERENCES production_fqc_replenishment_cycles(id) ON DELETE RESTRICT,
    authorization_id UUID NOT NULL UNIQUE
        REFERENCES production_fqc_recovery_authorizations(id) ON DELETE RESTRICT,
    stock_document_id UUID NOT NULL UNIQUE
        REFERENCES stock_documents(id) ON DELETE RESTRICT,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE production_fqc_replenishment_ready_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cycle_id UUID NOT NULL
        REFERENCES production_fqc_replenishment_cycles(id) ON DELETE RESTRICT,
    authorization_id UUID NOT NULL
        REFERENCES production_fqc_recovery_authorizations(id) ON DELETE RESTRICT,
    stock_document_id UUID NOT NULL
        REFERENCES stock_documents(id) ON DELETE RESTRICT,
    idempotency_key TEXT NOT NULL UNIQUE,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE production_fqc_replenishment_ready_reversals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ready_event_id UUID NOT NULL UNIQUE
        REFERENCES production_fqc_replenishment_ready_events(id) ON DELETE RESTRICT,
    reason_code TEXT NOT NULL CHECK (reason_code IN ('DRAW_ISSUE_REVERSED','AUTH_CANCELLED')),
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE production_fqc_replenishment_cycle_cancellations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cycle_id UUID NOT NULL UNIQUE
        REFERENCES production_fqc_replenishment_cycles(id) ON DELETE RESTRICT,
    authorization_id UUID NOT NULL
        REFERENCES production_fqc_recovery_authorizations(id) ON DELETE RESTRICT,
    reason_code TEXT NOT NULL CHECK (reason_code = 'AUTH_CANCELLED'),
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE VIEW v_production_fqc_replenishment_material_ready AS
SELECT cycle.authorization_id,
       cycle.id AS cycle_id,
       ready.id AS ready_event_id,
       ready.stock_document_id,
       ready.created_at AS ready_at
FROM production_fqc_replenishment_cycles cycle
JOIN production_fqc_replenishment_ready_events ready
  ON ready.cycle_id = cycle.id
 AND ready.authorization_id = cycle.authorization_id
LEFT JOIN production_fqc_replenishment_ready_reversals reversal
  ON reversal.ready_event_id = ready.id
LEFT JOIN production_fqc_replenishment_cycle_cancellations cancellation
  ON cancellation.cycle_id = cycle.id
LEFT JOIN production_fqc_recovery_cancellation_events authorization_cancellation
  ON authorization_cancellation.authorization_id = cycle.authorization_id
WHERE reversal.id IS NULL
  AND cancellation.id IS NULL
  AND authorization_cancellation.id IS NULL;

CREATE OR REPLACE FUNCTION fn_fqc_replenishment_material_ready(p_authorization_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM v_production_fqc_replenishment_material_ready ready
        WHERE ready.authorization_id = p_authorization_id
    );
$$;

CREATE OR REPLACE FUNCTION fn_guard_fqc_replenishment_cycle()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    task production_fqc_replenishment_tasks%ROWTYPE;
    recovery_auth production_fqc_recovery_authorizations%ROWTYPE;
    segment RECORD;
BEGIN
    SELECT * INTO task FROM production_fqc_replenishment_tasks
    WHERE id = NEW.replenishment_task_id;
    SELECT * INTO recovery_auth FROM production_fqc_recovery_authorizations
    WHERE id = NEW.authorization_id FOR UPDATE;
    SELECT s.plan_id, s.source_plan_item_id, s.package_id, p.status AS package_status
    INTO segment
    FROM production_execution_segments s
    JOIN production_planning_packages p ON p.id = s.package_id
    WHERE s.id = NEW.source_execution_segment_id
      AND s.is_deleted = FALSE AND p.is_deleted = FALSE;
    IF task.id IS NULL OR recovery_auth.id IS NULL OR segment IS NULL
       OR task.authorization_id IS DISTINCT FROM recovery_auth.id
       OR recovery_auth.disposition_code NOT IN ('SCRAP','REJECT')
       OR recovery_auth.execution_segment_id IS DISTINCT FROM NEW.source_execution_segment_id
       OR recovery_auth.source_plan_item_id IS DISTINCT FROM NEW.source_plan_item_id
       OR recovery_auth.warehouse_id IS DISTINCT FROM NEW.warehouse_id
       OR recovery_auth.authorized_qty IS DISTINCT FROM NEW.product_qty
       OR segment.plan_id IS DISTINCT FROM NEW.plan_id
       OR segment.source_plan_item_id IS DISTINCT FROM NEW.source_plan_item_id
       OR segment.package_id IS DISTINCT FROM NEW.package_id
       OR segment.package_status IS DISTINCT FROM 'CONFIRMED'
       OR NOT EXISTS (
            SELECT 1 FROM production_fqc_replenishment_analysis_links link
            WHERE link.replenishment_task_id = task.id
              AND link.authorization_id = recovery_auth.id)
       OR EXISTS (
            SELECT 1 FROM production_fqc_recovery_cancellation_events c
            WHERE c.authorization_id = recovery_auth.id) THEN
        RAISE EXCEPTION 'FQC replenishment cycle identity is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_replenishment_cycle_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_replenishment_cycle
    BEFORE INSERT ON production_fqc_replenishment_cycles
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_cycle();

CREATE OR REPLACE FUNCTION fn_guard_fqc_recovery_material_demand()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    cycle production_fqc_replenishment_cycles%ROWTYPE;
BEGIN
    IF NEW.fqc_replenishment_cycle_id IS NULL
       AND NEW.fqc_recovery_authorization_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT * INTO cycle FROM production_fqc_replenishment_cycles
    WHERE id = NEW.fqc_replenishment_cycle_id;
    IF cycle.id IS NULL
       OR NEW.fqc_recovery_authorization_id IS DISTINCT FROM cycle.authorization_id
       OR NEW.execution_segment_id IS NOT NULL
       OR NEW.package_id IS DISTINCT FROM cycle.package_id
       OR NEW.plan_id IS DISTINCT FROM cycle.plan_id
       OR NEW.source_plan_item_id IS DISTINCT FROM cycle.source_plan_item_id
       OR NEW.warehouse_id IS DISTINCT FROM cycle.warehouse_id
       OR NEW.requirement_mode IS DISTINCT FROM 'EXACT_SNAPSHOT'
       OR NEW.required_for_product_qty IS DISTINCT FROM cycle.product_qty
       OR NEW.requirement_fingerprint !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'FQC recovery material demand identity is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_recovery_material_demand_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_recovery_material_demand
    BEFORE INSERT OR UPDATE OF
        fqc_recovery_authorization_id, fqc_replenishment_cycle_id,
        execution_segment_id, package_id, plan_id, source_plan_item_id,
        warehouse_id, requirement_mode, required_for_product_qty,
        requirement_fingerprint
    ON production_material_demands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_recovery_material_demand();

CREATE OR REPLACE FUNCTION fn_guard_fqc_replenishment_draw_link()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    cycle production_fqc_replenishment_cycles%ROWTYPE;
    document stock_documents%ROWTYPE;
BEGIN
    SELECT * INTO cycle FROM production_fqc_replenishment_cycles
    WHERE id = NEW.cycle_id;
    SELECT * INTO document FROM stock_documents
    WHERE id = NEW.stock_document_id;
    IF cycle.id IS NULL OR document.id IS NULL
       OR NEW.authorization_id IS DISTINCT FROM cycle.authorization_id
       OR document.doc_type IS DISTINCT FROM 'DRAW'
       OR document.warehouse_id IS DISTINCT FROM cycle.warehouse_id
       OR document.status IS DISTINCT FROM 0
       OR document.is_deleted THEN
        RAISE EXCEPTION 'FQC replenishment DRAW identity is invalid'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_replenishment_draw_link
    BEFORE INSERT ON production_fqc_replenishment_draw_links
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_draw_link();

CREATE OR REPLACE FUNCTION fn_guard_fqc_replenishment_attempt()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    cycle production_fqc_replenishment_cycles%ROWTYPE;
BEGIN
    SELECT * INTO cycle FROM production_fqc_replenishment_cycles
    WHERE id = NEW.cycle_id;
    IF cycle.id IS NULL
       OR NEW.authorization_id IS DISTINCT FROM cycle.authorization_id THEN
        RAISE EXCEPTION 'FQC replenishment attempt identity is invalid'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_replenishment_attempt
    BEFORE INSERT ON production_fqc_replenishment_attempts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_attempt();

CREATE OR REPLACE FUNCTION fn_guard_fqc_replenishment_gap()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    attempt production_fqc_replenishment_attempts%ROWTYPE;
    demand production_material_demands%ROWTYPE;
BEGIN
    SELECT * INTO attempt FROM production_fqc_replenishment_attempts
    WHERE id = NEW.attempt_id;
    SELECT * INTO demand FROM production_material_demands
    WHERE id = NEW.demand_id;
    IF attempt.id IS NULL OR demand.id IS NULL
       OR attempt.outcome IS DISTINCT FROM 'BLOCKED'
       OR demand.fqc_replenishment_cycle_id IS DISTINCT FROM attempt.cycle_id
       OR demand.supply_route IS DISTINCT FROM NEW.supply_route
       OR demand.required_qty IS DISTINCT FROM NEW.required_qty
       OR NEW.allocated_qty + NEW.shortage_qty IS DISTINCT FROM NEW.required_qty THEN
        RAISE EXCEPTION 'FQC replenishment shortage identity is invalid'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_replenishment_gap
    BEFORE INSERT ON production_fqc_replenishment_supply_gaps
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_gap();

CREATE OR REPLACE FUNCTION fn_guard_fqc_replenishment_ready_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    cycle production_fqc_replenishment_cycles%ROWTYPE;
    draw stock_documents%ROWTYPE;
    demand_count BIGINT;
    fulfilled_count BIGINT;
BEGIN
    SELECT * INTO cycle FROM production_fqc_replenishment_cycles
    WHERE id = NEW.cycle_id FOR UPDATE;
    SELECT document.* INTO draw
    FROM production_fqc_replenishment_draw_links link
    JOIN stock_documents document ON document.id = link.stock_document_id
    WHERE link.cycle_id = NEW.cycle_id
      AND link.authorization_id = NEW.authorization_id
      AND link.stock_document_id = NEW.stock_document_id
    FOR UPDATE OF document;
    SELECT COUNT(*), COUNT(*) FILTER (WHERE status = 'FULFILLED')
    INTO demand_count, fulfilled_count
    FROM production_material_demands
    WHERE fqc_replenishment_cycle_id = NEW.cycle_id
      AND fqc_recovery_authorization_id = NEW.authorization_id
      AND is_deleted = FALSE;
    IF cycle.id IS NULL OR draw.id IS NULL OR demand_count = 0
       OR NEW.authorization_id IS DISTINCT FROM cycle.authorization_id
       OR draw.status IS DISTINCT FROM 1
       OR draw.issue_status IS DISTINCT FROM 2
       OR fulfilled_count <> demand_count
       OR EXISTS (
            SELECT 1 FROM production_fqc_replenishment_cycle_cancellations c
            WHERE c.cycle_id = cycle.id)
       OR EXISTS (
            SELECT 1 FROM production_fqc_recovery_cancellation_events c
            WHERE c.authorization_id = cycle.authorization_id) THEN
        RAISE EXCEPTION 'FQC replenishment READY lacks fulfilled physical DRAW facts'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_replenishment_ready_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_replenishment_ready_event
    BEFORE INSERT ON production_fqc_replenishment_ready_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_ready_event();

CREATE OR REPLACE FUNCTION fn_guard_fqc_replenishment_ready_reversal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    ready production_fqc_replenishment_ready_events%ROWTYPE;
BEGIN
    SELECT * INTO ready FROM production_fqc_replenishment_ready_events
    WHERE id = NEW.ready_event_id FOR UPDATE;
    IF ready.id IS NULL
       OR EXISTS (
            SELECT 1
            FROM production_fqc_recovery_allocation_events allocation
            JOIN production_daily_report_items item
              ON item.id = allocation.recovery_report_item_id
            JOIN production_daily_reports report ON report.id = item.report_id
            WHERE allocation.authorization_id = ready.authorization_id
              AND allocation.event_type = 'ALLOCATE'
              AND report.status = 1 AND report.is_deleted = FALSE
              AND NOT EXISTS (
                  SELECT 1 FROM production_fqc_recovery_allocation_events release
                  WHERE release.source_allocation_event_id = allocation.id
                    AND release.event_type = 'RELEASE')) THEN
        RAISE EXCEPTION 'active FQC replacement report blocks READY reversal'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_material_ready_use_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_replenishment_ready_reversal
    BEFORE INSERT ON production_fqc_replenishment_ready_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_ready_reversal();

CREATE OR REPLACE FUNCTION fn_guard_fqc_replenishment_cycle_cancellation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    cycle production_fqc_replenishment_cycles%ROWTYPE;
BEGIN
    SELECT * INTO cycle FROM production_fqc_replenishment_cycles
    WHERE id = NEW.cycle_id FOR UPDATE;
    IF cycle.id IS NULL
       OR NEW.authorization_id IS DISTINCT FROM cycle.authorization_id
       OR EXISTS (
            SELECT 1 FROM production_material_demands demand
            JOIN stock_reservations reservation ON reservation.demand_id = demand.id
            WHERE demand.fqc_replenishment_cycle_id = cycle.id
              AND reservation.is_deleted = FALSE
              AND reservation.qty - reservation.consumed_qty
                    - reservation.released_qty > 0)
       OR EXISTS (
            SELECT 1 FROM production_fqc_replenishment_draw_links link
            JOIN stock_documents document ON document.id = link.stock_document_id
            WHERE link.cycle_id = cycle.id
              AND document.is_deleted = FALSE AND document.status IN (0,1)) THEN
        RAISE EXCEPTION 'FQC replenishment cycle cancellation has active material facts'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_replenishment_cycle_cancellation
    BEFORE INSERT ON production_fqc_replenishment_cycle_cancellations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_cycle_cancellation();

CREATE OR REPLACE FUNCTION fn_reconcile_fqc_replenishment_ready(p_cycle_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    cycle production_fqc_replenishment_cycles%ROWTYPE;
    draw_id UUID;
    draw_status SMALLINT;
    draw_issue_status SMALLINT;
    all_fulfilled BOOLEAN;
    active_ready UUID;
    actor_id UUID;
BEGIN
    SELECT * INTO cycle FROM production_fqc_replenishment_cycles
    WHERE id = p_cycle_id FOR UPDATE;
    IF cycle.id IS NULL THEN RETURN; END IF;
    SELECT link.stock_document_id, document.status, document.issue_status
    INTO draw_id, draw_status, draw_issue_status
    FROM production_fqc_replenishment_draw_links link
    JOIN stock_documents document ON document.id = link.stock_document_id
    WHERE link.cycle_id = cycle.id AND document.is_deleted = FALSE;
    SELECT COALESCE(bool_and(demand.status = 'FULFILLED'), FALSE)
    INTO all_fulfilled
    FROM production_material_demands demand
    WHERE demand.fqc_replenishment_cycle_id = cycle.id
      AND demand.is_deleted = FALSE;
    SELECT ready.id INTO active_ready
    FROM production_fqc_replenishment_ready_events ready
    LEFT JOIN production_fqc_replenishment_ready_reversals reversal
      ON reversal.ready_event_id = ready.id
    WHERE ready.cycle_id = cycle.id AND reversal.id IS NULL
    ORDER BY ready.created_at DESC, ready.id DESC LIMIT 1 FOR UPDATE OF ready;
    actor_id := COALESCE(
        NULLIF(current_setting('app.actor_id', TRUE), '')::UUID,
        cycle.created_by);
    IF all_fulfilled AND draw_status = 1 AND draw_issue_status = 2 THEN
        IF active_ready IS NULL THEN
            INSERT INTO production_fqc_replenishment_ready_events(
                id, cycle_id, authorization_id, stock_document_id,
                idempotency_key, created_by)
            VALUES (
                gen_random_uuid(), cycle.id, cycle.authorization_id, draw_id,
                'FQC-MATERIAL-READY:' || cycle.id::text || ':' ||
                    COALESCE((SELECT COUNT(*)::text FROM production_fqc_replenishment_ready_events r
                              WHERE r.cycle_id = cycle.id), '0'),
                actor_id);
        END IF;
    ELSIF active_ready IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM production_fqc_recovery_allocation_events allocation
            JOIN production_daily_report_items item
              ON item.id = allocation.recovery_report_item_id
            JOIN production_daily_reports report ON report.id = item.report_id
            WHERE allocation.authorization_id = cycle.authorization_id
              AND allocation.event_type = 'ALLOCATE'
              AND report.status = 1 AND report.is_deleted = FALSE
              AND NOT EXISTS (
                  SELECT 1 FROM production_fqc_recovery_allocation_events release
                  WHERE release.source_allocation_event_id = allocation.id
                    AND release.event_type = 'RELEASE')
        ) THEN
            RAISE EXCEPTION 'approved FQC recovery report blocks material issue reversal'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_fqc_material_ready_use_guard';
        END IF;
        INSERT INTO production_fqc_replenishment_ready_reversals(
            id, ready_event_id, reason_code, created_by)
        VALUES (gen_random_uuid(), active_ready, 'DRAW_ISSUE_REVERSED', actor_id)
        ON CONFLICT (ready_event_id) DO NOTHING;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_reconcile_fqc_replenishment_from_demand()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.fqc_replenishment_cycle_id IS NOT NULL THEN
        PERFORM fn_reconcile_fqc_replenishment_ready(
            NEW.fqc_replenishment_cycle_id);
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_reconcile_fqc_replenishment_from_demand
    AFTER UPDATE OF status ON production_material_demands
    FOR EACH ROW EXECUTE FUNCTION fn_reconcile_fqc_replenishment_from_demand();

CREATE OR REPLACE FUNCTION fn_reconcile_fqc_replenishment_from_draw()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    cycle_id UUID;
BEGIN
    SELECT link.cycle_id INTO cycle_id
    FROM production_fqc_replenishment_draw_links link
    WHERE link.stock_document_id = NEW.id;
    IF cycle_id IS NOT NULL THEN
        PERFORM fn_reconcile_fqc_replenishment_ready(cycle_id);
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_reconcile_fqc_replenishment_from_draw
    AFTER UPDATE OF status, issue_status ON stock_documents
    FOR EACH ROW EXECUTE FUNCTION fn_reconcile_fqc_replenishment_from_draw();

-- Forward replacement of the V414 allocation guard: REWORK remains direct;
-- SCRAP/REJECT is accepted only after a physical-material READY fact exists.
CREATE OR REPLACE FUNCTION fn_guard_fqc_recovery_allocation_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    recovery_auth production_fqc_recovery_authorizations%ROWTYPE;
    report_item production_daily_report_items%ROWTYPE;
    report_status SMALLINT;
    source_event production_fqc_recovery_allocation_events%ROWTYPE;
    current_allocated NUMERIC(18,4);
BEGIN
    SELECT * INTO recovery_auth
    FROM production_fqc_recovery_authorizations
    WHERE id = NEW.authorization_id FOR UPDATE;
    SELECT * INTO report_item
    FROM production_daily_report_items
    WHERE id = NEW.recovery_report_item_id;
    SELECT status INTO report_status
    FROM production_daily_reports
    WHERE id = report_item.report_id AND is_deleted = FALSE;
    IF recovery_auth.id IS NULL OR report_item.id IS NULL
       OR report_item.fqc_recovery_authorization_id
            IS DISTINCT FROM recovery_auth.id
       OR NEW.qty <> report_item.qty THEN
        RAISE EXCEPTION 'FQC recovery allocation source is invalid'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.event_type = 'ALLOCATE' THEN
        IF recovery_auth.disposition_code <> 'REWORK'
           AND NOT fn_fqc_replenishment_material_ready(recovery_auth.id) THEN
            RAISE EXCEPTION 'SCRAP/REJECT recovery material is not fulfilled and issued'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_fqc_recovery_material_gate';
        END IF;
        IF report_status IS DISTINCT FROM 1 OR EXISTS (
            SELECT 1 FROM production_fqc_recovery_cancellation_events c
            WHERE c.authorization_id = recovery_auth.id) THEN
            RAISE EXCEPTION 'FQC recovery authorization is not open for allocation'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        SELECT * INTO source_event
        FROM production_fqc_recovery_allocation_events
        WHERE id = NEW.source_allocation_event_id FOR UPDATE;
        IF report_status IS DISTINCT FROM -1
           OR source_event.id IS NULL
           OR source_event.event_type <> 'ALLOCATE'
           OR source_event.authorization_id <> NEW.authorization_id
           OR source_event.recovery_report_item_id <> NEW.recovery_report_item_id
           OR source_event.qty <> NEW.qty THEN
            RAISE EXCEPTION 'FQC recovery release source is invalid'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    SELECT COALESCE(SUM(CASE event.event_type
        WHEN 'ALLOCATE' THEN event.qty
        WHEN 'RELEASE' THEN -event.qty ELSE 0 END), 0)
    INTO current_allocated
    FROM production_fqc_recovery_allocation_events event
    WHERE event.authorization_id = NEW.authorization_id;
    current_allocated := current_allocated
        + CASE WHEN NEW.event_type = 'ALLOCATE' THEN NEW.qty ELSE -NEW.qty END;
    IF current_allocated < 0 OR current_allocated > recovery_auth.authorized_qty THEN
        RAISE EXCEPTION 'FQC recovery allocation exceeds authorized quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_recovery_capacity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_fqc_material_authorization_cancellation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_demands demand
        JOIN stock_reservations reservation ON reservation.demand_id = demand.id
        WHERE demand.fqc_recovery_authorization_id = NEW.authorization_id
          AND demand.is_deleted = FALSE
          AND reservation.is_deleted = FALSE
          AND (
              reservation.consumed_qty > 0
              OR reservation.qty - reservation.consumed_qty
                   - reservation.released_qty > 0)
    ) OR EXISTS (
        SELECT 1 FROM production_fqc_replenishment_draw_links link
        JOIN production_fqc_replenishment_cycles cycle ON cycle.id = link.cycle_id
        JOIN stock_documents document ON document.id = link.stock_document_id
        WHERE cycle.authorization_id = NEW.authorization_id
          AND document.is_deleted = FALSE AND document.status IN (0,1)
    ) THEN
        RAISE EXCEPTION 'FQC material recovery must release/return DRAW before authorization cancellation'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_fqc_material_cancellation_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_fqc_material_authorization_cancellation
    BEFORE INSERT ON production_fqc_recovery_cancellation_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_material_authorization_cancellation();

CREATE OR REPLACE FUNCTION fn_guard_fqc_replenishment_append_only()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'FQC replenishment material ledgers are append-only'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_guard_fqc_replenishment_cycle_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_replenishment_cycles
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_append_only();
ALTER TABLE production_fqc_replenishment_cycles
    ENABLE ALWAYS TRIGGER trg_guard_fqc_replenishment_cycle_append_only;
CREATE TRIGGER trg_guard_fqc_replenishment_attempt_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_replenishment_attempts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_append_only();
ALTER TABLE production_fqc_replenishment_attempts
    ENABLE ALWAYS TRIGGER trg_guard_fqc_replenishment_attempt_append_only;
CREATE TRIGGER trg_guard_fqc_replenishment_gap_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_replenishment_supply_gaps
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_append_only();
ALTER TABLE production_fqc_replenishment_supply_gaps
    ENABLE ALWAYS TRIGGER trg_guard_fqc_replenishment_gap_append_only;
CREATE TRIGGER trg_guard_fqc_replenishment_draw_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_replenishment_draw_links
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_append_only();
ALTER TABLE production_fqc_replenishment_draw_links
    ENABLE ALWAYS TRIGGER trg_guard_fqc_replenishment_draw_append_only;
CREATE TRIGGER trg_guard_fqc_replenishment_ready_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_replenishment_ready_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_append_only();
ALTER TABLE production_fqc_replenishment_ready_events
    ENABLE ALWAYS TRIGGER trg_guard_fqc_replenishment_ready_append_only;
CREATE TRIGGER trg_guard_fqc_replenishment_ready_reversal_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_replenishment_ready_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_append_only();
ALTER TABLE production_fqc_replenishment_ready_reversals
    ENABLE ALWAYS TRIGGER trg_guard_fqc_replenishment_ready_reversal_append_only;
CREATE TRIGGER trg_guard_fqc_replenishment_cancel_append_only
    BEFORE UPDATE OR DELETE ON production_fqc_replenishment_cycle_cancellations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_fqc_replenishment_append_only();
ALTER TABLE production_fqc_replenishment_cycle_cancellations
    ENABLE ALWAYS TRIGGER trg_guard_fqc_replenishment_cancel_append_only;

CREATE TRIGGER trg_audit_production_fqc_replenishment_cycles
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_replenishment_cycles
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_replenishment_attempts
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_replenishment_attempts
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_replenishment_supply_gaps
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_replenishment_supply_gaps
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_replenishment_draw_links
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_replenishment_draw_links
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_replenishment_ready_events
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_replenishment_ready_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_replenishment_ready_reversals
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_replenishment_ready_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_fqc_replenishment_cycle_cancellations
    AFTER INSERT OR UPDATE OR DELETE ON production_fqc_replenishment_cycle_cancellations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

INSERT INTO permissions(
    code, name, module, category, sort_order, action_type, description,
    active, assignable)
VALUES
    ('production_fqc_replenishment:view', '查看FQC补产物料待办',
     '生产管理', 'FQC补产', 226, 'VIEW',
     '查看SCRAP/REJECT补产BOM、缺料、领料与放行状态', TRUE, TRUE),
    ('production_fqc_replenishment:confirm', '确认FQC补产物料方案',
     '生产管理', 'FQC补产', 227, 'APPROVE',
     '冻结当前BOM并生成补产物料需求、库存占用和领料单', TRUE, TRUE)
ON CONFLICT(code) DO UPDATE
SET name=EXCLUDED.name, module=EXCLUDED.module, category=EXCLUDED.category,
    sort_order=EXCLUDED.sort_order, action_type=EXCLUDED.action_type,
    description=EXCLUDED.description, active=TRUE, assignable=TRUE;

INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission ON permission.code IN (
    'production_fqc_replenishment:view',
    'production_fqc_replenishment:confirm')
WHERE department.code IN ('SUB_PLAN','GM')
  AND department.is_deleted = FALSE
ON CONFLICT DO NOTHING;

COMMENT ON TABLE production_fqc_replenishment_cycles IS
    'Planner-confirmed immutable SCRAP/REJECT material cycle bound to one FQC recovery authorization';
COMMENT ON TABLE production_fqc_replenishment_supply_gaps IS
    'Persisted fail-closed shortage evidence; BUY can be replenished then retried, MAKE/SUBCONTRACT need explicit upstream work';
COMMENT ON TABLE production_fqc_replenishment_ready_events IS
    'Physical DRAW issue plus all recovery demands FULFILLED; only this opens SCRAP/REJECT recovery reporting';
