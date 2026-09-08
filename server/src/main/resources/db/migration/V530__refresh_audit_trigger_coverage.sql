-- Future-write audit coverage. Preserve business rows and existing audit history.
-- No new technical exemptions: value jobs/tasks carry amount/source evidence.

CREATE OR REPLACE FUNCTION fn_audit_primary_key_identity(p_relation OID,p_row JSONB)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN count(*)=1 THEN min(p_row->>attribute.attname)
                WHEN count(*)>1 THEN jsonb_object_agg(attribute.attname,p_row->attribute.attname ORDER BY key.ordinality)::text END
    FROM pg_index index_row
    CROSS JOIN LATERAL unnest(index_row.indkey) WITH ORDINALITY AS key(attnum,ordinality)
    JOIN pg_attribute attribute ON attribute.attrelid=index_row.indrelid AND attribute.attnum=key.attnum
    WHERE index_row.indrelid=p_relation AND index_row.indisprimary;
$$;

-- Keep established id/bill/code identities unchanged. Event-keyed and composite
-- business tables otherwise had a NULL target_id, which could not be traced.
DO $audit_identity$
DECLARE definition TEXT;needle TEXT:='v_identity ->> ''employee_id'');';
BEGIN
    SELECT pg_get_functiondef('public.fn_audit()'::regprocedure) INTO definition;
    IF position('fn_audit_primary_key_identity(TG_RELID, v_identity)' IN definition)=0 THEN
        IF position(needle IN definition)=0 OR position('INSERT INTO audit_log' IN definition)=0 THEN
            RAISE EXCEPTION 'V530 unrecognized generic audit identity implementation' USING ERRCODE='55000';
        END IF;
        EXECUTE replace(definition,needle,'v_identity ->> ''employee_id'', fn_audit_primary_key_identity(TG_RELID, v_identity));');
    END IF;
END;
$audit_identity$;

-- Request bodies and large source snapshots are not copied into the audit sink.
-- Their hashes/FKs and scalar quantities, amounts, versions and actors remain.
DO $audit_minimization$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure) INTO definition;
    IF position('''request_payload''' IN definition)=0 THEN
        IF position('RETURN v_row;' IN definition)=0 THEN
            RAISE EXCEPTION 'V530 unrecognized audit row minimization implementation' USING ERRCODE='55000';
        END IF;
        EXECUTE replace(definition,'RETURN v_row;',
            'v_row := v_row - ARRAY[''request_payload'',''input_snapshot'',''output_snapshot'',''before_balance'',''original_balance'',''original_pool'',''approval_evidence'']; RETURN v_row;');
    END IF;
END;
$audit_minimization$;

-- V503 deliberately created exactly these three INSERT-only audit triggers.
-- Repair only that proven historical shape; disabled, filtered, wrong-function,
-- extra or otherwise unfamiliar triggers are not silently replaced.
DO $known_v503_audit$
DECLARE table_name TEXT; expected_name TEXT; relation OID; matches INTEGER; prefixed INTEGER;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['procurement_order_source_revisions',
        'procurement_order_source_revision_allocations','procurement_order_source_revision_peg_changes'] LOOP
        relation:=to_regclass(format('public.%I',table_name));
        IF relation IS NULL THEN RAISE EXCEPTION 'V530 missing V503 business table %',table_name USING ERRCODE='55000'; END IF;
        expected_name:='trg_audit_'||table_name;
        IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=relation AND tgname=expected_name AND tgtype=5) THEN
            SELECT count(*) INTO prefixed FROM pg_trigger WHERE tgrelid=relation AND NOT tgisinternal AND tgname LIKE 'trg_audit%';
            SELECT count(*) INTO matches FROM pg_trigger t
            WHERE t.tgrelid=relation AND t.tgname=expected_name AND NOT t.tgisinternal
              AND t.tgtype=5 AND t.tgenabled IN('O','A') AND t.tgnargs=0 AND t.tgqual IS NULL
              AND t.tgattr=''::int2vector AND NOT t.tgdeferrable AND NOT t.tginitdeferred AND t.tgconstraint=0
              AND t.tgoldtable IS NULL AND t.tgnewtable IS NULL
              AND t.tgfoid='public.fn_audit()'::regprocedure;
            IF prefixed<>1 OR matches<>1 THEN
                RAISE EXCEPTION 'V530 unrecognized V503 audit trigger on public.%',table_name USING ERRCODE='55000';
            END IF;
            EXECUTE format('DROP TRIGGER %I ON public.%I',expected_name,table_name);
            EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION fn_audit()',expected_name,table_name);
            EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I',table_name,expected_name);
        END IF;
    END LOOP;
END;
$known_v503_audit$;

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
