package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.NotifyRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.SupplyQuantityInput;
import com.uten.imp.features.production.analysis.MaterialAnalysisPlanningGapReader;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.execution.ProductionExecutionWorkbenchSegment;
import com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService;
import com.uten.imp.features.production.execution.ProductionPlanningUrgeService;
import com.uten.imp.features.production.execution.ProductionWorkshopTaskMaterial;
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
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.ClaimSharedFutureRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.SharedFutureClaimQuantity;
import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-117 车间催计划下单子层物料，真实 PostgreSQL。
 *
 * <p>钉住四件事：
 * <ol>
 *   <li>「计划还未落实供给」由物料分析权威覆盖计算给出：下单/认领一部分 = 剩余缺口、
 *       下够/认领够 = 0；仓库现货已分到的料不算计划缺口，未认领公共候选仍需办理；</li>
 *   <li>自制子件同样适用：子件还没排计划时父件任务在等计划，排了计划之后变成「等子件做完」；</li>
 *   <li>催计划只在真有计划缺口、本人车间、任务还在进行时成立；30 分钟内重复点不再打扰计划员；</li>
 *   <li>计划下够单后核对即办结在催记录，并撤回发给计划员的待办卡。</li>
 * </ol>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.production.planning-urge-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WorkshopPlanningUrgeEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionWorkbenchService workbench;
    @Autowired ProductionPlanningUrgeService urges;
    @Autowired com.uten.imp.features.production.execution.ProductionPlanningUrgeReconciler reconciler;
    @Autowired MaterialAnalysisPlanningGapReader planningSide;
    @Autowired com.uten.imp.features.notice.outbox.BusinessOutboxProcessor outbox;
    FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void purchaseChildGapFollowsTheAnalysisShortageUntilPlanningOrdersEnough() {
        Case c = create("pu-buy", "采购", false);
        fixture.loginAs(c.workerUser());
        ProductionExecutionWorkbenchSegment row = task(c);
        assertEquals(1, row.materialPlanningGapKindCount(), "子料一件都没下单: 在等计划");
        assertTrue(row.materialPlanningGapSummary().contains("子料-pu-buy"), row.materialPlanningGapSummary());
        assertTrue(row.materialPlanningGapSummary().contains("100"), row.materialPlanningGapSummary());
        assertTrue(row.canUrgePlanning());
        assertEquals(0, row.planningUrgeCount());
        qty("100", childMaterial(c).planningGapQty());
        assertTrue(childMaterial(c).planningRouteConfirmed(), "路线已确认为采购");

        var first = urges.urge(c.segment());
        assertTrue(first.notified());
        assertEquals(1, first.urgeCount());
        assertEquals(1, first.gapKindCount());
        assertNotNull(first.nextUrgeAllowedAt());
        assertEquals(1, outboxEvents(first.urgeId()), "每一次有效的催都进 Outbox");
        var repeat = urges.urge(c.segment());
        assertFalse(repeat.notified(), "30 分钟内再点不再打扰计划员");
        assertEquals(first.urgeId(), repeat.urgeId());
        assertEquals(1, repeat.urgeCount());
        assertEquals(1, outboxEvents(first.urgeId()));
        row = task(c);
        assertEquals(1, row.planningUrgeCount());
        assertNotNull(row.planningUrgedAt());
        assertNotNull(row.planningNextUrgeAt());

        // 计划侧：本分析上有一条在催，点名的是子料那一行。
        fixture.loginAs(c.world().superAdminUserId());
        var planning = planningSide.urges(c.analysis());
        assertEquals(1, planning.size());
        assertEquals(c.segment(), planning.getFirst().segmentId());
        assertEquals(List.of(childLine(c)), planning.getFirst().shortMaterialLineIds());

        // 只下一部分：剩下的仍是计划缺口，与主表「还缺数量」逐位一致。
        orderChild(c, "60");
        MaterialView child = childView(c);
        qty("40", child.netShortageQty());
        fixture.loginAs(c.workerUser());
        qty("40", childMaterial(c).planningGapQty());
        assertEquals(1, task(c).materialPlanningGapKindCount());
        fixture.loginAs(c.world().superAdminUserId());
        assertEquals(0, urges.reconcileAnalysis(c.analysis()), "还没下够: 在催记录不办结");

        // 下够：计划缺口归零，任务只是在等到货；在催记录办结。
        orderChild(c, "40");
        qty("0", childView(c).netShortageQty());
        fixture.loginAs(c.workerUser());
        row = task(c);
        assertEquals(0, row.materialPlanningGapKindCount());
        assertEquals(0, row.planningUrgeCount(), "计划已下够单的在催记录不再显示「已催」");
        assertFalse(row.canUrgePlanning());
        qty("0", childMaterial(c).planningGapQty());
        assertEquals("SHORT", childMaterial(c).state(), "仍在等采购到货, 只是不再等计划");
        fixture.loginAs(c.world().superAdminUserId());
        assertEquals(1, urges.reconcileAnalysis(c.analysis()));
        assertEquals("RESOLVED|ARRANGED", urgeState(first.urgeId()));
        assertTrue(planningSide.urges(c.analysis()).isEmpty());

        fixture.loginAs(c.workerUser());
        ApiException settled = assertThrows(ApiException.class, () -> urges.urge(c.segment()));
        assertEquals(ErrorCode.CONFLICT, settled.getCode());
        assertTrue(settled.getMessage().contains("下过单"), settled.getMessage());
    }

    @Test
    void stockAlreadyAllocatedToTheAnalysisIsNotAPlanningGap() {
        Case c = create("pu-stock", "采购", true);
        fixture.loginAs(c.workerUser());
        ProductionExecutionWorkbenchSegment row = task(c);
        assertEquals(0, row.materialPlanningGapKindCount(), "仓库现货已分到本分析: 不是在等计划下单");
        assertFalse(row.canUrgePlanning());
        qty("0", childMaterial(c).planningGapQty());
        assertThrows(ApiException.class, () -> urges.urge(c.segment()));
    }

    @Test
    void publicFutureCandidatesRequireActualClaimsBeforeAnUrgeCanBeResolved() {
        Case c = create("pu-public", "采购", false);
        fixture.loginAs(c.workerUser());
        var urge = urges.urge(c.segment());
        UUID publicSource = createPublicFuture(c);
        fixture.loginAs(c.world().superAdminUserId());
        MaterialView before = childView(c);
        qty("100", before.sharedFutureClaimableQty());
        qty("0", before.netShortageQty());
        qty("100", before.planningUncoveredQty());
        qty("100", planningSide.freshPlanningGaps(List.of(c.segment())).of(c.segment()).getFirst().gapQty());
        assertEquals(0, urges.reconcileAnalysis(c.analysis()), "公共候选未认领，不得把催办办结");
        assertEquals("OPEN|", urgeState(urge.urgeId()));

        AnalysisView view = analyses.detail(c.analysis());
        view = commands.claimSharedFuture(c.analysis(), new ClaimSharedFutureRequest(
                view.version(), view.fingerprint(), "pu-claim-40-" + c.segment(),
                List.of(before.actionGroupKey()),
                List.of(new SharedFutureClaimQuantity(before.actionGroupKey(), new BigDecimal("40"), publicSource)), false));
        MaterialView partial = view.flatMaterials().stream()
                .filter(material -> material.materialLineId().equals(before.materialLineId())).findFirst().orElseThrow();
        qty("60", partial.sharedFutureClaimableQty());
        qty("0", partial.netShortageQty());
        qty("60", partial.planningUncoveredQty());
        qty("60", planningSide.freshPlanningGaps(List.of(c.segment())).of(c.segment()).getFirst().gapQty());
        assertEquals(0, urges.reconcileAnalysis(c.analysis()), "认领 40 后剩余 60 仍需办理");

        commands.claimSharedFuture(c.analysis(), new ClaimSharedFutureRequest(
                view.version(), view.fingerprint(), "pu-claim-60-" + c.segment(),
                List.of(before.actionGroupKey()),
                List.of(new SharedFutureClaimQuantity(before.actionGroupKey(), new BigDecimal("60"), publicSource)), false));
        qty("0", childView(c).planningUncoveredQty());
        assertEquals(1, urges.reconcileAnalysis(c.analysis()));
        assertEquals("RESOLVED|ARRANGED", urgeState(urge.urgeId()));
        qty("100", db.queryForObject("SELECT SUM(requested_qty) FROM preplan_supply_actions "
                + "WHERE analysis_id=? AND operation_type='SHARED_FUTURE_CLAIM'", BigDecimal.class, c.analysis()));
        assertEquals(0, db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions "
                + "WHERE analysis_id=? AND operation_type='SUPPLY'", Integer.class, c.analysis()), "只认领，无重复新采购");
        qty("0", db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",
                BigDecimal.class, c.child()));
        fixture.loginAs(c.workerUser());
        assertEquals("SHORT", childMaterial(c).state(), "认领只是未来供给，并未到料或开工");
        assertFalse(task(c).canUrgePlanning());
    }

    @Test
    void makeChildWaitsForPlanningUntilItsOwnPlanIsIssued() {
        Case c = create("pu-make", "自制", false);
        fixture.loginAs(c.workerUser());
        assertEquals(1, task(c).materialPlanningGapKindCount(), "自制子件还没排计划: 父件在等计划");
        assertEquals("SHORT_MAKE", childMaterial(c).state());
        qty("100", childMaterial(c).planningGapQty());

        fixture.loginAs(c.world().superAdminUserId());
        AnalysisView view = analyses.detail(c.analysis());
        commands.issueWorkshopPlans(c.analysis(), new IssueWorkshopPlansRequest(
                view.version(), view.fingerprint(), "pu-make-child-" + c.segment(), c.world().warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(childLine(c), null, new BigDecimal("100"),
                        BusinessTime.today(), BusinessTime.today().plusDays(10),
                        c.workshop(), null, c.worker(), null, null))));
        fixture.loginAs(c.workerUser());
        assertEquals(0, task(c).materialPlanningGapKindCount(), "子件计划已下达: 等子件做完, 不再等计划");
        qty("0", childMaterial(c).planningGapQty());
    }

    @Test
    void onlyTheOwnWorkshopMayUrgeAndOnlyWhileTheTaskIsActive() {
        Case c = create("pu-scope", "采购", false);
        UUID stranger = fixture.createUserWithPerms(c.world(), "pu-stranger-" + UUID.randomUUID(),
                "production_execution:view", "production_execution:start");
        fixture.loginAs(stranger);
        ApiException hidden = assertThrows(ApiException.class, () -> urges.urge(c.segment()));
        assertEquals(ErrorCode.NOT_FOUND, hidden.getCode(), "别的车间看不到这个任务, 也不能替它催");

        fixture.loginAs(c.world().superAdminUserId());
        assertTrue(urges.urge(c.segment()).notified(), "超管可以替车间催");

        closeTask(c.segment());
        fixture.loginAs(c.workerUser());
        ApiException closed = assertThrows(ApiException.class, () -> urges.urge(c.segment()));
        assertEquals(ErrorCode.CONFLICT, closed.getCode());
        fixture.loginAs(c.world().superAdminUserId());
        assertEquals(1, urges.reconcileAnalysis(c.analysis()));
        UUID urgeId = db.queryForObject("SELECT id FROM production_planning_urges WHERE execution_segment_id=?",
                UUID.class, c.segment());
        assertEquals("RESOLVED|TASK_CLOSED", urgeState(urgeId));
    }

    @Test
    void plannersGetOneLatestCardThatIsWithdrawnOnceArranged() {
        Case c = create("pu-card", "采购", false);
        UUID subPlan = db.queryForObject("SELECT id FROM departments WHERE code='SUB_PLAN'", UUID.class);
        UUID planner = fixture.createUserWithPerms(c.world(), "pu-planner-" + UUID.randomUUID(), "notice:read",
                "production_material_analysis:view", "production_material_analysis:notify");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                subPlan, planner);
        // 计划部成员默认就带「下达采购委外」(部门默认授权)；不在计划 / 生产部门的人即使有同样的
        // 权限也不收——催料卡只发给计划那一边。
        UUID outsider = fixture.createUserWithPerms(c.world(), "pu-outsider-" + UUID.randomUUID(), "notice:read",
                "production_material_analysis:view", "production_material_analysis:notify");

        fixture.loginAs(c.workerUser());
        var urge = urges.urge(c.segment());
        deliver(urge.urgeId());
        assertEquals(1, openCards(planner, urge.urgeId()), "能下单的计划员收到待办卡");
        assertEquals(0, openCards(outsider, urge.urgeId()), "不在计划 / 生产部门的人不收");
        String content = db.queryForObject("""
                SELECT content FROM notices WHERE audience_user_id=? AND aggregate_id=? AND resolved_at IS NULL
                """, String.class, planner, urge.urgeId());
        assertTrue(content.contains("子料-pu-card") && content.contains("还没下单"), content);

        // 再催(过了 30 分钟)：旧卡撤掉, 只留一张最新的「第 2 次」。
        db.update("UPDATE production_planning_urges SET last_urged_at=last_urged_at-interval '31 minutes', "
                + "first_urged_at=first_urged_at-interval '31 minutes' WHERE id=?", urge.urgeId());
        var again = urges.urge(c.segment());
        assertTrue(again.notified());
        assertEquals(2, again.urgeCount());
        deliver(urge.urgeId());
        assertEquals(1, openCards(planner, urge.urgeId()), "同一条催办只留一张最新的卡");
        String title = db.queryForObject("""
                SELECT title FROM notices WHERE audience_user_id=? AND aggregate_id=? AND resolved_at IS NULL
                """, String.class, planner, urge.urgeId());
        assertTrue(title.contains("第 2 次"), title);

        fixture.loginAs(c.world().superAdminUserId());
        orderChild(c, "100");
        assertEquals(1, urges.reconcileAnalysis(c.analysis()));
        assertEquals(0, openCards(planner, urge.urgeId()), "计划下够单: 卡片撤回");
    }

    @Test
    void backgroundReconcileSettlesUrgesArrangedOutsideTheAnalysisPage() {
        Case c = create("pu-bg", "采购", false);
        fixture.loginAs(c.workerUser());
        var urge = urges.urge(c.segment());
        fixture.loginAs(c.world().superAdminUserId());
        orderChild(c, "100");
        SecurityContextHolder.clearContext();
        assertTrue(reconciler.runBatch() >= 1, "后台核对不需要登录身份");
        assertEquals("RESOLVED|ARRANGED", urgeState(urge.urgeId()));
    }

    @Test
    void cardsOnlyReachPlannersWhoCanOpenThisAnalysis() {
        Case c = create("pu-reach", "采购", false);
        // 这份分析归一位计划员(制单人)：生产部的人有下单权限但看不到别人的分析，不该收到卡。
        UUID makerUser = fixture.createUserWithPerms(c.world(), "pu-maker-" + UUID.randomUUID(), "notice:read",
                "production_material_analysis:view", "production_material_analysis:notify");
        UUID makerEmployee = db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, makerUser);
        withoutGuards("UPDATE production_material_analyses SET maker_id='" + makerEmployee + "' WHERE id='"
                + c.analysis() + "'");
        UUID production = db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'", UUID.class);
        UUID blind = fixture.createUserWithPerms(c.world(), "pu-blind-" + UUID.randomUUID(), "notice:read",
                "production_material_analysis:view", "production_material_analysis:generate");
        UUID scoped = fixture.createUserWithPerms(c.world(), "pu-scoped-" + UUID.randomUUID(), "notice:read",
                "production_material_analysis:view", "production_material_analysis:generate");
        db.update("UPDATE employees SET department_id=? WHERE id IN (SELECT employee_id FROM users WHERE id IN (?,?))",
                production, blind, scoped);
        db.update("""
                INSERT INTO user_data_scopes(user_id, scope, owner_employee_id, owner_employment_generation)
                VALUES (?, 'production_plan', ?, 0)
                """, scoped, makerEmployee);

        fixture.loginAs(c.workerUser());
        var urge = urges.urge(c.segment());
        deliver(urge.urgeId());
        assertEquals(1, openCards(makerUser, urge.urgeId()), "制单计划员不在计划部门也收到");
        assertEquals(1, openCards(scoped, urge.urgeId()), "授权看这位计划员单据的生产部成员收到");
        assertEquals(0, openCards(blind, urge.urgeId()), "看不到这份分析的人不收(收了也打不开, 还泄露物料)");
    }

    @Test
    void unreadableAnalysisIsNeitherAGapNorArranged() {
        Case c = create("pu-lost", "采购", false);
        fixture.loginAs(c.workerUser());
        var urge = urges.urge(c.segment());
        // 分析读不出来(这里用删掉来模拟；现实里多是 BOM 变了要重新分析)：不能当成「计划已下够单」撤卡。
        withoutGuards("UPDATE production_material_analyses SET is_deleted=TRUE WHERE id='" + c.analysis() + "'");
        fixture.loginAs(c.world().superAdminUserId());
        assertEquals(0, urges.reconcileAnalysis(c.analysis()));
        SecurityContextHolder.clearContext();
        reconciler.runBatch();
        assertEquals("OPEN|", urgeState(urge.urgeId()), "不知道计划下没下单时保持在催");

        db.update("UPDATE production_planning_urges SET last_urged_at=last_urged_at-interval '31 minutes', "
                + "first_urged_at=first_urged_at-interval '31 minutes' WHERE id=?", urge.urgeId());
        fixture.loginAs(c.workerUser());
        ApiException unknown = assertThrows(ApiException.class, () -> urges.urge(c.segment()));
        assertEquals(ErrorCode.CONFLICT, unknown.getCode());
        assertTrue(unknown.getMessage().contains("读不出来"), unknown.getMessage());
    }

    // ------------------------------------------------------------------ fixture

    private record Case(FullChainEndToEndTest.World world, UUID parent, UUID child, UUID analysis,
                        UUID plan, UUID segment, UUID workshop, UUID worker, UUID workerUser) {}

    /**
     * 父件(自制) → 子料(采购或自制)，订单 100。父件下达车间，子料一件都不下单。
     * [stockOnHand] = 子料仓库里已有 100 现货(分析会分给本批)。
     */
    private Case create(String tag, String childSource, boolean stockOnHand) {
        String unique = tag + "-" + UUID.randomUUID().toString().substring(0, 8);
        var w = fixture.seedWorld(unique);
        fixture.loginAs(w.superAdminUserId());
        UUID parent = UUID.randomUUID(), child = UUID.randomUUID();
        fixture.insertGoods(parent, "PU-P-" + unique, "父件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertGoods(child, "PU-C-" + unique, "子料-" + tag, childSource, w.unitId(), w.unitLegacy());
        fixture.insertBom(parent, child, "1");
        if (stockOnHand) {
            db.update("insert into stock_balances(warehouse_id,goods_id,color_id,qty) values (?,?,null,100)",
                    w.warehouseId(), child);
        }
        UUID production = db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'", UUID.class);
        UUID workshop = UUID.randomUUID(), worker = UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",
                workshop, "PU-W-" + unique, "催料车间-" + tag, production);
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """, worker, "PU-EMP-" + unique, "车间负责人-" + tag, workshop);
        UUID workerUser = fixture.createUserWithPerms(w, "pu-worker-" + unique,
                "production_execution:view", "production_execution:start");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                workshop, workerUser);

        UUID order = fixture.createApprovedOrder(w, parent, "100", "100");
        UUID orderItem = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, order);
        var view = analyses.preview(new PreviewRequest(null, null, null, w.warehouseId(),
                "pu-preview-" + unique, List.of(new PreviewItem("SALES_ORDER_ITEM", orderItem,
                null, null, null, null, null, BusinessTime.today().plusDays(10), new BigDecimal("100")))));
        String childRoute = "自制".equals(childSource) ? "MAKE" : "BUY";
        analyses.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(),
                "pu-routes-" + unique, view.flatMaterials().stream()
                        // 现货已盖住的子料没有独立需求, 不能也不用确认路线。
                        .filter(MaterialView::actionable)
                        .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                                row.goodsId().equals(child) ? childRoute : "MAKE", null))
                        .toList()));
        view = analyses.detail(view.analysisId());
        var root = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                view.version(), view.fingerprint(), "pu-root-" + unique, w.warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        null, view.products().getFirst().analysisLineId(), new BigDecimal("100"),
                        BusinessTime.today(), BusinessTime.today().plusDays(10),
                        workshop, null, worker, null, null))));
        UUID plan = root.plans().getFirst().planId();
        UUID segment = db.queryForObject(
                "SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted", UUID.class, plan);
        return new Case(w, parent, child, view.analysisId(), plan, segment, workshop, worker, workerUser);
    }

    private ProductionExecutionWorkbenchSegment task(Case c) {
        return workbench.workshopTasks(1, 100, null, "PREPARING", null, null, null).getItems().stream()
                .filter(row -> row.segmentId().equals(c.segment())).findFirst()
                .orElseThrow(() -> new AssertionError("车间任务列表里找不到本任务"));
    }

    private ProductionWorkshopTaskMaterial childMaterial(Case c) {
        String code = db.queryForObject("SELECT code FROM goods WHERE id=?", String.class, c.child());
        return workbench.workshopTaskMaterials(c.segment()).stream()
                .filter(material -> code.equals(material.goodsCode())).findFirst().orElseThrow();
    }

    private MaterialView childView(Case c) {
        return analyses.detail(c.analysis()).flatMaterials().stream()
                .filter(material -> material.goodsId().equals(c.child())).findFirst().orElseThrow();
    }

    private UUID childLine(Case c) {
        return db.queryForObject("""
                SELECT id FROM production_material_analysis_materials
                WHERE analysis_id=? AND goods_id=? AND active
                """, UUID.class, c.analysis(), c.child());
    }

    /** 另一份分析采购需求 1，实际审批订货 101，形成真实且尚未认领的公共在途 100。 */
    private UUID createPublicFuture(Case c) {
        var w = c.world();
        fixture.loginAs(w.superAdminUserId());
        UUID sourceProduct = UUID.randomUUID();
        fixture.insertGoods(sourceProduct, "PU-SOURCE-" + sourceProduct, "公共在途来源", "自制", w.unitId(), w.unitLegacy());
        fixture.insertBom(sourceProduct, c.child(), "1");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?", w.supplierId(), c.child());
        var view = analyses.preview(new PreviewRequest(null, null, null, w.warehouseId(),
                "pu-source-preview-" + sourceProduct, List.of(new PreviewItem("OTHER", null, sourceProduct,
                null, w.unitId(), "pu-source-" + sourceProduct, "公共在途来源", BusinessTime.today().plusDays(10), BigDecimal.ONE))));
        view = analyses.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(),
                "pu-source-route-" + sourceProduct, view.flatMaterials().stream().filter(MaterialView::actionable)
                .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                        row.goodsId().equals(c.child()) ? "BUY" : "MAKE", null)).toList()));
        MaterialView material = view.flatMaterials().stream().filter(row -> row.goodsId().equals(c.child()))
                .findFirst().orElseThrow();
        commands.notifySupply(view.analysisId(), new NotifyRequest(view.version(), view.fingerprint(),
                "pu-source-notify-" + sourceProduct, "BUY", List.of(material.materialLineId()), List.of(),
                List.of(new SupplyQuantityInput(null, material.materialLineId(), BigDecimal.ONE, BigDecimal.ZERO))));
        var source = db.queryForMap("SELECT action.id,allocation.external_item_id FROM preplan_supply_actions action "
                + "JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id "
                + "WHERE action.analysis_id=? AND action.route='BUY'", view.analysisId());
        UUID requestItem = (UUID) source.get("external_item_id");
        var request = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId"));
        request.setBillDate(LocalDate.of(2026, 1, 15));
        request.setSupplierId(w.supplierId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line = ReflectionTestUtils.invokeMethod(
                fixture, "ma65OrderLine", w, requestItem, c.child(), "101");
        line.setDeliverDate(BusinessTime.today().plusDays(5));
        request.setItems(List.of(line));
        var orders = (com.uten.imp.features.purchase.order.PurchaseOrderService) ReflectionTestUtils.getField(fixture, "purchaseOrderService");
        var finance = (com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService) ReflectionTestUtils.getField(fixture, "financeApproval");
        orders.createBatch(request);
        UUID order = db.queryForObject("SELECT item.order_id FROM purchase_order_items item "
                + "JOIN purchase_order_item_sources source ON source.order_item_id=item.id "
                + "WHERE source.request_item_id=? AND NOT item.is_deleted", UUID.class, requestItem);
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        finance.submit("PURCHASE", order);
        fixture.loginAs(reviewer);
        ReflectionTestUtils.invokeMethod(fixture, "approvePendingFinance", "PURCHASE", order);
        fixture.loginAs(w.superAdminUserId());
        return (UUID) source.get("id");
    }

    /** 计划员给子料下达采购(登录身份由调用方负责，一般是超管)。 */
    private void orderChild(Case c, String quantity) {
        fixture.loginAs(c.world().superAdminUserId());
        AnalysisView view = analyses.detail(c.analysis());
        MaterialView child = view.flatMaterials().stream()
                .filter(material -> material.goodsId().equals(c.child())).findFirst().orElseThrow();
        commands.notifySupply(c.analysis(), new NotifyRequest(view.version(), view.fingerprint(),
                "pu-order-" + UUID.randomUUID(), "BUY", List.of(child.materialLineId()), List.of(),
                List.of(new SupplyQuantityInput(child.actionGroupKey(), null, new BigDecimal(quantity), BigDecimal.ZERO))));
    }

    private int outboxEvents(UUID urgeId) {
        return db.queryForObject("""
                SELECT COUNT(*) FROM business_outbox
                WHERE event_type='PRODUCTION_PLANNING_URGED' AND aggregate_id=?
                """, Integer.class, urgeId);
    }

    /**
     * 走真实的 Outbox 处理器把本条催办的事件送达(与后台调度同一条路径；SKIP LOCKED 保证
     * 后台调度与这里抢到同一条时只送一次)。
     */
    private void deliver(UUID urgeId) {
        long deadline = System.nanoTime() + 20_000_000_000L;
        while (pendingEvents(urgeId) > 0) {
            if (!outbox.processNext()) Thread.onSpinWait();
            assertTrue(System.nanoTime() < deadline, "催计划事件 20 秒内没有送达");
        }
    }

    private int pendingEvents(UUID urgeId) {
        return db.queryForObject("""
                SELECT COUNT(*) FROM business_outbox
                WHERE event_type='PRODUCTION_PLANNING_URGED' AND aggregate_id=? AND status=0
                """, Integer.class, urgeId);
    }

    /**
     * 模拟任务已结束：真实的取消走计划取消 / 红冲整条链，这里只要一个终态的车间任务，
     * 所以在同一连接上临时跳过守卫触发器改状态。
     */
    private void closeTask(UUID segmentId) {
        db.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
            try (var statement = connection.createStatement()) {
                statement.execute("SET session_replication_role = replica");
                statement.execute("UPDATE production_execution_segments SET status='CANCELLED' WHERE id='" + segmentId + "'");
                statement.execute("SET session_replication_role = origin");
            }
            return null;
        });
    }

    /** 在同一连接上临时跳过守卫触发器执行一条造数语句(只用于构造极端现场)。 */
    private void withoutGuards(String sql) {
        db.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
            try (var statement = connection.createStatement()) {
                statement.execute("SET session_replication_role = replica");
                try {
                    statement.execute(sql);
                } finally {
                    statement.execute("SET session_replication_role = origin");
                }
            }
            return null;
        });
    }

    private int openCards(UUID userId, UUID urgeId) {
        return db.queryForObject("""
                SELECT COUNT(*) FROM notices
                WHERE audience_user_id=? AND aggregate_kind='PRODUCTION_PLANNING_URGE' AND aggregate_id=?
                  AND source_event='PRODUCTION_PLANNING_URGED' AND resolved_at IS NULL
                """, Integer.class, userId, urgeId);
    }

    private String urgeState(UUID urgeId) {
        return db.queryForObject("SELECT status || '|' || COALESCE(resolution,'') FROM production_planning_urges WHERE id=?",
                String.class, urgeId);
    }

    private static void qty(String expected, BigDecimal actual) {
        assertNotNull(actual);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), () -> "expected " + expected + " but was " + actual);
    }
}
