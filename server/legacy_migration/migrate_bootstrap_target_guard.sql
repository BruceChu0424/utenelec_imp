-- First bootstrap only. This complete schema inventory is independent of the retired
-- runtime reset capability (V919). It performs read-only emptiness checks only.
-- New public root tables require an explicit EMPTY or SEED_OR_ADMIN classification.
-- No business reset function, source-table clearing, or constraint bypass is used.
DO $$
DECLARE
    clear_tables text[];
    clear_table text;
    unknown_tables text;
    missing_tables text;
    occupied boolean;
BEGIN
    -- V182 itself records a zero-source schema audit on a fresh database.
    -- Preserve that exact successful audit; it is not a previous business import.
    IF EXISTS (SELECT 1 FROM legacy_migration_runs run WHERE
        run.run_id IS DISTINCT FROM NULLIF(current_setting('uten.bootstrap_run_id',true),'')::uuid
        AND (run.status = 'FAILED' AND run.target='--bootstrap-all' AND run.migration_mode='BOOTSTRAP'
            AND run.finished_at IS NOT NULL AND run.exit_code IS NOT NULL
            AND run.mapping_version=current_setting('uten.bootstrap_mapping_version',true)
            AND run.migration_repository_commit=current_setting('uten.bootstrap_repository_commit',true)
            AND run.export_manifest_sha256=current_setting('uten.bootstrap_manifest_sha',true)
            AND run.reconciliation_summary->>'targetDatabase'=current_database()
            AND run.reconciliation_summary->>'targetSystemIdentifier'=(SELECT system_identifier::text FROM pg_control_system())
            AND run.reconciliation_summary->>'targetApprovalReference' IS NOT NULL
            AND run.reconciliation_summary->>'importAtomicity' = 'single-transaction-v1') IS NOT TRUE
        AND (run.target = 'schema:V182-live-master-relationships'
            AND run.migration_mode = 'INCREMENTAL' AND run.mapping_version = 'v182-live-master-uuid-v1'
            AND run.status = 'SUCCESS' AND run.reconciliation_status = 'NOT_RUN' AND run.rejected_count=0
            AND run.reconciliation_summary->>'sourceReferenceCount' = '0'
            AND run.reconciliation_summary->>'issueCount' = '0'
            AND run.reconciliation_summary->>'failedMetricCount' = '0') IS NOT TRUE)
       OR EXISTS (SELECT 1 FROM goods)
       OR EXISTS (SELECT 1 FROM moulds)
       OR EXISTS (SELECT 1 FROM clients)
       OR EXISTS (SELECT 1 FROM suppliers)
       OR EXISTS (SELECT 1 FROM accounts)
       OR EXISTS (SELECT 1 FROM colors)
       OR EXISTS (SELECT 1 FROM units)
       OR EXISTS (SELECT 1 FROM warehouses)
       OR EXISTS (SELECT 1 FROM currencies WHERE NOT is_base_currency)
       OR EXISTS (SELECT 1 FROM employees WHERE code <> 'ADMIN' OR legacy_id IS NOT NULL)
       -- V718 脱钩后注册表不再钉货品根；按本体身份放行未分类根，其余视为脏数据。
       OR EXISTS (SELECT 1 FROM material_categories
                  WHERE NOT (legacy_id = -1 AND legacy_code_snapshot = 'LEGACY_ORPHAN'))
       OR EXISTS (SELECT 1 FROM client_categories WHERE id NOT IN (SELECT client_category_id FROM system_master_category_registry))
       OR EXISTS (SELECT 1 FROM supplier_categories WHERE id NOT IN (SELECT supplier_category_id FROM system_master_category_registry))
       OR EXISTS (SELECT 1 FROM mould_categories WHERE id NOT IN (SELECT mould_category_id FROM system_master_category_registry))
       OR (SELECT count(*) FROM users) > 1 THEN
        RAISE EXCEPTION 'bootstrap requires a fresh schema-only target; restore/recreate the disposable target after a failed or different import (runs %, goods %, clients %, suppliers %, accounts %, colors %, units %, warehouses %, extra currencies %, employees %, categories %/%/%/%)',
            (SELECT count(*) FROM legacy_migration_runs), (SELECT count(*) FROM goods),
            (SELECT count(*) FROM clients), (SELECT count(*) FROM suppliers), (SELECT count(*) FROM accounts),
            (SELECT count(*) FROM colors), (SELECT count(*) FROM units), (SELECT count(*) FROM warehouses),
            (SELECT count(*) FROM currencies WHERE NOT is_base_currency),
            (SELECT count(*) FROM employees WHERE code <> 'ADMIN' OR legacy_id IS NOT NULL),
            (SELECT count(*) FROM material_categories), (SELECT count(*) FROM client_categories),
            (SELECT count(*) FROM supplier_categories), (SELECT count(*) FROM mould_categories);
    END IF;
    -- The reviewed inventory includes the later archive/file/measurement schema
    -- through V968. Future root tables still require explicit classification.
    -- SEED_OR_ADMIN retains the existing explicit master/admin checks above;
    -- it never grants permission to reuse a previous business import.
    CREATE TEMP TABLE bootstrap_target_table_inventory (
        table_name text PRIMARY KEY,
        disposition text NOT NULL CHECK (disposition IN ('EMPTY','SEED_OR_ADMIN'))
    ) ON COMMIT DROP;
    INSERT INTO bootstrap_target_table_inventory(table_name,disposition) VALUES
        ('account_balance_adjustment_batches','EMPTY'),
        ('account_balance_adjustment_items','EMPTY'),
        ('account_flow_monthly_summaries','EMPTY'),
        ('accounts','SEED_OR_ADMIN'),
        ('ai_call_logs','EMPTY'),
        ('ai_chat_action_proposals','EMPTY'),
        ('ai_chat_operation_memory','EMPTY'),
        ('ai_input_original_bindings','EMPTY'),
        ('ai_input_originals','EMPTY'),
        ('ai_jobs','EMPTY'),
        ('ai_provider_history','EMPTY'),
        ('ai_providers','SEED_OR_ADMIN'),
        ('ai_usage_daily','EMPTY'),
        ('ai_user_limits','SEED_OR_ADMIN'),
        ('ar_ap_ledger','EMPTY'),
        ('ar_ap_source_refs','EMPTY'),
        ('attachment_object_outbox','SEED_OR_ADMIN'),
        ('attachment_reconciliation_findings','SEED_OR_ADMIN'),
        ('attachment_upload_sessions','SEED_OR_ADMIN'),
        ('attachments','SEED_OR_ADMIN'),
        ('audit_log','SEED_OR_ADMIN'),
        ('audit_log_archive','SEED_OR_ADMIN'),
        ('auth_sessions','EMPTY'),
        ('auth_step_up_states','SEED_OR_ADMIN'),
        ('authorization_state','SEED_OR_ADMIN'),
        ('business_column_definitions','SEED_OR_ADMIN'),
        ('business_column_deletions','SEED_OR_ADMIN'),
        ('business_document_sequences','SEED_OR_ADMIN'),
        ('business_identifier_conflicts','SEED_OR_ADMIN'),
        ('business_identifier_namespaces','SEED_OR_ADMIN'),
        ('business_identifier_reservation_members','SEED_OR_ADMIN'),
        ('business_identifier_reservations','SEED_OR_ADMIN'),
        ('business_outbox','EMPTY'),
        ('business_prefix_reservation_members','SEED_OR_ADMIN'),
        ('business_prefix_reservations','SEED_OR_ADMIN'),
        ('business_record_history','EMPTY'),
        ('business_record_identities','EMPTY'),
        ('business_record_retention_registry','SEED_OR_ADMIN'),
        ('category_master_code_sequences','SEED_OR_ADMIN'),
        ('client_access_change_events','SEED_OR_ADMIN'),
        ('client_categories','SEED_OR_ADMIN'),
        -- V948 co-owners are live customer responsibility assignments. The
        -- legacy import maps only the first owner into clients.owner_employee_id
        -- and never seeds this table; any row proves prior business use.
        ('client_co_owners','EMPTY'),
        ('client_default_settlement_migration_issues','SEED_OR_ADMIN'),
        ('client_goods_aliases','SEED_OR_ADMIN'),
        ('client_ship_addresses','SEED_OR_ADMIN'),
        ('client_visibility_grants','SEED_OR_ADMIN'),
        ('clients','SEED_OR_ADMIN'),
        ('colors','SEED_OR_ADMIN'),
        ('company_file_acl','EMPTY'),
        ('company_file_nodes','EMPTY'),
        ('currencies','SEED_OR_ADMIN'),
        ('customer_open_item_offset_batches','EMPTY'),
        ('customer_open_item_offsets','EMPTY'),
        ('da_amortization_log','EMPTY'),
        ('deferred_expenses','EMPTY'),
        ('department_permissions','SEED_OR_ADMIN'),
        ('departments','SEED_OR_ADMIN'),
        ('doc_number_sequences','SEED_OR_ADMIN'),
        ('document_malware_scans','SEED_OR_ADMIN'),
        ('document_unapprovals','EMPTY'),
        ('emergency_contacts','SEED_OR_ADMIN'),
        ('employee_compensation','SEED_OR_ADMIN'),
        ('employee_contracts','SEED_OR_ADMIN'),
        ('employee_credentials','SEED_OR_ADMIN'),
        ('employee_data_handover_scopes','SEED_OR_ADMIN'),
        ('employee_data_handovers','SEED_OR_ADMIN'),
        ('employee_education','SEED_OR_ADMIN'),
        -- V937 aliases are preserved identity evidence in ordinary operation.
        -- Any such evidence makes a first-bootstrap target nonempty, never reusable.
        ('employee_identity_aliases','EMPTY'),
        ('employee_offboarding_events','SEED_OR_ADMIN'),
        ('employee_phones','SEED_OR_ADMIN'),
        ('employee_reconcile_applies','SEED_OR_ADMIN'),
        ('employee_reconcile_plan_items','SEED_OR_ADMIN'),
        ('employee_reconcile_plan_rows','SEED_OR_ADMIN'),
        ('employee_reconcile_plans','SEED_OR_ADMIN'),
        ('employee_secondary_departments','SEED_OR_ADMIN'),
        ('employee_sensitive','SEED_OR_ADMIN'),
        ('employee_vehicles','SEED_OR_ADMIN'),
        ('employees','SEED_OR_ADMIN'),
        ('employment_history','SEED_OR_ADMIN'),
        ('execution_segment_sales_allocations','EMPTY'),
        ('expense_claim_events','EMPTY'),
        ('expense_claim_invoices','EMPTY'),
        ('expense_claim_items','EMPTY'),
        ('expense_claim_settings','SEED_OR_ADMIN'),
        ('expense_claims','EMPTY'),
        ('fa_depreciation_log','EMPTY'),
        ('finance_asset_accounting_periods','EMPTY'),
        ('finance_asset_approval_steps','EMPTY'),
        ('finance_asset_books','EMPTY'),
        ('finance_asset_categories','SEED_OR_ADMIN'),
        ('finance_asset_events','EMPTY'),
        ('finance_asset_posting_lines','EMPTY'),
        ('finance_asset_posting_runs','EMPTY'),
        ('finance_bank_transfer_lines','EMPTY'),
        ('finance_bank_transfers','EMPTY'),
        ('finance_check_register','EMPTY'),
        ('finance_deferral_schedule_lines','EMPTY'),
        ('finance_deferral_schedule_versions','EMPTY'),
        ('finance_expense_items','EMPTY'),
        ('finance_expenses','EMPTY'),
        ('finance_other_income_items','EMPTY'),
        ('finance_other_incomes','EMPTY'),
        ('finance_payment_lines','EMPTY'),
        ('finance_payment_methods','SEED_OR_ADMIN'),
        ('finance_payments','EMPTY'),
        ('finance_receipt_lines','EMPTY'),
        ('finance_receipt_source_allocations','EMPTY'),
        ('finance_receipts','EMPTY'),
        ('finance_reconciliations','EMPTY'),
        ('finance_report_line_bindings','SEED_OR_ADMIN'),
        ('fixed_assets','EMPTY'),
        ('flyway_schema_history','SEED_OR_ADMIN'),
        ('gl_entries','EMPTY'),
        ('gl_vouchers','EMPTY'),
        ('goods','SEED_OR_ADMIN'),
        ('goods_bom_actual_usages','SEED_OR_ADMIN'),
        ('goods_bom_items','SEED_OR_ADMIN'),
        ('goods_bom_learning_profiles','SEED_OR_ADMIN'),
        ('goods_code_lifecycles','SEED_OR_ADMIN'),
        ('goods_code_reuse_releases','SEED_OR_ADMIN'),
        ('goods_code_usage_facts','SEED_OR_ADMIN'),
        ('goods_cost_commands','SEED_OR_ADMIN'),
        ('goods_cost_import_mappings','SEED_OR_ADMIN'),
        ('goods_cost_imports','SEED_OR_ADMIN'),
        ('goods_cost_sheets','SEED_OR_ADMIN'),
        ('goods_cost_snapshots','SEED_OR_ADMIN'),
        ('goods_cost_templates','SEED_OR_ADMIN'),
        ('goods_import_batches','SEED_OR_ADMIN'),
        ('goods_import_creations','SEED_OR_ADMIN'),
        ('goods_market_reference_bindings','SEED_OR_ADMIN'),
        ('goods_material_identity_evidence','SEED_OR_ADMIN'),
        ('goods_operation_history','SEED_OR_ADMIN'),
        ('goods_operation_history_events','SEED_OR_ADMIN'),
        ('goods_operation_history_rows','SEED_OR_ADMIN'),
        ('goods_periodic_material_choices','SEED_OR_ADMIN'),
        ('goods_weight_estimates','EMPTY'),
        ('goods_weight_observations','EMPTY'),
        ('goods_weight_profiles','SEED_OR_ADMIN'),
        ('hr_task_claims','EMPTY'),
        ('inbound_expectation_items','EMPTY'),
        ('inbound_expectations','EMPTY'),
        ('inventory_cost_gl_links','EMPTY'),
        ('inventory_cost_gl_period_choices','EMPTY'),
        ('inventory_cost_gl_periods','EMPTY'),
        ('inventory_cost_gl_policy','SEED_OR_ADMIN'),
        ('legacy_departments','SEED_OR_ADMIN'),
        ('legacy_finance_import_sources','SEED_OR_ADMIN'),
        ('legacy_migration_checkpoints','SEED_OR_ADMIN'),
        ('legacy_migration_reconciliation_items','SEED_OR_ADMIN'),
        ('legacy_migration_rejects','SEED_OR_ADMIN'),
        ('legacy_migration_run_files','SEED_OR_ADMIN'),
        ('legacy_migration_runs','SEED_OR_ADMIN'),
        ('legacy_procurement_receipt_import_sources','SEED_OR_ADMIN'),
        ('legacy_production_plan_counter_import_contexts','SEED_OR_ADMIN'),
        ('legacy_production_plan_counter_import_sources','SEED_OR_ADMIN'),
        ('legacy_quantity_counter_import_sources','SEED_OR_ADMIN'),
        ('legacy_subcontract_order_import_sources','SEED_OR_ADMIN'),
        ('legacy_warehouse_workshop_links','SEED_OR_ADMIN'),
        ('manager_permission_delegations','SEED_OR_ADMIN'),
        ('master_code_change_batches','SEED_OR_ADMIN'),
        ('master_code_history','SEED_OR_ADMIN'),
        ('master_code_reservation_members','SEED_OR_ADMIN'),
        ('master_code_reservations','SEED_OR_ADMIN'),
        ('master_code_sequences','SEED_OR_ADMIN'),
        ('master_operation_history','SEED_OR_ADMIN'),
        ('master_operation_history_events','SEED_OR_ADMIN'),
        ('master_operation_history_rows','SEED_OR_ADMIN'),
        ('master_record_versions','SEED_OR_ADMIN'),
        ('material_categories','SEED_OR_ADMIN'),
        ('mould_categories','SEED_OR_ADMIN'),
        ('moulds','SEED_OR_ADMIN'),
        ('mrp_generations','EMPTY'),
        ('notice_acknowledgments','EMPTY'),
        ('notice_blessing_history','EMPTY'),
        ('notice_blessings','EMPTY'),
        ('notice_celebration_subjects','EMPTY'),
        ('notice_popup_preferences','SEED_OR_ADMIN'),
        ('notice_user_states','EMPTY'),
        ('notices','EMPTY'),
        ('organization_permission_leader_assignments','SEED_OR_ADMIN'),
        ('party_activity_records','SEED_OR_ADMIN'),
        ('party_addresses','SEED_OR_ADMIN'),
        ('party_contact_methods','SEED_OR_ADMIN'),
        ('password_history','SEED_OR_ADMIN'),
        ('payment_styles','SEED_OR_ADMIN'),
        ('payroll_batches','EMPTY'),
        ('payroll_items','EMPTY'),
        ('payroll_slips','EMPTY'),
        ('payroll_variable_inputs','EMPTY'),
        ('permission_surface_permissions','SEED_OR_ADMIN'),
        ('permission_surfaces','SEED_OR_ADMIN'),
        ('permission_templates','SEED_OR_ADMIN'),
        ('permissions','SEED_OR_ADMIN'),
        ('pii_key_rotation_runs','SEED_OR_ADMIN'),
        ('plan_draw_links','EMPTY'),
        ('plan_order_item_links','EMPTY'),
        ('platform_branding','SEED_OR_ADMIN'),
        ('platform_column_definition_deletions','SEED_OR_ADMIN'),
        ('platform_column_definitions','SEED_OR_ADMIN'),
        ('platform_column_usage','EMPTY'),
        ('platform_record_field_versions','EMPTY'),
        ('platform_record_fields','SEED_OR_ADMIN'),
        ('positions','SEED_OR_ADMIN'),
        ('preplan_aggregate_batch_events','EMPTY'),
        ('preplan_aggregate_batches','EMPTY'),
        ('preplan_aggregate_direct_transfer_slices','EMPTY'),
        ('preplan_aggregate_material_aliases','EMPTY'),
        ('preplan_analysis_stock_exact_pegs','EMPTY'),
        ('preplan_future_supply_transfer_cancellations','EMPTY'),
        ('preplan_future_supply_transfers','EMPTY'),
        ('preplan_make_entitlement_delegations','EMPTY'),
        ('preplan_make_public_claim_cancellations','EMPTY'),
        ('preplan_make_public_claims','EMPTY'),
        ('preplan_material_reallocations','EMPTY'),
        ('preplan_public_supply_events','EMPTY'),
        ('preplan_reallocation_make_supplements','EMPTY'),
        ('preplan_root_output_events','EMPTY'),
        ('preplan_stock_entitlement_events','EMPTY'),
        ('preplan_supply_action_allocations','EMPTY'),
        ('preplan_supply_actions','EMPTY'),
        ('procurement_arrival_exception_events','EMPTY'),
        ('procurement_arrival_exceptions','EMPTY'),
        ('procurement_inspection_events','EMPTY'),
        ('procurement_inspection_items','EMPTY'),
        ('procurement_iqc_consideration_reversals','EMPTY'),
        ('procurement_iqc_consideration_review_approvals','EMPTY'),
        ('procurement_iqc_credit_case_allocations','EMPTY'),
        ('procurement_iqc_credit_documents','EMPTY'),
        ('procurement_iqc_credit_slices','EMPTY'),
        ('procurement_iqc_funding_settlements','EMPTY'),
        ('procurement_iqc_funding_slices','EMPTY'),
        ('procurement_iqc_quality_consideration_parts','EMPTY'),
        ('procurement_iqc_rejection_cases','EMPTY'),
        ('procurement_iqc_rejection_commands','EMPTY'),
        ('procurement_iqc_rejection_events','EMPTY'),
        ('procurement_iqc_replacement_allocations','EMPTY'),
        ('procurement_iqc_stock_consideration_parts','EMPTY'),
        ('procurement_iqc_stock_in_batch_items','EMPTY'),
        ('procurement_iqc_stock_in_batches','EMPTY'),
        ('procurement_order_approval_cases','EMPTY'),
        ('procurement_order_approval_events','EMPTY'),
        ('procurement_order_qty_change_logs','EMPTY'),
        ('procurement_order_source_revision_allocations','EMPTY'),
        ('procurement_order_source_revision_peg_changes','EMPTY'),
        ('procurement_order_source_revisions','EMPTY'),
        ('procurement_order_termination_peg_changes','EMPTY'),
        ('procurement_order_termination_sources','EMPTY'),
        ('procurement_receipt_consideration_parts','EMPTY'),
        ('production_actual_output_supplement_claims','EMPTY'),
        ('production_actual_output_supplement_proofs','EMPTY'),
        ('production_actual_output_supplement_requests','EMPTY'),
        ('production_actual_output_supplement_reversals','EMPTY'),
        ('production_bom_learning_refresh_queue','EMPTY'),
        ('production_bom_learning_samples','EMPTY'),
        ('production_daily_report_commands','EMPTY'),
        ('production_daily_report_items','EMPTY'),
        ('production_daily_report_material_release_events','EMPTY'),
        ('production_daily_report_material_usages','EMPTY'),
        ('production_daily_report_target_events','EMPTY'),
        ('production_daily_report_workers','EMPTY'),
        ('production_daily_reports','EMPTY'),
        ('production_draw_issue_batches','EMPTY'),
        ('production_execution_material_changes','EMPTY'),
        ('production_execution_periodic_materials','EMPTY'),
        ('production_execution_segment_events','EMPTY'),
        ('production_execution_segment_growth_events','EMPTY'),
        ('production_execution_segment_notice_state','EMPTY'),
        ('production_execution_segment_splits','EMPTY'),
        ('production_execution_segments','EMPTY'),
        ('production_finished_arrival_registration_items','EMPTY'),
        ('production_finished_arrival_registration_reversals','EMPTY'),
        ('production_finished_arrival_registrations','EMPTY'),
        ('production_finished_in_confirm_batch_items','EMPTY'),
        ('production_finished_in_confirm_batches','EMPTY'),
        ('production_finished_in_confirmation_items','EMPTY'),
        ('production_finished_in_confirmation_reversal_items','EMPTY'),
        ('production_finished_in_confirmation_reversals','EMPTY'),
        ('production_finished_in_confirmations','EMPTY'),
        ('production_fqc_cancellation_events','EMPTY'),
        ('production_fqc_contribution_adjustments','EMPTY'),
        ('production_fqc_decision_events','EMPTY'),
        ('production_fqc_inspection_sheet_items','EMPTY'),
        ('production_fqc_inspection_sheets','EMPTY'),
        ('production_fqc_inspections','EMPTY'),
        ('production_fqc_legacy_exemptions','EMPTY'),
        ('production_fqc_lot_decision_commands','EMPTY'),
        ('production_fqc_pass_all_batch_items','EMPTY'),
        ('production_fqc_pass_all_batches','EMPTY'),
        ('production_fqc_recovery_allocation_events','EMPTY'),
        ('production_fqc_recovery_authorizations','EMPTY'),
        ('production_fqc_recovery_cancellation_events','EMPTY'),
        ('production_fqc_release_allocations','EMPTY'),
        ('production_fqc_release_commands','EMPTY'),
        ('production_fqc_replenishment_analysis_links','EMPTY'),
        ('production_fqc_replenishment_attempts','EMPTY'),
        ('production_fqc_replenishment_cycle_cancellations','EMPTY'),
        ('production_fqc_replenishment_cycles','EMPTY'),
        ('production_fqc_replenishment_draw_links','EMPTY'),
        ('production_fqc_replenishment_ready_events','EMPTY'),
        ('production_fqc_replenishment_ready_reversals','EMPTY'),
        ('production_fqc_replenishment_supply_gaps','EMPTY'),
        ('production_fqc_replenishment_tasks','EMPTY'),
        ('production_material_analyses','EMPTY'),
        ('production_material_analysis_borrows','EMPTY'),
        ('production_material_analysis_commands','EMPTY'),
        ('production_material_analysis_items','EMPTY'),
        ('production_material_analysis_materials','EMPTY'),
        ('production_material_analysis_plan_links','EMPTY'),
        ('production_material_demands','EMPTY'),
        ('production_material_discovery_lines','EMPTY'),
        ('production_material_discovery_requests','EMPTY'),
        ('production_material_increment_decisions','EMPTY'),
        ('production_material_increment_requests','EMPTY'),
        ('production_material_increment_reversals','EMPTY'),
        ('production_material_make_receipt_allocations','EMPTY'),
        ('production_material_movement_links','EMPTY'),
        ('production_material_peg_transfers','EMPTY'),
        ('production_material_receipt_allocations','EMPTY'),
        ('production_material_return_receiving_confirmations','EMPTY'),
        ('production_material_return_request_cancellations','EMPTY'),
        ('production_material_return_request_items','EMPTY'),
        ('production_material_return_requests','EMPTY'),
        ('production_material_settlement_events','EMPTY'),
        ('production_material_settlement_postings','EMPTY'),
        ('production_material_stock_events','EMPTY'),
        ('production_material_stock_postings','EMPTY'),
        ('production_material_subcontract_peg_transfers','EMPTY'),
        ('production_material_subcontract_receipt_allocations','EMPTY'),
        ('production_material_supply_pegs','EMPTY'),
        ('production_over_limit_decisions','EMPTY'),
        ('production_over_limit_dispositions','EMPTY'),
        ('production_overproduction_rate_decisions','EMPTY'),
        ('production_overproduction_rate_requests','EMPTY'),
        ('production_plan_costs','EMPTY'),
        ('production_plan_items','EMPTY'),
        ('production_planning_drafts','EMPTY'),
        ('production_planning_package_document_items','EMPTY'),
        ('production_planning_package_documents','EMPTY'),
        ('production_planning_packages','EMPTY'),
        ('production_planning_urges','EMPTY'),
        ('production_plans','EMPTY'),
        ('production_product_no_sequences','EMPTY'),
        ('production_workshop_custody_handoff_reversals','EMPTY'),
        ('production_workshop_custody_reverse_preparations','EMPTY'),
        ('production_workshop_direct_legacy_anomalies','EMPTY'),
        ('production_workshop_direct_source_allocations','EMPTY'),
        ('production_workshop_direct_source_events','EMPTY'),
        ('production_workshop_direct_transfer_items','EMPTY'),
        ('production_workshop_direct_transfer_reversals','EMPTY'),
        ('production_workshop_direct_transfers','EMPTY'),
        ('production_workshop_material_custody_handoffs','EMPTY'),
        ('production_workshop_material_custody_moves','EMPTY'),
        ('production_workshop_material_custody_preparations','EMPTY'),
        ('production_workshop_material_custody_reversals','EMPTY'),
        ('production_workshop_material_return_slices','EMPTY'),
        ('production_workshop_return_preplan_events','EMPTY'),
        ('profile_change_requests','SEED_OR_ADMIN'),
        ('purchase_order_item_sources','EMPTY'),
        ('purchase_order_items','EMPTY'),
        ('purchase_orders','EMPTY'),
        ('purchase_receipt_items','EMPTY'),
        ('purchase_receipts','EMPTY'),
        ('purchase_request_items','EMPTY'),
        ('purchase_request_qty_revisions','EMPTY'),
        ('purchase_requests','EMPTY'),
        ('purchase_return_items','EMPTY'),
        ('purchase_returns','EMPTY'),
        ('rd_task_forwarders','EMPTY'),
        ('rd_tasks','EMPTY'),
        ('read_scope_change_events','EMPTY'),
        -- The fixed immutable domain catalog is installed by the migrations;
        -- any committed change event or export identity proves prior use.
        ('read_scope_domains','SEED_OR_ADMIN'),
        ('refresh_tokens','SEED_OR_ADMIN'),
        ('report_export_jobs','EMPTY'),
        ('report_materialized_view_refresh_state','SEED_OR_ADMIN'),
        ('sales_alias_document_evidence','SEED_OR_ADMIN'),
        ('sales_document_learning_receipts','EMPTY'),
        ('sales_intake_layout_learning_evidence','EMPTY'),
        ('sales_intake_layouts','SEED_OR_ADMIN'),
        ('sales_order_cost_items','EMPTY'),
        ('sales_order_items','EMPTY'),
        ('sales_order_qty_change_logs','EMPTY'),
        ('sales_order_revision_logs','EMPTY'),
        ('sales_orders','EMPTY'),
        ('sales_other_shipment_items','EMPTY'),
        ('sales_other_shipments','EMPTY'),
        ('sales_quote_customer_templates','SEED_OR_ADMIN'),
        ('sales_quote_items','EMPTY'),
        ('sales_quote_revision_logs','EMPTY'),
        ('sales_quote_template_candidate_history','EMPTY'),
        ('sales_quote_template_candidates','EMPTY'),
        ('sales_quote_template_evidence','EMPTY'),
        ('sales_quote_template_versions','SEED_OR_ADMIN'),
        ('sales_quotes','EMPTY'),
        ('sales_return_disposition_events','EMPTY'),
        ('sales_return_items','EMPTY'),
        ('sales_return_quality_events','EMPTY'),
        ('sales_return_quality_items','EMPTY'),
        ('sales_returns','EMPTY'),
        ('sales_shipment_finance_release_events','EMPTY'),
        ('sales_shipment_items','EMPTY'),
        ('sales_shipment_submission_events','EMPTY'),
        ('sales_shipment_warehouse_events','EMPTY'),
        ('sales_shipments','EMPTY'),
        ('settlement_methods','SEED_OR_ADMIN'),
        ('sms_gateway_settings','SEED_OR_ADMIN'),
        ('stock_balance_adjustment_requests','EMPTY'),
        ('stock_balances','EMPTY'),
        ('stock_count_request_events','EMPTY'),
        ('stock_count_request_lines','EMPTY'),
        ('stock_count_requests','EMPTY'),
        ('stock_document_items','EMPTY'),
        ('stock_documents','EMPTY'),
        ('stock_draw_issue_batches','EMPTY'),
        ('stock_measurement_holds','EMPTY'),
        ('stock_movements','EMPTY'),
        ('stock_reservations','EMPTY'),
        ('stock_value_acquisition_sources','EMPTY'),
        ('stock_value_edges','EMPTY'),
        ('stock_value_events','EMPTY'),
        ('stock_value_jobs','EMPTY'),
        ('stock_value_legacy_balance_case_events','EMPTY'),
        ('stock_value_legacy_balance_cases','EMPTY'),
        ('stock_value_node_revisions','EMPTY'),
        ('stock_value_nodes','EMPTY'),
        ('stock_value_openings','EMPTY'),
        ('stock_value_pools','EMPTY'),
        ('stock_value_position_transfers','EMPTY'),
        ('stock_value_postings','EMPTY'),
        ('stock_value_production_cost_dirty','EMPTY'),
        ('stock_value_production_cost_inputs','EMPTY'),
        ('stock_value_production_cost_objects','EMPTY'),
        ('stock_value_production_cost_outputs','EMPTY'),
        ('stock_value_production_cost_revisions','EMPTY'),
        ('stock_value_production_cost_shares','EMPTY'),
        ('stock_value_production_cost_tasks','EMPTY'),
        ('stock_value_tasks','EMPTY'),
        ('stock_weight_adjustments','EMPTY'),
        ('subcontract_application_items','EMPTY'),
        ('subcontract_application_kit_notice_marks','EMPTY'),
        ('subcontract_applications','EMPTY'),
        ('subcontract_component_stock_handoffs','EMPTY'),
        ('subcontract_draw_notice_marks','EMPTY'),
        ('subcontract_inquiries','EMPTY'),
        ('subcontract_inquiry_items','EMPTY'),
        ('subcontract_loss_case_lines','EMPTY'),
        ('subcontract_loss_cases','EMPTY'),
        ('subcontract_loss_events','EMPTY'),
        ('subcontract_loss_fulfillment_allocations','EMPTY'),
        ('subcontract_loss_resolutions','EMPTY'),
        ('subcontract_material_issue_items','EMPTY'),
        ('subcontract_material_issues','EMPTY'),
        ('subcontract_material_plan_items','EMPTY'),
        ('subcontract_material_plans','EMPTY'),
        ('subcontract_material_return_items','EMPTY'),
        ('subcontract_material_returns','EMPTY'),
        ('subcontract_order_cost_items','EMPTY'),
        ('subcontract_order_item_sources','EMPTY'),
        ('subcontract_order_items','EMPTY'),
        ('subcontract_orders','EMPTY'),
        ('subcontract_outbound_issue_reservation_allocations','EMPTY'),
        ('subcontract_receipt_items','EMPTY'),
        ('subcontract_receipt_material_consumptions','EMPTY'),
        ('subcontract_receipts','EMPTY'),
        ('subcontract_return_items','EMPTY'),
        ('subcontract_returns','EMPTY'),
        ('subcontract_selected_outbound_commands','EMPTY'),
        ('subcontract_selected_outbound_items','EMPTY'),
        ('subcontract_short_delivery_case_events','EMPTY'),
        ('subcontract_short_delivery_cases','EMPTY'),
        ('subcontract_waste_items','EMPTY'),
        ('subcontract_wastes','EMPTY'),
        ('subplan_links','EMPTY'),
        ('suggestion_likes','EMPTY'),
        ('suggestion_replies','EMPTY'),
        ('suggestions','EMPTY'),
        ('supplier_categories','SEED_OR_ADMIN'),
        ('supplier_claim_cash_receipts','EMPTY'),
        ('supplier_claim_receivables','EMPTY'),
        ('supplier_open_item_offsets','EMPTY'),
        ('supplier_return_tasks','EMPTY'),
        ('supplier_settlement_batch_events','EMPTY'),
        ('supplier_settlement_batch_lines','EMPTY'),
        ('supplier_settlement_batches','EMPTY'),
        ('suppliers','SEED_OR_ADMIN'),
        ('system_master_category_registry','SEED_OR_ADMIN'),
        ('system_posting_style_roles','SEED_OR_ADMIN'),
        ('system_settings','SEED_OR_ADMIN'),
        ('task_claims','EMPTY'),
        ('unit_measurement_profiles','SEED_OR_ADMIN'),
        ('units','SEED_OR_ADMIN'),
        ('user_data_scopes','SEED_OR_ADMIN'),
        ('user_permission_overrides','SEED_OR_ADMIN'),
        ('user_preferences','SEED_OR_ADMIN'),
        ('users','SEED_OR_ADMIN'),
        ('visitor_accounts','EMPTY'),
        ('visitor_applications','EMPTY'),
        ('visitor_approval_steps','EMPTY'),
        ('visitor_refresh_tokens','EMPTY'),
        ('visitor_sms_codes','EMPTY'),
        ('warehouse_arrival_exception_stock_in_batch_items','EMPTY'),
        ('warehouse_arrival_exception_stock_in_batches','EMPTY'),
        ('warehouse_arrival_registration_commands','EMPTY'),
        ('warehouse_goods_place_preferences','EMPTY'),
        ('warehouse_keepers','SEED_OR_ADMIN'),
        ('warehouses','SEED_OR_ADMIN'),
        ('website_bridge_status','SEED_OR_ADMIN'),
        ('website_inquiries','EMPTY'),
        ('website_inquiry_events','EMPTY'),
        ('website_management_settings','SEED_OR_ADMIN'),
        ('workshop_bins','SEED_OR_ADMIN'),
        ('workshop_machine_containers','SEED_OR_ADMIN'),
        ('workshop_machines','SEED_OR_ADMIN'),
        ('workshop_material_close_allocations','EMPTY'),
        ('workshop_material_close_materials','EMPTY'),
        ('workshop_material_close_theory_lines','EMPTY'),
        ('workshop_material_commands','EMPTY'),
        ('workshop_material_count_adjustment_postings','EMPTY'),
        ('workshop_material_count_lines','EMPTY'),
        ('workshop_material_count_postings','EMPTY'),
        ('workshop_material_counts','EMPTY'),
        ('workshop_material_other_issues','EMPTY'),
        ('workshop_material_period_closes','EMPTY'),
        ('workshop_material_period_lines','EMPTY'),
        ('workshop_material_periods','EMPTY'),
        ('workshop_material_requisition_lines','EMPTY'),
        ('workshop_material_requisition_postings','EMPTY'),
        ('workshop_material_requisitions','EMPTY'),
        ('workshop_material_settings','EMPTY'),
        ('workshop_material_stock_documents','EMPTY'),
        -- V949-V965 additions: derived facts, delivery receipts, authorization
        -- assignments and sealed identity evidence must all remain empty for
        -- a first bootstrap. None is an exception for an existing import.
        ('business_archive_eligibility','EMPTY'),
        ('business_archive_packages','EMPTY'),
        ('business_outbox_payload_history','EMPTY'),
        ('department_permission_template_bindings','EMPTY'),
        ('employee_code_reuse_claims','EMPTY'),
        ('employee_code_reuse_releases','EMPTY'),
        ('employee_identity_document_claims','EMPTY'),
        ('employee_identity_historical_claims','EMPTY'),
        ('employee_identity_legacy_roles','SEED_OR_ADMIN'),
        ('employee_identity_merge_payloads','EMPTY'),
        ('employee_identity_merges','EMPTY'),
        ('employee_identity_review_certificates','EMPTY'),
        ('employee_identity_user_tombstones','EMPTY'),
        ('employee_legacy_identity_aliases','EMPTY'),
        ('party_month_dirty','EMPTY'),
        ('party_monthly_summaries','EMPTY'),
        ('permission_template_applies','EMPTY'),
        ('scheduled_task_runs','EMPTY'),
        ('stock_monthly_summaries','EMPTY'),
        ('user_permission_template_bindings','EMPTY'),
        -- Real Flyway seeds: lifecycle policy metadata, the initial empty
        -- verification cursor and the two sealed extension-installation
        -- receipts exist even before any employee/business fact is written.
        ('data_lifecycle_policies','SEED_OR_ADMIN'),
        ('stock_monthly_verification_state','SEED_OR_ADMIN'),
        ('employee_identity_merge_installation','SEED_OR_ADMIN'),
        ('employee_code_reuse_installation','SEED_OR_ADMIN');
    SELECT string_agg(table_row.relname,', ' ORDER BY table_row.relname)
      INTO unknown_tables
    FROM pg_catalog.pg_class table_row
    JOIN pg_catalog.pg_namespace namespace_row ON namespace_row.oid=table_row.relnamespace
    WHERE namespace_row.nspname='public' AND table_row.relkind IN ('r','p')
      AND NOT table_row.relispartition
      AND NOT EXISTS (SELECT 1 FROM bootstrap_target_table_inventory inventory
                      WHERE inventory.table_name=table_row.relname);
    SELECT string_agg(inventory.table_name,', ' ORDER BY inventory.table_name)
      INTO missing_tables
    FROM bootstrap_target_table_inventory inventory
    WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class table_row
                      JOIN pg_catalog.pg_namespace namespace_row ON namespace_row.oid=table_row.relnamespace
                      WHERE namespace_row.nspname='public' AND table_row.relname=inventory.table_name
                        AND table_row.relkind IN ('r','p') AND NOT table_row.relispartition);
    IF unknown_tables IS NOT NULL OR missing_tables IS NOT NULL THEN
        RAISE EXCEPTION 'bootstrap table inventory differs from reviewed schema (unclassified %, missing %)',
            COALESCE(unknown_tables,'none'),COALESCE(missing_tables,'none');
    END IF;
    -- V964's sealed role declarations are fixed schema metadata, not historical
    -- employee assignments. Require all nineteen exact declarations; do not
    -- turn this into an exemption for missing, extra or edited role evidence.
    WITH expected(source_table,uuid_column,legacy_column,namespace_key) AS (VALUES
        ('purchase_requests','applicant_id','applicant_legacy_id','B_WORKER'),
        ('purchase_orders','purchaser_id','purchaser_legacy_id','B_WORKER'),
        ('purchase_receipts','sender_id','sender_legacy_id','B_WORKER'),
        ('purchase_receipts','receiver_id','receiver_legacy_id','B_WORKER'),
        ('purchase_receipts','purchaser_id','purchaser_legacy_id','B_WORKER'),
        ('sales_orders','seller_id','seller_legacy_id','B_WORKER'),
        ('sales_shipments','seller_id','seller_legacy_id','B_WORKER'),
        ('sales_shipments','sender_id','sender_legacy_id','B_WORKER'),
        ('sales_other_shipments','seller_id','seller_legacy_id','B_WORKER'),
        ('sales_other_shipments','sender_id','sender_legacy_id','B_WORKER'),
        ('sales_returns','seller_id','seller_legacy_id','B_WORKER'),
        ('finance_receipts','operator_id','operator_legacy_id','B_WORKER'),
        ('finance_payments','operator_id','operator_legacy_id','B_WORKER'),
        ('finance_expenses','operator_id','operator_legacy_id','B_WORKER'),
        ('finance_other_incomes','operator_id','operator_legacy_id','B_WORKER'),
        ('stock_documents','worker_id','worker_legacy_id','B_WORKER'),
        ('subcontract_material_issues','worker_id','operator_legacy_id','B_WORKER'),
        ('subcontract_material_returns','worker_id','operator_legacy_id','B_WORKER'),
        ('subcontract_receipts','sender_id','receiver_legacy_id','B_WORKER')
    ), actual AS (
        SELECT source_table,uuid_column,legacy_column,namespace_key
        FROM public.employee_identity_legacy_roles
    ), difference AS (
        (SELECT * FROM expected EXCEPT SELECT * FROM actual)
        UNION ALL (SELECT * FROM actual EXCEPT SELECT * FROM expected)
    )
    SELECT EXISTS(SELECT 1 FROM difference) OR (SELECT count(*) FROM actual)<>19 INTO occupied;
    IF occupied THEN
        RAISE EXCEPTION 'bootstrap employee legacy role declarations differ from reviewed V964 metadata';
    END IF;
    SELECT array_agg(table_name ORDER BY table_name) INTO clear_tables
    FROM bootstrap_target_table_inventory WHERE disposition='EMPTY';
    FOREACH clear_table IN ARRAY COALESCE(clear_tables, ARRAY[]::text[])
    LOOP
        IF clear_table = 'business_record_identities' THEN
            -- 留痕身份跟着它的来源记录走: 迁移种下的配置行(如 V801 给部门的默认权限)在全新库里就有身份,
            -- 它们不是业务事实; 只有来源表本身是要清空的业务表时才算「目标库已有业务数据」。
            SELECT EXISTS (SELECT 1 FROM public.business_record_identities identity
                            WHERE identity.source_table = ANY(clear_tables)) INTO occupied;
        ELSIF clear_table = 'business_record_history' THEN
            -- V931 seeds the company-library entry for every initial department;
            -- V958 removes that exact grant after making the entry a baseline.
            -- V775 correctly retains its immutable DELETE evidence. Permit only
            -- this unattributed, identity-bound configuration migration shape.
            -- Every other history row still proves a non-fresh target, even if
            -- its original business row has already been removed.
            SELECT EXISTS (
                SELECT 1 FROM public.business_record_history history
                WHERE (
                    history.source_table = 'department_permissions'
                    AND history.operation = 'DELETE'
                    AND history.parent_table = 'departments'
                    AND history.actor_id IS NULL AND history.actor_name IS NULL AND history.request_id IS NULL
                    AND history.payload ?& ARRAY['created_at','created_by','department_id','permission_id']
                    AND history.payload - ARRAY['created_at','created_by','department_id','permission_id'] = '{}'::jsonb
                    AND jsonb_typeof(history.payload->'created_at') = 'string'
                    AND history.payload->'created_by' = 'null'::jsonb
                    AND history.parent_id = history.payload->>'department_id'
                    AND history.source_id = jsonb_build_object(
                        'department_id',history.payload->'department_id',
                        'permission_id',history.payload->'permission_id')::text
                    AND EXISTS (SELECT 1 FROM public.permissions permission
                                WHERE permission.id::text=history.payload->>'permission_id'
                                  AND permission.code='company_file:view' AND permission.baseline)
                    AND EXISTS (SELECT 1 FROM public.departments department
                                WHERE department.id::text=history.parent_id)
                    AND EXISTS (SELECT 1 FROM public.business_record_identities identity
                                WHERE identity.source_table=history.source_table AND identity.source_id=history.source_id
                                  AND identity.parent_table=history.parent_table AND identity.parent_id=history.parent_id)
                    AND NOT EXISTS (SELECT 1 FROM public.business_record_history duplicate
                                    WHERE duplicate.source_table=history.source_table
                                      AND duplicate.source_id=history.source_id AND duplicate.id<>history.id)
                ) IS NOT TRUE
            ) INTO occupied;
        ELSE
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I)', clear_table) INTO occupied;
        END IF;
        IF occupied THEN
            RAISE EXCEPTION 'bootstrap target already contains business facts in %', clear_table;
        END IF;
    END LOOP;
    DROP TABLE bootstrap_target_table_inventory;
END;
$$;
