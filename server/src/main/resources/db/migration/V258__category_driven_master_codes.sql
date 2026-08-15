-- Category-driven business numbers for the four hierarchical master-data domains.
--
-- UUID remains the only relationship key.  Category prefixes and master codes are
-- mutable display attributes; changing either never changes an entity id or FK.

-- The historical category code was not a safe relationship key (duplicates exist).
-- Preserve it twice: remark is user-editable, legacy_code_snapshot is immutable in
-- the application mapping.  code remains the internal path segment used by the
-- existing materialized-path triggers.
ALTER TABLE material_categories
    ADD COLUMN remark TEXT,
    ADD COLUMN legacy_code_snapshot TEXT,
    ADD COLUMN code_prefix TEXT,
    ADD COLUMN version BIGINT NOT NULL DEFAULT 0;
ALTER TABLE mould_categories
    ADD COLUMN remark TEXT,
    ADD COLUMN legacy_code_snapshot TEXT,
    ADD COLUMN code_prefix TEXT,
    ADD COLUMN version BIGINT NOT NULL DEFAULT 0;
ALTER TABLE client_categories
    ADD COLUMN remark TEXT,
    ADD COLUMN legacy_code_snapshot TEXT,
    ADD COLUMN code_prefix TEXT,
    ADD COLUMN version BIGINT NOT NULL DEFAULT 0;
ALTER TABLE supplier_categories
    ADD COLUMN remark TEXT,
    ADD COLUMN legacy_code_snapshot TEXT,
    ADD COLUMN code_prefix TEXT,
    ADD COLUMN version BIGINT NOT NULL DEFAULT 0;

UPDATE material_categories SET remark = code, legacy_code_snapshot = code;
UPDATE mould_categories SET remark = code, legacy_code_snapshot = code;
UPDATE client_categories SET remark = code, legacy_code_snapshot = code;
UPDATE supplier_categories SET remark = code, legacy_code_snapshot = code;

ALTER TABLE material_categories ADD CONSTRAINT material_categories_code_prefix_chk
    CHECK (code_prefix IS NULL OR code_prefix ~ '^[A-Z][A-Z0-9]{0,7}$');
ALTER TABLE mould_categories ADD CONSTRAINT mould_categories_code_prefix_chk
    CHECK (code_prefix IS NULL OR code_prefix ~ '^[A-Z][A-Z0-9]{0,7}$');
ALTER TABLE client_categories ADD CONSTRAINT client_categories_code_prefix_chk
    CHECK (code_prefix IS NULL OR code_prefix ~ '^[A-Z][A-Z0-9]{0,7}$');
ALTER TABLE supplier_categories ADD CONSTRAINT supplier_categories_code_prefix_chk
    CHECK (code_prefix IS NULL OR code_prefix ~ '^[A-Z][A-Z0-9]{0,7}$');

-- A prefix identifies one active category inside a master domain.  Prefixes may
-- repeat across different domains (for example a goods prefix and a client prefix),
-- while final active master codes remain unique inside their own master table.
CREATE UNIQUE INDEX material_categories_active_code_prefix_uq
    ON material_categories(code_prefix)
    WHERE is_deleted = false AND code_prefix IS NOT NULL;
CREATE UNIQUE INDEX mould_categories_active_code_prefix_uq
    ON mould_categories(code_prefix)
    WHERE is_deleted = false AND code_prefix IS NOT NULL;
CREATE UNIQUE INDEX client_categories_active_code_prefix_uq
    ON client_categories(code_prefix)
    WHERE is_deleted = false AND code_prefix IS NOT NULL;
CREATE UNIQUE INDEX supplier_categories_active_code_prefix_uq
    ON supplier_categories(code_prefix)
    WHERE is_deleted = false AND code_prefix IS NOT NULL;

-- One globally increasing numeric suffix per master type is the serialization
-- point for create, edit, category move and category-wide renumbering.  Prefixes
-- may end in digits (for example V6), so the suffix is stored separately rather
-- than re-parsed from a display code during later changes.
CREATE TABLE category_master_code_sequences (
    master_type TEXT PRIMARY KEY
        CHECK (master_type IN ('GOODS', 'MOULD', 'CLIENT', 'SUPPLIER')),
    last_seq BIGINT NOT NULL CHECK (last_seq >= 0)
);

ALTER TABLE goods
    ADD COLUMN code_managed BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN code_sequence BIGINT,
    ADD COLUMN code_prefix_category_id UUID REFERENCES material_categories(id) ON DELETE RESTRICT;
ALTER TABLE moulds
    ADD COLUMN code_managed BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN code_sequence BIGINT,
    ADD COLUMN code_prefix_category_id UUID REFERENCES mould_categories(id) ON DELETE RESTRICT;
ALTER TABLE clients
    ADD COLUMN code_managed BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN code_sequence BIGINT,
    ADD COLUMN code_prefix_category_id UUID REFERENCES client_categories(id) ON DELETE RESTRICT;
ALTER TABLE suppliers
    ADD COLUMN code_managed BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN code_sequence BIGINT,
    ADD COLUMN code_prefix_category_id UUID REFERENCES supplier_categories(id) ON DELETE RESTRICT;

-- Install binary-field redaction before the bulk metadata backfill below.  The
-- existing V185 audit trigger resolves this helper at execution time, so every
-- migration-generated goods UPDATE is audited without copying image bytea into
-- audit_log/WAL.
CREATE OR REPLACE FUNCTION fn_audit_redact_row(
    p_table_name TEXT,
    p_row JSONB
) RETURNS JSONB AS $$
DECLARE
    v_row JSONB;
BEGIN
    IF p_row IS NULL THEN
        RETURN NULL;
    END IF;

    v_row := p_row - ARRAY[
        'password_hash', 'token_hash', 'preview_token_hash', 'code_hash', 'secret',
        'id_card_enc', 'id_card_hash', 'phone_enc', 'phone_hash',
        'phone', 'phone2', 'link_phone', 'office_phone', 'email',
        'address', 'ship_address', 'huji_address', 'residence_address',
        'bank_account_enc', 'bank_branch_enc', 'bank_account', 'bank_account_no',
        'base_salary_enc', 'perf_salary_enc', 'social_insurance_base_enc',
        'housing_fund_base_enc', 'allowance_standard_enc',
        'old_value_enc', 'new_value_enc', 'plate_no_enc', 'qr_token', 'passcode',
        'content', 'body', 'message', 'description', 'remark', 'remarks',
        'note', 'comment', 'reject_reason', 'last_rejection_reason',
        'close_reason', 'reopen_reason', 'reversal_reason', 'location_text',
        'payload', 'exception_snapshot', 'calculation_snapshot',
        'required_document_codes', 'required_document_codes_snapshot',
        'source_ref', 'source_line_ref', 'linkman', 'legal_person',
        'ground_graph', 'product_graph1', 'product_graph2', 'product_graph3',
        'product_graph4', 'product_graph5', 'product_graph6', 'budget_graph'
    ];

    IF p_table_name = 'employees' THEN
        v_row := v_row - ARRAY[
            'full_name', 'gender', 'id_type', 'birth_date', 'ethnicity',
            'political_status', 'marital_status', 'paper_archive_no'
        ];
    ELSIF p_table_name = 'employee_compensation' THEN
        v_row := v_row - 'social_insurance_location';
    ELSIF p_table_name = 'emergency_contacts' THEN
        v_row := v_row - ARRAY['name', 'relationship'];
    ELSIF p_table_name = 'visitor_accounts' THEN
        v_row := v_row - 'name';
    ELSIF p_table_name = 'visitor_applications' THEN
        v_row := v_row - ARRAY['visitor_name', 'company', 'visit_purpose', 'plate_no'];
    ELSIF p_table_name = 'profile_change_requests' THEN
        v_row := v_row - 'review_comment';
    END IF;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Preserve an existing fallback-prefix suffix only when it is a positive BIGINT
-- and unique across the complete table.  Remaining legacy/manual/deleted rows get
-- a new internal stable suffix but stay unmanaged until an explicit operation
-- transitions them into category numbering.
WITH candidates AS (
    SELECT id, substring(code FROM 3)::BIGINT AS seq,
           row_number() OVER (
               PARTITION BY substring(code FROM 3)::BIGINT
               ORDER BY is_deleted ASC, id) AS rn
    FROM goods
    WHERE code ~ '^HP[0-9]{6,18}$'
      AND substring(code FROM 3)::NUMERIC > 0
)
UPDATE goods g
SET code_sequence = c.seq,
    code_managed = (c.rn = 1 AND NOT g.is_deleted)
FROM candidates c
WHERE g.id = c.id AND c.rn = 1;
WITH base AS (SELECT COALESCE(max(code_sequence), 0) AS n FROM goods),
     missing AS (
         SELECT id, row_number() OVER (ORDER BY id) AS rn
         FROM goods WHERE code_sequence IS NULL
     )
UPDATE goods g SET code_sequence = base.n + missing.rn
FROM base, missing WHERE g.id = missing.id;

WITH candidates AS (
    SELECT id, substring(code FROM 3)::BIGINT AS seq,
           row_number() OVER (
               PARTITION BY substring(code FROM 3)::BIGINT
               ORDER BY is_deleted ASC, id) AS rn
    FROM moulds
    WHERE code ~ '^MJ[0-9]{6,18}$'
      AND substring(code FROM 3)::NUMERIC > 0
)
UPDATE moulds m
SET code_sequence = c.seq,
    code_managed = (c.rn = 1 AND NOT m.is_deleted)
FROM candidates c
WHERE m.id = c.id AND c.rn = 1;
WITH base AS (SELECT COALESCE(max(code_sequence), 0) AS n FROM moulds),
     missing AS (
         SELECT id, row_number() OVER (ORDER BY id) AS rn
         FROM moulds WHERE code_sequence IS NULL
     )
UPDATE moulds m SET code_sequence = base.n + missing.rn
FROM base, missing WHERE m.id = missing.id;

WITH candidates AS (
    SELECT id, substring(code FROM 3)::BIGINT AS seq,
           row_number() OVER (
               PARTITION BY substring(code FROM 3)::BIGINT
               ORDER BY is_deleted ASC, id) AS rn
    FROM clients
    WHERE code ~ '^KH[0-9]{6,18}$'
      AND substring(code FROM 3)::NUMERIC > 0
)
UPDATE clients m
SET code_sequence = c.seq,
    code_managed = (c.rn = 1 AND NOT m.is_deleted)
FROM candidates c
WHERE m.id = c.id AND c.rn = 1;
WITH base AS (SELECT COALESCE(max(code_sequence), 0) AS n FROM clients),
     missing AS (
         SELECT id, row_number() OVER (ORDER BY id) AS rn
         FROM clients WHERE code_sequence IS NULL
     )
UPDATE clients m SET code_sequence = base.n + missing.rn
FROM base, missing WHERE m.id = missing.id;

WITH candidates AS (
    SELECT id, substring(code FROM 3)::BIGINT AS seq,
           row_number() OVER (
               PARTITION BY substring(code FROM 3)::BIGINT
               ORDER BY is_deleted ASC, id) AS rn
    FROM suppliers
    WHERE code ~ '^GY[0-9]{6,18}$'
      AND substring(code FROM 3)::NUMERIC > 0
)
UPDATE suppliers m
SET code_sequence = c.seq,
    code_managed = (c.rn = 1 AND NOT m.is_deleted)
FROM candidates c
WHERE m.id = c.id AND c.rn = 1;
WITH base AS (SELECT COALESCE(max(code_sequence), 0) AS n FROM suppliers),
     missing AS (
         SELECT id, row_number() OVER (ORDER BY id) AS rn
         FROM suppliers WHERE code_sequence IS NULL
     )
UPDATE suppliers m SET code_sequence = base.n + missing.rn
FROM base, missing WHERE m.id = missing.id;

ALTER TABLE goods ADD CONSTRAINT goods_code_sequence_positive_chk
    CHECK (code_sequence IS NOT NULL AND code_sequence > 0) NOT VALID;
ALTER TABLE moulds ADD CONSTRAINT moulds_code_sequence_positive_chk
    CHECK (code_sequence IS NOT NULL AND code_sequence > 0) NOT VALID;
ALTER TABLE clients ADD CONSTRAINT clients_code_sequence_positive_chk
    CHECK (code_sequence IS NOT NULL AND code_sequence > 0) NOT VALID;
ALTER TABLE suppliers ADD CONSTRAINT suppliers_code_sequence_positive_chk
    CHECK (code_sequence IS NOT NULL AND code_sequence > 0) NOT VALID;
ALTER TABLE goods VALIDATE CONSTRAINT goods_code_sequence_positive_chk;
ALTER TABLE moulds VALIDATE CONSTRAINT moulds_code_sequence_positive_chk;
ALTER TABLE clients VALIDATE CONSTRAINT clients_code_sequence_positive_chk;
ALTER TABLE suppliers VALIDATE CONSTRAINT suppliers_code_sequence_positive_chk;
ALTER TABLE goods ALTER COLUMN code_sequence SET NOT NULL;
ALTER TABLE moulds ALTER COLUMN code_sequence SET NOT NULL;
ALTER TABLE clients ALTER COLUMN code_sequence SET NOT NULL;
ALTER TABLE suppliers ALTER COLUMN code_sequence SET NOT NULL;

ALTER TABLE goods ADD CONSTRAINT goods_managed_code_present_chk
    CHECK (NOT code_managed OR code IS NOT NULL);
ALTER TABLE moulds ADD CONSTRAINT moulds_managed_code_present_chk
    CHECK (NOT code_managed OR code IS NOT NULL);
ALTER TABLE clients ADD CONSTRAINT clients_managed_code_present_chk
    CHECK (NOT code_managed OR code IS NOT NULL);
ALTER TABLE suppliers ADD CONSTRAINT suppliers_managed_code_present_chk
    CHECK (NOT code_managed OR code IS NOT NULL);

CREATE UNIQUE INDEX goods_code_sequence_uq ON goods(code_sequence);
CREATE UNIQUE INDEX moulds_code_sequence_uq ON moulds(code_sequence);
CREATE UNIQUE INDEX clients_code_sequence_uq ON clients(code_sequence);
CREATE UNIQUE INDEX suppliers_code_sequence_uq ON suppliers(code_sequence);
CREATE INDEX goods_code_prefix_category_idx ON goods(code_prefix_category_id);
CREATE INDEX moulds_code_prefix_category_idx ON moulds(code_prefix_category_id);
CREATE INDEX clients_code_prefix_category_idx ON clients(code_prefix_category_id);
CREATE INDEX suppliers_code_prefix_category_idx ON suppliers(code_prefix_category_id);

INSERT INTO category_master_code_sequences(master_type, last_seq) VALUES
    ('GOODS', (SELECT COALESCE(max(code_sequence), 0) FROM goods)),
    ('MOULD', (SELECT COALESCE(max(code_sequence), 0) FROM moulds)),
    ('CLIENT', (SELECT COALESCE(max(code_sequence), 0) FROM clients)),
    ('SUPPLIER', (SELECT COALESCE(max(code_sequence), 0) FROM suppliers));

CREATE TABLE master_code_change_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    master_type TEXT NOT NULL
        CHECK (master_type IN ('GOODS', 'MOULD', 'CLIENT', 'SUPPLIER')),
    category_id UUID NOT NULL,
    old_prefix TEXT NOT NULL,
    new_prefix TEXT NOT NULL,
    affected_count BIGINT NOT NULL CHECK (affected_count >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    request_id UUID
);
CREATE INDEX master_code_change_batches_category_idx
    ON master_code_change_batches(master_type, category_id, created_at DESC);

CREATE TABLE master_code_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES master_code_change_batches(id) ON DELETE RESTRICT,
    master_type TEXT NOT NULL
        CHECK (master_type IN ('GOODS', 'MOULD', 'CLIENT', 'SUPPLIER')),
    entity_id UUID NOT NULL,
    old_code TEXT,
    new_code TEXT NOT NULL,
    reason TEXT NOT NULL
        CHECK (reason IN ('AUTO_CREATE', 'CATEGORY_PREFIX_CHANGE', 'CATEGORY_MOVE', 'MANUAL_EDIT')),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_by UUID,
    request_id UUID,
    CONSTRAINT master_code_history_batch_entity_uq UNIQUE (batch_id, entity_id)
);
CREATE INDEX master_code_history_entity_idx
    ON master_code_history(master_type, entity_id, changed_at DESC);
CREATE INDEX master_code_history_batch_idx ON master_code_history(batch_id);

-- CategoryDrivenCodeService uses transaction-local settings only around its
-- two-phase uniqueness-safe update.  The temporary placeholder stage is an
-- internal implementation detail and is not audited; the final stage records a
-- logical before/after pair sourced from master_code_history.  Other updates keep
-- the established full generic audit behavior from V185.
CREATE OR REPLACE FUNCTION fn_audit() RETURNS TRIGGER AS $$
DECLARE
    v_actor UUID;
    v_actor_account TEXT;
    v_request_id UUID;
    v_action TEXT;
    v_target TEXT;
    v_before JSONB;
    v_after JSONB;
    v_identity JSONB;
    v_old_row JSONB;
    v_new_row JSONB;
    v_device JSONB;
    v_batch_id UUID;
    v_batch_old_code TEXT;
BEGIN
    IF TG_TABLE_NAME IN ('goods', 'moulds', 'clients', 'suppliers')
       AND NULLIF(current_setting('app.master_code_batch_id', true), '') IS NOT NULL
       AND current_setting('app.master_code_audit_stage', true) = 'temporary' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    v_actor_account := NULLIF(current_setting('app.actor_account', true), '');
    v_request_id := NULLIF(current_setting('app.audit_request_id', true), '')::UUID;
    v_action := lower(TG_OP);
    v_device := COALESCE(
        NULLIF(current_setting('app.audit_device_context', true), '')::JSONB,
        '{}'::JSONB);

    IF TG_TABLE_NAME IN ('goods', 'moulds', 'clients', 'suppliers')
       AND NULLIF(current_setting('app.master_code_batch_id', true), '') IS NOT NULL
       AND current_setting('app.master_code_audit_stage', true) = 'final' THEN
        v_batch_id := current_setting('app.master_code_batch_id', true)::UUID;
        SELECT h.old_code INTO v_batch_old_code
        FROM master_code_history h
        WHERE h.batch_id = v_batch_id AND h.entity_id = OLD.id;

        v_old_row := jsonb_build_object(
            'id', OLD.id,
            'category_id', OLD.category_id,
            'code', v_batch_old_code,
            'code_managed', OLD.code_managed,
            'code_sequence', OLD.code_sequence,
            'code_prefix_category_id', OLD.code_prefix_category_id,
            'is_deleted', OLD.is_deleted,
            'updated_at', OLD.updated_at);
        v_new_row := jsonb_build_object(
            'id', NEW.id,
            'category_id', NEW.category_id,
            'code', NEW.code,
            'code_managed', NEW.code_managed,
            'code_sequence', NEW.code_sequence,
            'code_prefix_category_id', NEW.code_prefix_category_id,
            'is_deleted', NEW.is_deleted,
            'updated_at', NEW.updated_at);
        v_before := fn_audit_redact_row(TG_TABLE_NAME, v_old_row);
        v_after := fn_audit_redact_row(TG_TABLE_NAME, v_new_row);
        v_identity := v_new_row;
    ELSE
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
            v_old_row := to_jsonb(OLD);
            v_before := fn_audit_redact_row(TG_TABLE_NAME, v_old_row);
            v_identity := v_old_row;
        END IF;
        IF TG_OP IN ('INSERT', 'UPDATE') THEN
            v_new_row := to_jsonb(NEW);
            v_after := fn_audit_redact_row(TG_TABLE_NAME, v_new_row);
            v_identity := v_new_row;
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' AND (
        ((v_old_row ->> 'is_deleted') = 'false'
            AND (v_new_row ->> 'is_deleted') = 'true')
        OR (v_old_row ? 'deleted_at'
            AND v_new_row ? 'deleted_at'
            AND (v_old_row ->> 'deleted_at') IS NULL
            AND (v_new_row ->> 'deleted_at') IS NOT NULL)
    ) THEN
        v_action := 'delete';
    END IF;

    v_target := COALESCE(
        v_identity ->> 'id', v_identity ->> 'bill_no', v_identity ->> 'code',
        v_identity ->> 'key', v_identity ->> 'period',
        v_identity ->> 'user_id', v_identity ->> 'employee_id');

    INSERT INTO audit_log (
        actor_id, actor_account, action, target_type, target_id,
        before, "after", ip, user_agent, result, request_id, event_source,
        client_event_id, device_installation_id, device_name,
        device_manufacturer, device_model, device_platform,
        device_os_version, app_version, app_build, device_form_factor,
        device_browser, device_locale, device_time_zone,
        device_time_zone_offset_minutes, device_is_physical, client_event_at,
        device_capture_status, device_profile_hash)
    VALUES (
        v_actor, v_actor_account, v_action, TG_TABLE_NAME, v_target,
        v_before, v_after,
        NULLIF(current_setting('app.audit_ip', true), ''),
        NULLIF(current_setting('app.audit_user_agent', true), ''),
        'success', v_request_id, 'database',
        NULLIF(v_device ->> 'clientEventId', '')::UUID,
        NULLIF(v_device ->> 'installationId', '')::UUID,
        NULLIF(v_device ->> 'deviceName', ''),
        NULLIF(v_device ->> 'manufacturer', ''),
        NULLIF(v_device ->> 'model', ''),
        NULLIF(v_device ->> 'platform', ''),
        NULLIF(v_device ->> 'osVersion', ''),
        NULLIF(v_device ->> 'appVersion', ''),
        NULLIF(v_device ->> 'appBuild', ''),
        NULLIF(v_device ->> 'formFactor', ''),
        NULLIF(v_device ->> 'browserName', ''),
        NULLIF(v_device ->> 'locale', ''),
        NULLIF(v_device ->> 'timeZone', ''),
        NULLIF(v_device ->> 'timeZoneOffsetMinutes', '')::INTEGER,
        NULLIF(v_device ->> 'physicalDevice', '')::BOOLEAN,
        NULLIF(v_device ->> 'clientEventAt', '')::TIMESTAMPTZ,
        COALESCE(NULLIF(v_device ->> 'captureStatus', ''), 'missing'),
        NULLIF(v_device ->> 'profileHash', ''));
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_master_code_change_batches
    AFTER INSERT OR UPDATE OR DELETE ON master_code_change_batches
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_master_code_history
    AFTER INSERT OR UPDATE OR DELETE ON master_code_history
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Fail closed after adding the two business-history tables.  The atomic suffix
-- counter is deliberately technical/high-churn; history and batch tables are not.
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
        SELECT
            count(*),
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
        JOIN pg_namespace function_schema
          ON function_schema.oid = audit_function.pronamespace
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
            'FOR EACH ROW EXECUTE FUNCTION fn_audit()',
            table_record.relname);
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
          (SELECT count(*)
           FROM pg_trigger audit_trigger
           WHERE audit_trigger.tgrelid = c.oid
             AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%') <> 1
          OR
          (SELECT count(*)
           FROM pg_trigger audit_trigger
           JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
           JOIN pg_namespace function_schema
             ON function_schema.oid = audit_function.pronamespace
           WHERE audit_trigger.tgrelid = c.oid
             AND NOT audit_trigger.tgisinternal
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

COMMENT ON COLUMN material_categories.code_prefix IS
    '下属货品编号前缀；空表示继承最近祖先，整条链为空时使用 HP';
COMMENT ON COLUMN mould_categories.code_prefix IS
    '下属模具编号前缀；空表示继承最近祖先，整条链为空时使用 MJ';
COMMENT ON COLUMN client_categories.code_prefix IS
    '下属客户编号前缀；空表示继承最近祖先，整条链为空时使用 KH';
COMMENT ON COLUMN supplier_categories.code_prefix IS
    '下属供应商编号前缀；空表示继承最近祖先，整条链为空时使用 GY';
COMMENT ON COLUMN material_categories.legacy_code_snapshot IS
    '迁移时冻结的旧分类编码，不参与运行时关联';
COMMENT ON TABLE category_master_code_sequences IS
    '分类驱动主档编号的原子高水位；每类主档一行，不是业务关联键';
COMMENT ON TABLE master_code_history IS
    '主档显示编号变更历史；实体关系始终使用 UUID，不使用这里的编号关联';
COMMENT ON FUNCTION fn_audit_redact_row(TEXT, JSONB) IS
    '审计行最小化：剔除凭证、PII、原因备注、大型 JSON 快照及货品 bytea 图片';
COMMENT ON FUNCTION fn_audit() IS
    '通用审计：保留 V185 语义，并将分类批量改号记录为无临时占位符的轻量逻辑变更';
