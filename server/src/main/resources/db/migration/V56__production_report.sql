-- =====================================================================
-- V56：生产报表 · 月度上卷物化视图（production_monthly_mv）
-- =====================================================================
-- 设计依据：
--   docs/数据迁移/27-DDL一致性契约.md §一（V56 归属：production_monthly_mv + 刷新函数）
--   docs/数据迁移/24-生产管理-新库与迁移.md §6.1（物化视图 DDL + 刷新策略）
--   范本：V46__purchase_report.sql / V49__stock_report_mv.sql
--
-- production_monthly_mv：月 × 类型(PLAN/DAILY) × 货品 × 客户(固定 nil-uuid) 预聚合（最细粒度）。
--   查询时按 货品/月/客户/类型 GROUP BY 上卷；起止日期按 ym 过滤。
--   client_id 固定 nil-uuid：production_plan_items 无 client FK（仅 client_name 文本冗余），
--     COALESCE 到 nil-uuid 避免空值破坏 UNIQUE 索引（同采购 V46 范式）。
--   CONCURRENTLY 刷新（需唯一索引，已建）；REFRESH 策略：每日 cron 全量 + 生产单据审核
--   接口手动触发（调 refresh_production_monthly_mv()）。
--
-- 4 报表入口（design §6.2）：
--   生产计划明细  → 查 production_plan_items JOIN goods/colors/units（参数化分页，不走 MV）
--   生产计划汇总  → 本物化视图 WHERE doc_type='PLAN'（按 货品/月/客户 上卷）
--   生产日报明细  → 查 production_daily_report_items（0 行空结构）
--   生产日报汇总  → 本物化视图 WHERE doc_type='DAILY'（0 行空结构）
--   老库 View_F_Plan / View_F_Plan2 / View_F_DateReport* 收敛为查 production_plan_items
--     + 本物化视图的 2 个参数化查询（同采购 [15] §6.1 范式）。
--
-- BOM 成本上卷（F_PlanCostItem 物化视图，按 master_goods × 月 × Level 汇总）本期不建，
--   归未来成本模块（design §6.1 末）。数据已就位，建 MV 是后续 task。
-- =====================================================================

CREATE MATERIALIZED VIEW production_monthly_mv AS
-- PLAN 分支：生产计划明细按月 × 货品预聚合
SELECT 'PLAN'::text  AS doc_type,
       date_trunc('month', bill_date)::date AS ym,
       goods_id,
       '00000000-0000-0000-0000-000000000000'::uuid AS client_id,  -- 生产计划无 client FK，固定 nil-uuid
       SUM(qty)   AS plan_qty_sum,        -- 排产数量合计
       SUM(oqty)  AS order_qty_sum,       -- 销售订货量合计
       SUM(iqty)  AS finished_qty_sum,    -- 完工/进仓量合计
       SUM(rqty)  AS inbound_qty_sum,     -- 入库量合计
       COUNT(*)   AS line_cnt
FROM production_plan_items
WHERE is_deleted = false
GROUP BY 1, 2, 3
UNION ALL
-- DAILY 分支：生产日报明细（F_DateReport 空结构，本期 0 行；结构留位）
SELECT 'DAILY'::text,
       date_trunc('month', bill_date)::date,
       goods_id,
       '00000000-0000-0000-0000-000000000000'::uuid,
       SUM(qty),
       SUM(0::numeric),                   -- DAILY 无销售订货量语义，占位 0（类型对齐 PLAN 分支）
       SUM(qty),                          -- DAILY 完工量（同 plan_qty_sum，design §6.1）
       SUM(0::numeric),                   -- DAILY 无入库量语义，占位 0
       COUNT(*)
FROM production_daily_report_items
WHERE is_deleted = false
GROUP BY 1, 2, 3;

-- 唯一索引（CONCURRENTLY 刷新所需；client_id 恒 nil-uuid，等价 (doc_type, ym, goods_id) 唯一）
CREATE UNIQUE INDEX mv_production_monthly_uidx
    ON production_monthly_mv (doc_type, ym, goods_id, client_id);
CREATE INDEX mv_production_monthly_goods ON production_monthly_mv (goods_id);
CREATE INDEX mv_production_monthly_ym    ON production_monthly_mv (ym);
CREATE INDEX mv_production_monthly_type  ON production_monthly_mv (doc_type);

COMMENT ON MATERIALIZED VIEW production_monthly_mv IS '生产月度上卷（PLAN 计划 / DAILY 日报 × 月 × 货品 × 客户(固定 nil)）；CONCURRENTLY 刷新';

-- 刷新函数（CONCURRENTLY 需唯一索引；审核接口 / 每日 cron 调用）
CREATE OR REPLACE FUNCTION refresh_production_monthly_mv() RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY production_monthly_mv;
END;
$$ LANGUAGE plpgsql;
