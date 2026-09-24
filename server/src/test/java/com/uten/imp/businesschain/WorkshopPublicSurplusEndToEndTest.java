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
    @Autowired com.uten.imp.features.production.dailyreport.ActualOutputSupplementService supplements;
    @Autowired com.uten.imp.features.production.plan.ProductionPlanService productionPlans;
    @Autowired com.uten.imp.features.production.execution.ProductionOverproductionRateService productionRates;
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

    @Test
    void actualOverproductionUsesActualMaterialsAndPublicShortReceiptsNeverCompleteTheSalesDemand() {
        Case c = createStartedTask("wps-actual-short-receipt", false);
        approveRate(c,"0.25");
        UUID report = approveReport(c, sources(c).getFirst(), "2300", "2000");
        qty("2000", planQuantity(c, "qty"));
        qty("2300", planQuantity(c, "fqty"));
        qty("2000", db.queryForObject("SELECT produced_qty FROM plan_order_item_links WHERE plan_item_id=? AND NOT is_deleted", BigDecimal.class, c.planItem()));
        qty("0", db.queryForObject("SELECT produced_qty FROM sales_order_items WHERE id=?", BigDecimal.class, c.orderItem()));
        qty("2000", db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?", BigDecimal.class, c.demand()));
        var output = db.queryForList("""
                SELECT id,qty,is_actual_surplus,is_public_output,output_batch_id,output_batch_qty,
                       execution_segment_sales_allocation_id,sales_order_item_id,destination
                FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted
                ORDER BY is_actual_surplus
                """, report);
        assertEquals(2, output.size());
        UUID demandItem = (UUID) output.getFirst().get("id");
        UUID publicItem = (UUID) output.getLast().get("id");
        qty("2000", (BigDecimal) output.getFirst().get("qty"));
        qty("300", (BigDecimal) output.getLast().get("qty"));
        assertEquals(output.getFirst().get("output_batch_id"), output.getLast().get("output_batch_id"));
        qty("2300", (BigDecimal) output.getLast().get("output_batch_qty"));
        assertEquals(true, output.getLast().get("is_public_output"));
        assertNull(output.getLast().get("sales_order_item_id"));
        assertNull(output.getLast().get("execution_segment_sales_allocation_id"));
        assertEquals("WAREHOUSE", output.getLast().get("destination"));

        arrivals.register(report, new ArrivalRegistrationRequest("actual-arrival-" + report,
                c.world().warehouseId(), List.of(new ArrivalRegistrationItemRequest(demandItem, "需求成品"),
                new ArrivalRegistrationItemRequest(publicItem, "公共超产")), null));
        UUID publicInbound = releaseOutputItem(publicItem, "300");
        qty("0", planQuantity(c, "iqty"));
        UUID residual = ReflectionTestUtils.invokeMethod(fixture, "confirmFinishedInboundPartially",
                publicInbound, new BigDecimal("100"), "本次实际到货100，余量200继续交接");
        qty("100", planQuantity(c, "iqty"));
        assertPlannedReceipt(c, "0", "100");
        assertEquals("IN_PROGRESS", status(c));
        fixture.confirmFinishedInboundFully(residual);
        assertPlannedReceipt(c, "0", "300");
        qty("0", db.queryForObject("SELECT inbound_qty FROM plan_order_item_links WHERE plan_item_id=? AND NOT is_deleted", BigDecimal.class, c.planItem()));
        qty("0", db.queryForObject("SELECT root_progress_ratio FROM v_production_execution_workbench_roots WHERE root_type='ANALYSIS' AND root_id=(SELECT material_analysis_id FROM production_plans WHERE id=?)", BigDecimal.class, c.plan()));

        UUID demandInbound = releaseOutputItem(demandItem, "2000");
        fixture.confirmFinishedInboundFully(demandInbound);
        qty("2300", planQuantity(c, "iqty"));
        qty("2000", planQuantity(c, "qty"));
        assertSalesProgress(c, 2000, 2000);
        assertPlannedReceipt(c, "2000", "300");
        assertEquals(0, db.queryForObject("""
                SELECT COUNT(*) FROM stock_reservations
                WHERE source_doc_type='PRODUCTION_INBOUND' AND source_doc_id IN (?,?)
                  AND NOT is_deleted AND owner_type IN ('SALES_ORDER_ITEM','PREPLAN_ANALYSIS')
                """, Integer.class, publicInbound, residual));
        qty("2300", db.queryForObject("SELECT fn_production_execution_cost_target(fn_production_execution_cost_scope(?))", BigDecimal.class, c.segment()));
        drainValuation(c);
        stock.reverseFinishedInbound(demandInbound);
        drainValuation(c);
        stock.reverseFinishedInbound(residual);
        drainValuation(c);
        stock.reverseFinishedInbound(publicInbound);
        drainValuation(c);
        reports.reverse(report);
        qty("0", planQuantity(c, "fqty"));
        qty("0", planQuantity(c, "iqty"));
        qty("2000", planQuantity(c, "qty"));
        assertSalesProgress(c, 2000, 0);
        qty("2000", db.queryForObject("SELECT fn_production_execution_cost_target(fn_production_execution_cost_scope(?))", BigDecimal.class, c.segment()));
    }

    private void assertPlannedReceipt(Case c, String planned, String surplus) {
        var progress = db.queryForMap("""
                SELECT planned_inbound_qty,actual_surplus_inbound_qty
                FROM v_production_execution_workbench_segments WHERE segment_id=?
                """, c.segment());
        qty(planned, (BigDecimal) progress.get("planned_inbound_qty"));
        qty(surplus, (BigDecimal) progress.get("actual_surplus_inbound_qty"));
    }

    private UUID releaseOutputItem(UUID reportItem, String quantity) {
        UUID inspection = db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?", UUID.class, reportItem);
        quality.decide(inspection, new DecisionRequest("PASS", new BigDecimal(quantity), null, null, null, "actual-pass-" + reportItem));
        return db.queryForObject("""
                SELECT document.id FROM stock_documents document JOIN stock_document_items item ON item.doc_id=document.id
                WHERE item.source_daily_report_item_id=? AND NOT item.is_deleted AND NOT document.is_deleted
                  AND document.doc_type='FINISHED_IN' AND document.status=0
                """, UUID.class, reportItem);
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

    @Test
    void actualPublicRecoveryReworkRetainsPublicOwnershipWithoutExpandingProductionTarget() {
        Case c=createStartedTask("wps-actual-rework",false);
        approveRate(c,"0.25");
        UUID original=approveReport(c,sources(c).getFirst(),"2300","2000");
        var rows=reports.detail(original).getItems();
        var normal=rows.stream().filter(row->!row.isActualSurplus()).findFirst().orElseThrow();
        var surplus=rows.stream().filter(row->row.isActualSurplus()).findFirst().orElseThrow();
        arrivals.register(original,new ArrivalRegistrationRequest("actual-rework-arrival-"+original,c.world().warehouseId(),
                List.of(new ArrivalRegistrationItemRequest(normal.getId(),"需求成品"),new ArrivalRegistrationItemRequest(surplus.getId(),"公共超产")),null));
        fixture.confirmFinishedInboundFully(releaseOutputItem(normal.getId(),"2000"));
        UUID inspection=db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?",UUID.class,surplus.getId());
        quality.decide(inspection,new DecisionRequest("PARTIAL",new BigDecimal("250"),new BigDecimal("50"),"REWORK","公共超产返工50","actual-rework-fail-"+inspection));
        UUID receipt=db.queryForObject("SELECT doc_id FROM stock_document_items WHERE source_daily_report_item_id=? AND NOT is_deleted",UUID.class,surplus.getId());
        fixture.confirmFinishedInboundFully(receipt);
        ReportablePlanLine recovery=sources(c).stream().filter(row->row.fqcRecoveryAuthorizationId()!=null).findFirst().orElseThrow();
        assertFalse(recovery.allowActualOverproduction());assertNull(recovery.orderItemId());
        qty("50",recovery.maxReportQty());
        UUID replacement=approveReport(c,recovery,"50","0");
        var replacementItem=reports.detail(replacement).getItems().getFirst();
        assertTrue(replacementItem.isPublicOutput());assertTrue(replacementItem.isActualSurplus());
        assertEquals(recovery.fqcRecoveryAuthorizationId(),replacementItem.getFqcRecoveryAuthorizationId());
        finishInbound(c,replacement);
        qty("2000",planQuantity(c,"qty"));qty("2300",planQuantity(c,"fqty"));qty("2300",planQuantity(c,"iqty"));
        assertSalesProgress(c,2000,2000);assertEquals("COMPLETED",status(c));
        qty("300",db.queryForObject("SELECT fn_execution_actual_surplus_qty(?,FALSE)",BigDecimal.class,c.segment()));
        qty("2300",db.queryForObject("SELECT fn_production_execution_cost_target(?)",BigDecimal.class,c.segment()));
        qty("2000",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,c.demand()));
    }

    @Test
    void actualPublicRecoveryRejectsZeroMaterialAndDoesNotReclassifyAnotherDraftsDemand() {
        Case c=createStartedTask("wps-actual-draft-material",false);
        approveRate(c,"0.25");
        ReportablePlanLine source=sources(c).getFirst();
        assertThrows(ApiException.class,()->reports.create(reportRequest(c,source,"2300","0")));
        UUID draft=reports.create(reportRequest(c,source,"1800","1800")).getId();
        ApiException reserved=assertThrows(ApiException.class,()->reports.create(reportRequest(c,source,"300","300")));
        assertTrue(reserved.getMessage().contains("其他未审核日报占用"));
        qty("0",planQuantity(c,"fqty"));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_items WHERE execution_segment_id=? AND is_actual_surplus AND NOT is_deleted",Integer.class,c.segment()));
        reports.delete(draft);
        UUID actual=approveReport(c,source,"2300","2000");
        assertEquals(2,reports.detail(actual).getItems().size());
        qty("2300",planQuantity(c,"fqty"));
    }

    @Test
    void actualYieldAbovePlanSplitsSalesPlannedPublicAndActualPublicWithoutInventingMaterial() {
        Case c=createStartedTask("actual-output-three-slices",true);
        approveRate(c,"0.25");
        ReportablePlanLine source=sources(c).stream().filter(row->row.orderItemId()!=null).findFirst().orElseThrow();
        assertTrue(source.allowActualOverproduction());
        UUID report=approveReport(c,source,"2400","2000");
        var slices=reports.detail(report).getItems();
        assertEquals(3,slices.size());
        assertEquals(1,slices.stream().map(row->row.getOutputBatchId()).distinct().count());
        for(var row:slices)qty("2400",row.getOutputBatchQty());
        qty("1000",slices.get(0).getQty());assertFalse(slices.get(0).isPublicOutput());
        qty("1000",slices.get(1).getQty());assertTrue(slices.get(1).isPublicOutput());assertFalse(slices.get(1).isActualSurplus());
        qty("400",slices.get(2).getQty());assertTrue(slices.get(2).isActualSurplus());
        for(var row:slices.subList(1,3)) {
            assertNull(row.getSalesOrderItemId());assertNull(row.getExecutionSegmentSalesAllocationId());
            assertEquals("WAREHOUSE",row.getDestination());
        }
        qty("2000",planQuantity(c,"qty"));qty("2400",planQuantity(c,"fqty"));
        qty("2000",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,c.demand()));
        for(var row:slices) {
            arrivals.register(report,new ArrivalRegistrationRequest("actual-arrival-"+row.getId(),c.world().warehouseId(),
                    List.of(new ArrivalRegistrationItemRequest(row.getId(),"实际产量逐份点收")),null));
            UUID inspection=db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?",UUID.class,row.getId());
            quality.decide(inspection,new DecisionRequest("PASS",row.getQty(),null,null,null,"actual-pass-"+row.getId()));
            UUID inbound=db.queryForObject("SELECT doc_id FROM stock_document_items WHERE source_daily_report_item_id=? AND NOT is_deleted",UUID.class,row.getId());
            fixture.confirmFinishedInboundFully(inbound);
            if(row.isPublicOutput())assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM stock_reservations WHERE source_doc_type='PRODUCTION_INBOUND' AND source_doc_id=? AND NOT is_deleted",Integer.class,inbound));
            if(!row.isActualSurplus())assertEquals("IN_PROGRESS",status(c));
        }
        qty("2400",planQuantity(c,"iqty"));assertEquals("COMPLETED",status(c));assertSalesTotals(c);
        qty("2400",db.queryForObject("SELECT fn_production_execution_cost_target(?)",BigDecimal.class,c.segment()));
        drainValuation(c);
        assertNotEquals("PENDING_BASIS",db.queryForObject("SELECT state FROM stock_value_production_cost_objects WHERE execution_segment_id=?",String.class,c.segment()));
        var revision=db.queryForMap("""
                SELECT revision.target_qty_base,revision.output_qty_base FROM stock_value_production_cost_objects object
                JOIN stock_value_production_cost_revisions revision ON revision.id=object.current_revision_id
                WHERE object.execution_segment_id=?
                """,c.segment());
        qty("2400",(BigDecimal)revision.get("target_qty_base"));qty("2400",(BigDecimal)revision.get("output_qty_base"));
        var cost=beans.getBean(com.uten.imp.application.port.InventoryProductionCostPort.class).position(c.segment());
        qty("20000",cost.actualKnownCostLocal());qty("20000",cost.allocatedToOutputsLocal());
        qty("0",cost.heldWipLocal());qty("0",cost.pendingReallocationLocal());
    }

    @Test
    void ordinaryRemainingOutputConvertsPreviouslyApprovedWipWithoutConsumingMaterialTwice() {
        Case c=createStartedTask("wps-approved-wip",false,"1000");
        var source=sources(c).getFirst();
        assertThrows(ApiException.class,()->reports.create(reportRequest(c,source,"500","0")));
        UUID first=approveReport(c,source,"500","1000");finishInbound(c,first);drainValuation(c);
        qty("1000",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,c.demand()));
        var costBefore=beans.getBean(com.uten.imp.application.port.InventoryProductionCostPort.class).position(c.segment());
        qty("5000",costBefore.heldWipLocal());
        UUID second=approveReport(c,sources(c).getFirst(),"500","0");finishInbound(c,second);drainValuation(c);
        qty("1000",planQuantity(c,"fqty"));qty("1000",planQuantity(c,"iqty"));
        qty("1000",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,c.demand()));
        var cost=beans.getBean(com.uten.imp.application.port.InventoryProductionCostPort.class).position(c.segment());
        qty("10000",cost.actualKnownCostLocal());qty("10000",cost.allocatedToOutputsLocal());qty("0",cost.heldWipLocal());

        Case reversed=createStartedTask("wps-reversed-wip",false,"1000");
        var originalSource=sources(reversed).getFirst();UUID original=approveReport(reversed,originalSource,"500","1000");
        reports.reverse(original);
        assertThrows(ApiException.class,()->reports.create(reportRequest(reversed,originalSource,"500","0")),
                "a cancelled consumption/report cannot become a perpetual zero-use reporting permission");
    }

    @Test
    void actualSupplementDefaultTenPercentKeepsOriginal100AndCreatesReviewed30WithOneMaterialPosting() {
        Case c=createStartedTask("wps-supplement-100-30",false,"100");
        var source=sources(c).getFirst();
        qty("0.10",source.allowedOverproductionRate());
        var request=reportRequest(c,source,"130","100");
        ApiException over=assertThrows(ApiException.class,()->reports.create(request));
        assertTrue(over.getMessage().contains("追加计划"));qty("130",request.getItems().getFirst().getQty());
        var preview=supplements.previewReport(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.ReportPreviewRequest(request,null));
        assertTrue(preview.requiresSupplements());var line=preview.lines().getFirst();
        qty("100",line.originalReportQty());qty("30",line.supplementQty());
        var created=supplements.create(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.CreateRequest(
                c.segment(),new BigDecimal("130"),source.executionSegmentSalesAllocationId(),line.fingerprint(),BusinessTime.today(),BusinessTime.today().plusDays(1),
                "实际130，原任务100，追加公共30","supplement-create-"+UUID.randomUUID(),null,request,0));
        assertEquals("DRAFT",created.status());qty("100",planQuantity(c,"qty"));qty("0",planQuantity(c,"fqty"));
        productionPlans.approve(created.planId());
        var approved=supplements.detail(created.id());assertEquals("APPROVED",approved.status());assertEquals("READY",approved.supplementSegmentStatus());
        assertNotNull(approved.proofId());assertNotNull(approved.reportContext());assertEquals(c.segment(),approved.sourceLine().executionSegmentId());
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,approved.supplementSegmentId()));
        request.getItems().getFirst().setSupplementProofId(approved.proofId());
        assertThrows(ApiException.class,()->reports.create(request));
        segments.start(approved.planId(),approved.supplementSegmentId(),new SegmentTransitionRequest(approved.supplementSegmentVersion(),"supplement-start-"+approved.id()));
        var draft=reports.create(request);assertEquals(2,draft.getItems().size());
        assertTrue(draft.getItems().stream().allMatch(item->approved.proofId().equals(item.getSupplementProofId())));
        assertEquals(1,draft.getItems().stream().map(item->item.getOutputBatchId()).distinct().count());
        for(var item:draft.getItems()){qty("130",item.getOutputBatchQty());assertEquals(c.segment(),item.getOutputSourceExecutionSegmentId());}
        request.setExpectedVersion(draft.getRowVersion());request.setRemark("草稿复核用料90");request.getMaterialLines().getFirst().setQtyBase(new BigDecimal("90"));
        var edited=reports.update(draft.getId(),request);
        qty("90",edited.getMaterialUsages().getFirst().getQtyBase());
        request.setExpectedVersion(edited.getRowVersion());request.setRemark("再次核实本批实际用料100");request.getMaterialLines().getFirst().setQtyBase(new BigDecimal("100"));
        reports.update(draft.getId(),request);
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_actual_output_supplement_claims WHERE proof_id=? AND event_type='CLAIM'",Integer.class,approved.proofId()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_actual_output_supplement_claims WHERE proof_id=? AND event_type='RELEASE'",Integer.class,approved.proofId()));
        var command=DailyReportApproveRequests.freshKey();var report=reports.approve(draft.getId(),command);reports.approve(draft.getId(),command);
        qty("100",planQuantity(c,"fqty"));
        UUID childItem=db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,approved.supplementSegmentId());
        qty("30",db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=?",BigDecimal.class,childItem));
        qty("100",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,c.demand()));
        for(var item:report.getItems()) {
            arrivals.register(report.getId(),new ArrivalRegistrationRequest("supplement-arrival-"+item.getId(),c.world().warehouseId(),List.of(new ArrivalRegistrationItemRequest(item.getId(),"实际分账入库")),null));
            fixture.confirmFinishedInboundFully(releaseOutputItem(item.getId(),item.getQty().toPlainString()));
        }
        qty("100",planQuantity(c,"iqty"));qty("30",db.queryForObject("SELECT iqty FROM production_plan_items WHERE id=?",BigDecimal.class,childItem));
        qty("130",db.queryForObject("SELECT fn_production_execution_cost_target(?)",BigDecimal.class,c.segment()));
        drainValuation(c);
        var cost=beans.getBean(com.uten.imp.application.port.InventoryProductionCostPort.class).position(c.segment());
        qty("1000",cost.actualKnownCostLocal());qty("1000",cost.allocatedToOutputsLocal());
        assertEquals("COMPLETED",status(c));
        assertEquals("COMPLETED",db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,approved.supplementSegmentId()));
    }

    private Case createStartedTask(String tag, boolean mixed) {
        return createStartedTask(tag,mixed,"2000");
    }

    @Test
    void actualSupplementWholeFormSharesTheMarginAndRecoversOnlyTheFailedSupplementSlice() {
        Case c=createStartedTask("wps-supplement-multi-recovery",false,"100");
        var source=sources(c).getFirst();var request=reportRequest(c,source,"110","100");
        var second=reportRequest(c,source,"20","0").getItems().getFirst();second.setLineNo(2);
        request.setItems(List.of(request.getItems().getFirst(),second));
        var preview=supplements.previewReport(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.ReportPreviewRequest(request,null));
        assertTrue(preview.lines().stream().allMatch(row->row.requiresSupplement()),"one shared margin cannot be spent independently by each input row");
        qty("100",preview.lines().getFirst().originalReportQty());qty("10",preview.lines().getFirst().supplementQty());
        qty("0",preview.lines().getLast().originalReportQty());qty("20",preview.lines().getLast().supplementQty());
        var requested=new ArrayList<com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.View>();
        for(var row:preview.lines()) {
            var command=new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.CreateRequest(
                    c.segment(),row.actualQty(),source.executionSegmentSalesAllocationId(),row.fingerprint(),BusinessTime.today(),BusinessTime.today().plusDays(1),
                    "同一日报逐行申请","supplement-multi-"+UUID.randomUUID(),null,request,row.inputLineIndex());
            var created=supplements.create(command);requested.add(created);
            var retry=new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.CreateRequest(
                    command.sourceExecutionSegmentId(),command.actualQty(),command.sourceSalesAllocationId(),command.fingerprint(),command.billDate(),command.deliveryDate(),
                    command.remark(),"changed-command-"+UUID.randomUUID(),null,request,row.inputLineIndex());
            assertEquals(created.id(),supplements.create(retry).id(),"a second command key cannot create another plan for the same captured physical input");
        }
        for(var created:requested)productionPlans.approve(created.planId());
        var approved=requested.stream().map(view->supplements.detail(view.id())).toList();
        assertEquals(2,approved.getFirst().relatedSupplements().size());assertEquals(2,approved.getFirst().inputSources().size());
        for(int index=0;index<approved.size();index++) {
            var target=approved.get(index);request.getItems().get(index).setSupplementProofId(target.proofId());
            segments.start(target.planId(),target.supplementSegmentId(),new SegmentTransitionRequest(target.supplementSegmentVersion(),"multi-start-"+target.id()));
        }
        var report=reports.approve(reports.create(request).getId(),DailyReportApproveRequests.freshKey());
        assertEquals(3,report.getItems().size());
        for(var item:report.getItems()) {
            arrivals.register(report.getId(),new ArrivalRegistrationRequest("multi-arrival-"+item.getId(),c.world().warehouseId(),List.of(new ArrivalRegistrationItemRequest(item.getId(),"同表真实产出")),null));
            if(item.getExecutionSegmentId().equals(approved.getLast().supplementSegmentId())) {
                UUID inspection=db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?",UUID.class,item.getId());
                quality.decide(inspection,new DecisionRequest("PARTIAL",new BigDecimal("15"),new BigDecimal("5"),"REWORK","本追加份返工5","supplement-rework-"+inspection));
                UUID inbound=db.queryForObject("SELECT doc_id FROM stock_document_items WHERE source_daily_report_item_id=? AND NOT is_deleted",UUID.class,item.getId());
                fixture.confirmFinishedInboundFully(inbound);
            } else fixture.confirmFinishedInboundFully(releaseOutputItem(item.getId(),item.getQty().toPlainString()));
        }
        var target=approved.getLast();
        var recovery=reportable.list(1,50,null,c.workshop(),List.of(target.supplementSegmentId())).getItems().stream()
                .filter(row->row.fqcRecoveryAuthorizationId()!=null).findFirst().orElseThrow();
        qty("5",recovery.maxReportQty());assertFalse(recovery.allowActualOverproduction());assertNull(recovery.orderItemId());
        var replacement=reports.approve(reports.create(reportRequest(c,recovery,"5","0")).getId(),DailyReportApproveRequests.freshKey());
        var recovered=replacement.getItems().getFirst();qty("5",recovered.getQty());qty("5",recovered.getOutputBatchQty());
        assertTrue(recovered.isPublicOutput());assertFalse(recovered.isActualSurplus());assertEquals(target.proofId(),recovered.getSupplementProofId());
        finishInbound(c,replacement.getId());
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_actual_output_supplement_claims WHERE report_id=? AND event_type='CLAIM'",Integer.class,report.getId()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_actual_output_supplement_claims WHERE report_id=?",Integer.class,replacement.getId()));
        qty("100",planQuantity(c,"qty"));qty("100",planQuantity(c,"iqty"));
        qty("130",db.queryForObject("SELECT fn_production_execution_cost_target(?)",BigDecimal.class,c.segment()));
        qty("100",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,c.demand()));
        drainValuation(c);var cost=beans.getBean(com.uten.imp.application.port.InventoryProductionCostPort.class).position(c.segment());
        qty("1000",cost.actualKnownCostLocal());qty("1000",cost.allocatedToOutputsLocal());qty("0",cost.heldWipLocal());
    }

    @Test
    void actualSupplementCancellationReleasesOnlyItsClaimAndRetainsTheOriginalPlan() {
        Case c=createStartedTask("wps-supplement-cancel",false,"100");var source=sources(c).getFirst();
        var input=reportRequest(c,source,"130","100");
        var preview=supplements.previewReport(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.ReportPreviewRequest(input,null)).lines().getFirst();
        var created=supplements.create(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.CreateRequest(
                c.segment(),input.getItems().getFirst().getQty(),source.executionSegmentSalesAllocationId(),preview.fingerprint(),BusinessTime.today(),BusinessTime.today(),
                "取消前核对完整责任","supplement-cancel-create-"+UUID.randomUUID(),null,input,0));
        assertThrows(ApiException.class,()->productionPlans.delete(created.planId()),"generic deletion cannot leave the physical-batch request orphaned");
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE production_plan_items SET qty=31 WHERE plan_id=?",created.planId()));
        productionPlans.approve(created.planId());var approved=supplements.detail(created.id());
        segments.start(approved.planId(),approved.supplementSegmentId(),new SegmentTransitionRequest(approved.supplementSegmentVersion(),"cancel-start-"+approved.id()));
        input.getItems().getFirst().setSupplementProofId(approved.proofId());UUID draft=reports.create(input).getId();
        var cancel=new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.CancelRequest("撤回尚未过账的完整实产批次","cancel-proof-"+approved.id());
        assertThrows(ApiException.class,()->supplements.cancel(created.id(),cancel));
        reports.delete(draft);var cancelled=supplements.cancel(created.id(),cancel);
        assertEquals("CANCELLED",cancelled.status());assertEquals("CANCELLED",cancelled.supplementSegmentStatus());
        assertEquals("CANCELLED",supplements.cancel(created.id(),cancel).status());
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_actual_output_supplement_claims WHERE proof_id=? AND event_type='RELEASE'",Integer.class,approved.proofId()));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_actual_output_supplement_reversals WHERE proof_id=?",Integer.class,approved.proofId()));
        qty("100",planQuantity(c,"qty"));qty("0",planQuantity(c,"fqty"));qty("100",db.queryForObject("SELECT fn_production_execution_cost_target(?)",BigDecimal.class,c.segment()));
        assertEquals("IN_PROGRESS",status(c));
    }

    private Case createStartedTask(String tag, boolean mixed,String plannedQuantity) {
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
        String salesQuantity = mixed ? new BigDecimal(plannedQuantity).divide(new BigDecimal("2")).toPlainString() : plannedQuantity;
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
            var appended = commands.issueWorkshopPlans(view.analysisId(), issue(view, rootItem, world.warehouseId(), workshop, worker, true, salesQuantity));
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

    private void approveRate(Case c,String rate) {
        long version=db.queryForObject("SELECT overproduction_rate_version FROM production_execution_segments WHERE id=?",Long.class,c.segment());
        var request=productionRates.submit(new com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.SubmitRequest(
                c.segment(),version,new BigDecimal(rate),"专项回归所需允许超产比例，经计划审批后使用","rate-regression-"+UUID.randomUUID()));
        productionRates.decide(request.id(),new com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.DecisionRequest(
                request.rowVersion(),"rate-approve-"+request.id(),null),true);
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
        return approveReport(c,source,quantity,quantity);
    }

    private UUID approveReport(Case c, ReportablePlanLine source, String quantity,String materialQuantity) {
        return reports.approve(reports.create(reportRequest(c,source,quantity,materialQuantity)).getId(),DailyReportApproveRequests.freshKey()).getId();
    }

    private DailyReportSaveRequest reportRequest(Case c,ReportablePlanLine source,String quantity,String materialQuantity) {
        var request = new DailyReportSaveRequest();
        request.setIdempotencyKey("wps-report-" + UUID.randomUUID()); request.setBillDate(BusinessTime.today());
        request.setDepartmentId(c.workshop()); request.setWorkerIds(List.of(c.worker()));
        var line = new DailyReportItemLine();
        line.setLineNo(1); line.setPlanItemId(source.planItemId()); line.setExecutionSegmentId(source.executionSegmentId());
        line.setExecutionSegmentSalesAllocationId(source.executionSegmentSalesAllocationId()); line.setSalesOrderItemId(source.orderItemId());
        line.setFqcRecoveryAuthorizationId(source.fqcRecoveryAuthorizationId());
        line.setGoodsId(c.product()); line.setUnitId(c.world().unitId()); line.setUnitRate(BigDecimal.ONE); line.setQty(new BigDecimal(quantity));
        request.setItems(List.of(line));
        var usage = new DailyReportMaterialUsageLine(); usage.setDemandId(c.demand()); usage.setQtyBase(new BigDecimal(materialQuantity));
        if(source.fqcRecoveryAuthorizationId()==null)request.setMaterialLines(List.of(usage));
        return request;
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
