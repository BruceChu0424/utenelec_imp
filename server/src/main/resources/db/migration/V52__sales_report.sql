-- =====================================================================
-- V52：销售报表（物化视图 + 待交货汇总视图 + 刷新函数）
-- =====================================================================
-- sales_monthly_mv：五类单据明细按 (doc_type, ym, goods_id, client_id, currency_id) 上卷到月度，
--                   单行 = 一月一货品一客户一币种；查询时按维度（货品/客户/分类/业务员/月）GROUP BY 上卷。
--   doc_type 取值：QUOTE / ORDER / SHIPMENT / OTHER_SHIPMENT / RETURN。
--   规模估算：出货 9 万 + 订货 8 万 + 退货 7 千 + 其它 4 千明细 → 上卷后约十万行。
--   CONCURRENTLY 刷新（需下面的唯一索引；client_id/currency_id COALESCE 到 nil-uuid，
--                     避免空值破坏唯一性，对齐 V46 purchase_monthly_mv 范本；OTHER_SHIPMENT.client_id 可空——内部领用场景）。
--   REFRESH 策略：每日 cron 全量 + 审核接口手动触发（调 refresh_sales_monthly_mv()）。
-- sales_order_pending_v：待交货订货汇总（取代老库 View_S_OrderItem "未发数量 = QTY − 发货数量"）。
--   语义：按货品+颜色+客户汇总 qty - shipped_qty + returned_qty - flag_qty > 0 的未交货量，
--         作为生产计划/采购驱动的重要入口（销售→生产→采购全链路打通的查询点）。
-- 详见 docs/数据迁移/20-销售管理-新库与迁移.md §五；DDL 一致性契约 docs/数据迁移/27-DDL一致性契约.md。
-- =====================================================================

CREATE MATERIALIZED VIEW sales_monthly_mv AS
-- sales_quotes 无 currency_id（老库 S_Quote 最简，design doc §3.1）；QUOTE 段 currency_id 用 nil-uuid 哨兵
SELECT 'QUOTE'::text          AS doc_type,
       date_trunc('month', i.bill_date)::date AS ym,
       i.goods_id,
       COALESCE(o.client_id,   '00000000-0000-0000-0000-000000000000'::uuid) AS client_id,
       '00000000-0000-0000-0000-000000000000'::uuid                          AS currency_id,
       SUM(i.qty)             AS qty_sum,
       SUM(i.amount_original) AS amt_original,
       SUM(i.amount_local)    AS amt_local,
       COUNT(*)               AS line_cnt,
       AVG(i.price)           AS avg_price
FROM sales_quote_items i JOIN sales_quotes o ON o.id = i.quote_id
WHERE i.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, i.goods_id, o.client_id
UNION ALL
SELECT 'ORDER'::text,
       date_trunc('month', i.bill_date)::date,
       i.goods_id,
       COALESCE(o.client_id,   '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(i.qty), SUM(i.amount_original), SUM(i.amount_local), COUNT(*), AVG(i.price)
FROM sales_order_items i JOIN sales_orders o ON o.id = i.order_id
WHERE i.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, i.goods_id, o.client_id, o.currency_id
UNION ALL
SELECT 'SHIPMENT'::text,
       date_trunc('month', i.bill_date)::date,
       i.goods_id,
       COALESCE(o.client_id,   '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(i.qty), SUM(i.amount_original), SUM(i.amount_local), COUNT(*), AVG(i.price)
FROM sales_shipment_items i JOIN sales_shipments o ON o.id = i.shipment_id
WHERE i.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, i.goods_id, o.client_id, o.currency_id
UNION ALL
SELECT 'OTHER_SHIPMENT'::text,
       date_trunc('month', i.bill_date)::date,
       i.goods_id,
       COALESCE(o.client_id,   '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(i.qty), SUM(i.amount_original), SUM(i.amount_local), COUNT(*), AVG(i.price)
FROM sales_other_shipment_items i JOIN sales_other_shipments o ON o.id = i.shipment_id
WHERE i.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, i.goods_id, o.client_id, o.currency_id
UNION ALL
SELECT 'RETURN'::text,
       date_trunc('month', i.bill_date)::date,
       i.goods_id,
       COALESCE(o.client_id,   '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(i.qty), SUM(i.amount_original), SUM(i.amount_local), COUNT(*), AVG(i.price)
FROM sales_return_items i JOIN sales_returns o ON o.id = i.return_id
WHERE i.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, i.goods_id, o.client_id, o.currency_id;

-- 唯一索引（CONCURRENTLY 刷新所需；COALESCE 后全非 null，安全）
CREATE UNIQUE INDEX mv_sales_monthly_uidx
    ON sales_monthly_mv (doc_type, ym, goods_id, client_id, currency_id);
CREATE INDEX mv_sales_monthly_goods  ON sales_monthly_mv (goods_id);
CREATE INDEX mv_sales_monthly_client ON sales_monthly_mv (client_id);
CREATE INDEX mv_sales_monthly_ym     ON sales_monthly_mv (ym);

COMMENT ON MATERIALIZED VIEW sales_monthly_mv IS '销售月度聚合（报价/订货/出货/其它出货/退货 × 年月 × 货品 × 客户 × 币种）；CONCURRENTLY 刷新';

-- 刷新函数（审核接口/定时任务调用；CONCURRENTLY 需唯一索引）
CREATE OR REPLACE FUNCTION refresh_sales_monthly_mv() RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY sales_monthly_mv;
END;
$$ LANGUAGE plpgsql;

-- 待交货订货汇总视图（取代老库 View_S_OrderItem：未发数量 = qty - shipped_qty + returned_qty - flag_qty > 0）
-- 按货品+颜色+客户汇总，作为生产计划/采购驱动入口（销售→生产→采购全链路打通的查询点）。
-- 注意：client_id 在主表 sales_orders 上（明细表无 client_id），需 JOIN。
CREATE OR REPLACE VIEW sales_order_pending_v AS
SELECT i.goods_id,
       i.color_id,
       o.client_id,
       SUM(i.qty - i.shipped_qty + i.returned_qty - i.flag_qty) AS pending_qty,
       SUM((i.qty - i.shipped_qty + i.returned_qty - i.flag_qty) * i.price) AS pending_amt
FROM sales_order_items i
JOIN sales_orders o ON o.id = i.order_id
WHERE i.is_deleted = false AND o.is_deleted = false
GROUP BY i.goods_id, i.color_id, o.client_id
HAVING SUM(i.qty - i.shipped_qty + i.returned_qty - i.flag_qty) > 0;

COMMENT ON VIEW sales_order_pending_v IS '待交货订货汇总（按货品+颜色+客户，未发数量=qty-shipped_qty+returned_qty-flag_qty>0）';
