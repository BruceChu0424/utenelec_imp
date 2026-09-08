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
@AutoConfigureMockMvc
@Import(ProductionJdbcMeasurement.Configuration.class)
class ProductionMaterialAnalysisScalePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("uten_production_scale").withUsername("uten_test").withPassword(UUID.randomUUID().toString());
    private static final String TEST_SECRET = UUID.randomUUID() + "-" + UUID.randomUUID();

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
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @Autowired javax.sql.DataSource dataSource;
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
            scale.put("postgres", jdbc.queryForObject("select version()", String.class));
            scale.put("migrationHead", jdbc.queryForObject("select max(version::int) from flyway_schema_history where success", Integer.class));
            emit(scale);
            AnalysisView view = measured("SERVICE", "analysis.preview.initial", size,
                    () -> analysis.preview(request(scenario, null, "scale-preview-" + suffix())));
            assertInitialDemand(scenario, view);
            UUID id = view.analysisId();
            for (int n = 0; n < samples; n++) {
                factory.login(scenario);
                AnalysisView refresh = view;
                view = measured("SERVICE", "analysis.preview.refresh", size,
                        () -> analysis.preview(request(scenario, refresh, "scale-refresh-" + suffix())));
                measured("SERVICE", "analysis.detail", size, () -> analysis.detail(id));
                var actor = SecurityContextHolder.getContext().getAuthentication();
                measured("MOCK_HTTP", "GET material-analyses/detail", size, () -> {
                    var response = http.perform(get("/api/production/material-analyses/{id}", id)
                            .with(authentication(actor))).andReturn().getResponse();
                    assertEquals(200, response.getStatus());
                    return response.getContentAsByteArray();
                });
                measured("SERVICE", "analysis.list.active.50", size, () -> analysis.list(null,"ACTIVE",null,1,50));
                measured("SERVICE", "analysis.list.all.50", size, () -> analysis.list(null,null,null,1,50));
            }
            factory.login(scenario);
            view = confirmAllRoutes(view, true);
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

    @FunctionalInterface private interface Work<T> { T run() throws Exception; }
    private <T> T measured(String transport, String operation, int products, Work<T> work) throws Exception {
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        long started = System.nanoTime();
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("transport", transport); row.put("operation", operation); row.put("products", products);
        try {
            T result = work.run();
            row.put("elapsedMillis", (System.nanoTime() - started) / 1_000_000.0);
            row.put("success", true);
            long serializationStart = System.nanoTime();
            row.put("responseBytes", result instanceof byte[] bytes ? bytes.length : json.writeValueAsBytes(result).length);
            row.put("responseSizeMeasurementMillis", (System.nanoTime() - serializationStart) / 1_000_000.0);
            return result;
        } catch (Exception | AssertionError failure) {
            row.put("success", false); row.put("failureType", failure.getClass().getSimpleName());
            throw failure;
        } finally {
            row.putIfAbsent("elapsedMillis", (System.nanoTime() - started) / 1_000_000.0);
            row.putAll(sample.result()); ProductionJdbcMeasurement.end(); emit(row);
            if (Boolean.TRUE.equals(row.get("success")) && historyRows>0
                    && (operation.equals("analysis.preview.initial") || operation.equals("analysis.list.active.50")
                        || operation.equals("analysis.list.all.50"))) {
                explainActualQueries(sample,operation,products);
            }
        }
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
                        }
                    }
                }
            } finally { connection.rollback(); }
        }
    }

    private Object safePlan(com.fasterxml.jackson.databind.JsonNode node) {
        if (node.isArray()) { List<Object> result=new ArrayList<>(); node.forEach(child -> result.add(safePlan(child))); return result; }
        if (!node.isObject()) return json.convertValue(node,Object.class);
        var result=new LinkedHashMap<String,Object>();
        // No SQL expressions, parameter values, conditions, query text or credential-bearing data are persisted.
        java.util.Set<String> keys=java.util.Set.of("Plan","Plans","Node Type","Relation Name","Index Name","Actual Rows","Actual Loops",
                "Rows Removed by Filter","Rows Removed by Index Recheck","Plan Rows","Planning Time","Execution Time",
                "Shared Hit Blocks","Shared Read Blocks","Shared Dirtied Blocks","Shared Written Blocks","Temp Read Blocks","Temp Written Blocks");
        node.fields().forEachRemaining(entry -> { if (keys.contains(entry.getKey())) result.put(entry.getKey(),safePlan(entry.getValue())); });
        return result;
    }

    private void assertNoFullHistoricalScan(com.fasterxml.jackson.databind.JsonNode node) {
        if (node.isArray()) { node.forEach(this::assertNoFullHistoricalScan); return; }
        if (!node.isObject()) return;
        String relation=node.path("Relation Name").asText();
        if (java.util.Set.of("goods_bom_items","production_material_analyses","production_material_analysis_items").contains(relation)) {
            double visited=(node.path("Actual Rows").asDouble()+node.path("Rows Removed by Filter").asDouble()
                    +node.path("Rows Removed by Index Recheck").asDouble())*node.path("Actual Loops").asDouble(1);
            assertTrue(visited<historyRows/2.0,"Current bucket/tree scanned a substantial historical table: "+relation+" rows="+visited);
        }
        node.elements().forEachRemaining(this::assertNoFullHistoricalScan);
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
