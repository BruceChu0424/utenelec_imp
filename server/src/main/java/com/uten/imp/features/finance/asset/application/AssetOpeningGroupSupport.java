package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.*;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchRequests;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** Shared group verification at every asset workflow boundary; no GL writes. */
final class AssetOpeningGroupSupport {
    private AssetOpeningGroupSupport() { }
    static boolean hasGroup(EntityManager em,String type,UUID id){return ((Number)em.createNativeQuery("SELECT count(*) FROM finance_asset_opening_members WHERE object_type=:type AND object_id=:id AND active").setParameter("type",type).setParameter("id",id).getSingleResult()).longValue()!=0;}
    static void lock(EntityManager em,String type,UUID id) {
        em.createNativeQuery("SELECT g.id FROM finance_asset_opening_groups g JOIN finance_asset_opening_members m ON m.group_id=g.id WHERE m.object_type=:type AND m.object_id=:id AND m.active FOR SHARE OF g")
                .setParameter("type",type).setParameter("id",id).getResultList();
    }
    static AssetWorkbenchRequests.OpeningBalance deferred(EntityManager em,UUID id) {
        Object[] r=(Object[])em.createNativeQuery("SELECT opening_as_of,opening_amortized_amount,opening_remaining_months FROM deferred_expenses WHERE id=:id")
                .setParameter("id",id).getSingleResult();
        return r[0]==null?null:new AssetWorkbenchRequests.OpeningBalance(NativeValueConverters.toLocalDate(r[0]),(BigDecimal)r[1],((Number)r[2]).intValue(),null);
    }
    static UUID voucher(EntityManager em,String type,UUID id) {
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery("SELECT g.source_voucher_id,g.status,fn_finance_asset_opening_group_valid(g.id) FROM finance_asset_opening_groups g JOIN finance_asset_opening_members m ON m.group_id=g.id WHERE m.object_type=:type AND m.object_id=:id AND m.active")
                .setParameter("type",type).setParameter("id",id).getResultList();
        if(rows.isEmpty())return null;
        var row=rows.getFirst();if(!"APPROVED".equals(row[1])||!Boolean.TRUE.equals(row[2]))throw new ApiException(ErrorCode.CONFLICT,"本组接续尚未由另一人核对，或成员/原GL已变化，请核对本组来源");
        return NativeValueConverters.uuid(row[0]);
    }
    static void requireNoSingleReversal(EntityManager em,String type,UUID id) {
        Number count=(Number)em.createNativeQuery("SELECT count(*) FROM finance_asset_opening_members WHERE object_type=:type AND object_id=:id AND active")
                .setParameter("type",type).setParameter("id",id).getSingleResult();
        if(count.longValue()!=0)throw new ApiException(ErrorCode.CONFLICT,"此记录由整组期初接续认领，不能冲销整张原GL凭证；请先倒序红冲平台计提，再由另一人复核撤销本组接续");
    }
}
