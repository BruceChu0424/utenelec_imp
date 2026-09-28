package com.uten.imp.businesschain;

import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import com.uten.imp.features.production.execution.ProductionExecutionBatch;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.ProductionExecutionWorkbenchSegment;
import com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService;
import com.uten.imp.features.production.execution.SegmentAssignmentRequest;
import com.uten.imp.features.production.execution.SegmentRouteConfirmRequest;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.Configure;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.Detail;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.Material;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.Request;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.RequestedMaterial;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryService;
import com.uten.imp.features.production.mrp.CompleteKitAllocator;
import com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest;
import com.uten.imp.features.production.mrp.ProductionExecutionBatchService;
import com.uten.imp.features.production.mrp.ProductionExecutionPlanningService;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.quality.ProductionFqcReplenishmentMaterialService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialChoiceController;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ChooseRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MaterialChangeRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodicRowView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SegmentMaterials;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialSettingsService;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.AfterEach;
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
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-131 生产执行侧 (包 S4): 下达时期间边只让零料原因变成「车间内料仓供料」、不建按单需求; 期间边的执行指纹
 * 只计用哪种料 (改单个重量不让按单段拆批报「BOM 已变化」); 工作台的用料状态、「要不要过开工确认表」与开工门
 * 一致 (待认料的行能进开工确认表, 认完料才开得了工); 领料发现不许登记整批领料的料, 认料勾了「还要按工单领别的料」
 * 的产品领料发现门保留; FQC 报废补产只用内料仓的料时不建补产轮次、任务直接就绪, 返工补产不计理论用量。
 *
 * <p>全部走真实服务与真实库 (V740 的状态函数、开工触发器、绑定触发器), 按真实账号切换: 仓库 (开启车间整批领料)、
 * 车间 (开工、认料)、没有认料权限的车间员工、超管 (下达、报工、品质)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WorkshopMaterialStartGatePostgresTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionPlanningService planning;
    @Autowired ProductionPlanningPackageService packages;
    @Autowired ProductionExecutionBatchService batches;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionExecutionWorkbenchService workbench;
    @Autowired ProductionMaterialDiscoveryService discovery;
    @Autowired ProductionDailyReportService reports;
    @Autowired ReportablePlanLineQueryService reportable;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired ProductionFqcReplenishmentMaterialService replenishment;
    @Autowired StockDocService stock;
    @Autowired WorkshopMaterialSettingsService settings;
    @Autowired WorkshopMaterialChoiceController choices;
    @Autowired WorkshopMaterialChoicePort choicePort;
    FullChainEndToEndTest fixture;

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    /**
     * 一个车间 (生产部下) 与它的负责人; 一种整批领料的颗粒 (千克, 主料); 仓库账号 (开启整批领料);
     * 车间账号 (开工、认料); 同车间只能开工、不能认料的员工。
     */
    private record Shop(FullChainEndToEndTest.World world, UUID workshop, UUID worker, UUID kg, UUID granule,
                        UUID setupUser, UUID workshopUser, UUID starterOnly) {}

    private record Released(UUID plan, UUID segment) {}

    // =============================================================================================
    // 下达: 零料原因与按单需求
    // =============================================================================================

    @Test
    void releaseFreezesPeriodicMaterialReasonAndDemandsOnlyForOrderEdges() {
        Shop shop = shop("release");
        UUID periodicOnly = product(shop, "只有塑料的注塑件");
        periodicEdge(periodicOnly, shop.granule(), "0.0125");
        Released first = release(shop, periodicOnly, "20");

        Map<String, Object> zero = db.queryForMap("""
                SELECT status, material_requirement_mode, zero_material_reason, zero_material_analysis_id
                FROM production_execution_segments WHERE id = ?""", first.segment());
        assertEquals("READY", zero.get("status"));
        assertEquals("ZERO_MATERIAL", zero.get("material_requirement_mode"));
        assertEquals(ProductionExecutionSegment.ZERO_MATERIAL_REASON_PERIODIC_MATERIAL, zero.get("zero_material_reason"));
        assertNull(zero.get("zero_material_analysis_id"), "车间内料仓供料的证据只在 BOM 上, 不带分析");
        assertEquals(0, count("SELECT count(*) FROM production_material_demands WHERE plan_id = ?", first.plan()));
        CompleteKitAllocator.ProductLine zeroLine = productLine(first.plan(), shop.world().warehouseId(), periodicOnly);
        assertTrue(zeroLine.materials().isEmpty());
        assertEquals(ProductionExecutionSegment.ZERO_MATERIAL_REASON_PERIODIC_MATERIAL, zeroLine.zeroMaterialReason());

        UUID insertMoulded = product(shop, "带铜件的注塑件");
        UUID copper = purchased(shop, "铜片");
        fixture.insertBom(insertMoulded, copper, "2");
        periodicEdge(insertMoulded, shop.granule(), "0.0080");
        Released second = release(shop, insertMoulded, "10");

        assertEquals("DEMANDED", db.queryForObject(
                "SELECT material_requirement_mode FROM production_execution_segments WHERE id = ?",
                String.class, second.segment()));
        assertEquals(List.of(copper), db.queryForList("""
                SELECT goods_id FROM production_material_demands
                WHERE execution_segment_id = ? AND NOT is_deleted""", UUID.class, second.segment()),
                "按单边 + 期间边: 只为按单边建需求");
        assertEquals(0, count("""
                SELECT count(*) FROM production_material_demands demand JOIN goods ON goods.id = demand.goods_id
                WHERE demand.plan_id IN (?, ?) AND goods.issue_method = 'PERIODIC'""", first.plan(), second.plan()));

        // 执行指纹: 改单个重量不变 (冻结的段指纹仍对得上), 改按单边的用量就变。
        String frozen = db.queryForObject("SELECT bom_fingerprint FROM production_execution_segments WHERE id = ?",
                String.class, second.segment());
        String before = productLine(second.plan(), shop.world().warehouseId(), insertMoulded).bomFingerprint();
        assertTrue(before.equalsIgnoreCase(frozen));
        db.update("UPDATE goods_bom_items SET qty = 0.0095 WHERE goods_id = ? AND component_goods_id = ?",
                insertMoulded, shop.granule());
        assertEquals(before, productLine(second.plan(), shop.world().warehouseId(), insertMoulded).bomFingerprint(),
                "改塑料单个重量不影响任何需求, 执行快照不能过期");
        db.update("UPDATE goods_bom_items SET qty = 3 WHERE goods_id = ? AND component_goods_id = ?",
                insertMoulded, copper);
        assertNotEquals(before, productLine(second.plan(), shop.world().warehouseId(), insertMoulded).bomFingerprint());
    }

    @Test
    void unitWeightChangeDoesNotStaleADemandedSegmentButAnOrderEdgeChangeDoes() {
        Shop shop = shop("split");
        UUID product = product(shop, "分批注塑件");
        UUID copper = purchased(shop, "分批铜片");
        fixture.insertBom(product, copper, "2");
        periodicEdge(product, shop.granule(), "0.0125");
        Released released = release(shop, product, "100");
        assertEquals("DEMANDED", db.queryForObject(
                "SELECT material_requirement_mode FROM production_execution_segments WHERE id = ?",
                String.class, released.segment()), "拆批只对按单需求的段比指纹, 用零料段测会假绿");

        fixture.loginAs(shop.world().superAdminUserId());
        segments.confirmRoute(released.plan(), released.segment(), new SegmentRouteConfirmRequest(
                version(released.segment()), key("route"), "BATCH"));
        receive(shop, copper, "20");

        fixture.loginAs(shop.workshopUser());
        var first = batches.preview(new ProductionExecutionBatch.PreviewRequest(
                released.segment(), version(released.segment()), null));
        money("10", first.maxReadyQty());

        db.update("UPDATE goods_bom_items SET qty = 0.0131 WHERE goods_id = ? AND component_goods_id = ?",
                product, shop.granule());
        var afterWeight = batches.preview(new ProductionExecutionBatch.PreviewRequest(
                released.segment(), version(released.segment()), null));
        money("10", afterWeight.maxReadyQty());
        var batch = batches.submit(new ProductionExecutionBatch.SubmitRequest(released.segment(),
                afterWeight.expectedVersion(), afterWeight.quantity(), afterWeight.fingerprint(), key("split")));
        assertNotNull(batch.batchSegmentId());
        assertNotNull(batch.remainingSegmentId());
        assertEquals(0, count("""
                SELECT count(*) FROM production_material_demands demand JOIN goods ON goods.id = demand.goods_id
                WHERE demand.plan_id = ? AND goods.issue_method = 'PERIODIC'""", released.plan()));

        // 对照: 改按单边用量后, 剩余段按当前 BOM 改算会被拒, 证明指纹比对仍在起作用。
        db.update("UPDATE goods_bom_items SET qty = 3 WHERE goods_id = ? AND component_goods_id = ?", product, copper);
        UUID remaining = batch.remainingSegmentId();
        ApiException stale = assertThrows(ApiException.class, () -> batches.preview(
                new ProductionExecutionBatch.PreviewRequest(remaining, version(remaining), null)));
        assertTrue(stale.getMessage().contains("BOM已变化"), stale.getMessage());
    }

    // =============================================================================================
    // 开工门与工作台
    // =============================================================================================

    @Test
    void needBinBlocksStartUntilTheWorkshopIsEnabledThenStartBindsTheBomWeight() {
        Shop shop = shop("need-bin");
        UUID product = product(shop, "要内料仓的注塑件");
        periodicEdge(product, shop.granule(), "0.0125");
        Released released = release(shop, product, "20");
        assertEquals("NEED_BIN", state(released.segment()));

        fixture.loginAs(shop.workshopUser());
        ProductionExecutionWorkbenchSegment blocked = task(shop, released.segment(), "PREPARING");
        assertEquals("NEED_BIN", blocked.binMaterialState());
        assertFalse(blocked.canStart(), "车间没开启整批领料, 开工就绪排除这种段");
        assertFalse(blocked.needsStartConfirmation(), "开工确认表也解决不了, 不进确认表");
        assertFalse(blocked.allowedActions().contains("CHOOSE"));
        assertFalse(bool("SELECT fn_execution_start_material_ready(?)", released.segment()));
        ApiException refused = assertThrows(ApiException.class, () -> segments.start(released.plan(),
                released.segment(), new SegmentTransitionRequest(version(released.segment()), key("start-refused"))));
        assertEquals(ErrorCode.CONFLICT, refused.getCode());
        assertTrue(refused.getMessage().contains("还没有开启整批领料"), refused.getMessage());
        assertEquals("READY", status(released.segment()));

        UUID bin = enable(shop);
        assertEquals("KNOWN", state(released.segment()));
        fixture.loginAs(shop.workshopUser());
        ProductionExecutionWorkbenchSegment ready = task(shop, released.segment(), "PREPARING");
        assertEquals("KNOWN", ready.binMaterialState());
        assertTrue(ready.canStart());
        assertFalse(ready.needsStartConfirmation(), "有期间边、路线已定: 直接开工");
        segments.start(released.plan(), released.segment(),
                new SegmentTransitionRequest(version(released.segment()), key("start")));
        assertEquals("IN_PROGRESS", status(released.segment()));

        UUID edge = db.queryForObject("""
                SELECT id FROM goods_bom_items WHERE goods_id = ? AND component_goods_id = ? AND NOT is_deleted""",
                UUID.class, product, shop.granule());
        Map<String, Object> row = db.queryForMap("""
                SELECT origin, bom_item_id, design_qty_snapshot, effective_from, effective_to, bin_warehouse_id,
                       material_goods_id, unit_id
                FROM production_execution_periodic_materials WHERE execution_segment_id = ?""", released.segment());
        assertEquals("BOM", row.get("origin"));
        assertEquals(edge, row.get("bom_item_id"));
        money("0.0125", (BigDecimal) row.get("design_qty_snapshot"));
        assertEquals(BusinessTime.today(), ((java.sql.Date) row.get("effective_from")).toLocalDate(),
                "起始日 = 启用日 (没有已结算的期间), 不是开工时钟");
        assertNull(row.get("effective_to"));
        assertEquals(bin, row.get("bin_warehouse_id"));
        assertEquals(shop.granule(), row.get("material_goods_id"));
        assertEquals(shop.kg(), row.get("unit_id"));

        ProductionExecutionWorkbenchSegment running = task(shop, released.segment(), "IN_PROGRESS");
        assertEquals("KNOWN", running.binMaterialState());
        assertTrue(running.allowedActions().contains("CHANGE_MATERIAL"));
        fixture.loginAs(shop.starterOnly());
        assertTrue(task(shop, released.segment(), "IN_PROGRESS").allowedActions().isEmpty(),
                "没有认料与换料权限的员工看不到「改用别的料」");
    }

    @Test
    void needChoiceRowCanEnterStartConfirmationAndStartsOnlyAfterChoosing() {
        Shop shop = shop("need-choice");
        UUID product = product(shop, "只有包装边的产品");
        fixture.insertBom(product, shop.world().goodsD(), "1");
        db.update("UPDATE goods_bom_items SET control_stage = 'SHIP', hard_gate = FALSE WHERE goods_id = ?", product);
        Released released = legacyRelease(shop, product, "10");
        assertEquals("NO_BIN", state(released.segment()));

        fixture.loginAs(shop.workshopUser());
        ProductionExecutionWorkbenchSegment before = task(shop, released.segment(), "PREPARING");
        assertEquals("NO_BIN", before.binMaterialState());
        assertTrue(before.canStart());
        assertFalse(before.needsStartConfirmation(), "没开启整批领料、路线已定: 原样直接开工");

        enable(shop);
        assertEquals("NEED_CHOICE", state(released.segment()));
        fixture.loginAs(shop.workshopUser());
        ProductionExecutionWorkbenchSegment pending = task(shop, released.segment(), "PREPARING");
        assertEquals("NEED_CHOICE", pending.binMaterialState());
        assertTrue(pending.canStart(), "开工就绪不排除待认料, 否则进不了开工确认表");
        assertTrue(pending.needsStartConfirmation());
        assertTrue(pending.allowedActions().contains("CHOOSE"));
        assertTrue(inBucket(shop, released.segment(), "WAITING_MATERIAL"), "待认料归「等待物料」");
        assertFalse(inBucket(shop, released.segment(), "DRAW_NOT_REQUESTED"), "去领料桶排除待认料");
        assertFalse(inBucket(shop, released.segment(), "READY_TO_START"));
        fixture.loginAs(shop.starterOnly());
        assertFalse(task(shop, released.segment(), "PREPARING").allowedActions().contains("CHOOSE"));

        fixture.loginAs(shop.workshopUser());
        ApiException refused = assertThrows(ApiException.class, () -> segments.start(released.plan(),
                released.segment(), new SegmentTransitionRequest(version(released.segment()), key("start-refused"))));
        assertEquals(ErrorCode.CONFLICT, refused.getCode());
        assertTrue(refused.getMessage().contains("开工确认表"), refused.getMessage());
        assertEquals("READY", status(released.segment()));

        List<WorkshopMaterialChoicePort.PendingChoice> sheet = choicePort.pending(List.of(released.segment()));
        assertEquals(1, sheet.size());
        assertTrue(sheet.getFirst().choiceRequired());
        assertEquals(List.of(released.segment()), sheet.getFirst().segmentIds());
        assertFalse(sheet.getFirst().alsoOrderMaterialsAllowed(), "有 BOM 的产品按 BOM 领, 不能勾");

        choose(shop, product, false);
        assertEquals("KNOWN", state(released.segment()));
        ProductionExecutionWorkbenchSegment chosen = task(shop, released.segment(), "PREPARING");
        assertFalse(chosen.needsStartConfirmation());
        assertTrue(chosen.canStart());
        assertTrue(inBucket(shop, released.segment(), "READY_TO_START"));
        segments.start(released.plan(), released.segment(),
                new SegmentTransitionRequest(version(released.segment()), key("start")));
        assertEquals("IN_PROGRESS", status(released.segment()));

        Map<String, Object> row = db.queryForMap("""
                SELECT material_row.origin, material_row.material_goods_id, material_row.effective_from,
                       material_row.choice_id = choice.id AS from_active_choice
                FROM production_execution_periodic_materials material_row
                JOIN goods_periodic_material_choices choice
                  ON choice.product_goods_id = ? AND choice.superseded_at IS NULL
                WHERE material_row.execution_segment_id = ?""", product, released.segment());
        assertEquals("CHOICE", row.get("origin"));
        assertEquals(shop.granule(), row.get("material_goods_id"));
        assertEquals(Boolean.TRUE, row.get("from_active_choice"));
        assertEquals(BusinessTime.today(), ((java.sql.Date) row.get("effective_from")).toLocalDate());
    }

    // =============================================================================================
    // 领料发现
    // =============================================================================================

    @Test
    void materialDiscoveryRejectsPeriodicGoodsAndAlsoOrderKeepsTheGate() {
        Shop shop = shop("discovery");
        enable(shop);
        UUID insertPart = product(shop, "嵌件注塑件");
        UUID plainPart = product(shop, "普通注塑件");
        Released inserted = release(shop, insertPart, "10");
        Released plain = release(shop, plainPart, "10");
        for (Released released : List.of(inserted, plain)) {
            assertEquals(ProductionExecutionSegment.ZERO_MATERIAL_REASON_DIRECT_MAKE, db.queryForObject(
                    "SELECT zero_material_reason FROM production_execution_segments WHERE id = ?",
                    String.class, released.segment()));
            assertEquals("NEED_CHOICE", state(released.segment()));
            assertTrue(bool("SELECT fn_material_discovery_pending(?)", released.segment()));
        }
        fixture.loginAs(shop.workshopUser());
        ProductionExecutionWorkbenchSegment waiting = task(shop, inserted.segment(), "PREPARING");
        assertEquals("NEED_CHOICE", waiting.binMaterialState());
        assertTrue(waiting.needsStartConfirmation(), "待认料的零料件也能进开工确认表");
        assertFalse(waiting.canStart(), "没认料前领料发现门仍在");
        assertTrue(waiting.materialDiscoveryRequired());

        // 车间申请领料时不能点名整批领料的料。
        fixture.loginAs(shop.world().superAdminUserId());
        ApiException periodicSuggestion = assertThrows(ApiException.class, () -> discovery.request(inserted.segment(),
                new Request(version(inserted.segment()), key("periodic-suggestion"),
                        List.of(new RequestedMaterial(shop.granule(), null, shop.kg(), null)))));
        assertTrue(periodicSuggestion.getMessage().contains("已整批放在车间内料仓"), periodicSuggestion.getMessage());
        assertEquals(0, count("SELECT count(*) FROM production_material_discovery_requests WHERE execution_segment_id = ?",
                inserted.segment()));

        // 勾了「还要按工单领别的料」: 用料已知, 但领料发现门保留, 只能登记非整批领料的料。
        choose(shop, insertPart, true);
        assertEquals("KNOWN", state(inserted.segment()));
        assertFalse(bool("SELECT fn_segment_bin_discovery_released(?)", inserted.segment()));
        assertTrue(bool("SELECT fn_material_discovery_pending(?)", inserted.segment()));
        fixture.loginAs(shop.workshopUser());
        ApiException early = assertThrows(ApiException.class, () -> segments.start(inserted.plan(),
                inserted.segment(), new SegmentTransitionRequest(version(inserted.segment()), key("early-start"))));
        assertTrue(early.getMessage().contains("请先提交领料"), early.getMessage());

        fixture.loginAs(shop.world().superAdminUserId());
        Detail requested = discovery.request(inserted.segment(),
                new Request(version(inserted.segment()), key("discovery-request")));
        assertEquals("PENDING", requested.status());
        receive(shop, shop.world().goodsD(), "30");
        ApiException periodicLine = assertThrows(ApiException.class, () -> discovery.configure(requested.requestId(),
                new Configure(requested.version(), key("configure-periodic"), List.of(new Material(
                        shop.granule(), null, shop.kg(), shop.world().warehouseId(), new BigDecimal("5"))))));
        assertTrue(periodicLine.getMessage().contains("已整批放在车间内料仓"), periodicLine.getMessage());
        Detail configured = discovery.configure(requested.requestId(), new Configure(requested.version(),
                key("configure-insert"), List.of(new Material(shop.world().goodsD(), null, shop.world().unitId(),
                        shop.world().warehouseId(), new BigDecimal("20")))));
        assertEquals("CONFIGURED", configured.status());
        assertEquals(List.of(shop.world().goodsD()), db.queryForList("""
                SELECT goods_id FROM production_material_demands WHERE execution_segment_id = ? AND NOT is_deleted""",
                UUID.class, inserted.segment()), "嵌件按工单领, 颗粒不建按单需求");
        for (UUID draw : configured.drawDocIds()) {
            issueAll(draw);
        }
        fixture.loginAs(shop.workshopUser());
        segments.start(inserted.plan(), inserted.segment(),
                new SegmentTransitionRequest(version(inserted.segment()), key("insert-start")));
        assertEquals("IN_PROGRESS", status(inserted.segment()));
        assertEquals("CHOICE", db.queryForObject("""
                SELECT origin FROM production_execution_periodic_materials
                WHERE execution_segment_id = ? AND material_goods_id = ?""", String.class,
                inserted.segment(), shop.granule()), "颗粒照样进内料仓期间理论");

        // 没勾「还要按工单领别的料」: 认完料领料发现门解除, 直接开工。
        choose(shop, plainPart, false);
        assertTrue(bool("SELECT fn_segment_bin_discovery_released(?)", plain.segment()));
        assertFalse(bool("SELECT fn_material_discovery_pending(?)", plain.segment()));
        fixture.loginAs(shop.workshopUser());
        ProductionExecutionWorkbenchSegment released = task(shop, plain.segment(), "PREPARING");
        assertFalse(released.materialDiscoveryRequired());
        assertTrue(released.canStart());
        assertFalse(released.needsStartConfirmation());
        segments.start(plain.plan(), plain.segment(),
                new SegmentTransitionRequest(version(plain.segment()), key("plain-start")));
        assertEquals("IN_PROGRESS", status(plain.segment()));
        assertEquals(0, count("SELECT count(*) FROM production_material_demands WHERE execution_segment_id = ?",
                plain.segment()));
    }

    // =============================================================================================
    // FQC 补产
    // =============================================================================================

    @Test
    void fqcScrapReplenishmentSkipsTheCycleAndReworkAddsNoTheory() {
        Shop shop = shop("fqc");
        UUID bin = enable(shop);
        UUID product = product(shop, "品质补产注塑件");
        periodicEdge(product, shop.granule(), "0.0125");
        // 计划量 = 两张正常报工之和: 品质补产行只在工单报满之后才出现在可报工来源里。
        Released released = release(shop, product, "20");
        fixture.loginAs(shop.workshopUser());
        segments.start(released.plan(), released.segment(),
                new SegmentTransitionRequest(version(released.segment()), key("fqc-start")));

        fixture.loginAs(shop.world().superAdminUserId());
        UUID scrapReport = approveReport(shop, product, source(shop, released.segment(), null), "10");
        UUID scrapInspection = inspect(shop, scrapReport);
        quality.decide(scrapInspection, new DecisionRequest("PARTIAL", new BigDecimal("7"), new BigDecimal("3"),
                "SCRAP", "三件报废, 需要补产", key("scrap")));
        confirmReceipt(scrapReport);
        UUID reworkReport = approveReport(shop, product, source(shop, released.segment(), null), "10");
        UUID reworkInspection = inspect(shop, reworkReport);
        quality.decide(reworkInspection, new DecisionRequest("PARTIAL", new BigDecimal("8"), new BigDecimal("2"),
                "REWORK", "两件返工", key("rework")));
        confirmReceipt(reworkReport);

        UUID scrap = db.queryForObject(
                "SELECT id FROM production_fqc_recovery_authorizations WHERE source_inspection_id = ?",
                UUID.class, scrapInspection);
        UUID rework = db.queryForObject(
                "SELECT id FROM production_fqc_recovery_authorizations WHERE source_inspection_id = ?",
                UUID.class, reworkInspection);
        assertTrue(bool("SELECT fn_fqc_replenishment_periodic_only(?)", scrap));
        assertTrue(bool("SELECT fn_fqc_replenishment_material_ready(?)", scrap));
        assertFalse(bool("SELECT fn_fqc_replenishment_periodic_only(?)", rework), "返工不是补产");

        assertEquals("READY", replenishment.detail(scrap).status(), "补产只用内料仓的料: 任务直接就绪");
        var confirmed = replenishment.confirm(scrap,
                new ProductionFqcReplenishmentMaterialService.ConfirmRequest(key("fqc-confirm")));
        assertEquals("READY", confirmed.status());
        assertNull(confirmed.cycleId());
        assertEquals(0, count("SELECT count(*) FROM production_fqc_replenishment_cycles WHERE authorization_id = ?",
                scrap), "不建补产轮次");
        assertEquals(0, count("SELECT count(*) FROM production_material_demands WHERE fqc_recovery_authorization_id = ?",
                scrap));

        // 同一销售分配一次只给一条补产来源, 返工排在前面: 先报返工, 再报报废补产。
        UUID reworkRecovery = approveReport(shop, product, source(shop, released.segment(), rework), "2");
        UUID scrapRecovery = approveReport(shop, product, source(shop, released.segment(), scrap), "3");
        UUID scrapRecoveryItem = firstItem(scrapRecovery);
        UUID reworkRecoveryItem = firstItem(reworkRecovery);
        money("10", decimal("SELECT fn_report_item_material_output_qty(?)", firstItem(scrapReport)));
        money("3", decimal("SELECT fn_report_item_material_output_qty(?)", scrapRecoveryItem));
        money("0", decimal("SELECT fn_report_item_material_output_qty(?)", reworkRecoveryItem));

        LocalDate today = BusinessTime.today();
        Map<String, Object> theory = db.queryForMap("""
                SELECT COALESCE(sum(theory.output_qty_base), 0) AS output_qty,
                       COALESCE(sum(theory.theory_qty), 0) AS theory_qty,
                       count(*) FILTER (WHERE theory.unit_weight IS NULL) AS missing_weight
                FROM fn_workshop_material_period_theory(?, CAST(? AS date), CAST(? AS date)) theory
                WHERE theory.execution_segment_id = ?""", bin, java.sql.Date.valueOf(today),
                java.sql.Date.valueOf(today), released.segment());
        money("23", (BigDecimal) theory.get("output_qty"));
        money("0.2875", (BigDecimal) theory.get("theory_qty"));
        assertEquals(0L, ((Number) theory.get("missing_weight")).longValue());
    }

    // =============================================================================================
    // 换料对话框: 读底稿 (现用的料、可换的料、最早从哪天起改) 与从某天起改用别的料
    // =============================================================================================

    @Test
    void changeMaterialDialogReadsTheSegmentRowsAndChangesFromAGivenDay() {
        Shop shop = shop("change");
        UUID product = product(shop, "换料注塑件");
        periodicEdge(product, shop.granule(), "0.0125");
        Released released = release(shop, product, "20");
        UUID bin = enable(shop);
        UUID other = UUID.randomUUID();
        int legacy = db.queryForObject("SELECT legacy_id FROM units WHERE id=?", Integer.class, shop.kg());
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence,
                                  issue_method,periodic_cost_basis,bulk_package_qty,min_qty)
                VALUES (?,?,?,'采购','使用',?,?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),
                        'PERIODIC','OWN',25,0)""",
                other, "WMG-" + other.toString().substring(0, 8), "新颗粒-" + other.toString().substring(0, 4),
                shop.kg(), legacy);
        fixture.loginAs(shop.workshopUser());
        segments.start(released.plan(), released.segment(),
                new SegmentTransitionRequest(version(released.segment()), key("start")));
        assertEquals("IN_PROGRESS", status(released.segment()));

        SegmentMaterials before = choices.segmentMaterials(released.segment());
        assertEquals(released.segment(), before.segmentId());
        assertEquals(bin, before.binWarehouseId());
        assertEquals(version(released.segment()), before.lockVersion());
        assertEquals(BusinessTime.today(), before.earliestEffectiveFrom(), "还没结算过: 最早从启用日起");
        assertEquals(1, before.rows().size());
        PeriodicRowView bound = before.rows().getFirst();
        assertEquals(shop.granule(), bound.materialGoodsId());
        assertEquals("BOM", bound.origin());
        assertNull(bound.effectiveTo());
        money("12.5", bound.unitWeightGrams());
        assertFalse(before.options().isEmpty());
        assertTrue(before.options().stream().allMatch(option -> Boolean.TRUE.equals(db.queryForObject(
                "SELECT issue_method = 'PERIODIC' AND periodic_cost_basis = 'OWN' FROM goods WHERE id = ?",
                Boolean.class, option.goodsId()))), "只列整批领料的主料");

        SegmentMaterials after = choices.changeMaterial(released.segment(), new MaterialChangeRequest(
                before.lockVersion(), bound.id(), other, null, BusinessTime.today(), "FROM_REPLACED", "换成新颗粒",
                key("change")));
        assertEquals(2, after.rows().size());
        PeriodicRowView ended = after.rows().stream().filter(row -> row.id().equals(bound.id())).findFirst()
                .orElseThrow();
        assertEquals(BusinessTime.today().minusDays(1), ended.effectiveTo(), "原来的料用到前一天");
        PeriodicRowView changed = after.rows().stream().filter(row -> row.materialGoodsId().equals(other))
                .findFirst().orElseThrow();
        assertEquals("CHANGE", changed.origin());
        assertEquals(BusinessTime.today(), changed.effectiveFrom());
        assertNull(changed.effectiveTo());
        money("12.5", changed.unitWeightGrams());
        assertEquals(version(released.segment()), after.lockVersion());
        assertEquals(2, choices.segmentMaterials(released.segment()).rows().size());

        // 没有换料权限的员工能看底稿, 改不了
        fixture.loginAs(shop.starterOnly());
        assertEquals(2, choices.segmentMaterials(released.segment()).rows().size());
        assertThrows(org.springframework.security.access.AccessDeniedException.class,
                () -> choices.changeMaterial(released.segment(), new MaterialChangeRequest(
                        version(released.segment()), changed.id(), shop.granule(), null, BusinessTime.today(),
                        "FROM_REPLACED", null, key("change-denied"))));

        // 对象范围: 别的车间的人看不到这张工单用的料
        Object otherAssignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment",
                "wm-other-" + UUID.randomUUID().toString().substring(0, 8));
        UUID otherWorkshop = ReflectionTestUtils.invokeMethod(otherAssignment, "workshopId");
        UUID outsider = fixture.createUserWithPerms(shop.world(), "out-" + UUID.randomUUID().toString().substring(0, 8),
                "notice:read", "workshop_material:view", "workshop_material:choose");
        db.update("UPDATE employees SET department_id = ? WHERE id = (SELECT employee_id FROM users WHERE id = ?)",
                otherWorkshop, outsider);
        fixture.loginAs(outsider);
        ApiException foreign = assertThrows(ApiException.class, () -> choices.segmentMaterials(released.segment()));
        assertEquals(ErrorCode.FORBIDDEN, foreign.getCode());
    }

    // =============================================================================================
    // 夹具
    // =============================================================================================

    private Shop shop(String tag) {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        String unique = tag + "-" + UUID.randomUUID().toString().substring(0, 8);
        var world = fixture.seedWorld("wm-start-" + unique);
        fixture.loginAs(world.superAdminUserId());
        Object assignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment", "wm-start-" + unique);
        UUID workshop = ReflectionTestUtils.invokeMethod(assignment, "workshopId");
        UUID worker = ReflectionTestUtils.invokeMethod(assignment, "workerId");
        UUID kg = UUID.randomUUID();
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES (?,?,?,'千克','使用')",
                kg, 900_000_000 + ThreadLocalRandom.current().nextInt(90_000_000), "KG-" + unique);
        db.update("""
                INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,canonical_unit_id,to_canonical_factor,provenance)
                VALUES (?,'MASS',?,1,'MANUAL_GOVERNANCE')""", kg, kg);
        UUID granule = UUID.randomUUID();
        int legacy = db.queryForObject("SELECT legacy_id FROM units WHERE id=?", Integer.class, kg);
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence,
                                  issue_method,periodic_cost_basis,bulk_package_qty,min_qty)
                VALUES (?,?,?,'采购','使用',?,?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),
                        'PERIODIC','OWN',25,0)""",
                granule, "WMG-" + granule.toString().substring(0, 8), "颗粒-" + granule.toString().substring(0, 4),
                kg, legacy);
        UUID setupUser = fixture.createUserWithPerms(world, "wm-setup-" + unique, "notice:read",
                "workshop_material:view", "workshop_material:setup");
        db.update("INSERT INTO warehouse_keepers(warehouse_id, employee_id) SELECT ?, employee_id FROM users WHERE id = ?",
                world.warehouseId(), setupUser);
        UUID workshopUser = fixture.createUserWithPerms(world, "wm-shop-" + unique, "notice:read",
                "production_execution:view", "production_execution:start",
                "workshop_material:view", "workshop_material:choose");
        UUID starterOnly = fixture.createUserWithPerms(world, "wm-starter-" + unique, "notice:read",
                "production_execution:view", "production_execution:start", "workshop_material:view");
        for (UUID user : List.of(workshopUser, starterOnly)) {
            db.update("UPDATE employees SET department_id = ? WHERE id = (SELECT employee_id FROM users WHERE id = ?)",
                    workshop, user);
        }
        // 车间挂在生产部下, 生产部默认授予认料与换料 (V740); 这位员工个人撤掉, 才是「只能开工、不能认料」。
        db.update("""
                INSERT INTO user_permission_overrides(user_id, permission_id, effect)
                SELECT ?, permission.id, 'revoke' FROM permissions permission
                WHERE permission.code = 'workshop_material:choose'""", starterOnly);
        fixture.loginAs(world.superAdminUserId());
        return new Shop(world, workshop, worker, kg, granule, setupUser, workshopUser, starterOnly);
    }

    private UUID product(Shop shop, String name) {
        UUID id = UUID.randomUUID();
        fixture.insertGoods(id, "WMP-" + id.toString().substring(0, 8), name + "-" + id.toString().substring(0, 4),
                "自制", shop.world().unitId(), shop.world().unitLegacy());
        return id;
    }

    private UUID purchased(Shop shop, String name) {
        UUID id = UUID.randomUUID();
        fixture.insertGoods(id, "WMM-" + id.toString().substring(0, 8), name + "-" + id.toString().substring(0, 4),
                "采购", shop.world().unitId(), shop.world().unitLegacy());
        return id;
    }

    /** 期间边: 只填单个重量 (公斤/件), 形状按 V740 守卫。 */
    private void periodicEdge(UUID product, UUID granule, String kilogramsPerPiece) {
        db.update("""
                INSERT INTO goods_bom_items(goods_id, component_goods_id, qty, hard_gate, control_stage,
                                            consumption_basis, basis_output_qty)
                VALUES (?, ?, ?, FALSE, 'START', 'PER_UNIT', 1)""",
                product, granule, new BigDecimal(kilogramsPerPiece));
    }

    /** 物料分析下达 (新流程): 产品走自制, 其余按单料走采购; 车间与负责人随下达确定。 */
    private Released release(Shop shop, UUID product, String qty) {
        fixture.loginAs(shop.world().superAdminUserId());
        UUID order = fixture.createApprovedOrder(shop.world(), product, qty, "100");
        UUID orderItem = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, order);
        String tag = UUID.randomUUID().toString().substring(0, 8);
        var view = analyses.preview(new PreviewRequest(null, null, null, shop.world().warehouseId(),
                "wm-start-preview-" + tag, List.of(new PreviewItem("SALES_ORDER_ITEM", orderItem, null, null, null,
                        null, null, BusinessTime.today().plusDays(10), new BigDecimal(qty)))));
        analyses.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(),
                "wm-start-routes-" + tag, view.flatMaterials().stream().filter(MaterialView::actionable)
                .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                        row.goodsId().equals(product) ? "MAKE" : "BUY", null)).toList()));
        view = analyses.detail(view.analysisId());
        var issued = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(view.version(),
                view.fingerprint(), "wm-start-issue-" + tag, shop.world().warehouseId(), BusinessTime.today(),
                BusinessTime.today().plusDays(10), true, List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        null, view.products().getFirst().analysisLineId(), new BigDecimal(qty), BusinessTime.today(),
                        BusinessTime.today().plusDays(10), shop.workshop(), null, shop.worker(), null, null))));
        UUID plan = issued.plans().getFirst().planId();
        UUID segment = issued.plans().getFirst().segmentIds().getFirst();
        return new Released(plan, segment);
    }

    /** 计划包确认下达 (与夹具零料段同一写法), 再把工单派给本车间与负责人。 */
    private Released legacyRelease(Shop shop, UUID product, String qty) {
        fixture.loginAs(shop.world().superAdminUserId());
        UUID plan = ReflectionTestUtils.invokeMethod(fixture, "approvedPlan", shop.world(), product, qty, qty);
        var preview = packages.preview(plan, shop.world().warehouseId());
        var generate = new GeneratePlanningPackageRequest();
        generate.setWarehouseId(shop.world().warehouseId());
        generate.setIdempotencyKey(key("package"));
        generate.setPreviewFingerprint(preview.fingerprint());
        generate.setGeneratePurchaseRequest(false);
        var result = packages.confirm(plan, generate);
        assertEquals(1, result.executionSegments().size());
        assertEquals(ProductionExecutionSegment.ZERO_MATERIAL_REASON_NO_PRODUCTION_HARD_GATE,
                result.executionSegments().getFirst().zeroMaterialReason());
        UUID segment = result.executionSegments().getFirst().segmentId();
        segments.assign(plan, segment, new SegmentAssignmentRequest(version(segment), key("assign"),
                shop.workshop(), null, shop.worker(), BusinessTime.today(), BusinessTime.today().plusDays(10)));
        return new Released(plan, segment);
    }

    /** 仓库账号开启车间整批领料 (内料仓挂在测试主仓下, 启用日今天)。返回内料仓。 */
    private UUID enable(Shop shop) {
        fixture.loginAs(shop.setupUser());
        var view = settings.update(shop.workshop(), new SettingsRequest(0L, true, shop.world().warehouseId(),
                BusinessTime.today(), List.of(), key("enable")));
        assertTrue(view.periodicEnabled());
        assertNotNull(view.binWarehouseId());
        fixture.loginAs(shop.world().superAdminUserId());
        return view.binWarehouseId();
    }

    /** 车间账号在开工确认表里认料 (颗粒)。 */
    private void choose(Shop shop, UUID product, boolean alsoOrderMaterials) {
        fixture.loginAs(shop.workshopUser());
        choices.choose(new ChooseRequest(shop.workshop(), List.of(new WorkshopMaterialChoicePort.ProductChoice(
                product, WorkshopMaterialChoicePort.KIND_MATERIAL,
                List.of(new WorkshopMaterialChoicePort.MaterialRef(shop.granule(), null)),
                alsoOrderMaterials, null)), key("choose")));
    }

    private ProductionExecutionWorkbenchSegment task(Shop shop, UUID segment, String status) {
        String code = db.queryForObject("SELECT segment_code FROM production_execution_segments WHERE id = ?",
                String.class, segment);
        return workbench.workshopTasks(1, 50, code, status, shop.workshop(), null, null).getItems().stream()
                .filter(row -> row.segmentId().equals(segment)).findFirst()
                .orElseThrow(() -> new AssertionError("车间任务列表里没有这张工单: " + code));
    }

    private boolean inBucket(Shop shop, UUID segment, String bucket) {
        return workbench.workshopTasks(1, 100, null, "PREPARING", shop.workshop(), null, null, bucket).getItems()
                .stream().anyMatch(row -> row.segmentId().equals(segment));
    }

    private CompleteKitAllocator.ProductLine productLine(UUID plan, UUID warehouse, UUID product) {
        return planning.preview(plan, warehouse).productLines().stream()
                .filter(line -> line.productGoodsId().equals(product)).findFirst().orElseThrow();
    }

    private ReportablePlanLine source(Shop shop, UUID segment, UUID recoveryAuthorization) {
        return reportable.list(1, 50, null, shop.workshop(), List.of(segment)).getItems().stream()
                .filter(row -> recoveryAuthorization == null
                        ? row.fqcRecoveryAuthorizationId() == null
                        : recoveryAuthorization.equals(row.fqcRecoveryAuthorizationId()))
                .findFirst().orElseThrow(() -> new AssertionError("没有可报工的来源行"));
    }

    private UUID approveReport(Shop shop, UUID product, ReportablePlanLine source, String qty) {
        var request = new DailyReportSaveRequest();
        request.setIdempotencyKey(key("report"));
        request.setBillDate(BusinessTime.today());
        request.setDepartmentId(shop.workshop());
        request.setWorkerIds(List.of(shop.worker()));
        var line = new DailyReportItemLine();
        line.setLineNo(1);
        line.setPlanItemId(source.planItemId());
        line.setExecutionSegmentId(source.executionSegmentId());
        line.setExecutionSegmentSalesAllocationId(source.executionSegmentSalesAllocationId());
        line.setSalesOrderItemId(source.orderItemId());
        line.setFqcRecoveryAuthorizationId(source.fqcRecoveryAuthorizationId());
        line.setGoodsId(product);
        line.setUnitId(shop.world().unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        request.setItems(List.of(line));
        return reports.approve(reports.create(request).getId(), DailyReportApproveRequests.freshKey()).getId();
    }

    private UUID inspect(Shop shop, UUID report) {
        UUID item = firstItem(report);
        arrivals.register(report, new ArrivalRegistrationRequest(key("arrival"), shop.world().warehouseId(),
                List.of(new ArrivalRegistrationItemRequest(item, "内料仓注塑件")), null));
        return db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id = ?",
                UUID.class, item);
    }

    private void confirmReceipt(UUID report) {
        UUID receipt = db.queryForObject("""
                SELECT doc_id FROM stock_document_items WHERE source_daily_report_item_id = ? AND NOT is_deleted""",
                UUID.class, firstItem(report));
        fixture.confirmFinishedInboundFully(receipt);
    }

    private UUID firstItem(UUID report) {
        return db.queryForObject("""
                SELECT id FROM production_daily_report_items WHERE report_id = ? AND NOT is_deleted
                ORDER BY line_no, id LIMIT 1""", UUID.class, report);
    }

    private void receive(Shop shop, UUID goods, String qty) {
        otherIn(shop, goods, shop.world().unitId(), qty);
    }

    private void otherIn(Shop shop, UUID goods, UUID unit, String qty) {
        fixture.loginAs(shop.world().superAdminUserId());
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setWarehouseId(shop.world().warehouseId());
        request.setBillDate(BusinessTime.today());
        var line = new StockDocItemLine();
        line.setGoodsId(goods);
        line.setUnitId(unit);
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(BigDecimal.TEN);
        line.setAmountOriginal(new BigDecimal(qty).multiply(BigDecimal.TEN));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        stock.approve(stock.create(request).getId());
    }

    private void issueAll(UUID draw) {
        var issue = new StockDocIssueRequest();
        issue.setIdempotencyKey(key("issue"));
        issue.setLines(db.query("SELECT id, qty FROM stock_document_items WHERE doc_id = ? AND NOT is_deleted",
                (rs, index) -> {
                    var line = new StockDocIssueRequest.Line();
                    line.setItemId(rs.getObject(1, UUID.class));
                    line.setQty(rs.getBigDecimal(2));
                    return line;
                }, draw));
        stock.approveAndIssue(draw, issue);
    }

    private String state(UUID segment) {
        return db.queryForObject("SELECT fn_segment_bin_material_state(?)", String.class, segment);
    }

    private String status(UUID segment) {
        return db.queryForObject("SELECT status FROM production_execution_segments WHERE id = ?", String.class, segment);
    }

    private long version(UUID segment) {
        return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id = ?",
                Long.class, segment);
    }

    private boolean bool(String sql, Object... args) {
        return Boolean.TRUE.equals(db.queryForObject(sql, Boolean.class, args));
    }

    private BigDecimal decimal(String sql, Object... args) {
        return db.queryForObject(sql, BigDecimal.class, args);
    }

    private int count(String sql, Object... args) {
        Integer value = db.queryForObject(sql, Integer.class, args);
        return value == null ? 0 : value;
    }

    private static String key(String tag) {
        return "wm-start-" + tag + "-" + UUID.randomUUID();
    }

    private static void money(String expected, BigDecimal actual) {
        assertNotNull(actual);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), () -> "expected " + expected + ", actual " + actual);
    }
}
