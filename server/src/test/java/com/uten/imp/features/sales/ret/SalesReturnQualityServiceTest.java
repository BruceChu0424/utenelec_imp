package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SalesReturnQualityServiceTest {

    @Test
    void dispositionActionIsClosedToTheThreeControlledOutcomes() {
        assertEquals("GOOD_RELEASE", SalesReturnQualityService.normalizeAction(" good_release "));
        assertEquals("SCRAP", SalesReturnQualityService.normalizeAction("scrap"));
        assertEquals("REWORK", SalesReturnQualityService.normalizeAction("REWORK"));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.normalizeAction("SELL_DIRECTLY"));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.normalizeAction(null));
    }

    @Test
    void cumulativeProrationHasNoFinalReleaseRoundingDrift() {
        BigDecimal first = SalesReturnQualityService.proratedIncrement(
                new BigDecimal("1.0000"), new BigDecimal("3"),
                BigDecimal.ZERO, BigDecimal.ONE);
        BigDecimal second = SalesReturnQualityService.proratedIncrement(
                new BigDecimal("1.0000"), new BigDecimal("3"),
                BigDecimal.ONE, BigDecimal.ONE);
        BigDecimal third = SalesReturnQualityService.proratedIncrement(
                new BigDecimal("1.0000"), new BigDecimal("3"),
                new BigDecimal("2"), BigDecimal.ONE);

        assertEquals(new BigDecimal("1.0000"), first.add(second).add(third));
    }

    @Test
    void dispositionQuantityMatchesTheDatabaseScaleAndPrecision() {
        assertEquals(new BigDecimal("1.0000"),
                SalesReturnQualityService.normalizeDispositionQty(
                        new BigDecimal("1.00000")));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.normalizeDispositionQty(
                        new BigDecimal("0.00001")));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.normalizeDispositionQty(
                        new BigDecimal("123456789012345")));
    }
}
