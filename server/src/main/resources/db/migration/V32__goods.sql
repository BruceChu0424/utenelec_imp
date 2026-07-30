-- =====================================================================
-- V32：货品主档 goods（基础资料 · 货品资料 → 具体货品）
-- =====================================================================
-- 来源：老库 B_Goods（34814 条），B_Goods.ParentID → SystemItem.ItemID（分类）
--   由 migrate.sh 的 goods 步骤迁移灌入。
-- 字段：B_Goods 全 78 字段（除 ParentID 转 category_id 外）。
--   * image 字段（GroundGraph/ProductGraph1-6/BudgetGraph）建 bytea 列，但二进制图本次不迁
--     （bcp 单独导较重，多数货品无图），结构留位，后续按需 bcp 灌图。
--   * 关联字段（Unit/Color/Mould/Client/Vend/...）保留 *_legacy_id INT（老库主键，暂不建 FK，
--     待对应主档表迁移后再加约束）。
--   * legacy_id = B_Goods.ID，迁移溯源 + 重跑幂等。
-- =====================================================================

CREATE TABLE goods (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                       -- B_Goods.ID
    category_id     UUID REFERENCES material_categories(id) ON DELETE RESTRICT,  -- B_Goods.ParentID → 分类

    -- 标识 / 名称
    code            TEXT,                              -- ANumber 编号
    name            TEXT,                              -- Goods_Name 名称
    short_name      TEXT,                              -- Short_Name
    model           TEXT,                              -- Number 型号
    spec            TEXT,                              -- Standard 规格

    -- 关联（老库主键，暂不 FK）
    unit_legacy_id     INT,    -- UnitID
    color_legacy_id    INT,    -- MColorID
    mould_legacy_id    INT,    -- MouldID
    client_legacy_id   INT,    -- ClientID
    vend_legacy_id     INT,    -- VendID
    vend2_legacy_id    INT,    -- VendID2
    assteam_legacy_id  INT,    -- AssTeamID
    veil_legacy_id     INT,    -- VeilID
    approver_legacy_id INT,    -- ApproverID
    make_legacy_id     INT,    -- MakeID

    -- 价格 / 数量
    price        DOUBLE PRECISION,  -- Price (float)
    a_price      NUMERIC(18,4),     -- APrice
    price2       NUMERIC(18,4),     -- Price2
    max_qty      DOUBLE PRECISION,  -- Max_QTY
    min_qty      DOUBLE PRECISION,  -- Min_QTY
    init_stock   INT,               -- InitStock
    init_count   NUMERIC(18,4),     -- InitCount
    init_weight  NUMERIC(18,4),     -- InitWeight
    kqty         NUMERIC(18,4),     -- KQTY
    kqty2        NUMERIC(18,4),     -- KQTY2
    pieces       INT,               -- Pieces
    lost_rate    NUMERIC(18,4),     -- LostRate
    cap          DOUBLE PRECISION,  -- CAP

    -- 物理属性
    material     TEXT,              -- Material
    thickness    NUMERIC(18,4),     -- Thickness
    l_style      TEXT,              -- LStyle
    z_weight     NUMERIC(18,4),     -- ZWeight
    m_weight     NUMERIC(18,4),     -- MWeight
    pack         TEXT,              -- Pack
    b_pack       TEXT,              -- BPack
    paper        TEXT,              -- Paper
    series       TEXT,              -- Series
    chart_id     TEXT,              -- ChartID
    lights       TEXT,              -- Lights
    stock_place  TEXT,              -- StockPlace
    c_number     TEXT,              -- CNumber
    v_number     TEXT,              -- VNumber
    bs_test      TEXT,              -- BSTest
    require_remark TEXT,            -- Require（保留字避让）

    -- 成本项
    source_e      NUMERIC(18,4),    -- SourceE
    work_e        NUMERIC(18,4),    -- WorkE
    lacquer_e     NUMERIC(18,4),    -- LacquerE
    incidental_e  NUMERIC(18,4),    -- IncidentalE
    plating_e     NUMERIC(18,4),    -- PlatingE
    casing_e      NUMERIC(18,4),    -- CasingE
    manage_e      NUMERIC(18,4),    -- ManageE
    polish_e      NUMERIC(18,4),    -- PolishE
    electric_e    NUMERIC(18,4),    -- ElectricE
    machining_e   NUMERIC(18,4),    -- MachiningE
    lost_e        NUMERIC(18,4),    -- LostE
    rent_e        NUMERIC(18,4),    -- RentE
    make_e        NUMERIC(18,4),    -- MakeE
    work_rate     NUMERIC(18,4),    -- WorkRate
    make_rate     NUMERIC(18,4),    -- MakeRate
    rent_rate     NUMERIC(18,4),    -- RentRate
    total         NUMERIC(18,4),    -- Total
    c_total       NUMERIC(18,4),    -- CTotal
    g_total       NUMERIC(18,4),    -- GTotal

    -- 状态 / 标志
    bom_status  BOOLEAN,            -- BomStatus (bit)
    status      TEXT,               -- Status
    app_status  INT,                -- AppStatus
    app_status2 INT,                -- AppStatus2
    g_style     INT,                -- GStyle
    ck          INT,                -- ck
    zk          NUMERIC(18,4),      -- zk

    -- 图片（image → bytea，本次建列不迁二进制，后续 bcp 灌图）
    ground_graph    BYTEA,          -- GroundGraph
    product_graph1  BYTEA,          -- ProductGraph1
    product_graph2  BYTEA,          -- ProductGraph2
    product_graph3  BYTEA,          -- ProductGraph3
    product_graph4  BYTEA,          -- ProductGraph4
    product_graph5  BYTEA,          -- ProductGraph5
    product_graph6  BYTEA,          -- ProductGraph6
    budget_graph    BYTEA,          -- BudgetGraph

    -- 审计 + 软删
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_goods_category    ON goods(category_id);
CREATE INDEX idx_goods_legacy_id   ON goods(legacy_id);
CREATE INDEX idx_goods_code        ON goods(code);

COMMENT ON TABLE  goods IS '货品主档（基础资料-货品资料），老库 B_Goods 全字段迁移';
COMMENT ON COLUMN goods.legacy_id   IS '老库 B_Goods.ID（迁移溯源+重跑幂等）';
COMMENT ON COLUMN goods.category_id IS '所属分类（material_categories.id，源自 B_Goods.ParentID→SystemItem.ItemID）';

-- 权限点（查看/维护货品，category「主数据」）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('goods:view', '查看货品', '主数据', 20),
    ('goods:edit', '维护货品', '主数据', 21)
ON CONFLICT (code) DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'goods:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;
