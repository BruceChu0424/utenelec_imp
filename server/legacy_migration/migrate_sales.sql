-- =====================================================================
-- 销售五单据迁移：CSV -> sales_quotes/orders/shipments/other_shipments/returns + *_items + cost_items
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --sales
-- 前提：V51 已建表；goods/colors/units/warehouses/currencies/clients 主档已迁。
-- 顺序：报价 -> 订货(+BOM) -> 出货 -> 其它出货 -> 退货（链路真 FK：
--   出货明细.order_item_id   -> 订货明细（S_OutItem.OrderID        -> S_OrderItem）
--   退货明细.out_item_id     -> 出货明细（S_WithdrawItem.OutID      -> S_OutItem）
--   退货明细.order_item_id   -> 订货明细（S_WithdrawItem.OrderID    -> S_OrderItem）
--   BOM 子表.order_item_id   -> 订货明细（S_OrderCostItem.BillID    -> S_OrderItem，dump biz_fkeys 已确认）
--   其它出货明细.order_item_id 业务上不挂单（老库触发器 UPDATE 段已注释），留 NULL。
--   四条真 FK 均按 legacy_id 子查询映射到新 UUID；0/null -> NULL。
-- 幂等：开头一次性 TRUNCATE 11 张销售表（被引用关系，须一起清），重跑安全。
-- 缺失基础资料自动补录（units/colors/warehouses/currencies/goods/clients，LEGACY- 前缀 + auto_created）。
-- 人员字段（maker/approver/seller/sender）：*_id(UUID) 留 NULL，**保留 *_legacy_id(INT)** 源老库
--   Sys_Operator/B_Worker ID。等员工档案录 employees.legacy_id 后，报表 LEFT JOIN 自动出人名（V66 + V65）。
-- status：老库 1->1（已审）、-1->-1（红冲），直接照搬（老库无 0 草稿态）。
-- 金额 float->numeric(18,4)；多币种：total_local = total_original * exchange_rate。
-- 多值溯源：订货明细 InNo/OutNo **分列**（成品进仓单号/销售出货单号，报表要），plan_no/swdraw_no 入 source_doc_no；
--   出货/其它/退货明细的 order_no/swdraw_no/out_no/sorder_no 仍 CONCAT 进 source_doc_no。
-- 成本分项（材料价/压铸价/机加价/围数）+ 进仓数量：V66 新列，订货/出货/其它出货明细原值迁入（numeric 修正 float）。
-- BOM 718 行：先 INSERT 全量 parent_id=NULL，再 UPDATE 自挂 parent_id（避免 FK 顺序依赖）。
-- 库存历史不在此迁（stock_movements 归库存模块）；应收不在此迁（ar_ap_ledger 归钱流，从 M_in 迁）。
-- 迁末刷新 sales_monthly_mv（汇总报表数据源，否则汇总报表空）。
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
TRUNCATE sales_return_items, sales_returns,
         sales_other_shipment_items, sales_other_shipments,
         sales_shipment_items, sales_shipments,
         sales_order_cost_items, sales_order_items, sales_orders,
         sales_quote_items, sales_quotes;
SET session_replication_role = DEFAULT;

-- ---------------- staging（11 张，列序与 export_sales_snippet.ps1 逐字对齐） ----------------
-- S_Quote / S_QuoteItem（老库 0 行，建 staging 保结构）
CREATE TEMP TABLE quote_stage (
    legacy_id int, bill_no text, bill_date date, client_legacy int, maker_legacy int, approver_legacy int,
    stop_bit boolean, remark text, total_original numeric(18,4), status smallint, status2 int);
\copy quote_stage FROM '/tmp/sales_quotes.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE quote_item_stage (
    legacy_id int, bill_legacy int, goods_legacy int, color_legacy int, unit_legacy int,
    unit_rate numeric(18,6), qty numeric(18,4), price numeric(18,4), sprice numeric(18,4), remark text);
\copy quote_item_stage FROM '/tmp/sales_quote_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- S_Order / S_OrderItem / S_OrderCostItem
CREATE TEMP TABLE order_stage (
    legacy_id int, bill_no text, bill_date date, client_legacy int, deliver_date date, link_phone text,
    sign_addr text, contract_no text, seller_legacy int, p_style int, maker_legacy int, approver_legacy int,
    remark text, total_original numeric(18,4), status smallint, fulfill_bit boolean, stop_bit boolean,
    ship_addr text, deposit numeric(18,4), cur_legacy int, tax_rate numeric(18,4),
    exchange_rate numeric(18,6), cancel_bit boolean, client_no text);
\copy order_stage FROM '/tmp/sales_orders.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE order_item_stage (
    legacy_id int, bill_legacy int, goods_legacy int, color_legacy int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), shipped_qty numeric(18,4),
    returned_qty numeric(18,4), flag_qty numeric(18,4), discount numeric(18,4), tax_amount numeric(18,4),
    unit_legacy int, unit_rate numeric(18,6), weight numeric(18,4), client_no text, client_model text,
    in_no text, plan_no text, out_no text, swdraw_no text, remark text,
    inbound_qty numeric(18,4), circumference numeric(18,4), material_price numeric(18,4),
    die_cast_price numeric(18,4), machining_price numeric(18,4));
\copy order_item_stage FROM '/tmp/sales_order_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE order_cost_stage (
    legacy_id int, bill_legacy int, parent_legacy int, level int, class_code int, goods_legacy int,
    color_legacy int, alt_goods_legacy int, alt_color_legacy int, qty numeric(18,4), price numeric(18,4),
    amount_original numeric(18,4), order_qty numeric(18,4), received_qty numeric(18,4),
    draw_qty numeric(18,4), purge_qty numeric(18,4), other_draw_qty numeric(18,4), supplier_legacy int,
    l_status smallint, porder_no text, pdraw_no text, pin_no text, pwdraw_no text, owdraw_no text, remark text);
\copy order_cost_stage FROM '/tmp/sales_order_cost_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- S_Out / S_OutItem（主流量）
CREATE TEMP TABLE ship_stage (
    legacy_id int, bill_no text, bill_date date, client_legacy int, warehouse_legacy int, link_phone text,
    p_count int, sender_legacy int, ship_addr text, p_style int, maker_legacy int, approver_legacy int,
    remark text, total_original numeric(18,4), status smallint, print_count int, last_date timestamptz,
    tax_rate numeric(18,4), cur_legacy int, exchange_rate numeric(18,6), seller_legacy int, cancel_bit boolean);
\copy ship_stage FROM '/tmp/sales_shipments.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE ship_item_stage (
    legacy_id int, bill_legacy int, goods_legacy int, color_legacy int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), order_item_legacy int, cost_amount numeric(18,4),
    returned_qty numeric(18,4), swdraw_no text, order_no text, unit_legacy int, unit_rate numeric(18,6),
    returned_amount numeric(18,4), discount numeric(18,4), tax_amount numeric(18,4),
    carton_count numeric(18,4), parcel_qty numeric(18,4), weight numeric(18,4), client_no text,
    client_model text, remark text,
    circumference numeric(18,4), material_price numeric(18,4), die_cast_price numeric(18,4),
    machining_price numeric(18,4));
\copy ship_item_stage FROM '/tmp/sales_shipment_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- S_OtherOut / S_OtherOutItem（字段与 S_Out(S_OutItem) 完全同构）
CREATE TEMP TABLE oship_stage (LIKE ship_stage INCLUDING DEFAULTS);
\copy oship_stage FROM '/tmp/sales_other_shipments.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE oship_item_stage (LIKE ship_item_stage INCLUDING DEFAULTS);
\copy oship_item_stage FROM '/tmp/sales_other_shipment_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- S_Withdraw / S_WithdrawItem（字段最简：无 TRate/SendDate/ShipAddr/SenderID）
CREATE TEMP TABLE return_stage (
    legacy_id int, bill_no text, bill_date date, client_legacy int, warehouse_legacy int, p_style int,
    maker_legacy int, approver_legacy int, remark text, total_original numeric(18,4), status smallint,
    last_date timestamptz, cur_legacy int, exchange_rate numeric(18,6), seller_legacy int, cancel_bit boolean);
\copy return_stage FROM '/tmp/sales_returns.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE return_item_stage (
    legacy_id int, bill_legacy int, goods_legacy int, color_legacy int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), out_no text, out_item_legacy int,
    order_item_legacy int, sorder_no text, unit_legacy int, unit_rate numeric(18,6), weight numeric(18,4),
    parcel_qty numeric(18,4), carton_count numeric(18,4), discount numeric(18,4), cost_amount numeric(18,4),
    client_model text, solution text, responsible text, remark text);
\copy return_item_stage FROM '/tmp/sales_return_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- ---------------- 自动补录缺失基础资料（同 migrate_purchase.sql §3.3，数据源换成 sales_*_stage） ----------------
-- 单位（S_OrderCostItem 无 UnitID，不参与）
INSERT INTO units (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-U-' || lid, '（迁移自动补录）', '使用'
FROM (SELECT unit_legacy AS lid FROM quote_item_stage UNION ALL
      SELECT unit_legacy FROM order_item_stage UNION ALL
      SELECT unit_legacy FROM ship_item_stage UNION ALL
      SELECT unit_legacy FROM oship_item_stage UNION ALL
      SELECT unit_legacy FROM return_item_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM units u WHERE u.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 颜色（颜色 0 = 无色，不补）
INSERT INTO colors (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-C-' || lid, '（迁移自动补录）', '使用'
FROM (SELECT color_legacy AS lid FROM quote_item_stage UNION ALL
      SELECT color_legacy FROM order_item_stage UNION ALL
      SELECT color_legacy FROM order_cost_stage UNION ALL
      SELECT color_legacy FROM ship_item_stage UNION ALL
      SELECT color_legacy FROM oship_item_stage UNION ALL
      SELECT color_legacy FROM return_item_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM colors c WHERE c.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 仓库（S_Order 无仓库；ship/oship/return 主表反推）
INSERT INTO warehouses (legacy_id, code, name, status, is_accountable, auto_created)
SELECT DISTINCT lid, 'LEGACY-W-' || lid, '（迁移自动补录）', '使用', TRUE, TRUE
FROM (SELECT warehouse_legacy AS lid FROM ship_stage UNION ALL
      SELECT warehouse_legacy FROM oship_stage UNION ALL
      SELECT warehouse_legacy FROM return_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM warehouses w WHERE w.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 币种（order/ship/oship/return 主表反推）
INSERT INTO currencies (legacy_id, code, name, exchange_rate, status, auto_created)
SELECT DISTINCT lid, 'LEGACY-CUR-' || lid, '（迁移自动补录）', 1, '使用', TRUE
FROM (SELECT cur_legacy AS lid FROM order_stage UNION ALL
      SELECT cur_legacy FROM ship_stage UNION ALL
      SELECT cur_legacy FROM oship_stage UNION ALL
      SELECT cur_legacy FROM return_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM currencies c WHERE c.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 货品（所有明细 + BOM 子件/替代货品反推）
INSERT INTO goods (legacy_id, code, name)
SELECT DISTINCT lid, 'LEGACY-G-' || lid, '（迁移自动补录）'
FROM (SELECT goods_legacy AS lid FROM quote_item_stage UNION ALL
      SELECT goods_legacy FROM order_item_stage UNION ALL
      SELECT goods_legacy FROM order_cost_stage UNION ALL
      SELECT alt_goods_legacy FROM order_cost_stage UNION ALL
      SELECT goods_legacy FROM ship_item_stage UNION ALL
      SELECT goods_legacy FROM oship_item_stage UNION ALL
      SELECT goods_legacy FROM return_item_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM goods g WHERE g.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 客户（销售独有：销售单据 client_id 多处 NOT NULL；主表反推）
INSERT INTO clients (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-CL-' || lid, '（迁移自动补录）', '使用'
FROM (SELECT client_legacy AS lid FROM quote_stage UNION ALL
      SELECT client_legacy FROM order_stage UNION ALL
      SELECT client_legacy FROM ship_stage UNION ALL
      SELECT client_legacy FROM oship_stage UNION ALL
      SELECT client_legacy FROM return_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM clients c WHERE c.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- ---------------- 1. 销售报价单（老库 0 行，保结构） ----------------
INSERT INTO sales_quotes (
    legacy_id, bill_no, bill_date, client_id, maker_id, approver_id, remark,
    total_original, total_local, status, is_closed)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM clients WHERE legacy_id = s.client_legacy),
       NULL, NULL, s.remark, s.total_original, s.total_original, s.status, FALSE
FROM quote_stage s
ON CONFLICT (legacy_id) DO NOTHING;

INSERT INTO sales_quote_items (
    legacy_id, bill_no, bill_date, quote_id, line_no, goods_id, color_id, unit_id, unit_rate,
    qty, price, amount_original, amount_local, remark)
SELECT s.legacy_id, q.bill_no, q.bill_date,
       (SELECT id FROM sales_quotes WHERE legacy_id = s.bill_legacy),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.price * s.qty, s.price * s.qty, NULLIF(s.remark, '')
FROM quote_item_stage s JOIN quote_stage q ON q.legacy_id = s.bill_legacy;

-- ---------------- 2. 销售订货单 ----------------
INSERT INTO sales_orders (
    legacy_id, bill_no, bill_date, client_id, currency_id, exchange_rate, tax_rate,
    payment_style_id, seller_id, maker_id, approver_id, deliver_date, contract_no, link_phone,
    sign_addr, ship_addr, deposit, remark, total_original, total_local, status, is_closed,
    is_stopped, source_doc_no, seller_legacy_id, maker_legacy_id, approver_legacy_id)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM clients    WHERE legacy_id = s.client_legacy),
       (SELECT id FROM currencies WHERE legacy_id = s.cur_legacy),
       COALESCE(s.exchange_rate, 1), s.tax_rate, s.p_style,
       NULL, NULL, NULL,                              -- *_id(UUID) 留空，待 employees.legacy_id 对齐回填
       s.deliver_date, s.contract_no, s.link_phone, s.sign_addr, s.ship_addr,
       s.deposit, s.remark, s.total_original,
       s.total_original * COALESCE(s.exchange_rate, 1),
       s.status, COALESCE(s.fulfill_bit, FALSE), COALESCE(s.stop_bit, FALSE), NULL,
       s.seller_legacy, s.maker_legacy, s.approver_legacy   -- *_legacy_id 保老库 B_Worker/Sys_Operator ID
FROM order_stage s
ON CONFLICT (legacy_id) DO NOTHING;

INSERT INTO sales_order_items (
    legacy_id, bill_no, bill_date, order_id, line_no, goods_id, color_id, unit_id, unit_rate,
    qty, price, amount_original, amount_local, shipped_qty, returned_qty, flag_qty, discount,
    tax_amount, weight, client_no, client_model, deliver_date, source_doc_no, remark,
    machining_price, circumference, inbound_qty, in_no, out_no)
SELECT s.legacy_id, o.bill_no, o.bill_date,
       (SELECT id FROM sales_orders WHERE legacy_id = s.bill_legacy),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original,
       s.amount_original * COALESCE(o.exchange_rate, 1),
       COALESCE(s.shipped_qty, 0), COALESCE(s.returned_qty, 0), COALESCE(s.flag_qty, 0),
       COALESCE(s.discount, 0), COALESCE(s.tax_amount, 0), s.weight,
       NULLIF(o.client_no, ''), NULLIF(s.client_model, ''), NULL,  -- 客户订单号取订单头 S_Order.ClientNo（明细无此列）；deliver_date 留 NULL
       NULLIF(CONCAT_WS(' | ', NULLIF(s.plan_no, ''), NULLIF(s.swdraw_no, '')), ''),  -- in_no/out_no 已分列
       NULLIF(s.remark, ''),
       s.machining_price, s.circumference, COALESCE(s.inbound_qty, 0),
       NULLIF(s.in_no, ''), NULLIF(s.out_no, '')
FROM order_item_stage s JOIN order_stage o ON o.legacy_id = s.bill_legacy;

-- BOM 子表：718 行，先 INSERT 全量 parent_id=NULL（避免自挂 FK 顺序依赖），再 UPDATE 自挂 parent_id
INSERT INTO sales_order_cost_items (
    legacy_id, bill_no, bill_date, order_item_id, parent_id, level, class_code, goods_id, color_id,
    alt_goods_id, alt_color_id, qty, order_qty, received_qty, draw_qty, purge_qty, other_draw_qty,
    supplier_id, l_status, source_doc_no, remark)
SELECT s.legacy_id, oi.bill_no, oi.bill_date,
       (SELECT id FROM sales_order_items WHERE legacy_id = s.bill_legacy),
       NULL,                                       -- 先置空，下方 UPDATE 补
       s.level, s.class_code,
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy),
       (SELECT id FROM goods  WHERE legacy_id = s.alt_goods_legacy),
       (SELECT id FROM colors WHERE legacy_id = s.alt_color_legacy),
       s.qty, COALESCE(s.order_qty, 0), COALESCE(s.received_qty, 0),
       COALESCE(s.draw_qty, 0), COALESCE(s.purge_qty, 0), COALESCE(s.other_draw_qty, 0),
       (SELECT id FROM suppliers WHERE legacy_id = s.supplier_legacy),
       s.l_status,
       NULLIF(CONCAT_WS(' | ',
                NULLIF(s.porder_no, ''), NULLIF(s.pdraw_no, ''), NULLIF(s.pin_no, ''),
                NULLIF(s.pwdraw_no, ''), NULLIF(s.owdraw_no, '')), ''),
       NULLIF(s.remark, '')
FROM order_cost_stage s
JOIN sales_order_items oi ON oi.legacy_id = s.bill_legacy
ON CONFLICT (legacy_id) DO NOTHING;

-- 补 parent_id 自挂（排除 ParentID=0/自身/不存在，避免环路）
UPDATE sales_order_cost_items c
   SET parent_id = pc.id
  FROM order_cost_stage t
  JOIN sales_order_cost_items pc ON pc.legacy_id = t.parent_legacy
 WHERE c.legacy_id = t.legacy_id
   AND t.parent_legacy IS NOT NULL
   AND t.parent_legacy <> 0
   AND t.parent_legacy <> t.legacy_id;

-- ---------------- 3. 销售出货单（S_Out，主流量 12124 行） ----------------
INSERT INTO sales_shipments (
    legacy_id, bill_no, bill_date, client_id, warehouse_id, currency_id, exchange_rate, tax_rate,
    payment_style_id, seller_id, sender_id, maker_id, approver_id, ship_addr, link_phone, parcel_count,
    print_count, last_date, remark, total_original, total_local, status, is_closed, ar_posted, source_doc_no,
    seller_legacy_id, sender_legacy_id, maker_legacy_id, approver_legacy_id)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM clients    WHERE legacy_id = s.client_legacy),
       (SELECT id FROM warehouses WHERE legacy_id = s.warehouse_legacy),
       (SELECT id FROM currencies WHERE legacy_id = s.cur_legacy),
       COALESCE(s.exchange_rate, 1), s.tax_rate, s.p_style,
       NULL, NULL, NULL, NULL,                       -- *_id(UUID) 留空，待 employees.legacy_id 对齐回填
       s.ship_addr, s.link_phone, s.p_count, s.print_count, s.last_date,
       s.remark, s.total_original,
       s.total_original * COALESCE(s.exchange_rate, 1),
       s.status, FALSE, FALSE, NULL,                 -- ar_posted 默认 false（历史应收在钱流模块独立迁）
       s.seller_legacy, s.sender_legacy, s.maker_legacy, s.approver_legacy
FROM ship_stage s
ON CONFLICT (legacy_id) DO NOTHING;

INSERT INTO sales_shipment_items (
    legacy_id, bill_no, bill_date, shipment_id, order_item_id, line_no, goods_id, color_id, unit_id,
    unit_rate, qty, price, amount_original, amount_local, cost_amount, returned_qty, returned_amount,
    weight, parcel_qty, carton_count, client_no, client_model, source_doc_no, remark,
    material_price, die_cast_price, machining_price, circumference, discount)
SELECT s.legacy_id, o.bill_no, o.bill_date,
       (SELECT id FROM sales_shipments WHERE legacy_id = s.bill_legacy),
       (SELECT id FROM sales_order_items WHERE legacy_id = s.order_item_legacy AND s.order_item_legacy <> 0),
                                                                       -- 真FK骨干：0/null -> NULL
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original,
       s.amount_original * COALESCE(o.exchange_rate, 1),
       s.cost_amount, COALESCE(s.returned_qty, 0), COALESCE(s.returned_amount, 0),
       s.weight, s.parcel_qty, s.carton_count,
       NULLIF(s.client_no, ''), NULLIF(s.client_model, ''),
       NULLIF(CONCAT_WS(' | ', NULLIF(s.order_no, ''), NULLIF(s.swdraw_no, '')), ''),
       NULLIF(s.remark, ''),
       s.material_price, s.die_cast_price, s.machining_price, s.circumference, COALESCE(s.discount, 0)
FROM ship_item_stage s JOIN ship_stage o ON o.legacy_id = s.bill_legacy;

-- ---------------- 4. 其它出货单（S_OtherOut，不挂订单/不立应收） ----------------
INSERT INTO sales_other_shipments (
    legacy_id, bill_no, bill_date, client_id, warehouse_id, currency_id, exchange_rate, tax_rate,
    payment_style_id, seller_id, sender_id, maker_id, approver_id, ship_addr, link_phone, parcel_count,
    print_count, last_date, remark, total_original, total_local, status, is_closed, source_doc_no,
    seller_legacy_id, sender_legacy_id, maker_legacy_id, approver_legacy_id)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM clients    WHERE legacy_id = s.client_legacy),  -- client_id 可空（内部领用）
       (SELECT id FROM warehouses WHERE legacy_id = s.warehouse_legacy),
       (SELECT id FROM currencies WHERE legacy_id = s.cur_legacy),
       COALESCE(s.exchange_rate, 1), s.tax_rate, s.p_style,
       NULL, NULL, NULL, NULL,                       -- *_id(UUID) 留空，待 employees.legacy_id 对齐回填
       s.ship_addr, s.link_phone, s.p_count, s.print_count, s.last_date,
       s.remark, s.total_original,
       s.total_original * COALESCE(s.exchange_rate, 1),
       s.status, FALSE, NULL,
       s.seller_legacy, s.sender_legacy, s.maker_legacy, s.approver_legacy
FROM oship_stage s
ON CONFLICT (legacy_id) DO NOTHING;

-- 其它出货明细：order_item_id 业务上不挂单（老库触发器 UPDATE 整段注释），留 NULL
INSERT INTO sales_other_shipment_items (
    legacy_id, bill_no, bill_date, shipment_id, order_item_id, line_no, goods_id, color_id, unit_id,
    unit_rate, qty, price, amount_original, amount_local, cost_amount, returned_qty, returned_amount,
    weight, parcel_qty, carton_count, client_no, client_model, source_doc_no, remark,
    material_price, die_cast_price, machining_price, circumference, discount)
SELECT s.legacy_id, o.bill_no, o.bill_date,
       (SELECT id FROM sales_other_shipments WHERE legacy_id = s.bill_legacy),
       NULL,                                                              -- 业务不挂单
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original,
       s.amount_original * COALESCE(o.exchange_rate, 1),
       s.cost_amount, COALESCE(s.returned_qty, 0), COALESCE(s.returned_amount, 0),
       s.weight, s.parcel_qty, s.carton_count,
       NULLIF(s.client_no, ''), NULLIF(s.client_model, ''),
       NULLIF(CONCAT_WS(' | ', NULLIF(s.order_no, ''), NULLIF(s.swdraw_no, '')), ''),
       NULLIF(s.remark, ''),
       s.material_price, s.die_cast_price, s.machining_price, s.circumference, COALESCE(s.discount, 0)
FROM oship_item_stage s JOIN oship_stage o ON o.legacy_id = s.bill_legacy;

-- ---------------- 5. 销售退货单（S_Withdraw，221 行） ----------------
INSERT INTO sales_returns (
    legacy_id, bill_no, bill_date, client_id, warehouse_id, currency_id, exchange_rate, tax_rate,
    payment_style_id, seller_id, maker_id, approver_id, last_date, remark, total_original, total_local,
    status, is_closed, ar_posted, source_doc_no, seller_legacy_id, maker_legacy_id, approver_legacy_id)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM clients    WHERE legacy_id = s.client_legacy),
       (SELECT id FROM warehouses WHERE legacy_id = s.warehouse_legacy),
       (SELECT id FROM currencies WHERE legacy_id = s.cur_legacy),
       COALESCE(s.exchange_rate, 1), NULL,            -- S_Withdraw 无 TRate
       s.p_style,
       NULL, NULL, NULL,                              -- *_id(UUID) 留空，待 employees.legacy_id 对齐回填
       s.last_date, s.remark,
       s.total_original,                              -- 退货 total 主表保持原值（红字在 ar_ap_ledger 取负）
       s.total_original * COALESCE(s.exchange_rate, 1),
       s.status, FALSE, FALSE, NULL,
       s.seller_legacy, s.maker_legacy, s.approver_legacy
FROM return_stage s
ON CONFLICT (legacy_id) DO NOTHING;

-- 退货明细：双挂 out_item_id + order_item_id（4 条真FK骨干里的 2 条）
INSERT INTO sales_return_items (
    legacy_id, bill_no, bill_date, return_id, out_item_id, order_item_id, line_no, goods_id, color_id,
    unit_id, unit_rate, qty, price, amount_original, amount_local, cost_amount, weight, parcel_qty,
    carton_count, client_no, client_model, solution, responsible, source_doc_no, remark, discount)
SELECT s.legacy_id, r.bill_no, r.bill_date,
       (SELECT id FROM sales_returns WHERE legacy_id = s.bill_legacy),
       (SELECT id FROM sales_shipment_items WHERE legacy_id = s.out_item_legacy AND s.out_item_legacy <> 0),
       (SELECT id FROM sales_order_items    WHERE legacy_id = s.order_item_legacy AND s.order_item_legacy <> 0),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original,
       s.amount_original * COALESCE(r.exchange_rate, 1),
       s.cost_amount, s.weight, s.parcel_qty, s.carton_count,
       NULL,                                          -- S_WithdrawItem 无 ClientNo
       NULLIF(s.client_model, ''),
       NULLIF(s.solution, ''), NULLIF(s.responsible, ''),
       NULLIF(CONCAT_WS(' | ', NULLIF(s.out_no, ''), NULLIF(s.sorder_no, '')), ''),
       NULLIF(s.remark, ''),
       COALESCE(s.discount, 0)
FROM return_item_stage s JOIN return_stage r ON r.legacy_id = s.bill_legacy;

COMMIT;

-- ---------------- 刷新销售月度物化视图（CONCURRENTLY 不能在事务内，置 COMMIT 后） ----------------
-- 修汇总报表空数据根因：V52 sales_monthly_mv 迁完必须刷新才有数据。
SELECT refresh_sales_monthly_mv();

-- ---------------- 校验 ----------------
SELECT '报价 '         || (SELECT count(*) FROM sales_quotes)            || ' / ' || (SELECT count(*) FROM sales_quote_items) AS r
UNION ALL SELECT '订货 '         || (SELECT count(*) FROM sales_orders)            || ' / ' || (SELECT count(*) FROM sales_order_items)
UNION ALL SELECT 'BOM 展开 '     || (SELECT count(*) FROM sales_order_cost_items)
UNION ALL SELECT '出货 '         || (SELECT count(*) FROM sales_shipments)         || ' / ' || (SELECT count(*) FROM sales_shipment_items)
UNION ALL SELECT '其它出货 '     || (SELECT count(*) FROM sales_other_shipments)   || ' / ' || (SELECT count(*) FROM sales_other_shipment_items)
UNION ALL SELECT '退货 '         || (SELECT count(*) FROM sales_returns)           || ' / ' || (SELECT count(*) FROM sales_return_items)
UNION ALL SELECT '已审出货 '     || (SELECT count(*) FROM sales_shipments WHERE status = 1)
UNION ALL SELECT 'MV行数 '       || (SELECT count(*) FROM sales_monthly_mv)
UNION ALL SELECT '订货 机加价非空 ' || (SELECT count(*) FROM sales_order_items WHERE machining_price IS NOT NULL)
UNION ALL SELECT '订货 进仓数非空 ' || (SELECT count(*) FROM sales_order_items WHERE inbound_qty <> 0)
UNION ALL SELECT '订货 in_no非空 '  || (SELECT count(*) FROM sales_order_items WHERE in_no IS NOT NULL AND in_no <> '')
UNION ALL SELECT '出货挂订单明细 ' || (SELECT count(*) FROM sales_shipment_items WHERE order_item_id IS NOT NULL)
UNION ALL SELECT '退货双挂明细 '  || (SELECT count(*) FROM sales_return_items WHERE out_item_id IS NOT NULL AND order_item_id IS NOT NULL)
UNION ALL SELECT '孤儿 出货明细(无货品) ' || (SELECT count(*) FROM sales_shipment_items WHERE goods_id IS NULL)
UNION ALL SELECT '孤儿 出货明细(无主表) ' || (SELECT count(*) FROM sales_shipment_items i
                                          WHERE NOT EXISTS (SELECT 1 FROM sales_shipments o WHERE o.id = i.shipment_id))
UNION ALL SELECT '孤儿 BOM(无订单明细) '  || (SELECT count(*) FROM sales_order_cost_items c
                                          WHERE NOT EXISTS (SELECT 1 FROM sales_order_items oi WHERE oi.id = c.order_item_id))
UNION ALL SELECT '补录 货品 '    || (SELECT count(*) FROM goods    WHERE code LIKE 'LEGACY-G-%')
UNION ALL SELECT '补录 客户 '    || (SELECT count(*) FROM clients  WHERE code LIKE 'LEGACY-CL-%')
UNION ALL SELECT '校验 订货已发量误差行' || (SELECT count(*) FROM (
          SELECT i.id FROM sales_order_items i
           JOIN (SELECT order_item_id, SUM(qty) AS sm FROM sales_shipment_items
                  WHERE order_item_id IS NOT NULL GROUP BY order_item_id) x ON x.order_item_id = i.id
          WHERE ABS(i.shipped_qty - x.sm) > 0.01) z)
UNION ALL SELECT '校验 订货已退量误差行' || (SELECT count(*) FROM (
          SELECT i.id FROM sales_order_items i
           JOIN (SELECT order_item_id, SUM(qty) AS sm FROM sales_return_items
                  WHERE order_item_id IS NOT NULL GROUP BY order_item_id) x ON x.order_item_id = i.id
          WHERE ABS(i.returned_qty - x.sm) > 0.01) z);
