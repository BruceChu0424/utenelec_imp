-- Withdraw unused qualified purchase stock by its original custody intervals.
-- Historical events remain immutable; this adds neither a new acquisition nor a guessed average-price fee.
ALTER TABLE stock_value_events ADD COLUMN position_store_reversal_of UUID UNIQUE
    REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE stock_value_position_transfers ADD COLUMN reversal_of_transfer_id UUID UNIQUE
    REFERENCES stock_value_position_transfers(id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE stock_value_nodes DROP CONSTRAINT stock_value_node_kind_v524;
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_node_kind_v527 CHECK(kind IN(
    'SOURCE','POOL','ISSUE_POSITION','RETURN_SOURCE','COST_RETURN_CURSOR','REVERSED_POOL_CURSOR'));
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_reversed_pool_cursor_shape CHECK(kind<>'REVERSED_POOL_CURSOR'
    OR (active AND owner_kind IS NULL AND owner_id IS NULL AND movement_id IS NULL AND root_issue_id IS NULL AND distributed_value_local=0));
ALTER TABLE stock_value_events DROP CONSTRAINT stock_value_event_operation_v524_check;
ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_operation_v527_check CHECK(operation IN(
    'RECEIVE','ISSUE','RETURN_ISSUE','COST_ADJUST','COST_ADJUST_REVERSE','OPENING','EMPTY_OPENING',
    'POSITION_ACQUIRE','POSITION_MOVE','POSITION_STORE','COST_ALLOCATE','CONSUMPTION_RETURN','POSITION_STORE_REVERSE'));
ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_store_reversal_identity CHECK(
    (operation='POSITION_STORE_REVERSE')=(position_store_reversal_of IS NOT NULL));
DO $shape$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
        WHERE conrelid='stock_value_events'::regclass AND conname='stock_value_event_shape_v524_check';
    IF definition IS NULL THEN RAISE EXCEPTION 'inventory event shape guard changed before V527'; END IF;
    definition:=substring(definition FROM 8 FOR length(definition)-8);
    ALTER TABLE stock_value_events DROP CONSTRAINT stock_value_event_shape_v524_check;
    EXECUTE 'ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_shape_v527_check CHECK ('||definition
        ||' OR (operation=''POSITION_STORE_REVERSE'' AND movement_id IS NOT NULL AND qty_base>0 AND qty_before>=qty_base'
        ||' AND source_node_id IS NOT NULL AND result_head_id IS NOT NULL AND known_value_local>=0))';
END;
$shape$;

CREATE FUNCTION fn_stock_value_unused_receipt_head(p_current UUID,p_original UUID) RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
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
        IF parent_id IS NULL THEN RETURN FALSE; END IF;
        current_id:=parent_id;steps:=steps+1;
    END LOOP;
    RETURN FALSE;
END;
$$;

CREATE FUNCTION fn_check_stock_value_reverse_transfer() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE original stock_value_position_transfers%ROWTYPE;source stock_value_nodes%ROWTYPE;remaining stock_value_nodes%ROWTYPE;
    target stock_value_nodes%ROWTYPE;event stock_value_events%ROWTYPE;source_value NUMERIC;
BEGIN
    SELECT * INTO original FROM stock_value_position_transfers WHERE id=NEW.reversal_of_transfer_id;
    SELECT * INTO source FROM stock_value_nodes WHERE id=NEW.source_node_id;
    SELECT * INTO remaining FROM stock_value_nodes WHERE id=NEW.remaining_node_id;
    SELECT * INTO target FROM stock_value_nodes WHERE id=NEW.target_node_id;
    SELECT * INTO event FROM stock_value_events WHERE id=NEW.event_id;
    IF NEW.source_revision=1 THEN source_value:=source.initial_known_value;
    ELSE SELECT after_value INTO source_value FROM stock_value_node_revisions WHERE node_id=source.id AND revision=NEW.source_revision; END IF;
    IF original.id IS NULL OR original.reversal_of_transfer_id IS NOT NULL OR event.operation<>'POSITION_STORE_REVERSE'
        OR original.event_id IS DISTINCT FROM event.position_store_reversal_of
        OR NEW.source_slice_id<>original.source_slice_id OR NEW.source_root_id<>original.source_root_id
        OR NEW.qty_base<>original.qty_base OR NEW.range_from<>original.range_from OR NEW.range_to<>original.range_to
        OR NEW.quantity_basis<>original.quantity_basis OR source_value IS NULL
        OR source.kind<>'ISSUE_POSITION' OR source.root_issue_id<>NEW.source_root_id OR source.active
        OR source.owner_kind<>'QUALITY_PASSED' OR source.range_from<NEW.range_to OR source.quantity_basis<>NEW.quantity_basis
        OR remaining.kind<>'ISSUE_POSITION' OR remaining.root_issue_id<>source.root_issue_id
        OR remaining.range_from<>source.range_from OR remaining.range_to<>source.range_to OR remaining.quantity_basis<>source.quantity_basis
        OR remaining.owner_kind IS DISTINCT FROM source.owner_kind OR remaining.owner_id IS DISTINCT FROM source.owner_id
        OR target.kind<>'ISSUE_POSITION' OR target.root_issue_id<>target.id OR target.owner_kind IS DISTINCT FROM source.owner_kind
        OR target.owner_id IS DISTINCT FROM source.owner_id OR target.quantity_basis<>NEW.qty_base
        OR target.pool_id<>source.pool_id OR remaining.pool_id<>source.pool_id
        OR target.creation_event_id<>NEW.event_id OR remaining.creation_event_id<>NEW.event_id
        OR NEW.initial_value_local<>round(source_value*NEW.range_to/NEW.quantity_basis,4)-round(source_value*NEW.range_from/NEW.quantity_basis,4)
        OR target.initial_known_value<>NEW.initial_value_local
        OR NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE parent_node_id=source.id AND child_node_id=target.id
            AND creation_event_id=NEW.event_id AND initial_parent_revision=NEW.source_revision
            AND interval_from=NEW.range_from AND interval_to=NEW.range_to AND denominator=NEW.quantity_basis)
        OR NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE parent_node_id=source.id AND child_node_id=remaining.id
            AND creation_event_id=NEW.event_id AND interval_from=0 AND interval_to=1 AND denominator=1) THEN
        RAISE EXCEPTION 'purchase stock withdrawal must restore each original qualified custody interval' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_reverse_transfer AFTER INSERT ON stock_value_position_transfers
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(NEW.reversal_of_transfer_id IS NOT NULL)
    EXECUTE FUNCTION fn_check_stock_value_reverse_transfer();
ALTER TABLE stock_value_position_transfers ENABLE ALWAYS TRIGGER trg_stock_value_reverse_transfer;
DO $transfer_dispatch$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_check_stock_value_position_transfer()'::regprocedure) INTO definition;
    IF position('BEGIN' IN definition)=0 THEN RAISE EXCEPTION 'position transfer proof missing'; END IF;
    EXECUTE replace(definition,E'BEGIN\n',E'BEGIN\n    IF NEW.reversal_of_transfer_id IS NOT NULL THEN RETURN NULL; END IF;\n');
    SELECT pg_get_functiondef('fn_check_stock_value_event()'::regprocedure) INTO definition;
    IF position('NEW.operation=''ISSUE''' IN definition)=0 THEN RAISE EXCEPTION 'physical value direction proof changed'; END IF;
    EXECUTE replace(definition,'NEW.operation=''ISSUE''','NEW.operation IN(''ISSUE'',''POSITION_STORE_REVERSE'')');
END;
$transfer_dispatch$;

CREATE FUNCTION fn_check_stock_value_reverse_store() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE original stock_value_events%ROWTYPE;archived stock_value_nodes%ROWTYPE;removed stock_value_nodes%ROWTYPE;
    next_pool stock_value_nodes%ROWTYPE;original_head stock_value_nodes%ROWTYPE;previous_pool stock_value_nodes%ROWTYPE;
    qty NUMERIC;amount NUMERIC;parts BIGINT;
BEGIN
    IF NEW.operation<>'POSITION_STORE_REVERSE' THEN RETURN NULL; END IF;
    SELECT * INTO original FROM stock_value_events WHERE id=NEW.position_store_reversal_of;
    SELECT * INTO archived FROM stock_value_nodes WHERE id=NEW.result_node_id;
    SELECT * INTO next_pool FROM stock_value_nodes WHERE id=NEW.result_head_id;
    SELECT parent.* INTO removed FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
        WHERE edge.child_node_id=archived.id AND edge.creation_event_id=NEW.id;
    SELECT * INTO original_head FROM stock_value_nodes WHERE id=original.result_head_id;
    SELECT parent.* INTO previous_pool FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
        WHERE edge.child_node_id=original_head.id AND parent.kind='POOL';
    SELECT count(*),coalesce(sum(qty_base),0),coalesce(sum(initial_value_local),0) INTO parts,qty,amount
        FROM stock_value_position_transfers WHERE event_id=NEW.id AND reversal_of_transfer_id IS NOT NULL;
    IF original.id IS NULL OR archived.id IS NULL OR removed.id IS NULL OR next_pool.id IS NULL OR original_head.id IS NULL
        OR original.operation<>'POSITION_STORE' OR original.pool_id<>NEW.pool_id
        OR original.qty_base<>NEW.qty_base OR NEW.source_node_id<>original.result_node_id
        OR NOT fn_stock_value_unused_receipt_head(removed.id,original.result_head_id)
        OR archived.kind<>'REVERSED_POOL_CURSOR' OR archived.creation_event_id<>NEW.id OR archived.pool_id<>NEW.pool_id
        OR removed.kind<>'POOL' OR removed.active OR removed.quantity_basis<>NEW.qty_before
        OR next_pool.kind<>'POOL' OR next_pool.creation_event_id<>NEW.id OR next_pool.pool_id<>NEW.pool_id
        OR next_pool.quantity_basis<>NEW.qty_before-NEW.qty_base OR next_pool.quantity_basis<>coalesce(previous_pool.quantity_basis,0)
        OR next_pool.initial_known_value<>coalesce(previous_pool.basis_value_local,0)
        OR removed.basis_value_local<>next_pool.initial_known_value+NEW.known_value_local
        OR archived.initial_known_value<>removed.basis_value_local
        OR parts=0 OR parts>100 OR qty<>NEW.qty_base OR amount<>NEW.known_value_local
        OR parts<>(SELECT count(*) FROM stock_value_position_transfers WHERE event_id=original.id)
        OR EXISTS(SELECT 1 FROM stock_value_production_cost_outputs WHERE source_node_id=original.result_node_id)
        OR NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=NEW.id AND node_id=removed.id
            AND owner_kind='INVENTORY' AND amount_delta_local=-NEW.known_value_local)
        OR EXISTS(SELECT 1 FROM stock_value_position_transfers transfer WHERE transfer.event_id=NEW.id AND NOT EXISTS(
            SELECT 1 FROM stock_value_postings posting WHERE posting.event_id=NEW.id AND posting.node_id=transfer.target_node_id
                AND posting.owner_kind='QUALITY_PASSED' AND posting.amount_delta_local=transfer.initial_value_local)) THEN
        RAISE EXCEPTION 'unused purchase stock withdrawal must pair the original receipt, restored custody and physical balance' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_reverse_store AFTER INSERT ON stock_value_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_reverse_store();
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_stock_value_reverse_store;
