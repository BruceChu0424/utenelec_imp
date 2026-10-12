-- Approved facts and compensating postings keep their original identity. An unapproval creates
-- one editable successor generation, so approval source IDs and reversal keys are never reused.
CREATE TABLE document_unapprovals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    family varchar(48) NOT NULL,
    original_id uuid NOT NULL,
    draft_id uuid NOT NULL,
    draft_bill_no varchar(64) NOT NULL,
    request_key varchar(128) NOT NULL CHECK(char_length(btrim(request_key)) BETWEEN 8 AND 128),
    reason varchar(500) NOT NULL CHECK(char_length(btrim(reason)) BETWEEN 1 AND 500),
    line_id_map jsonb NOT NULL CHECK(jsonb_typeof(line_id_map)='object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid NOT NULL REFERENCES users(id),
    CONSTRAINT document_unapprovals_distinct_generation CHECK(original_id<>draft_id),
    CONSTRAINT document_unapprovals_original_unique UNIQUE(family,original_id),
    CONSTRAINT document_unapprovals_draft_unique UNIQUE(family,draft_id),
    CONSTRAINT document_unapprovals_request_unique UNIQUE(created_by,family,request_key)
);
COMMENT ON TABLE document_unapprovals IS '反审原始审核/反向事实与可编辑草稿的永久关系；新草稿保留业务归属与冻结输入，附件保留在原单可追溯查看';
COMMENT ON COLUMN document_unapprovals.line_id_map IS '原始明细 UUID 到后续草稿明细 UUID；来源申请/销售/供应商等身份及精确份额不变';

CREATE FUNCTION fn_guard_document_unapprovals() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE document_table text; old_status smallint; new_status smallint;
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='document unapproval lineage is append-only';
    END IF;
    document_table:=CASE NEW.family
        WHEN 'salesOrder' THEN 'sales_orders' WHEN 'salesReturn' THEN 'sales_returns'
        WHEN 'salesOtherShipment' THEN 'sales_other_shipments'
        WHEN 'purchaseOrder' THEN 'purchase_orders' WHEN 'purchaseReceipt' THEN 'purchase_receipts'
        WHEN 'purchaseReturn' THEN 'purchase_returns'
        WHEN 'subcontractOrder' THEN 'subcontract_orders' WHEN 'subcontractInquiry' THEN 'subcontract_inquiries'
        WHEN 'subcontractReceipt' THEN 'subcontract_receipts' WHEN 'subcontractReturn' THEN 'subcontract_returns'
        WHEN 'subcontractMaterialIssue' THEN 'subcontract_material_issues'
        WHEN 'subcontractMaterialReturn' THEN 'subcontract_material_returns' WHEN 'subcontractWaste' THEN 'subcontract_wastes'
        WHEN 'financeReceipt' THEN 'finance_receipts' WHEN 'financePayment' THEN 'finance_payments'
        WHEN 'financeExpense' THEN 'finance_expenses' WHEN 'financeOtherIncome' THEN 'finance_other_incomes'
        WHEN 'financeBankTransfer' THEN 'finance_bank_transfers' WHEN 'productionPlan' THEN 'production_plans'
        WHEN 'stockDocument' THEN 'stock_documents' WHEN 'productionDailyReport' THEN 'production_daily_reports' END;
    IF document_table IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='unsupported document unapproval family';
    END IF;
    EXECUTE format('SELECT status FROM %I WHERE id=$1 AND NOT is_deleted',document_table) INTO old_status USING NEW.original_id;
    EXECUTE format('SELECT status FROM %I WHERE id=$1 AND NOT is_deleted',document_table) INTO new_status USING NEW.draft_id;
    IF old_status IS DISTINCT FROM -1 OR new_status IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='unapproval requires reversed original and draft successor';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_document_unapprovals BEFORE INSERT OR UPDATE OR DELETE ON document_unapprovals
    FOR EACH ROW EXECUTE FUNCTION fn_guard_document_unapprovals();
SELECT fn_audit_track_table('document_unapprovals','FULL','data_change',false);

-- Registration only; the migration never clears a database.
DO $unapproval_reset_policy$
DECLARE definition text; anchor text := '(''stock_documents'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V840 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''document_unapprovals'', ''CLEAR'')');
END $unapproval_reset_policy$;
