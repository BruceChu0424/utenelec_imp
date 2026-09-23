-- =====================================================================
-- 遗留导入的审计汇总(ADR-105): 每次运行只写这一条。
-- =====================================================================
-- 导入会话设置了 app.legacy_import='on', 数据库行级审计整体旁路, 约 250 万行历史数据
-- 不再逐行复制成整行快照; 导入正确性由 migrate_reconciliation.sql、reconcile_modules.py
-- 与 verify_candidate.py 的对账负责。审计里只留「哪次运行、结果如何、导入后各表多少行」。
-- 结果取运行的最终状态(SUCCESS 记成功, 其余记失败), 所以必须在状态定下来之后执行:
-- 全量导入在同一事务里标成功之后写; 单模块导入与失败的运行由 finish_run 在收尾时写。
-- 每个运行号只写一条(重复调用跳过)。调用方负责 BEGIN/COMMIT, 并提供 psql 变量 run_id。
-- =====================================================================
INSERT INTO audit_log (
    actor_account, action, target_type, target_id, "after", result,
    event_source, risk_level, event_category, device_capture_status)
SELECT 'ops:legacy_migration', 'legacy_migration_run', 'legacy_migration_run', run.run_id::text,
       jsonb_build_object(
           'target', run.target,
           'mode', run.migration_mode,
           'status', run.status,
           'exit_code', run.exit_code,
           'reconciliation_status', run.reconciliation_status,
           'mapping_version', run.mapping_version,
           'repository_commit', run.migration_repository_commit,
           'table_rows', (
               SELECT jsonb_object_agg(counted.table_name, counted.row_count ORDER BY counted.table_name)
               FROM (
                   SELECT listed.table_name,
                          (xpath('/row/c/text()',
                                 query_to_xml(format('SELECT count(*) AS c FROM public.%I', listed.table_name),
                                              false, true, '')))[1]::text::bigint AS row_count
                   FROM unnest(ARRAY[
                       'material_categories', 'mould_categories', 'client_categories', 'supplier_categories',
                       'colors', 'units', 'currencies', 'warehouses', 'moulds', 'clients', 'suppliers',
                       'goods', 'goods_bom_items', 'purchase_orders', 'purchase_order_items',
                       'purchase_receipts', 'purchase_receipt_items', 'stock_documents', 'stock_document_items',
                       'sales_orders', 'sales_order_items', 'sales_shipments', 'sales_shipment_items',
                       'subcontract_orders', 'subcontract_order_items', 'production_plans',
                       'production_plan_items', 'production_plan_costs', 'finance_receipts',
                       'finance_payments', 'ar_ap_ledger', 'employees']) AS listed(table_name)
                   WHERE to_regclass('public.' || listed.table_name) IS NOT NULL
               ) counted)),
       CASE WHEN run.status = 'SUCCESS' THEN 'success' ELSE 'failure' END,
       'system', 'high', 'system', 'missing'
FROM legacy_migration_runs run
WHERE run.run_id = :'run_id'::uuid
  AND run.status <> 'RUNNING'
  AND NOT EXISTS (
      SELECT 1 FROM audit_log recorded
      WHERE recorded.target_type = 'legacy_migration_run'
        AND recorded.target_id = run.run_id::text
        AND recorded.action = 'legacy_migration_run');
