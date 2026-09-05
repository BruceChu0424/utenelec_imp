-- V471: persist the primary issue warehouse together with the warehouses that
-- planners selected as transfer candidates for a material analysis.
--
-- production_material_analyses.warehouse_id remains the only authoritative
-- warehouse for readiness, exact entitlements, formal reservations and DRAW.
-- participating_warehouse_ids is a read/planning aid only.  It must never be
-- summed into READY or used as a physical reservation source without an
-- explicit, audited stock transfer into the primary warehouse.

CREATE OR REPLACE FUNCTION fn_uuid_array_is_unique(p_values UUID[])
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT cardinality(p_values) = (
        SELECT COUNT(DISTINCT value)
        FROM unnest(p_values) AS value
    );
$$;

ALTER TABLE production_material_analyses
    ADD COLUMN participating_warehouse_ids UUID[];

-- Every historical analysis with a primary warehouse keeps exactly that
-- warehouse selected.  A null primary cannot be repaired safely by guessing.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_analyses
        WHERE warehouse_id IS NULL
    ) THEN
        RAISE EXCEPTION
            'material analysis without a primary warehouse requires reconciliation before V471'
            USING ERRCODE = '23514';
    END IF;
END;
$$;

UPDATE production_material_analyses
SET participating_warehouse_ids = ARRAY[warehouse_id]::UUID[];

ALTER TABLE production_material_analyses
    ALTER COLUMN participating_warehouse_ids SET NOT NULL,
    ALTER COLUMN participating_warehouse_ids SET DEFAULT ARRAY[]::UUID[],
    ADD CONSTRAINT production_material_analysis_participating_warehouses_chk
        CHECK (
            cardinality(participating_warehouse_ids) BETWEEN 1 AND 100
            AND array_position(participating_warehouse_ids, NULL) IS NULL
            AND warehouse_id = ANY(participating_warehouse_ids)
            AND fn_uuid_array_is_unique(participating_warehouse_ids)
        ) NOT VALID;

ALTER TABLE production_material_analyses
    VALIDATE CONSTRAINT production_material_analysis_participating_warehouses_chk;

CREATE INDEX idx_production_material_analysis_participating_warehouses
    ON production_material_analyses
    USING gin(participating_warehouse_ids);

CREATE OR REPLACE FUNCTION fn_validate_material_analysis_warehouses()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    valid_count INTEGER;
BEGIN
    -- Compatibility for pre-V471 writers and fixtures that still insert only
    -- warehouse_id.  New services send the complete set explicitly.
    IF NEW.warehouse_id IS NULL THEN
        RAISE EXCEPTION
            'material analysis primary warehouse is required'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_analysis_primary_warehouse_required';
    END IF;
    IF NEW.participating_warehouse_ids IS NULL
       OR cardinality(NEW.participating_warehouse_ids) = 0 THEN
        NEW.participating_warehouse_ids := ARRAY[NEW.warehouse_id]::UUID[];
    END IF;

    SELECT COUNT(*)
    INTO valid_count
    FROM warehouses warehouse
    WHERE warehouse.id = ANY(NEW.participating_warehouse_ids)
      AND warehouse.is_deleted = FALSE
      AND warehouse.is_accountable = TRUE
      AND COALESCE(warehouse.status, '') <> '禁用';

    IF valid_count <> cardinality(NEW.participating_warehouse_ids) THEN
        RAISE EXCEPTION
            'material analysis participating warehouses must all be active accountable warehouses'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_analysis_participating_warehouses_fk_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_material_analysis_warehouses
    BEFORE INSERT OR UPDATE OF warehouse_id, participating_warehouse_ids
    ON production_material_analyses
    FOR EACH ROW EXECUTE FUNCTION fn_validate_material_analysis_warehouses();

COMMENT ON COLUMN production_material_analyses.participating_warehouse_ids IS
    'Planner-selected warehouses for availability and transfer hints. Includes warehouse_id; only warehouse_id can drive readiness, reservations or DRAW.';
