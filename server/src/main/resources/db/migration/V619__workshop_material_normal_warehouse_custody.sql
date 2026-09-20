-- This preflight must be the first V619 statement, before every DDL/data change.
-- A verified starting projection plus transaction deltas is exact net-posting
-- conservation. Missing old facts require offline reconciliation, not a runtime
-- compatibility offset, guessed ISSUE or changed material quantity.
LOCK TABLE stock_reservations,production_material_stock_postings IN SHARE ROW EXCLUSIVE MODE;
DO $material_consumption_projection_preflight$
DECLARE inconsistent RECORD;
BEGIN
 SELECT reservation.id,reservation.consumed_qty,COALESCE(posted.net_qty,0) AS net_qty
 INTO inconsistent FROM stock_reservations reservation
 LEFT JOIN (SELECT reservation_id,SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base
     WHEN 'GOOD_RETURN_REVERSE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base
     WHEN 'GOOD_RETURN' THEN -qty_base END) AS net_qty
   FROM production_material_stock_postings GROUP BY reservation_id) posted ON posted.reservation_id=reservation.id
 WHERE reservation.owner_type='PRODUCTION_MATERIAL_DEMAND'
   AND reservation.consumed_qty IS DISTINCT FROM COALESCE(posted.net_qty,0)
 ORDER BY reservation.id LIMIT 1;
 IF FOUND THEN
   RAISE EXCEPTION 'Production material consumption requires migration reconciliation: reservation %, projected %, net issued %',
     inconsistent.id,inconsistent.consumed_qty,inconsistent.net_qty
     USING ERRCODE='23514',CONSTRAINT='production_material_consumption_migration_reconciliation';
 END IF;
END $material_consumption_projection_preflight$;

-- Place with the V619 read-only preflights, before every DDL/data change.
LOCK TABLE production_material_settlement_postings,production_workshop_direct_source_events IN SHARE ROW EXCLUSIVE MODE;
DO $workshop_settlement_source_preflight$
DECLARE unresolved UUID;
BEGIN
 SELECT id INTO unresolved FROM production_material_settlement_postings WHERE issue_posting_id IS NULL ORDER BY id LIMIT 1;
 IF FOUND THEN RAISE EXCEPTION 'Material settlement requires migration reconciliation of its exact ISSUE: %',unresolved USING ERRCODE='23514'; END IF;
 SELECT settlement.id INTO unresolved
 FROM production_material_settlement_postings settlement
 JOIN production_material_stock_postings issued ON issued.id=settlement.issue_posting_id
 WHERE EXISTS(SELECT 1 FROM production_workshop_direct_source_allocations allocation WHERE allocation.stock_reservation_id=issued.reservation_id)
   AND ((SELECT COUNT(*) FROM production_workshop_direct_source_events source WHERE source.stock_posting_id=issued.id AND source.event_type='ISSUE')=0
     OR ((SELECT COUNT(*) FROM production_workshop_direct_source_events source WHERE source.stock_posting_id=issued.id AND source.event_type='ISSUE')>1
       AND settlement.qty_base<>issued.qty_base))
 ORDER BY settlement.id LIMIT 1;
 IF FOUND THEN RAISE EXCEPTION 'Ambiguous historical workshop settlement source slices require migration reconciliation: %',unresolved USING ERRCODE='23514'; END IF;
END $workshop_settlement_source_preflight$;


-- Normal storage of workshop material keeps its original owner and source.
-- V618 authorizes the actual receiving leaf; this migration supplies custody.
DO $custody_owner$
DECLARE constraint_name TEXT; definition TEXT; extra TEXT;
BEGIN
 FOREACH constraint_name IN ARRAY ARRAY['stock_reservations_owner_type_chk','stock_reservations_purpose_chk','stock_reservations_owner_shape_chk'] LOOP
  SELECT pg_get_expr(conbin,conrelid) INTO definition FROM pg_constraint
   WHERE conrelid='stock_reservations'::regclass AND conname=constraint_name;
  IF definition IS NULL THEN RAISE EXCEPTION 'Reservation owner contract missing: %',constraint_name; END IF;
  extra:=CASE constraint_name
   WHEN 'stock_reservations_owner_type_chk' THEN 'owner_type=''WORKSHOP_CUSTODY'''
   WHEN 'stock_reservations_purpose_chk' THEN 'purpose=''WORKSHOP_CUSTODY'''
   ELSE 'owner_type=''WORKSHOP_CUSTODY'' AND purpose=''WORKSHOP_CUSTODY'' AND owner_id IS NOT NULL
     AND demand_id IS NULL AND order_item_id IS NULL AND warehouse_id IS NOT NULL AND consumed_qty=0
     AND (status=0 OR released_qty=qty) AND (NOT is_deleted OR released_qty=qty)
     AND supply_type=''STOCK_BALANCE'' AND supply_id IS NOT NULL
     AND source_doc_type=''WORKSHOP_RETURN_CUSTODY'' AND source_doc_id IS NOT NULL AND idempotency_key IS NOT NULL' END;
  EXECUTE format('ALTER TABLE stock_reservations DROP CONSTRAINT %I, ADD CONSTRAINT %I CHECK ((%s) OR (%s))',constraint_name,constraint_name,definition,extra);
 END LOOP;
END $custody_owner$;

-- A carried slice must not be merged with a later public/other-receipt allocation.
DROP INDEX uq_stock_reservation_demand_supply;
CREATE UNIQUE INDEX uq_stock_reservation_demand_supply ON stock_reservations(demand_id,supply_id)
WHERE NOT is_deleted AND owner_type='PRODUCTION_MATERIAL_DEMAND' AND status=0
  AND consumed_qty=0 AND released_qty=0 AND source_doc_type IS DISTINCT FROM 'WORKSHOP_RETURN_CUSTODY';
CREATE INDEX idx_workshop_custody_owner ON stock_reservations(owner_id,warehouse_id,id)
WHERE owner_type='WORKSHOP_CUSTODY' AND NOT is_deleted;

CREATE FUNCTION fn_guard_workshop_custody_reservation() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE owned production_material_demands%ROWTYPE; physical NUMERIC; other_held NUMERIC;
 new_open NUMERIC;old_open NUMERIC:=0;
BEGIN
 IF TG_OP='UPDATE' AND OLD.source_doc_type='WORKSHOP_RETURN_CUSTODY' AND
   (NEW.source_doc_type IS DISTINCT FROM OLD.source_doc_type OR NEW.source_doc_id IS DISTINCT FROM OLD.source_doc_id
    OR NEW.qty IS DISTINCT FROM OLD.qty) THEN
  RAISE EXCEPTION 'Carried material identity and original quantity cannot become another allocation' USING ERRCODE='23514';
 END IF;
 IF TG_OP='UPDATE' AND OLD.owner_type='WORKSHOP_CUSTODY' AND
   (NEW.owner_type IS DISTINCT FROM OLD.owner_type OR NEW.owner_id IS DISTINCT FROM OLD.owner_id
    OR NEW.goods_id IS DISTINCT FROM OLD.goods_id OR NEW.color_id IS DISTINCT FROM OLD.color_id
    OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id OR NEW.supply_id IS DISTINCT FROM OLD.supply_id
    OR NEW.source_doc_type IS DISTINCT FROM OLD.source_doc_type OR NEW.source_doc_id IS DISTINCT FROM OLD.source_doc_id) THEN
  RAISE EXCEPTION 'Workshop custody reservation identity is immutable' USING ERRCODE='23514';
 END IF;
 IF NEW.owner_type IS DISTINCT FROM 'WORKSHOP_CUSTODY' THEN RETURN NEW; END IF;
 SELECT * INTO owned FROM production_material_demands WHERE id=NEW.owner_id;
 IF NOT FOUND OR owned.goods_id<>NEW.goods_id OR owned.color_id IS DISTINCT FROM NEW.color_id
   OR NEW.source_doc_type IS DISTINCT FROM 'WORKSHOP_RETURN_CUSTODY' OR NEW.consumed_qty<>0
   OR NOT EXISTS(SELECT 1 FROM production_material_return_receiving_confirmations received
      WHERE received.stock_document_id=NEW.source_doc_id AND received.received_warehouse_id=NEW.warehouse_id) THEN
  RAISE EXCEPTION 'Workshop custody requires the exact original task and confirmed physical warehouse' USING ERRCODE='23514';
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(NEW.goods_id::text||':'||COALESCE(NEW.color_id::text,'00000000-0000-0000-0000-000000000000'),6148615593807138892));
 SELECT qty INTO physical FROM stock_balances WHERE id=NEW.supply_id AND warehouse_id=NEW.warehouse_id
   AND goods_id=NEW.goods_id AND color_id IS NOT DISTINCT FROM NEW.color_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Custody requires its actual physical stock balance' USING ERRCODE='23514'; END IF;
 new_open:=CASE WHEN NEW.is_deleted OR NEW.status<>0 THEN 0 ELSE NEW.qty-NEW.released_qty END;
 IF TG_OP='UPDATE' THEN old_open:=CASE WHEN OLD.is_deleted OR OLD.status<>0 THEN 0 ELSE OLD.qty-OLD.released_qty END; END IF;
 IF new_open>old_open THEN
  SELECT COALESCE(SUM(qty-consumed_qty-released_qty),0) INTO other_held FROM stock_reservations
   WHERE id<>NEW.id AND warehouse_id=NEW.warehouse_id AND goods_id=NEW.goods_id
     AND color_id IS NOT DISTINCT FROM NEW.color_id AND status=0 AND NOT is_deleted;
  IF new_open+other_held>physical THEN RAISE EXCEPTION 'Workshop custody cannot borrow another owner physical stock' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_workshop_custody_reservation BEFORE INSERT OR UPDATE ON stock_reservations
FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_custody_reservation();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_guard_workshop_custody_reservation;

CREATE FUNCTION fn_create_workshop_return_reservation(p_source UUID,p_warehouse UUID,p_demand UUID,
 p_qty NUMERIC,p_target UUID,p_request_item UUID,p_actor UUID,p_formal BOOLEAN DEFAULT FALSE)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE demand production_material_demands%ROWTYPE; original stock_reservations%ROWTYPE;
 request_id UUID; balance_id UUID; formal BOOLEAN:=p_formal;
BEGIN
 IF p_actor::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'') OR p_qty<=0 OR p_target IS NULL THEN
  RAISE EXCEPTION 'A material custody reservation requires its current actor and positive exact quantity' USING ERRCODE='23514';
 END IF;
 SELECT * INTO STRICT demand FROM production_material_demands WHERE id=p_demand AND NOT is_deleted FOR UPDATE;
 SELECT item.request_id INTO request_id FROM production_material_return_request_items item
 JOIN production_material_return_receiving_confirmations received ON received.stock_document_id=item.request_id
  AND received.received_warehouse_id=p_warehouse
 WHERE item.id=p_request_item;
 IF request_id IS NULL OR NOT EXISTS(SELECT 1 FROM warehouses WHERE id=p_warehouse AND NOT is_line_side
   AND NOT is_defective AND is_accountable AND NOT is_deleted AND fn_warehouse_is_operational_leaf(id)) THEN
  RAISE EXCEPTION 'Custody must retain its confirmed ordinary receiving warehouse' USING ERRCODE='23514';
 END IF;
 IF p_source IS NOT NULL THEN
  SELECT * INTO STRICT original FROM stock_reservations WHERE id=p_source;
  IF original.goods_id<>demand.goods_id OR original.color_id IS DISTINCT FROM demand.color_id
    OR (original.owner_type='PRODUCTION_MATERIAL_DEMAND' AND original.demand_id IS DISTINCT FROM demand.id)
    OR (original.owner_type='WORKSHOP_CUSTODY' AND original.owner_id IS DISTINCT FROM demand.id)
    OR original.owner_type NOT IN('PRODUCTION_MATERIAL_DEMAND','WORKSHOP_CUSTODY') THEN
   RAISE EXCEPTION 'Custody cannot change the original material demand owner' USING ERRCODE='23514';
  END IF;
  formal:=formal OR original.owner_type='PRODUCTION_MATERIAL_DEMAND';
 END IF;
 IF formal AND NOT EXISTS(SELECT 1 FROM production_execution_segments WHERE id=demand.execution_segment_id
   AND start_route IS NOT NULL AND status IN('WAITING','READY','DISPATCHED','IN_PROGRESS') AND NOT is_deleted) THEN
  RAISE EXCEPTION 'Only a confirmed workshop route may hold a formal returned-material allocation' USING ERRCODE='23514';
 END IF;
 SELECT id INTO balance_id FROM stock_balances WHERE warehouse_id=p_warehouse AND goods_id=demand.goods_id
  AND color_id IS NOT DISTINCT FROM demand.color_id FOR UPDATE;
 IF balance_id IS NULL THEN RAISE EXCEPTION 'The actual returned stock must exist before its reservation' USING ERRCODE='23514'; END IF;
 INSERT INTO stock_reservations(id,order_item_id,goods_id,color_id,warehouse_id,qty,consumed_qty,released_qty,status,source,
   source_doc_type,source_doc_id,owner_type,owner_id,purpose,demand_id,supply_type,supply_id,idempotency_key,
   created_at,updated_at,created_by,updated_by,is_deleted,lock_version)
 VALUES(p_target,NULL,demand.goods_id,demand.color_id,p_warehouse,p_qty,0,0,0,2,
   'WORKSHOP_RETURN_CUSTODY',request_id,CASE WHEN formal THEN 'PRODUCTION_MATERIAL_DEMAND' ELSE 'WORKSHOP_CUSTODY' END,
   demand.id,CASE WHEN formal THEN 'PRODUCTION_MATERIAL' ELSE 'WORKSHOP_CUSTODY' END,CASE WHEN formal THEN demand.id ELSE NULL END,
   'STOCK_BALANCE',balance_id,'WORKSHOP_RETURN:'||p_target,now(),now(),p_actor,p_actor,FALSE,0);
 RETURN p_target;
END $$;


-- BEGIN SOURCE CUSTODY
-- V619 source section. Install after the owner/create-reservation prelude and V618.
-- Forward: material GOOD_RETURN posting (issued only), prepare, physical receipt,
-- finish. Reverse: prepare (issued C+/R- atomically), physical counters, finish,
-- exact GOOD_RETURN_REVERSE posting (issued only). All stages commit together.
CREATE TABLE production_workshop_material_return_slices (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 request_item_id UUID NOT NULL REFERENCES production_material_return_request_items(id),
 transfer_item_id UUID NOT NULL REFERENCES production_workshop_direct_transfer_items(id),
 source_allocation_id UUID REFERENCES production_workshop_direct_source_allocations(id),
 qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
 created_by UUID NOT NULL REFERENCES users(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE NULLS NOT DISTINCT(request_item_id,source_allocation_id)
);
CREATE INDEX idx_workshop_return_slice_source ON production_workshop_material_return_slices(transfer_item_id,request_item_id);
CREATE INDEX idx_workshop_return_slice_allocation ON production_workshop_material_return_slices(source_allocation_id,request_item_id)
 WHERE source_allocation_id IS NOT NULL;

CREATE TABLE production_workshop_material_custody_preparations (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 request_item_id UUID NOT NULL REFERENCES production_material_return_request_items(id),
 transfer_item_id UUID REFERENCES production_workshop_direct_transfer_items(id),
 material_return_posting_id UUID UNIQUE REFERENCES production_material_stock_postings(id),
 return_source_event_id UUID UNIQUE REFERENCES production_workshop_direct_source_events(id),
 return_slice_id UUID UNIQUE REFERENCES production_workshop_material_return_slices(id),
 source_allocation_id UUID REFERENCES production_workshop_direct_source_allocations(id),
 source_reservation_id UUID REFERENCES stock_reservations(id),
 source_release_event_id UUID UNIQUE REFERENCES production_workshop_direct_source_events(id),
 target_demand_id UUID NOT NULL REFERENCES production_material_demands(id),
 qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
 created_by UUID NOT NULL REFERENCES users(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 CHECK(num_nonnulls(material_return_posting_id,return_source_event_id,return_slice_id)=1),
 CHECK((material_return_posting_id IS NULL)=(transfer_item_id IS NOT NULL)),
 CHECK(material_return_posting_id IS NULL OR source_reservation_id IS NOT NULL),
 CHECK((source_allocation_id IS NULL)=(source_release_event_id IS NULL))
);
CREATE INDEX idx_workshop_custody_prepare_request ON production_workshop_material_custody_preparations(request_item_id);

CREATE FUNCTION fn_workshop_return_slice_pending(p_request_item UUID,p_exclude_document UUID DEFAULT NULL)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM production_material_return_request_items item
 JOIN production_material_return_requests request ON request.id=item.request_id
 JOIN stock_documents document ON document.id=request.id
 WHERE item.id=p_request_item AND document.id IS DISTINCT FROM p_exclude_document
   AND document.status=0 AND NOT document.is_deleted
   AND NOT EXISTS(SELECT 1 FROM production_material_return_request_cancellations cancelled WHERE cancelled.request_id=request.id))
$$;

CREATE FUNCTION fn_workshop_allocation_pending_return_qty(p_allocation UUID,p_exclude_document UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT COALESCE(SUM(qty_base),0) FROM production_workshop_material_return_slices
 WHERE source_allocation_id=p_allocation AND fn_workshop_return_slice_pending(request_item_id,p_exclude_document)
$$;

CREATE FUNCTION fn_workshop_reservation_unissued_available(p_reservation UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT COALESCE((SELECT GREATEST(held.qty-held.consumed_qty-held.released_qty
   -COALESCE((SELECT SUM(fn_workshop_allocation_pending_return_qty(allocation.id,NULL))
      FROM production_workshop_direct_source_allocations allocation WHERE allocation.stock_reservation_id=held.id),0),0)
   FROM stock_reservations held WHERE held.id=p_reservation AND NOT held.is_deleted AND held.status IN(0,1)
     AND held.owner_type='PRODUCTION_MATERIAL_DEMAND'),0)
$$;

CREATE FUNCTION fn_workshop_direct_pending_return_qty(p_source UUID,p_segment UUID,p_exclude_document UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT COALESCE(SUM(slice.qty_base),0) FROM production_workshop_material_return_slices slice
 JOIN production_material_return_request_items item ON item.id=slice.request_item_id
 JOIN production_material_return_requests request ON request.id=item.request_id
 WHERE slice.transfer_item_id=p_source AND request.execution_segment_id=p_segment
   AND fn_workshop_return_slice_pending(slice.request_item_id,p_exclude_document)
$$;

-- The caller must name the receiving task. A source shared by split tasks does
-- not make another task's reserved but unissued slices returnable by this one.
CREATE FUNCTION fn_workshop_direct_returnable_qty(p_source UUID,p_segment UUID,p_exclude_document UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT COALESCE((SELECT GREATEST(lot.available_qty,0)
   +COALESCE((SELECT SUM(GREATEST(allocation.effective_qty-allocation.net_issued_qty
       -fn_workshop_allocation_pending_return_qty(allocation.id,p_exclude_document),0))
      FROM v_workshop_direct_source_allocations allocation
      JOIN stock_reservations held ON held.id=allocation.stock_reservation_id
      JOIN production_material_demands owned ON owned.id=held.demand_id
      WHERE allocation.transfer_item_id=lot.id AND held.warehouse_id=lot.line_side_warehouse_id
        AND NOT held.is_deleted AND owned.execution_segment_id=p_segment),0)
   -- lot.available_qty excludes every pending free slice. Confirmation can
   -- re-read its own frozen slices without making any other request's free lot available.
   +COALESCE((SELECT SUM(slice.qty_base) FROM production_workshop_material_return_slices slice
      JOIN production_material_return_request_items item ON item.id=slice.request_item_id
      WHERE slice.transfer_item_id=lot.id AND slice.source_allocation_id IS NULL
        AND item.request_id=p_exclude_document AND fn_workshop_return_slice_pending(slice.request_item_id,NULL)),0)
 FROM v_workshop_direct_supply_lots lot WHERE lot.id=p_source
   AND EXISTS(SELECT 1 FROM production_material_demands demand
     WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
       AND lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
       AND lot.goods_id=demand.goods_id AND lot.color_id IS NOT DISTINCT FROM demand.color_id)),0)
$$;

CREATE FUNCTION fn_guard_workshop_material_return_slice() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Workshop return source slices are append-only' USING ERRCODE='55000'; END IF;
 PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=NEW.transfer_item_id FOR UPDATE;
 IF NEW.created_by::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')
 OR NOT EXISTS(SELECT 1 FROM production_material_return_request_items item
   JOIN production_material_return_requests request ON request.id=item.request_id
   JOIN v_workshop_direct_supply_lots lot ON lot.id=item.direct_transfer_item_id
   WHERE item.id=NEW.request_item_id AND lot.id=NEW.transfer_item_id
     AND item.created_by=NEW.created_by AND request.warehouse_id=lot.line_side_warehouse_id
     AND fn_workshop_return_slice_pending(item.id,NULL)
     AND (NEW.source_allocation_id IS NULL OR EXISTS(
       SELECT 1 FROM production_workshop_direct_source_allocations allocation
       JOIN stock_reservations held ON held.id=allocation.stock_reservation_id
       JOIN production_material_demands demand ON demand.id=held.demand_id
       WHERE allocation.id=NEW.source_allocation_id AND allocation.transfer_item_id=lot.id
         AND held.warehouse_id=lot.line_side_warehouse_id AND NOT held.is_deleted
         AND demand.execution_segment_id=request.execution_segment_id))) THEN
   RAISE EXCEPTION 'Pending workshop return must retain its exact task and physical source slice' USING ERRCODE='23514';
 END IF;
 IF NEW.source_allocation_id IS NOT NULL AND NEW.qty_base>COALESCE((
   SELECT effective_qty-net_issued_qty-fn_workshop_allocation_pending_return_qty(id,NULL)
   FROM v_workshop_direct_source_allocations WHERE id=NEW.source_allocation_id),0)
 OR NEW.source_allocation_id IS NULL AND NEW.qty_base>COALESCE((
   SELECT available_qty FROM v_workshop_direct_supply_lots WHERE id=NEW.transfer_item_id),0) THEN
   RAISE EXCEPTION 'Pending workshop return exceeds its exact unissued source slice' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;

CREATE FUNCTION fn_prepare_workshop_return_custody(p_request_item UUID,p_return_posting UUID,p_actor UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE requested production_material_return_request_items%ROWTYPE;
        request production_material_return_requests%ROWTYPE;
        receiving production_material_return_receiving_confirmations%ROWTYPE;
        part RECORD; target_demand UUID; released UUID; total NUMERIC:=0;
BEGIN
 SELECT * INTO requested FROM production_material_return_request_items WHERE id=p_request_item;
 SELECT * INTO request FROM production_material_return_requests WHERE id=requested.request_id;
 SELECT * INTO receiving FROM production_material_return_receiving_confirmations WHERE stock_document_id=request.id;
 IF receiving.id IS NULL THEN RAISE EXCEPTION 'Custody preparation requires warehouse receiving confirmation' USING ERRCODE='23514'; END IF;
 IF receiving.source_warehouse_id=receiving.received_warehouse_id THEN RETURN; END IF;
 IF p_actor::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'') OR receiving.created_by<>p_actor
    OR (requested.issue_posting_id IS NULL)<>(p_return_posting IS NULL)
    OR NOT EXISTS(SELECT 1 FROM production_material_return_receiving_confirmations confirmation
      WHERE confirmation.id=receiving.id AND confirmation.xmin::text=pg_current_xact_id()::text) THEN
   RAISE EXCEPTION 'Custody movement requires its exact typed warehouse confirmation' USING ERRCODE='23514';
 END IF;
 -- The material ledger appends the true GOOD_RETURN first. This command moves
 -- C down and R up together: material returns to another warehouse, never to a
 -- fictitious free-stock position at the original technical warehouse.
 FOR part IN
   SELECT event.id AS return_event,NULL::uuid AS slice_id,NULL::uuid AS plain_return_posting,event.source_allocation_id,
     allocation.transfer_item_id,allocation.stock_reservation_id AS source_r,event.qty_base
   FROM production_workshop_direct_source_events event
   JOIN production_workshop_direct_source_allocations allocation ON allocation.id=event.source_allocation_id
   JOIN production_material_stock_postings posting ON posting.id=event.stock_posting_id
   WHERE p_return_posting IS NOT NULL AND posting.id=p_return_posting AND posting.posting_type='GOOD_RETURN'
     AND posting.stock_document_item_id=requested.stock_document_item_id
     AND posting.source_posting_id=requested.issue_posting_id AND event.event_type='GOOD_RETURN'
   UNION ALL
   SELECT NULL,slice.id,NULL,slice.source_allocation_id,slice.transfer_item_id,allocation.stock_reservation_id,slice.qty_base
   FROM production_workshop_material_return_slices slice
   LEFT JOIN production_workshop_direct_source_allocations allocation ON allocation.id=slice.source_allocation_id
   WHERE p_return_posting IS NULL AND slice.request_item_id=requested.id
   UNION ALL
   SELECT NULL,NULL,posting.id,NULL,NULL,posting.reservation_id,posting.qty_base
   FROM production_material_stock_postings posting
   WHERE posting.id=p_return_posting AND posting.posting_type='GOOD_RETURN'
     AND posting.stock_document_item_id=requested.stock_document_item_id AND posting.source_posting_id=requested.issue_posting_id
     AND NOT EXISTS(SELECT 1 FROM production_workshop_direct_source_events event WHERE event.stock_posting_id=posting.id)
   ORDER BY transfer_item_id,source_r,source_allocation_id
 LOOP
   IF EXISTS(SELECT 1 FROM production_workshop_material_custody_preparations existing
     WHERE existing.return_source_event_id=part.return_event OR existing.return_slice_id=part.slice_id
       OR existing.material_return_posting_id=part.plain_return_posting) THEN
     RAISE EXCEPTION 'Custody slice was already received; replay the original document command' USING ERRCODE='23514';
   END IF;
   IF part.source_r IS NOT NULL THEN PERFORM 1 FROM stock_reservations WHERE id=part.source_r FOR UPDATE; END IF;
   PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=part.transfer_item_id FOR UPDATE;
   IF part.source_r IS NOT NULL THEN
     SELECT demand_id INTO STRICT target_demand FROM stock_reservations WHERE id=part.source_r;
   ELSE
     SELECT demand.id INTO STRICT target_demand FROM production_material_demands demand
     JOIN v_workshop_direct_supply_lots lot ON lot.id=part.transfer_item_id
     WHERE demand.execution_segment_id=request.execution_segment_id AND NOT demand.is_deleted
       AND lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
       AND lot.goods_id=demand.goods_id AND lot.color_id IS NOT DISTINCT FROM demand.color_id;
   END IF;
   released:=NULL;
   IF part.source_r IS NOT NULL THEN
    IF part.source_allocation_id IS NOT NULL THEN
     IF NOT EXISTS(SELECT 1 FROM v_workshop_direct_source_allocations allocation
       WHERE allocation.id=part.source_allocation_id AND allocation.effective_qty-allocation.net_issued_qty>=part.qty_base) THEN
       RAISE EXCEPTION 'Returned custody cannot release material already consumed by another posting' USING ERRCODE='23514';
     END IF;
     released:=gen_random_uuid();
     INSERT INTO production_workshop_direct_source_events(id,source_allocation_id,event_type,qty_base,created_by)
     VALUES(released,part.source_allocation_id,'RELEASE',part.qty_base,p_actor);
    END IF;
     UPDATE stock_reservations SET consumed_qty=consumed_qty-CASE WHEN p_return_posting IS NOT NULL THEN part.qty_base ELSE 0 END,
       released_qty=released_qty+part.qty_base,
       status=CASE WHEN consumed_qty+released_qty+CASE WHEN p_return_posting IS NULL THEN part.qty_base ELSE 0 END=qty THEN 1 ELSE 0 END,
       lock_version=lock_version+1,updated_at=now(),updated_by=p_actor
     WHERE id=part.source_r AND NOT is_deleted AND
       (p_return_posting IS NOT NULL AND consumed_qty>=part.qty_base
         OR p_return_posting IS NULL AND qty-consumed_qty-released_qty>=part.qty_base);
     IF NOT FOUND THEN RAISE EXCEPTION 'Original custody reservation changed before transfer' USING ERRCODE='23514'; END IF;
   ELSE
     PERFORM fn_prepare_workshop_preplan_return(requested.id,part.transfer_item_id,part.qty_base,p_actor);
   END IF;
   INSERT INTO production_workshop_material_custody_preparations(request_item_id,transfer_item_id,material_return_posting_id,return_source_event_id,
     return_slice_id,source_allocation_id,source_reservation_id,source_release_event_id,target_demand_id,qty_base,created_by)
   VALUES(requested.id,part.transfer_item_id,part.plain_return_posting,part.return_event,part.slice_id,part.source_allocation_id,part.source_r,released,
     target_demand,part.qty_base,p_actor);
   total:=total+part.qty_base;
 END LOOP;
 IF p_return_posting IS NULL AND total<>requested.qty_base THEN
   RAISE EXCEPTION 'Every unissued return requires its complete frozen custody slices' USING ERRCODE='23514';
 END IF;
 IF p_return_posting IS NOT NULL AND total<>COALESCE((SELECT posting.qty_base FROM production_material_stock_postings posting WHERE id=p_return_posting),0) THEN
   RAISE EXCEPTION 'Every workshop good return requires complete original source custody slices' USING ERRCODE='23514';
 END IF;
END $$;
CREATE TRIGGER trg_guard_workshop_material_return_slice BEFORE INSERT OR UPDATE OR DELETE ON production_workshop_material_return_slices
FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_return_slice();
ALTER TABLE production_workshop_material_return_slices ENABLE ALWAYS TRIGGER trg_guard_workshop_material_return_slice;

CREATE FUNCTION fn_freeze_workshop_direct_return_slices() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE request production_material_return_requests%ROWTYPE; part RECORD; remaining NUMERIC; take NUMERIC;
BEGIN
 IF NEW.direct_transfer_item_id IS NULL THEN RETURN NULL; END IF;
 SELECT * INTO request FROM production_material_return_requests WHERE id=NEW.request_id;
 PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=NEW.direct_transfer_item_id FOR UPDATE;
 remaining:=NEW.qty_base;
 IF remaining>fn_workshop_direct_returnable_qty(NEW.direct_transfer_item_id,request.execution_segment_id,NULL) THEN
   RAISE EXCEPTION 'Workshop direct return exceeds this task''s unissued physical source' USING ERRCODE='23514';
 END IF;
 FOR part IN SELECT allocation.id,allocation.effective_qty-allocation.net_issued_qty
       -fn_workshop_allocation_pending_return_qty(allocation.id,NULL) AS free_qty
   FROM v_workshop_direct_source_allocations allocation
   JOIN stock_reservations held ON held.id=allocation.stock_reservation_id
   JOIN production_material_demands demand ON demand.id=held.demand_id
   WHERE allocation.transfer_item_id=NEW.direct_transfer_item_id AND held.warehouse_id=request.warehouse_id
     AND NOT held.is_deleted AND demand.execution_segment_id=request.execution_segment_id
   ORDER BY allocation.allocation_no LOOP
   take:=LEAST(remaining,GREATEST(part.free_qty,0));
   IF take<=0 THEN CONTINUE; END IF;
   INSERT INTO production_workshop_material_return_slices(request_item_id,transfer_item_id,source_allocation_id,qty_base,created_by)
   VALUES(NEW.id,NEW.direct_transfer_item_id,part.id,take,NEW.created_by);
   remaining:=remaining-take;EXIT WHEN remaining=0;
 END LOOP;
 IF remaining>0 THEN
   IF remaining>COALESCE((SELECT available_qty FROM v_workshop_direct_supply_lots WHERE id=NEW.direct_transfer_item_id),0) THEN
     RAISE EXCEPTION 'Workshop free source changed while freezing its return' USING ERRCODE='23514';
   END IF;
   INSERT INTO production_workshop_material_return_slices(request_item_id,transfer_item_id,qty_base,created_by)
   VALUES(NEW.id,NEW.direct_transfer_item_id,remaining,NEW.created_by);
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER trg_freeze_workshop_direct_return_slices AFTER INSERT ON production_material_return_request_items
FOR EACH ROW EXECUTE FUNCTION fn_freeze_workshop_direct_return_slices();
ALTER TABLE production_material_return_request_items ENABLE ALWAYS TRIGGER trg_freeze_workshop_direct_return_slices;

CREATE TRIGGER trg_audit_production_workshop_material_return_slices AFTER INSERT OR UPDATE OR DELETE ON production_workshop_material_return_slices
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_material_return_slices ENABLE ALWAYS TRIGGER trg_audit_production_workshop_material_return_slices;

-- One MOVE describes an exact physical slice; it never changes the original
-- source allocation, ISSUE, return posting or original received quantity.
CREATE TABLE production_workshop_material_custody_moves (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 preparation_id UUID NOT NULL UNIQUE REFERENCES production_workshop_material_custody_preparations(id),
 request_item_id UUID NOT NULL REFERENCES production_material_return_request_items(id),
 transfer_item_id UUID REFERENCES production_workshop_direct_transfer_items(id),
 material_return_posting_id UUID UNIQUE REFERENCES production_material_stock_postings(id),
 return_source_event_id UUID UNIQUE REFERENCES production_workshop_direct_source_events(id),
 return_slice_id UUID UNIQUE REFERENCES production_workshop_material_return_slices(id),
 source_allocation_id UUID REFERENCES production_workshop_direct_source_allocations(id),
 source_reservation_id UUID REFERENCES stock_reservations(id),
 source_release_event_id UUID UNIQUE REFERENCES production_workshop_direct_source_events(id),
 target_demand_id UUID NOT NULL REFERENCES production_material_demands(id),
 target_reservation_id UUID NOT NULL REFERENCES stock_reservations(id),
 target_allocation_id UUID UNIQUE REFERENCES production_workshop_direct_source_allocations(id) DEFERRABLE INITIALLY DEFERRED,
 received_movement_id UUID NOT NULL REFERENCES stock_movements(id),
 source_out_movement_id UUID REFERENCES stock_movements(id),
 qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
 created_by UUID NOT NULL REFERENCES users(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 CHECK(num_nonnulls(material_return_posting_id,return_source_event_id,return_slice_id)=1),
 CHECK((material_return_posting_id IS NULL)=(transfer_item_id IS NOT NULL)),
 CHECK((material_return_posting_id IS NULL)=(target_allocation_id IS NOT NULL)),
 CHECK(material_return_posting_id IS NULL OR source_reservation_id IS NOT NULL),
 CHECK((source_allocation_id IS NULL)=(source_release_event_id IS NULL)),
 CHECK((return_slice_id IS NOT NULL)=(source_out_movement_id IS NOT NULL))
);
CREATE INDEX idx_workshop_custody_move_source ON production_workshop_material_custody_moves(transfer_item_id,request_item_id);
CREATE INDEX idx_workshop_custody_move_target ON production_workshop_material_custody_moves(target_reservation_id);
CREATE INDEX idx_workshop_custody_move_original_reservation ON production_workshop_material_custody_moves(source_reservation_id)
 WHERE source_reservation_id IS NOT NULL;
CREATE INDEX idx_workshop_custody_move_request ON production_workshop_material_custody_moves(request_item_id);
CREATE INDEX idx_workshop_custody_move_technical_movement ON production_workshop_material_custody_moves(source_out_movement_id)
 WHERE source_out_movement_id IS NOT NULL;

CREATE FUNCTION fn_move_workshop_return_custody(p_request_item UUID,p_return_posting UUID,
 p_received_movement UUID,p_source_out_movement UUID,p_actor UUID)
RETURNS TABLE(target_reservation_id UUID,qty_base NUMERIC) LANGUAGE plpgsql AS $$
DECLARE receiving production_material_return_receiving_confirmations%ROWTYPE;
 prepared RECORD; source_r UUID; target_r UUID; target_a UUID; total NUMERIC:=0;
BEGIN
 SELECT confirmation.* INTO receiving FROM production_material_return_receiving_confirmations confirmation
 JOIN production_material_return_request_items item ON item.request_id=confirmation.stock_document_id WHERE item.id=p_request_item;
 IF receiving.id IS NULL OR receiving.source_warehouse_id=receiving.received_warehouse_id THEN RETURN; END IF;
 IF receiving.created_by<>p_actor OR p_actor::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'') THEN
   RAISE EXCEPTION 'Source custody belongs to the exact receiving command actor' USING ERRCODE='23514';
 END IF;
 FOR prepared IN SELECT preparation.* FROM production_workshop_material_custody_preparations preparation
   LEFT JOIN production_workshop_direct_source_events returned ON returned.id=preparation.return_source_event_id
   WHERE preparation.request_item_id=p_request_item
     AND ((p_return_posting IS NULL AND preparation.return_slice_id IS NOT NULL) OR returned.stock_posting_id=p_return_posting
       OR preparation.material_return_posting_id=p_return_posting)
   ORDER BY preparation.transfer_item_id,preparation.id LOOP
   source_r:=prepared.source_reservation_id;
   target_r:=gen_random_uuid();target_a:=CASE WHEN prepared.transfer_item_id IS NULL THEN NULL ELSE gen_random_uuid() END;
   PERFORM fn_create_workshop_return_reservation(source_r,receiving.received_warehouse_id,prepared.target_demand_id,
     prepared.qty_base,target_r,p_request_item,p_actor,FALSE);
   INSERT INTO production_workshop_material_custody_moves(preparation_id,request_item_id,transfer_item_id,material_return_posting_id,return_source_event_id,
     return_slice_id,source_allocation_id,source_reservation_id,source_release_event_id,target_demand_id,target_reservation_id,target_allocation_id,
     received_movement_id,source_out_movement_id,qty_base,created_by)
   VALUES(prepared.id,p_request_item,prepared.transfer_item_id,prepared.material_return_posting_id,prepared.return_source_event_id,prepared.return_slice_id,
     prepared.source_allocation_id,source_r,prepared.source_release_event_id,prepared.target_demand_id,target_r,target_a,
     p_received_movement,p_source_out_movement,prepared.qty_base,p_actor);
   IF target_a IS NOT NULL THEN
     INSERT INTO production_workshop_direct_source_allocations(id,transfer_item_id,stock_reservation_id,qty_base,released_baseline,command_key,created_by)
     VALUES(target_a,prepared.transfer_item_id,target_r,prepared.qty_base,0,'RETURN-CUSTODY:'||prepared.id,p_actor);
   END IF;
   target_reservation_id:=target_r;qty_base:=prepared.qty_base;RETURN NEXT;total:=total+prepared.qty_base;
 END LOOP;
 IF p_return_posting IS NULL AND total<>COALESCE((SELECT item.qty_base FROM production_material_return_request_items item WHERE item.id=p_request_item),0) THEN
   RAISE EXCEPTION 'Physical receipt is missing its complete prepared source custody' USING ERRCODE='23514';
 END IF;
END $$;

CREATE TABLE production_workshop_custody_reverse_preparations (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 move_id UUID NOT NULL UNIQUE REFERENCES production_workshop_material_custody_moves(id),
 original_restore_event_id UUID UNIQUE REFERENCES production_workshop_direct_source_events(id),
 target_release_event_id UUID UNIQUE REFERENCES production_workshop_direct_source_events(id),
 reverse_material_event_id UUID REFERENCES production_material_stock_events(id),
 created_by UUID NOT NULL REFERENCES users(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE production_workshop_material_custody_reversals (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 preparation_id UUID NOT NULL UNIQUE REFERENCES production_workshop_custody_reverse_preparations(id),
 move_id UUID NOT NULL UNIQUE REFERENCES production_workshop_material_custody_moves(id),
 original_restore_event_id UUID UNIQUE REFERENCES production_workshop_direct_source_events(id),
 target_release_event_id UUID UNIQUE REFERENCES production_workshop_direct_source_events(id),
 received_reverse_movement_id UUID NOT NULL REFERENCES stock_movements(id),
 source_reverse_movement_id UUID REFERENCES stock_movements(id),
 reverse_material_event_id UUID REFERENCES production_material_stock_events(id),
 created_by UUID NOT NULL REFERENCES users(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_workshop_custody_reverse_technical_movement ON production_workshop_material_custody_reversals(source_reverse_movement_id)
 WHERE source_reverse_movement_id IS NOT NULL;

-- A private custody reservation may be formalized after route confirmation.
-- Its origin is still the moved source, never a second MAKE receipt conversion.
CREATE TABLE production_workshop_material_custody_handoffs (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 source_allocation_id UUID NOT NULL REFERENCES production_workshop_direct_source_allocations(id),
 target_allocation_id UUID NOT NULL UNIQUE REFERENCES production_workshop_direct_source_allocations(id) DEFERRABLE INITIALLY DEFERRED,
 source_release_event_id UUID NOT NULL UNIQUE REFERENCES production_workshop_direct_source_events(id),
 target_reservation_id UUID NOT NULL REFERENCES stock_reservations(id),
 qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
 command_key VARCHAR(128) NOT NULL,
 created_by UUID NOT NULL REFERENCES users(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(source_allocation_id,command_key)
);
CREATE INDEX idx_workshop_custody_handoff_source ON production_workshop_material_custody_handoffs(source_allocation_id);

CREATE TABLE production_workshop_custody_handoff_reversals (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 handoff_id UUID NOT NULL UNIQUE REFERENCES production_workshop_material_custody_handoffs(id),
 source_restore_event_id UUID NOT NULL UNIQUE REFERENCES production_workshop_direct_source_events(id),
 target_release_event_id UUID UNIQUE REFERENCES production_workshop_direct_source_events(id),
 created_by UUID NOT NULL REFERENCES users(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE FUNCTION fn_assert_workshop_custody_grants(p_reservation UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE source RECORD;
BEGIN
 IF EXISTS(SELECT 1 FROM stock_reservations held WHERE held.id=p_reservation AND held.released_qty<(
   SELECT COALESCE(SUM(move.qty_base),0) FROM production_workshop_material_custody_moves move
   WHERE move.source_reservation_id=held.id AND NOT EXISTS(
     SELECT 1 FROM production_workshop_material_custody_reversals reversed WHERE reversed.move_id=move.id))) THEN
   RAISE EXCEPTION 'An active warehouse custody transfer must retain its original reservation release' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM stock_reservations held
   JOIN production_workshop_material_custody_moves move ON move.target_reservation_id=held.id
   JOIN production_workshop_material_custody_reversals reversed ON reversed.move_id=move.id
   WHERE held.id=p_reservation AND (held.consumed_qty<>0 OR NOT held.is_deleted AND held.qty<>held.released_qty)) THEN
   RAISE EXCEPTION 'Reversed warehouse custody cannot restore destination reservation rights' USING ERRCODE='23514';
 END IF;
 FOR source IN SELECT DISTINCT transfer_item_id FROM production_workshop_direct_source_allocations WHERE stock_reservation_id=p_reservation LOOP
   PERFORM fn_assert_workshop_source_physical_custody(source.transfer_item_id);
 END LOOP;
 IF EXISTS(SELECT 1 FROM v_workshop_direct_source_allocations allocation
   WHERE allocation.stock_reservation_id=p_reservation AND allocation.effective_qty>
     allocation.qty_base
       -COALESCE((SELECT SUM(move.qty_base) FROM production_workshop_material_custody_moves move
          WHERE move.source_allocation_id=allocation.id AND NOT EXISTS(
            SELECT 1 FROM production_workshop_material_custody_reversals reversed WHERE reversed.move_id=move.id)),0)
       -COALESCE((SELECT SUM(handoff.qty_base) FROM production_workshop_material_custody_handoffs handoff
          WHERE handoff.source_allocation_id=allocation.id AND NOT EXISTS(
            SELECT 1 FROM production_workshop_custody_handoff_reversals reversed WHERE reversed.handoff_id=handoff.id)),0)) THEN
   RAISE EXCEPTION 'Moved or formalized source custody cannot be restored while its successor remains effective' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM v_workshop_direct_source_allocations allocation
   JOIN production_workshop_material_custody_moves move ON move.target_allocation_id=allocation.id
   JOIN production_workshop_material_custody_reversals reversed ON reversed.move_id=move.id
   WHERE allocation.stock_reservation_id=p_reservation AND allocation.effective_qty<>0)
 OR EXISTS(SELECT 1 FROM v_workshop_direct_source_allocations allocation
   JOIN production_workshop_material_custody_handoffs handoff ON handoff.target_allocation_id=allocation.id
   JOIN production_workshop_custody_handoff_reversals reversed ON reversed.handoff_id=handoff.id
   WHERE allocation.stock_reservation_id=p_reservation AND allocation.effective_qty<>0) THEN
   RAISE EXCEPTION 'Reversed source custody cannot acquire new holdings' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM stock_reservations held WHERE held.id=p_reservation
     AND held.owner_type='WORKSHOP_CUSTODY' AND held.consumed_qty<>0) THEN
   RAISE EXCEPTION 'Private workshop custody must be formally assigned before issue' USING ERRCODE='23514';
 END IF;
END $$;

CREATE FUNCTION fn_formalize_workshop_return_custody(p_source_reservation UUID,p_qty NUMERIC,p_command VARCHAR,p_actor UUID)
RETURNS TABLE(target_reservation_id UUID,qty_base NUMERIC) LANGUAGE plpgsql AS $$
DECLARE held stock_reservations%ROWTYPE; origin production_workshop_material_custody_moves%ROWTYPE;
        part RECORD; remaining NUMERIC:=p_qty; take NUMERIC; released UUID; target_r UUID; target_a UUID;
BEGIN
 SELECT * INTO held FROM stock_reservations WHERE id=p_source_reservation FOR UPDATE;
 IF NOT FOUND OR held.owner_type<>'WORKSHOP_CUSTODY' OR held.is_deleted OR held.consumed_qty<>0
   OR p_qty<=0 OR p_command IS NULL OR length(p_command)>128 OR p_actor::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')
   OR NOT EXISTS(SELECT 1 FROM production_material_demands demand JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
     WHERE demand.id=held.owner_id AND NOT demand.is_deleted AND NOT segment.is_deleted
       AND segment.start_route IN('FULL_KIT','CONTINUOUS') AND segment.status IN('WAITING','READY','DISPATCHED','IN_PROGRESS')) THEN
   RAISE EXCEPTION 'Custody can only be formalized for its original task after route confirmation' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM production_workshop_material_custody_handoffs handoff JOIN production_workshop_direct_source_allocations source ON source.id=handoff.source_allocation_id
   WHERE source.stock_reservation_id=held.id AND handoff.command_key=p_command) THEN
   IF p_qty IS DISTINCT FROM (SELECT SUM(handoff.qty_base) FROM production_workshop_material_custody_handoffs handoff
     JOIN production_workshop_direct_source_allocations source ON source.id=handoff.source_allocation_id
     WHERE source.stock_reservation_id=held.id AND handoff.command_key=p_command) THEN
     RAISE EXCEPTION 'Custody formalization command cannot be replayed with another quantity' USING ERRCODE='23514';
   END IF;
   RETURN QUERY SELECT handoff.target_reservation_id,handoff.qty_base FROM production_workshop_material_custody_handoffs handoff
     JOIN production_workshop_direct_source_allocations source ON source.id=handoff.source_allocation_id
     WHERE source.stock_reservation_id=held.id AND handoff.command_key=p_command;
   RETURN;
 END IF;
 PERFORM fn_lock_workshop_source_rows(held.id);
 FOR part IN SELECT * FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=held.id ORDER BY allocation_no LOOP
   take:=LEAST(remaining,GREATEST(part.effective_qty-part.net_issued_qty,0));IF take<=0 THEN CONTINUE; END IF;
   SELECT * INTO STRICT origin FROM production_workshop_material_custody_moves WHERE target_allocation_id=part.id;
   IF EXISTS(SELECT 1 FROM production_workshop_material_custody_reversals WHERE move_id=origin.id) THEN
     RAISE EXCEPTION 'Reversed physical custody cannot be formalized' USING ERRCODE='23514';
   END IF;
   released:=gen_random_uuid();target_r:=gen_random_uuid();target_a:=gen_random_uuid();
   INSERT INTO production_workshop_direct_source_events(id,source_allocation_id,event_type,qty_base,created_by)
   VALUES(released,part.id,'RELEASE',take,p_actor);
   UPDATE stock_reservations SET released_qty=released_qty+take,
     status=CASE WHEN released_qty+take=qty THEN 1 ELSE 0 END,lock_version=lock_version+1,updated_at=now(),updated_by=p_actor
   WHERE id=held.id AND qty-consumed_qty-released_qty>=take;
   IF NOT FOUND THEN RAISE EXCEPTION 'Custody balance changed during formalization' USING ERRCODE='23514'; END IF;
   PERFORM fn_create_workshop_return_reservation(held.id,held.warehouse_id,held.owner_id,take,target_r,origin.request_item_id,p_actor,TRUE);
   INSERT INTO production_workshop_material_custody_handoffs(source_allocation_id,target_allocation_id,source_release_event_id,target_reservation_id,qty_base,command_key,created_by)
   VALUES(part.id,target_a,released,target_r,take,p_command,p_actor);
   INSERT INTO production_workshop_direct_source_allocations(id,transfer_item_id,stock_reservation_id,qty_base,released_baseline,command_key,created_by)
   VALUES(target_a,part.transfer_item_id,target_r,take,0,'CUSTODY-FORMALIZE:'||p_command||':'||part.id,p_actor);
   target_reservation_id:=target_r;qty_base:=take;RETURN NEXT;remaining:=remaining-take;EXIT WHEN remaining=0;
 END LOOP;
 IF remaining<>0 THEN RAISE EXCEPTION 'Custody formalization exceeds its unissued source balance' USING ERRCODE='23514'; END IF;
END $$;

CREATE FUNCTION fn_reverse_workshop_custody_handoff(p_handoff UUID,p_actor UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE handoff production_workshop_material_custody_handoffs%ROWTYPE; source_r UUID; target_part RECORD; target_release UUID; source_restore UUID;
BEGIN
 SELECT * INTO handoff FROM production_workshop_material_custody_handoffs WHERE id=p_handoff;
 IF NOT FOUND OR EXISTS(SELECT 1 FROM production_workshop_custody_handoff_reversals WHERE handoff_id=p_handoff) THEN
   RAISE EXCEPTION 'Custody formalization was already reversed or is missing' USING ERRCODE='23514';
 END IF;
 SELECT stock_reservation_id INTO source_r FROM production_workshop_direct_source_allocations WHERE id=handoff.source_allocation_id;
 PERFORM 1 FROM stock_reservations WHERE id IN(source_r,handoff.target_reservation_id) ORDER BY id FOR UPDATE;
 PERFORM fn_lock_workshop_source_rows(source_r);
 SELECT * INTO STRICT target_part FROM v_workshop_direct_source_allocations WHERE id=handoff.target_allocation_id;
 IF EXISTS(SELECT 1 FROM production_workshop_material_custody_moves next_move
   WHERE next_move.source_allocation_id=target_part.id AND NOT EXISTS(
     SELECT 1 FROM production_workshop_material_custody_reversals reversed WHERE reversed.move_id=next_move.id)) THEN
   RAISE EXCEPTION 'Reverse the subsequent physical return before its custody assignment' USING ERRCODE='23514';
 END IF;
 IF target_part.net_issued_qty<>0 THEN RAISE EXCEPTION 'Custody has already been issued by its destination task' USING ERRCODE='23514'; END IF;
 target_release:=NULL;
 IF target_part.effective_qty>0 THEN
   target_release:=gen_random_uuid();
   INSERT INTO production_workshop_direct_source_events(id,source_allocation_id,event_type,qty_base,created_by)
   VALUES(target_release,target_part.id,'RELEASE',target_part.effective_qty,p_actor);
   UPDATE stock_reservations SET released_qty=released_qty+target_part.effective_qty,status=1,
     lock_version=lock_version+1,updated_at=now(),updated_by=p_actor WHERE id=handoff.target_reservation_id;
 END IF;
 source_restore:=gen_random_uuid();
 INSERT INTO production_workshop_direct_source_events(id,source_allocation_id,counter_event_id,event_type,qty_base,created_by)
 VALUES(source_restore,handoff.source_allocation_id,handoff.source_release_event_id,'RESTORE',handoff.qty_base,p_actor);
 UPDATE stock_reservations SET released_qty=released_qty-handoff.qty_base,status=0,is_deleted=FALSE,deleted_at=NULL,
   lock_version=lock_version+1,updated_at=now(),updated_by=p_actor WHERE id=source_r AND released_qty>=handoff.qty_base;
 IF NOT FOUND THEN RAISE EXCEPTION 'Original custody release is no longer restorable' USING ERRCODE='23514'; END IF;
 INSERT INTO production_workshop_custody_handoff_reversals(handoff_id,source_restore_event_id,target_release_event_id,created_by)
 VALUES(handoff.id,source_restore,target_release,p_actor);
END $$;

CREATE FUNCTION fn_prepare_reverse_workshop_return_custody(p_request_item UUID,p_reverse_material_event UUID,p_actor UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE move production_workshop_material_custody_moves%ROWTYPE; handoff RECORD;
 target_held stock_reservations%ROWTYPE; target_release UUID; source_restore UUID; open_qty NUMERIC;
BEGIN
 IF p_actor::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'') THEN
   RAISE EXCEPTION 'Custody reversal requires the current actor' USING ERRCODE='23514';
 END IF;
 FOR move IN SELECT * FROM production_workshop_material_custody_moves WHERE request_item_id=p_request_item ORDER BY transfer_item_id,id LOOP
   IF EXISTS(SELECT 1 FROM production_workshop_custody_reverse_preparations WHERE move_id=move.id) THEN
     RAISE EXCEPTION 'Physical custody was already reversed' USING ERRCODE='23514';
   END IF;
   -- Unissued formal successors are unwound as exact source handoffs. Warehouse
   -- code must also reverse their pending DRAW instructions in this transaction.
   FOR handoff IN SELECT formal.id FROM production_workshop_material_custody_handoffs formal
      WHERE formal.source_allocation_id=move.target_allocation_id AND NOT EXISTS(
        SELECT 1 FROM production_workshop_custody_handoff_reversals reversed WHERE reversed.handoff_id=formal.id)
      ORDER BY formal.id LOOP
      PERFORM fn_reverse_workshop_custody_handoff(handoff.id,p_actor);
   END LOOP;
   PERFORM 1 FROM stock_reservations WHERE id IN(move.source_reservation_id,move.target_reservation_id) ORDER BY id FOR UPDATE;
   PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=move.transfer_item_id FOR UPDATE;
   SELECT * INTO STRICT target_held FROM stock_reservations WHERE id=move.target_reservation_id;
   IF EXISTS(SELECT 1 FROM production_workshop_material_custody_moves next_move
     WHERE next_move.source_reservation_id=target_held.id AND NOT EXISTS(
       SELECT 1 FROM production_workshop_material_custody_reversals reversed WHERE reversed.move_id=next_move.id)) THEN
     RAISE EXCEPTION 'Reverse the subsequent physical return before its original receipt' USING ERRCODE='23514';
   END IF;
   IF target_held.consumed_qty<>0 THEN RAISE EXCEPTION 'Returned source has already been consumed by its destination' USING ERRCODE='23514'; END IF;
   target_release:=NULL;source_restore:=NULL;
   open_qty:=CASE WHEN target_held.is_deleted THEN 0 ELSE target_held.qty-target_held.released_qty END;
   IF open_qty>0 THEN
     IF move.target_allocation_id IS NOT NULL THEN
       target_release:=gen_random_uuid();
       INSERT INTO production_workshop_direct_source_events(id,source_allocation_id,event_type,qty_base,created_by)
       VALUES(target_release,move.target_allocation_id,'RELEASE',open_qty,p_actor);
     END IF;
     UPDATE stock_reservations SET released_qty=released_qty+open_qty,status=1,
       lock_version=lock_version+1,updated_at=now(),updated_by=p_actor WHERE id=move.target_reservation_id;
   END IF;
   IF move.return_slice_id IS NULL THEN
     IF p_reverse_material_event IS NULL THEN RAISE EXCEPTION 'Issued custody requires its exact material reverse event' USING ERRCODE='23514'; END IF;
     IF move.source_allocation_id IS NOT NULL THEN
       source_restore:=gen_random_uuid();
       INSERT INTO production_workshop_direct_source_events(id,source_allocation_id,counter_event_id,event_type,qty_base,created_by)
       VALUES(source_restore,move.source_allocation_id,move.source_release_event_id,'RESTORE',move.qty_base,p_actor);
     END IF;
     -- This material is restored to WIP, not to the technical shelf. Keeping
     -- open_qty unchanged avoids inventing a physical technical-stock receipt.
     UPDATE stock_reservations SET consumed_qty=consumed_qty+move.qty_base,released_qty=released_qty-move.qty_base,
       status=CASE WHEN consumed_qty+released_qty=qty THEN 1 ELSE 0 END,is_deleted=FALSE,deleted_at=NULL,
       lock_version=lock_version+1,updated_at=now(),updated_by=p_actor
     WHERE id=move.source_reservation_id AND released_qty>=move.qty_base;
     IF NOT FOUND THEN RAISE EXCEPTION 'Original issued custody cannot be restored to WIP' USING ERRCODE='23514'; END IF;
   ELSIF p_reverse_material_event IS NOT NULL THEN
     RAISE EXCEPTION 'Never-issued custody cannot create a material return reversal' USING ERRCODE='23514';
   END IF;
   INSERT INTO production_workshop_custody_reverse_preparations(move_id,original_restore_event_id,target_release_event_id,reverse_material_event_id,created_by)
   VALUES(move.id,source_restore,target_release,p_reverse_material_event,p_actor);
 END LOOP;
END $$;

CREATE FUNCTION fn_reverse_workshop_return_custody(p_request_item UUID,p_received_reverse UUID,
 p_source_reverse UUID,p_reverse_material_event UUID,p_actor UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE move RECORD; source_restore UUID;
BEGIN
 IF p_actor::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'') THEN
   RAISE EXCEPTION 'Custody reversal requires the current actor' USING ERRCODE='23514';
 END IF;
 FOR move IN SELECT original.*,prepared.id AS reverse_preparation_id,prepared.original_restore_event_id,
     prepared.target_release_event_id,prepared.reverse_material_event_id
   FROM production_workshop_material_custody_moves original
   JOIN production_workshop_custody_reverse_preparations prepared ON prepared.move_id=original.id
   WHERE original.request_item_id=p_request_item ORDER BY original.transfer_item_id,original.id LOOP
   IF move.reverse_material_event_id IS DISTINCT FROM p_reverse_material_event THEN
     RAISE EXCEPTION 'Custody reverse command cannot change its material event' USING ERRCODE='23514';
   END IF;
   source_restore:=move.original_restore_event_id;
   IF move.return_slice_id IS NOT NULL AND move.source_reservation_id IS NOT NULL THEN
     source_restore:=gen_random_uuid();
     INSERT INTO production_workshop_direct_source_events(id,source_allocation_id,counter_event_id,event_type,qty_base,created_by)
     VALUES(source_restore,move.source_allocation_id,move.source_release_event_id,'RESTORE',move.qty_base,p_actor);
     UPDATE stock_reservations SET released_qty=released_qty-move.qty_base,status=0,is_deleted=FALSE,deleted_at=NULL,
       lock_version=lock_version+1,updated_at=now(),updated_by=p_actor WHERE id=move.source_reservation_id AND released_qty>=move.qty_base;
     IF NOT FOUND THEN RAISE EXCEPTION 'Original unissued source cannot be restored after physical receipt' USING ERRCODE='23514'; END IF;
   END IF;
   INSERT INTO production_workshop_material_custody_reversals(preparation_id,move_id,original_restore_event_id,target_release_event_id,
     received_reverse_movement_id,source_reverse_movement_id,reverse_material_event_id,created_by)
   VALUES(move.reverse_preparation_id,move.id,source_restore,move.target_release_event_id,
     p_received_reverse,p_source_reverse,p_reverse_material_event,p_actor);
 END LOOP;
 IF EXISTS(SELECT 1 FROM production_workshop_material_custody_moves candidate WHERE candidate.request_item_id=p_request_item
   AND candidate.return_slice_id IS NOT NULL AND candidate.source_allocation_id IS NULL) THEN
   PERFORM fn_reverse_workshop_preplan_return(p_request_item,p_actor);
 END IF;
END $$;

CREATE FUNCTION fn_reservation_tracks_workshop_source(p_reservation UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM stock_reservations held JOIN warehouses warehouse ON warehouse.id=held.warehouse_id
   WHERE held.id=p_reservation AND (held.owner_type IN('PRODUCTION_MATERIAL_DEMAND','WORKSHOP_CUSTODY'))
     AND (warehouse.is_line_side OR EXISTS(SELECT 1 FROM production_workshop_direct_source_allocations allocation
       WHERE allocation.stock_reservation_id=held.id)))
$$;

CREATE FUNCTION fn_workshop_source_net_moved_from_technical(p_source UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT COALESCE(SUM(move.qty_base),0) FROM production_workshop_material_custody_moves move
 JOIN production_material_return_request_items item ON item.id=move.request_item_id
 JOIN production_material_return_receiving_confirmations confirmation ON confirmation.stock_document_id=item.request_id
 JOIN production_workshop_direct_transfer_items direct ON direct.id=move.transfer_item_id
 JOIN production_workshop_direct_transfers header ON header.id=direct.transfer_id
 WHERE move.transfer_item_id=p_source AND confirmation.source_warehouse_id=header.line_side_warehouse_id
   AND confirmation.received_warehouse_id<>header.line_side_warehouse_id
   AND NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_reversals reversed WHERE reversed.move_id=move.id)
$$;

CREATE FUNCTION fn_assert_workshop_source_physical_custody(p_source UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE received NUMERIC; physical_claimed NUMERIC;
BEGIN
 PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=p_source FOR UPDATE;
 SELECT received_qty INTO received FROM v_workshop_direct_supply_lots WHERE id=p_source;
 SELECT fn_workshop_source_net_moved_from_technical(p_source)
   +COALESCE((SELECT SUM(allocation.effective_qty) FROM v_workshop_direct_source_allocations allocation
      JOIN stock_reservations held ON held.id=allocation.stock_reservation_id
      JOIN production_workshop_direct_transfer_items direct ON direct.id=allocation.transfer_item_id
      JOIN production_workshop_direct_transfers header ON header.id=direct.transfer_id
      WHERE allocation.transfer_item_id=p_source AND held.warehouse_id=header.line_side_warehouse_id),0)
   +COALESCE((SELECT SUM(slice.qty_base) FROM production_workshop_material_return_slices slice
      WHERE slice.transfer_item_id=p_source AND slice.source_allocation_id IS NULL
        AND fn_workshop_return_slice_pending(slice.request_item_id,NULL)),0)
 INTO physical_claimed;
 IF physical_claimed>COALESCE(received,0) THEN
   RAISE EXCEPTION 'Original direct receipt still funds moved, held or pending physical custody' USING ERRCODE='23514';
 END IF;
END $$;

CREATE OR REPLACE VIEW v_workshop_direct_supply_lots AS
SELECT transfer_item.id,transfer_item.to_demand_id,transfer_item.to_execution_segment_id,
  transfer_item.created_at,source.execution_segment_id AS producing_segment_id,
  source.goods_id,source.color_id,transfer.line_side_warehouse_id,
  LEAST(round(transfer_item.qty*COALESCE(source.unit_rate,1),4),inbound.qty) AS received_qty,
  CASE WHEN EXISTS(SELECT 1 FROM production_workshop_direct_legacy_anomalies anomaly
      WHERE anomaly.warehouse_id=transfer.line_side_warehouse_id AND anomaly.goods_id=source.goods_id
        AND anomaly.color_id IS NOT DISTINCT FROM source.color_id) THEN 0 ELSE
  GREATEST(LEAST(round(transfer_item.qty*COALESCE(source.unit_rate,1),4),inbound.qty)
    -fn_workshop_source_net_moved_from_technical(transfer_item.id)
    -COALESCE((SELECT SUM(allocation.effective_qty) FROM v_workshop_direct_source_allocations allocation
      JOIN stock_reservations held ON held.id=allocation.stock_reservation_id
      WHERE allocation.transfer_item_id=transfer_item.id AND held.warehouse_id=transfer.line_side_warehouse_id),0)
    -COALESCE((SELECT SUM(slice.qty_base) FROM production_workshop_material_return_slices slice
      WHERE slice.transfer_item_id=transfer_item.id AND slice.source_allocation_id IS NULL
        AND fn_workshop_return_slice_pending(slice.request_item_id,NULL)),0),0) END AS available_qty
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
) inbound WHERE transfer_item.reversal_id IS NULL;

-- Reconcile only the remaining ledger difference. A custody command writes its
-- exact RELEASE/RESTORE first; the reservation projection must not choose a
-- different unused source or append a second release for the same transfer.
CREATE OR REPLACE FUNCTION fn_capture_workshop_source_reservation_release() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE actual_hold NUMERIC; expected_hold NUMERIC;
BEGIN
 IF NOT fn_reservation_tracks_workshop_source(NEW.id) THEN RETURN NULL; END IF;
 SELECT COALESCE(SUM(effective_qty),0) INTO actual_hold FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=NEW.id;
 expected_hold:=CASE WHEN NEW.is_deleted THEN 0 ELSE NEW.qty-NEW.released_qty END;
 -- Growing a reservation is followed by an explicit new allocation. This
 -- trigger only accounts for changes of release/deletion, never invents grants.
 IF NEW.released_qty IS DISTINCT FROM OLD.released_qty OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted THEN
   PERFORM fn_record_workshop_source_release(NEW.id,actual_hold-expected_hold,NULLIF(current_setting('app.actor_id',true),'')::UUID,FALSE);
 END IF;
 RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION fn_guard_workshop_direct_source_allocation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'workshop source allocation history is append-only' USING ERRCODE='55000'; END IF;
 PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=NEW.transfer_item_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM production_workshop_material_custody_moves move
   JOIN stock_reservations held ON held.id=move.target_reservation_id
   WHERE move.target_allocation_id=NEW.id AND move.target_reservation_id=NEW.stock_reservation_id
     AND move.transfer_item_id=NEW.transfer_item_id AND move.qty_base=NEW.qty_base AND NEW.released_baseline=0
     AND NOT held.is_deleted AND ((held.owner_type='PRODUCTION_MATERIAL_DEMAND' AND held.demand_id=move.target_demand_id)
       OR (held.owner_type='WORKSHOP_CUSTODY' AND held.owner_id=move.target_demand_id AND held.demand_id IS NULL)))
 OR EXISTS(SELECT 1 FROM production_workshop_material_custody_handoffs handoff
   JOIN production_workshop_direct_source_allocations original ON original.id=handoff.source_allocation_id
   JOIN stock_reservations source_held ON source_held.id=original.stock_reservation_id
   JOIN stock_reservations target_held ON target_held.id=handoff.target_reservation_id
   WHERE handoff.target_allocation_id=NEW.id AND handoff.target_reservation_id=NEW.stock_reservation_id
     AND original.transfer_item_id=NEW.transfer_item_id AND handoff.qty_base=NEW.qty_base AND NEW.released_baseline=0
     AND source_held.owner_type='WORKSHOP_CUSTODY' AND target_held.owner_type='PRODUCTION_MATERIAL_DEMAND'
     AND source_held.owner_id=target_held.demand_id AND source_held.warehouse_id=target_held.warehouse_id
     AND NOT target_held.is_deleted) THEN RETURN NEW; END IF;
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

DO $extend_existing_source_ledger$
DECLARE definition TEXT; changed TEXT; name TEXT; predicate TEXT;
BEGIN
 predicate:='held\.owner_type IS DISTINCT FROM ''PRODUCTION_MATERIAL_DEMAND''[[:space:]]+OR NOT EXISTS\(SELECT 1 FROM warehouses WHERE id=held\.warehouse_id AND is_line_side\)';
 FOREACH name IN ARRAY ARRAY['fn_record_workshop_direct_posting(uuid,boolean)','fn_assert_workshop_source_event_balances(uuid)'] LOOP
   SELECT pg_get_functiondef(name::regprocedure) INTO definition;
   changed:=regexp_replace(definition,predicate,'NOT fn_reservation_tracks_workshop_source(held.id)');
   IF changed=definition THEN RAISE EXCEPTION 'V619 expected source owner predicate in %',name; END IF;
   IF name='fn_record_workshop_direct_posting(uuid,boolean)' THEN
     changed:=replace(changed,'id,effective_qty-net_issued_qty AS free_qty',
       'id,effective_qty-net_issued_qty-fn_workshop_allocation_pending_return_qty(id,NULL) AS free_qty');
   ELSE
     changed:=replace(changed,'net_issued_qty>effective_qty',
       'net_issued_qty>effective_qty-fn_workshop_allocation_pending_return_qty(id,NULL)');
     changed:=replace(changed,'    expected_hold:=',
       E'    PERFORM fn_assert_workshop_custody_grants(held.id);\n    expected_hold:=');
   END IF;
   EXECUTE changed;
 END LOOP;
 SELECT pg_get_functiondef('fn_record_workshop_source_release(uuid,numeric,uuid,boolean)'::regprocedure) INTO definition;
 changed:=replace(definition,'id,effective_qty-net_issued_qty AS free_qty',
    'id,effective_qty-net_issued_qty-fn_workshop_allocation_pending_return_qty(id,NULL) AS free_qty');
 IF changed=definition THEN RAISE EXCEPTION 'V619 expected exact release free quantity'; END IF;
 EXECUTE changed;
 SELECT pg_get_functiondef('fn_assert_workshop_direct_source_allocation()'::regprocedure) INTO definition;
 changed:=replace(definition,
   'NEW.owner_type IS DISTINCT FROM ''PRODUCTION_MATERIAL_DEMAND'' OR NOT EXISTS(SELECT 1 FROM warehouses WHERE id=NEW.warehouse_id AND is_line_side)',
   'NOT fn_reservation_tracks_workshop_source(NEW.id)');
 IF changed=definition THEN RAISE EXCEPTION 'V619 expected deferred reservation scope'; END IF;
 changed:=replace(changed,E'\n RETURN NULL;\nEND',
   E'\n IF source_id IS NOT NULL THEN PERFORM fn_assert_workshop_source_physical_custody(source_id); END IF;\n RETURN NULL;\nEND');
 EXECUTE changed;
END $extend_existing_source_ledger$;

CREATE FUNCTION fn_guard_workshop_custody_history() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Workshop source custody history is append-only' USING ERRCODE='55000'; END IF;
 IF NEW.created_by::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'') THEN
   RAISE EXCEPTION 'Workshop custody history requires the current transaction actor' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;

CREATE FUNCTION fn_assert_workshop_custody_move(p_move UUID) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_moves move
   JOIN production_workshop_material_custody_preparations prepared ON prepared.id=move.preparation_id
   JOIN production_material_return_request_items requested ON requested.id=move.request_item_id
   JOIN production_material_return_requests request ON request.id=requested.request_id
   JOIN production_material_return_receiving_confirmations receiving ON receiving.stock_document_id=request.id
   JOIN stock_documents document ON document.id=request.id AND document.status=1 AND NOT document.is_deleted
   JOIN stock_movements incoming ON incoming.id=move.received_movement_id
   LEFT JOIN production_workshop_direct_source_allocations target ON target.id=move.target_allocation_id
   JOIN stock_reservations held ON held.id=move.target_reservation_id
   JOIN production_material_demands demand ON demand.id=move.target_demand_id
   LEFT JOIN production_workshop_direct_source_events returned ON returned.id=move.return_source_event_id
   LEFT JOIN production_material_stock_postings posting ON posting.id=COALESCE(returned.stock_posting_id,move.material_return_posting_id)
   LEFT JOIN production_workshop_material_return_slices frozen ON frozen.id=move.return_slice_id
   LEFT JOIN production_workshop_direct_source_events released ON released.id=move.source_release_event_id
   LEFT JOIN stock_movements outgoing ON outgoing.id=move.source_out_movement_id
   WHERE move.id=p_move AND prepared.request_item_id=move.request_item_id
     AND prepared.transfer_item_id IS NOT DISTINCT FROM move.transfer_item_id AND prepared.target_demand_id=move.target_demand_id
     AND prepared.material_return_posting_id IS NOT DISTINCT FROM move.material_return_posting_id
     AND prepared.source_reservation_id IS NOT DISTINCT FROM move.source_reservation_id
     AND prepared.return_source_event_id IS NOT DISTINCT FROM move.return_source_event_id
     AND prepared.return_slice_id IS NOT DISTINCT FROM move.return_slice_id
     AND prepared.source_allocation_id IS NOT DISTINCT FROM move.source_allocation_id
     AND prepared.source_release_event_id IS NOT DISTINCT FROM move.source_release_event_id
     AND prepared.qty_base=move.qty_base AND prepared.created_by=move.created_by AND receiving.created_by=move.created_by
     AND (move.material_return_posting_id IS NOT NULL OR (target.stock_reservation_id=move.target_reservation_id
       AND target.transfer_item_id=move.transfer_item_id AND target.qty_base=move.qty_base))
     AND held.warehouse_id=receiving.received_warehouse_id
     AND held.source_doc_type='WORKSHOP_RETURN_CUSTODY' AND held.source_doc_id=request.id
     AND held.qty=move.qty_base AND held.goods_id=demand.goods_id AND held.color_id IS NOT DISTINCT FROM demand.color_id
     AND (demand.execution_segment_id=request.execution_segment_id OR EXISTS(
       SELECT 1 FROM stock_reservations original_r WHERE original_r.id=move.source_reservation_id AND original_r.demand_id=demand.id))
     AND (held.owner_type='PRODUCTION_MATERIAL_DEMAND' AND held.demand_id=demand.id
       OR held.owner_type='WORKSHOP_CUSTODY' AND held.owner_id=demand.id AND held.demand_id IS NULL)
     AND incoming.source_doc_type='STOCK_DOC' AND incoming.source_doc_id=request.id
     AND incoming.source_item_id=requested.stock_document_item_id AND incoming.warehouse_id=receiving.received_warehouse_id
     AND incoming.goods_id=demand.goods_id AND incoming.color_id IS NOT DISTINCT FROM demand.color_id
     AND incoming.direction=1 AND incoming.qty=requested.qty_base
     AND incoming.created_by=move.created_by AND incoming.xmin::text=pg_current_xact_id()::text
     AND (move.source_allocation_id IS NULL OR (released.source_allocation_id=move.source_allocation_id
       AND released.event_type='RELEASE' AND released.qty_base=move.qty_base))
     AND ((requested.issue_posting_id IS NOT NULL AND posting.posting_type='GOOD_RETURN' AND incoming.movement_type=6
       AND (move.material_return_posting_id IS NOT NULL AND posting.qty_base=move.qty_base
         OR returned.event_type='GOOD_RETURN' AND returned.source_allocation_id=move.source_allocation_id AND returned.qty_base=move.qty_base)
       AND posting.source_posting_id=requested.issue_posting_id AND posting.stock_document_item_id=requested.stock_document_item_id
       AND posting.reservation_id=move.source_reservation_id AND posting.created_by=move.created_by
       AND EXISTS(SELECT 1 FROM production_material_movement_links link WHERE link.movement_id=incoming.id AND link.event_id=posting.event_id
           AND link.document_item_id=requested.stock_document_item_id)
       AND move.source_out_movement_id IS NULL)
       OR (requested.direct_transfer_item_id=move.transfer_item_id AND frozen.request_item_id=requested.id
         AND frozen.source_allocation_id IS NOT DISTINCT FROM move.source_allocation_id AND frozen.qty_base=move.qty_base
         AND incoming.movement_type=7 AND outgoing.movement_type=8 AND outgoing.direction=-1 AND outgoing.qty=requested.qty_base
         AND outgoing.created_by=move.created_by AND outgoing.xmin::text=pg_current_xact_id()::text
         AND outgoing.source_doc_type='STOCK_DOC' AND outgoing.source_doc_id=request.id
         AND outgoing.source_item_id=requested.stock_document_item_id AND outgoing.warehouse_id=receiving.source_warehouse_id
         AND outgoing.goods_id=demand.goods_id AND outgoing.color_id IS NOT DISTINCT FROM demand.color_id))
 ) THEN RAISE EXCEPTION 'Custody transfer requires exact source slices, inherited rights and its typed physical warehouse movements' USING ERRCODE='23514'; END IF;
END $$;

CREATE FUNCTION fn_assert_workshop_custody_reversal(p_reversal UUID) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_reversals reversed
   JOIN production_workshop_material_custody_moves move ON move.id=reversed.move_id
   JOIN production_workshop_custody_reverse_preparations prepared ON prepared.id=reversed.preparation_id AND prepared.move_id=move.id
   JOIN production_material_return_request_items item ON item.id=move.request_item_id
   JOIN stock_documents document ON document.id=item.request_id AND document.status=-1
   JOIN stock_movements original_in ON original_in.id=move.received_movement_id
   JOIN stock_movements reverse_in ON reverse_in.id=reversed.received_reverse_movement_id
   LEFT JOIN v_workshop_direct_source_allocations target ON target.id=move.target_allocation_id
   JOIN stock_reservations target_held ON target_held.id=move.target_reservation_id
   LEFT JOIN stock_movements original_out ON original_out.id=move.source_out_movement_id
   LEFT JOIN stock_movements reverse_out ON reverse_out.id=reversed.source_reverse_movement_id
   LEFT JOIN production_workshop_direct_source_events restored ON restored.id=reversed.original_restore_event_id
   LEFT JOIN production_workshop_direct_source_events returned ON returned.id=move.return_source_event_id
   WHERE reversed.id=p_reversal AND (move.target_allocation_id IS NULL OR target.effective_qty=0 AND target.net_issued_qty=0)
     AND target_held.consumed_qty=0 AND (target_held.is_deleted OR target_held.qty=target_held.released_qty)
     AND prepared.target_release_event_id IS NOT DISTINCT FROM reversed.target_release_event_id
     AND prepared.reverse_material_event_id IS NOT DISTINCT FROM reversed.reverse_material_event_id
     AND prepared.created_by=reversed.created_by
     AND (move.return_slice_id IS NOT NULL OR prepared.original_restore_event_id IS NOT DISTINCT FROM reversed.original_restore_event_id)
     AND reverse_in.source_doc_type=original_in.source_doc_type AND reverse_in.source_doc_id=original_in.source_doc_id
     AND reverse_in.source_item_id=original_in.source_item_id AND reverse_in.warehouse_id=original_in.warehouse_id
     AND reverse_in.goods_id=original_in.goods_id AND reverse_in.color_id IS NOT DISTINCT FROM original_in.color_id
     AND reverse_in.movement_type=original_in.movement_type AND reverse_in.direction=-original_in.direction AND reverse_in.qty=original_in.qty
     AND reverse_in.created_by=reversed.created_by AND reverse_in.xmin::text=pg_current_xact_id()::text
     AND ((move.source_allocation_id IS NULL AND reversed.original_restore_event_id IS NULL)
       OR (restored.source_allocation_id=move.source_allocation_id AND restored.event_type='RESTORE'
         AND restored.counter_event_id=move.source_release_event_id AND restored.qty_base=move.qty_base))
     AND ((move.return_slice_id IS NOT NULL AND reversed.reverse_material_event_id IS NULL
       AND reverse_out.source_doc_type=original_out.source_doc_type AND reverse_out.source_doc_id=original_out.source_doc_id
       AND reverse_out.source_item_id=original_out.source_item_id AND reverse_out.warehouse_id=original_out.warehouse_id
       AND reverse_out.goods_id=original_out.goods_id AND reverse_out.color_id IS NOT DISTINCT FROM original_out.color_id
       AND reverse_out.movement_type=original_out.movement_type AND reverse_out.direction=-original_out.direction AND reverse_out.qty=original_out.qty
       AND reverse_out.created_by=reversed.created_by AND reverse_out.xmin::text=pg_current_xact_id()::text)
     OR (move.return_slice_id IS NULL AND reversed.source_reverse_movement_id IS NULL AND EXISTS(
       SELECT 1 FROM production_material_stock_events event
       JOIN production_material_stock_postings posting ON posting.event_id=event.id
       JOIN production_material_stock_postings original_return ON original_return.id=COALESCE(returned.stock_posting_id,move.material_return_posting_id)
       JOIN production_material_movement_links link ON link.event_id=event.id AND link.document_item_id=posting.stock_document_item_id
       WHERE event.id=reversed.reverse_material_event_id AND event.event_type='GOOD_RETURN_REVERSE'
         AND posting.source_posting_id=original_return.id AND posting.stock_document_item_id=item.stock_document_item_id
         AND posting.qty_base=original_return.qty_base
         AND link.movement_id=reverse_in.id)))
 ) THEN RAISE EXCEPTION 'Custody reversal must undo the original source and both physical legs, without destination consumption' USING ERRCODE='23514'; END IF;
END $$;

CREATE FUNCTION fn_assert_workshop_custody_handoff(p_handoff UUID) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_handoffs handoff
   JOIN production_workshop_direct_source_allocations original ON original.id=handoff.source_allocation_id
   JOIN stock_reservations source_r ON source_r.id=original.stock_reservation_id
   JOIN production_workshop_direct_source_allocations target ON target.id=handoff.target_allocation_id
   JOIN stock_reservations target_r ON target_r.id=target.stock_reservation_id
   JOIN production_workshop_direct_source_events released ON released.id=handoff.source_release_event_id
   WHERE handoff.id=p_handoff AND source_r.owner_type='WORKSHOP_CUSTODY'
     AND target_r.owner_type='PRODUCTION_MATERIAL_DEMAND' AND source_r.owner_id=target_r.demand_id
     AND source_r.warehouse_id=target_r.warehouse_id AND source_r.goods_id=target_r.goods_id
     AND source_r.color_id IS NOT DISTINCT FROM target_r.color_id
     AND target_r.id=handoff.target_reservation_id AND original.transfer_item_id=target.transfer_item_id
     AND target.qty_base=handoff.qty_base AND target_r.qty=handoff.qty_base
     AND released.event_type='RELEASE' AND released.source_allocation_id=original.id AND released.qty_base=handoff.qty_base
 ) THEN RAISE EXCEPTION 'Custody formalization must retain the exact original private source and task' USING ERRCODE='23514'; END IF;
END $$;

CREATE FUNCTION fn_check_workshop_custody_history() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE move_id UUID; source_r UUID; target_r UUID;
BEGIN
 IF TG_TABLE_NAME='production_workshop_material_custody_preparations' THEN
   SELECT id INTO move_id FROM production_workshop_material_custody_moves WHERE preparation_id=NEW.id;
   IF move_id IS NULL THEN RAISE EXCEPTION 'Source custody preparation and physical receipt must commit together' USING ERRCODE='23514'; END IF;
   PERFORM fn_assert_workshop_custody_move(move_id);
 ELSIF TG_TABLE_NAME='production_workshop_material_custody_moves' THEN
   PERFORM fn_assert_workshop_custody_move(NEW.id);
 ELSIF TG_TABLE_NAME='production_workshop_material_custody_reversals' THEN
   PERFORM fn_assert_workshop_custody_reversal(NEW.id);
 ELSIF TG_TABLE_NAME='production_workshop_custody_reverse_preparations' THEN
   SELECT id INTO move_id FROM production_workshop_material_custody_reversals WHERE preparation_id=NEW.id;
   IF move_id IS NULL THEN RAISE EXCEPTION 'Custody reverse preparation and exact physical counters must commit together' USING ERRCODE='23514'; END IF;
   PERFORM fn_assert_workshop_custody_reversal(move_id);
 ELSIF TG_TABLE_NAME='production_workshop_material_custody_handoffs' THEN
   PERFORM fn_assert_workshop_custody_handoff(NEW.id);
 ELSE
   IF NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_handoffs handoff
     JOIN production_workshop_direct_source_events restored ON restored.id=NEW.source_restore_event_id
     JOIN v_workshop_direct_source_allocations target ON target.id=handoff.target_allocation_id
     WHERE handoff.id=NEW.handoff_id AND restored.counter_event_id=handoff.source_release_event_id
       AND restored.source_allocation_id=handoff.source_allocation_id AND restored.event_type='RESTORE'
       AND restored.qty_base=handoff.qty_base AND target.effective_qty=0 AND target.net_issued_qty=0
       AND EXISTS(SELECT 1 FROM production_workshop_material_custody_moves original
         JOIN production_workshop_material_custody_reversals reversed ON reversed.move_id=original.id
         WHERE original.target_allocation_id=handoff.source_allocation_id)) THEN
     RAISE EXCEPTION 'Custody formalization reversal must restore its exact original unused slice' USING ERRCODE='23514';
   END IF;
 END IF;
 RETURN NULL;
END $$;

DO $custody_history_triggers$
DECLARE name TEXT;
BEGIN
 FOREACH name IN ARRAY ARRAY['production_workshop_material_custody_preparations','production_workshop_custody_reverse_preparations','production_workshop_material_custody_moves',
   'production_workshop_material_custody_reversals','production_workshop_material_custody_handoffs','production_workshop_custody_handoff_reversals'] LOOP
   EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_custody_history()', 'trg_guard_'||name,name);
   EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',name,'trg_guard_'||name);
   EXECUTE format('CREATE CONSTRAINT TRIGGER %I AFTER INSERT ON %I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_workshop_custody_history()', 'trg_check_'||name,name);
   EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',name,'trg_check_'||name);
 END LOOP;
END $custody_history_triggers$;

CREATE TRIGGER trg_audit_production_workshop_material_custody_preparations AFTER INSERT OR UPDATE OR DELETE ON production_workshop_material_custody_preparations
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_material_custody_preparations ENABLE ALWAYS TRIGGER trg_audit_production_workshop_material_custody_preparations;
CREATE TRIGGER trg_audit_production_workshop_material_custody_moves AFTER INSERT OR UPDATE OR DELETE ON production_workshop_material_custody_moves
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_material_custody_moves ENABLE ALWAYS TRIGGER trg_audit_production_workshop_material_custody_moves;
CREATE TRIGGER trg_audit_production_workshop_material_custody_reversals AFTER INSERT OR UPDATE OR DELETE ON production_workshop_material_custody_reversals
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_material_custody_reversals ENABLE ALWAYS TRIGGER trg_audit_production_workshop_material_custody_reversals;
CREATE TRIGGER trg_audit_production_workshop_material_custody_handoffs AFTER INSERT OR UPDATE OR DELETE ON production_workshop_material_custody_handoffs
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_material_custody_handoffs ENABLE ALWAYS TRIGGER trg_audit_production_workshop_material_custody_handoffs;
CREATE TRIGGER trg_audit_production_workshop_custody_handoff_reversals AFTER INSERT OR UPDATE OR DELETE ON production_workshop_custody_handoff_reversals
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_custody_handoff_reversals ENABLE ALWAYS TRIGGER trg_audit_production_workshop_custody_handoff_reversals;
CREATE TRIGGER trg_audit_production_workshop_custody_reverse_preparations AFTER INSERT OR UPDATE OR DELETE ON production_workshop_custody_reverse_preparations
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_custody_reverse_preparations ENABLE ALWAYS TRIGGER trg_audit_production_workshop_custody_reverse_preparations;

CREATE FUNCTION fn_check_workshop_custody_reservation_grant() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.source_doc_type='WORKSHOP_RETURN_CUSTODY' AND (
   SELECT COUNT(*) FROM (SELECT target_reservation_id FROM production_workshop_material_custody_moves WHERE target_reservation_id=NEW.id
     UNION ALL SELECT target_reservation_id FROM production_workshop_material_custody_handoffs WHERE target_reservation_id=NEW.id) grant_rows)<>1 THEN
   RAISE EXCEPTION 'Returned-material reservation requires its exact custody movement or formalization grant' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM production_workshop_material_custody_moves WHERE source_reservation_id=NEW.id OR target_reservation_id=NEW.id) THEN
   PERFORM fn_assert_workshop_custody_grants(NEW.id);
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_check_workshop_custody_reservation_grant AFTER INSERT OR UPDATE ON stock_reservations
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_workshop_custody_reservation_grant();

-- A never-issued transfer has an actual technical-stock outbound. These exact
-- typed custody legs are the only new exception to the technical-stock boundary.
DO $custody_physical_boundary$
DECLARE definition TEXT;
BEGIN
 SELECT rtrim(pg_get_viewdef('v_workshop_direct_stock_anomalies'::regclass,true),E';\n ') INTO definition;
 EXECUTE 'CREATE OR REPLACE VIEW v_workshop_direct_stock_anomalies AS SELECT original.* FROM ('||definition||') original '
   ||'WHERE NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_moves move WHERE move.source_out_movement_id=original.movement_id) '
   ||'AND NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_reversals reversed WHERE reversed.source_reverse_movement_id=original.movement_id)';
END $custody_physical_boundary$;

CREATE FUNCTION fn_check_workshop_return_slice_total() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE item_id UUID; requested production_material_return_request_items%ROWTYPE;
BEGIN
 IF TG_TABLE_NAME='production_material_return_request_items' THEN item_id:=NEW.id; ELSE item_id:=NEW.request_item_id; END IF;
 SELECT * INTO requested FROM production_material_return_request_items WHERE id=item_id;
 IF requested.direct_transfer_item_id IS NULL THEN RETURN NULL; END IF;
 IF requested.qty_base<>(SELECT COALESCE(SUM(qty_base),0) FROM production_workshop_material_return_slices WHERE request_item_id=item_id) THEN
   RAISE EXCEPTION 'Unissued workshop return must freeze all of its exact source quantity' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM production_workshop_material_return_slices slice
   JOIN v_workshop_direct_source_allocations allocation ON allocation.id=slice.source_allocation_id
   WHERE slice.request_item_id=item_id
     AND fn_workshop_allocation_pending_return_qty(allocation.id,NULL)>allocation.effective_qty-allocation.net_issued_qty) THEN
   RAISE EXCEPTION 'Pending workshop returns exceed the exact unissued reservation slice' USING ERRCODE='23514';
 END IF;
 PERFORM fn_assert_workshop_source_physical_custody(requested.direct_transfer_item_id);
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_check_workshop_return_request_slices AFTER INSERT ON production_material_return_request_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_workshop_return_slice_total();
CREATE CONSTRAINT TRIGGER trg_check_workshop_return_slice_total AFTER INSERT ON production_workshop_material_return_slices
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_workshop_return_slice_total();

-- Original formalization remains on its original reservation. A custody move
-- carries that already-proven quantity to another warehouse without cloning a
-- FORMALIZE or MAKE-receipt fact on the successor reservation.
DO $qualified_custody_origin$
DECLARE definition TEXT; changed TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_assert_qualified_origin_formal_reservation(uuid)'::regprocedure) INTO definition;
 changed:=replace(definition,'covered IS DISTINCT FROM target.qty-target.released_qty',
   'covered IS DISTINCT FROM target.qty-target.released_qty+COALESCE((SELECT SUM(move.qty_base) '
   ||'FROM production_workshop_material_custody_moves move WHERE move.source_reservation_id=target.id '
   ||'AND NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_reversals reversed WHERE reversed.move_id=move.id)),0)');
 IF changed=definition THEN RAISE EXCEPTION 'V619 expected qualified-origin coverage predicate'; END IF;
 EXECUTE changed;
END $qualified_custody_origin$;

DO $pending_custody_start_gate$
DECLARE definition TEXT; changed TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_execution_start_material_ready(uuid)'::regprocedure) INTO definition;
 changed:=replace(definition,'SUM(reservation.qty-reservation.consumed_qty-reservation.released_qty)',
   'SUM(fn_workshop_reservation_unissued_available(reservation.id))');
 IF changed=definition THEN RAISE EXCEPTION 'V619 expected execution material unissued holding aggregate'; END IF;
 EXECUTE changed;
END $pending_custody_start_gate$;

-- Append after the source section. Recheck aggregate pending custody at commit,
-- including multiple rows in one statement and transactions that waited for locks.


-- BEGIN PRIVATE PREPLAN HANDOFF
CREATE TABLE production_workshop_return_preplan_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 request_item_id UUID NOT NULL REFERENCES production_material_return_request_items(id),
 transfer_item_id UUID NOT NULL REFERENCES production_workshop_direct_transfer_items(id),
 source_reservation_id UUID NOT NULL REFERENCES stock_reservations(id),
 source_entitlement_event_id UUID NOT NULL REFERENCES preplan_stock_entitlement_events(id),
 entitlement_event_id UUID NOT NULL UNIQUE REFERENCES preplan_stock_entitlement_events(id),
 event_type TEXT NOT NULL CHECK(event_type IN('RELEASE','RESTORE')),
 qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
 counter_id UUID UNIQUE REFERENCES production_workshop_return_preplan_events(id),
 created_by UUID NOT NULL REFERENCES users(id),created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 CHECK((event_type='RELEASE')=(counter_id IS NULL))
);
CREATE INDEX idx_workshop_return_preplan_request ON production_workshop_return_preplan_events(request_item_id,transfer_item_id);
CREATE FUNCTION fn_prepare_workshop_preplan_return(p_item UUID,p_transfer UUID,p_qty NUMERIC,p_actor UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE context RECORD; part RECORD; private_qty NUMERIC; public_qty NUMERIC; remaining NUMERIC:=p_qty;take NUMERIC;event_id UUID;
BEGIN
 SELECT requested.request_id,plan.material_analysis_id,plan.material_analysis_item_id,transfer.source_report_item_id,
    source.goods_id,source.color_id INTO STRICT context
 FROM production_material_return_request_items requested
 JOIN production_material_return_requests request ON request.id=requested.request_id
 JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
 JOIN production_plans plan ON plan.id=segment.plan_id
 JOIN production_workshop_direct_transfer_items transfer ON transfer.id=p_transfer
 JOIN production_daily_report_items source ON source.id=transfer.source_report_item_id WHERE requested.id=p_item;
 SELECT COALESCE(SUM(held.qty-held.consumed_qty-held.released_qty),0) INTO private_qty
 FROM stock_reservations held JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=held.id
 JOIN stock_document_items receipt ON receipt.id=exact.source_stock_document_item_id
 WHERE receipt.source_daily_report_item_id=context.source_report_item_id AND held.owner_type='PREPLAN_ANALYSIS'
   AND NOT held.is_deleted AND held.status=0;
 SELECT GREATEST(lot.available_qty+COALESCE((SELECT SUM(slice.qty_base) FROM production_workshop_material_return_slices slice
     WHERE slice.request_item_id=p_item AND slice.transfer_item_id=p_transfer AND slice.source_allocation_id IS NULL),0)-private_qty,0)
 INTO public_qty FROM v_workshop_direct_supply_lots lot WHERE lot.id=p_transfer;
 FOR part IN
  SELECT positive.*,held.id AS reservation_id,positive.qty-COALESCE((SELECT SUM(negative.qty)
    FROM preplan_stock_entitlement_events negative WHERE negative.source_entitlement_event_id=positive.id
      AND negative.event_type IN('MAKE_DELEGATE_OUT','SUBCONTRACT_HANDOFF_OUT','REALLOCATE_OUT','PRIORITY_OUT','FORMALIZE','RELEASE')),0) AS available
  FROM preplan_stock_entitlement_events positive
  JOIN stock_reservations held ON held.id=positive.stock_reservation_id AND held.owner_type='PREPLAN_ANALYSIS' AND NOT held.is_deleted
  JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=held.id
  JOIN stock_document_items receipt ON receipt.id=exact.source_stock_document_item_id
  WHERE receipt.source_daily_report_item_id=context.source_report_item_id
    AND positive.beneficiary_analysis_id=context.material_analysis_id
    AND fn_analysis_plan_material_matches(context.material_analysis_item_id,positive.beneficiary_analysis_material_id)
    AND positive.event_type IN('ORIGIN_IQC','ORIGIN_MAKE','MAKE_DELEGATE_IN','SUBCONTRACT_HANDOFF_IN','REALLOCATE_IN','PRIORITY_IN','RESTORE')
  ORDER BY held.id,positive.created_at,positive.id FOR UPDATE OF held,positive
 LOOP
  take:=LEAST(remaining,GREATEST(part.available,0));IF take<=0 THEN CONTINUE; END IF;
  event_id:=gen_random_uuid();
  INSERT INTO preplan_stock_entitlement_events(id,event_group_id,stock_reservation_id,beneficiary_analysis_id,
    beneficiary_analysis_material_id,event_type,qty,source_entitlement_event_id,reallocation_id,idempotency_key,created_by)
  VALUES(event_id,p_item,part.reservation_id,part.beneficiary_analysis_id,part.beneficiary_analysis_material_id,
    'RELEASE',take,part.id,part.reallocation_id,'WORKSHOP_CUSTODY_RELEASE:'||event_id,p_actor);
  UPDATE stock_reservations SET released_qty=released_qty+take,
    status=CASE WHEN consumed_qty+released_qty+take=qty THEN 1 ELSE 0 END,
    release_reason='WORKSHOP_RETURN_CUSTODY',lock_version=lock_version+1,updated_at=now(),updated_by=p_actor
    WHERE id=part.reservation_id AND qty-consumed_qty-released_qty>=take;
  IF NOT FOUND THEN RAISE EXCEPTION 'Original preplan stock changed before custody transfer' USING ERRCODE='23514'; END IF;
  INSERT INTO production_workshop_return_preplan_events(request_item_id,transfer_item_id,source_reservation_id,
    source_entitlement_event_id,entitlement_event_id,event_type,qty_base,created_by)
  VALUES(p_item,p_transfer,part.reservation_id,part.id,event_id,'RELEASE',take,p_actor);
  remaining:=remaining-take;EXIT WHEN remaining=0;
 END LOOP;
 IF remaining>COALESCE(public_qty,0) THEN
  RAISE EXCEPTION 'Dedicated workshop material is held for a different preplan beneficiary' USING ERRCODE='23514';
 END IF;
END $$;

CREATE FUNCTION fn_reverse_workshop_preplan_return(p_item UUID,p_actor UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE proof RECORD; positive preplan_stock_entitlement_events%ROWTYPE;released preplan_stock_entitlement_events%ROWTYPE;event_id UUID;
BEGIN
 FOR proof IN SELECT * FROM production_workshop_return_preplan_events origin WHERE request_item_id=p_item AND event_type='RELEASE'
  AND NOT EXISTS(SELECT 1 FROM production_workshop_return_preplan_events back WHERE back.counter_id=origin.id)
  ORDER BY source_reservation_id,id LOOP
  SELECT * INTO STRICT positive FROM preplan_stock_entitlement_events WHERE id=proof.source_entitlement_event_id FOR UPDATE;
  SELECT * INTO STRICT released FROM preplan_stock_entitlement_events WHERE id=proof.entitlement_event_id;
  UPDATE stock_reservations SET released_qty=released_qty-proof.qty_base,status=0,lock_version=lock_version+1,updated_at=now(),updated_by=p_actor
   WHERE id=proof.source_reservation_id AND released_qty>=proof.qty_base AND NOT is_deleted;
  IF NOT FOUND THEN RAISE EXCEPTION 'Original preplan custody is no longer restorable' USING ERRCODE='23514'; END IF;
  event_id:=gen_random_uuid();
  INSERT INTO preplan_stock_entitlement_events(id,event_group_id,stock_reservation_id,beneficiary_analysis_id,
    beneficiary_analysis_material_id,event_type,qty,reallocation_id,source_exact_peg_id,counter_event_id,idempotency_key,created_by)
  VALUES(event_id,p_item,proof.source_reservation_id,positive.beneficiary_analysis_id,positive.beneficiary_analysis_material_id,
    'RESTORE',proof.qty_base,released.reallocation_id,positive.source_exact_peg_id,released.id,'WORKSHOP_CUSTODY_RESTORE:'||event_id,p_actor);
  INSERT INTO production_workshop_return_preplan_events(request_item_id,transfer_item_id,source_reservation_id,
    source_entitlement_event_id,entitlement_event_id,event_type,qty_base,counter_id,created_by)
  VALUES(p_item,proof.transfer_item_id,proof.source_reservation_id,proof.source_entitlement_event_id,event_id,'RESTORE',proof.qty_base,proof.id,p_actor);
 END LOOP;
END $$;

CREATE FUNCTION fn_guard_workshop_return_preplan_event() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Workshop preplan custody events are immutable' USING ERRCODE='55000'; END IF;
 IF NEW.created_by::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'') OR NOT EXISTS(
  SELECT 1 FROM preplan_stock_entitlement_events event WHERE event.id=NEW.entitlement_event_id
   AND event.stock_reservation_id=NEW.source_reservation_id AND event.event_type=NEW.event_type AND event.qty=NEW.qty_base
   AND event.created_by=NEW.created_by AND event.event_group_id=NEW.request_item_id
   AND (NEW.event_type='RELEASE' AND event.source_entitlement_event_id=NEW.source_entitlement_event_id
     OR NEW.event_type='RESTORE' AND EXISTS(
       SELECT 1 FROM production_workshop_return_preplan_events original
       WHERE original.id=NEW.counter_id AND original.event_type='RELEASE'
         AND original.request_item_id=NEW.request_item_id AND original.transfer_item_id=NEW.transfer_item_id
         AND original.source_reservation_id=NEW.source_reservation_id
         AND original.source_entitlement_event_id=NEW.source_entitlement_event_id
         AND original.qty_base=NEW.qty_base AND event.counter_event_id=original.entitlement_event_id))
   AND event.xmin::text=pg_current_xact_id()::text) THEN
  RAISE EXCEPTION 'Preplan custody must bind its exact same-transaction entitlement fact' USING ERRCODE='23514';
 END IF;RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_workshop_return_preplan_event BEFORE INSERT OR UPDATE OR DELETE ON production_workshop_return_preplan_events
FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_return_preplan_event();
ALTER TABLE production_workshop_return_preplan_events ENABLE ALWAYS TRIGGER trg_guard_workshop_return_preplan_event;
CREATE FUNCTION fn_check_workshop_return_preplan_event() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.event_type='RELEASE' AND NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_moves move
   WHERE move.request_item_id=NEW.request_item_id AND move.transfer_item_id=NEW.transfer_item_id AND move.source_allocation_id IS NULL
    AND move.xmin::text=pg_current_xact_id()::text)
 OR NEW.event_type='RESTORE' AND NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_moves move
   JOIN production_workshop_material_custody_reversals reversed ON reversed.move_id=move.id
   WHERE move.request_item_id=NEW.request_item_id AND move.transfer_item_id=NEW.transfer_item_id
    AND reversed.xmin::text=pg_current_xact_id()::text) THEN
  RAISE EXCEPTION 'Preplan rights cannot leave custody without the exact real warehouse move' USING ERRCODE='23514';
 END IF;
 IF (SELECT SUM(qty_base) FROM production_workshop_return_preplan_events WHERE request_item_id=NEW.request_item_id
      AND transfer_item_id=NEW.transfer_item_id AND event_type='RELEASE')>
    (SELECT COALESCE(SUM(qty_base),0) FROM production_workshop_material_custody_moves WHERE request_item_id=NEW.request_item_id
      AND transfer_item_id=NEW.transfer_item_id AND source_allocation_id IS NULL) THEN
  RAISE EXCEPTION 'Preplan custody release exceeds the real moved source' USING ERRCODE='23514';
 END IF;RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_check_workshop_return_preplan_event AFTER INSERT ON production_workshop_return_preplan_events
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_workshop_return_preplan_event();
ALTER TABLE production_workshop_return_preplan_events ENABLE ALWAYS TRIGGER trg_check_workshop_return_preplan_event;
CREATE TRIGGER trg_audit_production_workshop_return_preplan_events AFTER INSERT OR UPDATE OR DELETE ON production_workshop_return_preplan_events
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_workshop_return_preplan_events ENABLE ALWAYS TRIGGER trg_audit_production_workshop_return_preplan_events;

-- BEGIN HISTORICAL MATERIAL CREDIT
-- A real ISSUE followed by warehouse custody remains historically issued.
-- A DIRECT_LOT return has no ISSUE history and must still block short closing.
CREATE OR REPLACE FUNCTION fn_daily_report_has_unissued_material(p_plan_item UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(
        SELECT 1 FROM production_material_demands demand
        JOIN stock_reservations reservation ON reservation.demand_id=demand.id
        WHERE demand.source_plan_item_id=p_plan_item AND NOT demand.is_deleted
          AND reservation.owner_type='PRODUCTION_MATERIAL_DEMAND' AND NOT reservation.is_deleted
          AND reservation.qty-reservation.released_qty>GREATEST(COALESCE((
              SELECT SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base
                         WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END)
              FROM production_material_stock_postings WHERE reservation_id=reservation.id),0),
              COALESCE((SELECT SUM(move.qty_base)
                FROM production_workshop_material_custody_moves move
                WHERE move.target_reservation_id=reservation.id
                  AND (move.return_source_event_id IS NOT NULL OR move.material_return_posting_id IS NOT NULL)
                  AND NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_reversals reversed
                    WHERE reversed.move_id=move.id)),0)))
       OR EXISTS(
        SELECT 1 FROM production_material_demands demand
        JOIN production_planning_package_document_items mapping ON mapping.demand_id=demand.id
          AND mapping.document_type='DRAW'
        JOIN stock_document_items item ON item.id=mapping.document_item_id AND NOT item.is_deleted
        JOIN stock_documents document ON document.id=item.doc_id AND document.doc_type='DRAW'
          AND document.status IN (0,1) AND NOT document.is_deleted
        WHERE demand.source_plan_item_id=p_plan_item AND NOT demand.is_deleted
          AND fn_production_draw_item_effective_qty(item.id)>COALESCE(item.issued_qty,0));
$$;

-- BEGIN VALUE AND LIFECYCLE CONTRACTS
CREATE FUNCTION fn_workshop_return_outbound_authorized(p_request UUID,p_doc UUID,p_item UUID,p_warehouse UUID,p_qty NUMERIC,p_kind TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM production_material_return_request_items requested
  JOIN production_material_return_requests request ON request.id=requested.request_id
  JOIN stock_documents document ON document.id=request.id AND document.doc_type='WDRAW'
  WHERE requested.id=p_request AND request.id=p_doc AND requested.stock_document_item_id=p_item AND requested.qty_base=p_qty
    AND CASE WHEN p_kind='DIRECT_OUT' THEN requested.direct_transfer_item_id IS NOT NULL AND request.warehouse_id=p_warehouse
      AND p_qty=(SELECT COALESCE(SUM(qty_base),0) FROM production_workshop_material_custody_preparations prepared
          WHERE prepared.request_item_id=requested.id AND prepared.created_by::text=NULLIF(current_setting('app.actor_id',true),'')
            AND prepared.xmin::text=pg_current_xact_id()::text)
    WHEN p_kind IN('RETURN_REVERSE','DIRECT_IN_REVERSE') THEN document.warehouse_id=p_warehouse AND (
      p_qty=(SELECT COALESCE(SUM(move.qty_base),0) FROM production_workshop_material_custody_moves move
        JOIN production_workshop_custody_reverse_preparations prepared ON prepared.move_id=move.id
        WHERE move.request_item_id=requested.id AND prepared.created_by::text=NULLIF(current_setting('app.actor_id',true),'')
          AND prepared.xmin::text=pg_current_xact_id()::text)
      OR requested.issue_posting_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_moves WHERE request_item_id=requested.id)
        AND p_qty=(SELECT COALESCE(SUM(posting.qty_base),0) FROM production_material_stock_postings posting
          JOIN production_material_stock_events event ON event.id=posting.event_id AND event.event_type='GOOD_RETURN_REVERSE'
          WHERE event.stock_document_id=document.id AND posting.stock_document_item_id=p_item
            AND event.created_by::text=NULLIF(current_setting('app.actor_id',true),'') AND event.xmin::text=pg_current_xact_id()::text))
    ELSE FALSE END)
$$;
ALTER TABLE production_workshop_material_custody_moves ADD CONSTRAINT uq_workshop_custody_move_target UNIQUE(target_reservation_id);
ALTER TABLE production_workshop_material_custody_handoffs ADD CONSTRAINT uq_workshop_custody_handoff_target UNIQUE(target_reservation_id);

CREATE OR REPLACE FUNCTION fn_guard_material_stock_posting_physical_warehouse_v489()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
   JOIN stock_reservations reservation ON reservation.id=NEW.reservation_id
   WHERE item.id=NEW.stock_document_item_id AND (
     document.warehouse_id=reservation.warehouse_id OR (
       NEW.posting_type IN('GOOD_RETURN','GOOD_RETURN_REVERSE') AND document.doc_type='WDRAW'
       AND EXISTS(SELECT 1 FROM production_material_return_request_items requested
         JOIN production_material_return_receiving_confirmations receiving ON receiving.stock_document_id=requested.request_id
         JOIN production_material_stock_postings issue ON issue.id=requested.issue_posting_id AND issue.posting_type='ISSUE'
         WHERE requested.stock_document_item_id=item.id AND requested.request_id=document.id
           AND issue.reservation_id=reservation.id AND receiving.source_warehouse_id=reservation.warehouse_id
           AND receiving.received_warehouse_id=document.warehouse_id
           AND (NEW.posting_type='GOOD_RETURN' AND NEW.source_posting_id=issue.id
             OR NEW.posting_type='GOOD_RETURN_REVERSE' AND EXISTS(SELECT 1 FROM production_material_stock_postings returned
               WHERE returned.id=NEW.source_posting_id AND returned.posting_type='GOOD_RETURN'
                 AND returned.source_posting_id=issue.id AND returned.stock_document_item_id=item.id)))))) THEN
  RAISE EXCEPTION 'Material posting requires its actual warehouse or exact confirmed source-to-receiving custody'
    USING ERRCODE='23514',CONSTRAINT='material_stock_posting_physical_warehouse_guard';
 END IF;RETURN NEW;
END $$;

-- Exact WIP/transit value can cross a warehouse. Reversal restores the same
-- interval to its original owner; the receiving pool's average is never used.
CREATE FUNCTION fn_workshop_return_value_owner_allowed(p_event UUID,p_node UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM stock_value_events event
  JOIN stock_documents document ON document.id=event.source_doc_id AND document.doc_type='WDRAW'
  JOIN production_material_return_request_items requested ON requested.request_id=document.id
    AND requested.stock_document_item_id=event.source_item_id
  JOIN stock_value_nodes node ON node.id=p_node
  JOIN stock_value_events original ON original.id=event.position_store_reversal_of AND original.operation='POSITION_STORE'
    AND original.source_doc_id=event.source_doc_id AND original.source_item_id=event.source_item_id
  WHERE event.id=p_event AND event.operation='POSITION_STORE_REVERSE' AND event.source_doc_type='STOCK_DOC'
    AND (node.owner_kind='WIP' AND node.owner_id=requested.issue_posting_id
      OR node.owner_kind='IN_TRANSIT' AND node.owner_id=requested.stock_document_item_id AND requested.direct_transfer_item_id IS NOT NULL))
$$;
DO $value_return$
DECLARE definition TEXT;anchor TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_check_stock_value_reverse_transfer()'::regprocedure) INTO definition;
 anchor:='source.owner_kind<>''QUALITY_PASSED''';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Value custody interval guard changed before V619'; END IF;
 EXECUTE replace(definition,anchor,'(source.owner_kind<>''QUALITY_PASSED'' AND NOT fn_workshop_return_value_owner_allowed(NEW.event_id,source.id))');
 SELECT pg_get_functiondef('fn_check_stock_value_reverse_store()'::regprocedure) INTO definition;
 anchor:='posting.owner_kind=''QUALITY_PASSED''';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Value receipt reversal guard changed before V619'; END IF;
 EXECUTE replace(definition,anchor,'(posting.owner_kind=''QUALITY_PASSED'' OR fn_workshop_return_value_owner_allowed(NEW.id,posting.node_id))');
END $value_return$;

-- Every append-only custody fact participates in the existing controlled development reset.
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
 SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V619 missing business reset anchor'; END IF;
 EXECUTE replace(definition,anchor,'(''production_workshop_material_return_slices'', ''CLEAR''),(''production_workshop_material_custody_preparations'', ''CLEAR''),(''production_workshop_material_custody_moves'', ''CLEAR''),(''production_workshop_material_custody_reversals'', ''CLEAR''),(''production_workshop_material_custody_handoffs'', ''CLEAR''),(''production_workshop_custody_handoff_reversals'', ''CLEAR''),(''production_workshop_custody_reverse_preparations'', ''CLEAR''),(''production_workshop_return_preplan_events'', ''CLEAR''),'||anchor);
END;
$reset_policy$;

-- Exact consumption projection
-- Authoritative consumption changes are the signed material postings committed
-- by this transaction. Existing legacy opening differences are not rewritten or
-- silently certified. No historical posting scan and no caller-controlled GUC.
ALTER TABLE stock_reservations
 ADD COLUMN material_projection_tx_id XID8,
 ADD COLUMN material_projection_initial_consumed_qty NUMERIC(18,4);
ALTER TABLE production_material_stock_postings ADD COLUMN recorded_tx_id XID8;
CREATE INDEX idx_material_posting_reservation_tx ON production_material_stock_postings(reservation_id,recorded_tx_id)
 WHERE recorded_tx_id IS NOT NULL;

CREATE FUNCTION fn_capture_material_reservation_projection() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE current_tx XID8:=pg_current_xact_id();
BEGIN
 IF NEW.owner_type IS DISTINCT FROM 'PRODUCTION_MATERIAL_DEMAND' THEN
   NEW.material_projection_tx_id:=NULL;
   NEW.material_projection_initial_consumed_qty:=NULL;
   RETURN NEW;
 END IF;
 NEW.material_projection_tx_id:=current_tx;
 IF TG_OP='INSERT' THEN
   NEW.material_projection_initial_consumed_qty:=0;
 ELSIF OLD.material_projection_tx_id IS DISTINCT FROM current_tx THEN
   NEW.material_projection_initial_consumed_qty:=OLD.consumed_qty;
 ELSE
   -- The second UPDATE cannot replace the baseline captured by the first one.
   -- Savepoint rollback rolls these ordinary tuple fields back atomically too.
   NEW.material_projection_initial_consumed_qty:=OLD.material_projection_initial_consumed_qty;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00_capture_material_reservation_projection BEFORE INSERT OR UPDATE ON stock_reservations
FOR EACH ROW EXECUTE FUNCTION fn_capture_material_reservation_projection();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_00_capture_material_reservation_projection;

CREATE FUNCTION fn_stamp_material_posting_transaction() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 -- Always derive it from PostgreSQL, including for inserts that explicitly pass
 -- another transaction ID. The existing posting ledger remains append-only.
 NEW.recorded_tx_id:=pg_current_xact_id();
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00_stamp_material_posting_transaction BEFORE INSERT ON production_material_stock_postings
FOR EACH ROW EXECUTE FUNCTION fn_stamp_material_posting_transaction();
ALTER TABLE production_material_stock_postings ENABLE ALWAYS TRIGGER trg_00_stamp_material_posting_transaction;

CREATE FUNCTION fn_assert_material_consumed_projection(p_reservation UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE held stock_reservations%ROWTYPE; current_tx XID8:=pg_current_xact_id();
 posted_delta NUMERIC; projection_delta NUMERIC;
BEGIN
 SELECT * INTO held FROM stock_reservations WHERE id=p_reservation FOR UPDATE;
 IF NOT FOUND OR held.owner_type IS DISTINCT FROM 'PRODUCTION_MATERIAL_DEMAND' THEN RETURN; END IF;
 SELECT COALESCE(SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'GOOD_RETURN_REVERSE' THEN qty_base
     WHEN 'ISSUE_REVERSE' THEN -qty_base WHEN 'GOOD_RETURN' THEN -qty_base ELSE 0 END),0)
 INTO posted_delta FROM production_material_stock_postings
 WHERE reservation_id=held.id AND recorded_tx_id=current_tx;
 IF held.material_projection_tx_id=current_tx THEN
   IF held.material_projection_initial_consumed_qty IS NULL THEN
     RAISE EXCEPTION 'Material consumption transaction baseline is missing' USING ERRCODE='23514',
       CONSTRAINT='production_material_consumed_projection_guard';
   END IF;
   projection_delta:=held.consumed_qty-held.material_projection_initial_consumed_qty;
 ELSE
   -- New postings cannot alter a reservation that this transaction never touched.
   projection_delta:=0;
 END IF;
 IF projection_delta IS DISTINCT FROM posted_delta THEN
   RAISE EXCEPTION 'Material consumed quantity change must equal the same transaction exact ISSUE and return postings'
     USING ERRCODE='23514',CONSTRAINT='production_material_consumed_projection_guard';
 END IF;
END $$;

CREATE FUNCTION fn_check_material_consumed_projection() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='production_material_stock_postings' THEN
   PERFORM fn_assert_material_consumed_projection(NEW.reservation_id);
   RETURN NULL;
 END IF;
 PERFORM fn_assert_material_consumed_projection(NEW.id);
 -- V150's stock_reservations_production_lifecycle_chk already owns status/open
 -- quantity/deletion shape. This guard owns the missing posting conservation.
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_check_material_reservation_consumed_projection AFTER INSERT OR UPDATE ON stock_reservations
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_material_consumed_projection();
ALTER TABLE stock_reservations ENABLE ALWAYS TRIGGER trg_check_material_reservation_consumed_projection;
CREATE CONSTRAINT TRIGGER trg_check_material_posting_consumed_projection AFTER INSERT ON production_material_stock_postings
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_material_consumed_projection();
ALTER TABLE production_material_stock_postings ENABLE ALWAYS TRIGGER trg_check_material_posting_consumed_projection;

COMMENT ON COLUMN stock_reservations.material_projection_tx_id IS 'Database-owned last transaction stamp for material consumption delta validation; not a business event or caller authority';
COMMENT ON COLUMN stock_reservations.material_projection_initial_consumed_qty IS 'Database-owned consumed quantity at the first reservation write in that transaction; migration baseline is verified against the complete signed material ledger';
COMMENT ON COLUMN production_material_stock_postings.recorded_tx_id IS 'Database-owned top-level transaction ID, including savepoint writes; historical rows remain NULL';

-- Frozen equal units remain authoritative for historical MAKE receipts even
-- when the mutable goods master did not yet declare a base unit.
DO $make_frozen_unit$
DECLARE definition TEXT; needle TEXT:='EXISTS(SELECT 1 FROM goods base_goods WHERE base_goods.id=demand.goods_id AND base_goods.unit_id=demand.unit_id)';
BEGIN
 SELECT pg_get_functiondef('fn_assert_make_receipt_allocation(uuid)'::regprocedure) INTO definition;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V619 MAKE frozen-unit proof anchor changed'; END IF;
 EXECUTE replace(definition,needle,
   '(source_item.unit_id=demand.unit_id AND COALESCE(source_item.unit_rate,1)=1 OR '
    ||needle||')');
END $make_frozen_unit$;
-- A receipt allocation records original funding, not today's unconsumed stock.
-- Delegate identity/actual-leaf/qualified receipt validation to the authoritative
-- V163/V162 validators, including their V563 and V615 forward changes.
CREATE OR REPLACE FUNCTION fn_assert_receipt_reservation_coverage(p_reservation_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE capacity NUMERIC; allocated NUMERIC; allocation RECORD;
BEGIN
 SELECT reservation.qty INTO capacity FROM stock_reservations reservation
 WHERE reservation.id=p_reservation_id AND reservation.owner_type='PRODUCTION_MATERIAL_DEMAND'
   AND fn_receipt_reservation_history_valid(reservation.id) FOR UPDATE;
 SELECT COALESCE(SUM(allocated_qty),0) INTO allocated FROM production_material_receipt_allocations
 WHERE reservation_id=p_reservation_id AND status='EFFECTIVE';
 IF allocated>COALESCE(capacity,0) THEN
   RAISE EXCEPTION 'Receipt allocations exceed their original production stock reservation'
     USING ERRCODE='23514',CONSTRAINT='production_receipt_reservation_capacity_guard';
 END IF;
 FOR allocation IN SELECT id FROM production_material_receipt_allocations
   WHERE reservation_id=p_reservation_id AND status='EFFECTIVE' LOOP
   PERFORM fn_assert_purchase_receipt_allocation(allocation.id);
 END LOOP;
END $$;

CREATE OR REPLACE FUNCTION fn_assert_subcontract_receipt_reservation_coverage(p_reservation_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE capacity NUMERIC; allocated NUMERIC; allocation RECORD;
BEGIN
 SELECT reservation.qty INTO capacity FROM stock_reservations reservation
 WHERE reservation.id=p_reservation_id AND reservation.owner_type='PRODUCTION_MATERIAL_DEMAND'
   AND fn_receipt_reservation_history_valid(reservation.id) FOR UPDATE;
 SELECT COALESCE(SUM(allocated_qty),0) INTO allocated FROM production_material_subcontract_receipt_allocations
 WHERE reservation_id=p_reservation_id AND status='EFFECTIVE';
 IF allocated>COALESCE(capacity,0) THEN
   RAISE EXCEPTION 'Subcontract receipt allocations exceed their original reservation'
     USING ERRCODE='23514',CONSTRAINT='production_subcontract_receipt_reservation_capacity_guard';
 END IF;
 FOR allocation IN SELECT id FROM production_material_subcontract_receipt_allocations
   WHERE reservation_id=p_reservation_id AND status='EFFECTIVE' LOOP
   PERFORM fn_assert_subcontract_receipt_allocation(allocation.id);
 END LOOP;
END $$;

-- A legacy MAKE peg is converted once when a previously never-issued source
-- is formalized from private normal-warehouse custody. Preserve the original
-- technical FINISHED_IN; the real MOVE/HANDOFF proves its present leaf.
CREATE FUNCTION fn_workshop_return_receipt_allows(p_reservation UUID,p_receipt_item UUID,p_qty NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT p_qty>0 AND p_qty<=COALESCE(SUM(source.qty_base),0)
 FROM stock_reservations held
 JOIN production_workshop_direct_source_allocations source ON source.stock_reservation_id=held.id
 JOIN production_workshop_direct_transfer_items direct ON direct.id=source.transfer_item_id
 JOIN production_workshop_direct_transfers transfer ON transfer.id=direct.transfer_id
 JOIN stock_document_items receipt_item ON receipt_item.id=p_receipt_item
   AND receipt_item.source_daily_report_item_id=direct.source_report_item_id
 JOIN stock_documents receipt ON receipt.id=receipt_item.doc_id AND receipt.doc_type='FINISHED_IN'
   AND receipt.warehouse_id=transfer.line_side_warehouse_id
 WHERE held.id=p_reservation AND held.source_doc_type='WORKSHOP_RETURN_CUSTODY'
  AND held.owner_type='PRODUCTION_MATERIAL_DEMAND' AND held.owner_id=held.demand_id
  AND (EXISTS(SELECT 1 FROM production_workshop_material_custody_moves movement
       JOIN stock_movements physical ON physical.id=movement.received_movement_id AND physical.warehouse_id=held.warehouse_id
       WHERE movement.target_allocation_id=source.id AND movement.target_reservation_id=held.id
        AND movement.transfer_item_id=direct.id AND movement.target_demand_id=held.demand_id)
    OR EXISTS(SELECT 1 FROM production_workshop_material_custody_handoffs handoff
       JOIN production_workshop_material_custody_moves movement ON movement.target_allocation_id=handoff.source_allocation_id
       JOIN stock_movements physical ON physical.id=movement.received_movement_id AND physical.warehouse_id=held.warehouse_id
       WHERE handoff.target_allocation_id=source.id AND handoff.target_reservation_id=held.id
        AND movement.transfer_item_id=direct.id AND movement.target_demand_id=held.demand_id))
$$;
DO $custody_make_receipt$
DECLARE definition TEXT;needle TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_assert_make_receipt_allocation(uuid)'::regprocedure) INTO definition;
 needle:='receipt.warehouse_id = reservation.warehouse_id';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V619 MAKE receipt warehouse proof anchor changed'; END IF;
 EXECUTE replace(definition,needle,'(receipt.warehouse_id = reservation.warehouse_id OR fn_workshop_return_receipt_allows(reservation.id,receipt_item.id,allocation.allocated_qty))');
 SELECT pg_get_functiondef('fn_assert_make_reservation_capacity(uuid)'::regprocedure) INTO definition;
 needle:='warehouse.is_line_side AND (reservation.qty>reservation.released_qty';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V619 precise MAKE source capacity anchor changed'; END IF;
 EXECUTE replace(definition,needle,'fn_reservation_tracks_workshop_source(reservation.id) AND (reservation.qty>reservation.released_qty');
END $custody_make_receipt$;
-- Repeated exact-cost withdrawals use a non-owning identity chain. A source
-- keeps its original pool edge plus one reference edge; each reference keeps
-- one result-pool edge plus one next-reference edge. Fan-out stays <= 2.
ALTER TABLE stock_value_nodes ADD COLUMN reference_root_id UUID REFERENCES stock_value_nodes(id);
ALTER TABLE stock_value_nodes DROP CONSTRAINT stock_value_node_kind_v527;
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_node_kind_v619 CHECK(kind IN(
 'SOURCE','POOL','ISSUE_POSITION','RETURN_SOURCE','COST_RETURN_CURSOR','REVERSED_POOL_CURSOR','VALUE_REFERENCE'));
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_reference_shape CHECK(
 (kind='VALUE_REFERENCE')=(reference_root_id IS NOT NULL)
 AND (kind<>'VALUE_REFERENCE' OR (NOT active AND owner_kind IS NULL AND owner_id IS NULL AND movement_id IS NULL
   AND root_issue_id IS NULL AND return_head_id IS NULL AND adjustment_head_id IS NULL
   AND range_from=0 AND range_to=quantity_basis AND distributed_value_local=0)));
CREATE INDEX idx_stock_value_reference_root_sequence ON stock_value_nodes(reference_root_id,node_sequence DESC)
 WHERE kind='VALUE_REFERENCE';

CREATE FUNCTION fn_assert_stock_value_reference(p_node UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE reference stock_value_nodes%ROWTYPE; original stock_value_nodes%ROWTYPE;
 parent stock_value_nodes%ROWTYPE; expected_parent UUID; event stock_value_events%ROWTYPE;
 count_in BIGINT; count_pool BIGINT; count_next BIGINT;
BEGIN
 SELECT * INTO reference FROM stock_value_nodes WHERE id=p_node;
 IF reference.kind IS DISTINCT FROM 'VALUE_REFERENCE' THEN RETURN; END IF;
 SELECT * INTO original FROM stock_value_nodes WHERE id=reference.reference_root_id;
 SELECT * INTO event FROM stock_value_events WHERE id=reference.creation_event_id;
 SELECT count(*) INTO count_in FROM stock_value_edges WHERE child_node_id=reference.id;
 SELECT candidate.* INTO parent FROM stock_value_edges edge JOIN stock_value_nodes candidate ON candidate.id=edge.parent_node_id
   WHERE edge.child_node_id=reference.id AND edge.creation_event_id=reference.creation_event_id
     AND edge.interval_from=0 AND edge.interval_to=1 AND edge.denominator=1;
 SELECT id INTO expected_parent FROM stock_value_nodes
   WHERE reference_root_id=original.id AND kind='VALUE_REFERENCE' AND node_sequence<reference.node_sequence
   ORDER BY node_sequence DESC LIMIT 1;
 expected_parent:=COALESCE(expected_parent,original.id);
 SELECT count(*) FILTER(WHERE child.id=event.result_head_id AND child.kind='POOL'),
   count(*) FILTER(WHERE child.kind='VALUE_REFERENCE' AND child.reference_root_id=original.id)
 INTO count_pool,count_next FROM stock_value_edges edge JOIN stock_value_nodes child ON child.id=edge.child_node_id
 WHERE edge.parent_node_id=reference.id AND edge.interval_from=0 AND edge.interval_to=1 AND edge.denominator=1;
 IF original.id IS NULL OR original.kind NOT IN('SOURCE','POOL','RETURN_SOURCE')
    OR original.pool_id<>reference.pool_id OR original.quantity_basis<>reference.quantity_basis
    OR reference.active OR reference.owned_value_local<>0 OR count_in<>1
    OR parent.id IS DISTINCT FROM expected_parent OR parent.quantity_basis<>reference.quantity_basis
    OR parent.pool_id<>reference.pool_id OR event.operation<>'POSITION_STORE_REVERSE'
    OR NOT fn_is_workshop_material_value_store(event.position_store_reversal_of)
    OR count_pool<>1 OR count_next>1
    OR (SELECT count(*) FROM stock_value_edges WHERE parent_node_id=reference.id)<>count_pool+count_next THEN
  RAISE EXCEPTION 'Retained value must use one exact non-owning binary reference chain' USING ERRCODE='23514';
 END IF;
END $$;

CREATE FUNCTION fn_check_stock_value_reference() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE reference_id UUID;
BEGIN
 IF TG_TABLE_NAME='stock_value_nodes' THEN
  PERFORM fn_assert_stock_value_reference(NEW.id);
 ELSE
  FOR reference_id IN SELECT id FROM stock_value_nodes WHERE id IN(NEW.parent_node_id,NEW.child_node_id)
      AND kind='VALUE_REFERENCE' LOOP
   PERFORM fn_assert_stock_value_reference(reference_id);
  END LOOP;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_stock_value_reference_node AFTER INSERT ON stock_value_nodes
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(NEW.kind='VALUE_REFERENCE') EXECUTE FUNCTION fn_check_stock_value_reference();
CREATE CONSTRAINT TRIGGER trg_stock_value_reference_edge AFTER INSERT ON stock_value_edges
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_reference();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_reference_node;
ALTER TABLE stock_value_edges ENABLE ALWAYS TRIGGER trg_stock_value_reference_edge;

-- Source repricing rechecks node lifecycle too. Its second child is permitted
-- only for the proved identity-reference chain; arbitrary fan-out stays banned.
DO $reference_source_lifecycle$
DECLARE definition TEXT; anchor TEXT:='n.kind IN(''SOURCE'',''RETURN_SOURCE'') AND outgoing<>1';
BEGIN
 SELECT pg_get_functiondef('fn_check_stock_value_node_lifecycle()'::regprocedure) INTO definition;
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Source lifecycle contract changed before value references'; END IF;
 EXECUTE replace(definition,anchor,
  'n.kind IN(''SOURCE'',''RETURN_SOURCE'') AND NOT (outgoing=1 OR (outgoing=2 AND EXISTS('
  ||'SELECT 1 FROM stock_value_edges edge JOIN stock_value_nodes reference ON reference.id=edge.child_node_id '
  ||'WHERE edge.parent_node_id=n.id AND reference.kind=''VALUE_REFERENCE'' AND reference.reference_root_id=n.id)))');
END $reference_source_lifecycle$;

COMMENT ON COLUMN stock_value_nodes.reference_root_id IS 'Immutable original retained value component; reference nodes carry no owned quantity or money and preserve binary cost propagation';

-- Only exact workshop-material receipts use this additive-history withdrawal.
-- Later real inbound contributions remain whole DAG parents; no blended fraction.
CREATE FUNCTION fn_is_workshop_material_value_store(p_event UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM stock_value_events event
   JOIN production_material_return_request_items item ON item.request_id=event.source_doc_id
     AND item.stock_document_item_id=event.source_item_id
   JOIN stock_movements movement ON movement.id=event.movement_id
     AND movement.source_doc_type='STOCK_DOC' AND movement.source_doc_id=item.request_id
     AND movement.source_item_id=item.stock_document_item_id AND movement.direction=1
     AND movement.movement_type=CASE WHEN item.issue_posting_id IS NOT NULL THEN 6 ELSE 7 END
     AND movement.qty=item.qty_base
   WHERE event.id=p_event AND event.operation='POSITION_STORE' AND event.source_doc_type='STOCK_DOC')
$$;

CREATE FUNCTION fn_workshop_return_retained_value_nodes(p_current UUID,p_original UUID)
RETURNS TABLE(node_id UUID) LANGUAGE plpgsql STABLE AS $$
DECLARE original stock_value_events%ROWTYPE; cursor_node stock_value_nodes%ROWTYPE;
 cursor_event stock_value_events%ROWTYPE; current_id UUID:=p_current; parent_id UUID;
 found_source BOOLEAN:=FALSE; retained UUID[]:=ARRAY[]::UUID[]; visited UUID[]:=ARRAY[]::UUID[];
 edge RECORD; parents INTEGER; additions INTEGER; steps INTEGER:=0; identity_parent UUID;
BEGIN
 SELECT * INTO original FROM stock_value_events WHERE id=p_original;
 IF NOT fn_is_workshop_material_value_store(p_original) THEN
  RAISE EXCEPTION 'Only an exact workshop material receipt can retain later inbound value sources' USING ERRCODE='23514';
 END IF;
 WHILE current_id IS NOT NULL AND steps<1000 LOOP
  IF current_id=ANY(visited) THEN RAISE EXCEPTION 'Value ancestry contains a cycle' USING ERRCODE='23514'; END IF;
  visited:=array_append(visited,current_id);steps:=steps+1;
  SELECT * INTO cursor_node FROM stock_value_nodes WHERE id=current_id;
  SELECT * INTO cursor_event FROM stock_value_events WHERE id=cursor_node.creation_event_id;
  IF cursor_node.id IS NULL OR cursor_node.kind<>'POOL' OR cursor_node.pool_id<>original.pool_id THEN
   RAISE EXCEPTION 'Material receipt ancestry changed its physical pool' USING ERRCODE='23514';
  END IF;
  IF current_id<>original.result_head_id AND cursor_event.operation NOT IN('RECEIVE','POSITION_STORE','POSITION_STORE_REVERSE') THEN
   -- A proven fully cancelled issue is already an identity in the old contract.
   identity_parent:=fn_stock_value_completed_issue_return_parent(current_id);
   IF identity_parent IS NULL THEN
    RAISE EXCEPTION 'Original material receipt has later actual stock consumption; reverse that dependency first' USING ERRCODE='23514';
   END IF;
   current_id:=identity_parent;CONTINUE;
  END IF;
  IF cursor_event.id IS NULL OR cursor_event.result_head_id IS DISTINCT FROM current_id
     OR cursor_event.pool_id<>original.pool_id THEN
   RAISE EXCEPTION 'Material receipt ancestry has no exact pool event' USING ERRCODE='23514';
  END IF;
  IF cursor_event.operation IN('RECEIVE','POSITION_STORE') AND NOT EXISTS(
      SELECT 1 FROM stock_movements movement WHERE movement.id=cursor_event.movement_id
        AND movement.direction=1 AND movement.qty=cursor_event.qty_base) THEN
   RAISE EXCEPTION 'Only a real later inbound may retain an additive value contribution' USING ERRCODE='23514';
  END IF;
  parent_id:=NULL;parents:=0;additions:=0;
  FOR edge IN SELECT relation.*,parent.kind AS parent_kind,parent.pool_id AS parent_pool,
      component.id AS component_id,component.kind AS component_kind,component.pool_id AS component_pool
    FROM stock_value_edges relation JOIN stock_value_nodes parent ON parent.id=relation.parent_node_id
    JOIN stock_value_nodes component ON component.id=COALESCE(parent.reference_root_id,parent.id)
    WHERE relation.child_node_id=current_id ORDER BY relation.id LOOP
   IF edge.creation_event_id<>cursor_event.id OR edge.interval_from<>0 OR edge.interval_to<>1 OR edge.denominator<>1
      OR edge.parent_pool<>original.pool_id OR edge.component_pool<>original.pool_id
      OR edge.parent_kind NOT IN('POOL','SOURCE','RETURN_SOURCE','VALUE_REFERENCE')
      OR edge.component_kind NOT IN('POOL','SOURCE','RETURN_SOURCE') THEN
    RAISE EXCEPTION 'Consumed or fractional pool ancestry cannot be treated as an unused material receipt' USING ERRCODE='23514';
   END IF;
   IF edge.component_kind='POOL' THEN
    parents:=parents+1;parent_id:=edge.component_id;
   ELSE
    additions:=additions+1;
    IF cursor_event.operation IN('RECEIVE','POSITION_STORE') AND edge.component_id<>cursor_event.result_node_id THEN
     RAISE EXCEPTION 'A receipt must retain its own exact incoming value node' USING ERRCODE='23514';
    END IF;
    IF edge.component_id=original.result_node_id THEN
     IF found_source THEN RAISE EXCEPTION 'Original material value was counted twice' USING ERRCODE='23514'; END IF;
     found_source:=TRUE;
    ELSE
     IF edge.component_id=ANY(retained) THEN RAISE EXCEPTION 'Later inbound value was counted twice' USING ERRCODE='23514'; END IF;
     retained:=array_append(retained,edge.component_id);
    END IF;
   END IF;
  END LOOP;
  IF parents>1 OR (cursor_event.operation IN('RECEIVE','POSITION_STORE') AND additions<>1) THEN
   RAISE EXCEPTION 'An additive pool event must have one original predecessor and one incoming source' USING ERRCODE='23514';
  END IF;
  IF found_source THEN
   IF parent_id IS NOT NULL THEN retained:=array_append(retained,parent_id); END IF;
   RETURN QUERY SELECT unnest(retained);RETURN;
  END IF;
  current_id:=parent_id;
 END LOOP;
 RAISE EXCEPTION 'Original material receipt is not present in bounded unused value ancestry' USING ERRCODE='23514';
END $$;

CREATE FUNCTION fn_assert_workshop_material_value_store_reverse(p_event UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE reversed stock_value_events%ROWTYPE; original stock_value_events%ROWTYPE;
 archived stock_value_nodes%ROWTYPE; removed stock_value_nodes%ROWTYPE; next_pool stock_value_nodes%ROWTYPE;
 kept UUID[]; actual UUID[]; expected_qty NUMERIC; expected_value NUMERIC;
 parts BIGINT; part_qty NUMERIC; part_value NUMERIC;
BEGIN
 SELECT * INTO reversed FROM stock_value_events WHERE id=p_event;
 SELECT * INTO original FROM stock_value_events WHERE id=reversed.position_store_reversal_of;
 SELECT * INTO archived FROM stock_value_nodes WHERE id=reversed.result_node_id;
 SELECT * INTO next_pool FROM stock_value_nodes WHERE id=reversed.result_head_id;
 SELECT parent.* INTO removed FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
   WHERE edge.child_node_id=archived.id AND edge.creation_event_id=reversed.id;
 IF reversed.operation<>'POSITION_STORE_REVERSE' OR NOT fn_is_workshop_material_value_store(original.id)
    OR archived.id IS NULL OR removed.id IS NULL OR next_pool.id IS NULL
    OR original.pool_id<>reversed.pool_id OR original.qty_base<>reversed.qty_base
    OR original.source_doc_type IS DISTINCT FROM reversed.source_doc_type
    OR original.source_doc_id IS DISTINCT FROM reversed.source_doc_id
    OR original.source_item_id IS DISTINCT FROM reversed.source_item_id
    OR reversed.source_node_id<>original.result_node_id
    OR NOT fn_stock_value_stored_cost_reversible(original.result_node_id)
    OR archived.kind<>'REVERSED_POOL_CURSOR' OR archived.creation_event_id<>reversed.id OR archived.pool_id<>reversed.pool_id
    OR removed.kind<>'POOL' OR removed.active OR removed.quantity_basis<>reversed.qty_before
    OR archived.quantity_basis<>removed.quantity_basis OR archived.initial_known_value<>removed.basis_value_local
    OR NOT EXISTS(SELECT 1 FROM stock_movements movement WHERE movement.id=reversed.movement_id
       AND movement.direction=-1 AND movement.qty=original.qty_base
       AND movement.source_doc_type=original.source_doc_type AND movement.source_doc_id=original.source_doc_id
       AND movement.source_item_id=original.source_item_id)
    OR next_pool.kind<>'POOL' OR next_pool.creation_event_id<>reversed.id OR next_pool.pool_id<>reversed.pool_id
    OR (SELECT count(*) FROM stock_value_edges WHERE child_node_id=archived.id)<>1
    OR NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE child_node_id=archived.id AND parent_node_id=removed.id
       AND creation_event_id=reversed.id AND interval_from=0 AND interval_to=1 AND denominator=1) THEN
  RAISE EXCEPTION 'Workshop material withdrawal lost its exact original receipt or pool cursor' USING ERRCODE='23514';
 END IF;
 SELECT COALESCE(array_agg(node.id ORDER BY node.id),ARRAY[]::UUID[]),COALESCE(SUM(node.quantity_basis),0)
 INTO kept,expected_qty FROM fn_workshop_return_retained_value_nodes(removed.id,original.id) retained
 JOIN stock_value_nodes node ON node.id=retained.node_id;
 IF cardinality(kept)>0 THEN
  SELECT COALESCE(array_agg(parent.reference_root_id ORDER BY parent.reference_root_id),ARRAY[]::UUID[]),COALESCE(SUM(parent.basis_value_local),0)
  INTO actual,expected_value FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
  WHERE edge.child_node_id=next_pool.id;
  IF actual IS DISTINCT FROM kept OR EXISTS(SELECT 1 FROM stock_value_edges edge
      JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id WHERE edge.child_node_id=next_pool.id
      AND (edge.creation_event_id<>reversed.id OR edge.interval_from<>0 OR edge.interval_to<>1 OR edge.denominator<>1
        OR parent.kind<>'VALUE_REFERENCE' OR parent.creation_event_id<>reversed.id)) THEN
   RAISE EXCEPTION 'Withdrawal must retain every later inbound as its whole original value contribution' USING ERRCODE='23514';
  END IF;
 ELSE
  expected_value:=0;
  IF (SELECT count(*) FROM stock_value_edges WHERE child_node_id=next_pool.id)<>1 OR NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE child_node_id=next_pool.id
    AND parent_node_id=removed.id AND creation_event_id=reversed.id AND interval_from=0 AND interval_to=0
    AND denominator=removed.quantity_basis) THEN
   RAISE EXCEPTION 'An empty remaining pool must carry only its exact zero contribution' USING ERRCODE='23514';
  END IF;
 END IF;
 SELECT count(*),COALESCE(SUM(qty_base),0),COALESCE(SUM(initial_value_local),0) INTO parts,part_qty,part_value
 FROM stock_value_position_transfers WHERE event_id=reversed.id AND reversal_of_transfer_id IS NOT NULL;
 -- Zero/pending value has no monetary posting. Physical intervals and owners
 -- remain mandatory even then; never fabricate a zero money row as evidence.
 IF next_pool.quantity_basis<>expected_qty OR next_pool.initial_known_value<>expected_value
    OR expected_qty<>reversed.qty_before-reversed.qty_base
    OR removed.basis_value_local<>expected_value+reversed.known_value_local
    OR parts=0 OR parts>100 OR part_qty<>reversed.qty_base OR part_value<>reversed.known_value_local
    OR parts<>(SELECT count(*) FROM stock_value_position_transfers WHERE event_id=original.id)
    OR (reversed.known_value_local<>0 AND NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=reversed.id AND node_id=removed.id
       AND owner_kind='INVENTORY' AND amount_delta_local=-reversed.known_value_local))
    OR EXISTS(SELECT 1 FROM stock_value_position_transfers transfer WHERE transfer.event_id=reversed.id AND (
       NOT fn_workshop_return_value_owner_allowed(reversed.id,transfer.target_node_id)
       OR (transfer.initial_value_local<>0 AND NOT EXISTS(
         SELECT 1 FROM stock_value_postings posting WHERE posting.event_id=reversed.id AND posting.node_id=transfer.target_node_id
           AND posting.amount_delta_local=transfer.initial_value_local)))) THEN
  RAISE EXCEPTION 'Workshop withdrawal must restore original custody cost and preserve every later inbound' USING ERRCODE='23514';
 END IF;
END $$;

DO $material_return_after_inbound$
DECLARE definition TEXT; anchor TEXT:=E'BEGIN\n';
BEGIN
 SELECT pg_get_functiondef('fn_check_stock_value_reverse_store()'::regprocedure) INTO definition;
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Reverse-store validation entry changed before V619'; END IF;
 EXECUTE overlay(definition placing anchor||E'    IF NEW.operation=''POSITION_STORE_REVERSE'' AND fn_is_workshop_material_value_store(NEW.position_store_reversal_of) THEN\n        PERFORM fn_assert_workshop_material_value_store_reverse(NEW.id); RETURN NULL;\n    END IF;\n'
   from position(anchor IN definition) for length(anchor));
END $material_return_after_inbound$;


-- Actual warehouse authorization has one read contract. Every private holding
-- outside the planning main must carry the database-validated source proof.
CREATE FUNCTION fn_production_material_actual_warehouse_allows(p_demand UUID,p_actual UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM production_material_demands demand WHERE demand.id=p_demand AND NOT demand.is_deleted
   AND (fn_warehouse_same_main(demand.warehouse_id,p_actual) OR (
     SELECT COALESCE(bool_and(held.requires_qualified_origin),FALSE)
     FROM stock_reservations held WHERE held.demand_id=demand.id AND held.owner_type='PRODUCTION_MATERIAL_DEMAND'
       AND held.owner_id=demand.id AND held.warehouse_id=p_actual AND NOT held.is_deleted
       AND held.status IN(0,1) AND held.qty-held.released_qty>0)))
$$;

-- Follow immutable physical-custody grants to the original qualified formal
-- source. Never invent another FORMALIZE or infer origin from a SKU match.
CREATE FUNCTION fn_workshop_return_qualified_root(p_reservation UUID)
RETURNS UUID LANGUAGE sql STABLE AS $$
 WITH RECURSIVE chain(id,visited,depth) AS (
   SELECT p_reservation,ARRAY[p_reservation],0
   UNION ALL
   SELECT parent.source_id,chain.visited||parent.source_id,chain.depth+1
   FROM chain JOIN stock_reservations held ON held.id=chain.id AND held.source_doc_type='WORKSHOP_RETURN_CUSTODY'
   CROSS JOIN LATERAL (
     SELECT movement.source_reservation_id AS source_id FROM production_workshop_material_custody_moves movement
       WHERE movement.target_reservation_id=held.id
     UNION ALL
     SELECT source.stock_reservation_id FROM production_workshop_material_custody_handoffs handoff
       JOIN production_workshop_direct_source_allocations source ON source.id=handoff.source_allocation_id
       WHERE handoff.target_reservation_id=held.id) parent
   WHERE parent.source_id IS NOT NULL AND NOT parent.source_id=ANY(chain.visited) AND chain.depth<64
 ) SELECT held.id FROM chain JOIN stock_reservations held ON held.id=chain.id
   WHERE held.requires_qualified_origin AND held.source_doc_type IS DISTINCT FROM 'WORKSHOP_RETURN_CUSTODY'
   ORDER BY chain.depth LIMIT 1
$$;
CREATE FUNCTION fn_assert_workshop_qualified_custody(p_target UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE target stock_reservations%ROWTYPE;original stock_reservations%ROWTYPE;granted NUMERIC;
BEGIN
 SELECT * INTO STRICT target FROM stock_reservations WHERE id=p_target;
 SELECT * INTO original FROM stock_reservations WHERE id=fn_workshop_return_qualified_root(p_target);
 SELECT COALESCE(SUM(grant_row.qty),0) INTO granted FROM (
   SELECT qty_base AS qty FROM production_workshop_material_custody_moves WHERE target_reservation_id=p_target
   UNION ALL SELECT qty_base FROM production_workshop_material_custody_handoffs WHERE target_reservation_id=p_target) grant_row;
 IF original.id IS NULL OR target.source_doc_type IS DISTINCT FROM 'WORKSHOP_RETURN_CUSTODY'
   OR target.qty<>granted OR target.demand_id IS DISTINCT FROM original.demand_id
   OR target.goods_id IS DISTINCT FROM original.goods_id OR target.color_id IS DISTINCT FROM original.color_id
   OR NOT fn_warehouse_same_main(target.warehouse_id,original.warehouse_id) THEN
  RAISE EXCEPTION 'Returned material must retain its exact qualified source and actual warehouse scope'
   USING ERRCODE='23514',CONSTRAINT='qualified_origin_custody_coverage';
 END IF;
 PERFORM fn_assert_qualified_origin_formal_reservation(original.id);
 PERFORM fn_assert_workshop_custody_grants(target.id);
END $$;
DO $custody_qualified_origin_inheritance$
DECLARE definition TEXT;anchor TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_create_workshop_return_reservation(uuid,uuid,uuid,numeric,uuid,uuid,uuid,boolean)'::regprocedure) INTO definition;
 anchor:='created_at,updated_at,created_by,updated_by,is_deleted,lock_version)';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Custody reservation creation columns changed'; END IF;
 definition:=replace(definition,anchor,'created_at,updated_at,created_by,updated_by,is_deleted,lock_version,requires_qualified_origin)');
 anchor:='p_actor,p_actor,FALSE,0);';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Custody reservation creation values changed'; END IF;
 definition:=replace(definition,anchor,'p_actor,p_actor,FALSE,0,formal AND COALESCE(original.requires_qualified_origin,FALSE));');
 EXECUTE definition;
 SELECT pg_get_functiondef('fn_assert_qualified_origin_formal_reservation(uuid)'::regprocedure) INTO definition;
 anchor:='IF NOT FOUND OR NOT target.requires_qualified_origin THEN RETURN; END IF;';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Qualified source validation entry changed'; END IF;
 EXECUTE replace(definition,anchor,anchor||E'\n    IF target.source_doc_type=''WORKSHOP_RETURN_CUSTODY'' THEN PERFORM fn_assert_workshop_qualified_custody(target.id); RETURN; END IF;');
END $custody_qualified_origin_inheritance$;

-- A warehouse return carries already-owned stock, not a new draw on the public
-- safety buffer. Read the exact grant, including its physical destination.
CREATE FUNCTION fn_workshop_custody_committed_qty(p_target UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT COALESCE(MAX(GREATEST(held.qty-held.released_qty,0)),0)
 FROM stock_reservations held
 WHERE held.id=p_target AND held.owner_type='PRODUCTION_MATERIAL_DEMAND' AND held.owner_id=held.demand_id
   AND held.source_doc_type='WORKSHOP_RETURN_CUSTODY' AND NOT held.is_deleted AND held.status IN(0,1)
   AND (EXISTS(SELECT 1 FROM production_workshop_material_custody_moves movement
       JOIN production_material_return_request_items item ON item.id=movement.request_item_id AND item.request_id=held.source_doc_id
       JOIN stock_movements received ON received.id=movement.received_movement_id
         AND received.warehouse_id=held.warehouse_id AND received.goods_id=held.goods_id
         AND received.color_id IS NOT DISTINCT FROM held.color_id AND received.direction=1
       WHERE movement.target_reservation_id=held.id AND movement.target_demand_id=held.demand_id AND movement.qty_base=held.qty
         AND NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_reversals reversed WHERE reversed.move_id=movement.id))
     OR EXISTS(SELECT 1 FROM production_workshop_material_custody_handoffs handoff
       JOIN production_workshop_material_custody_moves movement ON movement.target_allocation_id=handoff.source_allocation_id
       JOIN production_material_return_request_items item ON item.id=movement.request_item_id AND item.request_id=held.source_doc_id
       JOIN stock_movements received ON received.id=movement.received_movement_id
         AND received.warehouse_id=held.warehouse_id AND received.goods_id=held.goods_id
         AND received.color_id IS NOT DISTINCT FROM held.color_id AND received.direction=1
       WHERE handoff.target_reservation_id=held.id AND movement.target_demand_id=held.demand_id AND handoff.qty_base=held.qty
         AND NOT EXISTS(SELECT 1 FROM production_workshop_custody_handoff_reversals reversed WHERE reversed.handoff_id=handoff.id)
         AND NOT EXISTS(SELECT 1 FROM production_workshop_material_custody_reversals reversed WHERE reversed.move_id=movement.id)))
$$;
DO $private_custody_budget$
DECLARE definition TEXT;anchor TEXT:='qualified:=fn_production_qualified_formal_qty(target.id);';
BEGIN
 SELECT pg_get_functiondef('fn_check_main_warehouse_public_stock_budget()'::regprocedure) INTO definition;
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Private supply budget definition changed'; END IF;
 EXECUTE replace(definition,anchor,'qualified:=GREATEST(fn_production_qualified_formal_qty(target.id),fn_workshop_custody_committed_qty(target.id));');
END $private_custody_budget$;

-- Source-specific process use is immutable. A later return counter can restore
-- unused material, but cannot decide again which earlier source was consumed.
ALTER TABLE production_workshop_direct_source_events
 ADD COLUMN settlement_posting_id UUID REFERENCES production_material_settlement_postings(id),
 ADD COLUMN issue_source_event_id UUID REFERENCES production_workshop_direct_source_events(id);
DO $source_settlement_shapes$
DECLARE checked RECORD;
BEGIN
 FOR checked IN SELECT conname FROM pg_constraint
   WHERE conrelid='production_workshop_direct_source_events'::regclass AND contype='c'
     AND (pg_get_constraintdef(oid) LIKE '%event_type%' OR pg_get_constraintdef(oid) LIKE '%stock_posting_id%'
       OR pg_get_constraintdef(oid) LIKE '%counter_event_id%') LOOP
   EXECUTE format('ALTER TABLE production_workshop_direct_source_events DROP CONSTRAINT %I',checked.conname);
 END LOOP;
END $source_settlement_shapes$;
ALTER TABLE production_workshop_direct_source_events
 ADD CONSTRAINT workshop_source_event_kind CHECK(event_type IN(
   'ISSUE','ISSUE_REVERSE','GOOD_RETURN','GOOD_RETURN_REVERSE','RELEASE','RESTORE',
   'CONSUMED','APPROVED_LOSS','LEGAL_WIP','CONSUMED_REVERSE','APPROVED_LOSS_REVERSE','LEGAL_WIP_REVERSE')),
 ADD CONSTRAINT workshop_source_event_posting_shape CHECK(
   (event_type IN('ISSUE','ISSUE_REVERSE','GOOD_RETURN','GOOD_RETURN_REVERSE') AND stock_posting_id IS NOT NULL AND settlement_posting_id IS NULL AND issue_source_event_id IS NULL)
   OR (event_type IN('RELEASE','RESTORE') AND stock_posting_id IS NULL AND settlement_posting_id IS NULL AND issue_source_event_id IS NULL)
   OR (event_type IN('CONSUMED','APPROVED_LOSS','LEGAL_WIP','CONSUMED_REVERSE','APPROVED_LOSS_REVERSE','LEGAL_WIP_REVERSE')
     AND stock_posting_id IS NULL AND settlement_posting_id IS NOT NULL AND issue_source_event_id IS NOT NULL)),
 ADD CONSTRAINT workshop_source_event_counter_shape CHECK(
   (event_type IN('ISSUE','RELEASE') AND counter_event_id IS NULL)
   OR (event_type NOT IN('ISSUE','RELEASE') AND counter_event_id IS NOT NULL));
CREATE UNIQUE INDEX uq_workshop_source_settlement_slice ON production_workshop_direct_source_events(settlement_posting_id,issue_source_event_id)
 INCLUDE(source_allocation_id,counter_event_id,event_type,qty_base) WHERE settlement_posting_id IS NOT NULL;
CREATE INDEX idx_workshop_source_settled_issue ON production_workshop_direct_source_events(issue_source_event_id,event_type)
 INCLUDE(qty_base) WHERE issue_source_event_id IS NOT NULL;

CREATE OR REPLACE FUNCTION fn_workshop_source_issue_open(p_event UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT issued.qty_base
   -COALESCE((SELECT SUM(outflow.qty_base) FROM production_workshop_direct_source_events outflow
     WHERE outflow.counter_event_id=issued.id AND outflow.event_type IN('ISSUE_REVERSE','GOOD_RETURN')),0)
   +COALESCE((SELECT SUM(back.qty_base) FROM production_workshop_direct_source_events returned
     JOIN production_workshop_direct_source_events back ON back.counter_event_id=returned.id AND back.event_type='GOOD_RETURN_REVERSE'
     WHERE returned.counter_event_id=issued.id AND returned.event_type='GOOD_RETURN'),0)
   -COALESCE((SELECT SUM(CASE WHEN consumed.event_type IN('CONSUMED','APPROVED_LOSS','LEGAL_WIP') THEN consumed.qty_base ELSE -consumed.qty_base END)
     FROM production_workshop_direct_source_events consumed WHERE consumed.issue_source_event_id=issued.id),0)
 FROM production_workshop_direct_source_events issued WHERE issued.id=p_event AND issued.event_type='ISSUE'
$$;

CREATE OR REPLACE FUNCTION fn_guard_workshop_direct_source_event() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE allocation production_workshop_direct_source_allocations%ROWTYPE;
 posting production_material_stock_postings%ROWTYPE;
 counter production_workshop_direct_source_events%ROWTYPE;
 settlement_record production_material_settlement_postings%ROWTYPE;
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Workshop direct source events are append-only' USING ERRCODE='55000'; END IF;
 SELECT * INTO allocation FROM production_workshop_direct_source_allocations WHERE id=NEW.source_allocation_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Source event allocation is missing' USING ERRCODE='23514'; END IF;
 PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=allocation.transfer_item_id FOR UPDATE;
 IF NEW.counter_event_id IS NOT NULL THEN
   SELECT * INTO counter FROM production_workshop_direct_source_events WHERE id=NEW.counter_event_id;
   IF NOT FOUND OR counter.source_allocation_id<>NEW.source_allocation_id THEN
     RAISE EXCEPTION 'Source reversal must retain its exact original allocation and event' USING ERRCODE='23514';
   END IF;
 END IF;
 IF NEW.settlement_posting_id IS NOT NULL THEN
   SELECT * INTO settlement_record FROM production_material_settlement_postings WHERE id=NEW.settlement_posting_id;
   IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM production_material_stock_postings issued
     JOIN production_workshop_direct_source_events source ON source.stock_posting_id=issued.id AND source.event_type='ISSUE'
     WHERE issued.id=settlement_record.issue_posting_id AND issued.reservation_id=allocation.stock_reservation_id
       AND source.id=NEW.issue_source_event_id AND source.source_allocation_id=NEW.source_allocation_id)
     OR (NOT NEW.historical AND NEW.created_by IS DISTINCT FROM settlement_record.created_by)
     OR (settlement_record.source_posting_id IS NULL AND (NEW.event_type<>settlement_record.settlement_type
       OR counter.id<>NEW.issue_source_event_id OR counter.event_type<>'ISSUE'))
     OR (settlement_record.source_posting_id IS NOT NULL AND (NEW.event_type<>settlement_record.settlement_type||'_REVERSE'
       OR counter.event_type<>settlement_record.settlement_type OR counter.settlement_posting_id IS DISTINCT FROM settlement_record.source_posting_id
       OR counter.issue_source_event_id IS DISTINCT FROM NEW.issue_source_event_id)) THEN
     RAISE EXCEPTION 'Source settlement must retain the exact material settlement, ISSUE slice and original counter' USING ERRCODE='23514';
   END IF;
   RETURN NEW;
 END IF;
 IF NEW.counter_event_id IS NOT NULL AND counter.event_type<>(CASE NEW.event_type WHEN 'RESTORE' THEN 'RELEASE'
     WHEN 'GOOD_RETURN_REVERSE' THEN 'GOOD_RETURN' ELSE 'ISSUE' END) THEN
   RAISE EXCEPTION 'Source reversal must retain its exact original allocation and event' USING ERRCODE='23514';
 END IF;
 IF NEW.stock_posting_id IS NOT NULL THEN
   SELECT * INTO posting FROM production_material_stock_postings WHERE id=NEW.stock_posting_id;
   IF NOT FOUND OR posting.reservation_id<>allocation.stock_reservation_id OR posting.posting_type<>NEW.event_type
     OR (NEW.event_type<>'ISSUE' AND counter.stock_posting_id IS DISTINCT FROM posting.source_posting_id) THEN
     RAISE EXCEPTION 'Source event must match the exact material posting and original posting' USING ERRCODE='23514';
   END IF;
 END IF;
 RETURN NEW;
END $$;

CREATE FUNCTION fn_record_workshop_source_settlement(p_settlement UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE settled production_material_settlement_postings%ROWTYPE; held UUID; part RECORD;
 remaining NUMERIC; take NUMERIC; existing NUMERIC; kind TEXT;
BEGIN
 SELECT * INTO settled FROM production_material_settlement_postings WHERE id=p_settlement;
 IF NOT FOUND THEN RAISE EXCEPTION 'Material settlement posting is missing' USING ERRCODE='23514'; END IF;
 SELECT reservation_id INTO held FROM production_material_stock_postings WHERE id=settled.issue_posting_id;
 IF NOT fn_reservation_tracks_workshop_source(held) THEN RETURN; END IF;
 PERFORM 1 FROM stock_reservations WHERE id=held FOR UPDATE;
 PERFORM fn_lock_workshop_source_rows(held);
 SELECT SUM(qty_base) INTO existing FROM production_workshop_direct_source_events WHERE settlement_posting_id=settled.id;
 IF existing IS NOT NULL THEN
   IF existing<>settled.qty_base THEN RAISE EXCEPTION 'Partial source settlement replay is not permitted' USING ERRCODE='23514'; END IF;
   RETURN;
 END IF;
 remaining:=settled.qty_base;
 kind:=settled.settlement_type||CASE WHEN settled.source_posting_id IS NULL THEN '' ELSE '_REVERSE' END;
 IF settled.source_posting_id IS NULL THEN
   FOR part IN SELECT source.id,source.source_allocation_id,fn_workshop_source_issue_open(source.id) AS available
     FROM production_workshop_direct_source_events source
     JOIN production_workshop_direct_source_allocations allocation ON allocation.id=source.source_allocation_id
     WHERE source.stock_posting_id=settled.issue_posting_id AND source.event_type='ISSUE'
     ORDER BY allocation.allocation_no,source.event_no LOOP
     take:=LEAST(remaining,GREATEST(part.available,0));IF take<=0 THEN CONTINUE; END IF;
     INSERT INTO production_workshop_direct_source_events(source_allocation_id,settlement_posting_id,issue_source_event_id,counter_event_id,event_type,qty_base,created_by)
     VALUES(part.source_allocation_id,settled.id,part.id,part.id,kind,take,settled.created_by);
     remaining:=remaining-take;EXIT WHEN remaining=0;
   END LOOP;
 ELSE
   FOR part IN SELECT source.id,source.source_allocation_id,source.issue_source_event_id,
       source.qty_base-COALESCE((SELECT SUM(reversed.qty_base) FROM production_workshop_direct_source_events reversed
         WHERE reversed.counter_event_id=source.id AND reversed.event_type=kind),0) AS available
     FROM production_workshop_direct_source_events source
     WHERE source.settlement_posting_id=settled.source_posting_id AND source.event_type=settled.settlement_type
     ORDER BY source.event_no LOOP
     take:=LEAST(remaining,GREATEST(part.available,0));IF take<=0 THEN CONTINUE; END IF;
     INSERT INTO production_workshop_direct_source_events(source_allocation_id,settlement_posting_id,issue_source_event_id,counter_event_id,event_type,qty_base,created_by)
     VALUES(part.source_allocation_id,settled.id,part.issue_source_event_id,part.id,kind,take,settled.created_by);
     remaining:=remaining-take;EXIT WHEN remaining=0;
   END LOOP;
 END IF;
 IF remaining<>0 THEN RAISE EXCEPTION 'Material settlement lacks exact unused workshop source slices: %, missing %',settled.id,remaining USING ERRCODE='23514'; END IF;
END $$;

CREATE FUNCTION fn_assert_workshop_source_settlement(p_settlement UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE settled production_material_settlement_postings%ROWTYPE; held UUID;
BEGIN
 SELECT * INTO settled FROM production_material_settlement_postings WHERE id=p_settlement;
 SELECT reservation_id INTO held FROM production_material_stock_postings WHERE id=settled.issue_posting_id;
 IF NOT fn_reservation_tracks_workshop_source(held) THEN RETURN; END IF;
 IF settled.qty_base IS DISTINCT FROM (SELECT COALESCE(SUM(qty_base),0) FROM production_workshop_direct_source_events WHERE settlement_posting_id=settled.id) THEN
   RAISE EXCEPTION 'Every workshop material settlement requires complete exact source coverage' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM production_workshop_direct_source_events original
   WHERE original.settlement_posting_id=COALESCE(settled.source_posting_id,settled.id)
     AND original.event_type IN('CONSUMED','APPROVED_LOSS','LEGAL_WIP')
     AND original.qty_base<(SELECT COALESCE(SUM(reversed.qty_base),0) FROM production_workshop_direct_source_events reversed
       WHERE reversed.counter_event_id=original.id AND reversed.event_type=original.event_type||'_REVERSE')) THEN
   RAISE EXCEPTION 'A source settlement counter exceeds its exact original slice' USING ERRCODE='23514';
 END IF;
END $$;
CREATE FUNCTION fn_capture_workshop_source_settlement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN PERFORM fn_record_workshop_source_settlement(NEW.id);RETURN NULL;END $$;
CREATE FUNCTION fn_check_workshop_source_settlement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='production_material_settlement_postings' THEN
   PERFORM fn_assert_workshop_source_settlement(NEW.id);
 ELSE
   PERFORM fn_assert_workshop_source_settlement(NEW.settlement_posting_id);
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER trg_00_workshop_source_settlement AFTER INSERT ON production_material_settlement_postings
FOR EACH ROW EXECUTE FUNCTION fn_capture_workshop_source_settlement();
ALTER TABLE production_material_settlement_postings ENABLE ALWAYS TRIGGER trg_00_workshop_source_settlement;
CREATE CONSTRAINT TRIGGER trg_check_workshop_source_settlement AFTER INSERT ON production_material_settlement_postings
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_workshop_source_settlement();
ALTER TABLE production_material_settlement_postings ENABLE ALWAYS TRIGGER trg_check_workshop_source_settlement;
CREATE CONSTRAINT TRIGGER trg_check_workshop_source_settlement_event AFTER INSERT ON production_workshop_direct_source_events
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(NEW.settlement_posting_id IS NOT NULL)
EXECUTE FUNCTION fn_check_workshop_source_settlement();
ALTER TABLE production_workshop_direct_source_events ENABLE ALWAYS TRIGGER trg_check_workshop_source_settlement_event;

-- The preflight permits only mathematically unique old assignments: one source,
-- or an entire multi-source ISSUE and full counters. Never infer a partial mix.
INSERT INTO production_workshop_direct_source_events(source_allocation_id,settlement_posting_id,issue_source_event_id,counter_event_id,event_type,qty_base,historical)
SELECT source.source_allocation_id,settled.id,source.id,source.id,settled.settlement_type,
 CASE WHEN (SELECT COUNT(*) FROM production_workshop_direct_source_events part WHERE part.stock_posting_id=settled.issue_posting_id AND part.event_type='ISSUE')=1
   THEN settled.qty_base ELSE source.qty_base END,TRUE
FROM production_material_settlement_postings settled
JOIN production_workshop_direct_source_events source ON source.stock_posting_id=settled.issue_posting_id AND source.event_type='ISSUE'
WHERE settled.source_posting_id IS NULL;
INSERT INTO production_workshop_direct_source_events(source_allocation_id,settlement_posting_id,issue_source_event_id,counter_event_id,event_type,qty_base,historical)
SELECT source.source_allocation_id,settled.id,source.issue_source_event_id,source.id,settled.settlement_type||'_REVERSE',
 CASE WHEN (SELECT COUNT(*) FROM production_workshop_direct_source_events part WHERE part.settlement_posting_id=settled.source_posting_id)=1
   THEN settled.qty_base ELSE source.qty_base END,TRUE
FROM production_material_settlement_postings settled
JOIN production_workshop_direct_source_events source ON source.settlement_posting_id=settled.source_posting_id
WHERE settled.source_posting_id IS NOT NULL;

COMMENT ON COLUMN production_workshop_direct_source_events.settlement_posting_id IS 'Exact actual process use, extra loss or legal-WIP posting; its source slices cannot be reclassified by later stock return counters';
COMMENT ON COLUMN production_workshop_direct_source_events.issue_source_event_id IS 'Original ISSUE source slice for indexed net settlement availability; reversals preserve this UUID';
