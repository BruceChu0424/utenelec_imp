-- =====================================================================
-- V29：角色体系下线——存量角色权限沉淀为部门配置
-- =====================================================================
-- 背景（ADR-011 演进）：权限模型收敛为两层——部门配置 + 个人覆盖，
-- 角色分配 UI 移除。PermissionResolver 不再读取 user_roles / department_roles
-- 参与合成，仅保留 employee 角色作为"全员基础权限包"（人人隐式持有）。
--
-- 本迁移保证老用户权限不丢失：
--   把每个普通用户当前通过【非 employee 角色】获得的、且不属于全员基础包的权限，
--   按其直属部门沉淀为 department_permissions（多用户同部门取并集）。
--   超管跳过（本来就全量）。
--
-- 注意：
--   * user_roles / department_roles / role_permissions 数据保留不删
--     （JWT roles claim、DataAccessPolicy 脱敏仍读这些表）；
--   * 部门配置对下级部门生效（Resolver 递归向上取并集），沉淀在直属部门即可。
-- =====================================================================

INSERT INTO department_permissions (department_id, permission_id)
SELECT DISTINCT e.department_id, rp.permission_id
FROM users u
JOIN employees e ON e.id = u.employee_id
JOIN user_roles ur ON ur.user_id = u.id
JOIN role_permissions rp ON rp.role_id = ur.role_id
JOIN roles r ON r.id = ur.role_id AND r.code <> 'employee'
WHERE u.is_super_admin = FALSE
  AND e.department_id IS NOT NULL
  AND rp.permission_id NOT IN (
      SELECT rp2.permission_id
      FROM role_permissions rp2
      JOIN roles r2 ON r2.id = rp2.role_id
      WHERE r2.code = 'employee'
  )
ON CONFLICT DO NOTHING;
