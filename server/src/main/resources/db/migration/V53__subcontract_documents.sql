-- =====================================================================
-- V53：委外管理 8 单据主从表 + BOM 成本子表（委外管理）
-- =====================================================================
-- 范本：V44__purchase_documents.sql（委外 = 带 BOM 展开的采购，结构大量参照）
-- 设计依据：docs/数据迁移/22-委外管理-新库与迁移.md（design doc 22，17 张表完整 DDL）
-- 一致性契约：docs/数据迁移/27-DDL一致性契约.md（最高约束 · §三 movement_type 15-19 ·
--   §五 权限双 category 委外 sort 300-399 挂 DEPT_SALES · §八 交付前自检）
--
-- 8 类单据（综合营销部 DEPT_SALES，前端"8 单据 8 页"零割裂）：
--   询价 subcontract_inquiries        (E_Ask,0 行·建结构)
--   申请 subcontract_applications     (E_Application,0 行·建结构)
--   订货 subcontract_orders           (E_Order,2 行) → BOM 展开成本子表
--   进仓 subcontract_receipts         (E_In,10732 行) → 收回成品
--   发料 subcontract_material_issues  (E_SOut,10627 行) → 材料出仓
--   退货 subcontract_returns          (E_WithDraw,442 行) → 成品退
--   材料退 subcontract_material_returns (E_SWithDraw,65 行) → 材料退
--   损耗 subcontract_wastes           (E_SWaste,3 行) → 材料损耗（含 waste_rate/cause）
--
-- 链路真外键骨干（7 条，取代老库 varchar 逗号串 + f_split 游标回写）：
--   receipt_items.order_item_id            → 订货明细 (InID/OrderID)
--   return_items.receipt_item_id           → 进仓明细 (InID)
--   return_items.order_item_id             → 订货明细 (OrderID)
--   material_issue_items.order_item_id     → 订货明细 (EOrderID)
--   material_return_items.material_issue_item_id → 发料明细 (EOutID)
--   material_return_items.order_item_id    → 订货明细 (EOrderID)
--   waste_items.material_issue_item_id     → 发料明细 (OutID · ★补全老库未回写链路)
--
-- 状态机：status 0=草稿 / 1=已审 / -1=红冲（贴老库"保存即生效"）；is_closed 结案（Service 派生）。
-- 回写量：明细 received/returned/issued/material_returned/wasted_qty 由单据审核 Service 回写
--   （取代老库触发器；E_SWaste 损耗回写为新库补全项）。
-- 明细冗余 bill_no/bill_date：查询裁剪 + 报表（免 JOIN 主表取日期），建索引。
-- 人员 *_id（maker/approver/sender/worker/purchaser/applicant）：UUID，无 FK
--   （employees 与老库 B_Worker 未对齐，迁移留空；新系统录入填当前登录用户）。
-- 多值溯源（EOrderNo/BomItemID/SOrderNo/PlanNo 等 17 个 varchar 逗号串）→ 合并降级 source_doc_no。
--
-- 金额双口径：*_original（原币）+ *_local（本币 = 原币×汇率）。
--   订货/进仓/退货带币种；发料/材料退/损耗无币种（材料按成本发出，amount_local 由审核 Service 重算）。
-- BOM 决策（design doc 22 §五）：本期建结构 + 迁老库 67 行原样；自动展开后置 Service（与生产 F_PlanCostItem 一致）；
--   waste_allowance 字段化老库硬编码 +0.46；ap_posted 跟踪应付立帐状态（契约 §四，DDL 不 FK 到 ar_ap_ledger）。
-- 性能：明细单表 + 强索引（十几年 ~9 万行，单表 B-tree 毫秒级；无需分区；bill_date 留位，未来可在线转分区）。
-- =====================================================================


-- ====================== 委外询价单（E_Ask，0 行·建结构） ======================
CREATE TABLE subcontract_inquiries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- E_Ask.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),       -- VendID（委外商）
    warehouse_id    UUID REFERENCES warehouses(id),      -- StockID
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    maker_id        UUID,                                -- MakeID（无 FK）
    approver_id     UUID,
    deliver_date    DATE,                                -- SendDate
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,         -- 0草稿/1已审/-1红冲
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,                                -- 软关联占位
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE subcontract_inquiry_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,                                 -- 不 UNIQUE（跨表 IDENTITY 冲突，同仓库踩坑）
    bill_no         TEXT NOT NULL,                       -- 冗余（报表/查询）
    bill_date       DATE NOT NULL,                       -- 冗余（裁剪索引）
    inquiry_id      UUID NOT NULL REFERENCES subcontract_inquiries(id) ON DELETE CASCADE,
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),
    amount_local    NUMERIC(18,4),
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_sinq_billno    ON subcontract_inquiries(bill_no);
CREATE INDEX idx_sinq_date      ON subcontract_inquiries(bill_date);
CREATE INDEX idx_sinq_supplier  ON subcontract_inquiries(supplier_id);
CREATE INDEX idx_sinq_status    ON subcontract_inquiries(status);
CREATE INDEX idx_sinq_legacy    ON subcontract_inquiries(legacy_id);
CREATE INDEX idx_sini_inquiry   ON subcontract_inquiry_items(inquiry_id);
CREATE INDEX idx_sini_goods     ON subcontract_inquiry_items(goods_id);
CREATE INDEX idx_sini_date      ON subcontract_inquiry_items(bill_date);
CREATE INDEX idx_sini_legacy    ON subcontract_inquiry_items(legacy_id);


-- ====================== 委外申请单（E_Application，0 行·建结构） ======================
CREATE TABLE subcontract_applications (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- E_Application.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),
    warehouse_id    UUID REFERENCES warehouses(id),
    applicant_id    UUID,                                -- 申请人（无 FK）
    maker_id        UUID,
    approver_id     UUID,
    need_date       DATE,
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE subcontract_application_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    application_id  UUID NOT NULL REFERENCES subcontract_applications(id) ON DELETE CASCADE,
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),
    amount_local    NUMERIC(18,4),
    ordered_qty     NUMERIC(18,4) DEFAULT 0,             -- 已订量（订货审核回写）
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_sapp_billno    ON subcontract_applications(bill_no);
CREATE INDEX idx_sapp_date      ON subcontract_applications(bill_date);
CREATE INDEX idx_sapp_supplier  ON subcontract_applications(supplier_id);
CREATE INDEX idx_sapp_status    ON subcontract_applications(status);
CREATE INDEX idx_sapp_legacy    ON subcontract_applications(legacy_id);
CREATE INDEX idx_sapi_application ON subcontract_application_items(application_id);
CREATE INDEX idx_sapi_goods     ON subcontract_application_items(goods_id);
CREATE INDEX idx_sapi_date      ON subcontract_application_items(bill_date);
CREATE INDEX idx_sapi_legacy    ON subcontract_application_items(legacy_id);


-- ====================== 委外订货单（E_Order，2 行）+ BOM 成本子表 ======================
CREATE TABLE subcontract_orders (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- E_Order.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),       -- VendID（委外商）
    warehouse_id    UUID REFERENCES warehouses(id),      -- StockID
    currency_id     UUID REFERENCES currencies(id),      -- CurID
    exchange_rate   NUMERIC(18,6) DEFAULT 1,             -- CRate
    tax_rate        NUMERIC(18,4) DEFAULT 0,             -- TRate
    purchaser_id    UUID,                                -- 业务员（无 FK）
    maker_id        UUID,
    approver_id     UUID,
    deliver_date    DATE,                                -- SendDate 交货日
    fulfill         BOOLEAN NOT NULL DEFAULT FALSE,      -- 结案标志（老库 CF_E_Order 触发器，Service 派生）
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE subcontract_order_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    order_id        UUID NOT NULL REFERENCES subcontract_orders(id) ON DELETE CASCADE,
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),   -- 成品（父件）
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,               -- 订货量（成品）
    price           NUMERIC(18,4),                        -- 加工单价
    amount_original NUMERIC(18,4),
    amount_local    NUMERIC(18,4),
    received_qty    NUMERIC(18,4) DEFAULT 0,              -- 已进仓（E_In 审核回写，源 IQTY）
    returned_qty    NUMERIC(18,4) DEFAULT 0,              -- 已成品退（E_WithDraw 审核回写，源 WQTY）
    issued_qty      NUMERIC(18,4) DEFAULT 0,              -- 已发料（E_SOut 审核回写，源 OQTY）
    material_returned_qty NUMERIC(18,4) DEFAULT 0,        -- 已材料退（E_SWithDraw 审核回写）
    application_item_id UUID REFERENCES subcontract_application_items(id),  -- 申请明细真FK
    deliver_date    DATE,
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,                                 -- ESONo/ESWNo/EInNo/SWDrawNo 多值降级
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

-- 委外订货 BOM 展开成本子表（源 E_OrderCostItem，67 行；老库触发器递归维护，
-- 新库本期保结构 + 迁老库数据原样；自动展开逻辑后置 Service.expandOrderBom()，与生产 F_PlanCostItem 一致）
CREATE TABLE subcontract_order_cost_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    order_id        UUID NOT NULL REFERENCES subcontract_orders(id) ON DELETE CASCADE,
    order_item_id   UUID NOT NULL REFERENCES subcontract_order_items(id) ON DELETE CASCADE,  -- 根成品明细
    parent_cost_item_id UUID REFERENCES subcontract_order_cost_items(id),                    -- BOM 父件（自关联）
    bom_level       INT NOT NULL DEFAULT 1,                -- BOM 层级（老库最深 30）
    parent_goods_id UUID REFERENCES goods(id),             -- 父件货品（MGoodsID）
    parent_color_id UUID REFERENCES colors(id),            -- 父件颜色（MColorID）
    goods_id        UUID NOT NULL REFERENCES goods(id),    -- 子件货品（GoodsID）
    color_id        UUID REFERENCES colors(id),            -- 子件颜色（ColorID）
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    unit_qty        NUMERIC(18,6),                         -- DQTY 单支用量（BOM 子件单位用量）
    qty             NUMERIC(18,4) NOT NULL,                -- QTY = 父件量×子件用量+余量（迁老库原值）
    waste_allowance NUMERIC(18,6) DEFAULT 0,               -- ★规则化余量（老库硬编码 +0.46；新库字段化）
    issued_qty      NUMERIC(18,4) DEFAULT 0,               -- SQTY 已出仓量（E_SOut 审核按 BomItemID 累加）
    returned_qty    NUMERIC(18,4) DEFAULT 0,               -- WQTY 已退量
    line_class      TEXT,                                  -- 老库 Class 字段
    source_doc_no   TEXT,                                  -- SendNo/WDrawNo 多值降级
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_sord_billno      ON subcontract_orders(bill_no);
CREATE INDEX idx_sord_date        ON subcontract_orders(bill_date);
CREATE INDEX idx_sord_supplier    ON subcontract_orders(supplier_id);
CREATE INDEX idx_sord_status      ON subcontract_orders(status);
CREATE INDEX idx_sord_legacy      ON subcontract_orders(legacy_id);
CREATE INDEX idx_sori_order       ON subcontract_order_items(order_id);
CREATE INDEX idx_sori_goods       ON subcontract_order_items(goods_id);
CREATE INDEX idx_sori_appitem     ON subcontract_order_items(application_item_id);
CREATE INDEX idx_sori_date        ON subcontract_order_items(bill_date);
CREATE INDEX idx_sori_legacy      ON subcontract_order_items(legacy_id);
CREATE INDEX idx_scoci_order       ON subcontract_order_cost_items(order_id);
CREATE INDEX idx_scoci_orderitem   ON subcontract_order_cost_items(order_item_id);
CREATE INDEX idx_scoci_parent      ON subcontract_order_cost_items(parent_cost_item_id);
CREATE INDEX idx_scoci_goods       ON subcontract_order_cost_items(goods_id);
CREATE INDEX idx_scoci_date        ON subcontract_order_cost_items(bill_date);
CREATE INDEX idx_scoci_legacy      ON subcontract_order_cost_items(legacy_id);


-- ====================== 委外进仓单（E_In，收回成品 → 库存 type17 dir+1） ======================
CREATE TABLE subcontract_receipts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- E_In.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),       -- VendID（委外商）
    warehouse_id    UUID REFERENCES warehouses(id),      -- StockID
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    tax_rate        NUMERIC(18,4) DEFAULT 0,
    sender_id       UUID,                                -- SenderID 交货人（委外商联系人，常空，符合业务事实）
    maker_id        UUID,
    approver_id     UUID,
    last_date       DATE,                                -- Last_Date（最后交货日）
    ap_posted       BOOLEAN NOT NULL DEFAULT FALSE,      -- 应付已立帐标志（审核→postArAp(AP,SUBCONTRACT_RECEIPT)；契约 §四）
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,             -- Total 抽样全 0（成品收回按成本，主表合计不维护）
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE subcontract_receipt_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    receipt_id      UUID NOT NULL REFERENCES subcontract_receipts(id) ON DELETE CASCADE,
    order_item_id   UUID REFERENCES subcontract_order_items(id),     -- OrderID 真FK（关联订货明细）
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,               -- 进仓量（成品收回）
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),                        -- STotal（RefreshTotal_PROC 算的成本额）
    amount_local    NUMERIC(18,4),
    check_qty       NUMERIC(18,4),                        -- CQTY 检验数量（委外进仓检验）
    order_qty       NUMERIC(18,4),                        -- OrderQTY 关联订单数量（冗余）
    returned_qty    NUMERIC(18,4) DEFAULT 0,              -- 被成品退回（E_WithDraw 审核回写）
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,                                 -- EWDrawNo 多值降级
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_srcpt_billno     ON subcontract_receipts(bill_no);
CREATE INDEX idx_srcpt_date       ON subcontract_receipts(bill_date);
CREATE INDEX idx_srcpt_supplier   ON subcontract_receipts(supplier_id);
CREATE INDEX idx_srcpt_warehouse  ON subcontract_receipts(warehouse_id);
CREATE INDEX idx_srcpt_status     ON subcontract_receipts(status);
CREATE INDEX idx_srcpt_legacy     ON subcontract_receipts(legacy_id);
CREATE INDEX idx_sriti_receipt    ON subcontract_receipt_items(receipt_id);
CREATE INDEX idx_sriti_orderitem  ON subcontract_receipt_items(order_item_id);
CREATE INDEX idx_sriti_goods      ON subcontract_receipt_items(goods_id);
CREATE INDEX idx_sriti_date       ON subcontract_receipt_items(bill_date);
CREATE INDEX idx_sriti_legacy     ON subcontract_receipt_items(legacy_id);


-- ====================== 委外材料出仓单（E_SOut，发料 → 库存 type15 dir-1） ======================
-- 关键：发料单无 Price/Total/CurID（材料按成本发出，不是销售）。
-- amount_local 由审核时 Service 按当年当月成本重算（替代老库 RefreshTotal_PROC）。
CREATE TABLE subcontract_material_issues (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- E_SOut.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),       -- VendID（发给哪个委外商）
    warehouse_id    UUID REFERENCES warehouses(id),      -- StockID（发出仓）
    worker_id       UUID,                                -- WorkID 工人（无 FK）
    maker_id        UUID,
    approver_id     UUID,
    deliver_date    DATE,                                -- SendDate
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,             -- 无币种；original=local（本币成本）
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE subcontract_material_issue_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    issue_id        UUID NOT NULL REFERENCES subcontract_material_issues(id) ON DELETE CASCADE,
    order_item_id   UUID REFERENCES subcontract_order_items(id),     -- EOrderID 真FK（关联订货明细）
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),              -- 子件（发料货品）
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,                           -- 发料量（合并 STQTY 实际量）
    price           NUMERIC(18,4),                                    -- 无 Price；空
    amount_original NUMERIC(18,4),                                    -- 空（审核 Service 按成本重算）
    amount_local    NUMERIC(18,4),                                    -- STotal 成本额
    returned_qty    NUMERIC(18,4) DEFAULT 0,                          -- 已材料退（E_SWithDraw 审核回写）
    wasted_qty      NUMERIC(18,4) DEFAULT 0,                          -- 已损耗（E_SWaste 审核回写 · ★补全老库缺失）
    parent_goods_id UUID REFERENCES goods(id),                        -- MGoodsID 父件货品（反查成品）
    parent_color_id UUID REFERENCES colors(id),                       -- MColorID 父件颜色
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,                                             -- BomItemID/EOrderNo/WDrawNo 多值降级
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_smiss_billno     ON subcontract_material_issues(bill_no);
CREATE INDEX idx_smiss_date       ON subcontract_material_issues(bill_date);
CREATE INDEX idx_smiss_supplier   ON subcontract_material_issues(supplier_id);
CREATE INDEX idx_smiss_warehouse  ON subcontract_material_issues(warehouse_id);
CREATE INDEX idx_smiss_status     ON subcontract_material_issues(status);
CREATE INDEX idx_smiss_legacy     ON subcontract_material_issues(legacy_id);
CREATE INDEX idx_smisi_issue      ON subcontract_material_issue_items(issue_id);
CREATE INDEX idx_smisi_orderitem  ON subcontract_material_issue_items(order_item_id);
CREATE INDEX idx_smisi_goods      ON subcontract_material_issue_items(goods_id);
CREATE INDEX idx_smisi_date       ON subcontract_material_issue_items(bill_date);
CREATE INDEX idx_smisi_legacy     ON subcontract_material_issue_items(legacy_id);


-- ====================== 委外退货单（E_WithDraw，成品退 → 库存 type18 dir-1） ======================
CREATE TABLE subcontract_returns (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- E_WithDraw.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),
    warehouse_id    UUID REFERENCES warehouses(id),
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    tax_rate        NUMERIC(18,4) DEFAULT 0,
    maker_id        UUID,
    approver_id     UUID,
    last_date       DATE,
    ap_posted       BOOLEAN NOT NULL DEFAULT FALSE,      -- 应付反向立帐标志（审核→reverseArAp 或 postArAp 负向；契约 §四）
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE subcontract_return_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    return_id       UUID NOT NULL REFERENCES subcontract_returns(id) ON DELETE CASCADE,
    receipt_item_id UUID REFERENCES subcontract_receipt_items(id),   -- InID 真FK（关联进仓明细）
    order_item_id   UUID REFERENCES subcontract_order_items(id),     -- OrderID 真FK（同时冲订货）
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,                -- 退货量（成品退）
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),                         -- STotal
    amount_local    NUMERIC(18,4),
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,                                  -- InNo/OrderNo 多值降级
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_sret_billno      ON subcontract_returns(bill_no);
CREATE INDEX idx_sret_date        ON subcontract_returns(bill_date);
CREATE INDEX idx_sret_supplier    ON subcontract_returns(supplier_id);
CREATE INDEX idx_sret_warehouse   ON subcontract_returns(warehouse_id);
CREATE INDEX idx_sret_status      ON subcontract_returns(status);
CREATE INDEX idx_sret_legacy      ON subcontract_returns(legacy_id);
CREATE INDEX idx_srti_return      ON subcontract_return_items(return_id);
CREATE INDEX idx_srti_receiptitem ON subcontract_return_items(receipt_item_id);
CREATE INDEX idx_srti_orderitem   ON subcontract_return_items(order_item_id);
CREATE INDEX idx_srti_goods       ON subcontract_return_items(goods_id);
CREATE INDEX idx_srti_date        ON subcontract_return_items(bill_date);
CREATE INDEX idx_srti_legacy      ON subcontract_return_items(legacy_id);


-- ====================== 委外材料退货单（E_SWithDraw，材料退 → 库存 type16 dir+1） ======================
CREATE TABLE subcontract_material_returns (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- E_SWithDraw.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),
    warehouse_id    UUID REFERENCES warehouses(id),
    worker_id       UUID,                                -- WorkID（无 FK）
    maker_id        UUID,
    approver_id     UUID,
    b_style         INT,                                 -- BStyle（老库字段，含义模糊，照搬）
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,             -- 无币种；original=local
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE subcontract_material_return_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    material_return_id  UUID NOT NULL REFERENCES subcontract_material_returns(id) ON DELETE CASCADE,
    material_issue_item_id UUID REFERENCES subcontract_material_issue_items(id),  -- EOutID 真FK（关联发料明细）
    order_item_id   UUID REFERENCES subcontract_order_items(id),                  -- EOrderID 真FK（关联订货明细）
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,                -- 材料退回量
    price           NUMERIC(18,4),                         -- 无；空
    amount_original NUMERIC(18,4),
    amount_local    NUMERIC(18,4),                         -- STotal
    parent_goods_id UUID REFERENCES goods(id),             -- MGoodsID 父件
    parent_color_id UUID REFERENCES colors(id),
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,                                  -- EOutNo/SWasteNo 多值降级
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_smret_billno      ON subcontract_material_returns(bill_no);
CREATE INDEX idx_smret_date        ON subcontract_material_returns(bill_date);
CREATE INDEX idx_smret_supplier    ON subcontract_material_returns(supplier_id);
CREATE INDEX idx_smret_warehouse   ON subcontract_material_returns(warehouse_id);
CREATE INDEX idx_smret_status      ON subcontract_material_returns(status);
CREATE INDEX idx_smret_legacy      ON subcontract_material_returns(legacy_id);
CREATE INDEX idx_smri_materialreturn    ON subcontract_material_return_items(material_return_id);
CREATE INDEX idx_smri_issueitem         ON subcontract_material_return_items(material_issue_item_id);
CREATE INDEX idx_smri_orderitem         ON subcontract_material_return_items(order_item_id);
CREATE INDEX idx_smri_goods             ON subcontract_material_return_items(goods_id);
CREATE INDEX idx_smri_date              ON subcontract_material_return_items(bill_date);
CREATE INDEX idx_smri_legacy            ON subcontract_material_return_items(legacy_id);


-- ====================== 委外材料损耗单（E_SWaste，3 行，损耗 → 库存 type19 dir-1） ======================
-- 特有：损耗率 waste_rate、损耗原因 cause、期末量 ending_qty、标准应损量 standard_qty。
CREATE TABLE subcontract_wastes (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- E_SWaste.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),
    warehouse_id    UUID REFERENCES warehouses(id),
    worker_id       UUID,                                -- WorkerID（无 FK）
    maker_id        UUID,
    approver_id     UUID,
    total_weight    NUMERIC(18,4),                       -- Weight 主表汇总
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,             -- 无币种
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE subcontract_waste_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    waste_id        UUID NOT NULL REFERENCES subcontract_wastes(id) ON DELETE CASCADE,
    material_issue_item_id UUID REFERENCES subcontract_material_issue_items(id),  -- OutID 真FK（★补全老库未回写链路）
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,                -- 实际损耗量
    ending_qty      NUMERIC(18,4),                         -- FQTY 期末数量（损耗基准量）
    standard_qty    NUMERIC(18,4),                         -- OQTY 标准/应损量（与 ending_qty 反向算盈亏）
    waste_rate      NUMERIC(8,4),                          -- WRate 损耗率(%)
    cause           TEXT,                                  -- Cause 损耗原因
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),
    amount_local    NUMERIC(18,4),
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,                                  -- OutNo/WDrawNo 多值降级
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_swst_billno      ON subcontract_wastes(bill_no);
CREATE INDEX idx_swst_date        ON subcontract_wastes(bill_date);
CREATE INDEX idx_swst_supplier    ON subcontract_wastes(supplier_id);
CREATE INDEX idx_swst_warehouse   ON subcontract_wastes(warehouse_id);
CREATE INDEX idx_swst_status      ON subcontract_wastes(status);
CREATE INDEX idx_swst_legacy      ON subcontract_wastes(legacy_id);
CREATE INDEX idx_swsti_waste      ON subcontract_waste_items(waste_id);
CREATE INDEX idx_swsti_issueitem  ON subcontract_waste_items(material_issue_item_id);
CREATE INDEX idx_swsti_goods      ON subcontract_waste_items(goods_id);
CREATE INDEX idx_swsti_date       ON subcontract_waste_items(bill_date);
CREATE INDEX idx_swsti_legacy     ON subcontract_waste_items(legacy_id);


-- ====================== 注释 ======================
COMMENT ON TABLE subcontract_inquiries            IS '委外询价单主表（委外管理），源 E_Ask（0 行·建结构保未来）';
COMMENT ON TABLE subcontract_inquiry_items        IS '委外询价明细，源 E_AskItem';
COMMENT ON TABLE subcontract_applications         IS '委外申请单主表（委外管理），源 E_Application（0 行·建结构）';
COMMENT ON TABLE subcontract_application_items    IS '委外申请明细，源 E_ApplicationItem；ordered_qty 已订量(订货审核回写)';
COMMENT ON TABLE subcontract_orders               IS '委外订货单主表（委外管理），源 E_Order（2 行）；带 BOM 展开成本子表';
COMMENT ON TABLE subcontract_order_items          IS '委外订货明细，源 E_OrderItem；received/returned/issued/material_returned_qty 由 Service 回写';
COMMENT ON TABLE subcontract_order_cost_items     IS '委外订货 BOM 展开成本子表，源 E_OrderCostItem（67 行）；parent_cost_item_id 自关联表达层级；waste_allowance 规则化老库 +0.46；本期保结构后置展开';
COMMENT ON TABLE subcontract_receipts             IS '委外进仓单主表（委外管理），源 E_In；审核→库存 type17 dir+1 正向入库(不照搬老库 QTY-= 反向)；ap_posted 跟踪应付立帐';
COMMENT ON TABLE subcontract_receipt_items        IS '委外进仓明细，源 E_InItem；order_item_id→订货明细(InID/OrderID)';
COMMENT ON TABLE subcontract_material_issues      IS '委外材料出仓单主表，源 E_SOut；审核→库存 type15 dir-1；无币种无 Price(材料按成本)';
COMMENT ON TABLE subcontract_material_issue_items IS '委外发料明细，源 E_SOutItem；order_item_id→订货明细(EOrderID)；wasted_qty 由损耗审核回写(补全老库)';
COMMENT ON TABLE subcontract_returns              IS '委外退货单主表(成品退)，源 E_WithDraw；审核→库存 type18 dir-1';
COMMENT ON TABLE subcontract_return_items         IS '委外退货明细，源 E_WithDrawItem；receipt_item_id→进仓明细(InID)、order_item_id→订货明细(OrderID)';
COMMENT ON TABLE subcontract_material_returns     IS '委外材料退货单主表，源 E_SWithDraw；审核→库存 type16 dir+1';
COMMENT ON TABLE subcontract_material_return_items IS '委外材料退明细，源 E_SWithDrawItem；material_issue_item_id→发料明细(EOutID)、order_item_id→订货明细(EOrderID)';
COMMENT ON TABLE subcontract_wastes               IS '委外材料损耗单主表，源 E_SWaste(3 行)；审核→库存 type19 dir-1；特有 waste_rate/cause/total_weight';
COMMENT ON TABLE subcontract_waste_items          IS '委外损耗明细，源 E_SWasteItem；material_issue_item_id→发料明细(OutID,★补全回写)；含 ending/standard/waste_rate/cause';


-- ====================== 权限点（契约 §五：双 category，委外管理 300-379 / 委外报表 380-399） ======================
-- 委外单据 view 全员可查（内部业务数据）；edit 归综合营销部 DEPT_SALES；报表 view 全员。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    -- 委外管理（300-379，8 单据 view+edit）
    ('subcontract_inquiry:view',        '查看委外询价',     '委外管理', 300),
    ('subcontract_inquiry:edit',        '维护委外询价',     '委外管理', 301),
    ('subcontract_application:view',    '查看委外申请',     '委外管理', 310),
    ('subcontract_application:edit',    '维护委外申请',     '委外管理', 311),
    ('subcontract_order:view',          '查看委外订货',     '委外管理', 320),
    ('subcontract_order:edit',          '维护委外订货',     '委外管理', 321),
    ('subcontract_receipt:view',        '查看委外进仓',     '委外管理', 330),
    ('subcontract_receipt:edit',        '维护委外进仓',     '委外管理', 331),
    ('subcontract_material_issue:view', '查看委外材料出仓', '委外管理', 340),
    ('subcontract_material_issue:edit', '维护委外材料出仓', '委外管理', 341),
    ('subcontract_return:view',         '查看委外退货',     '委外管理', 350),
    ('subcontract_return:edit',         '维护委外退货',     '委外管理', 351),
    ('subcontract_material_return:view','查看委外材料退货', '委外管理', 360),
    ('subcontract_material_return:edit','维护委外材料退货', '委外管理', 361),
    ('subcontract_waste:view',          '查看委外材料损耗', '委外管理', 370),
    ('subcontract_waste:edit',          '维护委外材料损耗', '委外管理', 371),
    -- 委外报表（380-399）
    ('subcontract_report:view',         '查看委外报表',     '委外报表', 380)
ON CONFLICT (code) DO NOTHING;

-- ① view 给所有部门（委外单据/报表内部可见）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code IN ('subcontract_inquiry:view','subcontract_application:view','subcontract_order:view',
                 'subcontract_receipt:view','subcontract_material_issue:view','subcontract_return:view',
                 'subcontract_material_return:view','subcontract_waste:view','subcontract_report:view')
  AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- ② edit 给综合营销部 DEPT_SALES（委外操作归综合营销；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_SALES'
  AND p.code IN ('subcontract_inquiry:edit','subcontract_application:edit','subcontract_order:edit',
                 'subcontract_receipt:edit','subcontract_material_issue:edit','subcontract_return:edit',
                 'subcontract_material_return:edit','subcontract_waste:edit')
ON CONFLICT DO NOTHING;
