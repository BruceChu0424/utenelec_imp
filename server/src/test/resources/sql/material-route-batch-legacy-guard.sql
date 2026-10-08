WITH input AS MATERIALIZED (SELECT * FROM %s),
supply_scope AS MATERIALIZED (SELECT * FROM %s), conflicts AS (
    SELECT input.material_id FROM supply_scope input JOIN preplan_supply_actions action
      ON action.analysis_id=:analysisId AND action.action_group_key=input.group_key
    WHERE action.status<>'CANCELLED' AND action.route IS DISTINCT FROM input.route
    UNION ALL
    SELECT input.material_id FROM supply_scope input JOIN preplan_supply_action_allocations allocation
      ON allocation.analysis_id=:analysisId AND allocation.analysis_material_id=input.material_id
    JOIN preplan_supply_actions action ON action.id=allocation.action_id AND action.analysis_id=:analysisId
    WHERE action.status<>'CANCELLED' AND action.route IS DISTINCT FROM input.route
    UNION ALL
    SELECT input.material_id FROM supply_scope input
    JOIN preplan_aggregate_batches batch ON batch.analysis_id=:analysisId
    JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
    JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
        AND event.event_type IN('CREATE','APPEND')
    WHERE action.route IS DISTINCT FROM input.route AND jsonb_exists(COALESCE(
        event.intent_snapshot->'originalMaterialLineIds',batch.configuration_snapshot->'originalMaterialLineIds',
        event.intent_snapshot->'materialLineIds','[]'::jsonb),input.material_id::text)
    UNION ALL
    SELECT input.material_id FROM supply_scope input
    JOIN production_material_analysis_materials material ON material.id=input.material_id
        AND material.analysis_id=:analysisId
    WHERE input.route<>'MAKE' AND EXISTS (
        SELECT 1 FROM production_material_analysis_items source
        JOIN production_material_analysis_plan_links link ON link.analysis_item_id=source.id
            AND link.analysis_id=:analysisId AND link.allocation_status IN('SUBMITTED','APPROVED')
        WHERE source.analysis_id=:analysisId AND NOT source.is_deleted
            AND (source.parent_analysis_material_id=material.id
                OR material.node_role='ROOT_SUPPLY' AND source.id=material.analysis_item_id)
            AND link.submitted_qty+link.public_surplus_qty>0)
)
SELECT (SELECT count(*) FROM input JOIN production_material_analysis_materials material
        ON material.id=input.material_id AND material.analysis_id=:analysisId AND material.active),
       EXISTS(SELECT 1 FROM conflicts)
