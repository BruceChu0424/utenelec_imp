-- V466：IQC 不合格实物退回后的补货单通道收口（原订单继续补）。
--
-- 背景（2026-09-03 测试服务器实证，收货 200 / 合格 190 / 不合格 10 / 登记退回）：
-- 系统同时打开了两条互不知晓的补货通道——
--   ① 预计到货按「已收 − 已退回不合格」重开，原订货单等待供应商补 10；
--   ② 物料分析把供给行动整个取消（理由「原采购需求已无在途」），缺口重新出现，
--      引导重新通知 → 新采购申请 → 新订货单，与 ① 叠加成双重补货。
-- 根因：「在途」口径只看 qty − received + returned，从未计入已退回不合格量，因此
-- 退回登记后原订单事实上重新欠货，却被判定为「已无在途」。
--
-- 本迁移只改一处投影口径（业务事实零改动、不动任何行动行、不新增表）：
-- v_preplan_buy_action_slice_progress（V463 sources 分摊版）的 open_order_qty
-- 计入「已退回不合格量」（failed_base_qty，案件 return_recorded_at 非空且状态在
-- 四个已退回终态内），使 demand/safety_future_qty 反映原订单的真实欠货。
--
-- 行动本体按 V250 追加式契约保持 CANCELLED 不复活（触发器显式禁止）；补货单通道
-- 收口由应用侧完成：MaterialAnalysisCommandService 下达余量扣除「已取消 IQC 行动
-- 对应原订货单的当前欠货」（cancelledIqcReplacementInFlight），MaterialAnalysisService
-- 的取消在途守卫同样计入退回欠货（多批到货场景防误取消）。

CREATE OR REPLACE VIEW v_preplan_buy_action_slice_progress AS
WITH slice_items AS (
    SELECT DISTINCT action.id AS action_id,
           'DEMAND'::TEXT AS slice_type,
           allocation.external_item_id AS request_item_id
    FROM preplan_supply_actions action
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id = action.id
     AND allocation.external_item_id IS NOT NULL
    WHERE action.route = 'BUY'
    UNION ALL
    SELECT action.id, 'SAFETY', action.safety_external_item_id
    FROM preplan_supply_actions action
    WHERE action.route = 'BUY'
      AND action.safety_external_item_id IS NOT NULL
), request_progress AS (
    SELECT slice.action_id, slice.slice_type,
           COUNT(*)::BIGINT AS item_count,
           BOOL_AND(
               item.is_deleted = FALSE
               AND request.id IS NOT NULL
               AND request.is_deleted = FALSE
               AND request.status IN (0,1)
               AND COALESCE(request.is_stopped,FALSE) = FALSE
               AND request.id = action.external_document_id
           ) AS source_valid,
           SUM(GREATEST(
               COALESCE(item.qty,0) - COALESCE(item.ordered_qty,0), 0
           ) * COALESCE(item.unit_rate,1))::numeric AS unordered_qty
    FROM slice_items slice
    JOIN preplan_supply_actions action ON action.id = slice.action_id
    LEFT JOIN purchase_request_items item
      ON item.id = slice.request_item_id
    LEFT JOIN purchase_requests request
      ON request.id = item.request_id
    GROUP BY slice.action_id, slice.slice_type
), item_receipts AS (
    -- 每条已生效订货行的到货事实（与 V446 receipt_by_order_item 同一 CASE
    -- 口径，先按订货行汇总，供来源 FIFO 分摊）。V466：新增已退回不合格量
    -- （实物退回登记后原订单重新欠货，计入在途）。
    SELECT order_item.id AS order_item_id,
           COALESCE(SUM(CASE
               WHEN receipt.id IS NULL THEN 0
               WHEN inspection.id IS NULL
               THEN receipt_item.qty * COALESCE(receipt_item.unit_rate,1)
               WHEN inspection.status = 'REVERSED' THEN 0
               ELSE inspection.warehouse_stocked_base_qty
           END),0)::numeric AS passed_qty,
           COALESCE(SUM(CASE
               WHEN inspection.id IS NULL OR inspection.status = 'REVERSED'
               THEN 0 ELSE inspection.failed_base_qty
           END),0)::numeric AS failed_qty,
           COALESCE(SUM(CASE
               WHEN inspection.id IS NULL OR inspection.status = 'REVERSED'
               THEN 0
               ELSE GREATEST(
                   inspection.received_base_qty
                       - inspection.failed_base_qty
                       - inspection.warehouse_stocked_base_qty,
                   0
               )
           END),0)::numeric AS pending_qty,
           COALESCE((
               SELECT SUM(rejection.failed_base_qty)
               FROM procurement_iqc_rejection_cases rejection
               WHERE rejection.receipt_type = 'PURCHASE'
                 AND rejection.order_item_id = order_item.id
                 AND rejection.is_deleted = FALSE
                 AND rejection.return_recorded_at IS NOT NULL
                 AND rejection.status IN (
                     'RETURN_RECORDED','CREDIT_CONFIRMED',
                     'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
           ),0)::numeric AS returned_failure_base
    FROM purchase_order_items order_item
    JOIN purchase_orders purchase_order
      ON purchase_order.id = order_item.order_id
     AND purchase_order.status = 1
     AND purchase_order.is_deleted = FALSE
    LEFT JOIN purchase_receipt_items receipt_item
      ON receipt_item.order_item_id = order_item.id
     AND receipt_item.is_deleted = FALSE
    LEFT JOIN purchase_receipts receipt
      ON receipt.id = receipt_item.receipt_id
     AND receipt.status = 1
     AND receipt.is_deleted = FALSE
    LEFT JOIN procurement_inspection_items inspection
      ON receipt.id IS NOT NULL
     AND inspection.receipt_type = 'PURCHASE'
     AND inspection.receipt_item_id = receipt_item.id
    WHERE order_item.is_deleted = FALSE
    GROUP BY order_item.id
), source_slices AS (
    -- 订货行 × 来源申请行：alloc/prefix（BASE 单位）与末位标记。
    SELECT src.order_item_id,
           src.request_item_id,
           src.alloc_qty * COALESCE(order_item.unit_rate, 1) AS alloc_base,
           COALESCE(SUM(src.alloc_qty) OVER w, 0)
               * COALESCE(order_item.unit_rate, 1)
               - src.alloc_qty * COALESCE(order_item.unit_rate, 1) AS prefix_base,
           ROW_NUMBER() OVER w AS rn,
           COUNT(*) OVER (PARTITION BY src.order_item_id) AS source_count
    FROM purchase_order_item_sources src
    JOIN purchase_order_items order_item
      ON order_item.id = src.order_item_id
     AND order_item.is_deleted = FALSE
    WINDOW w AS (
        PARTITION BY src.order_item_id ORDER BY src.line_no, src.id)
), source_progress AS (
    SELECT slice.action_id, slice.slice_type,
           slice.request_item_id,
           sl.order_item_id,
           purchase_order.id IS NOT NULL AS order_exists,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(
                   GREATEST(
                       COALESCE(order_item.qty,0) - COALESCE(order_item.received_qty,0)
                       + COALESCE(order_item.returned_qty,0), 0)
                       * COALESCE(order_item.unit_rate,1)
                   + COALESCE(receipt.returned_failure_base,0)
                   - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   GREATEST(
                       COALESCE(order_item.qty,0) - COALESCE(order_item.received_qty,0)
                       + COALESCE(order_item.returned_qty,0), 0)
                       * COALESCE(order_item.unit_rate,1)
                   + COALESCE(receipt.returned_failure_base,0)
                   - sl.prefix_base), 0)
           END AS open_order_qty,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(
                   GREATEST(COALESCE(receipt.passed_qty,0)
                       - COALESCE(order_item.returned_qty,0)
                           * COALESCE(order_item.unit_rate,1), 0)
                   - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   GREATEST(COALESCE(receipt.passed_qty,0)
                       - COALESCE(order_item.returned_qty,0)
                           * COALESCE(order_item.unit_rate,1), 0)
                   - sl.prefix_base), 0)
           END AS qualified_qty,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(COALESCE(receipt.failed_qty,0) - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   COALESCE(receipt.failed_qty,0) - sl.prefix_base), 0)
           END AS failed_qty,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(COALESCE(receipt.pending_qty,0) - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   COALESCE(receipt.pending_qty,0) - sl.prefix_base), 0)
           END AS pending_qty
    FROM slice_items slice
    JOIN source_slices sl
      ON sl.request_item_id = slice.request_item_id
    JOIN purchase_order_items order_item
      ON order_item.id = sl.order_item_id
    JOIN purchase_orders purchase_order
      ON purchase_order.id = order_item.order_id
     AND purchase_order.status = 1
     AND purchase_order.is_deleted = FALSE
    LEFT JOIN item_receipts receipt ON receipt.order_item_id = order_item.id
), order_progress AS (
    SELECT slice.action_id, slice.slice_type,
           BOOL_OR(sp.order_exists) AS order_exists,
           COALESCE(SUM(sp.open_order_qty),0)::numeric AS open_order_qty,
           COALESCE(SUM(sp.qualified_qty),0)::numeric AS qualified_qty,
           COALESCE(SUM(sp.failed_qty),0)::numeric AS failed_qty,
           COALESCE(SUM(sp.pending_qty),0)::numeric AS pending_qty
    FROM slice_items slice
    LEFT JOIN source_progress sp
      ON sp.action_id = slice.action_id
     AND sp.slice_type = slice.slice_type
     AND sp.request_item_id = slice.request_item_id
    GROUP BY slice.action_id, slice.slice_type
), kind_progress AS (
    SELECT request.action_id, request.slice_type,
           request.item_count, request.source_valid,
           COALESCE(request.unordered_qty,0) AS unordered_qty,
           COALESCE(orders.order_exists,FALSE) AS order_exists,
           COALESCE(orders.open_order_qty,0) AS open_order_qty,
           COALESCE(orders.qualified_qty,0) AS qualified_qty,
           COALESCE(orders.failed_qty,0) AS failed_qty,
           COALESCE(orders.pending_qty,0) AS pending_qty
    FROM request_progress request
    LEFT JOIN order_progress orders
      ON orders.action_id = request.action_id
     AND orders.slice_type = request.slice_type
)
SELECT action.id AS action_id,
       action.requested_qty AS demand_requested_qty,
       action.safety_replenishment_qty AS safety_requested_qty,
       (action.requested_qty = 0 OR COALESCE(demand.item_count,0) > 0
          AND COALESCE(demand.source_valid,FALSE)) AS demand_source_valid,
       (action.safety_replenishment_qty = 0 OR COALESCE(safety.item_count,0) > 0
          AND COALESCE(safety.source_valid,FALSE)) AS safety_source_valid,
       COALESCE(demand.qualified_qty,0) AS demand_qualified_qty,
       COALESCE(safety.qualified_qty,0) AS safety_qualified_qty,
       COALESCE(demand.failed_qty,0) AS demand_failed_qty,
       COALESCE(safety.failed_qty,0) AS safety_failed_qty,
       COALESCE(demand.unordered_qty,0)
          + COALESCE(demand.open_order_qty,0)
          + COALESCE(demand.pending_qty,0) AS demand_future_qty,
       COALESCE(safety.unordered_qty,0)
          + COALESCE(safety.open_order_qty,0)
          + COALESCE(safety.pending_qty,0) AS safety_future_qty,
       COALESCE(demand.pending_qty,0) AS demand_pending_qty,
       COALESCE(safety.pending_qty,0) AS safety_pending_qty,
       COALESCE(demand.order_exists,FALSE) AS demand_order_exists,
       COALESCE(safety.order_exists,FALSE) AS safety_order_exists
FROM preplan_supply_actions action
LEFT JOIN kind_progress demand
  ON demand.action_id = action.id AND demand.slice_type = 'DEMAND'
LEFT JOIN kind_progress safety
  ON safety.action_id = action.id AND safety.slice_type = 'SAFETY'
WHERE action.route = 'BUY';
