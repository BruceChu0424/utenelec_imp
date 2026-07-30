-- =====================================================================
-- V51：销售五单据主从表（销售管理）
-- =====================================================================
-- 链路：报价 sales_quotes → 订货 sales_orders → 出货 sales_shipments → 退货 sales_returns
--       （独立分支：其它出货 sales_other_shipments，不挂订单、不立应收）
--   各带 *_items 明细；sales_orders 另带 sales_order_cost_items（BOM 展开子表）。
--
-- 链路真外键骨干（取代老库 varchar 逗号串 + f_split 游标回写；dump biz_fkeys.txt 验证）：
--   出货明细.order_item_id  → 订货明细   （S_OutItem.OrderID       → S_OrderItem）
--   退货明细.out_item_id    → 出货明细   （S_WithdrawItem.OutID     → S_OutItem）
--   退货明细.order_item_id  → 订货明细   （S_WithdrawItem.OrderID   → S_OrderItem）
--   BOM 子表.order_item_id  → 订货明细   （S_OrderCostItem.BillID   → S_OrderItem，dump 确认指向明细而非主表）
--   其它出货明细.order_item_id 留 FK 字段但业务上不强制挂单（老库触发器 UPDATE 段已注释，孤儿 ID）
--
-- 状态机：status 0=草稿 / 1=已审 / -1=红冲（贴老库"保存即生效"）；is_closed 结案（Service 派生）；
--        is_stopped（销售订单）业务独立位（贴老库 Stop）。
-- 回写量：明细 shipped_qty/returned_qty/flag_qty 由单据审核 Service 回写（取代老库触发器）。
--
-- 库存联动（Service 层，复用 V45 stock_movements 骨架；契约 doc 27 §三）：
--   sales_shipments       审核 → type 3  dir -1（销售出库）
--   sales_returns         审核 → type 4  dir +1（销售退货，入库）
--   sales_other_shipments 审核 → type 20 dir -1（销售其它出库，不挂订单不立应收）
--
-- 应收联动（委托钱流 Service，契约 doc 27 §四；本 DDL 不 FK ar_ap_ledger）：
--   sales_shipments.ar_posted → Service 调 postArAp(direction=AR, source_doc_type=SALES_SHIPMENT, BStyle=3,  正应收) 置 true
--   sales_returns.ar_posted   → Service 调 postArAp(direction=AR, source_doc_type=SALES_RETURN,     BStyle=18, 红字负应收) 置 true
--   sales_other_shipments 不加 ar_posted（不立应收，老库 TRI_OCStockItem 对应段已注释）
--   反审先校验 ar_ap_ledger.amount_settled=0，否则抛"此单已经存在收款，请先反审收款单!"（与老库 RAISERROR 同文案）
--
-- 明细冗余 bill_no/bill_date：查询裁剪 + 报表（免 JOIN 主表取日期），建索引。
-- 人员 *_id（maker/approver/seller/sender）：UUID，暂无 FK（employees 与老库 B_Worker/Sys_Operator 无 legacy_id 对齐，迁移留空）。
-- 多值溯源（InNo/OutNo/SOrderNo/PlanNo/BomItemID/SWDrawNo 等）→ 前缀化合并 source_doc_no TEXT（保留类型前缀便于未来回填真 FK）。
-- payment_style_id 留 INT 占位（待 V50 payment_styles 主档建后改 UUID REFERENCES）。
--
-- 性能：明细单表 + 强索引（出货约 9 万行、订货约 8 万行，百万级内单表 + B-tree 毫秒级；本期不分区，
--       未来千万级可按 bill_date 在线转分区，与 V44 采购明细同策略）。汇总走 V52 物化视图。
-- 详见 docs/数据迁移/20-销售管理-新库与迁移.md；DDL 一致性契约 docs/数据迁移/27-DDL一致性契约.md。
-- =====================================================================

-- ====================== 销售报价单（空结构，未启用） ======================
CREATE TABLE sales_quotes (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- S_Quote.ID（老库 0 行）
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    client_id       UUID REFERENCES clients(id),         -- ClientID
    maker_id        UUID,                                -- MakeID（人员，无 FK）
    approver_id     UUID,                                -- ApproverID
    valid_until     DATE,                                -- 报价有效期（老库无显式列，按 Stop 推断）
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,         -- 0草稿/1已审/-1红冲
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE sales_quote_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    quote_id        UUID NOT NULL REFERENCES sales_quotes(id) ON DELETE CASCADE,
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,             -- URate
    qty             NUMERIC(18,4) NOT NULL,
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),
    amount_local    NUMERIC(18,4),
    weight          NUMERIC(18,4),
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_sq_billno  ON sales_quotes(bill_no);
CREATE INDEX idx_sq_date    ON sales_quotes(bill_date);
CREATE INDEX idx_sq_status  ON sales_quotes(status);
CREATE INDEX idx_sq_legacy  ON sales_quotes(legacy_id);
CREATE INDEX idx_sqi_quote  ON sales_quote_items(quote_id);
CREATE INDEX idx_sqi_goods  ON sales_quote_items(goods_id);
CREATE INDEX idx_sqi_date   ON sales_quote_items(bill_date);
CREATE INDEX idx_sqi_legacy ON sales_quote_items(legacy_id);

-- ====================== 销售订货单 ======================
CREATE TABLE sales_orders (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- S_Order.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    client_id       UUID NOT NULL REFERENCES clients(id),-- ClientID（必填）
    currency_id     UUID REFERENCES currencies(id),      -- CurID
    exchange_rate   NUMERIC(18,6) DEFAULT 1,             -- CRate
    tax_rate        NUMERIC(18,4) DEFAULT 0,             -- TRate
    payment_style_id INT,                                -- PStyle → payment_styles（V50 建，留 INT 占位待 FK）
    seller_id       UUID,                                -- SellerID 业务员（B_Worker，无 FK）
    maker_id        UUID,                                -- MakeID（Sys_Operator，无 FK）
    approver_id     UUID,                                -- ApproverID（Sys_Operator，无 FK）
    deliver_date    DATE,                                -- SendDate 交货日
    contract_no     TEXT,                                -- ContractNo 合同号
    link_phone      TEXT,                                -- LinkPhone
    sign_addr       TEXT,                                -- SignAddr 签订地址
    ship_addr       TEXT,                                -- SStyle 发货地点（varchar(5000)）
    deposit         NUMERIC(18,4) DEFAULT 0,             -- Deposit 定金
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,             -- Total 原币
    total_local     NUMERIC(18,4) DEFAULT 0,             -- 本币 = 原币×汇率
    status          SMALLINT NOT NULL DEFAULT 0,         -- 0草稿/1已审/-1红冲
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,      -- Fulfill 结案（Service 派生：所有明细 qty-shipped-returned-flag≤0）
    is_stopped      BOOLEAN NOT NULL DEFAULT FALSE,      -- Stop 中止（业务独立位）
    source_doc_no   TEXT,                                -- 多值溯源占位
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE sales_order_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    order_id        UUID NOT NULL REFERENCES sales_orders(id) ON DELETE CASCADE,
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,             -- URate（qty×unit_rate=基本量）
    qty             NUMERIC(18,4) NOT NULL,              -- QTY 订货量（老库 float→numeric）
    price           NUMERIC(18,4),                       -- Price
    amount_original NUMERIC(18,4),                       -- Total 原币
    amount_local    NUMERIC(18,4),                       -- 本币
    shipped_qty     NUMERIC(18,4) DEFAULT 0,             -- RQTY 已发量（出货审核回写，含合单累计）
    returned_qty    NUMERIC(18,4) DEFAULT 0,             -- WQTY 已退量（退货审核回写）
    flag_qty        NUMERIC(18,4) DEFAULT 0,             -- FlagQTY 标记不交付量（结案扣减项，人工维护）
    discount        NUMERIC(18,4) DEFAULT 0,             -- Discount 折扣
    tax_amount      NUMERIC(18,4) DEFAULT 0,             -- TTotal 税额
    weight          NUMERIC(18,4),
    client_no       TEXT,                                -- ClientNo 客户单号（客户 PO）
    client_model    TEXT,                                -- CNumber 客户型号
    deliver_date    DATE,                                -- SendDate 该行交货日
    source_doc_no   TEXT,                                -- InNo/PlanNo/OutNo/SWDrawNo 多值合并文本
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

-- 销售订单的 BOM 展开（老库 718 行，约 93% 订单未展开；结构保未来 MRP）
CREATE TABLE sales_order_cost_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,                       -- 反冗余自 S_Order.BillDate（BOM 无原生日期）
    order_item_id   UUID NOT NULL REFERENCES sales_order_items(id) ON DELETE CASCADE,  -- BillID→明细（老库指向明细，dump biz_fkeys 确认）
    parent_id       UUID REFERENCES sales_order_cost_items(id),    -- ParentID 自挂 BOM 层级
    level           INT  NOT NULL DEFAULT 0,             -- Level（BOM 深度，触发器递归算，最深 30）
    class_code      INT,                                 -- Class（0=父件 / 非 0=子件）
    goods_id        UUID REFERENCES goods(id),           -- GoodsID 子件货品
    color_id        UUID REFERENCES colors(id),          -- ColorID
    alt_goods_id    UUID REFERENCES goods(id),           -- MGoodsID 替代货品
    alt_color_id    UUID REFERENCES colors(id),          -- MColorID
    unit_id         UUID REFERENCES units(id),
    qty             NUMERIC(18,4),                       -- 子件需求量
    order_qty       NUMERIC(18,4) DEFAULT 0,             -- OrderQTY 已订货（采购回写，老库功能未启用）
    received_qty    NUMERIC(18,4) DEFAULT 0,             -- INQTY 已收货
    draw_qty        NUMERIC(18,4) DEFAULT 0,             -- PDrawQTY 已领料
    purge_qty       NUMERIC(18,4) DEFAULT 0,             -- PWDrawQTY 采购退料量
    other_draw_qty  NUMERIC(18,4) DEFAULT 0,             -- OWDrawQTY 其它退料量
    supplier_id     UUID REFERENCES suppliers(id),       -- VendID 子件供应商
    l_status        SMALLINT DEFAULT 0,                  -- LStatus 子件展开状态
    source_doc_no   TEXT,                                -- POrderNo/PDrawNo/PInNo/PWDrawNo/OWDrawNo 多值
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_so_billno      ON sales_orders(bill_no);
CREATE INDEX idx_so_date        ON sales_orders(bill_date);
CREATE INDEX idx_so_client      ON sales_orders(client_id);
CREATE INDEX idx_so_status      ON sales_orders(status);
CREATE INDEX idx_so_closed      ON sales_orders(is_closed);
CREATE INDEX idx_so_legacy      ON sales_orders(legacy_id);
CREATE INDEX idx_soi_order      ON sales_order_items(order_id);
CREATE INDEX idx_soi_goods      ON sales_order_items(goods_id);
CREATE INDEX idx_soi_date       ON sales_order_items(bill_date);
CREATE INDEX idx_soi_legacy     ON sales_order_items(legacy_id);
CREATE INDEX idx_soci_orderitem ON sales_order_cost_items(order_item_id);
CREATE INDEX idx_soci_parent    ON sales_order_cost_items(parent_id);
CREATE INDEX idx_soci_goods     ON sales_order_cost_items(goods_id);
CREATE INDEX idx_soci_legacy    ON sales_order_cost_items(legacy_id);

-- ====================== 销售出货单（S_Out，主流量） ======================
CREATE TABLE sales_shipments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- S_Out.ID
    bill_no         TEXT NOT NULL,                       -- 单号前缀 XC
    bill_date       DATE NOT NULL,
    client_id       UUID NOT NULL REFERENCES clients(id),
    warehouse_id    UUID REFERENCES warehouses(id),      -- StockID 出货仓库
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    tax_rate        NUMERIC(18,4) DEFAULT 0,
    payment_style_id INT,                                -- PStyle
    seller_id       UUID,                                -- SellerID 业务员（无 FK）
    sender_id       UUID,                                -- SenderID 送货人（无 FK）
    maker_id        UUID,
    approver_id     UUID,
    ship_addr       TEXT,                                -- ShipAddr 送货地址 varchar(2550)
    link_phone      TEXT,
    parcel_count    INT,                                 -- PCount 总件数
    print_count     INT  DEFAULT 0,                      -- PrintTable 打印次数
    last_date       TIMESTAMPTZ,                         -- Last_Date 最后操作日（立应收用）
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,                                -- 多值溯源占位
    ar_posted       BOOLEAN NOT NULL DEFAULT FALSE,      -- 应收已立帐标志（Service 审核置 true，反审校验）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE sales_shipment_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    shipment_id     UUID NOT NULL REFERENCES sales_shipments(id) ON DELETE CASCADE,
    order_item_id   UUID REFERENCES sales_order_items(id),       -- OrderID 真FK（关联订货明细，可空=不挂订单的直销行）
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,               -- 出货量
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),                        -- Total 行金额原币
    amount_local    NUMERIC(18,4),
    cost_amount     NUMERIC(18,4),                        -- STotal 成本金额（RefreshTotal_PROC 重算）
    returned_qty    NUMERIC(18,4) DEFAULT 0,              -- WQTY 本出货行的已退量（退货审核回写）
    returned_amount NUMERIC(18,4) DEFAULT 0,              -- SWTotal 已退金额（同上）
    weight          NUMERIC(18,4),
    parcel_qty      NUMERIC(18,4),                        -- KQTY 件数（把/箱）
    carton_count    NUMERIC(18,4),                        -- Boxs 箱数
    client_no       TEXT,                                 -- ClientNo 客户 PO
    client_model    TEXT,                                 -- CNumber 客户型号
    source_doc_no   TEXT,
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_ss_billno     ON sales_shipments(bill_no);
CREATE INDEX idx_ss_date       ON sales_shipments(bill_date);
CREATE INDEX idx_ss_client     ON sales_shipments(client_id);
CREATE INDEX idx_ss_wh         ON sales_shipments(warehouse_id);
CREATE INDEX idx_ss_status     ON sales_shipments(status);
CREATE INDEX idx_ss_arposted   ON sales_shipments(ar_posted);
CREATE INDEX idx_ss_legacy     ON sales_shipments(legacy_id);
CREATE INDEX idx_ssi_shipment  ON sales_shipment_items(shipment_id);
CREATE INDEX idx_ssi_orderitem ON sales_shipment_items(order_item_id);  -- 按订单反查已发量
CREATE INDEX idx_ssi_goods     ON sales_shipment_items(goods_id);
CREATE INDEX idx_ssi_date      ON sales_shipment_items(bill_date);
CREATE INDEX idx_ssi_legacy    ON sales_shipment_items(legacy_id);

-- ====================== 其它出货单（S_OtherOut，不挂订单/不立应收） ======================
CREATE TABLE sales_other_shipments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- S_OtherOut.ID
    bill_no         TEXT NOT NULL,                       -- 单号前缀 OC
    bill_date       DATE NOT NULL,
    client_id       UUID REFERENCES clients(id),         -- ClientID（可空：内部领用无客户）
    warehouse_id    UUID REFERENCES warehouses(id),
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    tax_rate        NUMERIC(18,4) DEFAULT 0,
    payment_style_id INT,
    seller_id       UUID,
    sender_id       UUID,
    maker_id        UUID,
    approver_id     UUID,
    ship_addr       TEXT,
    link_phone      TEXT,
    parcel_count    INT,
    print_count     INT  DEFAULT 0,
    last_date       TIMESTAMPTZ,
    out_type        TEXT,                                -- 用途：样品/赠品/内部领用/损耗…（前端枚举，新库增）
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

CREATE TABLE sales_other_shipment_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    shipment_id     UUID NOT NULL REFERENCES sales_other_shipments(id) ON DELETE CASCADE,
    order_item_id   UUID REFERENCES sales_order_items(id),  -- 字段留位（老库 S_OtherOutItem.OrderID），**新库不强制挂单**，默认空
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),
    amount_local    NUMERIC(18,4),
    cost_amount     NUMERIC(18,4),                       -- STotal
    weight          NUMERIC(18,4),
    parcel_qty      NUMERIC(18,4),
    carton_count    NUMERIC(18,4),
    client_no       TEXT,
    client_model    TEXT,
    source_doc_no   TEXT,
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_sos_billno     ON sales_other_shipments(bill_no);
CREATE INDEX idx_sos_date       ON sales_other_shipments(bill_date);
CREATE INDEX idx_sos_client     ON sales_other_shipments(client_id);
CREATE INDEX idx_sos_wh         ON sales_other_shipments(warehouse_id);
CREATE INDEX idx_sos_status     ON sales_other_shipments(status);
CREATE INDEX idx_sos_legacy     ON sales_other_shipments(legacy_id);
CREATE INDEX idx_sosi_shipment  ON sales_other_shipment_items(shipment_id);
CREATE INDEX idx_sosi_orderitem ON sales_other_shipment_items(order_item_id);
CREATE INDEX idx_sosi_goods     ON sales_other_shipment_items(goods_id);
CREATE INDEX idx_sosi_date      ON sales_other_shipment_items(bill_date);
CREATE INDEX idx_sosi_legacy    ON sales_other_shipment_items(legacy_id);

-- ====================== 销售退货单（S_Withdraw） ======================
CREATE TABLE sales_returns (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- S_Withdraw.ID（单号前缀 XT）
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    client_id       UUID NOT NULL REFERENCES clients(id),
    warehouse_id    UUID REFERENCES warehouses(id),      -- 退货入货仓
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    tax_rate        NUMERIC(18,4) DEFAULT 0,
    payment_style_id INT,
    seller_id       UUID,
    maker_id        UUID,
    approver_id     UUID,
    last_date       TIMESTAMPTZ,
    remark          TEXT,                                -- 老库 Note 字段（M_in.Note 带过去）
    total_original  NUMERIC(18,4) DEFAULT 0,             -- 负数（红字，主表汇总；明细 amount 为正）
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,
    ar_posted       BOOLEAN NOT NULL DEFAULT FALSE,      -- 应收红字已立帐标志
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE sales_return_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    return_id       UUID NOT NULL REFERENCES sales_returns(id) ON DELETE CASCADE,
    out_item_id     UUID REFERENCES sales_shipment_items(id),   -- OutID 真FK（关联出货明细，可空=无来源直销退）
    order_item_id   UUID REFERENCES sales_order_items(id),      -- OrderID 真FK（双挂：同时回写订单已退量）
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,               -- 退货量（正数，金额在主表为负）
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),                        -- 行金额原币（正数；主表汇总时取负）
    amount_local    NUMERIC(18,4),
    cost_amount     NUMERIC(18,4),                        -- STotal（RefreshTotal_PROC 重算）
    weight          NUMERIC(18,4),
    client_no       TEXT,
    client_model    TEXT,
    solution        TEXT,                                 -- qlfa 处理方案（View_S_WithdrawItem 揭示）
    responsible     TEXT,                                 -- zrdw 责任单位
    source_doc_no   TEXT,
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_sr_billno     ON sales_returns(bill_no);
CREATE INDEX idx_sr_date       ON sales_returns(bill_date);
CREATE INDEX idx_sr_client     ON sales_returns(client_id);
CREATE INDEX idx_sr_wh         ON sales_returns(warehouse_id);
CREATE INDEX idx_sr_status     ON sales_returns(status);
CREATE INDEX idx_sr_arposted   ON sales_returns(ar_posted);
CREATE INDEX idx_sr_legacy     ON sales_returns(legacy_id);
CREATE INDEX idx_sri_return    ON sales_return_items(return_id);
CREATE INDEX idx_sri_outitem   ON sales_return_items(out_item_id);
CREATE INDEX idx_sri_orderitem ON sales_return_items(order_item_id);
CREATE INDEX idx_sri_goods     ON sales_return_items(goods_id);
CREATE INDEX idx_sri_date      ON sales_return_items(bill_date);
CREATE INDEX idx_sri_legacy    ON sales_return_items(legacy_id);

-- ====================== 注释 ======================
COMMENT ON TABLE sales_quotes                IS '销售报价单主表（销售管理），源 S_Quote；老库未启用（0行），建结构保未来';
COMMENT ON TABLE sales_quote_items           IS '销售报价明细，源 S_QuoteItem';
COMMENT ON TABLE sales_orders                IS '销售订货单主表（销售管理），源 S_Order；is_closed=所有明细 qty-shipped_qty+returned_qty-flag_qty≤0';
COMMENT ON TABLE sales_order_items           IS '销售订货明细，源 S_OrderItem；shipped_qty 出货回写/returned_qty 退货回写；source_doc_no 收容 InNo/OutNo/PlanNo/SWDrawNo 多值';
COMMENT ON TABLE sales_order_cost_items      IS '销售订单 BOM 展开子表，源 S_OrderCostItem（718行，约93%订单未展开）；parent_id/level 自挂层级；order_item_id→订货明细；MRP 重算后置';
COMMENT ON TABLE sales_shipments             IS '销售出货单主表（销售管理），源 S_Out（主流量 12124 行）；审核→库存出库(type3)+立应收(BStyle3)+回写订单已发量；ar_posted 立帐标志';
COMMENT ON TABLE sales_shipment_items        IS '销售出货明细，源 S_OutItem；order_item_id→订货明细(真FK骨干)；returned_qty 退货回写';
COMMENT ON TABLE sales_other_shipments       IS '其它出货单主表（销售管理），源 S_OtherOut；审核→仅库存出库(type20)，不挂订单不立应收（老库触发器对应段已注释）';
COMMENT ON TABLE sales_other_shipment_items  IS '其它出货明细，源 S_OtherOutItem；order_item_id 字段留位但默认空（业务不强制挂单）';
COMMENT ON TABLE sales_returns               IS '销售退货单主表（销售管理），源 S_Withdraw（221 行）；审核→库存入库(type4)+立红字应收(BStyle18,负数)+回写订单/出货已退量';
COMMENT ON TABLE sales_return_items          IS '销售退货明细，源 S_WithdrawItem；out_item_id→出货明细、order_item_id→订货明细（双挂真FK骨干）';

COMMENT ON COLUMN sales_shipments.ar_posted     IS '应收已立帐标志：Service 调钱流 postArAp(direction=AR, source_doc_type=SALES_SHIPMENT, BStyle=3) 置 true；反审时校验';
COMMENT ON COLUMN sales_returns.ar_posted       IS '应收红字已立帐标志：Service 调钱流 postArAp(direction=AR, source_doc_type=SALES_RETURN, BStyle=18) 置 true';

-- ====================== 权限点 ======================
-- 双 category：销售管理（200-279，单据 view+edit） / 销售报表（280-299，报表 view）。
-- 单据 view 全员可查（内部业务数据）；edit 归综合营销部 DEPT_SALES；报表 view 全员（契约 doc 27 §五）。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('sales_quote:view',         '查看销售报价', '销售管理', 200),
    ('sales_quote:edit',         '维护销售报价', '销售管理', 201),
    ('sales_order:view',         '查看销售订货', '销售管理', 210),
    ('sales_order:edit',         '维护销售订货', '销售管理', 211),
    ('sales_shipment:view',      '查看销售出货', '销售管理', 220),
    ('sales_shipment:edit',      '维护销售出货', '销售管理', 221),
    ('sales_other_shipment:view','查看其它出货', '销售管理', 230),
    ('sales_other_shipment:edit','维护其它出货', '销售管理', 231),
    ('sales_return:view',        '查看销售退货', '销售管理', 240),
    ('sales_return:edit',        '维护销售退货', '销售管理', 241),
    ('sales_report:view',        '查看销售报表', '销售报表', 280)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（销售单据/报表内部可见）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code IN ('sales_quote:view','sales_order:view','sales_shipment:view',
                 'sales_other_shipment:view','sales_return:view','sales_report:view')
  AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给综合营销部（销售操作归 DEPT_SALES；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_SALES'
  AND p.code IN ('sales_quote:edit','sales_order:edit','sales_shipment:edit',
                 'sales_other_shipment:edit','sales_return:edit')
ON CONFLICT DO NOTHING;
