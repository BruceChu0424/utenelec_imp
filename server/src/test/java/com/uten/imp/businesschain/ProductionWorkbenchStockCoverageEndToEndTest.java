package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequestService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
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
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.assertThat;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.production.planning-urge-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionWorkbenchStockCoverageEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionDrawRequestService draws;
    @Autowired StockDocService stockDocuments;
    private FullChainEndToEndTest fixture;

    @BeforeEach void setup() { fixture = new FullChainEndToEndTest(); beans.autowireBean(fixture); }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test
    void stockedMakeBomComponentNeedsNoChildWorkOrderAndFinishedRootLeavesActiveWorkbench() {
        var world = fixture.seedWorld("workbench-stock-component");
        fixture.loginAs(world.superAdminUserId());
        UUID product = UUID.randomUUID(), component = UUID.randomUUID(), raw = UUID.randomUUID();
        fixture.insertGoods(product, "WB-STOCK-P-" + product, "足库存组件总装", "自制", world.unitId(), world.unitLegacy());
        fixture.insertGoods(component, "WB-STOCK-C-" + component, "库存已够自制子件", "自制", world.unitId(), world.unitLegacy());
        fixture.insertGoods(raw, "WB-STOCK-R-" + raw, "子件底层采购料", "采购", world.unitId(), world.unitLegacy());
        fixture.insertBom(product, component, "1");
        fixture.insertBom(component, raw, "1");
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES(?,?,10)", world.warehouseId(), component);
        AnalysisView view = analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(), "workbench-stock-preview-" + product,
                List.of(new PreviewItem("STOCK", null, product, null, world.unitId(), "workbench-stock-source-" + product,
                        "足库存组件无需重复自制", BusinessTime.today().plusDays(10), BigDecimal.TEN))));
        assertThat(view.flatMaterials().stream().filter(row -> row.goodsId().equals(component)).findFirst().orElseThrow().allocatedAvailableQty()).isEqualByComparingTo("10");

        Object assignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment", "workbench-stock-component");
        UUID workshop = (UUID) ReflectionTestUtils.getField(assignment, "workshopId");
        UUID worker = (UUID) ReflectionTestUtils.getField(assignment, "workerId");
        UUID analysis = view.analysisId();
        UUID plan = commands.issueWorkshopPlans(analysis, new IssueWorkshopPlansRequest(view.version(), view.fingerprint(),
                "workbench-stock-issue-" + product, world.warehouseId(), BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null, view.products().getFirst().analysisLineId(), BigDecimal.TEN,
                        BusinessTime.today(), BusinessTime.today().plusDays(10), workshop, null, worker, null, null)))).plans().getFirst().planId();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND NOT is_deleted", Integer.class, analysis)).isZero();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted", Integer.class, plan)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT remaining_demand_qty FROM v_production_execution_workbench_roots WHERE root_id=?", BigDecimal.class, analysis)).isZero();

        fixture.confirmFullKitRoutes(plan);
        UUID segment = db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted", UUID.class, plan);
        var drawItems = List.of(new ProductionDrawRequest.Item(segment, db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, segment)));
        var drawPreview = draws.preview(new ProductionDrawRequest.PreviewRequest(drawItems));
        draws.submit(new ProductionDrawRequest.SubmitRequest(drawItems, "workbench-stock-draw-" + product, drawPreview.fingerprint()));
        for (UUID draw : db.queryForList("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW'", UUID.class, segment)) {
            StockDocIssueRequest issue = ReflectionTestUtils.invokeMethod(fixture, "drawIssueRequest", draw, "workbench-stock-out-" + draw, null, BigDecimal.ZERO);
            stockDocuments.approveAndIssue(draw, issue);
        }
        UUID planItem = db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted", UUID.class, plan);
        ReflectionTestUtils.invokeMethod(fixture, "produceInternal", world, planItem, product, "10");
        fixture.loginAs(world.superAdminUserId());
        assertThat(db.queryForObject("SELECT fn_material_analysis_fulfillment_status(?)", String.class, analysis)).isEqualTo("COMPLETED");
        assertThat(db.queryForObject("SELECT COUNT(*) FROM v_production_execution_workbench_roots WHERE root_id=?", Integer.class, analysis)).isZero();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND NOT is_deleted", Integer.class, analysis)).isZero();
    }
}
