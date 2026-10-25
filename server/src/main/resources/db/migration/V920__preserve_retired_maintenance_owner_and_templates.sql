-- Complete the V919 retirement without changing any applied migration bytes.
-- The original reset owner is gone. Only direct pre-919 catalog capture on this
-- migration connection, or explicit externally proven fresh/single-owner 919
-- initialization, can establish it. Never infer it from a finance refresh owner.
CREATE TEMP TABLE v920_owner_authority(proof jsonb NOT NULL,owner_oid oid NOT NULL,helper_before_oid oid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE v920_refresh_security_before ON COMMIT DROP AS
SELECT p.oid,p.proowner,p.proacl,p.prosecdef,p.proconfig,md5(pg_get_functiondef(p.oid)) definition_md5
FROM pg_proc p WHERE p.oid=ANY(ARRAY[
 'public.refresh_finance_ar_ap_mv()'::regprocedure,'public.refresh_production_monthly_mv()'::regprocedure,
 'public.refresh_purchase_monthly_mv()'::regprocedure,'public.refresh_sales_monthly_mv()'::regprocedure,
 'public.refresh_stock_monthly_mv()'::regprocedure,'public.refresh_subcontract_monthly_mv()'::regprocedure]);

DO $owner_proof$
DECLARE proof jsonb;helper record;owner_name text;database_owner oid;
BEGIN
 proof:=NULLIF(current_setting('uten.retired_refresh_owner_evidence',true),'')::jsonb;
 IF proof IS NULL OR jsonb_typeof(proof) IS DISTINCT FROM 'object' THEN
  RAISE EXCEPTION 'V920 requires a source-bound maintenance owner proof; the deleted reset owner cannot be inferred' USING ERRCODE='23514';
 END IF;
 SELECT datdba INTO STRICT database_owner FROM pg_database WHERE datname=current_database();
 IF proof->>'format' IS DISTINCT FROM 'uten-retired-refresh-owner-v1'
 OR proof->>'database_name' IS DISTINCT FROM current_database()
 OR (proof->>'database_oid')::oid IS DISTINCT FROM (SELECT oid FROM pg_database WHERE datname=current_database())
 OR proof->>'system_identifier' IS DISTINCT FROM (SELECT system_identifier::text FROM pg_control_system())
 OR (proof->>'backend_pid')::integer IS DISTINCT FROM pg_backend_pid()
 OR proof->>'session_user' IS DISTINCT FROM session_user
 OR (proof->>'database_owner_oid')::oid IS DISTINCT FROM database_owner
 OR to_regprocedure('public.business_data_reset()') IS NOT NULL THEN
  RAISE EXCEPTION 'V920 owner proof belongs to another connection, database or retirement state' USING ERRCODE='23514';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM flyway_schema_history WHERE version='919' AND success
       AND script='V919__remove_business_data_reset.sql' AND checksum=-844362970) THEN
  RAISE EXCEPTION 'V920 requires the exact original applied V919 history; repair or rewritten bytes are not accepted' USING ERRCODE='23514';
 END IF;
 SELECT p.oid,p.proowner,p.prosrc,p.prosecdef,p.proconfig INTO STRICT helper FROM pg_proc p
  WHERE p.oid='public.fn_require_runtime_refresh()'::regprocedure;
 IF helper.prosecdef OR helper.proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog, public, pg_temp']::text[]
 OR btrim(replace(helper.prosrc,E'\r\n',E'\n'),E'\r\n') NOT IN (
$original_body$DECLARE owner_id oid; is_administrator boolean;
BEGIN
    SELECT proowner INTO STRICT owner_id FROM pg_catalog.pg_proc
      WHERE oid = 'public.refresh_finance_ar_ap_mv()'::regprocedure;
    SELECT rolsuper INTO is_administrator FROM pg_catalog.pg_roles WHERE rolname = session_user;
    IF NOT COALESCE(is_administrator, false) AND session_user <> 'uten'
       AND NOT pg_catalog.pg_has_role(session_user, owner_id, 'MEMBER') THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'runtime maintenance caller is not authorized';
    END IF;
END;$original_body$,
$self_body$DECLARE owner_id oid; is_administrator boolean;
BEGIN
    SELECT proowner INTO STRICT owner_id FROM pg_catalog.pg_proc
      WHERE oid = 'public.fn_require_runtime_refresh()'::regprocedure;
    SELECT rolsuper INTO is_administrator FROM pg_catalog.pg_roles WHERE rolname = session_user;
    IF NOT COALESCE(is_administrator, false) AND session_user <> 'uten'
       AND NOT pg_catalog.pg_has_role(session_user, owner_id, 'MEMBER') THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'runtime maintenance caller is not authorized';
    END IF;
END;$self_body$) THEN
  RAISE EXCEPTION 'V920 refresh helper differs from the reviewed V919 body/security attributes' USING ERRCODE='23514';
 END IF;
 SELECT rolname INTO STRICT owner_name FROM pg_roles WHERE oid=(proof->>'owner_oid')::oid;
 IF owner_name IS DISTINCT FROM proof->>'owner_name' OR owner_name='uten' THEN
  RAISE EXCEPTION 'V920 original maintenance owner identity is unavailable or is the runtime login' USING ERRCODE='23514';
 END IF;
 IF proof->>'kind'='PRE_919_DIRECT_CATALOG' THEN
  IF COALESCE((proof->>'old_reset_oid')::bigint,0)<=0 OR COALESCE(proof->>'old_reset_definition_md5','')!~'^[0-9a-f]{32}$' THEN
   RAISE EXCEPTION 'V920 direct owner capture lacks the original function identity' USING ERRCODE='23514';
  END IF;
 ELSIF proof->>'kind'='VERIFIED_FRESH_919_INITIALIZATION' THEN
  -- This fallback is deliberately limited to the proven dedicated single-owner
  -- fresh bootstrap. It is not a recovery heuristic for an arbitrary old 919.
  IF session_user<>'uten_migrator' OR current_user<>session_user OR owner_name<>session_user
  OR helper.proowner IS DISTINCT FROM database_owner OR helper.proowner IS DISTINCT FROM (proof->>'owner_oid')::oid
  OR EXISTS(SELECT 1 FROM v920_refresh_security_before WHERE proowner<>helper.proowner)
  OR EXISTS(SELECT 1 FROM pg_roles WHERE rolname=session_user AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls))
  OR COALESCE(proof->>'source_evidence_sha256','')!~'^[0-9a-f]{64}$'
  OR COALESCE(proof->>'original_source_freeze_sha256','')!~'^[0-9a-f]{64}$'
  OR proof->>'applied_v919_sha256' IS DISTINCT FROM '701c9c2109d89960b33823bb3e1a89a30c63d90a242ec74c21d24e6c414266c2'
  OR COALESCE((proof->>'schema_head')::integer,0)<>919 OR COALESCE((proof->>'migration_count')::integer,0)<>845
  OR (SELECT count(*) FROM flyway_schema_history WHERE success AND version IS NOT NULL)<>845
  OR (SELECT max(version::numeric) FROM flyway_schema_history WHERE success AND version IS NOT NULL)<>919 THEN
   RAISE EXCEPTION 'V920 existing-919 owner fallback lacks proven fresh single-owner initialization' USING ERRCODE='23514';
  END IF;
 ELSE
  RAISE EXCEPTION 'V920 does not accept an inferred or unrecognized maintenance owner proof' USING ERRCODE='23514';
 END IF;
 INSERT INTO v920_owner_authority VALUES(proof,(proof->>'owner_oid')::oid,helper.proowner);
END;
$owner_proof$;

CREATE OR REPLACE FUNCTION public.fn_require_runtime_refresh() RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $function$
DECLARE owner_id oid; is_administrator boolean;
BEGIN
    SELECT proowner INTO STRICT owner_id FROM pg_catalog.pg_proc
      WHERE oid = 'public.fn_require_runtime_refresh()'::regprocedure;
    SELECT rolsuper INTO is_administrator FROM pg_catalog.pg_roles WHERE rolname = session_user;
    IF NOT COALESCE(is_administrator, false) AND session_user <> 'uten'
       AND NOT pg_catalog.pg_has_role(session_user, owner_id, 'MEMBER') THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'runtime maintenance caller is not authorized';
    END IF;
END;
$function$;

DO $preserve_exact_owner$
DECLARE authority record;owner_name text;entry record;
BEGIN
 SELECT * INTO STRICT authority FROM v920_owner_authority;
 SELECT rolname INTO STRICT owner_name FROM pg_roles WHERE oid=authority.owner_oid;
 EXECUTE format('ALTER FUNCTION public.fn_require_runtime_refresh() OWNER TO %I',owner_name);
 REVOKE ALL ON FUNCTION public.fn_require_runtime_refresh() FROM PUBLIC;
 -- Re-grant the existing definer entry owners after the ownership change, as
 -- original-owner ACL entries can be rewritten by ALTER OWNER itself.
 FOR entry IN SELECT DISTINCT proowner FROM v920_refresh_security_before LOOP
  EXECUTE format('GRANT EXECUTE ON FUNCTION public.fn_require_runtime_refresh() TO %I',pg_get_userbyid(entry.proowner));
 END LOOP;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN
  REVOKE ALL ON FUNCTION public.fn_require_runtime_refresh() FROM uten;
  IF has_function_privilege('uten','public.fn_require_runtime_refresh()','EXECUTE') THEN
   RAISE EXCEPTION 'V920 runtime login still inherits the private refresh helper' USING ERRCODE='23514';
  END IF;
 END IF;
 IF (SELECT proowner FROM pg_proc WHERE oid='public.fn_require_runtime_refresh()'::regprocedure) IS DISTINCT FROM authority.owner_oid
 OR EXISTS(SELECT 1 FROM v920_refresh_security_before before_row JOIN pg_proc actual ON actual.oid=before_row.oid
  WHERE (actual.proowner,actual.proacl,actual.prosecdef,actual.proconfig,md5(pg_get_functiondef(actual.oid)))
    IS DISTINCT FROM (before_row.proowner,before_row.proacl,before_row.prosecdef,before_row.proconfig,before_row.definition_md5)) THEN
  RAISE EXCEPTION 'V920 changed a refresh entry or failed to preserve the proved owner boundary' USING ERRCODE='23514';
 END IF;
 EXECUTE format('COMMENT ON FUNCTION public.fn_require_runtime_refresh() IS %L',
  'Refresh-only maintenance authority preserved by V920 owner proof: '||(authority.proof->>'kind'));
END;
$preserve_exact_owner$;

-- Editable active templates are current configuration. Deleted historical
-- snapshots and every unrelated code/field stay unchanged; normal revision
-- and audit triggers run. No current grants or authorization epochs are changed.
LOCK TABLE public.permission_templates IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE v920_templates_before ON COMMIT DROP AS
SELECT id,is_deleted,permission_codes,row_version,to_jsonb(template) payload FROM permission_templates template;
UPDATE public.permission_templates
SET permission_codes=permission_codes-'system:business_data_reset',row_version=row_version+1,updated_at=now()
WHERE NOT is_deleted AND permission_codes ? 'system:business_data_reset';
DO $verify_templates$
BEGIN
 IF EXISTS(SELECT 1 FROM v920_templates_before prior FULL JOIN permission_templates current_row USING(id)
  WHERE prior.id IS NULL OR current_row.id IS NULL
   OR CASE WHEN NOT prior.is_deleted AND prior.permission_codes ? 'system:business_data_reset'
      THEN current_row.permission_codes IS DISTINCT FROM prior.permission_codes-'system:business_data_reset'
        OR current_row.row_version<>prior.row_version+1
        OR to_jsonb(current_row)-ARRAY['permission_codes','row_version','updated_at'] IS DISTINCT FROM prior.payload-ARRAY['permission_codes','row_version','updated_at']
      ELSE to_jsonb(current_row) IS DISTINCT FROM prior.payload END) THEN
  RAISE EXCEPTION 'V920 template cleanup changed a historical snapshot or unrelated configuration' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM permission_templates WHERE NOT is_deleted AND permission_codes ? 'system:business_data_reset') THEN
  RAISE EXCEPTION 'V920 active template still contains the retired permission code' USING ERRCODE='23514';
 END IF;
END;
$verify_templates$;
