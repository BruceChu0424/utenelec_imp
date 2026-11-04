package com.uten.imp.common.finance;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;

/** Exact rational quantities throughout a BOM path. Projection happens only at the output boundary. */
public record CostFraction(BigInteger numerator,BigInteger denominator) {
    public CostFraction {
        if(denominator.signum()==0)throw new ArithmeticException("Zero denominator");
        if(denominator.signum()<0){numerator=numerator.negate();denominator=denominator.negate();}
        BigInteger gcd=numerator.gcd(denominator);numerator=numerator.divide(gcd);denominator=denominator.divide(gcd);
    }
    public static CostFraction of(BigDecimal value) {
        BigDecimal normalized=value.stripTrailingZeros();int scale=normalized.scale();
        return scale<0?new CostFraction(normalized.unscaledValue().multiply(BigInteger.TEN.pow(-scale)),BigInteger.ONE)
                :new CostFraction(normalized.unscaledValue(),BigInteger.TEN.pow(scale));
    }
    public CostFraction multiply(BigDecimal value){return multiply(of(value));}
    public CostFraction add(CostFraction value){return new CostFraction(numerator.multiply(value.denominator).add(value.numerator.multiply(denominator)),denominator.multiply(value.denominator));}
    public CostFraction multiply(CostFraction value){return new CostFraction(numerator.multiply(value.numerator),denominator.multiply(value.denominator));}
    public CostFraction divide(BigDecimal value){return divide(of(value));}
    public CostFraction divide(CostFraction value){return new CostFraction(numerator.multiply(value.denominator),denominator.multiply(value.numerator));}
    public BigDecimal ceiling(){return new BigDecimal(numerator).divide(new BigDecimal(denominator),0,RoundingMode.CEILING);}
    /** V609/V247 执行存储边界：固定十二位向上取整，与 fn_material_snapshot_required 同一孪生口径；
     * 这是冻结公式的确定性边界，不是按请求的用户精度选择。 */
    public BigDecimal ceilingBoundary(int scale){return new BigDecimal(numerator.multiply(BigInteger.TEN.pow(scale)))
            .divide(new BigDecimal(denominator),0,RoundingMode.CEILING).movePointLeft(scale);}
    public int signum(){return numerator.signum();}
    public BigDecimal project(){return project("cost.fraction","本次成本或用量投影",30);}
    public BigDecimal project(String key,String label,int maximum){return BusinessPrecisionContext.divide(new BigDecimal(numerator),new BigDecimal(denominator),key,label,maximum);}
}
