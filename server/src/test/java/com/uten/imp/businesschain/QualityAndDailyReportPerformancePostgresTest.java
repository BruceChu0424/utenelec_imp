package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.notice.outbox.BusinessOutboxScheduler;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportApproveRequest;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.features.warehouse.finishedin.FinishedArrivalTestSupport;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInRequest;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionPassRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

import static com.uten.imp.businesschain.WarehouseIqcScaleFixture.RECEIPT_QTY;
import static org.junit.jupiter.api.Assertions.*;

/**
 * Explicit opt-in, synthetic write-chain measurements. Each command includes its
 * real commit; fixture creation, verification, HTTP and background outbox delivery
 * are outside the window. Never connects to an existing database. Raw timings are
 * evidence, not a deployment SLO or a timing assertion on a shared CI machine.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_PRODUCTION_STRESS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.concurrency.verify-nested-footprint=false",
        "uten.workshop-material.auto-close.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@Import(ProductionJdbcMeasurement.Configuration.class)
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = QualityAndDailyReportPerformancePostgresTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class QualityAndDailyReportPerformancePostgresTest {
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine")
            .withCommand("postgres", "-c", "fsync=on", "-c", "synchronous_commit=on", "-c", "full_page_writes=on");
    private static final String SECRET = UUID.randomUUID() + "-" + UUID.randomUUID();
    private static final int REPORT_LINES = 10;

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry properties) {
        DATABASE.start();
        properties.add("spring.datasource.url", DATABASE::getJdbcUrl);
        properties.add("spring.datasource.username", DATABASE::getUsername);
        properties.add("spring.datasource.password", DATABASE::getPassword);
        properties.add("uten.jwt.secret", () -> SECRET);
        properties.add("uten.crypto.pgp-master-key", () -> SECRET);
        properties.add("uten.crypto.hmac-key", () -> SECRET);
        properties.add("uten.bootstrap.admin-login", () -> "quality-report-perf-bootstrap");
        properties.add("uten.bootstrap.admin-password", () -> SECRET + "Aa1!");
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) { DATABASE.stop(); }
    }

    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProductionDailyReportService reports;
    @Autowired ProcurementInspectionService iqc;
    @Autowired ProcurementIqcPreStockInService preStock;
    @Autowired ProductionFqcInspectionService fqc;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired BusinessOutboxScheduler outboxScheduler;
    @Autowired com.uten.imp.application.concurrency.FulfillmentMutationLocks fulfillmentLocks;
    @Autowired org.springframework.core.env.Environment environment;

    @BeforeEach void isolateBackgroundDelivery() {
        // Events still commit normally. Async notification delivery is explicitly
        // excluded so an unrelated drain cannot contend with the measured writer.
        outboxScheduler.close();
        assertEquals(Boolean.FALSE, ReflectionTestUtils.getField(fulfillmentLocks,"verifyNestedFootprint"));
        assertFalse(environment.getProperty("uten.concurrency.verify-nested-footprint",Boolean.class,true));
    }

    @AfterEach void clear() {
        ProductionJdbcMeasurement.end();
        SecurityContextHolder.clearContext();
    }

    @Test void fourReceiptsQualityApprovalIncludesAutomaticPhysicalStockInAndReplays() throws Exception {
        for (int repetition = 0; repetition < repetitions(); repetition++) {
            int linesPerReceipt = iqcLinesPerReceipt();
            var scenario = linesPerReceipt == 1
                    ? new WarehouseIqcScaleFixture(beans, db).prepare(4, tag("iqc"))
                    : new WarehouseIqcMultiLineFixture(beans, db).prepare(4, linesPerReceipt, tag("iqc"));
            var fixture = fixture();
            fixture.loginAs(scenario.world().superAdminUserId());
            Map<UUID, List<WarehouseIqcScaleFixture.Receipt>> grouped = new LinkedHashMap<>();
            for (var row : scenario.receipts()) grouped.computeIfAbsent(row.id(), ignored -> new ArrayList<>()).add(row);
            Map<UUID, BatchInspectionPassRequest> commands = new LinkedHashMap<>();
            for (var rows : grouped.values()) {
                var receipt = rows.getFirst();
                assertEquals(linesPerReceipt, rows.size());
                preStock.preStockIn(receipt.type(), receipt.id(), new PreStockInRequest(rows.stream().map(row ->
                        new PreStockInItem(row.inspectionId(), row.warehouseId(), "PERF-01")).toList()));
                commands.put(receipt.id(), new BatchInspectionPassRequest(rows.stream().map(row -> new BatchInspectionPassRequest.Item(
                        row.inspectionId(), RECEIPT_QTY, "perf-iqc-" + row.inspectionId())).toList(), null));
                for (var row : rows) assertEquals(0, db.queryForObject("SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?",
                        BigDecimal.class, row.inspectionId()).signum());
            }
            Supplier<Integer> command = () -> {
                commands.forEach((receipt, request) -> iqc.passBatch(grouped.get(receipt).getFirst().type(), receipt, request));
                return commands.size();
            };
            assertEquals(4, measure("iqc-four-receipts", repetition, 4, command));
            for (var receipt : scenario.receipts()) {
                quantity(RECEIPT_QTY, db.queryForObject("SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?",
                        BigDecimal.class, receipt.inspectionId()));
                quantity(RECEIPT_QTY, db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                        BigDecimal.class, receipt.warehouseId(), receipt.goodsId()));
                assertEquals(1, db.queryForObject("SELECT count(*) FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",
                        Integer.class, receipt.inspectionId()));
            }
            var facts = iqcFacts(scenario);
            assertEquals(4, measure("iqc-four-receipts-replay", repetition, 4, command));
            assertEquals(facts, iqcFacts(scenario), "replay cannot change quality, stock, value or audit facts");
        }
    }

    @Test void tenReportLinesMeasureCreateAndApproveSeparatelyAndPreserveOriginalReplay() throws Exception {
        for (int repetition = 0; repetition < repetitions(); repetition++) {
            var workshop = new WorkshopPublicSurplusEndToEndTest();
            beans.autowireBean(workshop);
            workshop.prepare();
            Object task = ReflectionTestUtils.invokeMethod(workshop, "createStartedTask", tag("report"), false, "10");
            @SuppressWarnings("unchecked") List<ReportablePlanLine> sources = ReflectionTestUtils.invokeMethod(workshop, "sources", task);
            DailyReportSaveRequest request = ReflectionTestUtils.invokeMethod(workshop, "reportRequest", task, sources.getFirst(), "1", "10");
            List<DailyReportItemLine> lines = new ArrayList<>();
            for (int line = 1; line <= REPORT_LINES; line++) {
                var item = json.readValue(json.writeValueAsBytes(request.getItems().getFirst()), DailyReportItemLine.class);
                item.setLineNo(line);
                lines.add(item);
            }
            request.setItems(lines);
            byte[] original = json.writeValueAsBytes(request);
            var created = measure("report-ten-create", repetition, 1, () -> reports.create(request));
            assertEquals(REPORT_LINES, created.getItems().size());
            assertEquals(0, db.queryForObject("SELECT status FROM production_daily_reports WHERE id=?", Integer.class, created.getId()));
            var approval = new DailyReportApproveRequest();
            approval.setIdempotencyKey("perf-report-approve-" + created.getId());
            measure("report-ten-approve", repetition, 1, () -> reports.approve(created.getId(), approval));
            assertEquals(1, db.queryForObject("SELECT status FROM production_daily_reports WHERE id=?", Integer.class, created.getId()));
            quantity(BigDecimal.TEN, db.queryForObject("SELECT SUM(qty) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",
                    BigDecimal.class, created.getId()));
            assertEquals(REPORT_LINES, db.queryForObject("SELECT count(*) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",
                    Integer.class, created.getId()));
            var facts = reportFacts(created.getId());
            DailyReportSaveRequest repeated = json.readValue(original, DailyReportSaveRequest.class);
            assertEquals(created.getId(), measure("report-ten-create-replay", repetition, 1, () -> reports.create(repeated)).getId());
            measure("report-ten-approve-replay", repetition, 1, () -> reports.approve(created.getId(), approval));
            assertEquals(facts, reportFacts(created.getId()), "original create/approve retries must not duplicate any source or movement");
        }
    }

    @Test void fourFinishedReportsQualityApprovalRetainsAllReleaseSourcesAndReplays() throws Exception {
        for (int repetition = 0; repetition < repetitions(); repetition++) {
            var fixture = fixture();
            var world = fixture.seedWorld(tag("fqc"));
            ReflectionTestUtils.invokeMethod(fixture, "receiveOpeningInputsForA", world, "40");
            List<UUID> reportIds = new ArrayList<>();
            List<UUID> inspectionIds = new ArrayList<>();
            for (int index = 0; index < 4; index++) {
                Object report = ReflectionTestUtils.invokeMethod(fixture, "approvedMultiLineReportOfNewPlan", world, (Object) new String[]{"10"});
                UUID id = ReflectionTestUtils.invokeMethod(report, "id");
                reportIds.add(id);
                List<UUID> items = db.queryForList("SELECT id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted ORDER BY line_no", UUID.class, id);
                FinishedArrivalTestSupport.registerItems(arrivals, id, "perf-arrival-" + id, world.warehouseId(), items, "Synthetic performance arrival");
                inspectionIds.addAll(db.queryForList("SELECT id FROM production_fqc_inspections WHERE source_report_id=? ORDER BY id", UUID.class, id));
            }
            fixture.loginAs(world.superAdminUserId());
            assertEquals(4, inspectionIds.size());
            var request = new PassAllBatchRequest(List.copyOf(inspectionIds), "perf-fqc-" + UUID.randomUUID());
            var result = measure("fqc-four-reports", repetition, 1, () -> fqc.passAll(request));
            assertFalse(result.replay());
            assertEquals(4, result.items().size());
            for (var item : result.items()) {
                assertEquals(fqc.detail(item.inspectionId()), item.inspection());
                assertEquals("RESOLVED", item.inspection().status());
                quantity(BigDecimal.TEN, item.inspection().authorizedInboundQty());
                assertEquals(1, db.queryForObject("SELECT count(*) FROM production_fqc_pass_all_batch_items WHERE batch_id=? AND inspection_id=? AND decision_event_id=?",
                        Integer.class, result.batchId(), item.inspectionId(), item.decisionEventId()));
            }
            for (UUID report : reportIds) assertEquals(1, db.queryForObject("SELECT count(*) FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted", Integer.class, report));
            var facts = reportIds.stream().map(this::reportFacts).toList();
            var replay = measure("fqc-four-reports-replay", repetition, 1, () -> fqc.passAll(request));
            assertTrue(replay.replay());
            assertEquals(result.batchId(), replay.batchId());
            assertEquals(result.items(), replay.items());
            assertEquals(facts, reportIds.stream().map(this::reportFacts).toList());
        }
    }

    private <T> T measure(String phase, int repetition, int commits, Supplier<T> action) throws Exception {
        var sample = ProductionJdbcMeasurement.begin();
        long start = System.nanoTime();
        T result;
        long elapsed;
        try { result = action.get(); }
        finally { elapsed = System.nanoTime() - start; ProductionJdbcMeasurement.end(); }
        assertEquals(commits, sample.commits, phase + " must include the real transaction commit");
        assertEquals(0, sample.rollbacks);
        Map<String, Object> record = new LinkedHashMap<>(sample.result());
        record.put("statementOrigins", sample.statementOrigins);
        record.put("phase", phase);
        record.put("repetition", repetition);
        record.put("elapsedMillis", elapsed / 1_000_000.0);
        record.put("scope", "synthetic service plus commit; excludes fixture preparation, HTTP and asynchronous outbox delivery");
        record.put("databaseSettings", db.queryForMap("SELECT current_setting('server_version') AS version, current_setting('fsync') AS fsync, current_setting('synchronous_commit') AS synchronous_commit, current_setting('full_page_writes') AS full_page_writes"));
        record.put("sourceIdentity", System.getProperty("uten.perf.source-identity", "unspecified"));
        record.put("diagnostic",System.getProperty("uten.jdbc.measurement.trace-directory")!=null);
        record.put("verifyNestedFootprint",environment.getProperty("uten.concurrency.verify-nested-footprint",Boolean.class));
        record.put("fixture",phase.startsWith("iqc-")?"four receipts, half purchase/half subcontract, two warehouses, pre-stock then quality auto-stock":
                phase.startsWith("fqc-")?"four finished reports, one output line each, quality releases drafts":
                        "ten separate output lines on one execution segment; simple reference only");
        record.put("backgroundWork","outbox dispatcher closed; audit retention, materialized view refresh, readiness reconcile, workshop auto-close and policy intelligence disabled; inventory value worker delayed one hour");
        if (phase.startsWith("iqc-")) record.put("linesPerReceipt", iqcLinesPerReceipt());
        String directory = System.getProperty("uten.perf.report-directory");
        if (directory != null && !directory.isBlank()) {
            Path path = Path.of(directory);
            Files.createDirectories(path);
            json.writerWithDefaultPrettyPrinter().writeValue(path.resolve(phase + "-" + repetition + ".json").toFile(), record);
        }
        System.out.println("QUALITY-REPORT-PERF phase=" + phase + " repetition=" + repetition + " elapsedMillis=" + elapsed / 1_000_000.0
                + " jdbcCalls=" + sample.jdbcCalls + " jdbcMillis=" + sample.jdbcNanos / 1_000_000.0 + " commitMillis=" + sample.commitNanos / 1_000_000.0);
        return result;
    }

    private Map<String, Object> reportFacts(UUID report) {
        return db.queryForMap("""
                SELECT r.status,r.row_version,r.xmin::text AS row_xmin,
                       (SELECT count(*) FROM production_daily_report_items i WHERE i.report_id=r.id) AS items,
                       (SELECT count(*) FROM production_fqc_inspections i WHERE i.source_report_id=r.id) AS inspections,
                       (SELECT count(*) FROM stock_documents d WHERE d.source_daily_report_id=r.id) AS documents,
                       (SELECT count(*) FROM stock_movements) AS movements,
                       (SELECT count(*) FROM stock_value_events) AS value_events
                FROM production_daily_reports r WHERE r.id=?
                """, report);
    }

    private List<Map<String, Object>> iqcFacts(WarehouseIqcScaleFixture.Scenario scenario) {
        return scenario.receipts().stream().map(receipt -> db.queryForMap("""
                SELECT i.status,i.passed_base_qty,i.failed_base_qty,i.warehouse_stocked_base_qty,i.xmin::text AS row_xmin,
                       (SELECT count(*) FROM procurement_inspection_events e WHERE e.inspection_item_id=i.id) AS events,
                       (SELECT count(*) FROM stock_movements) AS movements,
                       (SELECT count(*) FROM stock_value_events) AS value_events
                FROM procurement_inspection_items i WHERE i.id=?
                """, receipt.inspectionId())).toList();
    }

    private FullChainEndToEndTest fixture() {
        var fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        return fixture;
    }

    private static void quantity(BigDecimal expected, BigDecimal actual) { assertNotNull(actual); assertEquals(0, expected.compareTo(actual)); }
    private static String tag(String kind) { return "qr-" + kind + "-" + UUID.randomUUID().toString().substring(0, 8); }
    private static int repetitions() {
        int repetitions = Integer.getInteger("uten.perf.repetitions", 1);
        if (repetitions < 1 || repetitions > 10) throw new IllegalArgumentException("Use 1..10 independently prepared scenarios");
        return repetitions;
    }
    private static int iqcLinesPerReceipt() {
        int lines = Integer.getInteger("uten.perf.iqc-lines", 5);
        if (lines < 1 || lines > 75) throw new IllegalArgumentException("Use 1..75 distinct lines per IQC receipt");
        return lines;
    }
}
