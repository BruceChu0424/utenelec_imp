-- Warehouses use the organization workshop UUID as their live relationship.
--
-- Important legacy finding: B_Storage.WorkID is a Sys_Operator.ID. It is not
-- a SystemItem department/workshop id and it does not reference B_WorkShop.
-- The old warehouse column therefore remains a trace-only compatibility
-- snapshot and must never be used to infer workshop_department_id.

CREATE TABLE IF NOT EXISTS legacy_warehouse_workshop_links (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_legacy_id    INT NOT NULL UNIQUE,
    workshop_department_id UUID NOT NULL,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE warehouses
    ADD COLUMN workshop_department_id UUID,
    ADD COLUMN legacy_operator_id INT;

-- Install and validate FKs before any backfill. New writes are protected even
-- while an existing database is being upgraded.
ALTER TABLE warehouses
    ADD CONSTRAINT fk_warehouses_workshop_department
        FOREIGN KEY (workshop_department_id) REFERENCES departments(id)
        ON DELETE RESTRICT NOT VALID;

ALTER TABLE legacy_warehouse_workshop_links
    ADD CONSTRAINT fk_legacy_warehouse_workshop_department
        FOREIGN KEY (workshop_department_id) REFERENCES departments(id)
        ON DELETE RESTRICT NOT VALID;

ALTER TABLE warehouses
    VALIDATE CONSTRAINT fk_warehouses_workshop_department;

ALTER TABLE legacy_warehouse_workshop_links
    VALIDATE CONSTRAINT fk_legacy_warehouse_workshop_department;

CREATE INDEX idx_warehouses_workshop_department
    ON warehouses(workshop_department_id)
    WHERE workshop_department_id IS NOT NULL;

CREATE INDEX idx_legacy_warehouse_workshop_department
    ON legacy_warehouse_workshop_links(workshop_department_id);

COMMENT ON COLUMN warehouses.workshop_department_id IS
    'Live workshop UUID -> departments.id; must be a non-deleted direct child of DEPT_PROD';
COMMENT ON COLUMN warehouses.workshop_legacy_id IS
    'Compatibility snapshot: B_Storage.WorkID -> Sys_Operator.ID (historically misnamed; never a workshop bridge)';
COMMENT ON COLUMN warehouses.legacy_operator_id IS
    'Canonical compatibility snapshot: B_Storage.WorkID -> Sys_Operator.ID; read-only in normal APIs';
COMMENT ON TABLE legacy_warehouse_workshop_links IS
    'Explicit reviewed B_Storage.ID -> departments.id crosswalk; never populated by name matching';

CREATE OR REPLACE FUNCTION fn_guard_warehouse_workshop_department()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    valid_workshop_count BIGINT;
BEGIN
    IF NEW.workshop_department_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT count(*) INTO valid_workshop_count
    FROM departments workshop
    JOIN departments production_department
      ON production_department.id = workshop.parent_id
     AND production_department.code = 'DEPT_PROD'
     AND production_department.is_deleted = FALSE
    WHERE workshop.id = NEW.workshop_department_id
      AND workshop.is_deleted = FALSE;

    IF valid_workshop_count <> 1 THEN
        RAISE EXCEPTION
            'warehouse workshop must be a non-deleted direct child of DEPT_PROD'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'warehouse_production_workshop_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_warehouse_workshop_department
    BEFORE INSERT OR UPDATE OF workshop_department_id
    ON warehouses
    FOR EACH ROW EXECUTE FUNCTION fn_guard_warehouse_workshop_department();

CREATE TRIGGER trg_guard_legacy_warehouse_workshop_department
    BEFORE INSERT OR UPDATE OF workshop_department_id
    ON legacy_warehouse_workshop_links
    FOR EACH ROW EXECUTE FUNCTION fn_guard_warehouse_workshop_department();

CREATE OR REPLACE FUNCTION fn_sync_warehouse_legacy_operator_shadow()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.legacy_operator_id IS NOT NULL
           AND NEW.workshop_legacy_id IS NOT NULL
           AND NEW.legacy_operator_id <> NEW.workshop_legacy_id THEN
            RAISE EXCEPTION 'warehouse legacy operator shadows disagree'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'warehouse_legacy_operator_shadow_guard';
        END IF;
        NEW.legacy_operator_id := COALESCE(
            NEW.legacy_operator_id, NEW.workshop_legacy_id);
        NEW.workshop_legacy_id := COALESCE(
            NEW.workshop_legacy_id, NEW.legacy_operator_id);
        RETURN NEW;
    END IF;

    IF NEW.legacy_operator_id IS DISTINCT FROM OLD.legacy_operator_id
       AND NEW.workshop_legacy_id IS DISTINCT FROM OLD.workshop_legacy_id
       AND NEW.legacy_operator_id IS DISTINCT FROM NEW.workshop_legacy_id THEN
        RAISE EXCEPTION 'warehouse legacy operator shadows disagree'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'warehouse_legacy_operator_shadow_guard';
    ELSIF NEW.legacy_operator_id IS DISTINCT FROM OLD.legacy_operator_id THEN
        NEW.workshop_legacy_id := NEW.legacy_operator_id;
    ELSIF NEW.workshop_legacy_id IS DISTINCT FROM OLD.workshop_legacy_id THEN
        NEW.legacy_operator_id := NEW.workshop_legacy_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_warehouse_legacy_operator_shadow
    BEFORE INSERT OR UPDATE OF legacy_operator_id, workshop_legacy_id
    ON warehouses
    FOR EACH ROW EXECUTE FUNCTION fn_sync_warehouse_legacy_operator_shadow();

-- A physical FK protects hard deletes. This trigger also protects the normal
-- organization workflow, which soft-deletes departments.
CREATE OR REPLACE FUNCTION fn_guard_department_warehouse_workshop_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE'
       OR (OLD.is_deleted = FALSE AND NEW.is_deleted = TRUE) THEN
        IF EXISTS (
            SELECT 1
            FROM warehouses warehouse
            WHERE warehouse.workshop_department_id = OLD.id
              AND warehouse.is_deleted = FALSE
        ) OR EXISTS (
            SELECT 1
            FROM legacy_warehouse_workshop_links link
            WHERE link.workshop_department_id = OLD.id
        ) THEN
            RAISE EXCEPTION
                'department is referenced by a warehouse workshop relationship'
                USING ERRCODE = '23503',
                      CONSTRAINT = 'fk_warehouses_workshop_department';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_guard_department_warehouse_workshop_delete
    BEFORE UPDATE OF is_deleted OR DELETE
    ON departments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_department_warehouse_workshop_delete();

CREATE TRIGGER trg_set_updated_at_legacy_warehouse_workshop_links
    BEFORE UPDATE ON legacy_warehouse_workshop_links
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- V190 normally already covers warehouses, but refresh it explicitly here as
-- part of this relationship upgrade and attach audit to the new bridge table.
DROP TRIGGER IF EXISTS trg_audit_warehouses ON warehouses;
CREATE TRIGGER trg_audit_warehouses
    AFTER INSERT OR UPDATE OR DELETE ON warehouses
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_legacy_warehouse_workshop_links
    AFTER INSERT OR UPDATE OR DELETE ON legacy_warehouse_workshop_links
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Deterministic bridge only. The link is keyed by B_Storage.ID and must be
-- explicitly reviewed. B_Storage.WorkID/workshop_legacy_id is intentionally
-- excluded because it belongs to the Sys_Operator namespace.
UPDATE warehouses warehouse
SET legacy_operator_id = warehouse.workshop_legacy_id
WHERE warehouse.legacy_operator_id IS NULL
  AND warehouse.workshop_legacy_id IS NOT NULL
  AND warehouse.workshop_legacy_id <> 0;

UPDATE warehouses warehouse
SET workshop_department_id = link.workshop_department_id
FROM legacy_warehouse_workshop_links link
WHERE warehouse.workshop_department_id IS NULL
  AND warehouse.legacy_id IS NOT NULL
  AND warehouse.legacy_id <> 0
  AND link.warehouse_legacy_id = warehouse.legacy_id;
