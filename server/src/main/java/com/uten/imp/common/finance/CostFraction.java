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
    public CostFraction multiply(CostFraction value){return new CostFraction(numerator.multiply(value.numerator),denominator.multiply(value.denominator));}
    public CostFraction divide(BigDecimal value){return divide(of(value));}
    public CostFraction divide(CostFraction value){return new CostFraction(numerator.multiply(value.denominator),denominator.multiply(value.numerator));}
    public BigDecimal ceiling(){return new BigDecimal(numerator).divide(new BigDecimal(denominator),0,RoundingMode.CEILING);}
    public int signum(){return numerator.signum();}
    public BigDecimal project(int scale,RoundingMode mode) {
        try{return new BigDecimal(numerator).divide(new BigDecimal(denominator));}
        catch(ArithmeticException repeating){
            BigDecimal projected=new BigDecimal(numerator).divide(new BigDecimal(denominator),scale,mode);
            if(projected.signum()==0&&numerator.signum()!=0)throw CostCalculationMath.invalid("非零成本或用量小于计算精度，请调整计量单位或批量");
            return projected;
        }
    }
    /** Compatibility boundary deliberately enforces the caller's intermediate scale even for finite divisions. */
    public BigDecimal scaled(int scale,RoundingMode mode){return new BigDecimal(numerator).divide(new BigDecimal(denominator),scale,mode);}
    public BigDecimal project(){return project(24,RoundingMode.HALF_EVEN);}
}
