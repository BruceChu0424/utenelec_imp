-- =====================================================================
-- V462：工作台「系统测试 · 清空业务数据」服务端函数
-- =====================================================================
-- 背景：ops/reset_business_data.sql 是 psql 停机版（要求停应用、零其它连接）；
-- 工作台按钮需要「运行中的应用内执行」。因安全写入门禁止在 Java 内联
-- TRUNCATE/动态 SQL，清空口径整体下沉为本迁移创建的数据库函数，
-- Java 侧（BusinessDataResetService）只做：运行开关 + 超管校验 + 请求排水 +
-- 绑定审计 actor + 调用本函数 + 异常映射。
--
-- 口径与 ops/reset_business_data.sql 完全一致（同一份 318 表 CLEAR/PRESERVE
-- 分类，由 BusinessDataResetSqlContractTest 逐表锁定同步）。与 psql 版的
-- 三处差异：
--   1. 「停机静默」改为调用方（应用排水闸）保证；
--   2. 不复刻 psql 版的 Flyway 目录版本/数量元组门——未知表由下方
--      「未分类 public 表拒绝」兜底失败关闭；
--   3. 终局校验通过后追加全员下线：authorization_state.epoch + 1、
--      TRUNCATE refresh_tokens（断掉所有 staff 会话与续期）。
--
-- 本迁移不新增表，CLEAR 222 / PRESERVE 96 计数不变。
-- =====================================================================

CREATE OR REPLACE FUNCTION business_data_reset()
RETURNS TABLE (
    cleared_table_count INT,
    cleared_rows BIGINT,
    preserved_table_count INT,
    authorization_epoch_after BIGINT
)
LANGUAGE plpgsql
AS $fn$
DECLARE
    duplicate_tables TEXT;
    unknown_tables TEXT;
    invalid_policy_tables TEXT;
    unsafe_fk_edges TEXT;
    blocked_outbox BIGINT;
    unsafe_attachment_owners BIGINT;
    clear_tables TEXT;
    t RECORD;
    n BIGINT;
    cleared_rows_total BIGINT := 0;
    epoch_after_value BIGINT;
BEGIN
    -- 防御：同事务重试/残留时先清掉旧临时表（ON COMMIT DROP 正常情况下已清理）。
    DROP TABLE IF EXISTS reset_business_table_policy;
    DROP TABLE IF EXISTS reset_business_preserve_counts;
    DROP TABLE IF EXISTS reset_business_summary;

    CREATE TEMP TABLE reset_business_table_policy (
        table_name TEXT NOT NULL,
        disposition TEXT NOT NULL
            CHECK (disposition IN ('CLEAR', 'PRESERVE'))
    ) ON COMMIT DROP;

    INSERT INTO reset_business_table_policy(table_name, disposition) VALUES
    ('account_balance_adjustment_batches', 'CLEAR'),
    ('account_balance_adjustment_items', 'CLEAR'),
    ('account_flow_monthly_summaries', 'CLEAR'),
    ('ar_ap_ledger', 'CLEAR'),
    ('ar_ap_source_refs', 'CLEAR'),
    ('business_outbox', 'CLEAR'),
    ('customer_open_item_offset_batches', 'CLEAR'),
    ('customer_open_item_offsets', 'CLEAR'),
    ('da_amortization_log', 'CLEAR'),
    ('deferred_expenses', 'CLEAR'),
    ('execution_segment_sales_allocations', 'CLEAR'),
    ('expense_claim_items', 'CLEAR'),
    ('expense_claims', 'CLEAR'),
    ('fa_depreciation_log', 'CLEAR'),
    ('finance_asset_accounting_periods', 'CLEAR'),
    ('finance_asset_approval_steps', 'CLEAR'),
    ('finance_asset_books', 'CLEAR'),
    ('finance_asset_events', 'CLEAR'),
    ('finance_asset_posting_lines', 'CLEAR'),
    ('finance_asset_posting_runs', 'CLEAR'),
    ('finance_bank_transfer_lines', 'CLEAR'),
    ('finance_bank_transfers', 'CLEAR'),
    ('finance_check_register', 'CLEAR'),
    ('finance_deferral_schedule_lines', 'CLEAR'),
    ('finance_deferral_schedule_versions', 'CLEAR'),
    ('finance_expense_items', 'CLEAR'),
    ('finance_expenses', 'CLEAR'),
    ('finance_other_income_items', 'CLEAR'),
    ('finance_other_incomes', 'CLEAR'),
    ('finance_payment_lines', 'CLEAR'),
    ('finance_payments', 'CLEAR'),
    ('finance_receipt_lines', 'CLEAR'),
    ('finance_receipt_source_allocations', 'CLEAR'),
    ('finance_receipts', 'CLEAR'),
    ('finance_reconciliations', 'CLEAR'),
    ('fixed_assets', 'CLEAR'),
    ('gl_entries', 'CLEAR'),
    ('gl_vouchers', 'CLEAR'),
    ('hr_task_claims', 'CLEAR'),
    ('inbound_expectation_items', 'CLEAR'),
    ('inbound_expectations', 'CLEAR'),
    ('mrp_generations', 'CLEAR'),
    ('notice_acknowledgments', 'CLEAR'),
    ('notice_blessings', 'CLEAR'),
    ('notice_celebration_subjects', 'CLEAR'),
    ('notice_user_states', 'CLEAR'),
    ('notices', 'CLEAR'),
    ('payroll_batches', 'CLEAR'),
    ('payroll_items', 'CLEAR'),
    ('payroll_slips', 'CLEAR'),
    ('payroll_variable_inputs', 'CLEAR'),
    ('plan_draw_links', 'CLEAR'),
    ('plan_order_item_links', 'CLEAR'),
    ('preplan_analysis_stock_exact_pegs', 'CLEAR'),
    ('preplan_make_entitlement_delegations', 'CLEAR'),
    ('preplan_material_reallocations', 'CLEAR'),
    ('preplan_stock_entitlement_events', 'CLEAR'),
    ('preplan_supply_action_allocations', 'CLEAR'),
    ('preplan_supply_actions', 'CLEAR'),
    ('procurement_arrival_exception_events', 'CLEAR'),
    ('procurement_arrival_exceptions', 'CLEAR'),
    ('procurement_inspection_events', 'CLEAR'),
    ('procurement_inspection_items', 'CLEAR'),
    ('procurement_order_approval_cases', 'CLEAR'),
    ('procurement_order_approval_events', 'CLEAR'),
    ('production_daily_report_commands', 'CLEAR'),
    ('production_daily_report_workers', 'CLEAR'),
    ('production_daily_report_items', 'CLEAR'),
    ('production_daily_reports', 'CLEAR'),
    ('production_execution_segment_events', 'CLEAR'),
    ('production_execution_segments', 'CLEAR'),
    ('production_finished_arrival_registration_items', 'CLEAR'),
    ('production_finished_arrival_registrations', 'CLEAR'),
    ('production_finished_in_confirm_batch_items', 'CLEAR'),
    ('production_finished_in_confirm_batches', 'CLEAR'),
    ('production_fqc_cancellation_events', 'CLEAR'),
    ('production_fqc_contribution_adjustments', 'CLEAR'),
    ('production_fqc_decision_events', 'CLEAR'),
    ('production_fqc_inspections', 'CLEAR'),
    ('production_fqc_pass_all_batch_items', 'CLEAR'),
    ('production_fqc_pass_all_batches', 'CLEAR'),
    ('production_fqc_legacy_exemptions', 'CLEAR'),
    ('production_fqc_recovery_allocation_events', 'CLEAR'),
    ('production_fqc_recovery_authorizations', 'CLEAR'),
    ('production_fqc_recovery_cancellation_events', 'CLEAR'),
    ('production_fqc_release_allocations', 'CLEAR'),
    ('production_fqc_release_commands', 'CLEAR'),
    ('production_fqc_replenishment_analysis_links', 'CLEAR'),
    ('production_fqc_replenishment_attempts', 'CLEAR'),
    ('production_fqc_replenishment_cycle_cancellations', 'CLEAR'),
    ('production_fqc_replenishment_cycles', 'CLEAR'),
    ('production_fqc_replenishment_draw_links', 'CLEAR'),
    ('production_fqc_replenishment_ready_events', 'CLEAR'),
    ('production_fqc_replenishment_ready_reversals', 'CLEAR'),
    ('production_fqc_replenishment_supply_gaps', 'CLEAR'),
    ('production_fqc_replenishment_tasks', 'CLEAR'),
    ('production_finished_in_confirmation_reversal_items', 'CLEAR'),
    ('production_finished_in_confirmation_reversals', 'CLEAR'),
    ('production_finished_in_confirmation_items', 'CLEAR'),
    ('production_finished_in_confirmations', 'CLEAR'),
    ('production_material_analyses', 'CLEAR'),
    ('production_material_analysis_borrows', 'CLEAR'),
    ('production_material_analysis_commands', 'CLEAR'),
    ('production_material_analysis_items', 'CLEAR'),
    ('production_material_analysis_materials', 'CLEAR'),
    ('production_material_analysis_plan_links', 'CLEAR'),
    ('production_material_demands', 'CLEAR'),
    ('production_material_make_receipt_allocations', 'CLEAR'),
    ('production_material_peg_transfers', 'CLEAR'),
    ('production_material_receipt_allocations', 'CLEAR'),
    ('production_material_settlement_events', 'CLEAR'),
    ('production_material_settlement_postings', 'CLEAR'),
    ('production_material_stock_events', 'CLEAR'),
    ('production_material_stock_postings', 'CLEAR'),
    ('production_material_subcontract_peg_transfers', 'CLEAR'),
    ('production_material_subcontract_receipt_allocations', 'CLEAR'),
    ('production_material_supply_pegs', 'CLEAR'),
    ('production_plan_costs', 'CLEAR'),
    ('production_plan_items', 'CLEAR'),
    ('production_planning_drafts', 'CLEAR'),
    ('production_planning_package_document_items', 'CLEAR'),
    ('production_planning_package_documents', 'CLEAR'),
    ('production_planning_packages', 'CLEAR'),
    ('production_plans', 'CLEAR'),
    ('purchase_order_items', 'CLEAR'),
    ('purchase_orders', 'CLEAR'),
    ('purchase_receipt_items', 'CLEAR'),
    ('purchase_receipts', 'CLEAR'),
    ('purchase_request_items', 'CLEAR'),
    ('purchase_requests', 'CLEAR'),
    ('purchase_return_items', 'CLEAR'),
    ('purchase_returns', 'CLEAR'),
    ('rd_task_forwarders', 'CLEAR'),
    ('rd_tasks', 'CLEAR'),
    ('sales_order_cost_items', 'CLEAR'),
    ('sales_order_items', 'CLEAR'),
    ('sales_orders', 'CLEAR'),
    ('sales_other_shipment_items', 'CLEAR'),
    ('sales_other_shipments', 'CLEAR'),
    ('sales_quote_items', 'CLEAR'),
    ('sales_quotes', 'CLEAR'),
    ('sales_return_disposition_events', 'CLEAR'),
    ('sales_return_items', 'CLEAR'),
    ('sales_return_quality_events', 'CLEAR'),
    ('sales_return_quality_items', 'CLEAR'),
    ('sales_returns', 'CLEAR'),
    ('sales_shipment_items', 'CLEAR'),
    ('sales_shipment_warehouse_events', 'CLEAR'),
    ('sales_shipments', 'CLEAR'),
    ('stock_balance_adjustment_requests', 'CLEAR'),
    ('stock_balances', 'CLEAR'),
    ('stock_document_items', 'CLEAR'),
    ('stock_documents', 'CLEAR'),
    ('stock_movements', 'CLEAR'),
    ('stock_reservations', 'CLEAR'),
    ('subcontract_application_items', 'CLEAR'),
    ('subcontract_applications', 'CLEAR'),
    ('subcontract_inquiries', 'CLEAR'),
    ('subcontract_inquiry_items', 'CLEAR'),
    ('subcontract_loss_case_lines', 'CLEAR'),
    ('subcontract_loss_cases', 'CLEAR'),
    ('subcontract_loss_events', 'CLEAR'),
    ('subcontract_loss_fulfillment_allocations', 'CLEAR'),
    ('subcontract_loss_resolutions', 'CLEAR'),
    ('subcontract_material_issue_items', 'CLEAR'),
    ('subcontract_material_issues', 'CLEAR'),
    ('subcontract_material_plan_items', 'CLEAR'),
    ('subcontract_material_plans', 'CLEAR'),
    ('subcontract_material_return_items', 'CLEAR'),
    ('subcontract_material_returns', 'CLEAR'),
    ('subcontract_order_cost_items', 'CLEAR'),
    ('subcontract_order_items', 'CLEAR'),
    ('subcontract_orders', 'CLEAR'),
    ('subcontract_receipt_items', 'CLEAR'),
    ('subcontract_receipts', 'CLEAR'),
    ('subcontract_return_items', 'CLEAR'),
    ('subcontract_returns', 'CLEAR'),
    ('subcontract_waste_items', 'CLEAR'),
    ('subcontract_wastes', 'CLEAR'),
    ('subplan_links', 'CLEAR'),
    ('suggestion_likes', 'CLEAR'),
    ('suggestion_replies', 'CLEAR'),
    ('suggestions', 'CLEAR'),
    ('supplier_claim_cash_receipts', 'CLEAR'),
    ('supplier_claim_receivables', 'CLEAR'),
    ('supplier_open_item_offsets', 'CLEAR'),
    ('supplier_return_tasks', 'CLEAR'),
    ('supplier_settlement_batch_events', 'CLEAR'),
    ('supplier_settlement_batch_lines', 'CLEAR'),
    ('supplier_settlement_batches', 'CLEAR'),
    ('task_claims', 'CLEAR'),
    ('visitor_accounts', 'CLEAR'),
    ('visitor_applications', 'CLEAR'),
    ('visitor_approval_steps', 'CLEAR'),
    ('visitor_refresh_tokens', 'CLEAR'),
    ('visitor_sms_codes', 'CLEAR'),
    ('warehouse_arrival_registration_commands', 'CLEAR'),
    ('warehouse_arrival_exception_stock_in_batch_items', 'CLEAR'),
    ('warehouse_arrival_exception_stock_in_batches', 'CLEAR'),
    ('warehouse_goods_place_preferences', 'CLEAR'),
    ('website_inquiries', 'CLEAR'),
    ('production_product_no_sequences', 'CLEAR'),
    ('procurement_iqc_rejection_cases', 'CLEAR'),
    ('procurement_iqc_rejection_commands', 'CLEAR'),
    ('procurement_iqc_rejection_events', 'CLEAR'),
    ('procurement_iqc_replacement_allocations', 'CLEAR'),
    ('subcontract_outbound_issue_reservation_allocations', 'CLEAR'),
    ('subcontract_outbound_preparation_commands', 'CLEAR'),
    ('sales_shipment_finance_release_events', 'CLEAR'),
    ('procurement_iqc_stock_in_batch_items', 'CLEAR'),
    ('procurement_iqc_stock_in_batches', 'CLEAR'),
    ('preplan_subcontract_entitlement_handoff_slices', 'CLEAR'),
    ('preplan_subcontract_requirement_handoff_events', 'CLEAR'),
    ('preplan_subcontract_requirement_handoff_items', 'CLEAR'),
    ('preplan_subcontract_requirement_handoffs', 'CLEAR'),
    ('preplan_subcontract_requirement_supply_claims', 'CLEAR'),
    ('preplan_subcontract_make_task_batches', 'CLEAR'),
    ('preplan_subcontract_make_tasks', 'CLEAR'),
    ('measurement_capture_decision_events', 'CLEAR'),
    ('measurement_capture_evidence', 'CLEAR'),
    ('measurement_capture_line_snapshots', 'CLEAR'),
    ('measurement_capture_profiles', 'CLEAR'),
    ('accounts', 'PRESERVE'),
    ('attachment_object_outbox', 'PRESERVE'),
    ('attachment_reconciliation_findings', 'PRESERVE'),
    ('attachment_upload_sessions', 'PRESERVE'),
    ('attachments', 'PRESERVE'),
    ('audit_log', 'PRESERVE'),
    ('audit_log_archive', 'PRESERVE'),
    ('authorization_state', 'PRESERVE'),
    ('business_document_sequences', 'PRESERVE'),
    ('business_identifier_conflicts', 'PRESERVE'),
    ('business_identifier_namespaces', 'PRESERVE'),
    ('business_identifier_reservation_members', 'PRESERVE'),
    ('business_identifier_reservations', 'PRESERVE'),
    ('business_prefix_reservation_members', 'PRESERVE'),
    ('business_prefix_reservations', 'PRESERVE'),
    ('category_master_code_sequences', 'PRESERVE'),
    ('client_access_change_events', 'PRESERVE'),
    ('client_categories', 'PRESERVE'),
    ('client_default_settlement_migration_issues', 'PRESERVE'),
    ('client_ship_addresses', 'PRESERVE'),
    ('client_visibility_grants', 'PRESERVE'),
    ('clients', 'PRESERVE'),
    ('colors', 'PRESERVE'),
    ('currencies', 'PRESERVE'),
    ('department_permissions', 'PRESERVE'),
    ('department_roles', 'PRESERVE'),
    ('departments', 'PRESERVE'),
    ('doc_number_sequences', 'PRESERVE'),
    ('emergency_contacts', 'PRESERVE'),
    ('employee_compensation', 'PRESERVE'),
    ('employee_contracts', 'PRESERVE'),
    ('employee_credentials', 'PRESERVE'),
    ('employee_data_handover_scopes', 'PRESERVE'),
    ('employee_data_handovers', 'PRESERVE'),
    ('employee_education', 'PRESERVE'),
    ('employee_offboarding_events', 'PRESERVE'),
    ('employee_phones', 'PRESERVE'),
    ('employee_secondary_departments', 'PRESERVE'),
    ('employee_sensitive', 'PRESERVE'),
    ('employee_vehicles', 'PRESERVE'),
    ('employees', 'PRESERVE'),
    ('employment_history', 'PRESERVE'),
    ('finance_asset_categories', 'PRESERVE'),
    ('finance_payment_methods', 'PRESERVE'),
    ('flyway_schema_history', 'PRESERVE'),
    ('goods', 'PRESERVE'),
    ('goods_bom_items', 'PRESERVE'),
    ('goods_import_batches', 'PRESERVE'),
    ('goods_import_creations', 'PRESERVE'),
    ('legacy_departments', 'PRESERVE'),
    ('legacy_migration_checkpoints', 'PRESERVE'),
    ('legacy_migration_reconciliation_items', 'PRESERVE'),
    ('legacy_migration_rejects', 'PRESERVE'),
    ('legacy_migration_run_files', 'PRESERVE'),
    ('legacy_migration_runs', 'PRESERVE'),
    ('legacy_warehouse_workshop_links', 'PRESERVE'),
    ('manager_permission_delegations', 'PRESERVE'),
    ('master_code_change_batches', 'PRESERVE'),
    ('master_code_history', 'PRESERVE'),
    ('master_code_reservation_members', 'PRESERVE'),
    ('master_code_reservations', 'PRESERVE'),
    ('master_code_sequences', 'PRESERVE'),
    ('material_categories', 'PRESERVE'),
    ('mould_categories', 'PRESERVE'),
    ('moulds', 'PRESERVE'),
    ('official_policy_briefs', 'PRESERVE'),
    ('organization_permission_leader_assignments', 'PRESERVE'),
    ('password_history', 'PRESERVE'),
    ('payment_styles', 'PRESERVE'),
    ('permission_surface_permissions', 'PRESERVE'),
    ('permission_surfaces', 'PRESERVE'),
    ('permissions', 'PRESERVE'),
    ('positions', 'PRESERVE'),
    ('production_goods_workshop_preferences', 'PRESERVE'),
    ('profile_change_requests', 'PRESERVE'),
    ('refresh_tokens', 'PRESERVE'),
    ('report_materialized_view_refresh_state', 'PRESERVE'),
    ('role_permissions', 'PRESERVE'),
    ('roles', 'PRESERVE'),
    ('settlement_methods', 'PRESERVE'),
    ('supplier_categories', 'PRESERVE'),
    ('suppliers', 'PRESERVE'),
    ('system_master_category_registry', 'PRESERVE'),
    ('system_posting_style_roles', 'PRESERVE'),
    ('system_settings', 'PRESERVE'),
    ('units', 'PRESERVE'),
    ('user_data_scopes', 'PRESERVE'),
    ('user_permission_overrides', 'PRESERVE'),
    ('user_preferences', 'PRESERVE'),
    ('user_roles', 'PRESERVE'),
    ('users', 'PRESERVE'),
    ('warehouses', 'PRESERVE'),
    ('legacy_measurement_exceptions', 'PRESERVE'),
    ('legacy_measurement_profile_snapshots', 'PRESERVE'),
    ('legacy_measurement_source_registry', 'PRESERVE'),
    ('unit_measurement_profiles', 'PRESERVE');

    -- ============ 前置拒绝（ERRCODE UT900 → 应用层映射 409） ============

    SELECT count(*)
    INTO blocked_outbox
    FROM business_outbox
    WHERE status IN (0, 2);

    IF blocked_outbox > 0 THEN
        RAISE EXCEPTION
            '拒绝执行：business_outbox 仍有 % 条待处理或失败事件，请先处理',
            blocked_outbox
            USING ERRCODE = 'UT900';
    END IF;

    SELECT count(*)
    INTO unsafe_attachment_owners
    FROM (
        SELECT owner_type
        FROM attachments
        WHERE upper(btrim(owner_type))
              NOT IN ('EMPLOYEE', 'EMPLOYEE_CONTRACT')
        UNION ALL
        SELECT owner_type
        FROM attachment_upload_sessions
        WHERE upper(btrim(owner_type))
              NOT IN ('EMPLOYEE', 'EMPLOYEE_CONTRACT')
    ) unsafe_owner;

    IF unsafe_attachment_owners > 0 THEN
        RAISE EXCEPTION
            '拒绝执行：附件或上传会话存在 % 条非人事 owner；必须先走对象删除/对账流程',
            unsafe_attachment_owners
            USING ERRCODE = 'UT900';
    END IF;

    -- ============ 目录完整性失败关闭 ============

    SELECT string_agg(table_name, ', ' ORDER BY table_name)
    INTO duplicate_tables
    FROM (
        SELECT table_name
        FROM reset_business_table_policy
        GROUP BY table_name
        HAVING count(*) <> 1
    ) duplicates;

    IF duplicate_tables IS NOT NULL THEN
        RAISE EXCEPTION '表分类重复/重叠：%', duplicate_tables
            USING ERRCODE = 'UT900';
    END IF;

    SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO unknown_tables
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN reset_business_table_policy p ON p.table_name = c.relname
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND c.relispartition = FALSE
      AND c.relname <> 'spatial_ref_sys'
      AND NOT EXISTS (
          SELECT 1
          FROM pg_depend dependency
          JOIN pg_extension extension
            ON extension.oid = dependency.refobjid
          WHERE dependency.classid = 'pg_class'::regclass
            AND dependency.objid = c.oid
            AND dependency.deptype = 'e'
      )
      AND NOT EXISTS (
          SELECT 1
          FROM pg_extension extension
          WHERE c.oid = ANY(COALESCE(extension.extconfig, ARRAY[]::OID[]))
      )
      AND p.table_name IS NULL;

    IF unknown_tables IS NOT NULL THEN
        RAISE EXCEPTION
            '存在未分类 public 表（新增表后需同步 ops/reset_business_data.sql 与本函数）：%',
            unknown_tables
            USING ERRCODE = 'UT900';
    END IF;

    SELECT string_agg(p.table_name, ', ' ORDER BY p.table_name)
    INTO invalid_policy_tables
    FROM reset_business_table_policy p
    LEFT JOIN (
        SELECT c.relname, c.relkind, c.relispartition
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
    ) actual ON actual.relname = p.table_name
    WHERE actual.relname IS NULL
       OR actual.relkind NOT IN ('r', 'p')
       OR actual.relispartition = TRUE;

    IF invalid_policy_tables IS NOT NULL THEN
        RAISE EXCEPTION
            '白名单包含不存在/非普通父表/分区子表：%',
            invalid_policy_tables
            USING ERRCODE = 'UT900';
    END IF;

    SELECT string_agg(
               format('%I -> %I', child.relname, parent.relname),
               ', '
               ORDER BY child.relname, parent.relname
           )
    INTO unsafe_fk_edges
    FROM pg_constraint con
    JOIN pg_class child ON child.oid = con.conrelid
    JOIN pg_class parent ON parent.oid = con.confrelid
    JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
    JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
    JOIN reset_business_table_policy child_policy
      ON child_policy.table_name = child.relname
     AND child_policy.disposition = 'PRESERVE'
    JOIN reset_business_table_policy parent_policy
      ON parent_policy.table_name = parent.relname
     AND parent_policy.disposition = 'CLEAR'
    WHERE con.contype = 'f'
      AND child_ns.nspname = 'public'
      AND parent_ns.nspname = 'public';

    IF unsafe_fk_edges IS NOT NULL THEN
        RAISE EXCEPTION
            '保留表仍引用待清业务表，禁止清空：%',
            unsafe_fk_edges
            USING ERRCODE = 'UT900';
    END IF;

    -- ============ 统计待清行数 + TRUNCATE（RESTART IDENTITY，ID 从 1 开始） ============

    CREATE TEMP TABLE reset_business_summary (
        cleared_rows BIGINT NOT NULL,
        epoch_after BIGINT
    ) ON COMMIT DROP;

    FOR t IN
        SELECT table_name
        FROM reset_business_table_policy
        WHERE disposition = 'CLEAR'
        ORDER BY table_name
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name) INTO n;
        cleared_rows_total := cleared_rows_total + n;
    END LOOP;

    INSERT INTO reset_business_summary(cleared_rows)
    VALUES (cleared_rows_total);

    SELECT string_agg(
               format('public.%I', table_name),
               ', '
               ORDER BY table_name
           )
    INTO clear_tables
    FROM reset_business_table_policy
    WHERE disposition = 'CLEAR';

    IF clear_tables IS NULL THEN
        RAISE EXCEPTION 'CLEAR 白名单为空';
    END IF;

    EXECUTE 'TRUNCATE TABLE ' || clear_tables || ' RESTART IDENTITY';

    -- ============ 保留主档金额/期初投影归零（不停审计触发器） ============

    UPDATE accounts
    SET init_balance = 0,
        receipts_total = 0,
        payments_total = 0,
        balance_adjustments_total = 0,
        balance_current = 0
    WHERE init_balance <> 0
       OR receipts_total <> 0
       OR payments_total <> 0
       OR balance_adjustments_total <> 0
       OR balance_current <> 0;

    UPDATE clients
    SET init_total = 0,
        init_total2 = 0,
        version = version + 1,
        updated_at = CURRENT_TIMESTAMP
    WHERE COALESCE(init_total, 0) <> 0
       OR COALESCE(init_total2, 0) <> 0;

    UPDATE suppliers
    SET init_total = 0,
        init_total2 = 0,
        version = version + 1,
        updated_at = CURRENT_TIMESTAMP
    WHERE COALESCE(init_total, 0) <> 0
       OR COALESCE(init_total2, 0) <> 0;

    UPDATE goods
    SET init_stock = 0,
        init_count = 0,
        init_weight = 0,
        min_qty = 0,
        source_e = 0,
        work_e = 0,
        lacquer_e = 0,
        incidental_e = 0,
        plating_e = 0,
        casing_e = 0,
        manage_e = 0,
        polish_e = 0,
        electric_e = 0,
        machining_e = 0,
        lost_e = 0,
        rent_e = 0,
        make_e = 0,
        work_rate = 0,
        lost_rate = 0,
        make_rate = 0,
        rent_rate = 0,
        total = 0,
        c_total = 0,
        g_total = 0,
        version = version + 1,
        updated_at = CURRENT_TIMESTAMP
    WHERE COALESCE(init_stock, 0) <> 0
       OR COALESCE(init_count, 0) <> 0
       OR COALESCE(init_weight, 0) <> 0
       OR min_qty IS DISTINCT FROM 0
       OR source_e IS DISTINCT FROM 0
       OR work_e IS DISTINCT FROM 0
       OR lacquer_e IS DISTINCT FROM 0
       OR incidental_e IS DISTINCT FROM 0
       OR plating_e IS DISTINCT FROM 0
       OR casing_e IS DISTINCT FROM 0
       OR manage_e IS DISTINCT FROM 0
       OR polish_e IS DISTINCT FROM 0
       OR electric_e IS DISTINCT FROM 0
       OR machining_e IS DISTINCT FROM 0
       OR lost_e IS DISTINCT FROM 0
       OR rent_e IS DISTINCT FROM 0
       OR make_e IS DISTINCT FROM 0
       OR work_rate IS DISTINCT FROM 0
       OR lost_rate IS DISTINCT FROM 0
       OR make_rate IS DISTINCT FROM 0
       OR rent_rate IS DISTINCT FROM 0
       OR total IS DISTINCT FROM 0
       OR c_total IS DISTINCT FROM 0
       OR g_total IS DISTINCT FROM 0;

    UPDATE payment_styles
    SET init_balance = 0
    WHERE COALESCE(init_balance, 0) <> 0;

    -- ============ 保留表行数基线（主档归零追加审计行之后采集） ============

    CREATE TEMP TABLE reset_business_preserve_counts (
        table_name TEXT PRIMARY KEY,
        row_count BIGINT NOT NULL
    ) ON COMMIT DROP;

    FOR t IN
        SELECT table_name
        FROM reset_business_table_policy
        WHERE disposition = 'PRESERVE'
        ORDER BY table_name
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name) INTO n;
        INSERT INTO reset_business_preserve_counts(table_name, row_count)
        VALUES (t.table_name, n);
    END LOOP;

    -- ============ 六物化视图刷新（非并发式，可运行于本事务内） ============

    REFRESH MATERIALIZED VIEW purchase_monthly_mv;
    REFRESH MATERIALIZED VIEW production_monthly_mv;
    REFRESH MATERIALIZED VIEW stock_monthly_mv;
    REFRESH MATERIALIZED VIEW finance_ar_ap_mv;
    REFRESH MATERIALIZED VIEW sales_monthly_mv;
    REFRESH MATERIALIZED VIEW subcontract_monthly_mv;

    -- ============ 终局校验（任一失败整体回滚） ============

    SELECT count(*)
    INTO n
    FROM accounts
    WHERE init_balance <> 0
       OR receipts_total <> 0
       OR payments_total <> 0
       OR balance_adjustments_total <> 0
       OR balance_current <> 0;
    IF n <> 0 THEN
        RAISE EXCEPTION
            '账户金额归零校验失败：仍有 % 个账户存在非零期初/收款/付款/调整/当前余额，整体回滚',
            n;
    END IF;

    SELECT
        (SELECT count(*) FROM clients
         WHERE COALESCE(init_total, 0) <> 0
            OR COALESCE(init_total2, 0) <> 0)
      + (SELECT count(*) FROM suppliers
         WHERE COALESCE(init_total, 0) <> 0
            OR COALESCE(init_total2, 0) <> 0)
      + (SELECT count(*) FROM goods
         WHERE COALESCE(init_stock, 0) <> 0
            OR COALESCE(init_count, 0) <> 0
            OR COALESCE(init_weight, 0) <> 0)
      + (SELECT count(*) FROM payment_styles
         WHERE COALESCE(init_balance, 0) <> 0)
    INTO n;
    IF n <> 0 THEN
        RAISE EXCEPTION
            '遗留期初归零校验失败：仍有 % 个客户/供应商/货品/结算类别存在非零期初值，整体回滚',
            n;
    END IF;

    SELECT count(*)
    INTO n
    FROM goods
    WHERE min_qty IS DISTINCT FROM 0
       OR source_e IS DISTINCT FROM 0
       OR work_e IS DISTINCT FROM 0
       OR lacquer_e IS DISTINCT FROM 0
       OR incidental_e IS DISTINCT FROM 0
       OR plating_e IS DISTINCT FROM 0
       OR casing_e IS DISTINCT FROM 0
       OR manage_e IS DISTINCT FROM 0
       OR polish_e IS DISTINCT FROM 0
       OR electric_e IS DISTINCT FROM 0
       OR machining_e IS DISTINCT FROM 0
       OR lost_e IS DISTINCT FROM 0
       OR rent_e IS DISTINCT FROM 0
       OR make_e IS DISTINCT FROM 0
       OR work_rate IS DISTINCT FROM 0
       OR lost_rate IS DISTINCT FROM 0
       OR make_rate IS DISTINCT FROM 0
       OR rent_rate IS DISTINCT FROM 0
       OR total IS DISTINCT FROM 0
       OR c_total IS DISTINCT FROM 0
       OR g_total IS DISTINCT FROM 0;
    IF n <> 0 THEN
        RAISE EXCEPTION
            '货品安全库存/成本预算归零校验失败：仍有 % 个货品存在非零安全库存或成本金额/费率，整体回滚',
            n;
    END IF;

    FOR t IN
        SELECT table_name
        FROM reset_business_table_policy
        WHERE disposition = 'CLEAR'
        ORDER BY table_name
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name) INTO n;
        IF n <> 0 THEN
            RAISE EXCEPTION '清空校验失败：% 仍有 % 行，整体回滚',
                t.table_name, n;
        END IF;
    END LOOP;

    FOR t IN
        SELECT table_name, row_count
        FROM reset_business_preserve_counts
        ORDER BY table_name
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name) INTO n;
        IF n <> t.row_count THEN
            RAISE EXCEPTION '保留校验失败：% 清理前 % 行、清理后 % 行，整体回滚',
                t.table_name, t.row_count, n;
        END IF;
    END LOOP;

    FOR t IN
        SELECT unnest(ARRAY[
            'purchase_monthly_mv',
            'production_monthly_mv',
            'stock_monthly_mv',
            'finance_ar_ap_mv',
            'sales_monthly_mv',
            'subcontract_monthly_mv'
        ]) AS view_name
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.view_name) INTO n;
        IF n <> 0 THEN
            RAISE EXCEPTION '物化视图清空校验失败：% 仍有 % 行，整体回滚',
                t.view_name, n;
        END IF;
    END LOOP;

    -- ============ 全员强制重新登录（psql 停机版没有的收尾） ============
    -- epoch + 1 让所有存量 staff access token 下一请求 401；
    -- refresh_tokens 在分类里是 PRESERVE，但它是会话数据而非业务数据——
    -- 放在全部保留表行数校验之后清空，与 psql 版（停机、无会话）刻意不同。

    SELECT count(*)
    INTO n
    FROM authorization_state
    WHERE singleton_id = 1;
    IF n <> 1 THEN
        RAISE EXCEPTION
            'authorization_state 单例缺失（% 行），无法完成全员下线，整体回滚', n;
    END IF;

    UPDATE authorization_state
    SET epoch = epoch + 1
    WHERE singleton_id = 1;

    TRUNCATE TABLE refresh_tokens RESTART IDENTITY;

    SELECT epoch
    INTO epoch_after_value
    FROM authorization_state
    WHERE singleton_id = 1;

    UPDATE reset_business_summary
    SET epoch_after = epoch_after_value;

    RETURN QUERY
    SELECT (SELECT count(*)::INT
              FROM reset_business_table_policy
             WHERE disposition = 'CLEAR') AS cleared_table_count,
           cleared_rows_total,
           (SELECT count(*)::INT
              FROM reset_business_table_policy
             WHERE disposition = 'PRESERVE') AS preserved_table_count,
           epoch_after_value;
END;
$fn$;
