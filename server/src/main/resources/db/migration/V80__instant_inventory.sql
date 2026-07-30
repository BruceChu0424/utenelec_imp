-- =====================================================================
-- V80：即时库存（stock_balances 增加库存重量列）
-- =====================================================================
-- 背景：老系统「即时库存」窗口（View_IOStockGoods / View_StockGoods）展示
--   库存数量 FactQTY + 库存重量 FactWeight + 成本金额 B_Goods.CTotal×FactQTY
--   + 多排数量 View_ProductMore（F_PlanItem 可排余量）。
--   新库 stock_balances（V45）只有 qty / amount_local，缺重量口径。
--
-- 本迁移：
--   1) stock_balances 增加 weight（当前库存重量，仓+货+色 粒度，随数量联动）。
--   2) 历史重量由 legacy 迁移脚本从 StockGoods.FactWeight 重建
--      （migrate_stock_docs.sql 已同步改造：sg_stage 增 weight/fact_weight，
--       取最新年 SUM(COALESCE(FactWeight, Weight))，与 FactQTY 同口径）——
--       Flyway 无法访问老库 CSV，灌数走 migrate.sh --stock-docs（幂等可重跑）。
--   3) 增量维护：StockService.recordMovement 扩展可选 weight 参数，
--       仓库单据审核/红冲时按明细 weight × unit_rate × direction 同步增减。
-- =====================================================================

ALTER TABLE stock_balances ADD COLUMN IF NOT EXISTS weight NUMERIC(18,4);

COMMENT ON COLUMN stock_balances.weight IS
    '当前库存重量（仓+货+色 粒度）；历史=StockGoods 最新年 FactWeight，增量=单据明细 weight×unit_rate×direction';
