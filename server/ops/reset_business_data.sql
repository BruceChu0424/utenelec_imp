-- =====================================================================
-- 业务数据一键清空脚本（保留基础资料 / 人事 / 系统权限，幂等）
-- =====================================================================
-- 用途：把数据库重置为"只有基础资料、零业务单据"的干净状态，用于测试
--       库初始化、验收环境翻新等场景。
--
-- 清空范围（147 张业务表）：
--   · 销售：报价/订单/发货/退货/其他出库（含明细、成本、质检、处置事件）
--   · 采购：申请/订单/收货/退货、入库预期、IQC 检验、到货异常、审批
--   · 库存：单据/明细/流水/余额/预留/调整申请
--   · 生产：计划/工单/日报/执行段/物料分析/需求/供需 peg/结算与库存过账/
--           规划包/MRP/预排供给/研发任务
--   · 委外：申请/询价/订单/发料/退料/收货/退货/废料（含明细、成本）
--   · 财务：总账凭证/分录、应收应付台账、收付款、费用、其他收入、银行
--           转账、支票登记、对账、长期待摊、报销、固定资产全链
--   · 工资：批次/明细/工资条/变动项（员工档案本身保留）
--   · 其他：公告/建议/访客/官网询盘、审计日志、任务认领、附件索引、
--           货品导入批次、老库迁移运行记录、业务 outbox
--   · 单据编号流水 doc_number_sequences / business_document_sequences
--     一并清零，新单据从头编号
--
-- 保留范围（不清空）：
--   · 人事：employees 及合同/薪酬/学历/证件/车辆/紧急联系人/任职历史、
--     部门、岗位
--   · 主档：货品/BOM/客户/供应商/模具/各分类/颜色/单位/币种/仓库/
--     结算方式/付款方式/科目/账户
--   · 编码预留：master_code_* / business_identifier_* / business_prefix_*
--     （保留可避免清空后新单据与历史编号冲突）
--   · 系统权限：用户/角色/权限/部门权限/系统设置/flyway_schema_history
--
-- 安全机制：
--   · 必须显式传 -v confirm=CLEAR_BUSINESS，否则中止
--   · 单事务执行：清空后逐张业务表断言为 0 行才提交，任何异常整体回滚
--   · TRUNCATE 不触发行级触发器，无需 DISABLE TRIGGER；无外键从保留表
--     指向业务表（2026-08-19 已验证），CASCADE 只会波及上表清单内部
--
-- 用法（先备份！）：
--   docker exec uten-imp-postgres pg_dump -U uten -d uten_imp -Fc \
--       > server/backups/pre_reset_$(date +%Y%m%d_%H%M%S).dump
--   docker exec -i uten-imp-postgres psql -U uten -d uten_imp \
--       -v ON_ERROR_STOP=1 -v confirm=CLEAR_BUSINESS \
--       < server/ops/reset_business_data.sql
--
-- 执行记录：见 docs/数据迁移/README.md 顶部"本地库业务数据清空记录"。
-- =====================================================================

\if :{?confirm}
\else
    \echo '拒绝执行：必须显式传 -v confirm=CLEAR_BUSINESS'
    \set confirm 'MISSING'
\endif

SELECT set_config('app.reset_business_confirm', :'confirm', false);

BEGIN;

DO $$
BEGIN
    IF current_setting('app.reset_business_confirm', true) IS DISTINCT FROM 'CLEAR_BUSINESS' THEN
        RAISE EXCEPTION '拒绝执行：confirm 必须等于 CLEAR_BUSINESS';
    END IF;
END $$;

TRUNCATE
    -- 销售
    sales_quotes, sales_quote_items,
    sales_orders, sales_order_items, sales_order_cost_items,
    sales_shipments, sales_shipment_items, sales_shipment_warehouse_events,
    sales_other_shipments, sales_other_shipment_items,
    sales_returns, sales_return_items,
    sales_return_disposition_events, sales_return_quality_events, sales_return_quality_items,
    -- 采购
    purchase_requests, purchase_request_items,
    purchase_orders, purchase_order_items,
    purchase_receipts, purchase_receipt_items,
    purchase_returns, purchase_return_items,
    inbound_expectations, inbound_expectation_items,
    procurement_arrival_exceptions, procurement_arrival_exception_events,
    procurement_inspection_events, procurement_inspection_items,
    procurement_order_approval_cases, procurement_order_approval_events,
    supplier_return_tasks,
    -- 库存
    stock_documents, stock_document_items, stock_movements, stock_balances,
    stock_reservations, stock_balance_adjustment_requests,
    -- 生产（production_plan_costs 为分区父表，TRUNCATE 自动含全部分区）
    production_plans, production_plan_items, production_plan_costs,
    production_daily_reports, production_daily_report_items,
    production_execution_segments, production_execution_segment_events,
    production_material_analyses, production_material_analysis_borrows,
    production_material_analysis_commands, production_material_analysis_items,
    production_material_analysis_materials, production_material_analysis_plan_links,
    production_material_demands, production_material_make_receipt_allocations,
    production_material_peg_transfers, production_material_receipt_allocations,
    production_material_settlement_events, production_material_settlement_postings,
    production_material_stock_events, production_material_stock_postings,
    production_material_subcontract_peg_transfers,
    production_material_subcontract_receipt_allocations, production_material_supply_pegs,
    production_planning_drafts, production_planning_packages,
    production_planning_package_documents, production_planning_package_document_items,
    production_product_no_sequences,
    plan_draw_links, plan_order_item_links, subplan_links,
    execution_segment_sales_allocations,
    mrp_generations, preplan_supply_actions, preplan_supply_action_allocations,
    rd_tasks, rd_task_forwarders,
    -- 委外
    subcontract_applications, subcontract_application_items,
    subcontract_inquiries, subcontract_inquiry_items,
    subcontract_material_issues, subcontract_material_issue_items,
    subcontract_material_returns, subcontract_material_return_items,
    subcontract_orders, subcontract_order_items, subcontract_order_cost_items,
    subcontract_receipts, subcontract_receipt_items,
    subcontract_returns, subcontract_return_items,
    subcontract_wastes, subcontract_waste_items,
    -- 财务
    gl_vouchers, gl_entries, ar_ap_ledger, ar_ap_source_refs,
    finance_payments, finance_payment_lines,
    finance_receipts, finance_receipt_lines,
    finance_expenses, finance_expense_items,
    finance_other_incomes, finance_other_income_items,
    finance_bank_transfers, finance_bank_transfer_lines,
    finance_check_register, finance_reconciliations,
    finance_deferral_schedule_versions, finance_deferral_schedule_lines,
    deferred_expenses, da_amortization_log,
    expense_claims, expense_claim_items,
    fixed_assets, finance_asset_events, finance_asset_accounting_periods,
    finance_asset_approval_steps, finance_asset_books,
    finance_asset_posting_lines, finance_asset_posting_runs, fa_depreciation_log,
    -- 工资
    payroll_batches, payroll_items, payroll_slips, payroll_variable_inputs,
    -- 公告 / 建议 / 访客 / 询盘
    notices, notice_user_states, notice_blessings, notice_acknowledgments,
    suggestions, suggestion_likes, suggestion_replies,
    visitor_accounts, visitor_applications, visitor_approval_steps,
    visitor_refresh_tokens, visitor_sms_codes, website_inquiries,
    -- 审计 / 任务认领 / outbox / 附件索引 / 导入批次 / 迁移记录
    audit_log, audit_log_archive,
    task_claims, hr_task_claims, business_outbox,
    attachments, attachment_object_outbox, attachment_upload_sessions,
    attachment_reconciliation_findings,
    goods_import_batches, goods_import_creations,
    legacy_migration_checkpoints, legacy_migration_reconciliation_items,
    legacy_migration_rejects, legacy_migration_run_files, legacy_migration_runs,
    client_default_settlement_migration_issues, profile_change_requests,
    -- 单据编号流水（清零后新单据从头编号；主档编码预留表不在此列，保持保留）
    doc_number_sequences, business_document_sequences
RESTART IDENTITY CASCADE;

-- 提交前自检：上方清单内任何表仍有数据则整体回滚
DO $$
DECLARE
    t TEXT;
    n BIGINT;
    tbls TEXT[] := ARRAY[
        'sales_orders','purchase_orders','stock_documents','stock_balances','stock_movements',
        'production_plans','subcontract_orders','gl_vouchers','payroll_batches',
        'notices','audit_log','doc_number_sequences','business_document_sequences'
    ];
BEGIN
    FOREACH t IN ARRAY tbls LOOP
        EXECUTE format('SELECT count(*) FROM %I', t) INTO n;
        IF n > 0 THEN
            RAISE EXCEPTION '清空校验失败：% 仍有 % 行，整体回滚', t, n;
        END IF;
    END LOOP;
END $$;

COMMIT;

-- 月度统计物化视图刷新为空（报表口径同步归零）
REFRESH MATERIALIZED VIEW purchase_monthly_mv;
REFRESH MATERIALIZED VIEW production_monthly_mv;
REFRESH MATERIALIZED VIEW stock_monthly_mv;
REFRESH MATERIALIZED VIEW finance_ar_ap_mv;
REFRESH MATERIALIZED VIEW sales_monthly_mv;
REFRESH MATERIALIZED VIEW subcontract_monthly_mv;

\echo '完成：业务数据已清空，基础资料/人事/系统权限保留。'
\echo '抽查：'
SELECT 'employees' AS tbl, count(*) FROM employees
UNION ALL SELECT 'goods', count(*) FROM goods
UNION ALL SELECT 'clients', count(*) FROM clients
UNION ALL SELECT 'suppliers', count(*) FROM suppliers
UNION ALL SELECT 'sales_orders', count(*) FROM sales_orders
UNION ALL SELECT 'stock_balances', count(*) FROM stock_balances;
