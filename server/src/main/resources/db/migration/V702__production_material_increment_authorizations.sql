-- Additional material is a separately approved exact demand. It never changes
-- the frozen recipe, original demand, production quantity or sales ownership.
CREATE TABLE production_material_increment_requests (
    id UUID PRIMARY KEY,
    original_demand_id UUID NOT NULL REFERENCES production_material_demands(id),
    target_segment_id UUID NOT NULL REFERENCES production_execution_segments(id),
    supplement_proof_id UUID REFERENCES production_actual_output_supplement_proofs(id),
    expected_demand_version BIGINT NOT NULL CHECK(expected_demand_version>=0),
    original_required_qty NUMERIC(18,4) NOT NULL CHECK(original_required_qty>0),
    approved_increment_qty NUMERIC(18,4) NOT NULL CHECK(approved_increment_qty>=0),
    delta_qty NUMERIC(18,4) NOT NULL CHECK(delta_qty>0 AND delta_qty<'Infinity'::numeric),
    authorized_demand_id UUID NOT NULL UNIQUE,
    source_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
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
    UNIQUE(submitted_by,idempotency_key)
);
CREATE UNIQUE INDEX uq_material_increment_pending ON production_material_increment_requests(original_demand_id,target_segment_id)
    WHERE status='PENDING';
CREATE INDEX idx_material_increment_queue ON production_material_increment_requests(status,submitted_at,id);
CREATE INDEX idx_material_increment_target ON production_material_increment_requests(target_segment_id,status);
CREATE INDEX idx_material_increment_proof ON production_material_increment_requests(supplement_proof_id) WHERE supplement_proof_id IS NOT NULL;

CREATE TABLE production_material_increment_decisions (
    id UUID PRIMARY KEY,
    request_id UUID NOT NULL UNIQUE REFERENCES production_material_increment_requests(id),
    decision TEXT NOT NULL CHECK(decision IN('APPROVED','RETURNED')),
    reason TEXT CHECK(length(reason)<=500),
    expected_version BIGINT NOT NULL CHECK(expected_version>=0),
    decided_by UUID NOT NULL REFERENCES users(id),
    decided_by_employee_id UUID NOT NULL REFERENCES employees(id),
    decided_by_name TEXT NOT NULL,
    decided_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 128),
    request_hash TEXT NOT NULL CHECK(request_hash~'^[0-9a-f]{64}$'),
    UNIQUE(decided_by,idempotency_key),
    CHECK(decision<>'RETURNED' OR (reason IS NOT NULL AND length(btrim(reason))>=2))
);
CREATE TABLE production_material_increment_reversals (
    id UUID PRIMARY KEY,
    request_id UUID NOT NULL UNIQUE REFERENCES production_material_increment_requests(id),
    expected_version BIGINT NOT NULL CHECK(expected_version>=0),
    reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 2 AND 500),
    draw_item_quantities JSONB NOT NULL CHECK(jsonb_typeof(draw_item_quantities)='object'),
    created_by UUID NOT NULL REFERENCES users(id),
    created_by_employee_id UUID NOT NULL REFERENCES employees(id),
    created_by_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 128),
    request_hash TEXT NOT NULL CHECK(request_hash~'^[0-9a-f]{64}$'),
    UNIQUE(created_by,idempotency_key)
);
ALTER TABLE production_material_demands ADD COLUMN material_increment_request_id UUID
    UNIQUE REFERENCES production_material_increment_requests(id);
DROP INDEX uq_production_material_demand_dimension;
CREATE UNIQUE INDEX uq_production_material_demand_dimension ON production_material_demands(
    package_id,execution_segment_id,fqc_replenishment_cycle_id,material_increment_request_id,goods_id,color_id,need_date
) NULLS NOT DISTINCT WHERE NOT is_deleted;

CREATE FUNCTION fn_material_increment_source_valid(p_original UUID,p_target UUID,p_proof UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_material_demands original
        JOIN production_execution_segments source ON source.id=original.execution_segment_id
        JOIN production_plans source_plan ON source_plan.id=source.plan_id
        JOIN production_planning_packages source_package ON source_package.id=source.package_id
        JOIN production_execution_segments target ON target.id=p_target
        JOIN production_plans plan ON plan.id=target.plan_id
        JOIN production_planning_packages package ON package.id=target.package_id
        WHERE original.id=p_original AND NOT original.is_deleted AND original.material_increment_request_id IS NULL
          AND original.fqc_replenishment_cycle_id IS NULL AND original.fqc_recovery_authorization_id IS NULL
          AND original.status NOT IN('RELEASED','REVERSED') AND NOT source.is_deleted
          AND source_plan.status=1 AND NOT source_plan.is_deleted AND NOT source_plan.is_stopped AND NOT source_plan.is_canceled
          AND source_package.status='CONFIRMED' AND NOT source_package.is_deleted
          AND target.material_requirement_mode='DEMANDED' AND NOT target.is_deleted
          AND target.status IN('WAITING','READY','DISPATCHED','IN_PROGRESS')
          AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped
          AND package.status='CONFIRMED' AND NOT package.is_deleted
          AND original.warehouse_id=package.warehouse_id
          AND (source.workshop_department_id,source.product_goods_id,source.product_color_id,source.product_unit_id,
               source.product_unit_rate,source.bom_fingerprint)
              IS NOT DISTINCT FROM (target.workshop_department_id,target.product_goods_id,target.product_color_id,
               target.product_unit_id,target.product_unit_rate,target.bom_fingerprint)
          AND ((p_proof IS NULL AND source.id=target.id
                AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof WHERE proof.supplement_execution_segment_id=target.id))
               OR EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof
                  WHERE proof.id=p_proof AND proof.supplement_execution_segment_id=target.id
                    AND proof.source_execution_segment_id=source.id
                    AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id))))
$$;

CREATE FUNCTION fn_material_increment_source_snapshot(p_original UUID,p_target UUID) RETURNS JSONB LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('originalDemandId',original.id,'sourceSegmentId',original.execution_segment_id,
        'sourcePlanId',original.plan_id,'sourcePackageId',original.package_id,'sourcePlanItemId',original.source_plan_item_id,
        'goodsId',original.goods_id,'colorId',original.color_id,'unitId',original.unit_id,'warehouseId',original.warehouse_id,
        'requiredQty',original.required_qty,'perProductQty',original.per_product_qty,'needDate',original.need_date,
        'supplyRoute',original.supply_route,'requirementMode',original.requirement_mode,
        'requiredForProductQty',original.required_for_product_qty,'requirementFingerprint',original.requirement_fingerprint,
        'consumptionSnapshot',original.consumption_snapshot,'targetSegmentId',target.id,'targetPackageId',target.package_id,
        'targetPlanId',target.plan_id,'targetPlanItemId',target.source_plan_item_id,'targetPlannedQty',target.planned_qty,
        'targetSnapshotQty',target.material_snapshot_product_qty,'bomFingerprint',target.bom_fingerprint,
        'workshopDepartmentId',target.workshop_department_id,'responsibleEmployeeId',target.responsible_employee_id)
    FROM production_material_demands original CROSS JOIN production_execution_segments target
    WHERE original.id=p_original AND target.id=p_target
$$;

CREATE FUNCTION fn_material_increment_request_ready(p_request UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_material_increment_requests request
        JOIN production_material_demands original ON original.id=request.original_demand_id
        JOIN production_execution_segments target ON target.id=request.target_segment_id
        WHERE request.id=p_request AND request.status='PENDING'
          AND fn_material_increment_source_valid(original.id,target.id,request.supplement_proof_id)
          AND request.source_snapshot=fn_material_increment_source_snapshot(original.id,target.id)
          AND original.lock_version=request.expected_demand_version AND original.required_qty=request.original_required_qty
          AND request.approved_increment_qty=(SELECT COALESCE(SUM(delta_qty),0) FROM production_material_increment_requests prior
                WHERE prior.original_demand_id=original.id AND prior.target_segment_id=target.id AND prior.status='APPROVED'
                  AND NOT EXISTS(SELECT 1 FROM production_material_increment_reversals reversed WHERE reversed.request_id=prior.id))
          AND request.before_snapshot->>'planId'=target.plan_id::text
          AND (request.before_snapshot->>'workshopDepartmentId') IS NOT DISTINCT FROM target.workshop_department_id::text
          AND (request.before_snapshot->>'responsibleEmployeeId') IS NOT DISTINCT FROM target.responsible_employee_id::text
          AND (request.before_snapshot#>>'{items,0,goodsId}')=original.goods_id::text
          AND (request.before_snapshot#>>'{items,0,colorId}') IS NOT DISTINCT FROM original.color_id::text
          AND (request.before_snapshot#>>'{items,0,unitId}')=original.unit_id::text
          AND (request.before_snapshot#>>'{items,0,warehouseId}')=original.warehouse_id::text
          AND (request.before_snapshot#>>'{items,0,requiredForProductQty}')::numeric
                IS NOT DISTINCT FROM COALESCE(target.material_snapshot_product_qty,target.planned_qty))
$$;

CREATE FUNCTION fn_guard_material_increment_request() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE original production_material_demands%ROWTYPE; target production_execution_segments%ROWTYPE;
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Material increment requests are immutable history' USING ERRCODE='23514'; END IF;
    IF TG_OP='UPDATE' THEN
        IF (to_jsonb(NEW)-ARRAY['status','row_version']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','row_version'])
           OR OLD.status<>'PENDING' OR NEW.row_version<>OLD.row_version+1
           OR NOT EXISTS(SELECT 1 FROM production_material_increment_decisions decision
               WHERE decision.request_id=OLD.id AND decision.decision=NEW.status AND decision.expected_version=OLD.row_version) THEN
            RAISE EXCEPTION 'Material increment resolution needs its exact planning decision' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    SELECT * INTO target FROM production_execution_segments WHERE id=NEW.target_segment_id FOR UPDATE;
    SELECT * INTO original FROM production_material_demands WHERE id=NEW.original_demand_id FOR UPDATE;
    NEW.source_snapshot:=fn_material_increment_source_snapshot(NEW.original_demand_id,NEW.target_segment_id);
    IF NEW.status<>'PENDING' OR NEW.row_version<>0
       OR NOT fn_material_increment_source_valid(original.id,target.id,NEW.supplement_proof_id)
       OR original.required_qty IS DISTINCT FROM NEW.original_required_qty OR original.lock_version IS DISTINCT FROM NEW.expected_demand_version
       OR NEW.approved_increment_qty<>(SELECT COALESCE(SUM(delta_qty),0) FROM production_material_increment_requests
           WHERE original_demand_id=original.id AND target_segment_id=target.id AND status='APPROVED'
             AND NOT EXISTS(SELECT 1 FROM production_material_increment_reversals reversed WHERE reversed.request_id=production_material_increment_requests.id))
       OR jsonb_array_length(COALESCE(NEW.before_snapshot->'items','[]'::jsonb))<>1
       OR jsonb_array_length(COALESCE(NEW.after_snapshot->'items','[]'::jsonb))<>1
       OR (NEW.before_snapshot#>>'{items,0,itemId}') IS DISTINCT FROM original.id::text
       OR (NEW.before_snapshot#>>'{items,0,goodsId}') IS DISTINCT FROM original.goods_id::text
       OR (NEW.before_snapshot#>>'{items,0,colorId}') IS DISTINCT FROM original.color_id::text
       OR (NEW.before_snapshot#>>'{items,0,unitId}') IS DISTINCT FROM original.unit_id::text
       OR (NEW.before_snapshot#>>'{items,0,warehouseId}') IS DISTINCT FROM original.warehouse_id::text
       OR (NEW.before_snapshot#>>'{items,0,requiredQty}')::numeric IS DISTINCT FROM original.required_qty
       OR (NEW.before_snapshot#>>'{items,0,approvedIncrementQty}')::numeric IS DISTINCT FROM NEW.approved_increment_qty
       OR (NEW.after_snapshot#>>'{items,0,approvedIncrementQty}')::numeric IS DISTINCT FROM NEW.approved_increment_qty+NEW.delta_qty
       OR (NEW.before_snapshot#>>'{items,0,authorizedQty}')::numeric IS DISTINCT FROM original.required_qty+NEW.approved_increment_qty
       OR (NEW.after_snapshot#>>'{items,0,authorizedQty}')::numeric IS DISTINCT FROM original.required_qty+NEW.approved_increment_qty+NEW.delta_qty
       OR (NEW.before_snapshot#>>'{items,0,requiredForProductQty}')::numeric
             IS DISTINCT FROM COALESCE(target.material_snapshot_product_qty,target.planned_qty)
       OR NEW.before_snapshot->>'planId' IS DISTINCT FROM target.plan_id::text
       OR NEW.before_snapshot->>'workshopDepartmentId' IS DISTINCT FROM target.workshop_department_id::text
       OR NEW.before_snapshot->>'responsibleEmployeeId' IS DISTINCT FROM target.responsible_employee_id::text
       OR (NEW.before_snapshot-'items') IS DISTINCT FROM (NEW.after_snapshot-'items')
       OR ((NEW.before_snapshot#>'{items,0}')-ARRAY['authorizedQty','approvedIncrementQty']) IS DISTINCT FROM ((NEW.after_snapshot#>'{items,0}')-ARRAY['authorizedQty','approvedIncrementQty']) THEN
        RAISE EXCEPTION 'Material increment request must freeze its exact same-material authority' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_material_increment_request BEFORE INSERT OR UPDATE OR DELETE ON production_material_increment_requests
    FOR EACH ROW EXECUTE FUNCTION fn_guard_material_increment_request();

CREATE FUNCTION fn_apply_material_increment_decision() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE request production_material_increment_requests%ROWTYPE; original production_material_demands%ROWTYPE;
        target production_execution_segments%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Material increment decisions are append-only' USING ERRCODE='23514'; END IF;
    SELECT * INTO request FROM production_material_increment_requests WHERE id=NEW.request_id;
    SELECT * INTO target FROM production_execution_segments WHERE id=request.target_segment_id FOR UPDATE;
    SELECT * INTO original FROM production_material_demands WHERE id=request.original_demand_id FOR UPDATE;
    SELECT * INTO request FROM production_material_increment_requests WHERE id=NEW.request_id FOR UPDATE;
    IF request.id IS NULL OR request.status<>'PENDING' OR request.row_version<>NEW.expected_version THEN
        RAISE EXCEPTION 'Material increment request has changed' USING ERRCODE='23514';
    END IF;
    IF NEW.decision='APPROVED' THEN
        IF NOT fn_material_increment_request_ready(request.id) THEN
            RAISE EXCEPTION 'Material increment source changed; return and resubmit' USING ERRCODE='23514';
        END IF;
        INSERT INTO production_material_demands(id,package_id,plan_id,execution_segment_id,source_plan_item_id,
            warehouse_id,goods_id,color_id,unit_id,required_qty,per_product_qty,requirement_mode,
            required_for_product_qty,requirement_fingerprint,need_date,supply_route,idempotency_key,
            material_increment_request_id,created_by,updated_by)
        VALUES(request.authorized_demand_id,target.package_id,target.plan_id,target.id,target.source_plan_item_id,
            original.warehouse_id,original.goods_id,original.color_id,original.unit_id,request.delta_qty,
            original.per_product_qty,'EXACT_SNAPSHOT',COALESCE(target.material_snapshot_product_qty,target.planned_qty),
            request.request_hash,original.need_date,original.supply_route,'MATERIAL-INCREMENT:'||request.id,
            request.id,NEW.decided_by,NEW.decided_by);
    END IF;
    UPDATE production_material_increment_requests SET status=NEW.decision,row_version=row_version+1 WHERE id=request.id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_apply_material_increment_decision AFTER INSERT ON production_material_increment_decisions
    FOR EACH ROW EXECUTE FUNCTION fn_apply_material_increment_decision();
CREATE TRIGGER trg_immutable_material_increment_decision BEFORE UPDATE OR DELETE ON production_material_increment_decisions
    FOR EACH ROW EXECUTE FUNCTION fn_apply_material_increment_decision();

CREATE FUNCTION fn_material_increment_demand_is_proven(p_demand UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_material_demands demand
        JOIN production_material_increment_requests request ON request.id=demand.material_increment_request_id
        JOIN production_material_increment_decisions decision ON decision.request_id=request.id AND decision.decision='APPROVED'
        JOIN production_material_demands original ON original.id=request.original_demand_id
        JOIN production_execution_segments target ON target.id=request.target_segment_id
        WHERE demand.id=p_demand AND request.authorized_demand_id=demand.id
          AND demand.execution_segment_id=target.id AND demand.package_id=target.package_id AND demand.plan_id=target.plan_id
          AND demand.source_plan_item_id=target.source_plan_item_id AND demand.required_qty=request.delta_qty
          AND (demand.goods_id,demand.color_id,demand.unit_id,demand.warehouse_id,demand.supply_route,demand.per_product_qty)
              IS NOT DISTINCT FROM (original.goods_id,original.color_id,original.unit_id,original.warehouse_id,original.supply_route,original.per_product_qty)
          AND demand.requirement_mode='EXACT_SNAPSHOT' AND demand.requirement_fingerprint=request.request_hash
          AND demand.required_for_product_qty=(request.before_snapshot#>>'{items,0,requiredForProductQty}')::numeric
          AND demand.consumption_snapshot IS NULL AND demand.split_root_demand_id IS NULL
          AND demand.fqc_replenishment_cycle_id IS NULL AND demand.fqc_recovery_authorization_id IS NULL)
$$;
CREATE FUNCTION fn_guard_material_increment_demand() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='UPDATE' AND NEW.material_increment_request_id IS DISTINCT FROM OLD.material_increment_request_id THEN
        RAISE EXCEPTION 'Material increment demand identity is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.material_increment_request_id IS NOT NULL AND NOT fn_material_increment_demand_is_proven(NEW.id) THEN
        RAISE EXCEPTION 'Additional material needs exact approved same-material evidence' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_material_increment_demand AFTER INSERT OR UPDATE ON production_material_demands
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_material_increment_demand();

CREATE FUNCTION fn_guard_material_increment_history_delete() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.material_increment_request_id IS NOT NULL THEN
        RAISE EXCEPTION 'Approved material increment demand is permanent history; release or reverse actual material instead'
            USING ERRCODE='23514';
    END IF;
    RETURN OLD;
END;
$$;
CREATE TRIGGER trg_material_increment_history_delete BEFORE DELETE ON production_material_demands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_material_increment_history_delete();

CREATE FUNCTION fn_guard_supplement_increment_cancellation() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM production_material_increment_requests request
        WHERE request.supplement_proof_id=NEW.proof_id AND request.status IN('PENDING','APPROVED')
          AND NOT EXISTS(SELECT 1 FROM production_material_increment_reversals reversed WHERE reversed.request_id=request.id)) THEN
        RAISE EXCEPTION 'Additional-output cancellation requires resolving its material increment authorizations first'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_supplement_increment_cancellation BEFORE INSERT ON production_actual_output_supplement_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_guard_supplement_increment_cancellation();

CREATE FUNCTION fn_material_increment_cancel_ready(p_request UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_material_increment_requests request
        JOIN production_material_demands demand ON demand.id=request.authorized_demand_id
        WHERE request.id=p_request AND request.status='APPROVED' AND NOT demand.is_deleted
          AND NOT EXISTS(SELECT 1 FROM production_material_increment_reversals reversed WHERE reversed.request_id=request.id)
          AND NOT EXISTS(SELECT 1 FROM production_material_supply_pegs peg WHERE peg.demand_id=demand.id
              AND peg.status<>'REVERSED' AND peg.allocated_qty>peg.released_qty)
          AND COALESCE((SELECT SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'GOOD_RETURN_REVERSE' THEN qty_base
               WHEN 'ISSUE_REVERSE' THEN -qty_base WHEN 'GOOD_RETURN' THEN -qty_base ELSE 0 END)
              FROM production_material_stock_postings posting WHERE posting.demand_id=demand.id),0)=0
          AND NOT EXISTS(SELECT 1 FROM production_material_stock_postings issue
              WHERE issue.demand_id=demand.id AND issue.posting_type='ISSUE' AND fn_material_issue_pending_return(issue.id,NULL)>0)
          AND NOT EXISTS(SELECT 1 FROM production_material_settlement_postings posting
              JOIN production_material_settlement_events event ON event.id=posting.event_id
              WHERE posting.demand_id=demand.id GROUP BY posting.settlement_type
              HAVING SUM(CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END)<>0)
          AND NOT EXISTS(SELECT 1 FROM production_daily_report_material_usages usage
              JOIN production_daily_reports report ON report.id=usage.report_id AND NOT report.is_deleted AND report.status IN(0,1)
              WHERE usage.demand_id=demand.id AND (report.status=0 OR usage.qty_base>0))
          AND NOT EXISTS(SELECT 1 FROM stock_reservations reservation WHERE reservation.demand_id=demand.id
              AND NOT reservation.is_deleted AND reservation.consumed_qty<>0))
$$;

-- Preserve the original DRAW and every issued quantity. The cancellation fact
-- withdraws only this demand's still-unissued instructions, even in a mixed DRAW.
DO $draw_quantity$
DECLARE definition TEXT; needle TEXT:='SELECT item.qty-COALESCE';
BEGIN
    SELECT pg_get_functiondef('fn_production_draw_item_effective_qty(uuid)'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V702 effective DRAW quantity anchor changed'; END IF;
    -- CREATE OR REPLACE preserves the function identity already used by views.
    EXECUTE replace(definition,needle,'SELECT item.qty-COALESCE((
        SELECT SUM((reversed.draw_item_quantities->>item.id::text)::numeric)
        FROM production_material_increment_reversals reversed WHERE reversed.draw_item_quantities ? item.id::text),0)-COALESCE');
END;
$draw_quantity$;
CREATE FUNCTION fn_guard_material_increment_reversal() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE request production_material_increment_requests%ROWTYPE; expected JSONB;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Material increment reversals are append-only' USING ERRCODE='23514'; END IF;
    SELECT * INTO request FROM production_material_increment_requests WHERE id=NEW.request_id FOR UPDATE;
    IF request.id IS NULL OR request.row_version<>NEW.expected_version OR NOT fn_material_increment_cancel_ready(request.id) THEN
        RAISE EXCEPTION 'Material increment still has actual issue, consumption, pending return or downstream supply'
            USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM stock_reservations reservation WHERE reservation.demand_id=request.authorized_demand_id
        AND NOT reservation.is_deleted AND reservation.qty>reservation.consumed_qty+reservation.released_qty) THEN
        RAISE EXCEPTION 'Material increment must release its exact reservations first' USING ERRCODE='23514';
    END IF;
    SELECT COALESCE(jsonb_object_agg(item.id::text,GREATEST(fn_production_draw_item_effective_qty(item.id)-COALESCE(item.issued_qty,0),0))
            FILTER(WHERE fn_production_draw_item_effective_qty(item.id)>COALESCE(item.issued_qty,0)),'{}'::jsonb) INTO expected
    FROM production_planning_package_document_items mapping
    JOIN stock_document_items item ON item.id=mapping.document_item_id AND NOT item.is_deleted
    JOIN stock_documents document ON document.id=item.doc_id AND document.doc_type='DRAW' AND document.status IN(0,1) AND NOT document.is_deleted
    WHERE mapping.demand_id=request.authorized_demand_id AND mapping.document_type='DRAW';
    IF NEW.draw_item_quantities IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'Material increment cancellation must withdraw exactly its remaining picking instructions' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_material_increment_reversal BEFORE INSERT OR UPDATE OR DELETE ON production_material_increment_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_guard_material_increment_reversal();
CREATE FUNCTION fn_apply_material_increment_reversal() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE production_material_demands SET released_qty=required_qty,status='RELEASED',lock_version=lock_version+1,
        updated_at=now(),updated_by=NEW.created_by
    WHERE id=(SELECT authorized_demand_id FROM production_material_increment_requests WHERE id=NEW.request_id);
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_apply_material_increment_reversal AFTER INSERT ON production_material_increment_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_apply_material_increment_reversal();
CREATE FUNCTION fn_guard_reversed_increment_material_posting() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM production_material_increment_requests request
        JOIN production_material_increment_reversals reversed ON reversed.request_id=request.id
        WHERE request.authorized_demand_id=NEW.demand_id) THEN
        RAISE EXCEPTION 'Cancelled material authority cannot issue, restore returned custody or post consumption'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_reversed_increment_stock_posting BEFORE INSERT ON production_material_stock_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_reversed_increment_material_posting();
CREATE TRIGGER trg_reversed_increment_settlement_posting BEFORE INSERT ON production_material_settlement_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_reversed_increment_material_posting();

CREATE FUNCTION fn_actual_supplement_increment_identity(p_segment UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS(SELECT 1 FROM production_material_demands own
        WHERE own.execution_segment_id=p_segment AND NOT own.is_deleted AND NOT fn_material_increment_demand_is_proven(own.id))
      AND NOT EXISTS(SELECT 1 FROM production_planning_package_documents header
        JOIN production_planning_package_document_items item ON item.package_id=header.package_id
          AND item.document_id=header.document_id AND item.document_type=header.document_type
        LEFT JOIN production_material_demands own ON own.id=item.demand_id
        WHERE header.execution_segment_id=p_segment AND header.document_type='DRAW'
          AND (own.id IS NULL OR own.execution_segment_id<>p_segment OR NOT fn_material_increment_demand_is_proven(own.id)))
$$;

-- READY may own a picking instruction; START and reporting require its actual
-- issue. This prevents a READY -> ISSUE bootstrap loop for a new supplement.
CREATE FUNCTION fn_actual_supplement_material_prepared(p_segment UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT fn_actual_supplement_material_ready(p_segment) OR EXISTS(
        SELECT 1 FROM production_actual_output_supplement_proofs proof
        JOIN production_execution_segments target ON target.id=proof.supplement_execution_segment_id
        JOIN production_execution_segments source ON source.id=proof.source_execution_segment_id
        JOIN production_plans target_plan ON target_plan.id=target.plan_id
        JOIN production_plans source_plan ON source_plan.id=source.plan_id
        WHERE target.id=p_segment AND NOT target.is_deleted AND NOT source.is_deleted
          AND source.status IN('IN_PROGRESS','COMPLETED')
          AND target_plan.status=1 AND NOT target_plan.is_deleted AND NOT target_plan.is_closed AND NOT target_plan.is_stopped AND NOT target_plan.is_canceled
          AND source_plan.status=1 AND NOT source_plan.is_deleted AND NOT source_plan.is_stopped AND NOT source_plan.is_canceled
          AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id)
          AND fn_actual_supplement_increment_identity(target.id) AND fn_execution_material_custody_valid(target.id)
          AND EXISTS(SELECT 1 FROM fn_execution_segment_material_coverage(target.id) coverage
              WHERE fn_material_increment_demand_is_proven(coverage.demand_id) AND coverage.stock_backed>0 AND coverage.draw_backed>0))
$$;

DO $supplement_increments$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('fn_actual_supplement_material_ready(uuid)'::regprocedure),E'\r\n',E'\n') INTO definition;
    needle:=E'AND NOT EXISTS(SELECT 1 FROM production_material_demands own\n                         WHERE own.execution_segment_id=target.id AND NOT own.is_deleted)\n          AND NOT EXISTS(SELECT 1 FROM production_planning_package_documents own\n                         WHERE own.execution_segment_id=target.id AND own.document_type=''DRAW'')';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V702 supplement own-material identity anchor changed'; END IF;
    EXECUTE replace(definition,needle,'AND fn_actual_supplement_increment_identity(target.id)');
    SELECT replace(pg_get_functiondef('fn_assert_actual_supplement_segment_integrity(uuid)'::regprocedure),E'\r\n',E'\n') INTO definition;
    needle:=E'OR EXISTS(SELECT 1 FROM production_material_demands WHERE execution_segment_id=p_segment AND NOT is_deleted)\n        OR EXISTS(SELECT 1 FROM production_planning_package_documents WHERE execution_segment_id=p_segment AND document_type=''DRAW'')';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V702 supplement demand guard anchor changed'; END IF;
    definition:=replace(definition,needle,'OR NOT fn_actual_supplement_increment_identity(p_segment)');
    definition:=replace(definition,'IF target.status IN(''READY'',''DISPATCHED'',''IN_PROGRESS'',''COMPLETED'') AND NOT fn_actual_supplement_material_ready(p_segment) THEN',
        'IF (target.status IN(''READY'',''DISPATCHED'') AND NOT fn_actual_supplement_material_prepared(p_segment))
            OR (target.status IN(''IN_PROGRESS'',''COMPLETED'') AND NOT fn_actual_supplement_material_ready(p_segment)) THEN');
    needle:='IF target.status=''COMPLETED'' AND NOT fn_actual_supplement_material_cleared(p_segment) THEN';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V702 supplement clearance anchor changed'; END IF;
    definition:=replace(definition,needle,'IF EXISTS(SELECT 1 FROM production_material_demands WHERE execution_segment_id=p_segment AND NOT is_deleted) THEN
        PERFORM fn_assert_execution_segment_integrity_before_v561(p_segment);
    END IF;
    '||needle);
    EXECUTE definition;
END;
$supplement_increments$;

-- These demands authorize extra input rather than changing the original BOM
-- output threshold. They remain subject to the same allocation/issue/clearance
-- budgets; pending supply cannot invalidate already physically started work.
DO $increment_guards$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_assert_execution_segment_integrity_before_v561(uuid)'::regprocedure) INTO definition;
    needle:='v_segment.continuous_supply AS direct_partial';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V702 coverage authority anchor changed'; END IF;
    definition:=replace(definition,needle,'(v_segment.continuous_supply OR fn_material_increment_demand_is_proven(coverage.demand_id)) AS direct_partial');
    EXECUTE definition;
    SELECT pg_get_functiondef('fn_execution_material_output_capacity(uuid,boolean)'::regprocedure) INTO definition;
    needle:='WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V702 output capacity anchor changed'; END IF;
    EXECUTE replace(definition,needle,needle||' AND demand.material_increment_request_id IS NULL');
END;
$increment_guards$;

INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy)
VALUES('production_execution:request_material_increment','申请实际补料','生产管理','车间执行',43,'EDIT',
    '申请原冻结物料的正增量；计划部批准后按增量生成领料供给，仓库真实发料',ARRAY['NORMAL']::text[])
ON CONFLICT(code) DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id,permission.id FROM permission_surfaces surface CROSS JOIN permissions permission
WHERE surface.surface_key='production.workshop-tasks' AND permission.code='production_execution:request_material_increment'
ON CONFLICT DO NOTHING;
SELECT fn_audit_track_table('production_material_increment_requests','FULL','data_change',false);
SELECT fn_audit_track_table('production_material_increment_decisions','NONE','data_change',false);
SELECT fn_audit_track_table('production_material_increment_reversals','NONE','data_change',false);
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V702 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n (''production_material_increment_requests'', ''CLEAR''),\n (''production_material_increment_decisions'', ''CLEAR''),\n (''production_material_increment_reversals'', ''CLEAR'')');
END;
$reset_policy$;
