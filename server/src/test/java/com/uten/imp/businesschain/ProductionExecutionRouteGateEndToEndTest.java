package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.execution.ProductionExecutionBatch;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentRouteConfirmRequest;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.mrp.ProductionExecutionBatchService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest;
import static org.junit.jupiter.api.Assertions.*;

/**
 * 开工路线自动识别与到货进展通知(V599→V606 / ADR-091 批注)的用户口径回归：
 *
 * <ol>
 *   <li>路线在创建事务内按事实自动识别——「确认生产路线」步骤已删除：
 *       无同车间直送子件 → FULL_KIT；有 → CONTINUOUS；零料直制段恒 FULL_KIT；</li>
 *   <li>FULL_KIT 段到货即自动提升、开工/领料不再被任何确认门拦截；</li>
 *   <li>CONTINUOUS 段的竞态保持关闭：仓库料全到齐也保住 WAITING，
 *       「部分开工 · 持续生产」不再要求先确认路线(未动过同事务切路线)；</li>
 *   <li>「分批领料」动作驱动：不要求先确认 BATCH，拆批后批次段=FULL_KIT、剩余段=BATCH；</li>
 *   <li>路线冻结尺不变：动过(领料单/报工/预留)后不能改路线、不能切持续生产；
 *       手工改路线通道(confirmRoute)保留且同值幂等；</li>
 *   <li>真实写入库存的到货给还在等待的车间工单发「到货进展」聚合卡(经 outbox 投递)。</li>
 * </ol>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionExecutionRouteGateEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionExecutionBatchService batches;
    @Autowired ChainNoticeService chainNotices;
    @Autowired StockDocService stock;
    FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
    }

    @Test
    void fullKitRootIsAutoIdentifiedPromotesAndStartsWithoutAnyConfirmation() {
        // 不下达子件计划：根段没有同车间直送子件 → 自动识别为 FULL_KIT。
        Case c = create("rg-kit", false);
        fixture.loginAs(c.workerUser());
        assertEquals("FULL_KIT", route(c.segment()), "纯仓库供料段创建即自动识别为齐套路线");
        assertNotNull(db.queryForObject(
                "SELECT route_confirmed_at FROM production_execution_segments WHERE id=?",
                java.sql.Timestamp.class, c.segment()), "识别时间随创建事务落库");
        assertTrue(allowsAutoPromote(c.segment()), "FULL_KIT 放行自动提升");

        // 料到齐 → 自动提升建领料单 → 直接开工：全程没有 confirmRoute。
        receive(c, c.material(), c.leaf(), "100");
        assertEquals("READY", status(c.segment()), "到货即自动提升，不再等人工确认");
        assertTrue(drawCount(c.segment()) >= 1, "提升就建领料单");
        var started = segments.start(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "rg-kit-start-" + c.segment()));
        assertEquals("IN_PROGRESS", started.status(), "开工不被任何路线确认门拦截");
    }

    @Test
    void directSupplyRootIsAutoIdentifiedContinuousAndSurvivesFullWarehouseArrival() {
        // 先下达并开工子件计划(同车间在产) → 根段的子件需求可由本车间直送 → 自动 CONTINUOUS。
        Case c = create("rg-cont", true);
        fixture.loginAs(c.workerUser());
        assertTrue(routeContinuousEligible(c.segment()), "同车间有在产子件工单：直送资格成立");
        assertEquals("CONTINUOUS", route(c.segment()), "创建事务自动识别为持续生产路线");
        assertFalse(allowsAutoPromote(c.segment()),
                "持续生产未开工：仓库料先到也不把段顶成 READY(V595 竞态关闭)");
        // 子件全部直送 100：即使料全齐，段仍保持 WAITING 等车间按持续生产开工。
        transfer(c, "100");
        assertEquals("WAITING", status(c.segment()));
        assertTrue(Boolean.TRUE.equals(db.queryForObject(
                "SELECT fn_can_start_continuous_supply(?)", Boolean.class, c.segment())));
        // 不做任何路线确认，直接部分开工：未动过的工单同事务把路线切到 CONTINUOUS。
        var started = segments.startContinuousSupply(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "rg-cont-start-" + c.segment()));
        assertEquals("IN_PROGRESS", started.status());
        assertEquals("CONTINUOUS", route(c.segment()), "开工事务内路线已是持续生产");
        assertTrue(allowsAutoPromote(c.segment()), "持续生产置位后仓库需求恢复自动提升");
    }

    @Test
    void splitIsActionDrivenWithoutPriorBatchConfirmation() {
        // 点「分批领料」本身就是选择分批(V606)：FULL_KIT 根段不先确认 BATCH 也能拆。
        Case c = create("rg-batch", false);
        fixture.loginAs(c.workerUser());
        assertEquals("FULL_KIT", route(c.segment()));
        receive(c, c.material(), c.leaf(), "40");
        assertEquals("WAITING", status(c.segment()), "只到 40/100：不齐套不提升");

        var preview = batches.preview(new ProductionExecutionBatch.PreviewRequest(
                c.segment(), version(c.segment()), null));
        qty("40", preview.maxReadyQty());
        var result = batches.submit(new ProductionExecutionBatch.SubmitRequest(
                c.segment(), preview.expectedVersion(), preview.quantity(),
                preview.fingerprint(), "rg-batch-split-" + c.segment()));
        assertEquals("FULL_KIT", db.queryForObject(
                "SELECT start_route FROM production_execution_segments WHERE id=?",
                String.class, result.batchSegmentId()), "批次段落生即齐套路线");
        assertNotNull(db.queryForObject(
                "SELECT route_confirmed_at FROM production_execution_segments WHERE id=?",
                java.sql.Timestamp.class, result.batchSegmentId()));
        if (result.remainingSegmentId() != null) {
            assertEquals("BATCH", db.queryForObject(
                    "SELECT start_route FROM production_execution_segments WHERE id=?",
                    String.class, result.remainingSegmentId()), "剩余段继承分批路线");
        }
        // 自动识别与动作驱动切换都不产生 ROUTE_CONFIRMED 事件(不是人的确认决定)。
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM production_execution_segment_events
                WHERE execution_segment_id=? AND action='ROUTE_CONFIRMED'
                """, Integer.class, c.segment()));
    }

    @Test
    void touchedSegmentCannotSwitchRouteOrStartContinuous() {
        Case c = create("rg-frozen", false);
        receive(c, c.material(), c.leaf(), "100");
        fixture.loginAs(c.workerUser());
        assertEquals("READY", status(c.segment()), "自动提升后已有领料单=动过");
        // 动过后不能改选持续生产(开工侧同口径)。
        ApiException continuous = assertThrows(ApiException.class, () -> segments.startContinuousSupply(
                c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "rg-frozen-cont-" + c.segment())));
        assertTrue(continuous.getMessage().contains("不能切换"), continuous.getMessage());
        // 动过后手工改路线同样被拒(冻结尺不变)。
        ApiException frozen = assertThrows(ApiException.class, () -> segments.confirmRoute(
                c.plan(), c.segment(),
                new SegmentRouteConfirmRequest(version(c.segment()), "rg-frozen-change-" + c.segment(), "BATCH")));
        assertTrue(frozen.getMessage().contains("只能在等待物料阶段") || frozen.getMessage().contains("更改"),
                frozen.getMessage());
    }

    @Test
    void manualOverrideSurvivesAndSameValueConfirmIsIdempotent() {
        // 自动识别错边时的人工纠偏出口保留：未动过的段可改选；同值重复确认幂等。
        Case c = create("rg-override", true);
        fixture.loginAs(c.workerUser());
        assertEquals("CONTINUOUS", route(c.segment()));
        // 改成分批(未动过)。
        segments.confirmRoute(c.plan(), c.segment(),
                new SegmentRouteConfirmRequest(version(c.segment()), "rg-override-batch-" + c.segment(), "BATCH"));
        assertEquals("BATCH", route(c.segment()));
        assertFalse(allowsAutoPromote(c.segment()), "BATCH 根段不被自动提升：等车间来拆批");
        // 同值重复确认：幂等成功，不报「只能在等待物料阶段」。
        segments.confirmRoute(c.plan(), c.segment(),
                new SegmentRouteConfirmRequest(version(c.segment()), "rg-override-same-" + c.segment(), "BATCH"));
        assertEquals("BATCH", route(c.segment()));
        // 零料直制段(无子件)选分批必被拒：override 校验与弹窗选项同口径。
        ApiException batchOnZero = assertThrows(ApiException.class, () -> segments.confirmRoute(
                c.childPlan(), c.childSegment(),
                new SegmentRouteConfirmRequest(version(c.childSegment()), "rg-override-zero-" + c.childSegment(), "BATCH")));
        assertTrue(batchOnZero.getMessage().contains("分批") || batchOnZero.getMessage().contains("齐套"),
                batchOnZero.getMessage());
    }

    @Test
    void arrivalProgressCardFollowsTheWaitingSegmentFacts() {
        Case c = create("rg-notice", false);
        db.update("DELETE FROM notices WHERE source_event='PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED'");
        receive(c, c.material(), c.leaf(), "40");
        // OTHER_IN(人工库存调整)与收货审核都不是到货进展的触发面：只有 IQC 确认入库与
        // 产成品入库(非线边仓)这两类「真实写进库存」的事件才发卡——这里验证不误发。
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM business_outbox
                WHERE event_type='PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL' AND aggregate_id=?
                """, Integer.class, c.segment()), "人工其他入库不触发到货进展事件");
        // 业务事务侧：到货命中仍在等待的工单 → outbox 事件(带去重键)。直接落行，
        // 避免真实的异步 outbox 监听与本测试的手工投递竞态。
        db.update("""
                INSERT INTO business_outbox(id, event_type, aggregate_type, aggregate_id, payload, dedupe_key, created_by, status)
                VALUES (gen_random_uuid(), 'PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL', 'PRODUCTION_EXECUTION_SEGMENT', ?,
                        CAST('{"arrival":"本次入库：路线子件 40"}' AS jsonb), 'TEST:rg-notice', NULL, 1)
                """, c.segment());
        assertEquals(1, db.queryForObject("""
                SELECT count(*) FROM business_outbox
                WHERE event_type='PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL' AND aggregate_id=?
                """, Integer.class, c.segment()));
        // 投递侧按当时事实重组卡片：仍缺 60 → 发「到了多少 + 还差什么」聚合卡给车间。
        ObjectNode payload = new ObjectMapper().createObjectNode();
        payload.put("arrival", "本次入库：路线子件 40");
        deliverArrival(c.segment(), payload);
        assertTrue(db.queryForObject("""
                SELECT count(*) FROM notices n
                WHERE n.source_event='PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED'
                  AND n.audience_user_id=? AND n.content LIKE '%本次入库%'
                  AND n.content LIKE '%还缺%'
                """, Integer.class, c.workerUser()) >= 1,
                "车间收到「到了多少+还差什么」的聚合卡");
        // 剩余到齐 → FULL_KIT 自动提升(无需确认)：段不再等待，同一事件再投递不重复发卡。
        fixture.loginAs(c.workerUser());
        receive(c, c.material(), c.leaf(), "60");
        assertEquals("READY", status(c.segment()), "自动识别的齐套路线到齐即提升");
        db.update("DELETE FROM notices WHERE source_event='PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED'");
        deliverArrival(c.segment(), payload);
        // 段已齐套提升：系统正常的「物料齐套」状态卡允许出现，但不得再有「到货进展」卡。
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM notices
                WHERE source_event='PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED' AND audience_user_id=?
                  AND content LIKE '%本次入库%'
                """, Integer.class, c.workerUser()), "不在等待的段不重复发到货进展卡");
    }

    /** 与真实 outbox 处理器同款：投递在事务里跑，通知写入需要会话。 */
    private void deliverArrival(UUID segmentId, ObjectNode payload) {
        var txManager = beans.getBean(org.springframework.transaction.PlatformTransactionManager.class);
        new org.springframework.transaction.support.TransactionTemplate(txManager)
                .executeWithoutResult(ignored ->
                        chainNotices.deliverOutboxEvent(
                                "PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL", segmentId, payload));
    }

    // ===================== 夹具 =====================

    private record Case(
            FullChainEndToEndTest.World world,
            UUID parent, UUID material,
            UUID plan, UUID segment,
            UUID childPlan, UUID childSegment,
            UUID workshop, UUID worker, UUID workerUser,
            UUID leaf, UUID planItem) {
    }

    /**
     * 父件(自制) → 唯一子件(自制零料直制)。issueChild=true 时先下达并开工子件计划
     * (同车间在产) → 根段需求可直送 → 自动识别 CONTINUOUS；false 时不下达子件 →
     * 根段纯仓库供料 → 自动识别 FULL_KIT。
     */
    private Case create(String tag, boolean issueChild) {
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID parent = UUID.randomUUID(), child = UUID.randomUUID();
        fixture.insertGoods(parent, "RG-P-" + tag, "路线父件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertGoods(child, "RG-C-" + tag, "路线子件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertBom(parent, child, "1");
        UUID production = db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'", UUID.class);
        UUID workshop = UUID.randomUUID(), worker = UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",
                workshop, "RG-W-" + tag, "路线车间-" + tag, production);
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """, worker, "RG-EMP-" + tag, "路线负责人-" + tag, workshop);
        UUID workerUser = fixture.createUserWithPerms(w, "rg-worker-" + tag,
                "production_execution:view", "production_execution:start");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                workshop, workerUser);
        UUID leaf = UUID.randomUUID();
        db.update("""
                INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable)
                VALUES(?,?,?,?,'使用',TRUE)
                """, leaf, "RG-SUB-" + tag, "路线子仓-" + tag, w.warehouseId());

        UUID order = fixture.createApprovedOrder(w, parent, "100", "100");
        UUID orderItem = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, order);
        var view = analyses.preview(new PreviewRequest(null, null, null, w.warehouseId(),
                "rg-preview-" + tag, List.of(new PreviewItem("SALES_ORDER_ITEM", orderItem,
                null, null, null, null, null, BusinessTime.today().plusDays(10), new BigDecimal("100")))));
        analyses.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(),
                "rg-routes-" + tag, view.flatMaterials().stream()
                        .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                                row.goodsId().equals(parent) || row.goodsId().equals(child) ? "MAKE" : "BUY", null))
                        .toList()));
        view = analyses.detail(view.analysisId());
        UUID childPlan = null;
        UUID childSegment = null;
        if (issueChild) {
            UUID childLineId = view.flatMaterials().stream()
                    .filter(row -> row.goodsId().equals(child)).findFirst().orElseThrow().materialLineId();
            var childResult = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                    view.version(), view.fingerprint(), "rg-child-" + tag, w.warehouseId(),
                    BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                    List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                            childLineId, null, new BigDecimal("100"),
                            BusinessTime.today(), BusinessTime.today().plusDays(10),
                            workshop, null, worker, null, null))));
            childPlan = childResult.plans().getFirst().planId();
            childSegment = childResult.plans().getFirst().segmentIds().getFirst();
            assertEquals("READY", status(childSegment), "零料直制子件任务直接可开工");
            // 子件开工(后续直送/候选都要求「同车间在产」)；路线已自动识别，无需确认。
            fixture.loginAs(workerUser);
            segments.start(childPlan, childSegment,
                    new SegmentTransitionRequest(version(childSegment), "rg-child-open-start-" + childSegment));
            fixture.loginAs(w.superAdminUserId());
        }

        view = analyses.detail(view.analysisId());
        var rootResult = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                view.version(), view.fingerprint(), "rg-root-" + tag, w.warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        null, view.products().getFirst().analysisLineId(), new BigDecimal("100"),
                        BusinessTime.today(), BusinessTime.today().plusDays(10),
                        workshop, null, worker, null, null))));
        UUID plan = rootResult.plans().getFirst().planId();
        UUID segment = db.queryForObject(
                "SELECT id FROM production_execution_segments WHERE plan_id=? AND status='WAITING'", UUID.class, plan);
        UUID planItem = db.queryForObject(
                "SELECT source_plan_item_id FROM production_execution_segments WHERE id=?", UUID.class, segment);
        fixture.loginAs(workerUser);
        return new Case(w, parent, child, plan, segment, childPlan, childSegment,
                workshop, worker, workerUser, leaf, planItem);
    }

    /** 子件报工「转下一道工序」，直送给父件对本子件的需求。 */
    private void transfer(Case c, String quantity) {
        fixture.loginAs(c.workerUser());
        var report = new com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest();
        report.setIdempotencyKey("rg-report-" + c.childSegment() + "-" + quantity + "-" + UUID.randomUUID());
        report.setBillDate(BusinessTime.today());
        report.setWarehouseId(c.leaf());
        report.setDepartmentId(c.workshop());
        report.setWorkerIds(List.of(c.worker()));
        var item = new com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine();
        item.setLineNo(1);
        item.setExecutionSegmentId(c.childSegment());
        item.setPlanItemId(db.queryForObject(
                "SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",
                UUID.class, c.childSegment()));
        item.setGoodsId(childGoods(c));
        item.setUnitId(c.world().unitId());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(quantity));
        item.setDestination("WORKSHOP");
        item.setDirectTransferDemandId(parentDemand(c));
        report.setItems(List.of(item));
        reports().approve(reports().create(report).getId());
    }

    private UUID childGoods(Case c) {
        return db.queryForObject(
                "SELECT goods_id FROM production_material_demands WHERE execution_segment_id=? LIMIT 1",
                UUID.class, c.segment());
    }

    private com.uten.imp.features.production.dailyreport.ProductionDailyReportService reports() {
        return beans.getBean(com.uten.imp.features.production.dailyreport.ProductionDailyReportService.class);
    }

    private void receive(Case c, UUID goods, UUID warehouse, String quantity) {
        fixture.loginAs(c.world().superAdminUserId());
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setWarehouseId(warehouse);
        request.setBillDate(BusinessTime.today());
        var line = new StockDocItemLine();
        line.setGoodsId(goods);
        line.setUnitId(c.world().unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity));
        line.setPrice(BigDecimal.TEN);
        line.setAmountOriginal(line.getQty().multiply(BigDecimal.TEN));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        stock.approve(stock.create(request).getId());
    }

    private String route(UUID segmentId) {
        return db.queryForObject(
                "SELECT start_route FROM production_execution_segments WHERE id=?", String.class, segmentId);
    }

    private boolean allowsAutoPromote(UUID segmentId) {
        return Boolean.TRUE.equals(db.queryForObject(
                "SELECT fn_execution_route_allows_auto_promote(?)", Boolean.class, segmentId));
    }

    private boolean routeContinuousEligible(UUID segmentId) {
        return Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM production_material_demands demand
                    WHERE demand.execution_segment_id=? AND demand.is_deleted=FALSE
                      AND demand.status NOT IN ('RELEASED','REVERSED')
                      AND fn_demand_direct_supply_eligible(demand.id))
                """, Boolean.class, segmentId));
    }

    private UUID parentDemand(Case c) {
        return db.queryForObject(
                "SELECT id FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",
                UUID.class, c.segment(), childGoods(c));
    }

    private int drawCount(UUID segmentId) {
        return db.queryForObject("""
                SELECT count(*) FROM production_planning_package_documents mapping
                JOIN stock_documents document ON document.id=mapping.document_id AND NOT document.is_deleted
                WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW'
                """, Integer.class, segmentId);
    }

    private long version(UUID id) {
        return db.queryForObject(
                "SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, id);
    }

    private String status(UUID id) {
        return db.queryForObject(
                "SELECT status FROM production_execution_segments WHERE id=?", String.class, id);
    }

    private static void qty(String expected, BigDecimal value) {
        assertEquals(0, new BigDecimal(expected).compareTo(value), "expected " + expected + " but was " + value);
    }
}
