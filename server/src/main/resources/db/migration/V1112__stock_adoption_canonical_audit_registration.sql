-- V1108/V1109 are frozen source. Keep their four FULL decisions and business
-- guards/history, and replace only row-audit triggers through the canonical owner.
SELECT public.fn_audit_track_table('preplan_sales_stock_adoptions', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('preplan_physical_stock_claim_commands', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('preplan_physical_stock_claim_allocations', 'FULL', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('preplan_physical_stock_formalizations', 'FULL', 'data_change', false, NULL, true, NULL);
