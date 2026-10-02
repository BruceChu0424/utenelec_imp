package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.AggregateAllocationPendingParity;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderPreviewService;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderWriteService;
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

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** The preparation table's ordinary MAKE components can choose existing supply or extra stocking. */
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
class AggregateMaterialOrderFullQuantityEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired AggregateMaterialOrderPreviewService preview;
    @Autowired AggregateMaterialOrderWriteService writer;
    private AggregateMaterialOrderEndToEndTest support;

    @BeforeEach void prepare() {
        support = new AggregateMaterialOrderEndToEndTest();
        beans.autowireBean(support);
        support.before();
    }

    @AfterEach void clearActor() {
        SecurityContextHolder.clearContext();
        AggregateAllocationPendingParity.assertMatchesDatabaseFunctions(db);
    }

    @ParameterizedTest
    @NullSource
    @ValueSource(booleans = false)
    void ordinaryComponentAdoptsPublicMakeSupplyWithoutIssuingDuplicatePlans(Boolean skipAutoClaim) {
        Fixture fixture = fixture();
        var command = command(fixture, "2", false, skipAutoClaim);
        var result = writer.submit(fixture.target().analysisId(), command);
        assertTrue(result.batches().isEmpty());
        assertEquals(0, plans(fixture));
        assertEquals(1, claims(fixture));
        qty("0", available(fixture.sourceItem()));
        qty("2", component(result.analysis(), fixture).preparationAdoptedQty());
        assertTrue(writer.submit(fixture.target().analysisId(), command).replayed());
        assertEquals(1, claims(fixture));
    }

    @Test
    void fullQuantityPreservesAvailableSupplyAndPublicAppendIncreasesThePool() {
        Fixture fixture = fixture();
        var command = command(fixture, "2", false, true);
        var result = writer.submit(fixture.target().analysisId(), command);
        var batch = result.batches().getFirst();
        assertEquals(1, plans(fixture));
        assertEquals(0, claims(fixture));
        qty("2", available(fixture.sourceItem()));
        qty("2", db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",
                BigDecimal.class, batch.planId()));
        qty("2", db.queryForObject("SELECT SUM(required_qty) FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",
                BigDecimal.class, batch.planId()));
        qty("0", component(result.analysis(), fixture).preparationAdoptedQty());
        assertTrue(writer.submit(fixture.target().analysisId(), command).replayed());
        var changedIntent = new AggregateMaterialOrderContracts.SubmitRequest(command.version(), command.fingerprint(),
                command.idempotencyKey(), command.warehouseId(), command.billDate(), command.deliveryDate(),
                command.approveNow(), command.groups(), command.previewFingerprint(), false);
        assertThrows(ApiException.class, () -> writer.submit(fixture.target().analysisId(), changedIntent));

        // The target demand is now covered. Another three units are public stocking, not duplicate private supply.
        var appended = writer.submit(fixture.target().analysisId(), command(fixture, "3", true, true));
        var extra = appended.batches().getFirst();
        assertEquals(batch.planId(), extra.planId());
        qty("3", extra.publicExtraQty());
        qty("5", db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",
                BigDecimal.class, batch.planId()));
        qty("5", db.queryForObject("SELECT SUM(required_qty) FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",
                BigDecimal.class, batch.planId()));
        qty("2", db.queryForObject("SELECT submitted_qty FROM production_material_analysis_plan_links WHERE plan_id=?",
                BigDecimal.class, batch.planId()));
        qty("3", db.queryForObject("SELECT public_surplus_qty FROM production_material_analysis_plan_links WHERE plan_id=?",
                BigDecimal.class, batch.planId()));
        UUID newPublicItem = db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",
                UUID.class, batch.planId());
        qty("2", available(fixture.sourceItem()));
        qty("3", available(newPublicItem));
        qty("5", component(appended.analysis(), fixture).preparationSharedAvailableQty());
        assertEquals(0, claims(fixture));
        assertEquals(1, plans(fixture));
    }

    private Fixture fixture() {
        var source = support.create(true, false, "1");
        var supplied = writer.submit(source.analysis(), support.command(source,
                List.of(support.input(source, source.common(), "MAKE", "5", true))));
        UUID sourceItem = db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",
                UUID.class, supplied.batches().getFirst().planId());
        UUID root = UUID.randomUUID();
        support.fixture.insertGoods(root, "FQ-ROOT-" + root, "追加方式测试顶层", "自制",
                source.world().unitId(), source.world().unitLegacy());
        support.fixture.insertBom(root, source.common(), "1");
        var target = analyses.preview(new PreviewRequest(null, null, null, source.world().warehouseId(),
                "component-choice-" + root, List.of(new PreviewItem("OTHER", null, root, null,
                source.world().unitId(), "component-choice-source-" + root, "追加方式独立来源",
                BusinessTime.today().plusDays(10), new BigDecimal("2")))));
        target = analyses.saveRoutes(target.analysisId(), new RouteRequest(target.version(), target.fingerprint(),
                "component-choice-routes-" + target.analysisId(), target.flatMaterials().stream()
                .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                        row.goodsId().equals(source.material()) ? "BUY" : "MAKE", null)).toList()));
        Fixture fixture = new Fixture(source, sourceItem, target,
                target.flatMaterials().stream().filter(row -> row.goodsId().equals(source.common()))
                        .findFirst().orElseThrow().materialLineId());
        qty("2", available(sourceItem));
        assertEquals("BOM_COMPONENT", component(target, fixture).nodeRole());
        qty("0", component(target, fixture).sharedFutureClaimableQty());
        assertTrue(component(target, fixture).makePublicSupplyRefs().stream().anyMatch(candidate -> candidate.adoptable()));
        return fixture;
    }

    private AggregateMaterialOrderContracts.SubmitRequest command(Fixture fixture, String quantity,
            boolean extra, Boolean skipAutoClaim) {
        var current = analyses.detail(fixture.target().analysisId());
        var source = fixture.source();
        var group = new AggregateMaterialOrderContracts.GroupInput("make-component", List.of(fixture.componentId()),
                "MAKE", new BigDecimal(quantity), extra, source.workshop(), source.worker(), null, null,
                null, null, BigDecimal.ZERO, BigDecimal.ZERO);
        var request = new AggregateMaterialOrderContracts.PreviewRequest(current.version(), current.fingerprint(),
                "component-choice-submit-" + UUID.randomUUID(), source.world().warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true, List.of(group));
        var shown = preview.preview(current.analysisId(), request);
        assertNull(shown.groups().getFirst().blockedReason());
        return new AggregateMaterialOrderContracts.SubmitRequest(request.version(), request.fingerprint(),
                request.idempotencyKey(), request.warehouseId(), request.billDate(), request.deliveryDate(),
                request.approveNow(), request.groups(), shown.previewFingerprint(), skipAutoClaim);
    }

    private long claims(Fixture fixture) {
        return db.queryForObject("SELECT count(*) FROM preplan_make_public_claims WHERE target_analysis_id=?",
                Long.class, fixture.target().analysisId());
    }

    private long plans(Fixture fixture) {
        return db.queryForObject("SELECT count(*) FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted",
                Long.class, fixture.target().analysisId());
    }

    private BigDecimal available(UUID sourceItem) {
        return db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_make_public_supply_state WHERE source_plan_item_id=?",
                BigDecimal.class, sourceItem);
    }

    private static MaterialView component(AnalysisView view, Fixture fixture) {
        return view.flatMaterials().stream().filter(row -> row.materialLineId().equals(fixture.componentId()))
                .findFirst().orElseThrow();
    }

    private static void qty(String expected, BigDecimal actual) {
        assertEquals(0, new BigDecimal(expected).compareTo(actual), expected + " != " + actual);
    }

    private record Fixture(AggregateMaterialOrderEndToEndTest.Case source, UUID sourceItem,
                           AnalysisView target, UUID componentId) { }
}
