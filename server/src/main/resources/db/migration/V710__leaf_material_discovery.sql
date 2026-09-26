-- Leaf MAKE tasks require a warehouse-defined, real material source before START.
-- Existing started/history tasks retain their frozen zero-material evidence.
ALTER TABLE production_execution_segments ADD COLUMN material_discovery_required BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE production_material_discovery_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    status TEXT NOT NULL DEFAULT 'PENDING' CHECK(status IN('PENDING','CONFIGURED','CANCELLED')),
    expected_version BIGINT NOT NULL,
    row_version BIGINT NOT NULL DEFAULT 0,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    idempotency_key TEXT NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    configured_by UUID REFERENCES users(id),
    configured_at TIMESTAMPTZ,
    configuration_key TEXT,
    configuration_hash VARCHAR(64),
    cancelled_by UUID REFERENCES users(id),
    cancelled_at TIMESTAMPTZ,
    cancellation_key TEXT,
    cancellation_hash VARCHAR(64),
    UNIQUE(created_by,idempotency_key),
    UNIQUE(configured_by,configuration_key),
    UNIQUE(cancelled_by,cancellation_key),
    CHECK((status='PENDING' AND configured_by IS NULL AND configured_at IS NULL AND configuration_key IS NULL AND configuration_hash IS NULL)
       OR (status='CONFIGURED' AND configured_by IS NOT NULL AND configured_at IS NOT NULL AND configuration_key IS NOT NULL AND configuration_hash IS NOT NULL)
       OR (status='CANCELLED' AND cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL AND cancellation_key IS NOT NULL AND cancellation_hash IS NOT NULL AND configured_by IS NULL))
);
CREATE UNIQUE INDEX uq_material_discovery_active_segment ON production_material_discovery_requests(execution_segment_id) WHERE status<>'CANCELLED';
CREATE INDEX idx_material_discovery_pending ON production_material_discovery_requests(created_at,id) WHERE status='PENDING';
CREATE TABLE production_material_discovery_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id UUID NOT NULL REFERENCES production_material_discovery_requests(id),
    demand_id UUID NOT NULL REFERENCES production_material_demands(id) DEFERRABLE INITIALLY DEFERRED,
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    unit_id UUID NOT NULL REFERENCES units(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    qty NUMERIC(18,4) NOT NULL CHECK(qty>0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT(request_id,goods_id,color_id,warehouse_id)
);
CREATE INDEX idx_material_discovery_line_demand ON production_material_discovery_lines(demand_id);
CREATE FUNCTION fn_guard_material_discovery_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' OR TG_TABLE_NAME='production_material_discovery_lines' THEN
        RAISE EXCEPTION 'Material discovery evidence is append-only' USING ERRCODE='23514';
    END IF;
    IF OLD.status<>'PENDING' OR NEW.status NOT IN('CONFIGURED','CANCELLED')
       OR (NEW.id,NEW.execution_segment_id,NEW.expected_version,NEW.created_by,NEW.created_at,NEW.idempotency_key,NEW.request_hash)
          IS DISTINCT FROM (OLD.id,OLD.execution_segment_id,OLD.expected_version,OLD.created_by,OLD.created_at,OLD.idempotency_key,OLD.request_hash)
       OR NEW.row_version<>OLD.row_version+1 THEN
        RAISE EXCEPTION 'Invalid material discovery transition' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_material_discovery_requests_history BEFORE UPDATE OR DELETE ON production_material_discovery_requests FOR EACH ROW EXECUTE FUNCTION fn_guard_material_discovery_history();
CREATE TRIGGER trg_material_discovery_lines_history BEFORE UPDATE OR DELETE ON production_material_discovery_lines FOR EACH ROW EXECUTE FUNCTION fn_guard_material_discovery_history();

UPDATE production_execution_segments segment SET material_discovery_required=TRUE
WHERE material_requirement_mode='ZERO_MATERIAL' AND zero_material_reason='DIRECT_MAKE'
  AND status IN('WAITING','READY','DISPATCHED') AND NOT is_deleted
  AND source_segment_id IS NULL
  AND NOT EXISTS(SELECT 1 FROM production_daily_report_items report WHERE report.execution_segment_id=segment.id)
  AND NOT EXISTS(SELECT 1 FROM production_material_demands demand WHERE demand.execution_segment_id=segment.id)
  AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof WHERE proof.supplement_execution_segment_id=segment.id);

CREATE FUNCTION fn_mark_material_discovery() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.material_requirement_mode='ZERO_MATERIAL' AND NEW.zero_material_reason='DIRECT_MAKE' AND NEW.source_segment_id IS NULL
       AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof WHERE proof.supplement_execution_segment_id=NEW.id) THEN
        NEW.material_discovery_required:=TRUE;
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_mark_material_discovery BEFORE INSERT ON production_execution_segments FOR EACH ROW EXECUTE FUNCTION fn_mark_material_discovery();
CREATE FUNCTION fn_material_discovery_pending(p_segment UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT material_discovery_required AND material_requirement_mode='ZERO_MATERIAL'
        FROM production_execution_segments WHERE id=p_segment AND NOT is_deleted),FALSE);
$$;

-- Keep the mature material and custody functions intact; intercept only the new pending state.
ALTER FUNCTION fn_execution_start_material_ready(UUID) RENAME TO fn_execution_start_material_ready_before_discovery;
CREATE FUNCTION fn_execution_start_material_ready(p_segment UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT NOT fn_material_discovery_pending(p_segment) AND fn_execution_start_material_ready_before_discovery(p_segment);
$$;
ALTER FUNCTION fn_can_split_execution_batch(UUID) RENAME TO fn_can_split_execution_batch_before_discovery;
CREATE FUNCTION fn_can_split_execution_batch(p_segment UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT NOT fn_material_discovery_pending(p_segment) AND fn_can_split_execution_batch_before_discovery(p_segment);
$$;

CREATE FUNCTION fn_guard_discovery_start() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='UPDATE' AND OLD.material_discovery_required AND NOT NEW.material_discovery_required THEN
        RAISE EXCEPTION 'Material discovery origin is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.status='IN_PROGRESS' AND NEW.material_requirement_mode='ZERO_MATERIAL'
       AND (NEW.material_discovery_required OR (TG_OP='INSERT' AND NEW.zero_material_reason='DIRECT_MAKE' AND NEW.source_segment_id IS NULL
            AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof WHERE proof.supplement_execution_segment_id=NEW.id))) THEN
        RAISE EXCEPTION '请先提交领料，由仓库登记实际物料并发料后再开工' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_discovery_start BEFORE UPDATE OF status,material_discovery_required ON production_execution_segments FOR EACH ROW EXECUTE FUNCTION fn_guard_discovery_start();
CREATE TRIGGER trg_guard_discovery_insert BEFORE INSERT ON production_execution_segments FOR EACH ROW EXECUTE FUNCTION fn_guard_discovery_start();

DO $conversion$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_execution_segment_requirement_shape()'::regprocedure) INTO definition;
    needle:=E'BEGIN\n';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V710 frozen material guard anchor changed'; END IF;
    EXECUTE replace(definition,needle,needle||'
    IF TG_OP=''UPDATE'' AND OLD.material_discovery_required
       AND OLD.material_requirement_mode=''ZERO_MATERIAL'' AND OLD.zero_material_reason=''DIRECT_MAKE''
       AND NEW.material_requirement_mode=''DEMANDED'' AND OLD.status IN(''READY'',''DISPATCHED'')
       AND NEW.status=OLD.status AND NOT OLD.is_deleted
       AND EXISTS(SELECT 1 FROM production_material_discovery_requests request
           JOIN production_material_discovery_lines line ON line.request_id=request.id
           JOIN production_material_demands demand ON demand.id=line.demand_id
           WHERE request.execution_segment_id=OLD.id AND request.status=''CONFIGURED''
             AND demand.execution_segment_id=OLD.id AND NOT demand.is_deleted)
       AND NOT EXISTS(SELECT 1 FROM production_daily_report_items report WHERE report.execution_segment_id=OLD.id) THEN
        RETURN NEW;
    END IF;
');
END; $conversion$;

CREATE FUNCTION fn_assert_material_discovery_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_request UUID; request production_material_discovery_requests%ROWTYPE;
BEGIN
    IF TG_TABLE_NAME='production_material_discovery_requests' THEN target_request:=NEW.id;
    ELSE target_request:=NEW.request_id; END IF;
    SELECT * INTO request FROM production_material_discovery_requests WHERE id=target_request;
    IF request.status='CONFIGURED' AND (
       NOT EXISTS(SELECT 1 FROM production_material_discovery_lines WHERE production_material_discovery_lines.request_id=request.id)
       OR EXISTS(SELECT 1 FROM production_material_discovery_lines line
           LEFT JOIN production_material_demands demand ON demand.id=line.demand_id
           JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
           WHERE line.request_id=request.id AND (demand.id IS NULL OR demand.is_deleted
               OR NOT segment.material_discovery_required OR segment.material_requirement_mode<>'DEMANDED'
               OR (demand.execution_segment_id,demand.goods_id,demand.color_id,demand.unit_id)
                   IS DISTINCT FROM (segment.id,line.goods_id,line.color_id,line.unit_id)
               OR demand.required_qty<>(SELECT SUM(source.qty) FROM production_material_discovery_lines source WHERE source.demand_id=demand.id)))
    ) THEN RAISE EXCEPTION 'Discovery materials must own exact real demands' USING ERRCODE='23514'; END IF;
    RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER trg_material_discovery_request_source AFTER INSERT OR UPDATE ON production_material_discovery_requests DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_material_discovery_source();
CREATE CONSTRAINT TRIGGER trg_material_discovery_line_source AFTER INSERT ON production_material_discovery_lines DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_material_discovery_source();

-- Source cancellation/stop and later resume must resolve or redeliver the same
-- warehouse card even when no discovery API is called. Delivery reads final state.
CREATE FUNCTION fn_queue_material_discovery_visibility() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO business_outbox(id,event_type,aggregate_type,aggregate_id,payload,dedupe_key,created_by)
    SELECT gen_random_uuid(),'PRODUCTION_MATERIAL_DISCOVERY_VISIBILITY','PRODUCTION_MATERIAL_DISCOVERY_REQUEST',request.id,'{}'::jsonb,
           'MATERIAL_DISCOVERY_VISIBILITY:'||request.id||':'||txid_current(),
           NULLIF(current_setting('app.user_id',TRUE),'')::uuid
    FROM production_material_discovery_requests request
    JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
    WHERE request.status='PENDING' AND (CASE WHEN TG_TABLE_NAME='production_plans' THEN segment.plan_id=NEW.id ELSE segment.id=NEW.id END)
    ON CONFLICT(dedupe_key) DO NOTHING;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_plan_material_discovery_visibility AFTER UPDATE OF status,is_closed,is_canceled,is_stopped,is_deleted ON production_plans
FOR EACH ROW WHEN ((OLD.status,OLD.is_closed,OLD.is_canceled,OLD.is_stopped,OLD.is_deleted) IS DISTINCT FROM (NEW.status,NEW.is_closed,NEW.is_canceled,NEW.is_stopped,NEW.is_deleted)) EXECUTE FUNCTION fn_queue_material_discovery_visibility();
CREATE TRIGGER trg_segment_material_discovery_visibility AFTER UPDATE OF status,is_deleted,workshop_department_id ON production_execution_segments
FOR EACH ROW WHEN ((OLD.status,OLD.is_deleted,OLD.workshop_department_id) IS DISTINCT FROM (NEW.status,NEW.is_deleted,NEW.workshop_department_id)) EXECUTE FUNCTION fn_queue_material_discovery_visibility();

SELECT fn_audit_track_table('production_material_discovery_requests','FULL','data_change',false);
SELECT fn_audit_track_table('production_material_discovery_lines','NONE','data_change',false);
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V710 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n (''production_material_discovery_requests'', ''CLEAR''),\n (''production_material_discovery_lines'', ''CLEAR'')');
END;
$reset_policy$;
