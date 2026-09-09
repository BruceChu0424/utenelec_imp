-- One real cost object may produce the same goods/color into several actual warehouses.
-- The initial product pool remains immutable; every output still proves its own physical identity.
CREATE FUNCTION fn_check_cost_output_product_identity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM stock_value_nodes node
        JOIN stock_value_pools actual ON actual.id=node.pool_id
        JOIN stock_value_production_cost_objects object ON object.execution_segment_id=NEW.execution_segment_id
        JOIN stock_value_pools product ON product.id=object.product_pool_id
        JOIN stock_movements movement ON movement.id=NEW.movement_id
        WHERE node.id=NEW.source_node_id AND node.kind IN('SOURCE','RETURN_SOURCE')
          AND node.owner_kind IS NULL AND node.owner_id IS NULL
          AND actual.goods_id=product.goods_id AND actual.color_id IS NOT DISTINCT FROM product.color_id
          AND movement.id=node.movement_id AND movement.goods_id=actual.goods_id
          AND movement.color_id IS NOT DISTINCT FROM actual.color_id AND movement.warehouse_id=actual.warehouse_id
          AND movement.direction=1 AND movement.qty=NEW.qty_base AND node.quantity_basis=NEW.qty_base
    ) THEN
        RAISE EXCEPTION 'cost output must preserve product, ownership and its actual physical pool' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_cost_output_product_identity AFTER INSERT ON stock_value_production_cost_outputs
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_cost_output_product_identity();
ALTER TABLE stock_value_production_cost_outputs ENABLE ALWAYS TRIGGER trg_cost_output_product_identity;

-- Return custody may use one or several POSITION_STORE / RETURN_ISSUE events.
-- Follow the actual pool ancestry and the SAME original issue UUID. Equal balances
-- from unrelated receipts, consumption or another warehouse are never proof.
CREATE FUNCTION fn_stock_value_completed_issue_return_parent(p_current UUID) RETURNS UUID LANGUAGE plpgsql STABLE AS $$
DECLARE current_id UUID:=p_current;root_id UUID;parent_id UUID;steps INTEGER:=0;returned_qty NUMERIC:=0;
    returned stock_value_events%ROWTYPE;issued stock_value_events%ROWTYPE;
    root stock_value_nodes%ROWTYPE;current_pool stock_value_nodes%ROWTYPE;
BEGIN
    SELECT event.* INTO returned FROM stock_value_nodes node
        JOIN stock_value_events event ON event.id=node.creation_event_id AND event.result_head_id=node.id
        WHERE node.id=current_id;
    IF returned.operation='RETURN_ISSUE' THEN root_id:=returned.source_node_id;
    ELSIF returned.operation='POSITION_STORE' THEN
        SELECT min(source_root_id::text)::uuid INTO root_id FROM stock_value_position_transfers
            WHERE event_id=returned.id HAVING count(*)=1;
    ELSE RETURN NULL;
    END IF;
    SELECT * INTO root FROM stock_value_nodes WHERE id=root_id AND kind='ISSUE_POSITION' AND root_issue_id=id;
    SELECT * INTO issued FROM stock_value_events WHERE id=root.creation_event_id AND operation='ISSUE';
    IF issued.id IS NULL OR issued.qty_base<>root.quantity_basis OR issued.qty_before<>root.quantity_basis
       OR NOT EXISTS(SELECT 1 FROM stock_value_nodes remainder WHERE remainder.id=root.return_head_id
           AND remainder.active AND remainder.range_from=remainder.range_to) THEN RETURN NULL; END IF;
    WHILE current_id IS NOT NULL AND steps<1000 LOOP
        IF current_id=issued.result_head_id THEN
            IF returned_qty<>root.quantity_basis THEN RETURN NULL; END IF;
            SELECT edge.parent_node_id INTO parent_id FROM stock_value_edges edge
                JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id AND parent.kind='POOL'
                WHERE edge.child_node_id=root.id AND edge.interval_from=0
                  AND edge.interval_to=root.quantity_basis AND edge.denominator=root.quantity_basis;
            RETURN parent_id;
        END IF;
        SELECT * INTO current_pool FROM stock_value_nodes WHERE id=current_id AND kind='POOL';
        SELECT * INTO returned FROM stock_value_events WHERE id=current_pool.creation_event_id
            AND result_head_id=current_id AND pool_id=issued.pool_id;
        IF returned.id IS NULL OR returned.qty_base<=0
           OR returned.qty_before+returned.qty_base<>current_pool.quantity_basis THEN RETURN NULL; END IF;
        IF returned.operation='RETURN_ISSUE' THEN
            IF returned.source_node_id IS DISTINCT FROM root.id THEN RETURN NULL; END IF;
        ELSIF returned.operation='POSITION_STORE' THEN
            IF NOT EXISTS(SELECT 1 FROM stock_value_position_transfers transfer
                WHERE transfer.event_id=returned.id AND transfer.source_root_id=root.id
                  AND transfer.target_node_id=returned.result_node_id
                  AND transfer.qty_base=returned.qty_base AND transfer.quantity_basis=root.quantity_basis)
               OR (SELECT count(*) FROM stock_value_position_transfers WHERE event_id=returned.id)<>1 THEN RETURN NULL; END IF;
        ELSE RETURN NULL;
        END IF;
        returned_qty:=returned_qty+returned.qty_base;
        IF returned_qty>root.quantity_basis THEN RETURN NULL; END IF;
        SELECT edge.parent_node_id INTO parent_id FROM stock_value_edges edge
            JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id AND parent.kind='POOL' AND parent.pool_id=issued.pool_id
            WHERE edge.child_node_id=current_id AND edge.creation_event_id=returned.id
              AND edge.interval_from=0 AND edge.interval_to=1 AND edge.denominator=1;
        current_id:=parent_id;steps:=steps+1;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_stock_value_unused_receipt_head(p_current UUID,p_original UUID) RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE current_id UUID:=p_current;parent_id UUID;steps INTEGER:=0;
BEGIN
    WHILE current_id IS NOT NULL AND steps<1000 LOOP
        IF current_id=p_original THEN RETURN TRUE; END IF;
        SELECT edge.parent_node_id INTO parent_id FROM stock_value_nodes child
            JOIN stock_value_events event ON event.id=child.creation_event_id AND event.operation='POSITION_STORE_REVERSE' AND event.result_head_id=child.id
            JOIN stock_value_edges edge ON edge.child_node_id=child.id AND edge.creation_event_id=event.id
                AND edge.interval_from=0 AND edge.interval_to=1 AND edge.denominator=1
            JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id AND parent.kind='POOL'
            WHERE child.id=current_id;
        IF parent_id IS NULL THEN parent_id:=fn_stock_value_completed_issue_return_parent(current_id); END IF;
        IF parent_id IS NULL THEN RETURN FALSE; END IF;
        current_id:=parent_id;steps:=steps+1;
    END LOOP;
    RETURN FALSE;
END;
$$;

-- A retired output keeps its original quantity/movement. Its new monetary interval is zero;
-- the old nonzero share is reversed by the same approved revision/task/share machinery.
-- Freeze retirement at revision creation: a subcontract reversal first creates its
-- zero-money material-return revision, then withdraws physical stock in the same
-- transaction. The later flag must not rewrite that already-approved snapshot.
CREATE FUNCTION fn_check_cost_revision_output_retirement() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(NEW.output_snapshot) frozen
        LEFT JOIN stock_value_production_cost_outputs output
          ON output.execution_segment_id=NEW.execution_segment_id AND output.source_node_id=(frozen->>'source')::uuid
        WHERE output.source_node_id IS NULL
          OR (frozen->>'withdrawnMovement')::uuid IS DISTINCT FROM output.withdrawn_movement_id
    ) THEN
        RAISE EXCEPTION 'cost revision must freeze the actual output withdrawal identity at creation' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_cost_revision_output_retirement BEFORE INSERT ON stock_value_production_cost_revisions
    FOR EACH ROW EXECUTE FUNCTION fn_check_cost_revision_output_retirement();
ALTER TABLE stock_value_production_cost_revisions ENABLE ALWAYS TRIGGER trg_cost_revision_output_retirement;

DO $task_interval$
DECLARE definition TEXT;needle TEXT:='AND x.qty_base=NEW.output_to-NEW.output_from';
BEGIN
    SELECT pg_get_functiondef('fn_check_stock_value_cost_task_plan()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V536 cost-task source definition changed'; END IF;
    EXECUTE replace(definition,needle,
        'AND (((o->>''withdrawnMovement'') IS NULL AND x.qty_base=NEW.output_to-NEW.output_from)'
        ||' OR ((o->>''withdrawnMovement'')::uuid=x.withdrawn_movement_id AND NEW.output_to=NEW.output_from))');
END;
$task_interval$;

CREATE FUNCTION fn_assert_unused_production_receipt_reversal(p_event UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE reversed stock_value_events%ROWTYPE;original stock_value_events%ROWTYPE;
    source stock_value_nodes%ROWTYPE;old_head stock_value_nodes%ROWTYPE;removed stock_value_nodes%ROWTYPE;
    archived stock_value_nodes%ROWTYPE;next_pool stock_value_nodes%ROWTYPE;previous_pool stock_value_nodes%ROWTYPE;
BEGIN
    SELECT * INTO reversed FROM stock_value_events WHERE id=p_event;
    SELECT * INTO original FROM stock_value_events WHERE id=reversed.position_store_reversal_of;
    SELECT * INTO source FROM stock_value_nodes WHERE id=original.result_node_id;
    SELECT * INTO old_head FROM stock_value_nodes WHERE id=original.result_head_id;
    SELECT * INTO archived FROM stock_value_nodes WHERE id=reversed.result_node_id;
    SELECT * INTO next_pool FROM stock_value_nodes WHERE id=reversed.result_head_id;
    SELECT node.* INTO removed FROM stock_value_edges edge JOIN stock_value_nodes node ON node.id=edge.parent_node_id
        WHERE edge.child_node_id=archived.id AND edge.creation_event_id=reversed.id AND node.kind='POOL';
    SELECT node.* INTO previous_pool FROM stock_value_edges edge JOIN stock_value_nodes node ON node.id=edge.parent_node_id
        WHERE edge.child_node_id=old_head.id AND node.kind='POOL';
    IF original.id IS NULL OR original.operation<>'RECEIVE' OR reversed.operation<>'POSITION_STORE_REVERSE'
       OR reversed.pool_id<>original.pool_id OR reversed.source_node_id<>source.id
       OR reversed.qty_base<>original.qty_base OR reversed.qty_before<>old_head.quantity_basis
       OR reversed.known_value_local<>0 OR source.kind<>'SOURCE' OR source.basis_value_local<>0
       OR archived.id IS NULL OR archived.kind<>'REVERSED_POOL_CURSOR' OR archived.creation_event_id<>reversed.id
       OR archived.pool_id IS DISTINCT FROM original.pool_id
       OR removed.id IS NULL OR removed.active OR removed.pool_id IS DISTINCT FROM original.pool_id
       OR NOT fn_stock_value_unused_receipt_head(removed.id,old_head.id)
       OR archived.initial_known_value<>removed.basis_value_local
       OR next_pool.id IS NULL OR next_pool.kind<>'POOL' OR next_pool.creation_event_id<>reversed.id
       OR next_pool.pool_id IS DISTINCT FROM original.pool_id
       OR (previous_pool.id IS NOT NULL AND previous_pool.pool_id IS DISTINCT FROM original.pool_id)
       OR (SELECT count(*) FROM stock_value_edges edge JOIN stock_value_nodes node ON node.id=edge.parent_node_id
           WHERE edge.child_node_id=old_head.id AND node.kind='POOL')>1
       OR next_pool.quantity_basis<>reversed.qty_before-reversed.qty_base
       OR next_pool.quantity_basis<>coalesce(previous_pool.quantity_basis,0)
       OR next_pool.initial_known_value<>coalesce(previous_pool.basis_value_local,0)
       OR removed.basis_value_local<>next_pool.initial_known_value
       OR EXISTS(SELECT 1 FROM stock_value_production_cost_shares WHERE output_source_node_id=source.id AND allocated_value_local<>0)
       OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE output_source_node_id=source.id AND status='PENDING')
       OR NOT EXISTS(
           SELECT 1 FROM stock_value_production_cost_outputs output
           JOIN stock_value_production_cost_objects object ON object.execution_segment_id=output.execution_segment_id
           JOIN stock_movements inbound ON inbound.id=output.movement_id
           JOIN stock_movements outbound ON outbound.id=output.withdrawn_movement_id
           JOIN stock_document_items item ON item.id=inbound.source_item_id
           JOIN stock_documents document ON document.id=item.doc_id
           WHERE output.source_node_id=source.id AND output.withdrawn_movement_id=reversed.movement_id
             AND object.source_kind='PRODUCTION_EXECUTION' AND item.execution_segment_id=object.execution_segment_id
             AND document.doc_type='FINISHED_IN' AND document.warehouse_id=inbound.warehouse_id
             AND inbound.source_doc_type='STOCK_DOC' AND outbound.source_doc_type='STOCK_DOC'
             AND inbound.source_doc_id=document.id AND outbound.source_doc_id=document.id
             AND outbound.source_item_id=item.id AND inbound.direction=1 AND outbound.direction=-1
             AND inbound.qty=outbound.qty AND outbound.qty=reversed.qty_base AND outbound.amount_local=0
             AND inbound.warehouse_id=outbound.warehouse_id AND inbound.goods_id=outbound.goods_id
             AND inbound.color_id IS NOT DISTINCT FROM outbound.color_id
       ) THEN
        RAISE EXCEPTION 'production withdrawal must retire its exact unused receipt after returning every cost share to WIP' USING ERRCODE='23514';
    END IF;
END;
$$;

DO $production_withdrawal$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_check_stock_value_reverse_store()'::regprocedure) INTO definition;
    IF position('BEGIN' IN definition)=0 THEN RAISE EXCEPTION 'V536 reverse-store source definition changed'; END IF;
    EXECUTE replace(definition,'BEGIN',E'BEGIN\n    IF NEW.operation=''POSITION_STORE_REVERSE'' AND EXISTS(SELECT 1 FROM stock_value_events WHERE id=NEW.position_store_reversal_of AND operation=''RECEIVE'') THEN\n        PERFORM fn_assert_unused_production_receipt_reversal(NEW.id); RETURN NULL;\n    END IF;');
    SELECT pg_get_functiondef('fn_check_withdrawn_cost_output()'::regprocedure) INTO definition;
    IF position('BEGIN' IN definition)=0 THEN RAISE EXCEPTION 'V536 withdrawn-output source definition changed'; END IF;
    EXECUTE replace(definition,'BEGIN',E'BEGIN\n    IF NEW.withdrawn_movement_id IS NOT NULL AND EXISTS(SELECT 1 FROM stock_value_events original WHERE original.movement_id=NEW.movement_id AND original.operation=''RECEIVE'') THEN\n        IF NOT EXISTS(SELECT 1 FROM stock_value_events reversed WHERE reversed.movement_id=NEW.withdrawn_movement_id AND reversed.operation=''POSITION_STORE_REVERSE'') THEN RAISE EXCEPTION ''withdrawn production output requires its exact physical reverse event'' USING ERRCODE=''23514''; END IF;\n        PERFORM fn_assert_unused_production_receipt_reversal((SELECT id FROM stock_value_events WHERE movement_id=NEW.withdrawn_movement_id)); RETURN NULL;\n    END IF;');
END;
$production_withdrawal$;
