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
        Amounts original=original(semantics,charged,gift,unitRate);
        BigDecimal q=original.charged(),free=original.gift(),total=original.physical();
        BigDecimal rate=FinancialExactAmount.rate(unitRate,"单位换算率");
        BigDecimal physicalBase=MoneyPolicy.quantityToBase(total,rate);
        BigDecimal chargedBase=MoneyPolicy.quantityToBase(q,rate);
        BigDecimal giftBase=physicalBase.subtract(chargedBase);
        if(physicalBase.signum()<=0 || (q.signum()>0&&chargedBase.signum()<=0) || (free.signum()>0&&giftBase.signum()<=0))
            throw new BusinessPrecisionRequiredException("quantity.to-base","基本单位数量换算：所选精度丢失正数或计价/赠品份额，请明确重新选择",24,"PRECISION_LIMIT",true);
        return new Amounts(q,free,total,chargedBase,giftBase,physicalBase);
    }
    /** Input validation does not re-adopt a saved order under a later request's choice. */
    public static void validateOriginal(String semantics,BigDecimal charged,BigDecimal gift,BigDecimal unitRate){original(semantics,charged,gift,unitRate);}
    private static Amounts original(String semantics,BigDecimal charged,BigDecimal gift,BigDecimal unitRate){
        String mode=semantics(semantics);
        BigDecimal q=FinancialExactAmount.quantity(charged,"计价数量");
        BigDecimal free=isExtraGift(mode)?FinancialExactAmount.optionalNonNegativeQuantity(gift,"额外赠品数量"):BigDecimal.ZERO;
        if(q.signum()<0||!isExtraGift(mode)&&q.signum()==0)throw invalid("计价数量不合法");
        BigDecimal total=FinancialExactAmount.quantity(q.add(free),"实际实物数量");
        if(total.signum()<=0)throw invalid("计价量和赠品量不能同时为零");
        BigDecimal rate=FinancialExactAmount.rate(unitRate,"单位换算率");
        if(rate.signum()<=0)throw invalid("单位换算率必须大于零");
        return new Amounts(q,free,total,null,null,null);
    }
    /** Read a saved adoption without applying this request's unrelated choice to an old fact. */
    public static Amounts frozen(String semantics,BigDecimal charged,BigDecimal gift,BigDecimal unitRate,
                                 BigDecimal chargedBase,BigDecimal giftBase){
        Amounts original=original(semantics,charged,gift,unitRate);
        BigDecimal q=original.charged(),free=original.gift(),total=original.physical();
        BigDecimal rate=FinancialExactAmount.rate(unitRate,"原单位换算率");
        if(chargedBase==null&&giftBase==null){
            // Only unadopted legacy rows can lack these columns. Do not invent
            // a choice: a non-native result must be explicitly adopted first.
            chargedBase=FinancialExactAmount.quantity(q.multiply(rate),"原计价基本数量");
            giftBase=FinancialExactAmount.quantity(total.multiply(rate).subtract(chargedBase),"原赠品基本数量");
        }
        if(chargedBase==null||giftBase==null)throw invalid("原基本数量采用依据不完整");
        chargedBase=FinancialExactAmount.quantity(chargedBase,"原计价基本数量");
        giftBase=FinancialExactAmount.quantity(giftBase,"原赠品基本数量");
        BigDecimal physical=FinancialExactAmount.quantity(chargedBase.add(giftBase),"原实物基本数量");
        if(chargedBase.signum()<0||giftBase.signum()<0||physical.signum()<=0
            ||q.signum()>0&&chargedBase.signum()==0||free.signum()>0&&giftBase.signum()==0
            ||q.signum()==0&&chargedBase.signum()!=0||free.signum()==0&&giftBase.signum()!=0)
            throw invalid("原计价、赠品及实物基本数量不一致");
        return new Amounts(q,free,total,chargedBase,giftBase,physical);
    }
    public static String physicalText(String semantics,BigDecimal charged,BigDecimal gift){
        if(charged==null)return null;
        return (isExtraGift(semantics)?charged.add(gift==null?BigDecimal.ZERO:gift):charged).toPlainString();
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
