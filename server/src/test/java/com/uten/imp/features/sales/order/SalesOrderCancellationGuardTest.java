package com.uten.imp.features.sales.order;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SalesOrderCancellationGuardTest {

    @Test
    void unplannedOrderCanUseTheSimpleCancellationPath() {
        assertFalse(SalesOrderService.cancellationRequiresProductionClearance(
                BigDecimal.ZERO, BigDecimal.ZERO, false));
        assertFalse(SalesOrderService.cancellationRequiresProductionClearance(
                null, null, false));
    }

    @Test
    void anyProductionCommitmentRequiresUpstreamClearanceFirst() {
        assertTrue(SalesOrderService.cancellationRequiresProductionClearance(
                new BigDecimal("1"), BigDecimal.ZERO, false));
        assertTrue(SalesOrderService.cancellationRequiresProductionClearance(
                BigDecimal.ZERO, new BigDecimal("0.0001"), false));
        assertTrue(SalesOrderService.cancellationRequiresProductionClearance(
                BigDecimal.ZERO, BigDecimal.ZERO, true));
    }

    @Test
    void negativeLegacyValuesStillDoNotHideAnActivePlanLink() {
        assertTrue(SalesOrderService.cancellationRequiresProductionClearance(
                new BigDecimal("-1"), new BigDecimal("-1"), true));
    }
}
