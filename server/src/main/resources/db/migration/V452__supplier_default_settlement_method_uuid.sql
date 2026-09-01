-- V452: make the supplier's default settlement method UUID-authoritative.
--
-- Mirrors the V285 client contract for the payables side:
--   * suppliers.price_style remains only the legacy B_Provider.PStyle snapshot;
--   * suppliers.default_settlement_method_id is the online write truth and is
--     used solely as the default offered when creating purchase/subcontract
--     orders (orders remain the required, finance-frozen authority — V330/ADR-047);
--   * runtime never rediscovers the meaning of a method from legacy ints or names.
--
-- Unlike clients there is no operational gate that depends on this column, so
-- unresolved legacy rows surface in a live reconciliation view instead of a
-- blocking migration-issues table.

ALTER TABLE suppliers
    ADD COLUMN default_settlement_method_id UUID;

-- Reviewed one-time mapping: only an exact, active, non-deleted and unique
-- legacy dictionary match may be backfilled here. Missing/ambiguous values
-- stay NULL for humans to maintain; ordinary runtime writes never repeat this
-- lookup.
WITH active_matches AS (
    SELECT legacy_id,
           (array_agg(id ORDER BY id))[1] AS method_id,
           count(*)::INT AS match_count
    FROM settlement_methods
    WHERE legacy_id IS NOT NULL
      AND status = '使用'
      AND COALESCE(is_deleted, FALSE) = FALSE
    GROUP BY legacy_id
)
UPDATE suppliers supplier
SET default_settlement_method_id = matches.method_id
FROM active_matches matches
WHERE supplier.price_style = matches.legacy_id
  AND matches.match_count = 1;

ALTER TABLE suppliers
    ADD CONSTRAINT fk_suppliers_default_settlement_method
        FOREIGN KEY (default_settlement_method_id)
        REFERENCES settlement_methods(id)
        ON DELETE RESTRICT
        NOT VALID;

ALTER TABLE suppliers
    VALIDATE CONSTRAINT fk_suppliers_default_settlement_method;

CREATE INDEX idx_suppliers_default_settlement_method
    ON suppliers(default_settlement_method_id)
    WHERE default_settlement_method_id IS NOT NULL;

-- Live reconciliation evidence: non-deleted suppliers whose legacy price_style
-- has no exactly-one active UUID match. The view shrinks as humans maintain
-- defaults; it is evidence, not a gate.
CREATE VIEW v_supplier_default_settlement_migration_issues AS
SELECT supplier.id AS supplier_id,
       supplier.code AS supplier_code,
       supplier.name AS supplier_name,
       supplier.status AS supplier_status,
       supplier.price_style AS legacy_price_style,
       count(method.id)::INT AS active_match_count
FROM suppliers supplier
LEFT JOIN settlement_methods method
  ON method.legacy_id = supplier.price_style
 AND method.status = '使用'
 AND COALESCE(method.is_deleted, FALSE) = FALSE
WHERE supplier.price_style IS NOT NULL
  AND supplier.default_settlement_method_id IS NULL
  AND COALESCE(supplier.is_deleted, FALSE) = FALSE
GROUP BY supplier.id, supplier.code, supplier.name,
         supplier.status, supplier.price_style;

-- UUID is the online write truth; price_style is synchronized from it and is
-- accepted alone only in an explicitly marked legacy import transaction.
CREATE OR REPLACE FUNCTION fn_sync_supplier_default_settlement_method_reference()
RETURNS TRIGGER AS $$
DECLARE
    method_id UUID := NEW.default_settlement_method_id;
    supplied_legacy INT := NEW.price_style;
    canonical_legacy INT;
    relationship_untouched BOOLEAN := FALSE;
    becoming_active BOOLEAN := FALSE;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        relationship_untouched :=
            NEW.default_settlement_method_id IS NOT DISTINCT FROM OLD.default_settlement_method_id
            AND NEW.price_style IS NOT DISTINCT FROM OLD.price_style;
        becoming_active := NEW.status = '使用'
            AND COALESCE(NEW.is_deleted, FALSE) = FALSE
            AND (OLD.status IS DISTINCT FROM '使用'
                 OR COALESCE(OLD.is_deleted, FALSE));
    END IF;

    IF method_id IS NULL THEN
        IF supplied_legacy IS NULL
           OR lower(COALESCE(
                current_setting('uten.legacy_reference_import', TRUE),
                'off')) IN ('on', 'true', '1') THEN
            RETURN NEW;
        END IF;
        IF relationship_untouched AND NOT becoming_active THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'suppliers.default_settlement_method_id is required for a default settlement write';
    END IF;

    SELECT legacy_id INTO canonical_legacy
    FROM settlement_methods
    WHERE id = method_id
      AND status = '使用'
      AND COALESCE(is_deleted, FALSE) = FALSE;
    IF NOT FOUND THEN
        IF relationship_untouched
           AND (NEW.status IS DISTINCT FROM '使用'
                OR COALESCE(NEW.is_deleted, FALSE)) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'supplier default settlement UUID is missing, disabled, or deleted';
    END IF;
    IF supplied_legacy IS NOT NULL
       AND supplied_legacy IS DISTINCT FROM canonical_legacy THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'supplier default settlement UUID conflicts with price_style shadow';
    END IF;

    NEW.price_style := canonical_legacy;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_supplier_default_settlement_reference
    BEFORE INSERT OR UPDATE OF default_settlement_method_id, price_style, status, is_deleted
    ON suppliers
    FOR EACH ROW EXECUTE FUNCTION fn_sync_supplier_default_settlement_method_reference();

-- Protect active supplier default relationships on the settlement-method side,
-- mirroring the client guard. System-role rows keep the V285 immutability rules;
-- this trigger only adds the supplier-reference checks.
CREATE OR REPLACE FUNCTION fn_guard_supplier_default_settlement_method_target()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF EXISTS (
            SELECT 1
            FROM suppliers supplier
            WHERE supplier.default_settlement_method_id = OLD.id
              AND supplier.status = '使用'
              AND COALESCE(supplier.is_deleted, FALSE) = FALSE
        ) THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'settlement method is an active supplier default and cannot be remapped, disabled, or deleted';
        END IF;
        RETURN OLD;
    END IF;

    IF (NEW.legacy_id IS DISTINCT FROM OLD.legacy_id
        OR NEW.status IS DISTINCT FROM OLD.status
        OR COALESCE(NEW.is_deleted, FALSE))
       AND EXISTS (
           SELECT 1
           FROM suppliers supplier
           WHERE supplier.default_settlement_method_id = OLD.id
             AND supplier.status = '使用'
             AND COALESCE(supplier.is_deleted, FALSE) = FALSE
       ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'settlement method is an active supplier default and cannot be remapped, disabled, or deleted';
    END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_supplier_default_settlement_method_target
    BEFORE UPDATE OF legacy_id, status, is_deleted OR DELETE
    ON settlement_methods
    FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_default_settlement_method_target();

COMMENT ON COLUMN suppliers.default_settlement_method_id IS
    'UUID-authoritative supplier default offered when creating purchase/subcontract orders; price_style is the synchronized legacy B_Provider.PStyle snapshot only.';
COMMENT ON VIEW v_supplier_default_settlement_migration_issues IS
    'Live V452 reconciliation evidence: non-deleted suppliers with a legacy price_style that has no exactly-one active settlement-method UUID match.';
