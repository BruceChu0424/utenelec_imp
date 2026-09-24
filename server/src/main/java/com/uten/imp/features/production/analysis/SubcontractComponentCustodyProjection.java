package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;

import java.util.List;
import java.util.UUID;

/** Reads frozen component custody as source coverage; it never grants reusable stock. */
final class SubcontractComponentCustodyProjection {
    private SubcontractComponentCustodyProjection() {}

    /** Correlated to the original exact reservation, including already issued custody. */
    static final String TRANSFERRED_EVIDENCE = """
            EXISTS (
                SELECT 1 FROM subcontract_component_stock_handoffs custody
                JOIN stock_reservations outbound ON outbound.id=custody.target_reservation_id
                  AND NOT outbound.is_deleted AND outbound.qty>outbound.released_qty
                WHERE custody.source_reservation_id=reservation.id)
            """;

    /** A draft still owns physical stock at its actual warehouse, exclusively for this child UUID. */
    static List<Object[]> held(EntityManager em, UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT custody.id,child.id,child.analysis_item_id,child.node_key,
                       outbound.goods_id,outbound.color_id,child.unit_id,outbound.warehouse_id,
                       GREATEST(outbound.qty-outbound.consumed_qty-outbound.released_qty,0)
                FROM subcontract_component_stock_handoffs custody
                JOIN stock_reservations outbound ON outbound.id=custody.target_reservation_id
                  AND outbound.status=0 AND NOT outbound.is_deleted
                  AND outbound.qty>outbound.consumed_qty+outbound.released_qty
                JOIN production_material_analysis_materials child ON child.id=custody.child_material_id
                  AND child.analysis_id=:analysisId AND child.active
                WHERE fn_preplan_reservation_has_qualified_origin(custody.source_reservation_id)
                ORDER BY custody.created_at,custody.id
                """).setParameter("analysisId", analysisId));
    }

    /** Exact issued slices belong to their frozen parent; only truly public issue quantities are shared.
     * All allocation arithmetic stays in physical child units until the final parent-output conversion,
     * so division tails cannot turn an exact slice into phantom public supply for a sibling. */
    static List<Object[]> issuedByParent(EntityManager em, UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH relevant_orders AS MATERIALIZED (
                    SELECT DISTINCT source.order_item_id
                    FROM preplan_supply_actions action
                    JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
                    JOIN subcontract_order_item_sources source ON source.application_item_id=allocation.external_item_id
                        OR source.application_item_id=action.public_surplus_external_item_id
                    WHERE action.analysis_id=:analysisId AND action.route='SUBCONTRACT'
                      AND action.operation_type='SUPPLY' AND action.status<>'CANCELLED'
                      AND action.external_document_type='SUBCONTRACT_APPLICATION'
                ), quantity_basis AS (
                    SELECT item.id AS order_item_id,COALESCE(item.unit_rate,1) AS order_unit_rate,
                           MIN(plan_item.bom_unit_qty) AS bom_unit_qty
                    FROM relevant_orders relevant
                    JOIN subcontract_order_items item ON item.id=relevant.order_item_id
                    JOIN subcontract_material_plan_items plan_item ON plan_item.order_item_id=item.id
                      AND plan_item.flow_mode='COMPONENT_OUTBOUND' AND NOT plan_item.is_deleted AND plan_item.bom_unit_qty>0
                    GROUP BY item.id,item.unit_rate
                ), assigned AS (
                    SELECT item.id AS order_item_id,material.id AS parent_material_id,
                           material.analysis_id,material.analysis_item_id,material.node_key,
                           basis.order_unit_rate,basis.bom_unit_qty,
                           source.alloc_qty*basis.bom_unit_qty*allocation.allocated_qty
                           /NULLIF(SUM(allocation.allocated_qty) OVER (
                               PARTITION BY item.id,source.application_item_id),0) AS capacity
                    FROM relevant_orders relevant
                    JOIN subcontract_order_items item ON item.id=relevant.order_item_id AND NOT item.is_deleted AND item.qty>0
                    JOIN quantity_basis basis ON basis.order_item_id=item.id
                    JOIN subcontract_order_item_sources source ON source.order_item_id=item.id AND source.alloc_qty>0
                    JOIN preplan_supply_actions action ON action.route='SUBCONTRACT' AND action.operation_type='SUPPLY'
                      AND action.status<>'CANCELLED' AND action.external_document_type='SUBCONTRACT_APPLICATION'
                    JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
                      AND allocation.analysis_id=action.analysis_id AND allocation.allocated_qty>0
                      AND (allocation.external_item_id=source.application_item_id
                           OR action.public_surplus_external_item_id=source.application_item_id)
                    JOIN production_material_analysis_materials material ON material.id=allocation.analysis_material_id
                      AND material.analysis_id=allocation.analysis_id AND material.active
                ), owners AS (
                    SELECT order_item_id,parent_material_id,analysis_id,analysis_item_id,node_key,
                           order_unit_rate,bom_unit_qty,SUM(capacity) AS capacity
                    FROM assigned GROUP BY order_item_id,parent_material_id,analysis_id,analysis_item_id,node_key,order_unit_rate,bom_unit_qty
                ), issued AS (
                    SELECT item.id AS order_item_id,SUM(issue_item.qty*COALESCE(issue_item.unit_rate,1)) AS qty
                    FROM relevant_orders relevant
                    JOIN subcontract_order_items item ON item.id=relevant.order_item_id
                    JOIN subcontract_material_plan_items plan_item ON plan_item.order_item_id=item.id
                      AND plan_item.flow_mode='COMPONENT_OUTBOUND' AND NOT plan_item.is_deleted
                    JOIN subcontract_material_issue_items issue_item ON issue_item.plan_item_id=plan_item.id AND NOT issue_item.is_deleted
                      AND issue_item.frozen_unit_qty=plan_item.bom_unit_qty AND issue_item.frozen_unit_qty>0
                    JOIN subcontract_material_issues issue ON issue.id=issue_item.issue_id AND issue.status=1 AND NOT issue.is_deleted
                    GROUP BY item.id
                ), exact_issued AS (
                    SELECT item.id AS order_item_id,custody.parent_material_id,
                           SUM(outbound.consumed_qty) AS qty
                    FROM relevant_orders relevant
                    JOIN subcontract_order_items item ON item.id=relevant.order_item_id
                    JOIN subcontract_material_plan_items plan_item ON plan_item.order_item_id=item.id AND NOT plan_item.is_deleted
                    JOIN subcontract_component_stock_handoffs custody ON custody.plan_item_id=plan_item.id
                    JOIN stock_reservations outbound ON outbound.id=custody.target_reservation_id
                      AND NOT outbound.is_deleted AND outbound.consumed_qty>0
                    GROUP BY item.id,custody.parent_material_id
                ), balances AS (
                    SELECT owners.*,COALESCE(issued.qty,0) AS issued_qty,
                           COALESCE(exact_issued.qty,0) AS exact_qty,
                           GREATEST(owners.capacity-COALESCE(exact_issued.qty,0),0) AS open_qty
                    FROM owners LEFT JOIN issued USING(order_item_id)
                    LEFT JOIN exact_issued USING(order_item_id,parent_material_id)
                ), distributed AS (
                    SELECT balances.*,SUM(exact_qty) OVER(PARTITION BY order_item_id) AS exact_total,
                           SUM(open_qty) OVER(PARTITION BY order_item_id) AS open_total
                    FROM balances
                ), weighted AS (
                    SELECT distributed.*,CASE WHEN open_total>0 THEN open_qty ELSE capacity END AS weight
                    FROM distributed
                ), ranked AS (
                    SELECT weighted.*,SUM(weight) OVER(PARTITION BY order_item_id) AS weight_total,
                           SUM(weight) OVER(PARTITION BY order_item_id ORDER BY parent_material_id
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS weight_running
                    FROM weighted
                )
                SELECT analysis_item_id,node_key,SUM((exact_qty+COALESCE(
                    ROUND(GREATEST(issued_qty-exact_total,0)*weight_running/NULLIF(weight_total,0),4)
                    -ROUND(GREATEST(issued_qty-exact_total,0)*(weight_running-weight)/NULLIF(weight_total,0),4),0))
                    /NULLIF(bom_unit_qty,0)*order_unit_rate)::numeric
                FROM ranked WHERE analysis_id=:analysisId
                GROUP BY analysis_item_id,node_key ORDER BY analysis_item_id,node_key
                """).setParameter("analysisId", analysisId));
    }
}
