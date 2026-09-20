CREATE OR REPLACE FUNCTION public.fn_audit_redact_row(p_table_name text, p_row jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
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

    IF p_table_name = 'legacy_finance_import_sources' THEN
        v_row := v_row - 'initial_state';
    ELSIF p_table_name = 'employees' THEN
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
    ELSIF p_table_name = 'employee_data_handovers' THEN
        v_row := v_row - 'reason';
    ELSIF p_table_name = 'employee_offboarding_events' THEN
        v_row := v_row - ARRAY['reason', 'handover_reason'];
    END IF;

    v_row := v_row - ARRAY['request_payload','input_snapshot','output_snapshot','before_balance','original_balance','original_pool','approval_evidence']; RETURN v_row;
END;
$function$;

-- V626: source-bound historical finance snapshots, never reconstructed cash,
-- prepayments, settlements or GL postings. Existing business rows are not changed.
CREATE TABLE public.legacy_finance_import_sources (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id uuid NOT NULL REFERENCES public.legacy_migration_runs(run_id) ON DELETE RESTRICT,
    source_kind text NOT NULL,
    source_legacy_id integer NOT NULL CHECK(source_legacy_id>0),
    target_table text NOT NULL,
    target_id uuid NOT NULL UNIQUE,
    source_file text NOT NULL,
    source_row_sha256 char(64) NOT NULL CHECK(source_row_sha256 ~ '^[0-9a-f]{64}$'),
    source_file_sha256 char(64) NOT NULL CHECK(source_file_sha256 ~ '^[0-9a-f]{64}$'),
    target_fields text[] NOT NULL CHECK(cardinality(target_fields)>0),
    target_snapshot_sha256 char(64) NOT NULL CHECK(target_snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    initial_state jsonb NOT NULL DEFAULT '{}'::jsonb,
    issued_txid bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(run_id,source_kind,source_legacy_id),
    UNIQUE(run_id,target_id)
);
COMMENT ON TABLE public.legacy_finance_import_sources IS
    'PRESERVE: immutable approved bootstrap source hashes, target identity and original monetary state; no source personal text or credentials';

CREATE FUNCTION public.fn_require_legacy_bootstrap(p_run_id uuid,p_source_file text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE
    run public.legacy_migration_runs%ROWTYPE;
    lock_key bigint := hashtextextended('uten:legacy-bootstrap:'||current_database(),0);
    trusted boolean;
BEGIN
    SELECT rolsuper OR (rolname='uten_migrator' AND rolcanlogin) INTO trusted
      FROM pg_catalog.pg_roles WHERE rolname=session_user;
    IF NOT COALESCE(trusted,false) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='legacy source evidence requires the dedicated migration identity';
    END IF;
    IF p_source_file IS NULL OR p_source_file !~ '^[a-z0-9_]+[.]csv$'
       OR p_run_id IS NULL OR current_setting('uten.bootstrap_run_id',true) IS DISTINCT FROM p_run_id::text
       OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_locks WHERE locktype='advisory' AND pid=pg_backend_pid()
          AND granted AND mode='ExclusiveLock' AND objsubid=1
          AND classid=((lock_key>>32)&4294967295)::oid AND objid=(lock_key&4294967295)::oid) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='legacy source evidence requires the active bootstrap lock, run and source file';
    END IF;
    SELECT * INTO run FROM public.legacy_migration_runs WHERE run_id=p_run_id FOR UPDATE;
    IF NOT FOUND OR run.status<>'RUNNING' OR run.target<>'--bootstrap-all' OR run.migration_mode<>'BOOTSTRAP'
       OR run.database_user<>current_user OR run.finished_at IS NOT NULL
       OR run.reconciliation_summary->>'importAtomicity' IS DISTINCT FROM 'single-transaction-v1'
       OR run.reconciliation_summary->>'targetDatabase' IS DISTINCT FROM current_database()
       OR run.reconciliation_summary->>'targetSystemIdentifier' IS DISTINCT FROM
          (SELECT system_identifier::text FROM pg_catalog.pg_control_system())
       OR run.mapping_version IS DISTINCT FROM current_setting('uten.bootstrap_mapping_version',true)
       OR run.migration_repository_commit IS DISTINCT FROM current_setting('uten.bootstrap_repository_commit',true)
       OR run.export_manifest_sha256::text IS DISTINCT FROM current_setting('uten.bootstrap_manifest_sha',true)
       OR COALESCE(run.mapping_version !~ '^bootstrap-v[1-9][0-9]*$',true)
       OR COALESCE(run.migration_repository_commit !~ '^[0-9a-f]{40,64}$',true)
       OR run.export_manifest_sha256 IS NULL OR run.checksum_manifest_sha256 IS NULL
       OR run.migration_script_sha256 IS NULL OR run.source_backup_sha256 IS NULL OR run.export_approval_reference IS NULL
       OR COALESCE(run.reconciliation_summary->>'targetApprovalReference' !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$',true)
       OR NOT EXISTS(SELECT 1 FROM public.legacy_migration_run_files
          WHERE run_id=p_run_id AND file_name=p_source_file AND byte_size>0) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='legacy bootstrap provenance does not match this database, execution role and candidate';
    END IF;
END; $$;

-- Forward reuse only: V624 bytes and its per-row source proof remain immutable.
CREATE OR REPLACE FUNCTION public.fn_require_legacy_subcontract_bootstrap(p_run_id uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    PERFORM public.fn_require_legacy_bootstrap(p_run_id,'subcontract_order_m.csv');
END; $$;

CREATE FUNCTION public.fn_legacy_finance_kind(p_kind text)
RETURNS TABLE(target_table text,source_file text,source_keys text[])
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT table_name,file_name,string_to_array(keys,',') FROM (VALUES
      ('RECEIPT','finance_receipts','m_get.csv','approver_id,approver_name,bill_date,bill_no,cancel,cancel_date,client_legacy_id,crate,cur_id,dfch,invoices_no,legacy_id,make_id,maker_name,mtotal,qtfy,qtfymc,rec_acc,rec_style,remark,slf,source,status,status2,step_id,total,work_id,work_name'),
      ('PAYMENT','finance_payments','m_paid.csv','approver_id,approver_name,bill_date,bill_no,cancel,cancel_date,crate,cur_id,dfzh,invoices_no,jsr,legacy_id,make_id,maker_name,mtotal,paid_acc,paid_style,remark,source,status,status2,step_id,supplier_legacy_id,total,work_id,work_name'),
      ('EXPENSE','finance_expenses','m_dpaid.csv','approver_id,approver_name,bill_date,bill_no,cancel,cancel_date,crate,cur_id,dfzh,invoices_no,legacy_id,make_id,maker_name,mtotal,paid_acc,paid_style,remark,source,status,status2,total,work_id,work_name'),
      ('INCOME','finance_other_incomes','m_oget.csv','approver_id,approver_name,bill_date,bill_no,cancel,cancel_date,crate,cur_id,dfzh,invoices_no,legacy_id,make_id,maker_name,mtotal,rec_acc,rec_style,remark,source,status,status2,total,work_id,work_name'),
      ('ACCOUNT_FLOW','finance_reconciliations','m_allcheck.csv','acc_id,b_style,bill_date,bill_id,bill_no,check_no,company,in_total,legacy_id,out_date,out_total,remark,source'),
      ('EXPENSE_ITEM','finance_expense_items','m_dpaid_item.csv','acc_id,bill_legacy_id,ctotal,dept_legacy_id,dfmc,legacy_id,price,qty,style_legacy_id,summary,total'),
      ('INCOME_ITEM','finance_other_income_items','m_oget_item.csv','bill_legacy_id,ctotal,dept_legacy_id,df,legacy_id,style_legacy_id,summary,total'),
      ('AR_OPENING','ar_ap_ledger','m_in.csv','b_style,balance,bill_date,bill_legacy_id,bill_no,client_legacy_id,currency_legacy_id,due_date,exchange_rate,legacy_id,note,p_style,paid_bit,paid_date,settled,total'),
      ('AP_OPENING','ar_ap_ledger','m_out.csv','b_style,balance,bill_date,bill_legacy_id,bill_no,currency_legacy_id,due_date,exchange_rate,legacy_id,note,p_style,paid_bit,paid_date,settled,supplier_legacy_id,total')
    ) AS mappings(kind,table_name,file_name,keys) WHERE kind=p_kind
$$;

CREATE FUNCTION public.fn_legacy_finance_snapshot(p_row jsonb,p_fields text[]) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT COALESCE(jsonb_object_agg(key,CASE WHEN jsonb_typeof(value)='number'
        THEN to_jsonb(trim_scale((value#>>'{}')::numeric)) ELSE value END),'{}'::jsonb)
    FROM jsonb_each(p_row) WHERE key=ANY(p_fields)
$$;

CREATE FUNCTION public.fn_guard_legacy_finance_evidence() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE mapping record;
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='legacy finance source evidence is immutable';
    END IF;
    SELECT * INTO mapping FROM public.fn_legacy_finance_kind(NEW.source_kind);
    IF NOT FOUND OR NEW.target_table IS DISTINCT FROM mapping.target_table OR NEW.source_file IS DISTINCT FROM mapping.source_file THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='legacy finance source kind is not registered';
    END IF;
    PERFORM public.fn_require_legacy_bootstrap(NEW.run_id,NEW.source_file);
    IF NEW.issued_txid<>txid_current() OR NEW.source_file_sha256 IS DISTINCT FROM
       (SELECT sha256 FROM public.legacy_migration_run_files WHERE run_id=NEW.run_id AND file_name=NEW.source_file) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='legacy finance evidence belongs to another input or transaction';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_legacy_finance_evidence BEFORE INSERT OR UPDATE OR DELETE
    ON public.legacy_finance_import_sources FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_finance_evidence();
ALTER TABLE public.legacy_finance_import_sources ENABLE ALWAYS TRIGGER trg_guard_legacy_finance_evidence;
CREATE TRIGGER trg_audit_legacy_finance_import_sources AFTER INSERT OR UPDATE OR DELETE
    ON public.legacy_finance_import_sources FOR EACH ROW EXECUTE FUNCTION public.fn_audit_redacted();
ALTER TABLE public.legacy_finance_import_sources ENABLE ALWAYS TRIGGER trg_audit_legacy_finance_import_sources;

DO $columns$
DECLARE target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['finance_receipts','finance_payments','finance_expenses','finance_other_incomes',
        'finance_reconciliations','finance_expense_items','finance_other_income_items','ar_ap_ledger'] LOOP
        EXECUTE format('ALTER TABLE public.%I ADD COLUMN legacy_import_run_id uuid',target);
        EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY(legacy_import_run_id,id) '
            'REFERENCES public.legacy_finance_import_sources(run_id,target_id) ON DELETE RESTRICT',target,target||'_legacy_import_fk');
    END LOOP;
END;
$columns$;

CREATE FUNCTION public.fn_assert_legacy_finance_import(p_table text,p_row jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE proof public.legacy_finance_import_sources%ROWTYPE; run uuid;
BEGIN
    run:=(p_row->>'legacy_import_run_id')::uuid;
    SELECT * INTO proof FROM public.legacy_finance_import_sources
      WHERE run_id=run AND target_id=(p_row->>'id')::uuid AND target_table=p_table
        AND source_legacy_id=(p_row->>'legacy_id')::integer;
    IF NOT FOUND OR proof.issued_txid<>txid_current() THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='legacy finance row has no exact source proof in this transaction';
    END IF;
    PERFORM public.fn_require_legacy_bootstrap(run,proof.source_file);
    IF proof.target_snapshot_sha256 IS DISTINCT FROM
       encode(public.digest(public.fn_legacy_finance_snapshot(p_row,proof.target_fields)::text,'sha256'),'hex') THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='legacy finance target does not match its original source projection';
    END IF;
END; $$;

CREATE FUNCTION public.fn_guard_legacy_finance_document() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE previous jsonb; next_row jsonb;
BEGIN
    previous:=CASE WHEN TG_OP='INSERT' THEN NULL ELSE to_jsonb(OLD) END;
    next_row:=CASE WHEN TG_OP='DELETE' THEN NULL ELSE to_jsonb(NEW) END;
    IF TG_OP<>'INSERT' AND (previous->>'legacy_id' IS NOT NULL OR previous->>'legacy_import_run_id' IS NOT NULL) THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='imported finance documents are read-only historical facts';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    IF TG_OP='UPDATE' AND ((next_row->'legacy_id') IS DISTINCT FROM (previous->'legacy_id')
       OR (next_row->'legacy_import_run_id') IS DISTINCT FROM (previous->'legacy_import_run_id')) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='finance legacy provenance cannot be added, rebound or cleared';
    END IF;
    IF next_row->>'legacy_id' IS NOT NULL OR next_row->>'legacy_import_run_id' IS NOT NULL THEN
        PERFORM public.fn_assert_legacy_finance_import(TG_TABLE_NAME,next_row);
    ELSIF next_row->>'receipt_kind'='LEGACY_UNCLASSIFIED' OR next_row->>'entry_kind'='LEGACY_SNAPSHOT' THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='legacy finance classification requires exact bootstrap source evidence';
    END IF;
    IF TG_TABLE_NAME='finance_reconciliations' AND next_row->>'entry_kind'='REVERSAL' AND EXISTS(
        SELECT 1 FROM public.finance_reconciliations source WHERE source.id=(next_row->>'reversal_of_id')::uuid
          AND (source.legacy_id IS NOT NULL OR source.legacy_import_run_id IS NOT NULL)) THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='legacy account history cannot be turned into a new reversal';
    END IF;
    RETURN NEW;
END; $$;

DO $document_guards$
DECLARE target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['finance_receipts','finance_payments','finance_expenses','finance_other_incomes',
        'finance_reconciliations','finance_bank_transfers','finance_expense_items','finance_other_income_items'] LOOP
        EXECUTE format('CREATE TRIGGER trg_zz_legacy_finance_document BEFORE INSERT OR UPDATE OR DELETE ON public.%I '
            'FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_finance_document()',target);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_zz_legacy_finance_document',target);
    END LOOP;
END;
$document_guards$;

CREATE FUNCTION public.fn_guard_legacy_finance_lines() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE parent_table text; parent_column text; row_data jsonb; parent_id uuid; imported boolean;
BEGIN
    SELECT names.table_name,names.column_name INTO parent_table,parent_column FROM (VALUES
        ('finance_receipt_lines','finance_receipts','receipt_id'),('finance_payment_lines','finance_payments','payment_id'),
        ('finance_expense_items','finance_expenses','expense_id'),('finance_other_income_items','finance_other_incomes','income_id'),
        ('finance_bank_transfer_lines','finance_bank_transfers','transfer_id')
    ) names(child_name,table_name,column_name) WHERE child_name=TG_TABLE_NAME;
    FOR row_data IN SELECT data FROM unnest(ARRAY[
        CASE WHEN TG_OP='INSERT' THEN NULL ELSE to_jsonb(OLD) END,
        CASE WHEN TG_OP='DELETE' THEN NULL ELSE to_jsonb(NEW) END]) data WHERE data IS NOT NULL LOOP
        parent_id:=(row_data->>parent_column)::uuid;
        EXECUTE format('SELECT legacy_id IS NOT NULL OR to_jsonb(parent)->>''legacy_import_run_id'' IS NOT NULL FROM public.%I parent WHERE id=$1',parent_table)
            INTO imported USING parent_id;
        IF NOT COALESCE(imported,false) THEN CONTINUE; END IF;
        IF TG_OP='INSERT' AND TG_TABLE_NAME IN('finance_expense_items','finance_other_income_items') THEN
            PERFORM public.fn_assert_legacy_finance_import(TG_TABLE_NAME,row_data);
        ELSE
            RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='legacy finance lines cannot be added or changed without original line evidence';
        END IF;
    END LOOP;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END; $$;
DO $line_guards$
DECLARE target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['finance_receipt_lines','finance_payment_lines','finance_expense_items','finance_other_income_items','finance_bank_transfer_lines'] LOOP
        EXECUTE format('CREATE TRIGGER trg_zy_legacy_finance_lines BEFORE INSERT OR UPDATE OR DELETE ON public.%I '
            'FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_finance_lines()',target);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_zy_legacy_finance_lines',target);
    END LOOP;
END;
$line_guards$;

-- An old V379 classification is not evidence that legacy cash is available as
-- a new advance. Protect both the original and replacement endpoints.
CREATE FUNCTION public.fn_guard_legacy_finance_borrow() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE row_data jsonb; forbidden boolean;
BEGIN
    FOR row_data IN SELECT data FROM unnest(ARRAY[
        CASE WHEN TG_OP='INSERT' THEN NULL ELSE to_jsonb(OLD) END,
        CASE WHEN TG_OP='DELETE' THEN NULL ELSE to_jsonb(NEW) END]) data WHERE data IS NOT NULL LOOP
        IF TG_TABLE_NAME='finance_receipt_source_allocations' THEN
            SELECT EXISTS(SELECT 1 FROM public.finance_receipts receipt WHERE receipt.id=(row_data->>'receipt_id')::uuid
                AND (receipt.legacy_id IS NOT NULL OR receipt.legacy_import_run_id IS NOT NULL)) INTO forbidden;
        ELSE
            SELECT EXISTS(SELECT 1 FROM public.ar_ap_ledger ledger WHERE ledger.id=(row_data->>'source_ledger_id')::uuid
                AND (ledger.legacy_id IS NOT NULL OR ledger.legacy_import_run_id IS NOT NULL
                    OR ledger.legacy_source IN('M_in','M_out') OR EXISTS(SELECT 1 FROM public.finance_receipts receipt
                        WHERE ledger.source_doc_type='DIRECT_RECEIPT' AND receipt.id=ledger.source_doc_id
                          AND (receipt.legacy_id IS NOT NULL OR receipt.legacy_import_run_id IS NOT NULL)))) INTO forbidden;
        END IF;
        IF forbidden THEN RAISE EXCEPTION 'legacy cash is not authority for a new prepayment or allocation' USING ERRCODE='55000'; END IF;
    END LOOP;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_00_legacy_finance_borrow BEFORE INSERT OR UPDATE OR DELETE ON public.finance_receipt_source_allocations
    FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_finance_borrow();
ALTER TABLE public.finance_receipt_source_allocations ENABLE ALWAYS TRIGGER trg_00_legacy_finance_borrow;
CREATE TRIGGER trg_00_legacy_finance_borrow BEFORE INSERT OR UPDATE OR DELETE ON public.customer_open_item_offsets
    FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_finance_borrow();
ALTER TABLE public.customer_open_item_offsets ENABLE ALWAYS TRIGGER trg_00_legacy_finance_borrow;

ALTER TABLE public.finance_receipts DROP CONSTRAINT finance_receipts_kind_chk;
ALTER TABLE public.finance_receipts ADD CONSTRAINT finance_receipts_kind_chk
    CHECK(receipt_kind IN('AR_SETTLEMENT','CUSTOMER_PREPAYMENT','LEGACY_UNCLASSIFIED'));
ALTER TABLE public.finance_receipts ADD CONSTRAINT finance_receipts_legacy_unclassified_shape_chk
    CHECK(receipt_kind<>'LEGACY_UNCLASSIFIED' OR (legacy_import_run_id IS NOT NULL AND legacy_id IS NOT NULL
        AND settlement_authority_version=0 AND sales_order_id IS NULL));
ALTER TABLE public.finance_reconciliations DROP CONSTRAINT finance_reconciliations_entry_kind_chk;
ALTER TABLE public.finance_reconciliations ADD CONSTRAINT finance_reconciliations_entry_kind_chk
    CHECK(entry_kind IN('POSTING','REVERSAL','ADJUSTMENT','LEGACY_SNAPSHOT'));
ALTER TABLE public.finance_reconciliations ADD CONSTRAINT finance_reconciliations_legacy_snapshot_shape_chk
    CHECK(entry_kind<>'LEGACY_SNAPSHOT' OR (legacy_import_run_id IS NOT NULL AND legacy_id IS NOT NULL AND reversal_of_id IS NULL));
DROP INDEX public.uq_finance_reconciliation_active_source_account_kind;
CREATE UNIQUE INDEX uq_finance_reconciliation_active_source_account_kind
    ON public.finance_reconciliations(source_doc_type,source_doc_id,account_id,entry_kind)
    WHERE source_doc_id IS NOT NULL AND account_id IS NOT NULL AND NOT COALESCE(is_deleted,false)
      AND entry_kind<>'LEGACY_SNAPSHOT';

CREATE FUNCTION public.fn_legacy_finance_cash_projection(p_kind text,s jsonb,p_line_no integer) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE payload jsonb; account_id_value uuid; currency_id_value uuid; base_currency boolean;
    parent_id uuid; parent_row jsonb; item_count bigint; previous_legacy integer; parent_table text;
    child_table text; parent_column text; document_type text; document_id uuid;
BEGIN
    IF p_kind IN('RECEIPT','PAYMENT','EXPENSE','INCOME') THEN
        IF p_line_no IS NOT NULL THEN RAISE EXCEPTION 'header source cannot supply a line ordinal' USING ERRCODE='23514'; END IF;
        payload:=jsonb_build_object(
            'legacy_id',(s->>'legacy_id')::integer,'bill_no',s->>'bill_no','bill_date',(s->>'bill_date')::date,
            'currency_id',(SELECT id FROM public.currencies WHERE legacy_id=(s->>'cur_id')::integer),
            'exchange_rate',(s->>'crate')::numeric,'amount_original',(s->>'mtotal')::numeric,'amount_local',(s->>'total')::numeric,
            'status',(s->>'status')::smallint,'remark',NULLIF(s->>'remark',''),
            'maker_legacy_id',NULLIF((s->>'make_id')::integer,0),'approver_legacy_id',NULLIF((s->>'approver_id')::integer,0),
            'operator_legacy_id',NULLIF((s->>'work_id')::integer,0),
            'maker_name',NULLIF(s->>'maker_name',''),'approver_name',NULLIF(s->>'approver_name',''),
            'operator_name',NULLIF(CASE WHEN p_kind='PAYMENT' THEN s->>'jsr' ELSE s->>'work_name' END,''),
            'operator_id',(SELECT id FROM public.employees WHERE legacy_id=NULLIF((s->>'work_id')::integer,0)),
            'account_id',(SELECT id FROM public.accounts WHERE legacy_id=(s->>CASE WHEN p_kind IN('RECEIPT','INCOME') THEN 'rec_acc' ELSE 'paid_acc' END)::integer),
            'counterpart_account_id',(SELECT id FROM public.accounts WHERE legacy_id=NULLIF((s->>CASE WHEN p_kind='RECEIPT' THEN 'dfch' ELSE 'dfzh' END)::integer,0)));
        IF p_kind IN('RECEIPT','PAYMENT') THEN
            payload:=payload||jsonb_build_object('version',0,'invoice_no',NULLIF(s->>'invoices_no',''),
                'cancel_date',(s->>'cancel_date')::timestamptz,'source_remark',NULLIF(s->>'source',''));
        END IF;
        IF p_kind='RECEIPT' THEN
            payload:=payload||jsonb_build_object('receipt_kind','LEGACY_UNCLASSIFIED','settlement_authority_version',0,
                'sales_order_id',NULL,'client_id',(SELECT id FROM public.clients WHERE legacy_id=(s->>'client_legacy_id')::integer),
                'bank_fee',(s->>'slf')::numeric,'other_fee',(s->>'qtfy')::numeric,
                'other_fee_style_id',(SELECT id FROM public.payment_styles WHERE legacy_id=NULLIF((s->>'qtfymc')::integer,0)));
        ELSIF p_kind='PAYMENT' THEN
            payload:=payload||jsonb_build_object('amount_authority_version',0,
                'supplier_id',(SELECT id FROM public.suppliers WHERE legacy_id=(s->>'supplier_legacy_id')::integer));
        END IF;
        IF p_kind IN('RECEIPT','INCOME') THEN
            payload:=payload||jsonb_build_object('receipt_method_legacy_id',NULLIF((s->>'rec_style')::integer,0),
                'receipt_method_id',(SELECT id FROM public.finance_payment_methods WHERE legacy_id=NULLIF((s->>'rec_style')::integer,0)));
        ELSE
            payload:=payload||jsonb_build_object('payment_method_legacy_id',NULLIF((s->>'paid_style')::integer,0),
                'payment_method_id',(SELECT id FROM public.finance_payment_methods WHERE legacy_id=NULLIF((s->>'paid_style')::integer,0)));
        END IF;
        RETURN payload;
    END IF;
    IF p_kind IN('EXPENSE_ITEM','INCOME_ITEM') THEN
        parent_table:=CASE WHEN p_kind='EXPENSE_ITEM' THEN 'finance_expenses' ELSE 'finance_other_incomes' END;
        child_table:=CASE WHEN p_kind='EXPENSE_ITEM' THEN 'finance_expense_items' ELSE 'finance_other_income_items' END;
        parent_column:=CASE WHEN p_kind='EXPENSE_ITEM' THEN 'expense_id' ELSE 'income_id' END;
        EXECUTE format('SELECT to_jsonb(parent) FROM public.%I parent WHERE legacy_id=$1',parent_table)
            INTO parent_row USING (s->>'bill_legacy_id')::integer;
        IF parent_row IS NULL OR parent_row->>'legacy_import_run_id' IS DISTINCT FROM current_setting('uten.bootstrap_run_id',true) THEN
            RAISE EXCEPTION 'legacy finance line has no source header in this bootstrap' USING ERRCODE='23514';
        END IF;
        parent_id:=(parent_row->>'id')::uuid;
        EXECUTE format('SELECT count(*),max(legacy_id) FROM public.%I WHERE %I=$1',child_table,parent_column)
            INTO item_count,previous_legacy USING parent_id;
        IF p_line_no IS NULL OR p_line_no<>item_count+1
           OR (previous_legacy IS NOT NULL AND previous_legacy>=(s->>'legacy_id')::integer) THEN
            RAISE EXCEPTION 'legacy finance line order must be the complete original ascending identity order' USING ERRCODE='23514';
        END IF;
        payload:=jsonb_build_object('legacy_id',(s->>'legacy_id')::integer,parent_column,parent_id,
            'bill_no',parent_row->'bill_no','bill_date',parent_row->'bill_date','department_id',NULL,
            'amount_original',(s->>'ctotal')::numeric,'amount_local',(s->>'total')::numeric,
            'summary',NULLIF(s->>'summary',''),'line_no',p_line_no);
        IF p_kind='EXPENSE_ITEM' THEN
            RETURN payload||jsonb_build_object('expense_style_id',(SELECT id FROM public.payment_styles WHERE legacy_id=NULLIF((s->>'style_legacy_id')::integer,0)),
                'counterpart_account_id',(SELECT id FROM public.accounts WHERE legacy_id=NULLIF((s->>'acc_id')::integer,0)),
                'counterpart_name',NULLIF(s->>'dfmc',''),'qty',(s->>'qty')::numeric,'price',(s->>'price')::numeric);
        END IF;
        RETURN payload||jsonb_build_object('income_style_id',(SELECT id FROM public.payment_styles WHERE legacy_id=NULLIF((s->>'style_legacy_id')::integer,0)),
            'counterpart_name',NULLIF(s->>'df',''),'qty',NULL,'price',NULL);
    END IF;
    IF p_kind='ACCOUNT_FLOW' THEN
        IF p_line_no IS NOT NULL THEN RAISE EXCEPTION 'account flow source cannot supply a line ordinal' USING ERRCODE='23514'; END IF;
        document_type:=CASE (s->>'b_style')::integer WHEN 20 THEN 'RECEIPT' WHEN 21 THEN 'PAYMENT'
            WHEN 22 THEN 'INCOME' WHEN 23 THEN 'EXPENSE' WHEN 27 THEN 'BANK_TRANSFER' END;
        IF document_type IS NULL THEN RAISE EXCEPTION 'legacy account flow has an unsupported original document family' USING ERRCODE='23514'; END IF;
        parent_table:=CASE document_type WHEN 'RECEIPT' THEN 'finance_receipts' WHEN 'PAYMENT' THEN 'finance_payments'
            WHEN 'INCOME' THEN 'finance_other_incomes' WHEN 'EXPENSE' THEN 'finance_expenses' ELSE 'finance_bank_transfers' END;
        EXECUTE format('SELECT id FROM public.%I WHERE legacy_id=$1 AND bill_no=$2',parent_table)
            INTO document_id USING (s->>'bill_id')::integer,s->>'bill_no';
        SELECT account.id,account.currency_id,currency.is_base_currency INTO account_id_value,currency_id_value,base_currency
          FROM public.accounts account LEFT JOIN public.currencies currency ON currency.id=account.currency_id
          WHERE account.legacy_id=(s->>'acc_id')::integer;
        IF account_id_value IS NULL OR currency_id_value IS NULL OR s->>'bill_date' IS NULL THEN
            RAISE EXCEPTION 'legacy account flow requires a proven real account, currency and original date' USING ERRCODE='23514';
        END IF;
        RETURN jsonb_build_object('legacy_id',(s->>'legacy_id')::integer,'bill_no',s->>'bill_no',
            'source_doc_type',document_type,'source_doc_id',document_id,'account_id',account_id_value,
            'check_no',NULLIF(s->>'check_no',''),'counterpart_name',NULLIF(s->>'company',''),
            'in_amount',(s->>'in_total')::numeric,'out_amount',(s->>'out_total')::numeric,
            'bill_date',(s->>'bill_date')::timestamptz,'settled_date',(s->>'out_date')::timestamptz,
            'source_remark',NULLIF(s->>'source',''),'remark',NULLIF(s->>'remark',''),'legacy_bstyle',(s->>'b_style')::integer,
            'entry_kind','LEGACY_SNAPSHOT','account_currency_id',currency_id_value,
            'amount_local',CASE WHEN base_currency THEN (s->>'in_total')::numeric+(s->>'out_total')::numeric ELSE NULL END);
    END IF;
    RAISE EXCEPTION 'unsupported legacy cash source kind' USING ERRCODE='23514';
END; $$;

CREATE FUNCTION public.fn_import_legacy_finance_source(p_run_id uuid,p_kind text,p_source jsonb,p_line_no integer DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE mapping record; keys text[]; payload jsonb; record_id uuid:=gen_random_uuid(); fields text[];
    columns_sql text; initial_state_value jsonb; original_id integer;
BEGIN
    SELECT * INTO mapping FROM public.fn_legacy_finance_kind(p_kind);
    IF NOT FOUND THEN RAISE EXCEPTION 'unsupported legacy finance source kind' USING ERRCODE='23514'; END IF;
    PERFORM public.fn_require_legacy_bootstrap(p_run_id,mapping.source_file);
    IF jsonb_typeof(p_source) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'legacy finance source must be the complete typed original row' USING ERRCODE='23514';
    END IF;
    SELECT array_agg(key ORDER BY key) INTO keys FROM jsonb_object_keys(p_source) key;
    original_id:=(p_source->>'legacy_id')::integer;
    IF keys IS DISTINCT FROM (SELECT array_agg(key ORDER BY key) FROM unnest(mapping.source_keys) key)
       OR original_id IS NULL OR original_id<=0 THEN
        RAISE EXCEPTION 'legacy finance source shape or identity is not authoritative' USING ERRCODE='23514';
    END IF;
    IF p_kind IN('AR_OPENING','AP_OPENING') THEN
        IF p_line_no IS NOT NULL THEN RAISE EXCEPTION 'opening cannot supply a line ordinal' USING ERRCODE='23514'; END IF;
        payload:=public.fn_legacy_finance_opening_projection(p_kind,p_source);
    ELSE
        payload:=public.fn_legacy_finance_cash_projection(p_kind,p_source,p_line_no);
    END IF;
    payload:=payload||jsonb_build_object('id',record_id,'legacy_import_run_id',p_run_id);
    SELECT array_agg(key ORDER BY key),string_agg(format('%I',key),',' ORDER BY key)
      INTO fields,columns_sql FROM jsonb_object_keys(payload) key;
    -- Queryable original amounts are kept separately from mutable remaining
    -- projections. This field is explicitly redacted from generic audit JSON.
    SELECT COALESCE(jsonb_object_agg(key,value),'{}'::jsonb) INTO initial_state_value FROM jsonb_each(payload)
      WHERE key=ANY(ARRAY['amount_original','amount_local','amount_original_local','amount_settled','amount_balance',
          'amount_received_original','amount_received_local','amount_balance_original','currency_id','exchange_rate',
          'account_currency_id','in_amount','out_amount','legacy_source_resolution']);
    initial_state_value:=initial_state_value||jsonb_build_object('sourceSnapshotAsOfUtc',
        (SELECT reconciliation_summary->'sourceSnapshotAsOfUtc' FROM public.legacy_migration_runs WHERE run_id=p_run_id));
    INSERT INTO public.legacy_finance_import_sources(run_id,source_kind,source_legacy_id,target_table,target_id,source_file,
        source_row_sha256,source_file_sha256,target_fields,target_snapshot_sha256,initial_state,issued_txid)
    SELECT p_run_id,p_kind,original_id,mapping.target_table,record_id,mapping.source_file,
        encode(public.digest(p_source::text,'sha256'),'hex'),sha256,fields,
        encode(public.digest(public.fn_legacy_finance_snapshot(payload,fields)::text,'sha256'),'hex'),initial_state_value,txid_current()
    FROM public.legacy_migration_run_files WHERE run_id=p_run_id AND file_name=mapping.source_file;
    EXECUTE format('INSERT INTO public.%I(%s) SELECT %s FROM jsonb_populate_record(NULL::public.%I,$1) source',
        mapping.target_table,columns_sql,columns_sql,mapping.target_table) USING payload;
    RETURN record_id;
END; $$;

REVOKE ALL ON public.legacy_finance_import_sources FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_import_legacy_finance_source(uuid,text,jsonb,integer) FROM PUBLIC;
DO $source_privileges$
BEGIN
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON public.legacy_finance_import_sources FROM uten;
        GRANT SELECT ON public.legacy_finance_import_sources TO uten;
        REVOKE ALL ON FUNCTION public.fn_import_legacy_finance_source(uuid,text,jsonb,integer) FROM uten;
    END IF;
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten_migrator') THEN
        GRANT SELECT,INSERT ON public.legacy_finance_import_sources TO uten_migrator;
        GRANT EXECUTE ON FUNCTION public.fn_import_legacy_finance_source(uuid,text,jsonb,integer) TO uten_migrator;
    END IF;
END;
$source_privileges$;

DO $reset_policy$
DECLARE definition text; anchor text := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V626 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''legacy_finance_import_sources'', ''PRESERVE'')');
END;
$reset_policy$;


-- Source open items are balances already recorded by the old ledger, not new
-- approvals. Unknown source relationships and original-currency amounts remain
-- explicit. Only the common verified bootstrap importer may create this shape.
ALTER TABLE ar_ap_ledger ADD COLUMN legacy_source_resolution jsonb;
ALTER TABLE ar_ap_ledger ALTER COLUMN amount_original DROP NOT NULL;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_original_known_or_imported_chk
    CHECK (amount_original IS NOT NULL OR legacy_import_run_id IS NOT NULL);
ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_source_doc_type_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_source_doc_type_chk CHECK (
    source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN','PURCHASE_RECEIPT','PURCHASE_RETURN',
        'SUBCONTRACT_RECEIPT','SUBCONTRACT_RETURN','DIRECT_RECEIPT','DIRECT_PAYMENT',
        'SUBCONTRACT_WASTE','SUBCONTRACT_LOSS_OFFSET','PURCHASE_IQC_CREDIT','SUBCONTRACT_IQC_CREDIT',
        'LEGACY_OPENING'));
ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_open_item_kind_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_open_item_kind_chk CHECK (
    open_item_kind IN ('PAYABLE','CREDIT','CLAIM_CREDIT','PREPAYMENT','RECEIVABLE',
        'CUSTOMER_PREPAYMENT','LEGACY_UNVERIFIED'));
ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_open_item_direction_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_open_item_direction_chk CHECK (
    (open_item_kind<>'LEGACY_UNVERIFIED' AND (
        (direction='AR' AND open_item_kind IN('RECEIVABLE','CUSTOMER_PREPAYMENT'))
        OR (direction='AP' AND open_item_kind NOT IN('RECEIVABLE','CUSTOMER_PREPAYMENT'))))
    OR (open_item_kind='LEGACY_UNVERIFIED' AND legacy_import_run_id IS NOT NULL AND direction IN('AR','AP')));
ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_offset_sign_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_offset_sign_chk CHECK (
    (open_item_kind IN('PAYABLE','RECEIVABLE') AND amount_offset_original>=0 AND amount_offset_local>=0)
    OR (open_item_kind IN('CREDIT','CLAIM_CREDIT','PREPAYMENT','CUSTOMER_PREPAYMENT')
        AND amount_offset_original<=0 AND amount_offset_local<=0)
    OR (open_item_kind='LEGACY_UNVERIFIED' AND legacy_import_run_id IS NOT NULL
        AND amount_offset_original>=0 AND amount_offset_local>=0));
ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_settled_consistency_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_settled_consistency_chk CHECK (
    (is_settled AND amount_balance=0 AND (amount_balance_original IS NULL OR amount_balance_original=0)
        AND (settled_date IS NOT NULL OR legacy_import_run_id IS NOT NULL))
    OR (NOT is_settled AND (amount_balance<>0 OR COALESCE(amount_balance_original,0)<>0) AND settled_date IS NULL));

CREATE OR REPLACE FUNCTION fn_derive_ar_ap_open_item_metadata()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    NEW.business_type:=CASE
        WHEN NEW.source_doc_type='LEGACY_OPENING' THEN 'DIRECT'
        WHEN NEW.direction='AR' THEN 'SALES'
        WHEN NEW.source_doc_type IN('PURCHASE_RECEIPT','PURCHASE_RETURN','PURCHASE_IQC_CREDIT','PURCHASE_BILLING_CORRECTION') THEN 'PURCHASE'
        WHEN NEW.source_doc_type IN('SUBCONTRACT_RECEIPT','SUBCONTRACT_RETURN','SUBCONTRACT_WASTE',
            'SUBCONTRACT_LOSS_OFFSET','SUBCONTRACT_IQC_CREDIT','SUBCONTRACT_BILLING_CORRECTION') THEN 'SUBCONTRACT'
        ELSE 'DIRECT' END;
    NEW.open_item_kind:=CASE
        WHEN NEW.legacy_import_run_id IS NOT NULL OR NEW.source_doc_type='LEGACY_OPENING' THEN 'LEGACY_UNVERIFIED'
        WHEN NEW.direction='AR' AND NEW.source_doc_type='DIRECT_RECEIPT' THEN 'CUSTOMER_PREPAYMENT'
        WHEN NEW.direction='AR' THEN 'RECEIVABLE'
        WHEN NEW.source_doc_type='DIRECT_PAYMENT' THEN 'PREPAYMENT'
        WHEN NEW.source_doc_type IN('SUBCONTRACT_WASTE','SUBCONTRACT_LOSS_OFFSET') THEN 'CLAIM_CREDIT'
        WHEN COALESCE(NEW.amount_original,0)<0 OR COALESCE(NEW.amount_original_local,0)<0 THEN 'CREDIT'
        ELSE 'PAYABLE' END;
    RETURN NEW;
END; $$;

CREATE FUNCTION fn_legacy_finance_opening_projection(p_source_kind text,p_source jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE
    is_ar boolean := p_source_kind='AR_OPENING';
    keys text[];
    expected_keys text[] := ARRAY['b_style','balance','bill_date','bill_legacy_id','bill_no',
        'currency_legacy_id','due_date','exchange_rate','legacy_id','note','p_style',
        'paid_bit','paid_date','settled','total'];
    source_id integer;
    legacy_bill integer;
    source_style integer;
    party uuid;
    currency uuid;
    original_known boolean;
    local_total numeric;
    local_settled numeric;
    local_balance numeric;
    source_rate numeric;
    source_date date;
    source_number text;
    candidate_count integer;
    candidates jsonb;
    selected_type text;
    selected_id uuid;
    resolution text;
    snapshot_at timestamptz;
BEGIN
    IF p_source_kind NOT IN ('AR_OPENING','AP_OPENING') OR jsonb_typeof(p_source) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy open item has unsupported source shape';
    END IF;
    expected_keys:=expected_keys || CASE WHEN is_ar THEN 'client_legacy_id' ELSE 'supplier_legacy_id' END;
    SELECT array_agg(key ORDER BY key) INTO keys FROM jsonb_object_keys(p_source) key;
    IF keys IS DISTINCT FROM (SELECT array_agg(key ORDER BY key) FROM unnest(expected_keys) key) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy open item must contain the complete typed source row';
    END IF;
    SELECT (reconciliation_summary->>'sourceSnapshotAsOfUtc')::timestamptz INTO snapshot_at
    FROM public.legacy_migration_runs WHERE run_id=current_setting('uten.bootstrap_run_id')::uuid;
    IF snapshot_at IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy opening requires the approved source snapshot cutoff';
    END IF;
    source_id:=(p_source->>'legacy_id')::integer;
    legacy_bill:=(p_source->>'bill_legacy_id')::integer;
    source_style:=(p_source->>'b_style')::integer;
    local_total:=(p_source->>'total')::numeric;
    local_settled:=(p_source->>'settled')::numeric;
    local_balance:=(p_source->>'balance')::numeric;
    source_rate:=(p_source->>'exchange_rate')::numeric;
    source_date:=(p_source->>'bill_date')::date;
    source_number:=p_source->>'bill_no';
    IF source_id IS NULL OR source_id<=0 OR source_date IS NULL OR NULLIF(btrim(source_number),'') IS NULL
       OR local_total IS NULL OR local_settled IS NULL OR local_balance IS NULL
       OR local_total-local_settled<>local_balance OR source_date>(snapshot_at AT TIME ZONE 'Asia/Shanghai')::date THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy open item requires exact identity and amount conservation';
    END IF;
    IF is_ar THEN
        SELECT id INTO party FROM public.clients WHERE legacy_id=(p_source->>'client_legacy_id')::integer;
    ELSE
        SELECT id INTO party FROM public.suppliers WHERE legacy_id=(p_source->>'supplier_legacy_id')::integer;
    END IF;
    IF party IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='legacy open item requires its actual party identity';
    END IF;
    SELECT id, is_base_currency AND source_rate=1 INTO currency,original_known
    FROM public.currencies WHERE legacy_id=(p_source->>'currency_legacy_id')::integer;
    original_known:=COALESCE(original_known,false);
    -- The old namespace reused AP BStyle=1. Inspect every allowed family with
    -- the actual BillID/number/party; a prefix or the first match is insufficient.
    SELECT count(*),COALESCE(jsonb_agg(jsonb_build_object('kind',kind,'id',id) ORDER BY kind,id),'[]'::jsonb)
      INTO candidate_count,candidates
    FROM (
        SELECT 'SALES_SHIPMENT'::text kind,id FROM public.sales_shipments
            WHERE is_ar AND source_style=3 AND legacy_id=legacy_bill AND bill_no=source_number AND client_id=party
        UNION ALL SELECT 'SALES_RETURN',id FROM public.sales_returns
            WHERE is_ar AND source_style=18 AND legacy_id=legacy_bill AND bill_no=source_number AND client_id=party
        UNION ALL SELECT 'DIRECT_RECEIPT',id FROM public.finance_receipts
            WHERE is_ar AND source_style=20 AND legacy_id=legacy_bill AND bill_no=source_number AND client_id=party
        UNION ALL SELECT 'PURCHASE_RECEIPT',id FROM public.purchase_receipts
            WHERE NOT is_ar AND source_style=1 AND legacy_id=legacy_bill AND bill_no=source_number AND supplier_id=party
        UNION ALL SELECT 'PURCHASE_RETURN',id FROM public.purchase_returns
            WHERE NOT is_ar AND source_style=17 AND legacy_id=legacy_bill AND bill_no=source_number AND supplier_id=party
        UNION ALL SELECT 'SUBCONTRACT_RECEIPT',id FROM public.subcontract_receipts
            WHERE NOT is_ar AND source_style IN(1,30) AND legacy_id=legacy_bill AND bill_no=source_number AND supplier_id=party
        UNION ALL SELECT 'DIRECT_PAYMENT',id FROM public.finance_payments
            WHERE NOT is_ar AND source_style=21 AND legacy_id=legacy_bill AND bill_no=source_number AND supplier_id=party
    ) source;
    IF candidate_count=1 THEN
        selected_type:=candidates->0->>'kind'; selected_id:=(candidates->0->>'id')::uuid;
        resolution:='EXACT_SOURCE';
    ELSE
        selected_type:='LEGACY_OPENING'; selected_id:=NULL;
        resolution:=CASE WHEN candidate_count>1 THEN 'AMBIGUOUS_SOURCE'
            WHEN source_style IS NULL OR (is_ar AND source_style NOT IN(3,18,20))
                OR (NOT is_ar AND source_style NOT IN(1,17,30,21)) THEN 'UNVERIFIED_SOURCE_KIND'
            ELSE 'MISSING_OR_CONFLICTING_SOURCE' END;
    END IF;
    RETURN jsonb_build_object(
        'direction',CASE WHEN is_ar THEN 'AR' ELSE 'AP' END,
        'source_doc_type',selected_type,'source_doc_id',selected_id,'source_doc_no',source_number,
        'bill_no',source_number,'bill_date',source_date,'due_date',(p_source->>'due_date')::date,
        'client_id',CASE WHEN is_ar THEN party ELSE NULL END,
        'supplier_id',CASE WHEN is_ar THEN NULL ELSE party END,
        'currency_id',currency,'exchange_rate',source_rate,
        'amount_original',CASE WHEN original_known THEN local_total ELSE NULL END,
        'amount_original_local',local_total,'amount_settled',local_settled,'amount_balance',local_balance,
        'amount_received_local',local_settled,'amount_write_off_local',0,
        'amount_received_original',CASE WHEN original_known THEN local_settled ELSE NULL END,
        'amount_write_off_original',CASE WHEN original_known THEN 0 ELSE NULL END,
        'amount_balance_original',CASE WHEN original_known THEN local_balance ELSE NULL END,
        'amount_offset_original',0,'amount_offset_local',0,
        'is_settled',local_balance=0,'settled_date',CASE WHEN local_balance=0 THEN ((p_source->>'paid_date')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date ELSE NULL END,
        'status',1,'remark',NULLIF(p_source->>'note',''),
        'legacy_source',CASE WHEN is_ar THEN 'M_in' ELSE 'M_out' END,'legacy_id',source_id,
        'legacy_bstyle',source_style,'settlement_style_legacy',NULLIF((p_source->>'p_style')::integer,0),
        'settlement_type_id',(SELECT id FROM public.settlement_methods WHERE legacy_id=NULLIF((p_source->>'p_style')::integer,0)),
        'legacy_source_resolution',jsonb_build_object('status',resolution,'candidates',candidates,
            'snapshotAsOfUtc',snapshot_at,'sourceBillId',legacy_bill,'sourceCurrencyId',(p_source->>'currency_legacy_id')::integer,
            'originalCurrencyProven',original_known));
END; $$;

CREATE FUNCTION fn_guard_legacy_open_item_source() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE mutable_fields text[] := ARRAY['amount_settled','amount_balance','amount_received_local',
    'amount_write_off_local','amount_received_original','amount_write_off_original','amount_balance_original',
    'amount_offset_original','amount_offset_local','is_settled','settled_date','updated_at','updated_by'];
BEGIN
    IF TG_OP='INSERT' THEN
        IF NEW.legacy_import_run_id IS NOT NULL THEN
            PERFORM public.fn_assert_legacy_finance_import('ar_ap_ledger',to_jsonb(NEW));
        ELSIF NEW.source_doc_type='LEGACY_OPENING' OR NEW.legacy_source_resolution IS NOT NULL OR NEW.amount_original IS NULL
            OR NEW.legacy_source IS NOT NULL OR NEW.legacy_id IS NOT NULL THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='historical opening requires verified bootstrap provenance';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.legacy_import_run_id IS NOT NULL OR OLD.legacy_id IS NOT NULL OR OLD.legacy_source IN('M_in','M_out') THEN
        IF TG_OP='DELETE' OR (to_jsonb(NEW)-mutable_fields) IS DISTINCT FROM (to_jsonb(OLD)-mutable_fields) THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='original legacy open-item source facts are immutable';
        END IF;
    ELSIF TG_OP='UPDATE' AND (NEW.legacy_import_run_id IS NOT NULL
        OR NEW.source_doc_type='LEGACY_OPENING' OR NEW.legacy_source_resolution IS NOT NULL
        OR NEW.legacy_id IS DISTINCT FROM OLD.legacy_id OR NEW.legacy_source IS DISTINCT FROM OLD.legacy_source) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='existing ledger cannot be rebound to historical opening evidence';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_legacy_open_item_source
    BEFORE INSERT OR UPDATE OR DELETE ON ar_ap_ledger
    FOR EACH ROW EXECUTE FUNCTION fn_guard_legacy_open_item_source();
ALTER TABLE ar_ap_ledger ENABLE ALWAYS TRIGGER trg_guard_legacy_open_item_source;

CREATE FUNCTION fn_guard_legacy_opening_settlement_date() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE snapshot_at timestamptz; document_date date;
BEGIN
    SELECT (legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz INTO snapshot_at
    FROM public.ar_ap_ledger WHERE id=NEW.applied_ledger_id AND legacy_import_run_id IS NOT NULL;
    IF snapshot_at IS NULL THEN RETURN NEW; END IF;
    IF TG_TABLE_NAME='finance_receipt_lines' THEN
        SELECT bill_date INTO document_date FROM public.finance_receipts WHERE id=NEW.receipt_id;
    ELSE
        SELECT bill_date INTO document_date FROM public.finance_payments WHERE id=NEW.payment_id;
    END IF;
    IF document_date IS NULL OR document_date<=(snapshot_at AT TIME ZONE 'Asia/Shanghai')::date THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='new settlement must be after the verified historical opening cutoff';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_legacy_opening_receipt_date BEFORE INSERT OR UPDATE ON finance_receipt_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_legacy_opening_settlement_date();
CREATE TRIGGER trg_legacy_opening_payment_date BEFORE INSERT OR UPDATE ON finance_payment_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_legacy_opening_settlement_date();
ALTER TABLE finance_receipt_lines ENABLE ALWAYS TRIGGER trg_legacy_opening_receipt_date;
ALTER TABLE finance_payment_lines ENABLE ALWAYS TRIGGER trg_legacy_opening_payment_date;


CREATE OR REPLACE FUNCTION public.fn_guard_account_flow_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_currency UUID;
    v_account_active BOOLEAN;
    v_currency_active BOOLEAN;
    v_base_currency BOOLEAN;
BEGIN
    IF NEW.entry_kind='LEGACY_SNAPSHOT' THEN
        PERFORM public.fn_assert_legacy_finance_import('finance_reconciliations',to_jsonb(NEW));
        IF NEW.account_id IS NULL OR NEW.account_currency_id IS NULL OR NEW.bill_date IS NULL
           OR COALESCE(NEW.is_deleted,FALSE) OR NOT EXISTS(SELECT 1 FROM public.accounts account
                WHERE account.id=NEW.account_id AND account.currency_id=NEW.account_currency_id) THEN
            RAISE EXCEPTION 'legacy account snapshot requires its original real account, currency and date' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.account_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow requires a real account UUID',
            CONSTRAINT='finance_reconciliations_account_identity_guard';
    END IF;
    IF NEW.source_doc_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='new account flow requires an auditable source document UUID',
            CONSTRAINT='finance_reconciliations_source_identity_guard';
    END IF;
    IF NEW.bill_date IS NULL OR COALESCE(NEW.is_deleted,FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='new account flow requires an effective timestamp and cannot start deleted',
            CONSTRAINT='finance_reconciliations_effective_time_guard';
    END IF;
    SELECT account.currency_id,
           account.status='使用' AND COALESCE(account.is_deleted,FALSE)=FALSE,
           currency.status='使用' AND COALESCE(currency.is_deleted,FALSE)=FALSE,
           currency.is_base_currency
      INTO v_currency,v_account_active,v_currency_active,v_base_currency
    FROM accounts account
    JOIN currencies currency ON currency.id=account.currency_id
    WHERE account.id=NEW.account_id
    FOR SHARE OF account,currency;
    IF v_currency IS NULL OR NOT COALESCE(v_account_active,FALSE)
       OR NOT COALESCE(v_currency_active,FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow requires an active account and active currency UUID',
            CONSTRAINT='finance_reconciliations_account_identity_guard';
    END IF;
    IF NEW.account_currency_id IS NULL THEN NEW.account_currency_id:=v_currency; END IF;
    IF NEW.account_currency_id IS DISTINCT FROM v_currency THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow currency snapshot does not match account currency',
            CONSTRAINT='finance_reconciliations_account_identity_guard';
    END IF;
    IF COALESCE(NEW.in_amount,0)<0 OR COALESCE(NEW.out_amount,0)<0
       OR (COALESCE(NEW.in_amount,0)=0)=(COALESCE(NEW.out_amount,0)=0) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow must contain exactly one positive in/out amount',
            CONSTRAINT='finance_reconciliations_signed_amount_guard';
    END IF;
    IF NEW.amount_local IS NULL OR NEW.amount_local<=0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow requires one positive functional-currency snapshot',
            CONSTRAINT='finance_reconciliations_local_amount_guard';
    END IF;
    IF COALESCE(v_base_currency,FALSE)
       AND NEW.amount_local<>COALESCE(NEW.in_amount,0)+COALESCE(NEW.out_amount,0) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='base-currency account flow native and functional amounts must match',
            CONSTRAINT='finance_reconciliations_base_amount_guard';
    END IF;
    NEW.in_amount:=COALESCE(NEW.in_amount,0);
    NEW.out_amount:=COALESCE(NEW.out_amount,0);
    RETURN NEW;
END;
$function$;
-- An imported opening is an as-of balance, not authority to invent old cash or
-- sales-order allocations. Eligibility remains true after the balance reaches zero.
CREATE FUNCTION public.fn_is_verified_legacy_opening_ar(p_ledger uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT EXISTS(
        SELECT 1 FROM public.ar_ap_ledger ledger
        JOIN public.legacy_finance_import_sources proof
          ON proof.run_id=ledger.legacy_import_run_id AND proof.target_id=ledger.id
         AND proof.target_table='ar_ap_ledger' AND proof.source_kind='AR_OPENING'
         AND proof.source_legacy_id=ledger.legacy_id
        JOIN public.legacy_migration_runs run ON run.run_id=proof.run_id AND run.status='SUCCESS'
        WHERE ledger.id=p_ledger AND ledger.direction='AR' AND NOT ledger.is_deleted
          AND ledger.status=1 AND ledger.open_item_kind='LEGACY_UNVERIFIED'
          AND ledger.currency_id IS NOT NULL AND ledger.client_id IS NOT NULL
          AND proof.initial_state->'legacy_source_resolution'->>'originalCurrencyProven'='true'
          AND (proof.initial_state->>'amount_balance_original')::numeric>0
          AND (proof.initial_state->>'amount_received_original')::numeric IS NOT NULL
          AND (proof.initial_state->>'amount_settled')::numeric IS NOT NULL
          AND proof.initial_state->>'currency_id'=ledger.currency_id::text
          AND proof.initial_state->>'sourceSnapshotAsOfUtc' IS NOT NULL
    )
$$;
CREATE OR REPLACE FUNCTION public.fn_assert_receipt_source_conservation(v_line_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path=pg_catalog,public,pg_temp
AS $function$
DECLARE v_cash numeric; v_writeoff numeric; v_book numeric;
        v_alloc_cash numeric; v_alloc_writeoff numeric; v_alloc_book numeric;
        v_ledger UUID; v_client UUID; v_currency UUID; v_line_client UUID; v_line_currency UUID;
        v_ledger_row ar_ap_ledger%ROWTYPE;
BEGIN
    SELECT line.amount_original,line.write_off_amount,line.applied_amount_local,line.applied_ledger_id,
           receipt.client_id,receipt.currency_id,line.client_id,line.currency_id
      INTO v_cash,v_writeoff,v_book,v_ledger,v_client,v_currency,v_line_client,v_line_currency
    FROM finance_receipt_lines line JOIN finance_receipts receipt ON receipt.id=line.receipt_id
    WHERE line.id=v_line_id AND receipt.status=1 AND receipt.receipt_kind='AR_SETTLEMENT';
    IF v_cash IS NULL THEN RETURN; END IF;
    IF public.fn_is_verified_legacy_opening_ar(v_ledger) THEN
        SELECT * INTO v_ledger_row FROM public.ar_ap_ledger WHERE id=v_ledger;
        IF v_client IS DISTINCT FROM v_ledger_row.client_id OR v_currency IS DISTINCT FROM v_ledger_row.currency_id
           OR v_line_client IS DISTINCT FROM v_client OR v_line_currency IS DISTINCT FROM v_currency
           OR EXISTS(SELECT 1 FROM public.finance_receipt_source_allocations WHERE receipt_line_id=v_line_id) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='historical opening settlement must preserve its actual AR identity without invented orders';
        END IF;
        SELECT COALESCE(SUM(line.amount_original),0),COALESCE(SUM(line.write_off_amount),0),COALESCE(SUM(line.applied_amount_local),0)
          INTO v_alloc_cash,v_alloc_writeoff,v_alloc_book
        FROM public.finance_receipt_lines line JOIN public.finance_receipts receipt ON receipt.id=line.receipt_id
        WHERE line.applied_ledger_id=v_ledger AND receipt.status=1 AND NOT receipt.is_deleted AND NOT line.is_deleted
          AND receipt.legacy_id IS NULL AND receipt.legacy_import_run_id IS NULL;
        IF v_alloc_cash+(SELECT (initial_state->>'amount_received_original')::numeric
                  FROM public.legacy_finance_import_sources WHERE target_id=v_ledger)
                    IS DISTINCT FROM v_ledger_row.amount_received_original
           OR v_alloc_writeoff IS DISTINCT FROM v_ledger_row.amount_write_off_original
           OR v_alloc_book+(SELECT (initial_state->>'amount_settled')::numeric
                  FROM public.legacy_finance_import_sources WHERE target_id=v_ledger)
                    IS DISTINCT FROM v_ledger_row.amount_settled THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='new receipts do not conserve the immutable historical opening and actual subsequent settlements',
                CONSTRAINT='finance_receipt_source_allocation_conservation_guard';
        END IF;
        RETURN;
    END IF;
    IF fn_is_direct_customer_shipment_ar(v_ledger) THEN
        SELECT * INTO v_ledger_row FROM ar_ap_ledger WHERE id=v_ledger;
        IF v_client IS DISTINCT FROM v_ledger_row.client_id OR v_currency IS DISTINCT FROM v_ledger_row.currency_id
           OR v_line_client IS DISTINCT FROM v_client OR v_line_currency IS DISTINCT FROM v_currency
           OR EXISTS(SELECT 1 FROM finance_receipt_source_allocations WHERE receipt_line_id=v_line_id) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='direct shipment receipt must retain its actual AR identity without invented orders';
        END IF;
        SELECT COALESCE(SUM(line.amount_original),0),COALESCE(SUM(line.write_off_amount),0),COALESCE(SUM(line.applied_amount_local),0)
          INTO v_alloc_cash,v_alloc_writeoff,v_alloc_book
        FROM finance_receipt_lines line JOIN finance_receipts receipt ON receipt.id=line.receipt_id
        WHERE line.applied_ledger_id=v_ledger AND receipt.status=1 AND NOT receipt.is_deleted AND NOT line.is_deleted;
        IF v_alloc_cash IS DISTINCT FROM v_ledger_row.amount_received_original
           OR v_alloc_writeoff IS DISTINCT FROM v_ledger_row.amount_write_off_original
           OR v_alloc_book IS DISTINCT FROM v_ledger_row.amount_settled THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='direct shipment receipts do not conserve actual AR settlement snapshots',
                CONSTRAINT='finance_receipt_source_allocation_conservation_guard';
        END IF;
        RETURN;
    END IF;
    -- Original V379 order allocation guard remains intact for order and unresolved historical sources.
    SELECT COALESCE(SUM(cash_original),0),COALESCE(SUM(write_off_original),0),COALESCE(SUM(applied_book_local),0)
      INTO v_alloc_cash,v_alloc_writeoff,v_alloc_book
    FROM finance_receipt_source_allocations WHERE receipt_line_id=v_line_id AND status='APPLIED';
    IF v_alloc_cash<>v_cash OR v_alloc_writeoff<>v_writeoff OR v_alloc_book<>v_book THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='finance receipt source allocations do not conserve the approved line snapshots',
            CONSTRAINT='finance_receipt_source_allocation_conservation_guard';
    END IF;
END $function$;


-- Preserve every native AP shape and admit only source-proved unclassified historical balances.
ALTER TABLE public.ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_ap_open_item_shape_chk;
ALTER TABLE public.ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_ap_open_item_shape_chk CHECK (
    (((direction <> 'AP'::text) OR (((open_item_kind = 'PAYABLE'::text) AND (amount_original_local >= (0)::numeric) AND (amount_balance >= (0)::numeric)) OR ((open_item_kind = ANY (ARRAY['CREDIT'::text, 'CLAIM_CREDIT'::text])) AND (amount_original_local <= (0)::numeric) AND (amount_balance <= (0)::numeric)) OR ((open_item_kind = 'PREPAYMENT'::text) AND (source_doc_type = 'DIRECT_PAYMENT'::text) AND (amount_original_local = (0)::numeric) AND (amount_balance <= (0)::numeric)))))
    OR (legacy_import_run_id IS NOT NULL AND open_item_kind='LEGACY_UNVERIFIED'
        AND amount_offset_original>=0 AND amount_offset_local>=0));
ALTER TABLE public.ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_ap_original_open_item_shape_chk;
ALTER TABLE public.ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_ap_original_open_item_shape_chk CHECK (
    (((direction <> 'AP'::text) OR (amount_balance_original IS NULL) OR (((open_item_kind = 'PAYABLE'::text) AND (amount_original >= (0)::numeric) AND (amount_balance_original >= (0)::numeric)) OR ((open_item_kind = ANY (ARRAY['CREDIT'::text, 'CLAIM_CREDIT'::text])) AND (amount_original <= (0)::numeric) AND (amount_balance_original <= (0)::numeric)) OR ((open_item_kind = 'PREPAYMENT'::text) AND (source_doc_type = 'DIRECT_PAYMENT'::text) AND (amount_original = (0)::numeric) AND (amount_balance_original <= (0)::numeric)))))
    OR (legacy_import_run_id IS NOT NULL AND open_item_kind='LEGACY_UNVERIFIED'
        AND amount_offset_original>=0 AND amount_offset_local>=0));

-- Only subsequent native events may change an imported target's offset totals.
CREATE FUNCTION public.fn_is_verified_legacy_opening_target(p_ledger uuid,p_direction text) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT EXISTS(SELECT 1 FROM public.ar_ap_ledger ledger
        JOIN public.legacy_finance_import_sources proof
          ON proof.run_id=ledger.legacy_import_run_id AND proof.target_id=ledger.id
         AND proof.target_table='ar_ap_ledger' AND proof.source_legacy_id=ledger.legacy_id
         AND proof.source_kind=CASE p_direction WHEN 'AR' THEN 'AR_OPENING' WHEN 'AP' THEN 'AP_OPENING' END
        JOIN public.legacy_migration_runs run ON run.run_id=proof.run_id AND run.status='SUCCESS'
        WHERE ledger.id=p_ledger AND ledger.direction=p_direction AND ledger.status=1 AND NOT ledger.is_deleted
          AND ledger.open_item_kind='LEGACY_UNVERIFIED' AND ledger.currency_id IS NOT NULL
          AND proof.initial_state->'legacy_source_resolution'->>'originalCurrencyProven'='true'
          AND (proof.initial_state->>'amount_balance_original')::numeric>0
          AND proof.initial_state->>'currency_id'=ledger.currency_id::text
          AND proof.initial_state->>'sourceSnapshotAsOfUtc' IS NOT NULL)
$$;

CREATE FUNCTION public.fn_guard_legacy_opening_offset_event() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE source_row public.ar_ap_ledger%ROWTYPE; target_row public.ar_ap_ledger%ROWTYPE;
    event_row jsonb; expected_direction text; mutable_fields text[]:=ARRAY['status','row_version','reversed_by',
        'reversed_at','reverse_reason','updated_at','updated_by'];
BEGIN
    IF TG_OP<>'INSERT' AND EXISTS(SELECT 1 FROM public.ar_ap_ledger
        WHERE id=OLD.source_ledger_id AND (legacy_import_run_id IS NOT NULL OR legacy_id IS NOT NULL OR legacy_source IN('M_in','M_out'))) THEN
        RAISE EXCEPTION 'historical balances cannot be rebound into a new offset source' USING ERRCODE='23514';
    END IF;
    event_row:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
    SELECT * INTO source_row FROM public.ar_ap_ledger WHERE id=(event_row->>'source_ledger_id')::uuid;
    SELECT * INTO target_row FROM public.ar_ap_ledger WHERE id=(event_row->>'target_ledger_id')::uuid;
    IF source_row.legacy_import_run_id IS NOT NULL OR source_row.legacy_id IS NOT NULL OR source_row.legacy_source IN('M_in','M_out') THEN
        RAISE EXCEPTION 'historical balances are not a source of a new offset' USING ERRCODE='23514';
    END IF;
    IF target_row.legacy_import_run_id IS NULL THEN
        IF TG_OP='UPDATE' AND EXISTS(SELECT 1 FROM public.ar_ap_ledger
            WHERE id=OLD.target_ledger_id AND legacy_import_run_id IS NOT NULL) THEN
            RAISE EXCEPTION 'a historical offset target cannot be rebound' USING ERRCODE='23514';
        END IF;
        IF TG_OP='DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    expected_direction:=CASE TG_TABLE_NAME WHEN 'customer_open_item_offsets' THEN 'AR' ELSE 'AP' END;
    IF NOT public.fn_is_verified_legacy_opening_target(target_row.id,expected_direction)
       OR (event_row->>'effective_date')::date <=
            ((target_row.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date
       OR source_row.direction IS DISTINCT FROM expected_direction OR source_row.status IS DISTINCT FROM 1
       OR source_row.is_deleted OR source_row.currency_id IS DISTINCT FROM target_row.currency_id
       OR source_row.exchange_rate IS DISTINCT FROM (event_row->>'source_rate')::numeric
       OR target_row.exchange_rate IS DISTINCT FROM (event_row->>'target_rate')::numeric THEN
        RAISE EXCEPTION 'historical offset target requires exact current identities and a post-cutoff event' USING ERRCODE='23514';
    END IF;
    IF TG_TABLE_NAME='supplier_open_item_offsets' AND (
          source_row.open_item_kind NOT IN('CREDIT','CLAIM_CREDIT')
          OR source_row.supplier_id IS DISTINCT FROM target_row.supplier_id
          OR target_row.supplier_id IS DISTINCT FROM (event_row->>'supplier_id')::uuid
          OR target_row.currency_id IS DISTINCT FROM (event_row->>'currency_id')::uuid) THEN
        RAISE EXCEPTION 'historical AP target requires an actual same-party native credit' USING ERRCODE='23514';
    END IF;
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'historical target offset events are immutable; reverse the event' USING ERRCODE='55000'; END IF;
    IF TG_OP='UPDATE' AND ((to_jsonb(NEW)-mutable_fields) IS DISTINCT FROM (to_jsonb(OLD)-mutable_fields)
       OR OLD.status<>'APPLIED' OR NEW.status<>'REVERSED' OR NEW.row_version<>OLD.row_version+1
       OR NEW.reversed_at IS NULL OR NEW.reversed_by IS NULL) THEN
        RAISE EXCEPTION 'historical target offset accepts only an exact single reversal transition' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_00_legacy_opening_offset_event BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_open_item_offsets
    FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_opening_offset_event();
CREATE TRIGGER trg_00_legacy_opening_offset_event BEFORE INSERT OR UPDATE OR DELETE ON public.customer_open_item_offsets
    FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_opening_offset_event();
ALTER TABLE public.supplier_open_item_offsets ENABLE ALWAYS TRIGGER trg_00_legacy_opening_offset_event;
ALTER TABLE public.customer_open_item_offsets ENABLE ALWAYS TRIGGER trg_00_legacy_opening_offset_event;

CREATE FUNCTION public.fn_assert_legacy_opening_offset_totals(p_ledger uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE ledger public.ar_ap_ledger%ROWTYPE; actual_original numeric; actual_local numeric;
BEGIN
    SELECT * INTO ledger FROM public.ar_ap_ledger WHERE id=p_ledger;
    IF NOT FOUND OR ledger.legacy_import_run_id IS NULL THEN RETURN; END IF;
    IF ledger.direction='AR' THEN
        SELECT COALESCE(sum(amount_original),0),COALESCE(sum(target_amount_local),0)
          INTO actual_original,actual_local FROM public.customer_open_item_offsets WHERE target_ledger_id=p_ledger AND status='APPLIED';
    ELSE
        SELECT COALESCE(sum(amount_original),0),COALESCE(sum(target_amount_local),0)
          INTO actual_original,actual_local FROM public.supplier_open_item_offsets WHERE target_ledger_id=p_ledger AND status='APPLIED';
    END IF;
    IF ledger.amount_offset_original IS DISTINCT FROM actual_original OR ledger.amount_offset_local IS DISTINCT FROM actual_local THEN
        RAISE EXCEPTION 'historical opening offset totals must equal its actual native target events' USING ERRCODE='23514';
    END IF;
END; $$;
CREATE FUNCTION public.fn_guard_legacy_opening_offset_totals() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF TG_TABLE_NAME='ar_ap_ledger' THEN
        PERFORM public.fn_assert_legacy_opening_offset_totals(COALESCE(NEW.id,OLD.id));
    ELSE
        IF TG_OP<>'INSERT' THEN PERFORM public.fn_assert_legacy_opening_offset_totals(OLD.target_ledger_id); END IF;
        IF TG_OP<>'DELETE' THEN PERFORM public.fn_assert_legacy_opening_offset_totals(NEW.target_ledger_id); END IF;
    END IF;
    RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER trg_legacy_opening_offset_totals AFTER INSERT OR UPDATE ON public.ar_ap_ledger
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_opening_offset_totals();
CREATE CONSTRAINT TRIGGER trg_legacy_opening_offset_totals AFTER INSERT OR UPDATE OR DELETE ON public.supplier_open_item_offsets
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_opening_offset_totals();
CREATE CONSTRAINT TRIGGER trg_legacy_opening_offset_totals AFTER INSERT OR UPDATE OR DELETE ON public.customer_open_item_offsets
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_opening_offset_totals();
ALTER TABLE public.ar_ap_ledger ENABLE ALWAYS TRIGGER trg_legacy_opening_offset_totals;
ALTER TABLE public.supplier_open_item_offsets ENABLE ALWAYS TRIGGER trg_legacy_opening_offset_totals;
ALTER TABLE public.customer_open_item_offsets ENABLE ALWAYS TRIGGER trg_legacy_opening_offset_totals;
CREATE OR REPLACE FUNCTION public.fn_guard_customer_open_item_offset()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path=pg_catalog,public,pg_temp
AS $function$
DECLARE
    v_batch_client UUID; v_batch_currency UUID; v_batch_date DATE; v_batch_status TEXT;
    v_source_client UUID; v_source_currency UUID; v_source_kind TEXT; v_source_type TEXT;
    v_source_status SMALLINT; v_source_deleted BOOLEAN; v_source_direction TEXT; v_source_rate NUMERIC(18,6);
    v_target_client UUID; v_target_currency UUID; v_target_kind TEXT;
    v_target_status SMALLINT; v_target_deleted BOOLEAN; v_target_direction TEXT; v_target_rate NUMERIC(18,6);
    v_ref_ledger UUID; v_ref_type TEXT; v_ref_order UUID;
    v_bound_order UUID; v_receipt_kind TEXT; v_receipt_status SMALLINT; v_receipt_deleted BOOLEAN;
    v_order_client UUID; v_order_currency UUID;
    v_ref_before_original numeric; v_ref_before_local numeric;
BEGIN
    SELECT client_id,currency_id,effective_date,status
      INTO v_batch_client,v_batch_currency,v_batch_date,v_batch_status
    FROM customer_open_item_offset_batches WHERE id=NEW.offset_batch_id;
    SELECT client_id,currency_id,open_item_kind,source_doc_type,status,is_deleted,direction,exchange_rate
      INTO v_source_client,v_source_currency,v_source_kind,v_source_type,
           v_source_status,v_source_deleted,v_source_direction,v_source_rate
    FROM ar_ap_ledger WHERE id=NEW.source_ledger_id;
    SELECT client_id,currency_id,open_item_kind,status,is_deleted,direction,exchange_rate
      INTO v_target_client,v_target_currency,v_target_kind,
           v_target_status,v_target_deleted,v_target_direction,v_target_rate
    FROM ar_ap_ledger WHERE id=NEW.target_ledger_id;
    SELECT ledger_id,source_type,source_id
      INTO v_ref_ledger,v_ref_type,v_ref_order
    FROM ar_ap_source_refs WHERE id=NEW.target_source_ref_id;
    SELECT receipt.sales_order_id,receipt.receipt_kind,receipt.status,receipt.is_deleted
      INTO v_bound_order,v_receipt_kind,v_receipt_status,v_receipt_deleted
    FROM ar_ap_ledger ledger JOIN finance_receipts receipt ON receipt.id=ledger.source_doc_id
    WHERE ledger.id=NEW.source_ledger_id AND ledger.source_doc_type='DIRECT_RECEIPT';
    SELECT client_id,currency_id INTO v_order_client,v_order_currency
    FROM sales_orders WHERE id=NEW.sales_order_id;
    IF v_batch_client IS NULL OR v_batch_currency IS NULL OR v_batch_status<>'APPLIED'
       OR NEW.client_id<>v_batch_client OR NEW.currency_id<>v_batch_currency
       OR NEW.effective_date<>v_batch_date
       OR v_source_client<>NEW.client_id OR v_target_client<>NEW.client_id
       OR v_source_currency<>NEW.currency_id OR v_target_currency<>NEW.currency_id
       OR v_source_kind<>'CUSTOMER_PREPAYMENT' OR v_source_type<>'DIRECT_RECEIPT'
       OR v_source_status<>1 OR COALESCE(v_source_deleted,FALSE) OR v_source_direction<>'AR'
       OR v_source_rate IS DISTINCT FROM NEW.source_rate
       OR v_receipt_kind<>'CUSTOMER_PREPAYMENT' OR v_receipt_status<>1
       OR COALESCE(v_receipt_deleted,FALSE)
       OR (v_target_kind<>'RECEIVABLE' AND NOT public.fn_is_verified_legacy_opening_target(NEW.target_ledger_id,'AR')) OR v_target_status<>1
       OR COALESCE(v_target_deleted,FALSE) OR v_target_direction<>'AR'
       OR v_target_rate IS DISTINCT FROM NEW.target_rate
       OR v_ref_ledger<>NEW.target_ledger_id OR v_ref_type<>'SALES_ORDER'
       OR v_ref_order<>NEW.sales_order_id
       OR v_order_client<>NEW.client_id OR v_order_currency IS DISTINCT FROM NEW.currency_id
       OR (v_bound_order IS NOT NULL AND v_bound_order<>NEW.sales_order_id) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='customer prepayment offset crosses active client, currency, order, rate, or AR identities',
            CONSTRAINT='customer_open_item_offsets_identity_guard';
    END IF;
    IF TG_OP='INSERT' THEN
        SELECT ref.amount_original
                   -COALESCE((SELECT SUM(a.cash_original+a.write_off_original)
                              FROM finance_receipt_source_allocations a
                              WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)
                   -COALESCE((SELECT SUM(o.amount_original)
                              FROM customer_open_item_offsets o
                              WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0),
               ref.amount_local
                   -COALESCE((SELECT SUM(a.applied_book_local)
                              FROM finance_receipt_source_allocations a
                              WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)
                   -COALESCE((SELECT SUM(o.target_amount_local)
                              FROM customer_open_item_offsets o
                              WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0)
          INTO v_ref_before_original,v_ref_before_local
        FROM ar_ap_source_refs ref WHERE ref.id=NEW.target_source_ref_id;
        IF NEW.target_ref_balance_before_original IS DISTINCT FROM v_ref_before_original
           OR NEW.target_ref_balance_before_local IS DISTINCT FROM v_ref_before_local THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='customer prepayment target source-ref before balances do not match current authoritative capacity',
                CONSTRAINT='customer_open_item_offsets_source_ref_snapshot_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;


-- A new actual-bank payment may settle a proved historical positive opening.
-- Subsequent payments reconcile exactly after deducting immutable initial balances.
CREATE OR REPLACE FUNCTION public.fn_assert_payment_v2_terminal(p_payment uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path=pg_catalog,public,pg_temp
AS $function$
DECLARE p finance_payments%ROWTYPE;l RECORD;t RECORD;original RECORD;reversal RECORD;posting RECORD;backflow RECORD;a NUMERIC;b NUMERIC;different BOOLEAN;
BEGIN
  SELECT * INTO p FROM finance_payments WHERE id=p_payment;
  IF NOT FOUND OR p.amount_authority_version<>2 OR p.is_deleted THEN RETURN;END IF;
  SELECT count(*) n,COALESCE(sum(amount_original),0) a,COALESCE(sum(amount_local),0) b,COALESCE(sum(exchange_diff),0) fx
    INTO t FROM finance_payment_lines WHERE payment_id=p.id AND NOT is_deleted;
  IF (t.n=0 AND p.status<>0) OR (t.n>0 AND (t.a<>p.amount_original OR t.b<>p.amount_local
    OR (t.fx=0)<>(p.gl_fx_style_id IS NULL))) THEN RAISE EXCEPTION 'payment cash, source book and FX totals do not reconcile' USING ERRCODE='23514';END IF;
  a:=p.amount_original;b:=p.amount_local;
  FOR l IN SELECT * FROM finance_payment_lines WHERE payment_id=p.id AND NOT is_deleted ORDER BY line_no,id LOOP
    IF l.supplier_id IS DISTINCT FROM p.supplier_id OR NOT EXISTS(SELECT 1 FROM ar_ap_ledger ledger
      WHERE ledger.id=l.applied_ledger_id AND ledger.direction='AP' AND ledger.status=1 AND NOT ledger.is_deleted
        AND (ledger.open_item_kind='PAYABLE' OR public.fn_is_verified_legacy_opening_target(ledger.id,'AP')) AND ledger.supplier_id=p.supplier_id AND ledger.currency_id=p.currency_id
        AND ledger.exchange_rate IS NOT DISTINCT FROM l.recognition_rate) THEN
      RAISE EXCEPTION 'payment allocation crosses its payable supplier, currency or recognition snapshot' USING ERRCODE='23514';END IF;
    IF (l.bank_basis_before_original,l.bank_basis_before_local,l.bank_basis_after_original,l.bank_basis_after_local)
      IS DISTINCT FROM(a,b,a-l.amount_original,b-l.amount_local)
      OR l.amount_local<>fn_financial_book_part(l.amount_original,a,b)
      OR l.exchange_diff IS DISTINCT FROM l.amount_local-l.applied_amount_local OR l.cash_rate<>p.exchange_rate
      OR (p.status IN(1,-1) AND (l.book_balance_before_local IS NULL OR l.book_balance_after_local IS NULL
        OR l.balance_before_original IS NULL OR l.balance_after_original<>l.balance_before_original-l.amount_original
        OR l.book_balance_after_local<>l.book_balance_before_local-l.applied_amount_local
        OR l.applied_amount_local<>fn_financial_book_part(l.amount_original,l.balance_before_original,l.book_balance_before_local))) THEN
      RAISE EXCEPTION 'payment must conserve actual bank and payable book allocation basis' USING ERRCODE='23514';END IF;
    a:=l.bank_basis_after_original;b:=l.bank_basis_after_local;
    IF p.status IN(1,-1) AND EXISTS(SELECT 1 FROM ar_ap_ledger ledger
      CROSS JOIN LATERAL(SELECT COALESCE(sum(line.amount_original),0) original,
        COALESCE(sum(line.amount_local),0) cash,COALESCE(sum(line.applied_amount_local),0) book
        FROM finance_payment_lines line JOIN finance_payments payment ON payment.id=line.payment_id
        WHERE line.applied_ledger_id=ledger.id AND NOT line.is_deleted AND payment.status=1 AND NOT payment.is_deleted) used
      WHERE ledger.id=l.applied_ledger_id AND (ledger.amount_received_original IS NULL
        OR CASE WHEN ledger.legacy_import_run_id IS NULL THEN
          ledger.amount_received_original<used.original OR ledger.amount_received_local<used.cash OR ledger.amount_settled<used.book
        ELSE
          ledger.amount_received_original-(SELECT (proof.initial_state->>'amount_received_original')::numeric
            FROM public.legacy_finance_import_sources proof WHERE proof.target_id=ledger.id) IS DISTINCT FROM used.original
          OR ledger.amount_received_local-(SELECT (proof.initial_state->>'amount_received_local')::numeric
            FROM public.legacy_finance_import_sources proof WHERE proof.target_id=ledger.id) IS DISTINCT FROM used.cash
          OR ledger.amount_settled-(SELECT (proof.initial_state->>'amount_settled')::numeric
            FROM public.legacy_finance_import_sources proof WHERE proof.target_id=ledger.id) IS DISTINCT FROM used.book
        END)) THEN
      RAISE EXCEPTION 'payable cash and book totals do not contain their active payment facts' USING ERRCODE='23514';END IF;
  END LOOP;
  IF t.n>0 AND (a<>0 OR b<>0) THEN RAISE EXCEPTION 'payment allocation discards a bank remainder' USING ERRCODE='23514';END IF;
  IF p.status=0 THEN RETURN;END IF;
  IF (SELECT count(*) FROM gl_vouchers WHERE source='AUTO' AND source_type='PAYMENT' AND source_doc_id=p.id AND status=1 AND NOT is_deleted)<>1
    OR (SELECT count(*) FROM finance_reconciliations WHERE source_doc_type='PAYMENT' AND source_doc_id=p.id AND entry_kind='POSTING' AND NOT is_deleted)<>1 THEN
    RAISE EXCEPTION 'terminal actual-bank payment requires one immutable GL and bank posting' USING ERRCODE='23514';END IF;
  SELECT * INTO original FROM gl_vouchers WHERE source='AUTO' AND source_type='PAYMENT' AND source_doc_id=p.id AND status=1 AND NOT is_deleted;
  SELECT * INTO posting FROM finance_reconciliations WHERE source_doc_type='PAYMENT' AND source_doc_id=p.id AND entry_kind='POSTING' AND NOT is_deleted;
  IF (posting.account_id,posting.account_currency_id,posting.in_amount,posting.out_amount,posting.amount_local,posting.bill_date)
    IS DISTINCT FROM(p.account_id,p.account_currency_id,0::numeric,p.account_amount,p.account_amount_local,p.bank_booked_at) THEN
    RAISE EXCEPTION 'payment bank posting differs from its actual debit snapshot' USING ERRCODE='23514';END IF;
  SELECT EXISTS((SELECT line_no,style_id,direction,amount FROM v_payment_v2_expected_gl_entries WHERE payment_id=p.id
      EXCEPT ALL SELECT line_no,style_id,direction,amount FROM gl_entries WHERE voucher_id=original.id)
    UNION ALL (SELECT line_no,style_id,direction,amount FROM gl_entries WHERE voucher_id=original.id
      EXCEPT ALL SELECT line_no,style_id,direction,amount FROM v_payment_v2_expected_gl_entries WHERE payment_id=p.id)) INTO different;
  IF different THEN RAISE EXCEPTION 'payment GL snapshot mismatch' USING ERRCODE='23514';END IF;
  IF p.status=1 THEN
    IF original.reversed_by_voucher_id IS NOT NULL OR EXISTS(SELECT 1 FROM finance_reconciliations WHERE source_doc_type='PAYMENT'
      AND source_doc_id=p.id AND entry_kind='REVERSAL' AND NOT is_deleted) THEN
      RAISE EXCEPTION 'approved payment cannot already be reversed' USING ERRCODE='23514';END IF;
  ELSE
    SELECT * INTO reversal FROM gl_vouchers WHERE id=original.reversed_by_voucher_id AND source_type='PAYMENT_REV'
      AND reversal_of_voucher_id=original.id AND source_doc_id=p.id AND status=1 AND NOT is_deleted;
    SELECT * INTO backflow FROM finance_reconciliations WHERE source_doc_type='PAYMENT' AND source_doc_id=p.id
      AND entry_kind='REVERSAL' AND reversal_of_id=posting.id AND NOT is_deleted;
    IF reversal.id IS NULL OR backflow.id IS NULL OR reversal.voucher_date<>(p.reversed_at AT TIME ZONE 'Asia/Shanghai')::date
      OR backflow.bill_date<>p.reversed_at OR (backflow.in_amount,backflow.out_amount,backflow.amount_local)
        IS DISTINCT FROM(posting.out_amount,posting.in_amount,posting.amount_local) THEN
      RAISE EXCEPTION 'payment reversal must retain original bank amounts and GL lineage' USING ERRCODE='23514';END IF;
  END IF;
END $function$;
