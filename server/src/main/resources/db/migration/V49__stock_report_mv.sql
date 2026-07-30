-- =====================================================================
-- V49：仓库管理报表 · 月度上卷物化视图（stock_monthly_mv）
-- =====================================================================
-- 设计依据：docs/数据迁移/17-仓库管理-新库与迁移.md §五
-- 老库 18 张 View_O_* 报表视图（9 类 × 明细/汇总）→ 新库全查 stock_movements：
--   明细报表 = 过滤 movement_type + 日期 + 维度 的流水；
--   汇总报表 = 上卷（货品/仓库/月/类型），用本物化视图加速。
-- 物化视图按 月×movement_type×货品×仓库×颜色 预聚合（最细粒度），CONCURRENTLY 刷新
--   （需唯一索引，已建）。规模：月(180) × 类型(14) × 活跃货品仓组合 → 估算百万级行，
--   查询毫秒级。REFRESH 策略：每日 cron 全量 + 仓库单据审核接口手动触发。
-- =====================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS stock_monthly_mv AS
SELECT date_trunc('month', transaction_date) AS ym,
       movement_type,
       goods_id,
       warehouse_id,
       color_id,
       SUM(qty)          AS qty_sum,
       SUM(amount_local) AS amt_local,
       COUNT(*)          AS line_cnt
FROM stock_movements
GROUP BY 1, 2, 3, 4, 5;

-- 唯一索引（CONCURRENTLY 刷新所需）
CREATE UNIQUE INDEX IF NOT EXISTS mv_stock_monthly_uidx
    ON stock_monthly_mv (ym, movement_type, goods_id, warehouse_id, color_id);
CREATE INDEX IF NOT EXISTS mv_stock_monthly_goods    ON stock_monthly_mv (goods_id);
CREATE INDEX IF NOT EXISTS mv_stock_monthly_wh       ON stock_monthly_mv (warehouse_id);
CREATE INDEX IF NOT EXISTS mv_stock_monthly_type     ON stock_monthly_mv (movement_type);
CREATE INDEX IF NOT EXISTS mv_stock_monthly_ym       ON stock_monthly_mv (ym);

COMMENT ON MATERIALIZED VIEW stock_monthly_mv IS '库存月度上卷（月×类型×货品×仓库×颜色）；仓库/采购报表汇总加速，CONCURRENTLY 刷新';

-- 刷新函数（CONCURRENTLY 需唯一索引；审核接口/每日 cron 调用）
CREATE OR REPLACE FUNCTION refresh_stock_monthly_mv() RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY stock_monthly_mv;
END;
$$ LANGUAGE plpgsql;
