-- Purchase document printing uses its real maker policy; purchase reports retain
-- their original company-wide feature contract. Earlier migrations are immutable.
ALTER TABLE read_scope_domains DROP CONSTRAINT read_scope_domains_domain_check;
ALTER TABLE read_scope_domains ADD CONSTRAINT read_scope_domains_domain_check CHECK(domain IN (
 'sales','purchase','subcontract','production','stock','finance','client','supplier',
 'master_goods','master_account','master_currency','master_color','master_unit','master_mould','master_warehouse','master_settlement_method','audit',
 'native_feature','native_purchase_owner','native_subcontract_owner','native_production_owner','native_fqc_records','native_workshop_tasks','native_warehouse_tasks'));
INSERT INTO read_scope_domains(domain) VALUES('native_purchase_owner');

DO $$ DECLARE relation text;BEGIN
 FOREACH relation IN ARRAY ARRAY['purchase_orders','purchase_receipts','purchase_returns'] LOOP
  EXECUTE format('CREATE TRIGGER trg_native_purchase_maker AFTER UPDATE OF maker_id ON public.%I FOR EACH ROW WHEN(OLD.maker_id IS DISTINCT FROM NEW.maker_id) EXECUTE FUNCTION public.fn_mark_read_scope_domains(''native_purchase_owner'')',relation);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_native_purchase_maker',relation);
 END LOOP;
END $$;
CREATE TRIGGER trg_native_purchase_employee_deleted AFTER UPDATE OF is_deleted ON employees
FOR EACH ROW WHEN(OLD.is_deleted IS DISTINCT FROM NEW.is_deleted)
EXECUTE FUNCTION fn_mark_read_scope_domains('native_purchase_owner');
ALTER TABLE employees ENABLE ALWAYS TRIGGER trg_native_purchase_employee_deleted;

-- Keep a single Native owner-source algorithm. Extend its scope-to-domain map;
-- do not add another implementation for purchase or alter the original policies.
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
   scopes:=ARRAY['purchase','subcontract','production_plan'];
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
   WHEN 'subcontract' THEN ARRAY['native_subcontract_owner']
   WHEN 'production_plan' THEN ARRAY['native_production_owner','native_fqc_records'] ELSE ARRAY[]::text[] END;
  FOREACH domain IN ARRAY domains LOOP PERFORM public.fn_record_read_scope_change(domain);END LOOP;
 END LOOP;
 RETURN NULL;
END $$;
CREATE TRIGGER trg_native_purchase_grants_truncate AFTER TRUNCATE ON user_data_scopes
FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_read_scope_domains('native_purchase_owner');
ALTER TABLE user_data_scopes ENABLE ALWAYS TRIGGER trg_native_purchase_grants_truncate;
