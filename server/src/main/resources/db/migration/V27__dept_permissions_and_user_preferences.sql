-- =====================================================================
-- V27：部门直配权限点 + 用户偏好 + 权限目录排序
-- =====================================================================
-- 设计要点：
--   * department_permissions: 部门直接挂权限点（不经过角色），部门直属员工
--     在 PermissionResolver 合成时与角色权限取并集（仅直属部门，不含子部门）。
--     不插任何种子数据——所有部门初始空白，由超管在管理端按需配置。
--   * user_preferences: 每用户键值偏好（主题/布局/看板配置等），value 为 JSONB。
--   * permissions.sort_order: 权限目录展示排序（组内 sort_order + code 升序）。
--   * 不种子化新权限点：采购/客户/供应商/账户/基础资料等模块尚未实现，
--     按"权限目录只列已实现功能"的原则，待模块落地时再随迁移登记权限点。
-- =====================================================================

-- a) 部门直配权限点（审计列风格参照 V11 的 roles/permissions 审计列）
CREATE TABLE department_permissions (
    department_id UUID NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
    permission_id UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    PRIMARY KEY (department_id, permission_id)
);
CREATE INDEX idx_department_permissions_perm ON department_permissions(permission_id);
COMMENT ON TABLE  department_permissions IS '部门直配权限点：部门直属员工自动获得这些权限（仅直属，不向下继承）';
COMMENT ON COLUMN department_permissions.department_id IS '部门（仅直属，不向下继承）';
COMMENT ON COLUMN department_permissions.permission_id IS '直接授予的权限点';
COMMENT ON COLUMN department_permissions.created_by    IS '配置人（users.id）';

-- b) 用户偏好（每用户键值 JSON，upsert 语义）
CREATE TABLE user_preferences (
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pref_key   VARCHAR(100) NOT NULL,
    pref_value JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, pref_key)
);
COMMENT ON TABLE  user_preferences IS '用户偏好（键值 JSON，如主题/布局/看板配置）';
COMMENT ON COLUMN user_preferences.pref_key   IS '偏好键（≤100 字符，应用层校验）';
COMMENT ON COLUMN user_preferences.pref_value IS '偏好值（任意 JSON，应用层限制 ≤16KB）';

-- c) 权限目录展示排序
ALTER TABLE permissions ADD COLUMN IF NOT EXISTS sort_order INT NOT NULL DEFAULT 0;
COMMENT ON COLUMN permissions.sort_order IS '权限目录组内展示排序（升序，同值按 code）';
