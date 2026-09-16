-- =====================================================================
-- V587 2026-09-15 货品主档新增「所属仓库」
-- =====================================================================
-- 背景：新 ERP 导出的产品列表里每个货品都带一个「所属仓库」(五金仓库 / 塑胶仓库 /
--   包材仓库 / 成品仓库 / 五金车间)，这是这批货平时归哪个仓管的**主档归属**。
--   平台一直没有这个字段：物料分析下达采购 / 委外 / 车间时，计划员看不出这行料
--   归哪个仓，只能靠记。本迁移把它落到货品主档，前端在物料分析各表里可改，
--   改完写回主档，下次加载就是最新值。
--
-- 列：goods.owning_warehouse_id UUID NULL -> warehouses(id)
--
-- 命名为什么是 owning_warehouse_id 而不是 warehouse_id：
--   平台里 "warehouse_id" 已经是**单据落点仓**的通名(stock_movements、
--   warehouse_goods_place_preferences 等 6 张表都用它)，而物料分析页另有一套
--   「分析范围仓」(前端 production.materialAnalysis.warehouses 偏好)。再叫
--   warehouse_id，三个不同语义会在同一屏里撞名。owning_ 前缀把「归属」与
--   「落点」「范围」分开。
--
-- **不限叶子仓**：V476 的「只允许落到具体(叶子)仓」约束是给**单据过账**定的
--   (父仓只作查询聚合与下拉分组)。所属仓库是主档分类，不是过账落点；而且
--   「成品仓库」这类合法值本身可能挂着不良子仓，leaf-only 会把它拒掉。
--   这里只要求仓库存在且未软删，由服务端校验，不加数据库 CHECK。
--
-- **本迁移不回填**：名称→仓库的对照数据在 `product lists/` 三个 .xls 里，
--   该目录已被 .gitignore 明确排除(真实业务数据，绝不入库)。回填走既有的
--   `server/legacy_migration/import_product_lists.py`(按**产品名称**匹配，
--   17010 个不重名、零冲突)，并登记在 docs/数据迁移 目录里随下次数据迁移执行。
--   迁移只建列，任何环境跑都得到同一个结果。
--
-- 语句顺序(V259 第 6-9 行为 goods 明写过的规矩)：先加列、建索引、装未校验的
--   外键，**再**做任何 UPDATE，最后 VALIDATE。goods 带审计/业务触发器，
--   一旦本语句排队了触发器事件，PostgreSQL 会拒绝后续的 ALTER TABLE。
--   本迁移没有 UPDATE，顺序依旧照此写，免得后人往中间插回填。
--
-- 审计 / 清库白名单核实(只加列、不加表，两处都不用改)：
-- ① 审计触发器：goods 已在 AuditTriggerCoverageMigrationContractTest 的
--    REQUIRED_BUSINESS_TABLES 里，行级触发器按整行 to_jsonb 记录，新列自动进
--    快照，不需要动 allowlist，也不需要再发一版 refresh_audit_trigger_coverage。
-- ② 清空业务数据白名单(ops/reset_business_data.sql 与 business_data_reset())
--    是**表级** CLEAR/PRESERVE 分类，goods 已登记为 PRESERVE。本次没有新表，
--    白名单不用改。所属仓库是主档口径，清业务数据时应随主档保留，不进 CLEAR。
-- =====================================================================

ALTER TABLE goods
    ADD COLUMN IF NOT EXISTS owning_warehouse_id UUID;

CREATE INDEX IF NOT EXISTS idx_goods_owning_warehouse
    ON goods(owning_warehouse_id)
    WHERE owning_warehouse_id IS NOT NULL;

ALTER TABLE goods
    ADD CONSTRAINT fk_goods_owning_warehouse
        FOREIGN KEY (owning_warehouse_id) REFERENCES warehouses(id)
        ON DELETE RESTRICT
        NOT VALID;

ALTER TABLE goods
    VALIDATE CONSTRAINT fk_goods_owning_warehouse;

COMMENT ON COLUMN goods.owning_warehouse_id IS
    '所属仓库(warehouses.id，可空)：这批货平时归哪个仓管的主档归属，来源为新 ERP 产品列表的「所属仓库」列。不是单据落点仓(那是各单据自己的 warehouse_id)，也不是物料分析的范围仓；不限叶子仓。NULL=未登记。';
