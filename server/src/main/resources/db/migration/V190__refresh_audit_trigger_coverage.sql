-- V190: refresh and validate public-business-table audit trigger coverage.
--
-- V169, V184, and V185 may already be applied and remain immutable. This
-- migration repeats the full fail-closed coverage sweep after the V188 sales
-- shipment event ledger and V189 sales-return quarantine tables were added.
-- It only attaches fn_audit() to eligible tables that do not already have a
-- trg_audit* trigger. Exactly one prefixed trigger is accepted, and only when
-- it is enabled, AFTER ROW, covers INSERT/UPDATE/DELETE, and calls an approved
-- redacting audit function. Any trigger created here records only future
-- operations from V190 application onward; this migration never invents or
-- backfills historical audit rows.

DO $$
DECLARE
    table_record RECORD;
    prefixed_trigger_count INTEGER;
    valid_trigger_count INTEGER;
    missing_tables TEXT;
BEGIN
    FOR table_record IN
        SELECT c.oid, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname NOT IN (
              'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
              'authorization_state', 'doc_number_sequences', 'master_code_sequences',
              'report_materialized_view_refresh_state', 'password_history',
              'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
          AND c.relname NOT LIKE 'legacy_migration_%'
        ORDER BY c.relname
    LOOP
        SELECT
            count(*),
            count(*) FILTER (WHERE
                audit_trigger.tgenabled IN ('O', 'A')
                AND (audit_trigger.tgtype::INTEGER & 1) = 1
                AND (audit_trigger.tgtype::INTEGER & 2) = 0
                AND (audit_trigger.tgtype::INTEGER & 4) = 4
                AND (audit_trigger.tgtype::INTEGER & 8) = 8
                AND (audit_trigger.tgtype::INTEGER & 16) = 16
                AND function_schema.nspname = 'public'
                AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted'))
        INTO prefixed_trigger_count, valid_trigger_count
        FROM pg_trigger audit_trigger
        JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
        JOIN pg_namespace function_schema
          ON function_schema.oid = audit_function.pronamespace
        WHERE audit_trigger.tgrelid = table_record.oid
          AND NOT audit_trigger.tgisinternal
          AND audit_trigger.tgname LIKE 'trg_audit%';

        IF prefixed_trigger_count = 1 AND valid_trigger_count = 1 THEN
            CONTINUE;
        END IF;

        IF prefixed_trigger_count > 0 THEN
            RAISE EXCEPTION
                'public.% has % trg_audit%% triggers but exactly one valid enabled AFTER ROW INSERT/UPDATE/DELETE audit trigger is required (valid=%)',
                table_record.relname, prefixed_trigger_count, valid_trigger_count
                USING ERRCODE = '55000';
        END IF;

        EXECUTE format(
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit()',
            table_record.relname);
    END LOOP;

    SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO missing_tables
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND NOT c.relispartition
      AND c.relname NOT IN (
          'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
          'authorization_state', 'doc_number_sequences', 'master_code_sequences',
          'report_materialized_view_refresh_state', 'password_history',
          'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
      AND c.relname NOT LIKE 'legacy_migration_%'
      AND (
          (SELECT count(*)
           FROM pg_trigger audit_trigger
           WHERE audit_trigger.tgrelid = c.oid
             AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%') <> 1
          OR
          (SELECT count(*)
           FROM pg_trigger audit_trigger
           JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
           JOIN pg_namespace function_schema
             ON function_schema.oid = audit_function.pronamespace
           WHERE audit_trigger.tgrelid = c.oid
             AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%'
             AND audit_trigger.tgenabled IN ('O', 'A')
             AND (audit_trigger.tgtype::INTEGER & 1) = 1
             AND (audit_trigger.tgtype::INTEGER & 2) = 0
             AND (audit_trigger.tgtype::INTEGER & 4) = 4
             AND (audit_trigger.tgtype::INTEGER & 8) = 8
             AND (audit_trigger.tgtype::INTEGER & 16) = 16
             AND function_schema.nspname = 'public'
             AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted')) <> 1);

    IF missing_tables IS NOT NULL THEN
        RAISE EXCEPTION 'Audit trigger coverage remains invalid for: %', missing_tables
            USING ERRCODE = '55000';
    END IF;
END $$;
