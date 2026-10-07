package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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
import com.uten.imp.features.warehouse.finishedin.FinishedArrivalTestSupport;
import com.uten.imp.features.production.quality.ProductionFqcContracts.LotDecisionRequest;
import com.uten.imp.features.stock.dto.FinishedInboundConfirmRequest;
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
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
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

        // ADR-148：需求 2000 与实际超产 300 同批同去向 = 一批实物：整批登记、整批判定、一张入库单两行。
        UUID lot = lotOf(demandItem);
        assertEquals(lot, lotOf(publicItem));
        FinishedArrivalTestSupport.registerItems(arrivals, report, "actual-arrival-" + report,
                c.world().warehouseId(), List.of(demandItem, publicItem), "需求与超产同库位");
        quality.decideLot(lot, new LotDecisionRequest(new BigDecimal("2300"), BigDecimal.ZERO, null, null, "actual-pass-" + report));
        UUID inbound = draftOf(demandItem);
        assertEquals(inbound, draftOf(publicItem), "同一批实物合格只进一张入库单");
        qty("0", planQuantity(c, "iqty"));
        // 仓库只收到 2100：实收先满足需求份，短少的 200 只能是实际超产，余量单只含超产份。
        UUID residual = confirmLot(inbound, lot, "2100", "本次实际到货2100，余量200继续交接");
        qty("2100", planQuantity(c, "iqty"));
        assertPlannedReceipt(c, "2000", "100");
        assertSalesProgress(c, 2000, 2000);
        assertEquals(List.of(publicItem), db.queryForList(
                "SELECT source_daily_report_item_id FROM stock_document_items WHERE doc_id=? AND NOT is_deleted", UUID.class, residual));
        qty("200", db.queryForObject("SELECT qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted", BigDecimal.class, residual));
        fixture.confirmFinishedInboundFully(residual);
        qty("2300", planQuantity(c, "iqty"));
        qty("2000", planQuantity(c, "qty"));
        assertPlannedReceipt(c, "2000", "300");
        assertEquals(0, db.queryForObject("""
                SELECT COUNT(*) FROM stock_reservations
                WHERE source_doc_type='PRODUCTION_INBOUND' AND source_doc_id = ?
                  AND NOT is_deleted AND owner_type IN ('SALES_ORDER_ITEM','PREPLAN_ANALYSIS')
                """, Integer.class, residual), "公共超产余量不能占销售或分析需求");
        qty("2300", db.queryForObject("SELECT fn_production_execution_cost_target(fn_production_execution_cost_scope(?))", BigDecimal.class, c.segment()));
        drainValuation(c);
        stock.reverseFinishedInbound(residual);
        drainValuation(c);
        stock.reverseFinishedInbound(inbound);
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

    private UUID lotOf(UUID reportItem) {
        return db.queryForObject("SELECT output_lot_id FROM production_daily_report_items WHERE id=?", UUID.class, reportItem);
    }

    /** 本报工行当前的待点收草稿。 */
    private UUID draftOf(UUID reportItem) {
        return db.queryForObject("""
                SELECT document.id FROM stock_documents document JOIN stock_document_items item ON item.doc_id=document.id
                WHERE item.source_daily_report_item_id=? AND NOT item.is_deleted AND NOT document.is_deleted
                  AND document.doc_type='FINISHED_IN' AND document.status=0
                """, UUID.class, reportItem);
    }

    /** 按批点收(ADR-148)，返回余量单(全收时为 null)。 */
    private UUID confirmLot(UUID document, UUID lot, String accepted, String reason) {
        var request = new FinishedInboundConfirmRequest();
        request.setIdempotencyKey("lot-confirm-" + document);
        request.setVarianceReason(reason);
        var line = new FinishedInboundConfirmRequest.Lot();
        line.setLotId(lot);
        line.setAcceptedQty(new BigDecimal(accepted));
        request.setLots(List.of(line));
        stock.confirmFinishedInbound(document, request);
        return db.queryForObject("SELECT residual_stock_document_id FROM production_finished_in_confirmations WHERE stock_document_id=?",
                UUID.class, document);
    }

    /** 本报工全部批整批登记、整批全合格，返回生成的待点收入库单(不跨计划合单，可能多张)。 */
    private List<UUID> registerAndPassAll(Case c, UUID report, String key) {
        FinishedArrivalTestSupport.registerAll(arrivals, report, key, c.world().warehouseId(), "实际分账入库", null, false);
        for (var lot : db.queryForList("""
                SELECT item.output_lot_id, SUM(item.qty) FROM production_daily_report_items item
                WHERE item.report_id=? AND NOT item.is_deleted AND item.destination='WAREHOUSE'
                GROUP BY item.output_lot_id
                """, report)) {
            quality.decideLot((UUID) lot.get("output_lot_id"), new LotDecisionRequest(
                    (BigDecimal) lot.get("sum"), BigDecimal.ZERO, null, null, key + "-pass-" + lot.get("output_lot_id")));
        }
        return db.queryForList("""
                SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN'
                  AND status=0 AND NOT is_deleted ORDER BY bill_no
                """, UUID.class, report);
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

    /**
     * ADR-148 主场景：计划 1000、允许超产 10%、实报 1100 = 需求 1000 + 实际超产 100 同批同去向。
     * 登记一行、品质一次整批全合格 -> 恰好一张入库单两行、一个待点收任务、一条待点收通知；
     * 仓库只点到 1060 -> 需求 1000 + 超产 60 入库，余量单只含超产 40。
     */
    @Test
    void handoffLotOf1100IsOneInboundOneCountTaskOneNoticeAndShortCountTrimsActualSurplusFirst() {
        Case c=createStartedTask("wps-handoff-lot",false,"1000");
        // 默认允许超产比例即 10%(无需另行审批)。
        UUID report=approveReport(c,sources(c).getFirst(),"1100","1000");
        var detail=reports.detail(report);
        assertEquals(2,detail.getItems().size());
        UUID demand=detail.getItems().stream().filter(row->!row.isActualSurplus()).findFirst().orElseThrow().getId();
        UUID surplus=detail.getItems().stream().filter(row->row.isActualSurplus()).findFirst().orElseThrow().getId();
        UUID lot=lotOf(demand);
        assertEquals(lot,lotOf(surplus),"同一报工、同一产出批次、送入仓库 = 同一批实物");
        // 车间侧：服务端一批一行、同去向一组，摘要「送入仓库 1100(其中实际超产 100)」。
        assertEquals(1,detail.getOutputBatches().size());
        var batch=detail.getOutputBatches().getFirst();
        assertEquals(1,batch.groups().size());
        assertTrue(batch.groups().getFirst().summary().startsWith("送入仓库 1100(其中实际超产 100"),batch.groups().getFirst().summary());
        assertTrue(batch.summary().contains("共 1100"),batch.summary());
        // 仓库待登记：一个任务、一行(一批)，其中实际超产 100。
        var tasks=beans.getBean(com.uten.imp.features.warehouse.finishedin.ProductionFinishedInboundTaskService.class);
        var arrival=tasks.list(detail.getBillNo(),"ARRIVAL_REGISTRATION",null,1,40).getItems();
        assertEquals(1,arrival.size());assertEquals(1,arrival.getFirst().lineCount());
        qty("100",arrival.getFirst().actualSurplusQty());assertEquals("其中实际超产 100",arrival.getFirst().actualSurplusNote());
        var pending=arrivals.batchDetail(List.of(report)).getFirst();
        assertEquals(1,pending.lots().size());
        var lotView=pending.lots().getFirst();
        qty("1100",lotView.reportedQty());qty("1000",lotView.demandQty());qty("100",lotView.actualSurplusQty());
        assertEquals("需求 1000 · 实际超产 100",lotView.splitText());
        // 部分登记被数据库整批守卫拒绝(绕过服务直接写登记行)。
        assertWholeLotGuardRejectsPartialRegistration(c,report,demand);
        FinishedArrivalTestSupport.registerAll(arrivals,report,"handoff-arrival-"+report,c.world().warehouseId(),"A-01",null,false);
        assertEquals(1,db.queryForObject("SELECT count(DISTINCT place_snapshot) FROM production_finished_arrival_registration_items WHERE source_report_item_id IN (?,?)",Integer.class,demand,surplus));
        // 分成几份的批不能逐份判定。
        UUID demandInspection=db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=? AND status<>'CANCELLED'",UUID.class,demand);
        ApiException single=assertThrows(ApiException.class,()->quality.decide(demandInspection,
                new DecisionRequest("PASS",null,null,null,null,"handoff-single-"+report)));
        assertTrue(single.getMessage().contains("整批判定"),single.getMessage());
        var decided=quality.decideLot(lot,new LotDecisionRequest(new BigDecimal("1100"),BigDecimal.ZERO,null,null,"handoff-pass-"+report));
        assertFalse(decided.replay());assertEquals("RESOLVED",decided.lot().status());
        assertTrue(quality.decideLot(lot,new LotDecisionRequest(new BigDecimal("1100"),BigDecimal.ZERO,null,null,"handoff-pass-"+report)).replay());
        List<UUID> docs=db.queryForList("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted",UUID.class,report);
        assertEquals(1,docs.size(),"恰好一张成品入库单");
        UUID doc=docs.getFirst();
        assertEquals(2,db.queryForObject("SELECT count(*) FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",Integer.class,doc));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM plan_draw_links WHERE draw_id=?",Integer.class,doc));
        assertEquals(1,db.queryForObject("""
                SELECT count(*) FROM business_outbox WHERE event_type='PRODUCTION_FINISHED_INBOUND_PENDING'
                  AND aggregate_id IN (SELECT id FROM stock_documents WHERE source_daily_report_id=?)
                """,Integer.class,report),"恰好一条待点收通知");
        var count=tasks.list(detail.getBillNo(),"FINAL_COUNT",null,1,40).getItems();
        assertEquals(1,count.size(),"恰好一个待最终点收任务");
        assertEquals(doc,count.getFirst().documentId());assertEquals(1,count.getFirst().lineCount());
        qty("100",count.getFirst().actualSurplusQty());
        var stockDetail=stock.detail(doc);
        assertEquals(1,stockDetail.getFinishedLots().size());
        assertEquals("其中实际超产 100",stockDetail.getFinishedLots().getFirst().actualSurplusNote());
        UUID residual=confirmLot(doc,lot,"1060","实际到货1060，其余40待交接");
        qty("1060",planQuantity(c,"iqty"));
        assertPlannedReceipt(c,"1000","60");
        qty("1000",db.queryForObject("SELECT qty FROM stock_document_items WHERE doc_id=? AND source_daily_report_item_id=? AND NOT is_deleted",BigDecimal.class,doc,demand));
        qty("60",db.queryForObject("SELECT qty FROM stock_document_items WHERE doc_id=? AND source_daily_report_item_id=? AND NOT is_deleted",BigDecimal.class,doc,surplus));
        assertEquals(List.of(surplus),db.queryForList("SELECT source_daily_report_item_id FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",UUID.class,residual),"余量单只含超产份");
        qty("40",db.queryForObject("SELECT qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",BigDecimal.class,residual));
    }

    /**
     * 按批点收的重放(ADR-148): 只点到需求数时实际超产份收到 0, 被软删进余量单; 同一请求(同键同数)再来
     * 仍是原结果, 不能因为当前明细少了一行就变成 409 或 422; 同键换数 409。
     */
    @Test
    void lotCountThatZeroesASliceReplaysTheSameRequestAndRejectsADifferentOne() {
        Case c=createStartedTask("wps-lot-replay",false,"1000");
        UUID report=approveReport(c,sources(c).getFirst(),"1100","1000");
        var detail=reports.detail(report);
        UUID demand=detail.getItems().stream().filter(row->!row.isActualSurplus()).findFirst().orElseThrow().getId();
        UUID surplus=detail.getItems().stream().filter(row->row.isActualSurplus()).findFirst().orElseThrow().getId();
        UUID lot=lotOf(demand);
        FinishedArrivalTestSupport.registerAll(arrivals,report,"replay-arrival-"+report,c.world().warehouseId(),"A-02",null,false);
        // 数据库对抗: 绕过服务直接给多份批里的一份写逐份决定(没有整批命令) -> 守卫拒绝。
        UUID surplusInspection=db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=? AND status<>'CANCELLED'",UUID.class,surplus);
        var bypass=assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("""
                INSERT INTO production_fqc_decision_events(inspection_id,decision,pass_qty,fail_qty,idempotency_key,request_hash,
                    decided_by_employee_id,created_by)
                VALUES (?,'PASS',100,0,?,repeat('b',64),?,?)
                """,surplusInspection,"bypass-"+report,c.world().employeeId(),c.world().superAdminUserId()));
        assertTrue(String.valueOf(bypass.getMostSpecificCause().getMessage()).contains("请按整批判定"),
                bypass.getMostSpecificCause().getMessage());
        quality.decideLot(lot,new LotDecisionRequest(new BigDecimal("1100"),BigDecimal.ZERO,null,null,"replay-pass-"+report));
        UUID doc=db.queryForObject("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted",UUID.class,report);
        UUID residual=confirmLot(doc,lot,"1000","超产 100 还在车间");
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_document_items WHERE doc_id=? AND source_daily_report_item_id=? AND NOT is_deleted",Integer.class,doc,surplus),
                "收到 0 的超产份不留在原单");
        long movements=db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",Long.class,doc);
        // 同一请求再来(响应丢了, 页面按同一键重试): 原结果, 不再过账, 不多一张余量单。
        assertEquals(residual,confirmLot(doc,lot,"1000","超产 100 还在车间"));
        assertEquals(movements,db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",Long.class,doc));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND status=0 AND NOT is_deleted",Integer.class,report));
        // 同一个键换了实收数: 409, 不当成已办成。
        ApiException changed=assertThrows(ApiException.class,()->confirmLot(doc,lot,"990","超产 100 还在车间"));
        assertEquals(ErrorCode.CONFLICT,changed.getCode());
        assertTrue(changed.getMessage().contains("另一组实收数量"),changed.getMessage());
    }

    /** 品质整批判定的瀑布(ADR-118 §4 修订)：合格先满足需求份，不良先扣实际超产；同键重放、换内容 409。 */
    @Test
    void lotDecisionPassFillsDemandFirstAndFailureTrimsActualSurplusFirst() {
        for(String scenario:List.of("pass1050-fail50","pass950-fail150")) {
            Case c=createStartedTask("wps-lot-"+scenario,false,"1000");
            UUID report=approveReport(c,sources(c).getFirst(),"1100","1000");
            var items=reports.detail(report).getItems();
            UUID demand=items.stream().filter(row->!row.isActualSurplus()).findFirst().orElseThrow().getId();
            UUID surplus=items.stream().filter(row->row.isActualSurplus()).findFirst().orElseThrow().getId();
            FinishedArrivalTestSupport.registerAll(arrivals,report,"lot-arrival-"+report,c.world().warehouseId(),"W-01",null,false);
            boolean first=scenario.startsWith("pass1050");
            var request=new LotDecisionRequest(new BigDecimal(first?"1050":"950"),new BigDecimal(first?"50":"150"),
                    "REWORK","整批抽检不良返工","lot-decision-"+report);
            quality.decideLot(lotOf(demand),request);
            var demandRow=db.queryForMap("SELECT passed_qty,failed_qty FROM production_fqc_inspections WHERE source_report_item_id=? AND status<>'CANCELLED'",demand);
            var surplusRow=db.queryForMap("SELECT passed_qty,failed_qty FROM production_fqc_inspections WHERE source_report_item_id=? AND status<>'CANCELLED'",surplus);
            if(first) {
                qty("1000",(BigDecimal)demandRow.get("passed_qty"));qty("0",(BigDecimal)demandRow.get("failed_qty"));
                qty("50",(BigDecimal)surplusRow.get("passed_qty"));qty("50",(BigDecimal)surplusRow.get("failed_qty"));
            } else {
                qty("950",(BigDecimal)demandRow.get("passed_qty"));qty("50",(BigDecimal)demandRow.get("failed_qty"));
                qty("0",(BigDecimal)surplusRow.get("passed_qty"));qty("100",(BigDecimal)surplusRow.get("failed_qty"));
            }
            assertEquals(1,db.queryForObject("SELECT count(*) FROM production_fqc_lot_decision_commands WHERE lot_id=?",Integer.class,lotOf(demand)));
            assertTrue(quality.decideLot(lotOf(demand),request).replay());
            ApiException changed=assertThrows(ApiException.class,()->quality.decideLot(lotOf(demand),
                    new LotDecisionRequest(new BigDecimal("1000"),new BigDecimal("100"),"REWORK","换了数量","lot-decision-"+report)));
            assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,changed.getCode());
            List<UUID> docs=db.queryForList("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted",UUID.class,report);
            assertEquals(1,docs.size(),"一次整批判定合格的数量只进一张入库单");
        }
    }

    /** 同一报工、同一计划的两次录入(两个产出批次)在同一次登记里：品质全合格后仍只一张入库单。 */
    @Test
    void twoOutputBatchesOfOnePlanInOneRegistrationShareOneInboundAfterPassAll() {
        Case c=createStartedTask("wps-two-batches",false,"1000");
        var source=sources(c).getFirst();
        var request=reportRequest(c,source,"600","600");
        var second=reportRequest(c,source,"500","400").getItems().getFirst();second.setLineNo(2);
        request.setItems(List.of(request.getItems().getFirst(),second));
        request.getMaterialLines().getFirst().setQtyBase(new BigDecimal("1000"));
        UUID report=reports.approve(reports.create(request).getId(),DailyReportApproveRequests.freshKey()).getId();
        var items=reports.detail(report).getItems();
        assertEquals(2,items.stream().map(row->row.getOutputBatchId()).distinct().count());
        assertEquals(2,arrivals.batchDetail(List.of(report)).getFirst().lots().size(),"两次录入 = 两批实物");
        FinishedArrivalTestSupport.registerAll(arrivals,report,"two-batches-"+report,c.world().warehouseId(),"T-01",null,false);
        UUID surplusSlice=items.stream().filter(row->row.isActualSurplus()).findFirst().orElseThrow().getId();
        UUID firstBatchSlice=items.stream().filter(row->!row.getOutputBatchId().equals(
                items.stream().filter(item->item.getId().equals(surplusSlice)).findFirst().orElseThrow().getOutputBatchId()))
                .findFirst().orElseThrow().getId();
        // 检查单级全合格：只选第二批的超产份 + 第一批，服务端把第二批的需求份一起带上(选中一份 = 整批)。
        var result=quality.passAll(new com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest(
                List.of(inspectionOf(surplusSlice),inspectionOf(firstBatchSlice)),"two-batches-pass-"+report));
        assertEquals(3,result.items().size(),"两批三份全部判定");
        List<UUID> docs=db.queryForList("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted",UUID.class,report);
        assertEquals(1,docs.size(),"同报工、同登记、同计划只一张入库单");
        fixture.confirmFinishedInboundFully(docs.getFirst());
        qty("1100",planQuantity(c,"iqty"));
    }

    private UUID inspectionOf(UUID reportItem) {
        return db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=? AND status<>'CANCELLED'",UUID.class,reportItem);
    }

    private void assertWholeLotGuardRejectsPartialRegistration(Case c,UUID report,UUID oneSlice) {
        var failure=assertThrows(org.springframework.dao.DataAccessException.class,()->new org.springframework.transaction.support.TransactionTemplate(
                beans.getBean(org.springframework.transaction.PlatformTransactionManager.class)).executeWithoutResult(status->{
            UUID registration=UUID.randomUUID();
            db.update("""
                    INSERT INTO production_finished_arrival_registrations(id,source_report_id,warehouse_id,warehouse_code_snapshot,
                        warehouse_name_snapshot,receiver_employee_id,receiver_name_snapshot,idempotency_key,request_hash,created_by)
                    SELECT ?,?,warehouse.id,warehouse.code,warehouse.name,?,'整批守卫','partial-lot-'||?,repeat('a',64),?
                    FROM warehouses warehouse WHERE warehouse.id=?
                    """,registration,report,c.world().employeeId(),report,c.world().superAdminUserId(),c.world().warehouseId());
            db.update("INSERT INTO production_finished_arrival_registration_items(id,registration_id,source_report_item_id,place_snapshot,created_by) VALUES (?,?,?,?,?)",
                    UUID.randomUUID(),registration,oneSlice,"P-01",c.world().superAdminUserId());
        }));
        assertTrue(String.valueOf(failure.getMostSpecificCause().getMessage()).contains("同一次登记"),failure.getMostSpecificCause().getMessage());
    }

    @Test
    void actualPublicRecoveryReworkRetainsPublicOwnershipWithoutExpandingProductionTarget() {
        Case c=createStartedTask("wps-actual-rework",false);
        approveRate(c,"0.25");
        UUID original=approveReport(c,sources(c).getFirst(),"2300","2000");
        var rows=reports.detail(original).getItems();
        var normal=rows.stream().filter(row->!row.isActualSurplus()).findFirst().orElseThrow();
        var surplus=rows.stream().filter(row->row.isActualSurplus()).findFirst().orElseThrow();
        FinishedArrivalTestSupport.registerItems(arrivals,original,"actual-rework-arrival-"+original,c.world().warehouseId(),
                List.of(normal.getId(),surplus.getId()),"需求与超产同库位");
        // 整批判定：合格 2250、不良 50 -> 需求 2000 全合格；不良先扣实际超产(超产合格 250、返工 50)。
        quality.decideLot(lotOf(normal.getId()),new LotDecisionRequest(new BigDecimal("2250"),new BigDecimal("50"),"REWORK","超产返工50","actual-rework-lot-"+original));
        qty("50",db.queryForObject("SELECT failed_qty FROM production_fqc_inspections WHERE source_report_item_id=? AND status<>'CANCELLED'",BigDecimal.class,surplus.getId()));
        qty("0",db.queryForObject("SELECT failed_qty FROM production_fqc_inspections WHERE source_report_item_id=? AND status<>'CANCELLED'",BigDecimal.class,normal.getId()));
        UUID receipt=draftOf(normal.getId());
        assertEquals(receipt,draftOf(surplus.getId()));
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
        // ADR-148：销售 1000、计划公共 1000、实际超产 400 同批同去向 = 一批实物，一张入库单三行。
        List<UUID> inbounds=registerAndPassAll(c,report,"actual-arrival-"+report);
        assertEquals(1,inbounds.size());
        assertEquals(3,db.queryForObject("SELECT COUNT(*) FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",Integer.class,inbounds.getFirst()));
        assertEquals("IN_PROGRESS",status(c));
        fixture.confirmFinishedInboundFully(inbounds.getFirst());
        BigDecimal reserved=db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_reservations WHERE source_doc_type='PRODUCTION_INBOUND' AND source_doc_id=? AND NOT is_deleted",BigDecimal.class,inbounds.getFirst());
        assertTrue(reserved.compareTo(new BigDecimal("1000"))<=0,"公共与实际超产不占销售需求");
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
        assertTrue(over.getMessage().contains("超限原因"));qty("130",request.getItems().getFirst().getQty());
        var preview=supplements.previewReport(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.ReportPreviewRequest(request,null));
        assertFalse(preview.requiresSupplements());var line=preview.lines().getFirst();
        qty("20",line.overLimitQty());qty("110",line.withinAuthorizationQty());
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
        // 原计划 100 + 追加计划 30 同批同去向：整批登记、整批判定；不跨计划合单，两张入库单。
        List<UUID> inbounds=registerAndPassAll(c,report.getId(),"supplement-arrival-"+report.getId());
        assertEquals(2,inbounds.size());
        for(UUID inbound:inbounds)fixture.confirmFinishedInboundFully(inbound);
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
        assertFalse(preview.requiresSupplements());
        qty("0",preview.lines().getFirst().overLimitQty());qty("20",preview.lines().getLast().overLimitQty());
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
        FinishedArrivalTestSupport.registerAll(arrivals,report.getId(),"multi-arrival-"+report.getId(),c.world().warehouseId(),"同表真实产出",null,false);
        UUID reworkSegment=approved.getLast().supplementSegmentId();
        for(var lot:db.queryForList("""
                SELECT output_lot_id,SUM(qty) AS qty,bool_or(execution_segment_id=?) AS rework
                FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted AND destination='WAREHOUSE'
                GROUP BY output_lot_id
                """,reworkSegment,report.getId())) {
            UUID lotId=(UUID)lot.get("output_lot_id");BigDecimal total=(BigDecimal)lot.get("qty");
            if(Boolean.TRUE.equals(lot.get("rework"))) {
                // 第二行 20 全是第二个追加份：合格 15、返工 5(不良先扣批内末位的份)。
                quality.decideLot(lotId,new LotDecisionRequest(total.subtract(new BigDecimal("5")),new BigDecimal("5"),"REWORK","本追加份返工5","supplement-rework-"+lotId));
            } else {
                quality.decideLot(lotId,new LotDecisionRequest(total,BigDecimal.ZERO,null,null,"supplement-pass-"+lotId));
            }
        }
        for(UUID inbound:db.queryForList("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND status=0 AND NOT is_deleted",UUID.class,report.getId()))
            fixture.confirmFinishedInboundFully(inbound);
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
        FinishedArrivalTestSupport.registerItems(arrivals, reportId, "wps-arrival-" + reportId, c.world().warehouseId(),
                List.of(reportItem), "真实生产完工入库");
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
