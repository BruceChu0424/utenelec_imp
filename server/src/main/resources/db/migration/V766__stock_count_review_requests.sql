-- Inventory count intent and approval evidence. Submission never changes physical stock.
CREATE TABLE stock_count_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_no TEXT NOT NULL UNIQUE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    review_route TEXT NOT NULL CHECK (review_route IN ('FINANCE','WAREHOUSE')),
    status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED','CANCELLED')),
    row_version BIGINT NOT NULL DEFAULT 0,
    submitted_by UUID NOT NULL REFERENCES users(id),
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reason TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
    command_key TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    approval_event_id UUID,
    reviewed_by UUID REFERENCES users(id),
    reviewed_at TIMESTAMPTZ,
    review_reason TEXT,
    stock_document_id UUID REFERENCES stock_documents(id),
    posting_result JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(submitted_by, command_key),
    CHECK ((status='PENDING') = (reviewed_by IS NULL)),
    CHECK ((status='APPROVED') = (approval_event_id IS NOT NULL))
);
CREATE INDEX idx_stock_count_requests_review ON stock_count_requests(review_route,status,submitted_at,id);
CREATE INDEX idx_stock_count_requests_maker ON stock_count_requests(submitted_by,status,submitted_at,id);
CREATE UNIQUE INDEX uq_stock_count_request_stock_document ON stock_count_requests(stock_document_id) WHERE stock_document_id IS NOT NULL;

CREATE TABLE stock_count_request_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id UUID NOT NULL REFERENCES stock_count_requests(id),
    line_no INT NOT NULL CHECK (line_no>0),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    unit_id UUID NOT NULL REFERENCES units(id),
    expected_qty NUMERIC(18,4) NOT NULL,
    expected_weight_kg NUMERIC(18,4),
    expected_weight_estimated BOOLEAN NOT NULL,
    target_qty NUMERIC(18,4) NOT NULL CHECK (target_qty>=0),
    target_weight_kg NUMERIC(18,4) CHECK (target_weight_kg>=0),
    weight_changed BOOLEAN NOT NULL,
    material_setup_basis TEXT CHECK (material_setup_basis IN ('OWN','SHARED','EXPENSE')),
    goods_version BIGINT NOT NULL,
    goods_code TEXT,
    goods_name TEXT NOT NULL,
    color_name TEXT,
    unit_name TEXT NOT NULL,
    kg_per_base_unit NUMERIC(24,12),
    UNIQUE(request_id,line_no),
    UNIQUE NULLS NOT DISTINCT(request_id,goods_id,color_id),
    CHECK (target_qty<>0 OR target_weight_kg IS NULL OR target_weight_kg=0),
    CHECK (target_qty IS DISTINCT FROM expected_qty OR
           (weight_changed AND target_weight_kg IS DISTINCT FROM expected_weight_kg))
);
CREATE INDEX idx_stock_count_request_lines_goods ON stock_count_request_lines(goods_id,color_id,request_id);

CREATE TABLE stock_count_request_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id UUID NOT NULL REFERENCES stock_count_requests(id),
    action TEXT NOT NULL CHECK(action IN ('SUBMIT','APPROVE','REJECT','CANCEL')),
    actor_id UUID NOT NULL REFERENCES users(id),
    event_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reason TEXT,
    request_version BIGINT NOT NULL,
    command_key TEXT NOT NULL,
    UNIQUE(actor_id,command_key)
);
ALTER TABLE stock_count_requests ADD CONSTRAINT fk_stock_count_approval_event
    FOREIGN KEY(approval_event_id) REFERENCES stock_count_request_events(id) DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX idx_stock_count_events_request ON stock_count_request_events(request_id,event_at,id);

CREATE FUNCTION fn_guard_stock_count_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME IN ('stock_count_request_lines','stock_count_request_events') AND TG_OP<>'INSERT' THEN
        RAISE EXCEPTION '盘点申请明细和审核记录不可改写或删除' USING ERRCODE='23514';
    END IF;
    IF TG_TABLE_NAME='stock_count_requests' THEN
        IF TG_OP='DELETE' THEN RAISE EXCEPTION '盘点申请不可删除，请撤回保留记录' USING ERRCODE='23514'; END IF;
        IF TG_OP='UPDATE' AND
           (NEW.id,NEW.request_no,NEW.warehouse_id,NEW.review_route,NEW.submitted_by,NEW.submitted_at,
            NEW.reason,NEW.command_key,NEW.request_hash)
           IS DISTINCT FROM
           (OLD.id,OLD.request_no,OLD.warehouse_id,OLD.review_route,OLD.submitted_by,OLD.submitted_at,
            OLD.reason,OLD.command_key,OLD.request_hash) THEN
            RAISE EXCEPTION '已送审的盘点申请不能更换仓库或改写原始快照' USING ERRCODE='23514';
        END IF;
        IF TG_OP='UPDATE' AND OLD.status<>'PENDING' AND NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION '已办理的盘点申请不可再次流转' USING ERRCODE='23514';
        END IF;
        IF TG_OP='UPDATE' AND OLD.status<>'PENDING' AND
           (OLD.row_version,OLD.reviewed_by,OLD.reviewed_at,OLD.review_reason,OLD.approval_event_id)
             IS DISTINCT FROM (NEW.row_version,NEW.reviewed_by,NEW.reviewed_at,NEW.review_reason,NEW.approval_event_id) THEN
            RAISE EXCEPTION '审核决定不可改写' USING ERRCODE='23514';
        END IF;
        IF TG_OP='UPDATE' AND ((OLD.stock_document_id IS NOT NULL AND OLD.stock_document_id IS DISTINCT FROM NEW.stock_document_id)
             OR (OLD.posting_result IS NOT NULL AND OLD.posting_result IS DISTINCT FROM NEW.posting_result)) THEN
            RAISE EXCEPTION '已批准的库存入账来源不可替换' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_stock_count_header_history BEFORE UPDATE OR DELETE ON stock_count_requests
FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_count_evidence();
CREATE TRIGGER trg_stock_count_line_history BEFORE UPDATE OR DELETE ON stock_count_request_lines
FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_count_evidence();
CREATE TRIGGER trg_stock_count_event_history BEFORE UPDATE OR DELETE ON stock_count_request_events
FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_count_evidence();

CREATE FUNCTION fn_assert_stock_count_approval() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status='APPROVED' AND NOT EXISTS (
        SELECT 1 FROM stock_count_request_events event
        WHERE event.id=NEW.approval_event_id AND event.request_id=NEW.id AND event.action='APPROVE'
          AND event.actor_id=NEW.reviewed_by AND event.request_version=NEW.row_version
    ) THEN
        RAISE EXCEPTION '库存更改缺少本次审核通过的来源证明' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER trg_stock_count_approval AFTER INSERT OR UPDATE ON stock_count_requests
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_stock_count_approval();

INSERT INTO business_identifier_namespaces(namespace_key,identifier_family,fixed_prefix,source_table,identifier_column)
VALUES('STOCK_COUNT_REQUEST','DOCUMENT','PK','stock_count_requests','request_no');
CREATE TRIGGER trg_business_document_stock_count BEFORE INSERT ON stock_count_requests
FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('STOCK_COUNT_REQUEST','request_no','');
CREATE TRIGGER trg_business_document_stock_count_upd BEFORE UPDATE OF request_no ON stock_count_requests
FOR EACH ROW WHEN (OLD.request_no IS DISTINCT FROM NEW.request_no OR NULLIF(btrim(NEW.request_no),'') IS NULL)
EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('request_no','');

SELECT fn_audit_track_table('stock_count_requests','FULL','data_change',false);
SELECT fn_audit_track_table('stock_count_request_lines','FULL','data_change',false);
SELECT fn_audit_track_table('stock_count_request_events','FULL','data_change',false);
DO $reset$ DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')'; BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V766 reset policy anchor changed';
    END IF;
    EXECUTE replace(definition,anchor,anchor
        || E',\n            (''stock_count_requests'', ''CLEAR'')'
        || E',\n            (''stock_count_request_lines'', ''CLEAR'')'
        || E',\n            (''stock_count_request_events'', ''CLEAR'')');
END $reset$;
