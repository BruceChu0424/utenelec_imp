-- The permanent first-use fact is append-only. If every actual OLD/NEW
-- reference already has that fact, the original writer returns without a
-- lock or write. Extract distinct references once and prove them as a batch;
-- every unproved reference still reaches the original complete writer.
CREATE FUNCTION fn_goods_code_use_recorded(p_before jsonb,p_after jsonb,p_specs text[])
RETURNS boolean LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE referenced_goods uuid[]; original_executable boolean;
BEGIN
 IF p_specs IS NULL OR cardinality(p_specs)=0 THEN RETURN false; END IF;
 WITH source_rows AS (
  SELECT row_value FROM (VALUES(p_before),(p_after)) inputs(row_value) WHERE row_value IS NOT NULL
 ), cells AS (
  SELECT left(spec,1) kind,row_value->substring(spec FROM 3) value
  FROM source_rows CROSS JOIN unnest(p_specs) specifications(spec)
 ), source_references AS (
  SELECT (value#>>'{}')::uuid goods_id FROM cells
  WHERE kind='U' AND value IS NOT NULL AND value<>'null'::jsonb
  UNION
  SELECT matched[1]::uuid FROM cells
  CROSS JOIN LATERAL regexp_matches(value::text,
   '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})','g') matched
  WHERE kind<>'U' AND value IS NOT NULL AND value<>'null'::jsonb
 )
 SELECT array_agg(goods_id),
  has_function_privilege('public.fn_capture_goods_code_use()','EXECUTE')
   AND has_function_privilege('public.fn_note_goods_code_use(uuid,text)','EXECUTE')
 INTO referenced_goods,original_executable FROM source_references;
 -- With no reference the original callback never reads the metadata table.
 -- Otherwise use the caller's original SELECT/RLS visibility and privileges;
 -- the proof never elevates a source writer through a SECURITY DEFINER lookup.
 IF referenced_goods IS NULL THEN RETURN true; END IF;
 IF NOT original_executable THEN RETURN false; END IF;
 RETURN NOT EXISTS(SELECT 1 FROM unnest(referenced_goods) reference(goods_id)
  WHERE NOT EXISTS(SELECT 1 FROM public.goods_code_usage_facts proof WHERE proof.goods_id=reference.goods_id));
END $$;
COMMENT ON FUNCTION fn_goods_code_use_recorded(jsonb,jsonb,text[]) IS
 'Batch proof of existing permanent first-use facts only; never creates usage, grants authority, or substitutes a missing reference.';

-- Keep the canonical producer: later migrations adding tracked sources use
-- the same catalog, writer and proof gates. Preserve per-event modes/comments
-- when refreshing an already split trigger, and the original mode otherwise.
CREATE OR REPLACE FUNCTION fn_refresh_goods_code_usage_tracking() RETURNS void LANGUAGE plpgsql AS $$
DECLARE tracked record; item record; specs text[]; arguments text; proof_arguments text;
 names text[]:=ARRAY['trg_track_goods_code_usage','trg_track_goods_code_usage_update','trg_track_goods_code_usage_delete'];
 modes text[]; comments text[]; event_number integer; event_name text; condition text;
BEGIN
 FOR tracked IN SELECT DISTINCT table_name FROM fn_goods_code_usage_columns() ORDER BY table_name LOOP
  SELECT array_agg(kind||':'||column_name ORDER BY column_name),
   string_agg(quote_literal(kind||':'||column_name),',' ORDER BY column_name)
  INTO specs,arguments FROM fn_goods_code_usage_columns() WHERE table_name=tracked.table_name;
  IF cardinality(specs) IS NULL OR cardinality(specs)=0 THEN
   RAISE EXCEPTION 'Tracked goods-code source lacks its reference columns';
  END IF;
  -- V932/V968 are explicit unconditional installer contracts for physical
  -- holds and the monthly ledger projection. Retain their exact original
  -- observer, including zero quantities and the old tamper-refusal protocol.
  IF tracked.table_name IN ('stock_measurement_holds','stock_monthly_summaries') THEN
   IF specs<>ARRAY['U:goods_id'] THEN
    RAISE EXCEPTION 'Review the physical stock lifetime columns before refreshing';
   END IF;
   SELECT * INTO item FROM pg_trigger
    WHERE tgrelid=format('public.%I',tracked.table_name)::regclass AND tgname=names[1] AND NOT tgisinternal;
   IF FOUND THEN
    IF item.tgfoid<>'public.fn_capture_goods_code_use()'::regprocedure
     OR item.tgtype<>29 OR item.tgenabled<>'O' OR item.tgnargs<>1
     OR item.tgqual IS NOT NULL OR item.tgattr<>''::int2vector
     OR item.tgconstraint<>0 OR item.tgdeferrable OR item.tginitdeferred
     OR item.tgoldtable IS NOT NULL OR item.tgnewtable IS NOT NULL
     OR item.tgargs<>(convert_to('U:goods_id','UTF8')||decode('00','hex')) THEN
     RAISE EXCEPTION 'Review the physical stock lifetime trigger before refreshing';
    END IF;
   ELSE
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.fn_capture_goods_code_use(''U:goods_id'')',names[1],tracked.table_name);
   END IF;
   CONTINUE;
  END IF;
  proof_arguments:=format('%L::text[]',specs);
  modes:=ARRAY['O','O','O'];comments:=ARRAY[NULL,NULL,NULL]::text[];
  -- The pre-gate trigger has all three events and supplies their common mode.
  SELECT t.*,obj_description(t.oid,'pg_trigger') original_comment INTO item
  FROM pg_trigger t WHERE t.tgrelid=format('public.%I',tracked.table_name)::regclass AND t.tgname=names[1];
  IF FOUND THEN
   IF item.tgfoid<>'public.fn_capture_goods_code_use()'::regprocedure
    OR (item.tgtype & 3)<>1 OR item.tgconstraint<>0 THEN
    RAISE EXCEPTION 'Review the original goods-code source trigger before refreshing';
   END IF;
   modes:=ARRAY[item.tgenabled::text,item.tgenabled::text,item.tgenabled::text];
   comments:=ARRAY[item.original_comment,item.original_comment,item.original_comment];
  END IF;
  FOR event_number IN 2..3 LOOP
   SELECT t.*,obj_description(t.oid,'pg_trigger') original_comment INTO item
   FROM pg_trigger t WHERE t.tgrelid=format('public.%I',tracked.table_name)::regclass AND t.tgname=names[event_number];
   IF FOUND THEN
    IF item.tgfoid<>'public.fn_capture_goods_code_use()'::regprocedure
     OR (item.tgtype & 3)<>1 OR item.tgconstraint<>0 THEN
     RAISE EXCEPTION 'Review the split goods-code source trigger before refreshing';
    END IF;
    modes[event_number]:=item.tgenabled::text;comments[event_number]:=item.original_comment;
   END IF;
  END LOOP;
  FOR event_number IN 1..3 LOOP
   EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I',names[event_number],tracked.table_name);
   event_name:=CASE event_number WHEN 1 THEN 'INSERT' WHEN 2 THEN 'UPDATE' ELSE 'DELETE' END;
   condition:=CASE
    -- This immutable numeric adoption retains its unconditional original
    -- provenance observer as a separately bounded part of the source audit.
    WHEN event_number=1 AND tracked.table_name='goods_bom_material_cost_adoptions' THEN ''
    WHEN event_number=1 THEN ' WHEN (NOT public.fn_goods_code_use_recorded(NULL,to_jsonb(NEW),'||proof_arguments||'))'
    WHEN event_number=2 THEN ' WHEN (NOT public.fn_goods_code_use_recorded(to_jsonb(OLD),to_jsonb(NEW),'||proof_arguments||'))'
    ELSE ' WHEN (NOT public.fn_goods_code_use_recorded(to_jsonb(OLD),NULL,'||proof_arguments||'))' END;
   EXECUTE format('CREATE TRIGGER %I AFTER %s ON public.%I FOR EACH ROW%s EXECUTE FUNCTION public.fn_capture_goods_code_use(%s)',
    names[event_number],event_name,tracked.table_name,condition,arguments);
   EXECUTE format('ALTER TABLE public.%I %s TRIGGER %I',tracked.table_name,
    CASE modes[event_number] WHEN 'A' THEN 'ENABLE ALWAYS' WHEN 'R' THEN 'ENABLE REPLICA'
     WHEN 'D' THEN 'DISABLE' WHEN 'O' THEN 'ENABLE' ELSE NULL END,names[event_number]);
   IF comments[event_number] IS NOT NULL THEN
    EXECUTE format('COMMENT ON TRIGGER %I ON public.%I IS %L',names[event_number],tracked.table_name,comments[event_number]);
   END IF;
  END LOOP;
 END LOOP;
END $$;
SELECT fn_refresh_goods_code_usage_tracking();
