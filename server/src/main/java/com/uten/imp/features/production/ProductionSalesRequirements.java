package com.uten.imp.features.production;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Task-bound production instructions, read from their exact sales source, never by goods identity. */
public final class ProductionSalesRequirements {
    private final EntityManager em;

    public ProductionSalesRequirements(EntityManager em) { this.em = em; }

    public record Requirement(UUID salesOrderItemId, String salesOrderNo, String productName,
                              String orderRemark, String itemRemark) {}

    /** Caller must have authorized every analysis item before calling this batch projection. */
    public Map<UUID, List<Requirement>> analysisItems(Collection<UUID> ids) {
        return read(ids, """
                SELECT item.id AS context_id, item.id AS analysis_item_id, item.sales_order_item_id
                FROM production_material_analysis_items item
                WHERE item.id IN (:ids) AND NOT item.is_deleted
                """);
    }

    /** Caller must have authorized the containing plan, including retained-history access. */
    public Map<UUID, List<Requirement>> planItems(Collection<UUID> ids) {
        return read(ids, """
                SELECT item.id AS context_id,
                       CASE WHEN EXISTS(SELECT 1 FROM plan_order_item_links a WHERE a.plan_item_id=item.id AND NOT a.is_deleted)
                         THEN NULL::uuid ELSE plan.material_analysis_item_id END AS analysis_item_id,
                       CASE WHEN EXISTS(SELECT 1 FROM plan_order_item_links a WHERE a.plan_item_id=item.id AND NOT a.is_deleted)
                         THEN NULL::uuid ELSE item.sales_order_item_id END AS sales_order_item_id
                FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id
                WHERE item.id IN (:ids)
                UNION
                SELECT item.id, NULL::uuid, allocation.order_item_id
                FROM production_plan_items item JOIN plan_order_item_links allocation ON allocation.plan_item_id=item.id
                WHERE item.id IN (:ids) AND NOT allocation.is_deleted AND allocation.allocated_qty>0
                """);
    }

    /** The visible segment IDs have already passed workshop and document scope checks. */
    public Map<UUID, List<Requirement>> segments(Collection<UUID> ids) {
        return read(ids, """
                SELECT segment.id AS context_id,
                       CASE WHEN EXISTS(SELECT 1 FROM execution_segment_sales_allocations a WHERE a.execution_segment_id=segment.id)
                         THEN NULL::uuid ELSE plan.material_analysis_item_id END AS analysis_item_id,
                       CASE WHEN EXISTS(SELECT 1 FROM execution_segment_sales_allocations a WHERE a.execution_segment_id=segment.id)
                         THEN NULL::uuid ELSE item.sales_order_item_id END AS sales_order_item_id
                FROM production_execution_segments segment
                JOIN production_plans plan ON plan.id=segment.plan_id
                JOIN production_plan_items item ON item.id=segment.source_plan_item_id
                WHERE segment.id IN (:ids)
                UNION
                SELECT segment.id, NULL::uuid, allocation.order_item_id
                FROM production_execution_segments segment
                JOIN plan_order_item_links allocation ON allocation.plan_item_id=segment.source_plan_item_id
                WHERE segment.id IN (:ids) AND NOT allocation.is_deleted AND allocation.allocated_qty>0
                  AND NOT EXISTS(SELECT 1 FROM execution_segment_sales_allocations a WHERE a.execution_segment_id=segment.id)
                UNION
                SELECT allocation.execution_segment_id, NULL::uuid, allocation.sales_order_item_id
                FROM execution_segment_sales_allocations allocation
                WHERE allocation.execution_segment_id IN (:ids) AND allocation.allocated_qty>0
                """);
    }

    private Map<UUID, List<Requirement>> read(Collection<UUID> ids, String seeds) {
        if (ids.isEmpty()) return Map.of();
        var rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(sql(seeds)).setParameter("ids", ids));
        Map<UUID, List<Requirement>> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID context = (UUID) row[0];
            result.computeIfAbsent(context, ignored -> new java.util.ArrayList<>()).add(new Requirement(
                    (UUID) row[1], (String) row[2], (String) row[3], (String) row[4], (String) row[5]));
        }
        result.replaceAll((id, values) -> List.copyOf(values));
        return Map.copyOf(result);
    }

    static String sql(String seeds) {
        return "WITH RECURSIVE seeds AS (" + seeds + """
                ), analysis_scope AS (
                    SELECT DISTINCT item.analysis_id FROM seeds
                    JOIN production_material_analysis_items item ON item.id=seeds.analysis_item_id
                ), candidate_edges AS MATERIALIZED (
                    -- A cheap structural upper bound, never an authority for sales instructions.
                    -- Valid private proof is either canonical=self or has this historical alias.
                    SELECT child.id AS child_id,material.analysis_item_id AS parent_id
                    FROM production_material_analysis_items child
                    JOIN production_material_analysis_materials material ON material.id=child.parent_analysis_material_id AND material.analysis_id=child.analysis_id
                    WHERE child.analysis_id IN (SELECT analysis_id FROM analysis_scope)
                    UNION
                    SELECT batch.anchor_analysis_item_id,material.analysis_item_id
                    FROM preplan_aggregate_batches batch
                    JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                    JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id AND allocation.analysis_id=batch.analysis_id AND allocation.allocated_qty>0
                    JOIN production_material_analysis_materials material ON material.id=allocation.analysis_material_id AND material.analysis_id=batch.analysis_id
                    WHERE batch.analysis_id IN (SELECT analysis_id FROM analysis_scope) AND batch.anchor_analysis_item_id IS NOT NULL
                    UNION
                    SELECT batch.anchor_analysis_item_id,original.analysis_item_id
                    FROM preplan_aggregate_batches batch
                    JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                    JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id AND allocation.analysis_id=batch.analysis_id AND allocation.allocated_qty>0
                    JOIN preplan_aggregate_material_aliases alias ON alias.aggregate_material_id=allocation.analysis_material_id
                    JOIN production_material_analysis_materials original ON original.id=alias.source_material_id AND original.analysis_id=batch.analysis_id
                    WHERE batch.analysis_id IN (SELECT analysis_id FROM analysis_scope) AND batch.anchor_analysis_item_id IS NOT NULL
                ), candidate_items(id) AS (
                    SELECT DISTINCT analysis_item_id FROM seeds WHERE analysis_item_id IS NOT NULL
                    UNION
                    SELECT edge.parent_id FROM candidate_items reached JOIN candidate_edges edge ON edge.child_id=reached.id
                ), recorded_batches AS MATERIALIZED (
                    SELECT batch.id,batch.anchor_analysis_item_id,batch.analysis_id
                    FROM preplan_aggregate_batches batch
                    JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                    WHERE batch.analysis_id IN (SELECT analysis_id FROM analysis_scope)
                      AND batch.anchor_analysis_item_id IN (SELECT id FROM candidate_items)
                      AND EXISTS(SELECT 1 FROM preplan_aggregate_batch_events event
                        WHERE event.batch_id=batch.id AND event.event_type IN('CREATE','APPEND')
                          AND jsonb_typeof(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId')='object')
                ), recorded_sources AS MATERIALIZED (
                    -- Expand only reachable batches, once per analysis; keep JSON out of recursion.
                    SELECT batch.anchor_analysis_item_id,proof.original_analysis_item_id
                    FROM (SELECT analysis_id,array_agg(id) AS ids FROM recorded_batches GROUP BY analysis_id) scope
                    CROSS JOIN LATERAL fn_preplan_aggregate_recorded_private_sources_scoped_batches(scope.analysis_id,NULL::uuid,scope.ids) proof
                    JOIN recorded_batches batch ON batch.id=proof.supply_batch_id
                    WHERE proof.recorded_qty>0 AND proof.structural_valid
                ), edges AS MATERIALIZED (
                    -- Exact event evidence replaces broad ancestry; invalid evidence fails closed.
                    SELECT child.id AS child_id, parent.id AS parent_id
                    FROM production_material_analysis_items child
                    JOIN production_material_analysis_materials material ON material.id=child.parent_analysis_material_id
                      AND material.analysis_id=child.analysis_id
                    JOIN production_material_analysis_items parent ON parent.id=material.analysis_item_id
                      AND parent.analysis_id=child.analysis_id
                    WHERE child.id IN (SELECT id FROM candidate_items) AND child.analysis_id IN (SELECT analysis_id FROM analysis_scope)
                      AND NOT EXISTS(SELECT 1 FROM recorded_batches batch WHERE batch.anchor_analysis_item_id=child.id)
                    UNION
                    SELECT batch.anchor_analysis_item_id, material.analysis_item_id
                    FROM preplan_aggregate_batches batch
                    JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                    JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
                      AND allocation.analysis_id=batch.analysis_id AND allocation.allocated_qty>0
                    JOIN production_material_analysis_materials material ON material.id=allocation.analysis_material_id
                      AND material.analysis_id=batch.analysis_id
                    WHERE batch.anchor_analysis_item_id IN (SELECT id FROM candidate_items)
                      AND batch.analysis_id IN (SELECT analysis_id FROM analysis_scope)
                      AND NOT EXISTS(SELECT 1 FROM recorded_batches exact_batch WHERE exact_batch.id=batch.id)
                    UNION
                    SELECT anchor_analysis_item_id,original_analysis_item_id FROM recorded_sources
                ), lineage(context_id, analysis_item_id) AS (
                    SELECT context_id, analysis_item_id FROM seeds WHERE analysis_item_id IS NOT NULL
                    UNION
                    SELECT lineage.context_id, edges.parent_id FROM lineage
                    JOIN edges ON edges.child_id=lineage.analysis_item_id
                ), sources AS (
                    SELECT context_id, sales_order_item_id FROM seeds WHERE sales_order_item_id IS NOT NULL
                    UNION
                    SELECT lineage.context_id, item.sales_order_item_id
                    FROM lineage JOIN production_material_analysis_items item ON item.id=lineage.analysis_item_id
                    WHERE item.sales_order_item_id IS NOT NULL
                )
                SELECT DISTINCT sources.context_id, item.id, orders.bill_no, goods.name,
                       NULLIF(btrim(orders.remark),''), NULLIF(btrim(item.remark),'')
                FROM sources
                JOIN sales_order_items item ON item.id=sources.sales_order_item_id
                JOIN sales_orders orders ON orders.id=item.order_id
                LEFT JOIN goods ON goods.id=item.goods_id
                WHERE NULLIF(btrim(orders.remark),'') IS NOT NULL OR NULLIF(btrim(item.remark),'') IS NOT NULL
                ORDER BY sources.context_id, orders.bill_no, item.id
                """;
    }
}
