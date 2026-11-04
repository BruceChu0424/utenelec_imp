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
    public int signum(){return numerator.signum();}
    public BigDecimal project(int scale,RoundingMode mode) {
        return project();
    }
    /** Legacy arguments cannot silently authorize a new precision loss. */
    public BigDecimal scaled(int scale,RoundingMode mode){return project(scale,mode);}
    public BigDecimal project(){return project("cost.fraction","本次成本或用量投影",30);}
    public BigDecimal project(String key,String label,int maximum){return BusinessPrecisionContext.divide(new BigDecimal(numerator),new BigDecimal(denominator),key,label,maximum);}
}
