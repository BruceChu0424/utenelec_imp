-- Preserve every old successful result/hash/identity byte. Missing original bodies
-- on installed receipts are verified against the caller's exact original hash;
-- they are never reconstructed from current documents or backfilled by guess.
ALTER TABLE finance_batch_entry_commands
 ADD COLUMN outcome text NOT NULL DEFAULT 'SUCCEEDED',
 ADD COLUMN original_body jsonb;
ALTER TABLE finance_batch_entry_commands ADD CONSTRAINT ck_finance_batch_command_outcome
 CHECK(outcome IN('SUCCEEDED','CANCELLED_UNWRITTEN'));
ALTER TABLE finance_batch_entry_commands ADD CONSTRAINT ck_finance_batch_command_original_body
 CHECK((original_body IS NULL OR jsonb_typeof(original_body)='object')
   AND (outcome='SUCCEEDED' OR original_body IS NOT NULL));
-- Use the established immutable receipt guard; no late request can erase its
-- cancellation fence, and no update may reinterpret an old successful batch.
CREATE TRIGGER finance_batch_entry_commands_immutable
 BEFORE UPDATE OR DELETE ON finance_batch_entry_commands
 FOR EACH ROW EXECUTE FUNCTION fn_finance_application_events_immutable();
-- Native command evidence remains private. Actual documents keep their own
-- business audit; the original body/result is not copied to general row audit.
SELECT public.fn_audit_track_table('finance_batch_entry_commands','NONE','data_change',false);
