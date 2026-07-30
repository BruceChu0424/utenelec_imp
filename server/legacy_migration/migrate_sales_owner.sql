-- =====================================================================
-- 销售单据归属迁移：seller_legacy_id（老库 B_Worker.ID）→ owner_employee_id
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --sales-owner
-- 前提：销售单据已迁；employees 有 legacy_id；V91 已应用。
-- 规则：seller_legacy_id 非空非 0 且能对齐员工 → 归属；否则公共。
-- 幂等：先全量清零再灌入；HR 真员工替换 stub 后 legacy_id 不变，归属不断链。
-- =====================================================================

BEGIN;

-- Requires Flyway V137 or later: the final verification and refresh depend on
-- the owner-aware sales_monthly_mv definition.

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

-- Downstream documents inherit the owner of their linked upstream source.
-- Never silently choose one owner when legacy rows combine different owners.
DO $$
BEGIN
    IF EXISTS (
        SELECT si.shipment_id
        FROM sales_shipment_items si
        JOIN sales_order_items oi ON oi.id = si.order_item_id
        JOIN sales_orders o ON o.id = oi.order_id
        WHERE COALESCE(si.is_deleted,false)=false
          AND COALESCE(oi.is_deleted,false)=false
          AND COALESCE(o.is_deleted,false)=false
          AND o.owner_employee_id IS NOT NULL
        GROUP BY si.shipment_id
        HAVING COUNT(DISTINCT o.owner_employee_id) > 1
    ) THEN
        RAISE EXCEPTION
            'sales owner migration rejected: one shipment links orders owned by different employees';
    END IF;
END;
$$;

UPDATE sales_shipments shipment
SET owner_employee_id = source.owner_employee_id
FROM (
    SELECT si.shipment_id,
           MIN(o.owner_employee_id::text)::uuid AS owner_employee_id
    FROM sales_shipment_items si
    JOIN sales_order_items oi ON oi.id = si.order_item_id
    JOIN sales_orders o ON o.id = oi.order_id
    WHERE COALESCE(si.is_deleted,false)=false
      AND COALESCE(oi.is_deleted,false)=false
      AND COALESCE(o.is_deleted,false)=false
      AND o.owner_employee_id IS NOT NULL
    GROUP BY si.shipment_id
    HAVING COUNT(DISTINCT o.owner_employee_id) = 1
) source
WHERE shipment.id = source.shipment_id;

DO $$
BEGIN
    IF EXISTS (
        WITH return_source_owners AS (
            SELECT ri.return_id, shipment.owner_employee_id
            FROM sales_return_items ri
            JOIN sales_shipment_items si ON si.id = ri.out_item_id
            JOIN sales_shipments shipment ON shipment.id = si.shipment_id
            WHERE COALESCE(ri.is_deleted,false)=false
              AND COALESCE(si.is_deleted,false)=false
              AND COALESCE(shipment.is_deleted,false)=false
              AND shipment.owner_employee_id IS NOT NULL
            UNION ALL
            SELECT ri.return_id, sales_order.owner_employee_id
            FROM sales_return_items ri
            JOIN sales_order_items oi ON oi.id = ri.order_item_id
            JOIN sales_orders sales_order ON sales_order.id = oi.order_id
            WHERE COALESCE(ri.is_deleted,false)=false
              AND COALESCE(oi.is_deleted,false)=false
              AND COALESCE(sales_order.is_deleted,false)=false
              AND sales_order.owner_employee_id IS NOT NULL
        )
        SELECT return_id
        FROM return_source_owners
        GROUP BY return_id
        HAVING COUNT(DISTINCT owner_employee_id) > 1
    ) THEN
        RAISE EXCEPTION
            'sales owner migration rejected: one return links sources owned by different employees';
    END IF;
END;
$$;

UPDATE sales_returns sales_return
SET owner_employee_id = source.owner_employee_id
FROM (
    WITH return_source_owners AS (
        SELECT ri.return_id, shipment.owner_employee_id
        FROM sales_return_items ri
        JOIN sales_shipment_items si ON si.id = ri.out_item_id
        JOIN sales_shipments shipment ON shipment.id = si.shipment_id
        WHERE COALESCE(ri.is_deleted,false)=false
          AND COALESCE(si.is_deleted,false)=false
          AND COALESCE(shipment.is_deleted,false)=false
          AND shipment.owner_employee_id IS NOT NULL
        UNION ALL
        SELECT ri.return_id, sales_order.owner_employee_id
        FROM sales_return_items ri
        JOIN sales_order_items oi ON oi.id = ri.order_item_id
        JOIN sales_orders sales_order ON sales_order.id = oi.order_id
        WHERE COALESCE(ri.is_deleted,false)=false
          AND COALESCE(oi.is_deleted,false)=false
          AND COALESCE(sales_order.is_deleted,false)=false
          AND sales_order.owner_employee_id IS NOT NULL
    )
    SELECT return_id,
           MIN(owner_employee_id::text)::uuid AS owner_employee_id
    FROM return_source_owners
    GROUP BY return_id
    HAVING COUNT(DISTINCT owner_employee_id) = 1
) source
WHERE sales_return.id = source.return_id;

COMMIT;

-- migrate_sales.sql refreshes before HR/owner backfill in --bootstrap-all.
-- Refresh again after ownership is final so V137 cannot leave aggregates in
-- the legacy-public sentinel bucket after their headers become owned.
SELECT refresh_sales_monthly_mv();

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
    UNION ALL SELECT 7, '  MV owner buckets ' || count(DISTINCT owner_employee_id)
        FROM sales_monthly_mv
) t ORDER BY ord;
