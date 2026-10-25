-- ADR-105: these immutable closure-result rows are append-only ledgers.
-- The approved parent case and its semantic event retain the reviewer, time,
-- reason and snapshot fingerprint. Child rows retain the exact released source
-- and peg quantities; V923 guards reject every UPDATE/DELETE and bind inserts
-- to that approved decision in the same transaction.
-- Correct only future row-audit registration. Preserve V923 bytes, all fact and
-- quantity guards, the parent decision/event trail and existing audit records.
SELECT fn_audit_track_table('procurement_order_termination_sources','NONE','data_change',false);
SELECT fn_audit_track_table('procurement_order_termination_peg_changes','NONE','data_change',false);
