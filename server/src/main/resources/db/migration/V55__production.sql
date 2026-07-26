-- =====================================================================
-- V55：生产管理 · 生产计划 + BOM 展开成本 + 日报（生产管理）
-- =====================================================================
-- 设计依据：
--   docs/数据迁移/27-DDL一致性契约.md（§一文件归属 / §二通用约定 / §五权限双 category
--     生产 sort 400-469 挂 DEPT_PROD / §六分区规则 F_PlanCostItem 按年分区 / §八自检）
--   docs/数据迁移/24-生产管理-新库与迁移.md（§3 表 DDL + §5 F_PlanCostItem 分区方案
--     + §7 字段映射 + §4 本期"不做"清单）
--   范本：V48__stock_documents.sql / V44__purchase_documents.sql
--
-- 源 F_ 表（老库 YTDQ_2023）：
--   F_Plan           (7,235 行)      → production_plans
--   F_PlanItem       (73,388 行)     → production_plan_items
--   F_PlanCostItem   (1,359,875 行)  → production_plan_costs  ⭐ 按年 RANGE 分区
--   F_DateReport     (0 行 · 字段矛盾) → production_daily_reports         空结构保未来
--   F_DateReportItem (0 行)            → production_daily_report_items    空结构保未来
--
-- ⭐ production_plan_costs 分区（契约 §六 + design §5）：
--   PARTITION BY RANGE(bill_date)（反冗余 bill_date，取值路径：
--     production_plan_costs.bill_date
--       ← JOIN production_plan_items ppi ON ppi.id = bill_item_id
--       ← JOIN production_plans       pp  ON pp.id = ppi.plan_id
--       ← pp.bill_date）
--   初始 13 个年度分区（2018–2030，覆盖老库历史 + 未来 5 年）+ DEFAULT 兜底；
--   PK (id, bill_date)；UNIQUE(legacy_id, bill_date)（分区表 legacy_id 不能单独 UNIQUE）；
--   8 个索引（uq_ppc_legacy 组合 UNIQUE + bill_item_id / parent_id /
--     sales_order_cost_item_id / legacy_id / bill_date / goods_id / master_goods_id）。
--   对比老库：F_PlanCostItem 除 PK 外无任何二级索引 —— 1.36M 行全表扫描是性能重灾区。
--
-- ⚠ FK 陷阱（design §3.3 + §5）：
--   production_plan_costs.bill_item_id → production_plan_items.id（**不是 plans.id！**）
--   老库 fkeys.txt：F_PlanCostItem.BillID → F_PlanItem.ID（成本展开行挂在计划明细行下）。
--   错关联会全表错位。
--   本期不建该 FK：production_plan_costs 是分区表，跨分区 FK 复杂；改用
--     idx_ppc_billitem 索引 + 应用层 + 迁移校验保证（同 design §3.2 脚注）。
--   parent_id 自引用同样不建 FK：PG 分区表 PK 含 bill_date，自引用需含分区键，
--     改用 idx_ppc_parent 索引 + 应用层校验（子父行 bill_date 必一致）。
--
-- ⚠ 跨模块 FK 不建（契约 §一 最高约束："各模块 DDL 互不 FK，跨模块联动在 Service 层"）：
--   sales_order_item_id     （→ sales_order_items.id，V51 销售未落地）  → 留 UUID 列 + 索引 + 注释。
--   sales_order_cost_item_id（→ sales_order_cost_items.id，V51）        → 同上。
--   迁移时 V51 必须先于 V55 数据迁移应用（依赖序见契约 §一）。
--
-- 本期"不做"清单（design §4.2 + §10）—— 触发器逻辑归未来模块，BOM 数据原样保只读：
--   · BOM 自动展开（TRI_F_PlanCostItem_Insert）
--   · 数量级联重算（TRI_F_PlanCostItem_Update：父.QTY×DQTY → 子）
--   · Level 计算（TRI_F_PlanCostItem_Level ≤30，原样保 Level）
--   · 审核回写 S_OrderItem（PQTY/LQTY/PlanNo）
--   · 产能填充 F_ProductingItem / 排产 F_Arrange
--   · 工序 F_StepItem / F_PStepItem / F_Transfer
--   · 成本核算 F_Cost
--   · MRP 需购量公式（View_F_PlanCostItem 三分支 CASE）
--   · CheckFulfill4 改 Service 层派生 is_closed（同采购范式，本期实现）
-- =====================================================================


-- ====================== 生产计划单头（源 F_Plan，7,235 行） ======================
CREATE TABLE production_plans (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id           INT  UNIQUE,                     -- F_Plan.ID
    bill_no             TEXT NOT NULL,                   -- BillNo（前缀 SJ，业务主键）
    bill_date           DATE NOT NULL,                   -- BillDate
    f_style             TEXT,                            -- FStyle 生产类型（老库样本为空）
    delivery_date       DATE,                            -- DDate 交货日期
    department_id       UUID,                            -- WorkShop→departments（老库 varchar 装数字/名字，能对齐才填）
    workshop_name       TEXT,                            -- WorkShop 原样留底（车间编号/名字字符串，样本 "37"/"38"）
    worker_name         TEXT,                            -- WorkerID varchar(250) 多值名字，原样文本
    seller_name         TEXT,                            -- Seller varchar(250) 跟单员，原样文本
    maker_id            UUID,                            -- MakeID→employees（迁移留空，B_Worker 与 employees 无 legacy_id 对齐）
    approver_id         UUID,                            -- ApproverID→employees（迁移留空）
    maker_legacy_id     INT,                             -- MakeID 老 ID 留底（后续 worker_legacy_map 回填）
    approver_legacy_id  INT,                             -- ApproverID 老 ID 留底
    remark              TEXT,                            -- Remark（text 大字段）
    status              SMALLINT NOT NULL DEFAULT 0,     -- 0草稿/1已审/-1红冲（老库 1/-1，无 0）
    is_closed           BOOLEAN NOT NULL DEFAULT FALSE,  -- Fulfill（Service 派生：所有明细 qty-iqty ≤ 0）
    is_stopped          BOOLEAN NOT NULL DEFAULT FALSE,  -- Stop（手工中止）
    is_canceled         BOOLEAN NOT NULL DEFAULT FALSE,  -- Cancel（取消）
    source_doc_no       TEXT,                            -- 软关联占位（销售订单号等）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE INDEX idx_pp_billno  ON production_plans(bill_no);
CREATE INDEX idx_pp_date    ON production_plans(bill_date);
CREATE INDEX idx_pp_status  ON production_plans(status);
CREATE INDEX idx_pp_dept    ON production_plans(department_id);
CREATE INDEX idx_pp_legacy  ON production_plans(legacy_id);

COMMENT ON TABLE  production_plans            IS '生产计划单头（源 F_Plan 7,235 行）；status 0草稿/1已审/-1红冲；is_closed 由 Service 派生';
COMMENT ON COLUMN production_plans.workshop_name IS '老库 WorkShop varchar(250) 装数字/名字（样本 37/38），原样留底；department_id 待 workshop_legacy_map 回填';


-- ====================== 生产计划明细（源 F_PlanItem，73,388 行） ======================
-- ⚠ legacy_id（= F_PlanItem.ID）被 production_plan_costs.bill_item_id 经它映射为 UUID。
--   老库 fkeys.txt：F_PlanCostItem.BillID → F_PlanItem.ID（不是 F_Plan.ID）。
CREATE TABLE production_plan_items (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id               INT,                         -- F_PlanItem.ID（⚠ 被 production_plan_costs.bill_item_id 引用！）
    bill_no                 TEXT NOT NULL,               -- 冗余（查询裁剪 + 报表免 JOIN 主表）
    bill_date               DATE NOT NULL,               -- 冗余（裁剪索引）
    plan_id                 UUID NOT NULL REFERENCES production_plans(id) ON DELETE CASCADE,
    line_no                 INT,
    product_no              TEXT NOT NULL,               -- ProductNo 业务主键（IX_F_PlanItem 唯一）
    goods_id                UUID NOT NULL REFERENCES goods(id),  -- GoodsID
    color_id                UUID REFERENCES colors(id),  -- ColorID
    mgoods_id               UUID REFERENCES goods(id),   -- MGoodsID 替代/顶层货品
    unit_id                 UUID REFERENCES units(id),
    unit_rate               NUMERIC(18,6) DEFAULT 1,     -- URate（qty × unit_rate = 基本量）
    -- 销售订单真 FK 骨干（V51 sales_order_items 本批同步新建；跨模块不建 REFERENCES，仅列 + 索引）
    sales_order_item_id     UUID,                        -- S_OrderID → sales_order_items.id（单值逻辑 FK）
    sales_order_no          TEXT,                        -- S_OrderNo（文本占位，老库软关联）
    client_name             TEXT,                        -- Client varchar(250) 客户名冗余
    client_no               TEXT,                        -- ClientNo varchar(50) 客户号冗余
    -- 数量族（12 个，全保留 NUMERIC(18,4)；触发器游标回写的累计量，本期不重算但保数据）
    oqty                    NUMERIC(18,4) DEFAULT 0,     -- OQTY 销售订货量
    qty                     NUMERIC(18,4) DEFAULT 0,     -- QTY 本单排产数量（float→numeric）
    lqty                    NUMERIC(18,4) DEFAULT 0,     -- LQTY 本次用量（BOM 展开锁定）
    iqty                    NUMERIC(18,4) DEFAULT 0,     -- IQTY 完工/进仓数量（仓库 O_ProductionItem 回写）
    fqty                    NUMERIC(18,4) DEFAULT 0,     -- FQTY 完工数量（工序回写）
    rqty                    NUMERIC(18,4) DEFAULT 0,     -- RQTY 入库数量
    bqty                    NUMERIC(18,4) DEFAULT 0,     -- BQTY 在产数量（F_ProductItem 回写）
    tqty                    NUMERIC(18,4) DEFAULT 0,     -- TQTY 开工数量（F_Transfer 回写）
    paqty                   NUMERIC(18,4) DEFAULT 0,     -- PAQTY 已排产量
    isrqty                  NUMERIC(18,4) DEFAULT 0,     -- ISRQTY 已入库量
    cpqty                   NUMERIC(18,4) DEFAULT 0,     -- CPQTY 应排数量
    poqty                   NUMERIC(18,4) DEFAULT 0,     -- POQTY 已订货（采购回写）
    piqty                   NUMERIC(18,4) DEFAULT 0,     -- PIQTY 已收货（采购回写）
    -- 日期
    order_date              DATE,                        -- OderDate 下订日期（老库拼写保留）
    outbound_date           DATE,                        -- OutDate 交货日期
    plan_begin_date         DATE,                        -- PBeginDate 计划开工
    plan_end_date           DATE,                        -- PEndDate 计划完工
    -- 重量（float→numeric）
    finished_weight         NUMERIC(18,4),               -- FWeight 完工重量
    inbound_weight          NUMERIC(18,4),               -- IWeight 进仓重量
    -- 状态/工序（多套并存，原样保留）
    lstatus                 SMALLINT,                    -- LStatus 排产状态
    cstatus                 SMALLINT,                    -- CStatus 成本状态
    step_legacy_id          INT,                         -- StepID → B_Step（主档未建，留 legacy int）
    -- 领域字典（主档未建，留 legacy int + 文本）
    veil_legacy_id          INT,                         -- VeilID → B_Veil 面罩
    ass_team_legacy_id      INT,                         -- AssTeamID → B_AssTeam 装配组
    fittings                TEXT,                        -- Fittings 配件
    -- 辅助
    request_note            TEXT,                        -- Request 特殊要求
    customer_model          TEXT,                        -- CNumber 客户型号
    discount                NUMERIC(18,4),               -- Discount
    label_no                TEXT,                        -- LabelNo 标签号
    plan_app_no             TEXT,                        -- PAppNo 排产单号
    -- 多值溯源合并文本（InNo varchar(5000) 进仓单号 / TranNo varchar(5000) 工序调派单号）
    --   格式 'IN:xxx | TRAN:yyy'，每字段 NULL/空跳过，保留前缀便于未来按类型回填真 FK
    source_doc_no           TEXT,
    remark                  TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (product_no)
);

CREATE INDEX idx_ppi_plan    ON production_plan_items(plan_id);
CREATE INDEX idx_ppi_goods   ON production_plan_items(goods_id);
CREATE INDEX idx_ppi_date    ON production_plan_items(bill_date);
CREATE INDEX idx_ppi_legacy  ON production_plan_items(legacy_id);
CREATE INDEX idx_ppi_soitem  ON production_plan_items(sales_order_item_id);

COMMENT ON TABLE  production_plan_items IS '生产计划明细（源 F_PlanItem 73,388 行）；legacy_id 被 production_plan_costs.bill_item_id 引用（陷阱见 V55 头注释）';
COMMENT ON COLUMN production_plan_items.sales_order_item_id IS '→ sales_order_items.id（V51）；跨模块不建 REFERENCES（契约 §一），仅逻辑 FK + 索引';


-- ====================== 生产计划成本 / BOM 展开（源 F_PlanCostItem，1,359,875 行 · 按年 RANGE 分区） ======================
-- ⚠ FK 陷阱：bill_item_id → production_plan_items.id（不是 production_plans.id！）
--   老库 fkeys.txt：F_PlanCostItem.BillID → F_PlanItem.ID（成本展开行挂在计划明细行下）。
--   不建 FK 反向引用：production_plan_costs 是分区表，跨分区 FK 复杂；
--     改用 idx_ppc_billitem 索引 + 应用层 + 迁移校验（design §3.2 脚注）。
CREATE TABLE production_plan_costs (
    id                          UUID NOT NULL DEFAULT gen_random_uuid(),
    legacy_id                   INT  NOT NULL,           -- F_PlanCostItem.ID（老库 IDENTITY）
    bill_item_id                UUID NOT NULL,           -- ⚠ BillID → production_plan_items.id（不是 plans.id！）
    bill_no                     TEXT NOT NULL,           -- 反冗余（JOIN 三级链取，裁剪 + 报表免 JOIN）
    bill_date                   DATE NOT NULL,           -- ⭐ 反冗余自 F_Plan.BillDate，分区键
    -- BOM 树
    parent_id                   UUID,                    -- ParentID 自引用（UUID 映射后回填；不建 FK 见头注释）
    parent_legacy_id            INT  NOT NULL DEFAULT 0, -- 老库 ParentID（0=顶层），迁移留底便于校验
    level                       SMALLINT NOT NULL DEFAULT 0,  -- Level BOM 层级（TRI_F_PlanCostItem_Level ≤30，原样保）
    node_class                  SMALLINT NOT NULL DEFAULT 0,  -- Class 0=物料 / ≠0=工序或费用
    goods_id                    UUID NOT NULL REFERENCES goods(id),       -- GoodsID 当前节点
    color_id                    UUID REFERENCES colors(id),               -- ColorID
    master_goods_id             UUID REFERENCES goods(id),                -- MGoodsID 顶层成品（冗余便于按成品汇总）
    master_color_id             UUID REFERENCES colors(id),               -- MColorID
    sales_order_cost_item_id    UUID,                    -- SOCItemID → sales_order_cost_items.id（V51；跨模块不建 FK）
    -- 数量族（16 个，全保留 NUMERIC(18,4)；本期不重算，原样保触发器游标累计量）
    qty                         NUMERIC(18,4) DEFAULT 0, -- QTY 总需量（成品量 × 单支用量）
    dqty                        NUMERIC(18,4) DEFAULT 0, -- DQTY 单套用量（BOM 单耗）
    pqty                        NUMERIC(18,4) DEFAULT 0, -- PQTY 计划数量（带损耗投产量）
    lqty                        NUMERIC(18,4) DEFAULT 0, -- LQTY 排产占用
    slqty                       NUMERIC(18,4) DEFAULT 0, -- SLQTY 本次用量（计算列）
    rqty                        NUMERIC(18,4) DEFAULT 0, -- RQTY 入库数量
    order_qty                   NUMERIC(18,4) DEFAULT 0, -- OrderQTY 已订货（采购回写）
    in_qty                      NUMERIC(18,4) DEFAULT 0, -- INQTY 已收货（采购回写）
    pdraw_qty                   NUMERIC(18,4) DEFAULT 0, -- PDrawQTY 已领料（仓库回写）
    owdraw_qty                  NUMERIC(18,4) DEFAULT 0, -- OWDrawQTY 已退料（仓库回写）
    pwdraw_qty                  NUMERIC(18,4) DEFAULT 0, -- PWDrawQTY 采购退货量
    eo_qty                      NUMERIC(18,4) DEFAULT 0, -- EOQTY 委外订货（委外回写）
    ei_qty                      NUMERIC(18,4) DEFAULT 0, -- EIQTY 委外缴回
    ew_qty                      NUMERIC(18,4) DEFAULT 0, -- EWQTY 委外退回
    mqty                        NUMERIC(18,4) DEFAULT 0, -- MQTY 多订量（手工调整）
    pa_qty                      NUMERIC(18,4) DEFAULT 0, -- PAQTY 已排产量
    -- 金额
    price                       NUMERIC(18,4),           -- Price 单价
    total                       NUMERIC(18,4),           -- Total = QTY × Price
    supplier_id                 UUID REFERENCES suppliers(id),  -- VendID 建议供应
    ass_team_legacy_id          INT,                     -- AssTeamID → B_AssTeam（主档未建，留 legacy int）
    -- 多值溯源号 9 个 varchar → 合并 source_doc_no（前缀化保留类型可识别）
    --   格式 'PO:xxx | PI:yyy | PW:zzz | PD:aaa | OW:bbb | EO:ccc | EI:ddd | EW:eee | PA:fff'
    source_doc_no               TEXT,
    -- 状态
    lstatus                     SMALLINT,                -- LStatus 行状态（影响 View_F_PlanCostItem 需购量 CASE）
    summary                     TEXT,                    -- Summary 摘要
    -- 审计（分区明细省 created_by/updated_by，同 V48 仓库明细）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (id, bill_date)                          -- 分区表 PK 必须含分区键
) PARTITION BY RANGE (bill_date);

-- 年度分区 2018–2030（覆盖老库历史 + 未来 5 年）
CREATE TABLE production_plan_costs_2018  PARTITION OF production_plan_costs FOR VALUES FROM ('2018-01-01') TO ('2019-01-01');
CREATE TABLE production_plan_costs_2019  PARTITION OF production_plan_costs FOR VALUES FROM ('2019-01-01') TO ('2020-01-01');
CREATE TABLE production_plan_costs_2020  PARTITION OF production_plan_costs FOR VALUES FROM ('2020-01-01') TO ('2021-01-01');
CREATE TABLE production_plan_costs_2021  PARTITION OF production_plan_costs FOR VALUES FROM ('2021-01-01') TO ('2022-01-01');
CREATE TABLE production_plan_costs_2022  PARTITION OF production_plan_costs FOR VALUES FROM ('2022-01-01') TO ('2023-01-01');
CREATE TABLE production_plan_costs_2023  PARTITION OF production_plan_costs FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');
CREATE TABLE production_plan_costs_2024  PARTITION OF production_plan_costs FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE production_plan_costs_2025  PARTITION OF production_plan_costs FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE production_plan_costs_2026  PARTITION OF production_plan_costs FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE production_plan_costs_2027  PARTITION OF production_plan_costs FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');
CREATE TABLE production_plan_costs_2028  PARTITION OF production_plan_costs FOR VALUES FROM ('2028-01-01') TO ('2029-01-01');
CREATE TABLE production_plan_costs_2029  PARTITION OF production_plan_costs FOR VALUES FROM ('2029-01-01') TO ('2030-01-01');
CREATE TABLE production_plan_costs_2030  PARTITION OF production_plan_costs FOR VALUES FROM ('2030-01-01') TO ('2031-01-01');
-- DEFAULT 分区兜底（防 2031+ 或异常日期；迁移时 bill_date NULL 行已由 staging 兜底为 '1970-01-01'）
CREATE TABLE production_plan_costs_default PARTITION OF production_plan_costs DEFAULT;

-- UNIQUE(legacy_id, bill_date)：分区表 UNIQUE 必须含分区键；迁移去重 + 老库 ID 溯源（① 8 索引之一）
CREATE UNIQUE INDEX uq_ppc_legacy    ON production_plan_costs (legacy_id, bill_date);
-- 7 个核心索引（取代老库"除 PK 外无任何二级索引"的全表扫描重灾区）
CREATE INDEX idx_ppc_billitem        ON production_plan_costs (bill_item_id);          -- ② 经 F_PlanItem 反查 BOM（最频繁）
CREATE INDEX idx_ppc_parent          ON production_plan_costs (parent_id);             -- ③ BOM 自引用树遍历
CREATE INDEX idx_ppc_socitem         ON production_plan_costs (sales_order_cost_item_id);  -- ④ 生产→销售成本溯源
CREATE INDEX idx_ppc_legacy          ON production_plan_costs (legacy_id);             -- ⑤ 单值溯源（不带 bill_date）
CREATE INDEX idx_ppc_date            ON production_plan_costs (bill_date);             -- ⑥ 显式供查询规划器（分区裁剪已隐含）
CREATE INDEX idx_ppc_goods           ON production_plan_costs (goods_id);              -- ⑦ 按节点货品汇总（BOM 物料需求）
CREATE INDEX idx_ppc_mgoods          ON production_plan_costs (master_goods_id);       -- ⑧ 按顶层成品汇总（最常用）

COMMENT ON TABLE  production_plan_costs                IS '生产计划成本 / BOM 展开表（源 F_PlanCostItem 1,359,875 行 · 按年 RANGE 分区 2018-2030 + DEFAULT）；本期只读不重算';
COMMENT ON COLUMN production_plan_costs.bill_item_id   IS '⚠ FK 陷阱：→ production_plan_items.id（老库 F_PlanCostItem.BillID → F_PlanItem.ID，不是 F_Plan.ID）';
COMMENT ON COLUMN production_plan_costs.bill_date      IS '⭐ 反冗余分区键：JOIN bill_item_id → items.plan_id → plans.bill_date 三级取值';
COMMENT ON COLUMN production_plan_costs.parent_id      IS 'ParentID 自引用；不建 FK（PG 分区表 PK 含 bill_date，自引用需含分区键），改用 idx_ppc_parent + 应用层校验';
COMMENT ON COLUMN production_plan_costs.sales_order_cost_item_id IS '→ sales_order_cost_items.id（V51）；跨模块不建 REFERENCES（契约 §一），仅逻辑 FK + 索引';


-- ====================== 生产日报头（源 F_DateReport，0 行 · 空结构保未来） ======================
-- F_DateReport 从未启用（字段类型自相矛盾，design §3.4），本期建空结构，保未来启用零成本。
CREATE TABLE production_daily_reports (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id           INT  UNIQUE,                     -- F_DateReport.ID
    bill_no             TEXT NOT NULL,
    bill_date           DATE NOT NULL,
    warehouse_id        UUID REFERENCES warehouses(id),  -- StockID（F_DateReport 是 int ID，与 F_Plan varchar 矛盾，本期统一为 FK）
    department_id       UUID,                            -- WorkShop（同 plans，能对齐才填）
    workshop_name       TEXT,                            -- WorkShop 原样留底（与 plans 一致，design §7.4）
    worker_id           UUID,                            -- WorkerID 报工人（迁移留空）
    supplier_id         UUID REFERENCES suppliers(id),   -- VendID 委外供应商？（语义存疑，留位）
    maker_id            UUID,                            -- MakeID（迁移留空）
    approver_id         UUID,                            -- ApproverID（迁移留空）
    maker_legacy_id     INT,
    approver_legacy_id  INT,
    remark              TEXT,
    status              SMALLINT NOT NULL DEFAULT 0,
    is_closed           BOOLEAN NOT NULL DEFAULT FALSE,
    is_canceled         BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no       TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE production_daily_report_items (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id               INT,
    bill_no                 TEXT NOT NULL,
    bill_date               DATE NOT NULL,
    report_id               UUID NOT NULL REFERENCES production_daily_reports(id) ON DELETE CASCADE,
    line_no                 INT,
    goods_id                UUID NOT NULL REFERENCES goods(id),
    color_id                UUID REFERENCES colors(id),
    unit_id                 UUID REFERENCES units(id),
    unit_rate               NUMERIC(18,6) DEFAULT 1,
    qty                     NUMERIC(18,4),               -- 完工量（float→numeric）
    price                   NUMERIC(18,4),
    total                   NUMERIC(18,4),               -- 金额
    stotal                  NUMERIC(18,4),               -- 成本金额
    sales_order_item_id     UUID,                        -- OrderID → sales_order_items.id（V51；跨模块不建 FK）
    sales_order_no          TEXT,                        -- OrderNo
    plan_item_id            UUID,                        -- PlanID → production_plan_items.id（同表内引用，不建 FK 避复杂）
    plan_no                 TEXT,                        -- PlanNo
    outbound_no             TEXT,                        -- OutNo 发货单号
    outbound_qty            NUMERIC(18,4),               -- OutQTY 发货量
    order_qty               NUMERIC(18,4),               -- OrderQTY 订货量
    step_legacy_id          INT,                         -- StepID → B_Step（主档未建）
    order_date              DATE,                        -- OrderDate 下订日期
    boxes                   NUMERIC(18,4),               -- Boxs 箱数
    per_box_qty             NUMERIC(18,4),               -- KQTY 把/箱
    weight                  NUMERIC(18,4),               -- Weight
    client_name             TEXT,                        -- Client 客户名冗余
    source_doc_no           TEXT,
    remark                  TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_pdr_billno  ON production_daily_reports(bill_no);
CREATE INDEX idx_pdr_date    ON production_daily_reports(bill_date);
CREATE INDEX idx_pdr_wh      ON production_daily_reports(warehouse_id);
CREATE INDEX idx_pdr_status  ON production_daily_reports(status);
CREATE INDEX idx_pdri_report ON production_daily_report_items(report_id);
CREATE INDEX idx_pdri_goods  ON production_daily_report_items(goods_id);
CREATE INDEX idx_pdri_plan   ON production_daily_report_items(plan_item_id);

COMMENT ON TABLE  production_daily_reports        IS '生产日报头（源 F_DateReport 0 行 · 字段矛盾从未启用 · 空结构保未来）';
COMMENT ON TABLE  production_daily_report_items   IS '生产日报明细（源 F_DateReportItem 0 行 · 空结构保未来）';
COMMENT ON COLUMN production_daily_report_items.sales_order_item_id IS '→ sales_order_items.id（V51）；跨模块不建 REFERENCES（契约 §一），仅逻辑 FK + 索引';


-- ====================== 权限点（契约 §五：双 category + 三段 seed · DEPT_PROD） ======================
-- category 分配（契约 §五 生产段）：
--   生产管理 400-449：production_plan / production_plan_cost / production_daily_report
--   生产报表 450-469：production_report
-- production_plan_cost 只读（无 :edit）—— BOM 展开表 1.36M 行本期不重算不编辑（design §3.5）。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('production_plan:view',         '查看生产计划',  '生产管理', 400),
    ('production_plan:edit',         '维护生产计划',  '生产管理', 401),
    ('production_plan_cost:view',    '查看BOM展开',   '生产管理', 410),
    ('production_daily_report:view', '查看生产日报',  '生产管理', 420),
    ('production_daily_report:edit', '维护生产日报',  '生产管理', 421),
    ('production_report:view',       '查看生产报表',  '生产报表', 450)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（生产计划 / BOM / 日报 / 报表 内部可见）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code IN ('production_plan:view',
                 'production_plan_cost:view',
                 'production_daily_report:view',
                 'production_report:view')
  AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给生产部 DEPT_PROD（production_plan_cost 无 edit；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PROD'
  AND p.code IN ('production_plan:edit',
                 'production_daily_report:edit')
ON CONFLICT DO NOTHING;
