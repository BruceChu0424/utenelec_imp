-- 模具制造商由用户人工维护；新增可空字段，不猜测或改写既有模具资料。
ALTER TABLE moulds ADD COLUMN manufacturer TEXT;
COMMENT ON COLUMN moulds.manufacturer IS '模具制造商（人工维护；历史资料可为空）';
