-- Forward-only additions to the existing native warehouse authorization ledger.
-- Keep all V942 sources. These are ownership dimensions used by actual reads,
-- not quantity, amount, workflow progress or a request's selected warehouse.
CREATE TRIGGER trg_native_warehouse_document_dimensions
AFTER UPDATE OF to_warehouse_id,maker_id ON public.stock_documents
FOR EACH ROW EXECUTE FUNCTION public.fn_mark_native_scope_columns(
    'native_warehouse_tasks','to_warehouse_id','maker_id');
ALTER TABLE public.stock_documents ENABLE ALWAYS TRIGGER trg_native_warehouse_document_dimensions;

CREATE TRIGGER trg_native_warehouse_item_dimensions
AFTER UPDATE OF warehouse_id ON public.stock_document_items
FOR EACH ROW EXECUTE FUNCTION public.fn_mark_native_scope_columns(
    'native_warehouse_tasks','warehouse_id');
ALTER TABLE public.stock_document_items ENABLE ALWAYS TRIGGER trg_native_warehouse_item_dimensions;

-- Fixed physical identities read by the warehouse task unions and associated
-- status/count/history readers. State, quantities and prices are not watched.
DO $$ DECLARE rule text[]; column_name text; arguments text;
BEGIN
 FOREACH rule SLICE 1 IN ARRAY ARRAY[
  ['sales_shipments','warehouse_id'],
  ['sales_shipment_items','shipment_id,warehouse_id'],
  ['production_finished_arrival_registrations','warehouse_id'],
  ['production_material_discovery_lines','request_id,warehouse_id'],
  ['workshop_material_requisitions','workshop_department_id'],
  ['workshop_material_requisition_lines','requisition_id,suggested_leaf_warehouse_id'],
  ['workshop_bins','workshop_department_id,source_warehouse_id'],
  ['workshop_material_settings','workshop_department_id,periodic_bin_warehouse_id'],
  ['stock_count_requests','warehouse_id,review_route,submitted_by']
 ] LOOP
  arguments:=quote_literal('native_warehouse_tasks');
  FOREACH column_name IN ARRAY string_to_array(rule[2],',') LOOP
   IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_attribute
       WHERE attrelid=('public.'||rule[1])::regclass AND attname=column_name AND NOT attisdropped) THEN
    RAISE EXCEPTION 'Missing warehouse read authorization source %.%',rule[1],column_name;
   END IF;
   arguments:=arguments||','||quote_literal(column_name);
  END LOOP;
  EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.fn_mark_native_scope_columns(%s)',
      'trg_native_warehouse_'||md5(rule[1]||'/'||rule[2]),rule[1],arguments);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I',rule[1],
      'trg_native_warehouse_'||md5(rule[1]||'/'||rule[2]));
 END LOOP;
END $$;


-- Stock-document owner reads use the existing canonical owner-source hook.
-- Existing purchase/subcontract/production/quality rules remain intact; only stock_doc joins the same event contract.
CREATE OR REPLACE FUNCTION fn_mark_native_owner_sources() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE o jsonb:=CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
 n jsonb:=CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
 scopes text[]; scope text; domains text[]; domain text;
BEGIN
 IF TG_TABLE_SCHEMA<>'public' THEN RAISE EXCEPTION 'Invalid native owner source' USING ERRCODE='55000';END IF;
 IF TG_TABLE_NAME='user_data_scopes' THEN
  IF TG_OP='UPDATE' AND ROW(o->>'user_id',o->>'scope',o->>'owner_employee_id',o->>'owner_employment_generation')
   IS NOT DISTINCT FROM ROW(n->>'user_id',n->>'scope',n->>'owner_employee_id',n->>'owner_employment_generation') THEN RETURN NULL;END IF;
  scopes:=ARRAY[o->>'scope',n->>'scope'];
 ELSIF TG_TABLE_NAME='employment_history' THEN
  IF (o->>'event_type'='rehire' OR n->>'event_type'='rehire') AND
   (TG_OP<>'UPDATE' OR ROW(o->>'employee_id',o->>'event_type') IS DISTINCT FROM ROW(n->>'employee_id',n->>'event_type')) THEN
   scopes:=ARRAY['purchase','subcontract','production_plan','stock_doc'];
  END IF;
 ELSIF TG_TABLE_NAME='employee_data_handovers' THEN
  IF NOT(COALESCE(o->>'status'='COMPLETED',false) OR COALESCE(n->>'status'='COMPLETED',false)) THEN RETURN NULL;END IF;
  IF TG_OP='UPDATE' AND ROW(o->>'status',o->>'source_employee_id',o->>'target_employee_id',o->>'source_employment_generation',o->>'target_employment_generation',o->>'sequence_no')
   IS NOT DISTINCT FROM ROW(n->>'status',n->>'source_employee_id',n->>'target_employee_id',n->>'source_employment_generation',n->>'target_employment_generation',n->>'sequence_no') THEN RETURN NULL;END IF;
  SELECT array_agg(DISTINCT s.scope) INTO scopes FROM public.employee_data_handover_scopes s
   WHERE s.handover_id=COALESCE((n->>'id')::uuid,(o->>'id')::uuid);
 ELSIF TG_TABLE_NAME='employee_data_handover_scopes' THEN
  IF TG_OP='UPDATE' AND ROW(o->>'handover_id',o->>'scope') IS NOT DISTINCT FROM ROW(n->>'handover_id',n->>'scope') THEN RETURN NULL;END IF;
  SELECT array_agg(DISTINCT pair.scope) INTO scopes
   FROM(VALUES((o->>'handover_id')::uuid,o->>'scope'),((n->>'handover_id')::uuid,n->>'scope'))pair(id,scope)
   LEFT JOIN public.employee_data_handovers h ON h.id=pair.id WHERE TG_OP='DELETE' OR h.status='COMPLETED';
 ELSE RAISE EXCEPTION 'Invalid native owner source' USING ERRCODE='55000';
 END IF;
 FOR scope IN SELECT DISTINCT value FROM unnest(COALESCE(scopes,ARRAY[]::text[])) value LOOP
  domains:=CASE scope WHEN 'purchase' THEN ARRAY['native_purchase_owner']
   WHEN 'stock_doc' THEN ARRAY['native_warehouse_tasks']
   WHEN 'subcontract' THEN ARRAY['native_subcontract_owner']
   WHEN 'production_plan' THEN ARRAY['native_production_owner','native_fqc_records'] ELSE ARRAY[]::text[] END;
  FOREACH domain IN ARRAY domains LOOP PERFORM public.fn_record_read_scope_change(domain);END LOOP;
 END LOOP;
 RETURN NULL;
END $$;

DROP TRIGGER trg_native_owner_grants_truncate ON public.user_data_scopes;
CREATE TRIGGER trg_native_owner_grants_truncate AFTER TRUNCATE ON public.user_data_scopes
FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_read_scope_domains('native_subcontract_owner','native_production_owner','native_fqc_records','native_warehouse_tasks');
ALTER TABLE public.user_data_scopes ENABLE ALWAYS TRIGGER trg_native_owner_grants_truncate;
