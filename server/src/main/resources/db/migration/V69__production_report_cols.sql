-- =====================================================================
-- V69：生产报表所需字段补列（生产管理 / 生产报表）
-- =====================================================================
-- 背景：V55 建表时 production_plans 的制单员/审核员只留 *_legacy_id（INT，指向
--   老库 B_Worker / Sys_Operator），无冻结名列——报表显示人名依赖
--   employees.legacy_id 对齐（四模块共用 P0，HR 尚未录入）。现补
--   maker_name / approver_name 文本列：迁移期冻结老库 Sys_Operator.fname /
--   B_Worker.Emp_Name（migrate_production.sql 经 export 双表 COALESCE 取名）。
--   报表 COALESCE(em.full_name, p.maker_name)：employees 对齐后用真名，否则
--   用冻结名（同委外 V66 / 采购 V65 的 *_legacy_id + *_name 双轨范式）。
-- 全部可空列，不影响现有 CRUD / 审核 / MV 刷新。
-- employees.legacy_id 列 + 唯一索引已在 V65 建立，本迁移不动 employees 结构。
-- 权限 production_report:view 已在 V55:359 seed，物化视图 production_monthly_mv
--   已在 V56 就位，本迁移不重复注册。
-- =====================================================================

-- ---------------- 生产计划单主表 ----------------
ALTER TABLE production_plans
    ADD COLUMN IF NOT EXISTS maker_name    TEXT,   -- 制单员名（冻结老库 Sys_Operator.fname / B_Worker.Emp_Name；未来 employees.legacy_id 对齐后报表 COALESCE 优先真名）
    ADD COLUMN IF NOT EXISTS approver_name TEXT;   -- 审核员名（同上）

-- ---------------- 报表过滤辅助索引（facet 表头筛选） ----------------
CREATE INDEX IF NOT EXISTS idx_pp_maker    ON production_plans(maker_legacy_id);
CREATE INDEX IF NOT EXISTS idx_pp_approver ON production_plans(approver_legacy_id);
