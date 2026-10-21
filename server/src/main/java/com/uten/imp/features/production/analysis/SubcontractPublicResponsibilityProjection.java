package com.uten.imp.features.production.analysis;

/**
 * Company-owned material responsibility for aggregate subcontract output with no private demand.
 * These immutable-intent shares are a read projection; they never create customer allocations.
 */
final class SubcontractPublicResponsibilityProjection {
    private SubcontractPublicResponsibilityProjection() { }

    /**
     * Lateral rows correlated to {@code action}. Each positive public CREATE/APPEND delta
     * keeps its own frozen source weights. Aliases of one physical parent are counted once.
     * Once an action has private demand, its existing allocation projection owns the whole
     * physical batch, including public output; these extra rows must then disappear.
     */
    static final String OWNERS_FOR_ACTION_SQL = """
            WITH event_sources AS (
                SELECT event.id AS event_id,event.public_delta,event.intent_snapshot,
                       source.value AS source,material.id AS material_id,
                       material.analysis_item_id,material.node_key,
                       COALESCE((source.value->>'sourceRequiredQty')::numeric,0) AS required_weight,
                       COALESCE((source.value->>'allocationPriority')::integer,0) AS priority,
                       (source.value->>'needDate')::date AS need_date
                FROM preplan_aggregate_batches batch
                JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
                  AND event.event_type IN ('CREATE','APPEND') AND event.public_delta>0
                CROSS JOIN LATERAL jsonb_array_elements(CASE
                    WHEN jsonb_typeof(event.intent_snapshot->'sources')='array'
                    THEN event.intent_snapshot->'sources' ELSE '[]'::jsonb END) source(value)
                JOIN production_material_analysis_materials material
                  ON material.id=CAST(source.value->>'materialLineId' AS uuid)
                 AND material.analysis_id=action.analysis_id AND material.active
                 AND material.goods_id=action.goods_id
                 AND material.color_id IS NOT DISTINCT FROM action.color_id
                 AND material.unit_id=action.unit_id
                WHERE batch.action_id=action.id AND batch.analysis_id=action.analysis_id
                  AND action.operation_type='SUPPLY' AND action.route='SUBCONTRACT'
                  AND action.requested_qty=0 AND action.public_surplus_qty>0
                  AND action.status<>'CANCELLED'
            ), origins AS (
                SELECT DISTINCT event_id,analysis_item_id,node_key,origin.id,
                       COALESCE((intent_snapshot->'sourceRequestedQtyByMaterialLineId'->>origin.id)::numeric,0) AS weight
                FROM event_sources
                CROSS JOIN LATERAL jsonb_array_elements_text(CASE
                    WHEN jsonb_typeof(source->'originalMaterialLineIds')='array'
                         AND jsonb_array_length(source->'originalMaterialLineIds')>0
                    THEN source->'originalMaterialLineIds'
                    ELSE jsonb_build_array(source->>'materialLineId') END) origin(id)
            ), explicit_weights AS (
                SELECT event_id,analysis_item_id,node_key,SUM(weight) AS weight
                FROM origins GROUP BY event_id,analysis_item_id,node_key
            ), nodes AS (
                SELECT source.event_id,source.public_delta,source.analysis_item_id,source.node_key,
                       MIN(source.material_id::text)::uuid AS analysis_material_id,
                       MIN(source.priority) AS priority,MIN(source.need_date) AS need_date,
                       GREATEST(MAX(source.required_weight),0) AS required_weight,
                       GREATEST(COALESCE(MAX(explicit.weight),0),0) AS explicit_weight
                FROM event_sources source
                LEFT JOIN explicit_weights explicit ON explicit.event_id=source.event_id
                  AND explicit.analysis_item_id=source.analysis_item_id AND explicit.node_key=source.node_key
                GROUP BY source.event_id,source.public_delta,source.analysis_item_id,source.node_key
            ), weighted AS (
                SELECT nodes.*,CASE
                    WHEN SUM(explicit_weight) OVER(PARTITION BY event_id)>0 THEN explicit_weight
                    WHEN SUM(required_weight) OVER(PARTITION BY event_id)>0 THEN required_weight
                    ELSE 1 END AS weight
                FROM nodes
            ), ranked AS (
                SELECT weighted.*,SUM(weight) OVER(PARTITION BY event_id) AS total_weight,
                       SUM(weight) OVER(PARTITION BY event_id ORDER BY priority,need_date NULLS LAST,
                           analysis_item_id,node_key ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_weight
                FROM weighted WHERE weight>0
            ), shares AS (
                SELECT analysis_material_id,analysis_item_id,node_key,priority,need_date,
                       ROUND(public_delta*running_weight/NULLIF(total_weight,0),4)
                         -ROUND(public_delta*(running_weight-weight)/NULLIF(total_weight,0),4) AS qty
                FROM ranked
            ), owners AS (
                SELECT analysis_material_id,analysis_item_id,node_key,
                       MIN(priority) AS priority,MIN(need_date) AS need_date,SUM(qty) AS qty
                FROM shares GROUP BY analysis_material_id,analysis_item_id,node_key HAVING SUM(qty)>0
            )
            SELECT action.id AS action_id,action.analysis_id,owners.analysis_material_id,
                   action.public_surplus_external_item_id AS external_item_id,owners.qty,
                   SUM(owners.qty) OVER(ORDER BY priority,need_date NULLS LAST,analysis_item_id,node_key
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS planned_through_qty,
                   COALESCE(SUM(owners.qty) OVER(ORDER BY priority,need_date NULLS LAST,analysis_item_id,node_key
                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS planned_before_qty
            FROM owners
            """;

    /** Cumulative rounding conserves the full remaining public obligation at four places. */
    static String remainingShareSql(String remainingSql) {
        return """
                (ROUND(GREATEST((%s),0)*responsibility.planned_through_qty
                       /NULLIF(action.public_surplus_qty,0),4)
                 -ROUND(GREATEST((%s),0)*responsibility.planned_before_qty
                       /NULLIF(action.public_surplus_qty,0),4))
                """.formatted(remainingSql,remainingSql);
    }
}
