package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.util.UUID;

/** One compatibility predicate for review and actual append, with locks only on the write path. */
@Component
@RequiredArgsConstructor
public class AggregateMaterialBatchLookup {
    private final EntityManager em;
    public record BatchMatch(UUID batchId,UUID actionId,UUID anchorId,UUID planId,String route,long version,
                             BigDecimal priorOutputQty) { }

    public BatchMatch find(UUID analysisId,AggregateMaterialOrderContracts.GroupPreview group,
            boolean manufacturing,boolean approveNow,boolean lock) {
        return find(analysisId,group.compatibilityKey(),group.route(),group.allowedOverproductionRate(),group.safetyQty(),manufacturing,approveNow,lock);
    }

    public BatchMatch find(UUID analysisId,String key,String route,BigDecimal rate,BigDecimal safety,
            boolean manufacturing,boolean approveNow,boolean lock) {
        String eligible=manufacturing?"batch.plan_id IS NOT NULL AND fn_material_analysis_plan_growable(batch.plan_id) AND fn_plan_accepts_overproduction_allowance(batch.plan_id,:rate)"+(approveNow?"":" AND plan.status=0")
                :"fn_preplan_supply_action_growable(action.id) AND action.safety_replenishment_qty=0 AND :safety=0";
        var query=em.createNativeQuery("""
                SELECT batch.id,batch.action_id,batch.anchor_analysis_item_id,batch.plan_id,batch.row_version,
                       action.requested_qty+action.public_surplus_qty
                FROM preplan_aggregate_batches batch JOIN preplan_supply_actions action ON action.id=batch.action_id
                LEFT JOIN production_plans plan ON plan.id=batch.plan_id
                WHERE batch.analysis_id=:analysis AND batch.compatibility_key=:key AND action.status<>'CANCELLED' AND
                """+eligible+" ORDER BY batch.created_at DESC,batch.id DESC LIMIT 1"+(lock?" FOR UPDATE OF batch,action":""))
                .setParameter("analysis",analysisId).setParameter("key",key);
        if(manufacturing)query.setParameter("rate",rate);else query.setParameter("safety",safety);
        var rows=NativeQueryResults.objectArrayRows(query);if(rows.isEmpty())return null;Object[] row=rows.getFirst();
        return new BatchMatch((UUID)row[0],(UUID)row[1],(UUID)row[2],(UUID)row[3],route,((Number)row[4]).longValue(),new BigDecimal(row[5].toString()));
    }
}
