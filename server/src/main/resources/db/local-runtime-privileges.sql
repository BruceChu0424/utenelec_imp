-- Canonical split-role runtime ACL. The dev callback remains loopback/uten_imp only.
-- Views stay runtime read-only except insert_through_views: the audit unified read
-- layer (V952) receives the JPA write channel through its INSTEAD OF INSERT trigger.
-- A reviewed nonstandard candidate must enter through ops/reconcile-runtime-privileges.sql,
-- which pins its name, OID, cluster identity and migration owner in this transaction.
-- No business rows, migration history, object definitions, owners or role attributes change.
DO $local_runtime_privileges$
DECLARE
    entry record;
    attribute record;
    privilege_name text;
    runtime_id oid;
    owner_id oid;
    database_id oid;
    database_owner oid;
    schema_owner oid;
    scope_kind text := NULLIF(current_setting('uten.runtime_acl.scope_kind',true),'');
    expected_database text := NULLIF(current_setting('uten.runtime_acl.expected_database',true),'');
    expected_database_oid text := NULLIF(current_setting('uten.runtime_acl.expected_database_oid',true),'');
    expected_system_identifier text := NULLIF(current_setting('uten.runtime_acl.expected_system_identifier',true),'');
    expected_owner text := NULLIF(current_setting('uten.runtime_acl.expected_owner',true),'');
    confirmation text := NULLIF(current_setting('uten.runtime_acl.confirmation',true),'');
    protected_names constant text[] := ARRAY[
        'legacy_migration_runs','legacy_migration_run_files',
        'legacy_migration_reconciliation_items','legacy_migration_rejects',
        'legacy_migration_checkpoints','legacy_subcontract_order_import_sources',
        'legacy_finance_import_sources','legacy_procurement_receipt_import_sources',
        'legacy_quantity_counter_import_sources','legacy_production_plan_counter_import_sources',
        'legacy_production_plan_counter_import_contexts','stock_measurement_holds'];
    private_relations constant text[] := ARRAY[
        'flyway_schema_history','business_test_object_cleanup_intents'];
    -- Only these views keep a runtime INSERT path; the INSTEAD OF trigger lands the
    -- rows in audit_log, and UPDATE/DELETE stay denied because no such trigger exists.
    insert_through_views constant text[] := ARRAY['v_audit_log_all'];
    private_names constant text[] := ARRAY[
        'business_data_reset','fn_require_runtime_maintenance','fn_require_runtime_refresh',
        'fn_business_test_reset_verify_purged','fn_clear_business_test_object_metadata',
        'fn_audit_track_table','fn_audit_seal_privileges','fn_migrate_financial_amount_columns',
        'fn_capture_stock_measurement_holds','fn_verify_stock_original_measurement_basis',
        'fn_audit_stock_measurement_hold_columns'];
    -- V964/V965 freeze these ACLs inside their independent catalog seals. A
    -- general application grant must never reopen private preimages or merge/
    -- code-release commands, nor rewrite a valid seal during a no-op startup.
    sealed_relations constant text[] := ARRAY[
        'employee_identity_merges','employee_identity_merge_payloads','employee_legacy_identity_aliases',
        'employee_identity_historical_claims','employee_identity_user_tombstones','employee_identity_legacy_roles',
        'employee_identity_review_certificates','employee_identity_merge_installation',
        'employee_code_reuse_installation','employee_code_reuse_releases','employee_code_reuse_claims'];
    sealed_read_relations constant text[] := ARRAY[
        'employee_identity_merges','employee_identity_historical_claims','employee_legacy_identity_aliases'];
    sealed_functions text[];
    sealed_runtime_functions constant text[] := ARRAY[
        'fn_employee_merge_completed','fn_employee_identity_from_legacy_worker','fn_employee_merge_retained_user',
        'fn_employee_merge_database_identity','fn_employee_merge_source_fingerprint','fn_employee_merge_identifier_reviewed',
        'fn_claim_next_released_employee_code','fn_employee_code_reuse_claim_authorizes','fn_employee_code_requires_identity_mapping'];
    sealed_preserved_functions constant text[] := ARRAY['fn_reserve_master_code','fn_claim_global_business_identifier'];
BEGIN
    IF current_user<>'uten_migrator' OR session_user<>current_user
       OR EXISTS(SELECT 1 FROM pg_roles WHERE rolname=current_user
                 AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication)) THEN
        RAISE EXCEPTION 'Runtime ACL requires the direct non-superuser migration owner';
    END IF;
    SELECT oid INTO STRICT owner_id FROM pg_roles WHERE rolname=current_user;
    SELECT oid INTO STRICT runtime_id FROM pg_roles WHERE rolname='uten';
    SELECT oid,datdba INTO STRICT database_id,database_owner
      FROM pg_database WHERE datname=current_database();
    SELECT nspowner INTO STRICT schema_owner FROM pg_namespace WHERE nspname='public';

    IF scope_kind IS NULL AND expected_database IS NULL AND expected_database_oid IS NULL
       AND expected_system_identifier IS NULL AND expected_owner IS NULL AND confirmation IS NULL THEN
        -- Keep the existing dev boundary. No missing/partial candidate pins fall back here.
        IF current_database()<>'uten_imp' THEN
            RAISE EXCEPTION 'Nonstandard runtime ACL requires the reviewed scope-bound candidate wrapper';
        END IF;
    ELSE
        IF scope_kind IS DISTINCT FROM 'reviewed_candidate'
           OR expected_database IS NULL OR expected_database!~'^[a-z][a-z0-9_]{0,62}$'
           OR expected_database IN ('uten_imp','postgres','template0','template1')
           OR expected_database IS DISTINCT FROM current_database()
           OR expected_database_oid IS NULL OR expected_database_oid!~'^[1-9][0-9]{0,9}$'
           OR expected_database_oid IS DISTINCT FROM database_id::text
           OR expected_system_identifier IS NULL OR expected_system_identifier!~'^[1-9][0-9]{0,19}$'
           OR expected_owner IS DISTINCT FROM 'uten_migrator'
           OR confirmation IS DISTINCT FROM ('RECONCILE CANDIDATE RUNTIME ACL '||expected_database) THEN
            RAISE EXCEPTION 'Candidate runtime ACL name/OID/owner/confirmation binding does not match';
        END IF;
        -- This is a read prerequisite. Never grant access to an administrator-owned
        -- catalog function merely to make reconciliation pass.
        IF expected_system_identifier IS DISTINCT FROM
           (SELECT system_identifier::text FROM pg_control_system()) THEN
            RAISE EXCEPTION 'Candidate runtime ACL cluster identity does not match';
        END IF;
    END IF;
    IF database_owner<>owner_id
       OR (schema_owner<>owner_id AND schema_owner<>'pg_database_owner'::regrole::oid)
       OR EXISTS(SELECT 1 FROM pg_roles WHERE oid=runtime_id
                 AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication))
       OR pg_has_role('uten',owner_id,'MEMBER')
       OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member=runtime_id)
       OR has_schema_privilege('uten','public','CREATE')
       OR has_database_privilege('uten',current_database(),'CREATE')
       OR EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relowner=runtime_id)
       OR EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND p.proowner=runtime_id) THEN
        RAISE EXCEPTION 'Runtime and migration ownership must remain separated';
    END IF;
    -- Unknown database/schema delegation is not a routine app ACL repair.
    -- Refuse it before the first GRANT rather than silently rewriting other principals.
    IF has_database_privilege('uten',current_database(),'CONNECT WITH GRANT OPTION')
       OR has_database_privilege('uten',current_database(),'TEMPORARY WITH GRANT OPTION')
       OR has_schema_privilege('uten','public','USAGE WITH GRANT OPTION') THEN
        RAISE EXCEPTION 'Runtime database/schema delegation is unreviewed; no ACL changes were made';
    END IF;
    -- pg_database_owner owns public in a standard template0 database. It is
    -- accepted only with the current database's actual owner already pinned above.
    IF to_regprocedure('public.business_data_reset()') IS NOT NULL
       OR to_regprocedure('public.fn_require_runtime_maintenance(boolean)') IS NOT NULL THEN
        RAISE EXCEPTION 'Complete business-reset retirement before runtime ACL reconciliation';
    END IF;
    SELECT COALESCE(array_agg(DISTINCT p.proname),ARRAY[]::text[]) INTO sealed_functions
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND (
        p.proname ~ '^(fn_employee_merge_|fn_employee_code_|fn_guard_employee_code_|fn_finish_employee_code_reuse_claim$)'
        OR p.proname IN('fn_merge_employee_identity','fn_employee_identity_from_legacy_worker',
                       'fn_claim_next_released_employee_code','fn_release_merged_employee_code')
        OR (to_regclass('public.employee_code_reuse_installation') IS NOT NULL
            AND p.proname=ANY(sealed_preserved_functions)));
    -- Drift is a review failure, not permission to replace the extension's
    -- exact grants. Check effective column/PUBLIC paths before any ACL write.
    FOR entry IN SELECT c.oid,c.relname,c.relowner FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relname=ANY(sealed_relations) AND c.relkind IN('r','p') LOOP
        IF entry.relowner<>owner_id
           OR has_table_privilege('uten',entry.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
           OR has_any_column_privilege('uten',entry.oid,'INSERT,UPDATE,REFERENCES')
           OR has_table_privilege('uten',entry.oid,'SELECT WITH GRANT OPTION')
           OR has_any_column_privilege('uten',entry.oid,'SELECT WITH GRANT OPTION')
           OR (entry.relname=ANY(sealed_read_relations)
               AND NOT has_table_privilege('uten',entry.oid,'SELECT'))
           OR (NOT entry.relname=ANY(sealed_read_relations)
               AND (has_table_privilege('uten',entry.oid,'SELECT') OR has_any_column_privilege('uten',entry.oid,'SELECT'))) THEN
            RAISE EXCEPTION 'Sealed employee identity relation ACL drifted; explicit review required: %',entry.relname;
        END IF;
    END LOOP;
    FOR entry IN SELECT p.oid,p.proname,p.proowner,p.prorettype FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND p.proname=ANY(sealed_functions) LOOP
        IF entry.proowner<>owner_id OR has_function_privilege('uten',entry.oid,'EXECUTE WITH GRANT OPTION')
           OR (entry.proname=ANY(sealed_runtime_functions) AND NOT has_function_privilege('uten',entry.oid,'EXECUTE'))
           OR (NOT entry.proname=ANY(sealed_runtime_functions) AND NOT entry.proname=ANY(sealed_preserved_functions)
               -- PostgreSQL trigger functions are not directly callable. Their
               -- installed PUBLIC EXECUTE may differ with the site's defaults.
               AND entry.prorettype<>'trigger'::regtype
               AND has_function_privilege('uten',entry.oid,'EXECUTE')) THEN
            RAISE EXCEPTION 'Sealed employee identity function ACL drifted; explicit review required: %',entry.proname;
        END IF;
    END LOOP;
    PERFORM pg_advisory_xact_lock(hashtextextended('uten.local.runtime-privileges',0));
    PERFORM set_config('lock_timeout','5s',true);
    EXECUTE format('GRANT CONNECT,TEMPORARY ON DATABASE %I TO uten',current_database());
    GRANT USAGE ON SCHEMA public TO uten;

    -- Touch only PUBLIC/runtime grants on actual owner-managed application objects.
    -- RESTRICT preserves unrelated explicit grants and refuses delegated dependencies.
    -- Never use ALL TABLES/FUNCTIONS against extension or administrator-owned objects.
    FOR entry IN SELECT c.oid,c.relname,c.relkind,c.relispartition
                 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relowner=owner_id
                   AND c.relkind IN ('r','p','v','m') ORDER BY c.relname LOOP
        IF entry.relname=ANY(sealed_relations) THEN CONTINUE; END IF;
        EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,uten RESTRICT',entry.relname);
        FOR attribute IN SELECT attname FROM pg_attribute
                         WHERE attrelid=entry.oid AND attnum>0 AND NOT attisdropped
                           AND attacl IS NOT NULL LOOP
            EXECUTE format('REVOKE ALL (%I) ON TABLE public.%I FROM PUBLIC,uten RESTRICT',attribute.attname,entry.relname);
        END LOOP;
        IF entry.relispartition OR entry.relname=ANY(private_relations) THEN
            NULL;
        ELSIF entry.relname='audit_log' THEN
            GRANT SELECT,INSERT ON public.audit_log TO uten;
        ELSIF entry.relname=ANY(insert_through_views) THEN
            EXECUTE format('GRANT SELECT,INSERT ON TABLE public.%I TO uten',entry.relname);
        ELSIF entry.relname=ANY(protected_names) OR entry.relname='audit_log_archive'
              OR entry.relkind IN ('v','m') THEN
            EXECUTE format('GRANT SELECT ON TABLE public.%I TO uten',entry.relname);
        ELSE
            EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.%I TO uten',entry.relname);
        END IF;
    END LOOP;
    FOR entry IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relowner=owner_id AND c.relkind='S' LOOP
        EXECUTE format('REVOKE ALL ON SEQUENCE public.%I FROM PUBLIC,uten RESTRICT',entry.relname);
        -- Current business defaults require nextval/currval, never setval or raw sequence reads.
        EXECUTE format('GRANT USAGE ON SEQUENCE public.%I TO uten',entry.relname);
    END LOOP;
    FOR entry IN SELECT p.oid,p.proname,pg_get_function_identity_arguments(p.oid) args
                 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND p.proowner=owner_id AND p.prokind='f' LOOP
        IF entry.proname=ANY(sealed_functions) THEN CONTINUE; END IF;
        IF entry.proname=ANY(private_names)
           OR entry.proname LIKE 'fn\_register\_legacy\_%' ESCAPE '\'
           OR entry.proname LIKE 'fn\_import\_legacy\_%' ESCAPE '\' THEN
            EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM PUBLIC,uten RESTRICT',entry.proname,entry.args);
        ELSE
            EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM uten RESTRICT',entry.proname,entry.args);
            EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO uten',entry.proname,entry.args);
        END IF;
    END LOOP;
    -- These defaults are scoped to this database and this migration owner, not role attributes.
    -- Remove unsafe/global PUBLIC/runtime defaults before installing the public business profile.
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator REVOKE ALL ON TABLES FROM PUBLIC,uten;
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator REVOKE ALL ON SEQUENCES FROM PUBLIC,uten;
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator REVOKE ALL ON FUNCTIONS FROM PUBLIC,uten;
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC,uten;
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC,uten;
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM PUBLIC,uten;
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public
        GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO uten;
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public GRANT USAGE ON SEQUENCES TO uten;
    ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO uten;

    -- Verify effective rights, including independent column ACLs and PUBLIC paths.
    FOR entry IN SELECT c.oid,c.relname,c.relkind,c.relispartition
                 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND (c.relowner=owner_id
                   OR c.relname=ANY(protected_names) OR c.relname=ANY(private_relations)
                   OR c.relname IN ('audit_log','audit_log_archive'))
                   AND c.relkind IN ('r','p','v','m') LOOP
        FOREACH privilege_name IN ARRAY ARRAY['TRUNCATE','REFERENCES','TRIGGER',
                'SELECT WITH GRANT OPTION','INSERT WITH GRANT OPTION','UPDATE WITH GRANT OPTION','DELETE WITH GRANT OPTION'] LOOP
            IF has_table_privilege('uten',entry.oid,privilege_name) THEN
                RAISE EXCEPTION 'Runtime retains forbidden table/delegation privilege: % %',entry.relname,privilege_name;
            END IF;
        END LOOP;
        FOREACH privilege_name IN ARRAY ARRAY['REFERENCES','SELECT WITH GRANT OPTION',
                'INSERT WITH GRANT OPTION','UPDATE WITH GRANT OPTION'] LOOP
            IF has_any_column_privilege('uten',entry.oid,privilege_name) THEN
                RAISE EXCEPTION 'Runtime retains forbidden column/delegation privilege: % %',entry.relname,privilege_name;
            END IF;
        END LOOP;
        IF entry.relname=ANY(protected_names) OR entry.relname='audit_log_archive'
           OR entry.relkind IN ('v','m') OR entry.relispartition OR entry.relname=ANY(private_relations) THEN
        FOREACH privilege_name IN ARRAY ARRAY['INSERT','UPDATE','DELETE'] LOOP
            IF entry.relname=ANY(insert_through_views) AND privilege_name='INSERT' THEN
                NULL;
            ELSIF has_table_privilege('uten',entry.oid,privilege_name)
               OR (privilege_name IN ('INSERT','UPDATE') AND has_any_column_privilege('uten',entry.oid,privilege_name)) THEN
                RAISE EXCEPTION 'Runtime retains protected evidence mutation privilege: % %',entry.relname,privilege_name;
            END IF;
        END LOOP;
        ELSIF entry.relname='audit_log' AND
              (has_table_privilege('uten',entry.oid,'UPDATE,DELETE') OR has_any_column_privilege('uten',entry.oid,'UPDATE')) THEN
            RAISE EXCEPTION 'Runtime retains audit mutation privilege';
        END IF;
        IF (entry.relispartition OR entry.relname=ANY(private_relations)) AND
           (has_table_privilege('uten',entry.oid,'SELECT') OR has_any_column_privilege('uten',entry.oid,'SELECT')) THEN
            RAISE EXCEPTION 'Runtime retains private relation read privilege: %',entry.relname;
        END IF;
    END LOOP;
    FOR entry IN SELECT c.oid,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relowner=owner_id AND c.relkind='S' LOOP
        FOREACH privilege_name IN ARRAY ARRAY['SELECT','UPDATE','USAGE WITH GRANT OPTION',
                'SELECT WITH GRANT OPTION','UPDATE WITH GRANT OPTION'] LOOP
            IF has_sequence_privilege('uten',entry.oid,privilege_name) THEN
                RAISE EXCEPTION 'Runtime retains forbidden sequence/delegation privilege: % %',entry.relname,privilege_name;
            END IF;
        END LOOP;
    END LOOP;
    FOR entry IN SELECT p.oid,p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND p.proowner=owner_id AND p.prokind='f' LOOP
        IF has_function_privilege('uten',entry.oid,'EXECUTE WITH GRANT OPTION') THEN
            RAISE EXCEPTION 'Runtime retains function delegation privilege: %',entry.proname;
        END IF;
    END LOOP;
    FOR entry IN SELECT p.oid,p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND (p.proname=ANY(private_names)
                   OR p.proname LIKE 'fn\_register\_legacy\_%' ESCAPE '\'
                   OR p.proname LIKE 'fn\_import\_legacy\_%' ESCAPE '\') LOOP
        -- An ungrantable administrator-owned private routine is never silently opened.
        IF has_function_privilege('uten',entry.oid,'EXECUTE') THEN
            RAISE EXCEPTION 'Runtime retains a private maintenance/import function privilege: %',entry.proname;
        END IF;
    END LOOP;
    IF has_schema_privilege('uten','public','CREATE')
       OR has_database_privilege('uten',current_database(),'CREATE') THEN
        RAISE EXCEPTION 'Runtime retains database/schema DDL authority';
    END IF;
END;
$local_runtime_privileges$;
