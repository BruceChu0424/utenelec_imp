package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService;
import com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

/** Real PostgreSQL: draft -> frozen material review -> atomic actual use/selected return, including legacy drafts. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000","uten.workshop-material.auto-close.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class DailyReportMaterialReviewV3EndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionDailyReportService reports;
    @Autowired ProductionMaterialReturnRequestService returns;
    @Autowired ProductionMaterialSettlementService settlements;
    private WorkshopPublicSurplusEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void saveIsOnlyADraftAndKeepPostsTheExactSavedConsumptionWithRetainedReview() {
        Object task=task();UUID demand=id(task,"demand");UUID report=reports.create(request(task,"10","6")).getId();
        qty("10",book(demand));assertEquals(0,events(report));assertEquals(0,returnCount(task));
        var review=reports.materialReview(report);var row=review.rows().getFirst();
        qty("10",row.availableQty());qty("6",row.usageQty());qty("4",row.remainingIssuedQty());qty("4",row.returnableIssuedQty());
        assertTrue(row.canReturn());
        var approved=reports.approve(report,approve(review,"KEEP"));
        qty("6",approved.getMaterialUsages().getFirst().getQtyBase());qty("4",book(demand));
        assertEquals(1,events(report));assertEquals(0,returnCount(task));
        assertEquals(review,reports.detail(report).getMaterialReview());
        assertEquals("KEEP",reports.detail(report).getMaterialDecisions().getFirst().action());
        assertEquals(review.fingerprint(),approved.getApprovalReceipt().materialReviewFingerprint());
        assertEquals(review,reports.materialReview(report));
    }
    @Test void returnReservesTheReviewedRemainderAndDoesNotRestoreWarehouseInventoryUntilReceipt() {
        Object task=task();UUID demand=id(task,"demand");UUID report=reports.create(request(task,"10","6")).getId();
        BigDecimal warehouseBefore=warehouseBalance(task);var review=reports.materialReview(report);var command=approve(review,"RETURN");
        var approved=reports.approve(report,command);
        qty("6",approved.getMaterialUsages().getFirst().getQtyBase());qty("0",book(demand));qty("4",pending(demand));
        assertEquals(1,returnCount(task));qty(warehouseBefore.toPlainString(),warehouseBalance(task));
        var replay=reports.approve(report,command);assertTrue(replay.getApprovalReceipt().replay());
        assertEquals(1,events(report));assertEquals(1,returnCount(task));
        assertEquals(review.fingerprint(),reports.approvalReceipt(report,command.getIdempotencyKey()).receipt().materialReviewFingerprint());
        assertEquals("RETURN",reports.detail(report).getMaterialDecisions().getFirst().action());
    }
    @Test void v3OnAnOldCountedDraftNeverOverwritesTheSavedFivePointNineOrReturnsUnselectedMaterials() {
        Object task=task();UUID demand=id(task,"demand");
        ReflectionTestUtils.invokeMethod(fixture,"approveReport",task,source(task),"4");qty("6",book(demand));
        var input=request(task,"6","5.9");input.setSurplusReturnRequested(true);
        input.getMaterialLines().getFirst().setCountedLeftoverQty(new BigDecimal("0.5"));
        UUID report=reports.create(input).getId();var review=reports.materialReview(report);
        qty("0.1",review.rows().getFirst().remainingIssuedQty());
        var approved=reports.approve(report,approve(review,"KEEP"));
        qty("5.9",approved.getMaterialUsages().getFirst().getQtyBase());qty("0.5",approved.getMaterialUsages().getFirst().getCountedLeftoverQty());
        qty("0.1",book(demand));assertEquals(0,returnCount(task));assertFalse(approved.isSurplusReturnRequested());
    }
    @Test void pendingReturnIsExcludedAndTheAlreadyRequestedSliceIsNotRequestedTwice() {
        Object task=task();UUID demand=id(task,"demand");submitReturn(task,"1");qty("9",book(demand));
        UUID report=reports.create(request(task,"10","6")).getId();var review=reports.materialReview(report);
        qty("9",review.rows().getFirst().availableQty());qty("3",review.rows().getFirst().remainingIssuedQty());
        reports.approve(report,approve(review,"RETURN"));qty("4",pending(demand));qty("0",book(demand));assertEquals(2,returnCount(task));
    }
    @Test void sameKeyCannotChangeKeepToReturnAndOriginalApprovalStillResolves() {
        Object task=task();UUID report=reports.create(request(task,"10","6")).getId();var review=reports.materialReview(report);
        var command=approve(review,"KEEP");reports.approve(report,command);
        command.setMaterialDecisions(review.rows().stream().map(row->new DailyReportMaterialDecision(row.demandId(),"RETURN")).toList());
        assertThrows(ApiException.class,()->reports.approve(report,command));assertEquals(1,events(report));assertEquals(0,returnCount(task));
        assertEquals("CONFIRMED",reports.approvalReceipt(report,command.getIdempotencyKey()).status());
        assertEquals("KEEP",reports.detail(report).getMaterialDecisions().getFirst().action());
    }
    @Test void externalConsumptionAfterReviewRejectsTheOldSnapshotWithoutTouchingTheDraft() {
        Object task=task();UUID report=reports.create(request(task,"10","6")).getId();var review=reports.materialReview(report);
        consume(task,"1");qty("9",book(id(task,"demand")));
        var failure=assertThrows(ApiException.class,()->reports.approve(report,approve(review,"KEEP")));
        assertEquals(ErrorCode.DAILY_REPORT_MATERIAL_REVIEW_CONFLICT,failure.getCode());
        assertEquals(0,events(report));assertEquals(0,approvalCount(report));assertEquals((short)0,reports.detail(report).getStatus());
        qty("6",reports.detail(report).getMaterialUsages().getFirst().getQtyBase());
    }
    @Test void cancellationOfAPendingReturnChangesTheReviewAndRequiresAnewDecision() {
        Object task=task();UUID requestId=submitReturn(task,"1");
        UUID report=reports.create(request(task,"10","6")).getId();var review=reports.materialReview(report);
        returns.cancel(id(task,"plan"),requestId,new ProductionMaterialReturnRequest.Cancel("cancel-return-"+UUID.randomUUID(),"核对后撤回本次余料退仓"));
        assertThrows(ApiException.class,()->reports.approve(report,approve(review,"RETURN")));
        assertEquals(0,events(report));assertEquals(0,approvalCount(report));qty("10",book(id(task,"demand")));
        qty("4",reports.materialReview(report).rows().getFirst().remainingIssuedQty());
    }
    @Test void aPartialReportKeepsMaterialForFurtherProductionAndCannotReturnTheWholeTaskBalance() {
        Object task=task();UUID report=reports.create(request(task,"4","3")).getId();var review=reports.materialReview(report);
        assertFalse(review.rows().getFirst().canReturn());assertTrue(review.rows().getFirst().returnBlockedReason().contains("尚未收尾"));
        assertThrows(ApiException.class,()->reports.approve(report,approve(review,"RETURN")));assertEquals(0,events(report));
        reports.approve(report,approve(review,"KEEP"));qty("7",book(id(task,"demand")));assertEquals(0,returnCount(task));
    }
    @Test void aReturnFailureRollsBackConsumptionApprovalAndTheCommandThenSameKeyCanRetry() {
        Object task=task();UUID demand=id(task,"demand"),report=reports.create(request(task,"10","6")).getId();
        var review=reports.materialReview(report);var command=approve(review,"RETURN");
        String probe="test_v3_return_failure_"+UUID.randomUUID().toString().replace("-","");
        db.execute("CREATE FUNCTION "+probe+"() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic V3 return failure' USING ERRCODE='23514'; END $$");
        try {
            db.execute("CREATE TRIGGER "+probe+" BEFORE INSERT ON production_material_return_requests FOR EACH ROW EXECUTE FUNCTION "+probe+"()");
            assertThrows(RuntimeException.class,()->reports.approve(report,command));
            assertEquals((short)0,reports.detail(report).getStatus());assertEquals(0,events(report));assertEquals(0,approvalCount(report));
            assertEquals(0,returnCount(task));qty("10",book(demand));qty("6",reports.detail(report).getMaterialUsages().getFirst().getQtyBase());
        } finally {db.execute("DROP TRIGGER IF EXISTS "+probe+" ON production_material_return_requests");db.execute("DROP FUNCTION "+probe+"()");}
        reports.approve(report,command);assertEquals(1,events(report));assertEquals(1,returnCount(task));qty("4",pending(demand));
    }
    @Test void simultaneousSameKeyV3ApprovalsConsumeAndRequestTheRemainderExactlyOnce() throws Exception {
        Object task=task();UUID report=reports.create(request(task,"10","6")).getId();var review=reports.materialReview(report);var command=approve(review,"RETURN");
        var actor=SecurityContextHolder.getContext().getAuthentication();var ready=new java.util.concurrent.CountDownLatch(2);var go=new java.util.concurrent.CountDownLatch(1);
        try(var pool=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var futures=new java.util.ArrayList<java.util.concurrent.Future<DailyReportDetail>>();
            for(int index=0;index<2;index++)futures.add(pool.submit(()->{
                var context=SecurityContextHolder.createEmptyContext();context.setAuthentication(actor);SecurityContextHolder.setContext(context);
                try {ready.countDown();assertTrue(go.await(20,java.util.concurrent.TimeUnit.SECONDS));return reports.approve(report,command);}
                finally {SecurityContextHolder.clearContext();}
            }));
            assertTrue(ready.await(20,java.util.concurrent.TimeUnit.SECONDS));go.countDown();
            var a=futures.get(0).get(60,java.util.concurrent.TimeUnit.SECONDS);var b=futures.get(1).get(60,java.util.concurrent.TimeUnit.SECONDS);
            assertNotEquals(a.getApprovalReceipt().replay(),b.getApprovalReceipt().replay());
        }
        assertEquals(1,events(report));assertEquals(1,approvalCount(report));assertEquals(1,returnCount(task));qty("4",pending(id(task,"demand")));
    }
    @Test void missingForeignAndDuplicateDecisionsRollbackBeforeAllBusinessEffects() {
        Object task=task();UUID report=reports.create(request(task,"10","6")).getId();var review=reports.materialReview(report);
        var command=approve(review,"KEEP");command.setMaterialDecisions(List.of());
        assertThrows(ApiException.class,()->reports.approve(report,command));
        command.setMaterialDecisions(List.of(new DailyReportMaterialDecision(UUID.randomUUID(),"KEEP")));
        assertThrows(ApiException.class,()->reports.approve(report,command));
        var only=review.rows().getFirst();command.setMaterialDecisions(List.of(new DailyReportMaterialDecision(only.demandId(),"KEEP"),new DailyReportMaterialDecision(only.demandId(),"RETURN")));
        assertThrows(ApiException.class,()->reports.approve(report,command));
        assertEquals(0,events(report));assertEquals(0,approvalCount(report));qty("10",book(id(task,"demand")));
    }
    @Test void twoMaterialsFromWorkshopAndWarehouseHonorDifferentReviewedReturnChoices() {
        var mixed=new WorkshopDirectTransferBatchEndToEndTest();beans.autowireBean(mixed);mixed.prepare();
        FullChainEndToEndTest chain=(FullChainEndToEndTest)ReflectionTestUtils.getField(mixed,"fixture");
        Object c=ReflectionTestUtils.invokeMethod(mixed,"create","v3-mixed-"+UUID.randomUUID().toString().substring(0,8),true);
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(c,"world");
        UUID plan=id(c,"plan"),segment=id(c,"segment"),worker=id(c,"workerUser");
        chain.loginAs(worker);ReflectionTestUtils.invokeMethod(mixed,"confirmRoute",plan,segment,"FULL_KIT");
        ReflectionTestUtils.invokeMethod(mixed,"receive",c,id(c,"secondMaterial"),id(c,"leaf"),"100");
        ReflectionTestUtils.invokeMethod(mixed,"transfer",c,"100");
        var draws=beans.getBean(com.uten.imp.features.production.execution.ProductionDrawRequestService.class);
        var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(segment,version(segment)));
        var drawPreview=draws.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        var draw=draws.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(items,"v3-mixed-draw-"+segment,drawPreview.fingerprint()));
        chain.loginAs(world.superAdminUserId());var issue=new com.uten.imp.features.stock.dto.StockDocIssueBatchRequest();
        issue.setIdempotencyKey("v3-mixed-issue-"+segment);issue.setDocIds(draw.documentIds());beans.getBean(com.uten.imp.features.stock.StockDocService.class).issueFullBatch(issue);
        chain.loginAs(worker);beans.getBean(com.uten.imp.features.production.execution.ProductionExecutionSegmentService.class)
                .start(plan,segment,new com.uten.imp.features.production.execution.SegmentTransitionRequest(version(segment),"v3-mixed-start-"+segment));
        var save=new DailyReportSaveRequest();save.setIdempotencyKey("v3-mixed-report-"+UUID.randomUUID());save.setBillDate(com.uten.imp.common.time.BusinessTime.today());
        save.setWarehouseId(id(c,"leaf"));save.setDepartmentId(id(c,"workshop"));save.setWorkerIds(List.of(id(c,"worker")));
        var output=new DailyReportItemLine();output.setLineNo(1);output.setExecutionSegmentId(segment);
        output.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,segment));
        output.setExecutionSegmentSalesAllocationId(db.queryForObject("SELECT id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",UUID.class,segment));
        output.setSalesOrderItemId(db.queryForObject("SELECT sales_order_item_id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",UUID.class,segment));
        output.setGoodsId(id(c,"parent"));output.setUnitId(world.unitId());output.setUnitRate(BigDecimal.ONE);output.setQty(new BigDecimal("100"));save.setItems(List.of(output));
        List<UUID> demands=db.queryForList("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted ORDER BY id",UUID.class,segment);
        assertEquals(2,demands.size());save.setMaterialLines(demands.stream().map(demand->{var use=new DailyReportMaterialUsageLine();use.setDemandId(demand);use.setQtyBase(new BigDecimal("90"));return use;}).toList());
        UUID report=reports.create(save).getId();chain.loginAs(world.superAdminUserId());var review=reports.materialReview(report);assertEquals(2,review.rows().size());
        UUID directDemand=db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",UUID.class,segment,id(c,"child"));
        UUID warehouseDemand=db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",UUID.class,segment,id(c,"secondMaterial"));
        var command=approve(review,"KEEP");command.setMaterialDecisions(review.rows().stream().map(row->new DailyReportMaterialDecision(row.demandId(),row.demandId().equals(directDemand)?"RETURN":"KEEP")).toList());
        for(var row:review.rows()){qty("10",row.remainingIssuedQty());assertTrue(row.canReturn());}
        reports.approve(report,command);qty("10",pending(directDemand));qty("0",book(directDemand));qty("10",book(warehouseDemand));qty("0",pending(warehouseDemand));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_material_return_requests WHERE plan_id=?",Integer.class,plan));
        assertEquals(2,db.queryForObject("SELECT count(*) FROM production_daily_report_material_usages WHERE report_id=? AND qty_base=90",Integer.class,report));
    }
    @Test void laterBatchUsesEarlierIssueSourcesAndKeepsItsExactRegisteredUseWithoutPrematureReturn() {
        var batch=new ProductionExecutionBatchEndToEndTest();beans.autowireBean(batch);batch.prepare();
        FullChainEndToEndTest chain=(FullChainEndToEndTest)ReflectionTestUtils.getField(batch,"fixture");
        Object c=ReflectionTestUtils.invokeMethod(batch,"create","v3-split-"+UUID.randomUUID().toString().substring(0,8),true);
        UUID plan=id(c,"plan"),segment=id(c,"segment"),workerUser=id(c,"workerUser");
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(c,"world");
        var batches=beans.getBean(com.uten.imp.features.production.mrp.ProductionExecutionBatchService.class);
        var segments=beans.getBean(com.uten.imp.features.production.execution.ProductionExecutionSegmentService.class);
        ReflectionTestUtils.invokeMethod(batch,"confirmRoute",plan,segment,"BATCH","v3-split-route-"+segment);
        ReflectionTestUtils.invokeMethod(batch,"receive",c,"1");chain.loginAs(workerUser);
        var preview=batches.preview(new com.uten.imp.features.production.execution.ProductionExecutionBatch.PreviewRequest(segment,version(segment),new BigDecimal("20")));
        var first=batches.submit(new com.uten.imp.features.production.execution.ProductionExecutionBatch.SubmitRequest(segment,preview.expectedVersion(),preview.quantity(),preview.fingerprint(),"v3-split-first-"+segment));
        UUID demand=db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,first.batchSegmentId());
        chain.loginAs(world.superAdminUserId());
        var issue=new com.uten.imp.features.stock.dto.StockDocIssueBatchRequest();issue.setIdempotencyKey("v3-split-issue-"+segment);issue.setDocIds(first.documentIds());
        beans.getBean(com.uten.imp.features.stock.StockDocService.class).issueFullBatch(issue);
        chain.loginAs(workerUser);segments.start(plan,first.batchSegmentId(),new com.uten.imp.features.production.execution.SegmentTransitionRequest(version(first.batchSegmentId()),"v3-split-start-"+segment));
        UUID earlier=reports.create(splitRequest(c,first.batchSegmentId(),demand,"20","0.25")).getId();
        chain.loginAs(world.superAdminUserId());reports.approve(earlier,DailyReportApproveRequests.freshKey());qty("0.75",book(demand));
        chain.loginAs(workerUser);
        var rest=batches.preview(new com.uten.imp.features.production.execution.ProductionExecutionBatch.PreviewRequest(first.remainingSegmentId(),version(first.remainingSegmentId()),new BigDecimal("30")));
        var second=batches.submit(new com.uten.imp.features.production.execution.ProductionExecutionBatch.SubmitRequest(rest.segmentId(),rest.expectedVersion(),rest.quantity(),rest.fingerprint(),"v3-split-second-"+segment));
        assertTrue(second.documentIds().isEmpty());
        segments.start(plan,second.batchSegmentId(),new com.uten.imp.features.production.execution.SegmentTransitionRequest(version(second.batchSegmentId()),"v3-split-start-second-"+segment));
        UUID later=reports.create(splitRequest(c,second.batchSegmentId(),demand,"30","0.4")).getId();chain.loginAs(world.superAdminUserId());
        var review=reports.materialReview(later);var row=review.rows().stream().filter(value->value.demandId().equals(demand)).findFirst().orElseThrow();
        assertEquals(first.batchSegmentId(),row.materialExecutionSegmentId());qty("0.75",row.availableQty());qty("0.35",row.remainingIssuedQty());assertFalse(row.canReturn());
        reports.approve(later,approve(review,"KEEP"));qty("0.4",reports.detail(later).getMaterialUsages().getFirst().getQtyBase());qty("0.35",book(demand));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_return_requests WHERE plan_id=?",Integer.class,plan));
    }

    @Test void fractionalTwoOutputBatchesShareOneDemandAndRemainExactThroughReceiptReversalAndRetry() throws Exception {
        Object task=task();UUID demand=id(task,"demand");
        var input=request(task,"4.5001","6.0001");
        var second=request(task,"5.4999","0").getItems().getFirst();second.setLineNo(2);
        input.setItems(List.of(input.getItems().getFirst(),second));
        var mapper=beans.getBean(com.fasterxml.jackson.databind.ObjectMapper.class);
        var original=mapper.readValue(mapper.writeValueAsBytes(input),DailyReportSaveRequest.class);
        UUID report=reports.create(input).getId();
        assertEquals(report,reports.create(original).getId());
        assertEquals(2,reports.detail(report).getOutputBatches().size());
        var review=reports.materialReview(report);assertEquals(1,review.rows().size());
        qty("6.0001",review.rows().getFirst().usageQty());qty("3.9999",review.rows().getFirst().remainingIssuedQty());
        var command=approve(review,"RETURN");reports.approve(report,command);reports.approve(report,command);
        assertEquals(1,events(report));qty("3.9999",pending(demand));
        qty("10",scalar("SELECT SUM(qty) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",report));
        var warehouse=world(task).warehouseId();
        com.uten.imp.features.warehouse.finishedin.FinishedArrivalTestSupport.registerAll(
                beans.getBean(com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService.class),
                report,"fractional-arrival-"+report,warehouse,"精确小数实物批",null,false);
        var quality=beans.getBean(com.uten.imp.features.production.quality.ProductionFqcInspectionService.class);
        var lots=db.queryForList("SELECT DISTINCT output_lot_id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",UUID.class,report);
        assertEquals(2,lots.size());
        for(UUID lot:lots){
            BigDecimal quantity=scalar("SELECT SUM(qty) FROM production_daily_report_items WHERE output_lot_id=? AND NOT is_deleted",lot);
            quality.decideLot(lot,new com.uten.imp.features.production.quality.ProductionFqcContracts.LotDecisionRequest(
                    quantity,BigDecimal.ZERO,null,null,"fractional-pass-"+lot));
        }
        var documents=finishedDocuments(report);assertEquals(2,documents.size());
        FullChainEndToEndTest chain=(FullChainEndToEndTest)ReflectionTestUtils.getField(fixture,"fixture");
        documents.forEach(chain::confirmFinishedInboundFully);
        qty("10",productBalance(task));
        ReflectionTestUtils.invokeMethod(fixture,"drainValuation",task);
        assertThrows(ApiException.class,()->reports.reverse(report));qty("6.0001",reports.detail(report).getMaterialUsages().getFirst().getQtyBase());
        var stock=beans.getBean(com.uten.imp.features.stock.StockDocService.class);
        for(UUID document:documents.reversed()) {
            stock.reverseFinishedInbound(document);ReflectionTestUtils.invokeMethod(fixture,"drainValuation",task);
        }
        reports.reverse(report);
        qty("0",productBalance(task));qty("6.0001",book(demand));qty("3.9999",pending(demand));
        var replay=reports.approve(report,command);assertTrue(replay.getApprovalReceipt().replay());assertEquals((short)-1,replay.getStatus());
        assertEquals(2,events(report));
        UUID returned=db.queryForObject("SELECT id FROM production_material_return_requests WHERE plan_id=?",UUID.class,id(task,"plan"));
        returns.cancel(id(task,"plan"),returned,new ProductionMaterialReturnRequest.Cancel("fractional-cancel-"+report,"报工已红冲，撤回未收余料申请"));
        qty("10",book(demand));qty("0",pending(demand));
    }

    @Test void v3OverLimitUsesSavedConsumptionAndReleasesOnlyAuthorizedQualityFactsBeforeFullReversal() {
        Object task=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","v3-overlimit-"+UUID.randomUUID(),false,"1000");
        UUID demand=id(task,"demand");var input=request(task,"1200","900");
        input.getItems().getFirst().setOverLimitReason("本批实际产出超量，按原实耗与来源核对");
        UUID report=reports.create(input).getId();var review=reports.materialReview(report);
        qty("100",review.rows().getFirst().remainingIssuedQty());
        reports.approve(report,approve(review,"RETURN"));qty("900",reports.detail(report).getMaterialUsages().getFirst().getQtyBase());qty("100",pending(demand));
        qty("1000",scalar("SELECT SUM(qty) FROM production_daily_report_items WHERE report_id=? AND NOT is_actual_surplus AND NOT is_deleted",report));
        qty("100",scalar("SELECT SUM(qty) FROM production_daily_report_items WHERE report_id=? AND is_actual_surplus AND NOT is_over_limit AND NOT is_deleted",report));
        qty("100",scalar("SELECT SUM(qty) FROM production_daily_report_items WHERE report_id=? AND is_over_limit AND NOT is_deleted",report));
        UUID lot=db.queryForObject("SELECT DISTINCT output_lot_id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",UUID.class,report);
        com.uten.imp.features.warehouse.finishedin.FinishedArrivalTestSupport.registerAll(
                beans.getBean(com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService.class),
                report,"v3-overlimit-arrival-"+report,world(task).warehouseId(),"实产待点收",null,false);
        beans.getBean(com.uten.imp.features.production.quality.ProductionFqcInspectionService.class).decideLot(lot,
                new com.uten.imp.features.production.quality.ProductionFqcContracts.LotDecisionRequest(new BigDecimal("1200"),BigDecimal.ZERO,null,null,"v3-overlimit-pass-"+report));
        qty("1100",scalar("SELECT COALESCE(SUM(item.qty),0) FROM stock_document_items item JOIN stock_documents doc ON doc.id=item.doc_id WHERE doc.source_daily_report_id=? AND doc.doc_type='FINISHED_IN' AND NOT doc.is_deleted AND NOT item.is_deleted",report));
        qty("0",productBalance(task));
        UUID caseId=db.queryForObject("SELECT id FROM production_over_limit_dispositions WHERE report_id=?",UUID.class,report);
        var dispositions=beans.getBean(com.uten.imp.features.production.dailyreport.ProductionOverLimitDispositionService.class);
        var disposition=dispositions.detail(caseId);
        var decision=new com.uten.imp.features.production.dailyreport.ProductionOverLimitDispositionContracts.DecisionRequest(
                "ACCEPT_PUBLIC","核实实际超量并按原合格批接收",disposition.rowVersion(),"v3-overlimit-accept-"+report);
        dispositions.decide(caseId,decision);dispositions.decide(caseId,decision);
        var documents=finishedDocuments(report);assertEquals(2,documents.size());
        FullChainEndToEndTest chain=(FullChainEndToEndTest)ReflectionTestUtils.getField(fixture,"fixture");documents.forEach(chain::confirmFinishedInboundFully);
        qty("1200",productBalance(task));qty("1000",scalar("SELECT planned_qty FROM production_execution_segments WHERE id=?",id(task,"segment")));
        ReflectionTestUtils.invokeMethod(fixture,"drainValuation",task);
        assertThrows(ApiException.class,()->reports.reverse(report));
        var stock=beans.getBean(com.uten.imp.features.stock.StockDocService.class);
        for(UUID document:documents.reversed()) {
            stock.reverseFinishedInbound(document);ReflectionTestUtils.invokeMethod(fixture,"drainValuation",task);
        }
        reports.reverse(report);qty("0",productBalance(task));qty("900",book(demand));qty("100",pending(demand));
        assertEquals("WITHDRAWN",dispositions.detail(caseId).status());
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_over_limit_decisions WHERE disposition_id=?",Integer.class,caseId));
    }
    @Test void subQuantumWarehouseWorkshopAndRecoveryRequestsFailSavingWithoutAnyDraftOrMaterialPosting() {
        Object task=task();UUID demand=id(task,"demand");
        for(String route:List.of("WAREHOUSE","WORKSHOP","RECOVERY")) {
            var input=request(task,"0.0001","0.0001");var item=input.getItems().getFirst();item.setUnitRate(new BigDecimal("0.4"));
            if("WORKSHOP".equals(route))item.setAllocations(List.of(DailyReportOutputAllocationLine.direct(UUID.randomUUID(),item.getQty())));
            if("RECOVERY".equals(route))item.setFqcRecoveryAuthorizationId(UUID.randomUUID());
            var failure=assertThrows(ApiException.class,()->reports.create(input));
            assertTrue(failure.getMessage().contains("基本量不足0.0001"),failure.getMessage());
            qty("0.0001",item.getQty());qty("0.4",item.getUnitRate());
            assertEquals(0,db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE idempotency_key=?",Integer.class,input.getIdempotencyKey()));
            assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_settlement_events WHERE plan_id=?",Integer.class,id(task,"plan")));
            qty("10",book(demand));
        }
    }
    private List<UUID> finishedDocuments(UUID report){return db.queryForList("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted ORDER BY bill_no",UUID.class,report);}
    private FullChainEndToEndTest.World world(Object task){return ReflectionTestUtils.invokeMethod(task,"world");}
    private BigDecimal productBalance(Object task){return db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,id(task,"product"));}
    private BigDecimal scalar(String sql,UUID id){return db.queryForObject(sql,BigDecimal.class,id);}
    private long version(UUID segment){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
    private DailyReportSaveRequest splitRequest(Object c,UUID segment,UUID demand,String output,String used){
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(c,"world");
        var request=new DailyReportSaveRequest();request.setIdempotencyKey("v3-split-report-"+UUID.randomUUID());request.setBillDate(com.uten.imp.common.time.BusinessTime.today());
        request.setDepartmentId(id(c,"workshop"));request.setWorkerIds(List.of(id(c,"worker")));
        var item=new DailyReportItemLine();item.setLineNo(1);item.setExecutionSegmentId(segment);
        item.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,segment));
        item.setGoodsId(id(c,"root"));item.setUnitId(world.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal(output));request.setItems(List.of(item));
        var usage=new DailyReportMaterialUsageLine();usage.setDemandId(demand);usage.setQtyBase(new BigDecimal(used));request.setMaterialLines(List.of(usage));return request;
    }
    private Object task(){return ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","material-v3-"+UUID.randomUUID(),false,"10");}
    private UUID id(Object task,String name){return ReflectionTestUtils.invokeMethod(task,name);}
    private ReportablePlanLine source(Object task){List<ReportablePlanLine> values=ReflectionTestUtils.invokeMethod(fixture,"sources",task);return values.getFirst();}
    private DailyReportSaveRequest request(Object task,String output,String used){return ReflectionTestUtils.invokeMethod(fixture,"reportRequest",task,source(task),output,used);}
    private DailyReportApproveRequest approve(DailyReportMaterialReview review,String action){
        var request=new DailyReportApproveRequest();request.setIdempotencyKey("review-v3-"+UUID.randomUUID());request.setCommandVersion(3);
        request.setExpectedVersion(review.reportVersion());request.setMaterialReviewFingerprint(review.fingerprint());
        request.setMaterialDecisions(review.rows().stream().map(row->new DailyReportMaterialDecision(row.demandId(),action)).toList());return request;
    }
    private BigDecimal book(UUID demand){return db.queryForObject("SELECT COALESCE(SUM(fn_material_issue_available(id,NULL)),0) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",BigDecimal.class,demand);}
    private BigDecimal pending(UUID demand){return db.queryForObject("SELECT COALESCE(SUM(fn_material_issue_pending_return(id,NULL)),0) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",BigDecimal.class,demand);}
    private int events(UUID report){return db.queryForObject("SELECT count(*) FROM production_material_settlement_events WHERE daily_report_id=?",Integer.class,report);}
    private int approvalCount(UUID report){return db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE report_id=? AND command_kind='APPROVE'",Integer.class,report);}
    private int returnCount(Object task){return db.queryForObject("SELECT count(*) FROM production_material_return_requests WHERE plan_id=?",Integer.class,id(task,"plan"));}
    private BigDecimal warehouseBalance(Object task){FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(task,"world");return db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,world.warehouseId(),id(task,"material"));}
    private UUID submitReturn(Object task,String qty){
        var source=returns.sources(id(task,"plan"),id(task,"segment")).getFirst();
        return returns.submit(id(task,"plan"),new ProductionMaterialReturnRequest.Submit(id(task,"segment"),"return-before-review-"+UUID.randomUUID(),
                "核对现有余料退仓额度",List.of(new ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal(qty))))).getFirst().documentId();
    }
    private void consume(Object task,String qty){
        var request=new ProductionMaterialSettlementRequest();request.setExecutionSegmentId(id(task,"segment"));request.setIdempotencyKey("other-consumption-"+UUID.randomUUID());request.setReason("核对材料并登记另一笔实际用料");
        var line=new ProductionMaterialSettlementRequest.Line();line.setDemandId(id(task,"demand"));line.setSettlementType("CONSUMED");line.setQtyBase(new BigDecimal(qty));request.setLines(List.of(line));
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(task,"world");settlements.post(id(task,"plan"),request,world.superAdminUserId());
    }
    private static void qty(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+" but was "+actual);}
}
