-- Pending purchase revisions keep the same finance case. They amend reservations,
-- never confirmed request quantities or effective production supply.
ALTER TABLE procurement_order_source_revisions
    ADD COLUMN pending_case_id UUID REFERENCES procurement_order_approval_cases(id),
    ADD COLUMN pending_case_version BIGINT,
    ADD CONSTRAINT procurement_pending_revision_identity CHECK (
        (pending_case_id IS NULL AND pending_case_version IS NULL) OR
        (order_type='PURCHASE' AND pending_case_id IS NOT NULL AND pending_case_version>0));
ALTER TABLE procurement_order_source_revision_allocations
    ADD COLUMN pending_reservation BOOLEAN NOT NULL DEFAULT FALSE;
DO $migration$
DECLARE identity RECORD; found_count INTEGER:=0;
BEGIN
    FOR identity IN SELECT conname FROM pg_constraint
        WHERE conrelid='procurement_order_source_revision_allocations'::regclass AND contype='c'
          AND pg_get_constraintdef(oid) LIKE '%after_ordered_qty%before_ordered_qty%after_alloc_qty%'
    LOOP
        found_count:=found_count+1;
        EXECUTE format('ALTER TABLE procurement_order_source_revision_allocations DROP CONSTRAINT %I',identity.conname);
    END LOOP;
    IF found_count<>1 THEN RAISE EXCEPTION 'V963 allocation conservation constraint differs'; END IF;
END
$migration$;
ALTER TABLE procurement_order_source_revision_allocations
    ADD CONSTRAINT procurement_revision_lifecycle_conservation CHECK (
        (NOT pending_reservation AND after_ordered_qty-before_ordered_qty=after_alloc_qty-before_alloc_qty)
        OR (pending_reservation AND after_ordered_qty=before_ordered_qty
            AND before_peg_qty_base=0 AND after_peg_qty_base=0));

ALTER TABLE procurement_order_approval_events DROP CONSTRAINT procurement_order_approval_events_event_type_check;
ALTER TABLE procurement_order_approval_events ADD CONSTRAINT procurement_order_approval_events_event_type_check
    CHECK(event_type IN ('SUBMITTED','APPROVED','REJECTED','CANCELED','REASSIGNED','FINANCE_EDIT','CLOSED','QUANTITY_CHANGED'));

CREATE OR REPLACE FUNCTION fn_prepare_procurement_source_revision() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE item JSONB; prefix TEXT; header_status SMALLINT; deleted BOOLEAN; latest_attempt INTEGER;
    pending procurement_order_approval_cases%ROWTYPE;
BEGIN
    prefix:=CASE NEW.order_type WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
    EXECUTE format('SELECT to_jsonb(i),h.status,h.is_deleted FROM %I i JOIN %I h ON h.id=i.order_id
        WHERE i.id=$1 AND h.id=$2 FOR UPDATE OF h,i',prefix||'_order_items',prefix||'_orders')
        INTO item,header_status,deleted USING NEW.order_item_id,NEW.order_id;
    SELECT COALESCE(MAX(attempt),0) INTO latest_attempt FROM procurement_order_approval_cases
        WHERE order_type=NEW.order_type AND order_id=NEW.order_id;
    IF NEW.pending_case_id IS NOT NULL THEN
        SELECT * INTO pending FROM procurement_order_approval_cases WHERE id=NEW.pending_case_id FOR UPDATE;
        IF NEW.order_type<>'PURCHASE' OR header_status IS DISTINCT FROM 0 OR pending.id IS NULL
           OR pending.order_type<>'PURCHASE' OR pending.order_id<>NEW.order_id
           OR pending.status<>'PENDING' OR pending.request_type<>'ORDER'
           OR pending.version<>NEW.pending_case_version OR pending.attempt<>latest_attempt THEN
            RAISE EXCEPTION 'Pending quantity revision requires the current original purchase review' USING ERRCODE='23514';
        END IF;
    ELSIF header_status IS DISTINCT FROM 1 OR EXISTS(SELECT 1 FROM procurement_order_approval_cases
            WHERE order_type=NEW.order_type AND order_id=NEW.order_id AND status='PENDING') THEN
        RAISE EXCEPTION 'Approved quantity revision requires an effective order without a pending review' USING ERRCODE='23514';
    END IF;
    IF item IS NULL OR deleted OR COALESCE((item->>'is_deleted')::boolean,FALSE)
       OR NEW.created_txid<>txid_current() OR NEW.before_item IS DISTINCT FROM item
       OR NEW.old_qty IS DISTINCT FROM (item->>'qty')::numeric
       OR NEW.unit_rate IS DISTINCT FROM COALESCE((item->>'unit_rate')::numeric,1)
       OR NEW.approval_attempt_before<>latest_attempt THEN
        RAISE EXCEPTION 'Quantity revision must preserve the current order facts' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

-- Extend existing exact amount/identity and source conservation proofs; approved
-- revisions retain all their existing constraints and post-approval effects.
DO $migration$
DECLARE definition TEXT; anchor TEXT;
BEGIN
    definition:=pg_get_functiondef('fn_is_proven_procurement_qty_revision(text,jsonb,jsonb)'::regprocedure);
    anchor:='WHERE id=$1 AND status=1 AND is_deleted=FALSE';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V963 quantity proof anchor differs'; END IF;
    EXECUTE replace(definition,anchor,'WHERE id=$1 AND status IN (0,1) AND is_deleted=FALSE');

    definition:=pg_get_functiondef('fn_prepare_procurement_source_allocation()'::regprocedure);
    anchor:='expected_peg:=CASE WHEN NEW.after_alloc_qty<NEW.before_alloc_qty';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V963 allocation peg anchor differs'; END IF;
    definition:=replace(definition,anchor,'expected_peg:=CASE WHEN r.pending_case_id IS NOT NULL THEN 0 WHEN NEW.after_alloc_qty<NEW.before_alloc_qty');
    anchor:='IF current_alloc IS NULL OR current_alloc<>NEW.before_alloc_qty';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V963 allocation identity anchor differs'; END IF;
    definition:=replace(definition,anchor,'IF NEW.pending_reservation IS DISTINCT FROM (r.pending_case_id IS NOT NULL)
       OR current_alloc IS NULL OR current_alloc<>NEW.before_alloc_qty');
    anchor:='OR (NEW.after_alloc_qty>NEW.before_alloc_qty AND NEW.after_ordered_qty>source_qty-pending_qty)';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V963 allocation capacity anchor differs'; END IF;
    definition:=replace(definition,anchor,'OR (NEW.after_alloc_qty>NEW.before_alloc_qty AND
        CASE WHEN r.pending_case_id IS NULL THEN NEW.after_ordered_qty>source_qty-pending_qty
        ELSE NEW.after_alloc_qty-NEW.before_alloc_qty>source_qty-COALESCE(current_ordered,0)-pending_qty-
          COALESCE((SELECT SUM(a.after_alloc_qty-a.before_alloc_qty)
            FROM procurement_order_source_revision_allocations a JOIN procurement_order_source_revisions prior ON prior.id=a.revision_id
            WHERE prior.created_txid=txid_current() AND prior.order_type=r.order_type
              AND prior.pending_case_id IS NOT NULL AND a.source_item_id=NEW.source_item_id),0) END)');
    EXECUTE definition;

    definition:=pg_get_functiondef('fn_check_procurement_source_revision()'::regprocedure);
    anchor:='AND c.order_type=r.order_type AND c.order_id=r.order_id AND c.status=''PENDING'' AND c.attempt=r.approval_attempt_before+1
            AND EXISTS(SELECT 1 FROM procurement_order_approval_events e WHERE e.case_id=c.id AND e.event_type=''SUBMITTED''
                AND e.actor_user_id=r.actor_user_id AND e.actor_employee_id=r.actor_employee_id AND e.event_snapshot->>''reconfirmation''=''true'')';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V963 completed revision proof anchor differs'; END IF;
    EXECUTE replace(definition,anchor,'AND c.order_type=r.order_type AND c.order_id=r.order_id AND c.status=''PENDING''
            AND ((r.pending_case_id IS NULL AND c.attempt=r.approval_attempt_before+1
              AND EXISTS(SELECT 1 FROM procurement_order_approval_events e WHERE e.case_id=c.id AND e.event_type=''SUBMITTED''
                AND e.actor_user_id=r.actor_user_id AND e.actor_employee_id=r.actor_employee_id AND e.event_snapshot->>''reconfirmation''=''true''))
              OR (r.pending_case_id=c.id AND r.order_type=''PURCHASE'' AND c.request_type=''ORDER''
                AND c.attempt=r.approval_attempt_before AND c.version=r.pending_case_version+1
                AND EXISTS(SELECT 1 FROM procurement_order_approval_events e WHERE e.case_id=c.id AND e.event_type=''QUANTITY_CHANGED''
                  AND e.actor_user_id=r.actor_user_id AND e.actor_employee_id=r.actor_employee_id
                  AND (e.event_snapshot->>''previousVersion'')::bigint=r.pending_case_version
                  AND e.event_snapshot->>''snapshotHash''=c.snapshot_hash)))');
END
$migration$;

CREATE FUNCTION fn_is_pending_purchase_case_qty_revision(p_old JSONB,p_new JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF jsonb_typeof(p_old #> '{submission_snapshot,items}') IS DISTINCT FROM 'array'
       OR jsonb_typeof(p_new #> '{submission_snapshot,items}') IS DISTINCT FROM 'array' THEN RETURN FALSE; END IF;
    IF p_old->>'order_type'<>'PURCHASE' OR p_old->>'status'<>'PENDING' OR p_new->>'status'<>'PENDING'
       OR p_old->>'request_type'<>'ORDER' OR (p_new->>'version')::bigint<>(p_old->>'version')::bigint+1
       OR (p_old-ARRAY['amount_snapshot','submission_snapshot','snapshot_hash','display_snapshot','version','updated_at'])
          IS DISTINCT FROM (p_new-ARRAY['amount_snapshot','submission_snapshot','snapshot_hash','display_snapshot','version','updated_at'])
       OR ((p_old->'submission_snapshot')-ARRAY['totalOriginal','totalLocal','items'])
          IS DISTINCT FROM ((p_new->'submission_snapshot')-ARRAY['totalOriginal','totalLocal','items']) THEN RETURN FALSE; END IF;
    IF NOT EXISTS(SELECT 1 FROM procurement_order_source_revisions r JOIN purchase_orders h ON h.id=r.order_id
        WHERE r.created_txid=txid_current() AND r.order_type='PURCHASE' AND r.pending_case_id=(p_old->>'id')::uuid
          AND r.pending_case_version=(p_old->>'version')::bigint AND h.status=0 AND NOT h.is_deleted
          AND h.total_local=(p_new->>'amount_snapshot')::numeric
          AND h.total_local=(p_new #>> '{submission_snapshot,totalLocal}')::numeric
          AND h.total_original=(p_new #>> '{submission_snapshot,totalOriginal}')::numeric) THEN RETURN FALSE; END IF;
    IF NOT EXISTS(SELECT 1 FROM procurement_order_approval_events e WHERE e.case_id=(p_old->>'id')::uuid
        AND e.event_type='QUANTITY_CHANGED' AND e.event_snapshot->>'previousSnapshotHash'=p_old->>'snapshot_hash'
        AND (e.event_snapshot->>'previousVersion')::bigint=(p_old->>'version')::bigint
        AND e.event_snapshot->>'snapshotHash'=p_new->>'snapshot_hash'
        AND e.event_snapshot->'previousSubmissionSnapshot'=p_old->'submission_snapshot'
        AND e.event_snapshot->'previousDisplaySnapshot' IS NOT DISTINCT FROM p_old->'display_snapshot') THEN RETURN FALSE; END IF;
    IF jsonb_array_length(p_old #> '{submission_snapshot,items}')<>jsonb_array_length(p_new #> '{submission_snapshot,items}')
       OR (SELECT COUNT(DISTINCT value->>'itemId') FROM jsonb_array_elements(p_new #> '{submission_snapshot,items}'))
          <>jsonb_array_length(p_new #> '{submission_snapshot,items}')
       OR (SELECT COUNT(DISTINCT value->>'itemId') FROM jsonb_array_elements(p_old #> '{submission_snapshot,items}'))
          <>jsonb_array_length(p_old #> '{submission_snapshot,items}')
       OR EXISTS((SELECT value->>'itemId' FROM jsonb_array_elements(p_old #> '{submission_snapshot,items}')
                  EXCEPT SELECT value->>'itemId' FROM jsonb_array_elements(p_new #> '{submission_snapshot,items}'))
           UNION ALL (SELECT value->>'itemId' FROM jsonb_array_elements(p_new #> '{submission_snapshot,items}')
                  EXCEPT SELECT value->>'itemId' FROM jsonb_array_elements(p_old #> '{submission_snapshot,items}')))
       OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_new #> '{submission_snapshot,items}') updated
           LEFT JOIN LATERAL (SELECT value original FROM jsonb_array_elements(p_old #> '{submission_snapshot,items}')
                WHERE value->>'itemId'=updated->>'itemId') previous ON TRUE
           LEFT JOIN purchase_order_items i ON i.id=(updated->>'itemId')::uuid AND i.order_id=(p_old->>'order_id')::uuid AND NOT i.is_deleted
           WHERE previous.original IS NULL OR i.id IS NULL
             OR (previous.original-ARRAY['qty','amountOriginal','amountLocal','totalAmountInput'])
                 IS DISTINCT FROM (updated-ARRAY['qty','amountOriginal','amountLocal','totalAmountInput'])
             OR i.qty IS DISTINCT FROM (updated->>'qty')::numeric
             OR i.amount_original IS DISTINCT FROM (updated->>'amountOriginal')::numeric
             OR i.amount_local IS DISTINCT FROM (updated->>'amountLocal')::numeric
             OR i.total_amount_input IS DISTINCT FROM (updated->>'totalAmountInput')::numeric) THEN RETURN FALSE; END IF;
    RETURN TRUE;
END;
$$;

-- Reuse the current display snapshot builder (including extras, sources, names,
-- and exact values). Only a proven same-transaction pending revision may rebuild it.
DO $migration$
DECLARE definition TEXT; anchor TEXT;
BEGIN
    definition:=pg_get_functiondef('fn_procurement_approval_display_snapshot()'::regprocedure);
    anchor:='IF TG_OP = ''UPDATE'' THEN';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V963 display snapshot update anchor differs'; END IF;
    EXECUTE replace(definition,anchor,'IF TG_OP = ''UPDATE'' AND NOT fn_is_pending_purchase_case_qty_revision(to_jsonb(OLD),to_jsonb(NEW)) THEN');
END
$migration$;

DROP TRIGGER trg_procurement_approval_display_snapshot_immutable ON procurement_order_approval_cases;
CREATE TRIGGER trg_procurement_approval_display_snapshot_immutable
    BEFORE UPDATE OF display_snapshot,submission_snapshot,snapshot_hash,amount_snapshot ON procurement_order_approval_cases
    FOR EACH ROW EXECUTE FUNCTION fn_procurement_approval_display_snapshot();
ALTER TABLE procurement_order_approval_cases ENABLE ALWAYS TRIGGER trg_procurement_approval_display_snapshot_immutable;

CREATE FUNCTION fn_guard_procurement_pending_case_qty_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.submission_snapshot IS DISTINCT FROM OLD.submission_snapshot OR NEW.snapshot_hash IS DISTINCT FROM OLD.snapshot_hash
        OR NEW.amount_snapshot IS DISTINCT FROM OLD.amount_snapshot)
       AND NOT fn_is_pending_purchase_case_qty_revision(to_jsonb(OLD),to_jsonb(NEW)) THEN
        RAISE EXCEPTION 'Submitted review facts require a proven pending quantity revision' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_procurement_pending_case_qty_revision
    BEFORE UPDATE OF submission_snapshot,snapshot_hash,amount_snapshot ON procurement_order_approval_cases
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_pending_case_qty_revision();
ALTER TABLE procurement_order_approval_cases ENABLE ALWAYS TRIGGER trg_guard_procurement_pending_case_qty_revision;

UPDATE permissions SET name='采购订货单受控改量',
    description='待财务审核时修订原审批的数量和来源预占；财务批准后改量立即生效并进入财务复核'
    WHERE code='purchase_order:change_qty';
COMMENT ON COLUMN procurement_order_approval_cases.submission_snapshot IS
    'Current review facts; pending purchase quantity revisions preserve the previous canonical and display snapshots in QUANTITY_CHANGED events and increment version';
CREATE INDEX idx_procurement_pending_qty_revision_case
    ON procurement_order_source_revisions(pending_case_id) WHERE pending_case_id IS NOT NULL;
