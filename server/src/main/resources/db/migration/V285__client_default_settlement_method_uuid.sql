-- V285: make the client's default settlement method UUID-authoritative.
--
-- clients.price_style remains only the legacy B_PStyle snapshot.  Runtime
-- decisions (including the cash-shipment finance gate) use the persisted UUID
-- and the immutable settlement_methods.system_role instead of integer/name
-- guesses.

ALTER TABLE settlement_methods
    ADD COLUMN system_role VARCHAR(50);

ALTER TABLE settlement_methods
    ADD CONSTRAINT settlement_methods_system_role_chk
        CHECK (system_role IS NULL OR system_role ~ '^[A-Z][A-Z0-9_]*$');

CREATE UNIQUE INDEX ux_settlement_methods_system_role
    ON settlement_methods(system_role)
    WHERE system_role IS NOT NULL;

-- Reviewed one-time mapping from the deterministic V273 UUID.  The runtime
-- never rediscovers this role from legacy_id, code, or the Chinese name.
UPDATE settlement_methods
SET system_role = 'CASH'
WHERE id = '27300000-0000-4000-8100-000000000001'::UUID;

DO $$
BEGIN
    IF (SELECT count(*) FROM settlement_methods WHERE system_role = 'CASH') <> 1
       OR NOT EXISTS (
           SELECT 1
           FROM settlement_methods
           WHERE id = '27300000-0000-4000-8100-000000000001'::UUID
             AND system_role = 'CASH'
             AND status = '使用'
             AND COALESCE(is_deleted, FALSE) = FALSE
       ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'V285 cannot establish the unique active CASH settlement UUID role';
    END IF;
END
$$;

ALTER TABLE clients
    ADD COLUMN default_settlement_method_id UUID;

CREATE TABLE client_default_settlement_migration_issues (
    client_id          UUID PRIMARY KEY
        REFERENCES clients(id) ON DELETE RESTRICT,
    legacy_price_style INT NOT NULL,
    issue_code         VARCHAR(40) NOT NULL,
    active_match_count INT NOT NULL,
    detected_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at        TIMESTAMPTZ,
    resolved_by        UUID,
    resolution_note    TEXT,
    CONSTRAINT client_default_settlement_issue_code_chk
        CHECK (issue_code IN ('MISSING_ACTIVE_METHOD', 'AMBIGUOUS_ACTIVE_METHOD')),
    CONSTRAINT client_default_settlement_match_count_chk
        CHECK (active_match_count >= 0)
);

-- Only an exact, active, non-deleted and unique legacy dictionary match may be
-- used during this reviewed upgrade.  Missing/ambiguous values remain NULL and
-- are recorded below; ordinary runtime writes may never repeat this lookup.
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
UPDATE clients client
SET default_settlement_method_id = matches.method_id
FROM active_matches matches
WHERE client.price_style = matches.legacy_id
  AND matches.match_count = 1;

INSERT INTO client_default_settlement_migration_issues
    (client_id, legacy_price_style, issue_code, active_match_count)
SELECT client.id,
       client.price_style,
       CASE WHEN count(method.id) = 0
            THEN 'MISSING_ACTIVE_METHOD'
            ELSE 'AMBIGUOUS_ACTIVE_METHOD'
       END,
       count(method.id)::INT
FROM clients client
LEFT JOIN settlement_methods method
  ON method.legacy_id = client.price_style
 AND method.status = '使用'
 AND COALESCE(method.is_deleted, FALSE) = FALSE
WHERE client.price_style IS NOT NULL
  AND client.default_settlement_method_id IS NULL
GROUP BY client.id, client.price_style;

ALTER TABLE clients
    ADD CONSTRAINT fk_clients_default_settlement_method
        FOREIGN KEY (default_settlement_method_id)
        REFERENCES settlement_methods(id)
        ON DELETE RESTRICT
        NOT VALID;

ALTER TABLE clients
    VALIDATE CONSTRAINT fk_clients_default_settlement_method;

CREATE INDEX idx_clients_default_settlement_method
    ON clients(default_settlement_method_id)
    WHERE default_settlement_method_id IS NOT NULL;

-- UUID is the online write truth.  price_style is synchronized from it and is
-- accepted alone only in an explicitly marked legacy import transaction.  An
-- untouched unresolved historical row may still receive unrelated updates,
-- but reactivation or a changed relationship fails closed.
CREATE OR REPLACE FUNCTION fn_sync_client_default_settlement_method_reference()
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
            MESSAGE = 'clients.default_settlement_method_id is required for a default settlement write';
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
            MESSAGE = 'client default settlement UUID is missing, disabled, or deleted';
    END IF;
    IF supplied_legacy IS NOT NULL
       AND supplied_legacy IS DISTINCT FROM canonical_legacy THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'client default settlement UUID conflicts with price_style shadow';
    END IF;

    NEW.price_style := canonical_legacy;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_client_default_settlement_reference
    BEFORE INSERT OR UPDATE OF default_settlement_method_id, price_style, status, is_deleted
    ON clients
    FOR EACH ROW EXECUTE FUNCTION fn_sync_client_default_settlement_method_reference();

-- A migration issue is retained as an audit record.  A later explicit UUID
-- repair (or an explicit clearing of both fields) marks it resolved.
CREATE OR REPLACE FUNCTION fn_resolve_client_default_settlement_issue()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.default_settlement_method_id IS NOT NULL OR NEW.price_style IS NULL THEN
        UPDATE client_default_settlement_migration_issues
        SET resolved_at = COALESCE(resolved_at, now()),
            resolved_by = COALESCE(
                resolved_by,
                NULLIF(current_setting('app.actor_id', TRUE), '')::UUID),
            resolution_note = COALESCE(
                resolution_note,
                CASE WHEN NEW.default_settlement_method_id IS NULL
                     THEN 'default explicitly cleared'
                     ELSE 'resolved by UUID-authoritative write'
                END)
        WHERE client_id = NEW.id
          AND resolved_at IS NULL;
    END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_resolve_client_default_settlement_issue
    AFTER INSERT OR UPDATE OF default_settlement_method_id, price_style ON clients
    FOR EACH ROW EXECUTE FUNCTION fn_resolve_client_default_settlement_issue();

-- Protect both the immutable system meaning and active client relationships.
CREATE OR REPLACE FUNCTION fn_guard_client_default_settlement_method_target()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.system_role IS NOT NULL
           AND lower(COALESCE(
                current_setting('uten.system_settlement_role_maintenance', TRUE),
                'off')) NOT IN ('on', 'true', '1') THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'system settlement roles require controlled maintenance mode';
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        IF OLD.system_role IS NOT NULL THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'system settlement role/code is immutable and must remain active';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM clients client
            WHERE client.default_settlement_method_id = OLD.id
              AND client.status = '使用'
              AND COALESCE(client.is_deleted, FALSE) = FALSE
        ) THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'settlement method is an active client default and cannot be remapped, disabled, or deleted';
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.system_role IS NOT NULL
       AND (NEW.system_role IS DISTINCT FROM OLD.system_role
            OR NEW.code IS DISTINCT FROM OLD.code
            OR NEW.status IS DISTINCT FROM '使用'
            OR COALESCE(NEW.is_deleted, FALSE)) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'system settlement role/code is immutable and must remain active';
    END IF;

    IF OLD.system_role IS NULL AND NEW.system_role IS NOT NULL
       AND lower(COALESCE(
            current_setting('uten.system_settlement_role_maintenance', TRUE),
            'off')) NOT IN ('on', 'true', '1') THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'system settlement roles require controlled maintenance mode';
    END IF;

    IF (NEW.legacy_id IS DISTINCT FROM OLD.legacy_id
        OR NEW.status IS DISTINCT FROM '使用'
        OR COALESCE(NEW.is_deleted, FALSE))
       AND EXISTS (
           SELECT 1
           FROM clients client
           WHERE client.default_settlement_method_id = OLD.id
             AND client.status = '使用'
             AND COALESCE(client.is_deleted, FALSE) = FALSE
       ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'settlement method is an active client default and cannot be remapped, disabled, or deleted';
    END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_client_default_settlement_method_target
    BEFORE INSERT OR UPDATE OF system_role, code, legacy_id, status, is_deleted OR DELETE
    ON settlement_methods
    FOR EACH ROW EXECUTE FUNCTION fn_guard_client_default_settlement_method_target();

CREATE TRIGGER trg_audit_client_default_settlement_migration_issues
    AFTER INSERT OR UPDATE OR DELETE ON client_default_settlement_migration_issues
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON COLUMN settlement_methods.system_role IS
    'Immutable optional machine role; CASH drives the shipment finance gate without integer/name guesses.';
COMMENT ON COLUMN clients.default_settlement_method_id IS
    'UUID-authoritative client default; price_style is the synchronized legacy B_PStyle snapshot only.';
COMMENT ON TABLE client_default_settlement_migration_issues IS
    'Durable V285 reconciliation evidence for non-null legacy client defaults without exactly one active UUID match.';

-- V285 creates a business reconciliation-evidence table after the V279 sweep.
-- Refresh and verify full public audit coverage; the evidence table is not a
-- technical-table exemption.
DO $$
DECLARE
    table_record RECORD;
    prefixed_trigger_count INTEGER;
    valid_trigger_count INTEGER;
    missing_tables TEXT;
BEGIN
    FOR table_record IN
        SELECT c.oid, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname NOT IN (
              'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
              'authorization_state', 'doc_number_sequences', 'master_code_sequences',
              'category_master_code_sequences', 'business_document_sequences',
              'production_product_no_sequences',
              'report_materialized_view_refresh_state', 'password_history',
              'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
          AND c.relname NOT LIKE 'legacy_migration_%'
        ORDER BY c.relname
    LOOP
        SELECT count(*),
               count(*) FILTER (WHERE
                   audit_trigger.tgenabled IN ('O', 'A')
                   AND (audit_trigger.tgtype::INTEGER & 1) = 1
                   AND (audit_trigger.tgtype::INTEGER & 2) = 0
                   AND (audit_trigger.tgtype::INTEGER & 4) = 4
                   AND (audit_trigger.tgtype::INTEGER & 8) = 8
                   AND (audit_trigger.tgtype::INTEGER & 16) = 16
                   AND function_schema.nspname = 'public'
                   AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted'))
        INTO prefixed_trigger_count, valid_trigger_count
        FROM pg_trigger audit_trigger
        JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
        JOIN pg_namespace function_schema ON function_schema.oid = audit_function.pronamespace
        WHERE audit_trigger.tgrelid = table_record.oid
          AND NOT audit_trigger.tgisinternal
          AND audit_trigger.tgname LIKE 'trg_audit%';

        IF prefixed_trigger_count = 1 AND valid_trigger_count = 1 THEN
            CONTINUE;
        END IF;
        IF prefixed_trigger_count > 0 THEN
            RAISE EXCEPTION
                'public.% has % trg_audit* triggers but exactly one valid enabled AFTER ROW INSERT/UPDATE/DELETE audit trigger is required (valid=%)',
                table_record.relname, prefixed_trigger_count, valid_trigger_count
                USING ERRCODE = '55000';
        END IF;
        EXECUTE format(
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit()', table_record.relname);
    END LOOP;

    SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO missing_tables
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND NOT c.relispartition
      AND c.relname NOT IN (
          'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
          'authorization_state', 'doc_number_sequences', 'master_code_sequences',
          'category_master_code_sequences', 'business_document_sequences',
          'production_product_no_sequences',
          'report_materialized_view_refresh_state', 'password_history',
          'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
      AND c.relname NOT LIKE 'legacy_migration_%'
      AND (
          (SELECT count(*) FROM pg_trigger audit_trigger
           WHERE audit_trigger.tgrelid = c.oid AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%') <> 1
          OR
          (SELECT count(*)
           FROM pg_trigger audit_trigger
           JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
           JOIN pg_namespace function_schema ON function_schema.oid = audit_function.pronamespace
           WHERE audit_trigger.tgrelid = c.oid AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%'
             AND audit_trigger.tgenabled IN ('O', 'A')
             AND (audit_trigger.tgtype::INTEGER & 1) = 1
             AND (audit_trigger.tgtype::INTEGER & 2) = 0
             AND (audit_trigger.tgtype::INTEGER & 4) = 4
             AND (audit_trigger.tgtype::INTEGER & 8) = 8
             AND (audit_trigger.tgtype::INTEGER & 16) = 16
             AND function_schema.nspname = 'public'
             AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted')) <> 1);

    IF missing_tables IS NOT NULL THEN
        RAISE EXCEPTION 'Audit trigger coverage remains invalid for: %', missing_tables
            USING ERRCODE = '55000';
    END IF;
END $$;
