-- V94：notices 补齐审计列（updated_at / updated_by）
-- V92 建表只含 created_at/created_by，但 Notice 实体继承 BaseEntity（AuditableEntity 四审计列），
-- Hibernate schema-validation 报 missing column [updated_at] 导致服务无法启动。
-- V92 已被 Flyway 应用（不可改内容），故用增量迁移补齐。

ALTER TABLE notices
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS updated_by UUID;
