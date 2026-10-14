package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequestService;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
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
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired StockDocService stockDocuments;
    private FullChainEndToEndTest fixture;

    @BeforeEach void setup() { fixture = new FullChainEndToEndTest(); beans.autowireBean(fixture); }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test
    void netNestedChildQuotaSurvivesParentBatchConsumptionAndOnlyCountsItsOwnRemainder() {
        var world = fixture.seedWorld("workbench-net-child");
        fixture.loginAs(world.superAdminUserId());
        UUID product = UUID.randomUUID(), middle = UUID.randomUUID(), component = UUID.randomUUID(), raw = UUID.randomUUID();
        fixture.insertGoods(product, "WB-NET-P-" + product, "净缺口总装", "自制", world.unitId(), world.unitLegacy());
        fixture.insertGoods(middle, "WB-NET-B-" + middle, "可分批中间件", "自制", world.unitId(), world.unitLegacy());
        fixture.insertGoods(component, "WB-NET-C-" + component, "已有八件库存的子件", "自制", world.unitId(), world.unitLegacy());
        fixture.insertGoods(raw, "WB-NET-R-" + raw, "两件剩余子件的原料", "采购", world.unitId(), world.unitLegacy());
        fixture.insertBom(product, middle, "1");
        fixture.insertBom(middle, component, "1");
        fixture.insertBom(component, raw, "1");
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES(?,?,8)", world.warehouseId(), component);
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES(?,?,2)", world.warehouseId(), raw);
        AnalysisView view = analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(), "net-child-preview-" + product,
                List.of(new PreviewItem("STOCK", null, product, null, world.unitId(), "net-child-source-" + product,
                        "库存先净掉八件，子件仅负责两件", BusinessTime.today().plusDays(10), BigDecimal.TEN))));
        var middleMaterial = view.flatMaterials().stream().filter(row -> row.goodsId().equals(middle)).findFirst().orElseThrow();
        var componentMaterial = view.flatMaterials().stream().filter(row -> row.goodsId().equals(component)).findFirst().orElseThrow();
        assertThat(componentMaterial.demandSupplyGapQty()).isEqualByComparingTo("2");
        Object assignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment", "workbench-net-child");
        UUID workshop = (UUID) ReflectionTestUtils.getField(assignment, "workshopId");
        UUID worker = (UUID) ReflectionTestUtils.getField(assignment, "workerId");
        UUID analysis = view.analysisId();
        commands.issueWorkshopPlans(analysis, new IssueWorkshopPlansRequest(view.version(), view.fingerprint(),
                "net-child-issue-" + product, world.warehouseId(), BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(middleMaterial.materialLineId(), null, BigDecimal.TEN,
                                BusinessTime.today(), BusinessTime.today().plusDays(10), workshop, null, worker, null, null),
                        new IssueWorkshopPlansRequest.IssuePlanLine(componentMaterial.materialLineId(), null, new BigDecimal("2"),
                                BusinessTime.today(), BusinessTime.today().plusDays(10), workshop, null, worker, null, null))));
        UUID middleSource = db.queryForObject("SELECT id FROM production_material_analysis_items WHERE analysis_id=? AND parent_analysis_material_id=? AND source_type='MAKE_COMPONENT' AND NOT is_deleted", UUID.class, analysis, middleMaterial.materialLineId());
        UUID componentSource = db.queryForObject("SELECT id FROM production_material_analysis_items WHERE analysis_id=? AND parent_analysis_material_id=? AND source_type='MAKE_COMPONENT' AND NOT is_deleted", UUID.class, analysis, componentMaterial.materialLineId());
        assertThat(db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?", BigDecimal.class, componentSource)).isEqualByComparingTo("2");
        UUID middlePlan = db.queryForObject("SELECT id FROM production_plans WHERE material_analysis_item_id=? AND status=1 AND NOT is_deleted", UUID.class, middleSource);
        // The real complete-kit planner already partitions the parent into
        // an eight-piece ready batch and a two-piece waiting batch.
        assertThat(db.queryForObject("SELECT SUM(planned_qty) FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted AND status NOT IN ('CANCELLED','REVERSED')", BigDecimal.class, middlePlan)).isEqualByComparingTo("10");
        UUID readyBatch = db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND planned_qty=8 AND NOT is_deleted AND status NOT IN ('CANCELLED','REVERSED')", UUID.class, middlePlan);
        fixture.confirmFullKitRoute(middlePlan, readyBatch);
        var readyDrawItems = List.of(new ProductionDrawRequest.Item(readyBatch,
                db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, readyBatch)));
        var readyDrawPreview = draws.preview(new ProductionDrawRequest.PreviewRequest(readyDrawItems));
        draws.submit(new ProductionDrawRequest.SubmitRequest(readyDrawItems, "net-child-ready-draw-" + product, readyDrawPreview.fingerprint()));
        for (UUID draw : db.queryForList("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW'", UUID.class, readyBatch)) {
            StockDocIssueRequest issue = ReflectionTestUtils.invokeMethod(fixture, "drawIssueRequest", draw, "net-child-out-" + draw, null, BigDecimal.ZERO);
            stockDocuments.approveAndIssue(draw, issue);
        }
        assertComponentRemaining(componentSource, "2");
        segments.start(middlePlan, readyBatch, new SegmentTransitionRequest(
                db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, readyBatch),
                "net-child-start-" + product));
        UUID middlePlanItem = db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?", UUID.class, readyBatch);
        UUID report = ReflectionTestUtils.invokeMethod(fixture, "reportAndApproveExecutionSegment", world, middlePlanItem, null, middle, readyBatch, null, "8");
        UUID inbound = ReflectionTestUtils.invokeMethod(fixture, "finishedInDocForReport", report);
        ReflectionTestUtils.invokeMethod(fixture, "confirmFinishedInboundFully", inbound);
        fixture.loginAs(world.superAdminUserId());
        assertThat(db.queryForObject("SELECT required_qty FROM production_material_analysis_materials WHERE id=?", BigDecimal.class, componentMaterial.materialLineId())).isEqualByComparingTo("2");
        assertThat(db.queryForObject("SELECT SUM(required_qty-released_qty) FROM production_material_demands WHERE plan_id=? AND goods_id=? AND NOT is_deleted AND status NOT IN ('RELEASED','REVERSED')", BigDecimal.class, middlePlan, component)).isEqualByComparingTo("10");
        assertComponentRemaining(componentSource, "2");

        UUID componentPlan = db.queryForObject("SELECT id FROM production_plans WHERE material_analysis_item_id=? AND status=1 AND NOT is_deleted", UUID.class, componentSource);
        fixture.confirmFullKitRoutes(componentPlan);
        UUID componentSegment = db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted", UUID.class, componentPlan);
        var drawItems = List.of(new ProductionDrawRequest.Item(componentSegment, db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, componentSegment)));
        var drawPreview = draws.preview(new ProductionDrawRequest.PreviewRequest(drawItems));
        draws.submit(new ProductionDrawRequest.SubmitRequest(drawItems, "net-child-draw-" + product, drawPreview.fingerprint()));
        for (UUID draw : db.queryForList("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW'", UUID.class, componentSegment)) {
            StockDocIssueRequest issue = ReflectionTestUtils.invokeMethod(fixture, "drawIssueRequest", draw, "net-child-raw-out-" + draw, null, BigDecimal.ZERO);
            stockDocuments.approveAndIssue(draw, issue);
        }
        UUID componentPlanItem = db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted", UUID.class, componentPlan);
        ReflectionTestUtils.invokeMethod(fixture, "produceInternal", world, componentPlanItem, component, "2");
        fixture.loginAs(world.superAdminUserId());
        assertComponentRemaining(componentSource, "0");
        assertThat(db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?", BigDecimal.class, componentSource)).isEqualByComparingTo("2");
    }

    private void assertComponentRemaining(UUID source, String quantity) {
        assertThat(db.queryForObject("SELECT remaining_fulfillment_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, source)).isEqualByComparingTo(quantity);
    }

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
