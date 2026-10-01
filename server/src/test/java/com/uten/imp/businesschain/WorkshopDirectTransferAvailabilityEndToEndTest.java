package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportOutputAllocationLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.nio.file.Path;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real posting chain, unchanged block boundaries, and an SQL-origin budget for the duplicate read. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!",
        "uten.concurrency.verify-nested-footprint=false"})
@Import(ProductionJdbcMeasurement.Configuration.class)
class WorkshopDirectTransferAvailabilityEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionDailyReportService reports;

    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test void oneReceiverReadsEachPromotionSnapshotOnce() { verifyReceivers(1); }
    @Test void threeReceiversReadFreshSnapshotsWithoutRecheckingEachOne() { verifyReceivers(3); }
    @Test void elevenReceiversKeepImmediatePrivateHandoverAndLinearReads() { verifyReceivers(11); }

    @Test void partialCoverageStillAcceptsALaterExactDelivery() {
        var helper = new AggregateMaterialDirectTransferEndToEndTest();
        beans.autowireBean(helper); helper.before();
        var flow = helper.flow;
        var c = flow.createWithChild("2", 1);
        var shared = flow.writer.submit(c.analysis(), flow.command(c, List.of(
                flow.input(c, c.child(), "MAKE", "2", false)))).batches().getFirst();
        UUID parent = helper.issue(c, c.common(), "2").getFirst();
        UUID source = helper.segment(shared.planId());
        flow.receive(c, c.material(), "4"); helper.start(c, source);
        flow.fixture.loginAs(helper.worker(c));
        UUID target = helper.demand(helper.segment(parent));
        UUID first = helper.transfer(c, source, target, "1", "2");
        assertEquals(0, BigDecimal.ONE.compareTo(netIssued(target)));
        UUID second = helper.transfer(c, source, target, "1", "2");
        assertNotEquals(first, second);
        assertEquals(0, new BigDecimal("2").compareTo(netIssued(target)));
        assertEquals(0, new BigDecimal("4").compareTo(netIssued(helper.demand(source))));
        assertEquals(2, db.queryForObject("""
                SELECT count(*) FROM production_workshop_direct_transfer_items transfer
                JOIN production_daily_report_items item ON item.id=transfer.source_report_item_id
                WHERE item.report_id IN (?,?) AND transfer.reversal_id IS NULL
                """, Integer.class, first, second));
        assertEquals(0, BigDecimal.ZERO.compareTo(db.queryForObject(
                "SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.child())));
    }

    private BigDecimal netIssued(UUID demand) {
        return db.queryForObject("""
                SELECT COALESCE(SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base
                    WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END),0)
                FROM production_material_stock_postings WHERE demand_id=?
                """,BigDecimal.class,demand);
    }

    private void verifyReceivers(int receivers) {
        var helper = new AggregateMaterialDirectTransferEndToEndTest();
        beans.autowireBean(helper);
        helper.before();
        var flow = helper.flow;
        var c = flow.createWithChild("1", receivers);
        var shared = flow.writer.submit(c.analysis(), flow.command(c, List.of(
                flow.input(c, c.child(), "MAKE", Integer.toString(receivers), false)))).batches().getFirst();
        List<UUID> parents = helper.issue(c, c.common(), "1");
        assertEquals(receivers, parents.size());
        UUID source = helper.segment(shared.planId());
        flow.receive(c, c.material(), Integer.toString(receivers * 2));
        helper.start(c, source);
        flow.fixture.loginAs(helper.worker(c));
        var candidates = helper.direct().candidates(source, c.child(), null).candidates();
        assertEquals(receivers, candidates.size());

        var request = new DailyReportSaveRequest();
        request.setIdempotencyKey("availability-report-" + source);
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(c.world().warehouseId());
        request.setDepartmentId(c.workshop());
        request.setWorkerIds(List.of(c.worker()));
        var item = new DailyReportItemLine();
        item.setLineNo(1);
        item.setExecutionSegmentId(source);
        item.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?", UUID.class, source));
        item.setGoodsId(c.child());
        item.setUnitId(c.world().unitId());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(BigDecimal.valueOf(receivers));
        item.setAllocations(candidates.stream().map(candidate ->
                DailyReportOutputAllocationLine.direct(candidate.demandId(), BigDecimal.ONE)).toList());
        request.setItems(List.of(item));
        var usage = new DailyReportMaterialUsageLine();
        usage.setDemandId(helper.demand(source));
        usage.setQtyBase(BigDecimal.valueOf(receivers * 2L));
        request.setMaterialLines(List.of(usage));
        UUID reportId = reports.create(request).getId();
        var approval = DailyReportApproveRequests.freshKey();

        String traceProperty = "uten.jdbc.measurement.trace-directory";
        String previousTrace = System.getProperty(traceProperty);
        String traceRoot = previousTrace == null ? "target/readiness-availability" : previousTrace;
        System.setProperty(traceProperty, Path.of(traceRoot, receivers + "-receivers").toString());
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        try {
            reports.approve(reportId, approval);
        } finally {
            try { ProductionJdbcMeasurement.end(); }
            finally {
                if (previousTrace == null) System.clearProperty(traceProperty);
                else System.setProperty(traceProperty, previousTrace);
            }
        }

        // Same request remains one atomic transaction and each receiver owns one
        // inspection, physical inbound, and immediate DRAW posting of exactly 1.
        assertEquals(1, sample.commits);
        assertEquals(0, sample.rollbacks);
        assertEquals(receivers, db.queryForObject("""
                SELECT count(*) FROM production_fqc_inspections inspection
                JOIN production_daily_report_items item ON item.id=inspection.source_report_item_id
                WHERE item.report_id=? AND inspection.inspection_kind='WORKSHOP_SELF'
                  AND inspection.status='RESOLVED'
                """, Integer.class, reportId));
        assertEquals(receivers, db.queryForObject("""
                SELECT count(*) FROM stock_documents document JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
                WHERE document.source_daily_report_id=? AND document.doc_type='FINISHED_IN'
                  AND document.status=1 AND NOT document.is_deleted AND warehouse.is_line_side
                """, Integer.class, reportId));
        for (UUID parent : parents) {
            UUID segment = helper.segment(parent);
            BigDecimal posted = db.queryForObject("""
                    SELECT COALESCE(SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END),0)
                    FROM production_material_stock_postings WHERE demand_id=?
                    """, BigDecimal.class, helper.demand(segment));
            assertEquals(0, BigDecimal.ONE.compareTo(posted));
            assertEquals(0, db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='DRAW_REQUEST'",
                    Integer.class, segment));
        }
        assertEquals(0, BigDecimal.ZERO.compareTo(db.queryForObject(
                "SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?", BigDecimal.class, c.child())));
        reports.approve(reportId, approval);
        assertEquals(receivers, db.queryForObject("SELECT count(*) FROM production_workshop_direct_transfer_items transfer JOIN production_daily_report_items item ON item.id=transfer.source_report_item_id WHERE item.report_id=?",
                Integer.class, reportId), "replay must not manufacture another transfer");

        // Exact source rights still post immediately. Proven workshop-self
        // origins do not start a generic pre-approval readiness attempt; the
        // explicit direct handover reads once after its inbound is approved.
        long availabilityReads = originReads(sample, "stock_balances");
        long anomalyReads = originReads(sample, "production_workshop_direct_legacy_anomalies");
        System.out.println("READINESS-SNAPSHOT receivers=" + receivers + " availability=" + availabilityReads
                + " anomalies=" + anomalyReads + " totalStatements=" + sample.logicalStatements);
        assertEquals((long) receivers, availabilityReads);
        assertEquals((long) receivers, anomalyReads);
    }

    private static long originReads(ProductionJdbcMeasurement.Sample sample, String table) {
        return sample.statementOrigins.stream().filter(origin -> {
            var locations = (List<?>) origin.get("locations");
            var tables = (List<?>) origin.get("tables");
            return locations.stream().anyMatch(value -> value.toString().contains("ProductionExecutionReadinessService#availabilityRows:"))
                    && tables.contains(table);
        }).mapToLong(origin -> ((Number) origin.get("logicalStatements")).longValue()).sum();
    }
}
