-- =====================================================================
-- V70：钱流报表所需字段补列（钱流管理 / 钱流报表）
-- =====================================================================
-- 背景：V57 建表时 5 张钱流单据表的制单/审核/经手人只留 *_id UUID（迁移后全 NULL，
--   employees 与老库 Sys_Operator/B_Worker 无 legacy_id 对齐），报表里业务员/制单员/
--   审核员/经手人/收款人全部空白。现补 *_legacy_id INT（融合键）+ *_name TEXT（冻结名），
--   与 V65（采购）/V66（委外）/V67（仓库）/V68（销售）/V69（生产）完全同构——四模块里
--   钱流是唯一漏掉这波补列的，本迁移补齐。
--
-- ① 人员 *_legacy_id：
--   - maker_legacy_id / approver_legacy_id  ← 老库 MakeID/ApproverID（→ Sys_Operator.ID）
--     Sys_Operator 不入 employees（避免与 B_Worker 撞号 + 登录账号非员工档案实体），
--     其 fname 由 export 端 JOIN 冻结进 maker_name/approver_name 文本列（仿 V69 生产）。
--   - operator_legacy_id  ← 老库 WorkID（→ B_Worker.ID，经手人/收款人）。B_Worker 由
--     migrate_finance.sql 建 employees stub（legacy_id 融合键，status=resigned，
--     legacy_category=子类括注），报表 LEFT JOIN employees 出名 + 子类括注；HR 真名单不覆盖。
-- ② *_name 冻结列：maker_name/approver_name（Sys_Operator.fname）；operator_name（B_Worker.Emp_Name，
--   payments 已有 operator_name=jsr 文本，其余 4 表本次补）。报表用 COALESCE(em.full_name, t.*_name)。
-- ③ ar_ap_ledger.settlement_style_legacy：老库 M_in/M_out.PStyle（结帐方式原值，B_PStyle 字典
--   未 dump，前端按字典常量渲染或显示原值），供 A/C 应收应付明细「结帐方式」列。
--
-- 全部可空列，不影响现有 CRUD / 审核 / MV 刷新。employees.legacy_id（V65）+ legacy_category
-- （V67）已就位，本迁移不动 employees 结构。权限 finance_report:view 已在 V57:525 seed，
-- 物化视图 finance_ar_ap_mv 已在 V58 就位，本迁移不重复注册。
-- =====================================================================

-- ---------------- 销售收款 finance_receipts ----------------
ALTER TABLE finance_receipts
    ADD COLUMN IF NOT EXISTS maker_legacy_id     INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id  INT,
    ADD COLUMN IF NOT EXISTS operator_legacy_id  INT,   -- WorkID 经手人/收款人（B_Worker）
    ADD COLUMN IF NOT EXISTS maker_name          TEXT,  -- 冻结老库 Sys_Operator.fname
    ADD COLUMN IF NOT EXISTS approver_name       TEXT,
    ADD COLUMN IF NOT EXISTS operator_name       TEXT;  -- 冻结老库 B_Worker.Emp_Name（fallback）

-- ---------------- 采购付款 finance_payments ----------------
ALTER TABLE finance_payments
    ADD COLUMN IF NOT EXISTS maker_legacy_id     INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id  INT,
    ADD COLUMN IF NOT EXISTS operator_legacy_id  INT,   -- WorkID 经手人（B_Worker）；operator_name(jsr) 已存在
    ADD COLUMN IF NOT EXISTS maker_name          TEXT,
    ADD COLUMN IF NOT EXISTS approver_name       TEXT;

-- ---------------- 一般费用 finance_expenses ----------------
ALTER TABLE finance_expenses
    ADD COLUMN IF NOT EXISTS maker_legacy_id     INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id  INT,
    ADD COLUMN IF NOT EXISTS operator_legacy_id  INT,   -- WorkID 经手人（B_Worker）
    ADD COLUMN IF NOT EXISTS maker_name          TEXT,
    ADD COLUMN IF NOT EXISTS approver_name       TEXT,
    ADD COLUMN IF NOT EXISTS operator_name       TEXT;

-- ---------------- 其它收入 finance_other_incomes ----------------
ALTER TABLE finance_other_incomes
    ADD COLUMN IF NOT EXISTS maker_legacy_id     INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id  INT,
    ADD COLUMN IF NOT EXISTS operator_legacy_id  INT,   -- WorkID 经手人（B_Worker）
    ADD COLUMN IF NOT EXISTS maker_name          TEXT,
    ADD COLUMN IF NOT EXISTS approver_name       TEXT,
    ADD COLUMN IF NOT EXISTS operator_name       TEXT;

-- ---------------- 银行存取款 finance_bank_transfers（老库 0 行，保结构） ----------------
ALTER TABLE finance_bank_transfers
    ADD COLUMN IF NOT EXISTS maker_legacy_id     INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id  INT,
    ADD COLUMN IF NOT EXISTS operator_legacy_id  INT,   -- WorkID 经办人（B_Worker）
    ADD COLUMN IF NOT EXISTS maker_name          TEXT,
    ADD COLUMN IF NOT EXISTS approver_name       TEXT,
    ADD COLUMN IF NOT EXISTS operator_name       TEXT;

-- ---------------- 应收应付台账 ar_ap_ledger：PStyle 结帐方式原值 ----------------
ALTER TABLE ar_ap_ledger
    ADD COLUMN IF NOT EXISTS settlement_style_legacy SMALLINT;  -- M_in/M_out.PStyle（B_PStyle 字典未 dump）

-- ---------------- 报表过滤辅助索引（facet 表头筛选 + 人员 JOIN） ----------------
CREATE INDEX IF NOT EXISTS idx_frt_maker     ON finance_receipts(maker_legacy_id);
CREATE INDEX IF NOT EXISTS idx_frt_approver  ON finance_receipts(approver_legacy_id);
CREATE INDEX IF NOT EXISTS idx_frt_operator  ON finance_receipts(operator_legacy_id);
CREATE INDEX IF NOT EXISTS idx_fpm_maker     ON finance_payments(maker_legacy_id);
CREATE INDEX IF NOT EXISTS idx_fpm_approver  ON finance_payments(approver_legacy_id);
CREATE INDEX IF NOT EXISTS idx_fpm_operator  ON finance_payments(operator_legacy_id);
CREATE INDEX IF NOT EXISTS idx_fexp_maker    ON finance_expenses(maker_legacy_id);
CREATE INDEX IF NOT EXISTS idx_fexp_approver ON finance_expenses(approver_legacy_id);
CREATE INDEX IF NOT EXISTS idx_fexp_operator ON finance_expenses(operator_legacy_id);
CREATE INDEX IF NOT EXISTS idx_foi_maker     ON finance_other_incomes(maker_legacy_id);
CREATE INDEX IF NOT EXISTS idx_foi_approver  ON finance_other_incomes(approver_legacy_id);
CREATE INDEX IF NOT EXISTS idx_foi_operator  ON finance_other_incomes(operator_legacy_id);
CREATE INDEX IF NOT EXISTS idx_arap_settle   ON ar_ap_ledger(settlement_style_legacy);
