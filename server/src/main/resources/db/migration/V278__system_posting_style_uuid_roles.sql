-- V278: system GL posting roles reference payment styles by persisted UUID.
--
-- Paths and names are consumed exactly once below to upgrade historical data.
-- Runtime posting reads only role_key -> style_id.  A fresh/empty database may
-- retain NULL mappings, but posting that needs one then fails closed.

CREATE TABLE system_posting_style_roles (
    role_key          TEXT PRIMARY KEY,
    id                UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    style_id          UUID UNIQUE REFERENCES payment_styles(id) ON DELETE RESTRICT,
    required_category TEXT NOT NULL,
    description       TEXT NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    updated_by        UUID,
    CONSTRAINT ck_system_posting_role_key
        CHECK (role_key ~ '^[A-Z][A-Z0-9_]*$'),
    CONSTRAINT ck_system_posting_role_category
        CHECK (required_category IN ('ACCOUNT','LIABILITY','EQUITY','EXPENSE','INCOME'))
);

INSERT INTO system_posting_style_roles
    (role_key, required_category, description)
VALUES
    ('AR_CONTROL',       'ACCOUNT',   '销售立账与收款的应收账款科目'),
    ('SALES_REVENUE',    'INCOME',    '销售立账的销售收入科目'),
    ('INVENTORY_ASSET',  'ACCOUNT',   '采购立账与成本结转的库存商品科目'),
    ('AP_CONTROL',       'LIABILITY', '采购立账与付款的应付账款科目'),
    ('SALES_COST',       'EXPENSE',   '销售成本结转科目'),
    ('BANK_FEE_EXPENSE', 'EXPENSE',   '收款手续费科目'),
    ('FX_GAIN_LOSS',     'EXPENSE',   '收付款汇兑损益科目');

-- Reviewed one-time historical upgrade.  A locator is accepted only when it
-- resolves to exactly one active, non-deleted style of the required category.
-- Zero or multiple matches deliberately leave style_id NULL.
WITH locator(role_key, locator_kind, locator_value) AS (
    VALUES
        ('AR_CONTROL',       'PATH', '/113/'),
        ('SALES_REVENUE',    'PATH', '/031/'),
        ('INVENTORY_ASSET',  'PATH', '/123/'),
        ('AP_CONTROL',       'PATH', '/203/'),
        ('SALES_COST',       'PATH', '/041/'),
        ('BANK_FEE_EXPENSE', 'NAME', '手续费'),
        ('FX_GAIN_LOSS',     'NAME', '汇兑损益')
), unique_candidate AS (
    SELECT role.role_key, (array_agg(style.id))[1] AS style_id
    FROM system_posting_style_roles role
    JOIN locator ON locator.role_key = role.role_key
    JOIN payment_styles style
      ON style.category = role.required_category
     AND style.status = '使用'
     AND COALESCE(style.is_deleted, FALSE) = FALSE
     AND ((locator.locator_kind = 'PATH' AND style.path = locator.locator_value)
       OR (locator.locator_kind = 'NAME' AND style.name = locator.locator_value))
    GROUP BY role.role_key
    HAVING COUNT(*) = 1
)
UPDATE system_posting_style_roles role
SET style_id = candidate.style_id
FROM unique_candidate candidate
WHERE candidate.role_key = role.role_key;

CREATE OR REPLACE FUNCTION fn_enforce_system_posting_style_role()
RETURNS TRIGGER AS $$
DECLARE
    actual_category TEXT;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('PAYMENT_STYLE_HIERARCHY', 0));

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'system posting roles are immutable and cannot be deleted';
    END IF;
    IF TG_OP = 'UPDATE' AND (
            NEW.role_key IS DISTINCT FROM OLD.role_key
            OR NEW.required_category IS DISTINCT FROM OLD.required_category) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'system posting role keys and categories are immutable';
    END IF;

    IF NEW.style_id IS NOT NULL THEN
        SELECT style.category INTO actual_category
        FROM payment_styles style
        WHERE style.id = NEW.style_id
          AND style.status = '使用'
          AND COALESCE(style.is_deleted, FALSE) = FALSE;
        IF NOT FOUND THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'system posting role requires an active payment style UUID';
        END IF;
        IF actual_category IS DISTINCT FROM NEW.required_category THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'system posting role payment style category mismatch';
        END IF;
    END IF;

    NEW.updated_at := now();
    NEW.updated_by := COALESCE(
        NULLIF(current_setting('app.actor_id', TRUE), '')::UUID,
        NEW.updated_by);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_system_posting_style_role_guard
    BEFORE INSERT OR UPDATE OR DELETE ON system_posting_style_roles
    FOR EACH ROW EXECUTE FUNCTION fn_enforce_system_posting_style_role();

CREATE OR REPLACE FUNCTION fn_guard_mapped_system_posting_style()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'DELETE' OR NEW.status <> '使用'
            OR COALESCE(NEW.is_deleted, FALSE)
            OR NEW.category IS DISTINCT FROM OLD.category)
       AND EXISTS (
           SELECT 1 FROM system_posting_style_roles role
           WHERE role.style_id = OLD.id
       ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'payment style is mapped to a system posting role and cannot be disabled, deleted, or recategorized';
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_mapped_system_posting_style
    BEFORE UPDATE OF status, is_deleted, category OR DELETE ON payment_styles
    FOR EACH ROW EXECUTE FUNCTION fn_guard_mapped_system_posting_style();

CREATE TRIGGER trg_audit_system_posting_style_roles
    AFTER INSERT OR UPDATE OR DELETE ON system_posting_style_roles
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE FUNCTION system_posting_style_id(p_role_key TEXT)
RETURNS UUID AS $$
    SELECT role.style_id
    FROM system_posting_style_roles role
    JOIN payment_styles style ON style.id = role.style_id
    WHERE role.role_key = p_role_key
      AND style.category = role.required_category
      AND style.status = '使用'
      AND COALESCE(style.is_deleted, FALSE) = FALSE;
$$ LANGUAGE SQL STABLE STRICT;

COMMENT ON TABLE system_posting_style_roles IS
    'Stable system GL posting role to payment_styles UUID mappings; path/name are not runtime identities.';
COMMENT ON FUNCTION system_posting_style_id(TEXT) IS
    'Returns only the persisted active UUID mapping for a stable posting role; NULL means unavailable.';

-- Refresh complete future-write audit coverage.  This business mapping table
-- is deliberately audited and is not part of the technical-table allowlist.
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
