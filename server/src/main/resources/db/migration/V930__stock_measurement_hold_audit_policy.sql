-- Original quantity/value/weight evidence and all existing guards remain unchanged.
-- Existing holds are not rewritten and receive no invented historical audit rows.
-- A hold is not an append-only ledger: its one real resolution changes six fields.

CREATE FUNCTION public.fn_audit_stock_measurement_hold_columns() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    v_locator jsonb;
    v_old jsonb;
    v_new jsonb;
    v_before jsonb;
    v_after jsonb;
    v_redacted text[] := ARRAY[]::text[];
    v_device jsonb;
    v_actor uuid;
    v_account text;
BEGIN
    IF TG_TABLE_SCHEMA <> 'public' OR TG_TABLE_NAME <> 'stock_measurement_holds'
       OR TG_RELID <> 'public.stock_measurement_holds'::regclass THEN
        RAISE EXCEPTION 'Measurement-hold audit projection requires its exact registered table' USING ERRCODE='42501';
    END IF;
    IF current_setting('app.legacy_import',true)='on' THEN RETURN NULL; END IF;

    IF TG_OP='DELETE' THEN
        v_locator := jsonb_build_object('id',OLD.id,'stock_balance_id',OLD.stock_balance_id,
            'warehouse_id',OLD.warehouse_id,'goods_id',OLD.goods_id,'color_id',OLD.color_id);
    ELSE
        v_locator := jsonb_build_object('id',NEW.id,'stock_balance_id',NEW.stock_balance_id,
            'warehouse_id',NEW.warehouse_id,'goods_id',NEW.goods_id,'color_id',NEW.color_id);
    END IF;
    IF TG_OP IN ('UPDATE','DELETE') THEN
        v_old := jsonb_build_object('released_at',OLD.released_at,'verified_unit_id',OLD.verified_unit_id,
            'verified_by',OLD.verified_by,'evidence_sha256',OLD.evidence_sha256);
    END IF;
    IF TG_OP IN ('INSERT','UPDATE') THEN
        v_new := jsonb_build_object('released_at',NEW.released_at,'verified_unit_id',NEW.verified_unit_id,
            'verified_by',NEW.verified_by,'evidence_sha256',NEW.evidence_sha256);
    END IF;
    IF TG_OP='UPDATE' THEN
        SELECT coalesce(jsonb_object_agg(o.key,o.value),'{}'::jsonb),
               coalesce(jsonb_object_agg(n.key,n.value),'{}'::jsonb)
          INTO v_before,v_after FROM jsonb_each(v_new) n JOIN jsonb_each(v_old) o ON o.key=n.key
          WHERE n.value IS DISTINCT FROM o.value;
        IF OLD.evidence_reference IS DISTINCT FROM NEW.evidence_reference THEN
            v_redacted := array_append(v_redacted,'evidence_reference');
        END IF;
        IF OLD.resolution_note IS DISTINCT FROM NEW.resolution_note THEN
            v_redacted := array_append(v_redacted,'resolution_note');
        END IF;
        IF v_after='{}'::jsonb AND cardinality(v_redacted)=0 THEN RETURN NULL; END IF;
        v_before := v_locator||v_before;
        v_after := v_locator||v_after;
    ELSIF TG_OP='INSERT' THEN
        -- This is the actual new capture, not an approval or a copy of money/quantity.
        v_after := v_locator||v_new||jsonb_build_object('reason',NEW.reason,'captured_at',NEW.captured_at);
        IF NEW.evidence_reference IS NOT NULL THEN v_redacted := array_append(v_redacted,'evidence_reference'); END IF;
        IF NEW.resolution_note IS NOT NULL THEN v_redacted := array_append(v_redacted,'resolution_note'); END IF;
    ELSIF TG_OP='DELETE' THEN
        -- V928 rejects deletion. Keep a safe defensive projection if a future policy permits it.
        v_before := v_locator||v_old||jsonb_build_object('reason',OLD.reason,'captured_at',OLD.captured_at);
    ELSE
        RAISE EXCEPTION 'Unsupported measurement-hold audit operation' USING ERRCODE='22023';
    END IF;
    IF cardinality(v_redacted)>0 THEN
        v_after := v_after||jsonb_build_object('_redacted_changes',to_jsonb(v_redacted));
    END IF;
    -- The actual bound actor is retained; verified_by is evidence, never an actor substitute.
    v_actor := NULLIF(current_setting('app.actor_id',true),'')::uuid;
    v_account := NULLIF(current_setting('app.actor_account',true),'');
    IF v_actor IS NULL AND v_account IS NULL THEN v_account := session_user::text; END IF;
    v_device := coalesce(NULLIF(current_setting('app.audit_device_context',true),'')::jsonb,'{}'::jsonb);
    INSERT INTO public.audit_log(
        actor_id,actor_account,action,target_type,target_id,before,"after",ip,user_agent,result,request_id,event_source,
        risk_level,event_category,client_event_id,device_installation_id,device_name,device_manufacturer,device_model,
        device_platform,device_os_version,app_version,app_build,device_form_factor,device_browser,device_locale,
        device_time_zone,device_time_zone_offset_minutes,device_is_physical,client_event_at,device_capture_status,device_profile_hash)
    VALUES(v_actor,public.fn_audit_mask_account(v_account),lower(TG_OP),TG_TABLE_NAME,
        (v_locator->>'id'),v_before,v_after,NULLIF(current_setting('app.audit_ip',true),''),
        NULLIF(current_setting('app.audit_user_agent',true),''),'success',
        NULLIF(current_setting('app.audit_request_id',true),'')::uuid,'database',
        CASE WHEN TG_OP='DELETE' THEN 'high' ELSE 'low' END,'data_change',
        NULLIF(v_device->>'clientEventId','')::uuid,NULLIF(v_device->>'installationId','')::uuid,
        NULLIF(v_device->>'deviceName',''),NULLIF(v_device->>'manufacturer',''),NULLIF(v_device->>'model',''),
        NULLIF(v_device->>'platform',''),NULLIF(v_device->>'osVersion',''),NULLIF(v_device->>'appVersion',''),
        NULLIF(v_device->>'appBuild',''),NULLIF(v_device->>'formFactor',''),NULLIF(v_device->>'browserName',''),
        NULLIF(v_device->>'locale',''),NULLIF(v_device->>'timeZone',''),
        NULLIF(v_device->>'timeZoneOffsetMinutes','')::integer,NULLIF(v_device->>'physicalDevice','')::boolean,
        NULLIF(v_device->>'clientEventAt','')::timestamptz,coalesce(NULLIF(v_device->>'captureStatus',''),'missing'),
        NULLIF(v_device->>'profileHash',''));
    RETURN NULL;
END;
$$;

-- No defaults: all existing 2..7 argument calls still resolve uniquely to the unchanged V830 function.
CREATE FUNCTION public.fn_audit_track_table(
    p_table text,p_policy text,p_category text,p_redacted boolean,p_columns text[],
    p_insert_delete boolean,p_update_fn text,p_row_fn text)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE
    v_table oid;
    v_owner oid;
    v_projection oid;
    v_projection_name text;
    v_trigger record;
    v_row_name text := left('trg_audit_'||p_table,63);
    v_update_name text := left('trg_audit_upd_'||p_table,63);
BEGIN
    IF p_table IS DISTINCT FROM 'stock_measurement_holds'
       OR p_policy IS DISTINCT FROM 'COLUMN_SCOPED' OR p_category IS DISTINCT FROM 'data_change'
       OR p_redacted IS DISTINCT FROM false OR p_insert_delete IS DISTINCT FROM true
       OR p_columns IS DISTINCT FROM ARRAY['released_at','verified_unit_id','verified_by',
           'evidence_reference','evidence_sha256','resolution_note']::text[]
       OR p_update_fn IS DISTINCT FROM 'public.fn_audit_stock_measurement_hold_columns()'
       OR p_row_fn IS DISTINCT FROM 'public.fn_audit_stock_measurement_hold_columns()' THEN
        RAISE EXCEPTION 'Custom row audit requires the reviewed measurement-hold projection' USING ERRCODE='22023';
    END IF;
    SELECT c.oid,c.relowner INTO v_table,v_owner FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname=p_table AND c.relkind IN('r','p') AND NOT c.relispartition;
    SELECT p.oid,format('%I.%I',n.nspname,p.proname) INTO v_projection,v_projection_name
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE p.oid=to_regprocedure('public.fn_audit_stock_measurement_hold_columns()')
        AND n.nspname='public' AND p.proname='fn_audit_stock_measurement_hold_columns'
        AND p.prokind='f' AND p.pronargs=0 AND p.provariadic=0
        AND p.prorettype='trigger'::regtype AND p.proowner=v_owner;
    IF v_table IS NULL OR v_projection IS NULL
       OR to_regprocedure(p_row_fn) IS DISTINCT FROM v_projection
       OR to_regprocedure(p_update_fn) IS DISTINCT FROM v_projection THEN
        RAISE EXCEPTION 'Measurement-hold audit projection OID/type/owner/name does not match' USING ERRCODE='42501';
    END IF;
    -- Re-registration removes only this reviewed projection's own audit names.
    -- Unrelated guards are neither dropped nor disabled.
    FOR v_trigger IN SELECT tgname FROM pg_trigger WHERE tgrelid=v_table AND NOT tgisinternal AND tgparentid=0
        AND tgname IN(v_row_name,v_update_name) AND tgfoid=v_projection LOOP
        EXECUTE format('DROP TRIGGER %I ON public.%I',v_trigger.tgname,p_table);
    END LOOP;
    PERFORM public.fn_audit_track_table(p_table,p_policy,p_category,p_redacted,p_columns,p_insert_delete,p_update_fn);
    EXECUTE format('CREATE OR REPLACE TRIGGER %I AFTER INSERT OR DELETE ON public.%I '
                   'FOR EACH ROW EXECUTE FUNCTION %s()',v_row_name,p_table,v_projection_name);
    EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I',p_table,v_row_name);
END;
$$;
REVOKE ALL ON FUNCTION public.fn_audit_stock_measurement_hold_columns() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_audit_track_table(text,text,text,boolean,text[],boolean,text,text) FROM PUBLIC;
DO $private_projection$
BEGIN
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON FUNCTION public.fn_audit_stock_measurement_hold_columns() FROM uten;
        REVOKE ALL ON FUNCTION public.fn_audit_track_table(text,text,text,boolean,text[],boolean,text,text) FROM uten;
    END IF;
END;
$private_projection$;

SELECT public.fn_audit_track_table('stock_measurement_holds','COLUMN_SCOPED','data_change',false,
    ARRAY['released_at','verified_unit_id','verified_by','evidence_reference','evidence_sha256','resolution_note'],
    true,'public.fn_audit_stock_measurement_hold_columns()','public.fn_audit_stock_measurement_hold_columns()');
