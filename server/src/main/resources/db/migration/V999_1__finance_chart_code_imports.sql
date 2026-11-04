-- External accounting codes are aliases of verified UUIDs, never replacement payment-style identities.
CREATE TABLE finance_chart_imports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_id uuid NOT NULL REFERENCES users(id),
    source_name text NOT NULL, sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    storage_provider text NOT NULL, storage_key text NOT NULL, storage_version text,
    storage_size bigint NOT NULL CHECK(storage_size > 0), preview jsonb NOT NULL,
    applied_at timestamptz, applied_result jsonb, created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(actor_id,sha256), CHECK((applied_at IS NULL) = (applied_result IS NULL))
);
CREATE TABLE finance_chart_codes (
    code text PRIMARY KEY CHECK(code ~ '^[0-9]{1,32}$'), name text NOT NULL CHECK(length(btrim(name)) BETWEEN 1 AND 240),
    currency_name text NOT NULL DEFAULT '', sort_order integer NOT NULL,
    native_style_id uuid UNIQUE REFERENCES payment_styles(id),
    source_row integer NOT NULL CHECK(source_row>0), source_import_id uuid REFERENCES finance_chart_imports(id),
    source_kind text NOT NULL DEFAULT 'IMPORT' CHECK(source_kind IN('IMPORT','MANUAL')),
    source_reference text,
    classification text CHECK(classification IN('ASSET','LIABILITY','EQUITY','COST','PROFIT')),
    currency_id uuid REFERENCES currencies(id),
    row_version bigint NOT NULL DEFAULT 0, mapping_fingerprint text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid NOT NULL REFERENCES users(id),
    CHECK((source_kind='IMPORT' AND source_import_id IS NOT NULL) OR (source_kind='MANUAL' AND source_reference IS NOT NULL))
);
CREATE TABLE finance_chart_manual_operations (
    request_id uuid PRIMARY KEY,actor_id uuid NOT NULL REFERENCES users(id),
    fingerprint text NOT NULL CHECK(fingerprint~'^[0-9a-f]{64}$'),result jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE finance_chart_code_styles (
    code text NOT NULL REFERENCES finance_chart_codes(code),
    style_id uuid PRIMARY KEY REFERENCES payment_styles(id),
    created_at timestamptz NOT NULL DEFAULT now(), created_by uuid NOT NULL REFERENCES users(id)
);
CREATE INDEX idx_finance_chart_code_styles_code ON finance_chart_code_styles(code);
CREATE OR REPLACE FUNCTION fn_finance_chart_classification_allows(p_class text,p_category text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_class IS NULL OR CASE p_class WHEN 'ASSET' THEN p_category='ACCOUNT' WHEN 'COST' THEN p_category='ACCOUNT'
        WHEN 'LIABILITY' THEN p_category='LIABILITY' WHEN 'EQUITY' THEN p_category='EQUITY'
        WHEN 'PROFIT' THEN p_category IN('INCOME','EXPENSE') ELSE false END;
$$;
CREATE OR REPLACE FUNCTION fn_guard_finance_chart_classification()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE compatible boolean;
BEGIN
    IF TG_TABLE_NAME='finance_chart_codes' THEN
        SELECT bool_and(fn_finance_chart_classification_allows(NEW.classification,s.category)) INTO compatible
            FROM finance_chart_code_styles m JOIN payment_styles s ON s.id=m.style_id WHERE m.code=NEW.code;
    ELSIF TG_TABLE_NAME='payment_styles' THEN
        SELECT bool_and(fn_finance_chart_classification_allows(c.classification,NEW.category)) INTO compatible
            FROM finance_chart_code_styles m JOIN finance_chart_codes c ON c.code=m.code WHERE m.style_id=NEW.id;
    ELSE
        SELECT fn_finance_chart_classification_allows(c.classification,s.category) INTO compatible
            FROM finance_chart_codes c CROSS JOIN payment_styles s WHERE c.code=NEW.code AND s.id=NEW.style_id;
    END IF;
    IF compatible=false THEN RAISE EXCEPTION '财务类别与核算科目类别不一致，资产、成本与损益不可混配' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_finance_chart_classification_guard BEFORE UPDATE OF classification ON finance_chart_codes
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_chart_classification();
CREATE TRIGGER trg_finance_chart_style_classification_guard BEFORE INSERT OR UPDATE ON finance_chart_code_styles
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_chart_classification();
CREATE TRIGGER trg_finance_chart_native_classification_guard BEFORE UPDATE OF category ON payment_styles
    FOR EACH ROW WHEN(NEW.category IS DISTINCT FROM OLD.category) EXECUTE FUNCTION fn_guard_finance_chart_classification();
-- Only bindings created by this mapping command may be removed by a later mapping edit.
CREATE TABLE finance_chart_owned_bindings (
    code text NOT NULL REFERENCES finance_chart_codes(code), style_id uuid NOT NULL REFERENCES payment_styles(id),
    line_key text NOT NULL, PRIMARY KEY(code,style_id,line_key)
);
CREATE TRIGGER trg_audit_finance_chart_codes AFTER INSERT OR UPDATE OR DELETE ON finance_chart_codes
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_chart_code_styles AFTER INSERT OR UPDATE OR DELETE ON finance_chart_code_styles
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_chart_codes ENABLE ALWAYS TRIGGER trg_audit_finance_chart_codes;
ALTER TABLE finance_chart_code_styles ENABLE ALWAYS TRIGGER trg_audit_finance_chart_code_styles;

-- The annual-only prior-period row is explicitly configured, never inferred from its caption.
DROP TRIGGER trg_psref_report_binding_expense ON finance_report_line_bindings;
CREATE TRIGGER trg_psref_report_binding_expense BEFORE INSERT OR UPDATE ON finance_report_line_bindings
    FOR EACH ROW WHEN (NEW.line_key NOT LIKE 'BS\_%'
        AND NEW.line_key NOT IN ('PL_1','PL_20','PL_22','PL_23','PL_PRIOR_ADJUSTMENT'))
    EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','EXPENSE','false','true','false','false');
CREATE TRIGGER trg_psref_report_binding_prior_adjustment BEFORE INSERT OR UPDATE ON finance_report_line_bindings
    FOR EACH ROW WHEN (NEW.line_key='PL_PRIOR_ADJUSTMENT')
    EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','EQUITY','false','true','false','false');
