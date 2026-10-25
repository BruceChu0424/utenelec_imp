-- Reviewed candidate ACL only: no restore, migrations, role/owner changes or business writes.
-- Supply all pins from an independently checked candidate identity, never discover-and-approve
-- them in this script. The ordinary dev callback retains its fixed loopback uten_imp boundary.
-- Example (credentials stay in the operator's existing protected PGPASSFILE):
-- psql -X -v ON_ERROR_STOP=1 -U uten_migrator -d <exact-candidate> \
--   -v expected_database=<exact-candidate> -v expected_database_oid=<exact-OID> \
--   -v expected_system_identifier=<exact-cluster-ID> -v expected_owner=uten_migrator \
--   -v runtime_acl_confirm='RECONCILE CANDIDATE RUNTIME ACL <exact-candidate>' \
--   -f server/ops/reconcile-runtime-privileges.sql
\set ON_ERROR_STOP on
\set ECHO none
\set VERBOSITY terse
\set SHOW_CONTEXT never
\if :{?expected_database}
\else
  DO $$ BEGIN RAISE EXCEPTION 'expected_database is required'; END $$;
\endif
\if :{?expected_database_oid}
\else
  DO $$ BEGIN RAISE EXCEPTION 'expected_database_oid is required'; END $$;
\endif
\if :{?expected_system_identifier}
\else
  DO $$ BEGIN RAISE EXCEPTION 'expected_system_identifier is required'; END $$;
\endif
\if :{?expected_owner}
\else
  DO $$ BEGIN RAISE EXCEPTION 'expected_owner is required'; END $$;
\endif
\if :{?runtime_acl_confirm}
\else
  DO $$ BEGIN RAISE EXCEPTION 'runtime_acl_confirm is required'; END $$;
\endif

BEGIN;
SELECT set_config('uten.runtime_acl.scope_kind','reviewed_candidate',true) AS acl_scope_kind,
       set_config('uten.runtime_acl.expected_database',:'expected_database',true) AS acl_database,
       set_config('uten.runtime_acl.expected_database_oid',:'expected_database_oid',true) AS acl_database_oid,
       set_config('uten.runtime_acl.expected_system_identifier',:'expected_system_identifier',true) AS acl_cluster,
       set_config('uten.runtime_acl.expected_owner',:'expected_owner',true) AS acl_owner,
       set_config('uten.runtime_acl.confirmation',:'runtime_acl_confirm',true) AS acl_confirmation
\gset
-- This relative include is the same resource loaded by LocalRuntimePrivilegesCallback.
-- Do not copy a second protected-object list into this operator entry point.
\ir ../src/main/resources/db/local-runtime-privileges.sql
-- Keep a candidate offline atomically. The temporary canonical CONNECT grant is
-- never visible outside this transaction; an already authenticated verifier may
-- continue, but no new runtime session is admitted after this wrapper commits.
DO $candidate_runtime_quarantine$
BEGIN
    EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC,uten RESTRICT',current_database());
    IF has_database_privilege('uten',current_database(),'CONNECT') THEN
        RAISE EXCEPTION 'Candidate runtime CONNECT remains effective; keep the candidate offline';
    END IF;
END;
$candidate_runtime_quarantine$;
COMMIT;
\echo 'Scope-bound candidate runtime ACL reconciled; new runtime CONNECT remains denied.'
