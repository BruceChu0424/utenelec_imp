-- V572 full audit sweep after V560/V561/V568/V569 business tables
-- (production material return requests, execution batch splits, preplan
-- reallocation make supplements, preplan future supply transfers) reached the
-- schema without row-level audit triggers. Same fail-closed walk as V530:
-- every non-excluded public table must end with exactly one valid audit
-- trigger; malformed prefixed triggers abort the migration. No business row
-- and no audit history is modified.
-- Exclusions restate the approved V424 system-noise set and the V454
-- notice-mechanics exclusion so this sweep keeps V530's reviewed decision.

DO $full_audit_sweep$
DECLARE r RECORD; prefixed_trigger_count INTEGER; valid_trigger_count INTEGER; other_audit_count INTEGER; missing TEXT;
BEGIN
    FOR r IN SELECT c.oid,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND c.relkind IN('r','p') AND NOT c.relispartition
          AND c.relname NOT IN(
            'audit_log','audit_log_archive','flyway_schema_history','spatial_ref_sys',
            'authorization_state','doc_number_sequences','master_code_sequences','category_master_code_sequences',
            'business_document_sequences','production_product_no_sequences','report_materialized_view_refresh_state',
            'password_history','refresh_tokens','visitor_refresh_tokens','visitor_sms_codes',
            'notices','notice_user_states','notice_acknowledgments','notice_blessings','business_outbox',
            'attachment_object_outbox','account_flow_monthly_summaries','production_daily_report_commands',
            'production_fqc_release_commands','warehouse_arrival_registration_commands','production_material_analysis_commands',
            'notice_celebration_subjects')
          AND c.relname NOT LIKE 'legacy_migration_%' ORDER BY c.relname
    LOOP
        SELECT count(*) FILTER(WHERE t.tgname LIKE 'trg_audit%'),
            count(*) FILTER(WHERE t.tgname LIKE 'trg_audit%'
              AND t.tgenabled IN ('O', 'A') AND t.tgtype=29
              AND (t.tgtype::INTEGER & 1)=1 AND (t.tgtype::INTEGER & 2)=0
              AND (t.tgtype::INTEGER & 4)=4 AND (t.tgtype::INTEGER & 8)=8 AND (t.tgtype::INTEGER & 16)=16
              AND t.tgnargs=0 AND t.tgqual IS NULL AND t.tgattr=''::int2vector
              AND NOT t.tgdeferrable AND NOT t.tginitdeferred AND t.tgconstraint=0
              AND t.tgoldtable IS NULL AND t.tgnewtable IS NULL
              AND pn.nspname='public' AND p.proname IN('fn_audit','fn_audit_redacted')
              AND t.tgfoid IN('public.fn_audit()'::regprocedure,'public.fn_audit_redacted()'::regprocedure)),
            count(*) FILTER(WHERE t.tgname NOT LIKE 'trg_audit%'
              AND t.tgfoid IN('public.fn_audit()'::regprocedure,'public.fn_audit_redacted()'::regprocedure))
        INTO prefixed_trigger_count,valid_trigger_count,other_audit_count
        FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace pn ON pn.oid=p.pronamespace
        WHERE t.tgrelid=r.oid AND NOT t.tgisinternal;
        IF prefixed_trigger_count = 1 AND valid_trigger_count = 1 AND other_audit_count=0 THEN CONTINUE; END IF;
        IF prefixed_trigger_count>0 OR other_audit_count>0 THEN
            RAISE EXCEPTION 'public.% has % trg_audit* triggers but exactly one valid audit trigger is required (valid=%, other=%)',
                r.relname,prefixed_trigger_count,valid_trigger_count,other_audit_count USING ERRCODE='55000';
        END IF;
        EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION fn_audit()',
            'trg_audit_'||r.relname,r.relname);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I',r.relname,'trg_audit_'||r.relname);
    END LOOP;

    SELECT string_agg(c.relname,', ' ORDER BY c.relname) INTO missing
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind IN('r','p') AND NOT c.relispartition
      AND c.relname NOT IN(
        'audit_log','audit_log_archive','flyway_schema_history','spatial_ref_sys',
        'authorization_state','doc_number_sequences','master_code_sequences','category_master_code_sequences',
        'business_document_sequences','production_product_no_sequences','report_materialized_view_refresh_state',
        'password_history','refresh_tokens','visitor_refresh_tokens','visitor_sms_codes',
        'notices','notice_user_states','notice_acknowledgments','notice_blessings','business_outbox',
        'attachment_object_outbox','account_flow_monthly_summaries','production_daily_report_commands',
        'production_fqc_release_commands','warehouse_arrival_registration_commands','production_material_analysis_commands',
        'notice_celebration_subjects')
      AND c.relname NOT LIKE 'legacy_migration_%'
      AND ((SELECT count(*) FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal AND t.tgname LIKE 'trg_audit%')<>1
        OR (SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace pn ON pn.oid=p.pronamespace
            WHERE t.tgrelid=c.oid AND NOT t.tgisinternal AND t.tgname LIKE 'trg_audit%'
              AND t.tgenabled IN ('O', 'A') AND t.tgtype=29 AND t.tgnargs=0 AND t.tgqual IS NULL AND t.tgattr=''::int2vector
              AND NOT t.tgdeferrable AND NOT t.tginitdeferred AND t.tgconstraint=0
              AND t.tgoldtable IS NULL AND t.tgnewtable IS NULL
              AND pn.nspname='public' AND p.proname IN('fn_audit','fn_audit_redacted')
              AND t.tgfoid IN('public.fn_audit()'::regprocedure,'public.fn_audit_redacted()'::regprocedure))<>1
        OR EXISTS(SELECT 1 FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal AND t.tgname NOT LIKE 'trg_audit%'
              AND t.tgfoid IN('public.fn_audit()'::regprocedure,'public.fn_audit_redacted()'::regprocedure)));
    IF missing IS NOT NULL THEN RAISE EXCEPTION 'Audit trigger coverage remains invalid for: %',missing USING ERRCODE='55000'; END IF;
END;
$full_audit_sweep$;
