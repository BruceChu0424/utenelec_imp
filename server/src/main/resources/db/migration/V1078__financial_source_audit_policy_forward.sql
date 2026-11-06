-- Add only reviewed identity/reversal/source-coordinate metadata to Main V1059.
-- Preserve its private changed-key tracking/minimizer and all existing registrations.
-- No FULL re-registration, volatile updated_at, document numbers, private bodies,
-- monetary values or command results are added to general audit.
DO $require_main_financial_minimizer$
BEGIN
 IF strpos(pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure),'financial_subversion_private_changes_v1')=0 THEN
  RAISE EXCEPTION 'Main financial private-change minimizer must remain in force';
 END IF;
END;
$require_main_financial_minimizer$;

SELECT public.fn_audit_track_table('finance_accounting_import_batches','COLUMN_SCOPED','data_change',false,ARRAY['id','actor_id','sha256','status','row_version','submitted_by','submitted_at','approved_by','approved_at','paired_import_id','created_at','kind','reversed_at','reversed_by'],true,NULL);
SELECT public.fn_audit_track_table('finance_gl_entry_allocations','COLUMN_SCOPED','data_change',false,ARRAY['entry_id','allocation_no','account_code','currency_id','original_currency_id','auxiliary_id','auxiliary_role','party_id_snapshot','created_at','created_by','source_row'],true,NULL);
SELECT public.fn_audit_track_table('finance_gl_auxiliary_opening_evidence','COLUMN_SCOPED','data_change',false,ARRAY['id','import_batch_id','account_code','auxiliary_id','currency_id','original_currency_id','effective_from','entry_id','auxiliary_role','party_id_snapshot','source_sha256','submitted_by','approved_by','approved_at','source_row'],true,NULL);
SELECT public.fn_refresh_finance_audit_metadata_projection();
