package com.uten.imp.common.integrity;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;

/**
 * Sign guard for operational documents that store quantities and commercial
 * values as nonnegative magnitudes.
 *
 * <p>This guard validates signs only. It does not calculate an authoritative
 * price or amount and must not be reused by signed stock, AR/AP, or GL ledgers.
 */
public final class NonNegativeCommercialSignGuard {

    private NonNegativeCommercialSignGuard() {
    }

    /** Validate request data before it is persisted. */
    public static void requireRequestLine(
            String documentName, BigDecimal quantity, BigDecimal... commercialValues) {
        if (quantity == null || quantity.signum() <= 0 || hasNegative(commercialValues)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    documentName + "明细数量必须大于 0，价格与金额不得为负数");
        }
    }

    /** Reject anomalous persisted lines before approval or reversal effects. */
    public static void requireStoredLine(
            String documentName, BigDecimal quantity, BigDecimal... commercialValues) {
        if (quantity == null || quantity.signum() <= 0 || hasNegative(commercialValues)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    documentName + "明细的数量、价格或金额符号异常，禁止审核或红冲");
        }
    }

    /** Reject missing or negative persisted header totals. */
    public static void requireStoredTotals(
            String documentName, BigDecimal totalOriginal, BigDecimal totalLocal) {
        if (totalOriginal == null || totalOriginal.signum() < 0
                || totalLocal == null || totalLocal.signum() < 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    documentName + "合计金额为空或为负数，禁止审核或红冲");
        }
    }

    private static boolean hasNegative(BigDecimal... values) {
        if (values == null) return false;
        for (BigDecimal value : values) {
            if (value != null && value.signum() < 0) return true;
        }
        return false;
    }
}
