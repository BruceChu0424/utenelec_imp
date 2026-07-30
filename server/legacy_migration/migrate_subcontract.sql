-- =====================================================================
-- Subcontract (outsourcing) 8 documents migration:
--   legacy E_* -> subcontract_* (17 tables: 8 main + 8 item + 1 BOM cost)
-- =====================================================================
-- Usage: bash server/legacy_migration/migrate.sh --subcontract
-- Prereq: V32/V38/V39/V40/V42/V43 master data already migrated.
--         V53 subcontract tables already created.
--         Purchase / warehouse migrations do NOT need to run first (no FK
--         cross-coupling; only stock_movements type namespace is shared).
--
-- Source CSVs (from export_subcontract_snippet.ps1 -> SubcontractData case):
--   subcontract_ask_{m,i}.csv                (E_Ask     0/0  rows)
--   subcontract_application_{m,i}.csv        (E_Application 0/0 rows)
--   subcontract_order_{m,i,cost_i}.csv       (E_Order / E_OrderItem / E_OrderCostItem 2/5/67)
--   subcontract_in_{m,i}.csv                 (E_In      10732/39093)
--   subcontract_sout_{m,i}.csv               (E_SOut    10627/49889)
--   subcontract_withdraw_{m,i}.csv           (E_WithDraw 442/1649)
--   subcontract_swithdraw_{m,i}.csv          (E_SWithDraw 65/112)
--   subcontract_swaste_{m,i}.csv             (E_SWaste  3/3)
--
-- [Idempotent / re-runnable] (user requirement)
--   Head: TRUNCATE 17 subcontract tables (reverse FK order, single shot
--   under session_replication_role=replica so FK triggers do not fire).
--   Re-run is safe; future snapshots just re-run.
--   Missing master rows (units/colors/warehouses/currencies/suppliers/goods)
--   auto-stubbed (mirrors migrate_stock_docs.sql convention).
--
-- [Structure] One TEMP staging table per CSV (\copy HEADER true, DELIMITER '|').
--   Insert order is FK-respecting:
--     orders / order_items / order_cost_items (self-FK resolved in 2 steps)
--     -> applications / application_items (0 rows; staging built, INSERT skipped)
--     -> inquiries    / inquiry_items     (0 rows; staging built, INSERT skipped)
--     -> material_issues / material_issue_items
--     -> receipts / receipt_items
--     -> returns / return_items
--     -> material_returns / material_return_items
--     -> wastes / waste_items
--   Each main+item INSERT JOINs master tables on legacy_id to map to new UUIDs.
--
-- [Personnel] maker/approver/sender/worker/purchaser/applicant: B_Worker and
--   employees have no legacy_id alignment, so all *_id UUID columns stay NULL
--   (same convention as purchase migration). Legacy personnel IDs are staged
--   for traceability but not inserted.
-- [Status] Legacy only has 1 (approved) / -1 (red pin); copied verbatim.
-- [Float -> numeric] All legacy float QTY/Price columns land as NUMERIC(18,4).
-- [Multi-currency] total_local = total_original (matching purchase convention;
--   legacy CRate rarely meaningful; finance recompute deferred to Service).
-- [E_InItem.OrderID] Frequently 0 (subcontract receipts not tied to orders):
--   the order_item_id subquery returns NULL, which is allowed (nullable FK).
-- [E_In.SenderID] Frequently NULL (outsourcer contact, not on employee table):
--   left NULL, this is the documented business reality.
-- [AR/AP ledger] Not migrated here (cash flow belongs to ar_ap_ledger module);
--   ap_posted stays FALSE on receipts/returns.
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
TRUNCATE
    subcontract_waste_items,             subcontract_wastes,
    subcontract_material_return_items,   subcontract_material_returns,
    subcontract_return_items,            subcontract_returns,
    subcontract_material_issue_items,    subcontract_material_issues,
    subcontract_receipt_items,           subcontract_receipts,
    subcontract_order_cost_items,        subcontract_order_items, subcontract_orders,
    subcontract_application_items,       subcontract_applications,
    subcontract_inquiry_items,           subcontract_inquiries;
SET session_replication_role = DEFAULT;

-- ============================ staging ============================
-- 1. E_Ask (0 rows; structure only). E_Ask has no Fulfill column.
CREATE TEMP TABLE inquiry_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int,
    maker_legacy int, approver_legacy int, status smallint,
    total_original numeric(18,4), stop_bit boolean, cancel_bit boolean, remark text);
\copy inquiry_stage FROM '/tmp/subcontract_ask_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE inquiry_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int,
    unit_legacy_id int, unit_rate numeric(18,6), price numeric(18,4), summary text);
\copy inquiry_item_stage FROM '/tmp/subcontract_ask_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- 2. E_Application (0 rows; structure only)
CREATE TEMP TABLE application_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int,
    sender_legacy int, maker_legacy int, approver_legacy int, last_date date,
    currency_legacy_id int, exchange_rate numeric(18,6), tax_rate numeric(18,4),
    status smallint, total_original numeric(18,4), cancel_bit boolean, remark text);
\copy application_stage FROM '/tmp/subcontract_application_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE application_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int,
    qty numeric(18,4), price numeric(18,4), amount_original numeric(18,4),
    order_item_legacy_id int, unit_legacy_id int, unit_rate numeric(18,6),
    check_qty numeric(18,4), weight numeric(18,4), source_doc_no text);
\copy application_item_stage FROM '/tmp/subcontract_application_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- 3. E_Order (2 rows) + E_OrderItem (5) + E_OrderCostItem (67)
CREATE TEMP TABLE order_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int,
    deliver_date date, send_legacy int, maker_legacy int, approver_legacy int,
    fulfill_bit boolean, stop_bit boolean, currency_legacy_id int,
    exchange_rate numeric(18,6), tax_rate numeric(18,4), total_original numeric(18,4),
    status smallint, cancel_bit boolean, remark text);
\copy order_stage FROM '/tmp/subcontract_order_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE order_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int,
    unit_legacy_id int, unit_rate numeric(18,6), qty numeric(18,4), price numeric(18,4),
    amount_original numeric(18,4), received_qty numeric(18,4), issued_qty numeric(18,4),
    returned_qty numeric(18,4), weight numeric(18,4), source_doc_no text);
\copy order_item_stage FROM '/tmp/subcontract_order_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE cost_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int,
    qty numeric(18,4), m_goods_legacy_id int, m_color_legacy_id int,
    parent_legacy_id int, unit_qty numeric(18,6), issued_qty numeric(18,4),
    returned_qty numeric(18,4), line_class text, bom_level int, source_doc_no text);
\copy cost_item_stage FROM '/tmp/subcontract_order_cost_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- 4. E_In (10732 rows, the largest)
CREATE TEMP TABLE receipt_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int,
    warehouse_legacy_id int, sender_legacy int, maker_legacy int, approver_legacy int,
    last_date date, currency_legacy_id int, exchange_rate numeric(18,6),
    tax_rate numeric(18,4), total_original numeric(18,4), settlement_style_legacy int,
    status smallint, cancel_bit boolean, remark text);
\copy receipt_stage FROM '/tmp/subcontract_in_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE receipt_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int,
    qty numeric(18,4), price numeric(18,4), amount_original numeric(18,4),
    order_item_legacy_id int, unit_legacy_id int, unit_rate numeric(18,6),
    amount_local numeric(18,4), check_qty numeric(18,4), order_qty numeric(18,4),
    returned_qty numeric(18,4), weight numeric(18,4), girth_qty numeric(18,4),
    step_legacy_id int, return_amount numeric(18,4), return_no text, order_no text,
    source_doc_no text);
\copy receipt_item_stage FROM '/tmp/subcontract_in_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- 5. E_SOut (10627 rows)
CREATE TEMP TABLE issue_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int,
    warehouse_legacy_id int, worker_legacy int, maker_legacy int, approver_legacy int,
    deliver_date date, status smallint, cancel_bit boolean, remark text);
\copy issue_stage FROM '/tmp/subcontract_sout_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE issue_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int,
    unit_legacy_id int, unit_rate numeric(18,6), qty numeric(18,4), stqty numeric(18,4),
    order_item_legacy_id int, amount_local numeric(18,4), returned_qty numeric(18,4),
    parent_goods_legacy_id int, parent_color_legacy_id int, weight numeric(18,4),
    return_no text, order_no text, source_doc_no text);
\copy issue_item_stage FROM '/tmp/subcontract_sout_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- 6. E_WithDraw (442 rows)
CREATE TEMP TABLE return_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int,
    warehouse_legacy_id int, maker_legacy int, approver_legacy int, last_date date,
    currency_legacy_id int, exchange_rate numeric(18,6), total_original numeric(18,4),
    settlement_style_legacy int, status smallint, cancel_bit boolean, remark text);
\copy return_stage FROM '/tmp/subcontract_withdraw_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE return_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int,
    qty numeric(18,4), price numeric(18,4), amount_original numeric(18,4),
    receipt_item_legacy_id int, order_item_legacy_id int, unit_legacy_id int,
    unit_rate numeric(18,6), amount_local numeric(18,4), weight numeric(18,4),
    girth_qty numeric(18,4), step_legacy_id int, receipt_no text, order_no text,
    source_doc_no text);
\copy return_item_stage FROM '/tmp/subcontract_withdraw_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- 7. E_SWithDraw (65 rows)
CREATE TEMP TABLE mreturn_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int,
    warehouse_legacy_id int, worker_legacy int, maker_legacy int, approver_legacy int,
    b_style int, status smallint, cancel_bit boolean, remark text);
\copy mreturn_stage FROM '/tmp/subcontract_swithdraw_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE mreturn_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int,
    unit_legacy_id int, unit_rate numeric(18,6), qty numeric(18,4),
    material_issue_item_legacy_id int, order_item_legacy_id int,
    amount_local numeric(18,4), parent_goods_legacy_id int, parent_color_legacy_id int,
    weight numeric(18,4), girth_qty numeric(18,4), issue_no text, order_no text,
    source_doc_no text);
\copy mreturn_item_stage FROM '/tmp/subcontract_swithdraw_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- 8. E_SWaste (3 rows)
CREATE TEMP TABLE waste_stage (
    legacy_id int, bill_no text, bill_date date, supplier_legacy_id int,
    warehouse_legacy_id int, worker_legacy int, maker_legacy int, approver_legacy int,
    total_weight numeric(18,4), status smallint, cancel_bit boolean, remark text);
\copy waste_stage FROM '/tmp/subcontract_swaste_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE waste_item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int,
    unit_legacy_id int, unit_rate numeric(18,6), qty numeric(18,4),
    ending_qty numeric(18,4), standard_qty numeric(18,4), waste_rate numeric(8,4),
    cause text, material_issue_item_legacy_id int, amount_local numeric(18,4),
    weight numeric(18,4), source_doc_no text);
\copy waste_item_stage FROM '/tmp/subcontract_swaste_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- 9. 人员参考：B_Worker（收货人/经办人→employees stub）+ Sys_Operator（制单员/审核员→冻结名）
CREATE TEMP TABLE worker_ref_stage (legacy_id int, name text);
\copy worker_ref_stage FROM '/tmp/legacy_workers_ref.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE operator_ref_stage (legacy_id int, name text);
\copy operator_ref_stage FROM '/tmp/legacy_operators_ref.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- ============================ employees stub：B_Worker（真实员工=收货人/经办人）→ employees ============================
-- 用户钦定"老库有、新库没有就在员工表添加、显示名字"。B_Worker 72 行真实员工建 stub：
--   legacy_id = B_Worker.ID（融合键），full_name = Emp_Name，code='LEGACY-W-<id>'，
--   status='resigned'（老库很多人离职，默认离职；用户以后在员工档案激活/补全真实信息），
--   department_id=DEPT_SALES（委外归综合营销部），hire_date 占位，employment_type='regular'。
-- NOT EXISTS 守卫：用户已录真员工（同 legacy_id）优先，绝不覆盖；故重跑幂等、与真名单可融合。
-- Sys_Operator（制单员/审核员）不入 employees（避免与 B_Worker 撞号 + 登录账号非员工档案实体），
--   其 fname 在下方单据 INSERT 时冻结进 maker_name/approver_name 文本列。
INSERT INTO employees (legacy_id, code, full_name, id_type, department_id, hire_date, status, employment_type)
SELECT w.legacy_id, 'LEGACY-W-' || w.legacy_id, w.name, '其他',
       (SELECT id FROM departments WHERE code = 'DEPT_SALES'), DATE '2000-01-01', 'resigned', 'regular'
FROM worker_ref_stage w
WHERE w.legacy_id IS NOT NULL AND w.legacy_id <> 0
  AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.legacy_id = w.legacy_id);

-- ============================ auto-stub missing masters ============================
-- (Same convention as migrate_stock_docs.sql / migrate_purchase.sql.)
-- Legacy 0 / NULL means "no reference" and is NOT stubbed.

-- Goods (goods table has no NOT-NULL-no-default column; minimal stub: legacy_id+name)
INSERT INTO goods (legacy_id, name)
SELECT DISTINCT lid, '(migration auto-stub legacy ' || lid || ')'
FROM (SELECT goods_legacy_id AS lid FROM inquiry_item_stage UNION ALL
      SELECT goods_legacy_id FROM application_item_stage UNION ALL
      SELECT goods_legacy_id FROM order_item_stage UNION ALL
      SELECT goods_legacy_id FROM cost_item_stage UNION ALL
      SELECT goods_legacy_id FROM receipt_item_stage UNION ALL
      SELECT goods_legacy_id FROM issue_item_stage UNION ALL
      SELECT goods_legacy_id FROM return_item_stage UNION ALL
      SELECT goods_legacy_id FROM mreturn_item_stage UNION ALL
      SELECT goods_legacy_id FROM waste_item_stage UNION ALL
      SELECT m_goods_legacy_id FROM cost_item_stage UNION ALL
      SELECT parent_goods_legacy_id FROM issue_item_stage UNION ALL
      SELECT parent_goods_legacy_id FROM mreturn_item_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM goods g WHERE g.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- Units (no auto_created column; LEGACY-U- prefix marks stubs)
INSERT INTO units (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-U-' || lid, '(migration auto-stub)', 'in-use'
FROM (SELECT unit_legacy_id AS lid FROM inquiry_item_stage UNION ALL
      SELECT unit_legacy_id FROM application_item_stage UNION ALL
      SELECT unit_legacy_id FROM order_item_stage UNION ALL
      SELECT unit_legacy_id FROM receipt_item_stage UNION ALL
      SELECT unit_legacy_id FROM issue_item_stage UNION ALL
      SELECT unit_legacy_id FROM return_item_stage UNION ALL
      SELECT unit_legacy_id FROM mreturn_item_stage UNION ALL
      SELECT unit_legacy_id FROM waste_item_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM units u WHERE u.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- Colors (0 = no color, never stubbed)
INSERT INTO colors (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-C-' || lid, '(migration auto-stub)', 'in-use'
FROM (SELECT color_legacy_id AS lid FROM inquiry_item_stage UNION ALL
      SELECT color_legacy_id FROM application_item_stage UNION ALL
      SELECT color_legacy_id FROM order_item_stage UNION ALL
      SELECT color_legacy_id FROM cost_item_stage UNION ALL
      SELECT color_legacy_id FROM receipt_item_stage UNION ALL
      SELECT color_legacy_id FROM issue_item_stage UNION ALL
      SELECT color_legacy_id FROM return_item_stage UNION ALL
      SELECT color_legacy_id FROM mreturn_item_stage UNION ALL
      SELECT color_legacy_id FROM waste_item_stage UNION ALL
      SELECT m_color_legacy_id FROM cost_item_stage UNION ALL
      SELECT parent_color_legacy_id FROM issue_item_stage UNION ALL
      SELECT parent_color_legacy_id FROM mreturn_item_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM colors c WHERE c.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- Warehouses (from main tables that have StockID: E_In/E_SOut/E_WithDraw/E_SWithDraw/E_SWaste.
-- E_Ask/E_Application/E_Order have no StockID column -> their stages have no warehouse_legacy_id.)
INSERT INTO warehouses (legacy_id, code, name, status, is_accountable, auto_created)
SELECT DISTINCT lid, 'LEGACY-W-' || lid, '(migration auto-stub)', 'in-use', TRUE, TRUE
FROM (SELECT warehouse_legacy_id AS lid FROM receipt_stage UNION ALL
      SELECT warehouse_legacy_id FROM issue_stage UNION ALL
      SELECT warehouse_legacy_id FROM return_stage UNION ALL
      SELECT warehouse_legacy_id FROM mreturn_stage UNION ALL
      SELECT warehouse_legacy_id FROM waste_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM warehouses w WHERE w.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- Currencies (from main tables with currency)
INSERT INTO currencies (legacy_id, code, name, exchange_rate, status, auto_created)
SELECT DISTINCT lid, 'LEGACY-CUR-' || lid, '(migration auto-stub)', 1, 'in-use', TRUE
FROM (SELECT currency_legacy_id AS lid FROM application_stage UNION ALL
      SELECT currency_legacy_id FROM order_stage UNION ALL
      SELECT currency_legacy_id FROM receipt_stage UNION ALL
      SELECT currency_legacy_id FROM return_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM currencies c WHERE c.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- Suppliers (386 rows already migrated in V38; VendID sampled 100% hit.
-- Stub guard for any orphan VendID pointing to a soft-deleted supplier.)
INSERT INTO suppliers (legacy_id, code, name)
SELECT DISTINCT lid, 'LEGACY-S-' || lid, '(migration auto-stub legacy ' || lid || ')'
FROM (SELECT supplier_legacy_id AS lid FROM inquiry_stage UNION ALL
      SELECT supplier_legacy_id FROM application_stage UNION ALL
      SELECT supplier_legacy_id FROM order_stage UNION ALL
      SELECT supplier_legacy_id FROM receipt_stage UNION ALL
      SELECT supplier_legacy_id FROM issue_stage UNION ALL
      SELECT supplier_legacy_id FROM return_stage UNION ALL
      SELECT supplier_legacy_id FROM mreturn_stage UNION ALL
      SELECT supplier_legacy_id FROM waste_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM suppliers s WHERE s.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- ============================ 1. subcontract_orders (+ items + cost items) ============================
INSERT INTO subcontract_orders (
    legacy_id, bill_no, bill_date, supplier_id, currency_id, exchange_rate, tax_rate,
    deliver_date, remark, total_original, total_local, status, fulfill, is_closed)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id),
       (SELECT id FROM currencies WHERE legacy_id = s.currency_legacy_id),
       COALESCE(s.exchange_rate, 1), s.tax_rate, s.deliver_date, s.remark,
       s.total_original, s.total_original, s.status,
       COALESCE(s.fulfill_bit, FALSE), COALESCE(s.fulfill_bit, FALSE)
FROM order_stage s;

INSERT INTO subcontract_order_items (
    legacy_id, bill_no, bill_date, order_id, line_no, goods_id, color_id, unit_id, unit_rate,
    qty, price, amount_original, amount_local, received_qty, returned_qty, issued_qty,
    deliver_date, weight, source_doc_no)
SELECT s.legacy_id, o.bill_no, o.bill_date,
       (SELECT id FROM subcontract_orders WHERE legacy_id = s.bill_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_original, s.amount_original,
       COALESCE(s.received_qty, 0), COALESCE(s.returned_qty, 0), COALESCE(s.issued_qty, 0),
       NULL, s.weight, NULLIF(s.source_doc_no, '')
FROM order_item_stage s JOIN order_stage o ON o.legacy_id = s.bill_legacy_id;

-- Cost items: insert with parent_cost_item_id = NULL first (self-FK is checked
-- at statement end; subquery against the same INSERT is not visible), then UPDATE.
-- E_OrderCostItem.BillID points to E_OrderItem.ID (NOT E_Order.ID) — verified
-- against legacy: all 67 cost rows JOIN to E_OrderItem (0 to E_Order). So we
-- chain cost -> order_item -> order to derive order_id, bill_no, bill_date.
INSERT INTO subcontract_order_cost_items (
    legacy_id, bill_no, bill_date, order_id, order_item_id, bom_level,
    parent_goods_id, parent_color_id, goods_id, color_id, unit_qty, qty,
    issued_qty, returned_qty, line_class, source_doc_no)
SELECT s.legacy_id, o.bill_no, o.bill_date,
       (SELECT id FROM subcontract_orders WHERE legacy_id = o.legacy_id),
       (SELECT id FROM subcontract_order_items WHERE legacy_id = s.bill_legacy_id),
       s.bom_level,
       (SELECT id FROM goods  WHERE legacy_id = s.m_goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.m_color_legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       s.unit_qty, s.qty, COALESCE(s.issued_qty, 0), COALESCE(s.returned_qty, 0),
       s.line_class, NULLIF(s.source_doc_no, '')
FROM cost_item_stage s
JOIN order_item_stage oi ON oi.legacy_id = s.bill_legacy_id
JOIN order_stage o ON o.legacy_id = oi.bill_legacy_id;

-- Resolve self-FK parent_cost_item_id now that all cost rows are inserted.
UPDATE subcontract_order_cost_items ci
SET parent_cost_item_id = p.id
FROM cost_item_stage s, subcontract_order_cost_items p
WHERE ci.legacy_id = s.legacy_id
  AND s.parent_legacy_id <> 0
  AND p.legacy_id = s.parent_legacy_id;

-- ============================ 2. subcontract_applications (0 rows; staging built, INSERT skipped) =====
-- Legacy E_Application / E_ApplicationItem are empty; structure-only. Re-enable
-- these INSERTs if the source tables ever get data:
-- INSERT INTO subcontract_applications (...) SELECT ... FROM application_stage s;
-- INSERT INTO subcontract_application_items (...) SELECT ... FROM application_item_stage s JOIN application_stage a ON a.legacy_id = s.bill_legacy_id;

-- ============================ 3. subcontract_inquiries (0 rows; staging built, INSERT skipped) =====
-- Legacy E_Ask / E_AskItem are empty; structure-only. Re-enable these INSERTs
-- if the source tables ever get data:
-- INSERT INTO subcontract_inquiries (...) SELECT ... FROM inquiry_stage s;
-- INSERT INTO subcontract_inquiry_items (...) SELECT ... FROM inquiry_item_stage s JOIN inquiry_stage a ON a.legacy_id = s.bill_legacy_id;

-- ============================ 4. subcontract_material_issues ============================
INSERT INTO subcontract_material_issues (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, deliver_date, remark,
    total_original, total_local, status, is_closed,
    operator_legacy_id, operator_name, maker_legacy_id, maker_name, approver_legacy_id, approver_name)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id),
       (SELECT id FROM warehouses WHERE legacy_id = s.warehouse_legacy_id),
       s.deliver_date, s.remark,
       0, 0, s.status, FALSE,  -- E_SOut has no currency/Total; amount_local recomputed by Service
       NULLIF(s.worker_legacy, 0),
       (SELECT name FROM worker_ref_stage w WHERE w.legacy_id = NULLIF(s.worker_legacy, 0)),
       NULLIF(s.maker_legacy, 0),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = NULLIF(s.maker_legacy, 0)),
       NULLIF(s.approver_legacy, 0),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = NULLIF(s.approver_legacy, 0))
FROM issue_stage s;

INSERT INTO subcontract_material_issue_items (
    legacy_id, bill_no, bill_date, issue_id, order_item_id, line_no, goods_id, color_id,
    unit_id, unit_rate, qty, amount_local, returned_qty, parent_goods_id, parent_color_id,
    weight, return_no, order_no, source_doc_no)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM subcontract_material_issues WHERE legacy_id = s.bill_legacy_id),
       (SELECT id FROM subcontract_order_items WHERE legacy_id = s.order_item_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1), COALESCE(s.stqty, s.qty), s.amount_local,
       COALESCE(s.returned_qty, 0),
       (SELECT id FROM goods  WHERE legacy_id = s.parent_goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.parent_color_legacy_id),
       s.weight, NULLIF(s.return_no, ''), NULLIF(s.order_no, ''), NULLIF(s.source_doc_no, '')
FROM issue_item_stage s JOIN issue_stage a ON a.legacy_id = s.bill_legacy_id;

-- ============================ 5. subcontract_receipts ============================
INSERT INTO subcontract_receipts (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, currency_id, exchange_rate,
    tax_rate, last_date, remark, total_original, total_local, status, is_closed,
    settlement_style_legacy, receiver_legacy_id, receiver_name,
    maker_legacy_id, maker_name, approver_legacy_id, approver_name)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers   WHERE legacy_id = s.supplier_legacy_id),
       (SELECT id FROM warehouses  WHERE legacy_id = s.warehouse_legacy_id),
       (SELECT id FROM currencies  WHERE legacy_id = s.currency_legacy_id),
       COALESCE(s.exchange_rate, 1), s.tax_rate, s.last_date, s.remark,
       s.total_original, s.total_original, s.status, FALSE,
       NULLIF(s.settlement_style_legacy, 0),
       NULLIF(s.sender_legacy, 0),
       (SELECT name FROM worker_ref_stage w WHERE w.legacy_id = NULLIF(s.sender_legacy, 0)),
       NULLIF(s.maker_legacy, 0),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = NULLIF(s.maker_legacy, 0)),
       NULLIF(s.approver_legacy, 0),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = NULLIF(s.approver_legacy, 0))
FROM receipt_stage s;

INSERT INTO subcontract_receipt_items (
    legacy_id, bill_no, bill_date, receipt_id, order_item_id, line_no, goods_id, color_id,
    unit_id, unit_rate, qty, price, amount_original, amount_local, check_qty, order_qty,
    returned_qty, weight, girth_qty, step_legacy_id, return_amount, return_no, order_no,
    source_doc_no)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM subcontract_receipts WHERE legacy_id = s.bill_legacy_id),
       (SELECT id FROM subcontract_order_items WHERE legacy_id = s.order_item_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_local, s.amount_local,
       s.check_qty, s.order_qty, COALESCE(s.returned_qty, 0), s.weight,
       s.girth_qty, NULLIF(s.step_legacy_id, 0), s.return_amount,
       NULLIF(s.return_no, ''), NULLIF(s.order_no, ''), NULLIF(s.source_doc_no, '')
FROM receipt_item_stage s JOIN receipt_stage a ON a.legacy_id = s.bill_legacy_id;

-- ============================ 6. subcontract_returns ============================
INSERT INTO subcontract_returns (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, currency_id, exchange_rate,
    tax_rate, last_date, remark, total_original, total_local, status, is_closed,
    settlement_style_legacy, maker_legacy_id, maker_name, approver_legacy_id, approver_name)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers   WHERE legacy_id = s.supplier_legacy_id),
       (SELECT id FROM warehouses  WHERE legacy_id = s.warehouse_legacy_id),
       (SELECT id FROM currencies  WHERE legacy_id = s.currency_legacy_id),
       COALESCE(s.exchange_rate, 1), NULL, s.last_date, s.remark,  -- E_WithDraw has no TRate
       s.total_original, s.total_original, s.status, FALSE,
       NULLIF(s.settlement_style_legacy, 0),
       NULLIF(s.maker_legacy, 0),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = NULLIF(s.maker_legacy, 0)),
       NULLIF(s.approver_legacy, 0),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = NULLIF(s.approver_legacy, 0))
FROM return_stage s;

INSERT INTO subcontract_return_items (
    legacy_id, bill_no, bill_date, return_id, receipt_item_id, order_item_id, line_no,
    goods_id, color_id, unit_id, unit_rate, qty, price, amount_original, amount_local,
    weight, girth_qty, step_legacy_id, receipt_no, order_no, source_doc_no)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM subcontract_returns WHERE legacy_id = s.bill_legacy_id),
       (SELECT id FROM subcontract_receipt_items WHERE legacy_id = s.receipt_item_legacy_id),
       (SELECT id FROM subcontract_order_items  WHERE legacy_id = s.order_item_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1), s.qty, s.price, s.amount_local, s.amount_local,
       s.weight, s.girth_qty, NULLIF(s.step_legacy_id, 0),
       NULLIF(s.receipt_no, ''), NULLIF(s.order_no, ''), NULLIF(s.source_doc_no, '')
FROM return_item_stage s JOIN return_stage a ON a.legacy_id = s.bill_legacy_id;

-- ============================ 7. subcontract_material_returns ============================
INSERT INTO subcontract_material_returns (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, b_style, remark,
    total_original, total_local, status, is_closed,
    operator_legacy_id, operator_name, maker_legacy_id, maker_name, approver_legacy_id, approver_name)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers   WHERE legacy_id = s.supplier_legacy_id),
       (SELECT id FROM warehouses  WHERE legacy_id = s.warehouse_legacy_id),
       s.b_style, s.remark,
       0, 0, s.status, FALSE,  -- E_SWithDraw has no currency/Total; amount_local recomputed by Service
       NULLIF(s.worker_legacy, 0),
       (SELECT name FROM worker_ref_stage w WHERE w.legacy_id = NULLIF(s.worker_legacy, 0)),
       NULLIF(s.maker_legacy, 0),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = NULLIF(s.maker_legacy, 0)),
       NULLIF(s.approver_legacy, 0),
       (SELECT name FROM operator_ref_stage op WHERE op.legacy_id = NULLIF(s.approver_legacy, 0))
FROM mreturn_stage s;

INSERT INTO subcontract_material_return_items (
    legacy_id, bill_no, bill_date, material_return_id, material_issue_item_id, order_item_id,
    line_no, goods_id, color_id, unit_id, unit_rate, qty, amount_local, parent_goods_id,
    parent_color_id, weight, girth_qty, issue_no, order_no, source_doc_no)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM subcontract_material_returns WHERE legacy_id = s.bill_legacy_id),
       (SELECT id FROM subcontract_material_issue_items WHERE legacy_id = s.material_issue_item_legacy_id),
       (SELECT id FROM subcontract_order_items         WHERE legacy_id = s.order_item_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1), s.qty, s.amount_local,
       (SELECT id FROM goods  WHERE legacy_id = s.parent_goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.parent_color_legacy_id),
       s.weight, s.girth_qty, NULLIF(s.issue_no, ''), NULLIF(s.order_no, ''),
       NULLIF(s.source_doc_no, '')
FROM mreturn_item_stage s JOIN mreturn_stage a ON a.legacy_id = s.bill_legacy_id;

-- ============================ 8. subcontract_wastes ============================
INSERT INTO subcontract_wastes (
    legacy_id, bill_no, bill_date, supplier_id, warehouse_id, total_weight, remark,
    total_original, total_local, status, is_closed)
SELECT s.legacy_id, s.bill_no, s.bill_date,
       (SELECT id FROM suppliers   WHERE legacy_id = s.supplier_legacy_id),
       (SELECT id FROM warehouses  WHERE legacy_id = s.warehouse_legacy_id),
       s.total_weight, s.remark,
       0, 0, s.status, FALSE  -- E_SWaste has no currency/Total; amount_local recomputed by Service
FROM waste_stage s;

INSERT INTO subcontract_waste_items (
    legacy_id, bill_no, bill_date, waste_id, material_issue_item_id, line_no, goods_id,
    color_id, unit_id, unit_rate, qty, ending_qty, standard_qty, waste_rate, cause,
    price, amount_original, amount_local, weight, source_doc_no)
SELECT s.legacy_id, a.bill_no, a.bill_date,
       (SELECT id FROM subcontract_wastes WHERE legacy_id = s.bill_legacy_id),
       (SELECT id FROM subcontract_material_issue_items WHERE legacy_id = s.material_issue_item_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1), s.qty, s.ending_qty, s.standard_qty, s.waste_rate, s.cause,
       NULL, NULL, s.amount_local, s.weight, NULLIF(s.source_doc_no, '')
FROM waste_item_stage s JOIN waste_stage a ON a.legacy_id = s.bill_legacy_id;

COMMIT;

-- ============================ 刷新委外月度物化视图（防汇总报表空，同 sales/stock 修复） ============================
REFRESH MATERIALIZED VIEW subcontract_monthly_mv;

-- ============================ validation ============================
-- Row counts (17 tables; empty ones are expected to be 0)
SELECT 'inquiry        ' || (SELECT count(*) FROM subcontract_inquiries)            || ' / ' || (SELECT count(*) FROM subcontract_inquiry_items)        AS r
UNION ALL SELECT 'application    ' || (SELECT count(*) FROM subcontract_applications)         || ' / ' || (SELECT count(*) FROM subcontract_application_items)
UNION ALL SELECT 'order          ' || (SELECT count(*) FROM subcontract_orders)               || ' / ' || (SELECT count(*) FROM subcontract_order_items)
UNION ALL SELECT 'order_cost_item ' || (SELECT count(*) FROM subcontract_order_cost_items)
UNION ALL SELECT 'receipt        ' || (SELECT count(*) FROM subcontract_receipts)             || ' / ' || (SELECT count(*) FROM subcontract_receipt_items)
UNION ALL SELECT 'material_issue ' || (SELECT count(*) FROM subcontract_material_issues)      || ' / ' || (SELECT count(*) FROM subcontract_material_issue_items)
UNION ALL SELECT 'return         ' || (SELECT count(*) FROM subcontract_returns)              || ' / ' || (SELECT count(*) FROM subcontract_return_items)
UNION ALL SELECT 'material_return ' || (SELECT count(*) FROM subcontract_material_returns)    || ' / ' || (SELECT count(*) FROM subcontract_material_return_items)
UNION ALL SELECT 'waste          ' || (SELECT count(*) FROM subcontract_wastes)               || ' / ' || (SELECT count(*) FROM subcontract_waste_items)
-- Specific legacy counts (must match: E_Order=2 / E_OrderCostItem=67 / E_SWaste=3)
UNION ALL SELECT 'ASSERT order=2          ' || (SELECT count(*) FROM subcontract_orders)              || CASE WHEN (SELECT count(*) FROM subcontract_orders) = 2 THEN ' OK' ELSE ' MISMATCH' END
UNION ALL SELECT 'ASSERT order_cost=67    ' || (SELECT count(*) FROM subcontract_order_cost_items)   || CASE WHEN (SELECT count(*) FROM subcontract_order_cost_items) = 67 THEN ' OK' ELSE ' MISMATCH' END
UNION ALL SELECT 'ASSERT waste=3          ' || (SELECT count(*) FROM subcontract_wastes)             || CASE WHEN (SELECT count(*) FROM subcontract_wastes) = 3 THEN ' OK' ELSE ' MISMATCH' END
-- 7 real-FK linkup rates (NULL is allowed and expected where legacy OrderID/InID/EOutID/OutID = 0)
UNION ALL SELECT 'FK receipt_item -> order_item      ' || (SELECT count(*) FROM subcontract_receipt_items       WHERE order_item_id IS NOT NULL)
UNION ALL SELECT 'FK return_item  -> receipt_item    ' || (SELECT count(*) FROM subcontract_return_items        WHERE receipt_item_id IS NOT NULL)
UNION ALL SELECT 'FK return_item  -> order_item      ' || (SELECT count(*) FROM subcontract_return_items        WHERE order_item_id IS NOT NULL)
UNION ALL SELECT 'FK issue_item   -> order_item      ' || (SELECT count(*) FROM subcontract_material_issue_items WHERE order_item_id IS NOT NULL)
UNION ALL SELECT 'FK mreturn_item -> issue_item      ' || (SELECT count(*) FROM subcontract_material_return_items WHERE material_issue_item_id IS NOT NULL)
UNION ALL SELECT 'FK mreturn_item -> order_item      ' || (SELECT count(*) FROM subcontract_material_return_items WHERE order_item_id IS NOT NULL)
UNION ALL SELECT 'FK waste_item   -> issue_item      ' || (SELECT count(*) FROM subcontract_waste_items        WHERE material_issue_item_id IS NOT NULL)
-- Orphan guards (goods_id is NOT NULL -> these must be 0)
UNION ALL SELECT 'ORPHAN receipt_item (no goods)     ' || (SELECT count(*) FROM subcontract_receipt_items       WHERE goods_id IS NULL)
UNION ALL SELECT 'ORPHAN issue_item   (no goods)     ' || (SELECT count(*) FROM subcontract_material_issue_items WHERE goods_id IS NULL)
UNION ALL SELECT 'ORPHAN cost_item    (no goods)     ' || (SELECT count(*) FROM subcontract_order_cost_items  WHERE goods_id IS NULL)
-- Self-FK on cost_items (parent_cost_item_id resolved in UPDATE step)
UNION ALL SELECT 'cost_item parent linked            ' || (SELECT count(*) FROM subcontract_order_cost_items  WHERE parent_cost_item_id IS NOT NULL)
-- 人员 stub + 报表新列非空率（V66 报表补列）
UNION ALL SELECT 'employees stub (B_Worker)          ' || (SELECT count(*) FROM employees WHERE code LIKE 'LEGACY-W-%')
UNION ALL SELECT 'receipts settlement_style 非空     ' || (SELECT count(*) FROM subcontract_receipts WHERE settlement_style_legacy IS NOT NULL)
UNION ALL SELECT 'receipts receiver_legacy 非空      ' || (SELECT count(*) FROM subcontract_receipts WHERE receiver_legacy_id IS NOT NULL)
UNION ALL SELECT 'receipts receiver_name 命中        ' || (SELECT count(*) FROM subcontract_receipts WHERE receiver_name IS NOT NULL)
UNION ALL SELECT 'receipts maker_name 命中           ' || (SELECT count(*) FROM subcontract_receipts WHERE maker_name IS NOT NULL)
UNION ALL SELECT 'receipt_items girth 非空           ' || (SELECT count(*) FROM subcontract_receipt_items WHERE girth_qty IS NOT NULL)
UNION ALL SELECT 'receipt_items step 非空            ' || (SELECT count(*) FROM subcontract_receipt_items WHERE step_legacy_id IS NOT NULL)
UNION ALL SELECT 'receipt_items return_no 非空       ' || (SELECT count(*) FROM subcontract_receipt_items WHERE return_no IS NOT NULL)
UNION ALL SELECT 'material_issues operator_name 命中 ' || (SELECT count(*) FROM subcontract_material_issues WHERE operator_name IS NOT NULL)
UNION ALL SELECT 'returns settlement_style 非空      ' || (SELECT count(*) FROM subcontract_returns WHERE settlement_style_legacy IS NOT NULL)
UNION ALL SELECT 'returns maker/approver name 命中   ' || (SELECT count(*) FROM subcontract_returns WHERE maker_name IS NOT NULL OR approver_name IS NOT NULL);
