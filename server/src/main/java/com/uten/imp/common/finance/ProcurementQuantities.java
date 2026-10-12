package com.uten.imp.common.finance;

import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;

/** Charged and free quantities are distinct facts; only their physical sum moves inventory. */
public final class ProcurementQuantities {
    public static final String LEGACY="LEGACY_RECORDED";
    public static final String EXTRA_GIFT="CHARGED_PLUS_GIFT_V1";
    public static final String CHARGED="CHARGED";
    public static final String GIFT="GIFT";
    private ProcurementQuantities(){}

    public record Amounts(BigDecimal charged,BigDecimal gift,BigDecimal physical,
                          BigDecimal chargedBase,BigDecimal giftBase,BigDecimal physicalBase){}

    public static boolean isExtraGift(String semantics){return EXTRA_GIFT.equals(semantics);}
    public static String semantics(String value){
        if(value==null || LEGACY.equals(value))return LEGACY;
        if(EXTRA_GIFT.equals(value))return EXTRA_GIFT;
        throw invalid("数量语义未知，请核对来源单据");
    }
    public static Amounts of(String semantics,BigDecimal charged,BigDecimal gift,BigDecimal unitRate){
        String mode=semantics(semantics);
        BigDecimal q=FinancialExactAmount.quantity(charged,"计价数量");
        BigDecimal free=isExtraGift(mode)?FinancialExactAmount.optionalNonNegativeQuantity(gift,"额外赠品数量"):BigDecimal.ZERO;
        if(q.signum()<0 || (!isExtraGift(mode)&&q.signum()==0))throw invalid("计价数量不合法");
        BigDecimal total=FinancialExactAmount.quantity(q.add(free),"实际实物数量");
        if(total.signum()<=0)throw invalid("计价量和赠品量不能同时为零");
        BigDecimal rate=FinancialExactAmount.rate(unitRate==null?BigDecimal.ONE:unitRate,"单位换算率");
        if(rate.signum()<=0)throw invalid("单位换算率必须大于零");
        BigDecimal physicalBase=MoneyPolicy.quantity(total.multiply(rate));
        BigDecimal chargedBase=MoneyPolicy.quantity(q.multiply(rate));
        BigDecimal giftBase=physicalBase.subtract(chargedBase);
        if(physicalBase.signum()<=0 || (q.signum()>0&&chargedBase.signum()<=0) || (free.signum()>0&&giftBase.signum()<=0))
            throw invalid("基本单位数量小于可记录精度，请核对单位及实物数量");
        return new Amounts(q,free,total,chargedBase,giftBase,physicalBase);
    }
    public static String physicalText(String semantics,BigDecimal charged,BigDecimal gift){
        if(charged==null)return null;
        return (isExtraGift(semantics)?charged.add(gift==null?BigDecimal.ZERO:gift):charged).toPlainString();
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
