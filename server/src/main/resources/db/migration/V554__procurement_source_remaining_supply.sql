-- Remaining supply belongs to each immutable order source UUID. Allocate
-- cumulative total and cumulative accounted receipt first, then subtract;
-- allocating the remaining total again would restart FIFO at the first source.
-- No historical receipt, stock, source allocation or financial fact is rewritten.
CREATE OR REPLACE FUNCTION fn_procurement_source_interval_qty(
    p_receipt_type TEXT,
    p_order_item_id UUID,
    p_source_item_id UUID,
    p_from_base NUMERIC,
    p_to_base NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(CASE p_receipt_type
        WHEN 'PURCHASE' THEN
            fn_purchase_order_source_share(p_order_item_id,p_source_item_id,
                GREATEST(COALESCE(p_to_base,0),0))
            - fn_purchase_order_source_share(p_order_item_id,p_source_item_id,
                GREATEST(COALESCE(p_from_base,0),0))
        WHEN 'SUBCONTRACT' THEN
            fn_subcontract_order_source_share(p_order_item_id,p_source_item_id,
                GREATEST(COALESCE(p_to_base,0),0))
            - fn_subcontract_order_source_share(p_order_item_id,p_source_item_id,
                GREATEST(COALESCE(p_from_base,0),0))
        ELSE 0
    END,0);
$$;

-- The view already has each source's FIFO bounds. Reuse them rather than
-- reading every order source again for each progress column.
CREATE OR REPLACE FUNCTION fn_procurement_bounded_interval_qty(
    p_alloc_base NUMERIC, p_prefix_base NUMERIC, p_last BOOLEAN,
    p_from_base NUMERIC, p_to_base NUMERIC)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT GREATEST(
        CASE WHEN p_last THEN GREATEST(COALESCE(p_to_base,0)-p_prefix_base,0)
             ELSE GREATEST(LEAST(p_alloc_base,COALESCE(p_to_base,0)-p_prefix_base),0) END
        - CASE WHEN p_last THEN GREATEST(COALESCE(p_from_base,0)-p_prefix_base,0)
             ELSE GREATEST(LEAST(p_alloc_base,COALESCE(p_from_base,0)-p_prefix_base),0) END,
        0);
$$;

-- Derived current facts only. A recorded IQC return reopens the original
-- source's interval; free replacement receipts close it again as they arrive.
CREATE OR REPLACE FUNCTION fn_procurement_order_source_remaining_qty(
    p_receipt_type TEXT, p_order_item_id UUID, p_source_item_id UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH order_fact AS (
        SELECT item.qty*COALESCE(item.unit_rate,1) AS ordered_base,
               (COALESCE(item.received_qty,0)-COALESCE(item.returned_qty,0))
                   *COALESCE(item.unit_rate,1) AS received_net_base
        FROM purchase_order_items item
        JOIN purchase_orders header ON header.id=item.order_id
        WHERE p_receipt_type='PURCHASE' AND item.id=p_order_item_id
          AND item.is_deleted=FALSE AND header.is_deleted=FALSE AND header.status=1
        UNION ALL
        SELECT item.qty*COALESCE(item.unit_rate,1),
               (COALESCE(item.received_qty,0)-COALESCE(item.returned_qty,0))
                   *COALESCE(item.unit_rate,1)
        FROM subcontract_order_items item
        JOIN subcontract_orders header ON header.id=item.order_id
        WHERE p_receipt_type='SUBCONTRACT' AND item.id=p_order_item_id
          AND item.is_deleted=FALSE AND header.is_deleted=FALSE AND header.status=1
    ), returned_failure AS (
        SELECT COALESCE(SUM(rejection.failed_base_qty),0) AS base_qty
        FROM procurement_iqc_rejection_cases rejection
        WHERE rejection.receipt_type=p_receipt_type
          AND rejection.order_item_id=p_order_item_id
          AND rejection.is_deleted=FALSE AND rejection.return_recorded_at IS NOT NULL
          AND rejection.status IN ('RETURN_RECORDED','CREDIT_CONFIRMED',
              'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
    )
    SELECT COALESCE((SELECT fn_procurement_source_interval_qty(
        p_receipt_type,p_order_item_id,p_source_item_id,
        GREATEST(fact.received_net_base-returned.base_qty,0),fact.ordered_base)
        FROM order_fact fact CROSS JOIN returned_failure returned),0);
$$;

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
    WHERE src.alloc_qty>0
    WINDOW w AS (
        PARTITION BY src.order_item_id ORDER BY src.line_no, src.id)
), source_progress AS (
    SELECT slice.action_id, slice.slice_type,
           slice.request_item_id,
           sl.order_item_id,
           purchase_order.id IS NOT NULL AS order_exists,
           fn_procurement_bounded_interval_qty(
               sl.alloc_base, sl.prefix_base, sl.rn=sl.source_count,
               GREATEST((COALESCE(order_item.received_qty,0)
                   - COALESCE(order_item.returned_qty,0))
                   * COALESCE(order_item.unit_rate,1)
                   - COALESCE(receipt.returned_failure_base,0),0),
               COALESCE(order_item.qty,0) * COALESCE(order_item.unit_rate,1)
           ) AS open_order_qty,
           fn_procurement_bounded_interval_qty(
               sl.alloc_base, sl.prefix_base, sl.rn=sl.source_count,
               0,
               GREATEST(COALESCE(receipt.passed_qty,0) - COALESCE(order_item.returned_qty,0) * COALESCE(order_item.unit_rate,1),0)
           ) AS qualified_qty,
           fn_procurement_bounded_interval_qty(
               sl.alloc_base, sl.prefix_base, sl.rn=sl.source_count,
               GREATEST(COALESCE(receipt.passed_qty,0) - COALESCE(order_item.returned_qty,0) * COALESCE(order_item.unit_rate,1),0) + COALESCE(receipt.pending_qty,0),
               GREATEST(COALESCE(receipt.passed_qty,0) - COALESCE(order_item.returned_qty,0) * COALESCE(order_item.unit_rate,1),0) + COALESCE(receipt.pending_qty,0) + GREATEST(COALESCE(receipt.failed_qty,0) - COALESCE(receipt.returned_failure_base,0),0)
           ) AS failed_qty,
           fn_procurement_bounded_interval_qty(
               sl.alloc_base, sl.prefix_base, sl.rn=sl.source_count,
               GREATEST(COALESCE(receipt.passed_qty,0) - COALESCE(order_item.returned_qty,0) * COALESCE(order_item.unit_rate,1),0),
               GREATEST(COALESCE(receipt.passed_qty,0) - COALESCE(order_item.returned_qty,0) * COALESCE(order_item.unit_rate,1),0) + COALESCE(receipt.pending_qty,0)
           ) AS pending_qty
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
