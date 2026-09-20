-- Runtime maintenance must not depend on membership of a schema owner or
-- migration login. This migration changes seven fixed entry points only;
-- deployment removes any old role membership after restricted-login rehearsal.
CREATE FUNCTION public.fn_require_runtime_maintenance(p_reset boolean) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE
    owner_id oid;
    is_administrator boolean;
    actor_text text;
    request_text text;
    uuid_pattern constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
    reserved_names text[] := ARRAY['reset_business_table_policy','reset_business_preserve_counts',
        'reset_business_summary','reset_business_clear_work','reset_business_clear_family'];
BEGIN
    SELECT proowner INTO owner_id FROM pg_catalog.pg_proc
      WHERE oid='public.business_data_reset()'::regprocedure;
    SELECT rolsuper INTO is_administrator FROM pg_catalog.pg_roles WHERE rolname=session_user;
    IF NOT COALESCE(is_administrator,false) AND session_user<>'uten'
       AND NOT pg_catalog.pg_has_role(session_user,owner_id,'MEMBER') THEN
        RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='runtime maintenance caller is not authorized';
    END IF;
    IF NOT p_reset THEN RETURN; END IF;
    -- The existing reset creates and replaces only these fixed temp tables.
    -- A persistent namesake must never be dropped or interpreted as policy.
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_class relation
              JOIN pg_catalog.pg_namespace namespace ON namespace.oid=relation.relnamespace
              WHERE namespace.nspname='public' AND relation.relname=ANY(reserved_names))
       OR EXISTS(SELECT 1 FROM pg_catalog.pg_class relation
                 WHERE relation.relnamespace=pg_catalog.pg_my_temp_schema()
                   AND relation.relname=ANY(reserved_names) AND relation.relowner<>owner_id) THEN
        RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='reset maintenance namespace contains an unexpected relation';
    END IF;
    -- Database administrators retain their existing maintenance authority.
    -- The ordinary runtime login must carry the same real active super-admin
    -- identity that the application authenticates and binds for audit.
    IF COALESCE(is_administrator,false) OR session_user<>'uten' THEN RETURN; END IF;
    actor_text:=NULLIF(current_setting('app.actor_id',true),'');
    request_text:=NULLIF(current_setting('app.audit_request_id',true),'');
    IF actor_text IS NULL OR actor_text !~ uuid_pattern
       OR request_text IS NULL OR request_text !~ uuid_pattern
       OR NOT EXISTS(SELECT 1 FROM public.users actor WHERE actor.id=actor_text::uuid
           AND actor.is_super_admin AND actor.status='active' AND NOT actor.is_deleted
           AND actor.login_account=current_setting('app.actor_account',true)) THEN
        RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='business reset requires an authenticated active super-admin audit identity';
    END IF;
END; $$;
REVOKE ALL ON FUNCTION public.fn_require_runtime_maintenance(boolean) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.refresh_finance_ar_ap_mv() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    PERFORM public.fn_require_runtime_maintenance(false);
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.finance_ar_ap_mv;
END; $$;
CREATE OR REPLACE FUNCTION public.refresh_production_monthly_mv() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    PERFORM public.fn_require_runtime_maintenance(false);
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.production_monthly_mv;
END; $$;
CREATE OR REPLACE FUNCTION public.refresh_purchase_monthly_mv() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    PERFORM public.fn_require_runtime_maintenance(false);
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.purchase_monthly_mv;
END; $$;
CREATE OR REPLACE FUNCTION public.refresh_sales_monthly_mv() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    PERFORM public.fn_require_runtime_maintenance(false);
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.sales_monthly_mv;
END; $$;
CREATE OR REPLACE FUNCTION public.refresh_stock_monthly_mv() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    PERFORM public.fn_require_runtime_maintenance(false);
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.stock_monthly_mv;
END; $$;
CREATE OR REPLACE FUNCTION public.refresh_subcontract_monthly_mv() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    PERFORM public.fn_require_runtime_maintenance(false);
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.subcontract_monthly_mv;
END; $$;

-- Preserve the complete, already migrated reset implementation, including every
-- current CLEAR/PRESERVE row, refusal condition, final check and session epoch.
-- Only insert the checked entry guard; do not recreate an older reset body.
DO $reset_entry$
DECLARE body text; anchor text := E'BEGIN\n    -- 防御：同事务重试/残留时先清掉旧临时表（ON COMMIT DROP 正常情况下已清理）。';
BEGIN
    SELECT replace(prosrc,E'\r\n',E'\n') INTO body FROM pg_catalog.pg_proc
      WHERE oid='public.business_data_reset()'::regprocedure
        AND NOT prosecdef AND pronargs=0 AND proretset;
    IF body IS NULL OR (length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V625 cannot preserve the current business reset implementation safely';
    END IF;
    body:=replace(body,anchor,E'BEGIN\n    PERFORM public.fn_require_runtime_maintenance(true);\n'
        || substring(anchor FROM length(E'BEGIN\n')+1));
    EXECUTE format('CREATE OR REPLACE FUNCTION public.business_data_reset() '
        'RETURNS TABLE(cleared_table_count int,cleared_rows bigint,preserved_table_count int,authorization_epoch_after bigint) '
        'LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS %L',body);
END;
$reset_entry$;

DO $privileges$
DECLARE signature text; function_id oid; owner_id oid; grantee_name text;
BEGIN
    FOREACH signature IN ARRAY ARRAY['public.refresh_finance_ar_ap_mv()','public.refresh_production_monthly_mv()',
        'public.refresh_purchase_monthly_mv()','public.refresh_sales_monthly_mv()',
        'public.refresh_stock_monthly_mv()','public.refresh_subcontract_monthly_mv()','public.business_data_reset()'] LOOP
        function_id:=signature::regprocedure;
        SELECT proowner INTO owner_id FROM pg_catalog.pg_proc WHERE oid=function_id;
        IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE oid=owner_id AND rolname='uten' AND NOT rolsuper) THEN
            RAISE EXCEPTION 'V625 runtime maintenance entry cannot be owned by the ordinary application login';
        END IF;
        -- CREATE OR REPLACE retains the old entry owner. A previous hardening
        -- may have assigned it to uten_owner while this new helper is created
        -- by uten_migrator; ownership membership is deliberately one-way.
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.fn_require_runtime_maintenance(boolean) TO %I',
            pg_catalog.pg_get_userbyid(owner_id));
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',signature);
        FOR grantee_name IN SELECT DISTINCT role.rolname
            FROM pg_catalog.pg_proc function
            CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(function.proacl,pg_catalog.acldefault('f',function.proowner))) acl
            JOIN pg_catalog.pg_roles role ON role.oid=acl.grantee
            WHERE function.oid=function_id AND role.oid<>owner_id AND role.rolname<>'uten' LOOP
            EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I',signature,grantee_name);
        END LOOP;
        IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten') THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO uten',signature);
        END IF;
    END LOOP;
    -- The helper performs checks only and is invoked with its entry's owner
    -- privileges. No direct runtime grant is needed, including under default ACLs.
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON FUNCTION public.fn_require_runtime_maintenance(boolean) FROM uten;
    END IF;
END;
$privileges$;
