package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.UUID;

/** Complete exact alias ownership after priority replenishment, before readiness. */
@Service
@Order(50)
@RequiredArgsConstructor
public class PreplanAggregateEntitlementHook implements PreplanOriginEntitlementHook {
    private final EntityManager em;
    private final PreplanStockEntitlementService entitlement;

    @Override
    @Transactional(propagation=Propagation.MANDATORY)
    public void applyPriorityForOriginEvent(UUID originEventId) {
        for(int depth=0;depth<32;depth++) {
            var actions=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT DISTINCT batch.analysis_id,batch.action_id,batch.created_at
                    FROM preplan_stock_entitlement_events origin
                    JOIN v_preplan_stock_entitlement_beneficiary_balance balance ON balance.stock_reservation_id=origin.stock_reservation_id
                    JOIN preplan_aggregate_material_aliases alias ON alias.source_material_id=balance.beneficiary_analysis_material_id
                    JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id AND batch.analysis_id=balance.beneficiary_analysis_id
                    JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                    WHERE origin.id=:origin AND balance.effective_qty>0
                      AND fn_preplan_aggregate_alias_qty(alias.id)>fn_preplan_aggregate_alias_delegated_qty(alias.id)
                    ORDER BY batch.created_at,batch.action_id,batch.analysis_id
                    """).setParameter("origin",originEventId));
            BigDecimal moved=BigDecimal.ZERO;
            for(Object[] action:actions)moved=moved.add(entitlement.delegateAggregateMakeEntitlements((UUID)action[0],(UUID)action[1],originEventId));
            if(moved.signum()==0)return;
        }
        throw new IllegalStateException("Aggregate material alias depth exceeded the bounded ownership graph");
    }
}
