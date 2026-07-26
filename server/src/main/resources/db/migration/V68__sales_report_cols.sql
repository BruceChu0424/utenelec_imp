-- =====================================================================
-- V66：销售报表所需字段补列（销售管理 / 销售报表）
-- =====================================================================
-- 背景：V51 建表时按"业务零割裂 + 底层重设计"取舍，丢弃了若干老库字段；
--   现补回 8 张销售报表（订货/出货/退货/其它出货 各明细/汇总）所需的列，
--   全部为可空列，不影响现有 CRUD/审核/库存/应收联动。
--   **与 V65（采购报表补列）同型**——人员 *_legacy_id 是 employees.legacy_id 融合键
--   （V65 已为 employees 加 legacy_id，本迁移复用）。
--
-- ① 人员 *_legacy_id（maker/approver/seller/sender）：保留老库
--   · MakeID/ApproverID → Sys_Operator.ID
--   · SellerID/SenderID → B_Worker.ID
--   **等员工档案（employees）录入 legacy_id 后自动对齐**（报表 LEFT JOIN employees
--     ON e.legacy_id = o.*_legacy_id OR e.id = o.*_id）。历史单据人名暂时空显示。
-- ② 成本分项 + 包装派生列（明细）：材料价 SPrice / 压铸价 WPrice / 机加价 JPrice / 围数 KQTY2
--   ——老库 float，新库 numeric(18,4)（精度修正）；报表"材料价/压铸价/机加价/围"按列展示。
--   （采购 V65 决策"围数去列"，**销售保留**——用户销售报表规格明确要"围数/围"。）
-- ③ 进仓数量 inbound_qty（IQTY）：销售订货明细报表要"进仓数量"（仓库 O_ProductIn 回写的历史累计）。
-- ④ 单号分列 in_no / out_no：销售订货明细报表要"成品进仓单号""销售出货单号"分列展示
--   （V51 原把它们合并进 source_doc_no，现拆分便于报表；source_doc_no 保留收容 plan_no/swdraw_no）。
-- ⑤ 结帐方式 payment_style_id（V51 已是 INT 原值）→ 报表按 SalesSettlementStyle 字典渲染，无需新列。
--
-- 详见 docs/数据迁移/20-销售管理-新库与迁移.md 与计划 optimized-strolling-spring.md。
-- =====================================================================

-- ---------------- employees.legacy_id 由 V65 创建，此处不重复（IF NOT EXISTS 兜底，幂等） ----------------
ALTER TABLE employees ADD COLUMN IF NOT EXISTS legacy_id INT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_employees_legacy_id ON employees(legacy_id) WHERE legacy_id IS NOT NULL;

-- ---------------- 销售订货单（主表：人员 legacy_id） ----------------
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS maker_legacy_id    INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id INT,
    ADD COLUMN IF NOT EXISTS seller_legacy_id   INT;

-- ---------------- 销售出货单（主表：人员 legacy_id） ----------------
ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS maker_legacy_id    INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id INT,
    ADD COLUMN IF NOT EXISTS seller_legacy_id   INT,
    ADD COLUMN IF NOT EXISTS sender_legacy_id   INT;

-- ---------------- 其它出货单（主表：人员 legacy_id） ----------------
ALTER TABLE sales_other_shipments
    ADD COLUMN IF NOT EXISTS maker_legacy_id    INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id INT,
    ADD COLUMN IF NOT EXISTS seller_legacy_id   INT,
    ADD COLUMN IF NOT EXISTS sender_legacy_id   INT;

-- ---------------- 销售退货单（主表：人员 legacy_id） ----------------
ALTER TABLE sales_returns
    ADD COLUMN IF NOT EXISTS maker_legacy_id    INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id INT,
    ADD COLUMN IF NOT EXISTS seller_legacy_id   INT;

-- ---------------- 销售订货明细（机加价/围数/进仓数量/成品进仓单号/销售出货单号） ----------------
ALTER TABLE sales_order_items
    ADD COLUMN IF NOT EXISTS machining_price NUMERIC(18,4),   -- JPrice 机加价
    ADD COLUMN IF NOT EXISTS circumference   NUMERIC(18,4),   -- KQTY2 围数
    ADD COLUMN IF NOT EXISTS inbound_qty     NUMERIC(18,4) DEFAULT 0,  -- IQTY 进仓数量（仓库回写累计）
    ADD COLUMN IF NOT EXISTS in_no           TEXT,            -- InNo 成品进仓单号（分列）
    ADD COLUMN IF NOT EXISTS out_no          TEXT;            -- OutNo 销售出货单号（分列）

-- ---------------- 销售出货明细（成本分项 + 围数 + 折扣，老库 S_OutItem 同构） ----------------
ALTER TABLE sales_shipment_items
    ADD COLUMN IF NOT EXISTS material_price  NUMERIC(18,4),   -- SPrice 材料价
    ADD COLUMN IF NOT EXISTS die_cast_price  NUMERIC(18,4),   -- WPrice 压铸价
    ADD COLUMN IF NOT EXISTS machining_price NUMERIC(18,4),   -- JPrice 机加价
    ADD COLUMN IF NOT EXISTS circumference   NUMERIC(18,4),   -- KQTY2 围
    ADD COLUMN IF NOT EXISTS discount        NUMERIC(18,4) DEFAULT 0;   -- Discount 折扣（报表"折扣"+"成交金额"用）

-- ---------------- 其它出货明细（材料价/压铸价/机加价/围/折扣 + 退货量/退货额，与出货明细对称） ----------------
ALTER TABLE sales_other_shipment_items
    ADD COLUMN IF NOT EXISTS material_price    NUMERIC(18,4) DEFAULT 0,  -- SPrice 材料价
    ADD COLUMN IF NOT EXISTS die_cast_price    NUMERIC(18,4) DEFAULT 0,  -- WPrice 压铸价
    ADD COLUMN IF NOT EXISTS machining_price   NUMERIC(18,4) DEFAULT 0,  -- JPrice 机加价
    ADD COLUMN IF NOT EXISTS circumference     NUMERIC(18,4),            -- KQTY2 围
    ADD COLUMN IF NOT EXISTS discount          NUMERIC(18,4) DEFAULT 0,  -- Discount 折扣
    ADD COLUMN IF NOT EXISTS returned_qty      NUMERIC(18,4) DEFAULT 0,  -- WQTY 已退量（老库 S_OtherOutItem.WQTY，基本为0——S_Withdraw 不挂其它出货）
    ADD COLUMN IF NOT EXISTS returned_amount   NUMERIC(18,4) DEFAULT 0;  -- SWTotal 已退金额

-- ---------------- 销售退货明细（折扣，报表"折扣"+"成交金额"用） ----------------
ALTER TABLE sales_return_items
    ADD COLUMN IF NOT EXISTS discount NUMERIC(18,4) DEFAULT 0;   -- Discount 折扣（老库 S_WithdrawItem.Discount）

-- ---------------- 报表过滤辅助索引（低基数列 facet 筛选；已存在则跳过） ----------------
CREATE INDEX IF NOT EXISTS idx_so_pstyle     ON sales_orders(payment_style_id);
CREATE INDEX IF NOT EXISTS idx_ss_pstyle     ON sales_shipments(payment_style_id);
CREATE INDEX IF NOT EXISTS idx_sos_pstyle    ON sales_other_shipments(payment_style_id);
CREATE INDEX IF NOT EXISTS idx_sr_pstyle     ON sales_returns(payment_style_id);
CREATE INDEX IF NOT EXISTS idx_so_seller     ON sales_orders(seller_legacy_id);
CREATE INDEX IF NOT EXISTS idx_ss_sender     ON sales_shipments(sender_legacy_id);
CREATE INDEX IF NOT EXISTS idx_sosi_goods    ON sales_other_shipment_items(goods_id);

-- ---------------- 客户总监派生视图（报表"总监"列：客户所属分类上溯到 level=0 根的 name） ----------------
-- client_categories 层级：level=0 根 = 销售总监分管段（外贸（钟）/外贸（苏）/北区（芳）…括号内负责人姓）。
-- 客户的直属分类 = 单类；其 level=0 祖先 = 总监。递归 CTE 预算每客户 → 总监名，报表 LEFT JOIN 即取。
CREATE OR REPLACE VIEW client_director_v AS
WITH RECURSIVE chain AS (
    SELECT cc.id AS cat_id, cc.parent_id, cc.level, cc.name
    FROM client_categories cc
    WHERE COALESCE(cc.is_deleted, false) = false
    UNION ALL
    SELECT c.cat_id, p.parent_id, p.level, p.name
    FROM chain c JOIN client_categories p ON p.id = c.parent_id
    WHERE COALESCE(p.is_deleted, false) = false
)
SELECT cl.id AS client_id,
       (SELECT root.name FROM chain root
         WHERE root.cat_id = cl.category_id AND root.level = 0
         ORDER BY root.cat_id LIMIT 1) AS director
FROM clients cl;
COMMENT ON VIEW client_director_v IS '客户→总监派生（client_categories 上溯 level=0 根 name）；销售报表"总监"列数据源';

-- ---------------- 列注释 ----------------
COMMENT ON COLUMN sales_order_items.machining_price IS '机加价 JPrice（老库 float→numeric）；销售订货明细报表用';
COMMENT ON COLUMN sales_order_items.circumference   IS '围数 KQTY2（老库 float→numeric，包装尺寸派生）';
COMMENT ON COLUMN sales_order_items.inbound_qty     IS '进仓数量 IQTY（仓库 O_ProductIn 回写的历史累计；新库只留量，不再回写）';
COMMENT ON COLUMN sales_order_items.in_no           IS '成品进仓单号 InNo（分列，报表用）；老库多值空格分隔，迁移取原值';
COMMENT ON COLUMN sales_order_items.out_no          IS '销售出货单号 OutNo（分列，报表用）；老库多值空格分隔，迁移取原值';
COMMENT ON COLUMN sales_shipment_items.material_price  IS '材料价 SPrice（成本分项，老库 float→numeric）';
COMMENT ON COLUMN sales_shipment_items.die_cast_price  IS '压铸价 WPrice（成本分项）';
COMMENT ON COLUMN sales_shipment_items.machining_price IS '机加价 JPrice（成本分项）';
COMMENT ON COLUMN sales_shipment_items.circumference   IS '围数 KQTY2（包装派生）';
COMMENT ON COLUMN sales_other_shipment_items.material_price  IS '材料价 SPrice（其它出货明细报表要）';
COMMENT ON COLUMN sales_other_shipment_items.die_cast_price  IS '压铸价 WPrice';
COMMENT ON COLUMN sales_other_shipment_items.machining_price IS '机加价 JPrice';
COMMENT ON COLUMN sales_other_shipment_items.circumference   IS '围数 KQTY2（报表"围"）';
COMMENT ON COLUMN sales_orders.maker_legacy_id    IS '制单 MakeID→Sys_Operator.ID（待 employees.legacy_id 对齐回填 maker_id）';
COMMENT ON COLUMN sales_orders.approver_legacy_id IS '审批 ApproverID→Sys_Operator.ID（待回填 approver_id）';
COMMENT ON COLUMN sales_orders.seller_legacy_id   IS '业务员 SellerID→B_Worker.ID（待回填 seller_id）';
COMMENT ON COLUMN sales_shipments.sender_legacy_id  IS '送货人 SenderID→B_Worker.ID（待回填 sender_id）';
COMMENT ON COLUMN sales_other_shipments.sender_legacy_id IS '送货人 SenderID→B_Worker.ID';
