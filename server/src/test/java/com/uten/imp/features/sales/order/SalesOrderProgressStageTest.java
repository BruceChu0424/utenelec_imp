package com.uten.imp.features.sales.order;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;

/** 参数顺序：orderQty, producedQty, shippedQty, reservedQty, plannedQty, unplannedQty[, 标志]。 */
class SalesOrderProgressStageTest {

    @Test
    void positiveFinishedGoodsReservationIsPartiallyShippableBeforeFullProduction() {
        assertEquals(
                "SHIPPABLE",
                SalesOrderService.progressStageOf(
                        10, 5, 0, 5, 10, 0));
    }

    @Test
    void stageStillUsesActualShipmentCompletionAsTheTerminalBoundary() {
        assertEquals(
                "SHIPPABLE",
                SalesOrderService.progressStageOf(
                        10, 10, 5, 5, 10, 0));
        assertEquals(
                "SHIPPED",
                SalesOrderService.progressStageOf(
                        10, 10, 10, 0, 10, 0));
    }

    @Test
    void producedQuantityWithoutAvailableReservationIsNotCalledShippable() {
        // 已产 5 但预留已让出：不可发货；且这 5 件已不属于本单，剩余未排 5 → 回到待排产。
        String stage = SalesOrderService.progressStageOf(10, 5, 0, 0, 10, 5);
        assertNotEquals("SHIPPABLE", stage);
        assertEquals("PENDING", stage);
    }

    @Test
    void partialPlannedStaysPending() {
        // V545：订 10 排 4（未排 6）——仍是待排产，不因 planned>0 进生产中。
        assertEquals(
                "PENDING",
                SalesOrderService.progressStageOf(
                        10, 0, 0, 0, 4, 6));
        // 报工/部分入库后只要未排量还在，阶段不变（入库预留会先命中 SHIPPABLE，此处预留为 0）。
        assertEquals(
                "PENDING",
                SalesOrderService.progressStageOf(
                        10, 0, 0, 0, 4, 6, false, false, false));
        String expression = SalesOrderService.progressStageExpr();
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("reserved_qty") < expression.indexOf("unplanned_qty"));
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("unplanned_qty") < expression.indexOf("produced_qty"));
        org.junit.jupiter.api.Assertions.assertTrue(
                SalesOrderService.progressGroupedSql(
                        new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope(
                                "1=1", null, java.util.Set.of()))
                        .contains("AS unplanned_qty"));
    }

    @Test
    void fullyPlannedIsProducing() {
        assertEquals(
                "PRODUCING",
                SalesOrderService.progressStageOf(
                        10, 0, 0, 0, 10, 0));
        assertEquals(
                "PRODUCING",
                SalesOrderService.progressStageOf(
                        10, 3, 0, 0, 10, 0));
    }

    @Test
    void unresolvedFinanceRejectionOverridesEveryProductionStage() {
        assertEquals(
                "REJECTED",
                SalesOrderService.progressStageOf(
                        10, 10, 10, 0, 10, 0, true));
        assertEquals(
                "REJECTED",
                SalesOrderService.progressStageOf(
                        0, 0, 0, 0, 0, 0, true));
        String expression = SalesOrderService.progressStageExpr();
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("finance_rejected")
                        < expression.indexOf("shipped_qty"));
    }

    @Test
    void stoppedAndClosedOrdersAreTerminalStagesOutsideTheActiveSegments() {
        // 已中止（整单取消）：数量再怎么像在途，也不再占「待排产/生产中/可发货」。
        assertEquals(
                "CANCELED",
                SalesOrderService.progressStageOf(
                        10, 5, 0, 5, 10, 0, false, true, false));
        // 已结案：即使未发满也不再回到生产阶段。
        assertEquals(
                "CLOSED",
                SalesOrderService.progressStageOf(
                        10, 5, 2, 0, 10, 0, false, false, true));
        // 驳回优先于中止/结案（驳回未解决时仍要先出现在「财务驳回」段提醒销售）。
        assertEquals(
                "REJECTED",
                SalesOrderService.progressStageOf(
                        10, 5, 0, 5, 10, 0, true, true, false));
        String expression = SalesOrderService.progressStageExpr();
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("finance_rejected")
                        < expression.indexOf("is_stopped"));
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("is_stopped")
                        < expression.indexOf("is_closed"));
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("is_closed")
                        < expression.indexOf("order_qty"));
    }

    @Test
    void openStageIsThePendingDefaultAndUnknownStagesAreRejected() {
        assertEquals("", SalesOrderService.normalizeProgressStage(null));
        assertEquals("", SalesOrderService.normalizeProgressStage(""));
        assertEquals("OPEN", SalesOrderService.normalizeProgressStage("open"));
        assertEquals("REJECTED", SalesOrderService.normalizeProgressStage("rejected"));
        assertEquals("SHIPPED", SalesOrderService.normalizeProgressStage(" shipped "));
        assertEquals("CANCELED", SalesOrderService.normalizeProgressStage("canceled"));
        assertEquals("CLOSED", SalesOrderService.normalizeProgressStage("closed"));
        org.junit.jupiter.api.Assertions.assertThrows(
                com.uten.imp.common.web.ApiException.class,
                () -> SalesOrderService.normalizeProgressStage("BOGUS"));
    }

    @Test
    void stagePredicateCoversAllOpenAndExactStageBranches() {
        String predicate = SalesOrderService.progressStagePredicate();
        org.junit.jupiter.api.Assertions.assertTrue(predicate.contains(":stage = ''"));
        org.junit.jupiter.api.Assertions.assertTrue(predicate.contains(":stage = 'OPEN'"));
        // OPEN = 活跃在途：三个终态（已发货/已中止/已结案）都不算待完成。
        org.junit.jupiter.api.Assertions.assertTrue(
                predicate.contains("NOT IN ('SHIPPED','CANCELED','CLOSED')"));
        org.junit.jupiter.api.Assertions.assertTrue(predicate.contains(") = :stage"));
    }
}
