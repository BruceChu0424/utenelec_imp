-- Prepare ONE DISPOSABLE, ISOLATED LOCAL DEVELOPMENT PostgreSQL instance.
-- Never run this against the existing shared development/import cluster or a server.
-- This is an operator script, not a Flyway migration. No business function is called.
--
-- Required psql arguments:
--   -X -v ON_ERROR_STOP=1 -v local_dev_confirm='PREPARE LOCAL uten_imp'
--   -v expected_system_identifier=<the independently checked decimal identifier>
--   -d uten_imp -f ops/prepare-local-postgres-roles.sql
-- Required environment variables (20-512 ASCII alphanumeric, all different):
--   UTEN_LOCAL_ADMIN_PASSWORD, UTEN_LOCAL_MIGRATOR_PASSWORD,
--   UTEN_LOCAL_RUNTIME_PASSWORD
--
-- Create the NEW instance with POSTGRES_USER=uten_dev_admin. Run this script
-- before restore, restore with --no-owner --no-privileges --role uten_migrator,
-- and run this script again afterwards. Preserve the original instance and dump.
-- A cluster bootstrapped as uten (OID 10) is deliberately refused: PostgreSQL
-- pins its system ownership and cannot safely REASSIGN that bootstrap identity.
-- No role rename, system-catalog update, DROP OWNED, reset or shared-DB rewrite
-- is an acceptable shortcut. The original runtime password is changed only in
-- this explicitly confirmed isolated instance, to UTEN_LOCAL_RUNTIME_PASSWORD.

\set ON_ERROR_STOP on
\set ECHO none
\set VERBOSITY terse
\set SHOW_CONTEXT never
\if :{?local_dev_confirm}
\else
  DO $$ BEGIN RAISE EXCEPTION 'Refused: local_dev_confirm is required'; END $$;
\endif
\if :{?expected_system_identifier}
\else
  DO $$ BEGIN RAISE EXCEPTION 'Refused: expected_system_identifier is required'; END $$;
\endif
-- A failed earlier \i run must not supply stale psql variables when an env
-- variable is absent on a later attempt.
\unset _local_admin_password
\unset _local_migrator_password
\unset _local_runtime_password
\getenv _local_admin_password UTEN_LOCAL_ADMIN_PASSWORD
\getenv _local_migrator_password UTEN_LOCAL_MIGRATOR_PASSWORD
\getenv _local_runtime_password UTEN_LOCAL_RUNTIME_PASSWORD
\if :{?_local_admin_password}
\else
  DO $$ BEGIN RAISE EXCEPTION 'Refused: UTEN_LOCAL_ADMIN_PASSWORD is required'; END $$;
\endif
\if :{?_local_migrator_password}
\else
  DO $$ BEGIN RAISE EXCEPTION 'Refused: UTEN_LOCAL_MIGRATOR_PASSWORD is required'; END $$;
\endif
\if :{?_local_runtime_password}
\else
  DO $$ BEGIN RAISE EXCEPTION 'Refused: UTEN_LOCAL_RUNTIME_PASSWORD is required'; END $$;
\endif

BEGIN;
SET LOCAL search_path = pg_catalog, public;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- Privilege and identity checks precede ALL catalog/role/ACL mutations. Session
-- logging is suppressed before any password is interpolated by psql. These
-- settings are transaction-local; never print a generated CREATE/ALTER ROLE.
DO $local_admin_preflight$
BEGIN
    IF current_database() <> 'uten_imp' THEN
        RAISE EXCEPTION 'Refused: the target database must be exactly uten_imp';
    END IF;
    IF session_user NOT IN ('uten_dev_admin', 'uten', 'postgres')
       OR current_user <> session_user
       OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = session_user AND rolsuper) THEN
        RAISE EXCEPTION 'Refused: a direct recognized local administrator superuser login is required';
    END IF;
END;
$local_admin_preflight$;
SET LOCAL log_statement = 'none';
SET LOCAL log_min_duration_statement = -1;
SET LOCAL log_duration = off;
SET LOCAL log_min_error_statement = 'panic';
SET LOCAL log_parameter_max_length = 0;
SET LOCAL log_parameter_max_length_on_error = 0;

SELECT set_config('uten.local_dev_confirm', :'local_dev_confirm', true) AS local_confirm,
       set_config('uten.local_expected_system_identifier', :'expected_system_identifier', true) AS local_identity,
       set_config('uten.local_admin_password', :'_local_admin_password', true) AS local_admin,
       set_config('uten.local_migrator_password', :'_local_migrator_password', true) AS local_migrator,
       set_config('uten.local_runtime_password', :'_local_runtime_password', true) AS local_runtime
\gset
\unset _local_admin_password
\unset _local_migrator_password
\unset _local_runtime_password
\unset local_admin
\unset local_migrator
\unset local_runtime

DO $local_instance_preflight$
DECLARE runtime_id oid; namespace record;
BEGIN
    IF current_setting('uten.local_dev_confirm') <> 'PREPARE LOCAL uten_imp' THEN
        RAISE EXCEPTION 'Refused: local_dev_confirm must be PREPARE LOCAL uten_imp';
    END IF;
    IF current_setting('uten.local_expected_system_identifier') !~ '^[0-9]+$'
       OR current_setting('uten.local_expected_system_identifier') <>
          (SELECT system_identifier::text FROM pg_control_system()) THEN
        RAISE EXCEPTION 'Refused: expected_system_identifier does not identify this instance';
    END IF;
    IF length(current_setting('uten.local_admin_password')) NOT BETWEEN 20 AND 512
       OR current_setting('uten.local_admin_password') !~ '^[A-Za-z0-9]+$'
       OR length(current_setting('uten.local_migrator_password')) NOT BETWEEN 20 AND 512
       OR current_setting('uten.local_migrator_password') !~ '^[A-Za-z0-9]+$'
       OR length(current_setting('uten.local_runtime_password')) NOT BETWEEN 20 AND 512
       OR current_setting('uten.local_runtime_password') !~ '^[A-Za-z0-9]+$'
       OR current_setting('uten.local_admin_password') = current_setting('uten.local_migrator_password')
       OR current_setting('uten.local_admin_password') = current_setting('uten.local_runtime_password')
       OR current_setting('uten.local_migrator_password') = current_setting('uten.local_runtime_password') THEN
        RAISE EXCEPTION 'Refused: three different 20-512 character alphanumeric passwords are required';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres', 'uten_imp')) THEN
        RAISE EXCEPTION 'Refused: this is not an isolated single-business-database instance';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datid IS NOT NULL)
       OR EXISTS (SELECT 1 FROM pg_prepared_xacts)
       OR EXISTS (SELECT 1 FROM pg_replication_slots) THEN
        RAISE EXCEPTION 'Refused: other database sessions, prepared transactions or replication slots exist';
    END IF;
    IF NOT pg_try_advisory_xact_lock(8285574126285519::bigint) THEN
        RAISE EXCEPTION 'Refused: another local role preparation is running';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname !~ '^pg_'
               AND rolname NOT IN ('postgres', 'uten', 'uten_migrator', 'uten_dev_admin')) THEN
        RAISE EXCEPTION 'Refused: unreviewed roles exist in this instance';
    END IF;
    -- Never prune membership edges: NOINHERIT alone does not prevent SET ROLE.
    IF EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid IN (m.member, m.roleid)
               WHERE r.rolname IN ('uten', 'uten_migrator', 'uten_dev_admin')) THEN
        RAISE EXCEPTION 'Refused: runtime or maintenance roles have unreviewed memberships';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole,
                      LATERAL unnest(s.setconfig) setting
               WHERE r.rolname IN ('uten', 'uten_migrator', 'uten_dev_admin') AND setting LIKE 'role=%') THEN
        RAISE EXCEPTION 'Refused: a prepared role has a configured SET ROLE override';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'uten_dev_admin' AND NOT rolsuper)
       OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'uten_migrator'
                  AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
        RAISE EXCEPTION 'Refused: existing maintenance roles do not match the isolated local role model';
    END IF;
    SELECT oid INTO runtime_id FROM pg_roles WHERE rolname = 'uten';
    IF runtime_id = 10 THEN
        RAISE EXCEPTION 'Refused: uten is the pinned cluster bootstrap role; restore into a new uten_dev_admin instance';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extowner = runtime_id) THEN
        RAISE EXCEPTION 'Refused: uten owns an extension; restore without ownership into a new uten_dev_admin instance';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_database WHERE datname <> 'uten_imp' AND datdba = runtime_id) THEN
        RAISE EXCEPTION 'Refused: uten owns another database; shared ownership must not be changed here';
    END IF;
    FOR namespace IN SELECT n.oid FROM pg_namespace n
                     WHERE n.nspname NOT IN ('public', 'information_schema') AND n.nspname !~ '^pg_' LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extnamespace = namespace.oid)
           AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_namespace'::regclass
                           AND d.objid = namespace.oid AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e') THEN
            RAISE EXCEPTION 'Refused: an unreviewed application schema exists';
        END IF;
    END LOOP;
    -- Explicit ALTER OWNER below is deliberately limited to public. Unknown
    -- runtime-owned object kinds/schemas need a separately reviewed restore.
    IF EXISTS (SELECT 1 FROM pg_shdepend d
               WHERE d.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
                 AND d.refclassid = 'pg_authid'::regclass AND d.refobjid = runtime_id AND d.deptype = 'o'
                 AND d.classid NOT IN ('pg_class'::regclass, 'pg_proc'::regclass, 'pg_type'::regclass,
                                      'pg_namespace'::regclass, 'pg_default_acl'::regclass))
       OR EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE c.relowner = runtime_id AND n.nspname <> 'public'
                    -- ALTER TABLE OWNER also moves its internal TOAST table
                    -- and TOAST index; neither is another application schema.
                    AND NOT EXISTS (SELECT 1 FROM pg_class app JOIN pg_namespace an ON an.oid = app.relnamespace
                                    WHERE an.nspname = 'public' AND
                                      (app.reltoastrelid = c.oid OR app.reltoastrelid =
                                        (SELECT i.indrelid FROM pg_index i WHERE i.indexrelid = c.oid))))
       OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE p.proowner = runtime_id AND n.nspname <> 'public')
       OR EXISTS (SELECT 1 FROM pg_namespace WHERE nspowner = runtime_id AND nspname <> 'public') THEN
        RAISE EXCEPTION 'Refused: uten owns objects outside the supported public application scope';
    END IF;
END;
$local_instance_preflight$;

DO $local_roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'uten_dev_admin') THEN
        CREATE ROLE uten_dev_admin LOGIN SUPERUSER NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'uten_migrator') THEN
        CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOINHERIT NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'uten') THEN
        CREATE ROLE uten LOGIN NOSUPERUSER NOINHERIT NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    END IF;
    EXECUTE format('ALTER ROLE uten_dev_admin LOGIN SUPERUSER NOINHERIT PASSWORD %L',
                   current_setting('uten.local_admin_password'));
    EXECUTE format('ALTER ROLE uten_migrator LOGIN NOSUPERUSER NOINHERIT NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L',
                   current_setting('uten.local_migrator_password'));
    EXECUTE format('ALTER ROLE uten PASSWORD %L', current_setting('uten.local_runtime_password'));
END;
$local_roles$;
SET LOCAL ROLE uten_dev_admin;

-- Keep bootstrap/system/extension ownership in the administrator's hands.
-- Only ordinary public application relations, functions and types are moved.
DO $local_public_owners$
DECLARE object record;
BEGIN
    ALTER DATABASE uten_imp OWNER TO uten_migrator;
    ALTER SCHEMA public OWNER TO uten_migrator;
    FOR object IN SELECT c.oid, c.relname, c.relkind FROM pg_class c
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                  JOIN pg_roles r ON r.oid = c.relowner
                  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
                    AND r.rolname = 'uten'
                  ORDER BY CASE WHEN c.relkind = 'S' THEN 1 ELSE 0 END, c.oid LOOP
        EXECUTE format('ALTER %s public.%I OWNER TO uten_migrator',
                       CASE object.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW'
                            WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END,
                       object.relname);
    END LOOP;
    FOR object IN SELECT p.oid, p.proname, p.prokind, pg_get_function_identity_arguments(p.oid) AS args
                  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  JOIN pg_roles r ON r.oid = p.proowner WHERE n.nspname = 'public' AND r.rolname = 'uten' LOOP
        EXECUTE format('ALTER %s public.%I(%s) OWNER TO uten_migrator',
                       CASE object.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
                       object.proname, object.args);
    END LOOP;
    FOR object IN SELECT t.typname, t.typtype FROM pg_type t
                  JOIN pg_namespace n ON n.oid = t.typnamespace JOIN pg_roles r ON r.oid = t.typowner
                  LEFT JOIN pg_class c ON c.oid = t.typrelid
                  WHERE n.nspname = 'public' AND r.rolname = 'uten' AND t.typelem = 0
                    AND t.typtype IN ('b', 'c', 'd', 'e', 'r') AND (t.typrelid = 0 OR c.relkind = 'c') LOOP
        EXECUTE format('ALTER %s public.%I OWNER TO uten_migrator',
                       CASE WHEN object.typtype = 'd' THEN 'DOMAIN' ELSE 'TYPE' END, object.typname);
    END LOOP;
END;
$local_public_owners$;
ALTER ROLE uten LOGIN NOSUPERUSER NOINHERIT NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

REVOKE ALL ON DATABASE uten_imp FROM PUBLIC, uten;
GRANT CONNECT, TEMPORARY ON DATABASE uten_imp TO uten;
GRANT CONNECT ON DATABASE uten_imp TO uten_migrator;
REVOKE ALL ON SCHEMA public FROM PUBLIC, uten;
GRANT USAGE ON SCHEMA public TO uten;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, uten;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO uten;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, uten;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO uten;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM uten;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO uten;
REVOKE EXECUTE ON FUNCTION pg_catalog.pg_control_system() FROM PUBLIC, uten;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator;

-- A future migration creates ordinary objects with app permissions, but no
-- TRUNCATE/REFERENCES/TRIGGER/delegation authority. Individual migrations and
-- the seal below revoke private entry points and immutable evidence writes.
ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator REVOKE ALL ON TABLES FROM PUBLIC, uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator REVOKE ALL ON SEQUENCES FROM PUBLIC, uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator REVOKE ALL ON FUNCTIONS FROM PUBLIC, uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC, uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC, uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM PUBLIC, uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO uten;

DO $local_protected_acl$
DECLARE relation record; attribute record; routine record; privilege_name text; target oid;
BEGIN
    FOR relation IN SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND c.relname IN (
                        'legacy_migration_runs', 'legacy_migration_run_files', 'legacy_migration_reconciliation_items',
                        'legacy_migration_rejects', 'legacy_migration_checkpoints',
                        'legacy_subcontract_order_import_sources', 'legacy_finance_import_sources',
                        'legacy_procurement_receipt_import_sources', 'legacy_quantity_counter_import_sources',
                        'legacy_production_plan_counter_import_sources', 'legacy_production_plan_counter_import_contexts',
                        'flyway_schema_history', 'audit_log', 'audit_log_archive') LOOP
        EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, uten RESTRICT', relation.relname);
        -- Table REVOKE does not remove column-level grants or grant options.
        FOR attribute IN SELECT attname FROM pg_attribute WHERE attrelid = relation.oid AND attnum > 0 AND NOT attisdropped LOOP
            EXECUTE format('REVOKE ALL (%I) ON TABLE public.%I FROM PUBLIC, uten RESTRICT', attribute.attname, relation.relname);
        END LOOP;
        IF relation.relname = 'audit_log' THEN
            EXECUTE 'GRANT SELECT, INSERT ON public.audit_log TO uten';
        ELSIF relation.relname <> 'flyway_schema_history' THEN
            EXECUTE format('GRANT SELECT ON TABLE public.%I TO uten', relation.relname);
        END IF;
    END LOOP;
    FOR relation IN WITH RECURSIVE audit_relations(oid) AS (
                        SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                        WHERE n.nspname = 'public' AND c.relname IN ('audit_log', 'audit_log_archive')
                        UNION SELECT i.inhrelid FROM pg_inherits i JOIN audit_relations a ON a.oid = i.inhparent)
                    SELECT c.oid, c.relname, n.nspname FROM audit_relations a JOIN pg_class c ON c.oid = a.oid
                    JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relispartition LOOP
        EXECUTE format('REVOKE ALL ON TABLE %I.%I FROM PUBLIC, uten RESTRICT', relation.nspname, relation.relname);
        FOR attribute IN SELECT attname FROM pg_attribute WHERE attrelid = relation.oid AND attnum > 0 AND NOT attisdropped LOOP
            EXECUTE format('REVOKE ALL (%I) ON TABLE %I.%I FROM PUBLIC, uten RESTRICT', attribute.attname, relation.nspname, relation.relname);
        END LOOP;
    END LOOP;
    FOR routine IN SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args
                   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'public' AND p.prokind = 'f' AND (
                       p.proname IN ('business_data_reset', 'fn_require_runtime_maintenance',
                           'fn_business_test_reset_verify_purged', 'fn_clear_business_test_object_metadata',
                           'fn_audit_track_table', 'fn_audit_seal_privileges', 'fn_migrate_financial_amount_columns')
                       OR p.proname LIKE 'fn\_register\_legacy\_%' ESCAPE '\'
                       OR p.proname LIKE 'fn\_import\_legacy\_%' ESCAPE '\') LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM PUBLIC, uten RESTRICT', routine.proname, routine.args);
        IF has_function_privilege('uten', routine.oid, 'EXECUTE') THEN
            RAISE EXCEPTION 'Refused: runtime retains a private maintenance function privilege';
        END IF;
    END LOOP;
    -- Use the V917 effective-privilege oracle for ALL protected provenance.
    FOR relation IN SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'public' AND c.relname IN (
                        'legacy_migration_runs', 'legacy_migration_run_files', 'legacy_migration_reconciliation_items',
                        'legacy_migration_rejects', 'legacy_migration_checkpoints',
                        'legacy_subcontract_order_import_sources', 'legacy_finance_import_sources',
                        'legacy_procurement_receipt_import_sources', 'legacy_quantity_counter_import_sources',
                        'legacy_production_plan_counter_import_sources', 'legacy_production_plan_counter_import_contexts') LOOP
        FOREACH privilege_name IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'SELECT WITH GRANT OPTION'] LOOP
            IF has_table_privilege('uten', relation.oid, privilege_name) THEN
                RAISE EXCEPTION 'Refused: runtime retains protected evidence write or delegation authority';
            END IF;
        END LOOP;
        FOREACH privilege_name IN ARRAY ARRAY['INSERT', 'UPDATE', 'REFERENCES', 'SELECT WITH GRANT OPTION'] LOOP
            IF has_any_column_privilege('uten', relation.oid, privilege_name) THEN
                RAISE EXCEPTION 'Refused: runtime retains protected evidence column write or delegation authority';
            END IF;
        END LOOP;
    END LOOP;
END;
$local_protected_acl$;

DO $local_role_postconditions$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'uten'
               AND (rolsuper OR rolinherit OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls))
       OR pg_has_role('uten', 'uten_migrator', 'SET') OR pg_has_role('uten', 'uten_dev_admin', 'SET')
       OR has_schema_privilege('uten', 'public', 'CREATE')
       OR has_database_privilege('uten', 'uten_imp', 'CREATE')
       OR has_function_privilege('uten', 'pg_catalog.pg_control_system()', 'EXECUTE') THEN
        RAISE EXCEPTION 'Refused: runtime/maintenance separation postcondition failed';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               JOIN pg_roles r ON r.oid = c.relowner WHERE n.nspname = 'public' AND r.rolname = 'uten')
       OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  JOIN pg_roles r ON r.oid = p.proowner WHERE n.nspname = 'public' AND r.rolname = 'uten')
       OR EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                  JOIN pg_roles r ON r.oid = t.typowner WHERE n.nspname = 'public' AND r.rolname = 'uten') THEN
        RAISE EXCEPTION 'Refused: runtime still owns public application objects';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datid IS NOT NULL) THEN
        RAISE EXCEPTION 'Refused: another database session appeared during preparation';
    END IF;
END;
$local_role_postconditions$;
COMMIT;
\echo 'Prepared isolated local uten_imp roles. Business rows and Flyway history were not modified.'
