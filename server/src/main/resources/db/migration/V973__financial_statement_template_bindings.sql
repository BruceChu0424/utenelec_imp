-- Explicit statement mappings share the existing binding/locking protocol. No company-specific
-- tax, payroll or red-ink template interpretation is seeded here.
CREATE TABLE finance_report_line_confirmations (
    line_key TEXT PRIMARY KEY CHECK (line_key ~ '^[A-Z][A-Z0-9_]{1,63}$'),
    confirmed_zero BOOLEAN NOT NULL DEFAULT false,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES users(id)
);
CREATE TRIGGER trg_audit_finance_report_line_confirmations AFTER INSERT OR UPDATE OR DELETE ON finance_report_line_confirmations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_report_line_confirmations ENABLE ALWAYS TRIGGER trg_audit_finance_report_line_confirmations;

DROP TRIGGER trg_psref_finance_report_line_binding_style ON finance_report_line_bindings;
CREATE TRIGGER trg_psref_report_binding_account BEFORE INSERT OR UPDATE ON finance_report_line_bindings
    FOR EACH ROW WHEN (NEW.line_key ~ '^BS_([1-9]|[12][0-9]|30)$')
    EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','ACCOUNT','false','true','false','false');
CREATE TRIGGER trg_psref_report_binding_liability BEFORE INSERT OR UPDATE ON finance_report_line_bindings
    FOR EACH ROW WHEN (NEW.line_key ~ '^BS_(3[1-9]|4[0-7])$')
    EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','LIABILITY','false','true','false','false');
CREATE TRIGGER trg_psref_report_binding_equity BEFORE INSERT OR UPDATE ON finance_report_line_bindings
    FOR EACH ROW WHEN (NEW.line_key ~ '^BS_(4[89]|5[0-3])$')
    EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','EQUITY','false','true','false','false');
CREATE TRIGGER trg_psref_report_binding_income BEFORE INSERT OR UPDATE ON finance_report_line_bindings
    FOR EACH ROW WHEN (NEW.line_key IN ('PL_1','PL_20','PL_22','PL_23'))
    EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','INCOME','false','true','false','false');
CREATE TRIGGER trg_psref_report_binding_expense BEFORE INSERT OR UPDATE ON finance_report_line_bindings
    FOR EACH ROW WHEN (NEW.line_key NOT LIKE 'BS\_%' AND NEW.line_key NOT IN ('PL_1','PL_20','PL_22','PL_23'))
    EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','EXPENSE','false','true','false','false');

CREATE OR REPLACE FUNCTION fn_finance_report_line_sheet(p_line_key TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE
        WHEN p_line_key LIKE 'BS\_%' THEN 'BALANCE'
        WHEN p_line_key LIKE 'PL\_%' OR p_line_key = 'SALES_FEE' THEN 'PROFIT'
        WHEN p_line_key LIKE 'MFG\_%' THEN 'MANUFACTURING'
        WHEN p_line_key LIKE 'ADM\_%' THEN 'ADMIN'
        WHEN p_line_key LIKE 'OP\_%' THEN 'OPERATING'
        ELSE p_line_key END;
$$;
