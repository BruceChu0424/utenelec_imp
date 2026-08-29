package com.uten.imp.features.sales.order;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class SalesOrderProgressStageTest {

    @Test
    void positiveFinishedGoodsReservationIsPartiallyShippableBeforeFullProduction() {
        assertEquals(
                "SHIPPABLE",
                SalesOrderService.progressStageOf(
                        10, 5, 0, 5, 10));
    }

    @Test
    void stageStillUsesActualShipmentCompletionAsTheTerminalBoundary() {
        assertEquals(
                "SHIPPABLE",
                SalesOrderService.progressStageOf(
                        10, 10, 5, 5, 10));
        assertEquals(
                "SHIPPED",
                SalesOrderService.progressStageOf(
                        10, 10, 10, 0, 10));
    }

    @Test
    void producedQuantityWithoutAvailableReservationIsNotCalledShippable() {
        assertEquals(
                "PRODUCING",
                SalesOrderService.progressStageOf(
                        10, 5, 0, 0, 10));
    }

    @Test
    void unresolvedFinanceRejectionOverridesEveryProductionStage() {
        assertEquals(
                "REJECTED",
                SalesOrderService.progressStageOf(
                        10, 10, 10, 0, 10, true));
        assertEquals(
                "REJECTED",
                SalesOrderService.progressStageOf(
                        0, 0, 0, 0, 0, true));
        String expression = SalesOrderService.progressStageExpr();
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("finance_rejected")
                        < expression.indexOf("shipped_qty"));
    }

    @Test
    void openStageIsThePendingDefaultAndUnknownStagesAreRejected() {
        assertEquals("", SalesOrderService.normalizeProgressStage(null));
        assertEquals("", SalesOrderService.normalizeProgressStage(""));
        assertEquals("OPEN", SalesOrderService.normalizeProgressStage("open"));
        assertEquals("REJECTED", SalesOrderService.normalizeProgressStage("rejected"));
        assertEquals("SHIPPED", SalesOrderService.normalizeProgressStage(" shipped "));
        org.junit.jupiter.api.Assertions.assertThrows(
                com.uten.imp.common.web.ApiException.class,
                () -> SalesOrderService.normalizeProgressStage("BOGUS"));
    }

    @Test
    void stagePredicateCoversAllOpenAndExactStageBranches() {
        String predicate = SalesOrderService.progressStagePredicate();
        org.junit.jupiter.api.Assertions.assertTrue(predicate.contains(":stage = ''"));
        org.junit.jupiter.api.Assertions.assertTrue(predicate.contains(":stage = 'OPEN'"));
        org.junit.jupiter.api.Assertions.assertTrue(predicate.contains("<> 'SHIPPED'"));
        org.junit.jupiter.api.Assertions.assertTrue(predicate.contains(") = :stage"));
    }
}
