package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** Exact original private shares of an aggregate order, excluding public/safety output. */
final class AggregatePrivateIntentReader {
    private final EntityManager em;
    AggregatePrivateIntentReader(EntityManager em) { this.em=em; }
    record Coverage(Map<UUID,Map<UUID,BigDecimal>> byTarget) { }
    record Share(UUID batch,UUID target,UUID original,BigDecimal qty,
                 BigDecimal allocatedQty,BigDecimal effectiveQty) { }
    private record Slice(UUID batch,UUID target) { }

    Coverage read(UUID analysisId) {
        List<Share> shares=new ArrayList<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH complete_batches AS (
                  SELECT batch.id,batch.action_id
                  FROM preplan_aggregate_batches batch JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
                  WHERE batch.analysis_id=:analysis AND event.event_type IN('CREATE','APPEND')
                  GROUP BY batch.id,batch.action_id
                  HAVING bool_and(jsonb_typeof(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId') IS NOT DISTINCT FROM 'object')
                ), recorded AS (
                  SELECT batch.id batch_id,batch.action_id,target.key::uuid target_id,origin.key::uuid original_id,
                         SUM(origin.value::numeric) qty
                  FROM complete_batches batch JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
                  CROSS JOIN LATERAL jsonb_each(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId') target
                  CROSS JOIN LATERAL jsonb_each_text(target.value) origin
                  WHERE event.event_type IN('CREATE','APPEND')
                  GROUP BY batch.id,batch.action_id,target.key,origin.key
                ), actual AS (
                  SELECT batch.id batch_id,allocation.analysis_material_id target_id,
                         SUM(allocation.allocated_qty) allocated_qty,
                         SUM(CASE WHEN action.status='CANCELLED' THEN 0 ELSE LEAST(allocation.allocated_qty,
                             fn_preplan_aggregate_allocation_pending_qty(allocation.id)
                             +fn_preplan_allocation_received_qty(allocation.id)) END) effective_qty
                  FROM complete_batches batch JOIN preplan_supply_action_allocations allocation ON allocation.action_id=batch.action_id
                  JOIN preplan_supply_actions action ON action.id=batch.action_id
                  GROUP BY batch.id,allocation.analysis_material_id
                )
                SELECT recorded.batch_id,recorded.target_id,recorded.original_id,recorded.qty,
                       COALESCE(actual.allocated_qty,0),COALESCE(actual.effective_qty,0)
                FROM recorded LEFT JOIN actual ON actual.batch_id=recorded.batch_id AND actual.target_id=recorded.target_id
                """).setParameter("analysis",analysisId))) {
            shares.add(new Share((UUID)row[0],(UUID)row[1],(UUID)row[2],(BigDecimal)row[3],(BigDecimal)row[4],(BigDecimal)row[5]));
        }
        return project(shares);
    }

    static Coverage project(List<Share> shares) {
        Map<Slice,List<Share>> slices=new LinkedHashMap<>();
        for(Share share:shares) {
            if(share.batch()==null||share.target()==null||share.original()==null||share.qty()==null
                    ||share.qty().signum()<0||share.allocatedQty()==null||share.effectiveQty()==null)throw invalid();
            slices.computeIfAbsent(new Slice(share.batch(),share.target()),ignored->new ArrayList<>()).add(share);
        }
        Map<UUID,Map<UUID,BigDecimal>> targets=new LinkedHashMap<>();
        for(var entry:slices.entrySet()) {
            Share first=entry.getValue().getFirst();Map<UUID,BigDecimal> weights=new LinkedHashMap<>();
            for(Share share:entry.getValue()) {
                if(share.allocatedQty().compareTo(first.allocatedQty())!=0||share.effectiveQty().compareTo(first.effectiveQty())!=0)throw invalid();
                weights.merge(share.original(),share.qty(),BigDecimal::add);
            }
            BigDecimal recorded=weights.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add);
            if(recorded.compareTo(first.allocatedQty())!=0||first.effectiveQty().signum()<0
                    ||first.effectiveQty().compareTo(recorded)>0)throw invalid();
            Map<UUID,BigDecimal> target=targets.computeIfAbsent(entry.getKey().target(),ignored->new LinkedHashMap<>());
            AggregateDelegationProjection.proportional(first.effectiveQty(),weights)
                    .forEach((id,qty)->target.merge(id,qty,BigDecimal::add));
        }
        Map<UUID,Map<UUID,BigDecimal>> result=new LinkedHashMap<>();
        targets.forEach((id,values)->result.put(id,Map.copyOf(values)));
        return new Coverage(Map.copyOf(result));
    }
    private static ApiException invalid() {
        return new ApiException(ErrorCode.CONFLICT,"合单原行私有份额与真实供给不一致，请核对来源后重试");
    }
}
