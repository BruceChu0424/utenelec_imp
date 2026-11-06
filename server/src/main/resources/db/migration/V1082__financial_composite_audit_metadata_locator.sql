-- New forward only: preserve existing target_id/old audit bytes and all audit/business trigger registrations.
-- Three existing financial metadata PKs need their unchanged parts alongside UPDATE deltas.
DO $verify_financial_locator_basis$
DECLARE rule record;actual_keys text[];probe jsonb;definition text;
BEGIN
 SELECT pg_get_functiondef('public.fn_audit()'::regprocedure) INTO definition;
 IF encode(sha256(convert_to(replace(definition,E'\r\n',E'\n'),'UTF8')),'hex')<>'a2cb82b29fe8e803ec2f2cefe00c8bc8336d52f86869ba275e6be4b553a3c208'
    OR (length(definition)-length(replace(definition,'v_minimized := public.fn_audit_minimize(TG_TABLE_NAME, v_after, v_redacted);','')))/length('v_minimized := public.fn_audit_minimize(TG_TABLE_NAME, v_after, v_redacted);')<>1 THEN
  RAISE EXCEPTION 'Review the actual shared audit writer before adding financial metadata identity';
 END IF;
 IF strpos(pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure),'financial_subversion_private_changes_v1')=0 THEN
  RAISE EXCEPTION 'Existing financial private-change minimization must remain authoritative';
 END IF;
 FOR rule IN SELECT * FROM (VALUES
   ('finance_chart_owned_bindings',ARRAY['code','style_id','line_key']::text[]),
   ('finance_sales_cost_inputs',ARRAY['period','client_id']::text[]),
   ('finance_operating_report_notes',ARRAY['period','line_key']::text[])
 ) expected(table_name,keys) LOOP
  SELECT array_agg(attribute.attname::text ORDER BY item.ordinality) INTO actual_keys
  FROM pg_index index_row JOIN pg_class relation ON relation.oid=index_row.indrelid
  CROSS JOIN LATERAL unnest(index_row.indkey) WITH ORDINALITY item(attnum,ordinality)
  JOIN pg_attribute attribute ON attribute.attrelid=relation.oid AND attribute.attnum=item.attnum
  WHERE relation.relnamespace='public'::regnamespace AND relation.relname=rule.table_name AND relation.relkind='r'
    AND index_row.indisprimary AND item.ordinality<=index_row.indnkeyatts;
  IF actual_keys IS DISTINCT FROM rule.keys OR (rule.keys<@public.fn_finance_audit_metadata_columns(rule.table_name)) IS NOT TRUE THEN
   RAISE EXCEPTION 'Financial locator primary-key/metadata contract changed for %',rule.table_name;
  END IF;
  SELECT jsonb_object_agg(key,'"METADATA-PROBE"'::jsonb) INTO probe FROM unnest(rule.keys) key;
  IF public.fn_audit_minimize(rule.table_name,probe,false) IS DISTINCT FROM probe THEN
   RAISE EXCEPTION 'Financial locator cannot restore private/disallowed key values for %',rule.table_name;
  END IF;
 END LOOP;
END;
$verify_financial_locator_basis$;

-- No pg_catalog or business-row lookup on an audited write. The existing writer
-- still applies its original shared minimizer after this fixed metadata selection.
CREATE FUNCTION public.fn_finance_audit_composite_locator(p_table_name text,p_row jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog AS $$
 SELECT CASE p_table_name
 WHEN 'finance_chart_owned_bindings' THEN jsonb_build_object('code',p_row->'code','style_id',p_row->'style_id','line_key',p_row->'line_key')
 WHEN 'finance_sales_cost_inputs' THEN jsonb_build_object('period',p_row->'period','client_id',p_row->'client_id')
 WHEN 'finance_operating_report_notes' THEN jsonb_build_object('period',p_row->'period','line_key',p_row->'line_key')
 ELSE '{}'::jsonb END;
$$;

DO $add_financial_metadata_locator$
DECLARE definition text;expected text;actual text;
 anchor constant text:='v_minimized := public.fn_audit_minimize(TG_TABLE_NAME, v_after, v_redacted);';
 addition constant text:=$locator$
        -- financial_metadata_composite_locator_v1: unchanged permitted PKs precede existing minimization.
        v_locator := v_locator || (public.fn_finance_audit_composite_locator(TG_TABLE_NAME,v_old)
            - ARRAY(SELECT jsonb_object_keys(v_after)));
        $locator$;
BEGIN
 SELECT pg_get_functiondef('public.fn_audit()'::regprocedure) INTO definition;
 IF encode(sha256(convert_to(replace(definition,E'\r\n',E'\n'),'UTF8')),'hex')<>'a2cb82b29fe8e803ec2f2cefe00c8bc8336d52f86869ba275e6be4b553a3c208'
    OR (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Shared audit writer changed during financial locator verification';
 END IF;
 expected:=replace(definition,anchor,addition||anchor);
 EXECUTE expected;
 SELECT pg_get_functiondef('public.fn_audit()'::regprocedure) INTO actual;
 IF replace(actual,E'\r\n',E'\n') IS DISTINCT FROM replace(expected,E'\r\n',E'\n') THEN
  RAISE EXCEPTION 'Financial locator altered an unreviewed part of the shared audit writer';
 END IF;
END;
$add_financial_metadata_locator$;
