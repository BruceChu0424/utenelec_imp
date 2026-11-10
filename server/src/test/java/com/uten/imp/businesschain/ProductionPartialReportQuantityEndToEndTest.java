package com.uten.imp.businesschain;

import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService;
import com.uten.imp.features.production.execution.ProductionExecutionWorkbenchSegment;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
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
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/** The screenshot's 1000 -> 800 -> 200 flow across persisted report, FQC, receipt and task projection. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.workshop-material.auto-close.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionPartialReportQuantityEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionDailyReportService reports;
    @Autowired ProductionExecutionWorkbenchService workbench;
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test void partialIssueLimitsCombinedDraftsAndEditsWhilePreservingExactInputs() {
        var fixture = preparedFixture();
        Object task = partialTask(fixture,"partial-report-drafts");
        ReportablePlanLine initial=source(fixture,task);
        amount("500",initial.maxReportQty()); amount("500",initial.materialReportQty());
        var excessive=request(fixture,task,initial,"600","500");
        var failure=assertThrows(ApiException.class,()->reports.create(excessive));
        assertTrue(failure.getMessage().contains("物料配套可报数量 500"),failure.getMessage());
        amount("600",excessive.getItems().getFirst().getQty());
        var duplicate=request(fixture,task,initial,"300","500");
        var other=request(fixture,task,initial,"250","0").getItems().getFirst(); other.setLineNo(2);
        duplicate.setItems(List.of(duplicate.getItems().getFirst(),other));
        assertTrue(assertThrows(ApiException.class,()->reports.create(duplicate)).getMessage().contains("物料配套"));
        UUID draft=reports.create(request(fixture,task,initial,"300","300")).getId();
        amount("200",source(fixture,task).materialReportQty());
        var edited=request(fixture,task,initial,"400","400");
        edited.setExpectedVersion(reports.detail(draft).getRowVersion());
        reports.update(draft,edited); // Exclude the original draft; 400 is within 500.
        amount("100",source(fixture,task).materialReportQty());
        assertTrue(assertThrows(ApiException.class,()->reports.create(request(fixture,task,initial,"101","100")))
                .getMessage().contains("物料配套可报数量 100"));
        reports.delete(draft);
        amount("500",source(fixture,task).materialReportQty());
    }

    @Test void pendingMaterialReturnReducesReportRoomAndCancellationRestoresIt() {
        var fixture=preparedFixture(); Object task=partialTask(fixture,"partial-report-return");
        var initial=source(fixture,task);
        UUID draft=reports.create(request(fixture,task,initial,"450","400")).getId();
        var returns=beans.getBean(ProductionMaterialReturnRequestService.class);
        UUID plan=id(task,"plan"),segment=id(task,"segment");
        var issue=returns.sources(plan,segment).getFirst();
        var docs=returns.submit(plan,new ProductionMaterialReturnRequest.Submit(segment,"partial-return-"+UUID.randomUUID(),
                "部分领料待退，核对物料配套上限",List.of(new ProductionMaterialReturnRequest.Item(issue.issuePostingId(),new BigDecimal("100")))));
        var failure=assertThrows(ApiException.class,()->reports.approve(draft,approve(draft)));
        assertTrue(failure.getMessage().contains("物料配套"),failure.getMessage());
        returns.cancel(plan,docs.getFirst().documentId(),new ProductionMaterialReturnRequest.Cancel("partial-cancel-"+UUID.randomUUID(),"取消待退材料申请"));
        reports.approve(draft,approve(draft));
        amount("50",source(fixture,task).materialReportQty());
        reports.reverse(draft);
        amount("500",source(fixture,task).materialReportQty());
    }

    @Test void twoConcurrentOperatorsCannotTogetherExceedTheSamePartialIssue() throws Exception {
        var fixture=preparedFixture();Object task=partialTask(fixture,"partial-report-concurrent");
        var initial=source(fixture,task);
        var auth=SecurityContextHolder.getContext().getAuthentication();
        var ready=new CountDownLatch(2);var go=new CountDownLatch(1);
        var requests=List.of(request(fixture,task,initial,"300","300"),request(fixture,task,initial,"300","300"));
        try(var executor=Executors.newFixedThreadPool(2)) {
            var futures=requests.stream().map(input->executor.submit(()->{
                var context=SecurityContextHolder.createEmptyContext();context.setAuthentication(auth);SecurityContextHolder.setContext(context);
                ready.countDown();
                try { assertTrue(go.await(30,TimeUnit.SECONDS));return reports.create(input).getId(); }
                catch(ApiException conflict){assertTrue(conflict.getMessage().contains("物料配套"),conflict.getMessage());return null;}
                finally {SecurityContextHolder.clearContext();}
            })).toList();
            assertTrue(ready.await(30,TimeUnit.SECONDS));go.countDown();
            int successes=0;for(var future:futures)if(future.get(90,TimeUnit.SECONDS)!=null)successes++;
            assertEquals(1,successes);amount("200",source(fixture,task).materialReportQty());
        }
    }

    @Test void reversingAPreviouslyCompleteIssueRestoresThePartialLimitUntilReissue() {
        var fixture=preparedFixture();
        Object task=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","partial-reverse-"+UUID.randomUUID(),false,"1000");
        assertNull(source(fixture,task).materialReportQty());
        var issue=db.queryForMap("""
                SELECT item.id,item.doc_id FROM stock_document_items item
                JOIN production_planning_package_documents mapping ON mapping.document_id=item.doc_id
                WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW' AND NOT item.is_deleted
                """,id(task,"segment"));
        var item=new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line();
        item.setItemId((UUID)issue.get("id"));item.setQty(new BigDecimal("100"));
        var reverse=new com.uten.imp.features.stock.dto.StockDocIssueRequest();
        reverse.setIdempotencyKey("partial-reverse-"+UUID.randomUUID());reverse.setReason("未投入的一百件按原实际发料红冲");reverse.setLines(List.of(item));
        var stock=beans.getBean(com.uten.imp.features.stock.StockDocService.class);
        stock.reverseIssue((UUID)issue.get("doc_id"),reverse);
        var partial=source(fixture,task);amount("900",partial.materialReportQty());
        var rejected=assertThrows(ApiException.class,()->reports.create(request(fixture,task,partial,"901","900")));
        assertTrue(rejected.getMessage().contains("物料配套可报数量 900"),rejected.getMessage());
        var reissue=new com.uten.imp.features.stock.dto.StockDocIssueRequest();
        reissue.setIdempotencyKey("partial-reissue-"+UUID.randomUUID());reissue.setLines(List.of(item));
        stock.approveAndIssue((UUID)issue.get("doc_id"),reissue);
        assertNull(source(fixture,task).materialReportQty());
    }

    private WorkshopPublicSurplusEndToEndTest preparedFixture() {
        var fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();return fixture;
    }
    private Object partialTask(WorkshopPublicSurplusEndToEndTest fixture,String tag) {
        return ReflectionTestUtils.invokeMethod(fixture,"createStartedTask",tag+UUID.randomUUID(),false,"1000",false,new BigDecimal("0.5"));
    }
    private DailyReportSaveRequest request(WorkshopPublicSurplusEndToEndTest fixture,Object task,ReportablePlanLine source,String output,String material) {
        return ReflectionTestUtils.invokeMethod(fixture,"reportRequest",task,source,output,material);
    }

    @Test void reportingEightHundredKeepsTwoHundredOpenWithoutExpandingReportQualityOrReceipt() {
        var fixture = new WorkshopPublicSurplusEndToEndTest();
        beans.autowireBean(fixture);
        fixture.prepare();
        Object task = ReflectionTestUtils.invokeMethod(fixture, "createStartedTask",
                "partial-quantity-" + UUID.randomUUID(), false, "1000");
        UUID segment = id(task, "segment"), planItem = id(task, "planItem"), orderItem = id(task, "orderItem");
        ReportablePlanLine firstSource = source(fixture, task);
        amount("1000", firstSource.maxReportQty());
        DailyReportSaveRequest firstRequest = ReflectionTestUtils.invokeMethod(fixture, "reportRequest",
                task, firstSource, "800", "800");
        UUID first = reports.create(firstRequest).getId();
        assertEquals(first, reports.create(firstRequest).getId(), "same CREATE key must replay the saved 800");
        assertReport(first, firstSource, "800");
        assertTask(task, "IN_PROGRESS", "0", "1000", "0");
        amount("200", source(fixture, task).maxReportQty());

        var firstApproval = approve(first);
        reports.approve(first, firstApproval);
        reports.approve(first, firstApproval);
        assertReport(first, firstSource, "800");
        assertTask(task, "IN_PROGRESS", "800", "200", "0");
        amount("800", scalar("SELECT fqty FROM production_plan_items WHERE id=?", planItem));
        amount("0", scalar("SELECT produced_qty FROM sales_order_items WHERE id=?", orderItem));
        amount("800", scalar("SELECT produced_qty FROM plan_order_item_links WHERE plan_item_id=? AND NOT is_deleted", planItem));
        amount("800", reports.detail(first).getMaterialUsages().getFirst().getQtyBase());
        ReflectionTestUtils.invokeMethod(fixture, "finishInbound", task, first,true);
        amount("800", scalar("SELECT produced_qty FROM sales_order_items WHERE id=?", orderItem));
        amount("800", scalar("SELECT SUM(reported_qty) FROM production_fqc_inspections WHERE source_report_id=?", first));
        amount("800", scalar("SELECT SUM(passed_qty) FROM production_fqc_inspections WHERE source_report_id=?", first));
        assertTask(task, "IN_PROGRESS", "800", "200", "800");

        ReflectionTestUtils.invokeMethod(fixture,"drainValuation",task);
        ReportablePlanLine secondSource = source(fixture, task);
        amount("200", secondSource.maxReportQty());
        assertEquals(firstSource.executionSegmentId(), secondSource.executionSegmentId());
        assertEquals(firstSource.executionSegmentSalesAllocationId(), secondSource.executionSegmentSalesAllocationId());
        assertEquals(firstSource.orderItemId(), secondSource.orderItemId());
        DailyReportSaveRequest secondRequest = ReflectionTestUtils.invokeMethod(fixture, "reportRequest",
                task, secondSource, "200", "200");
        UUID second = reports.create(secondRequest).getId();
        assertReport(second, secondSource, "200");
        assertTask(task, "IN_PROGRESS", "800", "200", "800");
        reports.approve(second, approve(second));
        assertTask(task, "REPORT_INSPECTION", "1000", "0", "800");
        ReflectionTestUtils.invokeMethod(fixture, "finishInbound", task, second,true);
        assertTask(task, "COMPLETED", "1000", "0", "1000");
        amount("200", scalar("SELECT SUM(reported_qty) FROM production_fqc_inspections WHERE source_report_id=?", second));
        amount("1000", scalar("SELECT SUM(qty) FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id WHERE item.execution_segment_id=? AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted", segment));
        amount("1000", scalar("SELECT planned_qty FROM production_execution_segments WHERE id=?", segment));
        amount("1000", scalar("SELECT allocated_qty FROM plan_order_item_links WHERE plan_item_id=? AND NOT is_deleted", planItem));
    }

    private void assertReport(UUID report, ReportablePlanLine source, String quantity) {
        var items = reports.detail(report).getItems();
        assertEquals(1, items.size());
        var row = items.getFirst();
        amount(quantity, row.getQty());
        amount(quantity, row.getOutputBatchQty());
        assertEquals(source.planItemId(), row.getPlanItemId());
        assertEquals(source.executionSegmentId(), row.getExecutionSegmentId());
        assertEquals(source.executionSegmentSalesAllocationId(), row.getExecutionSegmentSalesAllocationId());
        assertEquals(source.orderItemId(), row.getSalesOrderItemId());
        assertFalse(Boolean.TRUE.equals(row.getIsFinal()));
    }
    private void assertTask(Object task, String bucket, String reported, String remaining, String inbound) {
        UUID segment = id(task, "segment");
        ProductionExecutionWorkbenchSegment row = workbench.workshopTasks(1, 50, null, bucket,
                id(task, "workshop"), null, null).getItems().stream()
                .filter(candidate -> segment.equals(candidate.segmentId())).findFirst().orElseThrow();
        amount("1000", row.plannedQty());
        amount(reported, row.reportedQty());
        amount(remaining, row.remainingReportQty());
        amount(inbound, row.inboundQty());
        assertEquals("IN_PROGRESS".equals(bucket), row.canReport() && row.remainingReportQty().signum() > 0);
    }
    private DailyReportApproveRequest approve(UUID report) {
        var review = reports.materialReview(report);
        var request = new DailyReportApproveRequest();
        request.setIdempotencyKey("partial-approve-" + UUID.randomUUID());
        request.setCommandVersion(3);
        request.setExpectedVersion(review.reportVersion());
        request.setMaterialReviewFingerprint(review.fingerprint());
        request.setMaterialDecisions(review.rows().stream()
                .map(row -> new DailyReportMaterialDecision(row.demandId(), "KEEP")).toList());
        return request;
    }
    private ReportablePlanLine source(WorkshopPublicSurplusEndToEndTest fixture, Object task) {
        List<ReportablePlanLine> sources = ReflectionTestUtils.invokeMethod(fixture, "sources", task);
        return sources.getFirst();
    }
    private UUID id(Object task, String name) { return ReflectionTestUtils.invokeMethod(task, name); }
    private BigDecimal scalar(String sql, Object argument) { return db.queryForObject(sql, BigDecimal.class, argument); }
    private static void amount(String expected, BigDecimal actual) {
        assertNotNull(actual);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), "expected " + expected + " but was " + actual);
    }
}
