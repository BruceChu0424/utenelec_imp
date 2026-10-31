-- V973/V974 have already been applied and remain byte-for-byte immutable.
-- These are mutable financial decisions, so use the same FULL/data_change
-- policy as the existing financial documents. The shared registration removes
-- only audit-function triggers by OID, retaining business guards and history.
SELECT public.fn_audit_track_table('finance_report_line_confirmations', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_asset_recognition_reversals', 'FULL', 'data_change', false, NULL, true, NULL);
