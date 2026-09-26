-- A remembered rate is a future planning default, never a rewrite of historical tasks.
ALTER TABLE goods ADD COLUMN production_overproduction_rate NUMERIC(9,6);
ALTER TABLE goods ADD CONSTRAINT goods_production_overproduction_rate_valid
    CHECK (production_overproduction_rate >= 0 AND production_overproduction_rate < 1000);
COMMENT ON COLUMN goods.production_overproduction_rate IS
    'Latest saved planning allowance or approved task allowance; null uses manufacturing-leaf default';

-- Purchased raw-material children do not introduce another manufacturing stage.
-- Unknown/subcontract/make children fail closed to zero until their route is confirmed.
CREATE FUNCTION fn_goods_default_overproduction_rate(p_goods UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(g.production_overproduction_rate,
        CASE WHEN g.source_type='自制' AND NOT EXISTS (
            SELECT 1 FROM goods_bom_items bom
            JOIN goods component ON component.id=bom.component_goods_id
            WHERE bom.goods_id=g.id AND NOT bom.is_deleted
              AND bom.control_stage NOT IN ('SHIP','REFERENCE')
              AND (component.is_deleted OR component.source_type IS DISTINCT FROM '采购')
        ) THEN 0.10 ELSE 0 END)
    FROM goods g WHERE g.id=p_goods AND NOT g.is_deleted
$$;

-- Includes non-JPA insert paths. Existing plan-item values are preserved verbatim.
ALTER TABLE production_plan_items ALTER COLUMN allowed_overproduction_rate DROP DEFAULT;
CREATE FUNCTION fn_initialize_plan_overproduction_default()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.allowed_overproduction_rate IS NULL THEN
        NEW.allowed_overproduction_rate := fn_goods_default_overproduction_rate(NEW.goods_id);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_initialize_plan_overproduction_default
BEFORE INSERT ON production_plan_items FOR EACH ROW
EXECUTE FUNCTION fn_initialize_plan_overproduction_default();

CREATE FUNCTION fn_remember_plan_overproduction_rate()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Fixed actual-output supplements are not editable future planning preferences.
    IF NOT NEW.is_deleted AND NOT EXISTS (
        SELECT 1 FROM production_plans WHERE id=NEW.plan_id
          AND actual_output_supplement_request_id IS NOT NULL
    ) THEN
        UPDATE goods SET production_overproduction_rate=NEW.allowed_overproduction_rate
        WHERE id=NEW.goods_id AND NOT is_deleted
          AND production_overproduction_rate IS DISTINCT FROM NEW.allowed_overproduction_rate;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_remember_plan_overproduction_rate
AFTER INSERT OR UPDATE OF allowed_overproduction_rate ON production_plan_items
FOR EACH ROW EXECUTE FUNCTION fn_remember_plan_overproduction_rate();

-- V698's existing guard only accepts approval-backed changes to this field.
-- Neither submitting nor returning a request changes a future default.
CREATE FUNCTION fn_remember_approved_overproduction_rate()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.allowed_overproduction_rate IS DISTINCT FROM OLD.allowed_overproduction_rate THEN
        UPDATE goods SET production_overproduction_rate=NEW.allowed_overproduction_rate
        WHERE id=NEW.product_goods_id AND NOT is_deleted
          AND production_overproduction_rate IS DISTINCT FROM NEW.allowed_overproduction_rate;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_remember_approved_overproduction_rate
AFTER UPDATE OF allowed_overproduction_rate ON production_execution_segments
FOR EACH ROW EXECUTE FUNCTION fn_remember_approved_overproduction_rate();
