-- Lifetime reservation for business-master codes.
--
-- Relationships continue to use UUIDs. Codes remain mutable display values, but a
-- normalized code (trimmed + case-insensitive) can never be assigned to another
-- business identity inside the same master domain, even after soft/hard deletion.
-- Historical duplicates are registered as legacy members instead of being silently
-- rewritten; V276 blocks every new identity from joining such a reservation.

CREATE TABLE master_code_reservations (
    id                    UUID NOT NULL DEFAULT gen_random_uuid(),
    master_domain         TEXT NOT NULL,
    normalized_code       TEXT NOT NULL,
    first_code_snapshot   TEXT NOT NULL,
    first_entity_id       UUID NOT NULL,
    first_legacy_identity TEXT,
    reserved_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT master_code_reservations_pk
        PRIMARY KEY (master_domain, normalized_code),
    CONSTRAINT master_code_reservations_id_uq UNIQUE (id),
    CONSTRAINT master_code_reservations_domain_chk
        CHECK (btrim(master_domain) <> ''),
    CONSTRAINT master_code_reservations_code_chk
        CHECK (normalized_code = upper(btrim(normalized_code))
               AND normalized_code <> '')
);

CREATE TABLE master_code_reservation_members (
    id              UUID NOT NULL DEFAULT gen_random_uuid(),
    master_domain   TEXT NOT NULL,
    normalized_code TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    legacy_identity TEXT,
    code_snapshot   TEXT NOT NULL,
    acquired_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT master_code_reservation_members_pk
        PRIMARY KEY (master_domain, normalized_code, entity_id),
    CONSTRAINT master_code_reservation_members_id_uq UNIQUE (id),
    CONSTRAINT master_code_reservation_members_reservation_fk
        FOREIGN KEY (master_domain, normalized_code)
        REFERENCES master_code_reservations(master_domain, normalized_code)
        ON DELETE RESTRICT
);

CREATE INDEX master_code_reservation_members_entity_idx
    ON master_code_reservation_members(master_domain, entity_id);
CREATE INDEX master_code_reservation_members_legacy_idx
    ON master_code_reservation_members(master_domain, legacy_identity)
    WHERE legacy_identity IS NOT NULL;

-- Seed every current and historical identity before write guards are installed.
-- Scope is deliberately per business-master domain. Position codes remain scoped to
-- their department; professional asset-category codes remain scoped to object type.
CREATE TEMP TABLE tmp_master_code_seed ON COMMIT DROP AS
SELECT 'GOODS'::TEXT master_domain, id entity_id, legacy_id::TEXT legacy_identity,
       code::TEXT code_snapshot, upper(btrim(code::TEXT)) normalized_code
FROM goods WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'MOULD', id, legacy_id::TEXT, code, upper(btrim(code))
FROM moulds WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'CLIENT', id, legacy_id::TEXT, code, upper(btrim(code))
FROM clients WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'SUPPLIER', id, legacy_id::TEXT, code, upper(btrim(code))
FROM suppliers WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'COLOR', id, legacy_id::TEXT, code, upper(btrim(code))
FROM colors WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'UNIT', id, legacy_id::TEXT, code, upper(btrim(code))
FROM units WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'CURRENCY', id, legacy_id::TEXT, code, upper(btrim(code))
FROM currencies WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'WAREHOUSE', id, legacy_id::TEXT, code, upper(btrim(code))
FROM warehouses WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'ACCOUNT', id, legacy_id::TEXT, code, upper(btrim(code))
FROM accounts WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'PAYMENT_STYLE', id, legacy_id::TEXT, code, upper(btrim(code))
FROM payment_styles WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'SETTLEMENT_METHOD', id, legacy_id::TEXT, code, upper(btrim(code))
FROM settlement_methods WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'FINANCE_PAYMENT_METHOD', id, legacy_id::TEXT, code, upper(btrim(code))
FROM finance_payment_methods WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'MATERIAL_CATEGORY_INTERNAL', id, legacy_id::TEXT, code, upper(btrim(code))
FROM material_categories WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'MOULD_CATEGORY_INTERNAL', id, legacy_id::TEXT, code, upper(btrim(code))
FROM mould_categories WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'CLIENT_CATEGORY_INTERNAL', id, legacy_id::TEXT, code, upper(btrim(code))
FROM client_categories WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'SUPPLIER_CATEGORY_INTERNAL', id, legacy_id::TEXT, code, upper(btrim(code))
FROM supplier_categories WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'DEPARTMENT', id, NULL, code, upper(btrim(code))
FROM departments WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'EMPLOYEE', id, legacy_id::TEXT, code, upper(btrim(code))
FROM employees WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'POSITION/' || department_id::TEXT, id, NULL, code, upper(btrim(code))
FROM positions
WHERE department_id IS NOT NULL AND NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'FIXED_ASSET', id, NULL, code, upper(btrim(code))
FROM fixed_assets WHERE NULLIF(btrim(code), '') IS NOT NULL
UNION ALL SELECT 'DEFERRED_EXPENSE', id, NULL, code, upper(btrim(code))
FROM deferred_expenses WHERE NULLIF(btrim(code), '') IS NOT NULL
-- A professional asset-category code identifies one logical policy family. New
-- versions intentionally receive a new UUID while keeping exactly the same code.
UNION ALL SELECT 'FINANCE_ASSET_CATEGORY/' || object_type, id, btrim(code), code, upper(btrim(code))
FROM finance_asset_categories
WHERE NULLIF(btrim(object_type), '') IS NOT NULL
  AND NULLIF(btrim(code), '') IS NOT NULL;

INSERT INTO master_code_reservations (
    master_domain, normalized_code, first_code_snapshot,
    first_entity_id, first_legacy_identity)
SELECT DISTINCT ON (master_domain, normalized_code)
       master_domain, normalized_code, code_snapshot,
       entity_id, legacy_identity
FROM tmp_master_code_seed
ORDER BY master_domain, normalized_code, entity_id;

INSERT INTO master_code_reservation_members (
    master_domain, normalized_code, entity_id, legacy_identity, code_snapshot)
SELECT master_domain, normalized_code, entity_id, legacy_identity, code_snapshot
FROM tmp_master_code_seed
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION fn_reserve_master_code()
RETURNS TRIGGER AS $$
DECLARE
    v_domain TEXT := TG_ARGV[0];
    v_scope_column TEXT := NULLIF(TG_ARGV[1], '');
    v_legacy_column TEXT := NULLIF(TG_ARGV[2], '');
    v_row JSONB := to_jsonb(NEW);
    v_entity_id UUID;
    v_scope TEXT;
    v_legacy_identity TEXT;
    v_code_snapshot TEXT;
    v_normalized_code TEXT;
    v_current_normalized TEXT;
    v_any_member BOOLEAN;
    v_self_member BOOLEAN;
    v_same_legacy_member BOOLEAN;
    v_other_member BOOLEAN;
BEGIN
    -- CategoryDrivenCodeService uses a two-phase placeholder only to avoid active
    -- unique-index swaps. Placeholder values are not business codes.
    IF current_setting('app.master_code_audit_stage', TRUE) = 'temporary' THEN
        RETURN NEW;
    END IF;

    v_entity_id := NULLIF(v_row ->> 'id', '')::UUID;
    v_code_snapshot := NULLIF(btrim(v_row ->> 'code'), '');
    IF v_code_snapshot IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = TG_TABLE_NAME || '.code must not be blank';
    END IF;
    IF v_entity_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = TG_TABLE_NAME || '.id is required before reserving a master code';
    END IF;

    IF v_scope_column IS NOT NULL THEN
        v_scope := NULLIF(btrim(v_row ->> v_scope_column), '');
        IF v_scope IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = TG_TABLE_NAME || '.' || v_scope_column
                    || ' is required for scoped master-code uniqueness';
        END IF;
        v_domain := v_domain || '/' || v_scope;
    END IF;
    IF v_legacy_column IS NOT NULL THEN
        v_legacy_identity := NULLIF(btrim(v_row ->> v_legacy_column), '');
    END IF;
    v_normalized_code := upper(v_code_snapshot);
    IF TG_OP = 'UPDATE' THEN
        v_current_normalized := upper(NULLIF(btrim(to_jsonb(OLD) ->> 'code'), ''));
    END IF;

    INSERT INTO master_code_reservations (
        master_domain, normalized_code, first_code_snapshot,
        first_entity_id, first_legacy_identity)
    VALUES (
        v_domain, v_normalized_code, v_code_snapshot,
        v_entity_id, v_legacy_identity)
    ON CONFLICT DO NOTHING;

    -- Serialize all attempts for the same normalized code.
    PERFORM 1
    FROM master_code_reservations
    WHERE master_domain = v_domain AND normalized_code = v_normalized_code
    FOR UPDATE;

    SELECT EXISTS (
               SELECT 1 FROM master_code_reservation_members member
               WHERE member.master_domain = v_domain
                 AND member.normalized_code = v_normalized_code),
           EXISTS (
               SELECT 1 FROM master_code_reservation_members member
               WHERE member.master_domain = v_domain
                 AND member.normalized_code = v_normalized_code
                 AND member.entity_id = v_entity_id),
           EXISTS (
               SELECT 1 FROM master_code_reservation_members member
               WHERE member.master_domain = v_domain
                 AND member.normalized_code = v_normalized_code
                 AND v_legacy_identity IS NOT NULL
                 AND member.legacy_identity = v_legacy_identity),
           EXISTS (
               SELECT 1 FROM master_code_reservation_members member
               WHERE member.master_domain = v_domain
                 AND member.normalized_code = v_normalized_code
                 AND member.entity_id <> v_entity_id)
    INTO v_any_member, v_self_member, v_same_legacy_member, v_other_member;

    -- Existing historical duplicates remain editable when their normalized code is
    -- unchanged, but cannot be reclaimed after moving away. A uniquely-owned old
    -- code can be restored by its original UUID. Full legacy re-import may recreate
    -- the same exact legacy identity after a controlled truncate.
    IF v_any_member
       AND NOT (
           (TG_OP = 'UPDATE' AND v_self_member
                AND (v_current_normalized = v_normalized_code OR NOT v_other_member))
           OR (TG_OP = 'INSERT' AND v_same_legacy_member)
       ) THEN
        RAISE EXCEPTION USING ERRCODE = '23505',
            CONSTRAINT = 'master_code_reservations_pk',
            MESSAGE = format(
                'master code is reserved for another identity: domain=%s code=%s',
                v_domain, v_code_snapshot);
    END IF;

    INSERT INTO master_code_reservation_members (
        master_domain, normalized_code, entity_id, legacy_identity, code_snapshot)
    VALUES (
        v_domain, v_normalized_code, v_entity_id, v_legacy_identity, v_code_snapshot)
    ON CONFLICT DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Static domains with a legacy identity column.
CREATE TRIGGER trg_reserve_code_goods BEFORE INSERT OR UPDATE OF code ON goods
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('GOODS', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_moulds BEFORE INSERT OR UPDATE OF code ON moulds
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('MOULD', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_clients BEFORE INSERT OR UPDATE OF code ON clients
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('CLIENT', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_suppliers BEFORE INSERT OR UPDATE OF code ON suppliers
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('SUPPLIER', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_colors BEFORE INSERT OR UPDATE OF code ON colors
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('COLOR', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_units BEFORE INSERT OR UPDATE OF code ON units
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('UNIT', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_currencies BEFORE INSERT OR UPDATE OF code ON currencies
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('CURRENCY', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_warehouses BEFORE INSERT OR UPDATE OF code ON warehouses
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('WAREHOUSE', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_accounts BEFORE INSERT OR UPDATE OF code ON accounts
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('ACCOUNT', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_payment_styles BEFORE INSERT OR UPDATE OF code ON payment_styles
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('PAYMENT_STYLE', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_settlement_methods BEFORE INSERT OR UPDATE OF code ON settlement_methods
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('SETTLEMENT_METHOD', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_finance_payment_methods BEFORE INSERT OR UPDATE OF code ON finance_payment_methods
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('FINANCE_PAYMENT_METHOD', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_material_categories BEFORE INSERT OR UPDATE OF code ON material_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('MATERIAL_CATEGORY_INTERNAL', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_mould_categories BEFORE INSERT OR UPDATE OF code ON mould_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('MOULD_CATEGORY_INTERNAL', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_client_categories BEFORE INSERT OR UPDATE OF code ON client_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('CLIENT_CATEGORY_INTERNAL', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_supplier_categories BEFORE INSERT OR UPDATE OF code ON supplier_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('SUPPLIER_CATEGORY_INTERNAL', '', 'legacy_id');
CREATE TRIGGER trg_reserve_code_employees BEFORE INSERT OR UPDATE OF code ON employees
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('EMPLOYEE', '', 'legacy_id');

-- Static domains without a legacy identity.
CREATE TRIGGER trg_reserve_code_departments BEFORE INSERT OR UPDATE OF code ON departments
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('DEPARTMENT', '', '');
CREATE TRIGGER trg_reserve_code_fixed_assets BEFORE INSERT OR UPDATE OF code ON fixed_assets
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('FIXED_ASSET', '', '');
CREATE TRIGGER trg_reserve_code_deferred_expenses BEFORE INSERT OR UPDATE OF code ON deferred_expenses
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('DEFERRED_EXPENSE', '', '');

-- Existing domain-scoped semantics are preserved.
CREATE TRIGGER trg_reserve_code_positions BEFORE INSERT OR UPDATE OF code, department_id ON positions
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('POSITION', 'department_id', '');
CREATE TRIGGER trg_reserve_code_finance_asset_categories
    BEFORE INSERT OR UPDATE OF code, object_type ON finance_asset_categories
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_master_code('FINANCE_ASSET_CATEGORY', 'object_type', 'code');

CREATE OR REPLACE FUNCTION fn_guard_master_code_reservation_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = TG_TABLE_NAME || ' is append-only; master-code reservations never expire';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_master_code_reservations_append_only
    BEFORE UPDATE OR DELETE ON master_code_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_master_code_reservation_append_only();
CREATE TRIGGER trg_guard_master_code_reservation_members_append_only
    BEFORE UPDATE OR DELETE ON master_code_reservation_members
    FOR EACH ROW EXECUTE FUNCTION fn_guard_master_code_reservation_append_only();

CREATE TRIGGER trg_audit_master_code_reservations
    AFTER INSERT OR UPDATE OR DELETE ON master_code_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_master_code_reservation_members
    AFTER INSERT OR UPDATE OR DELETE ON master_code_reservation_members
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE master_code_reservations IS
    'Lifetime normalized business-master code reservations; relationships always use UUID.';
COMMENT ON TABLE master_code_reservation_members IS
    'Append-only identities that historically owned a reserved code; duplicates are legacy evidence, not permission for new reuse.';
COMMENT ON FUNCTION fn_reserve_master_code() IS
    'Reserve trimmed/case-insensitive master codes per domain and reject assignment to another identity.';

-- Refresh full future-write audit coverage after V273-V276 introduced business
-- authorities, reviewed bridges, source ledgers and code-reservation history.
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
              'category_master_code_sequences',
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
          'category_master_code_sequences',
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
