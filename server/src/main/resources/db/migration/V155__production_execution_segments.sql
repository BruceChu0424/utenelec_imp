-- V155: first-class finished-product execution segments.
--
-- An execution segment is not a production_plans child and must never be
-- written to subplan_links.  It is the immutable allocation identity between
-- one source plan item, its frozen BOM demand, stock reservations and DRAW
-- document lines.  Historical V150 demands remain valid with a NULL segment.

ALTER TABLE production_planning_packages
    ADD COLUMN execution_model_version SMALLINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT production_planning_package_execution_model_chk
        CHECK (execution_model_version IN (0, 1));

CREATE TABLE production_execution_segments (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    package_id               UUID NOT NULL
        REFERENCES production_planning_packages(id) ON DELETE CASCADE,
    plan_id                  UUID NOT NULL REFERENCES production_plans(id),
    source_plan_item_id      UUID NOT NULL REFERENCES production_plan_items(id),
    segment_no               INTEGER NOT NULL,
    segment_code             TEXT NOT NULL,
    client_segment_key       TEXT NOT NULL,
    product_goods_id         UUID NOT NULL REFERENCES goods(id),
    product_color_id         UUID REFERENCES colors(id),
    product_unit_id          UUID NOT NULL REFERENCES units(id),
    product_unit_rate        NUMERIC(18,6) NOT NULL,
    planned_qty              NUMERIC(18,4) NOT NULL,
    status                   TEXT NOT NULL,
    workshop_department_id   UUID REFERENCES departments(id),
    team_department_id       UUID REFERENCES departments(id),
    responsible_employee_id  UUID REFERENCES employees(id),
    plan_begin_date          DATE,
    plan_end_date            DATE,
    bom_fingerprint          TEXT NOT NULL,
    idempotency_key          TEXT NOT NULL,
    lock_version             BIGINT NOT NULL DEFAULT 0,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               UUID,
    updated_by               UUID,
    is_deleted               BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at               TIMESTAMPTZ,
    CONSTRAINT production_execution_segment_no_chk
        CHECK (segment_no > 0),
    CONSTRAINT production_execution_segment_qty_chk
        CHECK (planned_qty > 0 AND product_unit_rate > 0),
    CONSTRAINT production_execution_segment_dates_chk
        CHECK (
            plan_begin_date IS NULL
            OR plan_end_date IS NULL
            OR plan_end_date >= plan_begin_date
        ),
    CONSTRAINT production_execution_segment_status_chk
        CHECK (status IN (
            'READY', 'WAITING', 'DISPATCHED', 'IN_PROGRESS',
            'COMPLETED', 'CANCELLED', 'REVERSED'
        )),
    CONSTRAINT production_execution_segment_hash_chk
        CHECK (bom_fingerprint ~ '^[0-9a-f]{64}$'),
    CONSTRAINT production_execution_segment_keys_chk
        CHECK (
            length(btrim(segment_code)) BETWEEN 1 AND 80
            AND length(btrim(client_segment_key)) BETWEEN 1 AND 128
            AND length(btrim(idempotency_key)) BETWEEN 8 AND 200
        ),
    CONSTRAINT production_execution_segment_team_chk
        CHECK (
            team_department_id IS NULL
            OR workshop_department_id IS NOT NULL
        )
);

CREATE UNIQUE INDEX uq_production_execution_segment_no
    ON production_execution_segments(package_id, source_plan_item_id, segment_no)
    WHERE is_deleted = FALSE;
CREATE UNIQUE INDEX uq_production_execution_segment_client_key
    ON production_execution_segments(package_id, client_segment_key)
    WHERE is_deleted = FALSE;
CREATE UNIQUE INDEX uq_production_execution_segment_idempotency
    ON production_execution_segments(idempotency_key)
    WHERE is_deleted = FALSE;
CREATE UNIQUE INDEX uq_production_execution_segment_code
    ON production_execution_segments(segment_code)
    WHERE is_deleted = FALSE;
CREATE INDEX idx_production_execution_segment_plan
    ON production_execution_segments(plan_id, status, plan_begin_date, id)
    WHERE is_deleted = FALSE;
CREATE INDEX idx_production_execution_segment_workshop
    ON production_execution_segments(
        workshop_department_id, plan_begin_date, plan_end_date, status)
    WHERE is_deleted = FALSE
      AND status NOT IN ('COMPLETED', 'CANCELLED', 'REVERSED');

ALTER TABLE production_material_demands
    ADD COLUMN execution_segment_id UUID
        REFERENCES production_execution_segments(id),
    ADD COLUMN source_plan_item_id UUID
        REFERENCES production_plan_items(id),
    ADD COLUMN per_product_qty NUMERIC(18,6);

ALTER TABLE production_material_demands
    ADD CONSTRAINT production_material_demand_segment_shape_chk
        CHECK (
            (
                execution_segment_id IS NULL
                AND source_plan_item_id IS NULL
                AND per_product_qty IS NULL
            )
            OR
            (
                execution_segment_id IS NOT NULL
                AND source_plan_item_id IS NOT NULL
                AND per_product_qty IS NOT NULL
                AND per_product_qty > 0
                AND supply_route <> 'MAKE'
            )
        );

DROP INDEX uq_production_material_demand_dimension;
CREATE UNIQUE INDEX uq_production_material_demand_dimension
    ON production_material_demands(
        package_id, execution_segment_id, goods_id, color_id, need_date
    ) NULLS NOT DISTINCT
    WHERE is_deleted = FALSE;
CREATE INDEX idx_production_material_demand_segment
    ON production_material_demands(execution_segment_id, status, goods_id, color_id)
    WHERE execution_segment_id IS NOT NULL AND is_deleted = FALSE;

ALTER TABLE production_planning_package_documents
    ADD COLUMN execution_segment_id UUID
        REFERENCES production_execution_segments(id);
CREATE INDEX idx_production_package_document_segment
    ON production_planning_package_documents(
        execution_segment_id, document_type, created_at, id)
    WHERE execution_segment_id IS NOT NULL;

-- Row-level identity and organization validation.  Assignments remain editable
-- while READY/WAITING, but material/product identity is immutable after insert.
CREATE OR REPLACE FUNCTION fn_validate_production_execution_segment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_package_plan UUID;
    v_package_status TEXT;
    v_execution_model SMALLINT;
    v_item_plan UUID;
    v_item_goods UUID;
    v_item_color UUID;
    v_item_unit UUID;
    v_workshop_path TEXT;
    v_team_path TEXT;
    v_employee_department UUID;
    v_employee_status TEXT;
    v_employee_path TEXT;
BEGIN
    SELECT plan_id, status, execution_model_version
    INTO v_package_plan, v_package_status, v_execution_model
    FROM production_planning_packages
    WHERE id = NEW.package_id AND is_deleted = FALSE;

    SELECT plan_id, goods_id, color_id, unit_id
    INTO v_item_plan, v_item_goods, v_item_color, v_item_unit
    FROM production_plan_items
    WHERE id = NEW.source_plan_item_id AND is_deleted = FALSE;

    IF v_package_plan IS NULL OR v_item_plan IS NULL
       OR NEW.plan_id <> v_package_plan
       OR v_item_plan <> NEW.plan_id
       OR v_item_goods <> NEW.product_goods_id
       OR v_item_color IS DISTINCT FROM NEW.product_color_id
       OR v_item_unit IS DISTINCT FROM NEW.product_unit_id THEN
        RAISE EXCEPTION 'execution segment identity does not match package/plan item'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_identity_guard';
    END IF;
    IF v_package_status <> 'CONFIRMED'
       OR v_execution_model <> 1 THEN
        RAISE EXCEPTION 'execution segment may only be changed in a confirmed package'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_package_guard';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.package_id IS DISTINCT FROM NEW.package_id
           OR OLD.plan_id IS DISTINCT FROM NEW.plan_id
           OR OLD.source_plan_item_id IS DISTINCT FROM NEW.source_plan_item_id
           OR OLD.segment_no IS DISTINCT FROM NEW.segment_no
           OR OLD.segment_code IS DISTINCT FROM NEW.segment_code
           OR OLD.client_segment_key IS DISTINCT FROM NEW.client_segment_key
           OR OLD.product_goods_id IS DISTINCT FROM NEW.product_goods_id
           OR OLD.product_color_id IS DISTINCT FROM NEW.product_color_id
           OR OLD.product_unit_id IS DISTINCT FROM NEW.product_unit_id
           OR OLD.product_unit_rate IS DISTINCT FROM NEW.product_unit_rate
           OR OLD.planned_qty IS DISTINCT FROM NEW.planned_qty
           OR OLD.bom_fingerprint IS DISTINCT FROM NEW.bom_fingerprint
           OR OLD.idempotency_key IS DISTINCT FROM NEW.idempotency_key THEN
            RAISE EXCEPTION 'execution segment frozen identity is immutable'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_execution_segment_immutable_guard';
        END IF;
        IF OLD.status IN ('COMPLETED', 'CANCELLED', 'REVERSED')
           AND NEW.status <> OLD.status THEN
            RAISE EXCEPTION 'terminal execution segment is immutable'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_execution_segment_terminal_guard';
        END IF;
        IF NOT (
            NEW.status = OLD.status
            OR (OLD.status = 'READY'
                AND NEW.status IN (
                    'WAITING', 'DISPATCHED', 'CANCELLED', 'REVERSED'))
            OR (OLD.status = 'WAITING'
                AND NEW.status IN ('READY', 'CANCELLED', 'REVERSED'))
            OR (OLD.status = 'DISPATCHED' AND NEW.status = 'IN_PROGRESS')
            OR (OLD.status = 'IN_PROGRESS' AND NEW.status = 'COMPLETED')
        ) THEN
            RAISE EXCEPTION 'invalid execution segment status transition'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_execution_segment_transition_guard';
        END IF;
        IF OLD.status NOT IN ('READY', 'WAITING')
           AND (
               OLD.workshop_department_id
                   IS DISTINCT FROM NEW.workshop_department_id
               OR OLD.team_department_id
                   IS DISTINCT FROM NEW.team_department_id
               OR OLD.responsible_employee_id
                   IS DISTINCT FROM NEW.responsible_employee_id
               OR OLD.plan_begin_date
                   IS DISTINCT FROM NEW.plan_begin_date
               OR OLD.plan_end_date
                   IS DISTINCT FROM NEW.plan_end_date
           ) THEN
            RAISE EXCEPTION 'dispatched execution assignment is frozen'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_execution_segment_assignment_frozen_guard';
        END IF;
    ELSIF NEW.status NOT IN ('READY', 'WAITING') THEN
        RAISE EXCEPTION 'new execution segment must start READY or WAITING'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_initial_status_guard';
    END IF;
    IF NEW.status = 'DISPATCHED'
       AND (
           NEW.workshop_department_id IS NULL
           OR NEW.responsible_employee_id IS NULL
           OR NEW.plan_begin_date IS NULL
           OR NEW.plan_end_date IS NULL
       ) THEN
        RAISE EXCEPTION 'dispatch requires workshop, owner and plan dates'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_dispatch_assignment_guard';
    END IF;

    IF NEW.workshop_department_id IS NOT NULL THEN
        SELECT path INTO v_workshop_path
        FROM departments
        WHERE id = NEW.workshop_department_id AND is_deleted = FALSE;
        IF v_workshop_path IS NULL THEN
            RAISE EXCEPTION 'execution segment workshop is unavailable'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_execution_segment_workshop_guard';
        END IF;
    END IF;
    IF NEW.team_department_id IS NOT NULL THEN
        SELECT path INTO v_team_path
        FROM departments
        WHERE id = NEW.team_department_id AND is_deleted = FALSE;
        IF v_team_path IS NULL
           OR v_workshop_path IS NULL
           OR v_team_path NOT LIKE v_workshop_path || '%' THEN
            RAISE EXCEPTION 'execution segment team must belong to workshop'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_execution_segment_team_guard';
        END IF;
    END IF;
    IF NEW.responsible_employee_id IS NOT NULL THEN
        SELECT e.department_id, e.status, d.path
        INTO v_employee_department, v_employee_status, v_employee_path
        FROM employees e
        JOIN departments d ON d.id = e.department_id
        WHERE e.id = NEW.responsible_employee_id
          AND e.is_deleted = FALSE
          AND d.is_deleted = FALSE;
        IF v_employee_department IS NULL
           OR v_employee_status NOT IN ('active', 'probation')
           OR (
               v_workshop_path IS NOT NULL
               AND v_employee_path NOT LIKE v_workshop_path || '%'
           )
           OR (
               v_team_path IS NOT NULL
               AND v_employee_path NOT LIKE v_team_path || '%'
           ) THEN
            RAISE EXCEPTION 'execution segment owner is inactive or outside assignment'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_execution_segment_owner_guard';
        END IF;
    END IF;
    NEW.updated_at := now();
    IF TG_OP = 'UPDATE' THEN
        NEW.lock_version := OLD.lock_version + 1;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_production_execution_segment
    BEFORE INSERT OR UPDATE ON production_execution_segments
    FOR EACH ROW EXECUTE FUNCTION fn_validate_production_execution_segment();

-- Deferred validator: a confirmed package is all-or-nothing.  Every source
-- plan item must be partitioned exactly once by segment quantities, every
-- demand is the frozen per-product requirement times segment quantity, and a
-- READY segment is both reservation-backed and DRAW-backed for every material.
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
                  OR supply_route = 'MAKE'
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

CREATE OR REPLACE FUNCTION fn_assert_execution_package_integrity(
    p_package_id UUID
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan_id UUID;
    v_status TEXT;
    v_execution_model SMALLINT;
    v_bad_count BIGINT;
    v_segment_id UUID;
BEGIN
    SELECT plan_id, status, execution_model_version
    INTO v_plan_id, v_status, v_execution_model
    FROM production_planning_packages
    WHERE id = p_package_id AND is_deleted = FALSE;
    IF NOT FOUND OR v_status <> 'CONFIRMED'
       OR v_execution_model <> 1 THEN
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_bad_count
    FROM production_plan_items i
    LEFT JOIN LATERAL (
        SELECT COALESCE(SUM(s.planned_qty), 0) AS segmented_qty
        FROM production_execution_segments s
        WHERE s.package_id = p_package_id
          AND s.source_plan_item_id = i.id
          AND s.is_deleted = FALSE
          AND s.status NOT IN ('CANCELLED', 'REVERSED')
    ) x ON TRUE
    WHERE i.plan_id = v_plan_id
      AND i.is_deleted = FALSE
      AND COALESCE(i.qty, 0) > 0
      AND x.segmented_qty IS DISTINCT FROM i.qty;
    IF v_bad_count > 0 THEN
        RAISE EXCEPTION 'execution segment quantities do not exactly partition plan items'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_package_total_guard';
    END IF;

    SELECT COUNT(*) INTO v_bad_count
    FROM production_execution_segments s
    LEFT JOIN production_plan_items i
      ON i.id = s.source_plan_item_id
     AND i.plan_id = v_plan_id
     AND i.is_deleted = FALSE
    WHERE s.package_id = p_package_id
      AND s.is_deleted = FALSE
      AND i.id IS NULL;
    IF v_bad_count > 0 THEN
        RAISE EXCEPTION 'execution segment references an unavailable plan item'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_package_source_guard';
    END IF;

    FOR v_segment_id IN
        SELECT id
        FROM production_execution_segments
        WHERE package_id = p_package_id AND is_deleted = FALSE
        ORDER BY source_plan_item_id, segment_no, id
    LOOP
        PERFORM fn_assert_execution_segment_integrity(v_segment_id);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_execution_segment_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment_id UUID;
    v_package_id UUID;
BEGIN
    IF TG_TABLE_NAME = 'production_execution_segments' THEN
        v_segment_id := COALESCE(NEW.id, OLD.id);
        v_package_id := COALESCE(NEW.package_id, OLD.package_id);
    ELSIF TG_TABLE_NAME = 'production_material_demands' THEN
        v_segment_id := COALESCE(NEW.execution_segment_id, OLD.execution_segment_id);
        v_package_id := COALESCE(NEW.package_id, OLD.package_id);
    ELSIF TG_TABLE_NAME = 'stock_reservations' THEN
        SELECT execution_segment_id, package_id
        INTO v_segment_id, v_package_id
        FROM production_material_demands
        WHERE id = COALESCE(NEW.demand_id, OLD.demand_id);
    ELSIF TG_TABLE_NAME = 'production_planning_package_document_items' THEN
        SELECT execution_segment_id, package_id
        INTO v_segment_id, v_package_id
        FROM production_material_demands
        WHERE id = COALESCE(NEW.demand_id, OLD.demand_id);
    ELSIF TG_TABLE_NAME = 'production_planning_package_documents' THEN
        v_segment_id := COALESCE(NEW.execution_segment_id, OLD.execution_segment_id);
        v_package_id := COALESCE(NEW.package_id, OLD.package_id);
    ELSIF TG_TABLE_NAME = 'stock_document_items' THEN
        SELECT d.execution_segment_id, d.package_id
        INTO v_segment_id, v_package_id
        FROM production_planning_package_document_items m
        JOIN production_material_demands d ON d.id = m.demand_id
        WHERE m.document_item_id = COALESCE(NEW.id, OLD.id)
        LIMIT 1;
    ELSIF TG_TABLE_NAME = 'production_planning_packages' THEN
        v_package_id := COALESCE(NEW.id, OLD.id);
    ELSIF TG_TABLE_NAME = 'production_plan_items' THEN
        SELECT id INTO v_package_id
        FROM production_planning_packages
        WHERE plan_id = COALESCE(NEW.plan_id, OLD.plan_id)
          AND is_deleted = FALSE
          AND status = 'CONFIRMED'
        LIMIT 1;
    END IF;
    IF v_segment_id IS NOT NULL THEN
        PERFORM fn_assert_execution_segment_integrity(v_segment_id);
    END IF;
    IF v_package_id IS NOT NULL THEN
        PERFORM fn_assert_execution_package_integrity(v_package_id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_check_execution_segment_row
    AFTER INSERT OR UPDATE OR DELETE ON production_execution_segments
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_demand
    AFTER INSERT OR UPDATE OR DELETE ON production_material_demands
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_reservation
    AFTER INSERT OR UPDATE OR DELETE ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_document
    AFTER INSERT OR UPDATE OR DELETE ON production_planning_package_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_document_item
    AFTER INSERT OR UPDATE OR DELETE
    ON production_planning_package_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_stock_item
    AFTER INSERT OR UPDATE OR DELETE ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_package
    AFTER INSERT OR UPDATE OR DELETE ON production_planning_packages
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();
CREATE CONSTRAINT TRIGGER trg_check_execution_segment_plan_item
    AFTER INSERT OR UPDATE OR DELETE ON production_plan_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_execution_segment_integrity();

-- Immediate operational gates. WAITING segments own neither physical
-- reservation nor DRAW; approval and ISSUE may never bypass readiness.
CREATE OR REPLACE FUNCTION fn_guard_execution_segment_draw_approval()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment_id UUID;
    v_segment_status TEXT;
BEGIN
    IF NEW.doc_type <> 'DRAW'
       OR NEW.status IS DISTINCT FROM 1
       OR OLD.status IS NOT DISTINCT FROM NEW.status THEN
        RETURN NEW;
    END IF;
    FOR v_segment_id, v_segment_status IN
        SELECT s.id, s.status
        FROM production_planning_package_documents h
        JOIN production_execution_segments s
          ON s.id = h.execution_segment_id
        WHERE h.document_type = 'DRAW'
          AND h.document_id = NEW.id
          AND s.is_deleted = FALSE
    LOOP
        IF v_segment_status NOT IN ('READY', 'DISPATCHED', 'IN_PROGRESS') THEN
            RAISE EXCEPTION 'WAITING execution segment DRAW cannot be approved'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_execution_segment_draw_approval_guard';
        END IF;
        PERFORM fn_assert_execution_segment_integrity(v_segment_id);
    END LOOP;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_execution_segment_draw_approval
    BEFORE UPDATE OF status ON stock_documents
    FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_segment_draw_approval();

CREATE OR REPLACE FUNCTION fn_guard_execution_segment_issue()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment_id UUID;
    v_status TEXT;
    v_exact_mapping_count BIGINT;
BEGIN
    IF NEW.posting_type <> 'ISSUE' THEN
        RETURN NEW;
    END IF;
    SELECT s.id, s.status
    INTO v_segment_id, v_status
    FROM production_material_demands d
    JOIN production_execution_segments s ON s.id = d.execution_segment_id
    WHERE d.id = NEW.demand_id
      AND d.is_deleted = FALSE
      AND s.is_deleted = FALSE;
    IF v_segment_id IS NULL THEN
        RETURN NEW;
    END IF;
    IF v_status NOT IN ('READY', 'DISPATCHED', 'IN_PROGRESS') THEN
        RAISE EXCEPTION 'WAITING execution segment material cannot be issued'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_issue_guard';
    END IF;
    SELECT COUNT(*)
    INTO v_exact_mapping_count
    FROM production_planning_package_document_items mapping
    JOIN production_planning_package_documents header
      ON header.package_id = mapping.package_id
     AND header.document_type = mapping.document_type
     AND header.document_id = mapping.document_id
    JOIN production_material_demands demand
      ON demand.id = mapping.demand_id
    JOIN stock_document_items item
      ON item.id = mapping.document_item_id
     AND item.doc_id = mapping.document_id
    WHERE mapping.document_type = 'DRAW'
      AND mapping.document_item_id = NEW.stock_document_item_id
      AND mapping.demand_id = NEW.demand_id
      AND header.execution_segment_id = v_segment_id
      AND demand.execution_segment_id = v_segment_id
      AND demand.goods_id = item.goods_id
      AND demand.color_id IS NOT DISTINCT FROM item.color_id
      AND demand.unit_id = item.unit_id
      AND COALESCE(item.unit_rate, 1) = 1
      AND demand.is_deleted = FALSE
      AND item.is_deleted = FALSE;
    IF v_exact_mapping_count <> 1 THEN
        RAISE EXCEPTION
            'execution segment ISSUE requires one exact DRAW item mapping'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_issue_mapping_guard';
    END IF;
    PERFORM fn_assert_execution_segment_integrity(v_segment_id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_execution_segment_issue
    BEFORE INSERT ON production_material_stock_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_segment_issue();

-- Extend the V152 plan close gate: an execution-model package is not complete
-- until every real finished-product segment is complete as well as the
-- existing finished-in and explicit material-clearance checks.
CREATE OR REPLACE FUNCTION fn_guard_production_plan_material_close()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.is_closed = TRUE
       AND COALESCE(OLD.is_closed, FALSE) = FALSE
       AND EXISTS (
           SELECT 1
           FROM production_planning_packages package
           WHERE package.plan_id = NEW.id
             AND package.status = 'CONFIRMED'
             AND package.is_deleted = FALSE
       )
       AND (
           EXISTS (
               SELECT 1
               FROM production_plan_items item
               WHERE item.plan_id = NEW.id
                 AND item.is_deleted = FALSE
                 AND COALESCE(item.iqty, 0) < COALESCE(item.qty, 0)
           )
           OR NOT EXISTS (
               SELECT 1
               FROM v_production_material_clearance clearance
               WHERE clearance.plan_id = NEW.id
           )
           OR EXISTS (
               SELECT 1
               FROM v_production_material_clearance clearance
               WHERE clearance.plan_id = NEW.id
                 AND clearance.can_close = FALSE
           )
           OR (
               EXISTS (
                   SELECT 1
                   FROM production_planning_packages package
                   WHERE package.plan_id = NEW.id
                     AND package.status = 'CONFIRMED'
                     AND package.is_deleted = FALSE
                     AND package.execution_model_version = 1
               )
               AND (
                   NOT EXISTS (
                       SELECT 1
                       FROM production_execution_segments segment
                       JOIN production_planning_packages active_package
                         ON active_package.id = segment.package_id
                        AND active_package.plan_id = NEW.id
                        AND active_package.status = 'CONFIRMED'
                        AND active_package.execution_model_version = 1
                        AND active_package.is_deleted = FALSE
                       WHERE segment.plan_id = NEW.id
                         AND segment.is_deleted = FALSE
                   )
                   OR EXISTS (
                       SELECT 1
                       FROM production_execution_segments segment
                       JOIN production_planning_packages active_package
                         ON active_package.id = segment.package_id
                        AND active_package.plan_id = NEW.id
                        AND active_package.status = 'CONFIRMED'
                        AND active_package.execution_model_version = 1
                        AND active_package.is_deleted = FALSE
                       WHERE segment.plan_id = NEW.id
                         AND segment.is_deleted = FALSE
                         AND segment.status <> 'COMPLETED'
                   )
               )
           )
       ) THEN
        NEW.is_closed := FALSE;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_production_execution_segments
    AFTER INSERT OR UPDATE OR DELETE ON production_execution_segments
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE VIEW v_production_execution_segment_materials AS
SELECT s.id AS execution_segment_id,
       s.package_id,
       s.plan_id,
       s.source_plan_item_id,
       s.status AS segment_status,
       d.id AS demand_id,
       d.goods_id,
       d.color_id,
       d.unit_id,
       d.per_product_qty,
       d.required_qty,
       d.need_date,
       d.supply_route,
       d.status AS demand_status,
       COALESCE(stock.stock_backed, 0)::numeric(18,4) AS stock_backed_qty,
       COALESCE(supply.supply_backed, 0)::numeric(18,4) AS supply_backed_qty,
       COALESCE(draw.draw_backed, 0)::numeric(18,4) AS draw_backed_qty,
       GREATEST(
           d.required_qty - COALESCE(stock.stock_backed, 0), 0
       )::numeric(18,4) AS stock_shortage_qty,
       (
           COALESCE(stock.stock_backed, 0) >= d.required_qty
           AND COALESCE(draw.draw_backed, 0) >= d.required_qty
       ) AS ready
FROM production_execution_segments s
JOIN production_material_demands d
  ON d.execution_segment_id = s.id
 AND d.is_deleted = FALSE
LEFT JOIN LATERAL (
    SELECT SUM(r.qty - r.released_qty) AS stock_backed
    FROM stock_reservations r
    WHERE r.demand_id = d.id AND r.is_deleted = FALSE
) stock ON TRUE
LEFT JOIN LATERAL (
    SELECT SUM(p.allocated_qty - p.consumed_qty - p.released_qty) AS supply_backed
    FROM production_material_supply_pegs p
    WHERE p.demand_id = d.id AND p.status <> 'REVERSED'
) supply ON TRUE
LEFT JOIN LATERAL (
    SELECT SUM(COALESCE(i.base_qty, i.qty * COALESCE(i.unit_rate, 1))) AS draw_backed
    FROM production_planning_package_document_items m
    JOIN stock_documents h
      ON h.id = m.document_id
     AND h.is_deleted = FALSE
     AND h.status <> -1
    JOIN stock_document_items i
      ON i.id = m.document_item_id
     AND i.doc_id = m.document_id
    WHERE m.demand_id = d.id
      AND m.document_type = 'DRAW'
) draw ON TRUE
WHERE s.is_deleted = FALSE;

CREATE OR REPLACE VIEW v_production_execution_segments AS
SELECT s.*,
       g.code AS product_code,
       g.name AS product_name,
       workshop.name AS workshop_name,
       team.name AS team_name,
       employee.full_name AS responsible_employee_name,
       COUNT(m.demand_id) AS material_kind_count,
       COUNT(m.demand_id) FILTER (WHERE NOT m.ready) AS shortage_kind_count,
       COALESCE(bool_and(m.ready), FALSE) AS material_ready
FROM production_execution_segments s
JOIN goods g ON g.id = s.product_goods_id
LEFT JOIN departments workshop ON workshop.id = s.workshop_department_id
LEFT JOIN departments team ON team.id = s.team_department_id
LEFT JOIN employees employee ON employee.id = s.responsible_employee_id
LEFT JOIN v_production_execution_segment_materials m
  ON m.execution_segment_id = s.id
WHERE s.is_deleted = FALSE
GROUP BY s.id, g.id, workshop.id, team.id, employee.id;

COMMENT ON TABLE production_execution_segments IS
    'Finished-product execution partitions; never reuse subplan_links.';
COMMENT ON COLUMN production_material_demands.execution_segment_id IS
    'NULL for historical package-wide demand; non-NULL for V155 segment demand.';
COMMENT ON COLUMN production_planning_package_documents.execution_segment_id IS
    'Execution identity for segment DRAW documents; NULL for legacy documents.';
