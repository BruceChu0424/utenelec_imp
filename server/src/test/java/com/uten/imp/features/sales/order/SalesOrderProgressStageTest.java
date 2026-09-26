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
    void inFlightShipmentsMoveTheOrderIntoShipmentStagesUntilTheWarehouseConfirms() {
        // 参数尾部四项：出货草稿 / 等待财审 / 财务退回 / 财务已放行待出库 的在途数量（V631）。
        // 预留 10 全部开了出货单待财审：不再算「可分批发货」，而是出货待财审。
        assertEquals("SHIPMENT_PENDING",
                SalesOrderService.progressStageOf(10, 10, 0, 10, 10, 0, false, false, false, 0, 10, 0, 0, false));
        // 财务已放行、仓库未出库：等仓库出货。
        assertEquals("WAREHOUSE_PENDING",
                SalesOrderService.progressStageOf(10, 10, 0, 10, 10, 0, false, false, false, 0, 0, 0, 10, false));
        // 部分在途、剩余仍有预留：可分批发货优先——剩余量才是销售的待办。
        assertEquals("SHIPPABLE",
                SalesOrderService.progressStageOf(10, 10, 0, 10, 10, 0, false, false, false, 0, 4, 0, 0, false));
        // 出货草稿、财务退回同样是出货在途。
        assertEquals("SHIPMENT_PENDING",
                SalesOrderService.progressStageOf(10, 10, 0, 10, 10, 0, false, false, false, 10, 0, 0, 0, false));
        assertEquals("SHIPMENT_PENDING",
                SalesOrderService.progressStageOf(10, 10, 0, 10, 10, 0, false, false, false, 0, 0, 10, 0, false));
        // 已出库达订货量仍是终态。
        assertEquals("SHIPPED",
                SalesOrderService.progressStageOf(10, 10, 10, 0, 10, 0, false, false, false, 0, 0, 0, 0, false));
        String expression = SalesOrderService.progressStageExpr();
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("'SHIPPED'") < expression.indexOf("'SHIPPABLE'"));
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("'SHIPPABLE'") < expression.indexOf("'WAREHOUSE_PENDING'"));
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("'WAREHOUSE_PENDING'") < expression.indexOf("'SHIPMENT_PENDING'"));
        org.junit.jupiter.api.Assertions.assertTrue(
                SalesOrderService.progressGroupedSql(
                        new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope(
                                "1=1", null, java.util.Set.of()))
                        .contains("AS shipment_approved_qty"));
    }

    @Test
    void draftOrdersCarryTheirOwnStageAndOnlyEnterViaTheDraftStageParameter() {
        // 草稿单（bill_status=0 且未驳回）即使数量像在途，也不派生生产阶段——
        // 它是「本人开了头没交出去」的活，只进「草稿」段（红徽章）。
        assertEquals("DRAFT",
                SalesOrderService.progressStageOf(10, 5, 0, 5, 10, 0, false, false, false, 0, 0, 0, 0, true));
        // 驳回优先于草稿：status=0 但 finance_rejected=true 的单仍是 REJECTED（驱回段口径不变）。
        assertEquals("REJECTED",
                SalesOrderService.progressStageOf(10, 5, 0, 5, 10, 0, true, false, false, 0, 0, 0, 0, true));
        assertEquals("DRAFT", SalesOrderService.normalizeProgressStage("draft"));
        // SQL 镜像同序：驳回 → 草稿 → 终态 → 生产阶段；草稿行只随 :stage='DRAFT' 放进子查询，
        // 其余 stage（含历史 '' 与两个大类）草稿都不进——不污染既有段落与计数。
        String expression = SalesOrderService.progressStageExpr();
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("finance_rejected") < expression.indexOf("bill_status"));
        org.junit.jupiter.api.Assertions.assertTrue(
                expression.indexOf("bill_status") < expression.indexOf("is_stopped"));
        String grouped = SalesOrderService.progressGroupedSql(
                new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope(
                        "1=1", null, java.util.Set.of()));
        org.junit.jupiter.api.Assertions.assertTrue(grouped.contains(":stage = 'DRAFT'"));
        org.junit.jupiter.api.Assertions.assertTrue(grouped.contains("AS bill_status"));
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
