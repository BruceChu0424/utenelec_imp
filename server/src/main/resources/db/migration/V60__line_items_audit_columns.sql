-- =====================================================================
-- V60：明细/行表补 created_by/updated_by 审计列
-- =====================================================================
-- 背景：所有明细 Entity extends BaseEntity → AuditableEntity，需 created_at/updated_at/
--   created_by/updated_by 四列。主表（V50-V58）齐备，但 21 张明细/行表在建表时
--   漏建 created_by/updated_by（契约 doc27 §二 误写"明细可省"，与采购 V44 范式冲突——
--   purchase_receipt_items 实测有 created_by/updated_by）。Hibernate ddl-auto=validate
--   启动校验失败（missing column created_by in finance_bank_transfer_lines）。
-- 修法：对齐采购范式，给 21 张明细/行表补 created_by/updated_by（不改 Entity，Entity 正确）。
--   列可空（历史迁移数据无审计人；新系统录单填当前登录用户）。
--   production_plan_costs 为分区表，ALTER ADD COLUMN 自动传播到所有子分区。
-- 幂等：ADD COLUMN IF NOT EXISTS。
-- =====================================================================

-- 销售明细（6）
ALTER TABLE sales_quote_items          ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sales_order_items          ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sales_order_cost_items     ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sales_shipment_items       ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sales_other_shipment_items ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sales_return_items         ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;

-- 委外明细（9）
ALTER TABLE subcontract_inquiry_items        ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE subcontract_application_items     ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE subcontract_order_items           ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE subcontract_order_cost_items      ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE subcontract_receipt_items         ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE subcontract_material_issue_items  ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE subcontract_return_items          ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE subcontract_material_return_items ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE subcontract_waste_items           ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;

-- 生产明细（1；plan_items / daily_report_items 建表时已有，无需补）
ALTER TABLE production_plan_costs       ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;

-- 钱流明细/行（5）
ALTER TABLE finance_receipt_lines       ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE finance_payment_lines       ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE finance_expense_items       ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE finance_other_income_items  ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE finance_bank_transfer_lines ADD COLUMN IF NOT EXISTS created_by UUID, ADD COLUMN IF NOT EXISTS updated_by UUID;
