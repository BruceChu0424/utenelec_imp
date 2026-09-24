-- Accepted loss fulfils a separate portion of the original subcontract contract.
-- It is never received stock and never releases the upstream application capacity.
CREATE FUNCTION fn_subcontract_settled_loss_qty(p_order_item_id UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(loss.loss_qty),0)
    FROM subcontract_short_delivery_cases loss
    LEFT JOIN subcontract_wastes waste ON waste.id=loss.waste_id
    WHERE loss.order_item_id=p_order_item_id
      AND loss.status='ACCEPTED_LOSS' AND loss.decision='ACCEPT_LOSS'
      AND loss.closed_at IS NOT NULL AND loss.loss_qty>0
      -- Older cases already reduced the order. Do not deduct that loss twice.
      AND loss.qty_change_log_id IS NULL
      AND (loss.waste_id IS NULL OR (waste.status=1 AND NOT waste.is_deleted))
$$;
COMMENT ON FUNCTION fn_subcontract_settled_loss_qty(UUID) IS
    'Effective separately settled loss in order units, excluding legacy quantity-change settlements; not stock or receipt quantity';
COMMENT ON COLUMN subcontract_short_delivery_cases.qty_change_log_id IS
    'Legacy loss settlements changed ordered quantity; NULL on new independent loss fulfilment settlements';
COMMENT ON TABLE subcontract_short_delivery_cases IS
    'Subcontract short delivery decisions: retain original ordered quantity; received output and accepted loss settle distinct contract portions';

-- V688 supplement. Install AFTER fn_subcontract_settled_loss_qty(uuid).
-- An accepted loss fulfils the original contract without becoming a receipt,
-- stock movement, source allocation revision, or a new finance approval case.

CREATE OR REPLACE FUNCTION fn_procurement_order_source_remaining_qty(
    p_receipt_type TEXT, p_order_item_id UUID, p_source_item_id UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH order_fact AS (
        SELECT item.qty*COALESCE(item.unit_rate,1) AS receivable_target_base,
               (COALESCE(item.received_qty,0)-COALESCE(item.returned_qty,0))
                   *COALESCE(item.unit_rate,1) AS received_net_base
        FROM purchase_order_items item
        JOIN purchase_orders header ON header.id=item.order_id
        WHERE p_receipt_type='PURCHASE' AND item.id=p_order_item_id
          AND item.is_deleted=FALSE AND header.is_deleted=FALSE AND header.status=1
        UNION ALL
        SELECT GREATEST(item.qty-COALESCE(fn_subcontract_settled_loss_qty(item.id),0),0)
                   *COALESCE(item.unit_rate,1),
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
    -- Keep the original source UUID/FIFO bounds. Loss removes the unreceivable
    -- tail of the contract; it is never added to the physical received prefix.
    SELECT COALESCE((SELECT fn_procurement_source_interval_qty(
        p_receipt_type,p_order_item_id,p_source_item_id,
        GREATEST(fact.received_net_base-returned.base_qty,0),fact.receivable_target_base)
        FROM order_fact fact CROSS JOIN returned_failure returned),0);
$$;

-- Preserve every existing source/analysis mutation guard. Only the subcontract
-- header's completion test changes from raw short quantity to remaining supply
-- for this exact immutable source, including physical IQC returns.
DO $loss_future_source_completion$
DECLARE
    definition TEXT;
    needle TEXT := $anchor$WHERE item.order_id=header_id AND fn_future_external_has_transfers(source.application_item_id)
                AND (NEW.status<>OLD.status OR NEW.is_deleted<>OLD.is_deleted OR item.qty-item.received_qty+item.returned_qty>0)$anchor$;
    replacement TEXT := $replacement$WHERE item.order_id=header_id AND fn_future_external_has_transfers(source.application_item_id)
                AND (NEW.status<>OLD.status OR NEW.is_deleted<>OLD.is_deleted
                     OR fn_procurement_order_source_remaining_qty('SUBCONTRACT',item.id,source.application_item_id)>0)$replacement$;
BEGIN
    SELECT replace(pg_get_functiondef('fn_guard_future_transfer_source_lifecycle()'::regprocedure),E'\r\n',E'\n')
      INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V688 subcontract future-source completion guard anchor changed';
    END IF;
    EXECUTE replace(definition,needle,replacement);
END;
$loss_future_source_completion$;

-- Preserve request ordered_qty, source alloc_qty, required_qty and actual
-- fulfilled_qty. Only approved subcontract orders' remaining work is reduced.
-- Extract the named CTE so the identical PURCHASE arithmetic stays unchanged.
DO $loss_decomposition_open_qty$
DECLARE
    definition TEXT;
    original_block TEXT;
    patched_block TEXT;
    block_start INTEGER;
    block_end INTEGER;
    start_anchor TEXT := 'subcontract_order_rows AS (';
    end_anchor TEXT := '), subcontract_rejected_rows AS (';
    needle TEXT := 'GREATEST(COALESCE(item.qty, 0::numeric) - COALESCE(item.received_qty, 0::numeric) + COALESCE(item.returned_qty, 0::numeric), 0::numeric) AS open_qty';
    replacement TEXT := 'GREATEST(COALESCE(item.qty, 0::numeric) - COALESCE(item.received_qty, 0::numeric) + COALESCE(item.returned_qty, 0::numeric) - COALESCE(fn_subcontract_settled_loss_qty(item.id), 0::numeric), 0::numeric) AS open_qty';
BEGIN
    SELECT pg_get_viewdef('v_procurement_decomposition_tasks'::regclass,true) INTO definition;
    IF (length(definition)-length(replace(definition,start_anchor,'')))/length(start_anchor)<>1
       OR (length(definition)-length(replace(definition,end_anchor,'')))/length(end_anchor)<>1 THEN
        RAISE EXCEPTION 'V688 subcontract decomposition CTE boundaries changed';
    END IF;
    block_start:=strpos(definition,start_anchor);
    block_end:=strpos(definition,end_anchor);
    IF block_end<=block_start THEN RAISE EXCEPTION 'V688 subcontract decomposition CTE order changed'; END IF;
    original_block:=substring(definition FROM block_start FOR block_end-block_start);
    IF (length(original_block)-length(replace(original_block,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V688 subcontract decomposition remaining-quantity anchor changed';
    END IF;
    patched_block:=replace(original_block,needle,replacement);
    EXECUTE 'CREATE OR REPLACE VIEW v_procurement_decomposition_tasks AS '
        || substring(definition FROM 1 FOR block_start-1)
        || patched_block || substring(definition FROM block_end);
END;
$loss_decomposition_open_qty$;

-- Original approved contract quantity remains immutable. Normal-loss costing
-- instead uses the separately accepted receivable output quantity. Legacy
-- quantity-revision cases receive no new credit from the authoritative function,
-- preserving their existing pending-old-quantity treatment without double loss.
CREATE OR REPLACE VIEW v_subcontract_normal_loss_basis AS
SELECT item.id AS order_item_id,
       approved.id AS approval_case_id,
       GREATEST(COALESCE(pending.old_qty,item.qty)
           -COALESCE(fn_subcontract_settled_loss_qty(item.id),0),0)
           *COALESCE(item.unit_rate,1) AS target_qty_base,
       header.status=1 AND approved.id IS NOT NULL AND NOT EXISTS(
           SELECT 1 FROM subcontract_waste_items waste
           JOIN subcontract_wastes document ON document.id=waste.waste_id
           JOIN subcontract_material_issue_items issue ON issue.id=waste.material_issue_item_id
           LEFT JOIN v_subcontract_waste_actual_value value ON value.waste_item_id=waste.id
           WHERE issue.order_item_id=item.id AND document.status=1
             AND NOT document.is_deleted AND NOT waste.is_deleted
             AND value.classified IS DISTINCT FROM TRUE) AS classification_complete
FROM subcontract_order_items item
JOIN subcontract_orders header ON header.id=item.order_id
LEFT JOIN LATERAL (
    SELECT approval.id,approval.decided_at
    FROM procurement_order_approval_cases approval
    WHERE approval.order_type='SUBCONTRACT' AND approval.order_id=header.id AND approval.status='APPROVED'
    ORDER BY approval.decided_at DESC,approval.attempt DESC LIMIT 1
) approved ON TRUE
LEFT JOIN LATERAL (
    SELECT change.old_qty FROM procurement_order_qty_change_logs change
    WHERE change.order_type='SUBCONTRACT' AND change.order_item_id=item.id
      AND change.changed_at>approved.decided_at
    ORDER BY change.changed_at,change.id LIMIT 1
) pending ON TRUE;
COMMENT ON VIEW v_subcontract_normal_loss_basis IS
    'Normal-loss cost output basis is approved contract quantity less independently settled loss; original order/source quantities and finance approval evidence remain unchanged';

-- Reporting uses the same valid waste lifecycle as fulfillment. Historical
-- quantity-revision cases retain their original loss facts for supplier history,
-- but are deliberately NOT credited again by fn_subcontract_settled_loss_qty.
CREATE OR REPLACE VIEW v_subcontract_supplier_goods_loss_summary AS
WITH settled_lines AS (
    SELECT order_item.id AS order_item_id,
           order_doc.supplier_id,
           order_item.goods_id,
           COALESCE(accepted.ordered_qty,order_item.qty) AS ordered_qty,
           COALESCE(fn_subcontract_settled_loss_qty(order_item.id),0)
               +COALESCE(accepted.legacy_loss_qty,0) AS loss_qty,
           COALESCE(accepted.accepted_count,0)>0 AS accepted_loss,
           accepted.closed_at
    FROM subcontract_order_items order_item
    JOIN subcontract_orders order_doc ON order_doc.id=order_item.order_id
      AND order_doc.status=1 AND order_doc.is_deleted=FALSE
    LEFT JOIN LATERAL (
        SELECT MAX(c.ordered_qty) AS ordered_qty,
               COALESCE(SUM(c.loss_qty) FILTER (WHERE c.qty_change_log_id IS NOT NULL),0) AS legacy_loss_qty,
               COUNT(*) AS accepted_count,
               MAX(c.closed_at) AS closed_at
        FROM subcontract_short_delivery_cases c
        WHERE c.order_item_id=order_item.id AND c.status='ACCEPTED_LOSS' AND c.loss_qty>0
          AND (c.waste_id IS NULL OR EXISTS (
              SELECT 1 FROM subcontract_wastes waste
              WHERE waste.id=c.waste_id AND waste.status=1 AND NOT waste.is_deleted))
    ) accepted ON TRUE
    WHERE order_item.is_deleted=FALSE AND order_doc.supplier_id IS NOT NULL
      AND COALESCE(order_item.qty,0)>0
      AND (COALESCE(accepted.accepted_count,0)>0
           OR COALESCE(order_item.received_qty,0)-COALESCE(order_item.returned_qty,0)>=COALESCE(order_item.qty,0))
)
SELECT supplier_id,goods_id,
       COUNT(*)::bigint AS settled_line_count,
       COUNT(*) FILTER (WHERE accepted_loss)::bigint AS accepted_loss_count,
       SUM(ordered_qty) AS ordered_qty,
       SUM(loss_qty) AS loss_qty,
       CASE WHEN SUM(ordered_qty)>0 THEN ROUND(SUM(loss_qty)*100/SUM(ordered_qty),2) ELSE 0 END AS loss_pct,
       MAX(CASE WHEN ordered_qty>0 THEN ROUND(loss_qty*100/ordered_qty,2) ELSE 0 END) AS max_loss_pct,
       MAX(closed_at) AS last_loss_at
FROM settled_lines GROUP BY supplier_id,goods_id;
COMMENT ON VIEW v_subcontract_supplier_goods_loss_summary IS
    'Accepted loss keeps the original order quantity; valid independent loss plus valid historical quantity-revision loss is reported once per order line, and reversed waste no longer counts';

-- v_subcontract_supplier_loss_summary already aggregates this unchanged column
-- contract, so no separate formula or duplicate loss-credit calculation is added.
