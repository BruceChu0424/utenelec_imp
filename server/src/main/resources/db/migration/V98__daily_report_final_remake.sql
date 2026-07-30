-- =====================================================================
-- V95：业务链 · 报工完结与不良缺额补产留痕
-- =====================================================================
-- 依据 docs/07-业务链路/02 §三「报工（分批）/ 不良缺额」两行：
--   ① 报工明细 is_final：车间负责人标记"该计划行报工完结"。完结且累计合格
--      （plan_items.fqty）< 计划量 → 差额为不良缺额，自动生成补产计划（links source=1）。
--   ② 缺额封顶留痕：完结时把计划行 qty 砍到实际合格量、links.allocated 砍到 produced，
--      砍掉的量记 capped_qty（否则补产审核过不了防超排校验：原排产量仍占着需求）。
--      红冲报工时按 capped_qty 精确恢复。
-- =====================================================================

ALTER TABLE production_daily_report_items
    ADD COLUMN IF NOT EXISTS is_final BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE production_plan_items
    ADD COLUMN IF NOT EXISTS capped_qty NUMERIC(18,4);

ALTER TABLE plan_order_item_links
    ADD COLUMN IF NOT EXISTS capped_qty NUMERIC(18,4);

COMMENT ON COLUMN production_daily_report_items.is_final IS
    '报工完结标记：该计划行不再继续报工；合格量不足计划量时触发缺额封顶 + 自动生成补产计划';
COMMENT ON COLUMN production_plan_items.capped_qty IS
    '完结缺额砍掉的计划量（原 qty − 现 qty）；红冲完结报工时恢复并清零';
COMMENT ON COLUMN plan_order_item_links.capped_qty IS
    '完结缺额砍掉的排产分摊量（原 allocated − 现 allocated=produced）；红冲完结报工时恢复并清零';
