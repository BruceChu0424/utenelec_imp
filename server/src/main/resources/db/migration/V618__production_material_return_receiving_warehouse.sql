-- The original ISSUE identifies custody and ownership. Warehouse staff decide
-- the ordinary operational leaf where the current workshop's surplus arrives.
CREATE TABLE production_material_return_receiving_confirmations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stock_document_id UUID NOT NULL UNIQUE REFERENCES stock_documents(id),
    return_request_id UUID NOT NULL UNIQUE REFERENCES production_material_return_requests(id),
    source_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    received_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    previous_warehouse_id UUID REFERENCES warehouses(id),
    idempotency_key VARCHAR(128) NOT NULL CHECK(idempotency_key ~ '^[A-Za-z0-9._:-]{8,128}$'),
    request_hash CHAR(64) NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK(stock_document_id=return_request_id),
    UNIQUE(created_by,idempotency_key)
);

ALTER TABLE production_material_return_request_items ALTER COLUMN issue_posting_id DROP NOT NULL;
ALTER TABLE production_material_return_request_items ADD COLUMN direct_transfer_item_id UUID REFERENCES production_workshop_direct_transfer_items(id);
ALTER TABLE production_material_return_request_items ADD CONSTRAINT material_return_exactly_one_source
    CHECK(num_nonnulls(issue_posting_id,direct_transfer_item_id)=1);
CREATE UNIQUE INDEX uq_material_return_request_direct_source
    ON production_material_return_request_items(request_id,direct_transfer_item_id) WHERE direct_transfer_item_id IS NOT NULL;

ALTER TABLE production_execution_segment_events
    ADD COLUMN receiving_confirmation_id UUID REFERENCES production_material_return_receiving_confirmations(id),
    ADD COLUMN receiving_direction SMALLINT CHECK(receiving_direction IN (1,-1)),
    ADD COLUMN counter_event_id UUID REFERENCES production_execution_segment_events(id);
ALTER TABLE production_execution_segment_events DROP CONSTRAINT production_execution_segment_events_action_check;
ALTER TABLE production_execution_segment_events ADD CONSTRAINT production_execution_segment_events_action_check CHECK(action IN(
    'ASSIGNMENT','DISPATCH','START','CANCEL','REVERSE','REOPEN_COMPLETION','RELEASE_DEFER','AUTO_START_ON_REPORT',
    'RECHECK_MATERIAL','DRAW_REQUEST','START_CONTINUOUS','ROUTE_CONFIRMED','MATERIAL_RETURN_DRAW_REDUCE','MATERIAL_RETURN_DRAW_RESTORE'));
ALTER TABLE production_execution_segment_events DROP CONSTRAINT production_draw_quantities_shape_chk;
ALTER TABLE production_execution_segment_events ADD CONSTRAINT production_draw_quantities_shape_chk CHECK(draw_item_quantities IS NULL OR
    (action IN('DRAW_REQUEST','MATERIAL_RETURN_DRAW_REDUCE','MATERIAL_RETURN_DRAW_RESTORE') AND jsonb_typeof(draw_item_quantities)='object' AND draw_item_quantities<>'{}'::jsonb));
ALTER TABLE production_execution_segment_events DROP CONSTRAINT production_execution_draw_request_shape_chk;
ALTER TABLE production_execution_segment_events ADD CONSTRAINT production_execution_draw_request_shape_chk CHECK(
    (action IN('DRAW_REQUEST','MATERIAL_RETURN_DRAW_REDUCE','MATERIAL_RETURN_DRAW_RESTORE') AND draw_document_ids IS NOT NULL
      AND cardinality(draw_document_ids)>0 AND array_position(draw_document_ids,NULL) IS NULL AND created_by IS NOT NULL
      AND resulting_version=expected_version+CASE WHEN action='DRAW_REQUEST' THEN 1 ELSE 0 END)
    OR (action NOT IN('DRAW_REQUEST','MATERIAL_RETURN_DRAW_REDUCE','MATERIAL_RETURN_DRAW_RESTORE') AND draw_document_ids IS NULL));
ALTER TABLE production_execution_segment_events ADD CONSTRAINT material_return_draw_proof_shape CHECK(
    (action IN('MATERIAL_RETURN_DRAW_REDUCE','MATERIAL_RETURN_DRAW_RESTORE') AND receiving_confirmation_id IS NOT NULL
      AND receiving_direction IS NOT NULL AND draw_item_quantities IS NOT NULL
      AND ((action='MATERIAL_RETURN_DRAW_RESTORE' AND counter_event_id IS NOT NULL)
        OR (action='MATERIAL_RETURN_DRAW_REDUCE' AND counter_event_id IS NULL)))
    OR (action NOT IN('MATERIAL_RETURN_DRAW_REDUCE','MATERIAL_RETURN_DRAW_RESTORE') AND receiving_confirmation_id IS NULL
      AND receiving_direction IS NULL AND counter_event_id IS NULL));
CREATE UNIQUE INDEX uq_material_return_draw_event ON production_execution_segment_events(
    execution_segment_id,receiving_confirmation_id,receiving_direction,action) WHERE receiving_confirmation_id IS NOT NULL;
CREATE INDEX idx_material_return_draw_documents ON production_execution_segment_events USING gin(draw_document_ids)
    WHERE receiving_confirmation_id IS NOT NULL;

CREATE FUNCTION fn_production_draw_item_effective_qty(p_item UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT item.qty-COALESCE((SELECT SUM(CASE event.action WHEN 'MATERIAL_RETURN_DRAW_REDUCE'
          THEN (event.draw_item_quantities->>item.id::text)::numeric
          WHEN 'MATERIAL_RETURN_DRAW_RESTORE' THEN -(event.draw_item_quantities->>item.id::text)::numeric ELSE 0 END)
        FROM production_execution_segment_events event WHERE event.receiving_confirmation_id IS NOT NULL
          AND event.draw_document_ids @> ARRAY[item.doc_id] AND event.draw_item_quantities ? item.id::text),0)
    FROM stock_document_items item WHERE item.id=p_item AND NOT item.is_deleted;
$$;

CREATE FUNCTION fn_guard_material_return_draw_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE entry RECORD; remaining NUMERIC; budget NUMERIC; allowed_warehouse UUID; linked production_material_return_receiving_confirmations%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN
        IF OLD.receiving_confirmation_id IS NOT NULL OR (TG_OP='UPDATE' AND NEW.receiving_confirmation_id IS NOT NULL) THEN
            RAISE EXCEPTION 'Material return DRAW adjustments are append-only' USING ERRCODE='55000';
        END IF;
        IF TG_OP='DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    IF NEW.action NOT IN('MATERIAL_RETURN_DRAW_REDUCE','MATERIAL_RETURN_DRAW_RESTORE') THEN
        IF NEW.receiving_confirmation_id IS NOT NULL OR NEW.receiving_direction IS NOT NULL OR NEW.counter_event_id IS NOT NULL THEN
            RAISE EXCEPTION 'Receiving proof is reserved for exact DRAW remainder adjustment' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    SELECT * INTO linked FROM production_material_return_receiving_confirmations WHERE id=NEW.receiving_confirmation_id;
    IF linked.id IS NULL OR NEW.receiving_direction IS NULL OR NEW.draw_item_quantities IS NULL
       OR NEW.created_by::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')
       OR NOT EXISTS(SELECT 1 FROM production_material_return_requests request WHERE request.id=linked.return_request_id
          AND request.execution_segment_id=NEW.execution_segment_id) THEN
        RAISE EXCEPTION 'DRAW adjustment requires the exact material return task and receiving proof' USING ERRCODE='23514';
    END IF;
    IF NEW.action='MATERIAL_RETURN_DRAW_RESTORE' THEN
        IF NEW.receiving_direction<>-1 OR NOT EXISTS(SELECT 1 FROM production_execution_segment_events original
           WHERE original.id=NEW.counter_event_id AND original.action='MATERIAL_RETURN_DRAW_REDUCE'
             AND original.receiving_confirmation_id=NEW.receiving_confirmation_id AND original.receiving_direction=1
             AND original.draw_item_quantities=NEW.draw_item_quantities AND original.draw_document_ids=NEW.draw_document_ids) THEN
            RAISE EXCEPTION 'DRAW restoration must counter its original exact receiving adjustment' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.counter_event_id IS NOT NULL THEN RAISE EXCEPTION 'DRAW reduction cannot counter another event' USING ERRCODE='23514'; END IF;
    allowed_warehouse:=CASE WHEN NEW.receiving_direction=1 THEN linked.source_warehouse_id ELSE linked.received_warehouse_id END;
    FOR entry IN SELECT key,value FROM jsonb_each(NEW.draw_item_quantities) LOOP
        IF jsonb_typeof(entry.value)<>'number' OR entry.value::text::numeric<=0
          OR entry.value::text::numeric<>round(entry.value::text::numeric,4) THEN
            RAISE EXCEPTION 'DRAW remainder adjustments use positive exact original document units' USING ERRCODE='23514';
        END IF;
        SELECT fn_production_draw_item_effective_qty(item.id)-COALESCE(item.issued_qty,0) INTO remaining
        FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
        JOIN production_planning_package_document_items mapping ON mapping.document_item_id=item.id AND mapping.document_type='DRAW'
        JOIN production_material_demands demand ON demand.id=mapping.demand_id AND demand.execution_segment_id=NEW.execution_segment_id
        WHERE item.id=entry.key::uuid AND NOT item.is_deleted AND document.doc_type='DRAW' AND document.status IN(0,1)
          AND NOT document.is_deleted AND document.warehouse_id=allowed_warehouse AND document.id=ANY(NEW.draw_document_ids);
        IF NOT FOUND OR entry.value::text::numeric>remaining THEN
            RAISE EXCEPTION 'DRAW adjustment exceeds this exact task and warehouse unissued remainder' USING ERRCODE='23514';
        END IF;
    END LOOP;
    IF cardinality(NEW.draw_document_ids)<>(SELECT COUNT(DISTINCT id) FROM unnest(NEW.draw_document_ids) id)
       OR EXISTS(SELECT 1 FROM unnest(NEW.draw_document_ids) document_id WHERE NOT EXISTS(
         SELECT 1 FROM stock_document_items item WHERE item.doc_id=document_id AND NEW.draw_item_quantities ? item.id::text)) THEN
        RAISE EXCEPTION 'DRAW adjustment contains an unrelated or repeated document' USING ERRCODE='23514';
    END IF;
    FOR entry IN SELECT mapping.demand_id,SUM(pair.value::text::numeric*COALESCE(item.unit_rate,1)) AS qty_base
       FROM jsonb_each(NEW.draw_item_quantities) pair
       JOIN stock_document_items item ON item.id=pair.key::uuid
       JOIN production_planning_package_document_items mapping ON mapping.document_item_id=item.id AND mapping.document_type='DRAW'
       GROUP BY mapping.demand_id LOOP
        IF NEW.receiving_direction=1 THEN
            SELECT COALESCE(SUM(slice.qty_base),0) INTO budget
            FROM production_workshop_material_return_slices slice
            JOIN production_material_return_request_items request_item ON request_item.id=slice.request_item_id
            JOIN production_workshop_direct_source_allocations allocation ON allocation.id=slice.source_allocation_id
            JOIN stock_reservations reservation ON reservation.id=allocation.stock_reservation_id
            WHERE request_item.request_id=linked.return_request_id AND reservation.demand_id=entry.demand_id;
        ELSE
            SELECT COALESCE(SUM(request_item.qty_base),0) INTO budget
            FROM production_material_return_request_items request_item
            LEFT JOIN production_material_stock_postings issue ON issue.id=request_item.issue_posting_id
            LEFT JOIN production_workshop_direct_transfer_items direct ON direct.id=request_item.direct_transfer_item_id
            JOIN production_material_demands demand ON demand.id=entry.demand_id
            WHERE request_item.request_id=linked.return_request_id AND
               (issue.demand_id=demand.id OR direct.to_demand_id IN(demand.id,demand.split_root_demand_id));
        END IF;
        IF entry.qty_base>budget THEN RAISE EXCEPTION 'DRAW reduction exceeds exact frozen receiving source slices' USING ERRCODE='23514'; END IF;
    END LOOP;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_material_return_draw_event BEFORE INSERT OR UPDATE OR DELETE ON production_execution_segment_events
FOR EACH ROW EXECUTE FUNCTION fn_guard_material_return_draw_event();
ALTER TABLE production_execution_segment_events ENABLE ALWAYS TRIGGER trg_guard_material_return_draw_event;

CREATE FUNCTION fn_assert_material_return_draw_event_committed()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.receiving_confirmation_id IS NULL THEN RETURN NULL; END IF;
    IF NOT EXISTS(SELECT 1 FROM production_material_return_receiving_confirmations confirmation
      JOIN stock_documents document ON document.id=confirmation.stock_document_id
      WHERE confirmation.id=NEW.receiving_confirmation_id AND NOT document.is_deleted
        AND document.status=CASE WHEN NEW.receiving_direction=1 THEN 1 ELSE -1 END
        AND document.xmin::text=pg_current_xact_id()::text
        AND (NEW.receiving_direction=-1 OR confirmation.xmin::text=pg_current_xact_id()::text)) THEN
        RAISE EXCEPTION 'DRAW remainder adjustment and its physical receipt or reversal must commit together' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_material_return_draw_event_committed AFTER INSERT ON production_execution_segment_events
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_material_return_draw_event_committed();

-- Share one effective instruction quantity across requests, warehouse picking,
-- readiness and reservation-budget checks; immutable original DRAW totals remain.
DO $effective_draw_quantity$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_production_draw_item_requested_qty(uuid)'::regprocedure) INTO definition;
    definition:=replace(definition,'SELECT CASE','SELECT LEAST(fn_production_draw_item_effective_qty(item.id), CASE');
    definition:=replace(definition,'END::numeric','END)::numeric');
    EXECUTE definition;
    SELECT pg_get_functiondef('fn_production_draw_fully_requested(uuid)'::regprocedure) INTO definition;
    EXECUTE replace(definition,'<item.qty','<fn_production_draw_item_effective_qty(item.id)');
    SELECT pg_get_functiondef('fn_guard_production_draw_quantities()'::regprocedure) INTO definition;
    EXECUTE replace(definition,'SELECT item.qty INTO current_qty','SELECT fn_production_draw_item_effective_qty(item.id) INTO current_qty');
    SELECT pg_get_functiondef('fn_execution_start_material_ready(uuid)'::regprocedure) INTO definition;
    EXECUTE replace(definition,'item.qty-COALESCE(item.issued_qty,0)','fn_production_draw_item_effective_qty(item.id)-COALESCE(item.issued_qty,0)');
    SELECT pg_get_functiondef('fn_execution_demand_draw_commitment_qty(uuid)'::regprocedure) INTO definition;
    EXECUTE replace(definition,'COALESCE(item.base_qty,item.qty*COALESCE(item.unit_rate,1))',
      '(fn_production_draw_item_effective_qty(item.id)*COALESCE(item.unit_rate,1))');
    SELECT pg_get_functiondef('fn_daily_report_has_unissued_material(uuid)'::regprocedure) INTO definition;
    EXECUTE replace(definition,'item.qty','fn_production_draw_item_effective_qty(item.id)');
    SELECT pg_get_functiondef('fn_can_reassign_execution_workshop(uuid)'::regprocedure) INTO definition;
    EXECUTE replace(definition,'AND NOT fn_execution_draw_assignment_syncable(document.id,p_segment)',
       'AND NOT fn_execution_draw_assignment_syncable(document.id,p_segment)
          AND EXISTS(SELECT 1 FROM stock_document_items item WHERE item.doc_id=document.id AND NOT item.is_deleted
            AND fn_production_draw_item_effective_qty(item.id)>COALESCE(item.issued_qty,0))');
END;
$effective_draw_quantity$;

-- Technical custody is handled by the workshop's explicit production command,
-- never by an ordinary warehouse pending-pick task.
CREATE OR REPLACE FUNCTION fn_production_draw_pending(p_document_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT fn_production_draw_requested(p_document_id)
      AND EXISTS(SELECT 1 FROM stock_documents document JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
          WHERE document.id=p_document_id AND NOT warehouse.is_line_side)
      AND EXISTS(SELECT 1 FROM stock_document_items item WHERE item.doc_id=p_document_id AND NOT item.is_deleted
          AND fn_production_draw_item_requested_qty(item.id)>COALESCE(item.issued_qty,0));
$$;

-- Independent batches are chosen before physical custody is bound. A route
-- already chosen as BATCH may still allocate its unreserved incoming direct
-- lots to the real child tasks; returned private reservations are binding.
CREATE OR REPLACE FUNCTION fn_can_split_execution_batch(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_execution_segments segment
      JOIN production_plans plan ON plan.id=segment.plan_id
      JOIN production_planning_packages package ON package.id=segment.package_id
      WHERE segment.id=p_segment AND segment.status='WAITING' AND segment.auto_promote_when_ready
        AND NOT segment.is_deleted AND segment.workshop_department_id IS NOT NULL
        AND plan.material_analysis_id IS NOT NULL AND plan.status=1 AND NOT plan.is_deleted
        AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped
        AND package.status='CONFIRMED' AND NOT package.is_deleted
        AND NOT EXISTS(SELECT 1 FROM production_planning_package_documents document WHERE document.execution_segment_id=segment.id)
        AND NOT EXISTS(SELECT 1 FROM production_daily_report_items report WHERE report.execution_segment_id=segment.id)
        AND NOT EXISTS(SELECT 1 FROM production_material_demands demand JOIN production_material_supply_pegs peg ON peg.demand_id=demand.id WHERE demand.execution_segment_id=segment.id)
        AND NOT EXISTS(SELECT 1 FROM production_material_demands demand JOIN stock_reservations reservation ON reservation.demand_id=demand.id WHERE demand.execution_segment_id=segment.id)
        AND NOT EXISTS(SELECT 1 FROM production_material_demands demand JOIN stock_reservations custody
          ON custody.owner_type='WORKSHOP_CUSTODY' AND custody.owner_id=demand.id AND NOT custody.is_deleted
            AND custody.qty>custody.released_qty WHERE demand.execution_segment_id=segment.id)
        AND (segment.start_route='BATCH' OR NOT EXISTS(SELECT 1 FROM production_material_demands demand
          JOIN v_workshop_direct_supply_lots lot ON lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
          WHERE demand.execution_segment_id=segment.id AND lot.available_qty>0)));
$$;

-- The DIRECT_LOT slice authority is installed by V619. plpgsql resolves that
-- dependency when used after migrations; ISSUE-only legacy facts are preserved.
CREATE OR REPLACE FUNCTION fn_execution_material_return_allowed(p_segment UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN EXISTS(SELECT 1 FROM production_execution_segments segment
      JOIN production_material_demands demand ON demand.execution_segment_id=segment.id AND NOT demand.is_deleted
        AND demand.status NOT IN('RELEASED','REVERSED')
      WHERE segment.id=p_segment AND NOT segment.is_deleted AND segment.status IN('WAITING','READY','DISPATCHED','IN_PROGRESS')
        AND ((segment.status<>'WAITING' AND EXISTS(SELECT 1 FROM production_material_stock_postings issue
          JOIN stock_document_items item ON item.id=issue.stock_document_item_id AND NOT item.is_deleted AND item.unit_rate>0
          JOIN stock_documents draw ON draw.id=item.doc_id AND draw.doc_type='DRAW' AND draw.status=1 AND NOT draw.is_deleted
          WHERE issue.demand_id=demand.id AND issue.posting_type='ISSUE' AND fn_material_issue_available(issue.id,NULL)>0
            AND NOT fn_issue_committed_to_later_batch(issue.id)))
          OR EXISTS(SELECT 1 FROM v_workshop_direct_supply_lots lot WHERE lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
            AND fn_workshop_direct_returnable_qty(lot.id,p_segment,NULL)>0)));
END;
$$;

CREATE FUNCTION fn_guard_material_return_receiving_confirmation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'Material return receiving confirmations are append-only' USING ERRCODE='55000';
    END IF;
    IF NEW.created_by::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')
       OR NOT fn_warehouse_is_active_accounting_leaf(NEW.received_warehouse_id)
       OR NOT fn_warehouse_same_main(NEW.source_warehouse_id,NEW.received_warehouse_id)
       OR NOT EXISTS(SELECT 1 FROM production_material_return_requests request
           JOIN stock_documents document ON document.id=request.id
           WHERE request.id=NEW.return_request_id AND request.id=NEW.stock_document_id
             AND request.warehouse_id=NEW.source_warehouse_id
             AND document.doc_type='WDRAW' AND document.status=0 AND NOT document.is_deleted
             AND document.warehouse_id IS NOT DISTINCT FROM NEW.previous_warehouse_id
             AND NOT EXISTS(SELECT 1 FROM production_material_return_request_cancellations cancellation WHERE cancellation.request_id=request.id)) THEN
        RAISE EXCEPTION 'Return receiving confirmation requires the exact active request and an ordinary operational leaf in its original main warehouse'
          USING ERRCODE='23514',CONSTRAINT='material_return_receiving_confirmation_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_material_return_receiving_confirmation
BEFORE INSERT OR UPDATE OR DELETE ON production_material_return_receiving_confirmations
FOR EACH ROW EXECUTE FUNCTION fn_guard_material_return_receiving_confirmation();
ALTER TABLE production_material_return_receiving_confirmations ENABLE ALWAYS TRIGGER trg_guard_material_return_receiving_confirmation;

CREATE FUNCTION fn_assert_material_return_receiving_committed()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM stock_documents document
        WHERE document.id=NEW.stock_document_id AND document.status=1 AND NOT document.is_deleted
          AND document.warehouse_id=NEW.received_warehouse_id)
       OR EXISTS(SELECT 1 FROM production_material_return_request_items item WHERE item.request_id=NEW.return_request_id
         AND NOT EXISTS(SELECT 1 FROM stock_movements movement WHERE movement.source_doc_id=NEW.stock_document_id
           AND movement.source_item_id=item.stock_document_item_id AND movement.warehouse_id=NEW.received_warehouse_id
           AND movement.direction=1 AND movement.qty=item.qty_base AND movement.created_by=NEW.created_by
           AND movement.xmin::text=pg_current_xact_id()::text))
       OR (EXISTS(SELECT 1 FROM production_material_return_request_items item WHERE item.request_id=NEW.return_request_id AND item.issue_posting_id IS NOT NULL)
         AND NOT EXISTS(SELECT 1 FROM production_material_stock_events event
           WHERE event.stock_document_id=NEW.stock_document_id AND event.event_type='GOOD_RETURN'
             AND event.created_by=NEW.created_by AND event.xmin::text=pg_current_xact_id()::text)) THEN
        RAISE EXCEPTION 'Return destination confirmation and real warehouse receipt must commit together'
          USING ERRCODE='23514',CONSTRAINT='material_return_receiving_commit_guard';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_material_return_receiving_committed
AFTER INSERT ON production_material_return_receiving_confirmations DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_assert_material_return_receiving_committed();

CREATE FUNCTION fn_is_material_return_receiving_change(p_document UUID,p_old_warehouse UUID,p_new_warehouse UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_material_return_receiving_confirmations confirmation
       JOIN stock_documents document ON document.id=confirmation.stock_document_id
       WHERE document.id=p_document AND document.doc_type='WDRAW' AND document.status=0 AND NOT document.is_deleted
         AND confirmation.previous_warehouse_id IS NOT DISTINCT FROM p_old_warehouse
         AND confirmation.received_warehouse_id=p_new_warehouse
         AND confirmation.created_by=NULLIF(current_setting('app.actor_id',true),'')::uuid
         AND confirmation.xmin::text=pg_current_xact_id()::text);
$$;
DO $receiving_header_guard$
DECLARE definition TEXT; anchor TEXT:='    IF TG_OP = ''DELETE'' THEN';
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_linked_stock_document()'::regprocedure) INTO definition;
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V618 missing production header guard anchor'; END IF;
    EXECUTE replace(definition,anchor,$allow$
    IF TG_OP='UPDATE' AND (to_jsonb(NEW)-ARRAY['warehouse_id','updated_at','updated_by'])
          =(to_jsonb(OLD)-ARRAY['warehouse_id','updated_at','updated_by'])
       AND fn_is_material_return_receiving_change(OLD.id,OLD.warehouse_id,NEW.warehouse_id) THEN
        RETURN NEW;
    END IF;
$allow$||anchor);
END;
$receiving_header_guard$;

-- The request freezes where the material came from. A draft's receiving
-- warehouse can remain unknown; no workshop employee chooses a warehouse.
CREATE OR REPLACE FUNCTION fn_guard_production_material_return_request() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source production_material_stock_postings%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Production material return requests are append-only' USING ERRCODE='55000'; END IF;
    IF TG_TABLE_NAME='production_material_return_requests' THEN
        IF NOT fn_execution_material_return_allowed(NEW.execution_segment_id)
           OR NOT EXISTS(SELECT 1 FROM production_execution_segments segment WHERE segment.id=NEW.execution_segment_id AND segment.plan_id=NEW.plan_id)
           OR NOT EXISTS(SELECT 1 FROM stock_documents document WHERE document.id=NEW.id
              AND document.doc_type='WDRAW' AND document.status=0 AND NOT document.is_deleted
              AND (document.warehouse_id IS NULL OR (document.warehouse_id=NEW.warehouse_id
                AND EXISTS(SELECT 1 FROM warehouses warehouse WHERE warehouse.id=NEW.warehouse_id AND NOT warehouse.is_line_side)))
              AND document.department_id IS NOT DISTINCT FROM NEW.source_department_id) THEN
            RAISE EXCEPTION 'Return request requires real active task custody and an original source; workshop transfer locations cannot default as receipt destinations' USING ERRCODE='23514';
        END IF;
    ELSIF TG_TABLE_NAME='production_material_return_request_items' THEN
      IF NEW.direct_transfer_item_id IS NOT NULL THEN
        PERFORM 1 FROM production_workshop_direct_transfer_items WHERE id=NEW.direct_transfer_item_id FOR UPDATE;
        IF NOT EXISTS(SELECT 1 FROM production_material_return_requests request
            JOIN stock_documents document ON document.id=request.id AND document.status=0 AND NOT document.is_deleted
            JOIN stock_document_items item ON item.id=NEW.stock_document_item_id AND item.doc_id=document.id
            JOIN production_workshop_direct_transfer_items direct ON direct.id=NEW.direct_transfer_item_id AND direct.reversal_id IS NULL
            JOIN production_workshop_direct_transfers transfer ON transfer.id=direct.transfer_id
            JOIN production_material_demands demand ON direct.to_demand_id IN(demand.id,demand.split_root_demand_id)
              AND demand.execution_segment_id=request.execution_segment_id AND demand.plan_id=request.plan_id AND NOT demand.is_deleted
            JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
              AND segment.status IN('WAITING','READY','DISPATCHED','IN_PROGRESS') AND NOT segment.is_deleted
            JOIN stock_document_items original ON original.id=item.upstream_item_id
              AND original.source_daily_report_item_id=direct.source_report_item_id AND NOT original.is_deleted AND original.qty>0
            JOIN stock_documents origin_receipt ON origin_receipt.id=original.doc_id AND origin_receipt.doc_type='FINISHED_IN'
              AND origin_receipt.status=1 AND NOT origin_receipt.is_deleted AND origin_receipt.warehouse_id=request.warehouse_id
            WHERE request.id=NEW.request_id AND request.warehouse_id=transfer.line_side_warehouse_id
              AND request.source_department_id=transfer.workshop_department_id
              AND document.department_id=transfer.workshop_department_id AND item.goods_id=original.goods_id
              AND item.color_id IS NOT DISTINCT FROM original.color_id AND item.unit_id=demand.unit_id AND item.unit_rate=1
              AND item.base_qty=NEW.qty_base AND item.qty*item.unit_rate=NEW.qty_base
              AND NEW.qty_base<=fn_workshop_direct_returnable_qty(direct.id,request.execution_segment_id,NULL)) THEN
            RAISE EXCEPTION 'Direct material return requires available unissued custody of this exact task and original direct lot' USING ERRCODE='23514';
        END IF;
      ELSE
        SELECT * INTO source FROM production_material_stock_postings WHERE id=NEW.issue_posting_id FOR UPDATE;
        IF source.id IS NULL OR source.posting_type<>'ISSUE' OR NEW.qty_base>fn_material_issue_available(source.id,NULL)
           OR fn_issue_committed_to_later_batch(source.id)
           OR NOT EXISTS(SELECT 1 FROM production_material_return_requests request
              JOIN stock_documents document ON document.id=request.id AND document.doc_type='WDRAW'
              JOIN stock_document_items item ON item.id=NEW.stock_document_item_id AND item.doc_id=document.id
              JOIN stock_document_items original ON original.id=source.stock_document_item_id
              JOIN stock_documents draw ON draw.id=original.doc_id
              JOIN production_material_demands demand ON demand.id=source.demand_id
              JOIN production_execution_segments segment ON segment.id=request.execution_segment_id AND NOT segment.is_deleted
                AND segment.status IN ('READY','DISPATCHED','IN_PROGRESS')
              WHERE request.id=NEW.request_id AND document.status=0 AND NOT document.is_deleted
                AND demand.plan_id=request.plan_id AND demand.execution_segment_id=request.execution_segment_id
                AND request.warehouse_id=draw.warehouse_id
                AND request.source_department_id IS NOT DISTINCT FROM draw.department_id
                AND document.department_id IS NOT DISTINCT FROM draw.department_id
                AND item.upstream_item_id=original.id AND item.goods_id=original.goods_id
                AND item.color_id IS NOT DISTINCT FROM original.color_id
                AND item.unit_id=demand.unit_id AND item.unit_rate=1
                AND item.base_qty=NEW.qty_base AND item.qty*item.unit_rate=NEW.qty_base) THEN
            RAISE EXCEPTION 'Return request changes or exceeds its exact original ISSUE, department or units' USING ERRCODE='23514';
        END IF;
      END IF;
    ELSIF TG_TABLE_NAME='production_material_return_request_cancellations' THEN
        IF NOT EXISTS(SELECT 1 FROM stock_documents WHERE id=NEW.request_id AND status=0 AND NOT is_deleted)
           OR EXISTS(SELECT 1 FROM production_material_stock_events WHERE stock_document_id=NEW.request_id) THEN
            RAISE EXCEPTION 'Only an unreceived return request can be cancelled' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_requested_material_return_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE requested production_material_return_request_items%ROWTYPE;
BEGIN
    IF NEW.posting_type<>'GOOD_RETURN' THEN RETURN NEW; END IF;
    SELECT * INTO requested FROM production_material_return_request_items WHERE stock_document_item_id=NEW.stock_document_item_id;
    IF requested.id IS NULL OR NEW.source_posting_id IS DISTINCT FROM requested.issue_posting_id
        OR NEW.qty_base+COALESCE((SELECT sum(qty_base) FROM production_material_stock_postings
            WHERE stock_document_item_id=NEW.stock_document_item_id AND posting_type='GOOD_RETURN'),0)>requested.qty_base
        OR NOT EXISTS(SELECT 1 FROM production_material_return_receiving_confirmations confirmation
            JOIN stock_documents receipt ON receipt.id=confirmation.stock_document_id
            JOIN production_material_stock_postings issue ON issue.id=requested.issue_posting_id
            JOIN stock_document_items original ON original.id=issue.stock_document_item_id
            JOIN stock_documents draw ON draw.id=original.doc_id
            WHERE confirmation.stock_document_id=requested.request_id
              AND confirmation.source_warehouse_id=draw.warehouse_id
              AND confirmation.received_warehouse_id=receipt.warehouse_id
              AND receipt.department_id IS NOT DISTINCT FROM draw.department_id) THEN
        RAISE EXCEPTION 'Warehouse receipt must match the exact ISSUE and confirmed ordinary receiving warehouse' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_production_material_return_receiving_confirmations
AFTER INSERT OR UPDATE OR DELETE ON production_material_return_receiving_confirmations
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_material_return_receiving_confirmations ENABLE ALWAYS TRIGGER trg_audit_production_material_return_receiving_confirmations;
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V618 missing business reset anchor'; END IF;
    EXECUTE replace(definition,anchor,'(''production_material_return_receiving_confirmations'', ''CLEAR''),'||anchor);
END;
$reset_policy$;

-- New code exposes exactly one explicit START command and one readiness predicate.
DROP FUNCTION fn_can_start_continuous_supply(UUID);
