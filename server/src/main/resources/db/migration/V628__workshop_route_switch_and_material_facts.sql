-- ADR-095: the workshop may switch its production route at any time before START.
-- Physical facts (reservations, draw instructions, issued material, direct transfers)
-- are never rewritten by a route change; only START/report history freezes the route.
-- Forward only: no data row is changed, existing routes and supply modes are kept.

-- 1. Route freeze = the task has started or has any report line. Actual material
--    issue no longer freezes the route: FULL_KIT keeps every issued/reserved fact and
--    simply waits for the rest; CONTINUOUS relaxes the start gate; BATCH additionally
--    requires an untouched task (fn_can_split_execution_batch, unchanged).
CREATE OR REPLACE FUNCTION fn_can_change_execution_route(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT 1 FROM production_execution_segments segment
    WHERE segment.id=p_segment AND NOT segment.is_deleted
      AND segment.status IN ('WAITING','READY','DISPATCHED')
      AND NOT EXISTS(SELECT 1 FROM production_daily_report_items item WHERE item.execution_segment_id=segment.id))
$$;
COMMENT ON FUNCTION fn_can_change_execution_route(UUID) IS
  'ADR-095: any route may be re-chosen before START and before the first report line; physical preparation is preserved. Independent batches still require fn_can_split_execution_batch.';

-- 2. The START gate follows the confirmed route, not the incremental-preparation flag.
--    continuous_supply now only means "this task is prepared incrementally" (it stays
--    TRUE when a partially prepared CONTINUOUS task is switched to FULL_KIT, so the
--    READY integrity guard keeps accepting its partial reservations); the route decides
--    whether partial material may start: CONTINUOUS = joint positive output,
--    FULL_KIT = every demand physically issued in full.
--    The live function body carries later anchor patches (V616 custody validity, V618/V619
--    unissued-available slices), so only the route branch is replaced in place; a hand
--    written copy of the V611 text would silently revert those guards.
DO $migration$
DECLARE definition TEXT; updated TEXT;
BEGIN
  SELECT pg_get_functiondef('fn_execution_start_material_ready(uuid)'::regprocedure) INTO definition;
  updated:=replace(definition,'CASE WHEN segment.continuous_supply','CASE WHEN segment.start_route=''CONTINUOUS''');
  IF updated=definition THEN RAISE EXCEPTION 'V628 missing V611 start gate anchor'; END IF;
  IF position('CASE WHEN segment.start_route=''CONTINUOUS''' IN updated)
     <> length(updated)-position(reverse('CASE WHEN segment.start_route=''CONTINUOUS''') IN reverse(updated))-length('CASE WHEN segment.start_route=''CONTINUOUS''')+2 THEN
    RAISE EXCEPTION 'V628 start gate anchor is not unique';
  END IF;
  EXECUTE updated;
END $migration$;
COMMENT ON FUNCTION fn_execution_start_material_ready(UUID) IS
  'ADR-095: START capability by confirmed route. CONTINUOUS = every demand jointly supports positive output from issued material plus the exact direct lots START itself will issue; every other route = every demand physically issued in full. Ordinary warehouse reservations never count as held.';

-- 3. "Ready" per material follows the route: only a CONTINUOUS task may call a partially
--    covered demand ready; a FULL_KIT task that still holds partial preparation from an
--    earlier CONTINUOUS choice reports KIT_SHORT until every demand is fully covered.
--    Same column list as V611, so dependent views keep their definition.
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
    COALESCE(stock.stock_backed, 0::numeric)::numeric(18,4) AS stock_backed_qty,
    COALESCE(supply.supply_backed, 0::numeric)::numeric(18,4) AS supply_backed_qty,
    COALESCE(draw.draw_backed, 0::numeric)::numeric(18,4) AS draw_backed_qty,
    GREATEST(d.required_qty - COALESCE(stock.stock_backed, 0::numeric), 0::numeric)::numeric(18,4) AS stock_shortage_qty,
    (s.start_route = 'CONTINUOUS' AND s.continuous_supply
        AND fn_demand_material_output_capacity(d.id, LEAST(COALESCE(stock.stock_backed, 0::numeric), COALESCE(draw.draw_backed, 0::numeric))) > 0::numeric)
      OR (COALESCE(stock.stock_backed, 0::numeric) >= d.required_qty AND COALESCE(draw.draw_backed, 0::numeric) >= d.required_qty) AS ready,
    d.direct_supply,
    s.continuous_supply
   FROM production_execution_segments s
     JOIN production_material_demands d ON d.execution_segment_id = s.id AND d.is_deleted = false
     LEFT JOIN LATERAL ( SELECT sum(r.qty - r.released_qty) AS stock_backed
           FROM stock_reservations r
          WHERE r.demand_id = d.id AND r.is_deleted = false) stock ON true
     LEFT JOIN LATERAL ( SELECT sum(p.allocated_qty - p.consumed_qty - p.released_qty) AS supply_backed
           FROM production_material_supply_pegs p
          WHERE p.demand_id = d.id AND p.status <> 'REVERSED'::text) supply ON true
     LEFT JOIN LATERAL ( SELECT sum(COALESCE(i.base_qty, i.qty * COALESCE(i.unit_rate, 1::numeric))) AS draw_backed
           FROM production_planning_package_document_items m
             JOIN stock_documents h ON h.id = m.document_id AND h.is_deleted = false AND h.status <> '-1'::integer
             JOIN stock_document_items i ON i.id = m.document_item_id AND i.doc_id = m.document_id
          WHERE m.demand_id = d.id AND m.document_type = 'DRAW'::text) draw ON true
  WHERE s.is_deleted = false;
COMMENT ON VIEW v_production_execution_segment_materials IS
  'Per-demand preparation facts of an execution segment. ready follows the confirmed route (ADR-095): CONTINUOUS accepts partial coverage with positive output, every other route requires full stock and DRAW coverage.';

-- 4. One pass per task over the exact per-material facts the workshop page shows.
--    Coverage is exclusive: a kind is either fully in workshop custody (issued) or not;
--    a not-issued kind is short when its reservations do not cover the demand (split by
--    same-workshop direct supply vs. purchase/subcontract arrival). Action counts are
--    independent of shortage, because a partially received kind can be short AND have
--    a requestable slice at the same time (continuous replenishment: 40 of 100 arrived).
--    Capacities reuse the frozen consumption curves (V609).
CREATE FUNCTION fn_execution_segment_material_summary(p_segment UUID)
RETURNS TABLE(kind_count INTEGER, issued_count INTEGER, partial_issued_count INTEGER,
              awaiting_warehouse_count INTEGER, drawable_count INTEGER,
              line_side_pending_count INTEGER, preparing_count INTEGER,
              short_count INTEGER, short_direct_count INTEGER,
              supported_output_qty NUMERIC, prepared_output_qty NUMERIC)
LANGUAGE sql STABLE AS $summary$
    WITH facts AS (
        SELECT demand.id, demand.required_qty, demand.direct_supply,
               coverage.stock_backed,
               GREATEST(fn_execution_material_net_issued_qty(demand.id),0) AS net_issued,
               COALESCE(instruction.ordinary_unrequested,0) AS ordinary_unrequested,
               COALESCE(instruction.ordinary_requested_unissued,0) AS ordinary_requested_unissued,
               COALESCE(instruction.line_side_unissued,0) AS line_side_unissued
        FROM production_material_demands demand
        JOIN fn_execution_segment_material_coverage(p_segment) coverage ON coverage.demand_id=demand.id
        LEFT JOIN LATERAL (
            SELECT SUM(GREATEST(fn_production_draw_item_effective_qty(item.id)-fn_production_draw_item_requested_qty(item.id),0)
                       *COALESCE(item.unit_rate,1)) FILTER (WHERE NOT warehouse.is_line_side) AS ordinary_unrequested,
                   SUM(GREATEST(fn_production_draw_item_requested_qty(item.id)-COALESCE(item.issued_qty,0),0)
                       *COALESCE(item.unit_rate,1)) FILTER (WHERE NOT warehouse.is_line_side) AS ordinary_requested_unissued,
                   SUM(GREATEST(fn_production_draw_item_effective_qty(item.id)-COALESCE(item.issued_qty,0),0)
                       *COALESCE(item.unit_rate,1)) FILTER (WHERE warehouse.is_line_side) AS line_side_unissued
            FROM production_planning_package_document_items mapping
            JOIN stock_document_items item ON item.id=mapping.document_item_id AND NOT item.is_deleted
            JOIN stock_documents document ON document.id=item.doc_id AND document.id=mapping.document_id
                AND document.doc_type='DRAW' AND document.status IN (0,1) AND NOT document.is_deleted
            JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
            WHERE mapping.demand_id=demand.id AND mapping.document_type='DRAW'
        ) instruction ON TRUE
        WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
          AND demand.status NOT IN ('RELEASED','REVERSED')
    ), classified AS (
        SELECT facts.*, net_issued>=required_qty AS issued, stock_backed<required_qty AS short
        FROM facts
    )
    SELECT COUNT(*)::integer,
           COUNT(*) FILTER (WHERE issued)::integer,
           COUNT(*) FILTER (WHERE net_issued>0 AND NOT issued)::integer,
           COUNT(*) FILTER (WHERE NOT issued AND ordinary_requested_unissued>0)::integer,
           COUNT(*) FILTER (WHERE NOT issued AND ordinary_unrequested>0)::integer,
           COUNT(*) FILTER (WHERE NOT issued AND line_side_unissued>0)::integer,
           COUNT(*) FILTER (WHERE NOT issued AND NOT short AND ordinary_unrequested<=0
                              AND ordinary_requested_unissued<=0 AND line_side_unissued<=0)::integer,
           COUNT(*) FILTER (WHERE NOT issued AND short)::integer,
           COUNT(*) FILTER (WHERE NOT issued AND short AND direct_supply)::integer,
           fn_execution_material_output_capacity(p_segment,TRUE),
           fn_execution_material_output_capacity(p_segment,FALSE)
    FROM classified;
$summary$;
COMMENT ON FUNCTION fn_execution_segment_material_summary(UUID) IS
  'ADR-095 workshop task material facts: issued vs short (by direct supply or arrival) is exclusive per demand; requestable / awaiting warehouse issue / line-side auto issue count every not-yet-issued demand holding such a slice, so a partially arrived kind is reported both short and requestable; plus output supported by issued and by reserved material.';

-- 5. Per-material detail for the workshop task dialog: exact quantities per demand and
--    the same exclusive state as the summary. Direct-supply rows also expose how much the
--    same-workshop child has already handed over (received) and still holds unallocated.
CREATE FUNCTION fn_execution_segment_material_facts(p_segment UUID)
RETURNS TABLE(demand_id UUID, goods_id UUID, color_id UUID, unit_id UUID, supply_route TEXT,
              direct_supply BOOLEAN, required_qty NUMERIC, reserved_qty NUMERIC,
              requested_unissued_qty NUMERIC, requestable_qty NUMERIC, line_side_pending_qty NUMERIC,
              issued_qty NUMERIC, shortage_qty NUMERIC, direct_received_qty NUMERIC,
              direct_available_qty NUMERIC, state TEXT)
LANGUAGE sql STABLE AS $facts$
    WITH facts AS (
        SELECT demand.id, demand.goods_id, demand.color_id, demand.unit_id, demand.supply_route,
               demand.direct_supply, demand.required_qty, coverage.stock_backed,
               GREATEST(fn_execution_material_net_issued_qty(demand.id),0) AS net_issued,
               COALESCE(instruction.ordinary_unrequested,0) AS ordinary_unrequested,
               COALESCE(instruction.ordinary_requested_unissued,0) AS ordinary_requested_unissued,
               COALESCE(instruction.line_side_unissued,0) AS line_side_unissued,
               COALESCE(lots.received_qty,0) AS direct_received_qty,
               COALESCE(lots.available_qty,0) AS direct_available_qty
        FROM production_material_demands demand
        JOIN fn_execution_segment_material_coverage(p_segment) coverage ON coverage.demand_id=demand.id
        LEFT JOIN LATERAL (
            SELECT SUM(GREATEST(fn_production_draw_item_effective_qty(item.id)-fn_production_draw_item_requested_qty(item.id),0)
                       *COALESCE(item.unit_rate,1)) FILTER (WHERE NOT warehouse.is_line_side) AS ordinary_unrequested,
                   SUM(GREATEST(fn_production_draw_item_requested_qty(item.id)-COALESCE(item.issued_qty,0),0)
                       *COALESCE(item.unit_rate,1)) FILTER (WHERE NOT warehouse.is_line_side) AS ordinary_requested_unissued,
                   SUM(GREATEST(fn_production_draw_item_effective_qty(item.id)-COALESCE(item.issued_qty,0),0)
                       *COALESCE(item.unit_rate,1)) FILTER (WHERE warehouse.is_line_side) AS line_side_unissued
            FROM production_planning_package_document_items mapping
            JOIN stock_document_items item ON item.id=mapping.document_item_id AND NOT item.is_deleted
            JOIN stock_documents document ON document.id=item.doc_id AND document.id=mapping.document_id
                AND document.doc_type='DRAW' AND document.status IN (0,1) AND NOT document.is_deleted
            JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
            WHERE mapping.demand_id=demand.id AND mapping.document_type='DRAW'
        ) instruction ON TRUE
        LEFT JOIN LATERAL (
            SELECT SUM(lot.received_qty) AS received_qty, SUM(lot.available_qty) AS available_qty
            FROM v_workshop_direct_supply_lots lot
            WHERE lot.to_demand_id IN (demand.id, demand.split_root_demand_id)
        ) lots ON TRUE
        WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
          AND demand.status NOT IN ('RELEASED','REVERSED')
    )
    SELECT id, goods_id, color_id, unit_id, supply_route, direct_supply, required_qty,
           stock_backed, ordinary_requested_unissued, ordinary_unrequested, line_side_unissued, net_issued,
           GREATEST(required_qty-stock_backed,0), direct_received_qty, direct_available_qty,
           -- The workshop's next action wins over the remaining gap: a kind with a
           -- requestable slice says "requestable" while its shortage column still shows
           -- what is missing; only a kind with nothing to act on reads as short.
           CASE
             WHEN net_issued>=required_qty THEN 'ISSUED'
             WHEN ordinary_unrequested>0 THEN 'DRAWABLE'
             WHEN ordinary_requested_unissued>0 THEN 'AWAITING_WAREHOUSE'
             WHEN line_side_unissued>0 THEN 'LINE_SIDE_PENDING'
             WHEN stock_backed<required_qty THEN CASE WHEN direct_supply THEN 'SHORT_DIRECT' ELSE 'SHORT' END
             ELSE 'PREPARING' END
    FROM facts;
$facts$;
COMMENT ON FUNCTION fn_execution_segment_material_facts(UUID) IS
  'ADR-095 per-material quantities of one execution segment for the workshop task detail; shortage_qty is always the remaining gap, state prefers the workshop''s next action (requestable / awaiting warehouse / line-side) over a pure shortage.';
