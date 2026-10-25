-- Local split-role ACL only. Run as uten_migrator in a transaction after migrations.
-- This is deliberately outside db/migration: no applied migration is rewritten,
-- no schema version changes, and no business data, passwords or owners change.
DO $local_runtime_privileges$
DECLARE
    entry record;
    attribute record;
    privilege_name text;
    runtime_id oid;
    owner_id oid;
    protected_names constant text[] := ARRAY[
        'legacy_migration_runs','legacy_migration_run_files',
        'legacy_migration_reconciliation_items','legacy_migration_rejects',
        'legacy_migration_checkpoints','legacy_subcontract_order_import_sources',
        'legacy_finance_import_sources','legacy_procurement_receipt_import_sources',
        'legacy_quantity_counter_import_sources','legacy_production_plan_counter_import_sources',
        'legacy_production_plan_counter_import_contexts'];
    private_names constant text[] := ARRAY[
        'business_data_reset','fn_require_runtime_maintenance','fn_require_runtime_refresh',
        'fn_business_test_reset_verify_purged','fn_clear_business_test_object_metadata',
        'fn_audit_track_table','fn_audit_seal_privileges','fn_migrate_financial_amount_columns'];
BEGIN
    IF current_database()<>'uten_imp' OR current_user<>'uten_migrator'
       OR session_user<>current_user
       OR EXISTS(SELECT 1 FROM pg_roles WHERE rolname=current_user
                 AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication)) THEN
        RAISE EXCEPTION 'Local runtime ACL requires the direct non-superuser migration owner';
    END IF;
    SELECT oid INTO STRICT owner_id FROM pg_roles WHERE rolname=current_user;
    SELECT oid INTO STRICT runtime_id FROM pg_roles WHERE rolname='uten';
    IF EXISTS(SELECT 1 FROM pg_roles WHERE oid=runtime_id
              AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication))
       OR pg_has_role('uten',owner_id,'MEMBER')
       OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member=runtime_id)
       OR has_schema_privilege('uten','public','CREATE')
       OR has_database_privilege('uten',current_database(),'CREATE')
       OR (SELECT nspowner FROM pg_namespace WHERE nspname='public')<>owner_id
       OR (SELECT datdba FROM pg_database WHERE datname=current_database())<>owner_id
       OR EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relowner=runtime_id)
       OR EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND p.proowner=runtime_id) THEN
        RAISE EXCEPTION 'Local runtime and migration ownership must remain separated';
    END IF;
    IF to_regprocedure('public.business_data_reset()') IS NOT NULL
       OR to_regprocedure('public.fn_require_runtime_maintenance(boolean)') IS NOT NULL THEN
        RAISE EXCEPTION 'Complete business-reset retirement before runtime ACL reconciliation';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('uten.local.runtime-privileges',0));
    PERFORM set_config('lock_timeout','5s',true);
    GRANT CONNECT,TEMPORARY ON DATABASE uten_imp TO uten;
    GRANT USAGE ON SCHEMA public TO uten;

    -- Only owner-managed application relations; extension/system objects are untouched.
    FOR entry IN SELECT c.oid,c.relname,c.relkind,c.relispartition
                 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relowner=owner_id
                   AND c.relkind IN ('r','p','v','m') ORDER BY c.relname LOOP
        IF entry.relname='flyway_schema_history' OR entry.relispartition
           OR entry.relname=ANY(protected_names)
           OR entry.relname IN ('audit_log','audit_log_archive') THEN
            EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,uten RESTRICT',entry.relname);
            FOR attribute IN SELECT attname FROM pg_attribute
                             WHERE attrelid=entry.oid AND attnum>0 AND NOT attisdropped LOOP
                EXECUTE format('REVOKE ALL (%I) ON TABLE public.%I FROM PUBLIC,uten RESTRICT',attribute.attname,entry.relname);
            END LOOP;
            IF entry.relname='audit_log' THEN
                GRANT SELECT,INSERT ON public.audit_log TO uten;
            ELSIF NOT entry.relispartition AND entry.relname<>'flyway_schema_history' THEN
                EXECUTE format('GRANT SELECT ON TABLE public.%I TO uten',entry.relname);
            END IF;
        ELSIF entry.relkind IN ('v','m') THEN
            EXECUTE format('GRANT SELECT ON TABLE public.%I TO uten',entry.relname);
        ELSE
            EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.%I TO uten',entry.relname);
        END IF;
    END LOOP;
    FOR entry IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relowner=owner_id AND c.relkind='S' LOOP
        EXECUTE format('GRANT USAGE,SELECT,UPDATE ON SEQUENCE public.%I TO uten',entry.relname);
    END LOOP;
    FOR entry IN SELECT p.oid,p.proname,pg_get_function_identity_arguments(p.oid) args
                 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND p.proowner=owner_id AND p.prokind='f' LOOP
        IF entry.proname=ANY(private_names)
           OR entry.proname LIKE 'fn\_register\_legacy\_%' ESCAPE '\'
           OR entry.proname LIKE 'fn\_import\_legacy\_%' ESCAPE '\' THEN
            EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM PUBLIC,uten RESTRICT',entry.proname,entry.args);
            IF has_function_privilege('uten',entry.oid,'EXECUTE') THEN
                RAISE EXCEPTION 'Runtime retains a private maintenance/import function privilege: %',entry.proname;
            END IF;
        ELSE
            EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO uten',entry.proname,entry.args);
        END IF;
    END LOOP;
    -- Fresh future owner-created objects also receive the normal application ACL.
    -- Each private object's migration and the reconciliation above seal exceptions.
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public
        GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO uten;
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public
        GRANT USAGE,SELECT,UPDATE ON SEQUENCES TO uten;
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public
        GRANT EXECUTE ON FUNCTIONS TO uten;
    -- Verify effective privileges, including column grants and inherited paths.
    FOR entry IN SELECT c.oid,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relname=ANY(protected_names) LOOP
        FOREACH privilege_name IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','SELECT WITH GRANT OPTION'] LOOP
            IF has_table_privilege('uten',entry.oid,privilege_name) THEN
                RAISE EXCEPTION 'Runtime retains a protected provenance privilege: % %',entry.relname,privilege_name;
            END IF;
        END LOOP;
        FOREACH privilege_name IN ARRAY ARRAY['INSERT','UPDATE','REFERENCES','SELECT WITH GRANT OPTION'] LOOP
            IF has_any_column_privilege('uten',entry.oid,privilege_name) THEN
                RAISE EXCEPTION 'Runtime retains a protected provenance column privilege: % %',entry.relname,privilege_name;
            END IF;
        END LOOP;
    END LOOP;
END;
$local_runtime_privileges$;
