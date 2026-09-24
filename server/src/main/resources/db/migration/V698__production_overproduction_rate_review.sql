-- The workshop may request a tolerance change; only planning approval changes
-- the effective rate. Snapshots and decisions remain immutable history.
ALTER TABLE production_execution_segments
    ADD COLUMN allowed_overproduction_rate NUMERIC(9,6) NOT NULL DEFAULT 0.10,
    ADD COLUMN overproduction_rate_version BIGINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT execution_overproduction_rate_nonnegative CHECK (
        allowed_overproduction_rate>=0 AND allowed_overproduction_rate<'Infinity'::numeric
        AND overproduction_rate_version>=0);

-- Later fixed actual-output supplements refine this predicate using their proof.
CREATE FUNCTION fn_execution_overproduction_policy_applies(p_segment UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_execution_segments WHERE id=p_segment)
$$;

CREATE FUNCTION fn_initialize_execution_overproduction_rate() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE inherited NUMERIC;
BEGIN
    IF NEW.source_segment_id IS NOT NULL THEN
        SELECT allowed_overproduction_rate INTO inherited FROM production_execution_segments
        WHERE id=NEW.source_segment_id FOR SHARE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Production batch tolerance needs its original task' USING ERRCODE='23514'; END IF;
        NEW.allowed_overproduction_rate:=inherited;
        NEW.overproduction_rate_version:=0;
    ELSIF NEW.allowed_overproduction_rate IS DISTINCT FROM 0.10 OR NEW.overproduction_rate_version<>0 THEN
        RAISE EXCEPTION 'New tasks start with default tolerance; changes require planning review' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_initialize_execution_overproduction_rate BEFORE INSERT ON production_execution_segments
    FOR EACH ROW EXECUTE FUNCTION fn_initialize_execution_overproduction_rate();

CREATE TABLE production_overproduction_rate_requests (
    id UUID PRIMARY KEY,
    execution_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    before_rate NUMERIC(9,6) NOT NULL CHECK(before_rate>=0 AND before_rate<'Infinity'::numeric),
    requested_rate NUMERIC(9,6) NOT NULL CHECK(requested_rate>=0 AND requested_rate<'Infinity'::numeric),
    expected_rate_version BIGINT NOT NULL CHECK(expected_rate_version>=0),
    planned_qty NUMERIC(18,4) NOT NULL CHECK(planned_qty>0),
    before_snapshot JSONB NOT NULL CHECK(jsonb_typeof(before_snapshot)='object'),
    after_snapshot JSONB NOT NULL CHECK(jsonb_typeof(after_snapshot)='object'),
    reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 2 AND 500),
    status TEXT NOT NULL DEFAULT 'PENDING' CHECK(status IN('PENDING','APPROVED','RETURNED')),
    row_version BIGINT NOT NULL DEFAULT 0 CHECK(row_version>=0),
    idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 128),
    request_hash TEXT NOT NULL CHECK(request_hash~'^[0-9a-f]{64}$'),
    submitted_by UUID NOT NULL REFERENCES users(id),
    submitted_by_employee_id UUID NOT NULL REFERENCES employees(id),
    submitted_by_name TEXT NOT NULL,
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_production_rate_submit UNIQUE(submitted_by,idempotency_key),
    CHECK(before_rate<>requested_rate)
);
CREATE UNIQUE INDEX uq_production_rate_pending ON production_overproduction_rate_requests(execution_segment_id)
    WHERE status='PENDING';
CREATE INDEX idx_production_rate_queue ON production_overproduction_rate_requests(status,submitted_at,id);
CREATE INDEX idx_production_rate_history ON production_overproduction_rate_requests(execution_segment_id,submitted_at DESC);

CREATE TABLE production_overproduction_rate_decisions (
    id UUID PRIMARY KEY,
    request_id UUID NOT NULL UNIQUE REFERENCES production_overproduction_rate_requests(id),
    decision TEXT NOT NULL CHECK(decision IN('APPROVED','RETURNED')),
    reason TEXT CHECK(length(reason)<=500),
    expected_version BIGINT NOT NULL CHECK(expected_version>=0),
    decided_by UUID NOT NULL REFERENCES users(id),
    decided_by_employee_id UUID NOT NULL REFERENCES employees(id),
    decided_by_name TEXT NOT NULL,
    decided_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 128),
    request_hash TEXT NOT NULL CHECK(request_hash~'^[0-9a-f]{64}$'),
    CONSTRAINT uq_production_rate_decision_command UNIQUE(decided_by,idempotency_key),
    CHECK(decision<>'RETURNED' OR (reason IS NOT NULL AND length(btrim(reason))>=2))
);

-- Read projection, application approval and database application share this
-- business eligibility rule. It deliberately does not grant caller authority.
CREATE FUNCTION fn_production_rate_request_ready(p_request UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_overproduction_rate_requests request
        JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
        JOIN production_plans plan ON plan.id=segment.plan_id
        JOIN production_planning_packages package ON package.id=segment.package_id
        WHERE request.id=p_request AND request.status='PENDING' AND NOT segment.is_deleted
          AND segment.status IN('WAITING','READY','DISPATCHED','IN_PROGRESS')
          AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_closed AND NOT plan.is_stopped AND NOT plan.is_canceled
          AND package.status='CONFIRMED' AND NOT package.is_deleted
          AND segment.planned_qty=request.planned_qty AND segment.allowed_overproduction_rate=request.before_rate
          AND segment.overproduction_rate_version=request.expected_rate_version
          AND (request.before_snapshot->>'workshopDepartmentId') IS NOT DISTINCT FROM segment.workshop_department_id::text
          AND (request.before_snapshot->>'responsibleEmployeeId') IS NOT DISTINCT FROM segment.responsible_employee_id::text
          AND (request.before_snapshot#>>'{items,0,goodsId}') IS NOT DISTINCT FROM segment.product_goods_id::text
          AND (request.before_snapshot#>>'{items,0,colorId}') IS NOT DISTINCT FROM segment.product_color_id::text
          AND (request.before_snapshot#>>'{items,0,unitId}') IS NOT DISTINCT FROM segment.product_unit_id::text
          AND (request.before_snapshot#>>'{items,0,unitRate}')::numeric IS NOT DISTINCT FROM segment.product_unit_rate
          AND fn_execution_overproduction_policy_applies(segment.id)
          AND fn_execution_actual_surplus_qty(segment.id,TRUE)<=trunc(segment.planned_qty*request.requested_rate,4))
$$;

CREATE FUNCTION fn_guard_production_rate_request() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE segment production_execution_segments%ROWTYPE;
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Production rate requests are immutable history' USING ERRCODE='23514'; END IF;
    IF TG_OP='UPDATE' THEN
        IF (to_jsonb(NEW)-ARRAY['status','row_version']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','row_version'])
           OR OLD.status<>'PENDING' OR NEW.status NOT IN('APPROVED','RETURNED')
           OR NEW.row_version<>OLD.row_version+1
           OR NOT EXISTS(SELECT 1 FROM production_overproduction_rate_decisions decision
               WHERE decision.request_id=OLD.id AND decision.decision=NEW.status
                 AND decision.expected_version=OLD.row_version) THEN
            RAISE EXCEPTION 'Production rate request may only resolve through its exact planning decision' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    SELECT * INTO segment FROM production_execution_segments WHERE id=NEW.execution_segment_id FOR UPDATE;
    IF NOT FOUND OR segment.is_deleted OR NOT fn_execution_overproduction_policy_applies(segment.id)
       OR NEW.status<>'PENDING' OR NEW.row_version<>0
       OR segment.allowed_overproduction_rate IS DISTINCT FROM NEW.before_rate
       OR segment.overproduction_rate_version IS DISTINCT FROM NEW.expected_rate_version
       OR segment.planned_qty IS DISTINCT FROM NEW.planned_qty THEN
        RAISE EXCEPTION 'Production rate request does not match the current execution snapshot' USING ERRCODE='23514';
    END IF;
    IF jsonb_array_length(COALESCE(NEW.before_snapshot->'items','[]'::jsonb))<>1
       OR jsonb_array_length(COALESCE(NEW.after_snapshot->'items','[]'::jsonb))<>1
       OR (NEW.before_snapshot#>>'{items,0,allowedOverproductionRate}')::numeric IS DISTINCT FROM NEW.before_rate
       OR (NEW.after_snapshot#>>'{items,0,allowedOverproductionRate}')::numeric IS DISTINCT FROM NEW.requested_rate
       OR (NEW.before_snapshot#>>'{items,0,itemId}') IS DISTINCT FROM segment.id::text
       OR (NEW.after_snapshot#>>'{items,0,itemId}') IS DISTINCT FROM segment.id::text
       OR (NEW.before_snapshot->>'planId') IS DISTINCT FROM segment.plan_id::text
       OR (NEW.before_snapshot->>'workshopDepartmentId') IS DISTINCT FROM segment.workshop_department_id::text
       OR (NEW.before_snapshot->>'responsibleEmployeeId') IS DISTINCT FROM segment.responsible_employee_id::text
       OR (NEW.before_snapshot#>>'{items,0,goodsId}') IS DISTINCT FROM segment.product_goods_id::text
       OR (NEW.before_snapshot#>>'{items,0,colorId}') IS DISTINCT FROM segment.product_color_id::text
       OR (NEW.before_snapshot#>>'{items,0,unitId}') IS DISTINCT FROM segment.product_unit_id::text
       OR (NEW.before_snapshot#>>'{items,0,plannedQty}')::numeric IS DISTINCT FROM segment.planned_qty
       OR (NEW.before_snapshot#>>'{items,0,unitRate}')::numeric IS DISTINCT FROM segment.product_unit_rate
       OR (NEW.before_snapshot#>>'{items,0,allowedTotalQty}')::numeric IS DISTINCT FROM trunc(segment.planned_qty*(1+NEW.before_rate),4)
       OR (NEW.after_snapshot#>>'{items,0,allowedTotalQty}')::numeric IS DISTINCT FROM trunc(segment.planned_qty*(1+NEW.requested_rate),4)
       OR (NEW.before_snapshot-'items') IS DISTINCT FROM (NEW.after_snapshot-'items')
       OR ((NEW.before_snapshot#>'{items,0}')-ARRAY['allowedOverproductionRate','allowedTotalQty'])
           IS DISTINCT FROM ((NEW.after_snapshot#>'{items,0}')-ARRAY['allowedOverproductionRate','allowedTotalQty']) THEN
        RAISE EXCEPTION 'Production rate review snapshots must contain the exact old and requested values' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_production_rate_request BEFORE INSERT OR UPDATE OR DELETE
    ON production_overproduction_rate_requests FOR EACH ROW EXECUTE FUNCTION fn_guard_production_rate_request();

CREATE FUNCTION fn_guard_production_effective_rate() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.allowed_overproduction_rate,NEW.overproduction_rate_version)
       IS NOT DISTINCT FROM (OLD.allowed_overproduction_rate,OLD.overproduction_rate_version) THEN RETURN NEW; END IF;
    IF NEW.overproduction_rate_version<>OLD.overproduction_rate_version+1
       OR NOT EXISTS(SELECT 1 FROM production_overproduction_rate_requests request
            JOIN production_overproduction_rate_decisions decision ON decision.request_id=request.id
            WHERE request.execution_segment_id=OLD.id AND decision.decision='APPROVED'
              AND request.expected_rate_version=OLD.overproduction_rate_version
              AND request.before_rate=OLD.allowed_overproduction_rate
              AND request.requested_rate=NEW.allowed_overproduction_rate) THEN
        RAISE EXCEPTION 'Effective production tolerance changes require an exact planning approval' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_production_effective_rate BEFORE UPDATE OF allowed_overproduction_rate,overproduction_rate_version
    ON production_execution_segments FOR EACH ROW EXECUTE FUNCTION fn_guard_production_effective_rate();

CREATE FUNCTION fn_apply_production_rate_decision() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE request production_overproduction_rate_requests%ROWTYPE;
        segment production_execution_segments%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Production rate decisions are append-only' USING ERRCODE='23514'; END IF;
    SELECT * INTO request FROM production_overproduction_rate_requests WHERE id=NEW.request_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Production rate request missing' USING ERRCODE='23514'; END IF;
    -- Shared lock order with reporting and submitting another request.
    SELECT * INTO segment FROM production_execution_segments WHERE id=request.execution_segment_id FOR UPDATE;
    SELECT * INTO request FROM production_overproduction_rate_requests WHERE id=NEW.request_id FOR UPDATE;
    IF request.status<>'PENDING' OR request.row_version<>NEW.expected_version THEN
        RAISE EXCEPTION 'Production rate request has already changed' USING ERRCODE='23514';
    END IF;
    IF NEW.decision='APPROVED' THEN
        IF NOT fn_production_rate_request_ready(request.id) THEN
            RAISE EXCEPTION 'Production arrangement changed; submit a fresh tolerance request' USING ERRCODE='23514';
        END IF;
        UPDATE production_execution_segments SET allowed_overproduction_rate=request.requested_rate,
            overproduction_rate_version=overproduction_rate_version+1,lock_version=lock_version+1,
            updated_at=now(),updated_by=NEW.decided_by WHERE id=segment.id;
    END IF;
    UPDATE production_overproduction_rate_requests SET status=NEW.decision,row_version=row_version+1 WHERE id=request.id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_apply_production_rate_decision AFTER INSERT
    ON production_overproduction_rate_decisions FOR EACH ROW EXECUTE FUNCTION fn_apply_production_rate_decision();
CREATE FUNCTION fn_immutable_production_rate_decision() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Production rate decisions are append-only' USING ERRCODE='23514'; END;
$$;
CREATE TRIGGER trg_immutable_production_rate_decision BEFORE UPDATE OR DELETE
    ON production_overproduction_rate_decisions FOR EACH ROW EXECUTE FUNCTION fn_immutable_production_rate_decision();

INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy)
VALUES('production_execution:request_overproduction_rate','申请调整允许超产比例','生产管理','车间执行',42,'EDIT',
       '在本人车间任务提交允许超产比例调整；计划部审批通过前原比例继续生效',ARRAY['NORMAL']::text[])
ON CONFLICT(code) DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id,permission.id FROM permission_surfaces surface CROSS JOIN permissions permission
WHERE surface.surface_key='production.workshop-tasks' AND permission.code='production_execution:request_overproduction_rate'
ON CONFLICT DO NOTHING;
-- Deliberately no bulk/default workshop grant: the administrator authorizes requesters.

SELECT fn_audit_track_table('production_overproduction_rate_requests','FULL','data_change',false);
SELECT fn_audit_track_table('production_overproduction_rate_decisions','NONE','data_change',false);
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V698 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''production_overproduction_rate_requests'', ''CLEAR''),\n            (''production_overproduction_rate_decisions'', ''CLEAR'')');
END;
$reset_policy$;
