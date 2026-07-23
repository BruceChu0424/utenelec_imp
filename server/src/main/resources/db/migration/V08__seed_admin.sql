-- 引导超管【员工档案】记录。
-- admin 的【登录账号 users 行】由后端 ApplicationRunner（BootstrapRunner）在首次启动时创建：
--   login_account='admin'，password_hash = Argon2id(.env 的 BOOTSTRAP_ADMIN_PASSWORD)，
--   must_change_password=true，user_roles→admin。
-- 这样避免在 SQL 里写死密码哈希。admin 员工挂在「行政与人力资源部」（账号归 HR 管）。

INSERT INTO employees (code, full_name, gender, id_type, hire_date, status, employment_type, department_id, email)
SELECT 'ADMIN', '系统管理员', 'male', '其他', DATE '2026-01-01', 'active', 'regular', p.id, 'admin@uten.local'
FROM departments p WHERE p.code='DEPT_HR';
