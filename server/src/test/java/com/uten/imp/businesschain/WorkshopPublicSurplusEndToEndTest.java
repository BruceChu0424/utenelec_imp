package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequestService;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentRouteConfirmRequest;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** The real 2000 planned / 1000 sales / 1000 public-stock workshop lifecycle. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WorkshopPublicSurplusEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionDrawRequestService drawRequests;
    @Autowired ProductionDailyReportService reports;
    @Autowired ReportablePlanLineQueryService reportable;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired StockDocService stock;
    FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void salesFirstThenPublicRemainderSurvivesSalesClosureAndReversesWithoutSalesMutation() {
        Case c = createStartedMixedTask();
        qty("2000", db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?", BigDecimal.class, c.segment()));
        qty("2000", db.queryForObject("SELECT fn_execution_material_output_capacity(?,TRUE)", BigDecimal.class, c.segment()));
        qty("1000", db.queryForObject("SELECT SUM(allocated_qty) FROM execution_segment_sales_allocations WHERE execution_segment_id=?", BigDecimal.class, c.segment()));

        ReportablePlanLine salesSource = sources(c).stream().filter(row -> c.orderItem().equals(row.orderItemId())).findFirst().orElseThrow();
        UUID salesReport = approveReport(c, salesSource);
        finishInbound(c, salesReport);
        assertSalesTotals(c);
        assertEquals("IN_PROGRESS", status(c));

        // Close the original order through a real shipment, leaving the original
        // workshop task open for its separate, explicitly approved public stock.
        UUID shipment = fixture.createShipment(c.world(), c.orderItem(), c.product(), "1000");
        fixture.shipThroughWarehouse(shipment);
        assertTrue(db.queryForObject("SELECT is_closed FROM sales_orders WHERE id=?", Boolean.class, c.order()));
        assertEquals(9, db.queryForObject("SELECT chain_status FROM sales_order_items WHERE id=?", Integer.class, c.orderItem()));

        List<ReportablePlanLine> remaining = sources(c);
        assertEquals(1, remaining.size(), "the remaining 50% must stay reportable after the sales source is exhausted and closed");
        ReportablePlanLine publicSource = remaining.getFirst();
        assertNull(publicSource.executionSegmentSalesAllocationId());
        assertNull(publicSource.orderItemId());
        assertNull(publicSource.orderNo());
        assertEquals(c.product(), publicSource.goodsId());
        assertEquals(c.workshop(), publicSource.departmentId());
        assertEquals(c.segment(), publicSource.executionSegmentId());
        qty("1000", publicSource.maxReportQty());
        UUID publicReport = approveReport(c, publicSource);
        assertSalesTotals(c);
        qty("2000", planQuantity(c, "fqty"));
        UUID publicInbound = finishInbound(c, publicReport);
        qty("2000", planQuantity(c, "iqty"));
        assertSalesTotals(c);
        assertEquals("COMPLETED", status(c));
        assertTrue(db.queryForObject("SELECT is_closed FROM production_plans WHERE id=?", Boolean.class, c.plan()));
        assertEquals(0, db.queryForObject("""
                SELECT COUNT(*) FROM stock_reservations
                WHERE source_doc_type='PRODUCTION_INBOUND' AND source_doc_id=?
                  AND NOT is_deleted AND owner_type IN ('SALES_ORDER_ITEM','PREPLAN_ANALYSIS')
                """, Integer.class, publicInbound), "public output must not become a reservation for the closed order or its analysis");
        qty("1000", db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?", BigDecimal.class, c.world().warehouseId(), c.product()));

        drainValuation(c);
        stock.reverseFinishedInbound(publicInbound);
        reports.reverse(publicReport);
        qty("1000", planQuantity(c, "fqty"));
        qty("1000", planQuantity(c, "iqty"));
        assertSalesTotals(c);
        assertEquals("IN_PROGRESS", status(c));
        assertFalse(db.queryForObject("SELECT is_closed FROM production_plans WHERE id=?", Boolean.class, c.plan()));
        assertTrue(db.queryForObject("SELECT is_closed FROM sales_orders WHERE id=?", Boolean.class, c.order()));
        qty("1000", sources(c).getFirst().maxReportQty());
    }

    @ParameterizedTest
    @ValueSource(strings = {"SALES_ONLY", "SALES_THEN_PUBLIC", "PUBLIC_THEN_SALES"})
    void repeatedPartialReportsPreserveSourceQuotasMaterialUsageAndReversals(String scenario) {
        boolean mixed = !"SALES_ONLY".equals(scenario);
        int salesTarget = mixed ? 1000 : 2000;
        String tag = switch (scenario) {
            case "SALES_ONLY" -> "wps-multi-sales";
            case "SALES_THEN_PUBLIC" -> "wps-multi-sales-public";
            default -> "wps-multi-public-sales";
        };
        Case c = createStartedTask(tag, mixed);
        List<Batch> batches = switch (scenario) {
            case "SALES_ONLY" -> List.of(new Batch(true, 500), new Batch(true, 700), new Batch(true, 800));
            case "SALES_THEN_PUBLIC" -> List.of(new Batch(true, 400), new Batch(true, 600), new Batch(false, 300), new Batch(false, 700));
            default -> List.of(new Batch(false, 300), new Batch(false, 700), new Batch(true, 400), new Batch(true, 600));
        };
        List<UUID> publicReports = new ArrayList<>();
        List<UUID> publicInbounds = new ArrayList<>();
        int salesReported = 0;
        int publicReported = 0;
        for (Batch batch : batches) {
            assertSourceRemainders(c, salesTarget, salesReported, publicReported);
            ReportablePlanLine source = sources(c).stream()
                    .filter(row -> batch.sales() == (row.orderItemId() != null))
                    .findFirst().orElseThrow();
            UUID report = approveReport(c, source, Integer.toString(batch.quantity()));
            UUID inbound = finishInbound(c, report);
            if (batch.sales()) {
                salesReported += batch.quantity();
            } else {
                publicReported += batch.quantity();
                publicReports.add(report);
                publicInbounds.add(inbound);
                assertEquals(0, db.queryForObject("""
                        SELECT COUNT(*) FROM stock_reservations
                        WHERE source_doc_type='PRODUCTION_INBOUND' AND source_doc_id=?
                          AND NOT is_deleted AND owner_type IN ('SALES_ORDER_ITEM','PREPLAN_ANALYSIS')
                        """, Integer.class, inbound));
            }
            int completed = salesReported + publicReported;
            qty(Integer.toString(completed), planQuantity(c, "fqty"));
            qty(Integer.toString(completed), planQuantity(c, "iqty"));
            qty(Integer.toString(completed), db.queryForObject(
                    "SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?", BigDecimal.class, c.demand()));
            assertSalesProgress(c, salesTarget, salesReported);
            assertEquals(completed == 2000 ? "COMPLETED" : "IN_PROGRESS", status(c));
            if (batch.sales() && salesReported == salesTarget) {
                UUID shipment = fixture.createShipment(c.world(), c.orderItem(), c.product(), Integer.toString(salesTarget));
                fixture.shipThroughWarehouse(shipment);
                assertTrue(db.queryForObject("SELECT is_closed FROM sales_orders WHERE id=?", Boolean.class, c.order()));
            }
        }
        assertEquals(1, db.queryForObject("SELECT COUNT(*) FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted", Integer.class, c.plan()));
        assertTrue(sources(c).isEmpty());
        assertTrue(db.queryForObject("SELECT is_closed FROM production_plans WHERE id=?", Boolean.class, c.plan()));
        if (mixed) {
            drainValuation(c);
            if ("PUBLIC_THEN_SALES".equals(scenario)) {
                // The older public receipt already precedes later finished
                // receipts and a real shipment. Source quotas stay separate,
                // but they cannot bypass the inventory cost chronology.
                UUID latestPublic = publicInbounds.getLast();
                ApiException blocked = assertThrows(ApiException.class,
                        () -> stock.reverseFinishedInbound(latestPublic));
                assertTrue(blocked.getMessage().contains("已有出库、使用或未撤回的后续入库"));
                qty("2000", planQuantity(c, "fqty"));
                qty("2000", planQuantity(c, "iqty"));
                qty("2000", db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?", BigDecimal.class, c.demand()));
                assertSalesProgress(c, salesTarget, salesTarget);
                assertEquals("COMPLETED", status(c));
                assertTrue(db.queryForObject("SELECT is_closed FROM sales_orders WHERE id=?", Boolean.class, c.order()));
                assertEquals(1, db.queryForObject("SELECT status FROM stock_documents WHERE id=?", Integer.class, latestPublic));
                assertEquals(1, db.queryForObject("SELECT status FROM production_daily_reports WHERE id=?", Integer.class, publicReports.getLast()));
                qty("1000", db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?", BigDecimal.class, c.world().warehouseId(), c.product()));
                return;
            }
            for (int index = publicInbounds.size() - 1; index >= 0; index--) {
                stock.reverseFinishedInbound(publicInbounds.get(index));
                reports.reverse(publicReports.get(index));
                assertSalesProgress(c, salesTarget, salesTarget);
                // Each reversal changes the remaining output cost shares.
                // Finish that durable work before reversing the next receipt.
                drainValuation(c);
            }
            qty("1000", planQuantity(c, "fqty"));
            qty("1000", planQuantity(c, "iqty"));
            qty("1000", db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?", BigDecimal.class, c.demand()));
            assertEquals("IN_PROGRESS", status(c));
            assertTrue(db.queryForObject("SELECT is_closed FROM sales_orders WHERE id=?", Boolean.class, c.order()));
            assertSourceRemainders(c, salesTarget, salesTarget, 0);
        }
    }

    private void assertSourceRemainders(Case c, int salesTarget, int salesReported, int publicReported) {
        List<ReportablePlanLine> available = sources(c);
        int salesRemaining = salesTarget - salesReported;
        int publicRemaining = 2000 - salesTarget - publicReported;
        assertEquals((salesRemaining > 0 ? 1 : 0) + (publicRemaining > 0 ? 1 : 0), available.size());
        for (ReportablePlanLine source : available) {
            assertEquals(c.product(), source.goodsId());
            assertEquals(c.workshop(), source.departmentId());
            assertEquals(c.segment(), source.executionSegmentId());
            assertEquals(c.planItem(), source.planItemId());
            if (source.orderItemId() == null) {
                assertNull(source.executionSegmentSalesAllocationId());
                assertNull(source.orderNo());
                assertNull(source.clientName());
                qty(Integer.toString(publicRemaining), source.maxReportQty());
            } else {
                assertEquals(c.orderItem(), source.orderItemId());
                assertNotNull(source.executionSegmentSalesAllocationId());
                qty(Integer.toString(salesRemaining), source.maxReportQty());
            }
        }
    }

    private Case createStartedMixedTask() {
        return createStartedTask("workshop-public-surplus", true);
    }

    private Case createStartedTask(String tag, boolean mixed) {
        var world = fixture.seedWorld(tag);
        fixture.loginAs(world.superAdminUserId());
        UUID product = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        fixture.insertGoods(product, "WPS-P-" + product, "持续生产公共备货成品", "自制", world.unitId(), world.unitLegacy());
        fixture.insertGoods(material, "WPS-M-" + material, "持续生产原料", "采购", world.unitId(), world.unitLegacy());
        fixture.insertBom(product, material, "1");
        Object assignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment", tag);
        UUID workshop = ReflectionTestUtils.invokeMethod(assignment, "workshopId");
        UUID worker = ReflectionTestUtils.invokeMethod(assignment, "workerId");
        String salesQuantity = mixed ? "1000" : "2000";
        UUID order = fixture.createApprovedOrder(world, product, salesQuantity, "100");
        UUID orderItem = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, order);
        var view = analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(), "wps-preview-" + order,
                List.of(new PreviewItem("SALES_ORDER_ITEM", orderItem, null, null, null, null, null, BusinessTime.today().plusDays(10), new BigDecimal(salesQuantity)))));
        analyses.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(), "wps-routes-" + order,
                view.flatMaterials().stream().filter(MaterialView::actionable).map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(), row.goodsId().equals(product) ? "MAKE" : "BUY", null)).toList()));
        view = analyses.detail(view.analysisId());
        UUID rootItem = view.products().getFirst().analysisLineId();
        var initial = commands.issueWorkshopPlans(view.analysisId(), issue(view, rootItem, world.warehouseId(), workshop, worker, false, salesQuantity));
        UUID plan = initial.plans().getFirst().planId();
        if (mixed) {
            view = analyses.detail(view.analysisId());
            var appended = commands.issueWorkshopPlans(view.analysisId(), issue(view, rootItem, world.warehouseId(), workshop, worker, true, "1000"));
            assertTrue(appended.plans().getFirst().mergedIntoExisting());
            assertEquals(plan, appended.plans().getFirst().planId());
        }
        UUID segment = db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted", UUID.class, plan);
        UUID planItem = db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?", UUID.class, segment);
        UUID demand = db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted", UUID.class, segment);
        Case c = new Case(world, product, material, order, orderItem, plan, planItem, segment, demand, workshop, worker);
        segments.confirmRoute(plan, segment, new SegmentRouteConfirmRequest(version(segment), "wps-route-" + segment, "CONTINUOUS"));
        receiveMaterial(c);
        var tasks = List.of(new ProductionDrawRequest.Item(segment, version(segment)));
        var preview = drawRequests.preview(new ProductionDrawRequest.PreviewRequest(tasks));
        assertFalse(preview.lines().isEmpty());
        drawRequests.submit(new ProductionDrawRequest.SubmitRequest(tasks, "wps-draw-" + segment, preview.fingerprint()));
        for (UUID documentId : preview.lines().stream().map(ProductionDrawRequest.Line::drawId).distinct().toList()) {
            var request = new StockDocIssueRequest();
            request.setIdempotencyKey("wps-issue-" + documentId);
            request.setLines(preview.lines().stream().filter(line -> documentId.equals(line.drawId())).map(line -> {
                var item = new StockDocIssueRequest.Line();
                item.setItemId(line.drawItemId()); item.setQty(line.qty()); return item;
            }).toList());
            stock.approveAndIssue(documentId, request);
        }
        segments.start(plan, segment, new SegmentTransitionRequest(version(segment), "wps-start-" + segment));
        return c;
    }

    private IssueWorkshopPlansRequest issue(AnalysisView view, UUID rootItem, UUID warehouse, UUID workshop, UUID worker, boolean surplus, String quantity) {
        return new IssueWorkshopPlansRequest(view.version(), view.fingerprint(), "wps-plan-" + UUID.randomUUID(), warehouse,
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null, rootItem, new BigDecimal(quantity), null, null, workshop, null, worker, null, null, surplus)));
    }

    private void receiveMaterial(Case c) {
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN"); request.setWarehouseId(c.world().warehouseId()); request.setBillDate(BusinessTime.today());
        var line = new StockDocItemLine();
        line.setGoodsId(c.material()); line.setUnitId(c.world().unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("2000")); line.setPrice(BigDecimal.TEN);
        line.setAmountOriginal(new BigDecimal("20000")); line.setAmountLocal(new BigDecimal("20000"));
        request.setItems(List.of(line)); stock.approve(stock.create(request).getId());
    }

    private UUID approveReport(Case c, ReportablePlanLine source) {
        return approveReport(c, source, "1000");
    }

    private UUID approveReport(Case c, ReportablePlanLine source, String quantity) {
        var request = new DailyReportSaveRequest();
        request.setIdempotencyKey("wps-report-" + UUID.randomUUID()); request.setBillDate(BusinessTime.today());
        request.setDepartmentId(c.workshop()); request.setWorkerIds(List.of(c.worker()));
        var line = new DailyReportItemLine();
        line.setLineNo(1); line.setPlanItemId(c.planItem()); line.setExecutionSegmentId(c.segment());
        line.setExecutionSegmentSalesAllocationId(source.executionSegmentSalesAllocationId()); line.setSalesOrderItemId(source.orderItemId());
        line.setGoodsId(c.product()); line.setUnitId(c.world().unitId()); line.setUnitRate(BigDecimal.ONE); line.setQty(new BigDecimal(quantity));
        request.setItems(List.of(line));
        var usage = new DailyReportMaterialUsageLine(); usage.setDemandId(c.demand()); usage.setQtyBase(new BigDecimal(quantity));
        request.setMaterialLines(List.of(usage));
        return reports.approve(reports.create(request).getId(), DailyReportApproveRequests.freshKey()).getId();
    }

    private UUID finishInbound(Case c, UUID reportId) {
        UUID reportItem = db.queryForObject("SELECT id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted", UUID.class, reportId);
        arrivals.register(reportId, new ArrivalRegistrationRequest("wps-arrival-" + reportId, c.world().warehouseId(),
                List.of(new ArrivalRegistrationItemRequest(reportItem, "真实生产完工入库")), null));
        UUID inspection = db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?", UUID.class, reportItem);
        BigDecimal quantity = db.queryForObject("SELECT qty FROM production_daily_report_items WHERE id=?", BigDecimal.class, reportItem);
        quality.decide(inspection, new DecisionRequest("PASS", quantity, null, null, null, "wps-pass-" + reportId));
        UUID inbound = db.queryForObject("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted", UUID.class, reportId);
        fixture.confirmFinishedInboundFully(inbound);
        return inbound;
    }

    private List<ReportablePlanLine> sources(Case c) {
        return reportable.list(1, 50, null, c.workshop(), List.of(c.segment())).getItems();
    }

    private void assertSalesTotals(Case c) {
        assertSalesProgress(c, 1000, 1000);
    }

    private void assertSalesProgress(Case c, int allocated, int completed) {
        var link = db.queryForMap("SELECT allocated_qty,produced_qty,inbound_qty FROM plan_order_item_links WHERE plan_item_id=? AND NOT is_deleted", c.planItem());
        qty(Integer.toString(allocated), (BigDecimal) link.get("allocated_qty"));
        for (String field : List.of("produced_qty", "inbound_qty")) qty(Integer.toString(completed), (BigDecimal) link.get(field));
        qty(Integer.toString(completed), db.queryForObject("SELECT produced_qty FROM sales_order_items WHERE id=?", BigDecimal.class, c.orderItem()));
    }

    private void drainValuation(Case c) {
        var context = SecurityContextHolder.getContext();
        SecurityContextHolder.clearContext();
        try { InventoryValueWorkTestSupport.drain(beans.getBean(InventoryValueWorkService.class), db, List.of(c.product(), c.material())); }
        finally { SecurityContextHolder.setContext(context); }
    }

    private Long version(UUID segment) { return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, segment); }
    private String status(Case c) { return db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?", String.class, c.segment()); }
    private BigDecimal planQuantity(Case c, String field) { return db.queryForObject("SELECT " + field + " FROM production_plan_items WHERE id=?", BigDecimal.class, c.planItem()); }
    private static void qty(String expected, BigDecimal actual) { assertNotNull(actual); assertEquals(0, new BigDecimal(expected).compareTo(actual), "expected " + expected + " but was " + actual); }
    private record Case(FullChainEndToEndTest.World world, UUID product, UUID material, UUID order, UUID orderItem, UUID plan, UUID planItem, UUID segment, UUID demand, UUID workshop, UUID worker) {}
    private record Batch(boolean sales, int quantity) {}
}
