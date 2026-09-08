package com.uten.imp.common.finance;

import com.uten.imp.common.util.FinancialExactAmount;
import java.math.BigDecimal;

/** A finite projection is optional; the linked source and exact quantity ratio are always authoritative. */
public final class ProcurementConsiderationBasis {
    private ProcurementConsiderationBasis() {}

    public static BigDecimal finitePortion(BigDecimal source,BigDecimal numerator,BigDecimal denominator) {
        return finitePortion(source,numerator,denominator,FinancialExactAmount.MAX_FRACTION_DIGITS);
    }
    public static BigDecimal finiteBookPortion(BigDecimal source,BigDecimal numerator,BigDecimal denominator) {
        return finitePortion(source,numerator,denominator,FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS);
    }
    private static BigDecimal finitePortion(BigDecimal source,BigDecimal numerator,BigDecimal denominator,int maxFractionDigits) {
        if(source==null)return null;
        if(numerator.signum()<0||denominator.signum()<=0||numerator.compareTo(denominator)>0)
            throw new IllegalArgumentException("Invalid consideration quantity basis");
        try {
            BigDecimal result=source.multiply(numerator).divide(denominator).stripTrailingZeros();
            return result.scale()>maxFractionDigits?null:result;
        } catch(ArithmeticException nonTerminating) {
            return null;
        }
    }

    public static BigDecimal add(BigDecimal left,BigDecimal right) {
        return left==null||right==null?null:left.add(right);
    }

    /** A reviewed book allocation retains its remainder in the source; the final share takes it all. */
    public static BigDecimal bookAllocation(BigDecimal remainingLocal,BigDecimal actualOriginal,BigDecimal remainingOriginal){
        BigDecimal exact=finiteBookPortion(remainingLocal,actualOriginal,remainingOriginal);
        return exact!=null?exact:remainingLocal.multiply(actualOriginal)
                .divide(remainingOriginal,FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS,java.math.RoundingMode.DOWN);
    }
}
