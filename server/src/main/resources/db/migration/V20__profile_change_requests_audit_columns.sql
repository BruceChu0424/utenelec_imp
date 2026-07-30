-- V18 在 profile_change_requests 上漏写 created_by / updated_by 列，
-- Hibernate 启动时 schema-validation 触发 [PersistenceUnit: default] Unable to build
-- Hibernate SessionFactory ... missing column [created_by]。
-- 本迁移给现有表补上审计人列（nullable，符合 Spring Data Auditing 行为）。
ALTER TABLE profile_change_requests ADD COLUMN IF NOT EXISTS created_by UUID;
ALTER TABLE profile_change_requests ADD COLUMN IF NOT EXISTS updated_by UUID;