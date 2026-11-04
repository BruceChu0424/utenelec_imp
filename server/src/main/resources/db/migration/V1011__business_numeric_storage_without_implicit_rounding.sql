-- Numeric typmods coerce/round BEFORE CHECK or row triggers can inspect the raw
-- value. Widen ordinary storage, preserving existing values, dependent views, ACLs and
-- triggers through the one existing migration utility. This never recalculates
-- or "repairs" historical business amounts.
DO $business_numeric_storage$
DECLARE definition text;targets jsonb;count integer;
BEGIN
 SELECT pg_get_functiondef('fn_migrate_financial_amount_columns(jsonb)'::regprocedure) INTO definition;
 -- One bounded whole-catalog pass avoids repeatedly rebuilding the same view
 -- graph for hundreds of small batches. Existing callers retain their contract.
 IF position('NOT BETWEEN 1 AND 200' IN definition)>0 THEN
  EXECUTE replace(definition,'NOT BETWEEN 1 AND 200','NOT BETWEEN 1 AND 4096');
 END IF;
 SELECT jsonb_agg(jsonb_build_object('table',relation.relname,'column',attribute.attname,
     'kind',CASE WHEN attribute.attname LIKE '%local%' OR attribute.attname IN('amount','amount_balance','amount_settled','exchange_diff','exchange_difference')THEN 'book' ELSE 'actual' END)
     ORDER BY relation.relname,attribute.attnum),count(*)
 INTO targets,count
 FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
 JOIN pg_attribute attribute ON attribute.attrelid=relation.oid AND attribute.attnum>0 AND NOT attribute.attisdropped
 WHERE namespace.nspname='public' AND relation.relkind='r'
   AND attribute.atttypid='numeric'::regtype AND attribute.atttypmod>=0
   AND attribute.attgenerated=''
   AND NOT EXISTS(SELECT 1 FROM pg_depend dependency
     JOIN pg_attrdef generation ON dependency.classid='pg_attrdef'::regclass AND dependency.objid=generation.oid
     JOIN pg_attribute generated ON generated.attrelid=generation.adrelid AND generated.attnum=generation.adnum
     WHERE dependency.refclassid='pg_class'::regclass AND dependency.refobjid=attribute.attrelid
       AND dependency.refobjsubid=attribute.attnum AND generated.attgenerated<>'');
 -- Generated source/derived families require a separate source-aware migration.
 -- Recreating a generated expression can recalculate old rows. Do not drop that
 -- dependency or silently claim these columns have already been migrated.
 IF count>4096 THEN RAISE EXCEPTION 'Review business numeric catalog before widening more than 4096 columns';END IF;
 IF targets IS NOT NULL THEN PERFORM fn_migrate_financial_amount_columns(targets);END IF;
END; $business_numeric_storage$;

-- Remove only the implicit typmod coercion from local declarations/casts in the
-- current installed functions. Explicit arithmetic rules are audited separately
-- and must use fn_business_exact_divide with the user's request choice.
DO $business_numeric_locals$
DECLARE item record;changed text;
BEGIN
 FOR item IN SELECT proc.oid,pg_get_functiondef(proc.oid) definition FROM pg_proc proc
   JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
   WHERE namespace.nspname='public' AND proc.prokind='f'
     AND proc.proname NOT IN('fn_migrate_financial_amount_columns') LOOP
  changed:=regexp_replace(item.definition,'\mnumeric\s*\(\s*[0-9]+\s*,\s*[0-9]+\s*\)','numeric','gi');
  IF changed<>item.definition THEN EXECUTE changed;END IF;
 END LOOP;
END; $business_numeric_locals$;
