-- V231: 主档乐观锁版本列（防"两人编辑同一记录、后写覆盖先写"的丢失更新）。
-- 配合实体 JPA @Version + 服务端 DTO 版本校验（OptimisticLocks.requireUpToDate）。
-- 默认 0；JPA 每次 save 自增；编辑表单回传读到的 version，服务端比对不符即 409。
-- 覆盖客户/货品/供应商三大主档（业务关键、偶有并发编辑）；简单查照类（颜色/单位/币种…）
-- 并发编辑极少，按既定模式（本迁移 + @Version + DTO 回传）按需追加。
ALTER TABLE clients   ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 0;
ALTER TABLE goods     ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 0;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 0;
