package com.uten.imp.features.stock.valuation;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.math.RoundingMode;

final class ValueMath {
    static final BigDecimal ZERO = new BigDecimal("0.0000");
    private static final BigDecimal MAX = new BigDecimal("99999999999999.9999");
    private ValueMath() {}

    static BigDecimal decimal(BigDecimal value, String field, boolean negativeAllowed) {
        if (value == null) throw invalid(field + "不能为空");
        try {
            BigDecimal result = value.setScale(4, RoundingMode.UNNECESSARY);
            if (result.abs().compareTo(MAX) > 0 || (!negativeAllowed && result.signum() < 0))
                throw invalid(field + "超出有效范围");
            return result;
        } catch (ArithmeticException ex) { throw invalid(field + "最多4位小数"); }
    }

    static BigDecimal positive(BigDecimal value, String field) {
        BigDecimal result = decimal(value, field, false);
        if (result.signum() <= 0) throw invalid(field + "必须大于0");
        return result;
    }

    /** Frozen cumulative interval; no rounded intermediate unit price or ratio. */
    static BigDecimal interval(BigDecimal value, BigDecimal from, BigDecimal to, BigDecimal denominator) {
        if (denominator.signum() <= 0 || from.signum() < 0 || to.compareTo(from) < 0
                || to.compareTo(denominator) > 0) throw invalid("成本分配数量区间无效");
        BigDecimal high = to.compareTo(denominator) == 0 ? value
                : value.multiply(to).divide(denominator, 4, RoundingMode.HALF_UP);
        BigDecimal low = from.signum() == 0 ? ZERO
                : value.multiply(from).divide(denominator, 4, RoundingMode.HALF_UP);
        return high.subtract(low).setScale(4);
    }

    static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
    static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
}
