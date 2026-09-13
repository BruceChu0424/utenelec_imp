-- Explicit workshop surplus return requests reserve unconsumed original ISSUE
-- slices. Warehouse approval remains the sole GOOD_RETURN / stock-in authority.
CREATE TABLE production_material_return_requests (
    id UUID PRIMARY KEY REFERENCES stock_documents(id) ON DELETE RESTRICT,
    plan_id UUID NOT NULL REFERENCES production_plans(id),
    execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    idempotency_key VARCHAR(128) NOT NULL,
    request_hash CHAR(64) NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
    reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 2 AND 500),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(created_by,idempotency_key,warehouse_id)
);
CREATE TABLE production_material_return_request_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id UUID NOT NULL REFERENCES production_material_return_requests(id),
    stock_document_item_id UUID NOT NULL UNIQUE REFERENCES stock_document_items(id),
    issue_posting_id UUID NOT NULL REFERENCES production_material_stock_postings(id),
    qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(request_id,issue_posting_id)
);
CREATE INDEX idx_material_return_request_issue ON production_material_return_request_items(issue_posting_id);
CREATE INDEX idx_material_return_request_segment ON production_material_return_requests(execution_segment_id,created_at,id);
CREATE FUNCTION fn_is_production_material_return_request(p_document UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_material_return_requests WHERE id=p_document);
$$;
CREATE TABLE production_material_return_request_cancellations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id UUID NOT NULL UNIQUE REFERENCES production_material_return_requests(id),
    idempotency_key VARCHAR(128) NOT NULL,
    request_hash CHAR(64) NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
    reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 2 AND 500),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE FUNCTION fn_material_issue_pending_return(p_issue UUID, p_exclude_document UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(item.qty_base),0)
    FROM production_material_return_request_items item
    JOIN stock_documents document ON document.id=item.request_id
    WHERE item.issue_posting_id=p_issue AND document.status=0 AND NOT document.is_deleted
      AND document.id IS DISTINCT FROM p_exclude_document
      AND NOT EXISTS(SELECT 1 FROM production_material_return_request_cancellations cancellation
                     WHERE cancellation.request_id=document.id);
$$;
CREATE FUNCTION fn_material_issue_available(p_issue UUID, p_exclude_document UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT GREATEST(COALESCE(fn_material_issue_unsettled(p_issue),0)
        -fn_material_issue_pending_return(p_issue,p_exclude_document),0);
$$;

CREATE FUNCTION fn_guard_production_material_return_request() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source production_material_stock_postings%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'Production material return requests are append-only' USING ERRCODE='55000';
    END IF;
    IF TG_TABLE_NAME='production_material_return_requests' THEN
        IF NOT EXISTS(SELECT 1 FROM production_execution_segments segment
            WHERE segment.id=NEW.execution_segment_id AND segment.plan_id=NEW.plan_id
              AND NOT segment.is_deleted AND segment.status IN ('IN_PROGRESS','COMPLETED'))
           OR NOT EXISTS(SELECT 1 FROM stock_documents document WHERE document.id=NEW.id
              AND document.doc_type='WDRAW' AND document.status=0 AND NOT document.is_deleted
              AND document.warehouse_id=NEW.warehouse_id) THEN
            RAISE EXCEPTION 'Surplus return requires a started task; use issue reversal before production starts' USING ERRCODE='23514';
        END IF;
    ELSIF TG_TABLE_NAME='production_material_return_request_items' THEN
        SELECT * INTO source FROM production_material_stock_postings WHERE id=NEW.issue_posting_id FOR UPDATE;
        IF source.id IS NULL OR source.posting_type<>'ISSUE' OR NEW.qty_base>fn_material_issue_available(source.id,NULL)
           OR NOT EXISTS(
              SELECT 1 FROM production_material_return_requests request
              JOIN stock_documents document ON document.id=request.id AND document.doc_type='WDRAW'
              JOIN stock_document_items item ON item.id=NEW.stock_document_item_id AND item.doc_id=document.id
              JOIN stock_document_items original ON original.id=source.stock_document_item_id
              JOIN stock_documents draw ON draw.id=original.doc_id
              JOIN production_material_demands demand ON demand.id=source.demand_id
              WHERE request.id=NEW.request_id AND document.status=0 AND NOT document.is_deleted
                AND demand.plan_id=request.plan_id AND demand.execution_segment_id=request.execution_segment_id
                AND EXISTS(SELECT 1 FROM production_execution_segments segment
                    WHERE segment.id=request.execution_segment_id AND NOT segment.is_deleted
                      AND segment.status IN ('IN_PROGRESS','COMPLETED'))
                AND document.warehouse_id=request.warehouse_id AND document.warehouse_id=draw.warehouse_id
                AND item.upstream_item_id=original.id AND item.goods_id=original.goods_id
                AND item.color_id IS NOT DISTINCT FROM original.color_id
                AND item.unit_id=original.unit_id AND item.unit_rate=original.unit_rate
                AND item.base_qty=NEW.qty_base AND item.qty*item.unit_rate=NEW.qty_base) THEN
            RAISE EXCEPTION 'Return request exceeds available exact issue or changes its warehouse/unit/source' USING ERRCODE='23514';
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
DO $guards$
DECLARE table_name TEXT;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['production_material_return_requests',
        'production_material_return_request_items','production_material_return_request_cancellations'] LOOP
        EXECUTE format('CREATE TRIGGER trg_guard_%I BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_production_material_return_request()',table_name,table_name);
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_guard_%I',table_name,table_name);
        EXECUTE format('CREATE TRIGGER trg_audit_%I AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_audit()',table_name,table_name);
    END LOOP;
END;
$guards$;

-- Keep the V521 provenance checks, adding the pending-request capacity to both
-- settlement and physical return/reversal writers. Receiving a request may use
-- only its own reserved slice, while all other requests remain protected.
DO $capacity$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_material_settlement_issue()'::regprocedure) INTO definition;
    IF position('fn_material_issue_unsettled(issue.id)' IN definition)=0 THEN
        RAISE EXCEPTION 'V560 settlement guard contract changed';
    END IF;
    EXECUTE replace(definition,'fn_material_issue_unsettled(issue.id)','fn_material_issue_available(issue.id,NULL)');
    SELECT pg_get_functiondef('fn_guard_material_return_unsettled_issue()'::regprocedure) INTO definition;
    IF position('fn_material_issue_unsettled(issue)' IN definition)=0 THEN
        RAISE EXCEPTION 'V560 return guard contract changed';
    END IF;
    EXECUTE replace(definition,'fn_material_issue_unsettled(issue)',
        'fn_material_issue_available(issue,CASE WHEN NEW.posting_type=''GOOD_RETURN'' THEN (SELECT doc_id FROM stock_document_items WHERE id=NEW.stock_document_item_id) ELSE NULL END)');
END;
$capacity$;

CREATE FUNCTION fn_guard_requested_material_return_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE requested production_material_return_request_items%ROWTYPE;
BEGIN
    IF NEW.posting_type<>'GOOD_RETURN' THEN RETURN NEW; END IF;
    SELECT * INTO requested FROM production_material_return_request_items WHERE stock_document_item_id=NEW.stock_document_item_id;
    IF requested.id IS NOT NULL AND (NEW.source_posting_id IS DISTINCT FROM requested.issue_posting_id
        OR NEW.qty_base+COALESCE((SELECT sum(qty_base) FROM production_material_stock_postings
            WHERE stock_document_item_id=NEW.stock_document_item_id AND posting_type='GOOD_RETURN'),0)>requested.qty_base) THEN
        RAISE EXCEPTION 'Warehouse receipt must match the exact requested original ISSUE slice' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_requested_material_return_receipt BEFORE INSERT ON production_material_stock_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_requested_material_return_receipt();
ALTER TABLE production_material_stock_postings ENABLE ALWAYS TRIGGER trg_requested_material_return_receipt;

-- Existing production cleanup requires an exact transaction-local document ID;
-- WDRAW additionally requires the newly appended cancellation proof.
DO $cleanup$
DECLARE definition TEXT;needle TEXT:='document.doc_type = ''DRAW''';
BEGIN
    SELECT pg_get_functiondef('fn_is_production_stock_cleanup_authorized(uuid)'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V560 production cleanup contract changed'; END IF;
    EXECUTE replace(definition,needle,
        '(document.doc_type = ''DRAW'' OR (document.doc_type = ''WDRAW'' AND EXISTS(SELECT 1 FROM production_material_return_request_cancellations cancellation WHERE cancellation.request_id=document.id)))');
END;
$cleanup$;

DO $reset_policy$
DECLARE definition TEXT;needle TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V560 business reset contract changed';
    END IF;
    EXECUTE replace(definition,needle,needle || E',\n            (''production_material_return_requests'', ''CLEAR''),\n            (''production_material_return_request_items'', ''CLEAR''),\n            (''production_material_return_request_cancellations'', ''CLEAR'')');
END;
$reset_policy$;

COMMENT ON TABLE production_material_return_requests IS 'Workshop-confirmed surplus return requests; warehouse approval alone records physical good return.';
COMMENT ON TABLE production_material_return_request_items IS 'Exact original ISSUE slices protected from additional settlement or duplicate return until receipt or cancellation.';
