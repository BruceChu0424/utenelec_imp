-- Forward optimization of only the eleven V985 column-aware observers.
-- Keep V942 and the shared observer algorithm, owner/ACL, domain and arguments unchanged.
DO $$
DECLARE
 rules text[][]:=ARRAY[
  ['stock_documents','U','to_warehouse_id,maker_id','trg_native_warehouse_document_dimensions'],
  ['stock_document_items','U','warehouse_id','trg_native_warehouse_item_dimensions'],
  ['sales_shipments','A','warehouse_id',''],
  ['sales_shipment_items','A','shipment_id,warehouse_id',''],
  ['production_finished_arrival_registrations','A','warehouse_id',''],
  ['production_material_discovery_lines','A','request_id,warehouse_id',''],
  ['workshop_material_requisitions','A','workshop_department_id',''],
  ['workshop_material_requisition_lines','A','requisition_id,suggested_leaf_warehouse_id',''],
  ['workshop_bins','A','workshop_department_id,source_warehouse_id',''],
  ['workshop_material_settings','A','workshop_department_id,periodic_bin_warehouse_id',''],
  ['stock_count_requests','A','warehouse_id,review_route,submitted_by','']
 ];
 rule text[]; columns text[]; arguments text[]; argument text;
 trigger_name text; expected_args bytea; expected_attr smallint[];
 source_function oid:='public.fn_mark_native_scope_columns()'::regprocedure;
 predecessor pg_catalog.pg_trigger%ROWTYPE;
 column_sql text; old_sql text; new_sql text; argument_sql text;
BEGIN
 -- This function has not changed since V942. EOL normalization only accounts
 -- for the same reviewed resource passing through Windows/Linux text storage.
 IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_proc p
   WHERE p.oid=source_function AND p.pronargs=0 AND p.prorettype='pg_catalog.trigger'::regtype
    AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
      pg_catalog.replace(p.prosrc,E'\r\n',E'\n'),'UTF8')),'hex')=
      '8ac3c8d78d1cfc902d65548386eecee093b54bfef064d7aed0703a006ad1f697') THEN
  RAISE EXCEPTION 'Unknown native scope observer function; refusing V986' USING ERRCODE='55000';
 END IF;

 -- Validate every exact predecessor before changing any trigger. Unknown
 -- event masks, WHEN clauses, columns, arguments, bindings or enable modes fail closed.
 FOREACH rule SLICE 1 IN ARRAY rules LOOP
  columns:=string_to_array(rule[3],',');
  trigger_name:=CASE WHEN rule[4]<>'' THEN rule[4]
    ELSE 'trg_native_warehouse_'||md5(rule[1]||'/'||rule[3]) END;
  arguments:=ARRAY['native_warehouse_tasks']||columns;
  expected_args:=''::bytea;
  FOREACH argument IN ARRAY arguments LOOP
   expected_args:=expected_args||pg_catalog.convert_to(argument,'UTF8')||pg_catalog.decode('00','hex');
  END LOOP;
  SELECT ARRAY(SELECT a.attnum::smallint FROM unnest(columns) WITH ORDINALITY c(name,position)
    JOIN pg_catalog.pg_attribute a ON a.attrelid=('public.'||rule[1])::regclass
      AND a.attname=c.name AND NOT a.attisdropped ORDER BY c.position) INTO expected_attr;
  IF cardinality(expected_attr)<>cardinality(columns) THEN
   RAISE EXCEPTION 'Missing reviewed V985 source columns on %',rule[1] USING ERRCODE='55000';
  END IF;
  SELECT t.* INTO predecessor FROM pg_catalog.pg_trigger t
    WHERE t.tgrelid=('public.'||rule[1])::regclass AND t.tgname=trigger_name;
  IF NOT FOUND OR predecessor.tgfoid<>source_function OR predecessor.tgtype<>(CASE WHEN rule[2]='U' THEN 17 ELSE 29 END)
    OR predecessor.tgenabled<>'A' OR predecessor.tgisinternal OR predecessor.tgconstraint<>0
    OR predecessor.tgparentid<>0 OR predecessor.tgdeferrable OR predecessor.tginitdeferred
    OR predecessor.tgoldtable IS NOT NULL OR predecessor.tgnewtable IS NOT NULL OR predecessor.tgqual IS NOT NULL
    OR predecessor.tgnargs<>cardinality(arguments) OR predecessor.tgargs<>expected_args
    OR ARRAY(SELECT value FROM unnest(predecessor.tgattr::smallint[]) value)<>
      (CASE WHEN rule[2]='U' THEN expected_attr ELSE ARRAY[]::smallint[] END)
    OR EXISTS(SELECT 1 FROM pg_catalog.pg_trigger t
      WHERE t.tgrelid=('public.'||rule[1])::regclass AND t.tgname=trigger_name||'_update') THEN
   RAISE EXCEPTION 'Unknown V985 observer predecessor %.%; refusing V986',rule[1],trigger_name USING ERRCODE='55000';
  END IF;
 END LOOP;

 FOREACH rule SLICE 1 IN ARRAY rules LOOP
  columns:=string_to_array(rule[3],',');
  trigger_name:=CASE WHEN rule[4]<>'' THEN rule[4]
    ELSE 'trg_native_warehouse_'||md5(rule[1]||'/'||rule[3]) END;
  SELECT string_agg(format('%I',name),',' ORDER BY position),
         string_agg(format('OLD.%I',name),',' ORDER BY position),
         string_agg(format('NEW.%I',name),',' ORDER BY position)
    INTO column_sql,old_sql,new_sql FROM unnest(columns) WITH ORDINALITY c(name,position);
  SELECT string_agg(quote_literal(value),',' ORDER BY position) INTO argument_sql
    FROM unnest(ARRAY['native_warehouse_tasks']||columns) WITH ORDINALITY a(value,position);
  EXECUTE format('DROP TRIGGER %I ON public.%I',trigger_name,rule[1]);
  IF rule[2]='A' THEN
   -- INSERT/DELETE retain exactly their former behavior. UPDATE intentionally
   -- has no OF restriction: BEFORE triggers may change watched fields even
   -- when the original SET list did not mention them.
   EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.fn_mark_native_scope_columns(%s)',
     trigger_name,rule[1],argument_sql);
   EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I',rule[1],trigger_name);
   trigger_name:=trigger_name||'_update';
   column_sql:='UPDATE';
  ELSE
   -- The same watched values may be assigned by a BEFORE trigger even when
   -- absent from SET. WHEN is the sole UPDATE gate for all V985 observers.
   column_sql:='UPDATE';
  END IF;
  EXECUTE format('CREATE TRIGGER %I AFTER %s ON public.%I FOR EACH ROW WHEN (ROW(%s) IS DISTINCT FROM ROW(%s)) EXECUTE FUNCTION public.fn_mark_native_scope_columns(%s)',
    trigger_name,column_sql,rule[1],old_sql,new_sql,argument_sql);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I',rule[1],trigger_name);
 END LOOP;
END $$;
