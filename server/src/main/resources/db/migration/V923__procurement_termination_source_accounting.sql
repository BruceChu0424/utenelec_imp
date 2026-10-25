-- Original order/source facts survive termination. Only unfulfilled commitments retire.
CREATE TABLE procurement_order_termination_sources (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id UUID NOT NULL REFERENCES procurement_order_approval_cases(id),
    order_type TEXT NOT NULL CHECK(order_type IN ('PURCHASE','SUBCONTRACT')),
    order_id UUID NOT NULL,
    order_item_id UUID NOT NULL,
    source_row_id UUID,
    source_item_id UUID NOT NULL,
    line_no INTEGER NOT NULL CHECK(line_no>0),
    released_qty NUMERIC(18,4) NOT NULL CHECK(released_qty>=0),
    released_gift_qty NUMERIC(18,4) NOT NULL CHECK(released_gift_qty>=0),
    retained_physical_qty NUMERIC(18,4) NOT NULL CHECK(retained_physical_qty>=0),
    unit_rate NUMERIC(18,6) NOT NULL CHECK(unit_rate>0),
    created_txid BIGINT NOT NULL DEFAULT txid_current(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(order_type,order_item_id,source_item_id),
    CHECK(released_qty+released_gift_qty>0)
);
CREATE INDEX idx_procurement_termination_source_case ON procurement_order_termination_sources(case_id);
CREATE TABLE procurement_order_termination_peg_changes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id UUID NOT NULL REFERENCES procurement_order_approval_cases(id),
    order_type TEXT NOT NULL CHECK(order_type IN ('PURCHASE','SUBCONTRACT')),
    transfer_id UUID NOT NULL,
    source_peg_id UUID NOT NULL REFERENCES production_material_supply_pegs(id),
    target_peg_id UUID NOT NULL REFERENCES production_material_supply_pegs(id),
    qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
    created_txid BIGINT NOT NULL DEFAULT txid_current(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(order_type,transfer_id)
);
CREATE INDEX idx_procurement_termination_peg_case ON procurement_order_termination_peg_changes(case_id);

CREATE FUNCTION fn_keep_terminated_inbound_closed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status='OPEN' AND (
        EXISTS(SELECT 1 FROM purchase_orders o WHERE NEW.order_type='PURCHASE' AND o.id=NEW.order_id AND o.termination_case_id IS NOT NULL)
        OR EXISTS(SELECT 1 FROM subcontract_orders o WHERE NEW.order_type='SUBCONTRACT' AND o.id=NEW.order_id AND o.termination_case_id IS NOT NULL)) THEN
        NEW.status:='CLOSED';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_keep_terminated_inbound_closed BEFORE INSERT OR UPDATE ON inbound_expectations
    FOR EACH ROW EXECUTE FUNCTION fn_keep_terminated_inbound_closed();
ALTER TABLE inbound_expectations ENABLE ALWAYS TRIGGER trg_keep_terminated_inbound_closed;

CREATE FUNCTION fn_guard_procurement_termination_source_fact() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE approval procurement_order_approval_cases%ROWTYPE; prefix TEXT; source_column TEXT;
    source_fact JSONB; item JSONB; qty NUMERIC; gift NUMERIC; closure_item JSONB;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'termination source evidence is immutable' USING ERRCODE='55000'; END IF;
    SELECT * INTO approval FROM procurement_order_approval_cases WHERE id=NEW.case_id;
    IF approval.id IS NULL OR approval.order_type<>NEW.order_type OR approval.status<>'APPROVED'
       OR approval.request_type NOT IN ('CLOSE','CLOSE_AND_REORDER') OR NEW.created_txid<>txid_current()
       OR approval.decided_txid IS DISTINCT FROM txid_current() THEN
        RAISE EXCEPTION 'termination source evidence requires approved closure' USING ERRCODE='23514';
    END IF;
    prefix:=CASE NEW.order_type WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
    source_column:=CASE NEW.order_type WHEN 'PURCHASE' THEN 'request_item_id' ELSE 'application_item_id' END;
    IF TG_TABLE_NAME='procurement_order_termination_sources' THEN
        EXECUTE format('SELECT to_jsonb(i) FROM %I i WHERE i.id=$1 AND i.order_id=$2 AND NOT i.is_deleted',prefix||'_order_items')
            INTO item USING NEW.order_item_id,NEW.order_id;
        IF item IS NULL OR NEW.order_id<>approval.order_id OR NEW.unit_rate IS DISTINCT FROM (item->>'unit_rate')::numeric THEN
            RAISE EXCEPTION 'termination source item identity differs' USING ERRCODE='23514'; END IF;
        SELECT entry INTO closure_item FROM jsonb_array_elements(approval.submission_snapshot->'closureRequest'->'items') entry
            WHERE entry->>'orderItemId'=NEW.order_item_id::text;
        IF closure_item IS NULL OR NEW.released_qty+COALESCE((SELECT SUM(s.released_qty) FROM procurement_order_termination_sources s
                WHERE s.case_id=NEW.case_id AND s.order_item_id=NEW.order_item_id),0)>(closure_item->>'remainingQty')::numeric
            OR NEW.released_gift_qty+COALESCE((SELECT SUM(s.released_gift_qty) FROM procurement_order_termination_sources s
                WHERE s.case_id=NEW.case_id AND s.order_item_id=NEW.order_item_id),0)>(closure_item->>'remainingGiftQty')::numeric THEN
            RAISE EXCEPTION 'termination source release exceeds the reviewed remainder' USING ERRCODE='23514'; END IF;
        IF NEW.source_row_id IS NOT NULL THEN
            EXECUTE format('SELECT to_jsonb(s) FROM %I s WHERE s.id=$1 AND s.order_item_id=$2',prefix||'_order_item_sources')
                INTO source_fact USING NEW.source_row_id,NEW.order_item_id;
            IF source_fact IS NULL OR (source_fact->>source_column)::UUID<>NEW.source_item_id THEN
                RAISE EXCEPTION 'termination source provenance differs' USING ERRCODE='23514'; END IF;
            qty:=(source_fact->>'alloc_qty')::numeric;
            gift:=CASE WHEN NEW.order_type='PURCHASE' AND item->>'quantity_semantics'='CHARGED_PLUS_GIFT_V1'
                THEN COALESCE((source_fact->>'allocated_gift_qty')::numeric,0) ELSE 0 END;
        ELSE
            IF (item->>source_column)::UUID IS DISTINCT FROM NEW.source_item_id THEN
                RAISE EXCEPTION 'termination legacy source differs' USING ERRCODE='23514'; END IF;
            qty:=(item->>'qty')::numeric;
            gift:=CASE WHEN NEW.order_type='PURCHASE' AND item->>'quantity_semantics'='CHARGED_PLUS_GIFT_V1'
                THEN COALESCE((item->>'gift_qty')::numeric,0) ELSE 0 END;
        END IF;
        IF NEW.released_qty>qty OR NEW.released_gift_qty>gift OR
            NEW.retained_physical_qty+NEW.released_qty+NEW.released_gift_qty<>qty+gift THEN
            RAISE EXCEPTION 'termination source quantities do not conserve original share' USING ERRCODE='23514'; END IF;
    ELSE
        EXECUTE format('SELECT to_jsonb(t) FROM %I t WHERE t.id=$1 AND t.status=''EFFECTIVE''',
            CASE NEW.order_type WHEN 'PURCHASE' THEN 'production_material_peg_transfers' ELSE 'production_material_subcontract_peg_transfers' END)
            INTO source_fact USING NEW.transfer_id;
        IF source_fact IS NULL OR (source_fact->>'from_peg_id')::UUID<>NEW.source_peg_id
           OR (source_fact->>'to_peg_id')::UUID<>NEW.target_peg_id OR NOT EXISTS (
               SELECT 1 FROM procurement_order_termination_sources s WHERE s.case_id=NEW.case_id
                 AND s.order_item_id=(source_fact->>'order_item_id')::UUID
                 AND s.source_item_id=(source_fact->>source_column)::UUID) THEN
            RAISE EXCEPTION 'termination peg provenance differs' USING ERRCODE='23514'; END IF;
        IF NEW.qty_base>fn_procurement_transfer_net_qty(NEW.order_type,NEW.transfer_id) THEN
            RAISE EXCEPTION 'termination release exceeds original transfer' USING ERRCODE='23514'; END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_procurement_termination_sources BEFORE INSERT OR UPDATE OR DELETE ON procurement_order_termination_sources
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_termination_source_fact();
CREATE TRIGGER trg_guard_procurement_termination_pegs BEFORE INSERT OR UPDATE OR DELETE ON procurement_order_termination_peg_changes
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_termination_source_fact();

CREATE FUNCTION fn_check_procurement_termination_source_complete() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE approval procurement_order_approval_cases%ROWTYPE; prefix TEXT; marker UUID;
    closure_item JSONB; paid NUMERIC; gift NUMERIC;
BEGIN
    SELECT * INTO approval FROM procurement_order_approval_cases WHERE id=NEW.case_id;
    prefix:=CASE NEW.order_type WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
    EXECUTE format('SELECT termination_case_id FROM %I WHERE id=$1',prefix||'_orders') INTO marker USING approval.order_id;
    IF marker IS DISTINCT FROM NEW.case_id THEN
        RAISE EXCEPTION 'termination source release did not close its original order' USING ERRCODE='23514'; END IF;
    IF TG_TABLE_NAME='procurement_order_termination_sources' THEN
        SELECT entry INTO closure_item FROM jsonb_array_elements(approval.submission_snapshot->'closureRequest'->'items') entry
            WHERE entry->>'orderItemId'=NEW.order_item_id::text;
        SELECT SUM(released_qty),SUM(released_gift_qty) INTO paid,gift FROM procurement_order_termination_sources
            WHERE case_id=NEW.case_id AND order_item_id=NEW.order_item_id;
        IF paid IS DISTINCT FROM (closure_item->>'remainingQty')::numeric
           OR gift IS DISTINCT FROM (closure_item->>'remainingGiftQty')::numeric THEN
            RAISE EXCEPTION 'termination source release differs from the reviewed remainder' USING ERRCODE='23514'; END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_check_procurement_termination_sources AFTER INSERT ON procurement_order_termination_sources
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_procurement_termination_source_complete();
CREATE CONSTRAINT TRIGGER trg_check_procurement_termination_pegs AFTER INSERT ON procurement_order_termination_peg_changes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_procurement_termination_source_complete();

CREATE OR REPLACE FUNCTION fn_procurement_transfer_net_qty(p_type TEXT,p_id UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT transferred_qty FROM production_material_peg_transfers WHERE p_type='PURCHASE' AND id=p_id),
                    (SELECT transferred_qty FROM production_material_subcontract_peg_transfers WHERE p_type='SUBCONTRACT' AND id=p_id),0)
        +COALESCE((SELECT SUM(qty_delta_base) FROM procurement_order_source_revision_peg_changes
                   WHERE order_type=p_type AND transfer_id=p_id AND change_kind='ADJUST'),0)
        -COALESCE((SELECT SUM(qty_base) FROM procurement_order_termination_peg_changes WHERE order_type=p_type AND transfer_id=p_id),0)
$$;
CREATE OR REPLACE FUNCTION fn_procurement_transfer_released_qty(p_type TEXT,p_id UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT SUM(GREATEST(-qty_delta_base,0)) FROM procurement_order_source_revision_peg_changes
        WHERE order_type=p_type AND transfer_id=p_id AND change_kind='ADJUST'),0)
        +COALESCE((SELECT SUM(qty_base) FROM procurement_order_termination_peg_changes WHERE order_type=p_type AND transfer_id=p_id),0)
$$;

-- An approved replacement draft keeps its source share until submitted, changed or deleted.
CREATE FUNCTION fn_procurement_order_reserves_source(p_type TEXT,p_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE(fn_procurement_order_latest_approval_status(p_type,p_id) IN ('PENDING','REJECTED'),FALSE)
        OR EXISTS(SELECT 1 FROM procurement_order_approval_cases c WHERE c.order_type=p_type
            AND c.replacement_order_id=p_id AND c.request_type='CLOSE_AND_REORDER' AND c.status='APPROVED')
$$;

-- Regenerate only the current live projection and function, leaving every historical migration untouched.
DO $$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_viewdef('v_procurement_decomposition_tasks'::regclass,TRUE) INTO definition;
    IF strpos(definition,'fn_procurement_order_latest_approval_status(''PURCHASE''::text, po.id) = ANY (ARRAY[''PENDING''::text, ''REJECTED''::text])')=0
       OR strpos(definition,'fn_procurement_order_latest_approval_status(''SUBCONTRACT''::text, so.id) = ANY (ARRAY[''PENDING''::text, ''REJECTED''::text])')=0 THEN
        RAISE EXCEPTION 'Procurement pending-source projection anchors changed';
    END IF;
    definition:=replace(definition,
        '(fn_procurement_order_latest_approval_status(''PURCHASE''::text, po.id) = ANY (ARRAY[''PENDING''::text, ''REJECTED''::text]))',
        'fn_procurement_order_reserves_source(''PURCHASE'',po.id)');
    definition:=replace(definition,
        '(fn_procurement_order_latest_approval_status(''SUBCONTRACT''::text, so.id) = ANY (ARRAY[''PENDING''::text, ''REJECTED''::text]))',
        'fn_procurement_order_reserves_source(''SUBCONTRACT'',so.id)');
    definition:=regexp_replace(definition,
        '(WHEN[[:space:]]+)(\(?fn_procurement_order_latest_approval_status\(''PURCHASE''::text, po.id\)[[:space:]]*=[[:space:]]*''PENDING''::text\)?)',
        'WHEN po.termination_case_id IS NOT NULL THEN ''COMPLETED''::text \1\2');
    definition:=regexp_replace(definition,
        '(WHEN[[:space:]]+)(\(?fn_procurement_order_latest_approval_status\(''SUBCONTRACT''::text, so.id\)[[:space:]]*=[[:space:]]*''PENDING''::text\)?)',
        'WHEN so.termination_case_id IS NOT NULL THEN ''COMPLETED''::text \1\2');
    IF strpos(definition,'WHEN po.termination_case_id IS NOT NULL THEN ''COMPLETED''::text')=0
       OR strpos(definition,'WHEN so.termination_case_id IS NOT NULL THEN ''COMPLETED''::text')=0 THEN
        RAISE EXCEPTION 'Procurement terminal-status projection anchors changed';
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW v_procurement_decomposition_tasks AS '||definition;
END;
$$;

-- A terminated promise has no future delivery capacity, including the physical IQC-return path.
DO $$
DECLARE definition TEXT; anchor TEXT:='header.is_deleted=FALSE AND header.status=1';
BEGIN
    SELECT pg_get_functiondef('fn_procurement_order_source_remaining_qty(text,uuid,uuid)'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>2 THEN
        RAISE EXCEPTION 'Procurement future capacity authority anchors changed';
    END IF;
    EXECUTE replace(definition,anchor,anchor||' AND header.termination_case_id IS NULL');
END;
$$;
CREATE OR REPLACE FUNCTION fn_subcontract_application_open_qty(p_application_item UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT GREATEST(COALESCE(item.qty,0)-COALESCE(item.ordered_qty,0)-COALESCE((
        SELECT SUM(source.alloc_qty) FROM subcontract_order_item_sources source
        JOIN subcontract_order_items oi ON oi.id=source.order_item_id AND NOT oi.is_deleted
        JOIN subcontract_orders o ON o.id=oi.order_id AND o.status=0 AND NOT o.is_deleted
        WHERE source.application_item_id=item.id AND fn_procurement_order_reserves_source('SUBCONTRACT',o.id)),0),0)
        FROM subcontract_application_items item JOIN subcontract_applications h ON h.id=item.application_id
        WHERE item.id=p_application_item AND NOT item.is_deleted AND h.status=1 AND NOT h.is_deleted AND NOT h.is_closed),0)
$$;

SELECT fn_register_record_retention('procurement_order_termination_sources',NULL,NULL);
SELECT fn_register_record_retention('procurement_order_termination_peg_changes',NULL,NULL);
SELECT fn_audit_track_table('procurement_order_termination_sources','FULL','data_change',false);
SELECT fn_audit_track_table('procurement_order_termination_peg_changes','FULL','data_change',false);

-- Validate the current V670/V830 three-list policy across the entire public catalog.
-- Preserve intentional NONE tables and COLUMN_SCOPED writers; FULL uses the central trigger pair.
DO $verify_audit_coverage$ DECLARE invalid TEXT; BEGIN
    SELECT string_agg(c.relname||':'||t.tgname,', ' ORDER BY c.relname,t.tgname) INTO invalid
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_trigger t ON t.tgrelid=c.oid
    WHERE n.nspname='public' AND c.relkind IN ('r','p') AND NOT c.relispartition
      AND NOT t.tgisinternal AND t.tgparentid=0
      AND t.tgfoid IN ('public.fn_audit()'::regprocedure,'public.fn_audit_route_columns()'::regprocedure)
      AND (t.tgenabled<>'A' OR t.tgname NOT IN (left('trg_audit_'||c.relname,63),left('trg_audit_upd_'||c.relname,63))
          OR (t.tgname=left('trg_audit_upd_'||c.relname,63) AND (t.tgqual IS NULL OR t.tgtype::INTEGER<>17))
          OR (t.tgname=left('trg_audit_'||c.relname,63) AND (t.tgqual IS NOT NULL OR t.tgtype::INTEGER<>13)));
    IF invalid IS NOT NULL THEN RAISE EXCEPTION 'V923 audit coverage shape is invalid: %',invalid; END IF;
    IF EXISTS(SELECT table_name FROM unnest(ARRAY['procurement_order_termination_sources','procurement_order_termination_peg_changes']) table_name
       WHERE (SELECT count(*) FROM pg_trigger t WHERE t.tgrelid=table_name::regclass AND NOT t.tgisinternal
           AND t.tgfoid='public.fn_audit()'::regprocedure AND t.tgenabled='A')<>2) THEN
        RAISE EXCEPTION 'V923 termination evidence requires the complete FULL audit pair';
    END IF;
END $verify_audit_coverage$;
