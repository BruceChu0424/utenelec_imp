-- Planning defines the initial allowance. Existing execution approvals stay unchanged;
-- their original initial allowance was 10%, even when a later review changed it.
ALTER TABLE production_plan_items
    ADD COLUMN allowed_overproduction_rate NUMERIC(9,6) NOT NULL DEFAULT 0.10,
    ADD CONSTRAINT production_plan_item_allowed_rate_valid CHECK (
        allowed_overproduction_rate >= 0 AND allowed_overproduction_rate < 'Infinity'::numeric);

COMMENT ON COLUMN production_plan_items.allowed_overproduction_rate IS
    'Initial allowance approved with the production plan; later execution changes use planning review';

-- Quantity growth is allowed only when the new intention has the exact same allowance.
-- A pending review freezes its quantity baseline, so another issue must get a new plan.
CREATE FUNCTION fn_plan_accepts_overproduction_allowance(p_plan UUID, p_rate NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT p_rate IS NOT NULL
      AND EXISTS (SELECT 1 FROM production_plan_items WHERE plan_id=p_plan AND NOT is_deleted)
      AND NOT EXISTS (
          SELECT 1 FROM production_plan_items
          WHERE plan_id=p_plan AND NOT is_deleted AND allowed_overproduction_rate <> p_rate)
      AND NOT EXISTS (
          SELECT 1 FROM production_execution_segments segment
          WHERE segment.plan_id=p_plan AND NOT segment.is_deleted
            AND segment.status NOT IN ('CANCELLED','REVERSED')
            AND (segment.allowed_overproduction_rate <> p_rate
                 OR EXISTS (SELECT 1 FROM production_overproduction_rate_requests request
                            WHERE request.execution_segment_id=segment.id AND request.status='PENDING')))
$$;

-- Both manual and material-analysis issuance ultimately create these same plan items.
-- The database is the single initializer, including non-JPA writers and multiple segments.
CREATE OR REPLACE FUNCTION fn_initialize_execution_overproduction_rate()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE inherited NUMERIC;
BEGIN
    IF NEW.source_segment_id IS NOT NULL THEN
        SELECT allowed_overproduction_rate INTO inherited
        FROM production_execution_segments WHERE id=NEW.source_segment_id FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Production batch tolerance needs its original task' USING ERRCODE='23514';
        END IF;
    ELSE
        SELECT allowed_overproduction_rate INTO inherited
        FROM production_plan_items
        WHERE id=NEW.source_plan_item_id AND plan_id=NEW.plan_id AND NOT is_deleted FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Production task tolerance needs its original plan item' USING ERRCODE='23514';
        END IF;
    END IF;
    NEW.allowed_overproduction_rate := inherited;
    NEW.overproduction_rate_version := 0;
    RETURN NEW;
END;
$$;

-- Editing a draft may set its initial allowance; an issued task can only change through
-- V698's immutable request/decision chain. Reversing a plan does not rewrite old history.
CREATE FUNCTION fn_guard_plan_initial_overproduction_allowance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.allowed_overproduction_rate IS NOT DISTINCT FROM OLD.allowed_overproduction_rate THEN
        RETURN NEW;
    END IF;
    PERFORM 1 FROM production_plans plan
    WHERE plan.id=OLD.plan_id AND plan.status=0 AND NOT plan.is_deleted
      AND plan.actual_output_supplement_request_id IS NULL FOR SHARE;
    IF NOT FOUND OR EXISTS (
        SELECT 1 FROM production_execution_segments WHERE source_plan_item_id=OLD.id
    ) THEN
        RAISE EXCEPTION 'Issued production tolerance changes require planning review' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_plan_initial_overproduction_allowance
BEFORE UPDATE OF allowed_overproduction_rate ON production_plan_items
FOR EACH ROW EXECUTE FUNCTION fn_guard_plan_initial_overproduction_allowance();
