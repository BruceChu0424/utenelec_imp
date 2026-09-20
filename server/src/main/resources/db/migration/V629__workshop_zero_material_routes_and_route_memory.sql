-- ADR-096: every workshop task, including a zero-material one, may choose any of the
-- three production routes. A zero-material task is READY from birth (V249 zero-ready
-- guard), so independent batches must be allowed from READY while the task still holds
-- no physical fact. The split proof stays exact: an empty material snapshot is valid only
-- for ZERO_MATERIAL children, every other guard and the retired-source proof are unchanged.
-- Forward only: no data row is changed.

-- 1. Eligibility for independent batches (workbench canSplitBatch, confirm-route BATCH).
DO $migration$
DECLARE definition TEXT; updated TEXT;
BEGIN
  SELECT pg_get_functiondef('fn_can_split_execution_batch(uuid)'::regprocedure) INTO definition;
  updated:=replace(definition,
      'segment.status=''WAITING'' AND segment.auto_promote_when_ready',
      '(segment.status=''WAITING'' OR (segment.status=''READY'' AND segment.material_requirement_mode=''ZERO_MATERIAL'')) AND segment.auto_promote_when_ready');
  IF updated=definition THEN RAISE EXCEPTION 'V629 missing V618 batch eligibility anchor'; END IF;
  EXECUTE updated;
END $migration$;
COMMENT ON FUNCTION fn_can_split_execution_batch(UUID) IS
  'ADR-096: independent batches from an untouched analysis-backed task; WAITING for material tasks, READY for zero-material tasks (they are born READY).';

-- 2. The append-only split history guard must accept the same zero-material READY source.
DO $migration$
DECLARE definition TEXT; updated TEXT;
BEGIN
  SELECT pg_get_functiondef('fn_guard_execution_split_history()'::regprocedure) INTO definition;
  updated:=replace(definition,
      'source.status=''WAITING'' AND source.auto_promote_when_ready',
      '(source.status=''WAITING'' OR (source.status=''READY'' AND source.material_requirement_mode=''ZERO_MATERIAL'')) AND source.auto_promote_when_ready');
  IF updated=definition THEN RAISE EXCEPTION 'V629 missing V561 split history anchor'; END IF;
  EXECUTE updated;
END $migration$;

-- 3. Zero-material children carry an empty (but present) material snapshot.
ALTER TABLE production_execution_segments DROP CONSTRAINT execution_split_shape;
ALTER TABLE production_execution_segments ADD CONSTRAINT execution_split_shape CHECK (
    (source_segment_id IS NULL AND split_root_segment_id IS NULL AND split_start_qty = 0 AND split_material_snapshot IS NULL)
    OR (source_segment_id IS NOT NULL AND split_root_segment_id IS NOT NULL AND split_material_snapshot IS NOT NULL
        AND jsonb_typeof(split_material_snapshot) = 'array'
        AND (jsonb_array_length(split_material_snapshot) > 0 OR material_requirement_mode = 'ZERO_MATERIAL')));

-- 4. Operator route memory (ADR-096): the workshop task list prefills an unconfirmed task
--    with the operator's most recent confirmed route when the product has no history of its
--    own. One point query per page load, never per row.
CREATE INDEX idx_execution_route_confirmed_by_actor
ON production_execution_segment_events(created_by, created_at DESC)
WHERE action = 'ROUTE_CONFIRMED';

-- 5. Material facts (V628) must not promise a same-workshop child will be handed over
--    directly: the child's output may be transferred on the line or received into the
--    warehouse and drawn from there. The shortage bucket therefore follows the demand's
--    supply route (in-house made child) instead of the continuous-route direct_supply flag,
--    which is only an allocation preference. Signature change: short_direct_count becomes
--    short_make_count, state SHORT_DIRECT becomes SHORT_MAKE.
DROP FUNCTION fn_execution_segment_material_summary(UUID);
CREATE FUNCTION fn_execution_segment_material_summary(p_segment UUID)
RETURNS TABLE(kind_count INTEGER, issued_count INTEGER, partial_issued_count INTEGER,
              awaiting_warehouse_count INTEGER, drawable_count INTEGER,
              line_side_pending_count INTEGER, preparing_count INTEGER,
              short_count INTEGER, short_make_count INTEGER,
              supported_output_qty NUMERIC, prepared_output_qty NUMERIC)
LANGUAGE sql STABLE AS $summary$
    WITH facts AS (
        SELECT demand.id, demand.required_qty, demand.supply_route,
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
           COUNT(*) FILTER (WHERE NOT issued AND short AND supply_route='MAKE')::integer,
           fn_execution_material_output_capacity(p_segment,TRUE),
           fn_execution_material_output_capacity(p_segment,FALSE)
    FROM classified;
$summary$;
COMMENT ON FUNCTION fn_execution_segment_material_summary(UUID) IS
  'ADR-095/096 workshop task material facts: issued vs short is exclusive per demand; short_make_count = short kinds supplied by an in-house child work order (delivered on the line or via the warehouse); requestable / awaiting warehouse issue / line-side auto issue count every not-yet-issued demand holding such a slice; plus output supported by issued and by reserved material.';

DROP FUNCTION fn_execution_segment_material_facts(UUID);
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
           -- The workshop's next action wins over the remaining gap; a pure shortage names
           -- its source: an in-house child work order (line hand-over or warehouse receipt
           -- decided when that child reports) or an external purchase/subcontract arrival.
           CASE
             WHEN net_issued>=required_qty THEN 'ISSUED'
             WHEN ordinary_unrequested>0 THEN 'DRAWABLE'
             WHEN ordinary_requested_unissued>0 THEN 'AWAITING_WAREHOUSE'
             WHEN line_side_unissued>0 THEN 'LINE_SIDE_PENDING'
             WHEN stock_backed<required_qty THEN CASE WHEN supply_route='MAKE' THEN 'SHORT_MAKE' ELSE 'SHORT' END
             ELSE 'PREPARING' END
    FROM facts;
$facts$;
COMMENT ON FUNCTION fn_execution_segment_material_facts(UUID) IS
  'ADR-095/096 per-material quantities of one execution segment for the workshop task detail; shortage_qty is always the remaining gap, state prefers the workshop''s next action over a pure shortage, and SHORT_MAKE means the kind is made by an in-house child work order whose hand-over route is decided at report time.';
