-- Ordinary stock receive cancellation shares the existing unused-receipt graph
-- proof, including its real SOURCE and predecessor pool. Newer receipts
-- and downstream issues must be handled first; balances alone are insufficient.
CREATE FUNCTION fn_assert_unused_stock_receipt_reversal(p_event UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE reversed stock_value_events%ROWTYPE;original stock_value_events%ROWTYPE;
    cursor stock_value_nodes%ROWTYPE;removed stock_value_nodes%ROWTYPE;next_pool stock_value_nodes%ROWTYPE;
    source stock_value_nodes%ROWTYPE;previous stock_value_nodes%ROWTYPE;old_head stock_value_nodes%ROWTYPE;
    original_move stock_movements%ROWTYPE;reverse_move stock_movements%ROWTYPE;
BEGIN
    SELECT * INTO reversed FROM stock_value_events WHERE id=p_event;
    SELECT * INTO original FROM stock_value_events WHERE id=reversed.position_store_reversal_of;
    SELECT * INTO source FROM stock_value_nodes WHERE id=original.result_node_id;
    SELECT * INTO old_head FROM stock_value_nodes WHERE id=original.result_head_id;
    SELECT * INTO cursor FROM stock_value_nodes WHERE id=reversed.result_node_id;
    SELECT parent.* INTO removed FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
        WHERE edge.child_node_id=cursor.id AND edge.creation_event_id=reversed.id;
    SELECT * INTO next_pool FROM stock_value_nodes WHERE id=reversed.result_head_id;
    SELECT parent.* INTO previous FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
        WHERE edge.child_node_id=old_head.id AND parent.kind='POOL';
    SELECT * INTO original_move FROM stock_movements WHERE id=original.movement_id;
    SELECT * INTO reverse_move FROM stock_movements WHERE id=reversed.movement_id;
    IF reversed.operation IS DISTINCT FROM 'POSITION_STORE_REVERSE' OR original.operation IS DISTINCT FROM 'RECEIVE'
        OR original.source_doc_type IS DISTINCT FROM 'STOCK_DOC' OR reversed.source_doc_type IS DISTINCT FROM original.source_doc_type
        OR reversed.source_doc_id IS DISTINCT FROM original.source_doc_id OR reversed.source_item_id IS DISTINCT FROM original.source_item_id
        OR reversed.pool_id IS DISTINCT FROM original.pool_id OR source.id IS NULL OR source.kind<>'SOURCE'
        OR reversed.source_node_id IS DISTINCT FROM source.id OR reversed.result_source_revision IS DISTINCT FROM source.revision
        OR reversed.qty_base IS DISTINCT FROM original.qty_base OR reversed.known_value_local IS DISTINCT FROM source.basis_value_local
        OR NOT EXISTS(SELECT 1 FROM stock_documents doc JOIN stock_document_items item ON item.doc_id=doc.id
            WHERE doc.id=original.source_doc_id AND item.id=original.source_item_id AND doc.doc_type IN('OTHER_IN','FINISHED_IN')
                AND NOT fn_is_production_linked_stock_document(doc.id))
        OR EXISTS(SELECT 1 FROM stock_value_production_cost_outputs WHERE source_node_id=source.id)
        OR EXISTS(WITH RECURSIVE descendants(id) AS (
            SELECT source.id UNION SELECT edge.child_node_id FROM stock_value_edges edge JOIN descendants parent ON parent.id=edge.parent_node_id
                WHERE edge.interval_to>edge.interval_from)
            SELECT 1 FROM descendants child JOIN stock_value_nodes node ON node.id=child.id WHERE node.kind='ISSUE_POSITION')
        OR cursor.kind IS DISTINCT FROM 'REVERSED_POOL_CURSOR' OR cursor.creation_event_id IS DISTINCT FROM reversed.id
        OR cursor.pool_id IS DISTINCT FROM reversed.pool_id OR cursor.initial_known_value IS DISTINCT FROM removed.basis_value_local
        OR removed.id IS NULL OR removed.active OR removed.quantity_basis IS DISTINCT FROM reversed.qty_before
        OR NOT fn_stock_value_unused_receipt_head(removed.id,original.result_head_id)
        OR next_pool.kind IS DISTINCT FROM 'POOL' OR next_pool.creation_event_id IS DISTINCT FROM reversed.id
        OR next_pool.pool_id IS DISTINCT FROM reversed.pool_id OR next_pool.quantity_basis IS DISTINCT FROM reversed.qty_before-reversed.qty_base
        OR next_pool.quantity_basis IS DISTINCT FROM COALESCE(previous.quantity_basis,0)
        OR next_pool.initial_known_value IS DISTINCT FROM COALESCE(previous.basis_value_local,0)
        OR removed.basis_value_local IS DISTINCT FROM next_pool.initial_known_value+reversed.known_value_local
        OR original_move.id IS NULL OR reverse_move.id IS NULL OR original_move.direction<>1 OR reverse_move.direction<>-1
        OR reverse_move.source_doc_id IS DISTINCT FROM original_move.source_doc_id OR reverse_move.source_item_id IS DISTINCT FROM original_move.source_item_id
        OR reverse_move.goods_id IS DISTINCT FROM original_move.goods_id OR reverse_move.color_id IS DISTINCT FROM original_move.color_id
        OR reverse_move.warehouse_id IS DISTINCT FROM original_move.warehouse_id OR reverse_move.movement_type IS DISTINCT FROM original_move.movement_type
        OR reverse_move.qty IS DISTINCT FROM original_move.qty OR reverse_move.qty IS DISTINCT FROM reversed.qty_base
        OR (reversed.known_value_local<>0 AND (NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=reversed.id
                AND node_id=removed.id AND owner_kind='INVENTORY' AND amount_delta_local=-reversed.known_value_local)
            OR NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=reversed.id AND node_id=source.id
                AND owner_kind='SOURCE' AND owner_id=original.source_event_id AND amount_delta_local=reversed.known_value_local)))
        OR (reversed.known_value_local=0 AND EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=reversed.id))
        OR (source.source_final AND source.pending_parents=0 AND reversed.result_state<>'FINAL')
        OR ((NOT source.source_final OR source.pending_parents<>0) AND reversed.result_state<>'PENDING') THEN
        RAISE EXCEPTION 'stock receive reversal must restore the original unused cost contribution and physical predecessor' USING ERRCODE='23514';
    END IF;
END;
$$;

-- Preserve all preceding POSITION_STORE proofs, including V847's material
-- return rules; restore V536's production RECEIVE dispatch as a separate path.
DO $$
DECLARE definition TEXT;begin_at INTEGER;
BEGIN
    SELECT pg_get_functiondef('fn_check_stock_value_reverse_store()'::regprocedure) INTO definition;
    begin_at:=position('BEGIN' IN definition);
    IF begin_at=0 THEN RAISE EXCEPTION 'stock reverse store proof lacks its expected function entry'; END IF;
    EXECUTE overlay(definition placing E'BEGIN\n    IF NEW.operation=''POSITION_STORE_REVERSE'' AND EXISTS(SELECT 1 FROM stock_value_events WHERE id=NEW.position_store_reversal_of AND operation=''RECEIVE'') THEN\n        IF EXISTS(SELECT 1 FROM stock_documents doc JOIN stock_document_items item ON item.doc_id=doc.id WHERE doc.id=NEW.source_doc_id AND item.id=NEW.source_item_id AND doc.doc_type IN(''OTHER_IN'',''FINISHED_IN'') AND NOT fn_is_production_linked_stock_document(doc.id)) THEN\n            PERFORM fn_assert_unused_stock_receipt_reversal(NEW.id);\n        ELSE\n            PERFORM fn_assert_unused_production_receipt_reversal(NEW.id);\n        END IF;\n        RETURN NULL;\n    END IF;' from begin_at for 5);
END;
$$;
