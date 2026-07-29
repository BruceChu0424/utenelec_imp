-- =====================================================================
-- 销售单据归属迁移：seller_legacy_id（老库 B_Worker.ID）→ owner_employee_id
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --sales-owner
-- 前提：销售单据已迁；employees 有 legacy_id；V91 已应用。
-- 规则：seller_legacy_id 非空非 0 且能对齐员工 → 归属；否则公共。
-- 幂等：先全量清零再灌入；HR 真员工替换 stub 后 legacy_id 不变，归属不断链。
-- =====================================================================

BEGIN;

UPDATE sales_orders          SET owner_employee_id = NULL WHERE owner_employee_id IS NOT NULL;
UPDATE sales_shipments       SET owner_employee_id = NULL WHERE owner_employee_id IS NOT NULL;
UPDATE sales_other_shipments SET owner_employee_id = NULL WHERE owner_employee_id IS NOT NULL;
UPDATE sales_returns         SET owner_employee_id = NULL WHERE owner_employee_id IS NOT NULL;

UPDATE sales_orders t SET owner_employee_id = e.id
FROM employees e WHERE t.seller_legacy_id IS NOT NULL AND t.seller_legacy_id <> 0
  AND e.legacy_id = t.seller_legacy_id;
UPDATE sales_shipments t SET owner_employee_id = e.id
FROM employees e WHERE t.seller_legacy_id IS NOT NULL AND t.seller_legacy_id <> 0
  AND e.legacy_id = t.seller_legacy_id;
UPDATE sales_other_shipments t SET owner_employee_id = e.id
FROM employees e WHERE t.seller_legacy_id IS NOT NULL AND t.seller_legacy_id <> 0
  AND e.legacy_id = t.seller_legacy_id;
UPDATE sales_returns t SET owner_employee_id = e.id
FROM employees e WHERE t.seller_legacy_id IS NOT NULL AND t.seller_legacy_id <> 0
  AND e.legacy_id = t.seller_legacy_id;

COMMIT;

-- ---------------- 校验 ----------------
SELECT r FROM (
    SELECT 1 AS ord, '✔ 订货 ' || count(*) AS r FROM sales_orders WHERE owner_employee_id IS NOT NULL
    UNION ALL SELECT 2, '  出货 ' || count(*) FROM sales_shipments WHERE owner_employee_id IS NOT NULL
    UNION ALL SELECT 3, '  其它出货 ' || count(*) FROM sales_other_shipments WHERE owner_employee_id IS NOT NULL
    UNION ALL SELECT 4, '  退货 ' || count(*) FROM sales_returns WHERE owner_employee_id IS NOT NULL
    UNION ALL SELECT 5, '  归属落空（seller 对员工不上，转公共） ' || (
        (SELECT count(*) FROM sales_orders WHERE seller_legacy_id IS NOT NULL AND seller_legacy_id<>0 AND owner_employee_id IS NULL) +
        (SELECT count(*) FROM sales_shipments WHERE seller_legacy_id IS NOT NULL AND seller_legacy_id<>0 AND owner_employee_id IS NULL) +
        (SELECT count(*) FROM sales_other_shipments WHERE seller_legacy_id IS NOT NULL AND seller_legacy_id<>0 AND owner_employee_id IS NULL) +
        (SELECT count(*) FROM sales_returns WHERE seller_legacy_id IS NOT NULL AND seller_legacy_id<>0 AND owner_employee_id IS NULL))::text
    UNION ALL SELECT 6, '  归属 TOP：' || string_agg(x.s, ' · ')
        FROM (SELECT e.full_name || ' ' || count(*) AS s
              FROM sales_orders t JOIN employees e ON e.id = t.owner_employee_id
              GROUP BY e.full_name ORDER BY count(*) DESC LIMIT 5) x
) t ORDER BY ord;
