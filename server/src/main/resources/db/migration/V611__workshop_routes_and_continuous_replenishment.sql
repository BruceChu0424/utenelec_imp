-- ADR-093: explicit workshop routes and source-independent continuous supply.
-- Forward only: existing routes and all physical/history facts remain unchanged.
-- New root tasks wait for a workshop route; prior continuous routes retain their mode.
-- Previously explicitly confirmed continuous routes are now prepared without a second
-- route-selection command. The scheduled reconciler only allocates existing real stock.
UPDATE production_execution_segments
SET continuous_supply=TRUE
WHERE start_route='CONTINUOUS' AND NOT continuous_supply AND NOT is_deleted
  AND status IN ('WAITING','READY','DISPATCHED','IN_PROGRESS');

-- Keep the existing over-allocation, WAITING, completed-clearance and reversal guards.
-- Only the READY backing rule changes: all demands in continuous mode may be partial.
DO $migration$
DECLARE definition TEXT; updated TEXT;
BEGIN
  SELECT pg_get_functiondef('fn_assert_execution_segment_integrity_before_v561(uuid)'::regprocedure) INTO definition;
  updated:=replace(definition,'(v_segment.continuous_supply AND d.direct_supply) AS direct_partial',
      'v_segment.continuous_supply AS direct_partial');
  IF updated=definition THEN RAISE EXCEPTION 'V611 missing V595 integrity guard anchor'; END IF;
  EXECUTE updated;
END $migration$;

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
    ((s.continuous_supply AND fn_demand_material_output_capacity(d.id,
         LEAST(COALESCE(stock.stock_backed,0),COALESCE(draw.draw_backed,0)))>0)
     OR (COALESCE(stock.stock_backed, 0::numeric) >= d.required_qty
         AND COALESCE(draw.draw_backed, 0::numeric) >= d.required_qty)) AS ready,
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

CREATE OR REPLACE FUNCTION fn_guard_production_draw_request_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        IF OLD.action='DRAW_REQUEST' OR (TG_OP='UPDATE' AND NEW.action='DRAW_REQUEST') THEN
            RAISE EXCEPTION 'Workshop DRAW request events are append-only' USING ERRCODE='55000';
        END IF;
        IF TG_OP='DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    IF NEW.action <> 'DRAW_REQUEST' THEN RETURN NEW; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM production_execution_segments segment
        WHERE segment.id=NEW.execution_segment_id AND NOT segment.is_deleted
          AND (segment.status IN ('READY','DISPATCHED') OR (segment.continuous_supply AND segment.status='IN_PROGRESS'))
          AND segment.start_route IN ('FULL_KIT','CONTINUOUS')
          AND segment.material_requirement_mode='DEMANDED'
          AND segment.lock_version=NEW.resulting_version)
       OR EXISTS (
        SELECT 1 FROM unnest(NEW.draw_document_ids) AS requested(document_id)
        WHERE NOT EXISTS (
            SELECT 1 FROM production_planning_package_documents mapping
            JOIN stock_documents document ON document.id=mapping.document_id
            WHERE mapping.execution_segment_id=NEW.execution_segment_id
              AND mapping.document_id=requested.document_id AND mapping.document_type='DRAW'
              AND document.doc_type='DRAW' AND document.status IN (0,1) AND NOT document.is_deleted))
       OR cardinality(NEW.draw_document_ids) <> (
          SELECT count(DISTINCT id) FROM unnest(NEW.draw_document_ids) id) THEN
        RAISE EXCEPTION 'Workshop DRAW request has stale or invalid execution documents' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE OR REPLACE FUNCTION fn_guard_system_readiness_formalize_actor()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.created_by IS NOT NULL THEN RETURN NEW; END IF;
    IF NEW.event_type IS DISTINCT FROM 'FORMALIZE'
       OR NEW.system_reason IS DISTINCT FROM 'AUTOMATIC_READINESS_RECHECK'
       OR current_setting('app.production_readiness_reconcile',true) IS DISTINCT FROM 'v1'
       OR NULLIF(current_setting('app.actor_id',true),'') IS NOT NULL
       OR current_setting('app.actor_account',true) IS DISTINCT FROM '系统自动核对备料'
       OR NOT EXISTS (
           SELECT 1 FROM production_material_demands demand
           JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
             AND (segment.status='WAITING' OR (segment.continuous_supply AND segment.status IN ('READY','DISPATCHED','IN_PROGRESS'))) AND segment.auto_promote_when_ready AND NOT segment.is_deleted
           JOIN production_planning_packages package ON package.id=demand.package_id
             AND package.id=NEW.target_package_id AND package.status='CONFIRMED'
             AND package.execution_model_version=1 AND NOT package.is_deleted
           JOIN production_plans plan ON plan.id=demand.plan_id AND plan.id=segment.plan_id
             AND plan.status=1 AND NOT plan.is_deleted AND NOT COALESCE(plan.is_closed,FALSE)
             AND NOT COALESCE(plan.is_canceled,FALSE) AND NOT COALESCE(plan.is_stopped,FALSE)
             AND plan.material_analysis_id=NEW.beneficiary_analysis_id
           JOIN stock_reservations target ON target.id=NEW.target_stock_reservation_id
             AND target.demand_id=demand.id AND target.owner_type='PRODUCTION_MATERIAL_DEMAND'
             AND NOT target.is_deleted
           JOIN stock_reservations source ON source.id=NEW.stock_reservation_id
             AND source.owner_type='PREPLAN_ANALYSIS' AND NOT source.is_deleted
             AND source.warehouse_id=target.warehouse_id AND source.goods_id=target.goods_id
             AND source.color_id IS NOT DISTINCT FROM target.color_id
           JOIN preplan_stock_entitlement_events origin ON origin.id=NEW.source_entitlement_event_id
             AND origin.stock_reservation_id=source.id
             AND origin.beneficiary_analysis_id=NEW.beneficiary_analysis_id
             AND origin.beneficiary_analysis_material_id=NEW.beneficiary_analysis_material_id
           WHERE demand.id=NEW.target_demand_id AND NOT demand.is_deleted
             AND fn_analysis_plan_material_matches(plan.material_analysis_item_id,NEW.beneficiary_analysis_material_id)
       ) THEN
        RAISE EXCEPTION 'system FORMALIZE requires the controlled automatic-readiness transaction and exact approved waiting task'
          USING ERRCODE='23514',CONSTRAINT='preplan_system_formalize_actor_guard';
    END IF;
    RETURN NEW;
END $$;

-- This compatibility capability now means physically ready to start continuous work.
-- Both fulfillment commands and physical issue/return use this one state rule.
CREATE FUNCTION fn_production_material_demand_status(p_demand UUID)
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT CASE
      WHEN demand.released_qty>=demand.required_qty THEN 'RELEASED'
      WHEN held.fulfilled>=demand.required_qty THEN 'FULFILLED'
      WHEN COALESCE(segment.continuous_supply,FALSE)
           AND held.fulfilled+demand.released_qty>=demand.required_qty THEN 'FULFILLED'
      WHEN held.committed+future.committed>=demand.required_qty AND future.committed>0 THEN 'WAITING_SUPPLY'
      WHEN held.committed>=demand.required_qty THEN 'ALLOCATED'
      WHEN held.committed+future.committed>0 THEN 'PARTIAL'
      ELSE 'OPEN' END
  FROM production_material_demands demand
  LEFT JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
  CROSS JOIN LATERAL (SELECT COALESCE(SUM(reservation.qty-reservation.released_qty),0) AS committed,
      COALESCE(SUM(reservation.consumed_qty),0) AS fulfilled
      FROM stock_reservations reservation WHERE reservation.demand_id=demand.id AND NOT reservation.is_deleted) held
  CROSS JOIN LATERAL (SELECT COALESCE(SUM(peg.allocated_qty-peg.consumed_qty-peg.released_qty),0) AS committed
      FROM production_material_supply_pegs peg WHERE peg.demand_id=demand.id AND peg.status<>'REVERSED') future
  WHERE demand.id=p_demand AND NOT demand.is_deleted
$$;

CREATE OR REPLACE FUNCTION fn_can_change_execution_route(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT 1 FROM production_execution_segments segment
    WHERE segment.id=p_segment AND NOT segment.is_deleted
      AND segment.status IN ('WAITING','READY','DISPATCHED')
      AND NOT EXISTS(SELECT 1 FROM production_daily_report_items item WHERE item.execution_segment_id=segment.id)
      AND NOT EXISTS(SELECT 1 FROM production_material_demands demand
          JOIN stock_reservations reservation ON reservation.demand_id=demand.id
          WHERE demand.execution_segment_id=segment.id AND reservation.consumed_qty>0))
$$;
COMMENT ON FUNCTION fn_can_change_execution_route(UUID) IS
  'Pre-start route adjustment without rewriting preparation: no actual material issue or report; batch splitting additionally requires no reservations/documents/supply pegs.';

-- Capability includes exact direct material that START will issue atomically.
-- Ordinary warehouse reservations never count as already held by the workshop.
CREATE FUNCTION fn_execution_start_material_ready(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN segment.material_requirement_mode='ZERO_MATERIAL'
                    OR fn_split_batch_empty_issued(segment.id) THEN TRUE
    ELSE COALESCE((
      SELECT bool_and(CASE WHEN segment.continuous_supply
          THEN fn_demand_material_output_capacity(demand.id,
              GREATEST(fn_execution_material_net_issued_qty(demand.id),0)
              +COALESCE(direct.pending_qty,0))>0
          ELSE fn_execution_material_net_issued_qty(demand.id)
                  +COALESCE(direct.pending_qty,0)>=demand.required_qty END)
      FROM production_material_demands demand
      LEFT JOIN LATERAL (
        SELECT SUM(LEAST(pending.qty,GREATEST(COALESCE(balance.qty,0),0),held.qty)) AS pending_qty
        FROM (
          SELECT document.warehouse_id,
              SUM(GREATEST(item.qty-COALESCE(item.issued_qty,0),0)*COALESCE(item.unit_rate,1)) AS qty
          FROM production_planning_package_document_items mapping
          JOIN stock_documents document ON document.id=mapping.document_id
              AND document.doc_type='DRAW' AND document.status IN (0,1) AND NOT document.is_deleted
          JOIN stock_document_items item ON item.id=mapping.document_item_id AND item.doc_id=document.id
              AND NOT item.is_deleted
          JOIN warehouses warehouse ON warehouse.id=document.warehouse_id AND warehouse.is_line_side
              AND NOT warehouse.is_deleted AND warehouse.workshop_department_id=segment.workshop_department_id
              AND fn_warehouse_same_main(warehouse.id,package.warehouse_id)
          WHERE mapping.demand_id=demand.id AND mapping.document_type='DRAW'
              AND fn_line_side_stock_targets_demand(warehouse.id,demand.id)
          GROUP BY document.warehouse_id
        ) pending
        JOIN stock_balances balance ON balance.warehouse_id=pending.warehouse_id
          AND balance.goods_id=demand.goods_id AND balance.color_id IS NOT DISTINCT FROM demand.color_id
        CROSS JOIN LATERAL (
          SELECT COALESCE(SUM(reservation.qty-reservation.consumed_qty-reservation.released_qty),0) AS qty
          FROM stock_reservations reservation WHERE reservation.demand_id=demand.id
            AND reservation.warehouse_id=pending.warehouse_id AND NOT reservation.is_deleted
            AND reservation.status=0
        ) held
      ) direct ON TRUE
      WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted
        AND demand.status NOT IN ('RELEASED','REVERSED')
    ),FALSE) END
  FROM production_execution_segments segment
  JOIN production_planning_packages package ON package.id=segment.package_id
  WHERE segment.id=p_segment AND NOT segment.is_deleted
$$;

CREATE OR REPLACE FUNCTION fn_can_start_continuous_supply(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT 1 FROM production_execution_segments segment
    JOIN production_plans plan ON plan.id=segment.plan_id
    JOIN production_planning_packages package ON package.id=segment.package_id
    WHERE segment.id=p_segment AND NOT segment.is_deleted
      AND segment.status IN ('READY','DISPATCHED') AND segment.start_route='CONTINUOUS'
      AND segment.continuous_supply AND segment.workshop_department_id IS NOT NULL
      AND segment.responsible_employee_id IS NOT NULL
      AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped
      AND package.status='CONFIRMED' AND NOT package.is_deleted
      AND fn_execution_start_material_ready(p_segment))
$$;

CREATE OR REPLACE FUNCTION fn_guard_execution_confirmed_route_start()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('DISPATCHED','IN_PROGRESS') THEN
    IF NEW.start_route IS NULL OR NEW.start_route='BATCH' THEN
      RAISE EXCEPTION 'Execution route must be confirmed before starting' USING ERRCODE='23514';
    END IF;
    IF NEW.status='IN_PROGRESS' AND NEW.continuous_supply
       AND fn_execution_material_output_capacity(NEW.id,TRUE)<=0 THEN
      RAISE EXCEPTION 'Continuous execution requires material for positive output' USING ERRCODE='23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_execution_confirmed_route_start
BEFORE UPDATE ON production_execution_segments
FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_confirmed_route_start();

CREATE INDEX idx_execution_continuous_replenishment ON production_execution_segments(id,plan_id)
WHERE continuous_supply AND auto_promote_when_ready AND NOT is_deleted
  AND status IN ('READY','DISPATCHED','IN_PROGRESS');

-- Arrival cards inspect this receipt's origin rights, not the whole event ledger.
CREATE INDEX idx_preplan_entitlement_origin_group
ON preplan_stock_entitlement_events(event_group_id,stock_reservation_id)
WHERE event_type IN ('ORIGIN_IQC','ORIGIN_MAKE');

COMMENT ON COLUMN production_execution_segments.continuous_supply IS
  'Confirmed continuous production: all material sources may arrive and be issued incrementally on the same task; START requires positive common material output capacity.';
COMMENT ON COLUMN production_material_demands.direct_supply IS
  'Eligible same-workshop direct handoff; physical source provenance remains mandatory and does not waive material output capacity.';

UPDATE permissions SET name='确认路线、领料与开工',
    description='在本人车间确认齐套、持续补料或分批路线；提交及追加领料、显式开工。仍受任务归属、物料容量与状态约束，不授予仓库发料或直送审核权限'
WHERE code='production_execution:start';
