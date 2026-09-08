package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;

/** Shared bound for finite financial facts. Validates without rounding their value. */
public final class FinancialExactAmount {
    private static final BigDecimal ABSOLUTE_LIMIT=BigDecimal.ONE.scaleByPowerOfTen(40);
    public static final int MAX_FRACTION_DIGITS=24;
    public static final int MAX_BOOK_FRACTION_DIGITS=30;

    private FinancialExactAmount() {}

    public static BigDecimal require(BigDecimal value,String label) {
        return requireFinite(value,label,MAX_FRACTION_DIGITS);
    }

    /** Derived book values retain the complete product of an actual amount and its rate. */
    public static BigDecimal book(BigDecimal value,String label) {
        return requireFinite(value,label,MAX_BOOK_FRACTION_DIGITS);
    }

    private static BigDecimal requireFinite(BigDecimal value,String label,int fractionDigits) {
        if(value==null) throw invalid(label,"不能为空");
        // Remove representational zeros only. This also avoids expanding a
        // zero carrying an adversarially large exponent when emitting JSON.
        BigDecimal exact=value.stripTrailingZeros();
        if(exact.abs().compareTo(ABSOLUTE_LIMIT)>=0 || exact.scale()>fractionDigits) {
            throw invalid(label,"超出可无损保存的金额范围，请核对原始单据；本次未保存");
        }
        return exact;
    }

    public static BigDecimal optional(BigDecimal value,String label) { return value==null?null:require(value,label); }

    public static BigDecimal unitPrice(BigDecimal value,String label) {
        return boundedInput(value,label,10,14);
    }

    public static BigDecimal quantity(BigDecimal value,String label) {
        return boundedInput(value,label,4,14);
    }

    public static BigDecimal rate(BigDecimal value,String label) {
        return boundedInput(value,label,6,12);
    }

    /** Keeps legacy four-decimal formatting for equal values without discarding further digits. */
    public static BigDecimal canonicalMoney(BigDecimal value,String label) {
        BigDecimal exact=book(value,label);
        return exact.setScale(Math.max(4,exact.scale()),java.math.RoundingMode.UNNECESSARY);
    }

    private static BigDecimal boundedInput(BigDecimal value,String label,int fractionDigits,int integerDigits) {
        BigDecimal exact=require(value,label);
        if(exact.scale()>fractionDigits || exact.abs().compareTo(BigDecimal.ONE.scaleByPowerOfTen(integerDigits))>=0) {
            throw invalid(label,"超出可无损保存的范围(小数最多"+fractionDigits+"位)，请核对原值；本次未保存");
        }
        return exact;
    }

    private static ApiException invalid(String label,String reason) {
        return new ApiException(ErrorCode.VALIDATION_FAILED,
                (label==null || label.isBlank()?"金额":label)+reason);
    }
}
