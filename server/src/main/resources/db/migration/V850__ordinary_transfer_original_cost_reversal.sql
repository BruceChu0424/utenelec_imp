-- The reverse target leg removes only its original unused RETURN_SOURCE value.
-- A linked reverse source leg then returns that exact new IN_TRANSIT issue.
CREATE FUNCTION fn_assert_unused_stock_transfer_in_reversal(p_event UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE reversed stock_value_events%ROWTYPE;original stock_value_events%ROWTYPE;source stock_value_nodes%ROWTYPE;
    original_head stock_value_nodes%ROWTYPE;previous stock_value_nodes%ROWTYPE;removed stock_value_nodes%ROWTYPE;
    cursor stock_value_nodes%ROWTYPE;transit stock_value_nodes%ROWTYPE;next_pool stock_value_nodes%ROWTYPE;
    old_issue stock_value_nodes%ROWTYPE;old_move stock_movements%ROWTYPE;new_move stock_movements%ROWTYPE;
    source_leg stock_value_events%ROWTYPE;doc stock_documents%ROWTYPE;
BEGIN
    SELECT * INTO reversed FROM stock_value_events WHERE id=p_event;
    SELECT * INTO original FROM stock_value_events WHERE id=reversed.position_store_reversal_of;
    SELECT * INTO source FROM stock_value_nodes WHERE id=original.result_node_id;
    SELECT * INTO original_head FROM stock_value_nodes WHERE id=original.result_head_id;
    SELECT * INTO previous FROM stock_value_nodes WHERE id=(SELECT parent.id FROM stock_value_edges edge
        JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id WHERE edge.child_node_id=original_head.id AND parent.kind='POOL');
    SELECT * INTO cursor FROM stock_value_nodes WHERE creation_event_id=reversed.id AND kind='REVERSED_POOL_CURSOR';
    SELECT * INTO removed FROM stock_value_nodes WHERE id=(SELECT edge.parent_node_id FROM stock_value_edges edge WHERE edge.child_node_id=cursor.id);
    SELECT * INTO transit FROM stock_value_nodes WHERE id=reversed.result_node_id;
    SELECT * INTO next_pool FROM stock_value_nodes WHERE id=reversed.result_head_id;
    SELECT * INTO old_issue FROM stock_value_nodes WHERE id=original.source_node_id;
    SELECT * INTO old_move FROM stock_movements WHERE id=original.movement_id;
    SELECT * INTO new_move FROM stock_movements WHERE id=reversed.movement_id;
    SELECT * INTO source_leg FROM stock_value_events WHERE source_doc_type='STOCK_DOC' AND source_doc_id=reversed.source_doc_id
        AND source_item_id=reversed.source_item_id AND operation='RETURN_ISSUE' AND source_node_id=transit.id;
    SELECT * INTO doc FROM stock_documents WHERE id=reversed.source_doc_id;
    IF reversed.operation IS DISTINCT FROM 'POSITION_STORE_REVERSE' OR original.operation IS DISTINCT FROM 'RETURN_ISSUE'
        OR original.source_doc_type IS DISTINCT FROM 'STOCK_DOC' OR doc.doc_type IS DISTINCT FROM 'TRANSFER'
        OR fn_is_production_linked_stock_document(doc.id)
        OR original.source_doc_id IS DISTINCT FROM reversed.source_doc_id OR original.source_item_id IS DISTINCT FROM reversed.source_item_id
        OR original.pool_id IS DISTINCT FROM reversed.pool_id OR source.id IS NULL OR source.kind<>'RETURN_SOURCE'
        OR old_issue.kind IS DISTINCT FROM 'ISSUE_POSITION' OR old_issue.root_issue_id IS DISTINCT FROM old_issue.id
        OR source.root_issue_id IS DISTINCT FROM old_issue.id
        OR reversed.source_node_id IS DISTINCT FROM source.id OR reversed.result_source_revision IS DISTINCT FROM source.revision
        OR reversed.qty_base IS DISTINCT FROM original.qty_base OR reversed.known_value_local IS DISTINCT FROM source.basis_value_local
        OR cursor.id IS NULL OR cursor.initial_known_value IS DISTINCT FROM removed.basis_value_local
        OR removed.active OR removed.quantity_basis IS DISTINCT FROM reversed.qty_before
        OR NOT fn_stock_value_unused_receipt_head(removed.id,original.result_head_id)
        OR transit.kind IS DISTINCT FROM 'ISSUE_POSITION' OR transit.root_issue_id IS DISTINCT FROM transit.id
        OR transit.owner_kind IS DISTINCT FROM 'IN_TRANSIT' OR transit.owner_id IS DISTINCT FROM reversed.source_item_id
        OR transit.movement_id IS DISTINCT FROM reversed.movement_id OR transit.creation_event_id IS DISTINCT FROM reversed.id
        OR transit.quantity_basis IS DISTINCT FROM reversed.qty_base OR transit.range_from<>0 OR transit.range_to<>reversed.qty_base
        OR transit.initial_known_value IS DISTINCT FROM reversed.known_value_local
        OR NOT EXISTS(SELECT 1 FROM stock_value_edges edge JOIN stock_value_nodes retained ON retained.id=edge.parent_node_id
            WHERE edge.child_node_id=transit.id AND retained.kind='VALUE_REFERENCE' AND retained.reference_root_id=source.id
                AND retained.creation_event_id=reversed.id AND edge.interval_from=0 AND edge.interval_to=1 AND edge.denominator=1)
        OR EXISTS(WITH RECURSIVE descendants(id) AS (SELECT source.id UNION
            SELECT edge.child_node_id FROM stock_value_edges edge JOIN descendants parent ON parent.id=edge.parent_node_id
                WHERE edge.interval_to>edge.interval_from)
            SELECT 1 FROM descendants child JOIN stock_value_nodes node ON node.id=child.id
                WHERE node.kind='ISSUE_POSITION' AND node.root_issue_id IS DISTINCT FROM transit.id)
        OR next_pool.kind IS DISTINCT FROM 'POOL' OR next_pool.creation_event_id IS DISTINCT FROM reversed.id
        OR next_pool.quantity_basis IS DISTINCT FROM COALESCE(previous.quantity_basis,0)
        OR next_pool.quantity_basis IS DISTINCT FROM reversed.qty_before-reversed.qty_base
        OR next_pool.initial_known_value IS DISTINCT FROM COALESCE(previous.basis_value_local,0)
        OR removed.basis_value_local IS DISTINCT FROM next_pool.initial_known_value+reversed.known_value_local
        OR old_move.movement_type<>7 OR old_move.direction<>1 OR old_move.warehouse_id IS DISTINCT FROM doc.to_warehouse_id
        OR new_move.movement_type<>7 OR new_move.direction<>-1 OR new_move.warehouse_id IS DISTINCT FROM doc.to_warehouse_id
        OR new_move.source_doc_id IS DISTINCT FROM old_move.source_doc_id OR new_move.source_item_id IS DISTINCT FROM old_move.source_item_id
        OR new_move.goods_id IS DISTINCT FROM old_move.goods_id OR new_move.color_id IS DISTINCT FROM old_move.color_id
        OR new_move.qty IS DISTINCT FROM old_move.qty OR new_move.qty IS DISTINCT FROM reversed.qty_base
        OR source_leg.id IS NULL OR source_leg.qty_base IS DISTINCT FROM reversed.qty_base OR source_leg.known_value_local IS DISTINCT FROM reversed.known_value_local
        OR NOT EXISTS(SELECT 1 FROM stock_movements movement WHERE movement.id=source_leg.movement_id
            AND movement.movement_type=8 AND movement.direction=1 AND movement.warehouse_id=doc.warehouse_id
            AND movement.source_doc_id=doc.id AND movement.source_item_id=reversed.source_item_id
            AND movement.goods_id=new_move.goods_id AND movement.color_id IS NOT DISTINCT FROM new_move.color_id AND movement.qty=new_move.qty)
        OR (reversed.known_value_local<>0 AND (NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=reversed.id AND node_id=removed.id
            AND owner_kind='INVENTORY' AND owner_id=reversed.pool_id AND amount_delta_local=-reversed.known_value_local)
            OR NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=reversed.id AND node_id=transit.id
                AND owner_kind='IN_TRANSIT' AND owner_id=reversed.source_item_id AND amount_delta_local=reversed.known_value_local)))
        OR (reversed.known_value_local=0 AND EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=reversed.id)) THEN
        RAISE EXCEPTION 'transfer reversal must preserve original return-source cost, two physical legs and unused destination predecessor' USING ERRCODE='23514';
    END IF;
END;
$$;

-- The existing retained-value reference guard is intentionally specific to
-- workshop material restores. Admit only this independently proven transfer
-- contribution into its one exact IN_TRANSIT issue; preserve that old branch.
CREATE FUNCTION fn_assert_stock_transfer_value_reference(p_node UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE reference stock_value_nodes%ROWTYPE;original stock_value_nodes%ROWTYPE;parent stock_value_nodes%ROWTYPE;
    issue stock_value_nodes%ROWTYPE;event stock_value_events%ROWTYPE;source_event stock_value_events%ROWTYPE;expected_parent UUID;
BEGIN
    SELECT * INTO reference FROM stock_value_nodes WHERE id=p_node;
    SELECT * INTO original FROM stock_value_nodes WHERE id=reference.reference_root_id;
    SELECT * INTO event FROM stock_value_events WHERE id=reference.creation_event_id;
    SELECT * INTO source_event FROM stock_value_events WHERE id=event.position_store_reversal_of;
    SELECT * INTO issue FROM stock_value_nodes WHERE id=event.result_node_id;
    SELECT * INTO parent FROM stock_value_nodes WHERE id=(SELECT edge.parent_node_id FROM stock_value_edges edge
        WHERE edge.child_node_id=reference.id AND edge.creation_event_id=reference.creation_event_id
            AND edge.interval_from=0 AND edge.interval_to=1 AND edge.denominator=1);
    SELECT id INTO expected_parent FROM stock_value_nodes WHERE reference_root_id=original.id AND kind='VALUE_REFERENCE'
        AND node_sequence<reference.node_sequence ORDER BY node_sequence DESC LIMIT 1;
    expected_parent:=COALESCE(expected_parent,original.id);
    IF reference.kind IS DISTINCT FROM 'VALUE_REFERENCE' OR original.kind IS DISTINCT FROM 'RETURN_SOURCE'
        OR original.id IS DISTINCT FROM source_event.result_node_id OR original.pool_id IS DISTINCT FROM reference.pool_id
        OR original.quantity_basis IS DISTINCT FROM reference.quantity_basis OR parent.id IS DISTINCT FROM expected_parent
        OR parent.quantity_basis IS DISTINCT FROM reference.quantity_basis OR parent.pool_id IS DISTINCT FROM reference.pool_id
        OR reference.active OR reference.owned_value_local<>0
        OR event.operation IS DISTINCT FROM 'POSITION_STORE_REVERSE' OR source_event.operation IS DISTINCT FROM 'RETURN_ISSUE'
        OR source_event.source_doc_type IS DISTINCT FROM 'STOCK_DOC'
        OR issue.kind IS DISTINCT FROM 'ISSUE_POSITION' OR issue.root_issue_id IS DISTINCT FROM issue.id
        OR issue.owner_kind IS DISTINCT FROM 'IN_TRANSIT' OR issue.creation_event_id IS DISTINCT FROM event.id
        OR (SELECT COUNT(*) FROM stock_value_edges WHERE child_node_id=reference.id)<>1
        OR (SELECT COUNT(*) FROM stock_value_edges WHERE parent_node_id=reference.id)<>1
        OR NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE parent_node_id=reference.id AND child_node_id=issue.id
            AND creation_event_id=event.id AND interval_from=0 AND interval_to=1 AND denominator=1) THEN
        RAISE EXCEPTION 'transfer retained value must keep its original return source and one exact transit issue' USING ERRCODE='23514';
    END IF;
    PERFORM fn_assert_unused_stock_transfer_in_reversal(event.id);
END;
$$;

DO $$
DECLARE definition TEXT;begin_at INTEGER;
BEGIN
    SELECT pg_get_functiondef('fn_assert_stock_value_reference(uuid)'::regprocedure) INTO definition;
    begin_at:=position('BEGIN' IN definition);
    IF begin_at=0 THEN RAISE EXCEPTION 'transfer value reference lacks current guard entry'; END IF;
    EXECUTE overlay(definition placing E'BEGIN\n    IF EXISTS(SELECT 1 FROM stock_value_nodes ref_row JOIN stock_value_events reverse_row ON reverse_row.id=ref_row.creation_event_id JOIN stock_value_events original_row ON original_row.id=reverse_row.position_store_reversal_of WHERE ref_row.id=p_node AND ref_row.kind=''VALUE_REFERENCE'' AND reverse_row.operation=''POSITION_STORE_REVERSE'' AND original_row.operation=''RETURN_ISSUE'') THEN\n        PERFORM fn_assert_stock_transfer_value_reference(p_node);\n        RETURN;\n    END IF;' from begin_at for 5);
END;
$$;

-- Insert one narrow dispatch at the current function entry. Preserve V847,
-- V848 and V849's existing source-specific guards byte for byte underneath it.
DO $$
DECLARE definition TEXT;begin_at INTEGER;
BEGIN
    SELECT pg_get_functiondef('fn_check_stock_value_reverse_store()'::regprocedure) INTO definition;
    begin_at:=position('BEGIN' IN definition);
    IF begin_at=0 THEN RAISE EXCEPTION 'transfer reversal proof lacks current function entry'; END IF;
    EXECUTE overlay(definition placing E'BEGIN\n    IF NEW.operation=''POSITION_STORE_REVERSE'' AND EXISTS(SELECT 1 FROM stock_value_events WHERE id=NEW.position_store_reversal_of AND operation=''RETURN_ISSUE'') THEN\n        PERFORM fn_assert_unused_stock_transfer_in_reversal(NEW.id);\n        RETURN NULL;\n    END IF;' from begin_at for 5);
END;
$$;
