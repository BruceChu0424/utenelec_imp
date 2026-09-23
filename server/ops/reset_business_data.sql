-- =====================================================================
-- 本地/测试库业务数据一键清空(支持至 V645；保留主档、人事、权限与治理证据)
-- =====================================================================
-- 用途：把数据库重置为“基础资料和系统治理数据保留、业务流程、库存、账户金额、
--       遗留期初往来/库存快照、货品安全库存及成本预算归零”的
--       干净测试起点。只允许在可丢弃的本地/测试库停写后运行。
--
-- 唯一范围事实：
--   · V572 当前目录：CLEAR 276 张、PRESERVE 96 张；V560三张退料事实表、V561一张分批谱系表、V568一张让料补自制事实表、V569两张在途转拨事实表；V562至V567仅补列、函数、索引与守卫，V570仅新增权限与默认授权，V571前向补齐在途规则且不增加表，V572只补审计触发器不增加表。
--   · V552 历史目录：CLEAR 269 张、PRESERVE 96 张（V547/V548 三张新表已计入；
--     V549–V551 只改函数/视图，V552 只加权限码与默认授权）；下列历史说明用于旧版本兼容。
--   · V547 新增品质检查单头/明细两张（CLEAR 266→268），V548 新增送检登记撤回记录
--     一张（CLEAR 268→269）；均随 FQC/登记事实清空，目录版本对由发布时统一登记。
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
--     V457/V458 不改本清单结构：V457 货品后模镶件列不新增表；V458 新增两张委外前置自制账本（CLEAR 220→222）；
--     V459 新增兼职部门表 employee_secondary_departments（组织与权限治理数据，PRESERVE，95→96 张），CLEAR 维持 222 张；
--     V462 只新增工作台「清空业务数据」函数 business_data_reset()（应用内运行的孪生口径，
--     清单同步由 BusinessDataResetSqlContractTest 锁定；不新增表），CLEAR 维持 222 张；
--     V463 新增两张订货行来源分配表 purchase_order_item_sources / subcontract_order_item_sources
--     （CLEAR 222→224），V464 重发 business_data_reset() 孪生同步该清单；
--     V465 只替换 ordered_qty 守卫触发器（不新增表，CLEAR 维持 224 张）；
--     V474 新增运行时公共在途追加事件账（CLEAR 224→225），并前向同步数据库函数；
--     建议、任务认领和业务 outbox。
--   · PRESERVE 96 张（V459 前为 95）：V442 的四张单位/迁移计量治理证据表明确保留；PostGIS 扩展表不进入业务策略计数；其余为主档、人事、账号/权限、系统配置、Flyway、审计日志、
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
--   · outbox 有待处理/失败事件，或业务附件尚无完整物理删除证明时拒绝执行。
--     V537 正常完成删除的历史附件/上传会话/队列继续保留审计，不再阻止清空；
--     旧目录缺少新证明函数时仍按原严格 owner 保护拒绝，绝不默认放行。
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

    IF to_regprocedure('fn_business_attachment_reset_blockers()') IS NOT NULL THEN
        SELECT count(*) INTO unsafe_attachment_owners FROM fn_business_attachment_reset_blockers();
    ELSE
        IF EXISTS (SELECT 1 FROM flyway_schema_history WHERE success AND version ~ '^[0-9]+$' AND version::integer >= 537) THEN
            RAISE EXCEPTION 'V537 附件删除完成证明函数缺失，拒绝清空';
        END IF;
        -- Older supported catalogs retain the original strict guard; absence is never permission.
        SELECT count(*) INTO unsafe_attachment_owners FROM (
            SELECT owner_type FROM attachments
            WHERE upper(btrim(owner_type)) NOT IN ('EMPLOYEE', 'EMPLOYEE_CONTRACT')
            UNION ALL
            SELECT owner_type FROM attachment_upload_sessions
            WHERE upper(btrim(owner_type)) NOT IN ('EMPLOYEE', 'EMPLOYEE_CONTRACT')
        ) unsafe_owner;
    END IF;

    IF unsafe_attachment_owners > 0 THEN
        RAISE EXCEPTION
            '拒绝执行：仍有 % 项业务文件未完成删除；请先完成测试附件清理准备并等待文件队列结束，禁止制造孤儿文件',
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
('expense_claim_events', 'CLEAR'),
('production_daily_report_target_events', 'CLEAR'),
('production_daily_report_material_release_events', 'CLEAR'),
('production_workshop_direct_source_allocations', 'CLEAR'),
('production_workshop_direct_source_events', 'CLEAR'),
('production_workshop_direct_legacy_anomalies', 'CLEAR'),
('production_material_return_receiving_confirmations', 'CLEAR'),
('production_workshop_material_return_slices', 'CLEAR'),
('production_workshop_material_custody_preparations', 'CLEAR'),
('production_workshop_material_custody_moves', 'CLEAR'),
('production_workshop_material_custody_reversals', 'CLEAR'),
('production_workshop_material_custody_handoffs', 'CLEAR'),
('production_workshop_custody_handoff_reversals', 'CLEAR'),
('production_workshop_custody_reverse_preparations', 'CLEAR'),
('production_workshop_return_preplan_events', 'CLEAR'),
('expense_claim_invoices', 'CLEAR'),
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
('preplan_reallocation_make_supplements', 'CLEAR'),
('preplan_future_supply_transfers', 'CLEAR'),
('preplan_future_supply_transfer_cancellations', 'CLEAR'),
('preplan_stock_entitlement_events', 'CLEAR'),
('preplan_supply_action_allocations', 'CLEAR'),
('preplan_public_supply_events', 'CLEAR'),
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
('production_finished_arrival_registration_reversals', 'CLEAR'),
('production_finished_arrival_registrations', 'CLEAR'),
('production_finished_in_confirm_batch_items', 'CLEAR'),
('production_finished_in_confirm_batches', 'CLEAR'),
('production_fqc_cancellation_events', 'CLEAR'),
('production_fqc_contribution_adjustments', 'CLEAR'),
('production_fqc_decision_events', 'CLEAR'),
('production_fqc_inspection_sheet_items', 'CLEAR'),
('production_fqc_inspection_sheets', 'CLEAR'),
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
('purchase_order_item_sources', 'CLEAR'),
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
('production_daily_report_material_usages', 'CLEAR'),
('production_workshop_direct_transfer_items', 'CLEAR'),
('production_workshop_direct_transfer_reversals', 'CLEAR'),
('production_workshop_direct_transfers', 'CLEAR'),
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
('subcontract_order_item_sources', 'CLEAR'),
('subcontract_order_items', 'CLEAR'),
('subcontract_orders', 'CLEAR'),
('subcontract_receipt_items', 'CLEAR'),
('subcontract_receipts', 'CLEAR'),
('subcontract_return_items', 'CLEAR'),
('subcontract_returns', 'CLEAR'),
('subcontract_short_delivery_case_events', 'CLEAR'),
('subcontract_short_delivery_cases', 'CLEAR'),
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
('expense_claim_settings', 'PRESERVE'),
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
-- V579 客户/供应商联系方式·地址·跟进记录三张子表：随主档保留(与迁移里的
-- 运行时 business_data_reset() 补丁同口径，都是 PRESERVE)。
('party_activity_records', 'PRESERVE'),
('party_addresses', 'PRESERVE'),
('party_contact_methods', 'PRESERVE'),
('permission_surface_permissions', 'PRESERVE'),
('permission_surfaces', 'PRESERVE'),
('permissions', 'PRESERVE'),
('positions', 'PRESERVE'),
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

-- V624 source proofs share the lifetime of preserved migration runs. They do
-- not disappear when their former business orders are reset.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('legacy_subcontract_order_import_sources', 'PRESERVE'),
('legacy_finance_import_sources', 'PRESERVE'),
('legacy_procurement_receipt_import_sources', 'PRESERVE')
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

-- V458 subcontract make-before-order ledgers: the in-analysis preparation task
-- and its application batches are business transaction facts; clear both
-- together before their parent analyses/subcontract applications.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('preplan_subcontract_make_task_batches', 'CLEAR'),
('preplan_subcontract_make_tasks', 'CLEAR')
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

-- V478 root output ledger is absent from older supported catalogs.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('preplan_root_output_events', 'CLEAR')
) AS optional(table_name, disposition)
WHERE to_regclass(format('public.%I', optional.table_name)) IS NOT NULL;

-- V482 销售订单改量事实账（业务数据，清空重放）。
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('sales_order_qty_change_logs', 'CLEAR'),
('procurement_order_qty_change_logs', 'CLEAR'),
('sales_order_revision_logs', 'CLEAR'),
('preplan_subcontract_make_batch_reversals', 'CLEAR')
) AS optional(table_name, disposition)
WHERE to_regclass(format('public.%I', optional.table_name)) IS NOT NULL;

-- V500 actual stock-value facts and V503 source quantity-revision facts.
-- Each family is checked for complete presence against its migration head below.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('stock_value_pools', 'CLEAR'),
('stock_value_events', 'CLEAR'),
('stock_value_nodes', 'CLEAR'),
('stock_value_edges', 'CLEAR'),
('stock_value_jobs', 'CLEAR'),
('stock_value_tasks', 'CLEAR'),
('stock_value_node_revisions', 'CLEAR'),
('stock_value_postings', 'CLEAR'),
('procurement_order_source_revisions', 'CLEAR'),
('procurement_order_source_revision_allocations', 'CLEAR'),
('procurement_order_source_revision_peg_changes', 'CLEAR')
) AS optional(table_name, disposition)
WHERE to_regclass(format('public.%I', optional.table_name)) IS NOT NULL;

-- V506 opening evidence and separately retained legacy-balance cases.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('stock_value_openings', 'CLEAR'),
('stock_value_legacy_balance_cases', 'CLEAR'),
('stock_value_legacy_balance_case_events', 'CLEAR')
) AS optional(table_name, disposition)
WHERE to_regclass(format('public.%I', optional.table_name)) IS NOT NULL;

-- Current operational receipt, source and custody facts.
INSERT INTO reset_business_table_policy(table_name, disposition)
SELECT optional.table_name, optional.disposition
FROM (VALUES
('sales_shipment_submission_events', 'CLEAR'),
('production_material_movement_links', 'CLEAR'),
('production_material_return_requests', 'CLEAR'),
('production_material_return_request_items', 'CLEAR'),
('production_material_return_request_cancellations', 'CLEAR'),
('production_execution_segment_splits', 'CLEAR'),
('stock_value_acquisition_sources', 'CLEAR'),
('stock_value_position_transfers', 'CLEAR'),
('stock_value_production_cost_dirty', 'CLEAR'),
('stock_value_production_cost_inputs', 'CLEAR'),
('stock_value_production_cost_objects', 'CLEAR'),
('stock_value_production_cost_outputs', 'CLEAR'),
('stock_value_production_cost_revisions', 'CLEAR'),
('stock_value_production_cost_shares', 'CLEAR'),
('stock_value_production_cost_tasks', 'CLEAR'),
('procurement_iqc_consideration_reversals', 'CLEAR'),
('procurement_iqc_consideration_review_approvals', 'CLEAR'),
('procurement_iqc_credit_case_allocations', 'CLEAR'),
('procurement_iqc_credit_documents', 'CLEAR'),
('procurement_iqc_credit_slices', 'CLEAR'),
('procurement_iqc_funding_settlements', 'CLEAR'),
('procurement_iqc_funding_slices', 'CLEAR'),
('procurement_iqc_quality_consideration_parts', 'CLEAR'),
('procurement_iqc_stock_consideration_parts', 'CLEAR'),
('procurement_receipt_consideration_parts', 'CLEAR'),
('subcontract_receipt_material_consumptions', 'CLEAR')
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
    v500_value_table_count BIGINT;
    v503_source_revision_table_count BIGINT;
    v506_opening_table_count BIGINT;
    current_operational_table_count BIGINT;
    incomplete_operational_tables TEXT;
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
        (456, 418),
        (457, 419),
        (458, 420),
        (459, 421),
        (460, 422),
        (461, 423),
        (462, 424),
        (463, 425),
        (464, 426),
        (465, 427),
        (466, 428),
        (467, 429),
        (468, 430),
        (469, 431),
        (470, 432),
        (471, 433),
        (472, 434),
        (473, 435),
        (474, 436),
        (475, 437),
        (476, 438),
        (477, 439),
        (478, 440),
        (479, 441),
        (480, 442),
        (481, 443),
        (482, 444),
        (483, 445),
        (484, 446),
        (485, 447),
        (486, 448),
        (487, 449),
        -- V488 只给偏好表补列、V489/V490 只替换函数、V491 只改报工门控函数，
        -- 均不新增业务表。
        (488, 450),
        (489, 451),
        (490, 452),
        (491, 453),
        (492, 454),
        (493, 455),
        (494, 456),
        (495, 457),
        (496, 458),
        (497, 459),
        (498, 460),
        (499, 461),
        (500, 462),
        (501, 463),
        (502, 464),
        (503, 465),
        (504, 466),
        (505, 467),
        (506, 468),
        (507, 469),
        (508, 470),
        (511, 471),
        (513, 472),
        (514, 473),
        (515, 474),
        (516, 475),
        (517, 476),
        (518, 477),
        (519, 478),
        (520, 479),
        (521, 480),
        (522, 481),
        (523, 482),
        (524, 483),
        (525, 484),
        (526, 485),
        (527, 486),
        (528, 487),
        (529, 488),
        (530, 489),
        (531, 490),
        (532, 491),
        (533, 492),
        (534, 493),
        (535, 494),
        (536, 495),
        (537, 496),
        (538, 497),
        (539, 498),
        (540, 499),
        -- V541/V543 只调整权限矩阵，V542 只加备注列，V545 只回填 chain_status，
        -- V546 只扩授附件权限，V549/V550 只替换函数；V547 +2 张 FQC 检查单表、
        -- V548 +1 张登记撤回表（CLEAR 266→269）。V544 未发布，目录跳号。
        (541, 500),
        (542, 501),
        (543, 502),
        (545, 503),
        (546, 504),
        (547, 505),
        (548, 506),
        (549, 507),
        (550, 508),
        -- V551 只替换待交货视图（排除草稿），不新增表。
        (551, 509),
        -- V552 只新增一个权限码并给已有部门默认授权，不新增业务表；CLEAR 维持 269 张。
        (552, 510),
        -- V553 only corrects setting descriptions; no table or configuration value changes.
        (553, 511),
        -- V554 fixes derived procurement source coverage without new business tables.
        (554, 512),
        -- V555 preserves original-order replacement entitlements; no new business tables.
        (555, 513),
        -- V556 changes future audit classification computation without new business tables.
        (556, 514),
        -- V557 records batch identity on existing quality events; no new business tables.
        (557, 515),
        -- V558 avoids empty-table storage recreation while retaining exact reset semantics.
        (558, 516),
        (559, 517),
        (560, 518),
        (561, 519),
        (562, 520),
        (563, 521),
        (564, 522),
        (565, 523),
        (566, 524),
        (567, 525),
        (568, 526),
        (569, 527),
        -- V570 只新增一个权限码（goods:price:view）并给既有部门默认授权，
        -- 不新增业务表；CLEAR 维持既有张数。
        (570, 528),
        (571, 529),
        -- V572 审计触发器 sweep：只补 trg_audit_*，不新增表。
        (572, 530),
        -- V573 放宽让料/在途调拨的业务原因 CHECK；V574 放开跨路线在途调入并补
        -- 两条热路径索引；V575 为货品加最小起订量与订货倍数。三者都只改
        -- 约束/函数/索引/列，不新增业务表，CLEAR 维持既有张数。
        (573, 531),
        (574, 532),
        (575, 533),
        -- V577 只给 production_material_analysis_plan_links 加一列并改一个触发器
        -- （下达车间超量的公共备货产出分账），不新增业务表，CLEAR 维持既有张数。
        -- V576 由并行的财务主档改造分支占用，本分支顺延取号，合并后需重算本表。
        (577, 534),
        -- V578 只扩财审事件类型 CHECK，不加表；V579 新增三张 party 子表；
        -- V580 只放宽计划关联行对账(公共备货单可不带销售来源)，不加表
        -- (全部 PRESERVE，CLEAR 维持既有张数)，并给运行时清空函数打 PRESERVE 补丁。
        (578, 535),
        (579, 536),
        (580, 537),
        -- V581 只扩 subcontract_material_plan_items 的 flow_mode 白名单与四个
        -- 既有守卫(委外「单一叶子子件」直接发料出仓)，不新增业务表，
        -- CLEAR 维持既有张数。
        (581, 538),
        -- V582 只收窄 sales_shipments.warehouse_work_status 取值(仓库一步确认出库)
        -- 并重建配套触发器/索引/视图，不新增业务表，CLEAR 维持既有张数。
        (582, 539),
        -- V583 新增 production_daily_report_material_usages(报工同页登记实际用料，CLEAR)
        -- 并给日报加收尾退仓意愿列、给结算事件加日报来源列。
        (583, 540),
        -- V584 新增车间直送三张表(CLEAR)：direct_transfers / _items / _reversals，
        -- 并给仓库加线边仓标记、给报工行加产出去向、给 FQC 加检验种类。
        (584, 541),
        -- V585 只加报工行的接收需求列、种一个审核权限码并登记权限面，不新增业务表。
        (585, 542),
        -- V586 只把 V583 报工实耗表与 V584 车间直送三张表补登记进清库策略
        -- (fail-closed 清单漏登记会让整包 ops 测试红)，不新增业务表；
        -- 版本对的第二个数是**迁移文件条数**，本迁移本身让它 542→543。
        (586, 543),
        -- V587 只给货品主档加「所属仓库」一列(owning_warehouse_id -> warehouses)，
        -- 不新增业务表；goods 已登记为 PRESERVE，清库分类不变，条数 543→544。
        (587, 544),
        -- V588 只放宽两个守卫函数(销售顶层超量下达不拆单：一张计划的数量=
        -- 归需求量+公共备货产出、分摊只认归需求量；采购/委外申请允许
        -- 需求片+公共超量片合并成一条明细)，不新增业务表，
        -- 清库分类不变，条数 544→545。
        (588, 545),
        -- V589 委外前置自制跟量：只放宽 fn_guard_preplan_public_surplus_shape
        -- 与 SUBCONTRACT_MAKE_TASK 批次行 allocation 锚，不新增业务表，
        -- 清库分类不变，条数 545→546。
        (589, 546),
        -- V590 货品归属「仓库/生产车间」单一事实源：货品表加归属车间/归属车间
        -- 负责人两列，production_goods_workshop_preferences 整表废弃删除
        -- (PRESERVE 96→95，数据搬进货品表随 goods 继续保留)；条数 546→547。
        (590, 547),
        -- V591 存量归属回填：只更新 goods 表的归属仓/车间两列(从既有事实种上；
        -- 注释里勿出现 goods 更新语句的字面写法，脚本契约测试按字面 indexOf 抓锚点
        -- 排序，注释抢锚点会让排序断言假红)，不新增业务表；条数 547→548。
        (591, 548),
        -- V592 客户默认销售条款：clients 加默认货运策略/默认币种两列并从
        -- 最近订单回填（结账方式复用既有列），不新增业务表；条数 548→549。
        (592, 549),
        -- V593 采购/委外链主档默认值：货品加采购/委外两价列、供应商加默认
        -- 币种/税率列并从最近订单回填（结账方式复用既有列，成对过 V452 触发器）；
        -- 不新增业务表；条数 549→550。
        (593, 550),
        -- V594 日报审核补链放行：只 CREATE OR REPLACE 只增不改守卫函数，
        -- 唯一放行 settlement_events.daily_report_id 的 NULL→值首次回填；
        -- 不新增业务表、不改任何既有行；条数 550→551。
        (594, 551),
        -- V595 车间直送 v2：段/需求各加一列(持续生产、直送供给)、锚点放宽段完整性守卫、
        -- 改写物料视图 ready 列、三个只读判定函数与两条索引、事件动作白名单加
        -- START_CONTINUOUS；不新增业务表、不改任何既有行；条数 551→552。
        (595, 552),
        -- V596 到货先入库后质检(上架待检)：待检明细加四列上架位置 + 事件动作 PRE_STOCKED +
        -- 入库批次来源列 + 登记命令结果扩展 + 一个权限码；不新增业务表、不改任何既有行；条数 552→553。
        (596, 553),
        -- V597 产成品先入库后质检(合格自动点收)：送检登记头加三列决定 + 登记守卫补记账叶仓/非线边仓 +
        -- 点收确认加 origin 与自动点收守卫 + 一个权限码；不新增业务表、不改任何既有行；条数 553→554。
        (597, 554),
        -- V598 货品来源按路线确认历史回填：只更新 goods 表的 source_type 一列
        -- (每货品取最近一次确认路线，BUY/MAKE/SUBCONTRACT 映射采购/自制/委外；
        -- 注释里勿出现 goods 更新语句的字面写法，脚本契约测试按字面 indexOf 抓
        -- 锚点排序，注释抢锚点会让排序断言假红)，不新增业务表；条数 554→555。
        (598, 555),
        -- V599 开工路线确认门控与到货进展通知：执行段加 start_route/route_confirmed_at 两列 +
        -- 两个只读判定函数 + 事件动作 ROUTE_CONFIRMED + 一条 demand_id 领料反查索引；
        -- 不新增业务表；条数 555→556。
        (599, 556),
        -- V600 庆典通知默认不自动发送：翻转 system_settings 一个开关、无 DDL；条数 556→557。
        (600, 557),
        -- V601 通知办结即已读存量回填：对已办结(resolved_at)定向通知的接收人
        -- 幂等补 read_at（INSERT..SELECT..ON CONFLICT，已读不回退、已删列表项
        -- 不复活），不加表、不改任何其它行；条数 557→558。
        (601, 558),
        -- V602 生产路线记忆点查：只 CREATE INDEX + COMMENT（执行段同产品最近
        -- 一次确认路线的部分索引），不加表、不改任何行；条数 558→559。
        (602, 559),
        -- V603 访客黑名单运营元数据：visitor_accounts 加 blocked_reason/blocked_at/
        -- blocked_by 三列 + 注释，不加表；条数 559→560。V604 未发布跳号（同 V544/V576）。
        (603, 560),
        -- V605 直送资格收紧：只认自制子件——改 fn_demand_direct_supply_eligible
        -- 判支（函数替换），不加表、不改数据行；条数 560→561。
        (605, 561),
        -- V606 开工路线自动识别：路线在创建事务内自动判定（函数替换 + 存量回填
        -- UPDATE），不加表；条数 561→562。
        (606, 562),
        -- V607 客户货款类型放开为选填（DROP 约束），不加表；条数 562→563。
        (607, 563),
        -- V608 报销链路完整化：发票登记表 + 审批事件表（+2 CLEAR）；条数 563→564。
        (608, 564),
        -- V609-V612 车间路线/容量/普通仓/直送守恒：无新增业务表。
        (609, 565),
        (610, 566),
        (611, 567),
        (612, 568),
        -- V613 技术子位不改变普通仓收发身份，统一运营叶仓定义。
        (613, 569),
        (614, 570),
        (615, 571),
        (616, 572),
        (617, 573),
        (618, 574),
        (619, 575),
        (620, 576),
        (621, 577),
        (622, 578),
        (623, 579),
        -- V624 keeps immutable first-import subcontract source evidence across business resets.
        (624, 580),
        -- V625 restricts runtime maintenance capabilities without adding business tables.
        (625, 581),
        -- V626 preserves original financial source evidence without replaying historical cash events.
        (626, 582),
        -- V627 preserves historical purchase/subcontract receipt source evidence.
        (627, 583),
        -- V628 only replaces route/material-fact functions and one view; no table.
        (628, 584),
        -- V629 relaxes split guards for zero-material tasks, rebuilds two fact functions and adds one index; no table.
        (629, 585),
        -- V630 退役客户货款类别标签: 删 clients/放行事件表两列+约束+索引+视图, 不加表; 条数 585→586。
        (630, 586),
        -- V631 出货明细按行记实际发出仓: 明细加列+索引、出库事件加 jsonb 列、锚点补丁一个守卫函数, 不加表; 条数 586→587。
        (631, 587),
        -- V632 出货放行记账汇率: 放行事件表加汇率/来源两列+三条 CHECK, 补 4 条标准收付款方式, 不加表; 条数 587→588。
        (632, 588),
        -- V634 委外前置自制超量后的订货批准谱系守卫: 只 CREATE OR REPLACE 一个断言函数, 不加表; V633 跳号, 本迁移 588→589。
        (634, 589),
        -- V636 委外允许损耗与回厂短交案件(ADR-098): goods/订货明细各加一列, 新增案件表与事件表(CLEAR 296→298), 权限 1 个, 汇总视图 2 个; V635 跳号; 条数 589→590。
        (636, 590),
        -- V638 委外回厂先出后进守卫计入前置自制出仓行: 只锚点补丁一个断言函数, 不加表; V637 跳号, 本迁移 590→591。
        (638, 591),
        -- V640 未订货申请明细就地追加(ADR-099): 两个判定函数 + 锚点补丁三个身份守卫, 不加表; V639 跳号, 本迁移 591→592。
        (640, 592),
        -- V641 我方供料委外件放开公共超量备货: 锚点补丁两个函数(形状守卫去掉单一叶子子件那条拒绝、运行时超订容量去掉「委外件有 BOM 恒返 0」), 不加表; 本迁移 592→593。
        (641, 593),
        -- V642 委外回厂守恒守卫计入财务已批准的委外商自带料(ADR-101): 只锚点补丁一个断言函数, 不加表; 本迁移 593→594。
        (642, 594),
        -- V644 审核生产日报的幂等键: 命令账本加 command_kind 一列并把 UNIQUE(report_id) 换成 (report_id, command_kind), 不加表; V642、V643 跳号, 本迁移 594→595。
        (644, 595),
        -- V645 追加自制并入未开工的生产计划(ADR-104): 四个判定函数 + 一条对账触发器 + 锚点补丁三个身份守卫, 不加表; 本迁移 595→596。
        (645, 596)
    ) THEN
        RAISE EXCEPTION
            '仅允许 V443/405、V446/408、V447/409、V448/410、V449/411、V450/412、V451/413、V452/414、V453/415、V454/416、V455/417、V456/418、V457/419、V458/420、V459/421、V460/422、V461/423、V462/424、V463/425、V464/426、V465/427、V466/428、V467/429、V468/430、V469/431、V470/432、V471/433、V472/434、V473/435、V474/436、V475/437 、V476/438、V477/439、V478/440、V479/441、V480/442、V481/443、V482/444、V483/445、V484/446、V485/447、V486/448、V487/449、V488/450、V489/451、V490/452、V491/453、V492/454、V493/455、V494/456、V495/457、V496/458、V497/459、V498/460、V499/461、V500/462、V501/463、V502/464、V503/465、V504/466、V505/467、V506/468、V507/469、V508/470及V511至V645完整目录(V544、V576、V604、V633、V635、V637、V639、V643 跳号)，当前 V%/%',
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

    SELECT count(*) INTO v500_value_table_count FROM reset_business_table_policy
    WHERE table_name IN ('stock_value_pools','stock_value_events','stock_value_nodes','stock_value_edges',
        'stock_value_jobs','stock_value_tasks','stock_value_node_revisions','stock_value_postings');
    SELECT count(*) INTO v503_source_revision_table_count FROM reset_business_table_policy
    WHERE table_name IN ('procurement_order_source_revisions','procurement_order_source_revision_allocations',
        'procurement_order_source_revision_peg_changes');
    SELECT count(*) INTO v506_opening_table_count FROM reset_business_table_policy
    WHERE table_name IN ('stock_value_openings','stock_value_legacy_balance_cases','stock_value_legacy_balance_case_events');
    IF v500_value_table_count <> (CASE WHEN applied_max_version>=500 THEN 8 ELSE 0 END)
       OR v503_source_revision_table_count <> (CASE WHEN applied_max_version>=503 THEN 3 ELSE 0 END) THEN
        RAISE EXCEPTION '存货价值表 %/8 或来源改量表 %/3 与目录 V% 不符，拒绝部分迁移目录',
            v500_value_table_count,v503_source_revision_table_count,applied_max_version;
    END IF;
    IF v506_opening_table_count <> (CASE WHEN applied_max_version>=506 THEN 3 ELSE 0 END) THEN
        RAISE EXCEPTION '开账及历史余额表 %/3 与目录 V% 不符，拒绝部分迁移目录',v506_opening_table_count,applied_max_version;
    END IF;

    -- Missing, partial and prematurely present families all fail closed.
    SELECT string_agg(required.table_name, ', ' ORDER BY required.table_name)
    INTO incomplete_operational_tables
    FROM (VALUES
            ('sales_shipment_submission_events', 511),
            ('production_material_movement_links', 514),
            ('production_material_return_requests', 560),
            ('production_material_return_request_items', 560),
            ('production_material_return_request_cancellations', 560),
            ('production_execution_segment_splits', 561),
            ('preplan_reallocation_make_supplements', 568),
            ('preplan_future_supply_transfers', 569),
            ('preplan_future_supply_transfer_cancellations', 569),
            ('stock_value_acquisition_sources', 517),
            ('stock_value_position_transfers', 517),
            ('stock_value_production_cost_dirty', 517),
            ('stock_value_production_cost_inputs', 517),
            ('stock_value_production_cost_objects', 517),
            ('stock_value_production_cost_outputs', 517),
            ('stock_value_production_cost_revisions', 517),
            ('stock_value_production_cost_shares', 517),
            ('stock_value_production_cost_tasks', 517),
            ('procurement_iqc_consideration_reversals', 518),
            ('procurement_iqc_consideration_review_approvals', 518),
            ('procurement_iqc_credit_case_allocations', 518),
            ('procurement_iqc_credit_documents', 518),
            ('procurement_iqc_credit_slices', 518),
            ('procurement_iqc_funding_settlements', 518),
            ('procurement_iqc_funding_slices', 518),
            ('procurement_iqc_quality_consideration_parts', 518),
            ('procurement_iqc_stock_consideration_parts', 518),
            ('procurement_receipt_consideration_parts', 518),
            ('subcontract_receipt_material_consumptions', 522),
            ('production_fqc_inspection_sheets', 547),
            ('production_fqc_inspection_sheet_items', 547),
            ('production_finished_arrival_registration_reversals', 548),
            ('production_daily_report_material_usages', 583),
            ('production_workshop_direct_transfers', 584),
            ('production_workshop_direct_transfer_items', 584),
            ('production_workshop_direct_transfer_reversals', 584),
            ('expense_claim_invoices', 608),
            ('expense_claim_events', 608),
            ('expense_claim_settings', 617),
            ('legacy_subcontract_order_import_sources', 624),
            ('legacy_finance_import_sources', 626),
            ('legacy_procurement_receipt_import_sources', 627),
            ('production_daily_report_target_events', 614),
            ('production_daily_report_material_release_events', 614),
            ('production_workshop_direct_source_allocations', 615),
            ('production_workshop_direct_source_events', 615),
            ('production_workshop_direct_legacy_anomalies', 615),
            ('production_material_return_receiving_confirmations', 618),
            ('production_workshop_material_return_slices', 619),
            ('production_workshop_material_custody_preparations', 619),
            ('production_workshop_material_custody_moves', 619),
            ('production_workshop_material_custody_reversals', 619),
            ('production_workshop_material_custody_handoffs', 619),
            ('production_workshop_custody_handoff_reversals', 619),
            ('production_workshop_custody_reverse_preparations', 619),
            ('production_workshop_return_preplan_events', 619)
    ) AS required(table_name, introduced_version)
    WHERE (to_regclass(format('public.%I', required.table_name)) IS NOT NULL)
        IS DISTINCT FROM (applied_max_version >= required.introduced_version);
    IF incomplete_operational_tables IS NOT NULL THEN
        RAISE EXCEPTION '当前业务来源表与迁移目录不符，拒绝清空: %', incomplete_operational_tables;
    END IF;
    SELECT count(*) INTO current_operational_table_count
    FROM reset_business_table_policy
    WHERE table_name IN ('preplan_future_supply_transfers','preplan_future_supply_transfer_cancellations','preplan_reallocation_make_supplements','production_material_return_requests','production_material_return_request_items','production_material_return_request_cancellations','production_execution_segment_splits','sales_shipment_submission_events','production_material_movement_links','stock_value_acquisition_sources','stock_value_position_transfers','stock_value_production_cost_dirty','stock_value_production_cost_inputs','stock_value_production_cost_objects','stock_value_production_cost_outputs','stock_value_production_cost_revisions','stock_value_production_cost_shares','stock_value_production_cost_tasks','procurement_iqc_consideration_reversals','procurement_iqc_consideration_review_approvals','procurement_iqc_credit_case_allocations','procurement_iqc_credit_documents','procurement_iqc_credit_slices','procurement_iqc_funding_settlements','procurement_iqc_funding_slices','procurement_iqc_quality_consideration_parts','procurement_iqc_stock_consideration_parts','procurement_receipt_consideration_parts','subcontract_receipt_material_consumptions','production_fqc_inspection_sheets','production_fqc_inspection_sheet_items','production_finished_arrival_registration_reversals','production_daily_report_material_usages','production_workshop_direct_transfers','production_workshop_direct_transfer_items','production_workshop_direct_transfer_reversals','expense_claim_invoices','expense_claim_events','production_daily_report_target_events','production_daily_report_material_release_events','production_workshop_direct_source_allocations','production_workshop_direct_source_events','production_workshop_direct_legacy_anomalies','production_material_return_receiving_confirmations','production_workshop_material_return_slices','production_workshop_material_custody_preparations','production_workshop_material_custody_moves','production_workshop_material_custody_reversals','production_workshop_material_custody_handoffs','production_workshop_custody_handoff_reversals','production_workshop_custody_reverse_preparations','production_workshop_return_preplan_events','subcontract_short_delivery_cases','subcontract_short_delivery_case_events');

    -- V459 新增兼职部门表（PRESERVE 95→96，组织与权限治理数据）。
    -- V579 新增客户/供应商联系方式·地址·跟进记录三张子表(PRESERVE 96→99，
    -- 随主档保留；它们是主档的一部分，不是业务流水)。
    IF (applied_max_version <= 458 AND preserve_count <> 95)
       OR (applied_max_version BETWEEN 459 AND 578 AND preserve_count <> 96)
       OR (applied_max_version BETWEEN 579 AND 589 AND preserve_count <> 99)
       -- V590 废弃车间偏好表 production_goods_workshop_preferences（数据搬进货品表
       -- 随 goods 继续保留）：PRESERVE 99→98。
       OR (applied_max_version BETWEEN 590 AND 616 AND preserve_count <> 98)
       OR (applied_max_version BETWEEN 617 AND 623 AND preserve_count <> 99)
       OR (applied_max_version BETWEEN 624 AND 625 AND preserve_count <> 100)
       OR (applied_max_version = 626 AND preserve_count <> 101)
       OR (applied_max_version >= 627 AND preserve_count <> 102)
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
           -- V458 adds two CLEAR ledger tables on top of the V447 catalog.
           OR (v446_business_table_count = 2
                AND v447_business_table_count = 5
                AND clear_count - v454_celebration_table_count = 221)
           -- V463 adds two CLEAR order-item source tables (221 → 223 + celebration = 224).
           OR (v446_business_table_count = 2
                AND v447_business_table_count = 5
                AND clear_count - v454_celebration_table_count = 223)
           -- V474 adds one CLEAR runtime public-supply event ledger.
           OR (v446_business_table_count = 2
                AND v447_business_table_count = 5
                AND clear_count - v454_celebration_table_count = 224)
           OR (applied_max_version>=478 AND v446_business_table_count=2
                AND v447_business_table_count=5
                AND clear_count-v454_celebration_table_count=225)
           -- V482 adds one CLEAR sales qty-change fact ledger (V474..V482 all in).
           OR (applied_max_version>=482 AND v446_business_table_count=2
                AND v447_business_table_count=5
                AND clear_count-v454_celebration_table_count=226)
           -- V486 adds one CLEAR procurement qty-change fact ledger (ADR-072).
           OR (applied_max_version>=486 AND v446_business_table_count=2
                AND v447_business_table_count=5
                AND clear_count-v454_celebration_table_count=227)
           -- V492 adds the append-only commercial revision ledger.
           OR (applied_max_version>=492 AND v446_business_table_count=2
                AND v447_business_table_count=5
                AND clear_count-v454_celebration_table_count=228)
           -- V496 adds append-only subcontract notification batch reversals.
           OR (applied_max_version>=496 AND v446_business_table_count=2
                AND v447_business_table_count=5
                AND clear_count-v454_celebration_table_count=229)
           -- V500 eight value tables; V503 three source revision tables.
           -- V608 报销链路完整化：发票登记表 + 审批事件表进 current_operational_
           -- table_count 清单（clear_count 同步 +2，恒等式仍为 229）。
           OR (applied_max_version>=500 AND v446_business_table_count=2
                AND v447_business_table_count=5
                AND clear_count-v454_celebration_table_count-v500_value_table_count-v503_source_revision_table_count-v506_opening_table_count-current_operational_table_count=229)
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
    t RECORD;
    n BIGINT;
    cleared_rows_total BIGINT := 0;
BEGIN
    -- V558 sparse reset: lock the complete policy before observing exact row counts.
    SELECT string_agg(format('public.%I', table_name), ', ' ORDER BY table_name)
    INTO clear_tables
    FROM reset_business_table_policy WHERE disposition = 'CLEAR';
    IF clear_tables IS NULL THEN
        RAISE EXCEPTION 'CLEAR 白名单为空';
    END IF;
    EXECUTE 'LOCK TABLE ' || clear_tables || ' IN ACCESS EXCLUSIVE MODE';

    DROP TABLE IF EXISTS pg_temp.reset_business_clear_work;
    CREATE TEMP TABLE reset_business_clear_work (
        table_name TEXT PRIMARY KEY,
        table_oid OID NOT NULL UNIQUE,
        row_count BIGINT NOT NULL DEFAULT 0,
        truncate_required BOOLEAN NOT NULL DEFAULT FALSE
    ) ON COMMIT DROP;
    INSERT INTO reset_business_clear_work(table_name, table_oid)
    SELECT policy.table_name, relation.oid
    FROM reset_business_table_policy policy
    JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'public'
    JOIN pg_catalog.pg_class relation
      ON relation.relnamespace = namespace.oid AND relation.relname = policy.table_name
    WHERE policy.disposition = 'CLEAR';

    -- LOCK privileges do not replace the original TRUNCATE check. PostgreSQL
    -- checks explicitly listed roots, not recursively included descendants.
    IF EXISTS (SELECT 1 FROM reset_business_clear_work work
               WHERE NOT pg_catalog.has_table_privilege(work.table_oid, 'TRUNCATE')) THEN
        RAISE EXCEPTION '清空范围内存在无 TRUNCATE 权限的业务表' USING ERRCODE = '42501';
    END IF;

    DROP TABLE IF EXISTS pg_temp.reset_business_clear_family;
    CREATE TEMP TABLE reset_business_clear_family (
        root_oid OID NOT NULL,
        member_oid OID NOT NULL,
        PRIMARY KEY(root_oid, member_oid)
    ) ON COMMIT DROP;
    WITH RECURSIVE family(root_oid, member_oid) AS (
        SELECT table_oid, table_oid FROM reset_business_clear_work
        UNION
        SELECT family.root_oid, inheritance.inhrelid FROM family
        JOIN pg_catalog.pg_inherits inheritance ON inheritance.inhparent = family.member_oid
    )
    INSERT INTO reset_business_clear_family SELECT root_oid, member_oid FROM family;
    CREATE INDEX ON reset_business_clear_family(member_oid);

    -- Retain full TRUNCATE RESTRICT even when a referenced table is empty:
    -- external schemas and references to individual partitions also count.
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint foreign_key
        WHERE foreign_key.contype = 'f'
          AND EXISTS (SELECT 1 FROM reset_business_clear_family family
                      WHERE family.member_oid = foreign_key.confrelid)
          AND NOT EXISTS (SELECT 1 FROM reset_business_clear_family family
                          WHERE family.member_oid = foreign_key.conrelid)
    ) THEN
        RAISE EXCEPTION '清空范围外的表仍引用待清业务表或分区，禁止清空' USING ERRCODE = 'UT900';
    END IF;

    FOR t IN SELECT table_name FROM reset_business_clear_work ORDER BY table_name LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name) INTO n;
        cleared_rows_total := cleared_rows_total + n;
        UPDATE reset_business_clear_work SET row_count = n WHERE table_name = t.table_name;
    END LOOP;

    -- Traditional inheritance and user TRUNCATE triggers retain the original
    -- full TRUNCATE semantics: a BEFORE trigger may write another empty table.
    -- Partition roots always retain their complete TRUNCATE subtree. Map FK
    -- references on any partition back to its classified root before closure.
    -- Higher isolation can retain an empty snapshot despite a newly committed
    -- row before these locks. Only a full TRUNCATE preserves that old behavior.
    IF current_setting('transaction_isolation') NOT IN ('read committed', 'read uncommitted') OR EXISTS (
        SELECT 1 FROM reset_business_clear_family family WHERE EXISTS (
            SELECT 1 FROM pg_catalog.pg_trigger trigger_row
            WHERE trigger_row.tgrelid = family.member_oid AND NOT trigger_row.tgisinternal
              AND (trigger_row.tgtype & 32) <> 0
        ) OR EXISTS (
            SELECT 1 FROM pg_catalog.pg_inherits inheritance
            JOIN pg_catalog.pg_class child_relation ON child_relation.oid = inheritance.inhrelid
            WHERE family.member_oid IN (inheritance.inhparent, inheritance.inhrelid)
              AND NOT child_relation.relispartition
        )
    ) THEN
        UPDATE reset_business_clear_work SET truncate_required = TRUE;
    ELSE
        WITH RECURSIVE truncate_scope(table_oid) AS (
            SELECT work.table_oid FROM reset_business_clear_work work
            WHERE work.row_count > 0 OR pg_catalog.row_security_active(work.table_oid) OR EXISTS (
                SELECT 1 FROM reset_business_clear_family family
                WHERE family.root_oid = work.table_oid AND family.member_oid <> family.root_oid
            )
            UNION
            SELECT child.root_oid
            FROM truncate_scope parent
            JOIN reset_business_clear_family parent_family ON parent_family.root_oid = parent.table_oid
            JOIN pg_catalog.pg_constraint foreign_key
              ON foreign_key.confrelid = parent_family.member_oid AND foreign_key.contype = 'f'
            JOIN reset_business_clear_family child ON child.member_oid = foreign_key.conrelid
        )
        UPDATE reset_business_clear_work work SET truncate_required = TRUE
        WHERE work.table_oid IN (SELECT table_oid FROM truncate_scope);
    END IF;

    SELECT string_agg(format('public.%I', table_name), ', ' ORDER BY table_name)
    INTO clear_tables FROM reset_business_clear_work WHERE truncate_required;
    IF clear_tables IS NOT NULL THEN
        EXECUTE 'TRUNCATE TABLE ' || clear_tables || ' RESTART IDENTITY';
    END IF;

    -- An empty table can still own an advanced sequence. RESTART (without a
    -- literal start value) preserves seqstart and rolls back with this reset.
    FOR t IN
        SELECT namespace.nspname AS sequence_schema, sequence.relname AS sequence_name
        FROM reset_business_clear_work work
        JOIN pg_catalog.pg_depend dependency
          ON dependency.refobjid = work.table_oid AND dependency.refobjsubid > 0
         AND dependency.classid = 'pg_catalog.pg_class'::regclass
         AND dependency.refclassid = 'pg_catalog.pg_class'::regclass
         AND dependency.deptype IN ('a', 'i')
        JOIN pg_catalog.pg_class sequence
          ON sequence.oid = dependency.objid AND sequence.relkind = 'S'
        JOIN pg_catalog.pg_namespace namespace ON namespace.oid = sequence.relnamespace
        WHERE NOT work.truncate_required
        ORDER BY namespace.nspname, sequence.relname
    LOOP
        EXECUTE format('ALTER SEQUENCE %I.%I RESTART', t.sequence_schema, t.sequence_name);
    END LOOP;
    -- End V558 sparse reset.
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
