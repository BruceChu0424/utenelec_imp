-- A partial issue, completely returned to the SAME pool through only its own return
-- events, restores the original parent identity. Equal quantities or values alone
-- are never sufficient; every edge, root, remainder and event is proved below.
CREATE FUNCTION fn_stock_value_completed_partial_issue_return_parent(p_current uuid)
RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE current_id uuid:=p_current;root_id uuid;parent_id uuid;steps integer:=0;returned_qty numeric:=0;
 returned stock_value_events%ROWTYPE;issued stock_value_events%ROWTYPE;
 root stock_value_nodes%ROWTYPE;current_pool stock_value_nodes%ROWTYPE;starting_pool stock_value_nodes%ROWTYPE;
 original_pool stock_value_nodes%ROWTYPE;remaining_pool stock_value_nodes%ROWTYPE;
BEGIN
 SELECT * INTO starting_pool FROM stock_value_nodes WHERE id=p_current AND kind='POOL';
 IF starting_pool.id IS NULL THEN RETURN NULL;END IF;
 SELECT * INTO returned FROM stock_value_events WHERE id=starting_pool.creation_event_id AND result_head_id=starting_pool.id;
 IF returned.operation='RETURN_ISSUE' THEN root_id:=returned.source_node_id;
 ELSIF returned.operation='POSITION_STORE' THEN
   SELECT min(source_root_id::text)::uuid INTO root_id FROM stock_value_position_transfers WHERE event_id=returned.id HAVING count(*)=1;
 ELSE RETURN NULL;END IF;
 SELECT * INTO root FROM stock_value_nodes WHERE id=root_id AND kind='ISSUE_POSITION' AND root_issue_id=id;
 SELECT * INTO issued FROM stock_value_events WHERE id=root.creation_event_id AND operation='ISSUE' AND result_node_id=root.id;
 IF issued.id IS NULL OR issued.qty_base<=0 OR issued.qty_base<>root.quantity_basis OR issued.qty_before<=root.quantity_basis
   OR starting_pool.pool_id<>issued.pool_id OR root.pool_id<>issued.pool_id
   OR NOT EXISTS(SELECT 1 FROM stock_value_nodes remainder WHERE remainder.id=root.return_head_id
      AND remainder.kind='ISSUE_POSITION' AND remainder.pool_id=root.pool_id AND remainder.root_issue_id=root.id
      AND remainder.active AND remainder.range_from=remainder.range_to AND remainder.range_to=root.quantity_basis)
 THEN RETURN NULL;END IF;

 -- The two actual ISSUE outputs must be complementary slices of exactly one
 -- original POOL. This is not the whole-pool 1/1 case handled by the old helper.
 SELECT parent.id INTO parent_id FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id AND parent.kind='POOL'
 WHERE edge.child_node_id=root.id AND edge.creation_event_id=issued.id AND parent.pool_id=issued.pool_id
   AND edge.interval_from=0 AND edge.interval_to=issued.qty_base AND edge.denominator=issued.qty_before
 GROUP BY parent.id HAVING count(*)=1;
 IF parent_id IS NULL OR(SELECT count(*) FROM stock_value_edges WHERE child_node_id=root.id)<>1 THEN RETURN NULL;END IF;
 SELECT * INTO original_pool FROM stock_value_nodes WHERE id=parent_id;
 SELECT * INTO remaining_pool FROM stock_value_nodes WHERE id=issued.result_head_id AND kind='POOL' AND pool_id=issued.pool_id;
 IF original_pool.quantity_basis<>issued.qty_before OR remaining_pool.id IS NULL
   OR remaining_pool.quantity_basis<>issued.qty_before-issued.qty_base
   OR (SELECT count(*) FROM stock_value_edges WHERE child_node_id=remaining_pool.id)<>1
   OR NOT EXISTS(SELECT 1 FROM stock_value_edges edge WHERE edge.parent_node_id=original_pool.id
      AND edge.child_node_id=remaining_pool.id AND edge.creation_event_id=issued.id
      AND edge.interval_from=issued.qty_base AND edge.interval_to=issued.qty_before AND edge.denominator=issued.qty_before)
 THEN RETURN NULL;END IF;

 WHILE current_id IS NOT NULL AND steps<1000 LOOP
   IF current_id=issued.result_head_id THEN
     IF returned_qty<>root.quantity_basis OR starting_pool.quantity_basis<>original_pool.quantity_basis
       OR starting_pool.basis_value_local<>original_pool.basis_value_local THEN RETURN NULL;END IF;
     -- A returned split has two paths to the same pending cost source. Its
     -- immediate pending-parent count can therefore be 2 while the original
     -- pool's count is 1. Prove the exact unresolved SOURCE UUID set instead of
     -- pretending those path counts are distinct obligations or confirmed zero.
     IF EXISTS(WITH RECURSIVE ancestry(side,id)AS(
        VALUES(0,starting_pool.id),(1,original_pool.id)
        UNION SELECT path.side,edge.parent_node_id FROM ancestry path JOIN stock_value_edges edge ON edge.child_node_id=path.id
       ),unresolved AS(SELECT DISTINCT path.side,node.id FROM ancestry path JOIN stock_value_nodes node ON node.id=path.id WHERE NOT node.source_final)
       SELECT 1 FROM(
        (SELECT id FROM unresolved WHERE side=0 EXCEPT SELECT id FROM unresolved WHERE side=1)
        UNION ALL(SELECT id FROM unresolved WHERE side=1 EXCEPT SELECT id FROM unresolved WHERE side=0)
       )difference)THEN RETURN NULL;END IF;
     RETURN original_pool.id;
   END IF;
   SELECT * INTO current_pool FROM stock_value_nodes WHERE id=current_id AND kind='POOL' AND pool_id=issued.pool_id;
   IF current_pool.id IS NULL THEN RETURN NULL;END IF;
   SELECT * INTO returned FROM stock_value_events WHERE id=current_pool.creation_event_id AND result_head_id=current_id AND pool_id=issued.pool_id;
   IF returned.id IS NULL OR returned.qty_base<=0 OR returned.qty_before+returned.qty_base<>current_pool.quantity_basis THEN RETURN NULL;END IF;
   IF returned.operation='RETURN_ISSUE' THEN
     IF returned.source_node_id IS DISTINCT FROM root.id THEN RETURN NULL;END IF;
   ELSIF returned.operation='POSITION_STORE' THEN
     IF (SELECT count(*) FROM stock_value_position_transfers WHERE event_id=returned.id)<>1
       OR NOT EXISTS(SELECT 1 FROM stock_value_position_transfers transfer WHERE transfer.event_id=returned.id
         AND transfer.source_root_id=root.id AND transfer.target_node_id=returned.result_node_id
         AND transfer.qty_base=returned.qty_base AND transfer.quantity_basis=root.quantity_basis) THEN RETURN NULL;END IF;
   ELSE RETURN NULL;END IF;
   IF (SELECT count(*) FROM stock_value_edges WHERE child_node_id=current_id)<>2
      OR NOT EXISTS(SELECT 1 FROM stock_value_edges edge WHERE edge.child_node_id=current_id AND edge.parent_node_id=returned.result_node_id
         AND edge.creation_event_id=returned.id AND edge.interval_from=0 AND edge.interval_to=1 AND edge.denominator=1)
      OR (SELECT count(*) FROM stock_value_edges WHERE child_node_id=returned.result_node_id)<>1
      OR NOT EXISTS(SELECT 1 FROM stock_value_edges edge JOIN stock_value_nodes held ON held.id=edge.parent_node_id
         WHERE edge.child_node_id=returned.result_node_id AND held.kind='ISSUE_POSITION' AND held.root_issue_id=root.id
         AND held.pool_id=root.pool_id AND held.quantity_basis=root.quantity_basis
         AND edge.creation_event_id=returned.id AND edge.interval_from>=held.range_from AND edge.interval_to<=held.range_to
         AND edge.interval_to-edge.interval_from=returned.qty_base AND edge.denominator=root.quantity_basis)
      THEN RETURN NULL;END IF;
   returned_qty:=returned_qty+returned.qty_base;IF returned_qty>root.quantity_basis THEN RETURN NULL;END IF;
   SELECT edge.parent_node_id INTO parent_id FROM stock_value_edges edge
     JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id AND parent.kind='POOL' AND parent.pool_id=issued.pool_id
     WHERE edge.child_node_id=current_id AND edge.creation_event_id=returned.id
       AND edge.interval_from=0 AND edge.interval_to=1 AND edge.denominator=1;
   current_id:=parent_id;steps:=steps+1;
 END LOOP;
 RETURN NULL;
END $$;

ALTER FUNCTION fn_stock_value_completed_issue_return_parent(uuid) RENAME TO fn_stock_value_completed_issue_return_parent_before_v1008;
CREATE FUNCTION fn_stock_value_completed_issue_return_parent(p_current uuid)
RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE original uuid;
BEGIN
 original:=fn_stock_value_completed_issue_return_parent_before_v1008(p_current);
 IF original IS NOT NULL THEN RETURN original;END IF;
 RETURN fn_stock_value_completed_partial_issue_return_parent(p_current);
END $$;
