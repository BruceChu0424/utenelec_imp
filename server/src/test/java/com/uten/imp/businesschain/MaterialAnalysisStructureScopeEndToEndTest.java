package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import jakarta.persistence.EntityManager;
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
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.UnexpectedRollbackException;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.sql.DriverManager;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.LinkedHashMap;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.reset;
import org.springframework.test.util.ReflectionTestUtils;

/** Real transaction boundaries and a second committed PostgreSQL connection. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {"spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false"})
@Import(ProductionJdbcMeasurement.Configuration.class)
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = MaterialAnalysisStructureScopeEndToEndTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class MaterialAnalysisStructureScopeEndToEndTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("uten_structure_scope").withUsername("uten_test").withPassword(UUID.randomUUID().toString());
    private static final String SECRET = UUID.randomUUID() + "-" + UUID.randomUUID();
    @DynamicPropertySource static void properties(DynamicPropertyRegistry registry) throws Exception {
        POSTGRES.start();
        var attachments = Files.createTempDirectory("uten-structure-scope-");
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        registry.add("uten.storage.local-dir", () -> attachments.toString());
        registry.add("uten.jwt.secret", () -> SECRET);
        registry.add("uten.crypto.pgp-master-key", () -> SECRET);
        registry.add("uten.crypto.hmac-key", () -> SECRET);
        registry.add("uten.bootstrap.admin-login", () -> "scope-bootstrap");
        registry.add("uten.bootstrap.admin-password", () -> SECRET + "Aa1!");
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) { POSTGRES.stop(); }
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired EntityManager em;
    @Autowired MaterialAnalysisService analysis;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired SalesOrderService sales;
    @Autowired SalesOrderFinanceConfirmService finance;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProductionMutationFootprintPort footprints;
    @Autowired FulfillmentMutationLocks locks;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired ObjectMapper json;
    @MockitoSpyBean ProductionPlanService plans;
    private ProductionChainDataFactory factory;

    @BeforeEach void prepare() { factory = new ProductionChainDataFactory(beans, jdbc, sales, finance); }
    @AfterEach void clear() { reset(plans); SecurityContextHolder.clearContext(); ProductionJdbcMeasurement.end(); }

    @Test void committedBomChangeOnUnselectedSourceDuringLoopRollsBackEveryPlan() throws Exception {
        driftDuringLoop(true);
    }
    @Test void unexpectedMaterialWriteInsidePlanLoopRollsBackEveryPlan() throws Exception {
        driftDuringLoop(false);
    }

    private void driftDuringLoop(boolean bom) throws Exception {
        var scenario = factory.sharedTree("scope-drift-" + suffix(), 3);
        AnalysisView view = previewAndRoute(scenario);
        var third = view.products().get(2);
        UUID rowId = bom ? jdbc.queryForObject("""
                SELECT id FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted ORDER BY id LIMIT 1
                """, UUID.class, third.goodsId()) : materialId(view, third.analysisLineId());
        var approvals = new AtomicInteger();
        doAnswer(invocation -> {
            Object result = invocation.callRealMethod();
            if (approvals.incrementAndGet() == 1) {
                if (bom) committedUpdate("UPDATE goods_bom_items SET qty=qty+1 WHERE id=?", rowId);
                else {
                    // Unexpected writes by this transaction must also be
                    // detected, independent of whether reconciliation changed a row.
                    assertEquals(1, jdbc.update("UPDATE production_material_analysis_materials SET available_qty=available_qty+1 WHERE id=?", rowId));
                }
            }
            return result;
        }).when(plans).approve(any(UUID.class));
        ApiException failure = assertThrows(ApiException.class,
                () -> commands.issueWorkshopPlans(view.analysisId(), issue(view, scenario, true)));
        assertTrue(failure.getMessage().contains("批量下达期间"), failure.getMessage());
        assertEquals(2, approvals.get(), "The unaffected selected plans finish; the full closing snapshot detects the other source drift");
        assertRolledBack(view);
    }

    @Test void unchangedEntryRowsAllowOtherWriterButClosingScopeRollsBackTheWholeBatch() throws Exception {
        var scenario = factory.sharedTree("scope-rowlock-" + suffix(), 3);
        AnalysisView view = previewAndRoute(scenario);
        UUID material = materialId(view, view.products().get(2).analysisLineId());
        BigDecimal original = jdbc.queryForObject(
                "SELECT available_qty FROM production_material_analysis_materials WHERE id=?", BigDecimal.class, material);
        var approvals = new AtomicInteger();
        doAnswer(invocation -> {
            Object result = invocation.callRealMethod();
            if (approvals.incrementAndGet() == 1) {
                try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
                     var timeout = connection.createStatement();
                     var statement = connection.prepareStatement("UPDATE production_material_analysis_materials SET available_qty=available_qty+1 WHERE id=?")) {
                    timeout.execute("SET lock_timeout='200ms'");
                    timeout.execute("SET statement_timeout='10s'");
                    statement.setObject(1, material);
                    assertEquals(1, statement.executeUpdate(),
                            "Input filtering skips the old conflict tuple lock for an unchanged row");
                }
            }
            return result;
        }).when(plans).approve(any(UUID.class));
        var rejected = assertThrows(ApiException.class,
                () -> commands.issueWorkshopPlans(view.analysisId(), issue(view, scenario, true)));
        assertTrue(rejected.getMessage().contains("批量下达期间"), rejected.getMessage());
        assertEquals(2, approvals.get(), "Closing validation catches the committed change after both selected plans");
        assertRolledBack(view);
        assertEquals(0, original.add(BigDecimal.ONE).compareTo(jdbc.queryForObject(
                "SELECT available_qty FROM production_material_analysis_materials WHERE id=?", BigDecimal.class, material)),
                "The independent transaction really committed; only the rejected business batch rolls back");
    }

    @Test void secondPlanFailurePreservesOriginalErrorAndLeavesNoFirstPlan() throws Exception {
        var scenario = factory.sharedTree("scope-fail-" + suffix(), 2);
        AnalysisView view = previewAndRoute(scenario);
        var approvals = new AtomicInteger();
        var original = new IllegalStateException("injected second-plan failure");
        doAnswer(invocation -> {
            if (approvals.incrementAndGet() == 2) throw original;
            return invocation.callRealMethod();
        }).when(plans).approve(any(UUID.class));
        var failure = assertThrows(IllegalStateException.class,
                () -> commands.issueWorkshopPlans(view.analysisId(), issue(view, scenario, true)));
        assertSame(original, failure);
        assertRolledBack(view);
    }

    @Test void caughtClosingConflictStillMarksActualJpaTransactionRollbackOnly() throws Exception {
        var scenario = factory.sharedTree("scope-catch-" + suffix(), 1);
        AnalysisView view = previewAndRoute(scenario);
        UUID material = materialId(view, view.products().getFirst().analysisLineId());
        BigDecimal before = jdbc.queryForObject("SELECT available_qty FROM production_material_analysis_materials WHERE id=?",
                BigDecimal.class, material);
        assertThrows(UnexpectedRollbackException.class, () -> new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
            var guard = locks.acquire(() -> footprints.forAnalyses(List.of(view.analysisId())));
            guard.verifyUnchanged();
            try (var scope = footprints.openAnalysisStructureScope(view.analysisId())) {
                em.createNativeQuery("UPDATE production_material_analysis_materials SET available_qty=available_qty+1 WHERE id=:id")
                        .setParameter("id", material).executeUpdate();
            } catch (ApiException expected) {
                assertTrue(expected.getMessage().contains("批量下达期间"));
            }
        }));
        assertEquals(0, before.compareTo(jdbc.queryForObject(
                "SELECT available_qty FROM production_material_analysis_materials WHERE id=?", BigDecimal.class, material)));
    }

    @Test void standaloneApprovalKeepsFullDiscoveryAndBatchScopeCannotLeakToAnotherAnalysis() throws Exception {
        var scenario = factory.sharedTree("scope-normal-" + suffix(), 2);
        AnalysisView view = previewAndRoute(scenario);
        GenerateResult generated = commands.issueWorkshopPlans(view.analysisId(), issue(view, scenario, false));
        assertEquals(2, generated.plans().size());
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        try { plans.approve(generated.plans().getFirst().planId()); }
        finally { ProductionJdbcMeasurement.end(); }
        long materialReads = sample.explainCandidates.values().stream()
                .filter(query -> query.sql().contains("SELECT material.id,material.goods_id,material.color_id,md5("))
                .mapToLong(query -> sample.fingerprints.get(query.fingerprint())).sum();
        assertTrue(materialReads >= 4, "Standalone approval must keep both original acquire/verify pairs");
        var otherScenario = factory.anotherSalesOrder(scenario);
        AnalysisView other = previewAndRoute(otherScenario);
        UUID otherMaterial = materialId(other, other.products().getFirst().analysisLineId());
        new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
            var guard = locks.acquire(() -> footprints.forAnalyses(List.of(view.analysisId())));
            guard.verifyUnchanged();
            try (var scope = footprints.openAnalysisStructureScope(view.analysisId())) {
                var before = footprints.forAnalyses(List.of(other.analysisId()));
                committedUpdate("UPDATE production_material_analysis_materials SET available_qty=available_qty+1 WHERE id=?", otherMaterial);
                var after = footprints.forAnalyses(List.of(other.analysisId()));
                assertNotEquals(before.fingerprint(), after.fingerprint(), "Another analysis must be read afresh inside this scope");
            }
        });
    }

    @Test void realRequiresNewSuspendsOuterSnapshotAndRestoresItAfterTheInnerRead() throws Exception {
        var scenario = factory.sharedTree("scope-newtx-" + suffix(), 1);
        AnalysisView view = previewAndRoute(scenario);
        var inner = new TransactionTemplate(transactionManager);
        inner.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
            var guard = locks.acquire(() -> footprints.forAnalyses(List.of(view.analysisId())));
            guard.verifyUnchanged();
            try (var scope = footprints.openAnalysisStructureScope(view.analysisId())) {
                var sample = ProductionJdbcMeasurement.begin();
                try {
                    var outer = footprints.forAnalyses(List.of(view.analysisId()));
                    assertEquals(0, staticMaterialReads(sample));
                    var separate = inner.execute(innerStatus -> footprints.forAnalyses(List.of(view.analysisId())));
                    assertEquals(outer.fingerprint(), separate.fingerprint());
                    assertEquals(1, staticMaterialReads(sample), "The new JPA transaction must perform its own material read");
                    assertEquals(outer.fingerprint(), footprints.forAnalyses(List.of(view.analysisId())).fingerprint());
                    assertEquals(1, staticMaterialReads(sample), "Resuming the outer transaction restores only its own checked scope");
                } finally { ProductionJdbcMeasurement.end(); }
            }
        });
    }

    @Test void unchangedNodeInputSkipsAllConflictsButKeepsRowsRoutesAndAuditWhileRealChangesReachGuards() throws Exception {
        var scenario=factory.sharedTree("node-noop-"+suffix(),2);
        AnalysisView view=previewAndRoute(scenario);
        UUID routeNode=jdbc.queryForObject("""
                SELECT id FROM production_material_analysis_materials
                WHERE analysis_id=? AND node_role='BOM_COMPONENT' AND source_suggestion='BUY'
                ORDER BY analysis_item_id,depth,node_key LIMIT 1
                """,UUID.class,view.analysisId());
        view=analysis.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"noop-route-"+suffix(),
                List.of(new RouteDecision(routeNode,null,"BUY",null))));
        UUID analysisId=view.analysisId();
        var rows=jdbc.queryForList("""
                SELECT * FROM production_material_analysis_materials
                WHERE analysis_id=? AND node_role='BOM_COMPONENT' ORDER BY analysis_item_id,depth,node_key LIMIT 100
                """,analysisId);
        assertEquals(100,rows.size());
        assertTrue(rows.stream().anyMatch(row->row.get("color_id")==null&&row.get("expected_ready_date")==null),
                "Real null UUID/date inputs must survive the typed CTE");
        assertTrue(jdbc.queryForObject("SELECT confirmed_route IS NOT NULL FROM production_material_analysis_materials WHERE id=?",Boolean.class,routeNode));
        String before=nodeDigest(analysisId);long auditBefore=nodeAudits(analysisId);
        new TransactionTemplate(transactionManager).executeWithoutResult(status->{
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
            var guard=locks.acquire(()->footprints.forAnalyses(List.of(analysisId)));guard.verifyUnchanged();
            try {
                var legacy=MaterialNodeUpsertProbe.explain(em,json,analysisId,scenario.world().superAdminUserId(),rows,false);
                var filtered=MaterialNodeUpsertProbe.explain(em,json,analysisId,scenario.world().superAdminUserId(),rows,true);
                assertEquals(100,legacy.path("Plan").path("Conflicting Tuples").asInt());
                assertEquals(0,filtered.path("Plan").path("Conflicting Tuples").asInt());
                assertEquals(before,nodeDigest(analysisId));assertEquals(auditBefore,nodeAudits(analysisId));
                var directory=java.nio.file.Path.of(System.getProperty("uten.build.directory","target"));
                Files.createDirectories(directory);
                json.writerWithDefaultPrettyPrinter().writeValue(directory.resolve("material-node-noop-proof.json").toFile(),
                        Map.of("rows",100,"unfilteredPlan",legacy,"filteredPlan",filtered,"fullRowsRoutesAuditUnchanged",true));

                var changed=new LinkedHashMap<>(rows.getFirst());
                String stage="FINISH".equals(changed.get("control_stage"))?"START":"FINISH";
                changed.put("control_stage",stage);
                var realChange=MaterialNodeUpsertProbe.explain(em,json,analysisId,scenario.world().superAdminUserId(),List.of(changed),true);
                assertEquals(1,realChange.path("Plan").path("Conflicting Tuples").asInt());
                MaterialNodeUpsertProbe.assertUpdateGuardRan(realChange);
                assertEquals(stage,jdbc.queryForObject("SELECT control_stage FROM production_material_analysis_materials WHERE id=?",String.class,changed.get("id")));

                var inactive=rows.get(1);
                jdbc.update("UPDATE production_material_analysis_materials SET active=FALSE WHERE id=?",inactive.get("id"));
                var activated=MaterialNodeUpsertProbe.explain(em,json,analysisId,scenario.world().superAdminUserId(),List.of(inactive),true);
                assertEquals(1,activated.path("Plan").path("Conflicting Tuples").asInt());
                MaterialNodeUpsertProbe.assertUpdateGuardRan(activated);
                assertTrue(jdbc.queryForObject("SELECT active FROM production_material_analysis_materials WHERE id=?",Boolean.class,inactive.get("id")));
                em.createNativeQuery("SET CONSTRAINTS ALL IMMEDIATE").executeUpdate();
            } catch(java.io.IOException failure) { throw new IllegalStateException(failure); }
            finally { status.setRollbackOnly(); }
        });
        assertEquals(before,nodeDigest(analysisId));assertEquals(auditBefore,nodeAudits(analysisId));
    }

    @Test void unchangedStructureStillRecomputesFreshPhysicalAvailability() throws Exception {
        var scenario=factory.sharedTree("node-numeric-"+suffix(),2);
        AnalysisView before=previewAndRoute(scenario);
        UUID id=before.analysisId(),goods=scenario.world().goodsE();
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM production_material_analysis_materials WHERE analysis_id=? AND goods_id=? AND available_qty<>0",Integer.class,id,goods));
        String structure=structureDigest(id);
        var harness=new FullChainEndToEndTest();beans.autowireBean(harness);
        ReflectionTestUtils.invokeMethod(harness,"receiveOpeningInputsForA",scenario.world(),"3");
        factory.login(scenario);
        AnalysisView refreshed=analysis.preview(new PreviewRequest(id,before.version(),before.fingerprint(),
                scenario.world().warehouseId(),"numeric-refresh-"+suffix(),scenario.sources()));
        assertTrue(refreshed.version()>before.version());
        assertEquals(structure,structureDigest(id));
        assertTrue(jdbc.queryForObject("SELECT count(*) FROM production_material_analysis_materials WHERE analysis_id=? AND goods_id=? AND available_qty=3",Integer.class,id,goods)>0,
                "The full allocation algorithm must publish newly received physical stock despite zero structural writes");
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM production_material_analysis_materials WHERE analysis_id=? AND goods_id=? AND available_qty<>3",Integer.class,id,goods));
    }

    private String nodeDigest(UUID analysisId) {
        return jdbc.queryForObject("SELECT md5(string_agg(to_jsonb(material)::text,E'\\n' ORDER BY id)) FROM production_material_analysis_materials material WHERE analysis_id=?",String.class,analysisId);
    }
    private long nodeAudits(UUID analysisId) {
        return jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='production_material_analysis_materials' AND target_id IN(SELECT id::text FROM production_material_analysis_materials WHERE analysis_id=?)",Long.class,analysisId);
    }
    private String structureDigest(UUID analysisId) {
        return jdbc.queryForObject("""
                SELECT md5(string_agg(ROW(analysis_item_id,node_key,parent_node_key,bom_item_id,goods_id,color_id,unit_id,depth,path,
                    per_product_qty,control_stage,consumption_basis,basis_output_qty,allow_partial_package,hard_gate,bom_qty,
                    parent_per_product_qty,calculation_mode,source_suggestion,active)::text,E'\n' ORDER BY id))
                FROM production_material_analysis_materials WHERE analysis_id=? AND node_role='BOM_COMPONENT'
                """,String.class,analysisId);
    }

    @Test void moreThanTheDriverParameterLimitOfNodeReferencesUsesConstantArrayBindings() throws Exception {
        var scenario = factory.sharedTree("scope-array-" + suffix(), 1);
        AnalysisView view = previewAndRoute(scenario);
        Object service = org.springframework.test.util.AopTestUtils.getUltimateTargetObject(analysis);
        new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
            List<?> sources = org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                    service, "loadSourceLines", view.analysisId(), false);
            List<?> original = org.springframework.test.util.ReflectionTestUtils.invokeMethod(service, "loadBomTrees", sources);
            assertNotNull(original); assertFalse(original.isEmpty());
            var expanded = new java.util.ArrayList<Object>(original);
            Object prototype = original.getFirst();
            var components = prototype.getClass().getRecordComponents();
            Object[] values = new Object[components.length];
            int keyIndex = -1;
            try {
                for (int index = 0; index < components.length; index++) {
                    var accessor = components[index].getAccessor(); accessor.setAccessible(true);
                    values[index] = accessor.invoke(prototype);
                    if (components[index].getName().equals("nodeKey")) keyIndex = index;
                }
                var constructor = prototype.getClass().getDeclaredConstructor(java.util.Arrays.stream(components)
                        .map(java.lang.reflect.RecordComponent::getType).toArray(Class<?>[]::new));
                constructor.setAccessible(true);
                assertTrue(keyIndex >= 0);
                for (int index = 0; index < 70_000; index++) {
                    values[keyIndex] = UUID.randomUUID().toString();
                    expanded.add(constructor.newInstance(values));
                }
            } catch (ReflectiveOperationException failure) { throw new IllegalStateException(failure); }
            var refs = new java.util.HashSet<String>();
            for (Object node : expanded) {
                refs.add(org.springframework.test.util.ReflectionTestUtils.invokeMethod(service, "nodeAllocationKey", node));
            }
            assertTrue(refs.size() > 65_536);
            var sample = ProductionJdbcMeasurement.begin();
            try {
                java.util.Map<?, ?> owned = org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                        service, "qualifiedOwnedStock", view.analysisId(), refs);
                assertNotNull(owned); assertTrue(owned.isEmpty());
                assertNotNull(org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                        service, "availability", view.analysisId(), scenario.world().warehouseId(), expanded, sources));
            } finally { ProductionJdbcMeasurement.end(); }
            assertTrue(sample.jdbcCalls >= 2, "Both actual entitlement and stock-availability queries must execute");
            assertTrue(sample.maxPreparedParameterIndex <= 32,
                    "Projected node count must not become scalar JDBC parameter count: " + sample.maxPreparedParameterIndex);
        });
    }

    private static long staticMaterialReads(ProductionJdbcMeasurement.Sample sample) {
        return sample.explainCandidates.values().stream()
                .filter(query -> query.sql().contains("SELECT material.id,material.goods_id,material.color_id,md5("))
                .mapToLong(query -> sample.fingerprints.get(query.fingerprint())).sum();
    }

    private AnalysisView previewAndRoute(ProductionChainDataFactory.Scenario scenario) {
        factory.login(scenario);
        var view = analysis.preview(new PreviewRequest(null, null, null, scenario.world().warehouseId(),
                "scope-preview-" + suffix(), scenario.sources()));
        List<RouteDecision> roots = view.flatMaterials().stream().filter(row -> row.level() == 0)
                .map(row -> new RouteDecision(null, row.actionGroupKey(), "MAKE", null)).toList();
        return analysis.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(), "scope-route-" + suffix(), roots));
    }
    private IssueWorkshopPlansRequest issue(AnalysisView view, ProductionChainDataFactory.Scenario scenario, boolean approve) {
        return new IssueWorkshopPlansRequest(view.version(), view.fingerprint(), "scope-issue-" + suffix(), scenario.world().warehouseId(),
                LocalDate.of(2026, 9, 1), LocalDate.of(2026, 9, 30), approve,
                view.products().stream().limit(2).map(row -> new IssueWorkshopPlansRequest.IssuePlanLine(
                        row.analysisLineId(), BigDecimal.TEN)).toList());
    }
    private UUID materialId(AnalysisView view, UUID sourceId) {
        return view.flatMaterials().stream().filter(row -> row.analysisLineId().equals(sourceId) && row.level() == 1)
                .findFirst().orElseThrow().materialLineId();
    }
    private void assertRolledBack(AnalysisView before) {
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM production_plans WHERE material_analysis_id=?", Integer.class, before.analysisId()));
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM production_material_analysis_commands WHERE analysis_id=? AND operation='GENERATE_PLAN'", Integer.class, before.analysisId()));
        assertEquals(before.version(), analysis.detail(before.analysisId()).version());
    }
    private void committedUpdate(String sql, UUID id) {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             var timeout = connection.createStatement(); var statement = connection.prepareStatement(sql)) {
            timeout.execute("SET statement_timeout='10s'");
            statement.setObject(1, id);
            assertEquals(1, statement.executeUpdate());
        } catch (Exception failure) { throw new IllegalStateException("Independent committed fixture mutation failed", failure); }
    }
    private static String suffix() { return UUID.randomUUID().toString().substring(0, 8); }
}
