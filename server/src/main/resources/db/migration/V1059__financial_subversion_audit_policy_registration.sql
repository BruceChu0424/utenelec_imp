-- Forward-only normalization of financial tables introduced by V999_1..V999_13.
-- Applied migration bytes and existing audit rows are immutable. The shared
-- registration removes only audit-function triggers by OID; all business,
-- immutable-source, authorization, reconciliation and FK guards stay intact.
-- The central audit retains identity, actor, approval state, version and source
-- fingerprints, plus redacted changed-key names. Private names, amounts, source previews, paths, snapshots and free text
-- remain behind their original financial-source permissions.
-- Existing explicit scopes retain their exact columns/category; formerly FULL
-- private-source tables receive reviewed metadata-only scopes. Technical revision
-- counters and result-only coordination receipts remain NONE.

-- Keep private-value edits observable without copying those values. The existing
-- fn_audit writer already emits _redacted_changes when a tracked key is removed
-- by its shared minimizer. Only these reviewed formerly-FULL financial tables
-- track private decision keys; this final minimizer strips their values for all
-- INSERT/UPDATE/DELETE payloads. Volatile-key handling stays unchanged.
DO $financial_subversion_private_changes$
DECLARE definition text;anchor text:='RETURN v_row;';projection text;
BEGIN
 SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure) INTO definition;
 IF strpos(definition,'finance_source_payload_guard_v1')=0
    OR strpos(definition,'financial_subversion_private_changes_v1')<>0
    OR (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Review the canonical financial audit minimizer before registering private decision changes';
 END IF;
 projection:=$private_projection$
    -- financial_subversion_private_changes_v1: keep changed key names, never values.
    v_row:=v_row-CASE p_table_name
            WHEN 'finance_auxiliary_parties' THEN ARRAY['source_system','source_code','source_name']
            WHEN 'finance_auxiliary_items' THEN ARRAY['source_system','source_code','source_name','source_reference']
            WHEN 'finance_account_auxiliary_rules' THEN ARRAY['source_reference']
            WHEN 'finance_sales_cost_inputs' THEN ARRAY['tax_rate','freight_local','exchange_rate','source_reference','client_name_snapshot','seller_name_snapshot','region_snapshot','director_snapshot']
            WHEN 'finance_plastic_template_inputs' THEN ARRAY['weight_kg_per_unit','material_name','reject_return_qty','reject_issue_qty','reason','source_reference']
            WHEN 'finance_material_order_references' THEN ARRAY['order_no','source_reference']
            WHEN 'finance_copper_template_inputs' THEN ARRAY['source_reference']
            WHEN 'finance_asset_template_metadata' THEN ARRAY['party_name','unit_specification','location_caption','category_caption','usage_caption','source_month','first_level_caption','second_level_caption','acceptance_caption','source_reference']
            WHEN 'finance_asset_opening_groups' THEN ARRAY['zero_balance_evidence','source_entry_snapshot','member_snapshot','reason','revoke_reason']
            WHEN 'finance_asset_opening_members' THEN ARRAY['source_sheet','original_amount','accumulated_amount','remaining_months','nominal_monthly_amount']
            WHEN 'finance_procurement_ap_policy' THEN ARRAY['source_reference']
            WHEN 'finance_procurement_ap_recognitions' THEN ARRAY['source_reference','counterpart_confirmed_by','file_provider','file_key','file_version','file_size','file_name','file_content_type','reverse_reason']
            ELSE ARRAY[]::text[] END;
    RETURN v_row;
$private_projection$;
 EXECUTE replace(definition,anchor,projection);
END;
$financial_subversion_private_changes$;

SELECT public.fn_audit_track_table('finance_chart_imports', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','actor_id','sha256','applied_at','created_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_chart_codes', 'COLUMN_SCOPED', 'data_change', false, ARRAY['code','native_style_id','source_import_id','source_kind','classification','currency_id','row_version','mapping_fingerprint','updated_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_chart_manual_operations', 'COLUMN_SCOPED', 'data_change', false, ARRAY['request_id','actor_id','fingerprint','created_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_chart_code_styles', 'COLUMN_SCOPED', 'data_change', false, ARRAY['code','style_id','created_at','created_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_chart_owned_bindings', 'COLUMN_SCOPED', 'data_change', false, ARRAY['code','style_id','line_key'], true, NULL);
SELECT public.fn_audit_track_table('finance_accounting_import_batches', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','actor_id','sha256','status','row_version','submitted_by','submitted_at','approved_by','approved_at','paired_import_id','created_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_voucher_evidence', 'COLUMN_SCOPED', 'data_change', false, ARRAY['voucher_id','import_batch_id','purpose','source_sha256','submitted_by','approved_by','approved_at','reversed_voucher_id'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_entry_allocations', 'COLUMN_SCOPED', 'data_change', false, ARRAY['entry_id','allocation_no','account_code','currency_id','original_currency_id','auxiliary_id','auxiliary_role','party_id_snapshot','created_at','created_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_period_versions', 'NONE', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_accounting_period_coverage', 'COLUMN_SCOPED', 'data_change', false, ARRAY['period','entries_revision','source_kind','import_batch_id','source_sha256','verified_by','verified_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_auxiliary_opening_evidence', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','import_batch_id','account_code','auxiliary_id','currency_id','original_currency_id','effective_from','entry_id','auxiliary_role','party_id_snapshot','source_sha256','submitted_by','approved_by','approved_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_accounting_review_operations', 'COLUMN_SCOPED', 'data_change', false, ARRAY['request_id','actor_id','import_id','action','fingerprint','created_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_gl_opening_baselines', 'COLUMN_SCOPED', 'data_change', false, ARRAY['effective_from','import_batch_id','source_sha256','verified_by','verified_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_auxiliary_parties', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','row_version','created_at','created_by','updated_by','source_system','source_code','source_name'], true, NULL);
SELECT public.fn_audit_track_table('finance_auxiliary_items', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','role','party_id','client_id','supplier_id','employee_id','financial_party_id','status','row_version','created_at','created_by','updated_by','source_system','source_code','source_name','source_reference'], true, NULL);
SELECT public.fn_audit_track_table('finance_account_auxiliary_rules', 'COLUMN_SCOPED', 'data_change', false, ARRAY['account_code','required','allowed_roles','row_version','updated_by','source_reference'], true, NULL);
SELECT public.fn_audit_track_table('finance_account_auxiliary_bindings', 'COLUMN_SCOPED', 'data_change', false, ARRAY['account_code','auxiliary_id','created_at','created_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_statement_source_reviews', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','actor_id','kind','currency_id','date_from','date_to','sha256','currency_mapping_fingerprint','created_at','directory_applied_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_sales_cost_inputs', 'COLUMN_SCOPED', 'data_change', false, ARRAY['period','client_id','channel','confirmed','row_version','updated_by','tax_rate','freight_local','exchange_rate','source_reference','client_name_snapshot','seller_name_snapshot','region_snapshot','director_snapshot'], true, NULL);
SELECT public.fn_audit_track_table('finance_plastic_template_inputs', 'COLUMN_SCOPED', 'data_change', false, ARRAY['period_line_id','source_close_id','source_unit_id','template_row','confirmed','row_version','updated_by','weight_kg_per_unit','material_name','reject_return_qty','reject_issue_qty','reason','source_reference'], true, NULL);
SELECT public.fn_audit_track_table('finance_material_order_references', 'COLUMN_SCOPED', 'data_change', false, ARRAY['requisition_id','confirmed','row_version','updated_by','order_no','source_reference'], true, NULL);
SELECT public.fn_audit_track_table('finance_cost_input_operations', 'NONE', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_copper_template_inputs', 'COLUMN_SCOPED', 'data_change', false, ARRAY['source_line_id','supplier_id','goods_id','section_key','confirmed','row_version','updated_by','source_reference'], true, NULL);
SELECT public.fn_audit_track_table('finance_template_sources', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','actor_id','template_key','period','sha256','source_selection'], true, NULL);
SELECT public.fn_audit_track_table('finance_asset_template_metadata', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','object_type','object_id','valid_from','document_date','confirmed','row_version','created_at','created_by','updated_by','party_name','unit_specification','location_caption','category_caption','usage_caption','source_month','first_level_caption','second_level_caption','acceptance_caption','source_reference'], true, NULL);
SELECT public.fn_audit_track_table('finance_asset_template_operations', 'NONE', 'data_change', false, NULL, true, NULL);
SELECT public.fn_audit_track_table('finance_asset_opening_groups', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','actor_id','source_import_id','source_voucher_id','as_of','source_voucher_ids','fingerprint','status','approved_by','approved_at','revoke_actor_id','revoke_approved_by','revoked_at','row_version','created_at','zero_balance_evidence','source_entry_snapshot','member_snapshot','reason','revoke_reason'], true, NULL);
SELECT public.fn_audit_track_table('finance_asset_opening_members', 'COLUMN_SCOPED', 'data_change', false, ARRAY['group_id','object_type','object_id','source_row','source_sha256','cost_style_id','accumulated_style_id','active','source_sheet','original_amount','accumulated_amount','remaining_months','nominal_monthly_amount'], true, NULL);
SELECT public.fn_audit_track_table('finance_asset_opening_entry_claims', 'COLUMN_SCOPED', 'data_change', false, ARRAY['entry_id','group_id'], true, NULL);
SELECT public.fn_audit_track_table('finance_asset_template_history', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','group_id','object_type','object_id','period_from','period_to','source_import_id','source_row','source_column'], true, NULL);
SELECT public.fn_audit_track_table('finance_sales_expense_groups', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','period','employee_id','channel','sales_confirmed','reviewed','sort_order','request_fingerprint','updated_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_sales_expense_assignments', 'COLUMN_SCOPED', 'data_change', false, ARRAY['entry_id','period','source_fingerprint','request_fingerprint','updated_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_expense_analysis_periods', 'COLUMN_SCOPED', 'data_change', false, ARRAY['period','policy_confirmed','locked','updated_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_operating_report_notes', 'COLUMN_SCOPED', 'data_change', false, ARRAY['period','line_key','updated_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_expense_note_imports', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','actor_id','period','sha256','applied_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_manufacturing_labor_splits', 'COLUMN_SCOPED', 'data_change', false, ARRAY['period','source_fingerprint','request_fingerprint','reviewed','updated_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_procurement_ap_policy', 'COLUMN_SCOPED', 'data_change', false, ARRAY['singleton','enabled','effective_from','row_version','updated_by','source_reference'], true, NULL);
SELECT public.fn_audit_track_table('finance_procurement_payable_routes', 'COLUMN_SCOPED', 'data_change', false, ARRAY['source_type','source_id','policy_version','approved_on','created_by','created_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_procurement_payable_candidates', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','source_type','source_id','commercial_date','accrual_date','due_date','supplier_id','currency_id','settlement_method_id','inventory_style_id','pending_style_id','pending_account_code','pending_accounting_currency_id','auxiliary_id','source_fingerprint','pending_voucher_id','pending_reversal_voucher_id','status','ledger_id','recognition_id','created_by','created_at','source_reversed_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_procurement_ap_recognitions', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','request_id','payload_hash','supplier_id','currency_id','effective_date','counterpart_confirmed_date','file_sha256','submitted_by','created_at','status','approved_by','approved_at','reversed_by','reversed_at','source_reference','counterpart_confirmed_by','file_provider','file_key','file_version','file_size','file_name','file_content_type','reverse_reason'], true, NULL);
SELECT public.fn_audit_track_table('finance_procurement_ap_recognition_lines', 'COLUMN_SCOPED', 'data_change', false, ARRAY['recognition_id','candidate_id','ledger_id','voucher_id','reversal_voucher_id','source_fingerprint'], true, NULL);
SELECT public.fn_audit_track_table('finance_application_settings', 'COLUMN_SCOPED', 'authorization', false, ARRAY['id','enabled','enabled_at','updated_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_application_enable_periods', 'COLUMN_SCOPED', 'authorization', false, ARRAY['id','enabled_at','disabled_at','actor_id'], true, NULL);
SELECT public.fn_audit_track_table('finance_application_role_bindings', 'COLUMN_SCOPED', 'authorization', false, ARRAY['id','role_key','department_id','employee_id','updated_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_applications', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','application_no','kind','source_kind','source_id','status','current_step','submission_round','source_fingerprint','payroll_instruction_fingerprint','submitted_at','approved_at','approved_by','created_by','updated_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_application_nodes', 'COLUMN_SCOPED', 'data_change', false, ARRAY['application_id','submission_round','step_no','role_key','action','status','decided_by','decided_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_application_events', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','application_id','submission_round','event_type','step_no','actor_id','actor_employee_id','occurred_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_application_operations', 'COLUMN_SCOPED', 'data_change', false, ARRAY['request_id','application_id','actor_id','operation','payload_hash','created_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_application_executions', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','application_id','submission_round','request_id','doc_type','doc_id','state','paid_by','paid_at','confirmed_by','confirmed_at','reversed_by','reversed_at'], true, NULL);
SELECT public.fn_audit_track_table('finance_expense_application_links', 'COLUMN_SCOPED', 'data_change', false, ARRAY['claim_id','kind','travel_application_id','application_id','created_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_supplier_settlement_dependencies', 'COLUMN_SCOPED', 'data_change', false, ARRAY['payment_line_id','offset_id','ledger_id','relation','created_at','created_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_open_item_classification_batches', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','request_id','ledger_id','revision','direction','party_id','currency_id','effective_from','fingerprint','created_at','created_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_open_item_classification_parts', 'COLUMN_SCOPED', 'data_change', false, ARRAY['batch_id','category'], true, NULL);
SELECT public.fn_audit_track_table('finance_payment_classification_batches', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','request_id','payment_line_id','revision','source_classification_id','currency_id','fingerprint','created_at','created_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_payment_classification_parts', 'COLUMN_SCOPED', 'data_change', false, ARRAY['batch_id','category'], true, NULL);
SELECT public.fn_audit_track_table('finance_supplier_offset_classification_batches', 'COLUMN_SCOPED', 'data_change', false, ARRAY['id','request_id','offset_id','revision','source_classification_id','target_classification_id','fingerprint','created_at','created_by'], true, NULL);
SELECT public.fn_audit_track_table('finance_supplier_offset_classification_parts', 'COLUMN_SCOPED', 'data_change', false, ARRAY['batch_id','source_category','target_category'], true, NULL);

-- Refresh the immutable INSERT/DELETE minimizer from these same registrations.
SELECT public.fn_refresh_finance_audit_metadata_projection();
