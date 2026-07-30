-- =====================================================================
-- V46：采购报表（物化视图 + 待交货汇总视图）
-- =====================================================================
-- purchase_monthly_mv：按 单据类型×年月×货品×供应商×币种 预聚合（最细粒度），
--   查询时按用户选定维度 GROUP BY 上卷（货品/供应商/采购员/时间…），起止日期按 ym 过滤。
--   CONCURRENTLY 刷新（需唯一索引；supplier_id/currency_id COALESCE 到 nil-uuid 避免空值破坏唯一性）。
--   REFRESH 策略：每日 cron 全量 + 审核接口手动触发（调 refresh_purchase_monthly_mv()）。
-- purchase_order_pending_v：待交货订货汇总（取代老库 P_OrderMore / View_P_OrderNoRec）。
-- 详见 docs/数据迁移/15-采购模块-新库与迁移.md §六。
-- =====================================================================

CREATE MATERIALIZED VIEW purchase_monthly_mv AS
SELECT 'ORDER'::text   AS doc_type,
       date_trunc('month', it.bill_date)::date AS ym,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid) AS supplier_id,
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid) AS currency_id,
       SUM(it.qty)             AS qty_sum,
       SUM(it.amount_local)    AS amt_local,
       SUM(it.amount_original) AS amt_original,
       COUNT(*)                AS line_cnt,
       AVG(it.price)           AS avg_price
FROM purchase_order_items it JOIN purchase_orders o ON o.id = it.order_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id, o.currency_id
UNION ALL
SELECT 'RECEIPT'::text,
       date_trunc('month', it.bill_date)::date,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(it.qty), SUM(it.amount_local), SUM(it.amount_original), COUNT(*), AVG(it.price)
FROM purchase_receipt_items it JOIN purchase_receipts o ON o.id = it.receipt_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id, o.currency_id
UNION ALL
SELECT 'RETURN'::text,
       date_trunc('month', it.bill_date)::date,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(it.qty), SUM(it.amount_local), SUM(it.amount_original), COUNT(*), AVG(it.price)
FROM purchase_return_items it JOIN purchase_returns o ON o.id = it.return_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id, o.currency_id;

-- 唯一索引（CONCURRENTLY 刷新所需；COALESCE 后全非 null，安全）
CREATE UNIQUE INDEX mv_purchase_monthly_uidx
    ON purchase_monthly_mv (doc_type, ym, goods_id, supplier_id, currency_id);
CREATE INDEX mv_purchase_monthly_goods    ON purchase_monthly_mv (goods_id);
CREATE INDEX mv_purchase_monthly_supplier ON purchase_monthly_mv (supplier_id);
CREATE INDEX mv_purchase_monthly_ym       ON purchase_monthly_mv (ym);

COMMENT ON MATERIALIZED VIEW purchase_monthly_mv IS '采购月度聚合（订货/收货/退货 × 年月 × 货品 × 供应商 × 币种）；CONCURRENTLY 刷新';

-- 刷新函数（审核接口/定时任务调用）
CREATE OR REPLACE FUNCTION refresh_purchase_monthly_mv() RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY purchase_monthly_mv;
END;
$$ LANGUAGE plpgsql;

-- 待交货订货汇总视图（取代 P_OrderMore / View_P_OrderNoRec：按货品+颜色汇总未交货量）
CREATE OR REPLACE VIEW purchase_order_pending_v AS
SELECT goods_id,
       color_id,
       SUM(qty - received_qty + returned_qty) AS pending_qty,
       SUM((qty - received_qty + returned_qty) * price) AS pending_amt
FROM purchase_order_items
WHERE is_deleted = false
GROUP BY goods_id, color_id
HAVING SUM(qty - received_qty + returned_qty) > 0;

COMMENT ON VIEW purchase_order_pending_v IS '待交货订货汇总（按货品+颜色，订货-已收+已退>0）';
