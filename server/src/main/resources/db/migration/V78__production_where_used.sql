-- 物料反查产成品报表（BOM where-used）权限点。
-- 仿 V55 production_report:view 范式：permissions seed + 给所有部门 view 授权。
-- 数据源 production_plan_costs（V55 已迁 136 万行，无需补数）；端点 GET /api/production/reports/where-used。
-- 语义：仅含历史上被排产展开过的自制产成品（未投产新品 / 委外路径不覆盖）。

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('production_where_used:view', '查看物料反查产成品', '生产报表', 451)
ON CONFLICT (code) DO NOTHING;

-- 所有部门默认可查看（与 production_report:view 同策略）。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE p.code = 'production_where_used:view'
  AND d.is_deleted = false
ON CONFLICT DO NOTHING;
