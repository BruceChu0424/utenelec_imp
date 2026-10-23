-- Launch hardening: no runtime account can execute the destructive reset entry.
-- Preserve the implementation for isolated local development and historical audit.
-- This migration changes privileges only; it never invokes the reset function.
DO $retire_business_reset$
DECLARE
    entry oid := 'public.business_data_reset()'::regprocedure;
    owner_id oid;
    grantee_name text;
BEGIN
    SELECT proowner INTO STRICT owner_id FROM pg_catalog.pg_proc WHERE oid = entry;
    REVOKE ALL ON FUNCTION public.business_data_reset() FROM PUBLIC;
    FOR grantee_name IN
        SELECT DISTINCT role.rolname
        FROM pg_catalog.pg_proc function
        CROSS JOIN LATERAL pg_catalog.aclexplode(
            COALESCE(function.proacl, pg_catalog.acldefault('f', function.proowner))) acl
        JOIN pg_catalog.pg_roles role ON role.oid = acl.grantee
        WHERE function.oid = entry AND role.oid <> owner_id
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION public.business_data_reset() FROM %I', grantee_name);
    END LOOP;
    -- A runtime account owning the function or inheriting its owner would bypass
    -- REVOKE; fail rather than claim that this server has been made safe.
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'uten')
       AND pg_catalog.has_function_privilege('uten', entry, 'EXECUTE') THEN
        RAISE EXCEPTION 'V915: runtime role uten still inherits business reset authority; separate owner and runtime roles first';
    END IF;
END;
$retire_business_reset$;
