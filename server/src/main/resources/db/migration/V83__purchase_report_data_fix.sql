-- =====================================================================
-- V83：采购报表数据补全（申请/订货/收货/退货 明细+汇总缺列修复）
-- =====================================================================
-- 背景：对照老库视图定义（View_P_Application / View_P_Order / View_P_In / View_P_WithDraw）
--   逐列核对后发现四类缺口，本迁移补底层列；数据由 migrate_purchase.sql 重迁灌入：
-- ① department_legacy_id：申请单"部门"= P_Application.StepID → SystemItem(ItemclassID=5)，
--    老视图口径（非员工 ParentID）。
-- ② maker_name / approver_name：制单员/审核员 = Sys_Operator.fname（登录账号，非 B_Worker
--    员工档案），按委外/钱流同款"迁移时冻结文本列"模式，employees 对齐后 COALESCE 优先真人。
-- ③ purchase_receipts.purchaser_legacy_id：收货"采购员"= P_In.sman（业务员），
--    老视图口径（不走订货单反查）。
-- ④ legacy_departments：老库部门字典（SystemItem ItemclassID=5），供报表按 legacy_id 出名。
-- =====================================================================

-- ---------------- 采购申请单 ----------------
ALTER TABLE purchase_requests
    ADD COLUMN IF NOT EXISTS department_legacy_id INT,      -- P_Application.StepID → legacy_departments
    ADD COLUMN IF NOT EXISTS maker_name          TEXT,      -- Sys_Operator.fname（迁移冻结）
    ADD COLUMN IF NOT EXISTS approver_name       TEXT;

-- ---------------- 采购订货单 ----------------
ALTER TABLE purchase_orders
    ADD COLUMN IF NOT EXISTS maker_name          TEXT,
    ADD COLUMN IF NOT EXISTS approver_name       TEXT;

-- ---------------- 采购收货单 ----------------
ALTER TABLE purchase_receipts
    ADD COLUMN IF NOT EXISTS purchaser_legacy_id INT,       -- P_In.sman 业务员（老视图"采购员"口径）
    ADD COLUMN IF NOT EXISTS maker_name          TEXT,
    ADD COLUMN IF NOT EXISTS approver_name       TEXT;

-- ---------------- 采购退货单 ----------------
ALTER TABLE purchase_returns
    ADD COLUMN IF NOT EXISTS maker_name          TEXT,
    ADD COLUMN IF NOT EXISTS approver_name       TEXT;

-- ---------------- 老库部门字典（SystemItem ItemclassID=5，只读参考） ----------------
CREATE TABLE IF NOT EXISTS legacy_departments (
    legacy_id INT PRIMARY KEY,                              -- SystemItem.ItemID
    name      TEXT NOT NULL,                                -- 部门名（计划部/销售部/...）
    code      TEXT                                          -- SystemItem.Number
);
