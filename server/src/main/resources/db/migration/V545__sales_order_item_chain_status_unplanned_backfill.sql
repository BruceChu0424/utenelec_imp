-- V545 销售订单行链路状态按剩余未排量派生（2026-09-10 用户口径：「我的车间任务 部分排产后
-- 订单会从待排产区域消失直接转移到进行中」）。根因：chain_status 派生规则内联在十余个写点，
-- 只要 planned − produced > 0 就把整行推进 3/4/5/6，剩余未排量（未交付 − 预留 − 未完工计划量）
-- 从不参与判定。自本版起 Service 统一走 SalesOrderChainSql：剩余未排量 > 0 ⇒ 行停在
-- 1 部分预留 / 2 待排产（已发部分 > 0 时为 8），未排量归零才落 3/4/5/6。
-- 本迁移只回填数据：把当前处于 3/4/5/6 但仍有剩余未排量的有效行按新规则改回；不改任何
-- 数量列，报工/入库事实仍留在 plan_order_item_links / produced_qty。幂等：重跑无命中行。
WITH target AS (
    SELECT i.id,
           CASE
             WHEN COALESCE(i.shipped_qty,0) > 0 THEN 8
             WHEN COALESCE(i.reserved_qty,0) > 0 THEN 1
             ELSE 2
           END AS next_status
    FROM sales_order_items i
    WHERE i.is_deleted = false
      AND COALESCE(i.chain_status,0) IN (3,4,5,6)
      AND GREATEST(
            (COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
             + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0))
            - COALESCE(i.reserved_qty,0)
            - GREATEST(COALESCE(i.planned_qty,0) - COALESCE(i.produced_qty,0), 0), 0) > 0
)
UPDATE sales_order_items i
SET chain_status = target.next_status,
    updated_at = now()
FROM target
WHERE i.id = target.id;
