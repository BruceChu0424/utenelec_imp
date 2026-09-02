-- =====================================================================
-- 本地/测试库业务数据一键清空（V443–V456；保留主档、人事、权限与治理证据）
-- =====================================================================
-- 用途：把数据库重置为“基础资料和系统治理数据保留、业务流程、库存、账户金额、
--       遗留期初往来/库存快照、货品安全库存及成本预算归零”的
--       干净测试起点。只允许在可丢弃的本地/测试库停写后运行。
--
-- 唯一范围事实：
--   · CLEAR 212/214/219/220 张：V443 为212张，V446新增两张 IQC 仓库入库事实表后为214张，V447新增五张交接事实表后为219张；V448–V450不新增父表；
--     V448 只增合并页读路径索引、不新增业务表，CLEAR 维持 219 张；
--     V449 只替换 V446 的 IQC 入库校验触发器函数（放开同人放行+确认限制），
--     不新增业务表，CLEAR 维持 219 张；
--     V451 只泛化库位学习表来源维度（IQC 确认入库也能学习库位），CLEAR 维持 219 张；
--     V452 只给供应商加默认结算方式列/触发器与核对视图、V453 只登记结算方式
--     管理页权限与权限面，均不新增业务表，CLEAR 维持 219 张；
--     V454 新增通知庆典主角表 notice_celebration_subjects（聚合祝福卡逐人快照，CLEAR），CLEAR 为 220 张；
--     V455 只补 10 个权限面并下线 15 个孤儿权限码（清授权行，不新增业务表），CLEAR 维持 220 张；
--     V456 只接线 5 个业务页的权限面入口（扩码/退役旧面，不新增业务表），CLEAR 维持 220 张；
--     建议、任务认领和业务 outbox。
--   · PRESERVE 95 张：V442 的四张单位/迁移计量治理证据表明确保留；PostGIS 扩展表不进入业务策略计数；其余为主档、人事、账号/权限、系统配置、Flyway、审计日志、
--     人事附件、导入/迁移证据、编号终身占用和单调流水。账户主档保留，
--     init/收/付/调整/当前余额五个金额字段在业务事实清空后同事务归零；
--     客户/供应商期初往来、货品 legacy 期初库存、安全库存、20 项成本金额/费率及
--     结算类别期初金额也归零；货品 UUID/编号/名称/分类/单位/BOM、max_qty 与
--     业务售价 price/a_price/price2 保持不变。
--   · 分区子表不单列；随已分类的分区父表一同处理，实际数量以目标库为准。
--
-- 安全边界：
--   · confirm、数据库名、PostgreSQL system_identifier 三重带外确认。
--   · 必须先停止应用、定时任务和 outbox worker；存在其它客户端连接即拒绝。
--   · outbox 有待处理/失败事件，或存在非人事附件 owner 时拒绝执行。
--   · 当前 public 非分区普通表/分区父表必须恰好分类一次；未知表失败关闭。
--   · 不使用级联扩大范围；新增未分类 FK 表会让执行失败，而不是被静默删除。
--   · 单事务完成业务表及其 identity 清空、账户金额/遗留期初/货品安全库存与成本预算归零、
--     六张物化视图刷新、CLEAR 逐表为零和
--     PRESERVE 逐表计数不变校验；保留主档 UPDATE 不停审计、共享 request ID 并使用可辨识 actor，
--     客户/供应商/货品 @Version 与 updated_at 随真实变化推进，
--     审计写入完成后才记录 PRESERVE 计数基线；任一失败全部回滚。
--
-- 先备份（示例；不要覆盖既有备份）：
--   $resetStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
--   $backupName = "uten_imp_pre_reset_v431_or_v440_$resetStamp.dump"
--   docker exec uten-imp-postgres pg_dump -U uten -d uten_imp -Fc \
--       -f "/tmp/$backupName"
--   docker exec uten-imp-postgres pg_restore -l "/tmp/$backupName"
--   docker cp "uten-imp-postgres:/tmp/$backupName" \
--       "D:\Projects\uten_imp\server\backups\$backupName"
--   Get-FileHash "D:\Projects\uten_imp\server\backups\$backupName" -Algorithm SHA256
--
-- 执行前读取 system_identifier：
--   $systemId = docker exec uten-imp-postgres psql -X -U uten -d uten_imp \
--       -At -c "SELECT system_identifier FROM pg_control_system()"
--
-- 执行：
--   Get-Content -Raw -LiteralPath \
--       "D:\Projects\uten_imp\server\ops\reset_business_data.sql" |
--     docker exec -i uten-imp-postgres psql -X -U uten -d uten_imp \
--       -v ON_ERROR_STOP=1 -v confirm=CLEAR_BUSINESS \
--       -v expected_database=uten_imp \
--       -v expected_system_identifier=$systemId
-- =====================================================================

\set ON_ERROR_STOP on

\if :{?confirm}
\else
    \echo '拒绝执行：必须显式传 -v confirm=CLEAR_BUSINESS'
    \set confirm 'MISSING'
\endif

\if :{?expected_database}
\else
    \echo '拒绝执行：必须显式传 -v expected_database=<数据库名>'
    \set expected_database 'MISSING'
\endif

\if :{?expected_system_identifier}
\else
    \echo '拒绝执行：必须显式传 -v expected_system_identifier=<system_identifier>'
    \set expected_system_identifier 'MISSING'
\endif

SELECT set_config('app.reset_business_confirm', :'confirm', false),
       set_config(
           'app.reset_business_expected_database',
           :'expected_database',
           false
       ),
       set_config(
           'app.reset_business_expected_system_identifier',
           :'expected_system_identifier',
           false
       );

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '30min';
SELECT set_config(
    'app.actor_account',
    'ops:reset_business_data',
    true
), set_config(
    'app.audit_request_id',
    gen_random_uuid()::text,
    true
);

DO $$
DECLARE
    actual_system_identifier TEXT;
    other_connections BIGINT;
    blocked_outbox BIGINT;
    unsafe_attachment_owners BIGINT;
BEGIN
    IF current_setting('app.reset_business_confirm', true)
           IS DISTINCT FROM 'CLEAR_BUSINESS' THEN
        RAISE EXCEPTION '拒绝执行：confirm 必须等于 CLEAR_BUSINESS';
    END IF;

    IF current_database() IS DISTINCT FROM
           current_setting('app.reset_business_expected_database', true) THEN
        RAISE EXCEPTION '拒绝执行：当前数据库 % 与 expected_database % 不一致',
            current_database(),
            current_setting('app.reset_business_expected_database', true);
    END IF;

    SELECT system_identifier::text
    INTO actual_system_identifier
    FROM pg_control_system();

    IF actual_system_identifier IS DISTINCT FROM
           current_setting(
               'app.reset_business_expected_system_identifier',
               true
           ) THEN
        RAISE EXCEPTION '拒绝执行：当前 system_identifier % 与期望值 % 不一致',
            actual_system_identifier,
            current_setting(
                'app.reset_business_expected_system_identifier',
                true
            );
    END IF;

    SELECT count(*)
    INTO other_connections
    FROM pg_stat_activity
    WHERE datname = current_database()
      AND pid <> pg_backend_pid()
      AND backend_type = 'client backend';

    IF other_connections > 0 THEN
        RAISE EXCEPTION '拒绝执行：当前数据库仍有 % 个其它客户端连接，请先停应用/worker',
            other_connections;
    END IF;

    SELECT count(*)
    INTO blocked_outbox
    FROM business_outbox
    WHERE status IN (0, 2);

    IF blocked_outbox > 0 THEN
        RAISE EXCEPTION '拒绝执行：business_outbox 仍有 % 条待处理或失败事件',
            blocked_outbox;
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
            '拒绝执行：附件或上传会话存在 % 条非人事 owner；必须先走对象删除/对账流程，禁止制造孤儿文件',
            unsafe_attachment_owners;
    END IF;
END $$;

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
('production_product_no_sequences', 'CLEAR'),
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
('warehouses', 'PRESERVE');

-- V436/V440 add six business tables. Support the current live V431 catalog and
-- the forward V440+ catalog without inventing absent tables; the count gate
-- below permits only all-six-absent or all-six-present.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('procurement_iqc_rejection_cases', 'CLEAR'),
('procurement_iqc_rejection_commands', 'CLEAR'),
('procurement_iqc_rejection_events', 'CLEAR'),
('procurement_iqc_replacement_allocations', 'CLEAR'),
('subcontract_outbound_issue_reservation_allocations', 'CLEAR'),
('subcontract_outbound_preparation_commands', 'CLEAR')
) AS optional(table_name, disposition)
WHERE to_regclass(format('public.%I', optional.table_name)) IS NOT NULL;

-- V443 adds the append-only shipment finance decision ledger. It is a
-- business-process fact and must be cleared before its parent shipment during
-- a deliberately authorized local/test reset.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('sales_shipment_finance_release_events', 'CLEAR')
) AS optional(table_name, disposition)
WHERE to_regclass(format('public.%I', optional.table_name)) IS NOT NULL;

-- V446 immutable warehouse confirmations are business transaction facts.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('procurement_iqc_stock_in_batch_items', 'CLEAR'),
('procurement_iqc_stock_in_batches', 'CLEAR')
) AS optional(table_name, disposition)
WHERE to_regclass(format('public.%I', optional.table_name)) IS NOT NULL;

-- V447 cross-analysis subcontract handoff ledgers are append-only business
-- transaction facts.  Keep the reset usable at V446, but only accept all five
-- V447 tables together.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('preplan_subcontract_entitlement_handoff_slices', 'CLEAR'),
('preplan_subcontract_requirement_handoff_events', 'CLEAR'),
('preplan_subcontract_requirement_handoff_items', 'CLEAR'),
('preplan_subcontract_requirement_handoffs', 'CLEAR'),
('preplan_subcontract_requirement_supply_claims', 'CLEAR')
) AS optional(table_name, disposition)
WHERE to_regclass(format('public.%I', optional.table_name)) IS NOT NULL;

-- V442 measurement learning adds four business-derived projections/events and
-- four governed migration/unit-evidence tables. Keep the script usable before
-- and after V442, but reject a partially applied catalog.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('legacy_measurement_exceptions', 'PRESERVE'),
('legacy_measurement_profile_snapshots', 'PRESERVE'),
('legacy_measurement_source_registry', 'PRESERVE'),
('measurement_capture_decision_events', 'CLEAR'),
('measurement_capture_evidence', 'CLEAR'),
('measurement_capture_line_snapshots', 'CLEAR'),
('measurement_capture_profiles', 'CLEAR'),
('unit_measurement_profiles', 'PRESERVE')
) AS optional(table_name, disposition)
WHERE to_regclass(format('public.%I', optional.table_name)) IS NOT NULL;

DO $$
DECLARE
    duplicate_tables TEXT;
    unknown_tables TEXT;
    invalid_policy_tables TEXT;
    clear_count BIGINT;
    preserve_count BIGINT;
    measurement_table_count BIGINT;
    v440_business_table_count BIGINT;
    v443_business_table_count BIGINT;
    v446_business_table_count BIGINT;
    v447_business_table_count BIGINT;
    v448_read_index_count BIGINT;
    v451_place_source_count BIGINT;
    v454_celebration_table_count BIGINT;
    applied_migration_count BIGINT;
    applied_max_version INTEGER;
    unsafe_fk_edges TEXT;
BEGIN
    SELECT string_agg(table_name, ', ' ORDER BY table_name)
    INTO duplicate_tables
    FROM (
        SELECT table_name
        FROM reset_business_table_policy
        GROUP BY table_name
        HAVING count(*) <> 1
    ) duplicates;

    IF duplicate_tables IS NOT NULL THEN
        RAISE EXCEPTION '表分类重复/重叠：%', duplicate_tables;
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
            '存在未分类 public 表，必须先决定 CLEAR/PRESERVE：%',
            unknown_tables;
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
            invalid_policy_tables;
    END IF;

    SELECT count(*) FILTER (WHERE disposition = 'CLEAR'),
           count(*) FILTER (WHERE disposition = 'PRESERVE')
    INTO clear_count, preserve_count
    FROM reset_business_table_policy;

    SELECT count(*)
    INTO measurement_table_count
    FROM reset_business_table_policy
    WHERE table_name IN (
        'legacy_measurement_exceptions',
        'legacy_measurement_profile_snapshots',
        'legacy_measurement_source_registry',
        'measurement_capture_decision_events',
        'measurement_capture_evidence',
        'measurement_capture_line_snapshots',
        'measurement_capture_profiles',
        'unit_measurement_profiles'
    );

    IF measurement_table_count <> 8 THEN
        RAISE EXCEPTION
            'V443/V446 要求 V442 计量学习表完整存在，当前 %/8',
            measurement_table_count;
    END IF;

    SELECT count(*)
    INTO v440_business_table_count
    FROM reset_business_table_policy
    WHERE table_name IN (
        'procurement_iqc_rejection_cases',
        'procurement_iqc_rejection_commands',
        'procurement_iqc_rejection_events',
        'procurement_iqc_replacement_allocations',
        'subcontract_outbound_issue_reservation_allocations',
        'subcontract_outbound_preparation_commands'
    );

    IF v440_business_table_count <> 6 THEN
        RAISE EXCEPTION
            'V443/V446 要求 V436/V440 业务表完整存在，当前 %/6',
            v440_business_table_count;
    END IF;

    SELECT count(*)
    INTO v443_business_table_count
    FROM reset_business_table_policy
    WHERE table_name = 'sales_shipment_finance_release_events';

    IF v443_business_table_count <> 1 THEN
        RAISE EXCEPTION
            'V443 财审事件表必须存在，当前 %/1',
            v443_business_table_count;
    END IF;

    SELECT count(*)
    INTO v446_business_table_count
    FROM reset_business_table_policy
    WHERE table_name IN (
        'procurement_iqc_stock_in_batch_items',
        'procurement_iqc_stock_in_batches'
    );

    IF v446_business_table_count NOT IN (0, 2) THEN
        RAISE EXCEPTION
            'V446 IQC 入库表只出现 %/2，拒绝在部分迁移目录上重置',
            v446_business_table_count;
    END IF;

    SELECT count(*) FILTER (WHERE success),
           max(version::INTEGER) FILTER (
               WHERE success AND version ~ '^[0-9]+$'
           )
    INTO applied_migration_count, applied_max_version
    FROM flyway_schema_history;

    IF (applied_max_version, applied_migration_count) NOT IN (
        (443, 405),
        (446, 408),
        (447, 409),
        (448, 410),
        (449, 411),
        (450, 412),
        (451, 413),
        (452, 414),
        (453, 415),
        (454, 416),
        (455, 417),
        (456, 418)
    ) THEN
        RAISE EXCEPTION
            '仅允许 V443/405、V446/408、V447/409、V448/410、V449/411、V450/412、V451/413、V452/414、V453/415、V454/416、V455/417 或 V456/418 目录，当前 V%/%',
            applied_max_version, applied_migration_count;
    END IF;

    -- V454 新增通知庆典主角表（CLEAR）：目录到 V454 时必须存在；V454 前的旧目录不允许出现。
    SELECT count(*)
    INTO v454_celebration_table_count
    FROM reset_business_table_policy
    WHERE table_name = 'notice_celebration_subjects';

    IF (applied_max_version >= 454) <> (v454_celebration_table_count = 1) THEN
        RAISE EXCEPTION
            'V454 通知庆典主角表存在性 %/1 与目录版本 V% 不符，拒绝在部分迁移目录上重置',
            v454_celebration_table_count, applied_max_version;
    END IF;

    SELECT count(*)
    INTO v447_business_table_count
    FROM reset_business_table_policy
    WHERE table_name IN (
        'preplan_subcontract_entitlement_handoff_slices',
        'preplan_subcontract_requirement_handoff_events',
        'preplan_subcontract_requirement_handoff_items',
        'preplan_subcontract_requirement_handoffs',
        'preplan_subcontract_requirement_supply_claims'
    );

    IF v447_business_table_count NOT IN (0, 5) THEN
        RAISE EXCEPTION
            'V447 委外前置自制权益交接表只出现 %/5，拒绝在部分迁移目录上重置',
            v447_business_table_count;
    END IF;
    IF v447_business_table_count = 5 AND v446_business_table_count <> 2 THEN
        RAISE EXCEPTION
            'V447 目录必须同时包含完整 V446 IQC 仓库入库事实表';
    END IF;

    -- V448 只增合并页读路径索引（品质部检查结果）；目录到 V448 时必须五个都在，
    -- 且完整叠在 V446/V447 业务表之上，拒绝在部分应用的重置目录上运行。
    SELECT count(*)
    INTO v448_read_index_count
    FROM pg_indexes
    WHERE indexname IN (
        'idx_procurement_inspection_items_quality_verdict',
        'idx_procurement_inspection_events_pending_release',
        'idx_procurement_iqc_stock_in_item_event_qty',
        'idx_procurement_iqc_stock_in_item_batch',
        'idx_procurement_iqc_rejection_pending_return'
    );

    IF applied_max_version >= 448 THEN
        IF v448_read_index_count <> 5 THEN
            RAISE EXCEPTION
                'V448 合并页读路径索引缺失 %/5，拒绝在未完整应用 V448 的目录上重置',
                v448_read_index_count;
        END IF;
        IF v446_business_table_count <> 2 OR v447_business_table_count <> 5 THEN
            RAISE EXCEPTION
                'V448 目录必须完整包含 V446 IQC 入库事实表与 V447 交接事实表';
        END IF;
    END IF;

    -- V451 只泛化库位学习表来源维度（kind + IQC 批次引用 + 互斥约束 + 索引），
    -- 不新增业务表；目录到 V451 时必须四件齐全，拒绝在部分应用的重置目录上运行。
    SELECT count(*)
    INTO v451_place_source_count
    FROM (
        SELECT 1 FROM pg_attribute
        WHERE attrelid = 'warehouse_goods_place_preferences'::regclass
          AND attname = 'source_kind' AND NOT attisdropped
        UNION ALL
        SELECT 1 FROM pg_attribute
        WHERE attrelid = 'warehouse_goods_place_preferences'::regclass
          AND attname = 'source_iqc_batch_id' AND NOT attisdropped
        UNION ALL
        SELECT 1 FROM pg_constraint
        WHERE conname = 'warehouse_goods_place_preference_source_chk'
          AND conrelid = 'warehouse_goods_place_preferences'::regclass
        UNION ALL
        SELECT 1 FROM pg_indexes
        WHERE indexname = 'idx_warehouse_goods_place_preference_iqc_batch'
    ) artifacts;

    IF applied_max_version >= 451 AND v451_place_source_count <> 4 THEN
        RAISE EXCEPTION
            'V451 库位学习来源泛化构件缺失 %/4，拒绝在未完整应用 V451 的目录上重置',
            v451_place_source_count;
    END IF;

    IF preserve_count <> 95
       OR NOT (
           (v446_business_table_count = 0
                AND v447_business_table_count = 0
                AND clear_count - v454_celebration_table_count = 212)
           OR (v446_business_table_count = 2
                AND v447_business_table_count = 0
                AND clear_count - v454_celebration_table_count = 214)
           OR (v446_business_table_count = 2
                AND v447_business_table_count = 5
                AND clear_count - v454_celebration_table_count = 219)
       ) THEN
        RAISE EXCEPTION
            'V443/V446/V447 白名单数量异常：CLEAR %，PRESERVE %，V442表 %/8，V440表 %/6，V443表 %/1，V446表 %/2，V447表 %/5，V454表 %/1',
            clear_count, preserve_count, measurement_table_count,
            v440_business_table_count, v443_business_table_count,
            v446_business_table_count, v447_business_table_count,
            v454_celebration_table_count;
    END IF;

    SELECT string_agg(
               format(
                   '%I -> %I (%I)',
                   child.relname,
                   parent.relname,
                   con.conname
               ),
               ', '
               ORDER BY child.relname, parent.relname, con.conname
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
            unsafe_fk_edges;
    END IF;
END $$;

CREATE UNIQUE INDEX reset_business_table_policy_name_uq
    ON reset_business_table_policy(table_name);

CREATE TEMP TABLE reset_business_preserve_counts (
    table_name TEXT PRIMARY KEY,
    row_count BIGINT NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
    clear_tables TEXT;
BEGIN
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
END $$;

-- accounts is a preserved master table, but its five monetary accumulators are
-- projections of the business facts cleared above. Reset all active, disabled
-- and soft-deleted account rows together so no hidden historical amount survives.
-- The ordinary accounts audit trigger remains enabled; app.actor_account above
-- makes every changed row attributable to this controlled local/test operation.
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

-- Selected reset-baseline values live on preserved master tables. Keep master
-- identities, business identifiers, category/unit relations, BOM, max_qty and
-- business sales prices (price/a_price/price2),
-- while clearing legacy opening facts plus goods safety-stock/cost-budget values
-- under the same audited reset actor/request id. Versioned masters advance once.
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

-- The audited preserved-master UPDATEs may append audit_log rows. Capture PRESERVE
-- counts only after that intentional write, then require them to remain stable.
DO $$
DECLARE
    t RECORD;
    n BIGINT;
BEGIN
    FOR t IN
        SELECT table_name
        FROM reset_business_table_policy
        WHERE disposition = 'PRESERVE'
        ORDER BY table_name
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name)
        INTO n;
        INSERT INTO reset_business_preserve_counts(table_name, row_count)
        VALUES (t.table_name, n);
    END LOOP;
END $$;

REFRESH MATERIALIZED VIEW purchase_monthly_mv;
REFRESH MATERIALIZED VIEW production_monthly_mv;
REFRESH MATERIALIZED VIEW stock_monthly_mv;
REFRESH MATERIALIZED VIEW finance_ar_ap_mv;
REFRESH MATERIALIZED VIEW sales_monthly_mv;
REFRESH MATERIALIZED VIEW subcontract_monthly_mv;

DO $$
DECLARE
    t RECORD;
    n BIGINT;
BEGIN
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
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name)
        INTO n;
        IF n <> 0 THEN
            RAISE EXCEPTION
                '清空校验失败：% 仍有 % 行，整体回滚',
                t.table_name, n;
        END IF;
    END LOOP;

    FOR t IN
        SELECT table_name, row_count
        FROM reset_business_preserve_counts
        ORDER BY table_name
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name)
        INTO n;
        IF n <> t.row_count THEN
            RAISE EXCEPTION
                '保留校验失败：% 清理前 % 行、清理后 % 行，整体回滚',
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
        ]) AS table_name
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name)
        INTO n;
        IF n <> 0 THEN
            RAISE EXCEPTION
                '物化视图清空校验失败：% 仍有 % 行，整体回滚',
                t.table_name, n;
        END IF;
    END LOOP;
END $$;

COMMIT;

\echo '完成：业务流程及其自增序列、库存、账户金额、遗留期初往来/库存快照、货品安全库存及成本预算已归零；货品身份/BOM/max_qty/业务售价(price/a_price/price2)与其它主档、人事、权限、审计、附件及治理证据保留。'
\echo '抽查：'
SELECT 'employees' AS table_name, count(*) AS row_count FROM employees
UNION ALL SELECT 'goods', count(*) FROM goods
UNION ALL SELECT 'clients', count(*) FROM clients
UNION ALL SELECT 'suppliers', count(*) FROM suppliers
UNION ALL SELECT 'users', count(*) FROM users
UNION ALL SELECT 'audit_log', count(*) FROM audit_log
UNION ALL SELECT 'sales_orders', count(*) FROM sales_orders
UNION ALL SELECT 'stock_balances', count(*) FROM stock_balances;
