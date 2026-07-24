-- V25：决策支持专属权限点 analytics:view
-- 背景：/analytics/* 此前挂在 viewcontext:scoped（管理视角切换）上，
-- hr/finance/manager/admin 种子默认都有该点 → 决策支持对人事/财务也可见，
-- 且权限管理页里没有可识别的「决策支持」条目。
-- 定稿：决策支持独立权限点，默认仅 manager/admin；其他人由超管在权限管理页显式授予。
-- viewcontext:scoped 保持原语义（管理视角选择器），不受影响。

INSERT INTO permissions (code, name, category)
VALUES ('analytics:view', '决策支持', 'analytics')
ON CONFLICT (code) DO NOTHING;

-- 默认授予：管理层 + 管理员（幂等）
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code IN ('manager', 'admin') AND p.code = 'analytics:view'
ON CONFLICT DO NOTHING;
