-- V525 treated every pending value job as a missing cost for every loss line.
-- Publish this loss's known projection only after its positive input closure
-- has settled, using InventoryValueLedger.sourceClosureWorkPending's contract.
-- Amount projections, original value nodes and quantity shares stay authoritative.
CREATE OR REPLACE VIEW v_subcontract_waste_actual_value AS
SELECT item.id waste_item_id,issue.order_item_id,item.qty actual_qty,
       LEAST(item.qty,COALESCE(item.standard_qty,0)) normal_qty,
       item.qty-LEAST(item.qty,COALESCE(item.standard_qty,0)) excess_qty,
       normal.result_node_id normal_value_node_id,excess.result_node_id excess_value_node_id,
       CASE WHEN LEAST(item.qty,COALESCE(item.standard_qty,0))=0 THEN 0 ELSE fn_inventory_value_book_projection(normal.result_node_id) END normal_value_local,
       CASE WHEN item.qty=LEAST(item.qty,COALESCE(item.standard_qty,0)) THEN 0 ELSE fn_inventory_value_book_projection(excess.result_node_id) END excess_value_local,
       (LEAST(item.qty,COALESCE(item.standard_qty,0))=0 OR fn_inventory_value_book_projection(normal.result_node_id) IS NOT NULL)
        AND (item.qty=LEAST(item.qty,COALESCE(item.standard_qty,0)) OR fn_inventory_value_book_projection(excess.result_node_id) IS NOT NULL)
        AND NOT work.pending complete,
       (LEAST(item.qty,COALESCE(item.standard_qty,0))=0 OR normal.result_node_id IS NOT NULL)
        AND (item.qty=LEAST(item.qty,COALESCE(item.standard_qty,0)) OR excess.result_node_id IS NOT NULL) classified
FROM subcontract_waste_items item JOIN subcontract_material_issue_items issue ON issue.id=item.material_issue_item_id
LEFT JOIN stock_value_events normal ON normal.source_doc_type='SUBCONTRACT_NORMAL_LOSS' AND normal.source_item_id=item.id
LEFT JOIN stock_value_events excess ON excess.source_doc_type='SUBCONTRACT_EXCESS_LOSS' AND excess.source_item_id=item.id
CROSS JOIN LATERAL (
    WITH RECURSIVE ancestors(id) AS (
        SELECT seed.node_id
        FROM (VALUES
            (normal.result_node_id,LEAST(item.qty,COALESCE(item.standard_qty,0))>0),
            (excess.result_node_id,item.qty>LEAST(item.qty,COALESCE(item.standard_qty,0)))
        ) seed(node_id,required)
        WHERE seed.required AND seed.node_id IS NOT NULL
        UNION
        SELECT edge.parent_node_id FROM stock_value_edges edge
        JOIN ancestors child ON child.id=edge.child_node_id
        WHERE edge.interval_to>edge.interval_from
    )
    SELECT EXISTS(SELECT 1 FROM stock_value_tasks task
        JOIN stock_value_edges edge ON edge.id=task.edge_id
        JOIN ancestors input ON input.id=edge.child_node_id WHERE task.status='PENDING')
     OR EXISTS(SELECT 1 FROM stock_value_jobs job
        JOIN ancestors input ON input.id=job.source_node_id WHERE job.status='PENDING')
     OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks task
        JOIN ancestors input ON input.id=task.output_source_node_id WHERE task.status='PENDING')
     OR EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty
        JOIN stock_value_production_cost_outputs output USING(execution_segment_id)
        JOIN ancestors input ON input.id=output.source_node_id
        WHERE dirty.observed_revision>dirty.cleared_revision AND output.withdrawn_movement_id IS NULL)
     OR EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output
        JOIN stock_value_production_cost_objects object USING(execution_segment_id)
        JOIN ancestors input ON input.id=output.source_node_id
        WHERE object.business_refresh_pending AND output.withdrawn_movement_id IS NULL) pending
) work;
