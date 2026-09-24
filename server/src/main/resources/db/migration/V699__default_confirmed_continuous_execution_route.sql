-- New workshop tasks have an effective continuous route, not an unconfirmed hint.
-- Explicit historical routes and batch lineage remain unchanged. Physical issue
-- and explicit START retain their existing independent guards.
ALTER TABLE production_execution_segments ADD COLUMN route_defaulted_at TIMESTAMPTZ;
COMMENT ON COLUMN production_execution_segments.route_defaulted_at IS
    '系统默认持续生产的时间；不表示人工确认，人工改路线沿用ROUTE_CONFIRMED事件';

DO $migration$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
    WHERE conrelid='production_execution_segment_events'::regclass
      AND conname='production_execution_segment_events_action_check';
    IF definition IS NULL OR definition NOT LIKE 'CHECK (%' THEN
        RAISE EXCEPTION 'V699 cannot extend execution action constraint';
    END IF;
    ALTER TABLE production_execution_segment_events DROP CONSTRAINT production_execution_segment_events_action_check;
    EXECUTE 'ALTER TABLE production_execution_segment_events ADD CONSTRAINT production_execution_segment_events_action_check '
        || replace(definition, 'CHECK (', 'CHECK (action = ''ROUTE_DEFAULTED'' OR ');
END $migration$;

CREATE FUNCTION fn_default_continuous_execution_route() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.start_route IS NULL AND NEW.status IN ('WAITING','READY','DISPATCHED') THEN
        NEW.start_route := 'CONTINUOUS';
        NEW.continuous_supply := TRUE;
        NEW.route_confirmed_at := now();
        NEW.route_defaulted_at := now();
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_00_default_continuous_execution_route
    BEFORE INSERT ON production_execution_segments
    FOR EACH ROW EXECUTE FUNCTION fn_default_continuous_execution_route();

CREATE FUNCTION fn_record_default_continuous_execution_route() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO production_execution_segment_events(execution_segment_id, action, idempotency_key,
        request_hash, expected_version, resulting_version, created_at, created_by)
    VALUES(NEW.id, 'ROUTE_DEFAULTED', 'system-default-continuous:'||NEW.id,
        encode(digest('SYSTEM_DEFAULT|CONTINUOUS|'||NEW.id::text,'sha256'),'hex'),
        CASE WHEN TG_OP='INSERT' THEN NEW.lock_version ELSE OLD.lock_version END,
        NEW.lock_version, NEW.route_defaulted_at, NULL)
    ON CONFLICT (execution_segment_id, action, idempotency_key) DO NOTHING;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_record_default_continuous_route_insert
    AFTER INSERT ON production_execution_segments
    FOR EACH ROW WHEN (NEW.route_defaulted_at IS NOT NULL)
    EXECUTE FUNCTION fn_record_default_continuous_execution_route();
CREATE TRIGGER trg_record_default_continuous_route_update
    AFTER UPDATE ON production_execution_segments
    FOR EACH ROW WHEN (OLD.route_defaulted_at IS NULL AND NEW.route_defaulted_at IS NOT NULL)
    EXECUTE FUNCTION fn_record_default_continuous_execution_route();

-- Only still-open, unstarted tasks with no explicit choice receive the default.
UPDATE production_execution_segments segment
SET start_route='CONTINUOUS', continuous_supply=TRUE,
    route_confirmed_at=now(), route_defaulted_at=now()
FROM production_plans plan, production_planning_packages package
WHERE segment.plan_id=plan.id AND segment.package_id=package.id
  AND segment.start_route IS NULL AND NOT segment.is_deleted
  AND segment.status IN ('WAITING','READY','DISPATCHED')
  AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_closed
  AND NOT plan.is_canceled AND NOT plan.is_stopped
  AND package.status='CONFIRMED' AND NOT package.is_deleted
  AND NOT EXISTS(SELECT 1 FROM production_daily_report_items item WHERE item.execution_segment_id=segment.id);

UPDATE production_material_demands demand
SET direct_supply=TRUE, lock_version=demand.lock_version+1, updated_at=now()
FROM production_execution_segments segment
WHERE demand.execution_segment_id=segment.id AND segment.route_defaulted_at IS NOT NULL
  AND segment.start_route='CONTINUOUS' AND NOT demand.is_deleted
  AND demand.status NOT IN ('RELEASED','REVERSED') AND NOT demand.direct_supply
  AND fn_demand_direct_supply_eligible(demand.id);

CREATE OR REPLACE FUNCTION fn_auto_execution_start_route(p_segment UUID)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT 'CONTINUOUS'::text;
$$;
COMMENT ON FUNCTION fn_auto_execution_start_route(UUID) IS
    '新任务默认有效持续生产；明确选择的齐套/分批保持，物料实领与显式开工仍独立校验';
