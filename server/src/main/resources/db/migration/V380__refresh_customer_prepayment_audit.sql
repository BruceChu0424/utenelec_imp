-- V380: full future-write audit sweep after customer prepayment tables.
DO $$
DECLARE r RECORD; prefixed_trigger_count INTEGER; valid_trigger_count INTEGER; missing TEXT;
BEGIN
  FOR r IN
    SELECT c.oid,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind IN('r','p') AND NOT c.relispartition
      AND c.relname NOT IN(
        'audit_log','audit_log_archive','flyway_schema_history','spatial_ref_sys',
        'authorization_state','doc_number_sequences','master_code_sequences',
        'category_master_code_sequences','business_document_sequences',
        'production_product_no_sequences','report_materialized_view_refresh_state',
        'password_history','refresh_tokens','visitor_refresh_tokens','visitor_sms_codes')
      AND c.relname NOT LIKE 'legacy_migration_%' ORDER BY c.relname
  LOOP
    SELECT count(*), count(*) FILTER (WHERE t.tgenabled IN ('O', 'A')
      AND (t.tgtype::INTEGER & 1)=1 AND (t.tgtype::INTEGER & 2)=0
      AND (t.tgtype::INTEGER & 4)=4 AND (t.tgtype::INTEGER & 8)=8
      AND (t.tgtype::INTEGER & 16)=16 AND pn.nspname='public'
      AND p.proname IN('fn_audit','fn_audit_redacted'))
    INTO prefixed_trigger_count,valid_trigger_count
    FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
    JOIN pg_namespace pn ON pn.oid=p.pronamespace
    WHERE t.tgrelid=r.oid AND NOT t.tgisinternal AND t.tgname LIKE 'trg_audit%';
    IF prefixed_trigger_count = 1 AND valid_trigger_count = 1 THEN CONTINUE; END IF;
    IF prefixed_trigger_count>0 THEN RAISE EXCEPTION
      'public.% has % trg_audit* triggers but exactly one valid audit trigger is required (valid=%)',
      r.relname,prefixed_trigger_count,valid_trigger_count USING ERRCODE='55000'; END IF;
    EXECUTE format('CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
      'FOR EACH ROW EXECUTE FUNCTION fn_audit()',r.relname);
  END LOOP;
  SELECT string_agg(c.relname,', ' ORDER BY c.relname) INTO missing
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind IN('r','p') AND NOT c.relispartition
    AND c.relname NOT IN(
      'audit_log','audit_log_archive','flyway_schema_history','spatial_ref_sys',
      'authorization_state','doc_number_sequences','master_code_sequences',
      'category_master_code_sequences','business_document_sequences',
      'production_product_no_sequences','report_materialized_view_refresh_state',
      'password_history','refresh_tokens','visitor_refresh_tokens','visitor_sms_codes')
    AND c.relname NOT LIKE 'legacy_migration_%'
    AND ((SELECT count(*) FROM pg_trigger t WHERE t.tgrelid=c.oid
      AND NOT t.tgisinternal AND t.tgname LIKE 'trg_audit%')<>1
      OR (SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
        JOIN pg_namespace pn ON pn.oid=p.pronamespace
        WHERE t.tgrelid=c.oid AND NOT t.tgisinternal AND t.tgname LIKE 'trg_audit%'
          AND t.tgenabled IN ('O', 'A') AND (t.tgtype::INTEGER & 1)=1
          AND (t.tgtype::INTEGER & 2)=0 AND (t.tgtype::INTEGER & 4)=4
          AND (t.tgtype::INTEGER & 8)=8 AND (t.tgtype::INTEGER & 16)=16
          AND pn.nspname='public' AND p.proname IN('fn_audit','fn_audit_redacted'))<>1);
  IF missing IS NOT NULL THEN RAISE EXCEPTION
    'Audit trigger coverage remains invalid for: %',missing USING ERRCODE='55000'; END IF;
END $$;
