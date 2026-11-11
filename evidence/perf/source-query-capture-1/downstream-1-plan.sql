EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT DISTINCT material.id,action.id,action.route,action.status,action.external_document_type,
       action.external_document_id,action.external_document_no
FROM preplan_aggregate_batches batch JOIN preplan_supply_actions action ON action.id=batch.action_id
JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id AND event.event_type IN('CREATE','APPEND')
CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(event.intent_snapshot->'materialLineIds','[]'::jsonb)) scope(id)
JOIN production_material_analysis_materials material ON material.id=CAST(scope.id AS uuid) AND material.analysis_id=batch.analysis_id
WHERE batch.analysis_id='ed1c28cd-39f9-442d-8c17-5ff79caf2806'::uuid AND (action.public_surplus_qty>0 OR action.safety_replenishment_qty>0)
  AND NOT EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation
    WHERE allocation.action_id=action.id AND allocation.analysis_material_id=material.id)
;