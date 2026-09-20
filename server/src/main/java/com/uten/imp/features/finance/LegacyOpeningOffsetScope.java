package com.uten.imp.features.finance;

import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.time.LocalDate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Batched eligibility for historical offset targets; historical balances are never new funds. */
public final class LegacyOpeningOffsetScope {
    private record Proof(boolean eligible, LocalDate cutoff) { }
    private final Map<UUID,Proof> history;
    private final LocalDate effectiveDate;

    private LegacyOpeningOffsetScope(Map<UUID,Proof> history,LocalDate effectiveDate) {
        this.history=Map.copyOf(history);this.effectiveDate=effectiveDate;
    }

    public static LegacyOpeningOffsetScope load(EntityManager em,List<UUID> ids,String direction,LocalDate effectiveDate) {
        if(!List.of("AR","AP").contains(direction))throw new IllegalArgumentException("Invalid offset direction");
        if(ids.isEmpty())return new LegacyOpeningOffsetScope(Map.of(),effectiveDate);
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT ledger.id,public.fn_is_verified_legacy_opening_target(ledger.id,:direction),
                       ((ledger.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz
                           AT TIME ZONE 'Asia/Shanghai')::date
                FROM ar_ap_ledger ledger
                WHERE ledger.id IN(:ids) AND (ledger.legacy_id IS NOT NULL
                    OR ledger.legacy_import_run_id IS NOT NULL OR ledger.legacy_source IS NOT NULL)
                """).setParameter("ids",ids).setParameter("direction",direction).getResultList();
        Map<UUID,Proof> history=new HashMap<>();
        for(Object[] row:rows)history.put((UUID)row[0],new Proof(Boolean.TRUE.equals(row[1]),NativeValueConverters.toLocalDate(row[2])));
        return new LegacyOpeningOffsetScope(history,effectiveDate);
    }

    public void requireNativeSource(UUID id) {
        if(history.containsKey(id))throw conflict("历史期初或旧资金记录不能作为新的预收、预付、贷项或索赔资金来源");
    }

    public boolean permitsTarget(UUID id,String actualKind,String nativeKind) {
        Proof proof=history.get(id);
        if(proof==null)return nativeKind.equals(actualKind);
        if(!proof.eligible()||proof.cutoff()==null)throw conflict("历史抵扣目标缺少已核验的正数原币、本币、币种或来源证明");
        if(effectiveDate==null||!effectiveDate.isAfter(proof.cutoff()))throw conflict("新的抵扣动作日期必须晚于历史快照截止日");
        return "LEGACY_UNVERIFIED".equals(actualKind);
    }

    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
