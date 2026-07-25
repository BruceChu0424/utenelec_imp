-- =====================================================================
-- 采购四单据迁移：CSV → purchase_requests/orders/receipts/returns + *_items
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --purchase
-- 前提：V42-V47 已建表；goods/colors/units/suppliers/currencies/warehouses 主档已迁。
-- 顺序：申请 → 订货 → 收货 → 退货（链路 FK：订货明细.request_item_id、收货明细.order_item_id、
--   退货明细.receipt_item_id/order_item_id，均按 legacy_id 子查询映射到新 UUID）。
-- 幂等：开头一次性 TRUNCATE 8 张采购表（被引用关系，须一起清），重跑安全。
-- 缺失基础资料自动补录（units/colors/warehouses/currencies，§3.3，auto_created=true 标记）。
-- 人员字段（applicant/maker/approver/purchaser/sender/receiver）：employees 与 B_Worker 未对齐，留 NULL。
-- status：老库 1→1（已审）、-1→-1（红冲），直接照搬（老库无草稿态）。
-- 库存历史不在此迁（stock_movements/balances 归库存模块，从 StockGoods 单独迁）。
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
TRUNCATE purchase_return_items, purchase_receipt_items, purchase_order_items, purchase_request_items,
         purchase_returns, purchase_receipts, purchase_orders, purchase_requests;
SET session_replication_role = DEFAULT;

-- ---------------- staging ----------------
CREATE TEMP TABLE app_stage (
    legacy_id int, bill_no text, bill_date date, applicant_legacy int, maker_legacy int, approver_legacy int,
    remark text, total_original numeric(18,4), status smallint, fulfill_bit boolean, stop_bit boolean,
    cancel_bit boolean, step_id int, b_style int, app_date date, warehouse_legacy_id int);
\copy app_stage FROM '/tmp/purchase_applications.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE app_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), ordered_qty numeric(18,4), unit_legacy_id int,
    unit_rate numeric(18,6), weight numeric(18,4), source_doc_no text);
\copy app_item_stage FROM '/tmp/purchase_application_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE order_stage (
    legacy_id int, bill_no text, bill_date date, deliver_date date, purchaser_legacy int, maker_legacy int,
    approver_legacy int, remark text, total_original numeric(18,4), status smallint, fulfill_bit boolean,
    stop_bit boolean, supplier_legacy_id int, tax_rate numeric(18,4), currency_legacy_id int,
    exchange_rate numeric(18,6), cancel_bit boolean);
\copy order_stage FROM '/tmp/purchase_orders.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE order_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), received_qty numeric(18,4), returned_qty numeric(18,4),
    request_item_legacy_id int, unit_legacy_id int, unit_rate numeric(18,6), deliver_date date,
    weight numeric(18,4), source_doc_no text);
\copy order_item_stage FROM '/tmp/purchase_order_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE receipt_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int, warehouse_legacy_id int,
    sender_legacy int, receiver_legacy int, maker_legacy int, approver_legacy int, remark text,
    total_original numeric(18,4), status smallint, tax_rate numeric(18,4), currency_legacy_id int,
    exchange_rate numeric(18,6), cancel_bit boolean, last_date date);
\copy receipt_stage FROM '/tmp/purchase_receipts.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE receipt_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), order_item_legacy_id int, unit_legacy_id int,
    unit_rate numeric(18,6), returned_qty numeric(18,4), gift_qty numeric(18,4), weight numeric(18,4),
    source_doc_no text);
\copy receipt_item_stage FROM '/tmp/purchase_receipt_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE return_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int, warehouse_legacy_id int,
    maker_legacy int, approver_legacy int, remark text, total_original numeric(18,4), status smallint,
    currency_legacy_id int, exchange_rate numeric(18,6), cancel_bit boolean, last_date date);
\copy return_stage FROM '/tmp/purchase_returns.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE return_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), receipt_item_legacy_id int, order_item_legacy_id int,
    unit_legacy_id int, unit_rate numeric(18,6), weight numeric(18,4), source_doc_no text);
\copy return_item_stage FROM '/tmp/purchase_return_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- ---------------- 自动补录缺失基础资料（§3.3） ----------------
-- 单位（从所有明细反推；units 表无 auto_created 列，用 code 前缀标识补录行）
INSERT INTO units (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-U-' || lid, '（迁移自动补录）', '使用'
FROM (SELECT unit_legacy_id AS lid FROM app_item_stage UNION ALL
      SELECT unit_legacy_id FROM order_item_stage UNION ALL
      SELECT unit_legacy_id FROM receipt_item_stage UNION ALL
      SELECT unit_legacy_id FROM return_item_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM units u WHERE u.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 颜色（同上，颜色 0 = 无色，不补）
INSERT INTO colors (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-C-' || lid, '（迁移自动补录）', '使用'
FROM (SELECT color_legacy_id AS lid FROM app_item_stage UNION ALL
      SELECT color_legacy_id FROM order_item_stage UNION ALL
      SELECT color_legacy_id FROM receipt_item_stage UNION ALL
      SELECT color_legacy_id FROM return_item_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM colors c WHERE c.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 仓库（从申请/收货/退货主表反推；订货单 P_Order 无仓库字段）
INSERT INTO warehouses (legacy_id, code, name, status, is_accountable, auto_created)
SELECT DISTINCT lid, 'LEGACY-W-' || lid, '（迁移自动补录）', '使用', TRUE, TRUE
FROM (SELECT warehouse_legacy_id AS lid FROM app_stage UNION ALL
      SELECT warehouse_legacy_id FROM receipt_stage UNION ALL
      SELECT warehouse_legacy_id FROM return_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM warehouses w WHERE w.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 币种（从订货/收货/退货主表反推）
INSERT INTO currencies (legacy_id, code, name, exchange_rate, status, auto_created)
SELECT DISTINCT lid, 'LEGACY-CUR-' || lid, '（迁移自动补录）', 1, '使用', TRUE
FROM (SELECT currency_legacy_id AS lid FROM order_stage UNION ALL
      SELECT currency_legacy_id FROM receipt_stage UNION ALL
      SELECT currency_legacy_id FROM return_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM currencies c WHERE c.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- ---------------- 1. 采购申请单 ----------------
INSERT INTO purchase_requests (
    legacy_id, bill_no, bill_date, warehouse_id, remark, total_original, total_local, status, is_closed)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM warehouses WHERE legacy_id = s.warehouse_legacy_id),
       s.remark, s.total_original, s.total_original, s.status,
       COALESCE(s.fulfill_bit, FALSE)
FROM app_stage s;

INSERT INTO purchase_request_items (
    legacy_id, bill_no, bill_date, request_id, line_no, goods_id, color_id, unit_id, unit_rate,
    qty, price, amount_original, amount_local, ordered_qty, weight, source_doc_no)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM purchase_requests WHERE legacy_id = s.bill_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original, s.amount_original,
       COALESCE(s.ordered_qty, 0), s.weight, NULLIF(s.source_doc_no, '')
FROM app_item_stage s JOIN app_stage a ON a.legacy_id = s.bill_legacy_id;

-- ---------------- 2. 采购订货单 ----------------
INSERT INTO purchase_orders (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, currency_id, exchange_rate, tax_rate,
    deliver_date, remark, total_original, total_local, status, is_closed)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id),
       NULL,  -- P_Order 无仓库字段（订货单不指定仓库，收货时定）
       (SELECT id FROM currencies WHERE legacy_id = s.currency_legacy_id),
       COALESCE(s.exchange_rate, 1), s.tax_rate, s.deliver_date, s.remark,
       s.total_original, s.total_original, s.status, COALESCE(s.fulfill_bit, FALSE)
FROM order_stage s;

INSERT INTO purchase_order_items (
    legacy_id, bill_no, bill_date, order_id, line_no, goods_id, color_id, unit_id, unit_rate,
    qty, price, amount_original, amount_local, received_qty, returned_qty, request_item_id, deliver_date, weight, source_doc_no)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM purchase_orders WHERE legacy_id = s.bill_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original, s.amount_original,
       COALESCE(s.received_qty, 0), COALESCE(s.returned_qty, 0),
       (SELECT id FROM purchase_request_items WHERE legacy_id = s.request_item_legacy_id),
       s.deliver_date, s.weight, NULLIF(s.source_doc_no, '')
FROM order_item_stage s JOIN order_stage a ON a.legacy_id = s.bill_legacy_id;

-- ---------------- 3. 采购收货单 ----------------
INSERT INTO purchase_receipts (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, currency_id, exchange_rate, tax_rate,
    remark, total_original, total_local, status, is_closed)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id),
       (SELECT id FROM warehouses WHERE legacy_id = s.warehouse_legacy_id),
       (SELECT id FROM currencies WHERE legacy_id = s.currency_legacy_id),
       COALESCE(s.exchange_rate, 1), s.tax_rate, s.remark,
       s.total_original, s.total_original, s.status, FALSE
FROM receipt_stage s;

INSERT INTO purchase_receipt_items (
    legacy_id, bill_no, bill_date, receipt_id, order_item_id, line_no, goods_id, color_id, unit_id,
    unit_rate, qty, price, amount_original, amount_local, returned_qty, gift_qty, weight, source_doc_no)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM purchase_receipts WHERE legacy_id = s.bill_legacy_id),
       (SELECT id FROM purchase_order_items WHERE legacy_id = s.order_item_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original, s.amount_original,
       COALESCE(s.returned_qty, 0), COALESCE(s.gift_qty, 0), s.weight, NULLIF(s.source_doc_no, '')
FROM receipt_item_stage s JOIN receipt_stage a ON a.legacy_id = s.bill_legacy_id;

-- ---------------- 4. 采购退货单 ----------------
INSERT INTO purchase_returns (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, currency_id, exchange_rate, tax_rate,
    remark, total_original, total_local, status, is_closed)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id),
       (SELECT id FROM warehouses WHERE legacy_id = s.warehouse_legacy_id),
       (SELECT id FROM currencies WHERE legacy_id = s.currency_legacy_id),
       COALESCE(s.exchange_rate, 1), NULL, s.remark,  -- P_Withdraw 无 TRate
       s.total_original, s.total_original, s.status, FALSE
FROM return_stage s;

INSERT INTO purchase_return_items (
    legacy_id, bill_no, bill_date, return_id, receipt_item_id, order_item_id, line_no, goods_id, color_id,
    unit_id, unit_rate, qty, price, amount_original, amount_local, weight, source_doc_no)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM purchase_returns WHERE legacy_id = s.bill_legacy_id),
       (SELECT id FROM purchase_receipt_items WHERE legacy_id = s.receipt_item_legacy_id),
       (SELECT id FROM purchase_order_items WHERE legacy_id = s.order_item_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original, s.amount_original,
       s.weight, NULLIF(s.source_doc_no, '')
FROM return_item_stage s JOIN return_stage a ON a.legacy_id = s.bill_legacy_id;

COMMIT;

-- ---------------- 校验 ----------------
SELECT '✔ 申请 ' || (SELECT count(*) FROM purchase_requests) || ' / ' || (SELECT count(*) FROM purchase_request_items) AS r
UNION ALL SELECT '订货 ' || (SELECT count(*) FROM purchase_orders) || ' / ' || (SELECT count(*) FROM purchase_order_items)
UNION ALL SELECT '收货 ' || (SELECT count(*) FROM purchase_receipts) || ' / ' || (SELECT count(*) FROM purchase_receipt_items)
UNION ALL SELECT '退货 ' || (SELECT count(*) FROM purchase_returns) || ' / ' || (SELECT count(*) FROM purchase_return_items)
UNION ALL SELECT '已审收货 ' || (SELECT count(*) FROM purchase_receipts WHERE status = 1)
UNION ALL SELECT '链路 收货明细挂订货 ' || (SELECT count(*) FROM purchase_receipt_items WHERE order_item_id IS NOT NULL)
UNION ALL SELECT '孤儿 收货明细(无货品) ' || (SELECT count(*) FROM purchase_receipt_items WHERE goods_id IS NULL);
