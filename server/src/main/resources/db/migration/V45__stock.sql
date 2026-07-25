-- =====================================================================
-- V45：库存流水 + 余额账（库存联动）
-- =====================================================================
-- 取代老库 StockGoods 按月分列台账（INQTY01..12 写死 12 列）：
--   stock_movements = 出入库流水（所有单据统一入口：采购/销售/领料/盘点/调拨…）
--   stock_balances  = 当前余额（仓库+货品+颜色 粒度，唯一约束 upsert）
-- 采购收货/退货审核时，Service 在同一事务内：写流水 + upsert 余额，对用户零割裂。
-- 历史台账（按月/期初期末）走流水聚合，后续库存模块再建按月物化视图。
-- 详见 docs/数据迁移/15-采购模块-新库与迁移.md §五。
-- =====================================================================

-- ====================== 出入库流水 ======================
CREATE TABLE stock_movements (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_date TIMESTAMPTZ NOT NULL,
    movement_type   SMALLINT NOT NULL,                   -- 1采购入库 2采购退货 3销售出库 4销售退货
                                                         -- 5生产领料 6生产退料 7调拨入 8调拨出
                                                         -- 9盘盈入 10盘亏出 11其它入 12其它出
    source_doc_type TEXT NOT NULL,                       -- PURCHASE_RECEIPT/PURCHASE_RETURN/SALES_OUT/...
    source_doc_id   UUID,                                -- 来源单据 id
    source_item_id  UUID,                                -- 来源明细 id
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    warehouse_id    UUID NOT NULL REFERENCES warehouses(id),
    direction       SMALLINT NOT NULL,                   -- +1 入库 / -1 出库
    qty             NUMERIC(18,4) NOT NULL,              -- 基本单位量（已乘 unit_rate）
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6),
    amount_local    NUMERIC(18,4),                       -- 本币金额（采购=入库成本）
    remark          TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID
);

CREATE INDEX idx_sm_date  ON stock_movements(transaction_date);
CREATE INDEX idx_sm_goods ON stock_movements(goods_id);
CREATE INDEX idx_sm_wh    ON stock_movements(warehouse_id);
CREATE INDEX idx_sm_src   ON stock_movements(source_doc_type, source_doc_id);
CREATE INDEX idx_sm_type  ON stock_movements(movement_type);

-- ====================== 当前余额 ======================
CREATE TABLE stock_balances (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_id    UUID NOT NULL REFERENCES warehouses(id),
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),          -- null = 无色货品
    qty             NUMERIC(18,4) NOT NULL DEFAULT 0,    -- 当前余量（基本单位）
    amount_local    NUMERIC(18,4) DEFAULT 0,             -- 库存成本（本币）
    last_movement_date TIMESTAMPTZ,                      -- 最后一次出入库时间
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,
    -- NULLS NOT DISTINCT：无色货品 color_id=null 也按唯一约束合并（pg15+，否则同仓同货多行 null）
    UNIQUE NULLS NOT DISTINCT (warehouse_id, goods_id, color_id)
);

CREATE INDEX idx_sb_goods ON stock_balances(goods_id);

COMMENT ON TABLE stock_movements IS '出入库流水（库存联动）；所有单据统一入口，direction +1 入/-1 出';
COMMENT ON TABLE stock_balances  IS '库存当前余额（仓库+货品+颜色 粒度）；采购审核同事务 upsert';

-- ====================== 权限点 ======================
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('stock:view', '查看库存', '库存管理', 200),
    ('stock:edit', '维护库存', '库存管理', 201)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（库存查询内部可见）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'stock:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给 PMC 运营部（库存盘点/调整归 PMC；正常出入库由各业务单据审核联动，不直接 CRUD）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC' AND p.code = 'stock:edit'
ON CONFLICT DO NOTHING;
