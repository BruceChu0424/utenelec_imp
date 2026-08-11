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
}
