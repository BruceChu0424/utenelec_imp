-- =====================================================================
-- V61：Entity / DDL 对齐补漏（finances 明细表 remark）
-- =====================================================================
-- 背景：系统性扫描 4 个新模块（sales / subcontract / production / finance）
--   + 2 个主档（accounts / payment_styles）共 47 个 @Entity 的 @Column / @JoinColumn /
--   继承基类（AuditableEntity / BaseEntity / SoftDeletableEntity）映射列，对比真实 DB 列，
--   除 V60 已补的明细表 created_by / updated_by 之外，仅发现 2 处遗漏：
--     finance_expense_items.remark
--     finance_other_income_items.remark
--   原因：V57 建表时这两张明细都只建了 summary TEXT，漏建 Entity 上同样声明的 remark TEXT
--   （Entity 无 @Column 注解 → 默认列名 remark，Hibernate SpringPhysicalNamingStrategy）。
--   ddl-auto=validate 启动校验报 "missing column remark in finance_expense_items"。
-- 修法：补 remark TEXT（NULLable，与同表 summary 风格一致；不影响迁移历史数据）。
--   不改 Entity——Entity 是事实源，对齐采购 V44 范式（行表明细普遍有 summary + remark 两栏）。
-- 幂等：ADD COLUMN IF NOT EXISTS。
-- =====================================================================

ALTER TABLE finance_expense_items      ADD COLUMN IF NOT EXISTS remark TEXT;
ALTER TABLE finance_other_income_items ADD COLUMN IF NOT EXISTS remark TEXT;
