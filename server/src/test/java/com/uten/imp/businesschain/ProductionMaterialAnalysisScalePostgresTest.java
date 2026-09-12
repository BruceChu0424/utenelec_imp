package com.uten.imp.businesschain;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.containers.PostgreSQLContainer;

/** Real service correctness by default when DB tests are enabled; large timing requires a second opt-in. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false"})
// Default failure-only printing still eagerly formats and retains every large
// successful response. Measure real MockMvc bytes without that test-only copy.
@AutoConfigureMockMvc(print = org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint.NONE)
@Import(ProductionJdbcMeasurement.Configuration.class)
class ProductionMaterialAnalysisScalePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = configuredDatabase();
    private static final String TEST_SECRET = UUID.randomUUID() + "-" + UUID.randomUUID();

    private static PostgreSQLContainer<?> configuredDatabase() {
        var database = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("uten_production_scale").withUsername("uten_test").withPassword(UUID.randomUUID().toString());
        if ("company".equals(System.getenv("UTEN_PRODUCTION_STRESS_DATABASE_PROFILE"))) {
            // Explicit isolated capacity profile; ordinary CI keeps its small
            // database. These are read-only verified company-server settings.
            database.withSharedMemorySize(1024L * 1024 * 1024).withCommand("postgres",
                    "-c", "shared_buffers=4GB", "-c", "work_mem=32MB",
                    "-c", "effective_cache_size=12GB", "-c", "max_connections=200",
                    "-c", "fsync=on", "-c", "synchronous_commit=on", "-c", "full_page_writes=on",
                    "-c", "wal_buffers=16MB", "-c", "default_statistics_target=100");
        }
        return database;
    }

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) throws java.io.IOException {
        POSTGRES.start();
        Path attachments = Files.createTempDirectory("uten-production-scale-attachments-");
        registry.add("uten.storage.local-dir", () -> attachments.toString());
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        registry.add("uten.jwt.secret", () -> TEST_SECRET);
        registry.add("uten.crypto.pgp-master-key", () -> TEST_SECRET);
        registry.add("uten.crypto.hmac-key", () -> TEST_SECRET);
        registry.add("uten.bootstrap.admin-login", () -> "scale-bootstrap");
        registry.add("uten.bootstrap.admin-password", () -> TEST_SECRET + "Aa1!");
    }

    @Autowired JdbcTemplate jdbc;
    @Autowired MaterialAnalysisService analysis;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired SalesOrderService sales;
    @Autowired SalesOrderFinanceConfirmService finance;
    @Autowired com.uten.imp.features.production.plan.ProductionPlanService planService;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @Autowired javax.sql.DataSource dataSource;
    @Autowired jakarta.persistence.EntityManager em;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    private ProductionChainDataFactory factory;
    private int historyRows;

    @BeforeEach void setUp() { factory = new ProductionChainDataFactory(beans, jdbc, sales, finance); }
    @AfterEach void clearActor() { SecurityContextHolder.clearContext(); ProductionJdbcMeasurement.end(); }

    @Test
    void twoProductsSharedTreeKeepsIndependentDemandAndConcurrentIssueIsIdempotent() throws Exception {
        var scenario = factory.sharedTree("scale-small-" + suffix(), 2);
        factory.terminalAnalysisMetadata(scenario,25);
        factory.historicalBomMasters(scenario,25);
        historyRows=25; // Instrumentation correctness only; never a pressure/SLO sample.
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        AnalysisView first;
        try { first = analysis.preview(request(scenario, null, "small-first-" + suffix())); }
        finally { ProductionJdbcMeasurement.end(); }
        assertTrue(sample.jdbcCalls > 0 && sample.logicalStatements >= sample.jdbcCalls);
        assertTrue(sample.commits > 0 && !sample.fingerprints.isEmpty(),
                "Measure actual JDBC and transaction execution without emitting parameters");
        explainActualQueries(sample,"analysis.preview.initial",2);
        sample=ProductionJdbcMeasurement.begin();
        try { assertEquals(1,analysis.list(null,"ACTIVE",null,1,50).getTotal()); }
        finally { ProductionJdbcMeasurement.end(); }
        explainActualQueries(sample,"analysis.list.active.50",2);
        assertInitialDemand(scenario, first);
        var other = factory.anotherSalesOrder(scenario);
        AnalysisView second = analysis.preview(request(other, null, "small-second-" + suffix()));
        assertInitialDemand(other, second);
        var firstKeys = first.flatMaterials().stream().map(MaterialView::nodeKey).collect(java.util.stream.Collectors.toSet());
        assertTrue(second.flatMaterials().stream().anyMatch(row -> firstKeys.contains(row.nodeKey())),
                "The fixture must actually repeat nodeKey across different analyses");
        AnalysisView routed = confirmAllRoutes(first, false);
        assertTrue(analysis.detail(second.analysisId()).flatMaterials().stream().noneMatch(MaterialView::routeConfirmed),
                "Route confirmation must be isolated by analysis, even for the same BOM path");

        for (String route : List.of("BUY", "SUBCONTRACT")) {
            var groups = routed.flatMaterials().stream().filter(MaterialView::actionable)
                    .filter(row -> route.equals(row.sourceConfirmed())).map(MaterialView::actionGroupKey).distinct().toList();
            assertFalse(groups.isEmpty());
            commands.notifySupply(routed.analysisId(), new NotifyRequest(routed.version(), routed.fingerprint(),
                    "small-notify-" + route + "-" + suffix(), route, List.of(), groups, null));
            routed = analysis.detail(routed.analysisId());
            assertActionConservation(routed.analysisId());
            assertNoInventoryOrSalesCompletion(scenario);
        }
        assertEquals(2, jdbc.queryForObject("""
                select count(*) from preplan_subcontract_make_tasks where analysis_id=? and status='ACTIVE'
                """, Integer.class, first.analysisId()), "One preparation per source path; no repeated child expansion");
        IssueWorkshopPlansRequest issue = issueRequest(scenario, routed, 2, "small-concurrent-" + suffix());
        UUID analysisId = routed.analysisId();
        var workers = Executors.newFixedThreadPool(2);
        CountDownLatch start = new CountDownLatch(1);
        try {
            var jobs = java.util.stream.IntStream.range(0, 2).mapToObj(n -> workers.submit(() -> {
                factory.login(scenario);
                try { assertTrue(start.await(30, TimeUnit.SECONDS)); return commands.issueWorkshopPlans(analysisId, issue); }
                finally { SecurityContextHolder.clearContext(); }
            })).toList();
            start.countDown();
            GenerateResult one = jobs.getFirst().get(90, TimeUnit.SECONDS);
            GenerateResult two = jobs.getLast().get(90, TimeUnit.SECONDS);
            assertEquals(one.plans().stream().map(GeneratedPlan::planId).toList(),
                    two.plans().stream().map(GeneratedPlan::planId).toList());
            assertTrue(one.replayed() != two.replayed(), "Exactly one commit and one recorded replay");
            assertWaitingPlanConservation(scenario, one, 2);
        } finally { workers.shutdownNow(); }
        assertNoInventoryOrSalesCompletion(scenario);
        assertInitialDemand(other, analysis.detail(second.analysisId()));
    }

    @Test
    @EnabledIfEnvironmentVariable(named = "UTEN_RUN_PRODUCTION_STRESS", matches = "(?i)true")
    void hundredSourcesCompareFootprintHashRepresentations() throws Exception {
        var scenario = factory.sharedTree("hash-compare-" + suffix(), 100);
        factory.terminalAnalysisMetadata(scenario, 20_000);
        factory.historicalBomMasters(scenario, 20_000);
        historyRows = 20_000;
        for (String table : List.of("production_material_analyses", "production_material_analysis_items", "goods_bom_items", "goods")) {
            jdbc.execute("ANALYZE " + table);
        }
        factory.login(scenario);
        var view = measured("SERVICE", "analysis.preview.initial", 100,
                () -> analysis.preview(request(scenario, null, "hash-preview-" + suffix())));
        assertInitialDemand(scenario, view);
    }

    @Test
    @EnabledIfEnvironmentVariable(named = "UTEN_RUN_PRODUCTION_STRESS", matches = "(?i)true")
    void hundredSourcesProfileNodeInsertBatches() throws Exception {
        var scenario = factory.sharedTree("insert-profile-" + suffix(), 100);
        factory.historicalBomMasters(scenario, 20_000);
        jdbc.execute("ANALYZE goods_bom_items"); jdbc.execute("ANALYZE goods");
        var view = analysis.preview(request(scenario, null, "insert-profile-" + suffix()));
        var rows = jdbc.queryForList("""
                SELECT * FROM production_material_analysis_materials
                WHERE analysis_id=? AND node_role='BOM_COMPONENT' ORDER BY analysis_item_id,depth,node_key LIMIT 1000
                """, view.analysisId());
        assertEquals(1000, rows.size());
        String ids = rows.stream().map(row -> row.get("id").toString()).collect(java.util.stream.Collectors.joining(","));
        boolean noOp = Boolean.getBoolean("uten.production.profileNodeNoop");
        for (int sampleIndex : java.util.stream.IntStream.range(0, noOp ? 5 : 1).toArray()) {
        for (int batch : sampleIndex % 2 == 0 ? List.of(100, 500, 1000) : List.of(1000, 500, 100)) {
            new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(status -> {
                beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
                // Only this private fixture's unreferenced component snapshots
                // are replaced. Every statement, audit and constraint is real;
                // the transaction always rolls back to the identical baseline.
                if (!noOp) assertEquals(1000, em.createNativeQuery("""
                        DELETE FROM production_material_analysis_materials
                        WHERE analysis_id=:analysis AND id IN (SELECT unnest(CAST(string_to_array(:ids, ',') AS uuid[])))
                        """).setParameter("analysis", view.analysisId()).setParameter("ids", ids).executeUpdate());
                var sample = ProductionJdbcMeasurement.begin();
                long started = System.nanoTime();
                var timings = new LinkedHashMap<String, Double>();
                double executionMillis = 0;
                try {
                    for (int offset = 0; offset < rows.size(); offset += batch) {
                        int count = Math.min(batch, rows.size() - offset);
                        String sql = org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                                MaterialAnalysisService.class, "nodeUpsertSql");
                        var query = em.createNativeQuery("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) " + sql)
                                .setParameter("snapshots", MaterialNodeUpsertProbe.snapshots(view.analysisId(),
                                        scenario.world().superAdminUserId(), rows.subList(offset, offset + count)));
                        var plan = json.readTree(query.getSingleResult().toString()).get(0);
                        if (noOp) {
                            assertEquals(0,plan.path("Plan").path("Tuples Inserted").asLong(-1));
                            assertEquals(0,plan.path("Plan").path("Conflicting Tuples").asLong(-1));
                        }
                        executionMillis += plan.path("Execution Time").asDouble();
                        for (var trigger : plan.path("Triggers")) {
                            timings.merge(trigger.path("Trigger Name").asText(), trigger.path("Time").asDouble(), Double::sum);
                        }
                    }
                    double statementsMillis = (System.nanoTime() - started) / 1_000_000.0;
                    long constraintsStarted = System.nanoTime();
                    em.createNativeQuery("SET CONSTRAINTS ALL IMMEDIATE").executeUpdate();
                    emit(Map.of("event", noOp ? "node-upsert-noop-profile" : "node-upsert-trigger-profile", "sample",sampleIndex,
                            "rows", rows.size(), "batchRows", batch,
                            "statementMillis", statementsMillis, "databaseExecutionMillis", executionMillis, "triggerMillis", timings,
                            "deferredConstraintMillis", (System.nanoTime() - constraintsStarted) / 1_000_000.0,
                            "maxPreparedParameterIndex", sample.maxPreparedParameterIndex));
                    assertEquals(1, sample.maxPreparedParameterIndex, "Typed snapshot cardinality must not expand the JDBC parameter count");
                } catch (Exception failure) { throw new IllegalStateException(failure); }
                finally { ProductionJdbcMeasurement.end(); status.setRollbackOnly(); }
            });
        }
        }
        assertEquals(9800, jdbc.queryForObject("SELECT count(*) FROM production_material_analysis_materials WHERE analysis_id=?",
                Integer.class, view.analysisId()), "Every profiling mutation must have rolled back");
    }

    @Test
    @EnabledIfEnvironmentVariable(named = "UTEN_RUN_PRODUCTION_STRESS", matches = "(?i)true")
    void hundredAndMaximumSourcesBulkPurchaseAndSubcontractNotifications() throws Exception {
        historyRows=integerEnv("UTEN_PRODUCTION_STRESS_HISTORY_ROWS",20_000,20_000,500_000);
        boolean historySeeded=false;
        for (String sizeText : System.getenv().getOrDefault("UTEN_PRODUCTION_STRESS_SIZES", "100,500").split(",")) {
            int size=Integer.parseInt(sizeText.trim());
            assertTrue(size==100 || size==500);
            var scenario=factory.sharedTree("notify-scale-"+size+"-"+suffix(),size);
            if (!historySeeded) {
                factory.terminalAnalysisMetadata(scenario,historyRows);
                factory.historicalBomMasters(scenario,historyRows);
                historySeeded=true;
            }
            for (String table:List.of("production_material_analyses","production_material_analysis_items","goods_bom_items","goods")) {
                jdbc.execute("ANALYZE "+table);
            }
            measureBulkSupplyNotifications(scenario,size);
        }
    }

    @Test
    void twoSourcesPurchaseSubcontractAndPreparationNotificationsKeepPhysicalFactsAndReplay() throws Exception {
        measureBulkSupplyNotifications(factory.sharedTree("notify-small-"+suffix(),2),2);
    }

    private void measureBulkSupplyNotifications(ProductionChainDataFactory.Scenario scenario,int size) throws Exception {
        factory.login(scenario);
        AnalysisView view=measured("SERVICE","supply.analysis.preview.initial",size,
                ()->analysis.preview(request(scenario,null,"notify-preview-"+suffix())));
        assertInitialDemand(scenario,view);
        Map<String,Object> scale = new LinkedHashMap<>();
        scale.put("event","supply-scale"); scale.put("products",size);
        scale.put("initialMaterialRows",view.flatMaterials().size()); scale.put("historicalRows",historyRows);
        scale.put("maxHeapBytes",Runtime.getRuntime().maxMemory());
        scale.put("migrationHead",jdbc.queryForObject("select max(version::int) from flyway_schema_history where success",Integer.class));
        scale.put("successfulMigrations",jdbc.queryForObject("select count(*) from flyway_schema_history where success and type='SQL'",Integer.class));
        scale.put("jit",jdbc.queryForObject("SHOW jit",String.class));
        scale.put("databaseProfile",System.getenv().getOrDefault("UTEN_PRODUCTION_STRESS_DATABASE_PROFILE","test-default"));
        scale.put("databaseSettings",databaseSettings());
        scale.put("concurrentLoad",System.getProperty("uten.production.concurrentLoad","unspecified"));
        emit(scale);
        List<RouteDecision> roots=view.flatMaterials().stream().filter(row->row.level()==0)
                .map(row->new RouteDecision(null,row.actionGroupKey(),"MAKE",null)).toList();
        view=analysis.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"notify-roots-"+suffix(),roots));
        for (String mode:List.of("BUY","SUBCONTRACT","SUBCONTRACT_PREPARATION")) {
            String route=mode.equals("BUY")?"BUY":"SUBCONTRACT";
            var parents=view.flatMaterials().stream().filter(row->row.parentNodeKey()!=null)
                    .map(row->row.analysisLineId()+"|"+row.parentNodeKey()).collect(java.util.stream.Collectors.toSet());
            var groups=new LinkedHashMap<String,MaterialView>();
            for (MaterialView row:view.flatMaterials()) {
                boolean preparation=parents.contains(row.analysisLineId()+"|"+row.nodeKey());
                if (row.actionable() && route.equals(row.sourceSuggestion()) && row.shortageQty().signum()>0
                        && (route.equals("BUY") || preparation==mode.equals("SUBCONTRACT_PREPARATION"))) {
                    groups.putIfAbsent(row.actionGroupKey(),row);
                }
            }
            List<String> selected=groups.keySet().stream().limit(500).toList();
            var selectedSet=java.util.Set.copyOf(selected);
            assertTrue(selected.size()>=Math.min(size,100),"The notification must remain a real bulk command");
            List<RouteDecision> decisions=selected.stream().map(key->new RouteDecision(null,key,route,null)).toList();
            view=analysis.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"notify-route-"+suffix(),decisions));
            var before=new LinkedHashMap<UUID,BigDecimal>();
            for (MaterialView row:view.flatMaterials()) if (selectedSet.contains(row.actionGroupKey())) {
                before.put(row.materialLineId(),row.shortageQty());
            }
            NotifyRequest notification=new NotifyRequest(view.version(),view.fingerprint(),
                    "notify-bulk-"+route+"-"+suffix(),route,List.of(),selected,null);
            UUID analysisId=view.analysisId();
            long actionsBefore=jdbc.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route=?",
                    Long.class,analysisId,route);
            view=measured("SERVICE","analysis.notify."+mode+"."+selected.size(),size,
                    ()->commands.notifySupply(analysisId,notification));
            assertActionConservation(analysisId);
            assertNoInventoryOrSalesCompletion(scenario);
            for (MaterialView row:view.flatMaterials()) if (before.containsKey(row.materialLineId())) {
                assertEquals(0,before.get(row.materialLineId()).compareTo(row.shortageQty()),
                        "Creating an external request is not a qualified receipt");
                assertEquals(0,row.allocatedAvailableQty().signum());
            }
            long actions=jdbc.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route=?",
                    Long.class,analysisId,route);
            assertEquals(selected.size(),actions-actionsBefore,"Every selected demand group must have exactly one downstream action");
            String expectedDocument=mode.equals("SUBCONTRACT_PREPARATION")?"SUBCONTRACT_MAKE_TASK"
                    :mode.equals("SUBCONTRACT")?"SUBCONTRACT_APPLICATION":"PURCHASE_REQUEST";
            assertEquals(selected.size(),jdbc.queryForObject("""
                    SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND external_document_type=?
                      AND action_group_key IN (SELECT unnest(string_to_array(?, ',')))
                    """,Integer.class,analysisId,expectedDocument,String.join(",",selected)),
                    "Subcontract preparation must not be presented as an already-created external application");
            BigDecimal allocated=jdbc.queryForObject("SELECT coalesce(sum(allocated_qty),0) FROM preplan_supply_action_allocations WHERE analysis_id=?",
                    BigDecimal.class,analysisId);
            measured("SERVICE","analysis.notify."+mode+"."+selected.size()+".replay",size,
                    ()->commands.notifySupply(analysisId,notification));
            assertEquals(actions,jdbc.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route=?",
                    Long.class,analysisId,route));
            assertEquals(0,allocated.compareTo(jdbc.queryForObject(
                    "SELECT coalesce(sum(allocated_qty),0) FROM preplan_supply_action_allocations WHERE analysis_id=?",BigDecimal.class,analysisId)));
            assertNoInventoryOrSalesCompletion(scenario);
        }
    }

    @Test
    @EnabledIfEnvironmentVariable(named = "UTEN_RUN_PRODUCTION_STRESS", matches = "(?i)true")
    void hundredAndMaximumProductsWithHistoryRecordRealServiceAndMockHttpCosts() throws Exception {
        int samples = integerEnv("UTEN_PRODUCTION_STRESS_SAMPLES", 5, 1, 30);
        historyRows=integerEnv("UTEN_PRODUCTION_STRESS_HISTORY_ROWS",20_000,20_000,500_000);
        assertTrue(List.of(20_000,100_000,500_000).contains(historyRows),"Use the documented 20k/100k/500k historical profiles");
        boolean historySeeded=false;
        for (String sizeText : System.getenv().getOrDefault("UTEN_PRODUCTION_STRESS_SIZES", "100,500").split(",")) {
            int size = Integer.parseInt(sizeText.trim());
            assertTrue(size == 100 || size == 500, "Use the documented 100/500 profiles");
            var scenario = factory.sharedTree("scale-" + size + "-" + suffix(), size);
            if (!historySeeded) {
                factory.terminalAnalysisMetadata(scenario,historyRows);
                factory.historicalBomMasters(scenario,historyRows);
                historySeeded=true;
            }
            jdbc.execute("ANALYZE production_material_analyses");
            jdbc.execute("ANALYZE production_material_analysis_items");
            jdbc.execute("ANALYZE goods_bom_items");
            jdbc.execute("ANALYZE goods");
            Map<String, Object> scale = new LinkedHashMap<>();
            scale.put("event", "scale"); scale.put("products", size); scale.put("salesSources", scenario.sources().size());
            scale.put("physicalBomRows", scenario.physicalBomRows()); scale.put("expectedExpandedRows", size * 98);
            scale.put("depth", 2); scale.put("terminalMetadataRows",historyRows); scale.put("historicalBomRows",historyRows); scale.put("samples", samples);
            scale.put("actualDatabaseBomRows",jdbc.queryForObject("select count(*) from goods_bom_items",Long.class));
            scale.put("actualAnalysisSourceRows",jdbc.queryForObject("select count(*) from production_material_analysis_items",Long.class));
            scale.put("java", System.getProperty("java.runtime.version")); scale.put("maxHeapBytes", Runtime.getRuntime().maxMemory());
            scale.put("processors", Runtime.getRuntime().availableProcessors());
            scale.put("concurrentLoad", System.getProperty("uten.production.concurrentLoad", "unspecified"));
            scale.put("postgres", jdbc.queryForObject("select version()", String.class));
            scale.put("migrationHead", jdbc.queryForObject("select max(version::int) from flyway_schema_history where success", Integer.class));
            scale.put("successfulMigrations", jdbc.queryForObject("select count(*) from flyway_schema_history where success and type='SQL'", Integer.class));
            scale.put("jit", jdbc.queryForObject("SHOW jit", String.class));
            scale.put("databaseProfile", System.getenv().getOrDefault("UTEN_PRODUCTION_STRESS_DATABASE_PROFILE", "test-default"));
            scale.put("databaseSettings", databaseSettings());
            scale.put("routeScope", size == 500 ? "five distinct 500-row requests and selected 20 root routes" : "all material routes");
            scale.put("issuedPlans", 20);
            emit(scale);
            factory.login(scenario);
            AnalysisView view = measured("SERVICE", "analysis.preview.initial", size,
                    () -> analysis.preview(request(scenario, null, "scale-preview-" + suffix())));
            assertInitialDemand(scenario, view);
            assertEquals("ACTIVE", view.status());
            UUID id = view.analysisId();
            for (int n = 0; n < samples; n++) {
                factory.login(scenario);
                AnalysisView refresh = view;
                view = measured("SERVICE", "analysis.preview.refresh", size,
                        () -> analysis.preview(request(scenario, refresh, "scale-refresh-" + suffix())));
                assertInitialDemand(scenario, view);
                assertEquals("ACTIVE", view.status());
                measured("SERVICE", "analysis.detail", size, () -> analysis.detail(id));
                var actor = SecurityContextHolder.getContext().getAuthentication();
                measured("MOCK_HTTP", "GET material-analyses/detail", size, () -> {
                    var response = http.perform(get("/api/production/material-analyses/{id}", id)
                            .with(authentication(actor))).andReturn().getResponse();
                    assertEquals(200, response.getStatus());
                    return response.getContentAsByteArray();
                });
                measured("MOCK_HTTP", "GET material-analyses/detail.shared", size, () -> {
                    var response = http.perform(get("/api/production/material-analyses/{id}", id)
                            .param("projection",com.uten.imp.features.production.analysis.MaterialAnalysisResponseProjection.VERSION)
                            .with(authentication(actor))).andReturn().getResponse();
                    assertEquals(200,response.getStatus());
                    return response.getContentAsByteArray();
                });
                // Spring Security clears the MockMvc request's thread context.
                // Restore the fixture actor before the next direct service call.
                factory.login(scenario);
                measured("SERVICE", "analysis.list.active.50", size, () -> analysis.list(null,"ACTIVE",null,1,50));
                measured("SERVICE", "analysis.list.all.50", size, () -> analysis.list(null,null,null,1,50));
            }
            factory.login(scenario);
            view = size == 500 ? confirmSampleRoutesAndPlanRoots(view) : confirmAllRoutes(view, true);
            IssueWorkshopPlansRequest issue = issueRequest(scenario, view, 20, "scale-issue-" + suffix());
            GenerateResult result = measured("SERVICE", "analysis.issueWorkshopPlans.20", size,
                    () -> commands.issueWorkshopPlans(id, issue));
            assertWaitingPlanConservation(scenario, result, 20);
            assertNoInventoryOrSalesCompletion(scenario);
        }
    }

    @Test
    void tenBomLevelsArePreservedAndTheEleventhFailsWithoutLeavingAnAnalysis() {
        var legal = factory.depthChain("depth10-" + suffix(), 10);
        var accepted = analysis.preview(new PreviewRequest(null, null, null, legal.world().warehouseId(),
                "depth10-preview-" + suffix(), legal.sources()));
        assertEquals(11, accepted.flatMaterials().size(), "Root and all ten BOM levels must survive expansion");
        assertEquals(10, accepted.flatMaterials().stream().mapToInt(MaterialView::level).max().orElseThrow());
        assertTrue(accepted.flatMaterials().stream().allMatch(row -> row.requiredQty().compareTo(BigDecimal.TEN) == 0));
        var tooDeep = factory.depthChain("depth11-" + suffix(), 11);
        var rejected = assertThrows(com.uten.imp.common.web.ApiException.class, () -> analysis.preview(new PreviewRequest(
                null, null, null, tooDeep.world().warehouseId(), "depth11-preview-" + suffix(), tooDeep.sources())));
        assertTrue(rejected.getMessage().contains("十层"));
        assertEquals(0, jdbc.queryForObject("select count(*) from production_material_analyses where warehouse_id=?",
                Integer.class, tooDeep.world().warehouseId()), "The rejected analysis must roll back completely");
    }

    @Test
    void cancellationPersistsReplaysAndRejectsAnOutstandingPlanUntilItIsRemoved() throws Exception {
        var scenario = factory.sharedTree("cancel-" + suffix(), 1);
        AnalysisView first = analysis.preview(request(scenario, null, "cancel-preview-" + suffix()));
        CancelRequest cancel = new CancelRequest(first.version(), first.fingerprint(),
                "cancel-command-" + suffix(), "需求已取消");

        AnalysisView cancelled = commands.cancelAnalysis(first.analysisId(), cancel);
        assertEquals("CANCELLED", cancelled.status());
        AnalysisView replay = commands.cancelAnalysis(first.analysisId(), cancel);
        assertEquals(cancelled.version(), replay.version(), "A replay must not cancel or release a second time");
        assertEquals(1, jdbc.queryForObject("""
                SELECT count(*) FROM production_material_analysis_commands
                WHERE analysis_id=? AND operation='CANCEL_ANALYSIS'
                """, Integer.class, first.analysisId()));
        assertThrows(com.uten.imp.common.web.ApiException.class, () -> commands.cancelAnalysis(
                first.analysisId(), new CancelRequest(first.version(), first.fingerprint(),
                        cancel.idempotencyKey(), "不同请求不能使用原幂等键")));

        AnalysisView next = confirmAllRoutes(analysis.preview(
                request(scenario, null, "cancel-plan-preview-" + suffix())), false);
        var product = next.products().getFirst();
        var generated = commands.issueWorkshopPlans(next.analysisId(), new IssueWorkshopPlansRequest(
                next.version(), next.fingerprint(), "cancel-plan-" + suffix(), scenario.world().warehouseId(),
                LocalDate.of(2026, 9, 1), LocalDate.of(2026, 9, 30), false,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(product.analysisLineId(), BigDecimal.TEN))));
        var withPlan = generated.analysis();
        var blocked = assertThrows(com.uten.imp.common.web.ApiException.class, () -> commands.cancelAnalysis(
                next.analysisId(), new CancelRequest(withPlan.version(), withPlan.fingerprint(),
                        "cancel-blocked-" + suffix(), "已下达计划不能直接取消分析")));
        assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT, blocked.getCode());
        assertEquals(withPlan.version(), analysis.detail(next.analysisId()).version());
        assertEquals(0, jdbc.queryForObject("""
                SELECT count(*) FROM production_material_analysis_commands
                WHERE analysis_id=? AND operation='CANCEL_ANALYSIS'
                """, Integer.class, next.analysisId()));

        planService.delete(generated.plans().getFirst().planId());
        AnalysisView released = analysis.detail(next.analysisId());
        assertEquals("CANCELLED", commands.cancelAnalysis(next.analysisId(), new CancelRequest(
                released.version(), released.fingerprint(), "cancel-after-delete-" + suffix(), "草稿已删除，取消分析")).status());
    }

    private AnalysisView confirmAllRoutes(AnalysisView initial, boolean measure) throws Exception {
        Map<String, RouteDecision> byGroup = new LinkedHashMap<>();
        for (MaterialView row : initial.flatMaterials()) if (row.actionable()) {
            byGroup.putIfAbsent(row.actionGroupKey(), new RouteDecision(null, row.actionGroupKey(), row.sourceSuggestion(), null));
        }
        List<RouteDecision> decisions = new ArrayList<>(byGroup.values());
        AnalysisView view = initial;
        for (int offset = 0; offset < decisions.size(); offset += 500) {
            RouteRequest request = new RouteRequest(view.version(), view.fingerprint(), "scale-route-" + suffix(),
                    List.copyOf(decisions.subList(offset, Math.min(offset + 500, decisions.size()))));
            view = measure ? measured("SERVICE", "analysis.saveRoutes." + request.decisions().size(), initial.products().size(),
                    () -> analysis.saveRoutes(initial.analysisId(), request)) : analysis.saveRoutes(initial.analysisId(), request);
        }
        return view;
    }

    /** The maximum-background profile measures five real bulk requests, not 98 repeated setup requests. */
    private AnalysisView confirmSampleRoutesAndPlanRoots(AnalysisView initial) throws Exception {
        Map<String, RouteDecision> byGroup = new LinkedHashMap<>();
        for (MaterialView row : initial.flatMaterials()) if (row.actionable()) {
            byGroup.putIfAbsent(row.actionGroupKey(), new RouteDecision(null, row.actionGroupKey(), row.sourceSuggestion(), null));
        }
        List<RouteDecision> decisions = new ArrayList<>(byGroup.values());
        assertTrue(decisions.size() >= 2500);
        AnalysisView view = initial;
        for (int offset = 0; offset < 2500; offset += 500) {
            RouteRequest request = new RouteRequest(view.version(), view.fingerprint(), "scale-route-" + suffix(),
                    List.copyOf(decisions.subList(offset, offset + 500)));
            view = measured("SERVICE", "analysis.saveRoutes.500", initial.products().size(),
                    () -> analysis.saveRoutes(initial.analysisId(), request));
        }
        var selected = initial.products().stream().filter(row -> row.salesOrderItemId() != null).limit(20)
                .map(ProductView::analysisLineId).collect(java.util.stream.Collectors.toSet());
        List<RouteDecision> roots = view.flatMaterials().stream()
                .filter(row -> selected.contains(row.analysisLineId()) && row.level() == 0)
                .map(row -> new RouteDecision(null, row.actionGroupKey(), "MAKE", null)).toList();
        assertEquals(20, roots.size());
        RouteRequest rootRequest = new RouteRequest(view.version(), view.fingerprint(), "scale-root-route-" + suffix(), roots);
        return measured("SERVICE", "analysis.saveRoutes.selectedRoots.20", initial.products().size(),
                () -> analysis.saveRoutes(initial.analysisId(), rootRequest));
    }

    private PreviewRequest request(ProductionChainDataFactory.Scenario scenario, AnalysisView previous, String key) {
        return new PreviewRequest(previous == null ? null : previous.analysisId(), previous == null ? null : previous.version(),
                previous == null ? null : previous.fingerprint(), scenario.world().warehouseId(), key, scenario.sources());
    }

    private IssueWorkshopPlansRequest issueRequest(ProductionChainDataFactory.Scenario scenario, AnalysisView view, int count, String key) {
        return new IssueWorkshopPlansRequest(view.version(), view.fingerprint(), key, scenario.world().warehouseId(),
                LocalDate.of(2026, 9, 1), LocalDate.of(2026, 9, 30), true,
                view.products().stream().filter(row -> row.salesOrderItemId() != null).limit(count)
                        .map(row -> new IssueWorkshopPlansRequest.IssuePlanLine(row.analysisLineId(), new BigDecimal("10"))).toList());
    }

    private void assertInitialDemand(ProductionChainDataFactory.Scenario scenario, AnalysisView view) {
        assertEquals(scenario.products().size(), view.products().size());
        assertEquals(scenario.products().size() * scenario.expectedExpandedRowsPerProduct(), view.flatMaterials().size());
        assertEquals(view.flatMaterials().size(), view.flatMaterials().stream()
                .map(row -> row.analysisLineId() + ":" + row.nodeKey()).distinct().count());
        for (ProductView product : view.products()) {
            assertEquals(0, product.requestedQty().compareTo(new BigDecimal("10")));
            assertEquals(0, product.readyNowQty().signum());
            List<MaterialView> nodes = view.flatMaterials().stream()
                    .filter(row -> row.analysisLineId().equals(product.analysisLineId())).toList();
            // D is needed under B (10*2*5) and assembled subcontract (10*1*2).
            assertEquals(0, nodes.stream().filter(row -> row.goodsId().equals(scenario.world().goodsD()))
                    .map(MaterialView::requiredQty).reduce(BigDecimal.ZERO, BigDecimal::add).compareTo(new BigDecimal("120")));
            for (UUID sharedLeaf : scenario.sharedBuyLeaves()) assertEquals(0,
                    nodes.stream().filter(row -> row.goodsId().equals(sharedLeaf)).map(MaterialView::requiredQty)
                            .reduce(BigDecimal.ZERO, BigDecimal::add).compareTo(new BigDecimal("100")));
        }
    }

    private void assertActionConservation(UUID analysisId) {
        assertEquals(0, jdbc.queryForObject("""
                select count(*) from preplan_supply_actions a where a.analysis_id=? and a.status<>'CANCELLED'
                  and a.requested_qty <> (select coalesce(sum(x.allocated_qty),0)
                      from preplan_supply_action_allocations x where x.action_id=a.id and x.analysis_id=a.analysis_id)
                """, Integer.class, analysisId));
    }

    private void assertWaitingPlanConservation(ProductionChainDataFactory.Scenario scenario, GenerateResult result, int count) {
        List<UUID> plans = result.plans().stream().map(GeneratedPlan::planId).toList();
        assertEquals(count, plans.size());
        for (UUID plan : plans) {
            assertEquals(1, jdbc.queryForObject("select count(*) from production_execution_segments where plan_id=? and status='WAITING'", Integer.class, plan));
            assertEquals(0, jdbc.queryForObject("select count(*) from stock_reservations where source_doc_id=? and is_deleted=false", Integer.class, plan));
            assertEquals(0, jdbc.queryForObject("""
                    select count(*) from plan_order_item_links l join production_plan_items p on p.id=l.plan_item_id
                    join sales_order_items s on s.id=l.order_item_id
                    where p.plan_id=? and s.order_id<>? and l.is_deleted=false
                    """, Integer.class, plan, scenario.orderId()));
        }
        assertEquals(0, jdbc.queryForObject("select coalesce(sum(planned_qty),0) from sales_order_items where order_id=? and is_deleted=false",
                BigDecimal.class, scenario.orderId()).compareTo(BigDecimal.TEN.multiply(BigDecimal.valueOf(count))));
    }

    private void assertNoInventoryOrSalesCompletion(ProductionChainDataFactory.Scenario scenario) {
        assertEquals(0, jdbc.queryForObject("select count(*) from stock_movements where warehouse_id=?", Integer.class, scenario.world().warehouseId()));
        assertEquals(0, jdbc.queryForObject("select count(*) from stock_reservations where warehouse_id=? and is_deleted=false and status=0", Integer.class, scenario.world().warehouseId()));
        assertEquals(0, jdbc.queryForObject("""
                select count(*) from sales_order_items where order_id=?
                  and (produced_qty<>0 or reserved_qty<>0 or shipped_qty<>0)
                """, Integer.class, scenario.orderId()));
    }

    private Map<String,Object> databaseSettings() {
        return jdbc.queryForMap("""
                SELECT current_setting('shared_buffers') AS shared_buffers, current_setting('work_mem') AS work_mem,
                       current_setting('effective_cache_size') AS effective_cache_size, current_setting('max_connections') AS max_connections,
                       current_setting('fsync') AS fsync, current_setting('synchronous_commit') AS synchronous_commit,
                       current_setting('full_page_writes') AS full_page_writes, current_setting('wal_buffers') AS wal_buffers,
                       current_setting('default_statistics_target') AS default_statistics_target
                """);
    }

    @FunctionalInterface private interface Work<T> { T run() throws Exception; }
    private <T> T measured(String transport, String operation, int products, Work<T> work) throws Exception {
        try (var profile=ProductionOperationProfile.start(operation,products)) {
            return measuredProfiled(transport,operation,products,work,profile);
        }
    }

    private <T> T measuredProfiled(String transport,String operation,int products,Work<T> work,
                                  ProductionOperationProfile profile) throws Exception {
        JvmGc gcBefore = jvmGc();
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        long started = System.nanoTime();
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("transport", transport); row.put("operation", operation); row.put("products", products);
        try {
            T result = work.run();
            row.put("elapsedMillis", (System.nanoTime() - started) / 1_000_000.0);
            row.put("success", true);
            // Separate the real endpoint from the diagnostic serialization of
            // both compatibility representations, which allocates extra buffers.
            JvmGc operationGc = jvmGc();
            row.put("operationGcCollections", operationGc.collections() - gcBefore.collections());
            row.put("operationGcMillis", operationGc.millis() - gcBefore.millis());
            row.put("operationUsedHeapBytes", Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory());
            profile.complete(row);
            long serializationStart = System.nanoTime();
            row.put("responseBytes", result instanceof byte[] bytes ? bytes.length : json.writeValueAsBytes(result).length);
            if (result instanceof AnalysisView view) {
                row.put("legacyResponseBytes",row.get("responseBytes"));
                row.put("sharedResponseBytes",json.writeValueAsBytes(
                        com.uten.imp.features.production.analysis.MaterialAnalysisResponseProjection.project(view)).length);
            } else if (result instanceof GenerateResult generated) {
                row.put("legacyResponseBytes",row.get("responseBytes"));
                row.put("sharedResponseBytes",json.writeValueAsBytes(new com.uten.imp.features.production.analysis.MaterialAnalysisResponseProjection.SharedGenerateResult(
                        com.uten.imp.features.production.analysis.MaterialAnalysisResponseProjection.project(generated.analysis()),generated.replayed(),generated.plans())).length);
            }
            if (operation.equals("analysis.preview.initial") && result instanceof AnalysisView view) {
                row.put("nonNullResponseBytes", json.copy()
                        .setSerializationInclusion(com.fasterxml.jackson.annotation.JsonInclude.Include.NON_NULL)
                        .writeValueAsBytes(view).length);
                row.put("responseFieldBytes", Map.of(
                        "products", json.writeValueAsBytes(view.products()).length,
                        "flatMaterials", json.writeValueAsBytes(view.flatMaterials()).length,
                        "warehouses", json.writeValueAsBytes(view.warehouses()).length,
                        "supplyActions", json.writeValueAsBytes(view.supplyActions()).length));
            }
            row.put("responseSizeMeasurementMillis", (System.nanoTime() - serializationStart) / 1_000_000.0);
            return result;
        } catch (Exception | Error failure) {
            row.put("success", false); row.put("failureType", failure.getClass().getSimpleName());
            throw failure;
        } finally {
            row.putIfAbsent("elapsedMillis", (System.nanoTime() - started) / 1_000_000.0);
            JvmGc gcAfter = jvmGc();
            row.put("gcCollections", gcAfter.collections() - gcBefore.collections());
            row.put("gcMillis", gcAfter.millis() - gcBefore.millis());
            row.put("usedHeapAfterBytes", Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory());
            row.putAll(sample.result()); ProductionJdbcMeasurement.end(); emit(row);
            if (Boolean.TRUE.equals(row.get("success")) && historyRows>0
                    && (operation.equals("analysis.preview.initial") || operation.equals("analysis.list.active.50")
                        || operation.equals("analysis.list.all.50"))) {
                explainActualQueries(sample,operation,products);
            }
        }
    }

    private record JvmGc(long collections, long millis) {}
    private static JvmGc jvmGc() {
        long collections = 0, millis = 0;
        for (var collector : java.lang.management.ManagementFactory.getGarbageCollectorMXBeans()) {
            collections += Math.max(0, collector.getCollectionCount());
            millis += Math.max(0, collector.getCollectionTime());
        }
        return new JvmGc(collections, millis);
    }

    /** Explain exactly the prepared query and scalar bindings issued by the real service, outside its timer. */
    private void explainActualQueries(ProductionJdbcMeasurement.Sample sample,String operation,int products) throws Exception {
        assertFalse(sample.explainCandidates.isEmpty(),"The selected service must provide its real SQL shape for index evidence");
        try (var connection=dataSource.getConnection()) {
            connection.setReadOnly(true); connection.setAutoCommit(false);
            try {
                for (var candidate:sample.explainCandidates.values()) {
                    try (var statement=connection.prepareStatement("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) "+candidate.sql())) {
                        candidate.bind(statement);
                        try (var result=statement.executeQuery()) {
                            assertTrue(result.next());
                            var plan=json.readTree(result.getString(1)).get(0);
                            emit(Map.of("event","explain","operation",operation,"products",products,"historyRows",historyRows,
                                    "sqlFingerprint",candidate.fingerprint(),"plan",safePlan(plan)));
                            if (historyRows>=20_000 && !operation.equals("analysis.list.all.50")) assertNoFullHistoricalScan(plan);
                            if (historyRows >= 20_000 && operation.equals("analysis.preview.initial")
                                    && candidate.sql().stripLeading().startsWith("WITH RECURSIVE")) {
                                compareJitModes(connection, candidate, products);
                            }
                            if (operation.equals("analysis.preview.initial")) {
                                compareFootprintHashes(connection, candidate, products);
                            }
                        }
                    }
                }
            } finally { connection.rollback(); }
        }
    }

    /** Same real prepared query and parameters, session-local JIT only, identical result digest. */
    private void compareJitModes(java.sql.Connection connection,
            ProductionJdbcMeasurement.CapturedQuery candidate, int products) throws Exception {
        String original;
        try (var statement = connection.createStatement(); var result = statement.executeQuery("SHOW jit")) {
            assertTrue(result.next()); original = result.getString(1);
        }
        try {
            setJit(connection, true);
            var enabled = digestQuery(connection, candidate);
            setJit(connection, false);
            var disabled = digestQuery(connection, candidate);
            assertEquals(enabled.rows(), disabled.rows());
            assertEquals(enabled.hash(), disabled.hash(), "JIT must not change any source, quantity, path or marker");
            emit(Map.of("event", "jit-comparison", "products", products, "sqlFingerprint", candidate.fingerprint(),
                    "onMillis", enabled.millis(), "offMillis", disabled.millis(), "rows", enabled.rows(),
                    "sameResult", true, "runtimeJit", original));
        } finally { setJit(connection, "on".equals(original)); }
    }

    private static void setJit(java.sql.Connection connection, boolean enabled) throws Exception {
        try (var statement = connection.createStatement()) {
            statement.execute(enabled ? "SET LOCAL jit=on" : "SET LOCAL jit=off");
        }
    }

    private record QueryDigest(long rows, String hash, double millis) {}
    private static QueryDigest digestQuery(java.sql.Connection connection,
            ProductionJdbcMeasurement.CapturedQuery candidate) throws Exception {
        return digestQuery(connection, candidate, false);
    }

    private void compareFootprintHashes(java.sql.Connection connection,
            ProductionJdbcMeasurement.CapturedQuery candidate, int products) throws Exception {
        String alias = candidate.sql().contains("md5(to_jsonb(material)::text)") || candidate.sql().contains("md5(material::text)") ? "material"
                : candidate.sql().contains("md5(to_jsonb(bom)::text)") || candidate.sql().contains("md5(bom::text)") ? "bom" : null;
        if (alias == null) return;
        String jsonSql = candidate.sql().replace("md5(" + alias + "::text)", "md5(to_jsonb(" + alias + ")::text)");
        var jsonCandidate = new ProductionJdbcMeasurement.CapturedQuery(candidate.fingerprint(), jsonSql, candidate.bindings());
        String alternate = jsonSql.replace("md5(to_jsonb(" + alias + ")::text)", "md5(" + alias + "::text)");
        var composite = new ProductionJdbcMeasurement.CapturedQuery(candidate.fingerprint(), alternate, candidate.bindings());
        for (int sample = 0; sample < 5; sample++) {
            QueryDigest jsonResult;
            QueryDigest textResult;
            if (sample % 2 == 0) {
                jsonResult = digestQuery(connection, jsonCandidate, true);
                textResult = digestQuery(connection, composite, true);
            } else {
                textResult = digestQuery(connection, composite, true);
                jsonResult = digestQuery(connection, jsonCandidate, true);
            }
            assertEquals(jsonResult.rows(), textResult.rows());
            assertEquals(jsonResult.hash(), textResult.hash(), "Only the ephemeral hash encoding may differ");
            emit(Map.of("event", "footprint-hash-comparison", "products", products, "kind", alias,
                    "sample", sample, "rows", jsonResult.rows(), "jsonMillis", jsonResult.millis(),
                    "compositeMillis", textResult.millis(), "sameSourceColumns", true));
        }
    }

    private static QueryDigest digestQuery(java.sql.Connection connection,
            ProductionJdbcMeasurement.CapturedQuery candidate, boolean omitLastHash) throws Exception {
        var hash = java.security.MessageDigest.getInstance("SHA-256");
        long started = System.nanoTime(); long rows = 0;
        try (var statement = connection.prepareStatement(candidate.sql())) {
            candidate.bind(statement);
            try (var result = statement.executeQuery()) {
                int columns = result.getMetaData().getColumnCount() - (omitLastHash ? 1 : 0);
                while (result.next()) {
                    rows++;
                    for (int column = 1; column <= columns; column++) {
                        Object value = result.getObject(column);
                        String canonical = value == null ? "NULL" : value.getClass().getName() + ":" + value;
                        byte[] bytes = canonical.getBytes(java.nio.charset.StandardCharsets.UTF_8);
                        hash.update(java.nio.ByteBuffer.allocate(4).putInt(bytes.length).array()); hash.update(bytes);
                    }
                }
            }
        }
        return new QueryDigest(rows, java.util.HexFormat.of().formatHex(hash.digest()),
                (System.nanoTime() - started) / 1_000_000.0);
    }

    private Object safePlan(com.fasterxml.jackson.databind.JsonNode node) {
        if (node.isArray()) { List<Object> result=new ArrayList<>(); node.forEach(child -> result.add(safePlan(child))); return result; }
        if (!node.isObject()) return json.convertValue(node,Object.class);
        var result=new LinkedHashMap<String,Object>();
        // No SQL expressions, parameter values, conditions, query text or credential-bearing data are persisted.
        java.util.Set<String> keys=java.util.Set.of("Plan","Plans","Node Type","Relation Name","Index Name","Actual Rows","Actual Loops",
                "Rows Removed by Filter","Rows Removed by Index Recheck","Plan Rows","Planning Time","Execution Time",
                "Shared Hit Blocks","Shared Read Blocks","Shared Dirtied Blocks","Shared Written Blocks","Temp Read Blocks","Temp Written Blocks",
                "JIT","Functions","Options","Timing","Generation","Inlining","Optimization","Emission","Total","Expressions","Deforming");
        node.fields().forEachRemaining(entry -> { if (keys.contains(entry.getKey())) result.put(entry.getKey(),safePlan(entry.getValue())); });
        if (node.has("Node Type")) result.put("Index Restricted",
                !node.path("Index Cond").asText().isBlank() || !node.path("Recheck Cond").asText().isBlank());
        return result;
    }

    private void assertNoFullHistoricalScan(com.fasterxml.jackson.databind.JsonNode node) {
        if (node.isArray()) { node.forEach(this::assertNoFullHistoricalScan); return; }
        if (!node.isObject()) return;
        String relation=node.path("Relation Name").asText();
        if (java.util.Set.of("goods_bom_items","production_material_analyses","production_material_analysis_items").contains(relation)) {
            double perLoop=node.path("Actual Rows").asDouble()+node.path("Rows Removed by Filter").asDouble()
                    +node.path("Rows Removed by Index Recheck").asDouble();
            double loops=node.path("Actual Loops").asDouble(1);
            double visited=perLoop*loops;
            // A parameterized current-edge lookup may expand 49k current paths
            // across many small index probes. That is not a scan of 20k unrelated
            // historic edges. Keep rejecting full scans and wide individual probes.
            boolean indexRestricted=java.util.Set.of("Index Scan","Index Only Scan","Bitmap Index Scan")
                    .contains(node.path("Node Type").asText()) && !node.path("Index Cond").asText().isBlank()
                    || node.path("Node Type").asText().equals("Bitmap Heap Scan") && !node.path("Recheck Cond").asText().isBlank();
            boolean boundedIndexProbe=indexRestricted && loops>1 && perLoop<=500;
            assertTrue(visited<historyRows/2.0 || boundedIndexProbe,
                    "Current bucket/tree scanned a substantial historical table: "+relation+" rows="+visited);
        }
        node.elements().forEachRemaining(this::assertNoFullHistoricalScan);
    }

    @Test
    void historyScanGuardDistinguishesBoundedCurrentIndexLoopsFromHistoryScans() throws Exception {
        historyRows=20_000;
        assertDoesNotThrow(() -> assertNoFullHistoricalScan(json.readTree("""
                {"Node Type":"Index Scan","Relation Name":"goods_bom_items","Index Cond":"goods_id = parent.component_goods_id",
                 "Actual Rows":98,"Actual Loops":500}
                """)));
        assertDoesNotThrow(() -> assertNoFullHistoricalScan(json.readTree("""
                {"Node Type":"Bitmap Heap Scan","Relation Name":"goods_bom_items","Recheck Cond":"goods_id = parent.component_goods_id",
                 "Actual Rows":6,"Actual Loops":6584}
                """)));
        assertThrows(AssertionError.class, () -> assertNoFullHistoricalScan(json.readTree("""
                {"Node Type":"Seq Scan","Relation Name":"goods_bom_items","Actual Rows":20000,"Actual Loops":1}
                """)));
        assertThrows(AssertionError.class, () -> assertNoFullHistoricalScan(json.readTree("""
                {"Node Type":"Index Scan","Relation Name":"goods_bom_items","Index Cond":"is_deleted = false",
                 "Actual Rows":20000,"Actual Loops":1}
                """)));
        assertThrows(AssertionError.class, () -> assertNoFullHistoricalScan(json.readTree("""
                {"Node Type":"Index Scan","Relation Name":"goods_bom_items","Actual Rows":98,"Actual Loops":500}
                """)));
        assertThrows(AssertionError.class, () -> assertNoFullHistoricalScan(json.readTree("""
                {"Node Type":"Bitmap Heap Scan","Relation Name":"goods_bom_items","Recheck Cond":"is_deleted = false",
                 "Actual Rows":20000,"Actual Loops":1}
                """)));
    }

    private void emit(Map<String, Object> record) throws Exception {
        Path output = Path.of(System.getProperty("uten.production.measurements", "target/production-scale-measurements.jsonl"));
        Files.createDirectories(output.toAbsolutePath().getParent());
        Files.writeString(output, json.writeValueAsString(record) + System.lineSeparator(), StandardOpenOption.CREATE, StandardOpenOption.APPEND);
    }

    private static int integerEnv(String name, int fallback, int min, int max) {
        int value = Integer.parseInt(System.getenv().getOrDefault(name, Integer.toString(fallback)));
        if (value < min || value > max) throw new IllegalArgumentException(name + " must be " + min + ".." + max);
        return value;
    }
    private static String suffix() { return UUID.randomUUID().toString().substring(0, 8); }
}
