-- Imported business facts are retained evidence, never a second executable lifecycle.
-- This migration changes no business status, quantity, amount, source proof or balance.
-- Session identity (not SECURITY DEFINER's current_user or a caller-set GUC) owns
-- the maintenance exception. Master data and present inventory are not archive roots.
CREATE FUNCTION public.fn_imported_business_document_roots() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path=pg_catalog AS $$
 SELECT ARRAY[
  'sales_quotes','sales_orders','sales_shipments','sales_returns','sales_other_shipments',
  'purchase_requests','purchase_orders','purchase_receipts','purchase_returns',
  'production_plans','production_daily_reports','stock_documents',
  'subcontract_inquiries','subcontract_applications','subcontract_orders',
  'subcontract_material_issues','subcontract_material_returns','subcontract_receipts',
  'subcontract_returns','subcontract_wastes','finance_receipts','finance_payments',
  'finance_expenses','finance_other_incomes','finance_bank_transfers','expense_claims',
  'ar_ap_ledger','finance_reconciliations','stock_movements']::text[]
$$;

CREATE FUNCTION public.fn_imported_business_document_maintenance_allowed() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT session_user <> 'uten' AND EXISTS (
  SELECT 1 FROM pg_roles actor JOIN pg_database database ON database.datname=current_database()
  WHERE actor.rolname=session_user AND
   (actor.rolsuper OR actor.oid=database.datdba OR (actor.rolname='uten_migrator' AND actor.rolcanlogin)))
$$;

-- A catalog-derived ownership/source closure makes child, batch and source-counter
-- mutations obey the same rule. Exclusions are current masters/projections or
-- immutable evidence stores, not imported business documents.
CREATE VIEW public.v_imported_business_document_guard_tables AS
WITH RECURSIVE roots AS (
 SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind IN('r','p')
  AND (c.relname=ANY(public.fn_imported_business_document_roots()) OR c.relname IN (
   'procurement_arrival_exceptions','procurement_inspection_items',
   'procurement_iqc_consideration_review_approvals','procurement_iqc_rejection_cases',
   'procurement_iqc_stock_in_batches','procurement_order_approval_cases',
   'procurement_order_qty_change_logs','procurement_order_source_revisions',
   'procurement_order_termination_sources','procurement_receipt_consideration_parts'))
), relations(oid) AS (
 SELECT oid FROM roots
 UNION
 SELECT constraint_row.conrelid FROM relations parent
 JOIN pg_constraint constraint_row ON constraint_row.confrelid=parent.oid AND constraint_row.contype='f'
 JOIN pg_class child ON child.oid=constraint_row.conrelid
 JOIN pg_namespace ns ON ns.oid=child.relnamespace
 WHERE ns.nspname='public' AND child.relkind IN('r','p')
  AND child.relname !~ '^(legacy_|audit_|stock_value_)'
  AND child.relname NOT IN('goods','goods_bom_items','employees','users','departments',
   'warehouses','units','colors','currencies','clients','suppliers','moulds','accounts',
   'stock_balances','business_record_history','business_record_identities',
   'business_record_deletions','business_column_definitions','platform_column_definitions',
   'platform_column_usage','flyway_schema_history')
)
SELECT c.oid AS table_oid,c.relname::text AS table_name,c.oid IN(SELECT oid FROM roots) AS is_root
FROM relations relation JOIN pg_class c ON c.oid=relation.oid;

-- Only tables carrying this trigger are accepted by the public lookup. Besides
-- bounding identifiers, this indexed catalog check avoids rebuilding the FK
-- closure for every row in an ordinary native document mutation.
CREATE FUNCTION public.fn_imported_business_document_table(p_table text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM pg_trigger trigger_row JOIN pg_class relation ON relation.oid=trigger_row.tgrelid
  JOIN pg_namespace ns ON ns.oid=relation.relnamespace
  WHERE ns.nspname='public' AND relation.relname=p_table
   AND trigger_row.tgname='trg_00_imported_business_archive_only' AND NOT trigger_row.tgisinternal)
$$;

CREATE FUNCTION public.fn_imported_business_document_scope_table(p_scope text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE scope_name text; candidate text;
BEGIN
 scope_name:=lower(regexp_replace(COALESCE(p_scope,''),'([a-z0-9])([A-Z])','\1_\2','g'));
 candidate:=CASE scope_name
  WHEN 'stock_doc' THEN 'stock_documents' WHEN 'stock_doc_item' THEN 'stock_document_items'
  WHEN 'purchase_application' THEN 'purchase_requests' WHEN 'purchase_application_item' THEN 'purchase_request_items'
  WHEN 'finance_receipt_item' THEN 'finance_receipt_lines'
  WHEN 'finance_payment_item' THEN 'finance_payment_lines'
  WHEN 'finance_bank_transfer_item' THEN 'finance_bank_transfer_lines'
  WHEN 'receipt' THEN 'finance_receipts' WHEN 'receipt_fee' THEN 'finance_receipts'
  WHEN 'direct_receipt' THEN 'finance_receipts'
  WHEN 'payment' THEN 'finance_payments' WHEN 'direct_payment' THEN 'finance_payments'
  WHEN 'expense' THEN 'finance_expenses'
  WHEN 'income' THEN 'finance_other_incomes' WHEN 'other_income' THEN 'finance_other_incomes'
  WHEN 'bank_transfer' THEN 'finance_bank_transfers'
  WHEN 'account_flow' THEN 'finance_reconciliations'
  WHEN 'account_flow_ledger' THEN 'finance_reconciliations'
  WHEN 'finance_reconciliation' THEN 'finance_reconciliations'
  WHEN 'supplier_claim_receipt' THEN 'supplier_claim_cash_receipts'
  WHEN 'procurement_iqc_rejection' THEN 'procurement_iqc_rejection_cases'
  WHEN 'expense_payment_proof' THEN 'expense_claims'
  WHEN 'production_quality_inspection' THEN 'production_fqc_inspections'
  ELSE scope_name END;
 IF public.fn_imported_business_document_table(candidate) THEN RETURN candidate; END IF;
 candidate:=CASE WHEN scope_name LIKE '%y' THEN left(scope_name,-1)||'ies' ELSE scope_name||'s' END;
 IF public.fn_imported_business_document_table(candidate) THEN RETURN candidate; END IF;
 RETURN NULL;
END $$;

CREATE FUNCTION public.fn_imported_business_document_row_internal(p_table text,p_row jsonb,p_path text[])
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE target regclass; reference record; parent_row jsonb; parent_table text; source_id text;
        row_key text; relation_name text; pair text[]; scope_name text;
BEGIN
 IF p_row IS NULL OR NOT public.fn_imported_business_document_table(p_table) THEN RETURN false; END IF;
 row_key:=p_table||':'||COALESCE(p_row->>'id',p_row->>'record_id','new');
 IF row_key=ANY(p_path) THEN RETURN false; END IF;
 IF cardinality(p_path)>64 THEN RAISE EXCEPTION 'Business document source graph exceeds the supported depth' USING ERRCODE='54001'; END IF;
 p_path:=array_append(p_path,row_key);
 IF p_table=ANY(public.fn_imported_business_document_roots()) OR p_row ? 'legacy_id' OR p_row ? 'legacy_import_run_id' THEN
  IF p_row->>'legacy_id' IS NOT NULL OR NULLIF(p_row->>'legacy_import_run_id','') IS NOT NULL THEN RETURN true; END IF;
 END IF;
 target:=to_regclass(format('public.%I',p_table));
 -- Follow every UUID FK into another protected business relation: ownership and
 -- linked sources both matter. Masters and current balances have no guard and
 -- therefore terminate here without becoming historical themselves.
 FOR reference IN
  SELECT parent.relname::text AS parent_table,child_column.attname::text AS child_column
  FROM pg_constraint key JOIN pg_class parent ON parent.oid=key.confrelid
  JOIN pg_namespace ns ON ns.oid=parent.relnamespace
  CROSS JOIN LATERAL generate_subscripts(key.conkey,1) position(index)
  JOIN pg_attribute child_column ON child_column.attrelid=key.conrelid AND child_column.attnum=key.conkey[position.index]
  JOIN pg_attribute parent_column ON parent_column.attrelid=key.confrelid AND parent_column.attnum=key.confkey[position.index]
  WHERE key.contype='f' AND key.conrelid=target AND ns.nspname='public'
   AND parent_column.attname='id' AND parent_column.atttypid='uuid'::regtype
 LOOP
  IF public.fn_imported_business_document_table(reference.parent_table) AND p_row->>reference.child_column IS NOT NULL THEN
   EXECUTE format('SELECT to_jsonb(parent) FROM public.%I parent WHERE id=$1',reference.parent_table)
    INTO parent_row USING (p_row->>reference.child_column)::uuid;
   IF public.fn_imported_business_document_row_internal(reference.parent_table,parent_row,p_path) THEN RETURN true; END IF;
  END IF;
 END LOOP;
 -- Polymorphic references have no physical FK. These are fixed column pairs,
 -- never caller-provided SQL identifiers or inferred matches by amount/name.
 FOREACH pair SLICE 1 IN ARRAY ARRAY[
  ['source_doc_type','source_doc_id'],['source_table','source_id'],
  ['parent_table','parent_id'],['owner_type','owner_id'],
  ['document_type','document_id'],['record_type','document_id'],['family','document_id'],
  ['receipt_type','receipt_id'],['receipt_type','receipt_item_id'],
  ['order_type','order_id'],['order_type','order_item_id']]
 LOOP
  source_id:=p_row->>pair[2];
  IF source_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
   -- Shared procurement tables use fixed PURCHASE/SUBCONTRACT discriminators,
   -- not a table name supplied by the caller. These exact pairs have no FK.
   IF pair[1]='receipt_type' THEN
    parent_table:=CASE upper(p_row->>pair[1])
     WHEN 'PURCHASE' THEN CASE pair[2] WHEN 'receipt_item_id' THEN 'purchase_receipt_items' ELSE 'purchase_receipts' END
     WHEN 'SUBCONTRACT' THEN CASE pair[2] WHEN 'receipt_item_id' THEN 'subcontract_receipt_items' ELSE 'subcontract_receipts' END END;
   ELSIF pair[1]='order_type' THEN
    parent_table:=CASE upper(p_row->>pair[1])
     WHEN 'PURCHASE' THEN CASE pair[2] WHEN 'order_item_id' THEN 'purchase_order_items' ELSE 'purchase_orders' END
     WHEN 'SUBCONTRACT' THEN CASE pair[2] WHEN 'order_item_id' THEN 'subcontract_order_items' ELSE 'subcontract_orders' END END;
   ELSE
    parent_table:=public.fn_imported_business_document_scope_table(p_row->>pair[1]);
   END IF;
   IF parent_table IS NOT NULL THEN
    EXECUTE format('SELECT to_jsonb(parent) FROM public.%I parent WHERE id=$1',parent_table)
     INTO parent_row USING source_id::uuid;
    IF public.fn_imported_business_document_row_internal(parent_table,parent_row,p_path) THEN RETURN true; END IF;
   END IF;
  END IF;
 END LOOP;
 IF p_table='platform_record_fields' THEN
  scope_name:=p_row->>'scope';
  parent_table:=public.fn_imported_business_document_scope_table(scope_name);
  source_id:=p_row->>'record_id';
  IF parent_table IS NOT NULL AND source_id IS NOT NULL THEN
   EXECUTE format('SELECT to_jsonb(parent) FROM public.%I parent WHERE id=$1',parent_table)
    INTO parent_row USING source_id::uuid;
   IF public.fn_imported_business_document_row_internal(parent_table,parent_row,p_path) THEN RETURN true; END IF;
  END IF;
  -- A new row cannot copy mutable values from an original archived header.
  parent_table:=public.fn_imported_business_document_scope_table(regexp_replace(scope_name,'_(item|line)$',''));
  source_id:=p_row->>'source_document_id';
  IF parent_table IS NOT NULL AND source_id IS NOT NULL THEN
   EXECUTE format('SELECT to_jsonb(parent) FROM public.%I parent WHERE id=$1',parent_table)
    INTO parent_row USING source_id::uuid;
   IF public.fn_imported_business_document_row_internal(parent_table,parent_row,p_path) THEN RETURN true; END IF;
  END IF;
 END IF;
 RETURN false;
END $$;

CREATE FUNCTION public.fn_imported_business_document_row(p_table text,p_row jsonb) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT public.fn_imported_business_document_row_internal(p_table,p_row,ARRAY[]::text[])
$$;

CREATE FUNCTION public.fn_imported_business_document(p_table text,p_id uuid) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE document jsonb;
BEGIN
 IF p_id IS NULL OR NOT public.fn_imported_business_document_table(p_table) THEN RETURN false; END IF;
 IF p_table='platform_record_fields' THEN
  FOR document IN SELECT to_jsonb(fields) FROM public.platform_record_fields fields WHERE fields.record_id=p_id LOOP
   IF public.fn_imported_business_document_row(p_table,document) THEN RETURN true; END IF;
  END LOOP;
  RETURN false;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=to_regclass(format('public.%I',p_table))
  AND attname='id' AND NOT attisdropped) THEN RETURN false; END IF;
 EXECUTE format('SELECT to_jsonb(document) FROM public.%I document WHERE id=$1',p_table) INTO document USING p_id;
 RETURN public.fn_imported_business_document_row(p_table,document);
END $$;

CREATE FUNCTION public.fn_guard_imported_business_document_archive() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF public.fn_imported_business_document_maintenance_allowed() THEN
  IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
 END IF;
 IF (TG_OP<>'INSERT' AND public.fn_imported_business_document_row(TG_TABLE_NAME,to_jsonb(OLD)))
  OR (TG_OP<>'DELETE' AND public.fn_imported_business_document_row(TG_TABLE_NAME,to_jsonb(NEW))) THEN
  RAISE EXCEPTION '历史原始单据仅供核对，不能修改、审核、反审或用于新的业务来源'
   USING ERRCODE='55000',CONSTRAINT='imported_business_document_archive_only';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;

-- TRUNCATE does not fire row guards. It is never an ordinary document command;
-- an accidental runtime grant or a SECURITY DEFINER helper must not erase history.
CREATE FUNCTION public.fn_guard_imported_business_document_truncate() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF NOT public.fn_imported_business_document_maintenance_allowed() THEN
  RAISE EXCEPTION '历史原始单据仅供核对，运行账号不能整表清空业务记录'
   USING ERRCODE='55000',CONSTRAINT='imported_business_document_archive_only';
 END IF;
 RETURN NULL;
END $$;

DO $install_archive_guards$
DECLARE target record;
BEGIN
 FOR target IN
  SELECT table_name FROM public.v_imported_business_document_guard_tables
  UNION SELECT relation.relname::text FROM pg_class relation JOIN pg_namespace ns ON ns.oid=relation.relnamespace
   WHERE ns.nspname='public' AND relation.relkind IN('r','p') AND (
    relation.relname IN('platform_record_fields','attachments') OR
    (EXISTS(SELECT 1 FROM pg_attribute a WHERE a.attrelid=relation.oid AND a.attname='owner_type' AND NOT a.attisdropped)
     AND EXISTS(SELECT 1 FROM pg_attribute a WHERE a.attrelid=relation.oid AND a.attname='owner_id' AND NOT a.attisdropped)))
 LOOP
  EXECUTE format('CREATE TRIGGER trg_00_imported_business_archive_only BEFORE INSERT OR UPDATE OR DELETE ON public.%I '
   'FOR EACH ROW EXECUTE FUNCTION public.fn_guard_imported_business_document_archive()',target.table_name);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_00_imported_business_archive_only',target.table_name);
  EXECUTE format('CREATE TRIGGER trg_00_imported_business_archive_truncate BEFORE TRUNCATE ON public.%I '
   'FOR EACH STATEMENT EXECUTE FUNCTION public.fn_guard_imported_business_document_truncate()',target.table_name);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_00_imported_business_archive_truncate',target.table_name);
 END LOOP;
END $install_archive_guards$;

COMMENT ON FUNCTION public.fn_imported_business_document(text,uuid) IS
 'Read-only imported-business provenance lookup. Master data/current inventory are not archive roots; no status or date inference.';
