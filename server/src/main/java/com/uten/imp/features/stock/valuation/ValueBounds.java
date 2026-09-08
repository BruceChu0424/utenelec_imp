package com.uten.imp.features.stock.valuation;

import java.math.BigDecimal;
import java.math.RoundingMode;
import static com.uten.imp.features.stock.valuation.ValueMath.invalid;

/** Directed numerical bounds for an exact expression. Neither end is a posted monetary fact. */
record ValueBounds(BigDecimal lower,BigDecimal upper,int scale) {
    static final int DEFAULT_SCALE=32;
    private static final int MAX_INLINE_EXACT_DIGITS=128;
    ValueBounds {
        if(lower==null||upper==null||lower.compareTo(upper)>0||scale<0||scale>256)
            throw invalid("金额精度界无效");
    }
    static ValueBounds exact(BigDecimal amount){return new ValueBounds(amount,amount,DEFAULT_SCALE);}
    boolean isExact(){return lower.compareTo(upper)==0;}
    ValueBounds add(ValueBounds other){return bounded(lower.add(other.lower),upper.add(other.upper),Math.min(scale,other.scale));}
    ValueBounds subtract(ValueBounds other){return new ValueBounds(lower.subtract(other.upper),upper.subtract(other.lower),Math.min(scale,other.scale));}
    ValueBounds weighted(BigDecimal from,BigDecimal to,BigDecimal denominator,int requestedScale){
        if(denominator==null||denominator.signum()<=0||from==null||to==null||from.signum()<0
                ||to.compareTo(from)<0||to.compareTo(denominator)>0)throw invalid("精确金额份额无效");
        BigDecimal numerator=to.subtract(from);
        if(numerator.signum()==0)return exact(BigDecimal.ZERO);
        if(isExact()&&lower.precision()<=MAX_INLINE_EXACT_DIGITS&&Math.abs(lower.scale())<=MAX_INLINE_EXACT_DIGITS)try{
            // A finite exact quotient stays finite and exact; 1/3 deliberately
            // falls through to directed bounds rather than a longer money value.
            BigDecimal result=lower.multiply(numerator).divide(denominator);
            if(result.precision()<=MAX_INLINE_EXACT_DIGITS&&Math.abs(result.scale())<=MAX_INLINE_EXACT_DIGITS)return exact(result);
        }catch(ArithmeticException nonTerminating){/* Preserve the exact expression outside this cache. */}
        return new ValueBounds(lower.multiply(numerator).divide(denominator,requestedScale,RoundingMode.FLOOR),
                upper.multiply(numerator).divide(denominator,requestedScale,RoundingMode.CEILING),requestedScale);
    }
    /** Replace one separately stored contribution; do not repeatedly subtract uncertain totals. */
    ValueBounds replace(ValueBounds previous,ValueBounds next){
        return new ValueBounds(lower.subtract(previous.lower).add(next.lower),
                upper.subtract(previous.upper).add(next.upper),Math.min(scale,Math.min(previous.scale,next.scale)));
    }
    boolean sameUnit(int places,RoundingMode presentationMode){
        return lower.setScale(places,presentationMode).compareTo(upper.setScale(places,presentationMode))==0;
    }
    private static ValueBounds bounded(BigDecimal lower,BigDecimal upper,int scale){
        if(lower.precision()<=MAX_INLINE_EXACT_DIGITS&&upper.precision()<=MAX_INLINE_EXACT_DIGITS
                &&Math.abs(lower.scale())<=MAX_INLINE_EXACT_DIGITS&&Math.abs(upper.scale())<=MAX_INLINE_EXACT_DIGITS)
            return new ValueBounds(lower,upper,scale);
        return new ValueBounds(lower.setScale(scale,RoundingMode.FLOOR),upper.setScale(scale,RoundingMode.CEILING),scale);
    }
}
