package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.execution.ProductionExecutionBatch;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.mrp.ProductionExecutionBatchService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

/** Full Flyway/Spring/stock chain, including deferred split quantity guards. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionExecutionBatchEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionBatchService batches;
    @Autowired com.uten.imp.features.production.execution.ProductionDrawRequestService drawRequests;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired StockDocService stock;
    @Autowired ProductionDailyReportService reports;
    @Autowired com.uten.imp.features.production.mrp.ProductionPlanningPackageService packages;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    @Autowired com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService materialReturns;
    FullChainEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}

    @Test void workshopWorkerCanRecheckOwnMaterialsAndReceiveDrawCapabilitiesWithoutPlannerReadScope() {
        Case c=create("split-recheck-scope",false);
        confirmRoute(c.plan(),c.segment(),"FULL_KIT","route-split-recheck-scope-"+c.segment());
        var waiting=segments.list(c.plan()).getFirst();
        assertTrue(waiting.canSplitBatch());assertFalse(waiting.canRequestDraw());
        receive(c,"50");fixture.loginAs(c.workerUser());
        assertThrows(ApiException.class,()->segments.list(c.plan()));
        // 缺料下的重核可达=车间身份权限证明(不是 403)；报缺料解释而非权限错误。
        assertTrue(assertThrows(ApiException.class,()->segments.recheckMaterial(c.plan(),c.segment(),
                new SegmentTransitionRequest(version(c.segment()),"workshop-recheck-partial-"+c.segment())))
                .getMessage().contains("缺"));
        receive(c,"150");fixture.loginAs(c.workerUser());
        // V606 到货即提升：补齐的那笔入库已把段提到 READY 并建领料单，无需再重核；
        // 开工仍被「待发料>0」拦下(领料申请→仓库发料仍是车间/仓库各自职责)。
        assertEquals("READY",db.queryForObject(
                "SELECT status FROM production_execution_segments WHERE id=?",String.class,c.segment()));
        assertThrows(ApiException.class,()->segments.start(c.plan(),c.segment(),
                new SegmentTransitionRequest(version(c.segment()),"recheck-before-issue-"+c.segment())));
    }

    @Test void requestedPartialMaterialIsTheWarehouseLimitUntilTheWorkshopRequestsTheRemainder() {
        Case c=create("draw-request-partial",false,"100",true);
        confirmRoute(c.plan(),c.segment(),"FULL_KIT","route-draw-request-partial-"+c.segment());
        receive(c,"200");receive(c,c.secondMaterial(),"300");fixture.loginAs(c.workerUser());
        // V606 到货即提升：料齐的段已自动提升(极端下未提升再走人工重核)。
        if ("WAITING".equals(db.queryForObject(
                "SELECT status FROM production_execution_segments WHERE id=?",String.class,c.segment()))) {
            segments.recheckMaterial(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"partial-ready-"+c.segment()));
        }
        var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        var selected=preview.lines().stream().filter(line->line.goodsId().equals(c.material())).findFirst().orElseThrow();
        var submitted=drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(items,
                "partial-request-"+c.segment(),preview.fingerprint(),List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Selection(selected.drawItemId(),new BigDecimal("20")))));
        fixture.loginAs(c.world().superAdminUserId());
        var issue=new StockDocIssueBatchRequest();issue.setIdempotencyKey("partial-issue-"+c.segment());issue.setDocIds(submitted.documentIds());stock.issueFullBatch(issue);
        qty("20",db.queryForObject("SELECT sum(posting.qty_base) FROM production_material_stock_postings posting JOIN production_material_demands demand ON demand.id=posting.demand_id WHERE demand.execution_segment_id=? AND posting.posting_type='ISSUE'",BigDecimal.class,c.segment()));
        assertFalse(db.queryForObject("SELECT bool_or(fn_production_draw_pending(document_id)) FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW'",Boolean.class,c.segment()));
        var reversal=new com.uten.imp.features.stock.dto.StockDocIssueRequest();
        reversal.setIdempotencyKey("partial-reverse-"+c.segment());reversal.setReason("本轮部分实物领错，退回后重新核对");
        var reverseLine=new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line();reverseLine.setItemId(selected.drawItemId());reverseLine.setQty(BigDecimal.TEN);
        reversal.setLines(List.of(reverseLine));
        stock.reverseIssue(selected.drawId(),reversal);stock.reverseIssue(selected.drawId(),reversal);
        assertTrue(db.queryForObject("SELECT fn_production_draw_pending(?)",Boolean.class,selected.drawId()));
        qty("10",db.queryForObject("SELECT issued_qty FROM stock_document_items WHERE id=?",BigDecimal.class,selected.drawItemId()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM business_outbox WHERE event_type='PRODUCTION_DRAW_ISSUE_REVERSED' AND aggregate_id=?",Integer.class,selected.drawId()));
        var reissue=new StockDocIssueBatchRequest();reissue.setIdempotencyKey("partial-reissue-"+c.segment());reissue.setDocIds(List.of(selected.drawId()));stock.issueFullBatch(reissue);
        assertFalse(db.queryForObject("SELECT fn_production_draw_pending(?)",Boolean.class,selected.drawId()));
        var partlyIssued=segments.list(c.plan()).getFirst();
        assertTrue(partlyIssued.canRequestDraw());assertFalse(partlyIssued.drawRequested());assertFalse(partlyIssued.materialIssued());
        fixture.loginAs(c.workerUser());
        assertThrows(ApiException.class,()->segments.start(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"partial-start-blocked-"+c.segment())));
        items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var remainder=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        qty("180",remainder.lines().stream().filter(line->line.goodsId().equals(c.material())).findFirst().orElseThrow().qty());
        qty("300",remainder.lines().stream().filter(line->line.goodsId().equals(c.secondMaterial())).findFirst().orElseThrow().qty());
        var rest=drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(items,"partial-rest-"+c.segment(),remainder.fingerprint()));
        fixture.loginAs(c.world().superAdminUserId());
        var restIssue=new StockDocIssueBatchRequest();restIssue.setIdempotencyKey("partial-rest-issue-"+c.segment());restIssue.setDocIds(rest.documentIds());stock.issueFullBatch(restIssue);
        fixture.loginAs(c.workerUser());
        var started=segments.start(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"partial-start-"+c.segment()));
        assertEquals("IN_PROGRESS",started.status());assertTrue(started.materialIssued());assertFalse(started.canRequestDraw());
    }

    @Test void thousandOrderedProductsCanFinishTenCompleteKitsThenTheRemainingNineHundredAndNinety() {
        Case c=create("split-thousand",false,"1000",true);
        confirmRoute(c.plan(),c.segment(),"BATCH","route-split-thousand-"+c.segment());
        receive(c,"20");fixture.loginAs(c.workerUser());
        var missing=batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),null));
        qty("0",missing.maxReadyQty());
        assertTrue(missing.summaries().isEmpty());
        assertThrows(ApiException.class,()->batches.submit(new ProductionExecutionBatch.SubmitRequest(
                c.segment(),missing.expectedVersion(),BigDecimal.ONE,missing.fingerprint(),"missing-material-"+c.segment())));

        receive(c,c.secondMaterial(),"30");fixture.loginAs(c.workerUser());
        var preview=batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),null));
        qty("10",preview.maxReadyQty());qty("990",preview.remainingQty());
        assertEquals(2,preview.summaries().size());
        qty("20",preview.summaries().stream().filter(line->line.goodsId().equals(c.material())).findFirst().orElseThrow().qty());
        qty("30",preview.summaries().stream().filter(line->line.goodsId().equals(c.secondMaterial())).findFirst().orElseThrow().qty());
        assertThrows(ApiException.class,()->batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),new BigDecimal("11"))));
        var request=new ProductionExecutionBatch.SubmitRequest(c.segment(),preview.expectedVersion(),preview.quantity(),preview.fingerprint(),"thousand-first-"+c.segment());
        var first=batches.submit(request);
        assertTrue(batches.submit(request).replayed());
        assertThrows(ApiException.class,()->segments.start(c.plan(),first.batchSegmentId(),new SegmentTransitionRequest(version(first.batchSegmentId()),"before-issue-"+first.batchSegmentId())));
        finishBatch(c,first,"10");
        qty("10",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.world().warehouseId(),c.root()));
        qty("1000",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,c.segment()));
        qty("990",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,first.remainingSegmentId()));
        assertEquals("WAITING",status(first.remainingSegmentId()));

        receive(c,"1980");fixture.loginAs(c.workerUser());
        qty("0",batches.preview(new ProductionExecutionBatch.PreviewRequest(first.remainingSegmentId(),version(first.remainingSegmentId()),null)).maxReadyQty());
        receive(c,c.secondMaterial(),"2970");fixture.loginAs(c.workerUser());
        var rest=batches.preview(new ProductionExecutionBatch.PreviewRequest(first.remainingSegmentId(),version(first.remainingSegmentId()),null));
        qty("990",rest.maxReadyQty());qty("0",rest.remainingQty());
        var second=batches.submit(new ProductionExecutionBatch.SubmitRequest(rest.segmentId(),rest.expectedVersion(),rest.quantity(),rest.fingerprint(),"thousand-rest-"+rest.segmentId()));
        assertNull(second.remainingSegmentId());
        finishBatch(c,second,"990");
        qty("1000",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.world().warehouseId(),c.root()));
        qty("1000",db.queryForObject("SELECT sum(planned_qty) FROM production_execution_segments WHERE plan_id=? AND status NOT IN('CANCELLED','REVERSED')",BigDecimal.class,c.plan()));
        qty("2000",db.queryForObject("SELECT sum(required_qty) FROM production_material_demands WHERE plan_id=? AND goods_id=? AND status NOT IN('RELEASED','REVERSED')",BigDecimal.class,c.plan(),c.material()));
        qty("3000",db.queryForObject("SELECT sum(required_qty) FROM production_material_demands WHERE plan_id=? AND goods_id=? AND status NOT IN('RELEASED','REVERSED')",BigDecimal.class,c.plan(),c.secondMaterial()));
        UUID orderItem=db.queryForObject("SELECT sales_order_item_id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",UUID.class,second.batchSegmentId());
        UUID shipment=fixture.createShipment(c.world(),orderItem,c.root(),"1000");
        fixture.shipThroughWarehouse(shipment);
        qty("0",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.world().warehouseId(),c.root()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_supply_pegs peg JOIN production_material_demands demand ON demand.id=peg.demand_id WHERE demand.plan_id=?",Integer.class,c.plan()));
    }

    @Test void twoPartialReceiptsCreateRequestedCompleteBatchesAndPreserveRemainingDemand() {
        Case c=create("split-linear",false);
        confirmRoute(c.plan(),c.segment(),"BATCH","route-split-linear-"+c.segment());
        receive(c,"40");fixture.loginAs(c.workerUser());
        var preview=batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),null));
        qty("20",preview.maxReadyQty());qty("80",preview.remainingQty());
        var request=new ProductionExecutionBatch.SubmitRequest(c.segment(),preview.expectedVersion(),preview.quantity(),preview.fingerprint(),"split-first-"+c.segment());
        var first=batches.submit(request);
        assertEquals(first.batchSegmentId(),batches.submit(request).batchSegmentId());
        assertEquals("CANCELLED",status(c.segment()));assertEquals("READY",status(first.batchSegmentId()));
        assertEquals("WAITING",status(first.remainingSegmentId()));
        qty("100",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,c.segment()));
        assertTrue(db.queryForObject("SELECT bool_and(fn_production_draw_requested(document_id)) FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW'",Boolean.class,first.batchSegmentId()));
        assertThrows(ApiException.class,()->segments.start(c.plan(),first.batchSegmentId(),new SegmentTransitionRequest(version(first.batchSegmentId()),"too-early-"+first.batchSegmentId())));
        issueAndReport(c,first,"20");
        receive(c,"60");fixture.loginAs(c.workerUser());
        var next=batches.preview(new ProductionExecutionBatch.PreviewRequest(first.remainingSegmentId(),version(first.remainingSegmentId()),null));
        qty("30",next.maxReadyQty());qty("50",next.remainingQty());
        var second=batches.submit(new ProductionExecutionBatch.SubmitRequest(next.segmentId(),next.expectedVersion(),next.quantity(),next.fingerprint(),"split-second-"+next.segmentId()));
        qty("100",db.queryForObject("SELECT sum(planned_qty) FROM production_execution_segments WHERE plan_id=? AND status NOT IN('CANCELLED','REVERSED')",BigDecimal.class,c.plan()));
        qty("200",db.queryForObject("SELECT sum(required_qty) FROM production_material_demands WHERE plan_id=? AND status NOT IN('RELEASED','REVERSED')",BigDecimal.class,c.plan()));
        qty("100",db.queryForObject("SELECT sum(allocation.allocated_qty) FROM execution_segment_sales_allocations allocation JOIN production_execution_segments segment ON segment.id=allocation.execution_segment_id WHERE segment.plan_id=? AND segment.status NOT IN('CANCELLED','REVERSED')",BigDecimal.class,c.plan()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_supply_pegs peg JOIN production_material_demands demand ON demand.id=peg.demand_id WHERE demand.plan_id=?",Integer.class,c.plan()));
        assertEquals("WAITING",status(second.remainingSegmentId()));
    }

    @Test void fixedBatchMaterialIsChargedOnceAndZeroIncrementContinuationNeedsActualPriorIssue() {
        Case c=create("split-fixed",true);
        confirmRoute(c.plan(),c.segment(),"BATCH","route-split-fixed-"+c.segment());
        receive(c,"1");fixture.loginAs(c.workerUser());
        var preview=batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),new BigDecimal("20")));
        var first=batches.submit(new ProductionExecutionBatch.SubmitRequest(c.segment(),preview.expectedVersion(),preview.quantity(),preview.fingerprint(),"fixed-first-"+c.segment()));
        assertThrows(ApiException.class,()->batches.preview(new ProductionExecutionBatch.PreviewRequest(first.remainingSegmentId(),version(first.remainingSegmentId()),new BigDecimal("30"))));
        issueAndReport(c,first,"20");fixture.loginAs(c.workerUser());
        var returnSources=materialReturns.sources(c.plan(),first.batchSegmentId());
        assertEquals(1,returnSources.size());
        qty("0",returnSources.getFirst().availableQty());
        assertTrue(returnSources.getFirst().returnBlockedReason().contains("后续生产批次"));
        assertThrows(ApiException.class,()->materialReturns.submit(c.plan(),
                new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(first.batchSegmentId(),
                        "protected-return-"+first.batchSegmentId(),"不能退后续批次仍需的物料",List.of(
                        new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(
                                returnSources.getFirst().issuePostingId(),new BigDecimal("0.25"))))));
        var next=batches.preview(new ProductionExecutionBatch.PreviewRequest(first.remainingSegmentId(),version(first.remainingSegmentId()),new BigDecimal("30")));
        assertTrue(next.summaries().isEmpty());
        var second=batches.submit(new ProductionExecutionBatch.SubmitRequest(next.segmentId(),next.expectedVersion(),next.quantity(),next.fingerprint(),"fixed-second-"+next.segmentId()));
        assertTrue(second.documentIds().isEmpty());
        assertTrue(db.queryForObject("SELECT fn_split_batch_empty_issued(?)",Boolean.class,second.batchSegmentId()));
        assertEquals(List.of(first.batchSegmentId()),db.queryForList("SELECT segment_id FROM fn_production_material_usage_source_segments(?)",UUID.class,second.batchSegmentId()));
        issueAndReport(c,second,"30");
        assertTrue(db.queryForObject("SELECT fn_issue_committed_to_later_batch(?)",Boolean.class,returnSources.getFirst().issuePostingId()));
        qty("1",db.queryForObject("SELECT sum(required_qty) FROM production_material_demands WHERE plan_id=? AND status NOT IN('RELEASED','REVERSED')",BigDecimal.class,c.plan()));
    }

    @Test void fixedPackageBoundaryUsesCumulativeDemandAcrossThreeBatchesInsteadOfAverageConsumption() {
        Case c=create("split-package-boundary",true,"1000",false);
        confirmRoute(c.plan(),c.segment(),"BATCH","route-split-package-boundary-"+c.segment());
        receive(c,"2");fixture.loginAs(c.workerUser());
        var preview=batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),new BigDecimal("150")));
        qty("200",preview.maxReadyQty());qty("2",preview.summaries().getFirst().qty());
        var first=batches.submit(new ProductionExecutionBatch.SubmitRequest(preview.segmentId(),preview.expectedVersion(),preview.quantity(),preview.fingerprint(),"package-first-"+preview.segmentId()));
        issueAndReport(c,first,"150");
        var remaining=batches.preview(new ProductionExecutionBatch.PreviewRequest(first.remainingSegmentId(),version(first.remainingSegmentId()),null));
        qty("50",remaining.maxReadyQty());assertTrue(remaining.summaries().isEmpty());
        var second=batches.submit(new ProductionExecutionBatch.SubmitRequest(remaining.segmentId(),remaining.expectedVersion(),remaining.quantity(),remaining.fingerprint(),"package-second-"+remaining.segmentId()));
        issueAndReport(c,second,"50");
        qty("0",batches.preview(new ProductionExecutionBatch.PreviewRequest(second.remainingSegmentId(),version(second.remainingSegmentId()),null)).maxReadyQty());
        receive(c,"1");fixture.loginAs(c.workerUser());
        var next=batches.preview(new ProductionExecutionBatch.PreviewRequest(second.remainingSegmentId(),version(second.remainingSegmentId()),null));
        qty("100",next.maxReadyQty());qty("1",next.summaries().getFirst().qty());
        batches.submit(new ProductionExecutionBatch.SubmitRequest(next.segmentId(),next.expectedVersion(),next.quantity(),next.fingerprint(),"package-third-"+next.segmentId()));
        qty("10",db.queryForObject("SELECT sum(required_qty) FROM production_material_demands WHERE plan_id=? AND status NOT IN('RELEASED','REVERSED')",BigDecimal.class,c.plan()));
        qty("1000",db.queryForObject("SELECT sum(planned_qty) FROM production_execution_segments WHERE plan_id=? AND status NOT IN('CANCELLED','REVERSED')",BigDecimal.class,c.plan()));
    }

    @Test void manualDeferralAndStaleVersionCannotBeBypassedByBatchSubmission() {
        Case c=create("split-negative",false);
        confirmRoute(c.plan(),c.segment(),"BATCH","route-split-negative-"+c.segment());fixture.loginAs(c.workerUser());
        long version=version(c.segment());
        assertThrows(ApiException.class,()->batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version+1,null)));
        fixture.loginAs(c.world().superAdminUserId());
        UUID packageId=db.queryForObject("SELECT package_id FROM production_execution_segments WHERE id=?",UUID.class,c.segment());
        packages.reverse(c.plan(),packageId,new com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest("defer-replace-"+packageId,"未执行计划包改为明确暂缓"));
        var preview=packages.preview(c.plan(),c.world().warehouseId());
        var waiting=preview.executionSegments().getFirst();
        var segment=new com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest.ExecutionSegment();
        segment.setClientSegmentKey("deferred-"+c.segment());segment.setSourcePlanItemId(waiting.sourcePlanItemId());
        segment.setRequestedStatus("WAITING");segment.setDeferUntilManualRelease(true);segment.setPlannedQty(new BigDecimal("100"));
        segment.setBomFingerprint(waiting.bomFingerprint());segment.setWorkshopDepartmentId(c.workshop());segment.setResponsibleEmployeeId(c.worker());
        segment.setPlanBeginDate(BusinessTime.today());segment.setPlanEndDate(BusinessTime.today().plusDays(10));
        var request=new com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest();request.setWarehouseId(c.world().warehouseId());
        request.setIdempotencyKey("explicit-defer-"+c.segment());request.setPreviewFingerprint(preview.fingerprint());request.setSegments(List.of(segment));
        UUID deferred=packages.confirm(c.plan(),request).executionSegments().getFirst().segmentId();
        receive(c,"40");fixture.loginAs(c.workerUser());
        assertFalse(db.queryForObject("SELECT fn_can_split_execution_batch(?)",Boolean.class,deferred));
        assertThrows(ApiException.class,()->batches.preview(new ProductionExecutionBatch.PreviewRequest(deferred,version(deferred),null)));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_execution_segment_splits WHERE source_segment_id=?",Integer.class,c.segment()));
    }

    @Test void qualifiedLotsUseArrivalOrderAcrossActualWarehousesAndPreviewDoesNotChangeBusinessFacts() {
        Case c=create("split-fifo",false);
        confirmRoute(c.plan(),c.segment(),"BATCH","route-split-fifo-"+c.segment());fixture.loginAs(c.world().superAdminUserId());
        UUID analysis=db.queryForObject("SELECT material_analysis_id FROM production_plans WHERE id=?",UUID.class,c.plan());
        var view=analyses.detail(analysis);
        UUID materialLine=view.flatMaterials().stream().filter(material->material.goodsId().equals(c.material()))
                .map(MaterialView::materialLineId).findFirst().orElseThrow();
        commands.notifySupply(analysis,new NotifyRequest(view.version(),view.fingerprint(),"fifo-supply-"+analysis,"BUY",List.of(materialLine),null,null));
        UUID orderItem=org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"approveExistingAnalysisPurchase",c.world(),analysis,c.material());
        UUID laterInUuid=UUID.fromString("f0000000-0000-0000-0000-"+UUID.randomUUID().toString().substring(24));
        UUID earlierInUuid=UUID.fromString("10000000-0000-0000-0000-"+UUID.randomUUID().toString().substring(24));
        for(UUID warehouse:List.of(laterInUuid,earlierInUuid))db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,?,?,'使用',TRUE)",
                warehouse,"FIFO-WH-"+warehouse,"实际分仓"+warehouse.toString().substring(0,1));
        for(UUID warehouse:List.of(laterInUuid,earlierInUuid)) {
            var actual=withWarehouse(c.world(),warehouse);
            UUID receipt=org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"receiveIntoQuarantine",actual,c.material(),orderItem,"40");
            org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"passAndStockPurchase",actual,receipt,"40");
        }
        // Arbitrary public stock outside the planned main warehouse must stay excluded.
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",withWarehouse(c.world(),laterInUuid),c.material(),"100");
        fixture.loginAs(c.workerUser());
        String before=materialFacts(c,analysis);
        var readOnly=new org.springframework.transaction.support.TransactionTemplate(transactionManager);
        readOnly.setReadOnly(true);
        var preview=readOnly.execute(transaction->{
            db.execute("SET TRANSACTION READ ONLY");
            assertEquals("on",db.queryForObject("SHOW transaction_read_only",String.class));
            return batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),new BigDecimal("25")));
        });
        assertNotNull(preview);
        assertEquals(before,materialFacts(c,analysis));
        qty("40",preview.maxReadyQty());
        qty("40",preview.summaries().stream().filter(line->line.warehouseId().equals(laterInUuid)).map(line->line.qty()).reduce(BigDecimal.ZERO,BigDecimal::add));
        qty("10",preview.summaries().stream().filter(line->line.warehouseId().equals(earlierInUuid)).map(line->line.qty()).reduce(BigDecimal.ZERO,BigDecimal::add));
        var submitted=batches.submit(new ProductionExecutionBatch.SubmitRequest(c.segment(),preview.expectedVersion(),preview.quantity(),preview.fingerprint(),"fifo-submit-"+c.segment()));
        for(var summary:preview.summaries())qty(summary.qty().toPlainString(),db.queryForObject("""
                SELECT sum(item.base_qty) FROM production_planning_package_documents mapping
                JOIN stock_documents document ON document.id=mapping.document_id JOIN stock_document_items item ON item.doc_id=document.id
                WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW' AND document.warehouse_id=?
                """,BigDecimal.class,submitted.batchSegmentId(),summary.warehouseId()));
    }

    @Test void concurrentDifferentRequestsCanOnlySplitTheSameWaitingSourceOnce() throws Exception {
        Case c=create("split-concurrent",false);
        confirmRoute(c.plan(),c.segment(),"BATCH","route-split-concurrent-"+c.segment());receive(c,"40");fixture.loginAs(c.workerUser());
        var preview=batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),new BigDecimal("20")));
        var start=new java.util.concurrent.CountDownLatch(1);
        var pool=java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            List<java.util.concurrent.Future<Boolean>> results=new java.util.ArrayList<>();
            for(int i=0;i<2;i++) {
                String key="concurrent-split-"+i+"-"+c.segment();
                results.add(pool.submit(()->{
                    fixture.loginAs(c.workerUser());start.await();
                    try {batches.submit(new ProductionExecutionBatch.SubmitRequest(c.segment(),preview.expectedVersion(),preview.quantity(),preview.fingerprint(),key));return true;}
                    catch(ApiException rejected){return false;}
                    finally{org.springframework.security.core.context.SecurityContextHolder.clearContext();}
                }));
            }
            start.countDown();int succeeded=0;
            for(var result:results)if(result.get(30,java.util.concurrent.TimeUnit.SECONDS))succeeded++;
            assertEquals(1,succeeded);
        } finally {pool.shutdownNow();}
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_execution_segment_splits WHERE source_segment_id=?",Integer.class,c.segment()));
        qty("100",db.queryForObject("SELECT sum(planned_qty) FROM production_execution_segments WHERE plan_id=? AND status NOT IN('CANCELLED','REVERSED')",BigDecimal.class,c.plan()));
        qty("40",db.queryForObject("SELECT sum(reservation.qty) FROM stock_reservations reservation JOIN production_material_demands demand ON demand.id=reservation.demand_id WHERE demand.plan_id=?",BigDecimal.class,c.plan()));
    }

    private String materialFacts(Case c,UUID analysis) {
        return db.queryForObject("""
                SELECT jsonb_build_array(
                    (SELECT jsonb_agg(to_jsonb(reservation) ORDER BY reservation.id) FROM stock_reservations reservation
                      WHERE reservation.owner_id=? OR reservation.demand_id IN(SELECT id FROM production_material_demands WHERE plan_id=?)),
                    (SELECT jsonb_agg(to_jsonb(event) ORDER BY event.id) FROM preplan_stock_entitlement_events event WHERE event.beneficiary_analysis_id=?),
                    (SELECT jsonb_agg(to_jsonb(segment) ORDER BY segment.id) FROM production_execution_segments segment WHERE segment.plan_id=?),
                    (SELECT count(*) FROM production_planning_package_documents document JOIN production_planning_packages package ON package.id=document.package_id WHERE package.plan_id=?))::text
                """,String.class,analysis,c.plan(),analysis,c.plan(),c.plan());
    }

    private static FullChainEndToEndTest.World withWarehouse(FullChainEndToEndTest.World w,UUID warehouse) {
        return new FullChainEndToEndTest.World(w.departmentId(),w.employeeId(),w.superAdminUserId(),w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),w.clientId(),w.supplierId(),warehouse,w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());
    }

    private Case create(String tag,boolean fixed) {
        return create(tag,fixed,"100",false);
    }
    private Case create(String tag,boolean fixed,String plannedQty,boolean twoMaterials) {
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());
        UUID root=UUID.randomUUID(),material=UUID.randomUUID(),workshop=UUID.randomUUID(),worker=UUID.randomUUID();
        fixture.insertGoods(root,"ROOT-"+tag,"分批成品","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(material,"MAT-"+tag,"分批原料","采购",w.unitId(),w.unitLegacy());
        fixture.insertBom(root,material,fixed?"1":"2");
        UUID secondMaterial=twoMaterials?UUID.randomUUID():null;
        if(twoMaterials) {
            fixture.insertGoods(secondMaterial,"MAT2-"+tag,"分批第二种原料","采购",w.unitId(),w.unitLegacy());
            fixture.insertBom(root,secondMaterial,"3");
        }
        if(fixed)db.update("UPDATE goods_bom_items SET consumption_basis='FIXED_BATCH',basis_output_qty=100 WHERE goods_id=?",root);
        UUID production=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'",UUID.class);
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",workshop,"W-"+tag,"分批车间",production);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",worker,"BATCH-WORKER-"+tag,"分批负责人",workshop);
        UUID workerUser=fixture.createUserWithPerms(w,"worker-"+tag,"production_execution:view","production_execution:start","production_daily_report:view","production_daily_report:create","production_material:settle");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",workshop,workerUser);
        fixture.loginAs(w.superAdminUserId());
        PreviewItem origin;
        if(fixed) origin=new PreviewItem("OTHER",null,root,null,w.unitId(),"source-"+tag,"明确分批需求",BusinessTime.today().plusDays(10),new BigDecimal(plannedQty));
        else {
            UUID order=fixture.createApprovedOrder(w,root,plannedQty,"100");
            UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
            origin=new PreviewItem("SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal(plannedQty));
        }
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"preview-"+tag,List.of(origin)));
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"routes-"+tag,
                view.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(root)?"MAKE":"BUY",null)).toList()));
        view=analyses.detail(view.analysisId());
        UUID plan=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"issue-"+tag,
                w.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                null,view.products().getFirst().analysisLineId(),new BigDecimal(plannedQty),BusinessTime.today(),BusinessTime.today().plusDays(10),workshop,null,worker,null,null)))).plans().getFirst().planId();
        UUID segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND status='WAITING'",UUID.class,plan);
        return new Case(w,root,material,plan,segment,workshop,worker,workerUser,secondMaterial);
    }
    private void receive(Case c,String quantity) {
        receive(c,c.material(),quantity);
    }
    private void receive(Case c,UUID material,String quantity) {
        fixture.loginAs(c.world().superAdminUserId());var request=new StockDocSaveRequest();request.setDocType("OTHER_IN");request.setWarehouseId(c.world().warehouseId());request.setBillDate(BusinessTime.today());
        var line=new StockDocItemLine();line.setGoodsId(material);line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(quantity));line.setPrice(BigDecimal.TEN);line.setAmountOriginal(line.getQty().multiply(BigDecimal.TEN));line.setAmountLocal(line.getAmountOriginal());request.setItems(List.of(line));stock.approve(stock.create(request).getId());
    }
    private void finishBatch(Case c,ProductionExecutionBatch.Result batch,String quantity) {
        fixture.loginAs(c.world().superAdminUserId());
        var issue=new StockDocIssueBatchRequest();issue.setIdempotencyKey("finish-issue-"+batch.batchSegmentId());issue.setDocIds(batch.documentIds());stock.issueFullBatch(issue);
        fixture.loginAs(c.workerUser());segments.start(c.plan(),batch.batchSegmentId(),new SegmentTransitionRequest(version(batch.batchSegmentId()),"finish-start-"+batch.batchSegmentId()));
        fixture.loginAs(c.world().superAdminUserId());
        var allocation=db.queryForMap("SELECT id,sales_order_item_id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",batch.batchSegmentId());
        UUID planItem=db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,batch.batchSegmentId());
        UUID report=fixture.reportAndApproveExecutionSegment(c.world(),planItem,(UUID)allocation.get("sales_order_item_id"),c.root(),batch.batchSegmentId(),(UUID)allocation.get("id"),quantity,false,"0",null,null);
        fixture.confirmFinishedInboundFully(fixture.finishedInDocForReport(report));
    }
    private void issueAndReport(Case c,ProductionExecutionBatch.Result batch,String quantity) {
        if(!batch.documentIds().isEmpty()){fixture.loginAs(c.world().superAdminUserId());var request=new StockDocIssueBatchRequest();request.setIdempotencyKey("issue-"+batch.batchSegmentId());request.setDocIds(batch.documentIds());stock.issueFullBatch(request);}
        fixture.loginAs(c.workerUser());segments.start(c.plan(),batch.batchSegmentId(),new SegmentTransitionRequest(version(batch.batchSegmentId()),"start-"+batch.batchSegmentId()));
        var report=new DailyReportSaveRequest();report.setIdempotencyKey("report-"+batch.batchSegmentId());report.setBillDate(BusinessTime.today());report.setDepartmentId(c.workshop());report.setWorkerIds(List.of(c.worker()));
        var item=new DailyReportItemLine();item.setLineNo(1);item.setExecutionSegmentId(batch.batchSegmentId());item.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,batch.batchSegmentId()));item.setGoodsId(c.root());item.setUnitId(c.world().unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal(quantity));
        var allocation=db.queryForList("SELECT id,sales_order_item_id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",batch.batchSegmentId());
        if(!allocation.isEmpty()){item.setExecutionSegmentSalesAllocationId((UUID)allocation.getFirst().get("id"));item.setSalesOrderItemId((UUID)allocation.getFirst().get("sales_order_item_id"));}
        report.setItems(List.of(item));
        var actualUses=db.queryForList("SELECT id,required_qty FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted AND status NOT IN('RELEASED','REVERSED')",batch.batchSegmentId()).stream().map(row->{
            var use=new com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine();
            use.setDemandId((UUID)row.get("id"));use.setQtyBase((BigDecimal)row.get("required_qty"));return use;
        }).toList();
        report.setMaterialLines(actualUses);
        item.setIsFinal(true);item.setQty(BigDecimal.ONE);
        ApiException earlyFinal=assertThrows(ApiException.class,()->reports.create(report));
        assertTrue(earlyFinal.getMessage().contains("分批报工不调整原批准总量"));
        item.setIsFinal(false);item.setQty(new BigDecimal(quantity));
        if(actualUses.isEmpty()&&Boolean.TRUE.equals(db.queryForObject("SELECT fn_split_batch_empty_issued(?)",Boolean.class,batch.batchSegmentId()))) {
            item.setQty(new BigDecimal(quantity).add(BigDecimal.ONE));
            ApiException unprovenSurplus=assertThrows(ApiException.class,()->reports.create(report));
            assertTrue(unprovenSurplus.getMessage().contains("新增超产"),"a fixed planned batch is not proof of additional unconsumed output");
            item.setQty(new BigDecimal(quantity));
        }
        assertNotNull(reports.create(report).getId());
    }

    /** V599 / ADR-091：开工前先确认生产路线——recheck/开工/领料=FULL_KIT，分批提交=BATCH。 */
    private void confirmRoute(UUID planId,UUID segmentId,String route,String key){
        segments.confirmRoute(planId,segmentId,new com.uten.imp.features.production.execution.SegmentRouteConfirmRequest(version(segmentId),key,route));
    }
    private long version(UUID id){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,id);}
    private String status(UUID id){return db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,id);}
    private static void qty(String expected,BigDecimal value){assertEquals(0,new BigDecimal(expected).compareTo(value));}
    private record Case(FullChainEndToEndTest.World world,UUID root,UUID material,UUID plan,UUID segment,UUID workshop,UUID worker,UUID workerUser,UUID secondMaterial){}
}
