-- 外网登录简化 (2026-10-29): 取消 TOTP 动态验证码、外网总开关与人数上限。
-- 员工外网访问的唯一闸门是 users.remote_access (权限设置 → 按员工 → 云端(外网)访问授权)，
-- 授权用户在外网直接用账号密码登录；未授权账号由服务端拒绝，客户端按网络不可达展示。
-- staff_mfa 的 TOTP 密文与 remote_access_policy 单例随之退役；历史审计行保留原始事实。
ALTER TABLE auth_sessions DROP CONSTRAINT IF EXISTS ck_auth_sessions_staff_mfa;
ALTER TABLE auth_sessions DROP COLUMN IF EXISTS mfa_verified_at;
DROP TABLE IF EXISTS staff_mfa;
DROP TABLE IF EXISTS remote_access_policy;
