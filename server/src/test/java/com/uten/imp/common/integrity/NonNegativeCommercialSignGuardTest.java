package com.uten.imp.common.integrity;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class NonNegativeCommercialSignGuardTest {

    @Test
    void requestRejectsMissingOrNonPositiveQuantity() {
        assertCode(ErrorCode.VALIDATION_FAILED, () ->
                NonNegativeCommercialSignGuard.requireRequestLine(
                        "采购收货", null, BigDecimal.ZERO));
        assertCode(ErrorCode.VALIDATION_FAILED, () ->
                NonNegativeCommercialSignGuard.requireRequestLine(
                        "采购收货", BigDecimal.ZERO, BigDecimal.ZERO));
    }

    @Test
    void requestRejectsNegativeCommercialValue() {
        assertCode(ErrorCode.VALIDATION_FAILED, () ->
                NonNegativeCommercialSignGuard.requireRequestLine(
                        "销售退货", BigDecimal.ONE,
                        BigDecimal.ZERO, new BigDecimal("-0.01")));
    }

    @Test
    void storedAnomaliesUseConflict() {
        assertCode(ErrorCode.CONFLICT, () ->
                NonNegativeCommercialSignGuard.requireStoredLine(
                        "采购退货", new BigDecimal("-1"), BigDecimal.ZERO));
        assertCode(ErrorCode.CONFLICT, () ->
                NonNegativeCommercialSignGuard.requireStoredLine(
                        "采购退货", BigDecimal.ONE, new BigDecimal("-0.01")));
        assertCode(ErrorCode.CONFLICT, () ->
                NonNegativeCommercialSignGuard.requireStoredTotals(
                        "采购退货", null, BigDecimal.ZERO));
        assertCode(ErrorCode.CONFLICT, () ->
                NonNegativeCommercialSignGuard.requireStoredTotals(
                        "采购退货", BigDecimal.ZERO, new BigDecimal("-0.01")));
    }

    @Test
    void acceptsPositiveQuantityZeroAmountsAndAbsentOptionalValues() {
        assertDoesNotThrow(() ->
                NonNegativeCommercialSignGuard.requireRequestLine(
                        "采购收货", BigDecimal.ONE,
                        BigDecimal.ZERO, null, new BigDecimal("2.50")));
        assertDoesNotThrow(() ->
                NonNegativeCommercialSignGuard.requireStoredLine(
                        "采购收货", BigDecimal.ONE,
                        BigDecimal.ZERO, null, new BigDecimal("2.50")));
        assertDoesNotThrow(() ->
                NonNegativeCommercialSignGuard.requireStoredTotals(
                        "采购收货", BigDecimal.ZERO, new BigDecimal("2.50")));
    }

    private static void assertCode(ErrorCode expected, Executable action) {
        ApiException exception = assertThrows(ApiException.class, action);
        assertEquals(expected, exception.getCode());
    }
}
