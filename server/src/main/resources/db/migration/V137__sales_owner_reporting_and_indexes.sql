-- Sales-document ownership is a first-class reporting dimension.
--
-- Legacy rows without an owner remain visible to ordinary sales users.  The
-- materialized view therefore stores NULL ownership as the nil UUID so the
-- ownership column is non-null and can participate in the unique index needed
-- by REFRESH MATERIALIZED VIEW CONCURRENTLY.

DROP MATERIALIZED VIEW sales_monthly_mv;

CREATE MATERIALIZED VIEW sales_monthly_mv AS
SELECT 'QUOTE'::text AS doc_type,
       date_trunc('month', i.bill_date)::date AS ym,
       i.goods_id,
       COALESCE(o.client_id, '00000000-0000-0000-0000-000000000000'::uuid) AS client_id,
       '00000000-0000-0000-0000-000000000000'::uuid AS currency_id,
       COALESCE(o.maker_id, '00000000-0000-0000-0000-000000000000'::uuid) AS owner_employee_id,
       SUM(i.qty) AS qty_sum,
       SUM(i.amount_original) AS amt_original,
       SUM(i.amount_local) AS amt_local,
       COUNT(*) AS line_cnt,
       AVG(i.price) AS avg_price
FROM sales_quote_items i
JOIN sales_quotes o ON o.id = i.quote_id
WHERE i.is_deleted = false
  AND o.is_deleted = false
  AND o.status = 1
GROUP BY 1, 2, i.goods_id, o.client_id, o.maker_id

UNION ALL

SELECT 'ORDER'::text,
       date_trunc('month', i.bill_date)::date,
       i.goods_id,
       COALESCE(o.client_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.owner_employee_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(i.qty),
       SUM(i.amount_original),
       SUM(i.amount_local),
       COUNT(*),
       AVG(i.price)
FROM sales_order_items i
JOIN sales_orders o ON o.id = i.order_id
WHERE i.is_deleted = false
  AND o.is_deleted = false
  AND o.status = 1
GROUP BY 1, 2, i.goods_id, o.client_id, o.currency_id, o.owner_employee_id

UNION ALL

SELECT 'SHIPMENT'::text,
       date_trunc('month', i.bill_date)::date,
       i.goods_id,
       COALESCE(o.client_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.owner_employee_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(i.qty),
       SUM(i.amount_original),
       SUM(i.amount_local),
       COUNT(*),
       AVG(i.price)
FROM sales_shipment_items i
JOIN sales_shipments o ON o.id = i.shipment_id
WHERE i.is_deleted = false
  AND o.is_deleted = false
  AND o.status = 1
GROUP BY 1, 2, i.goods_id, o.client_id, o.currency_id, o.owner_employee_id

UNION ALL

SELECT 'OTHER_SHIPMENT'::text,
       date_trunc('month', i.bill_date)::date,
       i.goods_id,
       COALESCE(o.client_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.owner_employee_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(i.qty),
       SUM(i.amount_original),
       SUM(i.amount_local),
       COUNT(*),
       AVG(i.price)
FROM sales_other_shipment_items i
JOIN sales_other_shipments o ON o.id = i.shipment_id
WHERE i.is_deleted = false
  AND o.is_deleted = false
  AND o.status = 1
GROUP BY 1, 2, i.goods_id, o.client_id, o.currency_id, o.owner_employee_id

UNION ALL

SELECT 'RETURN'::text,
       date_trunc('month', i.bill_date)::date,
       i.goods_id,
       COALESCE(o.client_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.owner_employee_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(i.qty),
       SUM(i.amount_original),
       SUM(i.amount_local),
       COUNT(*),
       AVG(i.price)
FROM sales_return_items i
JOIN sales_returns o ON o.id = i.return_id
WHERE i.is_deleted = false
  AND o.is_deleted = false
  AND o.status = 1
GROUP BY 1, 2, i.goods_id, o.client_id, o.currency_id, o.owner_employee_id;

CREATE UNIQUE INDEX mv_sales_monthly_uidx
    ON sales_monthly_mv
       (doc_type, ym, goods_id, client_id, currency_id, owner_employee_id);
CREATE INDEX mv_sales_monthly_goods
    ON sales_monthly_mv (goods_id);
CREATE INDEX mv_sales_monthly_client
    ON sales_monthly_mv (client_id);
CREATE INDEX mv_sales_monthly_ym
    ON sales_monthly_mv (ym);
CREATE INDEX mv_sales_monthly_owner_ym
    ON sales_monthly_mv (owner_employee_id, ym DESC);

COMMENT ON MATERIALIZED VIEW sales_monthly_mv IS
    'Sales monthly aggregate by document/month/goods/client/currency/owner; nil owner denotes owner-less legacy rows';
COMMENT ON COLUMN sales_monthly_mv.owner_employee_id IS
    'Effective sales owner; maker_id for quotes, owner_employee_id for other documents, nil UUID for legacy NULL';

CREATE OR REPLACE FUNCTION refresh_sales_monthly_mv() RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY sales_monthly_mv;
END;
$$ LANGUAGE plpgsql;

-- Owner-first indexes support list/range queries after years of data have
-- accumulated.  They complement, rather than duplicate, the existing
-- single-column owner and bill-date indexes.
CREATE INDEX IF NOT EXISTS idx_sq_maker_date_active
    ON sales_quotes (maker_id, bill_date DESC)
    WHERE is_deleted = false;
CREATE INDEX IF NOT EXISTS idx_so_owner_date_active
    ON sales_orders (owner_employee_id, bill_date DESC)
    WHERE is_deleted = false;
CREATE INDEX IF NOT EXISTS idx_ss_owner_date_active
    ON sales_shipments (owner_employee_id, bill_date DESC)
    WHERE is_deleted = false;
CREATE INDEX IF NOT EXISTS idx_sos_owner_date_active
    ON sales_other_shipments (owner_employee_id, bill_date DESC)
    WHERE is_deleted = false;
CREATE INDEX IF NOT EXISTS idx_sr_owner_date_active
    ON sales_returns (owner_employee_id, bill_date DESC)
    WHERE is_deleted = false;

ANALYZE sales_monthly_mv;
