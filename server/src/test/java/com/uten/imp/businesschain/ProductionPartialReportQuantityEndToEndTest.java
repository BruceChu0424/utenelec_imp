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
        ReflectionTestUtils.invokeMethod(fixture, "finishInbound", task, first);
        amount("800", scalar("SELECT produced_qty FROM sales_order_items WHERE id=?", orderItem));
        amount("800", scalar("SELECT SUM(reported_qty) FROM production_fqc_inspections WHERE source_report_id=?", first));
        amount("800", scalar("SELECT SUM(passed_qty) FROM production_fqc_inspections WHERE source_report_id=?", first));
        assertTask(task, "IN_PROGRESS", "800", "200", "800");

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
        ReflectionTestUtils.invokeMethod(fixture, "finishInbound", task, second);
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
