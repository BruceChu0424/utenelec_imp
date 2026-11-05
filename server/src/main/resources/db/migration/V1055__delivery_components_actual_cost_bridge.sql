-- Attribute each physical COGS slice to its commercial parent without changing any original movement/value fact.
CREATE OR REPLACE FUNCTION fn_cost_original_document_identity(p_type TEXT,p_item UUID,p_goods UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE source_table TEXT; item JSONB;
BEGIN
 IF p_type='SALES_SHIPMENT' AND p_item IS NOT NULL THEN
  SELECT to_jsonb(component) INTO item FROM sales_shipment_delivery_components component WHERE id=p_item AND goods_id=p_goods;
  IF item IS NOT NULL THEN RETURN jsonb_build_object('goodsId',p_goods,'goodsCode',item->>'goods_code_snapshot',
   'goodsName',item->>'goods_name_snapshot','unitId',item->>'unit_id','unitName',item->>'unit_name_snapshot',
   'state','MISSING','source','ORIGINAL_DELIVERY_COMPONENT'); END IF;
 END IF;
 source_table:=CASE p_type WHEN 'STOCK_DOC' THEN 'stock_document_items'
  WHEN 'PURCHASE_RECEIPT' THEN 'purchase_receipt_items' WHEN 'PURCHASE_RETURN' THEN 'purchase_return_items'
  WHEN 'SUBCONTRACT_RECEIPT' THEN 'subcontract_receipt_items' WHEN 'SUBCONTRACT_RETURN' THEN 'subcontract_return_items'
  WHEN 'SALES_SHIPMENT' THEN 'sales_shipment_items' WHEN 'SALES_RETURN' THEN 'sales_return_items' END;
 IF source_table IS NULL OR p_item IS NULL OR to_regclass('public.'||source_table) IS NULL THEN RETURN NULL; END IF;
 EXECUTE format('SELECT to_jsonb(item) FROM %I item WHERE id=$1 AND goods_id=$2',source_table) INTO item USING p_item,p_goods;
 IF item IS NULL OR item->>'goods_snapshot_locked_at' IS NULL OR COALESCE(item->>'goods_snapshot_source','') LIKE 'BACKFILL%'
   OR NULLIF(item->>'goods_snapshot_source','') IS NULL THEN RETURN NULL; END IF;
 RETURN jsonb_build_object('goodsId',p_goods,'goodsCode',item->>'goods_code_snapshot','goodsName',item->>'goods_name_snapshot',
  'unitId',CASE WHEN COALESCE((item->>'unit_rate')::numeric,0)=1 THEN item->>'unit_id' END,
  'unitName',NULL,'state','MISSING','source','ORIGINAL_DOCUMENT_PARTIAL');
END $$;

CREATE OR REPLACE VIEW v_stock_actual_cogs_postings AS
SELECT posting.id posting_id,posting.event_id,posting.node_id,
       COALESCE(component.shipment_item_id,posting.owner_id) shipment_item_id,
       item.shipment_id,shipment.client_id,item.goods_id,pool.warehouse_id,pool.color_id,
       event.operation,event.source_doc_type,event.source_doc_id,event.source_item_id,
       (event.occurred_at AT TIME ZONE 'Asia/Shanghai')::date business_date,
       to_char(event.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM') source_period,
       posting.amount_delta_local amount_local,posting.created_at,COALESCE(revision.revision,1) value_revision,
       (node.id IS NULL OR item.id IS NULL OR shipment.id IS NULL OR node.value_model<>'EXACT_SOURCE_SHARES' OR node.pending_parents>0
         OR fn_inventory_value_node_revaluation_pending(node.id)
         OR EXISTS(SELECT 1 FROM stock_value_jobs job WHERE job.event_id=posting.event_id AND job.status='PENDING')
         OR EXISTS(SELECT 1 FROM stock_value_tasks task WHERE task.event_id=posting.event_id AND task.status='PENDING')) pending
FROM stock_value_postings posting
JOIN stock_value_events event ON event.id=posting.event_id
LEFT JOIN stock_value_nodes node ON node.id=posting.node_id
LEFT JOIN stock_value_node_revisions revision ON revision.node_id=posting.node_id
 AND revision.event_id=posting.event_id AND revision.task_id IS NOT DISTINCT FROM posting.task_id
LEFT JOIN stock_value_pools pool ON pool.id=node.pool_id
LEFT JOIN sales_shipment_delivery_components component ON component.id=posting.owner_id
LEFT JOIN sales_shipment_items item ON item.id=COALESCE(component.shipment_item_id,posting.owner_id)
LEFT JOIN sales_shipments shipment ON shipment.id=item.shipment_id
WHERE posting.owner_kind='COGS';

CREATE OR REPLACE VIEW v_stock_actual_sales_cost_coverage AS
SELECT item.id shipment_item_id,item.shipment_id,shipment.client_id,item.goods_id,
       (movement.transaction_date AT TIME ZONE 'Asia/Shanghai')::date business_date,
       bool_or(event.id IS NULL OR node.id IS NULL OR node.value_model<>'EXACT_SOURCE_SHARES' OR node.pending_parents>0
         OR fn_inventory_value_node_revaluation_pending(node.id)) pending
FROM stock_movements movement
LEFT JOIN sales_shipment_delivery_components component ON component.id=movement.source_item_id
JOIN sales_shipment_items item ON item.id=COALESCE(component.shipment_item_id,movement.source_item_id)
JOIN sales_shipments shipment ON shipment.id=item.shipment_id
LEFT JOIN stock_value_events event ON event.movement_id=movement.id
LEFT JOIN stock_value_nodes node ON node.id=event.result_node_id
WHERE movement.source_doc_type='SALES_SHIPMENT' AND movement.movement_type IN(3,20)
GROUP BY item.id,item.shipment_id,shipment.client_id,item.goods_id,(movement.transaction_date AT TIME ZONE 'Asia/Shanghai')::date
UNION ALL
SELECT item.id,item.shipment_id,shipment.client_id,item.goods_id,
       (event.occurred_at AT TIME ZONE 'Asia/Shanghai')::date,
       (node.value_model<>'EXACT_SOURCE_SHARES' OR node.pending_parents>0 OR fn_inventory_value_node_revaluation_pending(node.id))
FROM stock_value_position_transfers transfer
JOIN stock_value_events event ON event.id=transfer.event_id
JOIN stock_value_nodes node ON (node.id=transfer.source_root_id OR node.id=transfer.target_node_id) AND node.owner_kind='COGS'
LEFT JOIN sales_shipment_delivery_components component ON component.id=node.owner_id
JOIN sales_shipment_items item ON item.id=COALESCE(component.shipment_item_id,node.owner_id)
JOIN sales_shipments shipment ON shipment.id=item.shipment_id;
