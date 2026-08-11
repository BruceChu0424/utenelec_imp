-- V249: freeze whether an execution segment has formal material demands.
--
-- ZERO_MATERIAL is an explicit, auditable exception. It is never inferred
-- merely from a missing demand row. Existing confirmed zero-demand segments
-- cannot be classified from mutable master data, so migration fails closed if
-- such a row exists and requires evidence-backed remediation before rollout.

ALTER TABLE production_execution_segments
    ADD COLUMN material_requirement_mode TEXT NOT NULL DEFAULT 'DEMANDED',
    ADD COLUMN zero_material_reason TEXT,
    ADD COLUMN zero_material_analysis_id UUID
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    ADD COLUMN zero_material_exception_reason TEXT,
    ADD COLUMN zero_material_authorized_by UUID
        REFERENCES users(id) ON DELETE RESTRICT,
    ADD CONSTRAINT production_execution_segment_material_requirement_chk
        CHECK (
            (
                material_requirement_mode = 'DEMANDED'
                AND zero_material_reason IS NULL
                AND zero_material_analysis_id IS NULL
                AND zero_material_exception_reason IS NULL
                AND zero_material_authorized_by IS NULL
            )
            OR
            (
                material_requirement_mode = 'ZERO_MATERIAL'
                AND (
                    (
                        zero_material_reason = 'DIRECT_MAKE'
                        AND zero_material_analysis_id IS NOT NULL
                        AND zero_material_exception_reason IS NULL
                        AND zero_material_authorized_by IS NULL
                    )
                    OR
                    (
                        zero_material_reason = 'PLAN_BOM_OVERRIDE'
                        AND zero_material_analysis_id IS NOT NULL
                        AND length(btrim(zero_material_exception_reason))
                            BETWEEN 2 AND 1000
                        AND zero_material_authorized_by IS NOT NULL
                    )
                    OR
                    (
                        zero_material_reason = 'NO_PRODUCTION_HARD_GATE'
                        AND zero_material_analysis_id IS NULL
                        AND zero_material_exception_reason IS NULL
                        AND zero_material_authorized_by IS NULL
                    )
                )
            )
        );

COMMENT ON COLUMN production_execution_segments.material_requirement_mode IS
    'DEMANDED requires one or more frozen demands; ZERO_MATERIAL requires none.';
COMMENT ON COLUMN production_execution_segments.zero_material_reason IS
    'Frozen evidence class for an authorized zero-material execution segment.';
COMMENT ON COLUMN production_execution_segments.zero_material_analysis_id IS
    'Confirmed material-analysis fact authorizing DIRECT_MAKE or a plan override.';
COMMENT ON COLUMN production_execution_segments.zero_material_exception_reason IS
    'Frozen human reason from the plan-level BOM override.';
COMMENT ON COLUMN production_execution_segments.zero_material_authorized_by IS
    'Frozen user who authorized the plan-level BOM override.';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_execution_segments segment
        JOIN production_planning_packages package
          ON package.id = segment.package_id
         AND package.status = 'CONFIRMED'
         AND package.is_deleted = FALSE
        WHERE segment.is_deleted = FALSE
          AND segment.status NOT IN ('CANCELLED', 'REVERSED')
          AND NOT EXISTS (
              SELECT 1
              FROM production_material_demands demand
              WHERE demand.execution_segment_id = segment.id
                AND demand.is_deleted = FALSE
          )
    ) THEN
        RAISE EXCEPTION
            'existing confirmed zero-demand segment needs evidence-backed classification before V249'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_zero_migration_guard';
    END IF;
END;
$$;

-- V155 required at least one material-clearance row before a confirmed plan
-- could close. ZERO_MATERIAL is now a frozen, evidence-backed segment shape,
-- so an execution-model plan made only of such segments must not need a fake
-- demand merely to close. DEMANDED and legacy packages keep the original gate.
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
           OR (
               NOT EXISTS (
                   SELECT 1
                   FROM v_production_material_clearance clearance
                   WHERE clearance.plan_id = NEW.id
               )
               AND (
                   NOT EXISTS (
                       SELECT 1
                       FROM production_planning_packages package
                       WHERE package.plan_id = NEW.id
                         AND package.status = 'CONFIRMED'
                         AND package.execution_model_version = 1
                         AND package.is_deleted = FALSE
                   )
                   OR EXISTS (
                       SELECT 1
                       FROM production_execution_segments segment
                       JOIN production_planning_packages package
                         ON package.id = segment.package_id
                        AND package.plan_id = NEW.id
                        AND package.status = 'CONFIRMED'
                        AND package.execution_model_version = 1
                        AND package.is_deleted = FALSE
                       WHERE segment.plan_id = NEW.id
                         AND segment.material_requirement_mode = 'DEMANDED'
                         AND segment.is_deleted = FALSE
                   )
               )
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

-- V155 treated an empty material set as not ready. V249 now has an immutable,
-- evidence-backed ZERO_MATERIAL shape, so the shared execution read model must
-- expose those READY segments as dispatchable without weakening DEMANDED rows.
-- The backing table gained columns above, while the V155 view used segment.*.
-- PostgreSQL cannot use CREATE OR REPLACE when that would insert columns before
-- the existing derived columns, so recreate this leaf view explicitly.
DROP VIEW v_production_execution_segments;

CREATE VIEW v_production_execution_segments AS
SELECT segment.*,
       goods.code AS product_code,
       goods.name AS product_name,
       workshop.name AS workshop_name,
       team.name AS team_name,
       employee.full_name AS responsible_employee_name,
       COUNT(material.demand_id) AS material_kind_count,
       COUNT(material.demand_id) FILTER (
           WHERE NOT material.ready
       ) AS shortage_kind_count,
       CASE
           WHEN segment.material_requirement_mode = 'ZERO_MATERIAL'
           THEN TRUE
           ELSE COALESCE(bool_and(material.ready), FALSE)
       END AS material_ready
FROM production_execution_segments segment
JOIN goods ON goods.id = segment.product_goods_id
LEFT JOIN departments workshop
  ON workshop.id = segment.workshop_department_id
LEFT JOIN departments team
  ON team.id = segment.team_department_id
LEFT JOIN employees employee
  ON employee.id = segment.responsible_employee_id
LEFT JOIN v_production_execution_segment_materials material
  ON material.execution_segment_id = segment.id
WHERE segment.is_deleted = FALSE
GROUP BY segment.id, goods.id, workshop.id, team.id, employee.id;

CREATE OR REPLACE FUNCTION fn_guard_execution_segment_requirement_shape()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.material_requirement_mode = 'ZERO_MATERIAL'
       AND NEW.status = 'WAITING' THEN
        RAISE EXCEPTION 'zero-material execution segment must start READY'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_zero_ready_guard';
    END IF;
    IF TG_OP = 'INSERT'
       AND NEW.material_requirement_mode = 'ZERO_MATERIAL'
       AND NOT (
           (
               NEW.zero_material_reason = 'DIRECT_MAKE'
               AND EXISTS (
                   SELECT 1
                   FROM production_plans plan
                   JOIN goods product
                     ON product.id = NEW.product_goods_id
                    AND product.is_deleted = FALSE
                   WHERE plan.id = NEW.plan_id
                     AND plan.is_deleted = FALSE
                     AND plan.material_analysis_id =
                         NEW.zero_material_analysis_id
                     AND product.production_bom_policy = 'DIRECT_MAKE'
               )
           )
           OR
           (
               NEW.zero_material_reason = 'PLAN_BOM_OVERRIDE'
               AND EXISTS (
                   SELECT 1
                   FROM production_plans plan
                   JOIN goods product
                     ON product.id = NEW.product_goods_id
                    AND product.is_deleted = FALSE
                   WHERE plan.id = NEW.plan_id
                     AND plan.is_deleted = FALSE
                     AND plan.material_analysis_id =
                         NEW.zero_material_analysis_id
                     AND product.production_bom_policy = 'BOM_REQUIRED'
                     AND btrim(plan.bom_override_reason) =
                         NEW.zero_material_exception_reason
                     AND plan.bom_override_by =
                         NEW.zero_material_authorized_by
               )
           )
           OR
           (
               NEW.zero_material_reason = 'NO_PRODUCTION_HARD_GATE'
               AND EXISTS (
                   SELECT 1
                   FROM goods_bom_items bom
                   WHERE bom.goods_id = NEW.product_goods_id
                     AND bom.is_deleted = FALSE
               )
               AND NOT EXISTS (
                   SELECT 1
                   FROM goods_bom_items bom
                   WHERE bom.goods_id = NEW.product_goods_id
                     AND bom.is_deleted = FALSE
                     AND bom.hard_gate = TRUE
                     AND bom.control_stage IN (
                         'START', 'ASSEMBLY', 'FINISH')
               )
           )
       ) THEN
        RAISE EXCEPTION 'zero-material evidence does not match the plan/BOM facts'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_zero_evidence_guard';
    END IF;
    IF TG_OP = 'UPDATE'
       AND (
           OLD.material_requirement_mode
               IS DISTINCT FROM NEW.material_requirement_mode
           OR OLD.zero_material_reason
               IS DISTINCT FROM NEW.zero_material_reason
           OR OLD.zero_material_analysis_id
               IS DISTINCT FROM NEW.zero_material_analysis_id
           OR OLD.zero_material_exception_reason
               IS DISTINCT FROM NEW.zero_material_exception_reason
           OR OLD.zero_material_authorized_by
               IS DISTINCT FROM NEW.zero_material_authorized_by
       ) THEN
        RAISE EXCEPTION 'execution segment material requirement shape is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_requirement_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_execution_segment_requirement_shape
    BEFORE INSERT OR UPDATE OF
        material_requirement_mode, zero_material_reason,
        zero_material_analysis_id, zero_material_exception_reason,
        zero_material_authorized_by, status
    ON production_execution_segments
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_execution_segment_requirement_shape();

-- Replace V248's deferred validator. DEMANDED retains every V248 invariant;
-- ZERO_MATERIAL is accepted only with zero demand rows, no DRAW, and a READY
-- (or later lifecycle) status.
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
               WHERE (
                   requirement_mode = 'LINEAR'
                   AND required_qty IS DISTINCT FROM
                       ceil((v_segment.planned_qty * per_product_qty) * 10000)
                       / 10000
               )
                  OR (
                      requirement_mode = 'EXACT_SNAPSHOT'
                      AND required_for_product_qty
                          IS DISTINCT FROM v_segment.planned_qty
                  )
                  OR requirement_mode NOT IN ('LINEAR', 'EXACT_SNAPSHOT')
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

    IF v_bad_count > 0
       OR (
           v_segment.material_requirement_mode = 'DEMANDED'
           AND v_demand_count = 0
       )
       OR (
           v_segment.material_requirement_mode = 'ZERO_MATERIAL'
           AND v_demand_count <> 0
       ) THEN
        RAISE EXCEPTION 'execution segment demand snapshot is missing or inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_execution_segment_demand_guard';
    END IF;

    IF v_segment.material_requirement_mode = 'ZERO_MATERIAL' THEN
        IF v_segment.status = 'WAITING' THEN
            RAISE EXCEPTION 'zero-material execution segment must be READY'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_execution_segment_zero_ready_guard';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM production_planning_package_documents document
            WHERE document.package_id = v_segment.package_id
              AND document.execution_segment_id = v_segment.id
              AND document.document_type = 'DRAW'
        ) THEN
            RAISE EXCEPTION 'zero-material execution segment cannot have DRAW'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_execution_segment_zero_draw_guard';
        END IF;
        RETURN;
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
