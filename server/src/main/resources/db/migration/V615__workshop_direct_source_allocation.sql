-- Direct supply is a responsibility-linked source lot, never all stock of the same SKU on a rack.
-- Existing physical/financial ledgers remain authoritative. This bridge records which exact
-- direct-transfer source funds a formal material reservation; releases follow reservation history.
CREATE FUNCTION fn_workshop_direct_responsibility_allows(p_producing UUID,p_demand UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS(
    SELECT 1 FROM production_execution_segments producing
    JOIN production_plans source_plan ON source_plan.id=producing.plan_id
    JOIN production_material_demands demand ON demand.id=p_demand
    JOIN production_execution_segments receiving ON receiving.id=demand.execution_segment_id
    JOIN production_plans target_plan ON target_plan.id=receiving.plan_id
    LEFT JOIN production_material_analysis_items source_item ON source_item.id=source_plan.material_analysis_item_id
      AND source_item.analysis_id=source_plan.material_analysis_id AND NOT source_item.is_deleted
    WHERE producing.id=p_producing AND NOT producing.is_deleted AND NOT receiving.is_deleted
      AND NOT source_plan.is_deleted AND NOT target_plan.is_deleted AND NOT demand.is_deleted
      AND producing.id<>receiving.id AND demand.supply_route='MAKE'
      AND producing.product_goods_id=demand.goods_id
      AND producing.product_color_id IS NOT DISTINCT FROM demand.color_id
      AND (
        (source_plan.material_analysis_id=target_plan.material_analysis_id
          AND source_item.source_type='MAKE_COMPONENT'
          AND source_item.parent_analysis_material_id IS NOT NULL
          AND fn_analysis_plan_material_matches(target_plan.material_analysis_item_id,source_item.parent_analysis_material_id))
        OR (source_plan.material_analysis_id IS NULL AND target_plan.material_analysis_id IS NULL
          AND ((NOT EXISTS(SELECT 1 FROM production_material_supply_pegs committed
                WHERE committed.demand_id IN(demand.id,demand.split_root_demand_id)
                  AND committed.status<>'REVERSED' AND committed.allocated_qty>committed.released_qty)
            AND EXISTS(SELECT 1 FROM subplan_links link WHERE link.plan_id=target_plan.id
                AND link.subplan_id=source_plan.id AND NOT link.is_deleted
                AND (link.planning_package_id IS NULL OR link.planning_package_id=receiving.package_id)))
            OR EXISTS(SELECT 1 FROM production_material_supply_pegs peg
                WHERE peg.demand_id IN (demand.id,demand.split_root_demand_id)
                  AND peg.supply_type='PRODUCTION_PLAN_ITEM' AND peg.supply_item_id=producing.source_plan_item_id
                  AND peg.status<>'REVERSED' AND peg.allocated_qty>peg.released_qty)))
      ))
$$;

-- Current workshop custody gates new operations, not immutable historical responsibility.
CREATE FUNCTION fn_workshop_direct_relationship_allows(p_producing UUID,p_demand UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT fn_workshop_direct_responsibility_allows(p_producing,p_demand) AND EXISTS(
   SELECT 1 FROM production_execution_segments producing
   JOIN production_material_demands demand ON demand.id=p_demand
   JOIN production_execution_segments receiving ON receiving.id=demand.execution_segment_id
   WHERE producing.id=p_producing AND producing.workshop_department_id=receiving.workshop_department_id)
$$;

CREATE TABLE production_workshop_direct_source_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  allocation_no BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
  transfer_item_id UUID NOT NULL REFERENCES production_workshop_direct_transfer_items(id),
  stock_reservation_id UUID NOT NULL REFERENCES stock_reservations(id),
  qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
  released_baseline NUMERIC(18,4) NOT NULL CHECK(released_baseline>=0),
  command_key TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID,
  UNIQUE(stock_reservation_id,transfer_item_id,command_key)
);
CREATE INDEX idx_workshop_source_allocation_source
  ON production_workshop_direct_source_allocations(transfer_item_id);
CREATE INDEX idx_workshop_source_allocation_reservation
  ON production_workshop_direct_source_allocations(stock_reservation_id,allocation_no);

CREATE TABLE production_workshop_direct_source_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_no BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
    source_allocation_id UUID NOT NULL REFERENCES production_workshop_direct_source_allocations(id),
    stock_posting_id UUID REFERENCES production_material_stock_postings(id),
    counter_event_id UUID REFERENCES production_workshop_direct_source_events(id),
    event_type TEXT NOT NULL CHECK(event_type IN ('ISSUE','ISSUE_REVERSE','GOOD_RETURN','GOOD_RETURN_REVERSE','RELEASE','RESTORE')),
    qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
    historical BOOLEAN NOT NULL DEFAULT FALSE,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK((event_type IN ('RELEASE','RESTORE') AND stock_posting_id IS NULL)
       OR (event_type IN ('ISSUE','ISSUE_REVERSE','GOOD_RETURN','GOOD_RETURN_REVERSE') AND stock_posting_id IS NOT NULL)),
    CHECK((event_type IN ('ISSUE','RELEASE') AND counter_event_id IS NULL)
       OR (event_type IN ('ISSUE_REVERSE','GOOD_RETURN','GOOD_RETURN_REVERSE','RESTORE') AND counter_event_id IS NOT NULL))
);
CREATE INDEX idx_workshop_source_event_allocation ON production_workshop_direct_source_events(source_allocation_id,event_type) INCLUDE(qty_base);
CREATE INDEX idx_workshop_source_event_posting ON production_workshop_direct_source_events(stock_posting_id) INCLUDE(source_allocation_id,qty_base) WHERE stock_posting_id IS NOT NULL;
CREATE INDEX idx_workshop_source_event_counter ON production_workshop_direct_source_events(counter_event_id,event_type) INCLUDE(qty_base) WHERE counter_event_id IS NOT NULL;
CREATE UNIQUE INDEX uq_workshop_source_event_posting_slice ON production_workshop_direct_source_events
    (stock_posting_id,source_allocation_id,counter_event_id) NULLS NOT DISTINCT WHERE stock_posting_id IS NOT NULL;

-- No global window aggregation and no live reclassification of consumed sources.
-- Deleted reservations also require real RELEASE facts; hiding rows is not a release.
CREATE OR REPLACE VIEW v_workshop_direct_source_allocations AS
SELECT allocation.*,
       allocation.qty_base-COALESCE(balance.released_qty,0) AS effective_qty,
       COALESCE(balance.net_issued_qty,0) AS net_issued_qty
FROM production_workshop_direct_source_allocations allocation
LEFT JOIN LATERAL (
    SELECT SUM(CASE event_type WHEN 'RELEASE' THEN qty_base WHEN 'RESTORE' THEN -qty_base ELSE 0 END) AS released_qty,
           SUM(CASE event_type WHEN 'ISSUE' THEN qty_base WHEN 'GOOD_RETURN_REVERSE' THEN qty_base
                    WHEN 'ISSUE_REVERSE' THEN -qty_base WHEN 'GOOD_RETURN' THEN -qty_base ELSE 0 END) AS net_issued_qty
    FROM production_workshop_direct_source_events WHERE source_allocation_id=allocation.id
) balance ON TRUE;


-- The rack is a custody location, never a generic stock pool. Historical moves
-- without an exact production source remain visible for reconciliation; a later
-- delivery cannot silently refill their missing provenance.
CREATE VIEW v_workshop_direct_stock_anomalies AS
SELECT movement.id AS movement_id,movement.warehouse_id,movement.goods_id,movement.color_id,
       movement.source_doc_type,movement.source_doc_id,movement.source_item_id,
       movement.movement_type,movement.direction,movement.qty
FROM stock_movements movement JOIN warehouses warehouse ON warehouse.id=movement.warehouse_id AND warehouse.is_line_side
WHERE NOT (movement.source_doc_type='STOCK_DOC' AND (
    (movement.movement_type IN(5,6) AND EXISTS(SELECT 1 FROM production_material_movement_links link
        WHERE link.movement_id=movement.id))
    OR (movement.movement_type=13 AND EXISTS(
        SELECT 1 FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
        JOIN production_workshop_direct_transfer_items direct ON direct.source_report_item_id=item.source_daily_report_item_id
        JOIN production_workshop_direct_transfers transfer ON transfer.id=direct.transfer_id
        WHERE item.id=movement.source_item_id AND document.id=movement.source_doc_id
          AND document.doc_type='FINISHED_IN' AND document.warehouse_id=movement.warehouse_id
          AND transfer.line_side_warehouse_id=movement.warehouse_id
          AND item.goods_id=movement.goods_id AND item.color_id IS NOT DISTINCT FROM movement.color_id))));

-- One upgrade scan records legacy exceptions. Normal task/lot queries must never
-- rescan every historical movement merely to prove that this set is still empty.
CREATE TABLE production_workshop_direct_legacy_anomalies (
  movement_id UUID PRIMARY KEY REFERENCES stock_movements(id),
  warehouse_id UUID NOT NULL REFERENCES warehouses(id),
  goods_id UUID NOT NULL REFERENCES goods(id),
  color_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES users(id)
);
CREATE INDEX idx_workshop_legacy_anomaly_dimension
  ON production_workshop_direct_legacy_anomalies(warehouse_id,goods_id,color_id);
CREATE FUNCTION fn_guard_workshop_legacy_anomaly() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Historical workshop physical exceptions are immutable reconciliation evidence' USING ERRCODE='55000'; END IF;
 IF NOT EXISTS(SELECT 1 FROM v_workshop_direct_stock_anomalies original
     WHERE original.movement_id=NEW.movement_id AND original.warehouse_id=NEW.warehouse_id
       AND original.goods_id=NEW.goods_id AND original.color_id IS NOT DISTINCT FROM NEW.color_id) THEN
   RAISE EXCEPTION 'Historical workshop exception must retain the exact original unexplained movement' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_workshop_legacy_anomaly BEFORE INSERT OR UPDATE OR DELETE ON production_workshop_direct_legacy_anomalies
FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_legacy_anomaly();
CREATE TRIGGER trg_audit_production_workshop_direct_legacy_anomalies AFTER INSERT OR UPDATE OR DELETE ON production_workshop_direct_legacy_anomalies
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_direct_legacy_anomalies ENABLE ALWAYS TRIGGER trg_audit_production_workshop_direct_legacy_anomalies;
INSERT INTO production_workshop_direct_legacy_anomalies(movement_id,warehouse_id,goods_id,color_id)
SELECT movement_id,warehouse_id,goods_id,color_id FROM v_workshop_direct_stock_anomalies;

CREATE FUNCTION fn_guard_workshop_direct_physical_movement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM v_workshop_direct_stock_anomalies WHERE movement_id=NEW.id) THEN
   RAISE EXCEPTION 'Technical workshop stock requires exact direct receipt or production issue/return provenance; ordinary transfer is not permitted'
     USING ERRCODE='23514',CONSTRAINT='workshop_direct_physical_provenance';
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_workshop_direct_physical_provenance AFTER INSERT ON stock_movements
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_direct_physical_movement();
ALTER TABLE stock_movements ENABLE ALWAYS TRIGGER trg_workshop_direct_physical_provenance;

CREATE VIEW v_workshop_direct_supply_lots AS
SELECT transfer_item.id,transfer_item.to_demand_id,transfer_item.to_execution_segment_id,
  transfer_item.created_at,source.execution_segment_id AS producing_segment_id,
  source.goods_id,source.color_id,transfer.line_side_warehouse_id,
  LEAST(round(transfer_item.qty*COALESCE(source.unit_rate,1),4),inbound.qty) AS received_qty,
  CASE WHEN EXISTS(SELECT 1 FROM production_workshop_direct_legacy_anomalies anomaly
      WHERE anomaly.warehouse_id=transfer.line_side_warehouse_id AND anomaly.goods_id=source.goods_id
        AND anomaly.color_id IS NOT DISTINCT FROM source.color_id) THEN 0 ELSE
  GREATEST(LEAST(round(transfer_item.qty*COALESCE(source.unit_rate,1),4),inbound.qty)
    -COALESCE((SELECT SUM(allocation.effective_qty) FROM v_workshop_direct_source_allocations allocation
      WHERE allocation.transfer_item_id=transfer_item.id),0),0) END AS available_qty
FROM production_workshop_direct_transfer_items transfer_item
JOIN production_workshop_direct_transfers transfer ON transfer.id=transfer_item.transfer_id
JOIN production_daily_report_items source ON source.id=transfer_item.source_report_item_id AND NOT source.is_deleted
JOIN production_daily_reports report ON report.id=source.report_id AND report.status=1 AND NOT report.is_deleted
CROSS JOIN LATERAL (
  SELECT COALESCE(SUM(COALESCE(item.base_qty,item.qty*COALESCE(item.unit_rate,1))),0) AS qty
  FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
    AND document.doc_type='FINISHED_IN' AND document.status=1 AND NOT document.is_deleted
    AND document.warehouse_id=transfer.line_side_warehouse_id
  WHERE item.source_daily_report_item_id=source.id AND NOT item.is_deleted
) inbound
WHERE transfer_item.reversal_id IS NULL;

-- Historical reconstruction can describe proven old holdings in a quarantined
-- dimension. It cannot create a lifetime allocation larger than the real receipt.
CREATE FUNCTION fn_workshop_direct_claim_capacity(p_source UUID,p_historical BOOLEAN,p_release_credit NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT GREATEST(LEAST(lot.received_qty,
   CASE WHEN p_historical THEN lot.received_qty-COALESCE((SELECT SUM(effective_qty)
       FROM v_workshop_direct_source_allocations WHERE transfer_item_id=lot.id),0)+p_release_credit
   ELSE lot.available_qty END),0)
 FROM v_workshop_direct_supply_lots lot WHERE lot.id=p_source
$$;

CREATE FUNCTION fn_workshop_direct_source_available(p_warehouse UUID,p_demand UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT COALESCE(SUM(lot.available_qty),0)
 FROM production_material_demands demand JOIN v_workshop_direct_supply_lots lot
   ON lot.to_demand_id IN (demand.id,demand.split_root_demand_id)
  AND lot.line_side_warehouse_id=p_warehouse AND lot.goods_id=demand.goods_id
  AND lot.color_id IS NOT DISTINCT FROM demand.color_id
 WHERE demand.id=p_demand AND fn_workshop_direct_relationship_allows(lot.producing_segment_id,demand.id)
$$;

CREATE FUNCTION fn_workshop_direct_receipt_available(p_receipt_item UUID,p_demand UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT COALESCE(SUM(lot.available_qty),0)
 FROM stock_document_items incoming
 JOIN production_workshop_direct_transfer_items transfer_item ON transfer_item.source_report_item_id=incoming.source_daily_report_item_id
 JOIN v_workshop_direct_supply_lots lot ON lot.id=transfer_item.id
 JOIN production_material_demands demand ON demand.id=p_demand AND lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
 WHERE incoming.id=p_receipt_item AND fn_workshop_direct_relationship_allows(lot.producing_segment_id,demand.id)
$$;

CREATE FUNCTION fn_workshop_entitlement_source_allows(p_source_reservation UUID,p_demand UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN warehouse.is_line_side THEN EXISTS(
     SELECT 1 FROM preplan_analysis_stock_exact_pegs exact
     JOIN stock_document_items incoming ON incoming.id=exact.source_stock_document_item_id
     JOIN production_workshop_direct_transfer_items transfer_item ON transfer_item.source_report_item_id=incoming.source_daily_report_item_id
     JOIN v_workshop_direct_supply_lots lot ON lot.id=transfer_item.id AND lot.available_qty>0
     JOIN production_material_demands demand ON demand.id=p_demand AND lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
     WHERE exact.stock_reservation_id=source.id AND fn_workshop_direct_relationship_allows(lot.producing_segment_id,demand.id)
   ) ELSE TRUE END
 FROM stock_reservations source JOIN warehouses warehouse ON warehouse.id=source.warehouse_id
 WHERE source.id=p_source_reservation
$$;

CREATE FUNCTION fn_claim_workshop_direct_sources(p_reservation UUID,p_command TEXT,p_actor UUID,p_historical BOOLEAN DEFAULT FALSE,p_preferences JSONB DEFAULT '[]')
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE target stock_reservations%ROWTYPE; remaining NUMERIC; baseline NUMERIC; source RECORD; take NUMERIC;
        preference RECORD; preferred_id UUID; part INTEGER:=0; available NUMERIC; candidate_count BIGINT; candidate_total NUMERIC;
BEGIN
  SELECT * INTO target FROM stock_reservations WHERE id=p_reservation FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM warehouses WHERE id=target.warehouse_id AND is_line_side) THEN RETURN; END IF;
  SELECT COALESCE(MIN(released_baseline),target.released_qty) INTO baseline
    FROM production_workshop_direct_source_allocations WHERE stock_reservation_id=target.id;
  SELECT GREATEST(target.qty-CASE WHEN p_historical THEN 0 ELSE target.released_qty END-COALESCE(SUM(effective_qty),0),0) INTO remaining
    FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=target.id;
  IF remaining<=0 THEN RETURN; END IF;
  -- Quantity checks are serialized on the actual immutable source rows; a snapshot
  -- taken before waiting on a source lock is never used to claim the source.
  PERFORM transfer_item.id FROM production_workshop_direct_transfer_items transfer_item
    JOIN production_workshop_direct_transfers transfer ON transfer.id=transfer_item.transfer_id
    JOIN production_material_demands demand ON demand.id=target.demand_id
      AND transfer_item.to_demand_id IN(demand.id,demand.split_root_demand_id)
    JOIN production_daily_report_items report_item ON report_item.id=transfer_item.source_report_item_id
    WHERE transfer.line_side_warehouse_id=target.warehouse_id AND transfer_item.reversal_id IS NULL
      AND (NOT p_historical OR transfer_item.created_at<=target.created_at
        OR NOT EXISTS(SELECT 1 FROM production_material_stock_postings WHERE reservation_id=target.id)
        OR EXISTS(SELECT 1 FROM preplan_stock_entitlement_events formal
            JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=formal.stock_reservation_id
            JOIN stock_document_items incoming ON incoming.id=exact.source_stock_document_item_id
            WHERE formal.event_type='FORMALIZE' AND formal.target_stock_reservation_id=target.id
              AND incoming.source_daily_report_item_id=report_item.id))
      AND (CASE WHEN p_historical THEN fn_workshop_direct_responsibility_allows(report_item.execution_segment_id,demand.id)
           ELSE fn_workshop_direct_relationship_allows(report_item.execution_segment_id,demand.id) END)
    ORDER BY transfer_item.id FOR UPDATE OF transfer_item;
  FOR preference IN SELECT * FROM jsonb_to_recordset(p_preferences) AS p(receipt_item_id uuid,source_reservation_id uuid,qty numeric)
  LOOP
    part:=part+1;
    SELECT transfer_item.id INTO preferred_id
    FROM stock_document_items incoming
    JOIN production_workshop_direct_transfer_items transfer_item ON transfer_item.source_report_item_id=incoming.source_daily_report_item_id
    JOIN v_workshop_direct_supply_lots lot ON lot.id=transfer_item.id AND lot.line_side_warehouse_id=target.warehouse_id
    JOIN production_material_demands demand ON demand.id=target.demand_id
      AND lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
    WHERE incoming.id=COALESCE(preference.receipt_item_id,(SELECT source_stock_document_item_id
      FROM preplan_analysis_stock_exact_pegs WHERE stock_reservation_id=preference.source_reservation_id))
      AND (CASE WHEN p_historical THEN fn_workshop_direct_responsibility_allows(lot.producing_segment_id,demand.id)
           ELSE fn_workshop_direct_relationship_allows(lot.producing_segment_id,demand.id) END);
    available:=fn_workshop_direct_claim_capacity(preferred_id,p_historical,target.released_qty);
    IF preferred_id IS NULL OR preference.qty<=0 OR preference.qty>remaining OR preference.qty>COALESCE(available,0) THEN
      RAISE EXCEPTION 'exact workshop receipt or entitlement source cannot fund its reserved quantity' USING ERRCODE='23514';
    END IF;
    INSERT INTO production_workshop_direct_source_allocations(transfer_item_id,stock_reservation_id,qty_base,released_baseline,command_key,created_by)
      VALUES(preferred_id,target.id,preference.qty,baseline,CASE WHEN p_historical THEN p_command ELSE p_command||':P'||part END,p_actor)
      ON CONFLICT(stock_reservation_id,transfer_item_id,command_key) DO UPDATE
        SET qty_base=production_workshop_direct_source_allocations.qty_base+EXCLUDED.qty_base
        WHERE p_historical;
    remaining:=remaining-preference.qty;
  END LOOP;
  IF remaining<=0 THEN RETURN; END IF;
  IF p_historical THEN
    SELECT COUNT(*),COALESCE(SUM(fn_workshop_direct_claim_capacity(lot.id,TRUE,0)),0) INTO candidate_count,candidate_total
    FROM v_workshop_direct_supply_lots lot JOIN production_material_demands demand ON demand.id=target.demand_id
      AND lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
    WHERE lot.line_side_warehouse_id=target.warehouse_id AND fn_workshop_direct_claim_capacity(lot.id,TRUE,0)>0
      AND (CASE WHEN p_historical THEN fn_workshop_direct_responsibility_allows(lot.producing_segment_id,demand.id)
           ELSE fn_workshop_direct_relationship_allows(lot.producing_segment_id,demand.id) END);
    IF candidate_count>1 AND candidate_total>remaining THEN
      RAISE EXCEPTION 'Ambiguous historical source ownership requires exact origin proof: %',target.id USING ERRCODE='23514';
    END IF;
  END IF;
  FOR source IN
    SELECT transfer_item.id FROM production_workshop_direct_transfer_items transfer_item
    JOIN production_workshop_direct_transfers transfer ON transfer.id=transfer_item.transfer_id
    JOIN production_material_demands demand ON demand.id=target.demand_id
      AND transfer_item.to_demand_id IN(demand.id,demand.split_root_demand_id)
    JOIN production_daily_report_items report_item ON report_item.id=transfer_item.source_report_item_id
    WHERE transfer.line_side_warehouse_id=target.warehouse_id AND transfer_item.reversal_id IS NULL
      AND (NOT p_historical OR transfer_item.created_at<=target.created_at
        OR NOT EXISTS(SELECT 1 FROM production_material_stock_postings WHERE reservation_id=target.id)
        OR EXISTS(SELECT 1 FROM preplan_stock_entitlement_events formal
            JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=formal.stock_reservation_id
            JOIN stock_document_items incoming ON incoming.id=exact.source_stock_document_item_id
            WHERE formal.event_type='FORMALIZE' AND formal.target_stock_reservation_id=target.id
              AND incoming.source_daily_report_item_id=report_item.id))
      AND (CASE WHEN p_historical THEN fn_workshop_direct_responsibility_allows(report_item.execution_segment_id,demand.id)
           ELSE fn_workshop_direct_relationship_allows(report_item.execution_segment_id,demand.id) END)
    ORDER BY transfer_item.created_at,transfer_item.id
  LOOP
    take:=LEAST(remaining,fn_workshop_direct_claim_capacity(source.id,p_historical,target.released_qty));
    IF COALESCE(take,0)<=0 THEN CONTINUE; END IF;
    INSERT INTO production_workshop_direct_source_allocations(
      transfer_item_id,stock_reservation_id,qty_base,released_baseline,command_key,created_by)
    VALUES(source.id,target.id,take,baseline,CASE WHEN p_historical THEN p_command ELSE p_command||':FREE' END,p_actor)
    ON CONFLICT(stock_reservation_id,transfer_item_id,command_key) DO UPDATE
      SET qty_base=production_workshop_direct_source_allocations.qty_base+EXCLUDED.qty_base WHERE p_historical;
    remaining:=remaining-take;
    EXIT WHEN remaining<=0;
  END LOOP;
  IF remaining>0 THEN
    RAISE EXCEPTION 'workshop material reservation lacks exact dedicated direct-transfer source: %, shortage %',target.id,remaining
      USING ERRCODE='23514',CONSTRAINT='workshop_direct_source_quantity_guard';
  END IF;
END $$;

CREATE FUNCTION fn_workshop_source_issue_open(p_event UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT issue.qty_base
      -COALESCE((SELECT SUM(outflow.qty_base) FROM production_workshop_direct_source_events outflow
          WHERE outflow.counter_event_id=issue.id AND outflow.event_type IN ('ISSUE_REVERSE','GOOD_RETURN')),0)
      +COALESCE((SELECT SUM(back.qty_base) FROM production_workshop_direct_source_events returned
          JOIN production_workshop_direct_source_events back ON back.counter_event_id=returned.id AND back.event_type='GOOD_RETURN_REVERSE'
          WHERE returned.counter_event_id=issue.id AND returned.event_type='GOOD_RETURN'),0)
    FROM production_workshop_direct_source_events issue WHERE issue.id=p_event AND issue.event_type='ISSUE';
$$;

CREATE FUNCTION fn_lock_workshop_source_rows(p_reservation UUID) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM production_workshop_direct_transfer_items source
    WHERE source.id IN (SELECT transfer_item_id FROM production_workshop_direct_source_allocations WHERE stock_reservation_id=p_reservation)
    ORDER BY source.id FOR UPDATE;
END;
$$;

CREATE FUNCTION fn_guard_workshop_direct_source_event() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE allocation production_workshop_direct_source_allocations%ROWTYPE;
        posting production_material_stock_postings%ROWTYPE;
        counter production_workshop_direct_source_events%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Workshop direct source events are append-only' USING ERRCODE='55000'; END IF;
    SELECT * INTO allocation FROM production_workshop_direct_source_allocations WHERE id=NEW.source_allocation_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Source event allocation is missing' USING ERRCODE='23514'; END IF;
    PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=allocation.transfer_item_id FOR UPDATE;
    IF NEW.counter_event_id IS NOT NULL THEN
        SELECT * INTO counter FROM production_workshop_direct_source_events WHERE id=NEW.counter_event_id;
        IF NOT FOUND OR counter.source_allocation_id<>NEW.source_allocation_id
           OR counter.event_type<>(CASE NEW.event_type WHEN 'RESTORE' THEN 'RELEASE'
                 WHEN 'GOOD_RETURN_REVERSE' THEN 'GOOD_RETURN' ELSE 'ISSUE' END) THEN
            RAISE EXCEPTION 'Source reversal must retain its exact original allocation and event' USING ERRCODE='23514';
        END IF;
    END IF;
    IF NEW.stock_posting_id IS NOT NULL THEN
        SELECT * INTO posting FROM production_material_stock_postings WHERE id=NEW.stock_posting_id;
        IF NOT FOUND OR posting.reservation_id<>allocation.stock_reservation_id OR posting.posting_type<>NEW.event_type
           OR (NEW.event_type<>'ISSUE' AND counter.stock_posting_id IS DISTINCT FROM posting.source_posting_id) THEN
            RAISE EXCEPTION 'Source event must match the exact material posting and original posting' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- p_historical is used only by the strictly checked migration routine below.
CREATE FUNCTION fn_record_workshop_direct_posting(p_posting UUID,p_historical BOOLEAN DEFAULT FALSE)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE posting production_material_stock_postings%ROWTYPE; held stock_reservations%ROWTYPE;
        part RECORD; remaining NUMERIC; available NUMERIC; take NUMERIC; existing NUMERIC; only_source UUID; counter UUID;
BEGIN
    SELECT * INTO posting FROM production_material_stock_postings WHERE id=p_posting;
    IF NOT FOUND THEN RAISE EXCEPTION 'Source material posting is missing' USING ERRCODE='23514'; END IF;
    SELECT * INTO held FROM stock_reservations WHERE id=posting.reservation_id FOR UPDATE;
    IF held.owner_type IS DISTINCT FROM 'PRODUCTION_MATERIAL_DEMAND'
       OR NOT EXISTS(SELECT 1 FROM warehouses WHERE id=held.warehouse_id AND is_line_side) THEN RETURN; END IF;
    PERFORM fn_lock_workshop_source_rows(held.id);
    SELECT SUM(qty_base) INTO existing FROM production_workshop_direct_source_events WHERE stock_posting_id=posting.id;
    IF existing IS NOT NULL THEN
        IF existing<>posting.qty_base THEN RAISE EXCEPTION 'Partial source posting replay is not permitted' USING ERRCODE='23514'; END IF;
        RETURN;
    END IF;
    -- A single proven historical source is exact regardless of the old transaction's
    -- timestamp ordering. Final deferred balances validate the complete replay.
    IF p_historical AND (SELECT COUNT(*) FROM production_workshop_direct_source_allocations WHERE stock_reservation_id=held.id)=1 THEN
        SELECT id INTO only_source FROM production_workshop_direct_source_allocations WHERE stock_reservation_id=held.id;
        IF posting.posting_type<>'ISSUE' THEN
            SELECT id INTO counter FROM production_workshop_direct_source_events
            WHERE stock_posting_id=posting.source_posting_id AND source_allocation_id=only_source;
            IF counter IS NULL THEN RAISE EXCEPTION 'Historical source posting dependency is missing' USING ERRCODE='23514'; END IF;
        END IF;
        INSERT INTO production_workshop_direct_source_events(source_allocation_id,stock_posting_id,counter_event_id,event_type,qty_base,historical,created_by)
        VALUES(only_source,posting.id,counter,posting.posting_type,posting.qty_base,TRUE,NULL);
        RETURN;
    END IF;
    remaining:=posting.qty_base;
    IF posting.posting_type='ISSUE' THEN
        FOR part IN SELECT id,effective_qty-net_issued_qty AS free_qty FROM v_workshop_direct_source_allocations
                    WHERE stock_reservation_id=held.id ORDER BY allocation_no LOOP
            take:=LEAST(remaining,GREATEST(part.free_qty,0));
            IF take<=0 THEN CONTINUE; END IF;
            INSERT INTO production_workshop_direct_source_events(source_allocation_id,stock_posting_id,event_type,qty_base,historical,created_by)
            VALUES(part.id,posting.id,'ISSUE',take,p_historical,CASE WHEN p_historical THEN NULL ELSE posting.created_by END);
            remaining:=remaining-take; EXIT WHEN remaining=0;
        END LOOP;
    ELSE
        FOR part IN SELECT event.id,event.source_allocation_id,event.qty_base,event.event_type
                    FROM production_workshop_direct_source_events event
                    JOIN production_workshop_direct_source_allocations allocation ON allocation.id=event.source_allocation_id
                    WHERE event.stock_posting_id=posting.source_posting_id
                    ORDER BY allocation.allocation_no,event.event_no LOOP
            IF posting.posting_type='GOOD_RETURN_REVERSE' THEN
                SELECT part.qty_base-COALESCE(SUM(qty_base),0) INTO available
                FROM production_workshop_direct_source_events WHERE counter_event_id=part.id AND event_type='GOOD_RETURN_REVERSE';
            ELSE available:=fn_workshop_source_issue_open(part.id); END IF;
            take:=LEAST(remaining,GREATEST(COALESCE(available,0),0));
            IF take<=0 THEN CONTINUE; END IF;
            INSERT INTO production_workshop_direct_source_events(source_allocation_id,stock_posting_id,counter_event_id,event_type,qty_base,historical,created_by)
            VALUES(part.source_allocation_id,posting.id,part.id,posting.posting_type,take,p_historical,CASE WHEN p_historical THEN NULL ELSE posting.created_by END);
            remaining:=remaining-take; EXIT WHEN remaining=0;
        END LOOP;
    END IF;
    IF remaining<>0 THEN RAISE EXCEPTION 'Material posting lacks an exact unconsumed source slice: %, missing %',posting.id,remaining USING ERRCODE='23514'; END IF;
END;
$$;

-- Positive delta releases unused sources; negative delta restores the exact previous
-- RELEASE slices in reverse event order. It never substitutes a newly available lot.
CREATE FUNCTION fn_record_workshop_source_release(p_reservation UUID,p_delta NUMERIC,p_actor UUID,p_historical BOOLEAN DEFAULT FALSE)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE remaining NUMERIC:=abs(p_delta); part RECORD; take NUMERIC;
BEGIN
    IF p_delta=0 THEN RETURN; END IF;
    PERFORM fn_lock_workshop_source_rows(p_reservation);
    IF p_delta>0 THEN
        FOR part IN SELECT id,effective_qty-net_issued_qty AS free_qty FROM v_workshop_direct_source_allocations
                    WHERE stock_reservation_id=p_reservation ORDER BY allocation_no LOOP
            take:=LEAST(remaining,GREATEST(part.free_qty,0));
            IF take<=0 THEN CONTINUE; END IF;
            INSERT INTO production_workshop_direct_source_events(source_allocation_id,event_type,qty_base,historical,created_by)
            VALUES(part.id,'RELEASE',take,p_historical,p_actor);
            remaining:=remaining-take; EXIT WHEN remaining=0;
        END LOOP;
    ELSE
        FOR part IN SELECT release.id,release.source_allocation_id,
                        release.qty_base-COALESCE((SELECT SUM(back.qty_base) FROM production_workshop_direct_source_events back
                            WHERE back.counter_event_id=release.id AND back.event_type='RESTORE'),0) AS restorable
                    FROM production_workshop_direct_source_events release
                    JOIN production_workshop_direct_source_allocations allocation ON allocation.id=release.source_allocation_id
                    WHERE allocation.stock_reservation_id=p_reservation AND release.event_type='RELEASE'
                    ORDER BY release.event_no DESC LOOP
            take:=LEAST(remaining,GREATEST(part.restorable,0));
            IF take<=0 THEN CONTINUE; END IF;
            INSERT INTO production_workshop_direct_source_events(source_allocation_id,counter_event_id,event_type,qty_base,historical,created_by)
            VALUES(part.source_allocation_id,part.id,'RESTORE',take,p_historical,p_actor);
            remaining:=remaining-take; EXIT WHEN remaining=0;
        END LOOP;
    END IF;
    IF remaining<>0 THEN RAISE EXCEPTION 'Reservation release/restoration would change consumed or unproven sources: %, missing %',p_reservation,remaining USING ERRCODE='23514'; END IF;
END;
$$;

CREATE FUNCTION fn_assert_workshop_source_event_balances(p_reservation UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE held stock_reservations%ROWTYPE; expected_hold NUMERIC; actual_hold NUMERIC; actual_issued NUMERIC;
BEGIN
    SELECT * INTO held FROM stock_reservations WHERE id=p_reservation;
    IF NOT FOUND OR held.owner_type IS DISTINCT FROM 'PRODUCTION_MATERIAL_DEMAND'
       OR NOT EXISTS(SELECT 1 FROM warehouses WHERE id=held.warehouse_id AND is_line_side) THEN RETURN; END IF;
    PERFORM fn_lock_workshop_source_rows(held.id);
    expected_hold:=CASE WHEN held.is_deleted THEN 0 ELSE held.qty-held.released_qty END;
    SELECT COALESCE(SUM(effective_qty),0),COALESCE(SUM(net_issued_qty),0) INTO actual_hold,actual_issued
    FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=held.id;
    IF actual_hold<>expected_hold OR actual_issued<>held.consumed_qty
       OR held.is_deleted AND held.consumed_qty<>0 OR EXISTS(
        SELECT 1 FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=held.id
          AND (effective_qty<0 OR effective_qty>qty_base OR net_issued_qty<0 OR net_issued_qty>effective_qty)) THEN
        RAISE EXCEPTION 'Exact workshop source holdings or consumption differ from the reservation' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM production_material_stock_postings posting WHERE posting.reservation_id=held.id
        AND posting.qty_base<>COALESCE((SELECT SUM(qty_base) FROM production_workshop_direct_source_events WHERE stock_posting_id=posting.id),0)) THEN
        RAISE EXCEPTION 'Every workshop material posting requires complete exact source coverage' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM production_workshop_direct_source_events original
        JOIN production_workshop_direct_source_allocations allocation ON allocation.id=original.source_allocation_id
        WHERE allocation.stock_reservation_id=held.id AND (
          original.event_type='ISSUE' AND fn_workshop_source_issue_open(original.id)<0
          OR original.event_type IN ('RELEASE','GOOD_RETURN') AND original.qty_base<COALESCE((
              SELECT SUM(back.qty_base) FROM production_workshop_direct_source_events back
              WHERE back.counter_event_id=original.id AND back.event_type IN ('RESTORE','GOOD_RETURN_REVERSE')),0))) THEN
        RAISE EXCEPTION 'A workshop source counter event exceeds its original slice' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM (SELECT DISTINCT transfer_item_id FROM production_workshop_direct_source_allocations WHERE stock_reservation_id=held.id) touched
        LEFT JOIN v_workshop_direct_supply_lots lot ON lot.id=touched.transfer_item_id
        WHERE COALESCE((SELECT SUM(effective_qty) FROM v_workshop_direct_source_allocations WHERE transfer_item_id=touched.transfer_item_id),0)>COALESCE(lot.received_qty,0)) THEN
        RAISE EXCEPTION 'A restored workshop source has been consumed or reserved elsewhere' USING ERRCODE='23514';
    END IF;
END;
$$;

CREATE FUNCTION fn_backfill_workshop_direct_source_events(p_reservation UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE held stock_reservations%ROWTYPE; sources BIGINT; postings BIGINT; posting RECORD; full_issue BOOLEAN;
BEGIN
    SELECT * INTO held FROM stock_reservations WHERE id=p_reservation FOR UPDATE;
    SELECT COUNT(*) INTO sources FROM production_workshop_direct_source_allocations WHERE stock_reservation_id=held.id;
    IF sources=0 OR EXISTS(SELECT 1 FROM production_workshop_direct_source_allocations WHERE stock_reservation_id=held.id AND command_key<>'V615-HISTORICAL') THEN
        RAISE EXCEPTION 'Historical source replay requires migration-owned original holdings' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM production_workshop_direct_source_allocations allocation
        LEFT JOIN v_workshop_direct_supply_lots lot ON lot.id=allocation.transfer_item_id
        WHERE allocation.stock_reservation_id=held.id AND allocation.qty_base>COALESCE(lot.received_qty,0)) THEN
        RAISE EXCEPTION 'Historical source lifetime allocation exceeds its proven receipt' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM production_workshop_direct_source_events event JOIN production_workshop_direct_source_allocations allocation ON allocation.id=event.source_allocation_id
              WHERE allocation.stock_reservation_id=held.id) THEN
        PERFORM fn_assert_workshop_source_event_balances(held.id); RETURN;
    END IF;
    SELECT COUNT(*),COALESCE(BOOL_AND(posting_type='ISSUE' AND qty_base=held.qty),FALSE)
      INTO postings,full_issue FROM production_material_stock_postings WHERE reservation_id=held.id;
    IF sources>1 AND NOT (held.released_qty=0 AND
        (postings=0 AND held.consumed_qty=0 OR postings=1 AND full_issue AND held.consumed_qty=held.qty)) THEN
        RAISE EXCEPTION 'Ambiguous historical multi-source consumption/release requires reconciliation: %',held.id USING ERRCODE='23514';
    END IF;
    FOR posting IN
        WITH RECURSIVE dependencies AS (
            SELECT id,created_at,0 AS depth FROM production_material_stock_postings WHERE reservation_id=held.id AND posting_type='ISSUE'
            UNION ALL SELECT child.id,child.created_at,parent.depth+1 FROM production_material_stock_postings child
            JOIN dependencies parent ON parent.id=child.source_posting_id WHERE child.reservation_id=held.id)
        SELECT id FROM dependencies ORDER BY depth,created_at,id
    LOOP PERFORM fn_record_workshop_direct_posting(posting.id,TRUE); END LOOP;
    IF held.released_qty>0 THEN PERFORM fn_record_workshop_source_release(held.id,held.released_qty,NULL,TRUE); END IF;
    PERFORM fn_assert_workshop_source_event_balances(held.id);
END;
$$;

CREATE FUNCTION fn_capture_workshop_source_posting() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN PERFORM fn_record_workshop_direct_posting(NEW.id,FALSE); RETURN NULL; END;
$$;
CREATE FUNCTION fn_capture_workshop_source_reservation_release() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE delta NUMERIC;
BEGIN
    IF NEW.owner_type IS DISTINCT FROM 'PRODUCTION_MATERIAL_DEMAND' OR NOT EXISTS(SELECT 1 FROM warehouses WHERE id=NEW.warehouse_id AND is_line_side) THEN RETURN NULL; END IF;
    delta:=CASE WHEN NOT OLD.is_deleted AND NEW.is_deleted THEN OLD.qty-OLD.released_qty
                WHEN OLD.is_deleted AND NOT NEW.is_deleted THEN -(NEW.qty-NEW.released_qty)
                WHEN OLD.is_deleted AND NEW.is_deleted THEN 0 ELSE NEW.released_qty-OLD.released_qty END;
    PERFORM fn_record_workshop_source_release(NEW.id,delta,NULLIF(current_setting('app.actor_id',TRUE),'')::UUID,FALSE);
    RETURN NULL;
END;
$$;
CREATE FUNCTION fn_check_workshop_source_event_balance() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE held UUID;
BEGIN
    IF TG_TABLE_NAME='production_workshop_direct_source_events' THEN
        SELECT stock_reservation_id INTO held FROM production_workshop_direct_source_allocations WHERE id=NEW.source_allocation_id;
    ELSIF TG_TABLE_NAME='production_material_stock_postings' THEN held:=NEW.reservation_id;
    ELSE held:=NEW.id; END IF;
    PERFORM fn_assert_workshop_source_event_balances(held); RETURN NULL;
END;
$$;


CREATE TRIGGER trg_guard_workshop_direct_source_event BEFORE INSERT OR UPDATE OR DELETE ON production_workshop_direct_source_events
FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_direct_source_event();
ALTER TABLE production_workshop_direct_source_events ENABLE ALWAYS TRIGGER trg_guard_workshop_direct_source_event;
CREATE TRIGGER trg_00_workshop_direct_source_posting AFTER INSERT ON production_material_stock_postings
FOR EACH ROW EXECUTE FUNCTION fn_capture_workshop_source_posting();
ALTER TABLE production_material_stock_postings ENABLE ALWAYS TRIGGER trg_00_workshop_direct_source_posting;
CREATE TRIGGER trg_00_workshop_source_reservation_release AFTER UPDATE ON stock_reservations
FOR EACH ROW EXECUTE FUNCTION fn_capture_workshop_source_reservation_release();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_00_workshop_source_reservation_release;
CREATE CONSTRAINT TRIGGER trg_check_workshop_source_event_balance AFTER INSERT ON production_workshop_direct_source_events
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_workshop_source_event_balance();
ALTER TABLE production_workshop_direct_source_events ENABLE ALWAYS TRIGGER trg_check_workshop_source_event_balance;
CREATE CONSTRAINT TRIGGER trg_check_workshop_source_posting_balance AFTER INSERT ON production_material_stock_postings
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_workshop_source_event_balance();
ALTER TABLE production_material_stock_postings ENABLE ALWAYS TRIGGER trg_check_workshop_source_posting_balance;
CREATE CONSTRAINT TRIGGER trg_check_workshop_source_reservation_balance AFTER INSERT OR UPDATE ON stock_reservations
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_workshop_source_event_balance();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_check_workshop_source_reservation_balance;
CREATE TRIGGER trg_audit_production_workshop_direct_source_events AFTER INSERT OR UPDATE OR DELETE ON production_workshop_direct_source_events
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_direct_source_events ENABLE ALWAYS TRIGGER trg_audit_production_workshop_direct_source_events;

-- No historic quantity is rewritten. Only provable active holdings are linked to
-- preceding real source lots. Ambiguous old holdings stop migration for reconciliation.
DO $migration$
DECLARE reservation RECORD; preferences JSONB;
BEGIN
  FOR reservation IN SELECT held.id FROM stock_reservations held JOIN warehouses warehouse ON warehouse.id=held.warehouse_id
      WHERE warehouse.is_line_side AND held.owner_type='PRODUCTION_MATERIAL_DEMAND'
        AND NOT held.is_deleted AND held.qty>held.released_qty ORDER BY held.created_at,held.id
  LOOP
    SELECT COALESCE(jsonb_agg(jsonb_build_object('source_reservation_id',proof.source_id,'qty',proof.qty)),'[]'::jsonb)
      INTO preferences FROM (SELECT formal.stock_reservation_id AS source_id,SUM(formal.qty) AS qty
        FROM preplan_stock_entitlement_events formal WHERE formal.event_type='FORMALIZE'
          AND formal.target_stock_reservation_id=reservation.id GROUP BY formal.stock_reservation_id) proof;
    PERFORM fn_claim_workshop_direct_sources(reservation.id,'V615-HISTORICAL',NULL,TRUE,preferences);
    PERFORM fn_backfill_workshop_direct_source_events(reservation.id);
  END LOOP;
END $migration$;

-- Repeated physical receipt slices remain separate immutable facts on one task.
DROP INDEX uq_production_material_make_receipt_active;
CREATE UNIQUE INDEX uq_production_material_make_receipt_active ON production_material_make_receipt_allocations(
    receipt_item_id,supply_peg_id,draw_item_id) WHERE status='EFFECTIVE';
DROP INDEX uq_production_material_receipt_allocation_active;
CREATE UNIQUE INDEX uq_production_material_receipt_allocation_active ON production_material_receipt_allocations(
    receipt_item_id,order_peg_id,draw_item_id) WHERE status='EFFECTIVE';
DROP INDEX uq_production_material_subcontract_receipt_active;
CREATE UNIQUE INDEX uq_production_material_subcontract_receipt_active ON production_material_subcontract_receipt_allocations(
    receipt_item_id,order_peg_id,draw_item_id) WHERE status='EFFECTIVE';

-- A fully returned/released reservation can retire while its original receipt
-- remains a true historical funding fact. New funding still requires live capacity.
CREATE FUNCTION fn_receipt_reservation_history_valid(p_reservation UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT (NOT is_deleted AND status IN(0,1))
     OR (is_deleted AND status=-1 AND consumed_qty=0 AND released_qty=qty)
 FROM stock_reservations WHERE id=p_reservation AND owner_type='PRODUCTION_MATERIAL_DEMAND'
$$;

CREATE FUNCTION fn_guard_new_receipt_reservation() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE held stock_reservations%ROWTYPE;
BEGIN
 SELECT * INTO held FROM stock_reservations WHERE id=NEW.reservation_id FOR UPDATE;
 IF NOT FOUND OR held.is_deleted OR held.status NOT IN(0,1)
    OR held.owner_type IS DISTINCT FROM 'PRODUCTION_MATERIAL_DEMAND'
    OR held.qty-held.consumed_qty-held.released_qty<NEW.allocated_qty THEN
   RAISE EXCEPTION 'New receipt funding requires its live unconsumed formal reservation'
     USING ERRCODE='23514',CONSTRAINT='new_receipt_reservation_capacity_guard';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_new_make_receipt_reservation BEFORE INSERT ON production_material_make_receipt_allocations
FOR EACH ROW EXECUTE FUNCTION fn_guard_new_receipt_reservation();
CREATE TRIGGER trg_guard_new_purchase_receipt_reservation BEFORE INSERT ON production_material_receipt_allocations
FOR EACH ROW EXECUTE FUNCTION fn_guard_new_receipt_reservation();
CREATE TRIGGER trg_guard_new_subcontract_receipt_reservation BEFORE INSERT ON production_material_subcontract_receipt_allocations
FOR EACH ROW EXECUTE FUNCTION fn_guard_new_receipt_reservation();
ALTER TABLE production_material_make_receipt_allocations ENABLE ALWAYS TRIGGER trg_guard_new_make_receipt_reservation;
ALTER TABLE production_material_receipt_allocations ENABLE ALWAYS TRIGGER trg_guard_new_purchase_receipt_reservation;
ALTER TABLE production_material_subcontract_receipt_allocations ENABLE ALWAYS TRIGGER trg_guard_new_subcontract_receipt_reservation;

DO $migration$
DECLARE definition TEXT; function_name TEXT;
BEGIN
  FOREACH function_name IN ARRAY ARRAY['fn_assert_make_receipt_allocation','fn_assert_purchase_receipt_allocation','fn_assert_subcontract_receipt_allocation'] LOOP
    SELECT pg_get_functiondef((function_name||'(uuid)')::regprocedure) INTO definition;
    IF position('reservation.warehouse_id = demand.warehouse_id' IN definition)=0
       OR position('draw.warehouse_id = demand.warehouse_id' IN definition)=0
       OR position('reservation.status = 0' IN definition)=0
       OR position('reservation.is_deleted = FALSE' IN definition)=0 THEN
      RAISE EXCEPTION 'V615 unexpected physical receipt provenance definition: %',function_name;
    END IF;
    definition:=replace(definition,'reservation.warehouse_id = demand.warehouse_id',
      'fn_warehouse_same_main(reservation.warehouse_id,demand.warehouse_id)');
    definition:=replace(definition,'draw.warehouse_id = demand.warehouse_id','draw.warehouse_id = reservation.warehouse_id');
    definition:=replace(definition,'reservation.is_deleted = FALSE','fn_receipt_reservation_history_valid(reservation.id)');
    definition:=replace(definition,'reservation.status = 0','TRUE');
    IF function_name='fn_assert_make_receipt_allocation' THEN
      definition:=replace(definition,'receipt.warehouse_id = demand.warehouse_id','receipt.warehouse_id = reservation.warehouse_id');
      definition:=replace(definition,'receipt_item.unit_id = demand.unit_id',
        'receipt_item.unit_id = source_item.unit_id AND COALESCE(receipt_item.unit_rate,1)=COALESCE(source_item.unit_rate,1)');
      definition:=replace(definition,'source_item.unit_id = demand.unit_id',
        'EXISTS(SELECT 1 FROM goods base_goods WHERE base_goods.id=demand.goods_id AND base_goods.unit_id=demand.unit_id)');
    END IF;
    EXECUTE definition;
  END LOOP;
END $migration$;

-- Receipt conversion is a historical funding fact. A later true return and
-- completion release must not rewrite it or compare it to today's net holding.
CREATE OR REPLACE FUNCTION fn_assert_make_reservation_capacity(p_reservation_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE capacity NUMERIC; allocated NUMERIC; precise_workshop BOOLEAN;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('MAKE_RESERVATION:'||p_reservation_id::text,6148615593807138892));
 SELECT reservation.qty,warehouse.is_line_side AND (reservation.qty>reservation.released_qty
     OR EXISTS(SELECT 1 FROM production_workshop_direct_source_allocations WHERE stock_reservation_id=reservation.id))
 INTO capacity,precise_workshop
 FROM stock_reservations reservation JOIN warehouses warehouse ON warehouse.id=reservation.warehouse_id
 WHERE reservation.id=p_reservation_id AND fn_receipt_reservation_history_valid(reservation.id)
 FOR UPDATE OF reservation;
 SELECT COALESCE(SUM(allocated_qty),0) INTO allocated FROM production_material_make_receipt_allocations
 WHERE reservation_id=p_reservation_id AND status='EFFECTIVE';
 IF allocated>COALESCE(capacity,0) THEN
   RAISE EXCEPTION 'MAKE receipt allocation exceeds original reservation quantity'
     USING ERRCODE='23514',CONSTRAINT='production_make_receipt_reservation_capacity_guard';
 END IF;
 IF precise_workshop AND EXISTS(
   SELECT 1 FROM production_material_make_receipt_allocations receipt_allocation
   JOIN stock_document_items receipt ON receipt.id=receipt_allocation.receipt_item_id
   LEFT JOIN production_workshop_direct_transfer_items direct ON direct.source_report_item_id=receipt.source_daily_report_item_id
   WHERE receipt_allocation.reservation_id=p_reservation_id AND receipt_allocation.status='EFFECTIVE'
   GROUP BY direct.id
   HAVING SUM(receipt_allocation.allocated_qty)>COALESCE((SELECT SUM(source.qty_base)
       FROM production_workshop_direct_source_allocations source
       WHERE source.stock_reservation_id=p_reservation_id AND source.transfer_item_id=direct.id),0)
 ) THEN
   RAISE EXCEPTION 'MAKE receipt funding must retain its exact workshop source allocation'
     USING ERRCODE='23514',CONSTRAINT='production_make_receipt_reservation_source_guard';
 END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_line_side_stock_targets_demand(p_line_side UUID,p_demand UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT fn_workshop_direct_source_available(p_line_side,p_demand)>0 OR EXISTS(
    SELECT 1 FROM v_workshop_direct_source_allocations allocation
    JOIN stock_reservations reservation ON reservation.id=allocation.stock_reservation_id
    WHERE reservation.demand_id=p_demand AND reservation.warehouse_id=p_line_side AND allocation.effective_qty>0)
$$;

CREATE OR REPLACE FUNCTION fn_workshop_direct_covered_base_qty(p_demand UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT SUM(qty-released_qty) FROM stock_reservations
      WHERE demand_id=p_demand AND NOT is_deleted),0)
    +COALESCE((SELECT SUM(lot.available_qty) FROM production_material_demands demand
        JOIN v_workshop_direct_supply_lots lot ON lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
        WHERE demand.id=p_demand AND fn_workshop_direct_relationship_allows(lot.producing_segment_id,demand.id)),0)
$$;

CREATE FUNCTION fn_workshop_direct_remaining_for_source(p_producing UUID,p_demand UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 WITH context AS (
   SELECT demand.id,demand.required_qty,producing.source_plan_item_id
   FROM production_material_demands demand CROSS JOIN production_execution_segments producing
   WHERE demand.id=p_demand AND producing.id=p_producing
     AND fn_workshop_direct_relationship_allows(producing.id,demand.id)
 ), assigned AS (
   SELECT peg.id,peg.allocated_qty-peg.released_qty AS capacity
   FROM context JOIN production_material_supply_pegs peg ON peg.demand_id=context.id
     AND peg.supply_type='PRODUCTION_PLAN_ITEM' AND peg.supply_item_id=context.source_plan_item_id
     AND peg.status<>'REVERSED'
 ), committed AS (
   SELECT COALESCE(SUM(allocation.allocated_qty),0) AS converted,
     COALESCE(SUM(allocation.allocated_qty) FILTER(WHERE EXISTS(
       SELECT 1 FROM production_workshop_direct_transfer_items transfer_item
       WHERE transfer_item.source_report_item_id=received.source_daily_report_item_id
         AND transfer_item.to_demand_id=p_demand AND transfer_item.reversal_id IS NULL)),0) AS direct_converted
   FROM assigned JOIN production_material_make_receipt_allocations allocation ON allocation.supply_peg_id=assigned.id
     AND allocation.status='EFFECTIVE'
   JOIN stock_document_items received ON received.id=allocation.receipt_item_id
 ), promised AS (
   SELECT COALESCE(SUM(round(transfer_item.qty*COALESCE(source.unit_rate,1),4)),0) AS direct_qty
   FROM production_workshop_direct_transfer_items transfer_item
   JOIN production_daily_report_items source ON source.id=transfer_item.source_report_item_id
   JOIN production_execution_segments source_segment ON source_segment.id=source.execution_segment_id
   JOIN context ON context.source_plan_item_id=source_segment.source_plan_item_id
   WHERE transfer_item.to_demand_id=p_demand
     AND transfer_item.reversal_id IS NULL
 )
 SELECT COALESCE((SELECT GREATEST(LEAST(required_qty-fn_workshop_direct_covered_base_qty(id),
     CASE WHEN EXISTS(SELECT 1 FROM assigned) THEN
       (SELECT SUM(capacity) FROM assigned)-(SELECT converted FROM committed)
         -GREATEST((SELECT direct_qty FROM promised)-(SELECT direct_converted FROM committed),0)
     ELSE required_qty END),0) FROM context),0)
$$;

CREATE FUNCTION fn_guard_workshop_direct_source_allocation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'workshop source allocation history is append-only' USING ERRCODE='55000'; END IF;
 PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=NEW.transfer_item_id FOR UPDATE;
 IF NOT EXISTS(
   SELECT 1 FROM stock_reservations reservation
   JOIN production_material_demands demand ON demand.id=reservation.demand_id
   JOIN v_workshop_direct_supply_lots lot ON lot.id=NEW.transfer_item_id
     AND lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
     AND lot.line_side_warehouse_id=reservation.warehouse_id AND lot.goods_id=reservation.goods_id
     AND lot.color_id IS NOT DISTINCT FROM reservation.color_id
   WHERE reservation.id=NEW.stock_reservation_id AND reservation.owner_type='PRODUCTION_MATERIAL_DEMAND'
     AND NOT reservation.is_deleted AND fn_workshop_direct_relationship_allows(lot.producing_segment_id,demand.id)
     AND NEW.released_baseline=COALESCE((SELECT MIN(released_baseline) FROM production_workshop_direct_source_allocations
       WHERE stock_reservation_id=reservation.id),reservation.released_qty)
 ) THEN RAISE EXCEPTION 'workshop source allocation has no matching responsibility and physical lot' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_workshop_direct_source_allocation
BEFORE INSERT OR UPDATE OR DELETE ON production_workshop_direct_source_allocations
FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_direct_source_allocation();

CREATE FUNCTION fn_assert_workshop_direct_source_allocation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE reservation_id UUID; source_id UUID;
BEGIN
 IF TG_TABLE_NAME='production_workshop_direct_source_allocations' THEN
   reservation_id:=NEW.stock_reservation_id;source_id:=NEW.transfer_item_id;
 ELSIF TG_TABLE_NAME='stock_reservations' THEN
   IF NEW.owner_type IS DISTINCT FROM 'PRODUCTION_MATERIAL_DEMAND' OR NOT EXISTS(SELECT 1 FROM warehouses WHERE id=NEW.warehouse_id AND is_line_side) THEN RETURN NULL; END IF;
   reservation_id:=NEW.id;
 ELSE source_id:=NEW.id;
 END IF;
 IF source_id IS NOT NULL THEN
   PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=source_id FOR UPDATE;
 ELSIF reservation_id IS NOT NULL THEN
   PERFORM 1 FROM production_workshop_direct_transfer_items transfer_item
     WHERE transfer_item.id IN (SELECT transfer_item_id FROM production_workshop_direct_source_allocations
       WHERE stock_reservation_id=reservation_id) ORDER BY transfer_item.id FOR UPDATE;
 END IF;
 IF reservation_id IS NOT NULL AND EXISTS(
   SELECT 1 FROM stock_reservations reservation WHERE id=reservation_id
     AND (CASE WHEN reservation.is_deleted THEN 0 ELSE reservation.qty-reservation.released_qty END)
       <> COALESCE((SELECT SUM(effective_qty) FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=reservation_id),0)
 ) THEN RAISE EXCEPTION 'workshop reservation and exact source allocations differ' USING ERRCODE='23514'; END IF;
 IF reservation_id IS NOT NULL AND EXISTS(
   SELECT 1 FROM (SELECT DISTINCT transfer_item_id FROM production_workshop_direct_source_allocations
     WHERE stock_reservation_id=reservation_id) touched
   LEFT JOIN v_workshop_direct_supply_lots lot ON lot.id=touched.transfer_item_id
   WHERE COALESCE((SELECT SUM(effective_qty) FROM v_workshop_direct_source_allocations allocation
       WHERE allocation.transfer_item_id=touched.transfer_item_id),0)>COALESCE(lot.received_qty,0)
 ) THEN RAISE EXCEPTION 'restored workshop reservation exceeds its original direct source' USING ERRCODE='23514'; END IF;
 IF source_id IS NOT NULL AND COALESCE((SELECT SUM(effective_qty) FROM v_workshop_direct_source_allocations WHERE transfer_item_id=source_id),0)
     >COALESCE((SELECT received_qty FROM v_workshop_direct_supply_lots WHERE id=source_id),0) THEN
   RAISE EXCEPTION 'workshop direct source is overallocated or reversed while still held' USING ERRCODE='23514';
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_workshop_source_allocation_quantity
AFTER INSERT ON production_workshop_direct_source_allocations DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_assert_workshop_direct_source_allocation();
CREATE CONSTRAINT TRIGGER trg_workshop_source_reservation_quantity
AFTER INSERT OR UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_assert_workshop_direct_source_allocation();
CREATE CONSTRAINT TRIGGER trg_workshop_source_reversal_quantity
AFTER UPDATE ON production_workshop_direct_transfer_items DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_assert_workshop_direct_source_allocation();

CREATE FUNCTION fn_guard_workshop_direct_relationship()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM production_daily_report_items source WHERE source.id=NEW.source_report_item_id
   AND fn_workshop_direct_relationship_allows(source.execution_segment_id,NEW.to_demand_id)) THEN
   RAISE EXCEPTION 'workshop direct transfer requires an exact parent-child supply responsibility' USING ERRCODE='23514';
 END IF;
 IF (SELECT round(NEW.qty*COALESCE(source.unit_rate,1),4)>
       fn_workshop_direct_remaining_for_source(source.execution_segment_id,NEW.to_demand_id)
       FROM production_daily_report_items source WHERE source.id=NEW.source_report_item_id) THEN
   RAISE EXCEPTION 'workshop direct quantity exceeds this exact source responsibility' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_workshop_direct_relationship BEFORE INSERT ON production_workshop_direct_transfer_items
FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_direct_relationship();

CREATE TRIGGER trg_audit_production_workshop_direct_source_allocations
AFTER INSERT OR UPDATE OR DELETE ON production_workshop_direct_source_allocations
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_direct_source_allocations ENABLE ALWAYS TRIGGER trg_audit_production_workshop_direct_source_allocations;

DO $migration$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
  SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
  IF position(anchor IN definition)=0 OR position('(''production_workshop_direct_source_allocations'', ''CLEAR'')' IN definition)>0 THEN
    RAISE EXCEPTION 'V615 cannot extend business_data_reset policy safely';
  END IF;
  EXECUTE replace(definition,anchor,'(''production_workshop_direct_source_allocations'', ''CLEAR''),(''production_workshop_direct_source_events'', ''CLEAR''),(''production_workshop_direct_legacy_anomalies'', ''CLEAR''),'||anchor);
END $migration$;
