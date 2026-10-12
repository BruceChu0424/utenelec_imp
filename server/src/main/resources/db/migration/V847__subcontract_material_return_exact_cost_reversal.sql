-- The historical workshop path keeps its exact predicate. The additive branch
-- certifies only a real SC material return store and its original issue owner.
CREATE OR REPLACE FUNCTION fn_is_workshop_material_value_store(p_event UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM stock_value_events event
   JOIN production_material_return_request_items item ON item.request_id=event.source_doc_id
     AND item.stock_document_item_id=event.source_item_id
   JOIN stock_movements movement ON movement.id=event.movement_id
     AND movement.source_doc_type='STOCK_DOC' AND movement.source_doc_id=item.request_id
     AND movement.source_item_id=item.stock_document_item_id AND movement.direction=1
     AND movement.movement_type=CASE WHEN item.issue_posting_id IS NOT NULL THEN 6 ELSE 7 END
     AND movement.qty=item.qty_base
   WHERE event.id=p_event AND event.operation='POSITION_STORE' AND event.source_doc_type='STOCK_DOC')
 OR EXISTS(SELECT 1 FROM stock_value_events event
   JOIN stock_movements movement ON movement.id=event.movement_id
   JOIN subcontract_material_return_items item ON item.id=event.source_item_id AND item.material_return_id=event.source_doc_id
   JOIN subcontract_material_returns document ON document.id=item.material_return_id
   JOIN subcontract_material_issue_items issue ON issue.id=item.material_issue_item_id
   JOIN subcontract_material_issues issue_document ON issue_document.id=issue.issue_id
   JOIN stock_value_pools pool ON pool.id=event.pool_id
   WHERE event.id=p_event AND event.operation='POSITION_STORE' AND event.source_doc_type='SUBCONTRACT_MATERIAL_RETURN'
     AND movement.source_doc_type=event.source_doc_type AND movement.source_doc_id=event.source_doc_id
     AND movement.source_item_id=event.source_item_id AND movement.direction=1 AND movement.movement_type=16
     AND movement.qty=event.qty_base AND movement.qty=round(item.qty*COALESCE(item.unit_rate,1),4)
     AND pool.warehouse_id=movement.warehouse_id AND pool.warehouse_id=document.warehouse_id
     AND pool.goods_id=movement.goods_id AND pool.goods_id=item.goods_id AND pool.goods_id=issue.goods_id
     AND pool.color_id IS NOT DISTINCT FROM movement.color_id AND pool.color_id IS NOT DISTINCT FROM item.color_id
     AND pool.color_id IS NOT DISTINCT FROM issue.color_id
     AND item.unit_id IS NOT DISTINCT FROM issue.unit_id AND COALESCE(item.unit_rate,1)=COALESCE(issue.unit_rate,1)
     AND document.supplier_id IS NOT DISTINCT FROM issue_document.supplier_id
     AND EXISTS(SELECT 1 FROM stock_value_position_transfers transfer
       JOIN stock_value_nodes source ON source.id=transfer.source_node_id
       WHERE transfer.event_id=event.id AND source.owner_kind='SUBCONTRACT_WIP' AND source.owner_id=issue.id)
     AND NOT EXISTS(SELECT 1 FROM stock_value_position_transfers transfer
       JOIN stock_value_nodes source ON source.id=transfer.source_node_id
       WHERE transfer.event_id=event.id AND (source.owner_kind<>'SUBCONTRACT_WIP' OR source.owner_id IS DISTINCT FROM issue.id)))
$$;

CREATE OR REPLACE FUNCTION fn_workshop_return_value_owner_allowed(p_event UUID,p_node UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM stock_value_events event
  JOIN stock_documents document ON document.id=event.source_doc_id AND document.doc_type='WDRAW'
  JOIN production_material_return_request_items requested ON requested.request_id=document.id
    AND requested.stock_document_item_id=event.source_item_id
  JOIN stock_value_nodes node ON node.id=p_node
  JOIN stock_value_events original ON original.id=event.position_store_reversal_of AND original.operation='POSITION_STORE'
    AND original.source_doc_id=event.source_doc_id AND original.source_item_id=event.source_item_id
  WHERE event.id=p_event AND event.operation='POSITION_STORE_REVERSE' AND event.source_doc_type='STOCK_DOC'
    AND (node.owner_kind='WIP' AND node.owner_id=requested.issue_posting_id
      OR node.owner_kind='IN_TRANSIT' AND node.owner_id=requested.stock_document_item_id AND requested.direct_transfer_item_id IS NOT NULL))
 OR EXISTS(SELECT 1 FROM stock_value_events event
  JOIN subcontract_material_return_items item ON item.id=event.source_item_id AND item.material_return_id=event.source_doc_id
  JOIN stock_value_events original ON original.id=event.position_store_reversal_of
    AND original.source_doc_type=event.source_doc_type AND original.source_doc_id=event.source_doc_id
    AND original.source_item_id=event.source_item_id
  JOIN stock_value_nodes node ON node.id=p_node
  WHERE event.id=p_event AND event.operation='POSITION_STORE_REVERSE' AND event.source_doc_type='SUBCONTRACT_MATERIAL_RETURN'
    AND fn_is_workshop_material_value_store(original.id)
    AND node.owner_kind='SUBCONTRACT_WIP' AND node.owner_id=item.material_issue_item_id
    AND node.pool_id IN(SELECT pool_id FROM stock_value_position_transfers source_transfer
      JOIN stock_value_nodes source_node ON source_node.id=source_transfer.source_node_id
      WHERE source_transfer.event_id=original.id AND source_node.owner_kind='SUBCONTRACT_WIP'
        AND source_node.owner_id=item.material_issue_item_id))
$$;

COMMENT ON FUNCTION fn_is_workshop_material_value_store(UUID) IS
 'Exact physical material-return POSITION_STORE sources: retained workshop receipts plus supplier material returns tied to their original issue custody';

-- V843 added confirmed-zero IQC checks by replacing the generic function. Restore
-- the V619 exact material-store dispatch while retaining every current IQC guard.
DO $exact_material_store_dispatch$
DECLARE definition TEXT; anchor TEXT:='IF NEW.operation<>''POSITION_STORE_REVERSE'' THEN RETURN NULL; END IF;'; branch TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_check_stock_value_reverse_store()'::regprocedure) INTO definition;
 IF position('PERFORM fn_assert_workshop_material_value_store_reverse(NEW.id)' IN definition)>0 THEN
  RETURN;
 END IF;
 IF position(anchor IN definition)=0 THEN
  RAISE EXCEPTION 'Reverse-store validation entry changed before V847';
 END IF;
 branch:=E'IF NEW.operation=''POSITION_STORE_REVERSE'' AND fn_is_workshop_material_value_store(NEW.position_store_reversal_of) THEN\n        PERFORM fn_assert_workshop_material_value_store_reverse(NEW.id); RETURN NULL;\n    END IF;\n    '||anchor;
 EXECUTE overlay(definition placing branch from position(anchor IN definition) for length(anchor));
END $exact_material_store_dispatch$;

-- Only the existing domain guard's 23514 refusal is data. Unexpected SQL errors
-- still fail normally. This read-only PL/pgSQL exception boundary keeps a refused
-- readiness SELECT from aborting the caller's transaction.
CREATE FUNCTION fn_workshop_return_retained_value_readiness(p_current UUID,p_original UUID)
RETURNS TABLE(node_ids UUID[],blocking_reason TEXT) LANGUAGE plpgsql STABLE AS $$
BEGIN
 SELECT COALESCE(array_agg(kept.node_id ORDER BY kept.node_id),ARRAY[]::UUID[])
 INTO node_ids FROM fn_workshop_return_retained_value_nodes(p_current,p_original) kept;
 blocking_reason:=NULL;
 RETURN NEXT;
EXCEPTION WHEN SQLSTATE '23514' THEN
 node_ids:=ARRAY[]::UUID[];
 blocking_reason:=SQLERRM;
 RETURN NEXT;
END $$;

COMMENT ON FUNCTION fn_workshop_return_retained_value_readiness(UUID,UUID) IS
 'Pure material-store withdrawal readiness: exact retained nodes or the original domain refusal, without writes or caller transaction poisoning';
