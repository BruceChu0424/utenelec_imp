-- Staging is a separate location. Its version need not equal the preserved FINAL version.
-- Protect all retained master-reference families; do not exempt arbitrary successful tasks.
CREATE OR REPLACE FUNCTION public.fn_business_test_object_protected(p_provider text,p_location text,p_key text,p_version text)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $function$
    SELECT EXISTS(
      SELECT 1 FROM attachments a WHERE upper(btrim(a.owner_type)) IN('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT')
        AND a.storage_key=p_key AND (a.storage_provider=p_provider OR a.storage_provider='legacy_unknown')
        AND (p_location='STAGING' OR p_version IS NULL OR p_provider='local' OR a.storage_version IS NULL OR a.storage_version IS NOT DISTINCT FROM p_version)
      UNION ALL
      SELECT 1 FROM attachment_upload_sessions s WHERE upper(btrim(s.owner_type)) IN('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT')
        AND s.storage_key=p_key AND (s.storage_provider=p_provider OR s.storage_provider='legacy_unknown')
      UNION ALL
      SELECT 1 FROM sales_quote_template_versions v WHERE v.storage_provider=p_provider AND v.storage_key=p_key
        AND (p_location='STAGING' OR (p_location='FINAL' AND (p_version IS NULL OR p_provider='local' OR v.storage_version IS NOT DISTINCT FROM p_version)))
      UNION ALL
      SELECT 1 FROM goods_cost_imports g WHERE (g.storage_provider=p_provider OR g.storage_provider='legacy_unknown') AND g.storage_key=p_key
        AND (p_location='STAGING' OR (p_location='FINAL' AND (p_version IS NULL OR p_provider='local' OR g.storage_version IS NULL OR g.storage_version IS NOT DISTINCT FROM p_version)))
    )
$function$;

-- This queue has both business and master sources. Preserve master cleanup facts,
-- even when a source-less historical task has no attachment/session FK left.
DO $protect_master_cleanup_history$
DECLARE definition text; anchor text:='AND s.source_id=operation.id::text)';
BEGIN
    SELECT pg_get_functiondef('public.fn_clear_business_test_object_metadata()'::regprocedure) INTO definition;
    IF strpos(definition,'DELETE FROM public.attachment_object_outbox operation WHERE EXISTS(')=0
       OR (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V783 cannot preserve exact mixed-owner test cleanup';
    END IF;
    -- The existing view excludes master owners and derives known owner only from the actual source FK.
    -- A known business relation can retire its task metadata while its shared master bytes remain.
    -- A source-less UNKNOWN task protected by a master reference remains an unchanged historical fact.
    EXECUTE replace(definition,anchor,'AND s.source_id=operation.id::text AND (upper(btrim(s.owner_type))<>''UNKNOWN'' OR NOT public.fn_business_test_object_protected(operation.storage_provider,CASE WHEN operation.operation=''DELETE_STAGING'' THEN ''STAGING'' ELSE ''FINAL'' END,operation.storage_key,operation.storage_version)))');
END $protect_master_cleanup_history$;
