-- =====================================================================
-- 人事数据清理：只保留 admin（员工 code='ADMIN' 及其登录账号）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --hr-cleanup --confirm-destructive
-- 范围：
--   · 删除所有 code<>'ADMIN' 的员工（级联 users/employee_sensitive/employment_history/
--     emergency_contacts/employee_contracts/employee_education/employee_credentials/
--     employee_compensation/user_data_scopes/profile_change_requests(employee_id)）。
--   · 删除老库试迁遗留的 LEG-P-* 岗位（stubs 已随员工删除，此处清岗位主档）。
--   · departments.headcount 冗余清零（正式名录导入时重算）。
-- 保留：
--   · ADMIN 员工 + 其 users 登录账号 + 角色权限（roles/permissions 属系统种子，不动）。
--   · V24/V206 岗位模板种子、组织架构 departments（名录迁移只做改名，不删部门）。
-- 安全：
--   · 业务表（单据/模具/工资/报销等）若仍引用被删员工，外键 RESTRICT/NO ACTION
--     会让整个事务回滚——清理失败而不是静默丢引用。
-- =====================================================================

BEGIN;

-- 工资条引用员工（RESTRICT）：先删非 admin 员工的工资条，并按剩余工资条重算批次合计。
-- （当前仅 2026-08 测试批次，ADMIN 全流程经手；若将来有正式工资数据，请先人工评估再清理。）
DELETE FROM payroll_slips
WHERE employee_id IN (SELECT id FROM employees WHERE code <> 'ADMIN');

UPDATE payroll_batches b
SET headcount       = sub.cnt,
    gross_income    = sub.gross,
    total_deduction = sub.ded,
    net_income      = sub.gross - sub.ded
FROM (SELECT batch_id,
             count(*)                         AS cnt,
             COALESCE(sum(gross_income), 0)   AS gross,
             COALESCE(sum(total_deduction), 0) AS ded
      FROM payroll_slips
      GROUP BY batch_id) sub
WHERE b.id = sub.batch_id;

DELETE FROM employees WHERE code <> 'ADMIN';

DELETE FROM positions WHERE code LIKE 'LEG-P-%';

UPDATE departments SET headcount = 0;

COMMIT;

-- ---------------- 校验 ----------------
SELECT '✔ 剩余员工（应只有 ADMIN）: ' || string_agg(code || '(' || full_name || ')', ', ') AS r
FROM employees WHERE is_deleted = false
UNION ALL SELECT '剩余登录账号: ' || COALESCE(string_agg(login_account, ', '), '(无)') FROM users WHERE is_deleted = false
UNION ALL SELECT 'LEG-P 岗位剩余（应 0）: ' || count(*) FROM positions WHERE code LIKE 'LEG-P-%'
UNION ALL SELECT '任职轨迹剩余: ' || count(*) FROM employment_history
UNION ALL SELECT '敏感信息剩余: ' || count(*) FROM employee_sensitive;
