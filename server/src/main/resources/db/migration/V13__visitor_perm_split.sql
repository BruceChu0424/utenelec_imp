-- C2 修复：拆分 visitor:approve（HR/admin 专属）与 visitor:host-confirm（被访人员工）。
-- 原设计把两者混用 visitor:approve，导致全体员工都有 HR 审批权。

-- 1) 新增 visitor:host-confirm 权限点
INSERT INTO permissions (code, name, category)
VALUES ('visitor:host-confirm', '被访人确认访客', 'visitor')
ON CONFLICT (code) DO NOTHING;

-- 2) employee 角色：移除 visitor:approve（仅 HR/admin 保留），加 visitor:host-confirm
DELETE FROM role_permissions
WHERE role_id = (SELECT id FROM roles WHERE code='employee')
  AND permission_id = (SELECT id FROM permissions WHERE code='visitor:approve');

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='employee' AND p.code='visitor:host-confirm'
ON CONFLICT DO NOTHING;
