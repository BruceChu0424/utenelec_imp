BEGIN TRANSACTION READ ONLY;
SELECT login_account,is_super_admin,status FROM users
WHERE login_account IN ('SU-old-v1-previews','other-import-auditor') ORDER BY login_account;
SELECT u.login_account,array_agg(p.code ORDER BY p.code) AS financial_rights
FROM users u JOIN user_permission_overrides o ON o.user_id=u.id AND o.effect='grant'
JOIN permissions p ON p.id=o.permission_id
WHERE u.login_account IN ('SU-old-v1-previews','other-import-auditor')
  AND p.code IN ('finance_report:view','finance:view:all','finance_post:execute','payment_style:edit')
GROUP BY u.login_account ORDER BY u.login_account;
SELECT 'cost' AS family,id,preview->>'columnContractVersion' AS server_version,
       jsonb_array_length(preview->'blocks'->0->'rows') AS source_rows
FROM goods_cost_imports ORDER BY created_at,id;
SELECT id,parent_import_id,actor_id,preview->>'columnContractVersion' AS server_version,
       jsonb_array_length(preview->'issues') AS issues,applied_at IS NOT NULL AS applied
FROM finance_chart_imports ORDER BY created_at,id;
SELECT id,actor_id,period,preview->>'columnContractVersion' AS server_version,
       applied_at IS NOT NULL AS applied FROM finance_expense_note_imports ORDER BY created_at,id;
SELECT period,locked FROM finance_expense_analysis_periods ORDER BY period;
SELECT id,actor_id,kind,preview->>'columnContractVersion' AS server_version,
       jsonb_array_length(preview->'issues') AS issues,directory_applied_at IS NOT NULL AS applied
FROM finance_statement_source_reviews ORDER BY created_at,id;
SELECT id,actor_id,kind,status,preview->>'columnContractVersion' AS server_version,
       jsonb_array_length(preview->'issues') AS issues FROM finance_accounting_import_batches ORDER BY created_at,id;
SELECT code,name,source_import_id FROM finance_chart_codes ORDER BY code;
SELECT period,line_key,remark FROM finance_operating_report_notes ORDER BY period,line_key;
SELECT 'goods' AS table_name,count(*) FROM goods
UNION ALL SELECT 'goods_bom_items',count(*) FROM goods_bom_items
UNION ALL SELECT 'goods_cost_import_mappings',count(*) FROM goods_cost_import_mappings
UNION ALL SELECT 'finance_chart_codes',count(*) FROM finance_chart_codes
UNION ALL SELECT 'finance_operating_report_notes',count(*) FROM finance_operating_report_notes
UNION ALL SELECT 'finance_auxiliary_items',count(*) FROM finance_auxiliary_items
UNION ALL SELECT 'gl_entries',count(*) FROM gl_entries;
COMMIT;
