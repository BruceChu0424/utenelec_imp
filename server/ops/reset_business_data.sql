-- =====================================================================
-- 本地/测试库业务数据一键清空（V328；保留主档、人事、权限与治理证据）
-- =====================================================================
-- 用途：把数据库重置为“基础资料和系统治理数据保留、业务流程与库存归零”的
--       干净测试起点。只允许在可丢弃的本地/测试库停写后运行。
--
-- 唯一范围事实：
--   · CLEAR 148 张：销售、采购、库存、生产、委外、财务、工资、通知、访客、
--     建议、任务认领和业务 outbox。
--   · PRESERVE 87 张：主档、人事、账号/权限、系统配置、Flyway、审计日志、
--     人事附件、导入/迁移证据、编号终身占用和单调流水。
--   · 34 张分区子表不单列；随已分类的分区父表一同处理。
--
-- 安全边界：
--   · confirm、数据库名、PostgreSQL system_identifier 三重带外确认。
--   · 必须先停止应用、定时任务和 outbox worker；存在其它客户端连接即拒绝。
--   · outbox 有待处理/失败事件，或存在非人事附件 owner 时拒绝执行。
--   · 当前 public 非分区普通表/分区父表必须恰好分类一次；未知表失败关闭。
--   · 不使用级联扩大范围；新增未分类 FK 表会让执行失败，而不是被静默删除。
--   · 单事务完成清空、六张物化视图刷新、CLEAR 逐表为零和 PRESERVE
--     逐表计数不变校验；任一失败全部回滚。
--
-- 先备份（示例；不要覆盖既有备份）：
--   $resetStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
--   $backupName = "uten_imp_pre_reset_v328_$resetStamp.dump"
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
('ar_ap_ledger', 'CLEAR'),
('ar_ap_source_refs', 'CLEAR'),
('business_outbox', 'CLEAR'),
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
('production_daily_report_items', 'CLEAR'),
('production_daily_reports', 'CLEAR'),
('production_execution_segment_events', 'CLEAR'),
('production_execution_segments', 'CLEAR'),
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
('supplier_return_tasks', 'CLEAR'),
('task_claims', 'CLEAR'),
('visitor_accounts', 'CLEAR'),
('visitor_applications', 'CLEAR'),
('visitor_approval_steps', 'CLEAR'),
('visitor_refresh_tokens', 'CLEAR'),
('visitor_sms_codes', 'CLEAR'),
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
('client_categories', 'PRESERVE'),
('client_default_settlement_migration_issues', 'PRESERVE'),
('client_ship_addresses', 'PRESERVE'),
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
('employee_education', 'PRESERVE'),
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
('spatial_ref_sys', 'PRESERVE'),
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

DO $$
DECLARE
    duplicate_tables TEXT;
    unknown_tables TEXT;
    invalid_policy_tables TEXT;
    clear_count BIGINT;
    preserve_count BIGINT;
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

    IF clear_count <> 148 OR preserve_count <> 87 THEN
        RAISE EXCEPTION
            'V328 白名单数量异常：CLEAR %（应为148），PRESERVE %（应为87）',
            clear_count, preserve_count;
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

\echo '完成：业务流程与库存已清空；主档、人事、权限、审计、附件及治理证据保留。'
\echo '抽查：'
SELECT 'employees' AS table_name, count(*) AS row_count FROM employees
UNION ALL SELECT 'goods', count(*) FROM goods
UNION ALL SELECT 'clients', count(*) FROM clients
UNION ALL SELECT 'suppliers', count(*) FROM suppliers
UNION ALL SELECT 'users', count(*) FROM users
UNION ALL SELECT 'audit_log', count(*) FROM audit_log
UNION ALL SELECT 'sales_orders', count(*) FROM sales_orders
UNION ALL SELECT 'stock_balances', count(*) FROM stock_balances;
