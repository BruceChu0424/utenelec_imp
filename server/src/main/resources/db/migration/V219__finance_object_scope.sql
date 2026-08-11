-- =====================================================================
-- V219：财务单据对象级数据范围（SEC-MED-4）
-- =====================================================================
-- 背景：features/finance 的 5 个单据（payment/receipt/expense/bank_transfer/
--   other_income）此前仅特性级 RBAC（finance_*:view/edit），无对象级范围过滤。
--   仅持 finance_*:view 而无 finance:view:all、且非制单人/未被数据范围授权者，
--   可读/动他人单据（含银行账户 PII）——「过度授权即 IDOR」。
--
-- 设计（镜像 V85/V86/V91 的 goods/client/sales 归属隔离 + 数据范围三档模型）：
--   * 归属列 = maker_employee_id（finance_*.maker_id，创建即落当前员工，恒非空）；
--   * 三档可见：本人 ∪ user_data_scopes 授权归属人 / finance:view:all 全部 / 超管全见；
--   * user_data_scopes.scope 放开 'finance'（与 goods/client/sales 并列第四个范围）；
--   * 新权限点 finance:view:all「查看全部财务单据」；
--   * 给 GM（管理只读）+ DEPT_FIN（财务全权）授予 finance:view:all —— 否则对象过滤
--     会让财务/管理看不到他人单据即回归。授权矩阵下（V212：仅 GM/DEPT_FIN 有财务
--     单据权限）本变更对既有用户零影响，纯纵深防御。
--
-- 运行时授权矩阵评估（SEC-MED-4）：
--   V212 下仅 GM（finance_*:view 只读）与 DEPT_FIN（finance_*:view+edit 全权）有财务
--   单据访问权，其余部门无任何 finance_* 权限。两者均获 finance:view:all → seeAll，
--   对象过滤对其无影响；过滤仅对「被额外点名授予 finance_*:view/edit 但未授
--   finance:view:all」的个别人起作用（防越权读他人银行账户 PII）。预期授权下不可利用。
--
-- 实现侧：FinanceDocumentAccessPolicy（server/security）+ 5 个 Service 的
--   list/detail/approve/reverse/update/delete。读失败一律 NOT_FOUND（不泄漏存在性）。
--   maker≠approver / M28 行锁等既有守卫不受影响。
-- =====================================================================

-- ① user_data_scopes.scope 放开 'finance'
ALTER TABLE user_data_scopes DROP CONSTRAINT IF EXISTS user_data_scopes_scope_check;
ALTER TABLE user_data_scopes ADD CONSTRAINT user_data_scopes_scope_check
    CHECK (scope IN ('goods', 'client', 'sales', 'finance'));

-- ② 新权限点 finance:view:all（钱流管理段 500–579）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('finance:view:all', '查看全部财务单据', '钱流管理', 555)
ON CONFLICT (code) DO NOTHING;

-- ③ 授予 GM（管理只读）+ DEPT_FIN（财务全权）—— 防回归（对象过滤下二者仍全可见）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'finance:view:all'
WHERE d.code IN ('GM', 'DEPT_FIN') AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ④ 归属列部分索引（list 的 maker_id IN (...) 谓词；finance_* 表均已有 maker_id 列）
CREATE INDEX IF NOT EXISTS idx_frt_maker ON finance_receipts(maker_id)       WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fpm_maker ON finance_payments(maker_id)       WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fex_maker ON finance_expenses(maker_id)       WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_foi_maker ON finance_other_incomes(maker_id)  WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fbt_maker ON finance_bank_transfers(maker_id) WHERE maker_id IS NOT NULL;
