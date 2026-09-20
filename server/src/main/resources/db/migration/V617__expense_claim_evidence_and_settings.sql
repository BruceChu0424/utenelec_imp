-- Forward-only correction: arithmetic agreement is not tax verification.
ALTER TABLE expense_claim_invoices ADD COLUMN buyer_tax_no TEXT,
    ADD COLUMN verification_remark TEXT, ADD COLUMN verified_at TIMESTAMPTZ,
    ADD COLUMN verified_by UUID REFERENCES employees(id), ADD COLUMN verified_by_name TEXT;
UPDATE expense_claim_invoices SET check_state='AMOUNTS_MATCH' WHERE check_state='VERIFIED_MANUAL';
ALTER TABLE expense_claim_invoices DROP CONSTRAINT expense_claim_invoices_no_chk,
    DROP CONSTRAINT expense_claim_invoices_code_chk,
    DROP CONSTRAINT expense_claim_invoices_code_shape_chk;
ALTER TABLE expense_claim_invoices ADD CONSTRAINT expense_claim_invoices_identity_chk CHECK (
    (invoice_type='OTHER' AND invoice_no ~ '^[A-Za-z0-9/-]{1,60}$'
        AND seller_name IS NOT NULL AND btrim(seller_name)<>''
        AND (invoice_code IS NULL OR invoice_code ~ '^[A-Za-z0-9/-]{1,20}$'))
    OR (invoice_type<>'OTHER' AND (
        (invoice_no ~ '^[0-9]{20}$' AND invoice_code IS NULL)
        OR (invoice_no ~ '^[0-9]{8}$' AND invoice_code ~ '^([0-9]{10}|[0-9]{12})$')))) NOT VALID,
    ADD CONSTRAINT expense_claim_invoices_verification_chk CHECK (
        check_state IN ('UNCHECKED','AMOUNTS_MATCH','MISMATCH','VERIFIED_MANUAL')
        AND (check_state<>'VERIFIED_MANUAL' OR (
            verified_by IS NOT NULL AND verified_at IS NOT NULL
            AND verification_remark IS NOT NULL AND btrim(verification_remark)<>''))),
    ADD CONSTRAINT expense_claim_invoices_buyer_tax_no_chk CHECK (
        buyer_tax_no IS NULL OR char_length(buyer_tax_no)<=20);

DROP INDEX expense_claim_invoices_dedup_uq;
CREATE UNIQUE INDEX expense_claim_invoices_dedup_uq ON expense_claim_invoices (
    (CASE WHEN invoice_type='OTHER' AND NOT ((invoice_no ~ '^[0-9]{20}$' AND invoice_code IS NULL) OR (invoice_no ~ '^[0-9]{8}$' AND coalesce(invoice_code,'') ~ '^([0-9]{10}|[0-9]{12})$')) THEN upper(btrim(seller_name)) ELSE '' END),
    coalesce(invoice_code,''),invoice_no);

CREATE TABLE expense_claim_settings (
    id INTEGER PRIMARY KEY CHECK(id=1), company_name TEXT NOT NULL DEFAULT '',
    company_tax_no TEXT, submission_guide TEXT,
    require_invoice BOOLEAN NOT NULL DEFAULT false,
    version BIGINT NOT NULL DEFAULT 0 CHECK(version>=0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,updated_by UUID,
    CONSTRAINT expense_claim_settings_text_chk CHECK (
        char_length(company_name)<=200 AND (company_tax_no IS NULL OR char_length(company_tax_no)<=20)
        AND (submission_guide IS NULL OR char_length(submission_guide)<=2000))
);
INSERT INTO expense_claim_settings(id,submission_guide) VALUES(1,
    '填写真实业务用途及费用日期，上传电子凭证原件和必要业务证明。未登记发票时在备注说明凭证类型及报销依据。识别结果须人工核对；财务审批前记录查验渠道和结果。');
CREATE TRIGGER trg_audit_expense_claim_settings AFTER INSERT OR UPDATE OR DELETE
ON expense_claim_settings FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE expense_claim_settings ENABLE ALWAYS TRIGGER trg_audit_expense_claim_settings;

INSERT INTO permissions(code,name,module,category,sort_order,action_type,description)
VALUES('expense:settings','报销业务设置','人事行政','报销',225,'CONFIGURE','维护公司报销抬头、凭证要求及提交说明')
ON CONFLICT(code) DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
WHERE s.surface_key='hr.expense' AND p.code='expense:settings' ON CONFLICT DO NOTHING;
-- Business settings require explicit assignment; do not give every finance employee administrative access.

DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V617 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor || E',\n            (''expense_claim_settings'', ''PRESERVE'')');
END;
$reset_policy$;
