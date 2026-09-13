package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import java.util.List;
import java.util.UUID;

/**
 * Reads each physical warehouse and safety-supply dimension once per snapshot.
 * The source-progress view remains authoritative. A missing safety-source UUID
 * implies no safety slice in that view; a zero declared quantity does not, so
 * historical sources with such a quantity remain included.
 */
final class MaterialAnalysisWarehouseBreakdownReader {
    private MaterialAnalysisWarehouseBreakdownReader() {}

    static final String SQL = """
            WITH dimensions AS MATERIALIZED (
                SELECT DISTINCT material.goods_id, material.color_id, material.unit_id
                FROM production_material_analysis_materials material
                WHERE material.analysis_id = :analysisId AND material.active = TRUE
                  AND material.goods_id IN (SELECT unnest(CAST(string_to_array(:goodsIds, ',') AS uuid[])))
            ), warehouse_facts AS MATERIALIZED (
                SELECT w.id, w.code, w.name,
                       (NOT w.is_defective AND NOT EXISTS (
                           SELECT 1 FROM warehouses child
                           WHERE child.parent_id=w.id AND child.is_deleted=FALSE)) AS public_allowed,
                       fn_warehouse_main_id(w.id) AS main_warehouse_id
                FROM warehouses w
                WHERE w.is_deleted=FALSE AND w.is_accountable=TRUE
            ), open_safety AS MATERIALIZED (
                SELECT action.warehouse_id, action.goods_id, action.color_id,
                       SUM(progress.safety_future_qty)::numeric AS open_qty
                FROM preplan_supply_actions action
                JOIN v_preplan_buy_action_slice_progress progress ON progress.action_id=action.id
                WHERE action.status <> 'CANCELLED'
                  AND action.safety_external_item_id IS NOT NULL
                  AND progress.safety_source_valid=TRUE
                  AND EXISTS (SELECT 1 FROM warehouse_facts warehouse WHERE warehouse.id=action.warehouse_id)
                  AND EXISTS (SELECT 1 FROM dimensions dimension
                      WHERE dimension.goods_id=action.goods_id
                        AND dimension.color_id IS NOT DISTINCT FROM action.color_id)
                GROUP BY action.warehouse_id, action.goods_id, action.color_id
            )
            SELECT dimension.goods_id, dimension.color_id, dimension.unit_id,
                   w.id, w.code, w.name,
                   COALESCE(v.on_hand_qty,0), COALESCE(v.reserved_qty,0),
                   GREATEST(COALESCE(v.available_qty,0),0), COALESCE(own.own_qty,0),
                   GREATEST(COALESCE(g.min_qty,0),0), COALESCE(open_safety.open_qty,0),
                   w.public_allowed, w.main_warehouse_id
            FROM dimensions dimension
            CROSS JOIN warehouse_facts w
            JOIN goods g ON g.id=dimension.goods_id
            LEFT JOIN v_stock_available v
              ON v.warehouse_id=w.id AND v.goods_id=dimension.goods_id
             AND v.color_id IS NOT DISTINCT FROM dimension.color_id
            LEFT JOIN LATERAL (
                SELECT SUM(CASE
                    WHEN EXISTS (SELECT 1 FROM preplan_stock_entitlement_events tracked
                        WHERE tracked.stock_reservation_id=r.id)
                    THEN COALESCE((
                        SELECT SUM(balance.effective_qty)
                        FROM v_preplan_stock_entitlement_beneficiary_balance balance
                        JOIN production_material_analysis_materials beneficiary
                          ON beneficiary.id=balance.beneficiary_analysis_material_id
                         AND beneficiary.analysis_id=balance.beneficiary_analysis_id
                        WHERE balance.stock_reservation_id=r.id
                          AND balance.beneficiary_analysis_id=:analysisId
                          AND beneficiary.active=TRUE
                    ),0)
                    WHEN r.owner_id=:analysisId THEN r.qty-r.consumed_qty-r.released_qty
                    ELSE 0 END) AS own_qty
                FROM stock_reservations r
                WHERE r.is_deleted=FALSE AND r.status=0 AND r.owner_type='PREPLAN_ANALYSIS'
                  AND r.warehouse_id=w.id AND r.goods_id=dimension.goods_id
                  AND r.color_id IS NOT DISTINCT FROM dimension.color_id
            ) own ON TRUE
            LEFT JOIN open_safety
              ON open_safety.warehouse_id=w.id AND open_safety.goods_id=dimension.goods_id
             AND open_safety.color_id IS NOT DISTINCT FROM dimension.color_id
            ORDER BY w.code, w.id
            """;

    static List<Object[]> read(EntityManager em, UUID analysisId, String goodsIds) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery(SQL)
                .setParameter("analysisId", analysisId).setParameter("goodsIds", goodsIds));
    }
}
