-- V580 销售订单来源顶层行超量下达：公共备货那张计划单允许不带销售来源
--
-- 背景：V577 让下达车间可以超出剩余需求，超出部分记 public_surplus_qty。
-- ADR-081 §7.3 对**销售订单来源顶层行**的做法是把一次下达拆成两张计划单——
--   单 A：原样销售行，1:1 分摊订单量（production_plan_sales_allocations 的
--         「分摊合计 = 计划数量」与「排产量 ≤ 订单未满足」两条守恒原样成立）；
--   单 B：无销售来源的公共备货行，link 记 submitted_qty = 0 + public_surplus_qty = N，
--         产出入库即公共库存供其他计划认领。
--
-- 但 V577 当时只把对账触发器里 `pi.qty = NEW.submitted_qty` 这一项改成了
-- 「归需求量 + 公共备货量」，**漏了同一个 EXISTS 里的销售关联等式**：
--     AND pi.sales_order_item_id IS NOT DISTINCT FROM ai.sales_order_item_id
-- 单 B 的计划明细按设计不带销售来源（带了就会破坏上面那两条销售守恒），
-- 而它挂的 analysis_item 正是那条销售来源顶层行 ⇒ 等式恒假 ⇒ EXISTS 落空 ⇒
-- RAISE 'analysis demand, plan item and submitted quantity differ'。
-- 结果就是「销售订单来源的产品填超量下达车间」100% 失败（非销售来源不受影响，
-- 因为两侧的 sales_order_item_id 都是 NULL，等式自然成立）。
-- 复现：MaterialWorkshopAnchorEndToEndTest#salesTopOverQuantitySplitsIntoOrderPlanAndPublicSurplusPlan
--
-- 本迁移只放宽这一项，且放宽范围收到最窄：**仅**当这条 link 是纯公共备货
-- （submitted_qty = 0 且 public_surplus_qty > 0）时，才允许它的计划明细不带
-- 销售来源。带需求的 link 一个字节不变，货品/颜色/单位/换算率/单行形状四条
-- 对账也全部原样保留。不加表、不改历史行。

DO $patch$
DECLARE
    definition TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_sync_material_analysis_plan_link_qty()'::regprocedure)
    INTO definition;

    -- 形状断言：锚点必须还在，且 V577 的数量对账已经打过（否则说明目录被改动
    -- 过或顺序不对，宁可失败也不要盲改函数体）。
    IF position('AND pi.sales_order_item_id IS NOT DISTINCT FROM ai.sales_order_item_id'
                IN definition) = 0
       OR position('AND pi.qty = NEW.submitted_qty + COALESCE(NEW.public_surplus_qty, 0)'
                IN definition) = 0 THEN
        RAISE EXCEPTION 'V580 analysis plan-link function shape changed'
            USING ERRCODE = '23514';
    END IF;

    patched := replace(
        definition,
        'AND pi.sales_order_item_id IS NOT DISTINCT FROM ai.sales_order_item_id',
        'AND (pi.sales_order_item_id IS NOT DISTINCT FROM ai.sales_order_item_id'
            || E'\n                      OR (COALESCE(NEW.submitted_qty, 0) = 0'
            || E'\n                          AND COALESCE(NEW.public_surplus_qty, 0) > 0'
            || E'\n                          AND pi.sales_order_item_id IS NULL))');

    IF patched IS NOT DISTINCT FROM definition THEN
        RAISE EXCEPTION 'V580 cannot relax the public-surplus plan link safely'
            USING ERRCODE = '23514';
    END IF;

    EXECUTE patched;
END;
$patch$;

COMMENT ON COLUMN production_material_analysis_plan_links.public_surplus_qty IS
    '超出本批需求、按公共备货产出记账的量（V577）；不绑定任何需求，产出入库即公共库存。'
    '销售订单来源顶层行超量时单独成一张无销售来源的计划单，该 link 的 submitted_qty 为 0，'
    '其计划明细允许不带 sales_order_item_id（V580 放宽对账）。';
