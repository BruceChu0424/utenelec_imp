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
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000",
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
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
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
            assertEquals(2, approvedDocs(scenario), "进入统一收尾之前每笔实收入库已即时完成");
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

    private Scenario prepare(int size, String mode) {
        assertTrue(Set.of("prestock", "mixed", "plain").contains(mode));
        FullChainEndToEndTest fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        String tag = "fqc-batch-" + UUID.randomUUID();
        var world = fixture.seedWorld(tag);
        fixture.loginAs(world.superAdminUserId());
        BigDecimal total = BigDecimal.valueOf(size);
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
        Object report = ReflectionTestUtils.invokeMethod(fixture, "approvedMultiLineReport", world,
                plan, planItem, orderItem, (Object) quantities);
        UUID reportId = ReflectionTestUtils.invokeMethod(report, "id");
        assertNotNull(reportId);
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

        List<UUID> items = db.queryForList("SELECT id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted ORDER BY line_no",
                UUID.class, reportId);
        assertEquals(size, items.size());
        int preStocked = mode.equals("prestock") ? size : mode.equals("mixed") ? (size + 1) / 2 : 0;
        register(reportId, world.warehouseId(), items.subList(0, preStocked), true);
        register(reportId, world.warehouseId(), items.subList(preStocked, size), false);
        List<UUID> inspections = db.queryForList("SELECT id FROM production_fqc_inspections WHERE source_report_id=? ORDER BY id",
                UUID.class, reportId);
        assertEquals(size, inspections.size());
        return new Scenario(world, source.analysisId(), watcher.analysisId(), reportId, inspections, preStocked, mode);
    }

    private void register(UUID report, UUID warehouse, List<UUID> items, boolean preStocked) {
        if (items.isEmpty()) return;
        arrivals.register(report, new ArrivalRegistrationRequest("fqc-register-" + report + "-" + preStocked,
                warehouse, items.stream().map(id -> new ArrivalRegistrationItemRequest(id,
                "FQC-BATCH-" + id.toString().substring(0, 8), preStocked ? BigDecimal.ONE : null)).toList(),
                "FQC batch projection", preStocked));
    }

    private Measured measure(Scenario scenario, String action, java.util.function.Supplier<PassAllBatchResult> command) throws Exception {
        Object spy = AopTestUtils.getUltimateTargetObject(analyses);
        clearInvocations(spy);
        ProductionJdbcMeasurement.Sample sql = ProductionJdbcMeasurement.begin();
        long started = System.nanoTime();
        PassAllBatchResult result;
        try { result = command.get(); }
        finally { ProductionJdbcMeasurement.end(); }
        long elapsed = System.nanoTime() - started;
        long refreshes = mockingDetails(spy).getInvocations().stream().filter(call ->
                call.getMethod().getName().equals("refreshLocked") && call.getArguments().length == 1
                        && scenario.watcherAnalysis().equals(call.getArgument(0))).count();
        var output = new LinkedHashMap<String, Object>(sql.result());
        output.put("action", action); output.put("size", scenario.inspections().size());
        output.put("mode", scenario.mode()); output.put("watcherRefreshes", refreshes);
        output.put("wallMillis", elapsed / 1_000_000.0);
        output.put("candidate", System.getProperty("uten.fqc.batch.run", "after"));
        output.put("verifyNestedFootprint", environment.getProperty("uten.concurrency.verify-nested-footprint", Boolean.class, true));
        output.put("stockBytecodeSha256", bytecodeHash(StockDocService.class));
        output.put("qualityBytecodeSha256", bytecodeHash(ProductionFqcInspectionService.class));
        System.out.println("FQC-BATCH-PROFILE " + json.writeValueAsString(output));
        return new Measured(result, sql, refreshes);
    }

    private void assertWorkBudget(Scenario scenario, Measured command, Measured replay) {
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
        assertEquals(size + earlierPhysicalSlices, sourceCount("stock_documents", "source_daily_report_id", scenario));
        assertEquals(scenario.preStocked() + earlierPhysicalSlices, approvedDocs(scenario));
        assertEquals(0, BigDecimal.valueOf(scenario.preStocked()).compareTo(balance(scenario)));
        assertEquals(scenario.preStocked() + earlierPhysicalSlices, db.queryForObject("""
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
