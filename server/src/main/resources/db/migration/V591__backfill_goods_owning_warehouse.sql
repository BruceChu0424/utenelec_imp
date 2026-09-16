-- =====================================================================
-- V591 2026-09-15 存量货品归属「仓库 / 生产车间」一次性回填（V590 种子补齐）
-- =====================================================================
-- 背景：V590 起 goods.owning_warehouse_id 由任何入库自动回写、
--   goods.owning_workshop_department_id 由排产确认/改派自动学习，但两者都只对
--   **今后**的操作生效——库里既有的库存、历史入库与历史排产不会倒灌，货品资料
--   表格里存量货品的「所属仓库 / 归属车间」仍是一片空白（2026-09-15 用户实测
--   反馈「每一个都还是空的，把仓库车间都填上」）。
--
-- 本迁移从**既有事实**一次性种上存量值，语义与自动回写/学习一致：
--   ① 归属仓 = 最新一条入库流水(stock_movements direction=1)的仓库
--     （与「最新入库仓」同义；transaction_date 可补录历史日期，created_at/id
--     兜底稳定排序）；
--   ② 无任何入库流水的货品，归属仓回落「在库量最大的仓」（stock_balances.qty）
--     ——货现在大部分躺在哪个仓；
--   ③ 归属生产车间(+负责人) = 最近一次执行段(production_execution_segments)
--     的车间与负责人——哪次排产用的哪个车间，货品就记住哪个（与学习语义同源，
--     与 V488 给偏好表做过的存量回填同一取数口径）。
--   全部只填空（IS NULL）：人工改过/Excel 回填(import_product_lists.py 只填空)
--   先到先得，本迁移绝不覆盖。
--
-- 顺序：全部是 UPDATE，无 DDL——goods 的审计/行触发器排队事件不与任何
--   ALTER 冲突（V259/V587/V590 同款规矩）。幂等：重放时守卫全部短路。
-- =====================================================================

UPDATE goods g
SET owning_warehouse_id = latest_inbound.warehouse_id
FROM (
    SELECT DISTINCT ON (m.goods_id)
           m.goods_id,
           m.warehouse_id
    FROM stock_movements m
    WHERE m.direction = 1
    ORDER BY m.goods_id,
             m.transaction_date DESC,
             m.created_at DESC,
             m.id DESC
) latest_inbound
WHERE g.id = latest_inbound.goods_id
  AND g.owning_warehouse_id IS NULL;

UPDATE goods g
SET owning_warehouse_id = largest_stock.warehouse_id
FROM (
    SELECT DISTINCT ON (b.goods_id)
           b.goods_id,
           b.warehouse_id
    FROM stock_balances b
    WHERE b.qty > 0
    ORDER BY b.goods_id,
             b.qty DESC,
             b.warehouse_id
) largest_stock
WHERE g.id = largest_stock.goods_id
  AND g.owning_warehouse_id IS NULL;

UPDATE goods g
SET owning_workshop_department_id = latest_segment.workshop_department_id,
    owning_responsible_employee_id = COALESCE(
        latest_segment.responsible_employee_id,
        g.owning_responsible_employee_id)
FROM (
    SELECT DISTINCT ON (segment.product_goods_id)
           segment.product_goods_id,
           segment.workshop_department_id,
           segment.responsible_employee_id
    FROM production_execution_segments segment
    WHERE segment.is_deleted = FALSE
      AND segment.workshop_department_id IS NOT NULL
    ORDER BY segment.product_goods_id,
             segment.created_at DESC,
             segment.id DESC
) latest_segment
WHERE g.id = latest_segment.product_goods_id
  AND g.owning_workshop_department_id IS NULL;
