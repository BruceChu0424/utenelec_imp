package com.uten.imp.businesschain;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.ProductionMutationFootprintService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.util.AopTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/** The preview's complete prelock is reused only before source writes. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
class MaterialAnalysisPreviewPrelockPostgresTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate jdbc;
    @Autowired MaterialAnalysisService analysis;
    @Autowired SalesOrderService sales;
    @Autowired SalesOrderFinanceConfirmService finance;
    @MockitoSpyBean ProductionMutationFootprintService footprints;
    private ProductionChainDataFactory factory;

    @BeforeEach void setup() { factory = new ProductionChainDataFactory(beans, jdbc, sales, finance); }
    @AfterEach void clearActor() { SecurityContextHolder.clearContext(); }

    @Test
    void changedQuantityRetainsStableNodesAndRevalidatesTheGraphAfterSourceWrites() {
        var scenario = factory.sharedTree("preview-reuse-" + suffix(), 2);
        AnalysisView before = analysis.preview(request(scenario, null, scenario.sources()));
        List<PreviewItem> reduced = withQuantity(scenario.sources(), new BigDecimal("5"));
        clearInvocations(target());

        AnalysisView after = analysis.preview(request(scenario, before, reduced));

        assertTrue(after.version() > before.version());
        assertEquals(2, after.products().size());
        assertEquals(before.flatMaterials().stream().map(MaterialView::materialLineId).collect(java.util.stream.Collectors.toSet()),
                after.flatMaterials().stream().map(MaterialView::materialLineId).collect(java.util.stream.Collectors.toSet()));
        assertTrue(after.products().stream().allMatch(row -> row.requestedQty().compareTo(new BigDecimal("5")) == 0));
        assertTrue(after.flatMaterials().stream().filter(row -> row.level() == 0)
                .allMatch(row -> row.requiredQty().compareTo(new BigDecimal("5")) == 0));
        verify(target(), times(2)).forPreview(any(), any(), any(), any(), any());
        // refreshLocked retains its own discovery and post-lock revalidation.
        verify(target(), times(2)).forAnalyses(List.of(before.analysisId()));
        assertEquals(0, jdbc.queryForObject("select count(*) from production_plans where material_analysis_id=?",
                Integer.class, before.analysisId()));
    }

    @Test
    void missingAnalysisCoverageIsRejectedBeforeAnySourceQuantityWrite() {
        var scenario = factory.sharedTree("preview-cover-" + suffix(), 2);
        AnalysisView before = analysis.preview(request(scenario, null, scenario.sources()));
        doAnswer(invocation -> {
            FulfillmentMutationLockPlan plan = (FulfillmentMutationLockPlan) invocation.callRealMethod();
            return new FulfillmentMutationLockPlan(plan.commercialSources(), plan.inventoryDimensions(),
                    plan.mainWarehouseIds(), Set.of(), plan.fingerprint());
        }).when(target()).forPreview(any(), any(), any(), any(), any());

        ApiException error = assertThrows(ApiException.class, () -> analysis.preview(request(scenario, before,
                withQuantity(scenario.sources(), new BigDecimal("5")))));
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        AnalysisView after = analysis.detail(before.analysisId());
        assertEquals(before.version(), after.version());
        assertEquals(before.fingerprint(), after.fingerprint());
        assertTrue(after.products().stream().allMatch(row -> row.requestedQty().compareTo(BigDecimal.TEN) == 0));
    }

    @Test
    void staleVersionDoesNotProceedToSourceWritesOrTheRefreshPhase() {
        var scenario = factory.sharedTree("preview-cas-" + suffix(), 2);
        AnalysisView before = analysis.preview(request(scenario, null, scenario.sources()));
        clearInvocations(target());
        PreviewRequest stale = new PreviewRequest(before.analysisId(), before.version() - 1, before.fingerprint(),
                scenario.world().warehouseId(), "stale-" + suffix(),
                withQuantity(scenario.sources(), new BigDecimal("5")));

        assertThrows(ApiException.class, () -> analysis.preview(stale));

        verify(target(), never()).forAnalyses(List.of(before.analysisId()));
        AnalysisView after = analysis.detail(before.analysisId());
        assertEquals(before.version(), after.version());
        assertTrue(after.products().stream().allMatch(row -> row.requestedQty().compareTo(BigDecimal.TEN) == 0));
    }

    private ProductionMutationFootprintService target() { return AopTestUtils.getUltimateTargetObject(footprints); }
    private static String suffix() { return UUID.randomUUID().toString().substring(0, 8); }
    private static PreviewRequest request(ProductionChainDataFactory.Scenario scenario, AnalysisView previous,
                                          List<PreviewItem> sources) {
        return new PreviewRequest(previous == null ? null : previous.analysisId(),
                previous == null ? null : previous.version(), previous == null ? null : previous.fingerprint(),
                scenario.world().warehouseId(), "preview-prelock-" + suffix(), sources);
    }
    private static List<PreviewItem> withQuantity(List<PreviewItem> sources, BigDecimal quantity) {
        return sources.stream().map(row -> new PreviewItem(row.sourceType(), row.salesOrderItemId(), row.goodsId(),
                row.colorId(), row.unitId(), row.sourceRef(), row.sourceReason(), row.deliveryDate(), quantity)).toList();
    }
}
