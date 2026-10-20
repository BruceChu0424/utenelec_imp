-- Exporting relationship evidence is independent of reading it or editing a BOM.
INSERT INTO permissions (code,name,module,category,sort_order,action_type,description,grant_policy,high_risk)
VALUES ('production_where_used:export','导出物料反查与追溯','生产管理','物料反查',452,'EXPORT',
        '导出有权查看的物料反查关系筛选结果，包含筛选条件、操作员、时间与证据来源；不授予组装编辑权限',
        ARRAY['NORMAL']::text[],false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
WHERE s.surface_key='production.where-used' AND p.code='production_where_used:export'
ON CONFLICT DO NOTHING;
