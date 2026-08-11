-- V248: exact execution-segment demand snapshots for non-linear BOM rules.
--
-- Historical and new PER_UNIT demands remain LINEAR and keep V194's exact
-- validation. PER_PACKAGE/FIXED_BATCH demands freeze the segment product
-- quantity, exact base-unit requirement and a canonical rule fingerprint.

ALTER TABLE production_material_demands
    ADD COLUMN requirement_mode TEXT NOT NULL DEFAULT 'LINEAR',
    ADD COLUMN required_for_product_qty NUMERIC(18,4),
    ADD COLUMN requirement_fingerprint VARCHAR(64),
    ADD CONSTRAINT production_material_demand_requirement_snapshot_chk CHECK (
        (
            requirement_mode = 'LINEAR'
            AND required_for_product_qty IS NULL
            AND requirement_fingerprint IS NULL
        )
        OR
        (
            requirement_mode = 'EXACT_SNAPSHOT'
            AND execution_segment_id IS NOT NULL
            AND source_plan_item_id IS NOT NULL
            AND required_for_product_qty > 0
            AND requirement_fingerprint ~ '^[0-9a-f]{64}$'
        )
    );

COMMENT ON COLUMN production_material_demands.requirement_mode IS
    'LINEAR validates qty*rate; EXACT_SNAPSHOT freezes a non-linear segment requirement.';
COMMENT ON COLUMN production_material_demands.required_for_product_qty IS
    'Execution-segment product quantity for which an EXACT_SNAPSHOT requirement was calculated.';
COMMENT ON COLUMN production_material_demands.requirement_fingerprint IS
    'SHA-256 of material identity, product unit rate, and the exact BOM consumption rules.';

CREATE OR REPLACE FUNCTION fn_guard_exact_production_demand_snapshot()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (
        OLD.requirement_mode = 'EXACT_SNAPSHOT'
        OR NEW.requirement_mode = 'EXACT_SNAPSHOT'
    ) AND (
        NEW.package_id IS DISTINCT FROM OLD.package_id
        OR NEW.plan_id IS DISTINCT FROM OLD.plan_id
        OR NEW.execution_segment_id IS DISTINCT FROM OLD.execution_segment_id
        OR NEW.source_plan_item_id IS DISTINCT FROM OLD.source_plan_item_id
        OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
        OR NEW.goods_id IS DISTINCT FROM OLD.goods_id
        OR NEW.color_id IS DISTINCT FROM OLD.color_id
        OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
        OR NEW.required_qty IS DISTINCT FROM OLD.required_qty
        OR NEW.per_product_qty IS DISTINCT FROM OLD.per_product_qty
        OR NEW.supply_route IS DISTINCT FROM OLD.supply_route
        OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
        OR NEW.requirement_mode IS DISTINCT FROM OLD.requirement_mode
        OR NEW.required_for_product_qty
            IS DISTINCT FROM OLD.required_for_product_qty
        OR NEW.requirement_fingerprint
            IS DISTINCT FROM OLD.requirement_fingerprint
    ) THEN
        RAISE EXCEPTION 'exact production material demand snapshot is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_material_demand_exact_snapshot_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_exact_production_demand_snapshot
    BEFORE UPDATE OF
        package_id, plan_id, execution_segment_id, source_plan_item_id,
        warehouse_id, goods_id, color_id, unit_id, required_qty,
        per_product_qty, supply_route, idempotency_key, requirement_mode,
        required_for_product_qty, requirement_fingerprint
    ON production_material_demands
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_exact_production_demand_snapshot();

-- Replace V194's deferred validator without changing the LINEAR branch. The
-- exact branch validates the immutable segment/product snapshot instead of
-- trying to reconstruct a non-linear package rule from a six-decimal rate.
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
