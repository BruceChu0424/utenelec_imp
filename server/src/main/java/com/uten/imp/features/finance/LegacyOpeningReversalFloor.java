package com.uten.imp.features.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.arap.ArApLedger;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** New settlements may reverse down to the immutable opening totals, never below them. */
public record LegacyOpeningReversalFloor(BigDecimal receivedOriginal,BigDecimal receivedLocal,BigDecimal settledLocal) {
    public static final LegacyOpeningReversalFloor ZERO=new LegacyOpeningReversalFloor(BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO);

    public static Map<UUID,LegacyOpeningReversalFloor> load(EntityManager em,Collection<ArApLedger> ledgers,String direction) {
        List<UUID> ids=ledgers.stream().filter(ledger->ledger.getLegacyId()!=null||ledger.getLegacySource()!=null
                ||ledger.getLegacySourceResolution()!=null).map(ArApLedger::getId).distinct().toList();
        if(ids.isEmpty())return Map.of();
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT ledger.id,public.fn_is_verified_legacy_opening_target(ledger.id,:direction),
                       (proof.initial_state->>'amount_received_original')::numeric,
                       (proof.initial_state->>'amount_received_local')::numeric,
                       (proof.initial_state->>'amount_settled')::numeric
                FROM ar_ap_ledger ledger LEFT JOIN legacy_finance_import_sources proof
                  ON proof.run_id=ledger.legacy_import_run_id AND proof.target_id=ledger.id
                 AND proof.target_table='ar_ap_ledger'
                WHERE ledger.id IN(:ids)
                """).setParameter("ids",ids).setParameter("direction",direction).getResultList();
        if(rows.size()!=ids.size())throw unavailable();
        Map<UUID,LegacyOpeningReversalFloor> result=new HashMap<>();
        for(Object[] row:rows) {
            if(!Boolean.TRUE.equals(row[1])||row[2]==null||row[3]==null||row[4]==null)throw unavailable();
            result.put((UUID)row[0],new LegacyOpeningReversalFloor((BigDecimal)row[2],(BigDecimal)row[3],(BigDecimal)row[4]));
        }
        return Map.copyOf(result);
    }
    private static ApiException unavailable(){return new ApiException(ErrorCode.CONFLICT,"历史累计缺少可核验的原币、本币或来源证明，禁止猜测红冲下限");}
}
