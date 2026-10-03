-- Restore guarded permanent capability; never certify an unknown installed runner.
DO $verified_permanent_capability$
DECLARE fingerprint text;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang
        WHERE p.oid=to_regprocedure('public.fn_audit_retention_run()')
          AND md5(replace(p.prosrc,E'\r\n',E'\n'))='9fd5dacf26868b27dc46f2308742e317'
          AND p.prosecdef AND l.lanname='plpgsql' AND p.provolatile='v'
          AND cardinality(p.proconfig)=2
          AND p.proconfig @> ARRAY['search_path=pg_catalog, public, pg_temp','lock_timeout=5s']) THEN
        RAISE EXCEPTION 'V786 requires the verified V770 retention runner definition and protection settings' USING ERRCODE='55000';
    END IF;
    SELECT md5(replace(p.prosrc,E'\r\n',E'\n')||':'||p.proconfig::text||':'||p.prosecdef::text)
      INTO STRICT fingerprint FROM pg_proc p WHERE p.oid='public.fn_audit_retention_run()'::regprocedure;
    EXECUTE format($definition$
      CREATE OR REPLACE FUNCTION public.fn_audit_retention_purge_mode() RETURNS text LANGUAGE sql STABLE
      SET search_path=pg_catalog,public,pg_temp AS $mode$
      SELECT COALESCE((SELECT CASE WHEN md5(replace(p.prosrc,E'\r\n',E'\n')||':'||COALESCE(p.proconfig::text,'')||':'||p.prosecdef::text)=%L
        THEN 'PERMANENT_RETAIN' ELSE 'UNKNOWN' END FROM pg_proc p
        WHERE p.oid=to_regprocedure('public.fn_audit_retention_run()')),'UNKNOWN')
      $mode$
    $definition$,fingerprint);
END $verified_permanent_capability$;
GRANT EXECUTE ON FUNCTION public.fn_audit_retention_purge_mode() TO PUBLIC;
