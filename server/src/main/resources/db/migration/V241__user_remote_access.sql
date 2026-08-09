-- V241：users.remote_access 列 + 扩展形状版本触发器。
--
-- 远程（云端/外网）访问授权标志。云端实例（uten.deployment.site=cloud）的门禁依据：
--   只有 remote_access=TRUE 的账号可在云端访问；变更即时 bump auth_version，旧 access token 失效
--   （JwtAuthFilter 逐请求复读 auth_version，不匹配即拒）。
-- 复用 V135 的 auth_version 失效机制，不自建吊销表。
-- 幂等：列 IF NOT EXISTS；函数 CREATE OR REPLACE；触发器 DROP IF EXISTS + 重建。

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS remote_access BOOLEAN NOT NULL DEFAULT FALSE;

-- 扩展 V135 的形状版本触发器函数：remote_access 变更时也 bump auth_version。
CREATE OR REPLACE FUNCTION fn_bump_user_auth_shape_version() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.is_super_admin IS DISTINCT FROM OLD.is_super_admin
       OR NEW.employee_id IS DISTINCT FROM OLD.employee_id
       OR NEW.remote_access IS DISTINCT FROM OLD.remote_access THEN
        NEW.auth_version := OLD.auth_version + 1;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 触发器列清单加入 remote_access（PostgreSQL「BEFORE UPDATE OF <cols>」加列须重建触发器）。
DROP TRIGGER IF EXISTS trg_user_auth_shape_version ON users;
CREATE TRIGGER trg_user_auth_shape_version
BEFORE UPDATE OF is_super_admin, employee_id, remote_access ON users
FOR EACH ROW EXECUTE FUNCTION fn_bump_user_auth_shape_version();

COMMENT ON COLUMN users.remote_access IS
    '是否允许云端(外网)访问；云端实例(uten.deployment.site=cloud)门禁依据，变更即时 bump auth_version 失效旧 token';
