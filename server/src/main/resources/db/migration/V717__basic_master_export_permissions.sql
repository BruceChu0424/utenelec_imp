-- =====================================================================
-- V717：基础资料五个主档补齐导出权限（模具/颜色/单位/结算方式/仓库）
-- =====================================================================
-- 背景（2026-09-25 用户口径「基础资料里其他资料的导出打印都要对应优化」）：
--   货品/客户/供应商/币种/账户五个主档已有加密导出（V71 口径：导出独立权限点，
--   「能看」≠「能导出」），模具/颜色/单位/结算方式/仓库五个主档此前完全没有
--   Excel 导出，也没有打印入口。本迁移登记五个 :export 权限点并按 V71 同款
--   「导出跟随查看」回填（持有对应 :view 的部门自动获得 :export），避免现有
--   用户断权；超管恒有全部权限不受影响。
-- 注意：权限在 JWT claim，上线后用户须重登，新 token 才带 :export。
-- 幂等：ON CONFLICT，重跑安全。
-- =====================================================================

-- ① 五个导出权限点（module/category 跟随各自 :view 在 V228/V453 的归类；
--    列形跟 V714：V677 已删 active/assignable/bulk_assignable 换 grant_policy）。
INSERT INTO permissions (code, name, module, category, sort_order, action_type, description,
                         grant_policy)
VALUES
    ('mould:export', '导出模具', '基础资料', '模具', 45,
     'EXPORT', '加密导出模具主档清单（列集与模具资料表格一致）',
     ARRAY['NORMAL']::text[]),
    ('color:export', '导出颜色', '基础资料', '颜色', 62,
     'EXPORT', '加密导出颜色字典清单（列集与颜色资料表格一致）',
     ARRAY['NORMAL']::text[]),
    ('unit:export', '导出单位', '基础资料', '单位', 72,
     'EXPORT', '加密导出计量单位清单（列集与单位资料表格一致）',
     ARRAY['NORMAL']::text[]),
    ('settlement_method:export', '导出结算方式', '基础资料', '收付款类别', 119,
     'EXPORT', '加密导出结算方式与账期策略清单（列集与结算方式表格一致）',
     ARRAY['NORMAL']::text[]),
    ('warehouse:export', '导出仓库', '基础资料', '仓库', 102,
     'EXPORT', '加密导出仓库主档清单（列集与仓库资料表格一致）',
     ARRAY['NORMAL']::text[])
ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name, module = EXCLUDED.module, category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order, action_type = EXCLUDED.action_type,
    description = EXCLUDED.description, grant_policy = EXCLUDED.grant_policy;

-- ② 权限面登记（basic.* 面；V328 之后新增码须显式挂面，前缀规则只在 V328 一次性展开）。
WITH mapping(surface_key, permission_code) AS (VALUES
    ('basic.mould', 'mould:export'),
    ('basic.color', 'color:export'),
    ('basic.unit', 'unit:export'),
    ('basic.settlement-method', 'settlement_method:export'),
    ('basic.warehouse', 'warehouse:export')
)
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN mapping m ON surface.surface_key = m.surface_key
JOIN permissions permission ON permission.code = m.permission_code
WHERE surface.enabled
ON CONFLICT DO NOTHING;

-- ③ 回填：导出跟随查看（V71 同款——持有对应 :view 的部门自动获得 :export）。
INSERT INTO department_permissions (department_id, permission_id)
SELECT dp.department_id, p_export.id
FROM department_permissions dp
JOIN permissions p_view ON p_view.id = dp.permission_id
JOIN permissions p_export ON p_export.code = REPLACE(p_view.code, ':view', ':export')
WHERE p_view.code IN ('mould:view', 'color:view', 'unit:view',
                      'settlement_method:view', 'warehouse:view')
  AND p_export.code IN ('mould:export', 'color:export', 'unit:export',
                        'settlement_method:export', 'warehouse:export')
ON CONFLICT DO NOTHING;
