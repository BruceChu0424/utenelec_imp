package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.execution.ProductionCompletionReverseService;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.*;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.*;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.*;

/** Real analysis-generated production, FQC and physical stock; only the measured PASS is timed. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.workshop-material.auto-close.enabled=false",
        "uten.policy-intelligence.enabled=false",
        "uten.inventory.value-work.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",

        "uten.concurrency.verify-nested-footprint=${uten.fqc.batch.verifyNestedFootprint:true}"})
@Import({ProductionJdbcMeasurement.Configuration.class, ProductionFqcPreStockBatchEndToEndTest.DeadlineProbeConfiguration.class})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = ProductionFqcPreStockBatchEndToEndTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class ProductionFqcPreStockBatchEndToEndTest {
    // 2026-09-30 same fixture measured at 3/5/20 rows: 111 SQL per physical
    // acceptance, 18 per draft-only PASS, with one 234/57 statement prefix.
    // Fixed headroom catches a per-row regression rather than hiding it in a percentage.
    private static final int POSTED_LINE_SQL = 111;
    private static final int DRAFT_LINE_SQL = 18;
    private static final int POSTED_BATCH_SQL = 234;
    private static final int DRAFT_BATCH_SQL = 57;
    private static final int SQL_HEADROOM = 12;
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine")
            .withCommand("postgres", "-c", "fsync=on", "-c", "synchronous_commit=on", "-c", "full_page_writes=on");
    private static final String SECRET = UUID.randomUUID() + "-" + UUID.randomUUID();

    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        DATABASE.start();
        properties.add("spring.datasource.url", DATABASE::getJdbcUrl);
        properties.add("spring.datasource.username", DATABASE::getUsername);
        properties.add("spring.datasource.password", DATABASE::getPassword);
        properties.add("uten.jwt.secret", () -> SECRET);
        properties.add("uten.crypto.pgp-master-key", () -> SECRET);
        properties.add("uten.crypto.hmac-key", () -> SECRET);
        properties.add("uten.bootstrap.admin-login", () -> "fqc-prestock-batch-bootstrap");
        properties.add("uten.bootstrap.admin-password", () -> SECRET + "Aa1!");
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) { DATABASE.stop(); }
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired MaterialAnalysisCommandService commands;
    @MockitoSpyBean MaterialAnalysisService analyses;
    @MockitoSpyBean ProductionCompletionReverseService completion;
    @Autowired StockDocService stock;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    @Autowired org.springframework.context.ApplicationContext applicationContext;
    @Autowired org.springframework.core.env.Environment environment;
    @Autowired DeadlineProbe deadlineProbe;
    @Autowired com.uten.imp.features.notice.outbox.BusinessOutboxScheduler outboxScheduler;

    @AfterEach void cleanup() {
        SecurityContextHolder.clearContext();
        ProductionJdbcMeasurement.end();
    }

    @Test void commandDeadlineIsWiredIntoTheRealApplicationTransactionInfrastructure() {
        var manager = assertInstanceOf(org.springframework.transaction.support.AbstractPlatformTransactionManager.class,
                transactionManager);
        assertTrue(manager.getTransactionExecutionListeners().stream().anyMatch(listener ->
                listener instanceof com.uten.imp.application.concurrency.FulfillmentCommandDeadlineTransactions));
        var interceptor = applicationContext.getBean("transactionInterceptor",
                org.springframework.transaction.interceptor.TransactionInterceptor.class);
        assertInstanceOf(com.uten.imp.application.concurrency.FulfillmentDeadlineTransactionAttributeSource.class,
                interceptor.getTransactionAttributeSource());
    }

    @Test void realJpaBusinessSqlAndProcessingTailBothRollBackWhenTheirDeadlineExpires() {
        db.execute("CREATE TABLE IF NOT EXISTS fqc_deadline_probe(id uuid PRIMARY KEY)");
        UUID sql = UUID.randomUUID(), processing = UUID.randomUUID();
        Throwable queryFailure = assertThrows(RuntimeException.class, () -> deadlineProbe.longSql(sql));
        assertTrue(causes(queryFailure).stream().anyMatch(cause -> cause instanceof java.sql.SQLException error
                && "57014".equals(error.getSQLState())), "Actual JPA SQL must be cancelled, not merely rejected afterwards");
        Throwable processingFailure = assertThrows(RuntimeException.class, () -> deadlineProbe.processingTail(processing));
        assertTrue(causes(processingFailure).stream().anyMatch(cause ->
                cause instanceof org.springframework.transaction.TransactionTimedOutException));
        assertEquals(0, db.queryForObject("SELECT count(*) FROM fqc_deadline_probe WHERE id IN (?,?)",
                Integer.class, sql, processing));
    }

    @org.springframework.boot.test.context.TestConfiguration(proxyBeanMethods = false)
    static class DeadlineProbeConfiguration {
        @org.springframework.context.annotation.Bean DeadlineProbe deadlineProbe() { return new DeadlineProbe(); }
    }

    public static class DeadlineProbe {
        @jakarta.persistence.PersistenceContext jakarta.persistence.EntityManager em;

        @org.springframework.transaction.annotation.Transactional(timeout = 1)
        public void longSql(UUID id) {
            em.createNativeQuery("INSERT INTO fqc_deadline_probe VALUES (:id)").setParameter("id", id).executeUpdate();
            em.createNativeQuery("SELECT 1 FROM pg_sleep(3)").getSingleResult();
        }

        @org.springframework.transaction.annotation.Transactional(timeout = 1)
        public void processingTail(UUID id) {
            em.createNativeQuery("INSERT INTO fqc_deadline_probe VALUES (:id)").setParameter("id", id).executeUpdate();
            try { Thread.sleep(1200); }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new IllegalStateException(interrupted); }
        }
    }

    private static List<Throwable> causes(Throwable failure) {
        List<Throwable> causes = new ArrayList<>();
        for (Throwable cause = failure; cause != null; cause = cause.getCause()) causes.add(cause);
        return causes;
    }

    @Test void configuredBatchesKeepFactsAndMeasureRealAnalysisRefreshes() throws Exception {
        boolean before = "before".equals(System.getProperty("uten.fqc.batch.run"));
        assertEquals(!before, com.uten.imp.application.port.ProductionPreStockedInboundPort.class
                .isAssignableFrom(StockDocService.class), "Loaded stock bytecode must match the selected before/after candidate");
        for (String sizeText : System.getProperty("uten.fqc.batch.sizes", "3").split(",")) {
            int size = Integer.parseInt(sizeText.strip());
            assertTrue(size >= 1 && size <= 20);
            for (String mode : System.getProperty("uten.fqc.batch.modes", "prestock,mixed,plain").split(",")) {
                Scenario scenario = prepare(size, mode.strip());
                var request = new PassAllBatchRequest(scenario.inspections(), "fqc-batch-" + scenario.reportId());
                Measured measured = measure(scenario, "pass", () -> quality.passAll(request));
                assertFalse(measured.result().replay());
                assertEquals(size, measured.result().items().size());
                assertFreshLotStatementBudget(measured);
                assertEquals(1, measured.sql().commits, "所有决定、自动点收、权益及刷新只提交一次");
                assertFacts(scenario);
                if (scenario.preStocked() == 0) {
                    assertEquals(0, measured.analysisRefreshes());
                } else if ("before".equals(System.getProperty("uten.fqc.batch.run"))) {
                    assertTrue(measured.analysisRefreshes() >= scenario.preStocked(),
                            "旧路径必须真实反复刷新同一分析, 否则不能作为优化基线");
                } else {
                    assertEquals(1, measured.analysisRefreshes(), "同批入库对受影响分析只做一次最终刷新");
                }
                for (var item : measured.result().items()) {
                    assertEquals(quality.detail(item.inspectionId()), item.inspection());
                }
                Measured replay = measure(scenario, "replay", () -> quality.passAll(request));
                assertTrue(replay.result().replay());
                assertEquals(measured.result().items(), replay.result().items());
                assertEquals(0, replay.analysisRefreshes());
                assertFacts(scenario);
                assertWorkBudget(scenario, measured, replay);
            }
        }
    }

    @Test void failureAtFinalAnalysisBoundaryRollsBackAllPhysicalAndQualityFacts() {
        Scenario scenario = prepare(2, "prestock");
        ProductionCompletionReverseService target = AopTestUtils.getUltimateTargetObject(completion);
        doAnswer(call -> {
            assertEquals(1, approvedDocs(scenario), "进入统一收尾之前这批实收入库(一张单两行)已即时完成");
            assertEquals(0, new BigDecimal("2").compareTo(balance(scenario)));
            throw new IllegalStateException("FQC final projection rejected");
        }).when(target).afterFinishedInboundBatchApproved(anyCollection());
        try {
            assertThrows(IllegalStateException.class, () -> quality.passAll(new PassAllBatchRequest(
                    scenario.inspections(), "fqc-batch-failing-" + scenario.reportId())));
        } finally {
            doCallRealMethod().when(target).afterFinishedInboundBatchApproved(anyCollection());
        }
        assertEquals(0, sourceCount("stock_documents", "source_daily_report_id", scenario));
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM production_fqc_decision_events event
                JOIN production_fqc_inspections inspection ON inspection.id=event.inspection_id
                WHERE inspection.source_report_id=?
                """, Integer.class, scenario.reportId()));
        assertEquals(0, balance(scenario).signum());
        assertEquals(0, db.queryForObject("SELECT count(*) FROM production_fqc_pass_all_batches WHERE idempotency_key=?",
                Integer.class, "fqc-batch-failing-" + scenario.reportId()));
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM business_outbox WHERE event_type IN ('PRODUCTION_FQC_RELEASED','PRODUCTION_FQC_RESOLVED')
                    AND aggregate_id IN (SELECT id FROM production_fqc_inspections WHERE source_report_id=?)
                """, Integer.class, scenario.reportId()));
    }

    @Test void twoAnalysesAndWarehousesKeepSeparateImmediateOwnershipAndOneRefreshEach() {
        Scenario first = prepare(1, "prestock"), second = prepare(1, "prestock");
        Object spy = AopTestUtils.getUltimateTargetObject(analyses);
        clearInvocations(spy);
        List<UUID> inspections = new ArrayList<>(first.inspections());
        inspections.addAll(second.inspections());
        var result = quality.passAll(new PassAllBatchRequest(inspections, "fqc-two-warehouses-" + UUID.randomUUID()));
        assertEquals(2, result.items().size());
        assertFacts(first);
        assertFacts(second);
        for (Scenario scenario : List.of(first, second)) {
            assertEquals(1, mockingDetails(spy).getInvocations().stream().filter(call ->
                    call.getMethod().getName().equals("refreshLocked") && call.getArguments().length == 1
                            && scenario.watcherAnalysis().equals(call.getArgument(0))).count());
        }
    }

    @Test void anEarlierPartialPassAndTheRemainingBatchKeepEveryPhysicalSlice() {
        Scenario scenario = prepare(2, "prestock");
        UUID first = scenario.inspections().getFirst();
        quality.decide(first, new DecisionRequest("PASS", new BigDecimal("0.4"), null,
                null, null, "fqc-earlier-partial-" + first));
        assertEquals(0, new BigDecimal("0.4").compareTo(balance(scenario)));
        var request = new PassAllBatchRequest(scenario.inspections(), "fqc-remaining-" + scenario.reportId());
        var result = quality.passAll(request);
        assertFalse(result.replay());
        assertFacts(scenario, 1);
        var replay = quality.passAll(request);
        assertTrue(replay.replay());
        assertEquals(result.items(), replay.items());
        assertFacts(scenario, 1);
    }

    @Test void batchedReleaseCommandsRemainIndividuallyReplayableAndRejectChangedQuantity() {
        Scenario scenario = prepare(2, "plain");
        quality.passAll(new PassAllBatchRequest(scenario.inspections(), "fqc-release-replay-" + scenario.reportId()));
        List<Map<String, Object>> releases = db.queryForList("""
                SELECT command.id, command.source_report_item_id, command.stock_document_item_id,
                       command.requested_qty, command.idempotency_key
                FROM production_fqc_release_commands command
                JOIN production_fqc_inspections inspection ON inspection.id=command.inspection_id
                WHERE inspection.source_report_id=? ORDER BY command.id
                """, scenario.reportId());
        assertEquals(2, releases.size());
        long allocations = db.queryForObject("SELECT count(*) FROM production_fqc_release_allocations", Long.class);
        var transaction = new org.springframework.transaction.support.TransactionTemplate(transactionManager);
        for (var row : releases) {
            var replay = transaction.execute(status -> quality.allocateReleasedQuantity(
                    (UUID) row.get("source_report_item_id"), (UUID) row.get("stock_document_item_id"),
                    (BigDecimal) row.get("requested_qty"), (String) row.get("idempotency_key")));
            assertNotNull(replay);
            assertEquals(row.get("id"), replay.releaseCommandId());
            assertThrows(com.uten.imp.common.web.ApiException.class, () -> transaction.execute(status ->
                    quality.allocateReleasedQuantity((UUID) row.get("source_report_item_id"),
                            (UUID) row.get("stock_document_item_id"),
                            ((BigDecimal) row.get("requested_qty")).add(BigDecimal.ONE),
                            (String) row.get("idempotency_key"))));
        }
        assertEquals(allocations, db.queryForObject("SELECT count(*) FROM production_fqc_release_allocations", Long.class));
        assertFacts(scenario);
    }

    @Test void fourPreStockedReportsKeepPhysicalFactsAndShareFinalAnalysisRefresh() throws Exception {
        outboxScheduler.close();
        assertEquals(Boolean.parseBoolean(System.getProperty("uten.fqc.batch.verifyNestedFootprint", "true")),
                environment.getProperty("uten.concurrency.verify-nested-footprint", Boolean.class, true));
        int repetitions = Integer.getInteger("uten.fqc.handoffs.repetitions", 1);
        assertTrue(repetitions >= 1 && repetitions <= 10);
        for (int repetition = 0; repetition < repetitions; repetition++) {
            List<Scenario> scenarios = prepareReports(1, "prestock", 4);
            Scenario first = scenarios.getFirst();
            List<UUID> inspections = scenarios.stream().flatMap(row -> row.inspections().stream()).toList();
            assertEquals(4, scenarios.stream().map(Scenario::reportId).distinct().count());
            assertEquals(4, inspections.size());
            var request = new PassAllBatchRequest(inspections, "fqc-four-handoffs-" + first.reportId());
            Measured measured = measure(scenarios, "four-handoffs-pass-" + repetition, () -> quality.passAll(request));
            assertEquals(1, measured.sql().commits, "Four quality reports and all physical receipts remain one atomic FQC command");
            assertEquals(4, measured.result().items().size());
            assertFreshLotStatementBudget(measured);
            assertEquals(1,statementCount(measured,"stock.confirm_graph"),"All four document graphs lock together before the first physical posting");
            assertEquals(4,statementCount(measured,"stock.prestock_proof"),"Each document proves its own recorded pre-stocked position once");
            assertEquals(4,statementCount(measured,"stock.plan_approval_proof"),"Each document checks its approved plan once in the shared lock window");
            assertEquals(4,statementCount(measured,"stock.plan_close"),"Plan closeout uses the final posted state once per document");
            assertEquals(4,statementCount(measured,"stock.document_items"),"Confirmation and approval reuse each document's exact locked items");
            assertEquals(1, measured.analysisRefreshes(), "The real shared observer analysis refreshes once after all four receipts");
            assertHandoffFacts(scenarios);
            Measured replay = measure(scenarios, "four-handoffs-replay-" + repetition, () -> quality.passAll(request));
            assertTrue(replay.result().replay());
            assertEquals(measured.result().items(), replay.result().items());
            assertEquals(0, replay.analysisRefreshes());
            assertHandoffFacts(scenarios);
        }
    }

    @Test void twentyPreStockedReportsMeasureFirstWarmupAndSteadyCommandsWithExactReplay() throws Exception {
        outboxScheduler.close();
        int steadySamples = Integer.getInteger("uten.fqc.twenty.steadySamples", 1);
        assertTrue(steadySamples >= 1 && steadySamples <= 5);
        List<String> phases = new ArrayList<>(List.of("first", "warmup"));
        for (int sample = 1; sample <= steadySamples; sample++) phases.add("steady-" + sample);
        for (String phase : phases) {
            // Fixture preparation exercises production services. "first" is the
            // first measured command, not a claim of a cold JVM/database cache.
            List<Scenario> scenarios = prepareReports(1, "prestock", 20);
            Scenario first = scenarios.getFirst();
            List<UUID> inspections = scenarios.stream().flatMap(row -> row.inspections().stream()).toList();
            assertEquals(20, scenarios.stream().map(Scenario::reportId).distinct().count());
            assertEquals(20, inspections.size());
            assertEquals(0, balance(first).signum(), "Pre-stock registration must not masquerade as accepted good stock");
            var request = new PassAllBatchRequest(inspections, "fqc-twenty-handoffs-" + first.reportId());
            Measured measured = measure(scenarios, "twenty-handoffs-" + phase + "-pass", () -> quality.passAll(request));
            assertFalse(measured.result().replay());
            assertEquals(20, measured.result().items().size());
            assertEquals(1, measured.sql().commits, "All twenty physical receipts must commit atomically");
            assertFreshLotStatementBudget(measured);
            assertEquals(1, statementCount(measured, "stock.confirm_graph"));
            assertEquals(20, statementCount(measured, "stock.prestock_proof"));
            assertEquals(20, statementCount(measured, "stock.document_items"));
            assertEquals(1, measured.analysisRefreshes());
            assertHandoffFacts(scenarios);
            var facts = handoffFacts(scenarios);
            Measured replay = measure(scenarios, "twenty-handoffs-" + phase + "-replay", () -> quality.passAll(request));
            assertTrue(replay.result().replay());
            assertEquals(measured.result().batchId(), replay.result().batchId());
            assertEquals(measured.result().items(), replay.result().items());
            assertEquals(0, replay.analysisRefreshes());
            assertEquals(0, statementCount(replay, "stock.confirm_graph"));
            assertEquals(facts, handoffFacts(scenarios), "Original-key replay preserves every quality, release, stock and ownership fact");
            assertHandoffFacts(scenarios);
        }
    }

    @Test void twentyLotsOnOneSheetCompareSequentialCommandsWithAtomicReport() throws Exception {
        outboxScheduler.close();
        boolean before = "before".equals(System.getProperty("uten.fqc.report.run", "after"));
        int samples = Integer.getInteger("uten.fqc.report.samples", 1);
        assertTrue(samples >= 1 && samples <= 5);
        for (int sample = 1; sample <= samples; sample++) {
            Scenario scenario = prepare(20, "prestock");
            List<UUID> lots = db.queryForList("""
                    SELECT source.output_lot_id FROM production_fqc_inspections inspection
                    JOIN production_daily_report_items source ON source.id=inspection.source_report_item_id
                    WHERE inspection.source_report_id=? ORDER BY source.line_no,source.id
                    """, UUID.class, scenario.reportId());
            assertEquals(20, lots.size());
            assertEquals(20, new HashSet<>(lots).size(), "The screen fixture must contain twenty actual output lots");
            assertEquals(1, db.queryForObject("""
                    SELECT count(DISTINCT sheet_item.sheet_id) FROM production_fqc_inspection_sheet_items sheet_item
                    JOIN production_fqc_inspections inspection ON inspection.id=sheet_item.inspection_id
                    WHERE inspection.source_report_id=?
                    """, Integer.class, scenario.reportId()), "All twenty rows belong to one real inspection sheet");
            assertEquals(0, balance(scenario).signum());
            List<LotSubmission> submissions = lots.stream().map(lot -> new LotSubmission(lot,
                    new LotDecisionRequest(BigDecimal.ONE, BigDecimal.ZERO, null, null,
                            "fqc-report-lot-" + lot))).toList();
            // Resolve the new request type only in the candidate branch. The exact
            // same test bytecode also runs against V858, where that type is absent.
            java.util.function.Supplier<Object> command = before
                    ? () -> submissions.stream().map(row -> quality.decideLot(row.lotId(), row.request())).toList()
                    : reportCommand(submissions);
            ReportMeasured fresh = measureReport(scenario, submissions, "sample-" + sample + "-submit", before, command);
            assertEquals(before ? 20 : 1, fresh.sql().commits,
                    "The old row loop commits twenty real transactions; the report commits exactly once");
            assertEquals(before ? 20 : 1, fresh.analysisRefreshes());
            assertTrue(fresh.receipts().stream().noneMatch(ReportReceipt::replay));
            assertReportFacts(scenario, fresh.receipts(), before ? 20 : 1);
            var facts = reportFacts(scenario);
            ReportMeasured replay = measureReport(scenario, submissions, "sample-" + sample + "-replay", before, command);
            assertEquals(before ? 20 : 1, replay.sql().commits);
            assertEquals(0, replay.analysisRefreshes());
            assertTrue(replay.receipts().stream().allMatch(ReportReceipt::replay));
            for (int index = 0; index < submissions.size(); index++) {
                assertEquals(fresh.receipts().get(index).commandId(), replay.receipts().get(index).commandId());
                assertEquals(fresh.receipts().get(index).lot(), replay.receipts().get(index).lot());
            }
            assertEquals(facts, reportFacts(scenario), "Original row keys cannot duplicate physical or quality facts");
            assertReportFacts(scenario, replay.receipts(), before ? 20 : 1);
        }
    }

    private java.util.function.Supplier<Object> reportCommand(List<LotSubmission> submissions) throws Exception {
        List<Map<String, Object>> items = submissions.stream().map(row -> {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("targetType", "LOT"); item.put("targetId", row.lotId());
            item.put("decision", null); item.put("passQty", row.request().passQty());
            item.put("failQty", row.request().failQty()); item.put("dispositionCode", row.request().dispositionCode());
            item.put("reason", row.request().reason()); item.put("idempotencyKey", row.request().idempotencyKey());
            return item;
        }).toList();
        Class<?> requestType = Class.forName("com.uten.imp.features.production.quality.ProductionFqcContracts$ReportDecisionRequest");
        Object request = json.convertValue(Map.of("items", items), requestType);
        java.lang.reflect.Method method = quality.getClass().getMethod("decideReport", requestType);
        return () -> {
            try { return method.invoke(quality, request); }
            catch (java.lang.reflect.InvocationTargetException failed) {
                if (failed.getCause() instanceof RuntimeException runtime) throw runtime;
                if (failed.getCause() instanceof Error error) throw error;
                throw new IllegalStateException(failed.getCause());
            } catch (ReflectiveOperationException failed) { throw new IllegalStateException(failed); }
        };
    }

    private ReportMeasured measureReport(Scenario scenario, List<LotSubmission> submissions, String action,
                                         boolean before, java.util.function.Supplier<Object> command) throws Exception {
        Object spy = AopTestUtils.getUltimateTargetObject(analyses);
        clearInvocations(spy);
        ProductionJdbcMeasurement.Sample sql = ProductionJdbcMeasurement.begin();
        var resources = CommandResourceMeasurement.begin(DATABASE);
        long started = System.nanoTime();
        Object result;
        long elapsed;
        Map<String, Object> resourceMetrics;
        try { result = command.get(); }
        finally {
            elapsed = System.nanoTime() - started;
            resourceMetrics = resources.finish();
            ProductionJdbcMeasurement.end();
        }
        long refreshes = mockingDetails(spy).getInvocations().stream().filter(call ->
                call.getMethod().getName().equals("refreshLocked") && call.getArguments().length == 1
                        && scenario.watcherAnalysis().equals(call.getArgument(0))).count();
        var output = new LinkedHashMap<String, Object>(sql.result());
        output.put("action", action); output.put("size", submissions.size()); output.put("reportCount", 1);
        output.put("fixture", "one approved production report; one inspection sheet; twenty distinct pre-stocked lots; one goods/warehouse and one unrelated observer analysis");
        output.put("candidate", before ? "before" : "after");
        output.put("entryPoint", before ? "twenty sequential decideLot transactions" : "one decideReport transaction");
        output.put("watcherRefreshes", refreshes); output.put("wallMillis", elapsed / 1_000_000.0);
        output.put("resources", resourceMetrics);
        output.put("verifyNestedFootprint", environment.getProperty("uten.concurrency.verify-nested-footprint", Boolean.class, true));
        output.put("sourceIdentity", System.getProperty("uten.perf.source-identity", "unspecified"));
        output.put("scope", "service proxy calls through every real commit; request construction, reflection lookup, fixtures, assertions, HTTP and rendering excluded; samples are not cold-JVM proof");
        output.put("backgroundWork", "outbox closed; inventory value worker, audit retention, view refresh, readiness, workshop auto-close and policy intelligence disabled");
        output.put("stockBytecodeSha256", bytecodeHash(StockDocService.class));
        output.put("qualityBytecodeSha256", bytecodeHash(ProductionFqcInspectionService.class));
        var databaseSettings = db.queryForMap("SELECT current_setting('server_version') AS version,current_setting('fsync') AS fsync,current_setting('synchronous_commit') AS synchronous_commit,current_setting('full_page_writes') AS full_page_writes");
        for (String setting : List.of("fsync", "synchronous_commit", "full_page_writes")) assertEquals("on", databaseSettings.get(setting));
        output.put("databaseSettings", databaseSettings);
        System.out.println("FQC-REPORT-PROFILE " + json.writeValueAsString(output));
        com.fasterxml.jackson.databind.JsonNode tree = json.valueToTree(result);
        com.fasterxml.jackson.databind.JsonNode rows = before ? tree : tree.path("items");
        assertTrue(rows.isArray());
        assertEquals(submissions.size(), rows.size());
        List<ReportReceipt> receipts = new ArrayList<>();
        for (int index = 0; index < submissions.size(); index++) {
            var expected = submissions.get(index);
            var row = rows.get(index);
            if (!before) {
                assertEquals("LOT", row.path("targetType").asText());
                assertEquals(expected.lotId().toString(), row.path("targetId").asText());
                assertEquals(expected.request().idempotencyKey(), row.path("idempotencyKey").asText());
                assertTrue(row.path("inspection").isNull());
            }
            InspectionLotView lot = json.treeToValue(row.path("lot"), InspectionLotView.class);
            assertEquals(expected.lotId(), lot.lotId());
            receipts.add(new ReportReceipt(UUID.fromString(row.path(before ? "lotCommandId" : "commandId").asText()),
                    row.path("replay").asBoolean(), lot));
        }
        return new ReportMeasured(List.copyOf(receipts), sql, refreshes);
    }

    private Map<String, List<String>> reportFacts(Scenario scenario) {
        var facts = new LinkedHashMap<>(handoffFacts(List.of(scenario)));
        facts.put("lotCommands", db.queryForList("SELECT to_jsonb(c)::text FROM production_fqc_lot_decision_commands c WHERE source_report_id=? ORDER BY id", String.class, scenario.reportId()));
        facts.put("inspections", db.queryForList("SELECT to_jsonb(i)::text FROM production_fqc_inspections i WHERE source_report_id=? ORDER BY id", String.class, scenario.reportId()));
        return facts;
    }

    private void assertReportFacts(Scenario scenario, List<ReportReceipt> receipts, int expectedDocuments) {
        assertEquals(20, receipts.size());
        assertEquals(expectedDocuments, sourceCount("stock_documents", "source_daily_report_id", scenario));
        assertEquals(expectedDocuments, approvedDocs(scenario));
        assertEquals(0, new BigDecimal("20").compareTo(balance(scenario)));
        assertEquals(expectedDocuments, db.queryForObject("""
                SELECT count(*) FROM production_finished_in_confirmations confirmation
                JOIN stock_documents document ON document.id=confirmation.stock_document_id
                WHERE document.source_daily_report_id=? AND confirmation.origin='PRE_STOCKED_AUTO'
                """, Integer.class, scenario.reportId()));
        assertEquals(20, db.queryForObject("""
                SELECT count(*) FROM stock_document_items item
                JOIN stock_documents document ON document.id=item.doc_id
                WHERE document.source_daily_report_id=? AND NOT item.is_deleted
                """, Integer.class, scenario.reportId()));
        assertEquals(0, new BigDecimal("20").compareTo(db.queryForObject("""
                SELECT sum(movement.qty) FROM stock_movements movement
                JOIN stock_documents document ON document.id=movement.source_doc_id
                WHERE document.source_daily_report_id=? AND movement.source_doc_type='STOCK_DOC' AND movement.direction=1
                """, BigDecimal.class, scenario.reportId())));
        assertEquals(20, db.queryForObject("""
                SELECT count(*) FROM production_fqc_release_commands command
                JOIN production_fqc_inspections inspection ON inspection.id=command.inspection_id
                JOIN stock_document_items item ON item.id=command.stock_document_item_id
                WHERE inspection.source_report_id=? AND inspection.status='RESOLVED'
                  AND command.source_report_item_id=inspection.source_report_item_id
                  AND item.source_daily_report_item_id=inspection.source_report_item_id AND command.requested_qty=1
                """, Integer.class, scenario.reportId()));
        assertEquals(20, db.queryForObject("""
                SELECT count(*) FROM production_fqc_decision_events event
                JOIN production_fqc_inspections inspection ON inspection.id=event.inspection_id
                WHERE inspection.source_report_id=? AND event.pass_qty=1 AND event.fail_qty=0
                """, Integer.class, scenario.reportId()));
        assertEquals(0, new BigDecimal("20").compareTo(db.queryForObject("""
                SELECT sum(allocation.qty) FROM production_fqc_release_allocations allocation
                JOIN production_fqc_inspections inspection ON inspection.id=allocation.inspection_id
                WHERE inspection.source_report_id=?
                """, BigDecimal.class, scenario.reportId())));
        assertEquals(20, sourceCount("production_fqc_lot_decision_commands", "source_report_id", scenario));
        for (ReportReceipt receipt : receipts) {
            assertEquals("RESOLVED", receipt.lot().status());
            assertEquals(0, BigDecimal.ONE.compareTo(receipt.lot().passedQty()));
            assertEquals(0, receipt.lot().remainingQty().signum());
            // Both candidate and baseline responses were normalized through JSON;
            // compare the same representation, preserving numeric value rather than BigDecimal scale.
            assertEquals(json.valueToTree(receipt.lot()), json.valueToTree(quality.lotDetail(receipt.lot().lotId())));
            assertEquals(receipt.commandId(), db.queryForObject("""
                    SELECT id FROM production_fqc_lot_decision_commands WHERE source_report_id=? AND lot_id=?
                    """, UUID.class, scenario.reportId(), receipt.lot().lotId()));
        }
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM stock_reservations WHERE owner_type='PREPLAN_ANALYSIS' AND owner_id=?
                  AND goods_id=? AND NOT is_deleted AND status=0 AND qty>consumed_qty+released_qty
                """, Integer.class, scenario.watcherAnalysis(), scenario.world().goodsA()));
    }

    private record LotSubmission(UUID lotId, LotDecisionRequest request) { }
    private record ReportReceipt(UUID commandId, boolean replay, InspectionLotView lot) { }
    private record ReportMeasured(List<ReportReceipt> receipts, ProductionJdbcMeasurement.Sample sql,
                                  long analysisRefreshes) { }

    private Map<String, List<String>> handoffFacts(List<Scenario> scenarios) {
        UUID[] reports = scenarios.stream().map(Scenario::reportId).toArray(UUID[]::new);
        var facts = new LinkedHashMap<String, List<String>>();
        facts.put("documents", db.queryForList("SELECT to_jsonb(d)::text FROM stock_documents d WHERE source_daily_report_id=ANY(?) ORDER BY id", String.class, (Object) reports));
        facts.put("documentItems", db.queryForList("SELECT to_jsonb(i)::text FROM stock_document_items i WHERE doc_id IN (SELECT id FROM stock_documents WHERE source_daily_report_id=ANY(?)) ORDER BY id", String.class, (Object) reports));
        facts.put("movements", db.queryForList("SELECT to_jsonb(m)::text FROM stock_movements m WHERE source_doc_id IN (SELECT id FROM stock_documents WHERE source_daily_report_id=ANY(?)) ORDER BY id", String.class, (Object) reports));
        facts.put("decisions", db.queryForList("SELECT to_jsonb(e)::text FROM production_fqc_decision_events e WHERE inspection_id IN (SELECT id FROM production_fqc_inspections WHERE source_report_id=ANY(?)) ORDER BY id", String.class, (Object) reports));
        facts.put("releases", db.queryForList("SELECT to_jsonb(a)::text FROM production_fqc_release_allocations a WHERE inspection_id IN (SELECT id FROM production_fqc_inspections WHERE source_report_id=ANY(?)) ORDER BY id", String.class, (Object) reports));
        facts.put("releaseCommands", db.queryForList("SELECT to_jsonb(c)::text FROM production_fqc_release_commands c WHERE inspection_id IN (SELECT id FROM production_fqc_inspections WHERE source_report_id=ANY(?)) ORDER BY id", String.class, (Object) reports));
        return facts;
    }

    private void assertHandoffFacts(List<Scenario> scenarios) {
        Scenario first = scenarios.getFirst();
        assertEquals(0, BigDecimal.valueOf(scenarios.size()).compareTo(balance(first)));
        for (Scenario scenario : scenarios) {
            assertEquals(1, sourceCount("stock_documents", "source_daily_report_id", scenario));
            assertEquals(1, approvedDocs(scenario));
            assertEquals(1, db.queryForObject("""
                    SELECT count(*) FROM production_finished_in_confirmations confirmation
                    JOIN stock_documents document ON document.id=confirmation.stock_document_id
                    WHERE document.source_daily_report_id=? AND confirmation.origin='PRE_STOCKED_AUTO'
                    """, Integer.class, scenario.reportId()));
            assertEquals(0, BigDecimal.ONE.compareTo(db.queryForObject("""
                    SELECT SUM(movement.qty) FROM stock_movements movement
                    JOIN stock_documents document ON document.id=movement.source_doc_id
                    WHERE movement.source_doc_type='STOCK_DOC' AND movement.direction=1
                      AND document.source_daily_report_id=?
                    """, BigDecimal.class, scenario.reportId())));
            UUID inspection = scenario.inspections().getFirst();
            assertEquals("RESOLVED", quality.detail(inspection).status());
            UUID originalReportItem = db.queryForObject("SELECT source_report_item_id FROM production_fqc_inspections WHERE id=?",
                    UUID.class, inspection);
            assertEquals(originalReportItem, db.queryForObject("""
                    SELECT item.source_daily_report_item_id FROM stock_document_items item
                    JOIN stock_documents document ON document.id=item.doc_id
                    WHERE document.source_daily_report_id=? AND NOT item.is_deleted
                    """, UUID.class, scenario.reportId()));
            assertEquals(1, db.queryForObject("""
                    SELECT count(*) FROM production_fqc_release_commands command
                    JOIN stock_document_items item ON item.id=command.stock_document_item_id
                    WHERE command.inspection_id=? AND command.source_report_item_id=?
                      AND item.source_daily_report_item_id=command.source_report_item_id AND command.requested_qty=1
                    """, Integer.class, inspection, originalReportItem));
            assertEquals(0, BigDecimal.ONE.compareTo(db.queryForObject(
                    "SELECT SUM(qty) FROM production_fqc_release_allocations WHERE inspection_id=?", BigDecimal.class, inspection)));
        }
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM stock_reservations WHERE owner_type='PREPLAN_ANALYSIS' AND owner_id=?
                  AND goods_id=? AND NOT is_deleted AND status=0 AND qty>consumed_qty+released_qty
                """, Integer.class, first.watcherAnalysis(), first.world().goodsA()),
                "The observer must not acquire another order's private output");
    }

    private void assertFreshLotStatementBudget(Measured measured) {
        var sql=measured.sql();
        long replayQueries=sql.fingerprints.entrySet().stream()
                .filter(entry -> "fqc.decision_replay".equals(sql.labelsByFingerprint.get(entry.getKey())))
                .mapToLong(Map.Entry::getValue).sum();
        long itemInserts=sql.fingerprints.entrySet().stream()
                .filter(entry -> "fqc.batch_item_insert".equals(sql.labelsByFingerprint.get(entry.getKey())))
                .mapToLong(Map.Entry::getValue).sum();
        assertEquals(0,replayQueries,"Fresh lot command children have no historical replay to read");
        assertEquals(1,itemInserts,"All batch associations use one statement with their original item order");
        List<UUID> expected=measured.result().items().stream().map(item -> item.inspectionId()).toList();
        assertEquals(expected,db.queryForList("SELECT inspection_id FROM production_fqc_pass_all_batch_items WHERE batch_id=? ORDER BY line_no",
                UUID.class,measured.result().batchId()));
        assertEquals(java.util.stream.IntStream.rangeClosed(1,expected.size()).boxed().toList(),
                db.queryForList("SELECT line_no FROM production_fqc_pass_all_batch_items WHERE batch_id=? ORDER BY line_no",
                        Integer.class,measured.result().batchId()));
    }

    private static long statementCount(Measured measured,String label) {
        return measured.sql().fingerprints.entrySet().stream()
                .filter(entry -> label.equals(measured.sql().labelsByFingerprint.get(entry.getKey())))
                .mapToLong(Map.Entry::getValue).sum();
    }

    private Scenario prepare(int size, String mode) {
        return prepareReports(size, mode, 1).getFirst();
    }

    private List<Scenario> prepareReports(int size, String mode, int reportCount) {
        assertTrue(Set.of("prestock", "mixed", "plain").contains(mode));
        FullChainEndToEndTest fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        String tag = "fqc-batch-" + UUID.randomUUID();
        var world = fixture.seedWorld(tag);
        fixture.loginAs(world.superAdminUserId());
        BigDecimal total = BigDecimal.valueOf((long) size * reportCount);
        ReflectionTestUtils.invokeMethod(fixture, "receiveOpeningInputsForA", world, total.toPlainString());
        UUID order = fixture.createApprovedOrder(world, world.goodsA(), total.toPlainString(), "100");
        UUID orderItem = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",
                UUID.class, order);
        AnalysisView source = analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(),
                "fqc-source-" + tag, List.of(new PreviewItem("SALES_ORDER_ITEM", orderItem,
                null, null, null, null, null, BusinessTime.today().plusDays(2), total))));
        ReflectionTestUtils.invokeMethod(fixture, "confirmRootMakeRoute", source.analysisId(), source);
        source = analyses.detail(source.analysisId());
        var generated = commands.issueWorkshopPlans(source.analysisId(), new IssueWorkshopPlansRequest(
                source.version(), source.fingerprint(), "fqc-issue-" + tag, world.warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(2), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(source.products().getFirst().analysisLineId(), total))));
        UUID plan = generated.plans().getFirst().planId();
        fixture.confirmFullKitRoutes(plan);
        List<UUID> draws = ReflectionTestUtils.invokeMethod(fixture, "currentPlanDrawIds", plan);
        assertNotNull(draws);
        fixture.requestWorkshopDraws(tag, draws);
        for (UUID draw : draws) {
            StockDocIssueRequest request = ReflectionTestUtils.invokeMethod(fixture, "drawIssueRequest",
                    draw, "fqc-draw-" + draw, null, BigDecimal.ZERO);
            stock.approveAndIssue(draw, request);
        }
        UUID planItem = db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND goods_id=? AND NOT is_deleted",
                UUID.class, plan, world.goodsA());
        String[] quantities = Collections.nCopies(size, "1").toArray(String[]::new);
        List<UUID> reportIds = new ArrayList<>();
        for (int index = 0; index < reportCount; index++) {
            Object report = ReflectionTestUtils.invokeMethod(fixture, "approvedMultiLineReport", world,
                    plan, planItem, orderItem, (Object) quantities);
            UUID reportId = ReflectionTestUtils.invokeMethod(report, "id");
            assertNotNull(reportId);
            reportIds.add(reportId);
        }
        fixture.loginAs(world.superAdminUserId());

        // A real active analysis in the same warehouse genuinely observes A.
        // Its different demand owns no part of this sales order's private output.
        UUID watcherProduct = UUID.randomUUID();
        fixture.insertGoods(watcherProduct, "FW-" + watcherProduct, "FQC analysis observer", "自制", world.unitId(), world.unitLegacy());
        fixture.insertBom(watcherProduct, world.goodsA(), "1");
        AnalysisView watcher = analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(),
                "fqc-observer-" + tag, List.of(new PreviewItem("OTHER", null, watcherProduct,
                null, world.unitId(), "FW-" + watcherProduct, "FQC batch refresh probe", BusinessTime.today(), total))));
        assertTrue(watcher.flatMaterials().stream().anyMatch(row -> world.goodsA().equals(row.goodsId())),
                "性能夹具必须有真实参与本次供给维度的分析材料");

        List<Scenario> scenarios = new ArrayList<>();
        for (UUID reportId : reportIds) {
            List<UUID> items = db.queryForList("SELECT id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted ORDER BY line_no",
                UUID.class, reportId);
            assertEquals(size, items.size());
            int preStocked = mode.equals("prestock") ? size : mode.equals("mixed") ? (size + 1) / 2 : 0;
            register(reportId, world.warehouseId(), items.subList(0, preStocked), true);
            register(reportId, world.warehouseId(), items.subList(preStocked, size), false);
            List<UUID> inspections = db.queryForList("SELECT id FROM production_fqc_inspections WHERE source_report_id=? ORDER BY id",
                UUID.class, reportId);
            assertEquals(size, inspections.size());
            scenarios.add(new Scenario(world, source.analysisId(), watcher.analysisId(), reportId, inspections, preStocked, mode));
        }
        return List.copyOf(scenarios);
    }

    private void register(UUID report, UUID warehouse, List<UUID> items, boolean preStocked) {
        if (items.isEmpty()) return;
        com.uten.imp.features.warehouse.finishedin.FinishedArrivalTestSupport.registerItems(arrivals, report,
                "fqc-register-" + report + "-" + preStocked, warehouse, items,
                id -> "FQC-BATCH-" + id.toString().substring(0, 8), "FQC batch projection", preStocked);
    }

    private Measured measure(Scenario scenario, String action, java.util.function.Supplier<PassAllBatchResult> command) throws Exception {
        return measure(List.of(scenario), action, command);
    }

    private Measured measure(List<Scenario> scenarios, String action, java.util.function.Supplier<PassAllBatchResult> command) throws Exception {
        Scenario scenario = scenarios.getFirst();
        Object spy = AopTestUtils.getUltimateTargetObject(analyses);
        clearInvocations(spy);
        ProductionJdbcMeasurement.Sample sql = ProductionJdbcMeasurement.begin();
        var resources = CommandResourceMeasurement.begin(DATABASE);
        long started = System.nanoTime();
        PassAllBatchResult result;
        long elapsed;
        Map<String,Object> resourceMetrics;
        try { result = command.get(); }
        finally {
            elapsed = System.nanoTime() - started;
            resourceMetrics = resources.finish();
            ProductionJdbcMeasurement.end();
        }
        long refreshes = mockingDetails(spy).getInvocations().stream().filter(call ->
                call.getMethod().getName().equals("refreshLocked") && call.getArguments().length == 1
                        && scenario.watcherAnalysis().equals(call.getArgument(0))).count();
        var output = new LinkedHashMap<String, Object>(sql.result());
        output.put("action", action); output.put("size", scenarios.stream().mapToInt(row -> row.inspections().size()).sum());
        output.put("reportCount", scenarios.size());
        output.put("fixture", "one real production plan; separate approved reports; one goods/warehouse dimension; one private owner and one unrelated observer analysis");
        output.put("mode", scenario.mode()); output.put("watcherRefreshes", refreshes);
        output.put("wallMillis", elapsed / 1_000_000.0);
        output.put("resources", resourceMetrics);
        output.put("candidate", System.getProperty("uten.fqc.batch.run", "after"));
        output.put("verifyNestedFootprint", environment.getProperty("uten.concurrency.verify-nested-footprint", Boolean.class, true));
        var databaseSettings = db.queryForMap("SELECT current_setting('server_version') AS version,current_setting('fsync') AS fsync,current_setting('synchronous_commit') AS synchronous_commit,current_setting('full_page_writes') AS full_page_writes");
        for (String setting : List.of("fsync", "synchronous_commit", "full_page_writes")) assertEquals("on", databaseSettings.get(setting));
        output.put("databaseSettings", databaseSettings);
        output.put("sourceIdentity", System.getProperty("uten.perf.source-identity", "unspecified"));
        output.put("backgroundWork", "handoff methods close outbox; inventory value worker, audit retention, materialized-view refresh, readiness reconcile, workshop auto-close and policy intelligence disabled");
        output.put("scope", "service through real commit; excludes fixture preparation, HTTP and client rendering; first sample is not cold JVM/database proof");
        output.put("stockBytecodeSha256", bytecodeHash(StockDocService.class));
        output.put("qualityBytecodeSha256", bytecodeHash(ProductionFqcInspectionService.class));
        Map<String,String> valueClasses = new LinkedHashMap<>();
        for (String name : List.of("InventoryPositionService", "InventoryValueLedger", "InventoryValueWriteSet")) {
            try { valueClasses.put(name, bytecodeHash(Class.forName("com.uten.imp.features.stock.valuation." + name))); }
            catch (ClassNotFoundException absentInBaseline) { valueClasses.put(name, "ABSENT"); }
        }
        output.put("valueBytecodeSha256", valueClasses);
        System.out.println("FQC-BATCH-PROFILE " + json.writeValueAsString(output));
        return new Measured(result, sql, refreshes);
    }

    private void assertWorkBudget(Scenario scenario, Measured command, Measured replay) {
        for (String label : List.of("fqc.release_inspections", "fqc.release_replay", "fqc.release_balances")) {
            long calls = command.sql().labelsByFingerprint.entrySet().stream()
                    .filter(entry -> label.equals(entry.getValue()))
                    .mapToLong(entry -> command.sql().fingerprints.getOrDefault(entry.getKey(), 0L)).sum();
            assertEquals(1, calls, "All PASS releases share one authoritative read: " + label);
        }
        if ("before".equals(System.getProperty("uten.fqc.batch.run"))
                || environment.getProperty("uten.concurrency.verify-nested-footprint", Boolean.class, true)) return;
        int physical = scenario.preStocked();
        int drafts = scenario.inspections().size() - physical;
        int budget = (physical == 0 ? DRAFT_BATCH_SQL : POSTED_BATCH_SQL)
                + physical * POSTED_LINE_SQL + drafts * DRAFT_LINE_SQL + SQL_HEADROOM;
        assertTrue(command.sql().logicalStatements <= budget,
                "FQC SQL budget exceeded: " + command.sql().logicalStatements + " > " + budget);
        assertTrue(replay.sql().logicalStatements <= (physical == 0 ? 31 : 41) + 4,
                "Idempotent replay must not re-run physical work or analysis refreshes");
        assertEquals(0, command.sql().md5Statements);
    }

    private static String bytecodeHash(Class<?> type) throws Exception {
        try (var input = type.getResourceAsStream("/" + type.getName().replace('.', '/') + ".class")) {
            assertNotNull(input);
            return HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(input.readAllBytes()));
        }
    }

    private void assertFacts(Scenario scenario) {
        assertFacts(scenario, 0);
    }

    private void assertFacts(Scenario scenario, int earlierPhysicalSlices) {
        int size = scenario.inspections().size();
        // ADR-148：一次全合格按「报工 x 登记批次 x 仓库 x 计划 x 是否先入库」合单：先入库的一张(自动点收)、
        // 原流程的一张(待点收)；之前单独放行的每次各一张。每份仍各占一行。
        int preStockedDocs = scenario.preStocked() > 0 ? 1 : 0;
        int draftDocs = size - scenario.preStocked() > 0 ? 1 : 0;
        assertEquals(preStockedDocs + draftDocs + earlierPhysicalSlices, sourceCount("stock_documents", "source_daily_report_id", scenario));
        assertEquals(size + earlierPhysicalSlices, db.queryForObject("""
                SELECT count(*) FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
                WHERE document.source_daily_report_id=? AND NOT item.is_deleted
                """, Integer.class, scenario.reportId()));
        assertEquals(preStockedDocs + earlierPhysicalSlices, approvedDocs(scenario));
        assertEquals(0, BigDecimal.valueOf(scenario.preStocked()).compareTo(balance(scenario)));
        assertEquals(preStockedDocs + earlierPhysicalSlices, db.queryForObject("""
                SELECT count(*) FROM production_finished_in_confirmations confirmation
                JOIN stock_documents document ON document.id=confirmation.stock_document_id
                WHERE document.source_daily_report_id=? AND confirmation.origin='PRE_STOCKED_AUTO'
                """, Integer.class, scenario.reportId()));
        assertEquals(size, db.queryForObject("SELECT count(*) FROM production_fqc_inspections WHERE source_report_id=? AND status='RESOLVED'",
                Integer.class, scenario.reportId()));
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM stock_reservations WHERE owner_type='PREPLAN_ANALYSIS' AND owner_id=?
                    AND goods_id=? AND NOT is_deleted AND status=0 AND qty>consumed_qty+released_qty
                """, Integer.class, scenario.watcherAnalysis(), scenario.world().goodsA()),
                "旁观分析不能把别人的私有产出误认成公共库存");
    }

    private int approvedDocs(Scenario scenario) {
        return db.queryForObject("SELECT count(*) FROM stock_documents WHERE source_daily_report_id=? AND status=1 AND NOT is_deleted",
                Integer.class, scenario.reportId());
    }

    private BigDecimal balance(Scenario scenario) {
        return db.queryForObject("SELECT coalesce(sum(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",
                BigDecimal.class, scenario.world().goodsA(), scenario.world().warehouseId());
    }

    private int sourceCount(String table, String column, Scenario scenario) {
        return db.queryForObject("SELECT count(*) FROM " + table + " WHERE " + column + "=?", Integer.class, scenario.reportId());
    }

    private record Scenario(FullChainEndToEndTest.World world, UUID sourceAnalysis, UUID watcherAnalysis,
                            UUID reportId, List<UUID> inspections, int preStocked, String mode) { }
    private record Measured(PassAllBatchResult result, ProductionJdbcMeasurement.Sample sql, long analysisRefreshes) { }
}
