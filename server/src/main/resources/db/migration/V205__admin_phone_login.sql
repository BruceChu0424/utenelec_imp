-- V205 管理员登录账号改为手机号（不再用 "admin" 用户名登录）
--
-- 既有库的引导超管 login_account='admin' → '17665410007'（管理员手机号）。
-- Flyway 在 ApplicationRunner(BootstrapRunner) 之前执行，故 BootstrapRunner 启动时
-- existsByLoginAccount('17665410007')=true 即跳过，不会因 users.employee_id 唯一冲突而重复建号。
-- 幂等：仅更新仍为 'admin' 的行，重复执行无副作用；超管身份/密码/首登强制改不变。
UPDATE users SET login_account = '17665410007'
WHERE login_account = 'admin' AND is_deleted = false;
