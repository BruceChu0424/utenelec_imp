-- =====================================================================
-- 管理端权限分配增强：部门默认角色 + 个人权限点覆盖
-- =====================================================================
-- 设计要点：
--   * department_roles: 部门直属员工自动获得这些角色的权限（不含子部门），
--     在 AuthService.permsOf 合成权限时与 user_roles 的直接角色取并集
--   * user_permission_overrides: 个人权限点覆盖，作用于角色合成结果之上
--       effect = 'grant'  → 在角色权限之外加授
--       effect = 'revoke' → 从角色权限中回收
--   * 两张表均为纯关联表，级联跟随主表删除
-- =====================================================================

-- 部门默认角色：部门直属员工自动获得这些角色的权限（不含子部门）
CREATE TABLE department_roles (
    department_id UUID NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
    role_id       UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    PRIMARY KEY (department_id, role_id)
);
CREATE INDEX idx_department_roles_role ON department_roles(role_id);
COMMENT ON TABLE  department_roles IS '部门默认角色：部门直属员工自动获得这些角色的权限（不含子部门）';
COMMENT ON COLUMN department_roles.department_id IS '部门（仅直属，不向下继承）';
COMMENT ON COLUMN department_roles.role_id       IS '默认授予的角色';

-- 个人权限点覆盖：grant=角色之外加授，revoke=从角色权限中回收
CREATE TABLE user_permission_overrides (
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    permission_id UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    effect        TEXT NOT NULL CHECK (effect IN ('grant','revoke')),
    PRIMARY KEY (user_id, permission_id)
);
CREATE INDEX idx_user_permission_overrides_perm ON user_permission_overrides(permission_id);
COMMENT ON TABLE  user_permission_overrides IS '个人权限点覆盖（grant=角色之外加授，revoke=从角色权限中回收）';
COMMENT ON COLUMN user_permission_overrides.effect IS '覆盖方向：grant 加授 / revoke 回收';
