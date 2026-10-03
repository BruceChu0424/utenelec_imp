-- 单设备登录（2026-10-03 实装）：同一账号新处登录即顶号，撤销原因登记为
-- replaced_by_new_login。V680 的 revoked_reason 白名单 CHECK 不含该值，此处
-- 原样重建约束放行；既有数据不受影响（只是放开新写入值）。
ALTER TABLE auth_sessions DROP CONSTRAINT ck_auth_sessions_revoked_reason;
ALTER TABLE auth_sessions ADD CONSTRAINT ck_auth_sessions_revoked_reason CHECK (
    revoked_reason IS NULL OR revoked_reason = ANY (ARRAY[
        'logout', 'idle_timeout', 'password_changed', 'account_status_changed',
        'password_reset', 'remote_access_changed', 'refresh_reuse', 'step_up_locked',
        'login_account_changed', 'replaced_by_new_login']));
