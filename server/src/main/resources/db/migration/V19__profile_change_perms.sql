-- =====================================================================
-- 新增 3 个权限点 + 给 employee/hr/admin 角色赋权
-- =====================================================================
-- profile:edit:self               员工提交个人信息修改
-- profile:review                  HR/admin 审核员工个人信息修改申请
-- employee:compensation:view      HR/finance/admin 查看员工薪资字段
-- =====================================================================

INSERT INTO permissions (code, name, category) VALUES
    ('profile:edit:self',          '提交个人信息修改',       'profile'),
    ('profile:review',             '审核个人信息修改申请',   'profile'),
    ('employee:compensation:view', '查看员工薪资字段',       'employee')
ON CONFLICT (code) DO NOTHING;

-- employee 角色 → profile:edit:self
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r, permissions p
WHERE r.code = 'employee' AND p.code = 'profile:edit:self'
ON CONFLICT DO NOTHING;

-- hr 角色 → profile:review + employee:compensation:view
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r, permissions p
WHERE r.code = 'hr'
  AND p.code IN ('profile:review', 'employee:compensation:view')
ON CONFLICT DO NOTHING;

-- finance 角色 → employee:compensation:view
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r, permissions p
WHERE r.code = 'finance' AND p.code = 'employee:compensation:view'
ON CONFLICT DO NOTHING;

-- admin 角色 → 全 3 个
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r, permissions p
WHERE r.code = 'admin'
  AND p.code IN ('profile:review', 'profile:edit:self', 'employee:compensation:view')
ON CONFLICT DO NOTHING;