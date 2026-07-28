-- =====================================================================
-- V79：货品组装信息 goods_bom_items（基础资料 · 货品资料 → 组装/BOM）
-- =====================================================================
-- 来源：老库 B_BomItem（218,820 行 / 23,322 个父货品），由 migrate.sh 的
--   goods-bom 步骤迁移灌入（migrate_goods_bom.sql）。
-- 语义：每行 = 「某货品（goods_id，成品/半成品）由某组件（component_goods_id）
--   组装 N 个」。组件本身也可有自己的 BOM（递归即成 001.jpg 的树）。
-- 约束：
--   * 同一成品下组件唯一（老库实测 (BillID,GoodsID) 0 重复）——编号唯一，
--     后续业务统一按组件货品编号关联。
--   * 老库孤儿行（BillID/GoodsID 指向已删除货品）迁移时跳过，不灌入。
-- =====================================================================

CREATE TABLE goods_bom_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- B_BomItem.ID（迁移溯源+重跑幂等）

    goods_id            UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,  -- 成品/半成品（B_BomItem.BillID）
    component_goods_id  UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,  -- 组件货品（B_BomItem.GoodsID）

    color_legacy_id INT,                               -- ColorID（组件颜色，老库主键）
    qty         NUMERIC(18,5) NOT NULL DEFAULT 1,      -- QTY 用量
    price       NUMERIC(18,3),                         -- Price 单价
    total       NUMERIC(18,2),                         -- Total 金额（= qty*price，后端兜底重算）
    vend_legacy_id INT,                                -- VendID（默认供应商，老库主键）
    summary     TEXT,                                  -- Summary 备注（外购/外加工...）
    bom_status  BOOLEAN,                               -- BomStatus
    sstatus     BOOLEAN,                               -- SStatus
    sort_order  INT NOT NULL DEFAULT 0,                -- 展示序号（迁移按老库 ID 序）

    -- 审计 + 软删
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_goods_bom_goods      ON goods_bom_items(goods_id);
CREATE INDEX idx_goods_bom_component  ON goods_bom_items(component_goods_id);
CREATE INDEX idx_goods_bom_legacy_id  ON goods_bom_items(legacy_id);

-- 同一成品下同一组件只允许一条未删除记录（编号唯一原则的落库保障）
CREATE UNIQUE INDEX uq_goods_bom_component
    ON goods_bom_items(goods_id, component_goods_id)
    WHERE is_deleted = false;

COMMENT ON TABLE  goods_bom_items IS '货品组装信息（BOM）：成品→组件用量清单，老库 B_BomItem 迁移';
COMMENT ON COLUMN goods_bom_items.legacy_id IS '老库 B_BomItem.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN goods_bom_items.goods_id IS '成品/半成品货品（goods.id，源自 B_BomItem.BillID）';
COMMENT ON COLUMN goods_bom_items.component_goods_id IS '组件货品（goods.id，源自 B_BomItem.GoodsID）';
