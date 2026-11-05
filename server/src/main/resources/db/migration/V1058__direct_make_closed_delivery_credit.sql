-- Current BOM delivery demand has already removed shipped frontier quantities.
-- Historical MAKE attribution still includes those receipts. Add the exact
-- closed part back only to direct-MAKE total admission, then subtract receipt
-- history once. This is not another demand or a public/aggregate stock budget.
CREATE FUNCTION fn_preplan_direct_make_delivery_closed_qty(p_child UUID,p_material UUID)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
BEGIN
 -- Ordinary manufacturing keeps its existing budget and avoids walking any
 -- delivery ledgers. Only this admitted customer frontier has a closed credit.
 IF NOT EXISTS(SELECT 1 FROM production_material_analysis_items child
   JOIN production_material_analysis_materials material ON material.id=child.parent_analysis_material_id
     AND material.analysis_id=child.analysis_id AND material.id=p_material
     AND material.delivery_frontier AND NOT material.delivery_context AND material.depth>0
   JOIN production_material_analysis_items source ON source.id=material.analysis_item_id
     AND source.analysis_id=material.analysis_id AND source.source_type='SALES_ORDER_ITEM' AND NOT source.is_deleted
     AND source.delivery_plan_snapshot->>'mode'='BOM'
   WHERE child.id=p_child AND child.source_type='MAKE_COMPONENT' AND NOT child.is_deleted) THEN RETURN 0; END IF;
 RETURN (SELECT COALESCE(sum(handoff.quantity),0)
 FROM production_material_analysis_items child
 JOIN production_material_analysis_materials material ON material.id=child.parent_analysis_material_id
   AND material.analysis_id=child.analysis_id AND material.id=p_material
   AND material.delivery_frontier AND NOT material.delivery_context AND material.depth>0
 JOIN production_material_analysis_items source ON source.id=material.analysis_item_id
   AND source.analysis_id=material.analysis_id AND source.source_type='SALES_ORDER_ITEM' AND NOT source.is_deleted
   AND source.delivery_plan_snapshot->>'mode'='BOM'
 JOIN sales_delivery_entitlement_handoffs handoff ON handoff.source_material_id=material.id
   AND handoff.source_analysis_id=material.analysis_id AND handoff.entitlement_material_id=material.id
   AND handoff.entitlement_analysis_id=material.analysis_id AND handoff.aggregate_alias_id IS NULL
 JOIN preplan_stock_entitlement_events origin ON origin.id=handoff.source_entitlement_event_id
   AND origin.event_type='ORIGIN_MAKE' AND origin.stock_reservation_id=handoff.source_reservation_id
   AND origin.beneficiary_analysis_id=material.analysis_id AND origin.beneficiary_analysis_material_id=material.id
 JOIN preplan_analysis_stock_exact_pegs exact ON exact.id=origin.source_exact_peg_id
   AND exact.make_source_analysis_item_id=child.id AND exact.make_public_claim_id IS NULL
   AND exact.source_receipt_type='MAKE' AND exact.stock_reservation_id=handoff.source_reservation_id
 JOIN stock_document_items receipt_item ON receipt_item.id=exact.source_stock_document_item_id
   AND receipt_item.doc_id=exact.source_stock_document_id AND receipt_item.bill_type='FINISHED_IN' AND NOT receipt_item.is_deleted
 JOIN stock_documents receipt ON receipt.id=receipt_item.doc_id AND receipt.status=1 AND NOT receipt.is_deleted
 JOIN production_plan_items plan_item ON plan_item.id=receipt_item.upstream_item_id AND NOT plan_item.is_deleted
 JOIN production_plans plan ON plan.id=plan_item.plan_id AND plan.material_analysis_id=child.analysis_id
   AND plan.material_analysis_item_id=child.id AND NOT plan.is_deleted
 JOIN sales_shipment_delivery_components component ON component.id=handoff.component_id
   AND component.order_item_id=source.sales_order_item_id AND component.goods_id=material.goods_id
   AND component.color_id IS NOT DISTINCT FROM material.color_id AND component.unit_id=material.unit_id
   AND component.bom_fingerprint=source.delivery_plan_snapshot->>'bomFingerprint'
   AND component.reversal_movement_id IS NULL
   AND material.node_key=(SELECT string_agg(edge.value,'/' ORDER BY edge.position)
       FROM jsonb_array_elements_text(component.bom_path) WITH ORDINALITY edge(value,position))
 JOIN sales_shipment_items shipment_item ON shipment_item.id=component.shipment_item_id
   AND shipment_item.shipment_id=component.shipment_id AND shipment_item.order_item_id=component.order_item_id
   AND NOT shipment_item.is_deleted
 JOIN sales_shipments shipment ON shipment.id=component.shipment_id AND shipment.status=1 AND NOT shipment.is_deleted
 JOIN stock_movements movement ON movement.id=component.movement_id AND movement.source_doc_type='SALES_SHIPMENT'
   AND movement.source_doc_id=component.shipment_id AND movement.source_item_id=component.id
   AND movement.movement_type=3 AND movement.direction=-1 AND movement.qty=component.required_qty
   AND movement.goods_id=component.goods_id AND movement.color_id IS NOT DISTINCT FROM component.color_id
   AND movement.warehouse_id=component.warehouse_id AND movement.unit_id=component.unit_id
 JOIN stock_reservations held ON held.id=handoff.target_reservation_id
   AND held.owner_type='SALES_DELIVERY_COMPONENT_SHIPMENT' AND held.owner_id=component.id
   AND held.qty=handoff.quantity AND held.consumed_qty=held.qty AND held.released_qty=0 AND held.status=1 AND NOT held.is_deleted
 JOIN sales_delivery_fulfillment_allocations allocation ON allocation.id=handoff.allocation_id
   AND allocation.analysis_id=material.analysis_id AND allocation.analysis_item_id=source.id
   AND allocation.shipment_item_id=component.shipment_item_id
 JOIN sales_delivery_fulfillment_groups kit ON kit.shipment_item_id=allocation.shipment_item_id
   AND kit.shipment_id=component.shipment_id AND kit.order_item_id=component.order_item_id AND kit.state='COMPLETED'
 JOIN sales_delivery_fulfillment_events fulfilled ON fulfilled.allocation_id=allocation.id AND fulfilled.event_type='FULFILL'
 WHERE child.id=p_child AND child.source_type='MAKE_COMPONENT' AND NOT child.is_deleted
   AND NOT EXISTS(SELECT 1 FROM sales_delivery_fulfillment_events reversed
       WHERE reversed.counter_event_id=fulfilled.id AND reversed.event_type='REVERSE')
   AND NOT EXISTS(SELECT 1 FROM sales_delivery_entitlement_restores restored WHERE restored.handoff_id=handoff.id)
   AND NOT EXISTS(SELECT 1 FROM preplan_stock_entitlement_events restored
       WHERE restored.counter_event_id=handoff.release_event_id AND restored.event_type='RESTORE'));
END;
$$;

CREATE FUNCTION fn_preplan_direct_make_total_capacity(p_child UUID,p_material UUID)
RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN original.qty IS NULL THEN NULL
   ELSE original.qty+fn_preplan_direct_make_delivery_closed_qty(p_child,p_material) END
 FROM (SELECT fn_preplan_aggregate_source_capacity(p_material) AS qty) original;
$$;

CREATE OR REPLACE FUNCTION fn_preplan_direct_make_admitted_qty(p_child UUID,p_material UUID)
RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT COALESCE((SELECT CASE WHEN capacity.qty IS NULL THEN NULL ELSE
   LEAST(child.requested_qty,capacity.qty+COALESCE((SELECT sum(supplement.qty)
     FROM preplan_reallocation_make_supplements supplement
     WHERE supplement.child_analysis_item_id=child.id AND supplement.source_analysis_material_id=material.id),0)) END
 FROM production_material_analysis_items child
 JOIN production_material_analysis_materials material ON material.id=child.parent_analysis_material_id AND material.analysis_id=child.analysis_id
 CROSS JOIN LATERAL (SELECT fn_preplan_direct_make_total_capacity(child.id,material.id) AS qty) capacity
 WHERE child.id=p_child AND material.id=p_material AND child.source_type='MAKE_COMPONENT' AND NOT child.is_deleted),0)::numeric;
$$;

COMMENT ON FUNCTION fn_preplan_direct_make_delivery_closed_qty(UUID,UUID) IS
 'Exact already-attributed direct MAKE receipts actually shipped for this original BOM frontier/order/path, without restore, alias or reversal';
COMMENT ON FUNCTION fn_preplan_direct_make_total_capacity(UUID,UUID) IS
 'Private direct-MAKE historical total only: current remaining capacity plus its closed shipment slices; unknown current capacity remains unknown';
