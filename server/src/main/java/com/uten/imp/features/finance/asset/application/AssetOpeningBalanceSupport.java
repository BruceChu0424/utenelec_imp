package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchRequests;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.YearMonth;
import java.util.*;

/** Opening registration owns only future depreciation; existing vouchers are linked, never reposted. */
final class AssetOpeningBalanceSupport {
    private final EntityManager em;
    AssetOpeningBalanceSupport(EntityManager em){this.em=em;}
    AssetWorkbenchRequests.OpeningBalance read(UUID id) {
        Object[] row=(Object[])em.createNativeQuery("SELECT opening_as_of,opening_accumulated_amount,opening_remaining_months,opening_voucher_id FROM fixed_assets WHERE id=:id")
                .setParameter("id",id).getSingleResult();
        return row[0]==null?null:new AssetWorkbenchRequests.OpeningBalance(NativeValueConverters.toLocalDate(row[0]),
                (BigDecimal)row[1],((Number)row[2]).intValue(),NativeValueConverters.uuid(row[3]));
    }
    AssetWorkbenchRequests.OpeningBalance prepare(UUID id,AssetWorkbenchRequests.FixedAssetDraft draft,BigDecimal salvage) {
        var opening=draft.openingBalance();
        if(opening!=null&&Boolean.TRUE.equals(draft.clearOpeningBalance()))throw invalid("不能同时填写期初接续资料并要求清除");
        // Missing fields in an older client must not erase an existing opening balance.
        if(opening==null&&!Boolean.TRUE.equals(draft.clearOpeningBalance()))opening=read(id);
        if(opening!=null)validate(opening,draft.originalValue(),salvage,draft.readyForUseDate(),draft.startPeriod());
        if(opening!=null&&opening.existingVoucherId()!=null) {
            em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                    .setParameter("key","ASSET_OPENING_VOUCHER|"+opening.existingVoucherId()).getSingleResult();
            Number claimed=(Number)em.createNativeQuery("SELECT count(*) FROM fixed_assets WHERE opening_voucher_id=:voucher AND id<>:id AND lifecycle_status<>'REVERSED' AND NOT is_deleted")
                    .setParameter("voucher",opening.existingVoucherId()).setParameter("id",id).getSingleResult();
            if(claimed.longValue()!=0)throw new ApiException(ErrorCode.CONFLICT,"该期初凭证已关联另一张资产，不能重复接续");
        }
        return opening;
    }
    void save(UUID id,AssetWorkbenchRequests.FixedAssetDraft draft,BigDecimal salvage) {
        var opening=prepare(id,draft,salvage);
        em.createNativeQuery("""
                UPDATE fixed_assets SET opening_as_of=:date,opening_accumulated_amount=:amount,
                    opening_remaining_months=:months,opening_voucher_id=:voucher WHERE id=:id AND lifecycle_status='DRAFT'
                """).setParameter("date",opening==null?null:opening.asOf())
                .setParameter("amount",opening==null?BigDecimal.ZERO:opening.accumulatedAmount())
                .setParameter("months",opening==null?null:opening.remainingMonths())
                .setParameter("voucher",opening==null?null:opening.existingVoucherId()).setParameter("id",id).executeUpdate();
    }
    static void validate(AssetWorkbenchRequests.OpeningBalance opening,BigDecimal original,BigDecimal residual,
                         LocalDate ready,String start) {
        com.uten.imp.common.util.FinancialExactAmount.book(opening.accumulatedAmount(),"期初累计");
        if(opening.asOf()==null||opening.asOf().isAfter(BusinessTime.today())
                ||!opening.asOf().equals(YearMonth.from(opening.asOf()).atEndOfMonth()))
            throw invalid("旧资产接续日必须是已经结束的月末日期");
        if(ready==null||ready.isAfter(opening.asOf()))throw invalid("旧资产可使用日期不能晚于接续日");
        if(!YearMonth.from(opening.asOf()).plusMonths(1).toString().equals(start))
            throw invalid("旧资产从接续日的下一个月开始计提");
        BigDecimal maximum=original.subtract(com.uten.imp.common.util.FinancialExactAmount.book(original.multiply(residual),"残值金额"));
        if(opening.accumulatedAmount()==null||opening.accumulatedAmount().signum()<0||opening.accumulatedAmount().compareTo(maximum)>0)
            throw invalid("期初累计折旧不能超过原值扣除残值后的金额");
        BigDecimal remaining=maximum.subtract(opening.accumulatedAmount());
        if(opening.remainingMonths()==null||opening.remainingMonths()<0||opening.remainingMonths()>1200
                ||(remaining.signum()>0&&opening.remainingMonths()==0)
                ||(remaining.signum()==0&&opening.remainingMonths()!=0))
            throw invalid("请填写剩余计提月数；已提足折旧时填 0");
        if(remaining.signum()>0&&com.uten.imp.features.finance.asset.domain.StraightLineScheduleCalculator.regularAmount(remaining,opening.remainingMonths()).signum()==0)
            throw invalid("剩余月折旧在账面精度下为零，请核对累计折旧和剩余月数");
    }
    UUID verifyExisting(AssetWorkbenchRequests.OpeningBalance opening,BigDecimal original,UUID cost,UUID accumulated,UUID clearing) {
        UUID voucher=opening.existingVoucherId();if(voucher==null)return null;
        @SuppressWarnings("unchecked") List<Object[]> headers=em.createNativeQuery("""
                SELECT source,status,voucher_date FROM gl_vouchers WHERE id=:id AND is_deleted=false FOR UPDATE
                """).setParameter("id",voucher).getResultList();
        if(headers.size()!=1||!"MANUAL".equals(headers.getFirst()[0])||((Number)headers.getFirst()[1]).intValue()!=1
                ||NativeValueConverters.toLocalDate(headers.getFirst()[2]).isAfter(opening.asOf()))
            throw invalid("接续凭证必须是接续日之前已生效的手工期初凭证，不能引用可被重建的业务凭证");
        @SuppressWarnings("unchecked") List<Object[]> entries=em.createNativeQuery("""
                SELECT style_id,SUM(direction*amount) FROM gl_entries
                WHERE voucher_id=:id AND is_deleted=false GROUP BY style_id
                """).setParameter("id",voucher).getResultList();
        Map<UUID,BigDecimal> actual=new HashMap<>();for(Object[] row:entries)actual.put(NativeValueConverters.uuid(row[0]),(BigDecimal)row[1]);
        Map<UUID,BigDecimal> expected=Map.of(cost,original,accumulated,opening.accumulatedAmount().negate(),
                clearing,original.subtract(opening.accumulatedAmount()).negate());
        actual.entrySet().removeIf(e->e.getValue().signum()==0);
        if(actual.keySet().stream().anyMatch(k->!expected.containsKey(k))
                ||expected.entrySet().stream().anyMatch(e->actual.getOrDefault(e.getKey(),BigDecimal.ZERO).compareTo(e.getValue())!=0))
            throw invalid("接续凭证的原值、累计折旧及清理科目金额必须与本张资产一致，不能重复认领汇总凭证");
        return voucher;
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
