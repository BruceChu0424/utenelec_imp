-- Preserve frozen execution identity. A split retires an unused WAITING segment
-- and appends quantity-conserving children; it never edits an issued demand.
ALTER TABLE production_execution_segments
    ADD COLUMN source_segment_id UUID REFERENCES production_execution_segments(id),
    ADD COLUMN split_root_segment_id UUID REFERENCES production_execution_segments(id),
    ADD COLUMN split_start_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (split_start_qty >= 0),
    ADD COLUMN split_material_snapshot JSONB,
    ADD CONSTRAINT execution_split_shape CHECK (
        (source_segment_id IS NULL AND split_root_segment_id IS NULL AND split_start_qty=0 AND split_material_snapshot IS NULL)
        OR (source_segment_id IS NOT NULL AND split_root_segment_id IS NOT NULL AND split_material_snapshot IS NOT NULL
            AND jsonb_typeof(split_material_snapshot)='array' AND jsonb_array_length(split_material_snapshot)>0));
ALTER TABLE production_material_demands
    ADD COLUMN split_root_demand_id UUID REFERENCES production_material_demands(id);
CREATE INDEX idx_execution_split_source ON production_execution_segments(source_segment_id);
CREATE INDEX idx_execution_split_root ON production_execution_segments(split_root_segment_id,split_start_qty);
CREATE INDEX idx_execution_split_demand_root ON production_material_demands(split_root_demand_id);

CREATE TABLE production_execution_segment_splits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_segment_id UUID NOT NULL UNIQUE REFERENCES production_execution_segments(id),
    batch_segment_id UUID NOT NULL UNIQUE REFERENCES production_execution_segments(id) DEFERRABLE INITIALLY DEFERRED,
    remaining_segment_id UUID UNIQUE REFERENCES production_execution_segments(id) DEFERRABLE INITIALLY DEFERRED,
    source_qty NUMERIC(18,4) NOT NULL CHECK(source_qty>0),
    batch_qty NUMERIC(18,4) NOT NULL CHECK(batch_qty>0),
    remaining_qty NUMERIC(18,4) NOT NULL CHECK(remaining_qty>=0),
    expected_version BIGINT NOT NULL CHECK(expected_version>=0),
    request_hash VARCHAR(64) NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
    idempotency_key VARCHAR(128) NOT NULL,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(created_by,idempotency_key),
    CHECK(batch_qty+remaining_qty=source_qty),
    CHECK((remaining_qty=0)=(remaining_segment_id IS NULL)),
    CHECK(source_segment_id<>batch_segment_id AND source_segment_id IS DISTINCT FROM remaining_segment_id
        AND batch_segment_id IS DISTINCT FROM remaining_segment_id)
);
CREATE TRIGGER trg_audit_production_execution_segment_splits AFTER INSERT OR UPDATE OR DELETE
    ON production_execution_segment_splits FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE FUNCTION fn_split_batch_prerequisites_issued(p_segment UUID) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (
        SELECT 1 FROM production_execution_segments segment,
            jsonb_array_elements(segment.split_material_snapshot) requirement
        WHERE segment.id=p_segment AND COALESCE((requirement->>'requiresPrior')::boolean,FALSE)
          AND COALESCE((
              SELECT sum(demand.required_qty)
              FROM production_material_demands demand
              JOIN production_execution_segments prior ON prior.id=demand.execution_segment_id
              WHERE demand.split_root_demand_id=(requirement->>'rootDemandId')::uuid
                AND prior.split_root_segment_id=segment.split_root_segment_id
                AND prior.split_start_qty+prior.planned_qty<=segment.split_start_qty
                AND prior.status NOT IN ('CANCELLED','REVERSED')
                AND NOT prior.is_deleted AND NOT demand.is_deleted AND demand.status='FULFILLED'
                AND NOT EXISTS(SELECT 1 FROM production_material_stock_postings issue
                    WHERE issue.demand_id=demand.id AND issue.posting_type='ISSUE'
                      AND fn_material_issue_pending_return(issue.id,NULL)>0)
          ),0)<(requirement->>'priorQty')::numeric);
$$;

CREATE FUNCTION fn_split_batch_empty_issued(p_segment UUID) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM production_execution_segments segment
        JOIN production_execution_segment_splits split ON split.batch_segment_id=segment.id
        WHERE segment.id=p_segment AND NOT segment.is_deleted
          AND segment.status IN ('READY','DISPATCHED','IN_PROGRESS','COMPLETED')
          AND segment.source_segment_id=split.source_segment_id
          AND segment.material_requirement_mode='DEMANDED'
          AND jsonb_array_length(segment.split_material_snapshot)>0
          AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(segment.split_material_snapshot) requirement
                         WHERE (requirement->>'requiredQty')::numeric<>0)
          AND NOT EXISTS(SELECT 1 FROM production_material_demands demand
                         WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted)
          AND ((segment.status='COMPLETED' AND EXISTS(SELECT 1 FROM production_execution_segment_events started
                    WHERE started.execution_segment_id=segment.id AND started.action='START'))
               OR (segment.status<>'COMPLETED' AND fn_split_batch_prerequisites_issued(segment.id))));
$$;

CREATE FUNCTION fn_issue_committed_to_later_batch(p_issue UUID) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_material_stock_postings issue
        JOIN production_material_demands demand ON demand.id=issue.demand_id
        JOIN production_execution_segments source ON source.id=demand.execution_segment_id
        JOIN production_execution_segments later ON later.split_root_segment_id=source.split_root_segment_id
            AND later.split_start_qty>=source.split_start_qty+COALESCE(source.material_snapshot_product_qty,source.planned_qty)
            AND later.status IN('WAITING','READY','DISPATCHED','IN_PROGRESS') AND NOT later.is_deleted
        CROSS JOIN LATERAL jsonb_array_elements(later.split_material_snapshot) requirement
        WHERE issue.id=p_issue AND issue.posting_type='ISSUE'
          AND (requirement->>'rootDemandId')::uuid=demand.split_root_demand_id
          AND (requirement->>'requiresPrior')::boolean);
$$;

CREATE FUNCTION fn_production_material_usage_source_segments(p_target UUID)
RETURNS TABLE(segment_id UUID) LANGUAGE sql STABLE AS $$
    SELECT target.id FROM production_execution_segments target
    WHERE target.id=p_target AND NOT target.is_deleted
      AND EXISTS(SELECT 1 FROM production_material_demands demand
        JOIN production_material_stock_postings issue ON issue.demand_id=demand.id AND issue.posting_type='ISSUE'
        WHERE demand.execution_segment_id=target.id AND NOT demand.is_deleted)
    UNION
    SELECT source.id FROM production_execution_segments target
    CROSS JOIN LATERAL jsonb_array_elements(target.split_material_snapshot) requirement
    JOIN production_material_demands demand ON demand.split_root_demand_id=(requirement->>'rootDemandId')::uuid
        AND NOT demand.is_deleted
    JOIN production_execution_segments source ON source.id=demand.execution_segment_id
        AND source.split_root_segment_id=target.split_root_segment_id
        AND source.split_start_qty+COALESCE(source.material_snapshot_product_qty,source.planned_qty)<=target.split_start_qty
        AND source.status NOT IN('CANCELLED','REVERSED') AND NOT source.is_deleted
    JOIN production_material_stock_postings issue ON issue.demand_id=demand.id AND issue.posting_type='ISSUE'
    WHERE target.id=p_target AND NOT target.is_deleted AND target.source_segment_id IS NOT NULL
        AND (requirement->>'requiresPrior')::boolean;
$$;

CREATE FUNCTION fn_guard_split_borrowed_material_return() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.posting_type='GOOD_RETURN' THEN
        PERFORM plan.id FROM production_material_stock_postings issue
            JOIN production_material_demands demand ON demand.id=issue.demand_id
            JOIN production_plans plan ON plan.id=demand.plan_id
            WHERE issue.id=NEW.source_posting_id FOR UPDATE OF plan;
        IF fn_issue_committed_to_later_batch(NEW.source_posting_id) THEN
            RAISE EXCEPTION '此物料已被后续生产批次承接，请先保留后续批次用料' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_split_borrowed_material_return BEFORE INSERT ON production_material_stock_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_split_borrowed_material_return();
ALTER TABLE production_material_stock_postings ENABLE ALWAYS TRIGGER trg_guard_split_borrowed_material_return;

CREATE FUNCTION fn_guard_execution_split_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='production_execution_segment_splits' THEN
        IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Execution split history is append-only' USING ERRCODE='55000'; END IF;
        PERFORM plan.id FROM production_execution_segments source
            JOIN production_plans plan ON plan.id=source.plan_id WHERE source.id=NEW.source_segment_id FOR UPDATE OF plan;
        IF NOT EXISTS(SELECT 1 FROM production_execution_segments source
            JOIN production_plans plan ON plan.id=source.plan_id
            WHERE source.id=NEW.source_segment_id AND source.status='WAITING' AND source.auto_promote_when_ready
              AND source.lock_version=NEW.expected_version AND NOT source.is_deleted
              AND plan.material_analysis_id IS NOT NULL AND plan.status=1
              AND NOT plan.is_deleted AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped)
          OR EXISTS(SELECT 1 FROM production_material_demands demand
              JOIN production_material_supply_pegs peg ON peg.demand_id=demand.id
              WHERE demand.execution_segment_id=NEW.source_segment_id)
          OR EXISTS(SELECT 1 FROM production_planning_package_documents document
              WHERE document.execution_segment_id=NEW.source_segment_id)
          OR EXISTS(SELECT 1 FROM production_daily_report_items report
              WHERE report.execution_segment_id=NEW.source_segment_id)
          OR EXISTS(SELECT 1 FROM stock_reservations reservation
              JOIN production_material_demands demand ON demand.id=reservation.demand_id
              WHERE demand.execution_segment_id=NEW.source_segment_id) THEN
            RAISE EXCEPTION 'Only unused analysis-backed waiting execution can be split' USING ERRCODE='23514';
        END IF;
    ELSIF TG_TABLE_NAME='production_execution_segments' THEN
        IF TG_OP='INSERT' THEN
            IF NEW.source_segment_id IS NOT NULL AND (NOT EXISTS(
                SELECT 1 FROM production_execution_segment_splits split WHERE split.source_segment_id=NEW.source_segment_id
                    AND NEW.id IN(split.batch_segment_id,split.remaining_segment_id)) OR NOT EXISTS(
                SELECT 1 FROM production_execution_segments source WHERE source.id=NEW.source_segment_id
                    AND (NEW.workshop_department_id,NEW.team_department_id,NEW.responsible_employee_id,NEW.plan_begin_date,NEW.plan_end_date)
                        IS NOT DISTINCT FROM (source.workshop_department_id,source.team_department_id,source.responsible_employee_id,source.plan_begin_date,source.plan_end_date))) THEN
                RAISE EXCEPTION 'New execution batch must inherit its proven source assignment' USING ERRCODE='23514';
            END IF;
            RETURN NEW;
        END IF;
        IF (NEW.source_segment_id,NEW.split_root_segment_id,NEW.split_start_qty,NEW.split_material_snapshot)
            IS DISTINCT FROM (OLD.source_segment_id,OLD.split_root_segment_id,OLD.split_start_qty,OLD.split_material_snapshot) THEN
            RAISE EXCEPTION 'Execution split lineage is immutable' USING ERRCODE='23514';
        END IF;
    ELSIF NEW.split_root_demand_id IS DISTINCT FROM OLD.split_root_demand_id THEN
        RAISE EXCEPTION 'Split demand root is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION fn_can_split_execution_batch(p_segment UUID) RETURNS boolean LANGUAGE sql STABLE AS $$
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
          AND NOT EXISTS(SELECT 1 FROM production_material_demands demand JOIN stock_reservations reservation ON reservation.demand_id=demand.id WHERE demand.execution_segment_id=segment.id));
$$;
CREATE TRIGGER trg_guard_execution_split_history BEFORE INSERT OR UPDATE OR DELETE
    ON production_execution_segment_splits FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_split_history();
CREATE TRIGGER trg_guard_execution_split_segment_identity BEFORE INSERT OR UPDATE ON production_execution_segments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_split_history();
CREATE TRIGGER trg_guard_execution_split_demand_identity BEFORE UPDATE ON production_material_demands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_split_history();

CREATE FUNCTION fn_assert_execution_batch_split(p_source UUID) RETURNS void LANGUAGE plpgsql AS $$
DECLARE split production_execution_segment_splits%ROWTYPE; source production_execution_segments%ROWTYPE;
        child production_execution_segments%ROWTYPE; root_demand production_material_demands%ROWTYPE;
        requirement JSONB; demand_qty NUMERIC; combined NUMERIC; prior_required NUMERIC;
BEGIN
    SELECT * INTO split FROM production_execution_segment_splits WHERE source_segment_id=p_source;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT * INTO source FROM production_execution_segments WHERE id=p_source;
    IF source.status<>'CANCELLED' OR source.is_deleted OR source.planned_qty<>split.source_qty
       OR source.lock_version<>split.expected_version+1 THEN
        RAISE EXCEPTION 'Execution split must preserve retired source quantity' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM production_material_demands demand WHERE demand.execution_segment_id=p_source
        AND (demand.status<>'RELEASED' OR demand.released_qty<>demand.required_qty OR demand.is_deleted)) THEN
        RAISE EXCEPTION 'Execution split must release only its original unused demand capacity' USING ERRCODE='23514';
    END IF;
    FOR child IN SELECT * FROM production_execution_segments
        WHERE id IN (split.batch_segment_id,split.remaining_segment_id) LOOP
        IF child.is_deleted OR child.source_segment_id<>source.id
          OR (child.package_id,child.plan_id,child.source_plan_item_id,child.product_goods_id,child.product_color_id,
              child.product_unit_id,child.product_unit_rate,child.bom_fingerprint)
             IS DISTINCT FROM (source.package_id,source.plan_id,source.source_plan_item_id,source.product_goods_id,
              source.product_color_id,source.product_unit_id,source.product_unit_rate,source.bom_fingerprint)
          OR child.planned_qty<>(CASE WHEN child.id=split.batch_segment_id THEN split.batch_qty ELSE split.remaining_qty END)
          OR child.split_root_segment_id<>COALESCE(source.split_root_segment_id,source.id)
          OR child.split_start_qty<>source.split_start_qty+(CASE WHEN child.id=split.batch_segment_id THEN 0 ELSE split.batch_qty END) THEN
            RAISE EXCEPTION 'Execution split child does not preserve its exact source identity and quantity' USING ERRCODE='23514';
        END IF;
        IF jsonb_array_length(child.split_material_snapshot)<>(SELECT count(*) FROM production_material_demands
              WHERE execution_segment_id=child.split_root_segment_id AND NOT is_deleted)
           OR jsonb_array_length(child.split_material_snapshot)<>(SELECT count(DISTINCT item->>'rootDemandId')
              FROM jsonb_array_elements(child.split_material_snapshot) item) THEN
            RAISE EXCEPTION 'Split snapshot must preserve every original material exactly once' USING ERRCODE='23514';
        END IF;
        FOR requirement IN SELECT * FROM jsonb_array_elements(child.split_material_snapshot) LOOP
            SELECT * INTO root_demand FROM production_material_demands
                WHERE id=(requirement->>'rootDemandId')::uuid;
            IF root_demand.id IS NULL OR root_demand.execution_segment_id<>child.split_root_segment_id
              OR requirement->>'requiredQty' IS NULL OR requirement->>'priorQty' IS NULL
              OR requirement->>'requiresPrior' IS NULL
              OR (requirement->>'requiredQty')::numeric<0 OR (requirement->>'priorQty')::numeric<0 THEN
                RAISE EXCEPTION 'Split material must reference its exact original demand' USING ERRCODE='23514';
            END IF;
            SELECT COALESCE(sum(prior_demand.required_qty),0) INTO prior_required
            FROM production_material_demands prior_demand
            JOIN production_execution_segments prior ON prior.id=prior_demand.execution_segment_id
            WHERE prior_demand.split_root_demand_id=root_demand.id
              AND prior.split_root_segment_id=child.split_root_segment_id
              AND prior.split_start_qty+COALESCE(prior.material_snapshot_product_qty,prior.planned_qty)<=child.split_start_qty
              AND NOT EXISTS(SELECT 1 FROM production_execution_segment_splits replacement WHERE replacement.source_segment_id=prior.id);
            IF (requirement->>'priorQty')::numeric<>prior_required
               OR (requirement->>'requiresPrior')::boolean IS DISTINCT FROM
                    (prior_required>0 AND (root_demand.requirement_mode='EXACT_SNAPSHOT'
                       OR (requirement->>'requiredQty')::numeric<ceil(COALESCE(child.material_snapshot_product_qty,child.planned_qty)*root_demand.per_product_qty*10000)/10000)) THEN
                RAISE EXCEPTION 'Split continuation must retain prior material allocation proof' USING ERRCODE='23514';
            END IF;
            SELECT COALESCE(sum(required_qty),0) INTO demand_qty FROM production_material_demands
                WHERE execution_segment_id=child.id AND split_root_demand_id=root_demand.id AND NOT is_deleted;
            IF demand_qty<>(requirement->>'requiredQty')::numeric THEN
                RAISE EXCEPTION 'Split child material snapshot and formal demands disagree' USING ERRCODE='23514';
            END IF;
        END LOOP;
    END LOOP;
    IF (SELECT count(*) FROM production_execution_segments WHERE id IN(split.batch_segment_id,split.remaining_segment_id))
       <>(CASE WHEN split.remaining_segment_id IS NULL THEN 1 ELSE 2 END) THEN
        RAISE EXCEPTION 'Execution split children are incomplete' USING ERRCODE='23514';
    END IF;
    FOR root_demand IN SELECT * FROM production_material_demands
        WHERE execution_segment_id=COALESCE(source.split_root_segment_id,source.id) LOOP
        SELECT COALESCE(sum((json_material->>'requiredQty')::numeric),0) INTO combined
        FROM production_execution_segments segment, jsonb_array_elements(segment.split_material_snapshot) json_material
        WHERE segment.id IN(split.batch_segment_id,split.remaining_segment_id)
          AND (json_material->>'rootDemandId')::uuid=root_demand.id;
        SELECT COALESCE(sum(required_qty),0) INTO demand_qty FROM production_material_demands
        WHERE execution_segment_id=source.id AND (id=root_demand.id OR split_root_demand_id=root_demand.id);
        IF combined<>demand_qty THEN
            RAISE EXCEPTION 'Execution split material quantities are not conserved' USING ERRCODE='23514';
        END IF;
    END LOOP;
END;
$$;

ALTER FUNCTION fn_assert_execution_segment_integrity(UUID) RENAME TO fn_assert_execution_segment_integrity_before_v561;
CREATE FUNCTION fn_assert_execution_segment_integrity(p_segment_id UUID) RETURNS void LANGUAGE plpgsql AS $$
DECLARE segment production_execution_segments%ROWTYPE;
BEGIN
    SELECT * INTO segment FROM production_execution_segments WHERE id=p_segment_id AND NOT is_deleted;
    IF NOT FOUND THEN RETURN; END IF;
    IF EXISTS(SELECT 1 FROM production_execution_segment_splits WHERE source_segment_id=p_segment_id) THEN
        PERFORM fn_assert_execution_batch_split(p_segment_id); RETURN;
    END IF;
    IF segment.source_segment_id IS NOT NULL THEN
        IF NOT EXISTS(SELECT 1 FROM production_execution_segment_splits split
            WHERE split.source_segment_id=segment.source_segment_id AND segment.id IN(split.batch_segment_id,split.remaining_segment_id)) THEN
            RAISE EXCEPTION 'Execution batch requires an exact immutable split proof' USING ERRCODE='23514';
        END IF;
        PERFORM fn_assert_execution_batch_split(segment.source_segment_id);
        IF segment.status IN ('READY','DISPATCHED','IN_PROGRESS') AND NOT fn_split_batch_prerequisites_issued(p_segment_id) THEN
            RAISE EXCEPTION 'Earlier batch material has not actually been issued' USING ERRCODE='23514';
        END IF;
        IF NOT EXISTS(SELECT 1 FROM production_material_demands WHERE execution_segment_id=p_segment_id AND NOT is_deleted)
           AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(segment.split_material_snapshot) material
                          WHERE (material->>'requiredQty')::numeric<>0)
           AND (segment.status='WAITING' OR fn_split_batch_empty_issued(p_segment_id)) THEN RETURN; END IF;
    END IF;
    PERFORM fn_assert_execution_segment_integrity_before_v561(p_segment_id);
END;
$$;

ALTER TABLE production_execution_segment_splits ENABLE ALWAYS TRIGGER trg_guard_execution_split_history;
ALTER TABLE production_execution_segment_splits ENABLE ALWAYS TRIGGER trg_audit_production_execution_segment_splits;
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_guard_execution_split_segment_identity;
ALTER TABLE production_material_demands ENABLE ALWAYS TRIGGER trg_guard_execution_split_demand_identity;

DO $reset_policy$
DECLARE definition TEXT;needle TEXT:='(''production_execution_segment_events'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V561 business reset contract changed';
    END IF;
    EXECUTE replace(definition,needle,needle||E',\n    (''production_execution_segment_splits'', ''CLEAR'')');
END;
$reset_policy$;

COMMENT ON TABLE production_execution_segment_splits IS 'Explicit unused execution splits; old identities, material quantities and sales allocations remain auditable.';
