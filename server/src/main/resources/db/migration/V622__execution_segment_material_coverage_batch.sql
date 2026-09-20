-- Compute every demand's unchanged material budget together. Deferred guards
-- still validate the complete final segment on every invocation; no cache,
-- trigger suppression, or weaker WAITING/READY/completion predicate is used.
CREATE FUNCTION fn_execution_segment_material_coverage(p_segment UUID)
RETURNS TABLE(demand_id UUID, required_qty NUMERIC, stock_backed NUMERIC,
              draw_backed NUMERIC, draw_committed NUMERIC)
LANGUAGE sql STABLE AS $coverage$
    WITH demands AS MATERIALIZED (
        SELECT id, required_qty FROM production_material_demands
        WHERE execution_segment_id=p_segment AND NOT is_deleted
    ), stock AS (
        SELECT reservation.demand_id, SUM(reservation.qty-reservation.released_qty) AS qty
        FROM demands JOIN stock_reservations reservation ON reservation.demand_id=demands.id
        WHERE NOT reservation.is_deleted GROUP BY reservation.demand_id
    ), historical_draw AS (
        SELECT mapping.demand_id, SUM(COALESCE(item.base_qty,item.qty*COALESCE(item.unit_rate,1))) AS qty
        FROM demands JOIN production_planning_package_document_items mapping ON mapping.demand_id=demands.id
        JOIN production_planning_package_documents header ON header.package_id=mapping.package_id
            AND header.document_type=mapping.document_type AND header.document_id=mapping.document_id
        JOIN stock_documents document ON document.id=mapping.document_id AND document.doc_type='DRAW'
            AND NOT document.is_deleted AND document.status<>-1
        JOIN stock_document_items item ON item.id=mapping.document_item_id AND item.doc_id=mapping.document_id
        WHERE mapping.document_type='DRAW' AND header.execution_segment_id=p_segment
        GROUP BY mapping.demand_id
    ), instructions AS MATERIALIZED (
        SELECT mapping.demand_id, item.id,
               fn_production_draw_item_effective_qty(item.id)*COALESCE(item.unit_rate,1) AS qty
        FROM demands JOIN production_planning_package_document_items mapping ON mapping.demand_id=demands.id
        JOIN stock_document_items item ON item.id=mapping.document_item_id AND NOT item.is_deleted
        JOIN stock_documents document ON document.id=item.doc_id AND document.id=mapping.document_id
            AND document.doc_type='DRAW' AND document.status IN (0,1) AND NOT document.is_deleted
        WHERE mapping.document_type='DRAW'
    ), issued_by_item AS (
        -- An instruction can have postings for more than one demand. Deduplicate
        -- item IDs for this aggregate, but retain every original mapping above.
        SELECT posting.stock_document_item_id, SUM(CASE posting.posting_type
                   WHEN 'ISSUE' THEN posting.qty_base WHEN 'ISSUE_REVERSE' THEN -posting.qty_base ELSE 0 END) AS qty
        FROM (SELECT DISTINCT id FROM instructions) selected
        JOIN production_material_stock_postings posting ON posting.stock_document_item_id=selected.id
        GROUP BY posting.stock_document_item_id
    ), pending_by_demand AS (
        SELECT instructions.demand_id,
               SUM(GREATEST(instructions.qty-COALESCE(issued_by_item.qty,0),0)) AS qty
        FROM instructions LEFT JOIN issued_by_item ON issued_by_item.stock_document_item_id=instructions.id
        GROUP BY instructions.demand_id
    ), physical_by_demand AS (
        SELECT posting.demand_id, SUM(CASE posting.posting_type
                   WHEN 'ISSUE' THEN posting.qty_base WHEN 'GOOD_RETURN_REVERSE' THEN posting.qty_base
                   WHEN 'ISSUE_REVERSE' THEN -posting.qty_base WHEN 'GOOD_RETURN' THEN -posting.qty_base ELSE 0 END) AS qty
        FROM demands JOIN production_material_stock_postings posting ON posting.demand_id=demands.id
        GROUP BY posting.demand_id
    )
    SELECT demands.id, demands.required_qty, COALESCE(stock.qty,0), COALESCE(historical_draw.qty,0),
           COALESCE(pending_by_demand.qty,0)+COALESCE(physical_by_demand.qty,0)
    FROM demands
    LEFT JOIN stock ON stock.demand_id=demands.id
    LEFT JOIN historical_draw ON historical_draw.demand_id=demands.id
    LEFT JOIN pending_by_demand ON pending_by_demand.demand_id=demands.id
    LEFT JOIN physical_by_demand ON physical_by_demand.demand_id=demands.id;
$coverage$;

COMMENT ON FUNCTION fn_execution_segment_material_coverage(UUID) IS
    'Exact segment-wide stock, historical DRAW and net physical/instruction coverage; same budgets as the V618 per-demand function without repeated scalar queries';

-- Full V621 guard definition follows. Only its coverage source changes;
-- the snapshot, readiness, over-allocation, closure and lineage gates remain.

CREATE OR REPLACE FUNCTION public.fn_assert_execution_segment_integrity_before_v561(p_segment_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
                       ceil((coalesce(v_segment.material_snapshot_product_qty,v_segment.planned_qty) * per_product_qty) * 10000)
                       / 10000
               )
                  OR (
                      requirement_mode = 'EXACT_SNAPSHOT'
                      AND required_for_product_qty
                          IS DISTINCT FROM coalesce(v_segment.material_snapshot_product_qty,v_segment.planned_qty)
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

    WITH coverage AS MATERIALIZED (
        SELECT coverage.*, v_segment.continuous_supply AS direct_partial
        FROM fn_execution_segment_material_coverage(v_segment.id) coverage
    )
    SELECT COUNT(*) FILTER (
               WHERE direct_partial
                  OR (stock_backed >= required_qty
                      AND draw_backed >= required_qty)
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
                 OR draw_committed > required_qty
                 OR (
                     v_segment.status <> 'COMPLETED'
                     AND NOT (
                         v_segment.status = 'IN_PROGRESS'
                         AND v_segment.completion_reopened
                     )
                     AND draw_committed > stock_backed
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
$function$;
