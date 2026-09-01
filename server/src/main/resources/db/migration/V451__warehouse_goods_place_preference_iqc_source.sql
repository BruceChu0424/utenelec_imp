-- V451: IQC 仓库确认入库也作为库位学习来源。
--
-- 现状缺口：warehouse_goods_place_preferences 只有产成品到货登记能写，
-- 采购/委外 IQC 合格品入库确认从不回写学习表，导致「上次入库库位」
-- 永远带不出来（placeHint 只剩可能为空的 goods.stock_place）。
--
-- 本迁移把来源维度泛化为 source_kind + 两个按类型互斥的可空引用：
-- - FINISHED_ARRIVAL：原 source_registration_id（保持 NOT NULL 语义由互斥约束接管）；
-- - IQC_STOCK_IN：新增 source_iqc_batch_id 指向 procurement_iqc_stock_in_batches。
-- 偏好行本身仍只承载「仓库×货品×颜色的未来建议库位」，不改库存、不改历史快照。

ALTER TABLE warehouse_goods_place_preferences
    ALTER COLUMN source_registration_id DROP NOT NULL;

ALTER TABLE warehouse_goods_place_preferences
    ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'FINISHED_ARRIVAL'
        CONSTRAINT warehouse_goods_place_preference_kind_chk CHECK (
            source_kind IN ('FINISHED_ARRIVAL', 'IQC_STOCK_IN'));

ALTER TABLE warehouse_goods_place_preferences
    ADD COLUMN source_iqc_batch_id UUID
        REFERENCES procurement_iqc_stock_in_batches(id) ON DELETE RESTRICT;

-- 存量行默认 FINISHED_ARRIVAL 且登记引用非空，直接满足；新行必须按 kind 二选一。
ALTER TABLE warehouse_goods_place_preferences
    ADD CONSTRAINT warehouse_goods_place_preference_source_chk CHECK (
        (source_kind = 'FINISHED_ARRIVAL'
            AND source_registration_id IS NOT NULL
            AND source_iqc_batch_id IS NULL)
        OR (source_kind = 'IQC_STOCK_IN'
            AND source_iqc_batch_id IS NOT NULL
            AND source_registration_id IS NULL));

CREATE INDEX idx_warehouse_goods_place_preference_iqc_batch
    ON warehouse_goods_place_preferences(source_iqc_batch_id);

COMMENT ON COLUMN warehouse_goods_place_preferences.source_kind IS
    '学习来源类型：FINISHED_ARRIVAL=产成品到货登记；IQC_STOCK_IN=采购/委外 IQC 仓库确认入库';
COMMENT ON COLUMN warehouse_goods_place_preferences.source_iqc_batch_id IS
    'IQC_STOCK_IN 来源的确认批次 UUID（幂等重放不产生新批次，不重复学习）';
COMMENT ON COLUMN warehouse_goods_place_preferences.source_registered_at IS
    '最近一次成功学习的来源事件时间，与来源 UUID 一起阻止旧来源覆盖新偏好';
