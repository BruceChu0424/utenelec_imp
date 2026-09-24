package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.plan.ProductionPlanService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Real node-to-anchor projection and source-quota protection for workshop batch commands.
 *
 * <p>2026-09-10（C05 F1-flow）追加：混合候选一次下达、二次下达复用锚点、两线程不同候选行、
 * 超量行整批回滚——覆盖 batchChildLineIds 的 IN 批量映射与 refresh 收敛后的不变量。
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>：本类（与 FullChain/Scale 同款门控）
 * 未设置时全部 SKIP，surefire 仍 exit 0，会出现「全绿但没跑」的假象（09-09 的 min(uuid)
 * 回归正是这样漏到运行态的）。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialWorkshopAnchorEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionPlanService plans;
    @Autowired com.uten.imp.features.production.execution.ProductionExecutionSegmentService segments;
    @Autowired com.uten.imp.features.sales.order.SalesOrderService sales;
    @Autowired com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService finance;
    @Autowired com.uten.imp.features.common.taskclaim.TaskClaimService claims;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    @Autowired com.uten.imp.features.stock.StockDocService stockDocuments;
    @Autowired com.uten.imp.features.master.goods.GoodsBomService goodsBom;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}

    @Test void unchangedRefreshPreservesBomRowsButStillRecomputesCurrentStockAndVersion() {
        Case c = create("incremental-snapshot", false);
        AnalysisView before = analyses.detail(c.analysis());
        Map<UUID, String> originalRows = materialRowVersions(c);

        AnalysisView unchanged = refreshCase(c, "unchanged");

        assertEquals(before.version() + 1, unchanged.version());
        assertEquals(originalRows, materialRowVersions(c), "Unchanged BOM nodes must not toggle active or reset allocation");
        postGenericStock(c, c.world().goodsC(), "4000", "OTHER_IN");
        fixture.loginAs(c.planner());
        AnalysisView changed = refreshCase(c, "new-stock");
        qty("4000", material(changed, c.materials().getFirst()).allocatedAvailableQty());
        qty("6000", material(changed, c.materials().getFirst()).demandSupplyGapQty());
        assertNotEquals(originalRows.get(c.materials().getFirst()), materialRowVersions(c).get(c.materials().getFirst()));
        Map<UUID, String> updatedRows = materialRowVersions(c);
        refreshCase(c, "stable-stock");
        assertEquals(updatedRows, materialRowVersions(c), "Existing nonzero allocation must remain untouched when its inputs did not change");
    }

    @Test void removingABomEdgeOnlyDeactivatesThatHistoricalNode() {
        Case c = create("incremental-bom-delete", false);
        Map<UUID, String> before = materialRowVersions(c);
        UUID removedMaterial = c.materials().getFirst();
        UUID edge = db.queryForObject("SELECT id FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND is_deleted=FALSE",
                UUID.class, c.root(), c.world().goodsC());
        fixture.loginAs(c.world().superAdminUserId());
        goodsBom.delete(c.root(), edge);
        fixture.loginAs(c.planner());

        AnalysisView refreshed = refreshCase(c, "removed-edge");

        assertFalse(db.queryForObject("SELECT active FROM production_material_analysis_materials WHERE id=?", Boolean.class, removedMaterial));
        assertTrue(refreshed.flatMaterials().stream().noneMatch(row -> row.materialLineId().equals(removedMaterial)));
        var after = materialRowVersions(c);
        for (var row : before.entrySet()) if (!row.getKey().equals(removedMaterial)) assertEquals(row.getValue(), after.get(row.getKey()));
    }

    @Test void reactivatedChangedBomStillClearsAndCountsItsHistoricalConfirmation() {
        Case c = create("snapshot-reactivate", false);
        UUID material = c.materials().getFirst();
        UUID edge = db.queryForObject("SELECT id FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",
                UUID.class, c.root(), c.world().goodsC());
        fixture.loginAs(c.world().superAdminUserId()); goodsBom.delete(c.root(), edge);
        fixture.loginAs(c.planner()); refreshCase(c, "deactivate");
        assertEquals(false, db.queryForObject("SELECT active FROM production_material_analysis_materials WHERE id=?", Boolean.class, material));
        // An administrative correction restores the same historical BOM identity.
        db.update("UPDATE goods_bom_items SET is_deleted=FALSE,deleted_at=NULL,qty=2 WHERE id=?", edge);
        var restored = refreshCase(c, "restore-changed-edge");
        assertEquals(1, restored.routeResetCount());
        assertEquals(null, material(restored, material).sourceConfirmed());
        qty("20000", material(restored, material).requiredQty());
    }

    private Map<UUID, String> materialRowVersions(Case c) {
        Map<UUID, String> result = new LinkedHashMap<>();
        db.query("SELECT id,xmin::text FROM production_material_analysis_materials WHERE analysis_id=? AND node_role='BOM_COMPONENT' ORDER BY id",
                rs -> { result.put(rs.getObject(1, UUID.class), rs.getString(2)); }, c.analysis());
        return result;
    }

    private AnalysisView refreshCase(Case c, String key) {
        AnalysisView view = analyses.detail(c.analysis());
        ProductView source = view.products().stream().filter(row -> row.sourceType().equals("OTHER")).findFirst().orElseThrow();
        return analyses.preview(new PreviewRequest(c.analysis(), view.version(), view.fingerprint(), c.world().warehouseId(),
                key + "-" + c.analysis(), List.of(new PreviewItem("OTHER", null, c.root(), null, c.world().unitId(),
                c.sourceRef(), source.sourceReason(), source.deliveryDate(), source.requestedQty()))));
    }

    @Test void genericStockIncreaseReducesNewChildQuotaWithoutARefreshOnPageEntry() {
        Case c = create("anchor-live-stock-in", false);
        AnalysisView stale = analyses.detail(c.analysis());
        postGenericStock(c, c.world().goodsC(), "4000", "OTHER_IN");
        fixture.loginAs(c.planner());
        assertEquals(stale.version(), analyses.detail(c.analysis()).version(), "Generic stock posting does not silently rewrite the analysis");

        var result = commands.issueWorkshopPlans(c.analysis(), request(c, stale, c.materials().getFirst(), "6000", "live-stock", true));

        UUID anchor = material(result.analysis(), c.materials().getFirst()).planAnchorAnalysisLineId();
        qty("6000", product(result.analysis(), anchor).requestedQty());
        assertQuotaAndPlans(c, anchor, "6000", 1);
    }

    @Test void genericStockCoveringTheWholeCandidateRejectsStaleIssueWithoutCreatingAnAnchor() {
        Case c = create("anchor-stock-covered", false);
        AnalysisView stale = analyses.detail(c.analysis());
        postGenericStock(c, c.world().goodsC(), "10000", "OTHER_IN");
        fixture.loginAs(c.planner());

        ApiException rejected = assertThrows(ApiException.class, () -> commands.issueWorkshopPlans(
                c.analysis(), request(c, stale, c.materials().getFirst(), "10000", "covered", true)));

        assertTrue(rejected.getMessage().contains("刷新"));
        assertEquals(0, count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?", c.analysis()));
        assertEquals(0, count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT'", c.analysis()));
    }

    @Test void stockDecreaseBlocksContinuousOutputAndReplayDoesNotDuplicatePreparation() {
        Case c = create("anchor-live-stock-out", false);
        postGenericStock(c, c.world().goodsC(), "10000", "OTHER_IN");
        postGenericStock(c, c.world().goodsD(), "10000", "OTHER_IN");
        fixture.loginAs(c.planner());
        AnalysisView before = analyses.detail(c.analysis());
        AnalysisView ready = analyses.preview(new PreviewRequest(c.analysis(), before.version(), before.fingerprint(),
                c.world().warehouseId(), "stock-ready-" + c.analysis(), List.of(new PreviewItem("OTHER", null,
                c.root(), null, c.world().unitId(), c.sourceRef(), "实际入库后刷新", BusinessTime.today().plusDays(10), new BigDecimal("10000")))));
        qty("10000", ready.products().getFirst().readyFinishQty());
        postGenericStock(c, c.world().goodsD(), "10000", "OTHER_OUT");
        fixture.loginAs(c.planner());
        Object assignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment", "stock-out-" + c.analysis());
        UUID workshop = ReflectionTestUtils.invokeMethod(assignment, "workshopId");
        UUID workerUser = fixture.createUserWithPerms(c.world(), "stock-out-worker-" + c.analysis(),
                "production_execution:view", "production_execution:start");
        UUID worker = db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, workerUser);
        db.update("UPDATE employees SET department_id=? WHERE id=?", workshop, worker);
        var request = new IssueWorkshopPlansRequest(ready.version(), ready.fingerprint(), "stock-out-" + c.analysis(),
                c.world().warehouseId(), BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null, ready.products().getFirst().analysisLineId(),
                        new BigDecimal("10000"), null, null, workshop, null, worker, null, null)));

        var result = commands.issueWorkshopPlans(c.analysis(), request);
        UUID plan = result.plans().getFirst().planId();
        Map<String, String> firstPreparation = workshopPreparationFacts(c.analysis(), plan);
        var replay = commands.issueWorkshopPlans(c.analysis(), request);
        assertTrue(replay.replayed());
        assertEquals(plan, replay.plans().getFirst().planId());
        assertEquals(firstPreparation, workshopPreparationFacts(c.analysis(), plan),
                "Idempotent retry must not recreate plans, demands, reservations, supply pegs or DRAW documents");
        fixture.loginAs(c.world().superAdminUserId());
        var segment = segments.list(plan).getFirst();
        assertEquals("CONTINUOUS", segment.startRoute());
        assertEquals(workshop, segment.workshopDepartmentId());
        assertEquals(worker, segment.responsibleEmployeeId());
        // Continuous preparation can reserve the C that really remains. READY
        // does not assert that all required materials jointly support production.
        assertEquals("READY", segment.status());
        assertFalse(segment.materialReady());
        assertFalse(segment.canStart());
        assertEquals(1, segment.shortageKindCount());
        assertEquals(2, segment.materialDemandCount());
        for (UUID materialId : List.of(c.world().goodsC(), c.world().goodsD())) {
            qty("10000", db.queryForObject("""
                    SELECT required_qty FROM production_material_demands
                    WHERE plan_id=? AND goods_id=? AND NOT is_deleted
                    """, BigDecimal.class, plan, materialId));
            qty(materialId.equals(c.world().goodsC()) ? "10000" : "0", db.queryForObject("""
                    SELECT COALESCE(SUM(r.qty-r.released_qty),0) FROM stock_reservations r
                    JOIN production_material_demands d ON d.id=r.demand_id
                    WHERE d.plan_id=? AND d.goods_id=? AND NOT r.is_deleted
                    """, BigDecimal.class, plan, materialId));
        }
        qty("0", db.queryForObject("""
                SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL
                """, BigDecimal.class, c.world().warehouseId(), c.world().goodsD()));
        assertEquals(0, db.queryForObject("""
                SELECT COUNT(*) FROM production_material_supply_pegs peg
                JOIN production_material_demands demand ON demand.id=peg.demand_id
                WHERE demand.plan_id=? AND demand.goods_id=? AND peg.status<>'REVERSED'
                """, Integer.class, plan, c.world().goodsD()));
        qty("0", db.queryForObject("SELECT fn_execution_material_output_capacity(?,FALSE)", BigDecimal.class, segment.id()));
        qty("0", db.queryForObject("SELECT fn_execution_material_output_capacity(?,TRUE)", BigDecimal.class, segment.id()));
        var drawLines = db.queryForList("""
                SELECT doc.id,item.goods_id,item.base_qty
                FROM plan_draw_links link JOIN stock_documents doc ON doc.id=link.draw_id AND NOT doc.is_deleted
                JOIN stock_document_items item ON item.doc_id=doc.id AND NOT item.is_deleted
                WHERE link.plan_id=? AND NOT link.is_deleted
                """, plan);
        assertEquals(1, drawLines.size());
        assertEquals(c.world().goodsC(), drawLines.getFirst().get("goods_id"));
        qty("10000", (BigDecimal) drawLines.getFirst().get("base_qty"));

        // The assigned workshop member really requests C and the warehouse
        // issues it. Missing D must still block output, independently of actor
        // assignment and the distinction between a reservation and an issue.
        fixture.loginAs(workerUser);
        var drawRequests = beans.getBean(com.uten.imp.features.production.execution.ProductionDrawRequestService.class);
        var drawItems = List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(segment.id(), segment.lockVersion()));
        var drawPreview = drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(drawItems));
        drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(
                drawItems, "stock-out-request-" + plan, drawPreview.fingerprint()));
        UUID drawId = (UUID) drawLines.getFirst().get("id");
        fixture.loginAs(c.world().superAdminUserId());
        com.uten.imp.features.stock.dto.StockDocIssueRequest issueRequest = ReflectionTestUtils.invokeMethod(
                fixture, "drawIssueRequest", drawId, "stock-out-issue-" + plan, null, BigDecimal.ZERO);
        stockDocuments.approveAndIssue(drawId, issueRequest);
        for (UUID materialId : List.of(c.world().goodsC(), c.world().goodsD())) {
            qty(materialId.equals(c.world().goodsC()) ? "10000" : "0", db.queryForObject("""
                    SELECT fn_execution_material_net_issued_qty(id) FROM production_material_demands
                    WHERE plan_id=? AND goods_id=? AND NOT is_deleted
                    """, BigDecimal.class, plan, materialId));
        }
        qty("0", db.queryForObject("SELECT fn_execution_material_output_capacity(?,TRUE)", BigDecimal.class, segment.id()));
        var afterIssue = segments.list(plan).getFirst();
        assertFalse(afterIssue.canStart());
        Map<String, String> issuedFacts = workshopPreparationFacts(c.analysis(), plan);
        fixture.loginAs(workerUser);
        ApiException blocked = assertThrows(ApiException.class, () -> segments.start(plan, segment.id(),
                new com.uten.imp.features.production.execution.SegmentTransitionRequest(afterIssue.lockVersion(), "stock-out-start-" + plan)));
        assertTrue(blocked.getMessage().contains("全部必需物料须共同支持正产出"), blocked.getMessage());
        assertEquals(issuedFacts, workshopPreparationFacts(c.analysis(), plan));
        assertEquals(0, count("SELECT COUNT(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='START'", segment.id()));
        assertEquals(0, count("SELECT COUNT(*) FROM production_daily_report_items WHERE execution_segment_id=? AND NOT is_deleted", segment.id()));
    }

    private Map<String, String> workshopPreparationFacts(UUID analysis, UUID plan) {
        Map<String, String> facts = frozenPlans(analysis);
        String demands = "demand_id IN (SELECT id FROM production_material_demands WHERE plan_id=?)";
        facts.put("reservations", rows("stock_reservations", demands, plan));
        facts.put("supply-pegs", rows("production_material_supply_pegs", demands, plan));
        facts.put("draw-links", rows("plan_draw_links", "plan_id=?", plan));
        facts.put("draw-documents", rows("stock_documents", "id IN (SELECT draw_id FROM plan_draw_links WHERE plan_id=?)", plan));
        facts.put("draw-items", rows("stock_document_items", "doc_id IN (SELECT draw_id FROM plan_draw_links WHERE plan_id=?)", plan));
        return facts;
    }

    @Test void stockCoverageUsesActualSiblingLeafAndExcludesAnotherMainWarehouse() {
        Case c = create("anchor-leaf-coverage", false);
        UUID leaf = UUID.randomUUID();
        UUID unrelated = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,parent_id,is_accountable) VALUES (?,?,?, ?,TRUE)",
                leaf, "LEAF-" + leaf, "实际入库分仓", c.world().warehouseId());
        db.update("INSERT INTO warehouses(id,code,name,is_accountable) VALUES (?,?,?,TRUE)",
                unrelated, "OTHER-" + unrelated, "其它主仓库存");
        postGenericStock(c, c.world().goodsC(), "4000", "OTHER_IN", leaf);
        postGenericStock(c, c.world().goodsC(), "10000", "OTHER_IN", unrelated);
        fixture.loginAs(c.planner());
        AnalysisView stale = analyses.detail(c.analysis());

        var result = commands.issueWorkshopPlans(c.analysis(), request(c, stale,
                c.materials().getFirst(), "6000", "leaf-current", true));

        UUID anchor = material(result.analysis(), c.materials().getFirst()).planAnchorAnalysisLineId();
        qty("6000", product(result.analysis(), anchor).requestedQty());
        qty("4000", db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                BigDecimal.class, leaf, c.world().goodsC()));
        qty("10000", db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                BigDecimal.class, unrelated, c.world().goodsC()));
    }

    @Test void twoParentPathsKeepTheirPartialFormalCoverageOnTheirOwnOriginalNodes() {
        Case c = create("anchor-formal-paths", true);
        postGenericStock(c, c.world().goodsC(), "6000", "OTHER_IN");
        fixture.loginAs(c.planner());
        var parents = analyses.detail(c.analysis()).flatMaterials().stream()
                .filter(row -> row.level() == 1 && "MAKE".equals(row.sourceConfirmed()))
                .map(MaterialView::materialLineId).toList();
        assertEquals(2, parents.size());
        for (UUID parent : parents) {
            var result = issue(c, parent, "3000", "partial-" + parent, true);
            UUID planId = result.plans().getFirst().planId();
            UUID segmentId = db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=?", UUID.class, planId);
            fixture.loginAs(c.world().superAdminUserId());
            segments.confirmRoute(planId, segmentId,
                    new com.uten.imp.features.production.execution.SegmentRouteConfirmRequest(
                            db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, segmentId),
                            "formal-path-route-" + segmentId, "FULL_KIT"));
            fixture.loginAs(c.planner());
        }

        var view = refreshCase(c, "formal-path-route-selected");
        for (UUID materialId : c.materials()) {
            qty("3000", material(view, materialId).allocatedAvailableQty());
            qty("7000", material(view, materialId).demandSupplyGapQty());
            qty("0", material(view, materialId).externalFutureCoverageQty());
        }
        qty("6000", c.materials().stream().map(id -> material(view, id).allocatedAvailableQty())
                .reduce(BigDecimal.ZERO, BigDecimal::add));
        assertEquals(2, count("SELECT count(*) FROM production_material_demands demand JOIN production_plans plan ON plan.id=demand.plan_id "
                + "WHERE plan.material_analysis_id=? AND demand.required_qty=3000 AND demand.is_deleted=FALSE", c.analysis()));
    }

    @Test void mixedGoodsRoutesRemainIndependentAndDoNotLearnARequestOrderDependentDefault() {
        Case c = create("routes-mixed", true);
        var before = analyses.detail(c.analysis());
        long goodsVersion = db.queryForObject("SELECT version FROM goods WHERE id=?", Long.class, c.world().goodsC());
        var choices = List.of(new RouteDecision(c.materials().get(0), null, "BUY", "外购物料路径"),
                new RouteDecision(c.materials().get(1), null, "MAKE", "车间自制路径"));
        var changed = analyses.saveRoutes(c.analysis(), new RouteRequest(before.version(), before.fingerprint(),
                "route-mixed-" + c.analysis(), choices));
        assertEquals("BUY", material(changed, c.materials().get(0)).sourceConfirmed());
        assertEquals("MAKE", material(changed, c.materials().get(1)).sourceConfirmed());
        assertEquals("自制", db.queryForObject("SELECT source_type FROM goods WHERE id=?", String.class, c.world().goodsC()));
        assertEquals(goodsVersion, db.queryForObject("SELECT version FROM goods WHERE id=?", Long.class, c.world().goodsC()));
        var routeFacts = db.queryForList("SELECT id,confirmed_route,route_reason,route_confirmed_by,route_confirmed_at FROM production_material_analysis_materials WHERE analysis_id=? ORDER BY id", c.analysis());
        var reversed = new ArrayList<>(choices); java.util.Collections.reverse(reversed);
        var repeated = analyses.saveRoutes(c.analysis(), new RouteRequest(changed.version(), changed.fingerprint(),
                "route-mixed-reverse-" + c.analysis(), reversed));
        assertEquals(routeFacts, db.queryForList("SELECT id,confirmed_route,route_reason,route_confirmed_by,route_confirmed_at FROM production_material_analysis_materials WHERE analysis_id=? ORDER BY id", c.analysis()),
                "Equal confirmations must not rewrite their actor or time when request order changes");
        assertEquals("BUY", material(repeated, c.materials().get(0)).sourceConfirmed());
        assertEquals("MAKE", material(repeated, c.materials().get(1)).sourceConfirmed());
        var uniform = choices.stream().map(choice -> new RouteDecision(choice.materialLineId(), null, "BUY", null)).toList();
        var learned = analyses.saveRoutes(c.analysis(), new RouteRequest(repeated.version(), repeated.fingerprint(),
                "route-uniform-" + c.analysis(), uniform));
        assertEquals("采购", db.queryForObject("SELECT source_type FROM goods WHERE id=?", String.class, c.world().goodsC()));
        assertEquals(goodsVersion + 1, db.queryForObject("SELECT version FROM goods WHERE id=?", Long.class, c.world().goodsC()));
        for (UUID id : c.materials()) assertEquals("BUY", material(learned, id).sourceConfirmed());
    }

    @Test void routeBatchRejectsDuplicateInvalidForeignAndCommittedChangesWithoutPartialWrites() {
        Case c = create("routes-atomic", true);
        var initial = analyses.detail(c.analysis());
        var good = new RouteDecision(c.materials().get(0), null, "BUY", null);
        var original = db.queryForList("SELECT id,confirmed_route,route_reason,route_confirmed_at FROM production_material_analysis_materials WHERE analysis_id=? ORDER BY id", c.analysis());
        for (var choices : List.of(List.of(good, good),
                List.of(good, new RouteDecision(c.materials().get(1), null, "INVALID", null)),
                List.of(good, new RouteDecision(UUID.randomUUID(), null, "MAKE", null)))) {
            assertThrows(ApiException.class, () -> analyses.saveRoutes(c.analysis(), new RouteRequest(initial.version(),
                    initial.fingerprint(), "bad-route-" + UUID.randomUUID(), choices)));
            assertEquals(original, db.queryForList("SELECT id,confirmed_route,route_reason,route_confirmed_at FROM production_material_analysis_materials WHERE analysis_id=? ORDER BY id", c.analysis()));
            assertEquals(initial.version(), analyses.detail(c.analysis()).version());
            assertEquals("自制", db.queryForObject("SELECT source_type FROM goods WHERE id=?", String.class, c.world().goodsC()));
        }
        var buyer = analyses.saveRoutes(c.analysis(), new RouteRequest(initial.version(), initial.fingerprint(),
                "route-buy-" + c.analysis(), List.of(good)));
        var supplied = commands.notifySupply(c.analysis(), new NotifyRequest(buyer.version(), buyer.fingerprint(),
                "route-committed-" + c.analysis(), "BUY", List.of(good.materialLineId()), null, null));
        var facts = db.queryForList("SELECT id,confirmed_route,route_reason,route_confirmed_at FROM production_material_analysis_materials WHERE analysis_id=? ORDER BY id", c.analysis());
        var incompatible = List.of(new RouteDecision(c.materials().get(1), null, "SUBCONTRACT", null),
                new RouteDecision(c.materials().get(0), null, "MAKE", null));
        assertThrows(ApiException.class, () -> analyses.saveRoutes(c.analysis(), new RouteRequest(supplied.version(),
                supplied.fingerprint(), "route-conflict-" + c.analysis(), incompatible)));
        assertEquals(facts, db.queryForList("SELECT id,confirmed_route,route_reason,route_confirmed_at FROM production_material_analysis_materials WHERE analysis_id=? ORDER BY id", c.analysis()));
        assertEquals("采购", db.queryForObject("SELECT source_type FROM goods WHERE id=?", String.class, c.world().goodsC()));
    }

    @Test void concurrentRouteBatchesRejectTheStaleVersionAndLearnGoodsExactlyOnce() throws Exception {
        Case c = create("routes-concurrent", true);
        var initial = analyses.detail(c.analysis());
        long goodsVersion = db.queryForObject("SELECT version FROM goods WHERE id=?", Long.class, c.world().goodsC());
        var choices = c.materials().stream().map(id -> new RouteDecision(id, null, "BUY", null)).toList();
        var workers = Executors.newFixedThreadPool(2);
        CountDownLatch start = new CountDownLatch(1);
        try {
            var jobs = java.util.stream.IntStream.range(0, 2).mapToObj(index -> workers.submit(() -> {
                fixture.loginAs(c.planner());
                try {
                    assertTrue(start.await(30, TimeUnit.SECONDS));
                    return analyses.saveRoutes(c.analysis(), new RouteRequest(initial.version(), initial.fingerprint(),
                            "concurrent-route-" + c.analysis() + "-" + index, choices));
                } finally { SecurityContextHolder.clearContext(); }
            })).toList();
            start.countDown();
            int succeeded = 0, conflicted = 0;
            for (var job : jobs) {
                try { job.get(120, TimeUnit.SECONDS); succeeded++; }
                catch (java.util.concurrent.ExecutionException failure) {
                    assertInstanceOf(ApiException.class, failure.getCause()); conflicted++;
                }
            }
            assertEquals(1, succeeded); assertEquals(1, conflicted);
        } finally { workers.shutdownNow(); }
        fixture.loginAs(c.planner());
        assertEquals(goodsVersion + 1, db.queryForObject("SELECT version FROM goods WHERE id=?", Long.class, c.world().goodsC()));
        for (UUID id : c.materials()) assertEquals("BUY", material(analyses.detail(c.analysis()), id).sourceConfirmed());
    }

    private void postGenericStock(Case c, UUID goods, String quantity, String type) {
        postGenericStock(c, goods, quantity, type, c.world().warehouseId());
    }

    private void postGenericStock(Case c, UUID goods, String quantity, String type, UUID warehouse) {
        fixture.loginAs(c.world().superAdminUserId());
        var request = new com.uten.imp.features.stock.dto.StockDocSaveRequest();
        request.setDocType(type); request.setWarehouseId(warehouse); request.setBillDate(BusinessTime.today());
        var item = new com.uten.imp.features.stock.dto.StockDocItemLine();
        item.setGoodsId(goods); item.setUnitId(c.world().unitId()); item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(quantity)); item.setPrice(BigDecimal.TEN);
        item.setAmountOriginal(item.getQty().multiply(item.getPrice())); item.setAmountLocal(item.getAmountOriginal());
        request.setItems(List.of(item)); stockDocuments.approve(stockDocuments.create(request).getId());
    }

    @Test void repeatedMaterialLineReusesQuotaAnd6000Then4000AreTwoDeltasNotCumulativeTotals(){
        Case c=create("anchor-partial",false);
        UUID material=c.materials().getFirst();
        issue(c,material,"6000","first",true);
        AnalysisView first=analyses.detail(c.analysis());UUID anchor=material(first,material).planAnchorAnalysisLineId();
        assertNotNull(anchor);assertEquals("MAKE_COMPONENT",product(first,anchor).sourceType());
        qty("10000",product(first,anchor).requestedQty());qty("6000",product(first,anchor).approvedQty());
        qty("4000",product(first,anchor).remainingQty());qty("10000",material(first,material).requiredQty());
        assertNull(material(first,material).delegatedToAnalysisLineId());
        assertEquals("ACTIVE",material(first,material).requirementState());
        assertEquals(0,count("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route='MAKE'",c.analysis()));

        // 增量口径仍然成立：剩余 4000 时误填累计量 10000，**锚点 requested_qty 不会被抬成
        // 16000**——4000 归本需求、6000 记公共备货产出（V577）。超量本身自 2026-09-14 起合法
        // （用户口径：生产可超量下达，超出部分是公共的），前端提交前会逐行点名二次确认。
        AnalysisView current=analyses.detail(c.analysis());
        var request=request(c,current,material,"4000","second",true);
        var second=commands.issueWorkshopPlans(c.analysis(),request);
        var replay=commands.issueWorkshopPlans(c.analysis(),request);
        assertTrue(replay.replayed());assertEquals(second.plans().getFirst().planId(),replay.plans().getFirst().planId());
        // ADR-104：第一张已审核但没开工, 第二批并进同一张(6000→10000 归需求 + 6000 公共), 全分析仍一张计划。
        assertTrue(second.plans().getFirst().mergedIntoExisting());assertTrue(replay.plans().getFirst().mergedIntoExisting());
        assertQuotaAndPlans(c,anchor,"10000",1);
        qty("0",product(analyses.detail(c.analysis()),anchor).remainingQty());
        // 需求全部转计划后该行不再可排产（canSchedule 资格闸，早于数量校验）：
        // V577 放开的是「本批数量可以超出剩余需求」，不是「已办结的任务行还能再下达」。
        // 纯粹为了多备货的生产属于另立备货任务，不从已办结的子件行复活。
        assertThrows(ApiException.class,()->issue(c,material,"1","new-key-after-full",true));
        assertQuotaAndPlans(c,anchor,"10000",1);
    }

    @Test void equalGoodsOnTwoBomPathsHaveDistinctAnchorsAndLegacyActionIsNotCountedTwice(){
        Case c=create("anchor-paths",true);UUID first=c.materials().get(0),second=c.materials().get(1);
        issue(c,first,"6000","legacy-first",true);
        UUID legacyAnchor=material(analyses.detail(c.analysis()),first).planAnchorAnalysisLineId();
        addHistoricalMakeAction(c,first,legacyAnchor);
        issue(c,first,"4000","legacy-remaining",true);
        issue(c,second,"4000","other-path",true);
        AnalysisView view=analyses.detail(c.analysis());UUID secondAnchor=material(view,second).planAnchorAnalysisLineId();
        assertNotNull(legacyAnchor);assertNotNull(secondAnchor);assertNotEquals(legacyAnchor,secondAnchor);
        qty("10000",product(view,legacyAnchor).requestedQty());qty("0",product(view,legacyAnchor).remainingQty());
        qty("10000",product(view,secondAnchor).requestedQty());qty("6000",product(view,secondAnchor).remainingQty());
        assertEquals(1,count("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route='MAKE'",c.analysis()));
        assertThrows(ApiException.class,()->issue(c,first,"1","cannot-use-sibling-quota",true));
        // ADR-104：legacy 路径的两批(6000 + 4000)并成一张没开工的计划, 另一条路径自己一张——共两张。
        assertEquals(2,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        qty("10000",product(analyses.detail(c.analysis()),legacyAnchor).requestedQty());
    }

    @Test void deletingDraftReleasesItsPlanQuantityWithoutIncreasingTheAnchorDemand(){
        Case c=create("anchor-draft-delete",false);UUID material=c.materials().getFirst();
        var first=issue(c,material,"6000","draft",false);
        UUID anchor=material(first.analysis(),material).planAnchorAnalysisLineId();
        qty("6000",product(first.analysis(),anchor).submittedQty());
        plans.delete(first.plans().getFirst().planId());
        var released=analyses.detail(c.analysis());
        qty("10000",product(released,anchor).requestedQty());qty("10000",product(released,anchor).remainingQty());
        issue(c,material,"4000","after-delete",false);
        qty("10000",product(analyses.detail(c.analysis()),anchor).requestedQty());
        qty("4000",product(analyses.detail(c.analysis()),anchor).submittedQty());
        assertEquals(1,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted",c.analysis()));
    }

    /** ADR-104 修订：来源增量本身不动任何计划; 随后按新增配额下达时, 没开工的原计划就地并入(明细 10000→15000)。 */
    @Test void explicitSourceIncreaseAddsOnlyTheNewQuotaAndGrowsTheUnstartedPlanInPlace(){
        Case c=create("anchor-source-growth",false);UUID material=c.materials().getFirst();
        var first=issue(c,material,"10000","original-demand",true);
        UUID anchor=material(first.analysis(),material).planAnchorAnalysisLineId();
        AnalysisView before=analyses.detail(c.analysis());
        var request=new PreviewRequest(c.analysis(),before.version(),before.fingerprint(),c.world().warehouseId(),
                "grow-source-"+c.analysis(),List.of(new PreviewItem("OTHER",null,c.root(),null,c.world().unitId(),
                        c.sourceRef(),"明确增加原始生产需求",BusinessTime.today().plusDays(10),new BigDecimal("15000"))));
        AnalysisView grown=analyses.preview(request);
        assertEquals(anchor,material(grown,material).planAnchorAnalysisLineId());
        qty("15000",product(grown,anchor).requestedQty());qty("10000",product(grown,anchor).approvedQty());
        qty("5000",product(grown,anchor).remainingQty());
        assertEquals(0,new BigDecimal("10000").compareTo(db.queryForObject(
                "SELECT sum(qty) FROM production_plan_items WHERE plan_id=?",BigDecimal.class,first.plans().getFirst().planId())));
        qty("15000",product(analyses.preview(request),anchor).requestedQty());
        qty("15000",product(analyses.detail(c.analysis()),anchor).requestedQty());
        var delta=issue(c,material,"5000","new-source-delta",true);
        assertTrue(delta.plans().getFirst().mergedIntoExisting());
        assertEquals(first.plans().getFirst().planId(),delta.plans().getFirst().planId());
        assertQuotaAndPlans(c,anchor,"15000",1);
        assertEquals(0,new BigDecimal("15000").compareTo(db.queryForObject(
                "SELECT sum(qty) FROM production_plan_items WHERE plan_id=?",BigDecimal.class,first.plans().getFirst().planId())));
        assertEquals(1,count("SELECT count(*) FROM production_execution_segments WHERE plan_id=? AND is_deleted=FALSE",first.plans().getFirst().planId()));
        assertThrows(ApiException.class,()->issue(c,material,"1","source-growth-full",true));
    }

    @Test void approvedRoot6000CanAdmitOnlyFinanceApprovedExtra2000WithoutRewritingOldPackages(){
        Case c=create("anchor-sales-growth",false,true,"6000");
        UUID material=c.materials().getFirst();
        var childPlan=issue(c,material,"6000","child-original",true);
        UUID anchor=material(childPlan.analysis(),material).planAnchorAnalysisLineId();
        AnalysisView view=analyses.detail(c.analysis());
        UUID root=view.products().stream().filter(p->p.salesOrderItemId()!=null)
                .map(ProductView::analysisLineId).findFirst().orElseThrow();
        var rootPlan=issueProduct(c,root,"6000","root-original");
        Map<String,String> oldPlans=frozenPlans(c.analysis());
        qty("6000",product(rootPlan.analysis(),root).approvedQty());

        fixture.loginAs(c.salesActor());
        var changed=new com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest.Line();
        changed.setOrderItemId(c.salesItem());changed.setNewQty(new BigDecimal("8000"));
        var amendment=new com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest();
        amendment.setItems(List.of(changed));sales.changeQty(c.salesOrder(),amendment);
        fixture.loginAs(c.planner());
        ApiException pending=assertThrows(ApiException.class,()->analyses.preview(salesPreview(c,"8000","pending-finance")));
        assertTrue(pending.getMessage().contains("等待财务确认"));
        qty("6000",product(analyses.detail(c.analysis()),root).requestedQty());
        assertEquals(oldPlans,frozenPlans(c.analysis()));

        confirmSales(c.salesOrder(),c.financeActor());fixture.loginAs(c.planner());
        Map<String,String> before=nonPlanningFacts(c);
        ApiException excessive=assertThrows(ApiException.class,()->analyses.preview(salesPreview(c,"9000","over-capacity")));
        assertTrue(excessive.getMessage().contains("超过销售订单尚未安排"));
        UUID otherWarehouse=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",otherWarehouse,"ALT-"+otherWarehouse,"增额不可顺便切换的仓库");
        var latest=analyses.detail(c.analysis());
        var wrongWarehouse=new PreviewRequest(c.analysis(),latest.version(),latest.fingerprint(),otherWarehouse,
                "growth-other-warehouse-"+c.analysis(),salesPreview(c,"8000","warehouse-template").items());
        assertTrue(assertThrows(ApiException.class,()->analyses.preview(wrongWarehouse)).getMessage().contains("不能同时更改"));
        var admitted=analyses.preview(salesPreview(c,"8000","admit-finance-growth"));
        qty("8000",product(admitted,root).requestedQty());qty("2000",product(admitted,root).remainingQty());
        qty("8000",product(admitted,anchor).requestedQty());qty("2000",product(admitted,anchor).remainingQty());
        assertEquals(oldPlans,frozenPlans(c.analysis()));assertEquals(before,nonPlanningFacts(c));

        // 两张原计划都未执行：计划头及包不变，原工单与需求保留身份并各增长到 8000。
        Map<UUID,String> oldSegments=new LinkedHashMap<>();
        for(UUID segment:db.queryForList("SELECT s.id FROM production_execution_segments s JOIN production_plans p ON p.id=s.plan_id WHERE p.material_analysis_id=? ORDER BY s.id",UUID.class,c.analysis()))
            oldSegments.put(segment,db.queryForObject("SELECT segment_code FROM production_execution_segments WHERE id=?",String.class,segment));
        Map<UUID,String> oldDemands=new LinkedHashMap<>();
        Map<UUID,BigDecimal> oldDemandQuantities=new LinkedHashMap<>();
        for(UUID demand:db.queryForList("SELECT d.id FROM production_material_demands d JOIN production_plans p ON p.id=d.plan_id WHERE p.material_analysis_id=? ORDER BY d.id",UUID.class,c.analysis())) {
            oldDemands.put(demand,db.queryForObject("SELECT jsonb_build_array(execution_segment_id,goods_id,color_id,unit_id)::text FROM production_material_demands WHERE id=?",String.class,demand));
            oldDemandQuantities.put(demand,db.queryForObject("SELECT required_qty FROM production_material_demands WHERE id=?",BigDecimal.class,demand));
        }
        var childExtra=issue(c,material,"2000","child-extra",true);
        var rootExtra=issueProduct(c,root,"2000","root-extra");
        assertTrue(childExtra.plans().getFirst().mergedIntoExisting());assertTrue(rootExtra.plans().getFirst().mergedIntoExisting());
        assertEquals(childPlan.plans().getFirst().planId(),childExtra.plans().getFirst().planId());
        assertEquals(rootPlan.plans().getFirst().planId(),rootExtra.plans().getFirst().planId());
        qty("0",product(analyses.detail(c.analysis()),root).remainingQty());
        assertThrows(ApiException.class,()->issueProduct(c,root,"1","root-after-full"));
        assertEquals(2,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        Map<String,String> after=frozenPlans(c.analysis());
        oldPlans.forEach((key,value)->{
            if(key.endsWith("/header")||key.endsWith("/production_planning_packages"))
                assertEquals(value,after.get(key),"原计划头及计划包未改写: "+key);
        });
        oldSegments.forEach((id,code)->{
            assertEquals(code,db.queryForObject("SELECT segment_code FROM production_execution_segments WHERE id=? AND NOT is_deleted",String.class,id),"原工单号保留: "+id);
            qty("8000",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,id));
        });
        oldDemands.forEach((id,identity)->{
            assertEquals(identity,db.queryForObject("SELECT jsonb_build_array(execution_segment_id,goods_id,color_id,unit_id)::text FROM production_material_demands WHERE id=? AND NOT is_deleted",String.class,id),"原需求身份保留: "+id);
            qty(oldDemandQuantities.get(id).multiply(new BigDecimal("4")).divide(new BigDecimal("3")).toPlainString(),db.queryForObject("SELECT required_qty FROM production_material_demands WHERE id=?",BigDecimal.class,id));
        });
        for(UUID plan:List.of(childPlan.plans().getFirst().planId(),rootPlan.plans().getFirst().planId())){
            qty("8000",db.queryForObject("SELECT sum(qty) FROM production_plan_items WHERE plan_id=?",BigDecimal.class,plan));
            assertEquals(1,count("SELECT count(*) FROM production_execution_segments WHERE plan_id=? AND is_deleted=FALSE",plan));
        }
        assertEquals(before,nonPlanningFacts(c));
    }

    /**
     * 混合候选一次下达（2 个自制 + 1 个有自制子层的委外）：每行各一张计划、各一条子件锚点
     * （MAKE_COMPONENT / SUBCONTRACT_MAKE）、委外台账一条；batchChildLineIds 一次 IN 按父行映射，
     * 唯一部分索引保证每父至多一子（无重复子件）；同请求重放不重复建行。
     */
    @Test void mixedMakeAndSubcontractCandidatesIssueInOneBatchWithOneAnchorEach(){
        MixedCase c=createMixed("anchor-mixed");
        AnalysisView view=analyses.detail(c.analysis());
        var request=issueRequest(c.analysis(),view,c.world(),"mixed",
                line(c.makeLines().get(0),"6000"),line(c.makeLines().get(1),"6000"),line(c.subcontractLine(),"6000"));
        GenerateResult result=commands.issueWorkshopPlans(c.analysis(),request);
        assertFalse(result.replayed());assertEquals(3,result.plans().size());
        AnalysisView after=analyses.detail(c.analysis());
        for(UUID make:c.makeLines()){
            UUID anchor=material(after,make).planAnchorAnalysisLineId();
            assertNotNull(anchor,"每个自制候选各有一条锚点");
            assertEquals("MAKE_COMPONENT",product(after,anchor).sourceType());
            qty("10000",product(after,anchor).requestedQty());qty("6000",product(after,anchor).approvedQty());
        }
        assertEquals(2,count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE",c.analysis()));
        assertEquals(1,count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='SUBCONTRACT_MAKE' AND is_deleted=FALSE",c.analysis()));
        assertEquals(1,count("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route='SUBCONTRACT'",c.analysis()));
        assertEquals(3,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        assertEquals(0,count("SELECT count(*) FROM (SELECT parent_analysis_material_id FROM production_material_analysis_items WHERE analysis_id=? AND source_type IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE') AND is_deleted=FALSE GROUP BY 1 HAVING count(*)>1) dup",c.analysis()));
        var replay=commands.issueWorkshopPlans(c.analysis(),request);
        assertTrue(replay.replayed());
        assertEquals(3,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
    }

    /**
     * V589（2026-09-15）用户口径「顶层要做 5000，委外件就要加工 5000」：有自制
     * 子层的委外候选超量下达车间时，委外链如实跟量——ARRANGE 行动记
     * requested=归需求量(锁) + public_surplus=超量，台账 required=两者之和，
     * 锚点计划一张（link 分账，V577 形状）。人工「下达委外」通道不变：仍整量
     * 接管、仍禁公共超量。
     */
    @Test void subcontractMakeFirstTaskFollowsWorkshopOverquantity(){
        MixedCase c=createMixed("anchor-sc-over");
        AnalysisView view=analyses.detail(c.analysis());
        var result=commands.issueWorkshopPlans(c.analysis(),issueRequest(c.analysis(),view,c.world(),"sc-over",
                line(c.subcontractLine(),"15000")));
        assertEquals(1,result.plans().size());
        var action=db.queryForMap("SELECT requested_qty,public_surplus_qty FROM preplan_supply_actions WHERE analysis_id=? AND route='SUBCONTRACT'",c.analysis());
        qty("10000",(BigDecimal)action.get("requested_qty"));
        qty("5000",(BigDecimal)action.get("public_surplus_qty"));
        qty("15000",db.queryForObject("SELECT required_qty FROM preplan_subcontract_make_tasks WHERE analysis_id=?",
                BigDecimal.class,c.analysis()));
        qty("15000",db.queryForObject("""
                SELECT COALESCE(SUM(pi.qty),0) FROM production_plan_items pi
                JOIN production_plans p ON p.id=pi.plan_id
                WHERE p.material_analysis_id=? AND pi.is_deleted=FALSE
                """,BigDecimal.class,c.analysis()));
        var links=db.queryForList("SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links WHERE analysis_id=?",c.analysis());
        assertEquals(1,links.size());
        qty("10000",(BigDecimal)links.get(0).get("submitted_qty"));
        qty("5000",(BigDecimal)links.get(0).get("public_surplus_qty"));
        // 锚点行需求侧仍只记需求量（10000）——超量在台账与行动上，不抬需求账。
        AnalysisView after=analyses.detail(c.analysis());
        UUID anchor=material(after,c.subcontractLine()).planAnchorAnalysisLineId();
        qty("10000",product(after,anchor).requestedQty());
        qty("0", material(after, c.subcontractLine()).externalFutureCoverageQty());
        qty("15000", material(after, c.subcontractLine()).internalCommittedOutputQty());
    }

    @Test void subcontractSecondCandidateBatchConsumesExistingCommitmentBeforeAddingSurplus() {
        assertSubcontractSecondBatch(false, "4000", "10000", "0");
    }

    @Test void subcontractSecondCandidateOverquantityAddsOnlyTrueSurplus() {
        assertSubcontractSecondBatch(false, "6000", "12000", "2000");
    }

    @Test void subcontractSecondAnchorBatchConsumesExistingCommitmentBeforeAddingSurplus() {
        assertSubcontractSecondBatch(true, "4000", "10000", "0");
    }

    @Test void subcontractSecondAnchorOverquantityUpdatesPreparationCommitment() {
        assertSubcontractSecondBatch(true, "6000", "12000", "2000");
    }

    @Test void subcontractSurplusCancellationProtectsPlansThenReleasesExactAndPublicCommitment() {
        MixedCase c = createMixed("sc-cancel-" + UUID.randomUUID().toString().substring(0, 8));
        var before = analyses.detail(c.analysis());
        var first = commands.issueWorkshopPlans(c.analysis(), new IssueWorkshopPlansRequest(
                before.version(), before.fingerprint(), "sc-cancel-first-" + c.analysis(), c.world().warehouseId(),
                BusinessTime.today(), null, false, List.of(line(c.subcontractLine(), "6000"))));
        var second = commands.issueWorkshopPlans(c.analysis(), new IssueWorkshopPlansRequest(
                first.analysis().version(), first.analysis().fingerprint(), "sc-cancel-second-" + c.analysis(),
                c.world().warehouseId(), BusinessTime.today(), null, false, List.of(line(c.subcontractLine(), "6000"))));
        UUID surplusAction = db.queryForObject("SELECT id FROM preplan_supply_actions WHERE analysis_id=? AND public_surplus_qty>0",
                UUID.class, c.analysis());
        assertThrows(ApiException.class, () -> commands.cancelAction(c.analysis(), surplusAction,
                cancel(second.analysis(), "blocked")), "Public-only actions also protect actual plan output");
        // ADR-104：两批都是草稿、都没开工, 第二批并进第一张草稿——只有一张计划可删。
        assertTrue(second.plans().getFirst().mergedIntoExisting());
        assertEquals(first.plans().getFirst().planId(), second.plans().getFirst().planId());
        plans.delete(second.plans().getFirst().planId());
        commands.cancelAction(c.analysis(), surplusAction, cancel(analyses.detail(c.analysis()), "surplus"));
        qty("10000", db.queryForObject("SELECT required_qty FROM preplan_subcontract_make_tasks WHERE analysis_id=?",
                BigDecimal.class, c.analysis()));
        UUID original = db.queryForObject("SELECT id FROM preplan_supply_actions WHERE analysis_id=? AND requested_qty>0",
                UUID.class, c.analysis());
        commands.cancelAction(c.analysis(), original, cancel(analyses.detail(c.analysis()), "original"));
        assertEquals("CANCELLED", db.queryForObject("SELECT status FROM preplan_subcontract_make_tasks WHERE analysis_id=?",
                String.class, c.analysis()));
        assertEquals(0, count("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND status<>'CANCELLED'", c.analysis()));
    }

    private static CancelRequest cancel(AnalysisView view, String suffix) {
        return new CancelRequest(view.version(), view.fingerprint(), "cancel-" + view.analysisId() + "-" + suffix,
                "回归验证撤回未生产承诺");
    }

    private void assertSubcontractSecondBatch(boolean anchorInput, String secondQty,
            String required, String surplus) {
        MixedCase c = createMixed("sc-repeat-" + UUID.randomUUID().toString().substring(0, 8));
        var first = commands.issueWorkshopPlans(c.analysis(), issueRequest(c.analysis(),
                analyses.detail(c.analysis()), c.world(), "first", line(c.subcontractLine(), "6000")));
        UUID anchor = material(first.analysis(), c.subcontractLine()).planAnchorAnalysisLineId();
        var secondLine = anchorInput
                ? new IssueWorkshopPlansRequest.IssuePlanLine(null, anchor, new BigDecimal(secondQty),
                        null, null, null, null, null, null, null)
                : line(c.subcontractLine(), secondQty);
        var request = issueRequest(c.analysis(), first.analysis(), c.world(), "second", secondLine);
        var second = commands.issueWorkshopPlans(c.analysis(), request);
        assertEquals(1, second.plans().size());
        qty(required, db.queryForObject("SELECT required_qty FROM preplan_subcontract_make_tasks WHERE analysis_id=?",
                BigDecimal.class, c.analysis()));
        qty("10000", db.queryForObject("SELECT SUM(requested_qty) FROM preplan_supply_actions WHERE analysis_id=? AND status<>'CANCELLED'",
                BigDecimal.class, c.analysis()));
        qty(surplus, db.queryForObject("SELECT SUM(public_surplus_qty) FROM preplan_supply_actions WHERE analysis_id=? AND status<>'CANCELLED'",
                BigDecimal.class, c.analysis()));
        qty(surplus, db.queryForObject("SELECT SUM(public_surplus_qty) FROM production_material_analysis_plan_links WHERE analysis_id=?",
                BigDecimal.class, c.analysis()));
        qty("10000", product(second.analysis(), anchor).requestedQty());
        var replay = commands.issueWorkshopPlans(c.analysis(), request);
        assertTrue(replay.replayed());
        assertEquals(second.plans().getFirst().planId(), replay.plans().getFirst().planId());
        qty(required, db.queryForObject("SELECT required_qty FROM preplan_subcontract_make_tasks WHERE analysis_id=?",
                BigDecimal.class, c.analysis()));
        // ADR-104：前置自制那张计划没开工, 第二批并进同一张。
        assertTrue(second.plans().getFirst().mergedIntoExisting());
        assertEquals(first.plans().getFirst().planId(), second.plans().getFirst().planId());
        assertEquals(1, count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?", c.analysis()));
    }

    /** 同一批自制候选二次下达：走既有锚点，各自原工单加量。 */
    @Test void secondIssueOnTheSameCandidatesReusesExistingAnchorsWithoutNewChildRows(){
        MixedCase c=createMixed("anchor-reuse");
        UUID a=c.makeLines().get(0),b=c.makeLines().get(1);
        commands.issueWorkshopPlans(c.analysis(),issueRequest(c.analysis(),analyses.detail(c.analysis()),c.world(),"first",line(a,"6000"),line(b,"6000")));
        List<String> originalTaskIdentities=db.queryForList("SELECT s.id::text||'|'||s.segment_code FROM production_execution_segments s JOIN production_plans p ON p.id=s.plan_id WHERE p.material_analysis_id=? AND NOT s.is_deleted ORDER BY s.id",String.class,c.analysis());
        AnalysisView first=analyses.detail(c.analysis());
        // Arrays.asList 允许 null 元素：锚点缺失时走断言失败而不是 List.of 的 NPE。
        List<UUID> anchors=java.util.Arrays.asList(material(first,a).planAnchorAnalysisLineId(),material(first,b).planAnchorAnalysisLineId());
        anchors.forEach(anchor->assertNotNull(anchor,"二次下达前每个自制候选都已有锚点"));
        commands.issueWorkshopPlans(c.analysis(),issueRequest(c.analysis(),first,c.world(),"second",line(a,"4000"),line(b,"4000")));
        AnalysisView second=analyses.detail(c.analysis());
        assertEquals(anchors,List.of(material(second,a).planAnchorAnalysisLineId(),material(second,b).planAnchorAnalysisLineId()));
        assertEquals(2,count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE",c.analysis()));
        // 两个锚点各自并入原计划与原工单：两张计划、各一段，数量 10000。
        assertEquals(2,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        assertEquals(2,count("SELECT count(*) FROM production_execution_segments s JOIN production_plans p ON p.id=s.plan_id WHERE p.material_analysis_id=? AND s.is_deleted=FALSE",c.analysis()));
        assertEquals(originalTaskIdentities,db.queryForList("SELECT s.id::text||'|'||s.segment_code FROM production_execution_segments s JOIN production_plans p ON p.id=s.plan_id WHERE p.material_analysis_id=? AND NOT s.is_deleted ORDER BY s.id",String.class,c.analysis()));
        assertEquals(2,count("SELECT count(*) FROM production_execution_segments s JOIN production_plans p ON p.id=s.plan_id WHERE p.material_analysis_id=? AND NOT s.is_deleted AND s.planned_qty=10000",c.analysis()));
        for(UUID anchor:anchors){qty("10000",product(second,anchor).requestedQty());qty("0",product(second,anchor).remainingQty());}
        assertThrows(ApiException.class,()->commands.issueWorkshopPlans(c.analysis(),issueRequest(c.analysis(),second,c.world(),"third",line(a,"1"))));
        assertEquals(2,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
    }

    /**
     * 两线程分别下达不同候选行（同一版本/指纹）：advisory 锁串行，先到者成功，后到者按 CAS
     * 得 409（不会死锁、不留半截锚点）；失败方用新版本重试成功。最终两条锚点、两张计划、
     * line_priority 互不冲突。
     */
    @Test void twoThreadsIssuingDifferentCandidateLinesSerializeWithoutResidueAndKeepDistinctPriorities() throws Exception{
        Case c=create("anchor-threads",true);UUID first=c.materials().get(0),second=c.materials().get(1);
        AnalysisView view=analyses.detail(c.analysis());
        List<IssueWorkshopPlansRequest> requests=List.of(
                request(c,view,first,"6000","thread-a",true),request(c,view,second,"6000","thread-b",true));
        var workers=Executors.newFixedThreadPool(2);CountDownLatch start=new CountDownLatch(1);
        List<Object> outcomes=new ArrayList<>();
        try{
            var jobs=requests.stream().map(r->workers.submit(()->{
                fixture.loginAs(c.planner());
                try{assertTrue(start.await(30,TimeUnit.SECONDS));return commands.issueWorkshopPlans(c.analysis(),r);}
                finally{SecurityContextHolder.clearContext();}
            })).toList();
            start.countDown();
            for(var job:jobs){
                try{outcomes.add(job.get(120,TimeUnit.SECONDS));}
                catch(java.util.concurrent.ExecutionException e){outcomes.add(e.getCause());}
            }
        }finally{workers.shutdownNow();}
        long successes=outcomes.stream().filter(o->o instanceof GenerateResult).count();
        assertTrue(successes>=1,"至少一个线程成功: "+outcomes);
        outcomes.stream().filter(o->!(o instanceof GenerateResult))
                .forEach(o->assertInstanceOf(ApiException.class,o,"落后线程只能是 CAS/锁冲突，不是其它异常"));
        assertEquals(successes,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        assertEquals(successes,count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE",c.analysis()));
        for(UUID material:List.of(first,second)){
            if(material(analyses.detail(c.analysis()),material).planAnchorAnalysisLineId()==null){
                issue(c,material,"6000","retry-"+material,true);
            }
        }
        AnalysisView done=analyses.detail(c.analysis());
        assertNotEquals(material(done,first).planAnchorAnalysisLineId(),material(done,second).planAnchorAnalysisLineId());
        assertEquals(2,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        assertEquals(2,count("SELECT count(DISTINCT line_priority) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE",c.analysis()));
    }

    /**
     * V577：子件锚点行的本批数量可以超出剩余需求，超出部分按「公共备货产出」单独记账。
     *
     * <p>守的是拆账本身——计划行数量 = 全量；关联行 submitted_qty 只记归本需求的那部分、
     * public_surplus_qty 记超出部分；**锚点的 requested_qty 一个字节不动**（抬需求会污染
     * growMakeAnchorQuotasAfterSourcePreview 的配额算法并与来源对账脱钩，见 V577 说明）。
     * 用户口径（2026-09-14）：「生产是可以超出数量下达的，超出部分就是公共的，其他计划可以占用」。
     */
    @Test void overQuantityLineSplitsPublicSurplusWithoutTouchingDemand(){
        Case c=create("anchor-over-qty",true);UUID first=c.materials().get(0),second=c.materials().get(1);
        AnalysisView view=analyses.detail(c.analysis());
        commands.issueWorkshopPlans(c.analysis(),
                issueRequest(c.analysis(),view,c.world(),"over",line(first,"6000"),line(second,"20000")));
        AnalysisView after=analyses.detail(c.analysis());
        UUID overAnchor=material(after,second).planAnchorAnalysisLineId();
        assertNotNull(overAnchor);
        // 锚点需求仍是建锚时的全量剩余需求（10000），没有被本批的 20000 抬高。
        qty("10000",product(after,overAnchor).requestedQty());
        Object[] link=db.queryForObject(
                "SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links"
                        +" WHERE analysis_id=? AND analysis_item_id=?",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},c.analysis(),overAnchor);
        qty("10000",(BigDecimal)link[0]);
        qty("10000",(BigDecimal)link[1]);
        // 计划行数量 = 归需求 + 公共备货产出；两笔之和必须与计划一致（V577 触发器对账）。
        qty("20000",db.queryForObject(
                "SELECT item.qty FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id"
                        +" WHERE plan.material_analysis_id=? AND plan.material_analysis_item_id=? AND item.is_deleted=FALSE",
                BigDecimal.class,c.analysis(),overAnchor));
        // 未超量的那行照旧全额归需求，不受影响。
        UUID exactAnchor=material(after,first).planAnchorAnalysisLineId();
        qty("0",db.queryForObject("SELECT public_surplus_qty FROM production_material_analysis_plan_links"
                +" WHERE analysis_id=? AND analysis_item_id=?",BigDecimal.class,c.analysis(),exactAnchor));
        assertEquals(2,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
    }

    private static IssueWorkshopPlansRequest.IssuePlanLine line(UUID material,String qty){
        return new IssueWorkshopPlansRequest.IssuePlanLine(material,null,new BigDecimal(qty),null,null,null,null,null,null,null);
    }
    private static IssueWorkshopPlansRequest issueRequest(UUID analysis,AnalysisView view,FullChainEndToEndTest.World w,String key,
                                                          IssueWorkshopPlansRequest.IssuePlanLine...lines){
        return new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"issue-"+analysis+"-"+key,w.warehouseId(),
                BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(lines));
    }

    /** 根 → {P0(自制)→C, P1(自制)→C, S(委外)→C, D(采购)}：两条自制候选 + 一条有自制子层的委外候选。 */
    private MixedCase createMixed(String tag){
        var w=fixture.seedWorld(tag);UUID root=UUID.randomUUID();
        fixture.insertGoods(root,"ROOT-"+tag,"混合候选成品","自制",w.unitId(),w.unitLegacy());
        List<UUID> makeParents=new ArrayList<>();
        for(int i=0;i<2;i++){
            UUID parent=UUID.randomUUID();fixture.insertGoods(parent,"P"+i+"-"+tag,"自制父件"+i,"自制",w.unitId(),w.unitLegacy());
            fixture.insertBom(root,parent,"1");fixture.insertBom(parent,w.goodsC(),"1");makeParents.add(parent);
        }
        UUID sub=UUID.randomUUID();fixture.insertGoods(sub,"S-"+tag,"有自制子层的委外件","委外",w.unitId(),w.unitLegacy());
        fixture.insertBom(root,sub,"1");fixture.insertBom(sub,w.goodsC(),"1");
        // 必须挂**两颗**子件：V581 起「只有一个叶子子件」的委外件属直接发那颗子件
        // 出去（COMPONENT_OUTBOUND），issue-plans 会明确拒掉它。本用例测的正是
        // 「有自制子层的委外件与自制候选同批下达车间」，夹具要落在前置自制那一类。
        // 第二颗取已存在的采购件 goodsD（路线映射里是 BUY），不会多出自制锚点。
        fixture.insertBom(sub,w.goodsD(),"1");
        fixture.insertBom(root,w.goodsD(),"1");
        UUID planner=fixture.createUserWithPerms(w,"planner-"+tag,
                "production_material_analysis:view","production_material_analysis:manage","production_material_analysis:route",
                "production_material_analysis:notify","production_material_analysis:generate","production_plan:view",
                "production_plan:approve","production_plan:delete");
        fixture.loginAs(planner);
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"preview-"+tag,List.of(
                new PreviewItem("OTHER",null,root,null,w.unitId(),"manual-"+tag,"混合候选原始需求",BusinessTime.today().plusDays(10),new BigDecimal("10000")))));
        var routes=view.flatMaterials().stream().map(m->new RouteDecision(m.materialLineId(),m.actionGroupKey(),
                m.goodsId().equals(w.goodsD())?"BUY":m.goodsId().equals(sub)?"SUBCONTRACT":"MAKE",null)).toList();
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"routes-"+tag,routes));
        view=analyses.detail(view.analysisId());
        List<UUID> makeLines=view.flatMaterials().stream().filter(m->makeParents.contains(m.goodsId()))
                .map(MaterialView::materialLineId).sorted().toList();
        UUID subLine=view.flatMaterials().stream().filter(m->m.goodsId().equals(sub))
                .map(MaterialView::materialLineId).findFirst().orElseThrow();
        assertEquals(2,makeLines.size());
        return new MixedCase(w,view.analysisId(),makeLines,subLine,planner);
    }
    private record MixedCase(FullChainEndToEndTest.World world,UUID analysis,List<UUID> makeLines,UUID subcontractLine,UUID planner){}

    private GenerateResult issueProduct(Case c,UUID product,String qty,String key){
        AnalysisView view=analyses.detail(c.analysis());
        return commands.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "issue-"+c.analysis()+"-"+key,c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(product,new BigDecimal(qty)))));
    }

    private PreviewRequest salesPreview(Case c,String qty,String key){
        AnalysisView view=analyses.detail(c.analysis());
        return new PreviewRequest(c.analysis(),view.version(),view.fingerprint(),c.world().warehouseId(),
                key+"-"+c.analysis(),List.of(new PreviewItem("SALES_ORDER_ITEM",c.salesItem(),null,null,null,
                null,null,BusinessTime.today().plusDays(10),new BigDecimal(qty))));
    }

    private void confirmSales(UUID order,UUID actor){
        fixture.loginAs(actor);var claim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.toString());
        Long revision=db.queryForObject("SELECT finance_review_revision FROM sales_orders WHERE id=?",Long.class,order);
        finance.confirm(order,new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,revision,claim.claimId()));
    }

    private Map<String,String> frozenPlans(UUID analysis){
        Map<String,String> facts=new LinkedHashMap<>();
        for(UUID plan:db.queryForList("SELECT id FROM production_plans WHERE material_analysis_id=? ORDER BY id",UUID.class,analysis)){
            facts.put(plan+"/header",rows("production_plans","id=?",plan));
            for(String table:List.of("production_plan_items","production_planning_packages","production_execution_segments","production_material_demands"))
                facts.put(plan+"/"+table,rows(table,"plan_id=?",plan));
        }
        return facts;
    }

    private Map<String,String> nonPlanningFacts(Case c){
        Map<String,String> facts=new LinkedHashMap<>();
        facts.put("movement",rows("stock_movements","warehouse_id=?",c.world().warehouseId()));
        facts.put("balance",db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY goods_id,color_id),'[]')::text FROM stock_balances t WHERE warehouse_id=?",String.class,c.world().warehouseId()));
        facts.put("ledger",rows("ar_ap_ledger","TRUE"));
        facts.put("finance",db.queryForObject("SELECT jsonb_build_array(total_original,total_local,finance_confirmed,finance_review_revision)::text FROM sales_orders WHERE id=?",String.class,c.salesOrder()));
        return facts;
    }

    private String rows(String table,String predicate,Object...args){
        return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]')::text FROM "+table+" t WHERE "+predicate,String.class,args);
    }

    private void addHistoricalMakeAction(Case c,UUID material,UUID anchor){
        AnalysisView view=analyses.detail(c.analysis());MaterialView parent=material(view,material);ProductView child=product(view,anchor);
        UUID action=UUID.randomUUID();UUID actor=db.queryForObject("SELECT created_by FROM production_material_analysis_items WHERE id=?",UUID.class,anchor);
        // MAKE notification is retired at the current API. Preserve its real, guard-checked legacy relation as a fixture.
        new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(status->{
            db.update("""
                    INSERT INTO preplan_supply_actions(id,analysis_id,warehouse_id,goods_id,color_id,unit_id,need_date,
                        route,requested_qty,status,idempotency_key,action_group_key,request_business_key,generation,
                        request_hash,created_by)
                    VALUES(?,?,?,?,?,?,?,'MAKE',?,'OPEN',?,?,?,1,?,?)
                    """,action,c.analysis(),c.world().warehouseId(),parent.goodsId(),parent.colorId(),parent.unitId(),
                    BusinessTime.today().plusDays(10),child.requestedQty(),"legacy-"+action,parent.actionGroupKey(),
                    PlanningPackageFingerprint.sha256(
                            List.of("PREPLAN-SUPPLY-ACTION-V1",c.analysis().toString(),parent.actionGroupKey(),"MAKE","1")),
                    PlanningPackageFingerprint.sha256(List.of("legacy-action-fixture",action.toString())),actor);
            db.update("INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty,created_by) VALUES(?,?,?,?,?,?)",
                    UUID.randomUUID(),c.analysis(),action,material,child.requestedQty(),actor);
            db.update("UPDATE preplan_supply_actions SET status='CREATED',external_document_type='PREPLAN_MAKE_TASK',external_document_id=?,external_document_no=? WHERE id=?",
                    anchor,child.sourceRef(),action);
            db.update("UPDATE preplan_supply_action_allocations SET external_item_id=? WHERE action_id=?",anchor,action);
        });
    }

    private Case create(String tag,boolean twoPaths){return create(tag,twoPaths,false,"10000");}
    private Case create(String tag,boolean twoPaths,boolean salesSource,String sourceQty){
        var w=fixture.seedWorld(tag);UUID root=UUID.randomUUID();
        fixture.insertGoods(root,"ROOT-"+tag,"锚点回归成品","自制",w.unitId(),w.unitLegacy());
        if(twoPaths){
            for(int i=0;i<2;i++){
                UUID parent=UUID.randomUUID();fixture.insertGoods(parent,"P"+i+"-"+tag,"独立父路径","自制",w.unitId(),w.unitLegacy());
                fixture.insertBom(root,parent,"1");fixture.insertBom(parent,w.goodsC(),"1");
            }
        }else fixture.insertBom(root,w.goodsC(),"1");
        fixture.insertBom(root,w.goodsD(),"1");
        UUID salesOrder=null,salesItem=null,salesActor=null,financeActor=null;
        if(salesSource){
            salesActor=fixture.createUserWithPerms(w,"seller-"+tag,"sales_order:create","sales_order:view","sales_order:approve","sales_order:change_qty","sales_order:change_planned");
            financeActor=fixture.createUserWithPerms(w,"finance-"+tag,"sales_order_finance:view","sales_order_finance:confirm");
            db.update("UPDATE clients SET owner_employee_id=(SELECT employee_id FROM users WHERE id=?) WHERE id=?",salesActor,w.clientId());
            fixture.loginAs(salesActor);salesOrder=sales.create(fixture.orderRequest(w,root,sourceQty,"100")).getId();
            sales.approve(salesOrder);confirmSales(salesOrder,financeActor);
            salesItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,salesOrder);
        }
        UUID planner=fixture.createUserWithPerms(w,"planner-"+tag,
                "production_material_analysis:view","production_material_analysis:manage","production_material_analysis:route",
                "production_material_analysis:notify","production_material_analysis:generate","production_plan:view",
                "production_plan:approve","production_plan:delete");
        fixture.loginAs(planner);
        String source="manual-"+tag;
        PreviewItem sourceItem=salesSource
                ?new PreviewItem("SALES_ORDER_ITEM",salesItem,null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal(sourceQty))
                :new PreviewItem("OTHER",null,root,null,w.unitId(),source,"明确的原始生产需求",BusinessTime.today().plusDays(10),new BigDecimal(sourceQty));
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"preview-"+tag,List.of(sourceItem)));
        var routes=view.flatMaterials().stream().map(m->new RouteDecision(m.materialLineId(),m.actionGroupKey(),
                m.goodsId().equals(w.goodsD())?"BUY":"MAKE",null)).toList();
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"routes-"+tag,routes));
        view=analyses.detail(view.analysisId());
        List<UUID> materialIds=view.flatMaterials().stream().filter(m->m.goodsId().equals(w.goodsC()))
                .map(MaterialView::materialLineId).sorted().toList();
        assertEquals(twoPaths?2:1,materialIds.size());
        return new Case(w,view.analysisId(),root,source,materialIds,planner,salesOrder,salesItem,salesActor,financeActor);
    }
    private GenerateResult issue(Case c,UUID material,String qty,String key,boolean approve){
        AnalysisView view=analyses.detail(c.analysis());
        return commands.issueWorkshopPlans(c.analysis(),request(c,view,material,qty,key,approve));
    }
    private static IssueWorkshopPlansRequest request(Case c,AnalysisView view,UUID material,String qty,String key,boolean approve){
        return new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"issue-"+c.analysis()+"-"+key,
                c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),approve,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(material,null,new BigDecimal(qty),null,null,null,null,null,null,null)));
    }
    private void assertQuotaAndPlans(Case c,UUID anchor,String qty,int expectedPlans){
        qty(qty,product(analyses.detail(c.analysis()),anchor).requestedQty());
        assertEquals(expectedPlans,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
    }
    private static MaterialView material(AnalysisView view,UUID id){return view.flatMaterials().stream().filter(m->m.materialLineId().equals(id)).findFirst().orElseThrow();}
    private static ProductView product(AnalysisView view,UUID id){return view.products().stream().filter(p->p.analysisLineId().equals(id)).findFirst().orElseThrow();}
    private int count(String sql,UUID id){return db.queryForObject(sql,Integer.class,id);}
    private static void qty(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual));}

    /**
     * 2026-09-14 修订二：销售订单来源顶层行超量下达不再拒绝（用户口径「填大于
     * 需求的量要能下单，超出部分就是公共的」）。本批 13000 > 订单剩余 10000 时
     * 仍出**一张**计划（2026-09-15 修订，用户口径「多余的不要单独列一张单，
     * 直接合并」）：明细数量 13000、带销售来源，link 记 submitted=10000 +
     * surplus=3000；销售分摊（plan_order_item_links 容量与订单侧 planned_qty）
     * 只认 submitted 的 10000，3000 公共备货产出不进销售账（V588 放宽执行段
     * 分摊断言的计划件级口径）。
     */
    @Test void salesTopOverQuantityIssuesSinglePlanWithSurplusLink(){
        Case c=create("sales-top-over",false,true,"10000");
        AnalysisView view=analyses.detail(c.analysis());
        ProductView top=view.products().stream().filter(p->p.salesOrderItemId()!=null).findFirst().orElseThrow();
        qty("10000",top.remainingQty());
        var result=commands.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(
                view.version(),view.fingerprint(),"issue-"+c.analysis()+"-over",
                c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,top.analysisLineId(),
                        new BigDecimal("13000"),null,null,null,null,null,null,null))));
        assertEquals(1,result.plans().size());
        assertEquals(1,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=? AND is_deleted=FALSE",c.analysis()));
        // 计划分账：一张 link submitted=10000 + surplus=3000，计划明细 13000。
        var links=db.queryForList("SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links WHERE analysis_id=?",c.analysis());
        assertEquals(1,links.size());
        qty("10000",(BigDecimal)links.get(0).get("submitted_qty"));
        qty("3000",(BigDecimal)links.get(0).get("public_surplus_qty"));
        // 一张计划行带销售来源，数量 13000（不再拆出无销售来源的备货行）。
        qty("13000",db.queryForObject("""
                SELECT COALESCE(SUM(pi.qty),0) FROM production_plan_items pi
                JOIN production_plans p ON p.id=pi.plan_id
                WHERE p.material_analysis_id=? AND pi.is_deleted=FALSE AND pi.sales_order_item_id IS NOT NULL
                """,BigDecimal.class,c.analysis()));
        qty("0",db.queryForObject("""
                SELECT COALESCE(SUM(pi.qty),0) FROM production_plan_items pi
                JOIN production_plans p ON p.id=pi.plan_id
                WHERE p.material_analysis_id=? AND pi.is_deleted=FALSE AND pi.sales_order_item_id IS NULL
                """,BigDecimal.class,c.analysis()));
        // 销售侧只排产 10000：plan_order_item_links 容量（= 审核分摊）只认
        // 归需求量，公共备货的 3000 不进订单 planned_qty。
        qty("10000",db.queryForObject("""
                SELECT COALESCE(SUM(l.allocated_qty),0) FROM plan_order_item_links l
                WHERE l.order_item_id=?
                """,BigDecimal.class,c.salesItem()));
        qty("10000",db.queryForObject("""
                SELECT COALESCE(planned_qty,0) FROM sales_order_items WHERE id=?
                """,BigDecimal.class,c.salesItem()));
        // 分析任务的需求侧仍只记 10000（不是 13000）——超产的 3000 走公共备货，
        // 不占需求账。本例 approveNow=true，计划一审核 trg_sync_material_analysis_plan_lifecycle
        // 就把 link 翻成 APPROVED，数量从 items.submitted_qty 移进 approved_qty，
        // 所以这里对账的是两者之和（只看 submitted 会在审核后恒为 0）。
        AnalysisView after=analyses.detail(c.analysis());
        ProductView top2=product(after,top.analysisLineId());
        qty("10000",top2.submittedQty().add(top2.approvedQty()));
    }

    /**
     * 2026-09-15 修复回归：单计划超量（V588 形态）在「超量 > 需求」时曾把
     * `销售订单剩余可排数量` 算成负数——审核前的二次校验把整张草稿（含公共
     * 备货 4000）都当成销售容量占用，available = 需求 − 超量 = 1000 − 4000。
     * 修复后 draft 口径只记 link 的归需求量；本例需求 1000 实下 5000（用户
     * 实测形态）必须整链成功。
     */
    @Test void salesTopOverQuantityLargerThanDemandStillIssuesSinglePlan(){
        Case c=create("sales-top-over3",false,true,"1000");
        AnalysisView view=analyses.detail(c.analysis());
        ProductView top=view.products().stream().filter(p->p.salesOrderItemId()!=null).findFirst().orElseThrow();
        var result=commands.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(
                view.version(),view.fingerprint(),"issue-"+c.analysis()+"-over3",
                c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,top.analysisLineId(),
                        new BigDecimal("5000"),null,null,null,null,null,null,null))));
        assertEquals(1,result.plans().size());
        var links=db.queryForList("SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links WHERE analysis_id=?",c.analysis());
        assertEquals(1,links.size());
        qty("1000",(BigDecimal)links.get(0).get("submitted_qty"));
        qty("4000",(BigDecimal)links.get(0).get("public_surplus_qty"));
        // 公共备货 4000 不得进订单排产量
        qty("1000",db.queryForObject("""
                SELECT COALESCE(planned_qty,0) FROM sales_order_items WHERE id=?
                """,BigDecimal.class,c.salesItem()));
    }
    private record Case(FullChainEndToEndTest.World world,UUID analysis,UUID root,String sourceRef,List<UUID> materials,
                        UUID planner,UUID salesOrder,UUID salesItem,UUID salesActor,UUID financeActor){}
}
