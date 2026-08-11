-- =====================================================================
-- V128：货品「来源」属性（自制/采购/委外）
-- =====================================================================
-- 背景：货品主档需要区分货品是自制、采购还是委外（数据来源：新 ERP 产品列表
--   「产品角色」列：自制件→自制、外购件→采购、委外件→委外）。
-- 设计：
--   goods.source_type VARCHAR(20)，可空（老数据未维护时为空，不强制回填）。
--   值域约定：'自制' / '采购' / '委外'（与前端编辑下拉 kGoodsSourceTypeOptions 对齐）；
--   不加 CHECK 约束，保留将来扩展（如 '客供'）的余地。
--   批量回填由移植脚本 server/legacy_migration/import_product_lists.py 按产品编号匹配灌入（幂等）。
-- 版本号说明：开发库 flyway_schema_history 已由更新代码树推进到 V127，
--   本脚本取下一个空号 V128，避免与既有 V100「order change planned perm」冲突。
-- =====================================================================

ALTER TABLE goods
    ADD COLUMN IF NOT EXISTS source_type VARCHAR(20);
CREATE INDEX IF NOT EXISTS idx_goods_source_type ON goods(source_type) WHERE source_type IS NOT NULL;
