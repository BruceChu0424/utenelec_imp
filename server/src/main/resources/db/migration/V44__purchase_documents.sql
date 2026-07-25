-- =====================================================================
-- V44：采购四单据主从表（采购管理）
-- =====================================================================
-- 链路：申请 purchase_requests → 订货 purchase_orders → 收货 purchase_receipts → 退货 purchase_returns
--   （各带 *_items 明细）。
--
-- 链路真外键骨干（取代老库 varchar 逗号串 + f_split 游标回写）：
--   订货明细.request_item_id  → 申请明细
--   收货明细.order_item_id    → 订货明细
--   退货明细.receipt_item_id  → 收货明细
--   退货明细.order_item_id    → 订货明细
--
-- 状态机：status 0=草稿 / 1=已审 / -1=红冲（贴老库"保存即生效"）；is_closed 结案（Service 派生）。
-- 回写量：明细 ordered_qty/received_qty/returned_qty 由单据审核时 Service 回写（取代老库触发器）。
-- 明细冗余 bill_no/bill_date：查询裁剪 + 报表（免 JOIN 主表取日期），建索引。
-- 人员 *_id（applicant/purchaser/maker/approver/sender/receiver）：UUID，暂无 FK
--   （employees 与老库 B_Worker 未对齐，迁移留空；新系统录入填当前登录用户）。
-- 销售/生产计划溯源降级为 source_doc_no 文本占位（新库未做，模块上线后补关联表）。
--
-- 性能：明细单表 + 强索引（十几年约 12 万行，百万级内单表 + B-tree 毫秒级；无需分区；
--   未来千万级可按 bill_date 在线转分区）。汇总走 V49 物化视图。
-- 详见 docs/数据迁移/15-采购模块-新库与迁移.md。
-- =====================================================================

-- ====================== 采购申请单 ======================
CREATE TABLE purchase_requests (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- P_Application.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    warehouse_id    UUID REFERENCES warehouses(id),      -- 意向仓库（请购可空）
    applicant_id    UUID,                                -- Applier（人员，无 FK）
    maker_id        UUID,                                -- MakeID
    approver_id     UUID,                                -- ApproverID
    need_date       DATE,                                -- 需求日期
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,             -- 合计（申请阶段本币，原币=本币）
    total_local     NUMERIC(18,4) DEFAULT 0,
    status          SMALLINT NOT NULL DEFAULT 0,         -- 0草稿/1已审/-1红冲
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,      -- 结案（Service 派生）
    source_doc_no   TEXT,                                -- 销售/计划溯源占位
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE purchase_request_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,                       -- 冗余（报表/查询）
    bill_date       DATE NOT NULL,                       -- 冗余（裁剪索引）
    request_id      UUID NOT NULL REFERENCES purchase_requests(id) ON DELETE CASCADE,
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,             -- URate
    qty             NUMERIC(18,4) NOT NULL,              -- QTY 申请量
    price           NUMERIC(18,4),                       -- Price 预估单价
    amount_original NUMERIC(18,4),                       -- Total
    amount_local    NUMERIC(18,4),
    ordered_qty     NUMERIC(18,4) DEFAULT 0,             -- 已订量（订货单审核回写，源 RQTY）
    gift_qty        NUMERIC(18,4) DEFAULT 0,
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_pr_billno   ON purchase_requests(bill_no);
CREATE INDEX idx_pr_date     ON purchase_requests(bill_date);
CREATE INDEX idx_pr_status   ON purchase_requests(status);
CREATE INDEX idx_pr_legacy   ON purchase_requests(legacy_id);
CREATE INDEX idx_pri_request ON purchase_request_items(request_id);
CREATE INDEX idx_pri_goods   ON purchase_request_items(goods_id);
CREATE INDEX idx_pri_date    ON purchase_request_items(bill_date);
CREATE INDEX idx_pri_legacy  ON purchase_request_items(legacy_id);

-- ====================== 采购订货单 ======================
CREATE TABLE purchase_orders (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- P_Order.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),       -- VendID
    warehouse_id    UUID REFERENCES warehouses(id),      -- StockID
    currency_id     UUID REFERENCES currencies(id),      -- CurID
    exchange_rate   NUMERIC(18,6) DEFAULT 1,             -- CRate
    tax_rate        NUMERIC(18,4) DEFAULT 0,             -- TRate
    purchaser_id    UUID,                                -- Purchaser（人员，无 FK）
    maker_id        UUID,                                -- MakeID
    approver_id     UUID,                                -- ApproverID
    deliver_date    DATE,                                -- SendDate 交货日
    remark          TEXT,
    total_original  NUMERIC(18,4) DEFAULT 0,             -- Total 原币
    total_local     NUMERIC(18,4) DEFAULT 0,             -- 本币 = 原币×汇率
    status          SMALLINT NOT NULL DEFAULT 0,
    is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
    source_doc_no   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    UNIQUE (bill_no)
);

CREATE TABLE purchase_order_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    order_id        UUID NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,              -- 订货量
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),
    amount_local    NUMERIC(18,4),
    received_qty    NUMERIC(18,4) DEFAULT 0,             -- 已收（收货审核回写，源 RQTY）
    returned_qty    NUMERIC(18,4) DEFAULT 0,             -- 已退（退货审核回写，源 WQTY）
    gift_qty        NUMERIC(18,4) DEFAULT 0,
    request_item_id UUID REFERENCES purchase_request_items(id),  -- ApplyID 真FK
    deliver_date    DATE,                                -- SendDate
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_po_billno   ON purchase_orders(bill_no);
CREATE INDEX idx_po_date     ON purchase_orders(bill_date);
CREATE INDEX idx_po_supplier ON purchase_orders(supplier_id);
CREATE INDEX idx_po_status   ON purchase_orders(status);
CREATE INDEX idx_po_legacy   ON purchase_orders(legacy_id);
CREATE INDEX idx_poi_order   ON purchase_order_items(order_id);
CREATE INDEX idx_poi_goods   ON purchase_order_items(goods_id);
CREATE INDEX idx_poi_date    ON purchase_order_items(bill_date);
CREATE INDEX idx_poi_reqitem ON purchase_order_items(request_item_id);
CREATE INDEX idx_poi_legacy  ON purchase_order_items(legacy_id);

-- ====================== 采购收货单 ======================
CREATE TABLE purchase_receipts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- P_In.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),       -- VendID（收货必填）
    warehouse_id    UUID REFERENCES warehouses(id),      -- StockID（收货必填）
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    tax_rate        NUMERIC(18,4) DEFAULT 0,
    sender_id       UUID,                                -- SenderID 交货人（无 FK）
    receiver_id     UUID,                                -- Receiver 收货人（无 FK）
    maker_id        UUID,
    approver_id     UUID,
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

CREATE TABLE purchase_receipt_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    receipt_id      UUID NOT NULL REFERENCES purchase_receipts(id) ON DELETE CASCADE,
    order_item_id   UUID REFERENCES purchase_order_items(id),     -- OrderID 真FK（关联订货明细）
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,              -- 收货量（QTY+BPQTY 由 Service 合计入库）
    price           NUMERIC(18,4),
    amount_original NUMERIC(18,4),
    amount_local    NUMERIC(18,4),
    returned_qty    NUMERIC(18,4) DEFAULT 0,             -- 被退货（退货审核回写）
    gift_qty        NUMERIC(18,4) DEFAULT 0,             -- BPQTY 赠品（独立入库）
    weight          NUMERIC(18,4),
    source_doc_no   TEXT,
    remark          TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_pcrt_billno    ON purchase_receipts(bill_no);
CREATE INDEX idx_pcrt_date      ON purchase_receipts(bill_date);
CREATE INDEX idx_pcrt_supplier  ON purchase_receipts(supplier_id);
CREATE INDEX idx_pcrt_warehouse ON purchase_receipts(warehouse_id);
CREATE INDEX idx_pcrt_status    ON purchase_receipts(status);
CREATE INDEX idx_pcrt_legacy    ON purchase_receipts(legacy_id);
CREATE INDEX idx_pcrit_receipt  ON purchase_receipt_items(receipt_id);
CREATE INDEX idx_pcrit_orderitem ON purchase_receipt_items(order_item_id);
CREATE INDEX idx_pcrit_goods    ON purchase_receipt_items(goods_id);
CREATE INDEX idx_pcrit_date     ON purchase_receipt_items(bill_date);
CREATE INDEX idx_pcrit_legacy   ON purchase_receipt_items(legacy_id);

-- ====================== 采购退货单 ======================
CREATE TABLE purchase_returns (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT  UNIQUE,                         -- P_Withdraw.ID
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    supplier_id     UUID REFERENCES suppliers(id),       -- VendID
    warehouse_id    UUID REFERENCES warehouses(id),      -- StockID
    currency_id     UUID REFERENCES currencies(id),
    exchange_rate   NUMERIC(18,6) DEFAULT 1,
    tax_rate        NUMERIC(18,4) DEFAULT 0,
    receiver_id     UUID,                                -- 退货经手人（无 FK）
    maker_id        UUID,
    approver_id     UUID,
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

CREATE TABLE purchase_return_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id       INT,
    bill_no         TEXT NOT NULL,
    bill_date       DATE NOT NULL,
    return_id       UUID NOT NULL REFERENCES purchase_returns(id) ON DELETE CASCADE,
    receipt_item_id UUID REFERENCES purchase_receipt_items(id),   -- InID 真FK（关联收货明细）
    order_item_id   UUID REFERENCES purchase_order_items(id),     -- OrderID 真FK（关联订货明细）
    line_no         INT,
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    unit_id         UUID REFERENCES units(id),
    unit_rate       NUMERIC(18,6) DEFAULT 1,
    qty             NUMERIC(18,4) NOT NULL,              -- 退货量
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

CREATE INDEX idx_pret_billno     ON purchase_returns(bill_no);
CREATE INDEX idx_pret_date       ON purchase_returns(bill_date);
CREATE INDEX idx_pret_supplier   ON purchase_returns(supplier_id);
CREATE INDEX idx_pret_warehouse  ON purchase_returns(warehouse_id);
CREATE INDEX idx_pret_status     ON purchase_returns(status);
CREATE INDEX idx_pret_legacy     ON purchase_returns(legacy_id);
CREATE INDEX idx_preit_return    ON purchase_return_items(return_id);
CREATE INDEX idx_preit_receiptitem ON purchase_return_items(receipt_item_id);
CREATE INDEX idx_preit_orderitem ON purchase_return_items(order_item_id);
CREATE INDEX idx_preit_goods     ON purchase_return_items(goods_id);
CREATE INDEX idx_preit_date      ON purchase_return_items(bill_date);
CREATE INDEX idx_preit_legacy    ON purchase_return_items(legacy_id);

-- ====================== 注释 ======================
COMMENT ON TABLE purchase_requests        IS '采购申请单主表（采购管理），源 P_Application';
COMMENT ON TABLE purchase_request_items   IS '采购申请明细，源 P_ApplicationItem；ordered_qty 已订量(订货审核回写)';
COMMENT ON TABLE purchase_orders          IS '采购订货单主表（采购管理），源 P_Order';
COMMENT ON TABLE purchase_order_items     IS '采购订货明细，源 P_OrderItem；received_qty 已收/returned_qty 已退(Service回写)；request_item_id→申请明细';
COMMENT ON TABLE purchase_receipts        IS '采购收货单主表（采购管理），源 P_In；审核→库存入库';
COMMENT ON TABLE purchase_receipt_items   IS '采购收货明细，源 P_InItem；order_item_id→订货明细；gift_qty=BPQTY赠品';
COMMENT ON TABLE purchase_returns         IS '采购退货单主表（采购管理），源 P_Withdraw；审核→库存出库';
COMMENT ON TABLE purchase_return_items    IS '采购退货明细，源 P_WithdrawItem；receipt_item_id→收货明细、order_item_id→订货明细';

-- ====================== 权限点 ======================
-- 采购单据 view 全员可查（内部业务数据，非敏感）；edit 归 PMC 运营部；报表 view 全员。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('purchase_request:view',  '查看采购申请', '采购管理', 100),
    ('purchase_request:edit',  '维护采购申请', '采购管理', 101),
    ('purchase_order:view',    '查看采购订货', '采购管理', 110),
    ('purchase_order:edit',    '维护采购订货', '采购管理', 111),
    ('purchase_receipt:view',  '查看采购收货', '采购管理', 120),
    ('purchase_receipt:edit',  '维护采购收货', '采购管理', 121),
    ('purchase_return:view',   '查看采购退货', '采购管理', 130),
    ('purchase_return:edit',   '维护采购退货', '采购管理', 131),
    ('purchase_report:view',   '查看采购报表', '采购管理', 140)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（采购单据/报表内部可见）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code IN ('purchase_request:view','purchase_order:view','purchase_receipt:view',
                 'purchase_return:view','purchase_report:view')
  AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- edit 给 PMC 运营部（采购操作归 PMC；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC'
  AND p.code IN ('purchase_request:edit','purchase_order:edit','purchase_receipt:edit','purchase_return:edit')
ON CONFLICT DO NOTHING;
