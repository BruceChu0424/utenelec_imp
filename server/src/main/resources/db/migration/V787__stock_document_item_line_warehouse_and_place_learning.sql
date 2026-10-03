-- V787: 手工出入库单的行级仓库 + 库位记忆来源扩展（2026-10-01 用户口径
-- 「仓库不放表头，放表格里；库位号之类的要有记忆」，对齐销售出库 V631 / 委外批量拣货）。
-- 原占位 V782 与 closeout 批次的 explicit_test_business_reset 撞号（并行会话各自取号），
-- 已提交侧不可改，本迁移顺延为 V787。
--
-- 1) stock_document_items 增加可选 warehouse_id：OTHER_IN / OTHER_OUT / WASTE /
--    FINISHED_IN / FINISHED_OUT / DRAW / WDRAW 审核与红冲按行仓走库存流水
--    （空 = 沿用表头仓；历史单据与服务端链路生成的行不带值，行为不变）。
--    TRANSFER（调出/调入两腿在表头）与 CHECK（账面按表头仓快照）仍只用表头。
-- 2) 库位学习来源增加 STOCK_DOC：其它入库 / 产成品进仓审核成功后按
--    仓库×货品×颜色把本次实际库位写进 warehouse_goods_place_preferences，
--    下次登记/制单的建议库位即可带出（与 IQC / 产成品登记同一条记忆链）。

ALTER TABLE stock_document_items
    ADD COLUMN warehouse_id UUID REFERENCES warehouses(id) ON DELETE RESTRICT;

COMMENT ON COLUMN stock_document_items.warehouse_id IS
    '行级仓库(手工出入库单逐行选仓; 空=沿用表头仓; TRANSFER/CHECK 不使用)';

CREATE INDEX idx_sdi_warehouse ON stock_document_items(warehouse_id)
    WHERE warehouse_id IS NOT NULL;

ALTER TABLE warehouse_goods_place_preferences
    DROP CONSTRAINT warehouse_goods_place_preference_kind_chk;
ALTER TABLE warehouse_goods_place_preferences
    ADD CONSTRAINT warehouse_goods_place_preference_kind_chk CHECK (
        source_kind IN ('FINISHED_ARRIVAL', 'IQC_STOCK_IN', 'STOCK_DOC'));

-- STOCK_DOC 学习不带来源单据引用：与既有两来源的互斥约束并列成第三臂，
-- 防错记时无法追溯（place 偏好本身无历史依赖，幂等重放由审核事务保证只写一次）。
ALTER TABLE warehouse_goods_place_preferences
    DROP CONSTRAINT warehouse_goods_place_preference_source_chk;
ALTER TABLE warehouse_goods_place_preferences
    ADD CONSTRAINT warehouse_goods_place_preference_source_chk CHECK (
        (source_kind = 'FINISHED_ARRIVAL'
            AND source_registration_id IS NOT NULL
            AND source_iqc_batch_id IS NULL)
        OR (source_kind = 'IQC_STOCK_IN'
            AND source_iqc_batch_id IS NOT NULL
            AND source_registration_id IS NULL)
        OR (source_kind = 'STOCK_DOC'
            AND source_registration_id IS NULL
            AND source_iqc_batch_id IS NULL));

COMMENT ON COLUMN warehouse_goods_place_preferences.source_kind IS
    '学习来源类型：FINISHED_ARRIVAL=产成品到货登记；IQC_STOCK_IN=采购/委外 IQC 仓库确认入库；'
    'STOCK_DOC=其它入库/产成品进仓单据审核';
