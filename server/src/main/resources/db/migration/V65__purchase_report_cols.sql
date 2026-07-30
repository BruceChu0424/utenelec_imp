-- =====================================================================
-- V65：采购报表所需字段补列（采购管理 / 采购报表）
-- =====================================================================
-- 背景：V44 建表时按"业务零割裂 + 底层重设计"取舍，丢弃了若干老库字段；
--   现补回 9 张采购报表（催料单 + 申请/订货/收货/退货 各明细/汇总）所需的列，
--   全部为可空列，不影响现有 CRUD/审核/库存联动。
--
-- ① 人员 *_legacy_id（applicant/maker/approver/purchaser/sender/receiver）：
--   保留老库 B_Worker.ID，**等员工档案（employees）录入 legacy_id 后自动对齐**。
--   历史单据人名暂时空显示；employees.legacy_id 是融合键（P0-1/P0-2 基础设施）。
-- ② settlement_style_legacy：老库 PStyle（结帐方式原值，无字典，前端按字典常量渲染）。
-- ③ is_stopped：老库 Stop 位（是否中止）。
-- ④ 明细交叉引用文本：生产单号/采购订货单号/销售订货单号/生产计划单号/收货单号/
--   采购回复/摘要/交货日期——老库 varchar 软关联，报表按列展示（保留为文本，不强 FK）。
--
-- 详见 docs/数据迁移/15-采购模块-新库与迁移.md 与计划 noble-exploring-rabbit.md。
-- =====================================================================

-- ---------------- employees：加 legacy_id（与 B_Worker.ID 对齐的融合键） ----------------
ALTER TABLE employees ADD COLUMN IF NOT EXISTS legacy_id INT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_employees_legacy_id ON employees(legacy_id) WHERE legacy_id IS NOT NULL;

-- ---------------- 采购申请单 ----------------
ALTER TABLE purchase_requests
    ADD COLUMN IF NOT EXISTS applicant_legacy_id   INT,
    ADD COLUMN IF NOT EXISTS maker_legacy_id       INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id    INT,
    ADD COLUMN IF NOT EXISTS is_stopped            BOOLEAN NOT NULL DEFAULT FALSE;

-- ---------------- 采购订货单 ----------------
ALTER TABLE purchase_orders
    ADD COLUMN IF NOT EXISTS purchaser_legacy_id     INT,
    ADD COLUMN IF NOT EXISTS maker_legacy_id         INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id      INT,
    ADD COLUMN IF NOT EXISTS settlement_style_legacy SMALLINT,
    ADD COLUMN IF NOT EXISTS is_stopped              BOOLEAN NOT NULL DEFAULT FALSE;

-- ---------------- 采购收货单 ----------------
ALTER TABLE purchase_receipts
    ADD COLUMN IF NOT EXISTS sender_legacy_id        INT,
    ADD COLUMN IF NOT EXISTS receiver_legacy_id      INT,
    ADD COLUMN IF NOT EXISTS maker_legacy_id         INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id      INT,
    ADD COLUMN IF NOT EXISTS settlement_style_legacy SMALLINT;

-- ---------------- 采购退货单 ----------------
ALTER TABLE purchase_returns
    ADD COLUMN IF NOT EXISTS maker_legacy_id         INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id      INT,
    ADD COLUMN IF NOT EXISTS settlement_style_legacy SMALLINT,
    ADD COLUMN IF NOT EXISTS receiver_legacy_id      INT;

-- ---------------- 采购申请明细 ----------------
ALTER TABLE purchase_request_items
    ADD COLUMN IF NOT EXISTS deliver_date        DATE,
    ADD COLUMN IF NOT EXISTS production_no       TEXT,   -- ProduceNo 生产单号
    ADD COLUMN IF NOT EXISTS purchase_order_no   TEXT,   -- POrderNo 采购订货单号
    ADD COLUMN IF NOT EXISTS sales_order_no      TEXT,   -- SOrderNo 销售订货单号
    ADD COLUMN IF NOT EXISTS production_plan_no  TEXT,   -- FPlanNo 生产计划单号
    ADD COLUMN IF NOT EXISTS purchase_reply      TEXT,   -- Pback 采购回复
    ADD COLUMN IF NOT EXISTS summary             TEXT;   -- Summary 摘要

-- ---------------- 采购订货明细（deliver_date 已有） ----------------
ALTER TABLE purchase_order_items
    ADD COLUMN IF NOT EXISTS sales_order_no      TEXT,   -- SOrderNo
    ADD COLUMN IF NOT EXISTS receipt_no          TEXT,   -- PInNo 收货单号
    ADD COLUMN IF NOT EXISTS production_plan_no  TEXT;   -- FPlanNo

-- ---------------- 采购收货明细 ----------------
ALTER TABLE purchase_receipt_items
    ADD COLUMN IF NOT EXISTS order_no            TEXT,   -- OrderNo 订货单号
    ADD COLUMN IF NOT EXISTS sales_order_no      TEXT,   -- SOrderNo
    ADD COLUMN IF NOT EXISTS production_plan_no  TEXT;   -- FPlanNo

-- ---------------- 采购退货明细 ----------------
ALTER TABLE purchase_return_items
    ADD COLUMN IF NOT EXISTS receipt_no          TEXT,   -- InNo 收货单号
    ADD COLUMN IF NOT EXISTS sales_order_no      TEXT,   -- SOrderNo
    ADD COLUMN IF NOT EXISTS production_plan_no  TEXT,   -- FPlanNo
    ADD COLUMN IF NOT EXISTS order_no            TEXT;   -- OrderNo 订货单号

-- ---------------- 报表过滤辅助索引（低基数列 facet 筛选） ----------------
CREATE INDEX IF NOT EXISTS idx_po_settlement  ON purchase_orders(settlement_style_legacy);
CREATE INDEX IF NOT EXISTS idx_pcrt_settle    ON purchase_receipts(settlement_style_legacy);
CREATE INDEX IF NOT EXISTS idx_pret_settle    ON purchase_returns(settlement_style_legacy);
CREATE INDEX IF NOT EXISTS idx_po_stopped     ON purchase_orders(is_stopped);
CREATE INDEX IF NOT EXISTS idx_pr_stopped     ON purchase_requests(is_stopped);
