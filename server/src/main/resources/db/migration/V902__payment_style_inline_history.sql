-- Field-CAS and batch status use the same durable actor history as native forms.
-- Keep every existing route; fail if the expected reviewed function has drifted.
DO $$
DECLARE definition text; inline_anchor text:='WHEN p_method=''PATCH'' AND p_path ~ ''^/api/master/inline-edit/(colors|units|currencies|moulds|accounts|reference-methods|clients|suppliers|warehouses)/[0-9a-fA-F-]{36}$''';
BEGIN
 SELECT pg_get_functiondef('public.fn_master_history_entity(text,text)'::regprocedure) INTO definition;
 IF strpos(definition,inline_anchor)=0 THEN RAISE EXCEPTION 'Cannot extend payment-style inline history routes'; END IF;
 definition:=replace(definition,inline_anchor,
  'WHEN p_method=''PATCH'' AND p_path ~ ''^/api/master/inline-edit/payment-styles/[0-9a-fA-F-]{36}$'' THEN ''payment-styles'' '||inline_anchor);
 definition:=replace(definition,
  'WHEN p_path ~ ''^/api/master/payment-styles(/[0-9a-fA-F-]{36})?$''',
  'WHEN p_path ~ ''^/api/master/payment-styles(/[0-9a-fA-F-]{36}|/batch-status)?$''');
 EXECUTE definition;
END $$;
