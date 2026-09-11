-- =====================================================================
-- V551 待交货订货汇总视图排除草稿（G5-reports）
--
-- 背景：sales_order_pending_v（V52 建）只排 is_deleted，未过滤审核状态，
--       草稿订货单（status=0）的未发数量因此混进「待交货」汇总，被生产计划/
--       采购驱动当成真实承诺量读走——未审核的单据不构成交货承诺。
-- 本迁移：在原定义上只加一条 `AND o.status = 1`（已审），列名/列序/聚合口径
--         全部保持不变，故 CREATE OR REPLACE 安全（依赖本视图的对象不受影响）。
-- 口径变化：历史「待交货」数字会减少草稿部分；报表默认口径同步调整见
--         SalesReportService（status 未显式传入时默认排除 status=0）。
-- 详见 docs/数据迁移/149-V551待交货视图排除草稿.md。
-- =====================================================================

CREATE OR REPLACE VIEW sales_order_pending_v AS
SELECT i.goods_id,
       i.color_id,
       o.client_id,
       SUM(i.qty - i.shipped_qty + i.returned_qty - i.flag_qty) AS pending_qty,
       SUM((i.qty - i.shipped_qty + i.returned_qty - i.flag_qty) * i.price) AS pending_amt
FROM sales_order_items i
JOIN sales_orders o ON o.id = i.order_id
WHERE i.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY i.goods_id, i.color_id, o.client_id
HAVING SUM(i.qty - i.shipped_qty + i.returned_qty - i.flag_qty) > 0;

COMMENT ON VIEW sales_order_pending_v IS '待交货订货汇总（仅已审订单 status=1；按货品+颜色+客户，未发数量=qty-shipped_qty+returned_qty-flag_qty>0）';
