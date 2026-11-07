package com.uten.imp.businesschain;

import com.uten.imp.application.port.PreplanInboundAllocationReadPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService.ClosureRequest;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.*;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

/** Follow the quantities suggested by analysis through real manufacturing, dispatch and actual receipt. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SubcontractMaterialAnalysisSupplyEndToEndTest extends SubcontractFullChainTestContext {
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired PreplanInboundAllocationReadPort inboundAllocations;
    AggregateMaterialOrderEndToEndTest h;

    @BeforeEach void before() { h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before(); }
    @AfterEach void after() { h.after(); }

    private UUID parentSegment(AggregateMaterialOrderEndToEndTest.Case c) {
        var world = c.world();
        var initial = h.analyses.detail(c.analysis());
        var root = initial.products().stream().filter(row -> row.salesOrderItemId() != null).findFirst().orElseThrow();
        var parentPlan = h.ordinary.issueWorkshopPlans(c.analysis(), new IssueWorkshopPlansRequest(
                initial.version(), initial.fingerprint(), "supplement-parent-" + c.analysis(), world.warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(5), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null, root.analysisLineId(), new BigDecimal("1000"),
                        null, null, c.workshop(), null, c.worker(), null, null, false, BigDecimal.ZERO))))
                .plans().getFirst().planId();
        UUID segment = h.db.queryForObject("""
                SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted
                """, UUID.class, parentPlan);
        h.fixture.confirmFullKitRoute(parentPlan, segment);
        return segment;
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void qualifiedSupplementCompletesTheOriginalWorkshopDemandAfterShortDelivery(boolean directClosure) {
        var c = h.createWithChildAndLoss("1000", "0");
        UUID segment = parentSegment(c);
        h.fixture.receiveSubcontractMaterial(c.world(), c.child(), "1200");
        UUID first = order(c, "0", "1000");
        h.fixture.drawAndIssueSubcontract(first, new BigDecimal("1000"), "supplement-first-draw-" + first);
        receiveAndStock(c, first, "800", true);
        drainCosts(c);
        assertEquals("WAITING", segmentStatus(segment));

        UUID supplement;
        if (directClosure) {
            var closure = beans.getBean(ProcurementOrderClosureService.class);
            UUID firstOrder = h.db.queryForObject("SELECT order_id FROM subcontract_order_items WHERE id=?", UUID.class, first);
            UUID originalApplication = h.db.queryForObject("""
                    SELECT application_item_id FROM subcontract_order_item_sources WHERE order_item_id=?
                    """, UUID.class, first);
            var preview = closure.preview("SUBCONTRACT", firstOrder);
            amount("200", preview.items().getFirst().remainingQty());
            closure.submit("SUBCONTRACT", firstOrder, new ClosureRequest("CLOSE", "剩余件数结束，计划按真实缺口补订", preview.fingerprint()));
            amount("0", h.db.queryForObject("SELECT fn_subcontract_settled_loss_qty(?)", BigDecimal.class, first));
            amount("800", h.db.queryForObject("SELECT ordered_qty FROM subcontract_application_items WHERE id=?", BigDecimal.class, originalApplication));
            refresh(c);
            supplement = orderSubcontractApplication(c, externalApplication(c, "SUBCONTRACT", "200", true,
                    "PRIORITIZE_PARENT"), "0", "200");
        } else {
            var losses = beans.getBean(SubcontractShortDeliveryService.class);
            UUID shortCase = h.db.queryForObject("""
                    SELECT id FROM subcontract_short_delivery_cases WHERE order_item_id=? AND closed_at IS NULL
                    """, UUID.class, first);
            var pending = losses.detail(shortCase).row();
            losses.decide(shortCase, new DecisionRequest("ACCEPT_LOSS", null, "实际只回厂800，其余另行补单", pending.version()));
            amount("200", material(refresh(c), c.common()).planningUncoveredQty());
            supplement = order(c, "0", "200");
        }
        amount("1000", h.db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, first));
        assertEquals("WAITING", segmentStatus(segment));
        h.fixture.drawAndIssueSubcontract(supplement, new BigDecimal("200"), "supplement-draw-" + supplement);
        receiveAndStock(c, supplement, "200");
        drainCosts(c);
        assertEquals("READY", segmentStatus(segment));
        assertDrawQuantity(c, segment, "1000");
        assertPublicStock(c, "0");
    }

    @ParameterizedTest
    @CsvSource({
            "SUBCONTRACT, PRIORITIZE_PARENT, true",
            "BUY, PRIORITIZE_PARENT, true",
            "SUBCONTRACT, PRIORITIZE_PARENT, false",
            "SUBCONTRACT, PUBLIC_ONLY, true",
            "BUY, PUBLIC_ONLY, true"
    })
    void independentOrdersKeepTheParentCapAcrossReceiptOrder(String route, String receiptMode, boolean appendedFirst) {
        var c = supplyCase(route);
        UUID segment = parentSegment(c);
        if (route.equals("SUBCONTRACT")) h.fixture.receiveSubcontractMaterial(c.world(), c.child(), "10000");
        UUID original = orderExternal(c, route, "1000", null);
        UUID appended = orderExternal(c, route, "9000", receiptMode);
        assertNotEquals(original, appended);
        assertEquals("WAITING", segmentStatus(segment));
        assertPublicStock(c, "0");

        boolean firstCoversParent = !appendedFirst || receiptMode.equals("PRIORITIZE_PARENT");
        String firstQty = appendedFirst ? "9000" : "1000";
        UUID firstReceipt = receiveExternal(c, route, appendedFirst ? appended : original, firstQty);
        String firstPrivate = firstCoversParent ? "1000" : "0";
        String firstPublic = new BigDecimal(firstQty).subtract(new BigDecimal(firstPrivate)).toPlainString();
        assertReceiptAllocation(c, firstReceipt, firstPrivate, firstPublic);
        assertEquals(firstCoversParent ? "READY" : "WAITING", segmentStatus(segment));
        assertPublicStock(c, firstPublic);
        boolean issueBeforeOriginal = route.equals("SUBCONTRACT") && appendedFirst && firstCoversParent;
        String finalStatus = "READY";
        if (issueBeforeOriginal) {
            assertDrawQuantity(c, segment, "1000");
            submitAndIssueDraw(segment);
            drainCosts(c);
            finalStatus = segmentStatus(segment);
        }

        String secondQty = appendedFirst ? "1000" : "9000";
        UUID secondReceipt = receiveExternal(c, route, appendedFirst ? original : appended, secondQty);
        String secondPrivate = firstCoversParent ? "0" : "1000";
        assertReceiptAllocation(c, secondReceipt, secondPrivate,
                new BigDecimal(secondQty).subtract(new BigDecimal(secondPrivate)).toPlainString());
        assertEquals(finalStatus, segmentStatus(segment));
        if (!issueBeforeOriginal) assertDrawQuantity(c, segment, "1000");
        assertPublicStock(c, "9000");
        if (issueBeforeOriginal) {
            amount("9000", h.db.queryForObject("""
                    SELECT SUM(qty) FROM stock_balances WHERE goods_id=? AND warehouse_id=?
                    """, BigDecimal.class, c.common(), c.world().warehouseId()));
            assertPublicStock(c, "9000");
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"SUBCONTRACT", "BUY"})
    void firstOrderMayContainOneThousandForTheParentAndNineThousandForPublicStock(String route) {
        var c = supplyCase(route);
        UUID segment = parentSegment(c);
        if (route.equals("SUBCONTRACT")) h.fixture.receiveSubcontractMaterial(c.world(), c.child(), "10000");
        UUID ordered = orderExternal(c, route, "10000", null);
        UUID receipt = receiveExternal(c, route, ordered, "10000");
        assertReceiptAllocation(c, receipt, "1000", "9000");
        assertEquals("READY", segmentStatus(segment));
        assertDrawQuantity(c, segment, "1000");
        assertPublicStock(c, "9000");
        if (route.equals("BUY")) assertAnotherOrderCanUsePublicStock(c);
    }

    private void assertAnotherOrderCanUsePublicStock(AggregateMaterialOrderEndToEndTest.Case c) {
        var world = c.world();
        UUID product = UUID.randomUUID();
        h.fixture.insertGoods(product, "PRIORITY-PUBLIC-" + product, "公共库存供另一订单成品", "自制",
                world.unitId(), world.unitLegacy());
        h.fixture.insertBom(product, c.common(), "1");
        UUID sales = h.fixture.createApprovedOrder(world, product, "1000", "100");
        UUID salesLine = h.db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, sales);
        var analysis = h.analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(), "priority-public-" + sales,
                List.of(new PreviewItem("SALES_ORDER_ITEM", salesLine, null, null, null, null,
                        null, BusinessTime.today().plusDays(7), new BigDecimal("1000")))));
        var routes = analysis.flatMaterials().stream().filter(MaterialView::actionable)
                .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(), row.sourceSuggestion(), null)).toList();
        if (!routes.isEmpty()) h.analyses.saveRoutes(analysis.analysisId(), new RouteRequest(
                analysis.version(), analysis.fingerprint(), "priority-public-routes-" + sales, routes));
        var other = new AggregateMaterialOrderEndToEndTest.Case(world, analysis.analysisId(), c.common(),
                c.child(), c.material(), c.workshop(), c.worker());
        UUID segment = parentSegment(other);
        assertEquals("READY", segmentStatus(segment));
        assertDrawQuantity(other, segment, "1000");
        submitAndIssueDraw(segment);
        assertPublicStock(c, "8000");
    }

    @Test void reversingAnUnissuedPriorityReceiptRestoresCapacityForTheOriginalOrder() {
        var c = supplyCase("BUY");
        UUID segment = parentSegment(c);
        UUID original = orderExternal(c, "BUY", "1000", null);
        UUID appended = orderExternal(c, "BUY", "600", "PRIORITIZE_PARENT");
        UUID earlyReceipt = receiveExternal(c, "BUY", appended, "600");
        assertReceiptAllocation(c, earlyReceipt, "600", "0");
        assertEquals("WAITING", segmentStatus(segment));
        assertPublicStock(c, "0");

        var receipts = beans.getBean(com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class);
        receipts.reverse(earlyReceipt);
        drainCosts(c);
        assertEquals("WAITING", segmentStatus(segment));
        amount("0", h.db.queryForObject("""
                SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?
                """, BigDecimal.class, c.common(), c.world().warehouseId()));

        UUID originalReceipt = receiveExternal(c, "BUY", original, "1000");
        assertReceiptAllocation(c, originalReceipt, "1000", "0");
        assertEquals("READY", segmentStatus(segment));
        assertDrawQuantity(c, segment, "1000");
        assertPublicStock(c, "0");
    }

    @Test void concurrentPurchaseStockInsDoNotClaimMoreThanTheParentsRemainingDemand() throws Exception {
        var c = supplyCase("BUY");
        UUID segment = parentSegment(c);
        UUID original = orderExternal(c, "BUY", "1000", null);
        UUID appended = orderExternal(c, "BUY", "600", "PRIORITIZE_PARENT");
        var originalInbound = purchaseInbound(c, original, "1000");
        var appendedInbound = purchaseInbound(c, appended, "600");
        UUID keeper = h.fixture.createIqcWarehouseConfirmer(c.world(), "priority-race-" + c.analysis());
        var stockIn = beans.getBean(ProcurementIqcStockInService.class);
        var ready = new CountDownLatch(2);
        var start = new CountDownLatch(1);
        var pool = Executors.newFixedThreadPool(2);
        try {
            var receipts = List.of(originalInbound, appendedInbound);
            var tasks = receipts.stream().map(inbound -> pool.submit(() -> {
                h.fixture.loginAs(keeper);
                ready.countDown();
                try {
                    assertTrue(start.await(20, TimeUnit.SECONDS));
                    return stockIn.confirm("PURCHASE", inbound.receipt(), inbound.command());
                } finally {
                    SecurityContextHolder.clearContext();
                }
            })).toList();
            assertTrue(ready.await(20, TimeUnit.SECONDS));
            start.countDown();
            var committed = List.of(tasks.get(0).get(60, TimeUnit.SECONDS).batchId(),
                    tasks.get(1).get(60, TimeUnit.SECONDS).batchId());
            assertAllocationTotals(c, inboundAllocations.actualForBatches(committed), "1000", "600");
        } finally {
            start.countDown();
            pool.shutdownNow();
            assertTrue(pool.awaitTermination(10, TimeUnit.SECONDS));
        }
        h.fixture.loginAs(c.world().superAdminUserId());
        assertEquals("READY", segmentStatus(segment));
        assertDrawQuantity(c, segment, "1000");
        assertPublicStock(c, "600");
    }

    private record PurchaseInbound(UUID receipt, ConfirmRequest command) { }

    private PurchaseInbound purchaseInbound(AggregateMaterialOrderEndToEndTest.Case c, UUID order, String rawQty) {
        var world = c.world();
        var qty = new BigDecimal(rawQty);
        var registered = arrivals.register(new WarehouseArrivalRegisterRequest("priority-arrival-" + order, "PURCHASE",
                BusinessTime.today(), world.supplierId(), world.warehouseId(), null, world.employeeId(), null,
                List.of(new ArrivalLine(c.common(), qty, order, null, world.unitId(), BigDecimal.ONE, null, null)), null, null));
        assertEquals("SUBMITTED_FOR_INSPECTION", registered.outcome());
        UUID inspection = h.db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_id=?", UUID.class, registered.receiptId());
        beans.getBean(ProcurementInspectionService.class).dispose("PURCHASE", registered.receiptId(), inspection,
                new InspectionDispositionRequest("PASS", null, "合格", "priority-pass-" + order));
        UUID pass = h.db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",
                UUID.class, inspection);
        return new PurchaseInbound(registered.receiptId(), new ConfirmRequest("priority-stock-" + order,
                List.of(new ConfirmItem(pass, qty, qty, "PRIORITY-A01", world.warehouseId()))));
    }

    private AggregateMaterialOrderEndToEndTest.Case supplyCase(String route) {
        return route.equals("SUBCONTRACT") ? h.createWithChildAndLoss("1000", "0") : h.createWithChild("1000", 1, route);
    }

    private void assertDrawQuantity(AggregateMaterialOrderEndToEndTest.Case c, UUID segment, String quantity) {
        var draws = beans.getBean(ProductionDrawRequestService.class);
        var preview = draws.preview(new ProductionDrawRequest.PreviewRequest(
                List.of(new ProductionDrawRequest.Item(segment, h.version(segment)))));
        amount(quantity, preview.lines().stream().filter(row -> row.goodsId().equals(c.common()))
                .map(ProductionDrawRequest.Line::qty).reduce(BigDecimal.ZERO, BigDecimal::add));
    }

    private void assertPublicStock(AggregateMaterialOrderEndToEndTest.Case c, String quantity) {
        amount(quantity, h.db.queryForObject("""
                SELECT COALESCE(SUM(available_qty),0) FROM v_stock_available WHERE goods_id=? AND warehouse_id=?
                """, BigDecimal.class, c.common(), c.world().warehouseId()));
    }

    private void assertReceiptAllocation(AggregateMaterialOrderEndToEndTest.Case c, UUID receipt, String privateQty, String publicQty) {
        var actual = inboundAllocations.actualForBatches(h.db.queryForList("""
                SELECT id FROM procurement_iqc_stock_in_batches WHERE receipt_id=?
                """, UUID.class, receipt));
        assertAllocationTotals(c, actual, privateQty, publicQty);
    }

    private void assertAllocationTotals(AggregateMaterialOrderEndToEndTest.Case c,
                                        List<PreplanInboundAllocationReadPort.AllocationView> actual,
                                        String privateQty, String publicQty) {
        amount(privateQty, actual.stream().filter(slice -> c.analysis().equals(slice.analysisId()))
                .map(PreplanInboundAllocationReadPort.AllocationView::qty).reduce(BigDecimal.ZERO, BigDecimal::add));
        amount(publicQty, actual.stream().filter(slice -> PreplanInboundAllocationReadPort.PUBLIC.equals(slice.kind()))
                .map(PreplanInboundAllocationReadPort.AllocationView::qty).reduce(BigDecimal.ZERO, BigDecimal::add));
    }

    private void drainCosts(AggregateMaterialOrderEndToEndTest.Case c) {
        InventoryValueWorkTestSupport.drain(beans.getBean(InventoryValueWorkService.class), h.db,
                java.util.stream.Stream.of(c.common(), c.child(), c.material()).filter(java.util.Objects::nonNull).distinct().toList());
    }

    private String segmentStatus(UUID segment) {
        return h.db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?", String.class, segment);
    }

    @Test void baseShortageIs1000BeforeApprovalAndFrozen1100SupplyCanDeliver1050() {
        var c=h.createWithChildAndLoss("1000","10");
        MaterialView child=child(c);
        amount("1000",child.sourceRequiredQty());amount("1",child.bomQty());amount("1000",child.requiredQty());
        amount("0",child.preparationAvailableQty());
        amount("1000",child.shortageQty());
        amount("1000",child.netShortageQty());
        amount("1000",child.planningUncoveredQty());
        MaterialView refreshedChild=material(refresh(c),c.child());
        amount("1000",refreshedChild.netShortageQty());
        amount("1000",refreshedChild.planningUncoveredQty());

        UUID plan=issue(c,"1100").plans().getFirst().planId();
        produce(c,plan);
        UUID item=order(c,"10");
        amount("1000",h.db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?",BigDecimal.class,item));
        amount("1100",h.db.queryForObject("SELECT planned_qty FROM subcontract_material_plan_items WHERE order_item_id=? AND goods_id=?",BigDecimal.class,item,c.child()));
        h.fixture.drawAndIssueSubcontract(item,new BigDecimal("1000"),"initial-budget-draw-"+item);
        receiveAndStock(c,item,"1050");
        var refreshed=refresh(c);MaterialView parent=material(refreshed,c.common());
        amount("1000",parent.exactPeggedQty());amount("0",parent.planningUncoveredQty());
        amount("0",material(refreshed,c.child()).requiredQty());
        amount("0",material(refreshed,c.child()).planningUncoveredQty());
        amount("1050",h.db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.world().warehouseId(),c.common()));
        amount("50",h.db.queryForObject("SELECT SUM(available_qty) FROM v_stock_available WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.world().warehouseId(),c.common()));

        // The completed parent's unused material returns through the real
        // supplier-custody/warehouse/cost chain, without reviving its old claim.
        InventoryValueWorkTestSupport.drain(beans.getBean(InventoryValueWorkService.class),h.db,
                List.of(c.material(),c.child(),c.common()));
        UUID issueItem=h.db.queryForObject("""
                SELECT source.id FROM subcontract_material_issue_items source
                JOIN subcontract_material_issues issue ON issue.id=source.issue_id
                  AND issue.status=1 AND NOT issue.is_deleted
                WHERE source.order_item_id=? AND source.goods_id=? AND NOT source.is_deleted
                """,UUID.class,item,c.child());
        amount("50",h.db.queryForObject("""
                SELECT at_supplier_qty+COALESCE(compensated_qty,0)-consumed_qty
                    -COALESCE(returned_qty,0)-COALESCE(wasted_qty,0)
                FROM subcontract_material_issue_items WHERE id=?
                """,BigDecimal.class,issueItem));
        var returnLine=new MaterialReturnItemLine();returnLine.setGoodsId(c.child());
        returnLine.setUnitId(c.world().unitId());returnLine.setUnitRate(BigDecimal.ONE);
        returnLine.setQty(new BigDecimal("50"));returnLine.setOrderItemId(item);
        returnLine.setParentGoodsId(c.common());returnLine.setMaterialIssueItemId(issueItem);
        var returnRequest=new MaterialReturnSaveRequest();returnRequest.setBillDate(BusinessTime.today());
        returnRequest.setSupplierId(c.world().supplierId());returnRequest.setWarehouseId(c.world().warehouseId());
        returnRequest.setItems(List.of(returnLine));
        var materialReturns=beans.getBean(SubcontractMaterialReturnService.class);
        UUID returned=materialReturns.create(returnRequest).getId();materialReturns.approve(returned);
        InventoryValueWorkTestSupport.drain(beans.getBean(InventoryValueWorkService.class),h.db,
                List.of(c.material(),c.child(),c.common()));
        var afterReturn=refresh(c);
        amount("1000",material(afterReturn,c.common()).exactPeggedQty());
        amount("0",material(afterReturn,c.common()).planningUncoveredQty());
        amount("0",material(afterReturn,c.child()).requiredQty());
        amount("0",material(afterReturn,c.child()).planningUncoveredQty());
        amount("50",h.db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.world().warehouseId(),c.child()));
        amount("50",h.db.queryForObject("SELECT SUM(available_qty) FROM v_stock_available WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.world().warehouseId(),c.child()));
        amount("0",h.db.queryForObject("""
                SELECT COALESCE(SUM(lot.remaining_qty),0)
                FROM v_preplan_stock_entitlement_lot_balance lot
                JOIN stock_reservations reservation ON reservation.id=lot.stock_reservation_id
                  AND reservation.status=0 AND NOT reservation.is_deleted
                WHERE lot.beneficiary_analysis_id=? AND reservation.goods_id=? AND lot.remaining_qty>0
                """,BigDecimal.class,c.analysis(),c.child()));
        assertEquals(1L,h.db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Long.class,c.analysis()));
        amount("1100",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,plan));
    }

    @Test void lateAllowanceCreatesPrivateSupplementAfterActualCompletionWithoutChangingTheOldPlan() {
        var c=h.createWithChildAndLoss("1000","0");
        UUID original=issue(c,"1000").plans().getFirst().planId();produce(c,original);
        h.db.update("UPDATE goods SET subcontract_allowed_loss_pct=10 WHERE id=?",c.common());
        order(c,"10");
        var refreshed=refresh(c);amount("100",material(refreshed,c.child()).planningUncoveredQty());
        var request=issueRequest(c,"100");
        var result=h.ordinary.issueWorkshopPlans(c.analysis(),request);
        assertEquals(1,result.plans().size());UUID replacement=result.plans().getFirst().planId();
        assertNotEquals(original,replacement);
        amount("1000",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,original));
        amount("100",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,replacement));
        amount("100",h.db.queryForObject("SELECT submitted_qty FROM production_material_analysis_plan_links WHERE plan_id=?",BigDecimal.class,replacement));
        amount("0",h.db.queryForObject("SELECT public_surplus_qty FROM production_material_analysis_plan_links WHERE plan_id=?",BigDecimal.class,replacement));
        assertTrue(h.ordinary.issueWorkshopPlans(c.analysis(),request).replayed());
        assertEquals(2L,h.db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Long.class,c.analysis()));
        amount("0",child(c).planningUncoveredQty());
    }

    @Test void actual1000From1000SuppliedMaterialCompletesTheTargetWithoutForcingTheUnsentBudget() {
        var c=h.createWithChildAndLoss("1000","0");
        UUID plan=issue(c,"1000").plans().getFirst().planId();produce(c,plan);
        h.db.update("UPDATE goods SET subcontract_allowed_loss_pct=10 WHERE id=?",c.common());
        UUID item=order(c,"10");
        refresh(c);amount("100",child(c).planningUncoveredQty());
        h.fixture.drawAndIssueSubcontract(item,null,"actual-target-draw-"+item);
        amount("1000",h.db.queryForObject("SELECT SUM(issued_qty) FROM subcontract_material_plan_items WHERE order_item_id=?",BigDecimal.class,item));
        receiveAndStock(c,item,"1000");
        var refreshed=refresh(c);
        amount("0",material(refreshed,c.common()).planningUncoveredQty());
        amount("0",material(refreshed,c.child()).requiredQty());
        amount("0",material(refreshed,c.child()).planningUncoveredQty());
        assertEquals(1L,h.db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Long.class,c.analysis()));
    }

    private GenerateResult issue(AggregateMaterialOrderEndToEndTest.Case c,String qty) {
        return h.ordinary.issueWorkshopPlans(c.analysis(),issueRequest(c,qty));
    }
    private IssueWorkshopPlansRequest issueRequest(AggregateMaterialOrderEndToEndTest.Case c,String qty) {
        var view=h.analyses.detail(c.analysis());MaterialView child=material(view,c.child());
        return new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"supply-plan-"+UUID.randomUUID(),c.world().warehouseId(),
                BusinessTime.today(),BusinessTime.today().plusDays(5),true,List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                child.materialLineId(),null,new BigDecimal(qty),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO)));
    }
    private void produce(AggregateMaterialOrderEndToEndTest.Case c,UUID plan) {
        BigDecimal raw=h.db.queryForObject("SELECT SUM(required_qty) FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,plan);
        h.receive(c,c.material(),raw.toPlainString());
        UUID segment=h.db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",UUID.class,plan);
        submitAndIssueDraw(segment);
        beans.getBean(ProductionExecutionSegmentService.class).start(plan,segment,new SegmentTransitionRequest(h.version(segment),"supply-start-"+segment));
        UUID planItem=h.db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",UUID.class,plan);
        UUID demand=h.db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,segment);
        var use=new DailyReportMaterialUsageLine();use.setDemandId(demand);use.setQtyBase(raw);
        BigDecimal output=h.db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,planItem);
        UUID report=h.fixture.reportAndApproveExecutionSegment(c.world(),planItem,null,c.child(),segment,null,output.toPlainString(),false,"0",null,null,List.of(use));
        for(UUID inbound:h.db.queryForList("SELECT id FROM stock_documents WHERE doc_type='FINISHED_IN' AND source_daily_report_id=? AND NOT is_deleted",UUID.class,report))
            h.fixture.confirmFinishedInboundFully(inbound);
        amount(output.toPlainString(),h.db.queryForObject("SELECT iqty FROM production_plan_items WHERE id=?",BigDecimal.class,planItem));
        // This context deliberately disables automatic inventory-value polling.
        // Warehouse confirmation persists real production-cost closure work;
        // consume it before the next department can issue the manufactured stock.
        Map<String,Object> before=productionValueState(c,segment);
        System.out.println("subcontract-supply-value BEFORE plan="+plan+" "+before);
        InventoryValueWorkTestSupport.drain(beans.getBean(InventoryValueWorkService.class),h.db,
                List.of(c.material(),c.child()));
        Map<String,Object> after=productionValueState(c,segment);
        System.out.println("subcontract-supply-value AFTER plan="+plan+" "+after);
        assertEquals("FINAL",after.get("state"),after::toString);
        assertEquals(Boolean.FALSE,after.get("business_refresh_pending"),after::toString);
        assertEquals(Boolean.FALSE,after.get("material_marked"),after::toString);
        assertEquals(Boolean.FALSE,after.get("child_marked"),after::toString);
    }

    private void submitAndIssueDraw(UUID segment) {
        var stock = beans.getBean(StockDocService.class);
        var draws = beans.getBean(ProductionDrawRequestService.class);
        var pick = new ProductionDrawRequest.Item(segment, h.version(segment));
        var preview = draws.preview(new ProductionDrawRequest.PreviewRequest(List.of(pick)));
        draws.submit(new ProductionDrawRequest.SubmitRequest(List.of(pick), "supply-draw-" + segment, preview.fingerprint()));
        for (UUID document : preview.lines().stream().map(ProductionDrawRequest.Line::drawId).distinct().toList()) {
            var request = new StockDocIssueRequest();
            request.setIdempotencyKey("supply-issue-" + document);
            request.setLines(preview.lines().stream().filter(line -> line.drawId().equals(document)).map(line -> {
                var issued = new StockDocIssueRequest.Line();
                issued.setItemId(line.drawItemId());
                issued.setQty(line.qty());
                return issued;
            }).toList());
            stock.approveAndIssue(document, request);
        }
    }
    private Map<String,Object> productionValueState(AggregateMaterialOrderEndToEndTest.Case c,UUID segment) {
        return h.db.queryForMap("""
                SELECT object.state,object.business_refresh_pending,
                       object.precision_closure_pending,object.precision_closure_complete,
                       fn_inventory_value_precision_marked(ARRAY[
                           fn_inventory_value_precision_key(CAST(? AS uuid),NULL::uuid)]) AS material_marked,
                       fn_inventory_value_precision_marked(ARRAY[
                           fn_inventory_value_precision_key(CAST(? AS uuid),NULL::uuid)]) AS child_marked
                FROM stock_value_production_cost_objects object
                WHERE object.execution_segment_id=fn_production_execution_cost_scope(?)
                """,c.material(),c.child(),segment);
    }
    private UUID order(AggregateMaterialOrderEndToEndTest.Case c,String loss) {
        return order(c,loss,"1000");
    }

    private UUID order(AggregateMaterialOrderEndToEndTest.Case c,String loss,String qty) {
        return orderSubcontractApplication(c, externalApplication(c, "SUBCONTRACT", qty, false, null), loss, qty);
    }

    private UUID externalApplication(AggregateMaterialOrderEndToEndTest.Case c, String route, String qty,
                                     boolean allowPublic, String receiptMode) {
        var input = h.input(c, c.common(), route, qty, allowPublic);
        assertEquals(1, input.materialLineIds().size());
        var group = receiptMode == null ? input : new GroupInput(input.clientGroupKey(), input.materialLineIds(), route, input.qty(), allowPublic,
                null, null, null, input.billDate(), input.deliveryDate(), null, null, BigDecimal.ZERO,
                Map.of(input.materialLineIds().getFirst(), input.qty()), null, null, null, receiptMode);
        var request = h.request(c, List.of(group));
        var preview = h.preview.preview(c.analysis(), request);
        var planned = preview.groups().getFirst();
        if (receiptMode != null) {
            BigDecimal parentQty = receiptMode.equals("PRIORITIZE_PARENT")
                    ? input.qty().min(new BigDecimal("1000")) : BigDecimal.ZERO;
            var source = planned.sources().getFirst();
            amount(parentQty.toPlainString(), source.allocatedQty());
            amount(parentQty.subtract(source.remainingQty()).max(BigDecimal.ZERO).toPlainString(), source.priorityQty());
            amount(input.qty().subtract(parentQty).toPlainString(), planned.publicExtraQty());
        }
        var command = h.submit(preview, request);
        var batch = h.writer.submit(c.analysis(), command).batches().getFirst();
        if (receiptMode != null) assertTrue(h.writer.submit(c.analysis(), command).replayed());
        String table = route.equals("BUY") ? "purchase_request_items" : "subcontract_application_items";
        String parentColumn = route.equals("BUY") ? "request_id" : "application_id";
        return h.db.queryForObject("SELECT id FROM " + table + " WHERE " + parentColumn + "=? AND NOT is_deleted",
                UUID.class, batch.documentId());
    }

    private UUID orderExternal(AggregateMaterialOrderEndToEndTest.Case c, String route, String qty, String receiptMode) {
        UUID application = externalApplication(c, route, qty, !"1000".equals(qty), receiptMode);
        if (route.equals("BUY")) return orderPurchaseApplication(c, application, qty);
        UUID item = orderSubcontractApplication(c, application, "0", qty);
        h.fixture.drawAndIssueSubcontract(item, new BigDecimal(qty), "independent-order-draw-" + item);
        return item;
    }

    private UUID orderPurchaseApplication(AggregateMaterialOrderEndToEndTest.Case c, UUID application, String qty) {
        var world = c.world();
        var request = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(h.fixture, "activeSettlementMethodId"));
        request.setBillDate(BusinessTime.today());
        request.setSupplierId(world.supplierId());
        request.setWarehouseId(world.warehouseId());
        request.setCurrencyId(world.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(c.common());
        line.setRequestItemId(application);
        line.setUnitId(world.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("50"));
        request.setItems(List.of(line));
        var orders = beans.getBean(com.uten.imp.features.purchase.order.PurchaseOrderService.class);
        orders.createBatch(request);
        UUID order = h.db.queryForObject("SELECT order_id FROM purchase_order_items WHERE request_item_id=? AND NOT is_deleted",
                UUID.class, application);
        UUID reviewer = h.fixture.createApprover(world);
        finance.submit("PURCHASE", order);
        h.fixture.loginAs(reviewer);
        h.fixture.approvePendingFinance("PURCHASE", order);
        h.fixture.loginAs(world.superAdminUserId());
        return h.db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=? AND NOT is_deleted", UUID.class, order);
    }

    private UUID orderSubcontractApplication(AggregateMaterialOrderEndToEndTest.Case c, UUID application, String loss, String qty) {
        var request=new OrderSaveRequest();request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(h.fixture,"activeSettlementMethodId"));
        request.setBillDate(BusinessTime.today());request.setSupplierId(c.world().supplierId());request.setWarehouseId(c.world().warehouseId());
        request.setCurrencyId(c.world().currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        var line=new OrderItemLine();line.setGoodsId(c.common());line.setApplicationItemId(application);line.setUnitId(c.world().unitId());
        line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(BigDecimal.ONE);line.setAllowedLossPct(new BigDecimal(loss));
        request.setItems(List.of(line));UUID order=h.fixture.createWithFullMaterialBudget(request).getId();
        UUID reviewer=ReflectionTestUtils.invokeMethod(h.fixture,"createApprover",c.world());finance.submit("SUBCONTRACT",order);
        h.fixture.loginAs(reviewer);h.fixture.approvePendingFinance("SUBCONTRACT",order);h.fixture.loginAs(c.world().superAdminUserId());
        return h.db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
    }
    private UUID receiveExternal(AggregateMaterialOrderEndToEndTest.Case c, String route, UUID item, String qty) {
        UUID receipt = route.equals("BUY")
                ? h.fixture.receiveAndPassPurchase(c.world(), item, c.common(), new BigDecimal(qty),
                "priority-receipt-" + item, BusinessTime.today())
                : receiveAndStock(c, item, qty);
        drainCosts(c);
        h.fixture.loginAs(c.world().superAdminUserId());
        return receipt;
    }

    private UUID receiveAndStock(AggregateMaterialOrderEndToEndTest.Case c,UUID item,String actual) {
        return receiveAndStock(c,item,actual,false);
    }

    private UUID receiveAndStock(AggregateMaterialOrderEndToEndTest.Case c,UUID item,String actual,boolean shortDelivery) {
        var received=arrivals.register(new WarehouseArrivalRegisterRequest("supply-receive-"+UUID.randomUUID(),"SUBCONTRACT",BusinessTime.today(),
                c.world().supplierId(),c.world().warehouseId(),null,c.world().employeeId(),null,List.of(new ArrivalLine(c.common(),new BigDecimal(actual),
                item,null,c.world().unitId(),BigDecimal.ONE,null,null)),null,shortDelivery ? true : null));
        assertEquals("SUBMITTED_FOR_INSPECTION",received.outcome());
        if (shortDelivery) {
            var losses = beans.getBean(SubcontractShortDeliveryService.class);
            UUID shortCase = h.db.queryForObject("""
                    SELECT id FROM subcontract_short_delivery_cases WHERE order_item_id=? AND closed_at IS NULL
                    """, UUID.class, item);
            losses.decide(shortCase,new DecisionRequest("WAIT_MORE",BusinessTime.today().plusDays(2),
                    "允许已到部分先验收入库",losses.detail(shortCase).row().version()));
        }
        var inbound=new SubcontractComponentReturnLegEndToEndTest();beans.autowireBean(inbound);ReflectionTestUtils.setField(inbound,"fixture",h.fixture);
        Object pass=ReflectionTestUtils.invokeMethod(inbound,"passIqc",received.receiptId(),"supply-iqc-"+UUID.randomUUID());
        UUID keeper=ReflectionTestUtils.invokeMethod(h.fixture,"createIqcWarehouseConfirmer",c.world(),"supply-keeper-"+UUID.randomUUID().toString().substring(0,8));
        ReflectionTestUtils.invokeMethod(inbound,"stockIn",keeper,received.receiptId(),pass,"supply-stock-"+UUID.randomUUID(),c.world());
        h.fixture.loginAs(c.world().superAdminUserId());
        return received.receiptId();
    }
    private AnalysisView refresh(AggregateMaterialOrderEndToEndTest.Case c) {
        var view=h.analyses.detail(c.analysis());
        return h.analyses.preview(new PreviewRequest(c.analysis(),view.version(),view.fingerprint(),c.world().warehouseId(),"supply-refresh-"+UUID.randomUUID(),
                view.products().stream().filter(row->"SALES_ORDER_ITEM".equals(row.sourceType())).map(row->new PreviewItem("SALES_ORDER_ITEM",row.salesOrderItemId(),
                        null,null,null,null,null,row.deliveryDate(),row.requestedQty())).toList()));
    }
    private MaterialView child(AggregateMaterialOrderEndToEndTest.Case c) { return material(h.analyses.detail(c.analysis()),c.child()); }
    private static MaterialView material(AnalysisView view,UUID goods) { return view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)).findFirst().orElseThrow(); }
}
