-- 给 users 加 super-admin 标记。
-- 当 is_super_admin=true 时：
--   - AuthService.permsOf() 直接读全部 permissions（绕过 role 映射）
--   - 前端拿到 isSuperAdmin=true，UI 上隐藏"岗位/职务"这类不适用字段
-- "不设置职务"语义：超管不被 role_permissions 是否齐全所限制，也不依赖具体 position / department 的业务角色。
ALTER TABLE users ADD COLUMN is_super_admin BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX idx_users_super_admin ON users(is_super_admin) WHERE is_super_admin = TRUE;

-- 兼容历史数据：之前 BootstrapRunner 创建的 admin 账号置为 true。
-- 工号 ADMIN 的员工对应的账号即超管（login_account='admin'，由 .env 的 BOOTSTRAP_ADMIN_LOGIN 控制）。
UPDATE users
SET is_super_admin = TRUE
WHERE login_account = 'admin';

-- 给 admin 的 employee 档案再写一次注释（V08 已存在 super admin 行；此 UPDATE 仅清理一份兜底说明）
COMMENT ON COLUMN users.is_super_admin IS 'TRUE = 该账号是超级管理员，绕过角色-权限映射拥有全量权限，且不绑定具体职务语义';
