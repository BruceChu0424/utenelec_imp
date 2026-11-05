-- Forward-only adoption of the shared payment-style reference protocol for
-- financial relations introduced by V999_1..V1023. No source rows, historical
-- snapshots, amounts, UUIDs, classifications or already-applied migrations change.
--
-- New/changed non-null references take V674's SHARED hierarchy key. They also
-- lock the actual style tuple before checking its live identity, so a direct
-- concurrent soft delete cannot commit between validation and reference storage.
-- Unchanged historical references retain the existing early return.
DO $payment_style_reference_target_lock$
DECLARE definition text;anchor text:='AND COALESCE(style.is_deleted, FALSE) = FALSE;';
BEGIN
 SELECT pg_get_functiondef('public.fn_guard_payment_style_reference()'::regprocedure) INTO definition;
 IF strpos(definition,'pg_advisory_xact_lock_shared')=0
    OR (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>2 THEN
  RAISE EXCEPTION 'Review the canonical shared payment-style reference guard before adding target locks';
 END IF;
 EXECUTE replace(definition,anchor,'AND COALESCE(style.is_deleted, FALSE) = FALSE FOR SHARE;');
END;
$payment_style_reference_target_lock$;

-- These are source mappings, draft configurations and frozen accounting facts.
-- They may retain a disabled style or a mapped parent. Their owning native
-- approval/source/role guards keep all existing active/leaf/role-specific rules;
-- the new shared guards do not turn historical correspondence into live choices.
-- Fixed ACCOUNT/LIABILITY/EXPENSE roles are explicit. Empty category is deliberate
-- for cross-category chart aliases, general GL scopes, configured posting roles,
-- cost/expense allocation legs, original fee counterparts, frozen FX roles and
-- procurement pending sources (receipt GRNI is LIABILITY; a return credit is ACCOUNT).

CREATE TRIGGER trg_psref_fin_chart_native
 BEFORE INSERT OR UPDATE OF native_style_id ON finance_chart_codes
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('native_style_id','','false','false','false','false');

CREATE TRIGGER trg_psref_fin_chart_style
 BEFORE INSERT OR UPDATE OF style_id ON finance_chart_code_styles
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','','false','false','false','false');

CREATE TRIGGER trg_psref_fin_chart_owned_style
 BEFORE INSERT OR UPDATE OF style_id ON finance_chart_owned_bindings
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','','false','false','false','false');

CREATE TRIGGER trg_psref_fin_asset_opening_cost
 BEFORE INSERT OR UPDATE OF cost_style_id ON finance_asset_opening_members
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('cost_style_id','ACCOUNT','false','false','false','false');

CREATE TRIGGER trg_psref_fin_asset_opening_accum
 BEFORE INSERT OR UPDATE OF accumulated_style_id ON finance_asset_opening_members
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('accumulated_style_id','ACCOUNT','false','false','false','false');

CREATE TRIGGER trg_psref_fin_gl_settlement_scope
 BEFORE INSERT OR UPDATE OF style_id ON finance_gl_settlement_scopes
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','','false','false','false','false');

CREATE TRIGGER trg_psref_fin_native_posting_config
 BEFORE INSERT OR UPDATE OF style_id ON finance_native_posting_configurations
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','','false','false','false','false');

CREATE TRIGGER trg_psref_fin_payable_adjust_counter
 BEFORE INSERT OR UPDATE OF counterpart_style_id ON finance_payable_statement_adjustment_lines
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('counterpart_style_id','','false','false','false','false');

CREATE TRIGGER trg_psref_fin_payroll_accrual_wage
 BEFORE INSERT OR UPDATE OF wage_style_id ON finance_payroll_accruals
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('wage_style_id','LIABILITY','false','false','false','false');

CREATE TRIGGER trg_psref_fin_payroll_accrual_expense
 BEFORE INSERT OR UPDATE OF expense_style_id ON finance_payroll_accrual_lines
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('expense_style_id','','false','false','false','false');

CREATE TRIGGER trg_psref_fin_payroll_attempt_fee
 BEFORE INSERT OR UPDATE OF fee_style_id ON finance_payroll_payment_attempts
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('fee_style_id','EXPENSE','false','false','false','false');

CREATE TRIGGER trg_psref_fin_procurement_inventory
 BEFORE INSERT OR UPDATE OF inventory_style_id ON finance_procurement_payable_candidates
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('inventory_style_id','ACCOUNT','false','false','false','false');

CREATE TRIGGER trg_psref_fin_procurement_pending
 BEFORE INSERT OR UPDATE OF pending_style_id ON finance_procurement_payable_candidates
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('pending_style_id','','false','false','false','false');

CREATE TRIGGER trg_psref_fin_supplier_advance_asset
 BEFORE INSERT OR UPDATE OF style_id ON finance_supplier_advances
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('style_id','ACCOUNT','false','false','false','false');

CREATE TRIGGER trg_psref_fin_advance_refund_bank
 BEFORE INSERT OR UPDATE OF bank_style_id ON finance_supplier_advance_refunds
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('bank_style_id','ACCOUNT','false','false','false','false');

CREATE TRIGGER trg_psref_fin_advance_refund_fee
 BEFORE INSERT OR UPDATE OF fee_style_id ON finance_supplier_advance_refunds
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('fee_style_id','EXPENSE','false','false','false','false');

CREATE TRIGGER trg_psref_fin_advance_refund_fx
 BEFORE INSERT OR UPDATE OF fx_style_id ON finance_supplier_advance_refunds
 FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference('fx_style_id','','false','false','false','false');
