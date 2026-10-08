package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;

import java.util.List;
import java.util.UUID;

/** Read-local alias quantities: scalar lifecycle authorities stay in PostgreSQL, each source budget is read once. */
final class AggregateAliasCoverageReader {
    private final EntityManager em;
    AggregateAliasCoverageReader(EntityManager em) { this.em=em; }

    static final String SQL="""
            WITH aliases AS MATERIALIZED (
                SELECT alias.id,alias.source_material_id,alias.aggregate_material_id,alias.created_at,
                    fn_preplan_aggregate_alias_qty(alias.id) AS quota,
                    fn_preplan_aggregate_alias_delegated_qty(alias.id) AS received
                FROM preplan_aggregate_material_aliases alias
                JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id
                WHERE batch.analysis_id=:analysisId AND fn_preplan_aggregate_alias_valid(alias.id)
            ), source_ids AS MATERIALIZED (
                SELECT DISTINCT source_material_id FROM aliases
            ), source_budgets AS MATERIALIZED (
                SELECT source_material_id,fn_preplan_aggregate_source_future_available_qty(source_material_id) AS available
                FROM source_ids
            ), positions AS (
                SELECT alias.*,COALESCE(SUM(GREATEST(quota-received,0)) OVER (
                    PARTITION BY source_material_id ORDER BY created_at,id
                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS preceding_capacity
                FROM aliases alias
            ), pending AS MATERIALIZED (
                SELECT alias.aggregate_material_id,alias.source_material_id,alias.quota,alias.received,
                    LEAST(GREATEST(alias.quota-alias.received,0),GREATEST(source.available-alias.preceding_capacity,0)) AS pending_qty
                FROM positions alias JOIN source_budgets source ON source.source_material_id=alias.source_material_id
            )
            SELECT 'IN',aggregate_material_id,NULL::uuid,SUM(pending_qty) FROM pending
                GROUP BY aggregate_material_id HAVING SUM(pending_qty)>0
            UNION ALL
            SELECT 'OUT',source_material_id,NULL::uuid,SUM(pending_qty) FROM pending GROUP BY source_material_id
            UNION ALL
            SELECT 'COVERED',aggregate_material_id,source_material_id,SUM(LEAST(quota,received+pending_qty))
                FROM pending GROUP BY aggregate_material_id,source_material_id
            """;

    List<Object[]> read(UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery(SQL).setParameter("analysisId",analysisId));
    }
}
