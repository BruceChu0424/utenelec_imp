package com.uten.imp.businesschain;

import com.uten.imp.application.port.RdBomGapPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.master.goods.GoodsBomService;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest;
import com.uten.imp.features.production.mrp.PlanningPackageResult;
import com.uten.imp.features.production.mrp.PlanningPreviewResult;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
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
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.NotifyRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * ADR-143 §二.3 缺 BOM 的委外件真库全链验收: 委外件必须先有可发外的直属物料(唯一判定
 * {@code fn_subcontract_draw_edges})才能往下走。
 *
 * <p>主链: 成品 F(自制) 的直属子件 S(委外) 没有 BOM →
 * <ol>
 *   <li>计划员甲新建物料分析: S 行标「缺 BOM」, 系统自动给工程研发部建一条「完善 BOM」研发任务,
 *       甲进等待名单; 计划员乙另一张分析发现同一缺口只进等待名单, 研发任务仍只有一条、只通知研发一次;</li>
 *   <li>甲下达委外 409(说明已通知研发、研发保存后分析会自动更新), 不建委外申请;</li>
 *   <li>委外人员手工下 S 的委外订货单: 草稿可以保存(明细标缺 BOM), 提交财务 409, 提交人进等待名单;</li>
 *   <li>另一位计划员按旧生产计划确认执行计划包: 生成委外申请前同样 409, 确认人进等待名单;</li>
 *   <li>研发在货品资料里给 S 加一条直属边(S → M ×2) → 投递 outbox: 研发任务自动完成; 两张分析各自经
 *       {@code MATERIAL_ANALYSIS_BOM_REFRESH} 事件自动刷新, 展开出 M 节点; 等待名单里每个人收到「BOM 已完善」
 *       通知并直达自己被挡住的单据;</li>
 *   <li>之后下达委外、提交财务(批准冻结 M 的领料计划行)、确认执行计划包全部放行。</li>
 * </ol>
 *
 * <p>另一用例: BUY 父件下面没有需求的委外子件不转研发(审核意见 analysis/AN-3)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractNoBomGateEndToEndTest {

    private static final String[] PLANNER_PERMISSIONS = {
            "production_material_analysis:view", "production_material_analysis:manage",
            "production_material_analysis:route", "production_material_analysis:notify", "notice:read"};
    private static final String BOM_MISSING_TEXT = "还没有维护 BOM(直属物料)，已通知研发完善";

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService analysisCommands;
    @Autowired SubcontractOrderService subcontractOrders;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired ProductionPlanningPackageService planningPackages;
    @Autowired GoodsBomService boms;
    @Autowired BusinessOutboxProcessor outbox;

    FullChainEndToEndTest fixture;

    @BeforeEach
    void setup() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    // =====================================================================================
    // 主链: 缺 BOM 挡住分析下达 / 委外送财务 / 计划包确认 → 研发保存 BOM → 分析自动刷新 → 全部放行
    // =====================================================================================

    @Test
    void aSubcontractNodeWithoutBomBlocksEveryIssuePathUntilRdSavesTheBomAndTheAnalysesRefreshThemselves() {
        String tag = "scnobom";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID f = goods(w, "F-" + tag, "成品F-" + tag, "自制");
        UUID s = goods(w, "S-" + tag, "委外件S-" + tag, "委外");
        UUID m = goods(w, "M-" + tag, "原料M-" + tag, "采购");
        fixture.insertBom(f, s, "1");
        String sLabel = RdBomGapPort.goodsLabel("委外件S-" + tag, "S-" + tag);
        assertFalse(hasDrawableEdges(s), "S 没有任何可发外的直属边");
        Set<UUID> mine = new LinkedHashSet<>(List.of(f, s, m));

        UUID planner1 = fixture.createUserWithPerms(w, tag + "-planner1", PLANNER_PERMISSIONS);
        UUID planner2 = fixture.createUserWithPerms(w, tag + "-planner2", PLANNER_PERMISSIONS);
        UUID salesItem1 = salesItemOf(fixture.createApprovedOrder(w, f, "10", "100"));
        UUID salesItem2 = salesItemOf(fixture.createApprovedOrder(w, f, "10", "100"));

        // ① 计划员甲新建分析: S 行「缺 BOM」, 展开不出直属物料; 提交后自动建一条「完善 BOM」研发任务, 甲进等待名单。
        fixture.loginAs(planner1);
        AnalysisView a1 = preview(w, salesItem1, tag + "-a1");
        UUID analysis1 = a1.analysisId();
        mine.add(analysis1);
        MaterialView sRow = row(a1, s);
        assertEquals("SUBCONTRACT", sRow.sourceSuggestion(), "S 按货品资料建议委外");
        assertTrue(sRow.bomMissing(), "委外节点没有可发外直属物料 → 缺 BOM");
        assertTrue(a1.flatMaterials().stream().noneMatch(row -> m.equals(row.goodsId())),
                "S 还没有 BOM, 分析里不可能有 M");
        Map<String, Object> task = theOnlyBomTask(s);
        UUID taskId = (UUID) task.get("id");
        String taskNo = (String) task.get("task_no");
        mine.add(taskId);
        assertEquals("OPEN", task.get("status"));
        assertEquals("BOM", task.get("category"));
        assertEquals(RdBomGapPort.SOURCE_MATERIAL_ANALYSIS, task.get("source_doc_type"), "任务来源 = 这张物料分析");
        assertEquals(analysis1, task.get("source_doc_id"));
        assertWaiter(taskId, employeeOf(planner1), RdBomGapPort.SOURCE_MATERIAL_ANALYSIS, analysis1);
        assertEquals(1, waiterCount(taskId));
        assertEquals(taskNo, row(analyses.detail(analysis1), s).rdTaskNo(), "缺 BOM 行带上研发任务编号");
        assertEquals(1, count("""
                SELECT COUNT(*) FROM business_outbox WHERE event_type='RD_TASK_FORWARDED' AND aggregate_id=?
                """, taskId), "新建研发任务时通知工程研发部一次");

        // ② 计划员乙的分析发现同一缺口: 研发任务不重复建, 乙只进等待名单, 也不再打扰研发。
        fixture.loginAs(planner2);
        AnalysisView a2 = preview(w, salesItem2, tag + "-a2");
        UUID analysis2 = a2.analysisId();
        mine.add(analysis2);
        assertTrue(row(a2, s).bomMissing());
        assertEquals(1, count("SELECT COUNT(*) FROM rd_tasks WHERE goods_id=? AND category='BOM' AND NOT is_deleted", s),
                "同一货品同时只有一条「完善 BOM」研发任务");
        assertWaiter(taskId, employeeOf(planner2), RdBomGapPort.SOURCE_MATERIAL_ANALYSIS, analysis2);
        assertEquals(2, waiterCount(taskId), "后发现缺口的计划员加入等待名单");
        assertEquals(1, count("""
                SELECT COUNT(*) FROM business_outbox WHERE event_type='RD_TASK_FORWARDED' AND aggregate_id=?
                """, taskId), "已有任务时只登记等待人, 不再通知研发");
        assertEquals(taskNo, row(analyses.detail(analysis2), s).rdTaskNo(), "两张分析指向同一条研发任务");

        // ③ 甲下达委外: 409 说明缺 BOM、已通知研发、研发保存后分析自动更新; 不建委外申请。
        fixture.loginAs(planner1);
        AnalysisView routed = confirmSubcontractRoute(analysis1, s, tag + "-route-a1-blocked");
        MaterialView blockedLine = row(routed, s);
        ApiException notifyBlocked = assertThrows(ApiException.class, () -> analysisCommands.notifySupply(analysis1,
                new NotifyRequest(routed.version(), routed.fingerprint(), tag + "-notify-a1-blocked", "SUBCONTRACT",
                        List.of(blockedLine.materialLineId()), List.of(), null)));
        assertEquals(ErrorCode.CONFLICT, notifyBlocked.getCode());
        assertTrue(notifyBlocked.getMessage().contains(sLabel) && notifyBlocked.getMessage().contains(BOM_MISSING_TEXT)
                        && notifyBlocked.getMessage().contains("研发保存后物料分析会自动更新"),
                notifyBlocked.getMessage());
        assertEquals(0, count("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=? AND route='SUBCONTRACT'",
                analysis1), "缺 BOM 不能下达委外申请");
        assertEquals(2, waiterCount(taskId), "同一人再次被挡不重复登记");

        // ④ 委外人员手工下 S 的委外订货单: 草稿能保存(明细标缺 BOM), 提交财务 409, 提交人进等待名单。
        fixture.loginAs(w.superAdminUserId());
        UUID subcontractOrderId = subcontractOrder(w, s, "10");
        mine.add(subcontractOrderId);
        assertTrue(subcontractOrders.detail(subcontractOrderId).getItems().getFirst().isBomMissing(),
                "草稿订货单明细提示缺 BOM");
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        ApiException submitBlocked = assertThrows(ApiException.class,
                () -> financeApproval.submit("SUBCONTRACT", subcontractOrderId));
        assertEquals(ErrorCode.CONFLICT, submitBlocked.getCode());
        assertTrue(submitBlocked.getMessage().contains(sLabel + " " + BOM_MISSING_TEXT), submitBlocked.getMessage());
        assertEquals(0, count("""
                SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_type='SUBCONTRACT' AND order_id=?
                """, subcontractOrderId), "被拒的送审不留审批案件");
        assertEquals(0, ((Number) db.queryForObject("SELECT status FROM subcontract_orders WHERE id=?", Integer.class,
                subcontractOrderId)).intValue(), "订货单仍是草稿");
        assertWaiter(taskId, employeeOf(w.superAdminUserId()), RdBomGapPort.SOURCE_SUBCONTRACT_ORDER, subcontractOrderId);
        assertEquals(3, waiterCount(taskId));

        // ⑤ 旧生产计划确认执行计划包: 按缺口生成委外申请前同样 409, 确认人进等待名单。
        var planWorld = fixture.seedWorld(tag + "-plan");
        fixture.loginAs(planWorld.superAdminUserId());
        UUID planId = ReflectionTestUtils.invokeMethod(fixture, "approvedPlan", planWorld, f, "10", "10");
        mine.add(planId);
        PlanningPreviewResult planPreview = planningPackages.preview(planId, planWorld.warehouseId());
        ApiException planBlocked = assertThrows(ApiException.class, () -> planningPackages.confirm(planId,
                packageRequest(planWorld.warehouseId(), tag + "-package-blocked-" + planId, planPreview)));
        assertEquals(ErrorCode.CONFLICT, planBlocked.getCode());
        assertTrue(planBlocked.getMessage().contains(sLabel + " " + BOM_MISSING_TEXT), planBlocked.getMessage());
        assertEquals(0, count("SELECT COUNT(*) FROM production_planning_packages WHERE plan_id=?", planId),
                "被拒的确认整体回滚");
        assertWaiter(taskId, employeeOf(planWorld.superAdminUserId()), RdBomGapPort.SOURCE_PRODUCTION_PLAN, planId);
        assertEquals(4, waiterCount(taskId));
        assertEquals("OPEN", theOnlyBomTask(s).get("status"), "所有被挡的路径共用同一条研发任务");

        // ⑥ 研发在货品资料里给 S 加直属边 S → M ×2(按件、开工投入), 投递 outbox。
        fixture.loginAs(w.superAdminUserId());
        var edge = new BomItemSaveRequest();
        edge.setComponentGoodsId(m);
        edge.setQty(new BigDecimal("2"));
        edge.setControlStage("START");
        edge.setConsumptionBasis("PER_UNIT");
        boms.create(s, edge);
        assertTrue(hasDrawableEdges(s), "S 现在有可发外直属边");
        drainOutboxFor(mine);

        // 研发任务自动完成。
        Map<String, Object> done = theOnlyBomTask(s);
        assertEquals("DONE", done.get("status"), "研发保存 BOM 后「完善 BOM」任务自动完成");
        assertNotNull(done.get("completed_at"));

        // 两张分析各自经一条 MATERIAL_ANALYSIS_BOM_REFRESH 事件自动刷新, 组件表展开出 M。
        for (Map.Entry<UUID, UUID> analysisAndMaker : Map.of(analysis1, planner1, analysis2, planner2).entrySet()) {
            UUID analysisId = analysisAndMaker.getKey();
            assertTrue(count("""
                    SELECT COUNT(*) FROM business_outbox
                    WHERE event_type='MATERIAL_ANALYSIS_BOM_REFRESH' AND status=1
                      AND (aggregate_id=? OR payload::text LIKE ?)
                    """, analysisId, "%" + analysisId + "%") >= 1,
                    "每张分析一条自己的自动刷新事件且已投递: " + analysisId);
            assertEquals(1, count("""
                    SELECT COUNT(*) FROM production_material_analysis_materials
                    WHERE analysis_id=? AND goods_id=? AND active AND node_role='BOM_COMPONENT'
                    """, analysisId, m), "自动刷新后 S 下面展开出直属物料 M: " + analysisId);
            fixture.loginAs(analysisAndMaker.getValue());
            AnalysisView refreshed = analyses.detail(analysisId);
            MaterialView refreshedS = row(refreshed, s);
            assertFalse(refreshedS.bomMissing(), "S 不再缺 BOM");
            assertNull(refreshedS.rdTaskNo(), "研发任务已完成, 行上不再挂任务编号");
            MaterialView mRow = refreshed.flatMaterials().stream()
                    .filter(row -> m.equals(row.goodsId()) && s.equals(row.parentGoodsId()))
                    .findFirst().orElseThrow(() -> new AssertionError("分析里缺 S 的直属物料 M: " + analysisId));
            assertEquals("BUY", mRow.sourceSuggestion(), "M 按货品资料走采购");
        }

        // 等待名单里每个人都收到「BOM 已完善」通知, 直达自己被挡住的单据。
        assertBomReadyNotice(planner1, s, "/production/material-analysis?analysisId=" + analysis1);
        assertBomReadyNotice(planner2, s, "/production/material-analysis?analysisId=" + analysis2);
        assertBomReadyNotice(w.superAdminUserId(), s, "/subcontract/orders/" + subcontractOrderId);
        assertBomReadyNotice(planWorld.superAdminUserId(), s, "/production/plans/" + planId);

        // ⑦ 放行: 甲下达委外建出委外申请。
        fixture.loginAs(planner1);
        AnalysisView reRouted = confirmSubcontractRoute(analysis1, s, tag + "-route-a1-after");
        analysisCommands.notifySupply(analysis1, new NotifyRequest(reRouted.version(), reRouted.fingerprint(),
                tag + "-notify-a1-after", "SUBCONTRACT", List.of(row(reRouted, s).materialLineId()), List.of(), null));
        assertEquals(1, count("""
                SELECT COUNT(*) FROM preplan_supply_actions
                WHERE analysis_id=? AND route='SUBCONTRACT' AND status='CREATED'
                  AND external_document_type='SUBCONTRACT_APPLICATION' AND external_document_id IS NOT NULL
                """, analysis1), "BOM 完善后下达委外落真实委外申请");

        // 委外订货单: 明细不再标缺 BOM, 送财务放行; 批准按新 BOM 冻结 M 的领料计划行(计划量 = CEIL4(10 × 2))。
        fixture.loginAs(w.superAdminUserId());
        assertFalse(subcontractOrders.detail(subcontractOrderId).getItems().getFirst().isBomMissing());
        financeApproval.submit("SUBCONTRACT", subcontractOrderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", subcontractOrderId);
        fixture.loginAs(w.superAdminUserId());
        List<Map<String, Object>> planLines = db.queryForList("""
                SELECT line.goods_id, line.planned_qty
                FROM subcontract_material_plan_items line
                JOIN subcontract_order_items item ON item.id = line.order_item_id
                WHERE item.order_id=? AND NOT line.is_deleted
                """, subcontractOrderId);
        assertEquals(1, planLines.size(), "一种直属物料一条冻结计划行, 现状 " + planLines);
        assertEquals(m, planLines.getFirst().get("goods_id"));
        qty("20", planLines.getFirst().get("planned_qty"), "M 计划量");

        // 执行计划包确认: 委外申请照常生成。
        fixture.loginAs(planWorld.superAdminUserId());
        PlanningPreviewResult planPreviewAfter = planningPackages.preview(planId, planWorld.warehouseId());
        PlanningPackageResult confirmed = planningPackages.confirm(planId,
                packageRequest(planWorld.warehouseId(), tag + "-package-after-" + planId, planPreviewAfter));
        assertNotNull(confirmed.subcontractApplication(), "BOM 完善后计划包按缺口生成委外申请");
    }

    // =====================================================================================
    // BUY 父件下面没有需求的委外子件不转研发(审核意见 analysis/AN-3)
    // =====================================================================================

    @Test
    void aSubcontractChildWithoutDemandUnderABoughtParentIsNotForwardedToRd() {
        String tag = "scnobom-nodemand";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID f = goods(w, "F-" + tag, "成品F-" + tag, "自制");
        UUID x = goods(w, "X-" + tag, "外购组件X-" + tag, "采购");
        UUID y = goods(w, "Y-" + tag, "委外件Y-" + tag, "委外");
        fixture.insertBom(f, x, "1");
        fixture.insertBom(x, y, "1");
        assertFalse(hasDrawableEdges(y));
        UUID planner = fixture.createUserWithPerms(w, tag + "-planner", PLANNER_PERMISSIONS);
        UUID salesItem = salesItemOf(fixture.createApprovedOrder(w, f, "10", "100"));

        fixture.loginAs(planner);
        AnalysisView view = preview(w, salesItem, tag + "-a");
        assertEquals("BUY", row(view, x).sourceSuggestion(), "X 整件外购");
        MaterialView yRow = row(view, y);
        assertEquals(0, yRow.requiredQty().signum(), "外购父件不展开需求, Y 需求为 0");
        assertEquals(0, count("SELECT COUNT(*) FROM rd_tasks WHERE goods_id=? AND NOT is_deleted", y),
                "没有需求的委外节点永远不会下达, 不转研发、不打扰工程研发部");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM rd_task_forwarders forwarder
                JOIN rd_tasks task ON task.id = forwarder.rd_task_id
                WHERE task.goods_id=? AND forwarder.reporter_employee_id=?
                """, y, employeeOf(planner)), "计划员也不进等待名单");
    }

    // =====================================================================================
    // 夹具
    // =====================================================================================

    private UUID goods(FullChainEndToEndTest.World w, String code, String name, String sourceType) {
        UUID id = UUID.randomUUID();
        fixture.insertGoods(id, code, name, sourceType, w.unitId(), w.unitLegacy());
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?", w.supplierId(), id);
        return id;
    }

    private boolean hasDrawableEdges(UUID goodsId) {
        return Boolean.TRUE.equals(db.queryForObject(
                "SELECT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(?))", Boolean.class, goodsId));
    }

    private UUID salesItemOf(UUID salesOrderId) {
        return db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, salesOrderId);
    }

    private UUID employeeOf(UUID userId) {
        return db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, userId);
    }

    private AnalysisView preview(FullChainEndToEndTest.World w, UUID salesItemId, String key) {
        return analyses.preview(new PreviewRequest(null, null, null, w.warehouseId(), key + "-" + salesItemId,
                List.of(new PreviewItem("SALES_ORDER_ITEM", salesItemId, null, null, null, null, null,
                        BusinessTime.today().plusDays(20), new BigDecimal("10")))));
    }

    private static MaterialView row(AnalysisView view, UUID goodsId) {
        List<MaterialView> rows = view.flatMaterials().stream()
                .filter(material -> goodsId.equals(material.goodsId())).toList();
        assertEquals(1, rows.size(), "分析里该货品应当恰好一个节点, 现状 " + rows.size());
        return rows.getFirst();
    }

    /** 把 S 的路线确认为委外(与页面「确认路线」同一入口), 返回确认后的分析。 */
    private AnalysisView confirmSubcontractRoute(UUID analysisId, UUID goodsId, String key) {
        AnalysisView current = analyses.detail(analysisId);
        MaterialView line = row(current, goodsId);
        return analyses.saveRoutes(analysisId, new RouteRequest(current.version(), current.fingerprint(), key,
                List.of(new RouteDecision(line.materialLineId(), line.actionGroupKey(), "SUBCONTRACT", null))));
    }

    private UUID subcontractOrder(FullChainEndToEndTest.World w, UUID goodsId, String qty) {
        var request = new OrderSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setDeliverDate(BusinessTime.today().plusDays(10));
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId"));
        var line = new OrderItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("50"));
        request.setItems(List.of(line));
        return subcontractOrders.create(request).getId();
    }

    private static GeneratePlanningPackageRequest packageRequest(UUID warehouseId, String key,
                                                                 PlanningPreviewResult preview) {
        var request = new GeneratePlanningPackageRequest();
        request.setWarehouseId(warehouseId);
        request.setIdempotencyKey(key);
        request.setPreviewFingerprint(preview.fingerprint());
        request.setGeneratePurchaseRequest(true);
        return request;
    }

    private Map<String, Object> theOnlyBomTask(UUID goodsId) {
        List<Map<String, Object>> tasks = db.queryForList("""
                SELECT id, task_no, status, category, source_doc_type, source_doc_id, completed_at
                FROM rd_tasks WHERE goods_id=? AND category='BOM' AND NOT is_deleted
                """, goodsId);
        assertEquals(1, tasks.size(), "同一货品只有一条「完善 BOM」研发任务, 现状 " + tasks);
        return tasks.getFirst();
    }

    private int waiterCount(UUID taskId) {
        return count("SELECT COUNT(*) FROM rd_task_forwarders WHERE rd_task_id=?", taskId);
    }

    private void assertWaiter(UUID taskId, UUID employeeId, String sourceType, UUID sourceId) {
        List<Map<String, Object>> waiters = db.queryForList("""
                SELECT source_doc_type, source_doc_id FROM rd_task_forwarders
                WHERE rd_task_id=? AND reporter_employee_id=?
                """, taskId, employeeId);
        assertEquals(1, waiters.size(), "等待名单里每人一行, 现状 " + waiters);
        assertEquals(sourceType, waiters.getFirst().get("source_doc_type"), "等待人被挡住的来源单据类型");
        assertEquals(sourceId, waiters.getFirst().get("source_doc_id"), "等待人被挡住的来源单据");
    }

    private void assertBomReadyNotice(UUID audienceUserId, UUID goodsId, String route) {
        String code = db.queryForObject("SELECT code FROM goods WHERE id=?", String.class, goodsId);
        List<Map<String, Object>> notices = db.queryForList("""
                SELECT title, content, action_route FROM notices
                WHERE audience_user_id=? AND title LIKE '%BOM%' AND content LIKE ?
                """, audienceUserId, "%" + code + "%");
        assertTrue(notices.stream().anyMatch(notice -> route.equals(notice.get("action_route"))),
                "等待人收到「BOM 已完善」通知且直达被挡住的单据 " + route + ", 现状 " + notices);
    }

    /**
     * 投递 outbox 直到本用例自己的聚合(货品、分析、研发任务、订货单、计划)以及载荷里点名它们的事件都投完;
     * 共享库里别的用例的积压也会顺带投掉。投递期间的瞬时冲突不算失败, 下一轮重投。
     */
    private void drainOutboxFor(Collection<UUID> aggregateIds) {
        String ids = "{" + aggregateIds.stream().map(UUID::toString).collect(Collectors.joining(",")) + "}";
        String patterns = "{" + aggregateIds.stream().map(id -> "%" + id + "%").collect(Collectors.joining(",")) + "}";
        String mineSql = "(aggregate_id = ANY(CAST(? AS uuid[])) OR payload::text LIKE ANY(CAST(? AS text[])))";
        long deadline = System.currentTimeMillis() + 120_000;
        while (true) {
            db.update("UPDATE business_outbox SET available_at=now() WHERE status=0 AND available_at>now()");
            try {
                for (int i = 0; i < 500 && outbox.processNext(); i++) {
                    // 投到取不出为止
                }
            } catch (RuntimeException transientDeliveryFailure) {
                // 瞬时冲突: 下一轮抹平退避后重投。
            }
            int pending = count("SELECT COUNT(*) FROM business_outbox WHERE status=0 AND " + mineSql, ids, patterns);
            if (pending == 0) {
                break;
            }
            if (System.currentTimeMillis() > deadline) {
                fail("本用例的 outbox 事件没有投递完: " + db.queryForList(
                        "SELECT event_type, attempts, last_error FROM business_outbox WHERE status=0 AND " + mineSql,
                        ids, patterns));
            }
            try {
                Thread.sleep(50);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                fail("等待 outbox 投递时被中断");
            }
        }
        List<Map<String, Object>> dead = db.queryForList(
                "SELECT event_type, last_error FROM business_outbox WHERE status=2 AND " + mineSql, ids, patterns);
        assertTrue(dead.isEmpty(), "本用例有 outbox 事件投递失败进了死信: " + dead);
    }

    private int count(String sql, Object... args) {
        Integer n = db.queryForObject(sql, Integer.class, args);
        return n == null ? 0 : n;
    }

    private static void qty(String expected, Object actual, String what) {
        assertNotNull(actual, what + ": 现状 null, 期望 " + expected);
        BigDecimal value = actual instanceof BigDecimal decimal ? decimal : new BigDecimal(actual.toString());
        assertEquals(0, new BigDecimal(expected).compareTo(value), what + ": 现状 " + value + " 期望 " + expected);
    }
}
