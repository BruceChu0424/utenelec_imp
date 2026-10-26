-- Native candidate reads retain their exact business authorities. Earlier migrations stay byte-identical.
ALTER TABLE read_scope_domains DROP CONSTRAINT read_scope_domains_domain_check;
ALTER TABLE read_scope_domains ADD CONSTRAINT read_scope_domains_domain_check CHECK(domain IN (
 'sales','purchase','subcontract','production','stock','finance','client','supplier',
 'master_goods','master_account','master_currency','master_color','master_unit','master_mould','master_warehouse','master_settlement_method','audit',
 'native_feature','native_subcontract_owner','native_production_owner','native_fqc_records','native_workshop_tasks','native_warehouse_tasks'));
INSERT INTO read_scope_domains(domain) VALUES ('native_feature'),('native_subcontract_owner'),('native_production_owner'),
 ('native_fqc_records'),('native_workshop_tasks'),('native_warehouse_tasks');
-- native_sales_owner reuses the existing sales authorization ledger, not a new watermark.

CREATE FUNCTION fn_mark_native_scope_columns() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE o jsonb:=CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
 n jsonb:=CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
 changed boolean:=TG_OP<>'UPDATE'; domain text; index integer;
BEGIN
 IF TG_TABLE_SCHEMA<>'public' THEN RAISE EXCEPTION 'Invalid native scope source' USING ERRCODE='55000'; END IF;
 IF NOT changed THEN
  FOR index IN 1..TG_NARGS-1 LOOP
   IF o->TG_ARGV[index] IS DISTINCT FROM n->TG_ARGV[index] THEN changed:=true;EXIT;END IF;
  END LOOP;
 END IF;
 IF changed THEN
  FOREACH domain IN ARRAY string_to_array(TG_ARGV[0],',') LOOP PERFORM public.fn_record_read_scope_change(domain);END LOOP;
 END IF;
 RETURN NULL;
END $$;

-- Only attributes used by the actual authorities. Names, amounts, quantities,
-- ordinary progress/status, request filters and selected warehouses are excluded.
DO $$ DECLARE rule text[]; columns text[]; column_name text; arguments text; events text;
BEGIN
 FOREACH rule SLICE 1 IN ARRAY ARRAY[
  ['subcontract_orders','native_subcontract_owner','U','maker_id'],
  ['production_plans','native_production_owner','U','maker_id'],
  ['production_material_analyses','native_production_owner','U','maker_id'],
  ['production_daily_reports','native_production_owner','U','maker_id'],
  ['production_fqc_inspections','native_fqc_records','U','report_maker_id'],
  ['production_execution_segments','native_workshop_tasks','U','workshop_department_id,responsible_employee_id'],
  ['departments','native_workshop_tasks,native_warehouse_tasks','A','parent_id,manager_id,is_deleted'],
  ['departments','native_warehouse_tasks','U','code'],
  ['employees','native_subcontract_owner,native_production_owner,native_fqc_records,native_workshop_tasks,native_warehouse_tasks','U','is_deleted'],
  ['employees','native_fqc_records,native_workshop_tasks,native_warehouse_tasks','U','status'],
  ['employees','native_workshop_tasks,native_warehouse_tasks','U','department_id'],
  ['employee_secondary_departments','native_workshop_tasks,native_warehouse_tasks','A','employee_id,department_id'],
  ['users','native_fqc_records,native_warehouse_tasks','U','employee_id,status,is_deleted,is_super_admin'],
  ['warehouses','native_warehouse_tasks','A','parent_id,is_deleted,code,is_line_side'],
  ['warehouse_keepers','native_warehouse_tasks','A','warehouse_id,employee_id'],
  ['purchase_receipts','native_warehouse_tasks','U','warehouse_id'],
  ['subcontract_receipts','native_warehouse_tasks','U','warehouse_id'],
  ['subcontract_material_issues','native_warehouse_tasks','U','warehouse_id'],
  ['subcontract_returns','native_warehouse_tasks','U','warehouse_id'],
  ['subcontract_material_returns','native_warehouse_tasks','U','warehouse_id'],
  ['subcontract_wastes','native_warehouse_tasks','U','warehouse_id'],
  ['procurement_inspection_items','native_warehouse_tasks','A','receipt_type,receipt_id,receipt_item_id,warehouse_id'],
  ['subcontract_waste_items','native_warehouse_tasks','A','waste_id,material_issue_item_id,is_deleted'],
  ['subcontract_material_issue_items','native_warehouse_tasks','A','issue_id'],
  ['goods','native_warehouse_tasks','U','owning_warehouse_id'],
  ['production_daily_report_items','native_warehouse_tasks','A','report_id,goods_id,is_deleted'],
  ['stock_documents','native_warehouse_tasks','U','warehouse_id'],
  ['stock_document_items','native_warehouse_tasks','A','doc_id']
 ] LOOP
  columns:=string_to_array(rule[4],',');arguments:=quote_literal(rule[2]);
  FOREACH column_name IN ARRAY columns LOOP
   IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_attribute WHERE attrelid=('public.'||rule[1])::regclass AND attname=column_name AND NOT attisdropped) THEN
    RAISE EXCEPTION 'Missing native authorization source %.%',rule[1],column_name;
   END IF;
   arguments:=arguments||','||quote_literal(column_name);
  END LOOP;
  events:=CASE WHEN rule[3]='A' THEN 'INSERT OR UPDATE OR DELETE' ELSE 'UPDATE' END;
  EXECUTE format('CREATE TRIGGER %I AFTER %s ON public.%I FOR EACH ROW EXECUTE FUNCTION public.fn_mark_native_scope_columns(%s)',
   'trg_native_scope_'||md5(rule[1]||'/'||rule[2]||'/'||rule[4]),events,rule[1],arguments);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I',rule[1],
   'trg_native_scope_'||md5(rule[1]||'/'||rule[2]||'/'||rule[4]));
 END LOOP;
END $$;

-- Inspection reversal changes which physical warehouse controls an existing
-- receipt; ordinary inspection progress does not change its audience.
CREATE TRIGGER trg_native_scope_inspection_reversed AFTER UPDATE OF status ON procurement_inspection_items
FOR EACH ROW WHEN ((OLD.status='REVERSED') IS DISTINCT FROM (NEW.status='REVERSED'))
EXECUTE FUNCTION fn_mark_read_scope_domains('native_warehouse_tasks');
ALTER TABLE procurement_inspection_items ENABLE ALWAYS TRIGGER trg_native_scope_inspection_reversed;

CREATE FUNCTION fn_mark_native_owner_sources() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE o jsonb:=CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
 n jsonb:=CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
 scope text;
BEGIN
 IF TG_TABLE_SCHEMA<>'public' THEN RAISE EXCEPTION 'Invalid native owner source' USING ERRCODE='55000';END IF;
 IF TG_TABLE_NAME='user_data_scopes' THEN
  IF TG_OP='UPDATE' AND ROW(o->>'user_id',o->>'scope',o->>'owner_employee_id',o->>'owner_employment_generation')
   IS NOT DISTINCT FROM ROW(n->>'user_id',n->>'scope',n->>'owner_employee_id',n->>'owner_employment_generation') THEN RETURN NULL;END IF;
  FOR scope IN SELECT DISTINCT value FROM unnest(ARRAY[o->>'scope',n->>'scope']) value WHERE value IN('subcontract','production_plan') LOOP
   IF scope='subcontract' THEN PERFORM public.fn_record_read_scope_change('native_subcontract_owner');
   ELSE PERFORM public.fn_record_read_scope_change('native_production_owner');PERFORM public.fn_record_read_scope_change('native_fqc_records');END IF;
  END LOOP;
 ELSIF TG_TABLE_NAME='employment_history' THEN
  IF (o->>'event_type'='rehire' OR n->>'event_type'='rehire') AND
   (TG_OP<>'UPDATE' OR ROW(o->>'employee_id',o->>'event_type') IS DISTINCT FROM ROW(n->>'employee_id',n->>'event_type')) THEN
   PERFORM public.fn_record_read_scope_change('native_subcontract_owner');PERFORM public.fn_record_read_scope_change('native_production_owner');
   PERFORM public.fn_record_read_scope_change('native_fqc_records');
  END IF;
 ELSIF TG_TABLE_NAME='employee_data_handovers' THEN
  IF NOT(COALESCE(o->>'status'='COMPLETED',false) OR COALESCE(n->>'status'='COMPLETED',false)) THEN RETURN NULL;END IF;
  IF TG_OP='UPDATE' AND ROW(o->>'status',o->>'source_employee_id',o->>'target_employee_id',o->>'source_employment_generation',o->>'target_employment_generation',o->>'sequence_no')
   IS NOT DISTINCT FROM ROW(n->>'status',n->>'source_employee_id',n->>'target_employee_id',n->>'source_employment_generation',n->>'target_employment_generation',n->>'sequence_no') THEN RETURN NULL;END IF;
  FOR scope IN SELECT DISTINCT s.scope FROM public.employee_data_handover_scopes s WHERE s.handover_id=COALESCE((n->>'id')::uuid,(o->>'id')::uuid) AND s.scope IN('subcontract','production_plan') LOOP
   IF scope='subcontract' THEN PERFORM public.fn_record_read_scope_change('native_subcontract_owner');
   ELSE PERFORM public.fn_record_read_scope_change('native_production_owner');PERFORM public.fn_record_read_scope_change('native_fqc_records');END IF;
  END LOOP;
 ELSIF TG_TABLE_NAME='employee_data_handover_scopes' THEN
  IF TG_OP='UPDATE' AND ROW(o->>'handover_id',o->>'scope') IS NOT DISTINCT FROM ROW(n->>'handover_id',n->>'scope') THEN RETURN NULL;END IF;
  FOR scope IN SELECT DISTINCT pair.scope FROM(VALUES((o->>'handover_id')::uuid,o->>'scope'),((n->>'handover_id')::uuid,n->>'scope'))pair(id,scope)
   LEFT JOIN public.employee_data_handovers h ON h.id=pair.id WHERE pair.scope IN('subcontract','production_plan') AND(TG_OP='DELETE' OR h.status='COMPLETED') LOOP
   IF scope='subcontract' THEN PERFORM public.fn_record_read_scope_change('native_subcontract_owner');
   ELSE PERFORM public.fn_record_read_scope_change('native_production_owner');PERFORM public.fn_record_read_scope_change('native_fqc_records');END IF;
  END LOOP;
 END IF;
 RETURN NULL;
END $$;
DO $$ DECLARE relation text;BEGIN
 FOREACH relation IN ARRAY ARRAY['user_data_scopes','employment_history','employee_data_handovers','employee_data_handover_scopes'] LOOP
  EXECUTE format('CREATE TRIGGER trg_native_owner_sources AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.fn_mark_native_owner_sources()',relation);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_native_owner_sources',relation);
 END LOOP;
END $$;
CREATE TRIGGER trg_native_owner_grants_truncate AFTER TRUNCATE ON user_data_scopes
FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_read_scope_domains('native_subcontract_owner','native_production_owner','native_fqc_records');
ALTER TABLE user_data_scopes ENABLE ALWAYS TRIGGER trg_native_owner_grants_truncate;
