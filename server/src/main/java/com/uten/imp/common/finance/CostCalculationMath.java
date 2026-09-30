package com.uten.imp.common.finance;

import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.math.RoundingMode;

/** Shared forecast arithmetic. Quantity is not silently forced through the four-place posting boundary. */
public final class CostCalculationMath {
    private CostCalculationMath() {}
    public static BigDecimal decimal(String text, String label) {
        if (text == null || text.isBlank() || text.length()>100 || !text.matches("[+-]?[0-9]+(?:\\.[0-9]+)?"))
            throw invalid(label + "需为十进制数字");
        try { return FinancialExactAmount.require(new BigDecimal(text),label); }
        catch (NumberFormatException ex) { throw invalid(label + "需为十进制数字"); }
    }
    public static BigDecimal nonnegative(String text, String label) {
        BigDecimal value=decimal(text,label);
        if(value.signum()<0) throw invalid(label+"不能为负数");
        return value;
    }
    public static BigDecimal positive(String text,String label) {
        BigDecimal value=nonnegative(text,label);
        if(value.signum()==0) throw invalid(label+"必须大于零");
        return value;
    }
    public static BigDecimal product(BigDecimal... factors) {
        BigDecimal result=BigDecimal.ONE;
        for(BigDecimal factor:factors) result=result.multiply(factor);
        return FinancialExactAmount.book(result,"成本金额");
    }
    /** Finite divisions stay exact; repeating projections have one explicit 24-place policy. */
    public static BigDecimal divide(BigDecimal numerator,BigDecimal denominator) {
        if(denominator==null || denominator.signum()<=0) throw invalid("成本计算分母必须大于零");
        try { return FinancialExactAmount.book(numerator.divide(denominator),"成本计算结果"); }
        catch(ArithmeticException repeating) {
            return FinancialExactAmount.book(numerator.divide(denominator,24,RoundingMode.HALF_EVEN),"成本计算结果");
        }
    }
    public static String text(BigDecimal value) { return value==null?null:value.stripTrailingZeros().toPlainString(); }
    public static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED,message); }
}
