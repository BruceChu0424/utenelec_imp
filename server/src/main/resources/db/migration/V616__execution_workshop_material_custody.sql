-- A task's workshop identifies actual material custody, not just its next owner.
-- Preserve historical assignments and require the original physical chain to be
-- returned/reversed before moving an unstarted task to a different workshop.
CREATE FUNCTION fn_material_issue_custody_qty(p_issue UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT issue.qty_base
      -COALESCE((SELECT SUM(qty_base) FROM production_material_stock_postings
          WHERE source_posting_id=issue.id AND posting_type IN ('ISSUE_REVERSE','GOOD_RETURN')),0)
      +COALESCE((SELECT SUM(reverse.qty_base) FROM production_material_stock_postings returned
          JOIN production_material_stock_postings reverse ON reverse.source_posting_id=returned.id
            AND reverse.posting_type='GOOD_RETURN_REVERSE'
          WHERE returned.source_posting_id=issue.id AND returned.posting_type='GOOD_RETURN'),0)
    FROM production_material_stock_postings issue WHERE issue.id=p_issue AND issue.posting_type='ISSUE';
$$;

CREATE FUNCTION fn_execution_draw_assignment_syncable(p_document UUID,p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT 1 FROM stock_documents document
    WHERE document.id=p_document AND document.doc_type='DRAW'
      AND document.status IN (0,1) AND NOT document.is_deleted
      AND EXISTS(SELECT 1 FROM production_planning_package_documents mapping
        WHERE mapping.document_id=document.id AND mapping.document_type='DRAW' AND mapping.execution_segment_id=p_segment)
      AND NOT EXISTS(SELECT 1 FROM production_planning_package_documents other
        WHERE other.document_id=document.id AND other.document_type='DRAW' AND other.execution_segment_id IS DISTINCT FROM p_segment)
      AND NOT EXISTS(SELECT 1 FROM stock_document_items item WHERE item.doc_id=document.id
        AND (COALESCE(item.issued_qty,0)>0
          OR EXISTS(SELECT 1 FROM production_material_stock_postings posting
            WHERE posting.stock_document_item_id=item.id AND posting.posting_type='ISSUE')
          OR EXISTS(SELECT 1 FROM stock_movements movement
            WHERE movement.source_item_id=item.id AND movement.direction=-1))));
$$;

CREATE FUNCTION fn_can_reassign_execution_workshop(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    WITH source_segments AS (
        SELECT p_segment AS id
        UNION
        SELECT segment_id FROM fn_production_material_usage_source_segments(p_segment)
    ), demands AS (
        SELECT demand.id,COALESCE(demand.split_root_demand_id,demand.id) AS root_id
        FROM production_material_demands demand
        WHERE demand.execution_segment_id IN (SELECT id FROM source_segments)
          AND NOT demand.is_deleted
    )
    SELECT EXISTS(SELECT 1 FROM production_execution_segments segment
        WHERE segment.id=p_segment AND NOT segment.is_deleted
          AND segment.status IN ('WAITING','READY'))
      AND NOT EXISTS(
        SELECT 1 FROM demands demand
        JOIN production_material_stock_postings posting ON posting.demand_id=demand.id AND posting.posting_type='ISSUE'
        WHERE fn_material_issue_custody_qty(posting.id)<>0)
      AND NOT EXISTS(
        SELECT 1 FROM demands demand
        JOIN stock_reservations reservation ON reservation.demand_id=demand.id AND NOT reservation.is_deleted
        JOIN warehouses warehouse ON warehouse.id=reservation.warehouse_id
        WHERE reservation.consumed_qty>0
           OR (warehouse.is_line_side AND reservation.qty>reservation.released_qty))
      AND NOT EXISTS(
        SELECT 1 FROM demands demand
        JOIN v_workshop_direct_supply_lots lot ON lot.to_demand_id IN (demand.id,demand.root_id)
        WHERE lot.available_qty>0)
      AND NOT EXISTS(
        SELECT 1 FROM production_planning_package_documents mapping
        JOIN stock_documents document ON document.id=mapping.document_id AND document.doc_type='DRAW'
          AND document.status IN (0,1) AND NOT document.is_deleted
        WHERE mapping.execution_segment_id=p_segment AND mapping.document_type='DRAW'
          AND NOT fn_execution_draw_assignment_syncable(document.id,p_segment))
      -- Shared fixed/package material is one physical source even before issue.
      -- Changing either side of that dependency cannot turn it into an implicit
      -- cross-workshop handoff when the preceding batch receives material later.
      AND NOT EXISTS(
        SELECT 1 FROM production_execution_segments target
        CROSS JOIN LATERAL jsonb_array_elements(target.split_material_snapshot) requirement
        WHERE target.id=p_segment AND (requirement->>'requiresPrior')::boolean)
      AND NOT EXISTS(
        SELECT 1 FROM production_execution_segments source
        JOIN production_material_demands source_demand ON source_demand.execution_segment_id=source.id
          AND NOT source_demand.is_deleted
        JOIN production_execution_segments later ON later.split_root_segment_id=source.split_root_segment_id
          AND later.source_segment_id IS NOT NULL AND NOT later.is_deleted
          AND later.status NOT IN ('CANCELLED','REVERSED')
          AND later.split_start_qty>=source.split_start_qty+COALESCE(source.material_snapshot_product_qty,source.planned_qty)
        CROSS JOIN LATERAL jsonb_array_elements(later.split_material_snapshot) requirement
        WHERE source.id=p_segment AND (requirement->>'requiresPrior')::boolean
          AND (requirement->>'rootDemandId')::uuid=COALESCE(source_demand.split_root_demand_id,source_demand.id));
$$;

CREATE FUNCTION fn_guard_execution_workshop_material_custody()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.workshop_department_id IS DISTINCT FROM NEW.workshop_department_id
       AND NOT fn_can_reassign_execution_workshop(OLD.id) THEN
        RAISE EXCEPTION 'Workshop reassignment requires returning/reversing material custody and withdrawing shared-material batch dependencies first'
            USING ERRCODE='23514',CONSTRAINT='execution_workshop_material_custody_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_execution_workshop_material_custody
BEFORE UPDATE OF workshop_department_id ON production_execution_segments
FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_workshop_material_custody();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_guard_execution_workshop_material_custody;

COMMENT ON FUNCTION fn_can_reassign_execution_workshop(UUID) IS
  'Only unstarted tasks without real material custody or shared fixed/package batch dependencies can change workshops. Pending returns are still physical custody; same-workshop reassignment is unaffected.';

-- A pending request records the requested material, not a completed handoff.
-- Preserve that event and document identity while synchronizing the recipient
-- with an exact same-transaction assignment event. Never rewrite issued history.
CREATE FUNCTION fn_is_execution_draw_assignment_change(p_document UUID,p_workshop UUID,p_employee UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT 1 FROM production_planning_package_documents mapping
    JOIN production_execution_segments segment ON segment.id=mapping.execution_segment_id
    JOIN production_execution_segment_events event ON event.execution_segment_id=segment.id AND event.action='ASSIGNMENT'
    WHERE mapping.document_id=p_document AND mapping.document_type='DRAW'
      AND segment.status IN ('READY','WAITING') AND NOT segment.is_deleted
      AND p_workshop IS NOT NULL AND segment.workshop_department_id=p_workshop
      AND segment.responsible_employee_id IS NOT DISTINCT FROM p_employee
      AND event.resulting_version=segment.lock_version AND event.expected_version+1=event.resulting_version
      AND event.created_by=NULLIF(current_setting('app.actor_id',true),'')::uuid
      AND event.xmin::text=pg_current_xact_id()::text AND segment.xmin::text=pg_current_xact_id()::text
      AND fn_execution_draw_assignment_syncable(p_document,segment.id));
$$;

-- xmin identifies this transaction only because assignment history cannot be
-- updated in place. A no-op UPDATE of an old event must not refresh its proof.
CREATE FUNCTION fn_guard_execution_assignment_event_history()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.action='ASSIGNMENT' OR (TG_OP='UPDATE' AND NEW.action='ASSIGNMENT') THEN
        RAISE EXCEPTION 'Execution assignment events are append-only' USING ERRCODE='55000';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_execution_assignment_event_history
BEFORE UPDATE OR DELETE ON production_execution_segment_events
FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_assignment_event_history();
ALTER TABLE production_execution_segment_events ENABLE ALWAYS TRIGGER trg_guard_execution_assignment_event_history;

DO $assignment_guard$
DECLARE definition TEXT; anchor TEXT:='    IF TG_OP = ''DELETE'' THEN';
BEGIN
  SELECT pg_get_functiondef('fn_guard_production_linked_stock_document()'::regprocedure) INTO definition;
  IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Production linked-stock identity guard changed before V616'; END IF;
  EXECUTE replace(definition,anchor,$allow$
    IF TG_OP='UPDATE'
       AND (to_jsonb(NEW)-ARRAY['department_id','worker_id','updated_at','updated_by'])
           =(to_jsonb(OLD)-ARRAY['department_id','worker_id','updated_at','updated_by'])
       AND fn_is_execution_draw_assignment_change(OLD.id,NEW.department_id,NEW.worker_id) THEN
        RETURN NEW;
    END IF;
$allow$||anchor);
END;
$assignment_guard$;

-- Detect known historical misassignments without rewriting any actual issue.
-- Ordinary leaf warehouses are deliberately not workshop identities; only the
-- document's real receiving department or a technical line-side location is.
CREATE FUNCTION fn_execution_material_custody_valid(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  WITH target AS (
    SELECT id,workshop_department_id FROM production_execution_segments WHERE id=p_segment AND NOT is_deleted
  ), source_segments AS (
    SELECT p_segment AS id UNION SELECT segment_id FROM fn_production_material_usage_source_segments(p_segment)
  ), demands AS (
    SELECT demand.id,COALESCE(demand.split_root_demand_id,demand.id) AS root_id
    FROM production_material_demands demand
    WHERE demand.execution_segment_id IN(SELECT id FROM source_segments) AND NOT demand.is_deleted
  )
  SELECT EXISTS(SELECT 1 FROM target)
    AND NOT EXISTS(
      SELECT 1 FROM target CROSS JOIN demands demand
      JOIN production_material_stock_postings issue ON issue.demand_id=demand.id AND issue.posting_type='ISSUE'
      JOIN stock_document_items item ON item.id=issue.stock_document_item_id
      JOIN stock_documents document ON document.id=item.doc_id
      LEFT JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
      WHERE fn_material_issue_custody_qty(issue.id)>0
        AND ((document.department_id IS NOT NULL AND document.department_id IS DISTINCT FROM target.workshop_department_id)
          OR (warehouse.is_line_side AND warehouse.workshop_department_id IS NOT NULL
              AND warehouse.workshop_department_id IS DISTINCT FROM target.workshop_department_id)))
    AND NOT EXISTS(
      SELECT 1 FROM target CROSS JOIN demands demand
      JOIN stock_reservations reservation ON reservation.demand_id=demand.id AND NOT reservation.is_deleted
      JOIN warehouses warehouse ON warehouse.id=reservation.warehouse_id AND warehouse.is_line_side
      WHERE reservation.qty>reservation.released_qty AND warehouse.workshop_department_id IS NOT NULL
        AND warehouse.workshop_department_id IS DISTINCT FROM target.workshop_department_id)
    AND NOT EXISTS(
      SELECT 1 FROM target CROSS JOIN demands demand
      JOIN v_workshop_direct_supply_lots lot ON lot.to_demand_id IN(demand.id,demand.root_id)
      JOIN warehouses warehouse ON warehouse.id=lot.line_side_warehouse_id
      WHERE lot.available_qty>0 AND warehouse.workshop_department_id IS NOT NULL
        AND warehouse.workshop_department_id IS DISTINCT FROM target.workshop_department_id);
$$;

CREATE OR REPLACE FUNCTION fn_execution_material_output_capacity(p_segment UUID,p_issued_only BOOLEAN DEFAULT TRUE)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN NOT fn_execution_material_custody_valid(segment.id) THEN 0
                WHEN segment.material_requirement_mode='ZERO_MATERIAL' THEN segment.planned_qty
                WHEN fn_split_batch_empty_issued(segment.id) THEN segment.planned_qty
                ELSE COALESCE((
                    SELECT MIN(fn_demand_material_output_capacity(demand.id,
                        CASE WHEN p_issued_only THEN fn_execution_material_net_issued_qty(demand.id)
                        ELSE COALESCE((SELECT SUM(reservation.qty-reservation.released_qty)
                            FROM stock_reservations reservation
                            WHERE reservation.demand_id=demand.id AND NOT reservation.is_deleted),0) END))
                    FROM production_material_demands demand
                    WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted
                      AND demand.status NOT IN ('RELEASED','REVERSED')
                ),0) END
    FROM production_execution_segments segment WHERE segment.id=p_segment AND NOT segment.is_deleted;
$$;

DO $start_custody$
DECLARE definition TEXT; anchor TEXT:='SELECT CASE WHEN segment.material_requirement_mode=''ZERO_MATERIAL''';
BEGIN
    SELECT pg_get_functiondef('fn_execution_start_material_ready(uuid)'::regprocedure) INTO definition;
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Execution start readiness changed before V616'; END IF;
    EXECUTE replace(definition,anchor,
      'SELECT CASE WHEN NOT fn_execution_material_custody_valid(segment.id) THEN FALSE WHEN segment.material_requirement_mode=''ZERO_MATERIAL''');
END;
$start_custody$;

CREATE FUNCTION fn_guard_execution_start_material_custody()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status='IN_PROGRESS' AND OLD.status IS DISTINCT FROM NEW.status
       AND NOT fn_execution_material_custody_valid(NEW.id) THEN
        RAISE EXCEPTION 'Actual material workshop custody conflicts with the execution assignment'
          USING ERRCODE='23514',CONSTRAINT='execution_start_material_custody_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_execution_start_material_custody
BEFORE UPDATE OF status ON production_execution_segments
FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_start_material_custody();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_guard_execution_start_material_custody;

-- Real return is independent from START. New return headers retain the original
-- delivery department; one user command may create separate receipts for two
-- original departments in the same physical warehouse. Old headers stay intact.
ALTER TABLE production_material_return_requests ADD COLUMN source_department_id UUID REFERENCES departments(id);
DO $return_destination_key$
DECLARE original_key TEXT;
BEGIN
    SELECT conname INTO original_key FROM pg_constraint
    WHERE conrelid='production_material_return_requests'::regclass AND contype='u'
      AND pg_get_constraintdef(oid)='UNIQUE (created_by, idempotency_key, warehouse_id)';
    IF original_key IS NULL THEN RAISE EXCEPTION 'Return request destination key changed before V616'; END IF;
    EXECUTE format('ALTER TABLE production_material_return_requests DROP CONSTRAINT %I',original_key);
END;
$return_destination_key$;
ALTER TABLE production_material_return_requests ADD CONSTRAINT uq_material_return_actor_destination
    UNIQUE NULLS NOT DISTINCT(created_by,idempotency_key,warehouse_id,source_department_id);

CREATE FUNCTION fn_execution_material_return_allowed(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_execution_segments segment
      JOIN production_material_demands demand ON demand.execution_segment_id=segment.id AND NOT demand.is_deleted
        AND demand.status NOT IN ('RELEASED','REVERSED')
      JOIN production_material_stock_postings issue ON issue.demand_id=demand.id AND issue.posting_type='ISSUE'
      JOIN stock_document_items item ON item.id=issue.stock_document_item_id AND NOT item.is_deleted AND item.unit_rate>0
      JOIN stock_documents draw ON draw.id=item.doc_id AND draw.doc_type='DRAW' AND draw.status=1 AND NOT draw.is_deleted
      WHERE segment.id=p_segment AND NOT segment.is_deleted AND segment.status IN ('READY','DISPATCHED','IN_PROGRESS')
        AND fn_material_issue_available(issue.id,NULL)>0 AND NOT fn_issue_committed_to_later_batch(issue.id));
$$;

CREATE OR REPLACE FUNCTION fn_guard_production_material_return_request() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source production_material_stock_postings%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'Production material return requests are append-only' USING ERRCODE='55000';
    END IF;
    IF TG_TABLE_NAME='production_material_return_requests' THEN
        IF NOT fn_execution_material_return_allowed(NEW.execution_segment_id)
           OR NOT EXISTS(SELECT 1 FROM production_execution_segments segment
              WHERE segment.id=NEW.execution_segment_id AND segment.plan_id=NEW.plan_id)
           OR NOT EXISTS(SELECT 1 FROM stock_documents document WHERE document.id=NEW.id
              AND document.doc_type='WDRAW' AND document.status=0 AND NOT document.is_deleted
              AND document.warehouse_id=NEW.warehouse_id
              AND document.department_id IS NOT DISTINCT FROM NEW.source_department_id) THEN
            RAISE EXCEPTION 'Surplus return requires available real ISSUE material on an active task and its exact source destination' USING ERRCODE='23514';
        END IF;
    ELSIF TG_TABLE_NAME='production_material_return_request_items' THEN
        SELECT * INTO source FROM production_material_stock_postings WHERE id=NEW.issue_posting_id FOR UPDATE;
        IF source.id IS NULL OR source.posting_type<>'ISSUE' OR NEW.qty_base>fn_material_issue_available(source.id,NULL)
           OR fn_issue_committed_to_later_batch(source.id)
           OR NOT EXISTS(
              SELECT 1 FROM production_material_return_requests request
              JOIN stock_documents document ON document.id=request.id AND document.doc_type='WDRAW'
              JOIN stock_document_items item ON item.id=NEW.stock_document_item_id AND item.doc_id=document.id
              JOIN stock_document_items original ON original.id=source.stock_document_item_id
              JOIN stock_documents draw ON draw.id=original.doc_id
              JOIN production_material_demands demand ON demand.id=source.demand_id
              JOIN production_execution_segments segment ON segment.id=request.execution_segment_id AND NOT segment.is_deleted
                AND segment.status IN ('READY','DISPATCHED','IN_PROGRESS')
              WHERE request.id=NEW.request_id AND document.status=0 AND NOT document.is_deleted
                AND demand.plan_id=request.plan_id AND demand.execution_segment_id=request.execution_segment_id
                AND document.warehouse_id=request.warehouse_id AND document.warehouse_id=draw.warehouse_id
                AND request.source_department_id IS NOT DISTINCT FROM draw.department_id
                AND document.department_id IS NOT DISTINCT FROM draw.department_id
                AND item.upstream_item_id=original.id AND item.goods_id=original.goods_id
                AND item.color_id IS NOT DISTINCT FROM original.color_id
                AND item.unit_id=original.unit_id AND item.unit_rate=original.unit_rate
                AND item.base_qty=NEW.qty_base AND item.qty*item.unit_rate=NEW.qty_base) THEN
            RAISE EXCEPTION 'Return request exceeds available exact issue or changes its warehouse/department/unit/source' USING ERRCODE='23514';
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
    IF requested.id IS NOT NULL AND (NEW.source_posting_id IS DISTINCT FROM requested.issue_posting_id
        OR NEW.qty_base+COALESCE((SELECT sum(qty_base) FROM production_material_stock_postings
            WHERE stock_document_item_id=NEW.stock_document_item_id AND posting_type='GOOD_RETURN'),0)>requested.qty_base
        OR NOT EXISTS(SELECT 1 FROM stock_document_items returned
            JOIN stock_documents receipt ON receipt.id=returned.doc_id
            JOIN production_material_stock_postings issue ON issue.id=requested.issue_posting_id
            JOIN stock_document_items original ON original.id=issue.stock_document_item_id
            JOIN stock_documents draw ON draw.id=original.doc_id
            WHERE returned.id=NEW.stock_document_item_id AND receipt.department_id IS NOT DISTINCT FROM draw.department_id)) THEN
        RAISE EXCEPTION 'Warehouse receipt must match the exact requested original ISSUE slice and department; cancel an unreceived mismatched legacy request and submit it again' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

-- Historical DRAW quantities prove that the task was prepared. They are not
-- current commitments: a real return can be picked again without changing the
-- first DRAW or its ISSUE/GOOD_RETURN history. Only undelivered promises plus
-- net physical issues can consume the current reservation/demand budget.
CREATE FUNCTION fn_execution_demand_draw_commitment_qty(p_demand UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    -- ISSUE can consume several reservation slices before issued_qty is updated.
    -- Derive both sides from postings so a trigger between slices cannot count
    -- the first actual issue and its still-stale projection as two commitments.
    SELECT COALESCE((SELECT SUM(GREATEST(COALESCE(item.base_qty,item.qty*COALESCE(item.unit_rate,1))
            -COALESCE((SELECT SUM(CASE posted.posting_type WHEN 'ISSUE' THEN posted.qty_base
                         WHEN 'ISSUE_REVERSE' THEN -posted.qty_base ELSE 0 END)
                       FROM production_material_stock_postings posted WHERE posted.stock_document_item_id=item.id),0),0))
        FROM production_planning_package_document_items mapping
        JOIN stock_document_items item ON item.id=mapping.document_item_id AND NOT item.is_deleted
        JOIN stock_documents document ON document.id=item.doc_id AND document.id=mapping.document_id
          AND document.doc_type='DRAW' AND document.status IN (0,1) AND NOT document.is_deleted
        WHERE mapping.demand_id=p_demand AND mapping.document_type='DRAW'),0)
      + COALESCE((SELECT SUM(CASE posting.posting_type
            WHEN 'ISSUE' THEN posting.qty_base WHEN 'GOOD_RETURN_REVERSE' THEN posting.qty_base
            WHEN 'ISSUE_REVERSE' THEN -posting.qty_base WHEN 'GOOD_RETURN' THEN -posting.qty_base ELSE 0 END)
        FROM production_material_stock_postings posting WHERE posting.demand_id=p_demand),0);
$$;

DO $net_draw_commitment$
DECLARE definition TEXT; changed TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_assert_execution_segment_integrity_before_v561(uuid)'::regprocedure) INTO definition;
    changed:=replace(definition,'d.required_qty,','d.required_qty, fn_execution_demand_draw_commitment_qty(d.id) AS draw_committed,');
    IF changed=definition THEN RAISE EXCEPTION 'V616 missing demand coverage anchor'; END IF;
    definition:=changed;
    changed:=replace(definition,'draw_backed > required_qty','draw_committed > required_qty');
    IF changed=definition THEN RAISE EXCEPTION 'V616 missing DRAW requirement budget anchor'; END IF;
    definition:=changed;
    changed:=replace(definition,'draw_backed > stock_backed','draw_committed > stock_backed');
    IF changed=definition THEN RAISE EXCEPTION 'V616 missing DRAW reservation budget anchor'; END IF;
    EXECUTE changed;
END;
$net_draw_commitment$;

-- A valid issued task may later replace physically returned material through
-- the same request command regardless of the route used for its first START.
DO $draw_request_active_task$
DECLARE definition TEXT; anchor TEXT:='(segment.status IN (''READY'',''DISPATCHED'') OR (segment.continuous_supply AND segment.status=''IN_PROGRESS''))';
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_draw_request_event()'::regprocedure) INTO definition;
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V616 missing DRAW request active-task anchor'; END IF;
    EXECUTE replace(definition,anchor,'segment.status IN (''READY'',''DISPATCHED'',''IN_PROGRESS'')');
END;
$draw_request_active_task$;
