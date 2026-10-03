-- Retain exact deleted business rows transactionally. Current projections keep
-- their original uniqueness, quantities and FK semantics. No age-based purge.
CREATE TABLE business_record_history (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_table text NOT NULL,
    source_id text NOT NULL,
    parent_table text,
    parent_id text,
    payload jsonb NOT NULL,
    operation text NOT NULL CHECK (operation IN ('DELETE','SOFT_DELETE')),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    actor_id uuid,
    actor_name text,
    request_id uuid,
    transaction_id bigint NOT NULL DEFAULT txid_current(),
    CHECK (jsonb_typeof(payload) = 'object'),
    CHECK ((parent_table IS NULL) = (parent_id IS NULL))
);
CREATE INDEX ix_business_record_history_identity ON business_record_history(source_table,source_id,id DESC);
CREATE INDEX ix_business_record_history_parent ON business_record_history(parent_table,parent_id,id DESC)
    WHERE parent_id IS NOT NULL;
CREATE TABLE business_record_retention_registry (
    source_table text PRIMARY KEY,
    parent_table text,
    parent_column text,
    CHECK ((parent_table IS NULL) = (parent_column IS NULL))
);
-- Permanent identity bindings prevent a replaced child UUID from being reused
-- under another document, including concurrent/rolling writers. No payload here.
CREATE TABLE business_record_identities (
    source_table text NOT NULL,
    source_id text NOT NULL,
    parent_table text NOT NULL,
    parent_id text,
    PRIMARY KEY(source_table,source_id)
);
COMMENT ON TABLE business_record_history IS
    'Permanent exact business deletion snapshots; read only through current domain authorization, never general audit-log payload access';
-- These are the immutable evidence/identity sinks, not another copy of the
-- already redacted audit stream. Avoid recursively auditing full payloads.
SELECT fn_audit_track_table('business_record_history','NONE','system',true);
SELECT fn_audit_track_table('business_record_identities','NONE','system',true);
SELECT fn_audit_track_table('business_record_retention_registry','FULL','system',false);

CREATE FUNCTION fn_business_history_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Retained business history cannot be modified or destroyed' USING ERRCODE='55000';
END;
$$;
CREATE TRIGGER trg_business_history_immutable BEFORE UPDATE OR DELETE ON business_record_history
    FOR EACH ROW EXECUTE FUNCTION fn_business_history_immutable();
CREATE TRIGGER trg_business_history_no_truncate BEFORE TRUNCATE ON business_record_history
    FOR EACH STATEMENT EXECUTE FUNCTION fn_business_history_immutable();
ALTER TABLE business_record_history ENABLE ALWAYS TRIGGER trg_business_history_immutable;
ALTER TABLE business_record_history ENABLE ALWAYS TRIGGER trg_business_history_no_truncate;
CREATE TRIGGER trg_business_identity_immutable BEFORE UPDATE OR DELETE ON business_record_identities
    FOR EACH ROW EXECUTE FUNCTION fn_business_history_immutable();
CREATE TRIGGER trg_business_identity_no_truncate BEFORE TRUNCATE ON business_record_identities
    FOR EACH STATEMENT EXECUTE FUNCTION fn_business_history_immutable();
ALTER TABLE business_record_identities ENABLE ALWAYS TRIGGER trg_business_identity_immutable;
ALTER TABLE business_record_identities ENABLE ALWAYS TRIGGER trg_business_identity_no_truncate;

CREATE FUNCTION fn_bind_business_record_identity(p_source text,p_id text,p_parent text,p_parent_id text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE bound_parent text; bound_id text;
BEGIN
    INSERT INTO business_record_identities VALUES(p_source,p_id,p_parent,p_parent_id)
    ON CONFLICT(source_table,source_id) DO NOTHING;
    SELECT parent_table,parent_id INTO bound_parent,bound_id FROM business_record_identities
    WHERE source_table=p_source AND source_id=p_id;
    -- A repeatable-read transaction that cannot see a concurrent binding fails
    -- closed instead of treating its old snapshot as an unbound identity.
    IF NOT FOUND THEN RAISE EXCEPTION 'Retained identity changed concurrently' USING ERRCODE='40001'; END IF;
    IF bound_parent IS DISTINCT FROM p_parent OR bound_id IS DISTINCT FROM p_parent_id THEN
        RAISE EXCEPTION 'A retained record identity cannot move to another parent; create a new identity' USING ERRCODE='23514';
    END IF;
END;
$$;

CREATE FUNCTION fn_guard_business_record_parent() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE payload jsonb:=to_jsonb(NEW); identity_text text; identity_columns text[];
BEGIN
    IF TG_OP='UPDATE' THEN
        RAISE EXCEPTION 'A retained record identity cannot move to another parent; create a new identity' USING ERRCODE='23514';
    END IF;
    identity_text:=payload->>'id';
    IF identity_text IS NULL THEN
        SELECT array_agg(a.attname ORDER BY k.ordinality) INTO identity_columns
        FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum,ordinality)
        JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum
        WHERE i.indrelid=TG_RELID AND i.indisprimary;
        SELECT jsonb_object_agg(key,value)::text INTO identity_text FROM jsonb_each(payload) WHERE key=ANY(identity_columns);
    END IF;
    PERFORM fn_bind_business_record_identity(TG_TABLE_NAME,identity_text,TG_ARGV[0],payload->>TG_ARGV[1]);
    RETURN NEW;
END;
$$;

CREATE FUNCTION fn_retain_business_record() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_payload jsonb := to_jsonb(OLD); saved_payload jsonb; identity_text text;
    parent_value text; parent_name text; identity_columns text[];
BEGIN
    IF TG_OP='UPDATE' THEN
        IF NOT (COALESCE(old_payload->>'is_deleted','false') <> 'true'
                AND to_jsonb(NEW)->>'is_deleted' = 'true') THEN RETURN NEW; END IF;
        saved_payload := to_jsonb(NEW);
    ELSE saved_payload := old_payload;
    END IF;
    identity_text := saved_payload->>'id';
    IF identity_text IS NULL THEN
        SELECT array_agg(a.attname ORDER BY k.ordinality) INTO identity_columns
        FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum,ordinality)
        JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum
        WHERE i.indrelid=TG_RELID AND i.indisprimary;
        SELECT jsonb_object_agg(key,value)::text INTO identity_text
        FROM jsonb_each(saved_payload) WHERE key=ANY(identity_columns);
    END IF;
    IF identity_text IS NULL THEN RAISE EXCEPTION 'Retained record lacks an identity: %',TG_TABLE_NAME; END IF;
    IF TG_NARGS=2 THEN
        parent_value:=saved_payload->>TG_ARGV[1];
        PERFORM fn_bind_business_record_identity(TG_TABLE_NAME,identity_text,TG_ARGV[0],parent_value);
        IF parent_value IS NOT NULL THEN parent_name:=TG_ARGV[0]; END IF;
    END IF;
    INSERT INTO business_record_history(source_table,source_id,parent_table,parent_id,payload,operation,
                                        actor_id,actor_name,request_id)
    VALUES(TG_TABLE_NAME,identity_text,parent_name,parent_value,saved_payload,
           CASE WHEN TG_OP='DELETE' THEN 'DELETE' ELSE 'SOFT_DELETE' END,
           NULLIF(current_setting('app.actor_id',true),'')::uuid,
           NULLIF(current_setting('app.actor_account',true),''),
           NULLIF(current_setting('app.audit_request_id',true),'')::uuid);
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;

-- TRUNCATE does not fire row triggers. Preserve every registered original even
-- during an explicitly requested business reset, within the same locked transaction.
CREATE FUNCTION fn_retain_business_records_before_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE keys text[]; parent_name text; parent_column text;
BEGIN
    SELECT array_agg(a.attname ORDER BY k.ordinality) INTO keys
    FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum,ordinality)
    JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum
    WHERE i.indrelid=TG_RELID AND i.indisprimary;
    IF TG_NARGS=2 THEN parent_name:=TG_ARGV[0];parent_column:=TG_ARGV[1]; END IF;
    IF parent_name IS NOT NULL THEN
        EXECUTE format($sql$
            SELECT fn_bind_business_record_identity($1,
                COALESCE(payload->>'id',(SELECT jsonb_object_agg(key,value)::text FROM jsonb_each(payload) WHERE key=ANY($2))),
                $3,payload->>$4)
            FROM (SELECT to_jsonb(source) payload FROM public.%I source) retained
            $sql$,TG_TABLE_NAME) USING TG_TABLE_NAME,keys,parent_name,parent_column;
    END IF;
    EXECUTE format($sql$
        INSERT INTO business_record_history(source_table,source_id,parent_table,parent_id,payload,operation,
                                            actor_id,actor_name,request_id)
        SELECT $1,COALESCE(payload->>'id',(SELECT jsonb_object_agg(key,value)::text FROM jsonb_each(payload) WHERE key=ANY($2))),
               CASE WHEN payload->>$4 IS NULL THEN NULL ELSE $3 END,payload->>$4,payload,'DELETE',
               NULLIF(current_setting('app.actor_id',true),'')::uuid,
               NULLIF(current_setting('app.actor_account',true),''),
               NULLIF(current_setting('app.audit_request_id',true),'')::uuid
        FROM (SELECT to_jsonb(source) payload FROM public.%I source) retained
        $sql$,TG_TABLE_NAME) USING TG_TABLE_NAME,keys,parent_name,parent_column;
    RETURN NULL;
END;
$$;

CREATE FUNCTION fn_register_record_retention(p_source text,p_parent text DEFAULT NULL,p_parent_column text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE relation regclass; arguments text;
BEGIN
    IF p_source !~ '^[a-z][a-z0-9_]*$' OR p_source IN ('business_record_history','business_record_retention_registry')
       OR ((p_parent IS NULL) <> (p_parent_column IS NULL)) THEN
        RAISE EXCEPTION 'Invalid retained business source';
    END IF;
    relation:=to_regclass(format('public.%I',p_source));
    IF relation IS NULL THEN RAISE EXCEPTION 'Missing retained business source %',p_source; END IF;
    IF NOT EXISTS(SELECT 1 FROM pg_index WHERE indrelid=relation AND indisprimary) THEN
        RAISE EXCEPTION 'Retained business source % needs a stable primary key',p_source;
    END IF;
    IF p_parent IS NOT NULL AND (to_regclass(format('public.%I',p_parent)) IS NULL
        OR NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=relation AND attname=p_parent_column AND NOT attisdropped)) THEN
        RAISE EXCEPTION 'Invalid retained business parent for %',p_source;
    END IF;
    INSERT INTO business_record_retention_registry VALUES(p_source,p_parent,p_parent_column)
    ON CONFLICT(source_table) DO UPDATE SET parent_table=EXCLUDED.parent_table,parent_column=EXCLUDED.parent_column;
    arguments:=CASE WHEN p_parent IS NULL THEN '' ELSE format('%L,%L',p_parent,p_parent_column) END;
    EXECUTE format('CREATE OR REPLACE TRIGGER trg_retain_business_record BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION fn_retain_business_record(%s)',p_source,arguments);
    EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_retain_business_record',p_source);
    EXECUTE format('CREATE OR REPLACE TRIGGER trg_retain_business_truncate BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION fn_retain_business_records_before_truncate(%s)',p_source,arguments);
    EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_retain_business_truncate',p_source);
    IF EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=relation AND attname='is_deleted' AND NOT attisdropped) THEN
        EXECUTE format('CREATE OR REPLACE TRIGGER trg_retain_soft_deleted_record BEFORE UPDATE OF is_deleted ON public.%I FOR EACH ROW WHEN (OLD.is_deleted IS DISTINCT FROM NEW.is_deleted AND NEW.is_deleted) EXECUTE FUNCTION fn_retain_business_record(%s)',p_source,arguments);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_retain_soft_deleted_record',p_source);
    END IF;
    IF p_parent IS NOT NULL THEN
        EXECUTE format('CREATE OR REPLACE TRIGGER trg_bind_business_record_parent BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION fn_guard_business_record_parent(%s)',p_source,arguments);
        EXECUTE format('CREATE OR REPLACE TRIGGER trg_guard_business_record_parent BEFORE UPDATE OF %I ON public.%I FOR EACH ROW WHEN (OLD.%I IS DISTINCT FROM NEW.%I) EXECUTE FUNCTION fn_guard_business_record_parent(%s)',p_parent_column,p_source,p_parent_column,p_parent_column,arguments);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_bind_business_record_parent',p_source);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_guard_business_record_parent',p_source);
    END IF;
END;
$$;

-- Explicit ownership registration is extended by domain migrations. Credential,
-- cache and scratch tables are never swept into this permanent content store.
SELECT fn_register_record_retention('sales_quotes');
SELECT fn_register_record_retention('sales_quote_items','sales_quotes','quote_id');
SELECT fn_register_record_retention('sales_orders');
SELECT fn_register_record_retention('sales_order_items','sales_orders','order_id');
SELECT fn_register_record_retention('sales_order_cost_items','sales_order_items','order_item_id');
SELECT fn_register_record_retention('sales_shipments');
SELECT fn_register_record_retention('sales_shipment_items','sales_shipments','shipment_id');
SELECT fn_register_record_retention('sales_other_shipments');
SELECT fn_register_record_retention('sales_other_shipment_items','sales_other_shipments','shipment_id');
SELECT fn_register_record_retention('sales_returns');
SELECT fn_register_record_retention('sales_return_items','sales_returns','return_id');
SELECT fn_register_record_retention('purchase_requests');
SELECT fn_register_record_retention('purchase_request_items','purchase_requests','request_id');
SELECT fn_register_record_retention('purchase_orders');
SELECT fn_register_record_retention('purchase_order_items','purchase_orders','order_id');
SELECT fn_register_record_retention('purchase_receipts');
SELECT fn_register_record_retention('purchase_receipt_items','purchase_receipts','receipt_id');
SELECT fn_register_record_retention('purchase_returns');
SELECT fn_register_record_retention('purchase_return_items','purchase_returns','return_id');
SELECT fn_register_record_retention('subcontract_applications');
SELECT fn_register_record_retention('subcontract_application_items','subcontract_applications','application_id');
SELECT fn_register_record_retention('subcontract_inquiries');
SELECT fn_register_record_retention('subcontract_inquiry_items','subcontract_inquiries','inquiry_id');
SELECT fn_register_record_retention('subcontract_orders');
SELECT fn_register_record_retention('subcontract_order_items','subcontract_orders','order_id');
SELECT fn_register_record_retention('subcontract_material_issues');
SELECT fn_register_record_retention('subcontract_material_issue_items','subcontract_material_issues','issue_id');
SELECT fn_register_record_retention('subcontract_material_returns');
SELECT fn_register_record_retention('subcontract_material_return_items','subcontract_material_returns','material_return_id');
SELECT fn_register_record_retention('subcontract_receipts');
SELECT fn_register_record_retention('subcontract_receipt_items','subcontract_receipts','receipt_id');
SELECT fn_register_record_retention('subcontract_returns');
SELECT fn_register_record_retention('subcontract_return_items','subcontract_returns','return_id');
SELECT fn_register_record_retention('subcontract_wastes');
SELECT fn_register_record_retention('subcontract_waste_items','subcontract_wastes','waste_id');
SELECT fn_register_record_retention('finance_bank_transfers');
SELECT fn_register_record_retention('finance_bank_transfer_lines','finance_bank_transfers','transfer_id');
SELECT fn_register_record_retention('finance_expenses');
SELECT fn_register_record_retention('finance_expense_items','finance_expenses','expense_id');
SELECT fn_register_record_retention('finance_other_incomes');
SELECT fn_register_record_retention('finance_other_income_items','finance_other_incomes','income_id');
SELECT fn_register_record_retention('finance_payments');
SELECT fn_register_record_retention('finance_payment_lines','finance_payments','payment_id');
SELECT fn_register_record_retention('finance_receipts');
SELECT fn_register_record_retention('finance_receipt_lines','finance_receipts','receipt_id');

ALTER TABLE expense_claims ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false;
ALTER TABLE expense_claims ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
-- Archived draft invoices remain in native history but do not reserve a live
-- reimbursement number. The deduplication key itself is unchanged.
ALTER TABLE expense_claim_invoices ADD COLUMN is_archived boolean NOT NULL DEFAULT false;
DO $invoice_active_unique$
DECLARE definition text;
BEGIN
    SELECT pg_get_indexdef('expense_claim_invoices_dedup_uq'::regclass) INTO definition;
    IF definition IS NULL OR definition LIKE '% WHERE %' THEN RAISE EXCEPTION 'Unexpected invoice deduplication definition'; END IF;
    DROP INDEX expense_claim_invoices_dedup_uq;
    EXECUTE definition || ' WHERE NOT is_archived';
END $invoice_active_unique$;
SELECT fn_register_record_retention('expense_claims');
SELECT fn_register_record_retention('expense_claim_items','expense_claims','claim_id');
SELECT fn_register_record_retention('expense_claim_invoices','expense_claims','claim_id');
SELECT fn_register_record_retention('expense_claim_events','expense_claims','claim_id');

-- Replaced responsibility, HR and master-data relations are records as well.
-- These snapshots have no generic audit HTTP endpoint: HR/price scope remains
-- the owning domain's responsibility and passwords/tokens are not registered.
SELECT fn_register_record_retention('user_data_scopes','users','user_id');
SELECT fn_register_record_retention('client_goods_aliases','clients','client_id');
SELECT fn_register_record_retention('unit_measurement_profiles','units','unit_id');
SELECT fn_register_record_retention('warehouse_keepers','warehouses','warehouse_id');
SELECT fn_register_record_retention('legacy_warehouse_workshop_links');
SELECT fn_register_record_retention('employee_credentials','employees','employee_id');
SELECT fn_register_record_retention('employee_education','employees','employee_id');
SELECT fn_register_record_retention('employee_secondary_departments','employees','employee_id');
SELECT fn_register_record_retention('employee_vehicles','employees','employee_id');
SELECT fn_register_record_retention('employee_phones','employees','employee_id');
SELECT fn_register_record_retention('department_permissions','departments','department_id');
SELECT fn_register_record_retention('suggestion_likes','suggestions','suggestion_id');
SELECT fn_register_record_retention('goods_bom_items','goods','goods_id');
SELECT fn_register_record_retention('platform_record_fields');

DO $reset_policy$
DECLARE definition text; anchor text := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V775 cannot extend reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor || E',\n            (''business_record_history'', ''PRESERVE'')'
        || E',\n            (''business_record_retention_registry'', ''PRESERVE'')'
        || E',\n            (''business_record_identities'', ''PRESERVE'')');
END $reset_policy$;
