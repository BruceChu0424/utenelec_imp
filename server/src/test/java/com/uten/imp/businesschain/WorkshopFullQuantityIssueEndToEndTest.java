package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderWriteService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullSource;
import org.junit.jupiter.params.provider.ValueSource;
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
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** ADR-099: the submit-time full-quantity choice does not redefine the preceding ordinary preview. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WorkshopFullQuantityIssueEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired AggregateMaterialOrderWriteService writer;
    private AggregateMaterialOrderEndToEndTest support;

    @BeforeEach
    void prepare() {
        support = new AggregateMaterialOrderEndToEndTest();
        beans.autowireBean(support);
        support.before();
    }

    @AfterEach
    void clearActor() { SecurityContextHolder.clearContext(); }

    @ParameterizedTest
    @NullSource
    @ValueSource(booleans = false)
    void omittedAndFalseKeepOrdinaryPreviewAndRealAdoptionEqual(Boolean skipAutoClaim) {
        Fixture fixture = fixture();
        IssueWorkshopPlansRequest request = issue(fixture, skipAutoClaim);
        AnalysisView preview = preview(fixture, request);
        assertEquals(0, claims(fixture));
        assertEquals(0, plans(fixture));

        var issued = commands.issueWorkshopPlans(fixture.target().analysisId(), request);
        assertTrue(issued.plans().isEmpty());
        assertEquals(List.of(), MaterialAnalysisPreviewParity.mismatches(preview, issued.analysis(), Set.of()));
        qty("2", root(issued.analysis(), fixture).preparationAdoptedQty());
        qty("0", available(fixture));
        assertEquals(1, claims(fixture));
        assertTrue(commands.issueWorkshopPlans(fixture.target().analysisId(), request).replayed());
        assertEquals(1, claims(fixture));
        assertEquals(0, plans(fixture));
    }

    @Test
    void fullQuantityCreatesTheTypedPlanWithoutClaimingPublicOutputAndRejectsChangedReplayIntent() {
        Fixture fixture = fixture();
        IssueWorkshopPlansRequest request = issue(fixture, true);
        // The choice is made at submission. Its preceding preview retains the ordinary contract.
        AnalysisView ordinaryPreview = preview(fixture, request);
        assertEquals(0, claims(fixture));
        assertEquals(0, plans(fixture));
        qty("2", available(fixture));

        var issued = commands.issueWorkshopPlans(fixture.target().analysisId(), request);
        assertEquals(1, issued.plans().size());
        UUID plan = issued.plans().getFirst().planId();
        qty("2", db.queryForObject("SELECT sum(qty) FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",
                BigDecimal.class, plan));
        qty("0", root(issued.analysis(), fixture).preparationAdoptedQty());
        qty("2", available(fixture));
        assertEquals(0, claims(fixture));
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM preplan_supply_actions
                WHERE analysis_id=? AND operation_type='SHARED_FUTURE_CLAIM'
                """, Integer.class, fixture.target().analysisId()));
        assertTrue(root(ordinaryPreview, fixture).preparationAdoptedQty()
                .compareTo(root(issued.analysis(), fixture).preparationAdoptedQty()) > 0,
                "ADR-099 permits the full-quantity submission to differ from the preceding ordinary preview");

        var replay = commands.issueWorkshopPlans(fixture.target().analysisId(), request);
        assertTrue(replay.replayed());
        assertEquals(plan, replay.plans().getFirst().planId());
        assertEquals(1, plans(fixture));
        qty("2", available(fixture));
        var changed = new IssueWorkshopPlansRequest(request.version(), request.fingerprint(), request.idempotencyKey(),
                request.warehouseId(), request.billDate(), request.deliveryDate(), request.approveNow(), request.lines(), false);
        ApiException conflict = assertThrows(ApiException.class,
                () -> commands.issueWorkshopPlans(fixture.target().analysisId(), changed));
        assertTrue(conflict.getMessage().contains("同一防重复提交标识已用于不同内容的请求"), conflict.getMessage());
        assertEquals(1, plans(fixture));
        assertEquals(0, claims(fixture));
        qty("2", available(fixture));
    }

    @Test
    void batchedPreviewLookupRetainsDefaultZeroDepartmentLatestDraftAndExecutionBoundaries() throws Exception {
        Fixture fixture = fixture();
        var source = fixture.source();
        ReflectionTestUtils.invokeMethod(support.fixture, "putDirectTargetStockZeroPriceAt", source.world(),
                source.material(), new BigDecimal("10"), source.world().warehouseId());
        UUID first = commands.issueWorkshopPlans(fixture.target().analysisId(), issue(fixture, true))
                .plans().getFirst().planId();
        Object otherAssignment = ReflectionTestUtils.invokeMethod(support.fixture, "productionAssignment",
                "preview-lookup-workshop-" + UUID.randomUUID());
        UUID otherDepartment = ReflectionTestUtils.invokeMethod(otherAssignment, "workshopId");
        UUID otherWorker = ReflectionTestUtils.invokeMethod(otherAssignment, "workerId");
        UUID latest = append(fixture, otherDepartment, otherWorker, true, BigDecimal.ZERO);
        UUID draft = append(fixture, source.workshop(), source.worker(), false, new BigDecimal(".25"));
        assertNotEquals(first, latest);
        assertNotEquals(first, draft);

        assertLookup(fixture, BigDecimal.ZERO, null, true, latest);
        assertLookup(fixture, BigDecimal.ZERO, source.workshop(), true, first);
        assertLookup(fixture, BigDecimal.ZERO, otherDepartment, true, latest);
        assertLookup(fixture, BigDecimal.ZERO, null, false, null);
        assertLookup(fixture, new BigDecimal(".25"), null, false, draft);
        assertLookup(fixture, null, source.workshop(), true, draft);
        assertLookup(fixture, null, otherDepartment, true, null);

        // A real workshop draw request is an execution fact; it freezes in-place growth.
        support.fixture.confirmFullKitRoutes(first);
        List<UUID> draws = ReflectionTestUtils.invokeMethod(support.fixture, "currentPlanDrawIds", first);
        assertNotNull(draws);
        assertFalse(draws.isEmpty());
        support.fixture.requestWorkshopDraws("preview-lookup-freeze-" + first, draws);
        assertFalse(db.queryForObject("SELECT fn_material_analysis_plan_growable(?)", Boolean.class, first));
        assertLookup(fixture, BigDecimal.ZERO, source.workshop(), true, null);
        assertLookup(fixture, BigDecimal.ZERO, null, true, latest);
    }

    private UUID append(Fixture fixture, UUID department, UUID worker, boolean approve, BigDecimal rate) {
        var view = analyses.detail(fixture.target().analysisId());
        var line = new IssueWorkshopPlansRequest.IssuePlanLine(null, view.products().getFirst().analysisLineId(),
                BigDecimal.ONE, null, null, department, null, worker, null, null, true, rate);
        var request = new IssueWorkshopPlansRequest(view.version(), view.fingerprint(),
                "preview-lookup-append-" + UUID.randomUUID(), fixture.source().world().warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), approve, List.of(line), true);
        return commands.issueWorkshopPlans(view.analysisId(), request).plans().getFirst().planId();
    }

    private void assertLookup(Fixture fixture, BigDecimal requestedRate, UUID department,
                              boolean approve, UUID expectedPlan) throws Exception {
        UUID line = fixture.target().products().getFirst().analysisLineId();
        Class<?> lookup = Class.forName(MaterialAnalysisCommandService.class.getName() + "$PreviewPlanLookup");
        var constructor = lookup.getDeclaredConstructor(int.class, UUID.class, UUID.class, UUID.class, BigDecimal.class);
        constructor.setAccessible(true);
        Object input = constructor.newInstance(0, line, fixture.source().common(), department, requestedRate);
        var transaction = new org.springframework.transaction.support.TransactionTemplate(
                beans.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        transaction.setReadOnly(true);
        transaction.setIsolationLevel(org.springframework.transaction.TransactionDefinition.ISOLATION_REPEATABLE_READ);
        transaction.executeWithoutResult(ignored -> {
            db.execute("SET TRANSACTION READ ONLY");
            Map<?, ?> batch = ReflectionTestUtils.invokeMethod(commands, "previewGrowablePlans",
                    fixture.target().analysisId(), List.of(input), approve);
            assertNotNull(batch);
            BigDecimal rate = com.uten.imp.features.production.plan.ProductionOverproductionAllowance.resolve(
                    beans.getBean(jakarta.persistence.EntityManager.class), fixture.source().common(), requestedRate);
            Object original = ReflectionTestUtils.invokeMethod(commands, "growablePlanFor",
                    fixture.target().analysisId(), line, department, approve, rate, false);
            assertEquals(original, batch.get(line), "The batched query must retain the original per-line selection");
            UUID selected = original == null ? null : ReflectionTestUtils.invokeMethod(original, "planId");
            assertEquals(expectedPlan, selected);
        });
    }

    private Fixture fixture() {
        var source = support.create(true, true, "1");
        var supplied = writer.submit(source.analysis(), support.command(source,
                List.of(support.input(source, source.common(), "MAKE", "5", true))));
        UUID sourceItem = db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",
                UUID.class, supplied.batches().getFirst().documentId());
        var target = analyses.preview(new PreviewRequest(null, null, null, source.world().warehouseId(),
                "full-quantity-preview-" + UUID.randomUUID(), List.of(new PreviewItem("OTHER", null, source.common(),
                null, source.world().unitId(), "full-quantity-source-" + UUID.randomUUID(), "足额下达独立来源",
                BusinessTime.today().plusDays(10), new BigDecimal("2")))));
        target = analyses.saveRoutes(target.analysisId(), new RouteRequest(target.version(), target.fingerprint(),
                "full-quantity-routes-" + target.analysisId(), target.flatMaterials().stream()
                .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                        row.goodsId().equals(source.common()) ? "MAKE" : "BUY", null)).toList()));
        Fixture fixture = new Fixture(source, sourceItem, target);
        qty("2", available(fixture));
        return fixture;
    }

    private IssueWorkshopPlansRequest issue(Fixture fixture, Boolean skipAutoClaim) {
        var source = fixture.source();
        var target = fixture.target();
        var line = new IssueWorkshopPlansRequest.IssuePlanLine(null, target.products().getFirst().analysisLineId(),
                new BigDecimal("2"), null, null, source.workshop(), null, source.worker(), null, null, false, BigDecimal.ZERO);
        return new IssueWorkshopPlansRequest(target.version(), target.fingerprint(), "full-quantity-issue-" + target.analysisId(),
                source.world().warehouseId(), BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(line), skipAutoClaim);
    }

    private AnalysisView preview(Fixture fixture, IssueWorkshopPlansRequest request) {
        return commands.previewIssuePlans(fixture.target().analysisId(), new PreviewIssuePlansRequest(request.version(),
                request.fingerprint(), request.idempotencyKey(), request.warehouseId(), request.billDate(),
                request.deliveryDate(), request.approveNow(), request.lines(), List.of()));
    }

    private long claims(Fixture fixture) {
        return db.queryForObject("SELECT count(*) FROM preplan_make_public_claims WHERE target_analysis_id=?",
                Long.class, fixture.target().analysisId());
    }

    private long plans(Fixture fixture) {
        return db.queryForObject("SELECT count(*) FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted",
                Long.class, fixture.target().analysisId());
    }

    private BigDecimal available(Fixture fixture) {
        return db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_make_public_supply_state WHERE source_plan_item_id=?",
                BigDecimal.class, fixture.sourceItem());
    }

    private static MaterialView root(AnalysisView view, Fixture fixture) {
        return view.flatMaterials().stream().filter(row -> row.goodsId().equals(fixture.source().common()))
                .findFirst().orElseThrow();
    }

    private static void qty(String expected, BigDecimal actual) {
        assertEquals(0, new BigDecimal(expected).compareTo(actual), expected + " != " + actual);
    }

    private record Fixture(AggregateMaterialOrderEndToEndTest.Case source, UUID sourceItem, AnalysisView target) {}
}
