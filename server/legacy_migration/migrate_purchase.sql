-- =====================================================================
-- 采购四单据迁移：CSV → purchase_requests/orders/receipts/returns + *_items
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --purchase
-- 前提：Flyway 至少 V269；goods/colors/units/suppliers/currencies/warehouses 主档已迁。
-- 顺序：申请 → 订货 → 收货 → 退货（链路 FK：订货明细.request_item_id、收货明细.order_item_id、
--   退货明细.receipt_item_id/order_item_id，均按 legacy_id 子查询映射到新 UUID）。
-- 重载：按 FK 逆序 DELETE；任何当前模块的下游执行/质检/财务引用都会
-- 在导入前 fail-closed，绝不级联删除在线证据。
-- 缺失基础资料自动补录（units/colors/warehouses/currencies，§3.3，auto_created=true 标记）。
-- 人员（两类来源，与委外/钱流同模式）：
--   · B_Worker（申请人/采购员/收货人/交货人）→ employees stub（legacy_id=B_Worker.ID，
--     status='resigned'，NOT EXISTS 守卫不覆盖 HR 真名单）；报表 JOIN employees 出名。
--   · Sys_Operator（制单员/审核员，登录账号非员工档案）→ 迁移时把 fname 冻结进
--     maker_name/approver_name 文本列；报表 COALESCE(employees 真名, 冻结名)。
-- 部门：申请单 StepID → SystemItem(ItemclassID=5) 老库部门（老视图 View_P_Application 口径），
--   department_id 通过 legacy_departments.department_id 写 UUID 真源；StepID 仍存
--   department_legacy_id 作为无法映射时的历史名称快照。
-- 结帐方式：settlement_style_legacy 存老库 PStyle 原值；字典=老库 B_PStyle
--   （1现金/2提货/3代付/4支票/6月结/7垫付/8汇款/10代收），常量固化在 PurchaseSettlementStyle。
-- 是否中止：is_stopped 存老库 Stop 位。
-- 收货采购员：P_In.sman（业务员）→ employees.legacy_id 精确映射 purchaser_id；
--   purchaser_legacy_id 仅保留老值快照。
-- 明细交叉引用（生产单号/采购订货单号/销售订货单号/生产计划单号/收货单号/采购回复/摘要/交货日期）：
--   老库 varchar 软关联，按列原样迁入（NULLIF 去空串），不强 FK。
-- status：老库 1→1（已审）、-1→-1（红冲），直接照搬（老库无草稿态）。
-- 库存历史不在此迁（stock_movements/balances 归库存模块，从 StockGoods 单独迁）。
-- =====================================================================

BEGIN;
SELECT set_config('uten.legacy_reference_import', 'legacy-purchase-v273', true);
DELETE FROM purchase_return_items;
DELETE FROM purchase_returns;
DELETE FROM purchase_receipt_items;
DELETE FROM purchase_receipts;
DELETE FROM purchase_order_items;
DELETE FROM purchase_orders;
DELETE FROM purchase_request_items;
DELETE FROM purchase_requests;

-- ---------------- staging（列顺序须与 export_legacy.ps1 的 SELECT 顺序一致：\copy 按位置读） ----------------
CREATE TEMP TABLE app_stage (
    legacy_id int, bill_no text, bill_date date, applicant_legacy int, maker_legacy int, approver_legacy int,
    remark text, total_original numeric(18,4), status smallint, fulfill_bit boolean, stop_bit boolean,
    cancel_bit boolean, step_id int, b_style int, app_date date, warehouse_legacy_id int);
\copy app_stage FROM '/tmp/purchase_applications.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE app_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), ordered_qty numeric(18,4), unit_legacy_id int,
    unit_rate numeric(18,6), weight numeric(18,4), source_doc_no text,
    sales_order_no text, production_no text, purchase_order_no text, production_plan_no text,
    purchase_reply text, summary text, deliver_date date);
\copy app_item_stage FROM '/tmp/purchase_application_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE order_stage (
    legacy_id int, bill_no text, bill_date date, deliver_date date, purchaser_legacy int, maker_legacy int,
    approver_legacy int, remark text, total_original numeric(18,4), status smallint, fulfill_bit boolean,
    stop_bit boolean, supplier_legacy_id int, tax_rate numeric(18,4), currency_legacy_id int,
    exchange_rate numeric(18,6), cancel_bit boolean, settlement_style_legacy smallint);
\copy order_stage FROM '/tmp/purchase_orders.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE order_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), received_qty numeric(18,4), returned_qty numeric(18,4),
    request_item_legacy_id int, unit_legacy_id int, unit_rate numeric(18,6), deliver_date date,
    weight numeric(18,4), source_doc_no text, sales_order_no text, receipt_no text, production_plan_no text);
\copy order_item_stage FROM '/tmp/purchase_order_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE receipt_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int, warehouse_legacy_id int,
    sender_legacy int, receiver_legacy int, maker_legacy int, approver_legacy int, remark text,
    total_original numeric(18,4), status smallint, tax_rate numeric(18,4), currency_legacy_id int,
    exchange_rate numeric(18,6), cancel_bit boolean, last_date date, settlement_style_legacy smallint,
    salesman_legacy int);
\copy receipt_stage FROM '/tmp/purchase_receipts.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE receipt_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), order_item_legacy_id int, unit_legacy_id int,
    unit_rate numeric(18,6), returned_qty numeric(18,4), gift_qty numeric(18,4), weight numeric(18,4),
    source_doc_no text, order_no text, sales_order_no text, production_plan_no text);
\copy receipt_item_stage FROM '/tmp/purchase_receipt_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE return_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int, warehouse_legacy_id int,
    maker_legacy int, approver_legacy int, remark text, total_original numeric(18,4), status smallint,
    currency_legacy_id int, exchange_rate numeric(18,6), cancel_bit boolean, last_date date,
    settlement_style_legacy smallint);
\copy return_stage FROM '/tmp/purchase_returns.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE return_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int, qty numeric(18,4),
    price numeric(18,4), amount_original numeric(18,4), receipt_item_legacy_id int, order_item_legacy_id int,
    unit_legacy_id int, unit_rate numeric(18,6), weight numeric(18,4), source_doc_no text,
    receipt_no text, order_no text, sales_order_no text, production_plan_no text);
\copy return_item_stage FROM '/tmp/purchase_return_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- ---------------- 人员/部门参考 staging ----------------
CREATE TEMP TABLE worker_ref_stage (legacy_id int, name text);
\copy worker_ref_stage FROM '/tmp/legacy_workers_ref.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE operator_ref_stage (legacy_id int, name text);
\copy operator_ref_stage FROM '/tmp/legacy_operators_ref.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE dept_stage (legacy_id int, name text, code text);
\copy dept_stage FROM '/tmp/legacy_departments.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- 老库部门字典（SystemItem ItemclassID=5）：幂等 upsert（重迁时部门改名可同步）
INSERT INTO legacy_departments (legacy_id, name, code)
SELECT d.legacy_id, NULLIF(BTRIM(d.name), ''), NULLIF(BTRIM(d.code), '')
FROM dept_stage d
WHERE d.legacy_id IS NOT NULL AND d.legacy_id <> 0 AND NULLIF(BTRIM(d.name), '') IS NOT NULL
ON CONFLICT (legacy_id) DO UPDATE SET name = EXCLUDED.name, code = EXCLUDED.code;

-- employees stub：B_Worker（申请人/采购员/收货人/交货人）→ employees（与委外/钱流同模式）。
-- NOT EXISTS 守卫：HR 已录真员工（同 legacy_id）优先，绝不覆盖；重跑幂等。
INSERT INTO employees (legacy_id, code, full_name, id_type, department_id, hire_date, status, employment_type)
SELECT w.legacy_id, 'LEGACY-W-' || w.legacy_id, NULLIF(w.name, ''), '其他',
       (SELECT id FROM departments WHERE code = 'DEPT_PMC'), DATE '2000-01-01', 'resigned', 'regular'
FROM worker_ref_stage w
WHERE w.legacy_id IS NOT NULL AND w.legacy_id <> 0 AND NULLIF(w.name, '') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.legacy_id = w.legacy_id);

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
-- 部门 = StepID（老视图口径）；制单员/审核员名冻结自 Sys_Operator。
INSERT INTO purchase_requests (
    legacy_id, bill_no, bill_date, warehouse_id, department_id, applicant_id, maker_id, approver_id, need_date, remark,
    total_original, total_local, status, is_closed,
    applicant_legacy_id, maker_legacy_id, approver_legacy_id, is_stopped,
    department_legacy_id, maker_name, approver_name)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM warehouses WHERE legacy_id = s.warehouse_legacy_id),
       (SELECT department_id FROM legacy_departments WHERE legacy_id = s.step_id),
       NULL, NULL, NULL,                -- *_id(UUID) 待 employees.legacy_id 对齐后回填
       s.app_date,                       -- need_date ← AppDate
       s.remark, s.total_original, s.total_original, s.status,
       COALESCE(s.fulfill_bit, FALSE),
       NULLIF(s.applicant_legacy, 0), NULLIF(s.maker_legacy, 0), NULLIF(s.approver_legacy, 0),
       COALESCE(s.stop_bit, FALSE),
       NULLIF(s.step_id, 0),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = s.maker_legacy),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = s.approver_legacy)
FROM app_stage s;

INSERT INTO purchase_request_items (
    legacy_id, bill_no, bill_date, request_id, line_no, goods_id, color_id, unit_id, unit_rate,
    qty, price, amount_original, amount_local, ordered_qty, weight, source_doc_no,
    deliver_date, production_no, purchase_order_no, sales_order_no, production_plan_no, purchase_reply, summary,
    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM purchase_requests WHERE legacy_id = s.bill_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       COALESCE(
           (SELECT id FROM units WHERE legacy_id = NULLIF(s.unit_legacy_id, 0)),
           (
               SELECT u.id
               FROM goods g
               JOIN units u ON u.legacy_id = g.unit_legacy_id
                           AND u.is_deleted = FALSE
               WHERE g.legacy_id = s.goods_legacy_id
                 AND g.is_deleted = FALSE
                 AND COALESCE(s.unit_legacy_id, 0) = 0
                 AND COALESCE(s.unit_rate, 1) = 1
           )
       ),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original, s.amount_original,
       COALESCE(s.ordered_qty, 0), s.weight, NULLIF(s.source_doc_no, ''),
       s.deliver_date,
       NULLIF(s.production_no, ''), NULLIF(s.purchase_order_no, ''), NULLIF(s.sales_order_no, ''),
       NULLIF(s.production_plan_no, ''), NULLIF(s.purchase_reply, ''), NULLIF(s.summary, ''),
       (SELECT code FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT name FROM goods WHERE legacy_id = s.goods_legacy_id),
       'LEGACY_IMPORT', CASE WHEN a.status <> 0 THEN now() ELSE NULL END
FROM app_item_stage s JOIN app_stage a ON a.legacy_id = s.bill_legacy_id;

-- ---------------- 2. 采购订货单 ----------------
INSERT INTO purchase_orders (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, currency_id, exchange_rate, tax_rate,
    purchaser_id, maker_id, approver_id, deliver_date, remark, total_original, total_local, status, is_closed,
    purchaser_legacy_id, maker_legacy_id, approver_legacy_id, settlement_style_legacy, is_stopped,
    maker_name, approver_name)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id),
       NULL,  -- P_Order 无仓库字段（订货单不指定仓库，收货时定）
       (SELECT id FROM currencies WHERE legacy_id = s.currency_legacy_id),
       COALESCE(s.exchange_rate, 1), s.tax_rate,
       NULL, NULL, NULL,                  -- *_id(UUID) 待对齐
       s.deliver_date, s.remark,
       s.total_original, s.total_original, s.status, COALESCE(s.fulfill_bit, FALSE),
       NULLIF(s.purchaser_legacy, 0), NULLIF(s.maker_legacy, 0), NULLIF(s.approver_legacy, 0),
       s.settlement_style_legacy, COALESCE(s.stop_bit, FALSE),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = s.maker_legacy),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = s.approver_legacy)
FROM order_stage s;

INSERT INTO purchase_order_items (
    legacy_id, bill_no, bill_date, order_id, line_no, goods_id, color_id, unit_id, unit_rate,
    qty, price, amount_original, amount_local, received_qty, returned_qty, request_item_id, deliver_date,
    weight, source_doc_no, sales_order_no, receipt_no, production_plan_no,
    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM purchase_orders WHERE legacy_id = s.bill_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       COALESCE(
           (SELECT id FROM units WHERE legacy_id = NULLIF(s.unit_legacy_id, 0)),
           (
               SELECT u.id
               FROM goods g
               JOIN units u ON u.legacy_id = g.unit_legacy_id
                           AND u.is_deleted = FALSE
               WHERE g.legacy_id = s.goods_legacy_id
                 AND g.is_deleted = FALSE
                 AND COALESCE(s.unit_legacy_id, 0) = 0
                 AND COALESCE(s.unit_rate, 1) = 1
           )
       ),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original, s.amount_original,
       COALESCE(s.received_qty, 0), COALESCE(s.returned_qty, 0),
       (SELECT id FROM purchase_request_items WHERE legacy_id = s.request_item_legacy_id),
       s.deliver_date, s.weight, NULLIF(s.source_doc_no, ''),
       NULLIF(s.sales_order_no, ''), NULLIF(s.receipt_no, ''), NULLIF(s.production_plan_no, ''),
       (SELECT code FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT name FROM goods WHERE legacy_id = s.goods_legacy_id),
       'LEGACY_IMPORT', CASE WHEN a.status <> 0 THEN now() ELSE NULL END
FROM order_item_stage s JOIN order_stage a ON a.legacy_id = s.bill_legacy_id;

-- ---------------- 3. 采购收货单 ----------------
-- 采购员 = sman（业务员，老视图口径）；制单员/审核员名冻结自 Sys_Operator。
INSERT INTO purchase_receipts (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, currency_id, exchange_rate, tax_rate,
    sender_id, receiver_id, purchaser_id, maker_id, approver_id, remark, total_original, total_local, status, is_closed,
    sender_legacy_id, receiver_legacy_id, maker_legacy_id, approver_legacy_id, settlement_style_legacy,
    purchaser_legacy_id, maker_name, approver_name)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id),
       (SELECT id FROM warehouses WHERE legacy_id = s.warehouse_legacy_id),
       (SELECT id FROM currencies WHERE legacy_id = s.currency_legacy_id),
       COALESCE(s.exchange_rate, 1), s.tax_rate,
       NULL, NULL,
       (SELECT id FROM employees WHERE legacy_id = NULLIF(s.salesman_legacy, 0)),
       NULL, NULL,                         -- maker/approver UUID 待对齐
       s.remark, s.total_original, s.total_original, s.status, FALSE,
       NULLIF(s.sender_legacy, 0), NULLIF(s.receiver_legacy, 0),
       NULLIF(s.maker_legacy, 0), NULLIF(s.approver_legacy, 0),
       s.settlement_style_legacy,
       NULLIF(s.salesman_legacy, 0),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = s.maker_legacy),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = s.approver_legacy)
FROM receipt_stage s;

INSERT INTO purchase_receipt_items (
    legacy_id, bill_no, bill_date, receipt_id, order_item_id, line_no, goods_id, color_id, unit_id,
    unit_rate, qty, price, amount_original, amount_local, returned_qty, gift_qty, weight, source_doc_no,
    order_no, sales_order_no, production_plan_no,
    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM purchase_receipts WHERE legacy_id = s.bill_legacy_id),
       (SELECT id FROM purchase_order_items WHERE legacy_id = s.order_item_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       COALESCE(
           (SELECT id FROM units WHERE legacy_id = NULLIF(s.unit_legacy_id, 0)),
           (
               SELECT u.id
               FROM goods g
               JOIN units u ON u.legacy_id = g.unit_legacy_id
                           AND u.is_deleted = FALSE
               WHERE g.legacy_id = s.goods_legacy_id
                 AND g.is_deleted = FALSE
                 AND COALESCE(s.unit_legacy_id, 0) = 0
                 AND COALESCE(s.unit_rate, 1) = 1
           )
       ),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original, s.amount_original,
       COALESCE(s.returned_qty, 0), COALESCE(s.gift_qty, 0), s.weight, NULLIF(s.source_doc_no, ''),
       NULLIF(s.order_no, ''), NULLIF(s.sales_order_no, ''), NULLIF(s.production_plan_no, ''),
       (SELECT code FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT name FROM goods WHERE legacy_id = s.goods_legacy_id),
       'LEGACY_IMPORT', CASE WHEN a.status <> 0 THEN now() ELSE NULL END
FROM receipt_item_stage s JOIN receipt_stage a ON a.legacy_id = s.bill_legacy_id;

-- ---------------- 4. 采购退货单 ----------------
INSERT INTO purchase_returns (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, currency_id, exchange_rate, tax_rate,
    receiver_id, maker_id, approver_id, remark, total_original, total_local, status, is_closed,
    maker_legacy_id, approver_legacy_id, settlement_style_legacy, receiver_legacy_id,
    maker_name, approver_name)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id),
       (SELECT id FROM warehouses WHERE legacy_id = s.warehouse_legacy_id),
       (SELECT id FROM currencies WHERE legacy_id = s.currency_legacy_id),
       COALESCE(s.exchange_rate, 1), NULL,          -- P_Withdraw 无 TRate → tax_rate NULL
       NULL, NULL, NULL,                            -- receiver_id/maker_id/approver_id 待对齐（主表无 Receiver → receiver_legacy_id 恒 NULL）
       s.remark,
       s.total_original, s.total_original, s.status, FALSE,
       NULLIF(s.maker_legacy, 0), NULLIF(s.approver_legacy, 0), s.settlement_style_legacy, NULL,
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = s.maker_legacy),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = s.approver_legacy)
FROM return_stage s;

INSERT INTO purchase_return_items (
    legacy_id, bill_no, bill_date, return_id, receipt_item_id, order_item_id, line_no, goods_id, color_id,
    unit_id, unit_rate, qty, price, amount_original, amount_local, weight, source_doc_no,
    receipt_no, order_no, sales_order_no, production_plan_no,
    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM purchase_returns WHERE legacy_id = s.bill_legacy_id),
       (SELECT id FROM purchase_receipt_items WHERE legacy_id = s.receipt_item_legacy_id),
       (SELECT id FROM purchase_order_items WHERE legacy_id = s.order_item_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       COALESCE(
           (SELECT id FROM units WHERE legacy_id = NULLIF(s.unit_legacy_id, 0)),
           (
               SELECT u.id
               FROM goods g
               JOIN units u ON u.legacy_id = g.unit_legacy_id
                           AND u.is_deleted = FALSE
               WHERE g.legacy_id = s.goods_legacy_id
                 AND g.is_deleted = FALSE
                 AND COALESCE(s.unit_legacy_id, 0) = 0
                 AND COALESCE(s.unit_rate, 1) = 1
           )
       ),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original, s.amount_original,
       s.weight, NULLIF(s.source_doc_no, ''),
       NULLIF(s.receipt_no, ''), NULLIF(s.order_no, ''), NULLIF(s.sales_order_no, ''), NULLIF(s.production_plan_no, ''),
       (SELECT code FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT name FROM goods WHERE legacy_id = s.goods_legacy_id),
       'LEGACY_IMPORT', CASE WHEN a.status <> 0 THEN now() ELSE NULL END
FROM return_item_stage s JOIN return_stage a ON a.legacy_id = s.bill_legacy_id;

UPDATE purchase_orders d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.settlement_style_legacy;
UPDATE purchase_receipts d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.settlement_style_legacy;
UPDATE purchase_returns d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.settlement_style_legacy;

COMMIT;

-- ---------------- 校验 ----------------
SELECT '✔ 申请 ' || (SELECT count(*) FROM purchase_requests) || ' / ' || (SELECT count(*) FROM purchase_request_items) AS r
UNION ALL SELECT '订货 ' || (SELECT count(*) FROM purchase_orders) || ' / ' || (SELECT count(*) FROM purchase_order_items)
UNION ALL SELECT '收货 ' || (SELECT count(*) FROM purchase_receipts) || ' / ' || (SELECT count(*) FROM purchase_receipt_items)
UNION ALL SELECT '退货 ' || (SELECT count(*) FROM purchase_returns) || ' / ' || (SELECT count(*) FROM purchase_return_items)
UNION ALL SELECT '已审收货 ' || (SELECT count(*) FROM purchase_receipts WHERE status = 1)
UNION ALL SELECT '链路 收货明细挂订货 ' || (SELECT count(*) FROM purchase_receipt_items WHERE order_item_id IS NOT NULL)
UNION ALL SELECT '孤儿 收货明细(无货品) ' || (SELECT count(*) FROM purchase_receipt_items WHERE goods_id IS NULL)
UNION ALL SELECT '人员 订货 maker_legacy 非空 ' || (SELECT count(*) FROM purchase_orders WHERE maker_legacy_id IS NOT NULL)
UNION ALL SELECT '人员 制单员名冻结(订货) ' || (SELECT count(*) FROM purchase_orders WHERE maker_name IS NOT NULL)
UNION ALL SELECT '部门 申请单 department 非空 ' || (SELECT count(*) FROM purchase_requests WHERE department_legacy_id IS NOT NULL)
UNION ALL SELECT '部门 申请单 department UUID 已映射 ' || (SELECT count(*) FROM purchase_requests WHERE department_id IS NOT NULL)
UNION ALL SELECT '字典 老库部门 ' || (SELECT count(*) FROM legacy_departments)
UNION ALL SELECT '交货日期 申请明细非空 ' || (SELECT count(*) FROM purchase_request_items WHERE deliver_date IS NOT NULL)
UNION ALL SELECT '结帐 订货 settlement 非空 ' || (SELECT count(*) FROM purchase_orders WHERE settlement_style_legacy IS NOT NULL)
UNION ALL SELECT '结帐 收货 settlement 非空 ' || (SELECT count(*) FROM purchase_receipts WHERE settlement_style_legacy IS NOT NULL)
UNION ALL SELECT '结帐 退货 settlement 非空 ' || (SELECT count(*) FROM purchase_returns WHERE settlement_style_legacy IS NOT NULL)
UNION ALL SELECT '采购员 收货 sman 非空 ' || (SELECT count(*) FROM purchase_receipts WHERE purchaser_legacy_id IS NOT NULL)
UNION ALL SELECT '采购员 收货 UUID 已映射 ' || (SELECT count(*) FROM purchase_receipts WHERE purchaser_id IS NOT NULL)
UNION ALL SELECT '明细 申请 production_plan_no 非空 ' || (SELECT count(*) FROM purchase_request_items WHERE production_plan_no IS NOT NULL)
UNION ALL SELECT '待治理 采购全链明细单位无法确定 ' || (
    SELECT count(*)
    FROM (
        SELECT unit_id, unit_rate FROM purchase_request_items
        UNION ALL SELECT unit_id, unit_rate FROM purchase_order_items
        UNION ALL SELECT unit_id, unit_rate FROM purchase_receipt_items
        UNION ALL SELECT unit_id, unit_rate FROM purchase_return_items
    ) i
    WHERE i.unit_id IS NULL OR COALESCE(i.unit_rate, 1) <= 0
)
UNION ALL SELECT '阻塞MRP 未完成订货明细单位无法确定 ' || (
    SELECT count(*)
    FROM purchase_order_items i
    JOIN purchase_orders o ON o.id = i.order_id
    WHERE o.status = 1
      AND o.is_deleted = FALSE
      AND COALESCE(o.is_stopped, FALSE) = FALSE
      AND o.is_closed = FALSE
      AND i.is_deleted = FALSE
      AND GREATEST(COALESCE(i.qty, 0) - COALESCE(i.received_qty, 0), 0) > 0
      AND (i.unit_id IS NULL OR COALESCE(i.unit_rate, 1) <= 0)
);
