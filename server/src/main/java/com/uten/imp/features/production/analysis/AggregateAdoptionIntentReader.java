package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** Restores recorded original-row adoption shares from live, immutable claim identities. */
final class AggregateAdoptionIntentReader {
    private final EntityManager em;
    AggregateAdoptionIntentReader(EntityManager em) { this.em=em; }

    record Coverage(Map<UUID,BigDecimal> byOriginal,Map<UUID,BigDecimal> coveredByTarget) { }
    record Intent(UUID original,UUID target,String kind,UUID claim,BigDecimal qty,
                  BigDecimal originalClaimQty,BigDecimal liveClaimQty) { }
    private record Claim(String kind,UUID id) { }

    Coverage read(UUID analysisId) {
        List<Intent> intents=new ArrayList<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH intents AS (
                  SELECT (entry->>'originalMaterialLineId')::uuid original_id,
                         (entry->>'targetMaterialLineId')::uuid target_id,
                         entry->>'kind' kind,(entry->>'claimId')::uuid claim_id,
                         (entry->>'qty')::numeric qty
                  FROM production_material_analysis_commands command
                  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(command.result_payload->'sourceAdoptionIntent','[]'::jsonb)) entry
                  WHERE command.analysis_id=:analysis AND command.operation='AGGREGATE_ORDER'
                )
                SELECT intent.original_id,intent.target_id,intent.kind,intent.claim_id,intent.qty,
                       CASE WHEN intent.kind='MAKE_PUBLIC' THEN manufacture.qty
                            WHEN intent.kind='EXTERNAL_PUBLIC' AND action.id IS NOT NULL THEN allocation.allocated_qty END,
                       CASE WHEN intent.kind='MAKE_PUBLIC' THEN GREATEST(manufacture.qty-fn_preplan_make_public_claim_cancelled_qty(manufacture.id),0)
                            WHEN intent.kind='EXTERNAL_PUBLIC' AND action.status<>'CANCELLED'
                              THEN fn_preplan_allocation_admitted_qty(allocation.id)
                            WHEN intent.kind='EXTERNAL_PUBLIC' AND action.status='CANCELLED' THEN 0 END
                FROM intents intent
                LEFT JOIN preplan_make_public_claims manufacture ON intent.kind='MAKE_PUBLIC'
                  AND manufacture.id=intent.claim_id AND manufacture.target_analysis_id=:analysis
                  AND manufacture.target_material_id=intent.target_id
                LEFT JOIN preplan_supply_action_allocations allocation ON intent.kind='EXTERNAL_PUBLIC'
                  AND allocation.id=intent.claim_id AND allocation.analysis_material_id=intent.target_id
                LEFT JOIN preplan_supply_actions action ON action.id=allocation.action_id
                  AND action.analysis_id=:analysis AND action.operation_type='SHARED_FUTURE_CLAIM'
                """).setParameter("analysis",analysisId))) {
            intents.add(new Intent((UUID)row[0],(UUID)row[1],(String)row[2],(UUID)row[3],
                    (BigDecimal)row[4],(BigDecimal)row[5],(BigDecimal)row[6]));
        }
        return project(intents);
    }

    static Coverage project(List<Intent> intents) {
        Map<Claim,List<Intent>> claims=new LinkedHashMap<>();
        for(Intent intent:intents) {
            if(intent.original()==null||intent.target()==null||intent.claim()==null
                    ||!Set.of("MAKE_PUBLIC","EXTERNAL_PUBLIC").contains(Objects.toString(intent.kind(),""))
                    ||intent.qty()==null||intent.qty().signum()<=0
                    ||intent.originalClaimQty()==null||intent.liveClaimQty()==null)throw invalid();
            claims.computeIfAbsent(new Claim(intent.kind(),intent.claim()),ignored->new ArrayList<>()).add(intent);
        }
        Map<UUID,BigDecimal> originals=new HashMap<>(),targets=new HashMap<>();
        for(List<Intent> entries:claims.values()) {
            Intent first=entries.getFirst();Map<UUID,BigDecimal> weights=new LinkedHashMap<>();
            for(Intent entry:entries) {
                if(!entry.target().equals(first.target())
                        ||entry.originalClaimQty().compareTo(first.originalClaimQty())!=0
                        ||entry.liveClaimQty().compareTo(first.liveClaimQty())!=0)throw invalid();
                weights.merge(entry.original(),entry.qty(),BigDecimal::add);
            }
            BigDecimal total=weights.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add);
            if(total.compareTo(first.originalClaimQty())!=0||first.liveClaimQty().signum()<0
                    ||first.liveClaimQty().compareTo(total)>0)throw invalid();
            AggregateDelegationProjection.proportional(first.liveClaimQty(),weights)
                    .forEach((id,qty)->originals.merge(id,qty,BigDecimal::add));
            targets.merge(first.target(),first.liveClaimQty(),BigDecimal::add);
        }
        return new Coverage(Map.copyOf(originals),Map.copyOf(targets));
    }

    private static ApiException invalid() {
        return new ApiException(ErrorCode.CONFLICT,"原行采用记录与真实供给份额不一致，请核对来源后重试");
    }
}
