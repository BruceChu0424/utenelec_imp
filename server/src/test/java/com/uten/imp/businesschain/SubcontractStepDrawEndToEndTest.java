package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.NotifyRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.request.dto.RequestItemLine;
import com.uten.imp.features.purchase.request.dto.RequestSaveRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawCloseRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawItemRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPendingDraft;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPreview;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPreviewLine;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPreviewRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPreviewTask;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSubmitRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSubmitResult;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskMaterial;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskMaterials;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskPage;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskRow;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawWithdrawRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawWithdrawResult;
import com.uten.imp.features.subcontract.draw.SubcontractDrawQueryService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueDetail;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemDto;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest;
import com.uten.imp.features.subcontract.order.SubcontractOrderProgressService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskDetail;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalDecisionRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterResult;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
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
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * ADR-143 §八 委外按工序领直属物料、齐套通知、分批回厂的真库全链验收。
 *
 * <p>主链: 委外件 P 的两种直属物料 A(自制, 单耗 1)与 B(采购, 单耗 2)。批准冻结两条领料计划行
 * (计划量 = CEIL4(Q × b)), 不建草稿; A 完工入库、B 到货一半 → 可领部分套数 → 委外人员提交领料, 每仓一张
 * 新草稿并写 requested_qty → 仓库少发 B(只能改少) → 审核出仓, 已领按「已发齐的完整套数」→ B 再到货 →
 * 第二次领料只补落后的 B → 领满 → 分批回厂、来料质检、仓库确认入库, 逐种按目标核销, 红冲中间一批再回厂
 * 不被尾差拦住 → 最后一批关单, 成本 FINAL。每一步都断言行级恒等式 已领 + 待仓库发 + 可领 + 还缺 = 订货数量。
 *
 * <p>其余用例: 撤回未发领料(撤回后拿旧幂等键重发 409, 新键建新草稿)与结束领料后短交重评; 材料退货后再领与
 * 超过可回厂量转财务(委外商自带料); 批准后改量扩缩(缩量先撤回待发领料); 同一批量领料两个任务抢同一种物料时
 * 默认值能直接提交; BOM 边颜色为空时冻结物料默认颜色; 嵌套委外(直属物料本身是委外件)回厂入库后父件变可领;
 * 仓库整行不发(软删保留提交量, 发料回执列少发, 下次补齐); 仓库改过的草稿只能由仓库整张「退回委外」, 结束领料
 * 不论改没改过都撤回; 两张分析合并成一个订货明细时领用的料按回厂先进先出归属。
 *
 * <p>A 的「完工入库」用其它入库单表示(与车间成品入库走同一个库存内核入库钩子, 同样追加领料重算),
 * B 走真实采购订货 → 到货登记 → 来料质检 → 仓库确认入库。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractStepDrawEndToEndTest {

    private static final String DRAW_ROUTE = "/operations/workbench/subcontract?segment=DRAW&orderItemId=";

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractOrderService orders;
    @Autowired SubcontractOrderProgressService orderProgress;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired SubcontractDrawQueryService drawQueries;
    @Autowired SubcontractDrawCommandService drawCommands;
    @Autowired SubcontractMaterialPlanService plans;
    @Autowired SubcontractMaterialIssueService materialIssues;
    @Autowired SubcontractMaterialReturnService materialReturns;
    @Autowired SubcontractReceiptService subcontractReceipts;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired ProcurementArrivalControlService arrivalControl;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcStockInService iqcStockIn;
    @Autowired StockDocService stockDocs;
    @Autowired PurchaseRequestService purchaseRequests;
    @Autowired PurchaseOrderService purchaseOrders;
    @Autowired BusinessOutboxProcessor outbox;
    @Autowired InventoryValueWorkService inventoryValueWork;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService analysisCommands;
    @Autowired PlatformTransactionManager transactions;

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
    // 主链
    // =====================================================================================

    @Test
    void twoMaterialsDrawInBatchesWarehouseShortIssueTopsUpAndBatchReturnsCloseWithFinalCost() {
        String tag = "scstep-main";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "自制");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID w1 = w.warehouseId();
        UUID w2 = warehouse(tag + "-2");
        Set<UUID> mine = new LinkedHashSet<>(List.of(p, a, b));

        // ① B 已下采购订货 200(在途); 委外订货 P 100 获财务批准: 按可发外直属边冻结两条计划行, 不建草稿。
        PurchaseLine purchase = approvedPurchase(w, w2, b, "200", tag);
        UUID orderId = subcontractOrder(w, p, "100", BusinessTime.today().plusDays(10), null);
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_material_plans WHERE order_id=?", orderId),
                "送审前不建领料计划");
        approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        mine.add(item);
        Map<UUID, Map<String, Object>> lines = planLines(item);
        assertEquals(Set.of(a, b), lines.keySet(), "两种直属物料各一条冻结计划行");
        qty("1", lines.get(a).get("bom_unit_qty"), "A 冻结单耗");
        qty("100", lines.get(a).get("planned_qty"), "A 计划量 = CEIL4(100 × 1)");
        qty("2", lines.get(b).get("bom_unit_qty"), "B 冻结单耗");
        qty("200", lines.get(b).get("planned_qty"), "B 计划量 = CEIL4(100 × 2)");
        qty("0", lines.get(a).get("issued_qty"), "A 已发净量");
        qty("0", lines.get(b).get("issued_qty"), "B 已发净量");
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_material_issue_items WHERE order_item_id=?", item),
                "财务批准不再自动建出仓草稿, 领料只由委外人员提交");
        assertTrue(count("""
                SELECT COUNT(*) FROM business_outbox
                WHERE event_type='SUBCONTRACT_DRAW_RECHECK' AND aggregate_id IN (?, ?)
                """, a, b) >= 2, "批准后按冻结物料追加领料重算事件");

        // ② 无库存: A 没有任何在途供应 → 等计划安排; B 的供应来源是采购在途 200。
        DrawTaskRow row = taskRow(orderId);
        assertRow(row, "0", "0", "0", "100", "WAITING_PLANNING");
        assertEquals(2, row.materialKindCount(), "物料种数");
        assertEquals(0, row.readyKindCount(), "已备种数");
        assertEquals(2, row.shortKindCount(), "还缺种数");
        assertEquals(1, row.unplannedShortKindCount(), "只有 A 没有在途供应");
        assertFalse(row.canDraw(), "没有可领就不能勾选领料");
        DrawTaskMaterials detail = drawQueries.materials(item);
        DrawTaskMaterial ma = material(detail, a);
        DrawTaskMaterial mb = material(detail, b);
        assertEquals("SHORT", ma.state());
        qty("100", ma.shortQty(), "A 还缺");
        assertTrue(ma.supplySources().isEmpty(), "A 没有在途 → 页面显示「未安排」");
        assertEquals("SHORT", mb.state());
        qty("200", mb.shortQty(), "B 还缺");
        assertTrue(mb.supplySources().stream().anyMatch(source -> "PURCHASE".equals(source.kind())
                        && purchase.orderId().equals(source.docId())
                        && source.openQty().compareTo(new BigDecimal("200")) == 0),
                "B 的供应来源列出采购在途 200, 现状 " + mb.supplySources());
        assertTrue(detail.pendingDrafts().isEmpty(), "还没有待仓库发的领料");
        assertTrue(detail.allowedActions().contains("CLOSE"), "开放且未发满的明细可以结束领料");
        assertFalse(detail.allowedActions().contains("WITHDRAW"), "没有待发领料不能撤回");
        DrawTaskPage page = drawQueries.tasks(1, 20, "", "", orderId, null);
        assertEquals(1L, page.statusCounts().get("WAITING_PLANNING"), "分段计数按订货单筛选");
        assertEquals(1L, page.statusCounts().get("ALL"));

        // ③ A 完工入库 100(仓 1): A 已备, B 还缺但有采购在途 → 等待物料。
        otherIn(w, w1, a, null, "100", "10");
        row = taskRow(orderId);
        assertRow(row, "0", "0", "0", "100", "WAITING_MATERIAL");
        assertEquals(1, row.readyKindCount(), "A 已备");
        assertEquals(0, row.unplannedShortKindCount(), "B 有在途, 不再等计划安排");

        // ④ B 到货一半 80(仓 2): 来料质检合格 → 仓库确认入库 → 按短板可领 40 套(部分可领)。
        receivePurchase(w, w2, b, purchase.orderItemId(), "80", tag + "-b1");
        row = taskRow(orderId);
        assertRow(row, "0", "0", "40", "60", "DRAWABLE_PARTIAL");
        assertTrue(row.canDraw(), "有可领且有领料权限才能勾选");
        detail = drawQueries.materials(item);
        ma = material(detail, a);
        qty("100", ma.availableQty(), "A 仓库可用");
        qty("40", ma.drawableQty(), "A 本次可领 = f(40,1)");
        qty("0", ma.shortQty(), "A 还缺");
        assertEquals("DRAWABLE", ma.state());
        mb = material(detail, b);
        qty("80", mb.availableQty(), "B 仓库可用");
        qty("80", mb.drawableQty(), "B 本次可领 = f(40,2)");
        qty("120", mb.shortQty(), "B 还缺");
        assertEquals("SHORT", mb.state());
        assertTrue(drawQueries.countDrawable() >= 1, "「领料」红数含本任务");
        drainOutboxFor(mine);
        assertDrawAvailableCard(item, w.superAdminUserId(), "可领 40");
        qty("40", markOf(item), "可领提醒水位");

        // 没有委外领料权限的人: 红数恒为 0、能力位为假、提交被拒。
        UUID viewer = fixture.createUserWithPerms(w, tag + "-viewer", "subcontract_order:view", "notice:read");
        fixture.loginAs(viewer);
        assertEquals(0L, drawQueries.countDrawable(), "无领料权限红数恒为 0");
        assertFalse(drawQueries.tasks(1, 20, "", "", null, null).capabilities().canSubmitDraw(),
                "无领料权限能力位为假");
        ApiException forbidden = assertThrows(ApiException.class, () -> drawCommands.submit(
                new DrawSubmitRequest(List.of(new DrawItemRequest(item, null)), "scstep-viewer-" + item)));
        assertEquals(ErrorCode.FORBIDDEN, forbidden.getCode());
        fixture.loginAs(w.superAdminUserId());

        // ⑤ 预览: 默认本批可领 40, 按「订货单 × 仓库」预计两张出仓单; 填 41 被拒并给出实时值。
        DrawPreview preview = drawQueries.preview(new DrawPreviewRequest(List.of(new DrawItemRequest(item, null))));
        DrawPreviewTask previewTask = preview.tasks().getFirst();
        qty("40", previewTask.drawableQty(), "预览单任务可领");
        qty("40", previewTask.batchDrawableQty(), "预览本批可领");
        qty("40", previewTask.qty(), "默认本次领料 = 本批可领");
        assertEquals(2, preview.documentCount(), "A 在仓 1、B 在仓 2: 两张出仓单");
        qty("40", previewQty(preview, a, w1), "预览 A 从仓 1 领 40");
        qty("80", previewQty(preview, b, w2), "预览 B 从仓 2 领 80");
        ApiException tooMuch = assertThrows(ApiException.class, () -> drawQueries.preview(
                new DrawPreviewRequest(List.of(new DrawItemRequest(item, new BigDecimal("41"))))));
        assertEquals(ErrorCode.CONFLICT, tooMuch.getCode());
        assertTrue(tooMuch.getMessage().contains("本批可领 40"), tooMuch.getMessage());

        // ⑥ 提交: 每仓一张新草稿、写 requested_qty、占用库存、每张草稿通知所在仓库; 同幂等键重放原样返回。
        String firstKey = "scstep-main-draw-1-" + item;
        DrawSubmitResult first = drawCommands.submit(
                new DrawSubmitRequest(List.of(new DrawItemRequest(item, null)), firstKey));
        assertFalse(first.replayed());
        assertEquals(2, first.documentCount());
        mine.addAll(first.issueIds());
        DrawSubmitResult replay = drawCommands.submit(
                new DrawSubmitRequest(List.of(new DrawItemRequest(item, null)), firstKey));
        assertTrue(replay.replayed(), "同一幂等键是重放");
        assertEquals(first.issueIds(), replay.issueIds(), "重放返回原草稿");
        assertEquals(first.issueBillNos(), replay.issueBillNos());
        UUID draftA = draftIn(first.issueIds(), w1);
        UUID draftB = draftIn(first.issueIds(), w2);
        assertDraftLine(draftA, a, "40", "40");
        assertDraftLine(draftB, b, "80", "80");
        for (UUID draft : first.issueIds()) {
            Map<String, Object> header = db.queryForMap("""
                    SELECT status, is_deleted, maker_id, owner_pool, remark, created_by
                    FROM subcontract_material_issues WHERE id=?
                    """, draft);
            assertEquals(0, ((Number) header.get("status")).intValue(), "草稿待仓库发");
            assertEquals(Boolean.FALSE, header.get("is_deleted"));
            assertNull(header.get("maker_id"), "仓库待发池草稿没有个人归属");
            assertEquals("WAREHOUSE_SUBCONTRACT_OUTBOUND", header.get("owner_pool"));
            assertEquals("委外领料", header.get("remark"));
            assertEquals(w.superAdminUserId(), header.get("created_by"), "建单人 = 提交领料的人");
            assertEquals(1, count("""
                    SELECT COUNT(*) FROM business_outbox WHERE event_type='SUBCONTRACT_OUTBOUND_READY' AND aggregate_id=?
                    """, draft), "每张草稿只通知一次所在仓库");
        }
        qty("40", reserved(draftA), "A 草稿占用");
        qty("80", reserved(draftB), "B 草稿占用");
        row = taskRow(orderId);
        assertRow(row, "0", "40", "0", "60", "DRAW_SUBMITTED");
        drainOutboxFor(mine);
        assertNoDrawAvailableCard(item, w.superAdminUserId());
        qty("0", markOf(item), "提交后可领 0, 提醒水位降为 0");
        detail = drawQueries.materials(item);
        assertEquals(2, detail.pendingDrafts().size(), "任务详情列出两张待仓库发的草稿");
        assertTrue(detail.allowedActions().contains("WITHDRAW"), "有待发领料可以撤回");
        String orderNo = billNo(orderId);
        assertEquals(2, plans.tasks(1, 50, orderNo, null).getItems().size(), "仓库委外出仓工作台一张草稿一行");
        OutboundTaskDetail pick = plans.taskDetail(draftB);
        qty("80", pick.lines().getFirst().requestedQty(), "拣货页显示委外人员提交的数量");

        // ⑦ 仓库少发 B: 只能改少(80 → 60), 改多被拒; 改少后只占 60, 释放的 20 又够 10 套。
        ApiException raised = assertThrows(ApiException.class, () -> warehousePick(draftB, b, "81"));
        assertEquals(ErrorCode.CONFLICT, raised.getCode());
        assertTrue(raised.getMessage().contains("仓库只能少发不能多发"), raised.getMessage());
        warehousePick(draftB, b, "60");
        assertDraftLine(draftB, b, "60", "80");
        qty("60", reserved(draftB), "改少后立即只占 60");
        row = taskRow(orderId);
        assertRow(row, "0", "30", "10", "60", "DRAWABLE_PARTIAL");
        detail = drawQueries.materials(item);
        assertTrue(pendingDraft(detail, draftB).edited(), "仓库改少过的草稿标「仓库已改过」");
        assertFalse(pendingDraft(detail, draftA).edited(), "仓库没动过的草稿不标");
        assertTrue(detail.allowedActions().contains("WITHDRAW"), "还有一张没被仓库改过的草稿, 仍给「撤回」");
        // 仓库已改过拣货的草稿不能撤回(整次撤回回滚, 另一张草稿也原样保留), 提示去请仓库退回。
        ApiException edited = assertThrows(ApiException.class,
                () -> drawCommands.withdraw(new DrawWithdrawRequest(List.of(item))));
        assertEquals(ErrorCode.CONFLICT, edited.getCode());
        assertTrue(edited.getMessage().contains("仓库已开始拣货并修改过") && edited.getMessage().contains("退回"),
                edited.getMessage());
        assertEquals(2, count("""
                SELECT COUNT(*) FROM subcontract_material_issues WHERE id IN (?, ?) AND status=0 AND NOT is_deleted
                """, draftA, draftB), "撤回被拒后两张草稿都还在");
        qty("40", reserved(draftA), "撤回被拒不释放 A 的占用");

        // ⑧ 仓库审核发出: 已发净量 A 40 / B 60, 已领 = 已发齐的完整套数 30; 发料回执写明少发。
        materialIssues.approve(draftA);
        materialIssues.approve(draftB);
        lines = planLines(item);
        qty("40", lines.get(a).get("issued_qty"), "A 已发净量");
        qty("60", lines.get(b).get("issued_qty"), "B 已发净量");
        row = taskRow(orderId);
        assertRow(row, "30", "0", "10", "60", "DRAWABLE_PARTIAL");
        qty("60", onHand(a, w1), "仓 1 的 A 剩 60");
        qty("20", onHand(b, w2), "仓 2 的 B 剩 20");
        drainOutboxFor(mine);
        List<String> completions = db.queryForList("""
                SELECT content FROM notices WHERE audience_user_id=? AND title=?
                """, String.class, w.superAdminUserId(), "委外直属物料已发出：" + orderNo);
        assertTrue(completions.stream().anyMatch(text -> text.contains("少发") && text.contains("下次领料自动补齐")),
                "B 少发时发料回执要写明少发并提示下次自动补齐, 现状 " + completions);

        // ⑨ B 再到货 120: 可领重算为剩余全部 70, 提醒按更高的可领量刷新。
        receivePurchase(w, w2, b, purchase.orderItemId(), "120", tag + "-b2");
        row = taskRow(orderId);
        assertRow(row, "30", "0", "70", "0", "DRAWABLE");
        drainOutboxFor(mine);
        assertDrawAvailableCard(item, w.superAdminUserId(), "可领 70");
        qty("70", markOf(item), "可领提醒水位抬到 70");

        // ⑩ 第二次只领 10 套: 领先的 A 已够 40 套不多发, 只补齐落后的 B(再发 20)。
        DrawPreview topUp = drawQueries.preview(new DrawPreviewRequest(
                List.of(new DrawItemRequest(item, new BigDecimal("10")))));
        assertEquals(1, topUp.lines().size(), "只补 B 一种物料, 现状 " + topUp.lines());
        DrawPreviewLine topUpLine = topUp.lines().getFirst();
        assertEquals(b, topUpLine.goodsId());
        assertEquals(w2, topUpLine.warehouseId());
        qty("20", topUpLine.qty(), "B 补 f(40,2) − 60 = 20");
        DrawSubmitResult second = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, new BigDecimal("10"))), "scstep-main-draw-2-" + item));
        assertEquals(1, second.documentCount());
        mine.addAll(second.issueIds());
        assertDraftLine(second.issueIds().getFirst(), b, "20", "20");
        materialIssues.approve(second.issueIds().getFirst());
        row = taskRow(orderId);
        assertRow(row, "40", "0", "60", "0", "DRAWABLE");

        // ⑪ 第三次领满剩余 60 套: 两种物料都发齐, 任务离开「领料」。
        DrawSubmitResult third = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-main-draw-3-" + item));
        assertEquals(2, third.documentCount());
        mine.addAll(third.issueIds());
        assertDraftLine(draftIn(third.issueIds(), w1), a, "60", "60");
        assertDraftLine(draftIn(third.issueIds(), w2), b, "120", "120");
        for (UUID draft : third.issueIds()) {
            materialIssues.approve(draft);
        }
        lines = planLines(item);
        qty("100", lines.get(a).get("issued_qty"), "A 发满");
        qty("200", lines.get(b).get("issued_qty"), "B 发满");
        assertNull(taskRow(orderId), "发满后不再是领料任务");
        detail = drawQueries.materials(item);
        assertEquals("SENT_FULL", material(detail, a).state());
        assertEquals("SENT_FULL", material(detail, b).state());
        assertIdentity(detail.task(), "发满后");
        qty("100", detail.task().drawnQty(), "已领 100");
        qty("100", returnable(item), "委外商处物料可做成 100 套");

        // ⑫ 分批回厂第一批 30: 物料口径 30, 逐种按目标核销 A 30 / B 60; 来料质检 → 仓库确认入库。
        Receipt r1 = registerReturn(w, item, p, "30", tag + "-r1");
        qty("30", materialBasis(r1.receiptItemId()), "第一批物料口径回厂量");
        qty("30", consumed(item, a), "A 核销 f(30,1)");
        qty("60", consumed(item, b), "B 核销 f(30,2)");
        stockIn("SUBCONTRACT", r1.receiptId(), passIqc("SUBCONTRACT", r1.receiptId(), tag + "-r1-pass"),
                tag + "-r1-stock", w1);

        // ⑬ 第二批 40 回厂、质检已判但未入库时红冲: 核销按记录的切片原样退回; 再回厂 40 不因尾差被拦。
        Receipt r2 = registerReturn(w, item, p, "40", tag + "-r2");
        qty("70", consumed(item, a), "第二批后 A 累计核销");
        qty("140", consumed(item, b), "第二批后 B 累计核销");
        passIqc("SUBCONTRACT", r2.receiptId(), tag + "-r2-pass");
        subcontractReceipts.reverse(r2.receiptId());
        qty("30", consumed(item, a), "红冲后 A 核销退回");
        qty("60", consumed(item, b), "红冲后 B 核销退回");
        assertTrue(count("""
                SELECT COUNT(*) FROM subcontract_receipt_material_consumptions
                WHERE receipt_item_id=? AND reversal_of IS NOT NULL
                """, r2.receiptItemId()) >= 2, "两种物料的核销切片都按原样冲回");
        Map<String, Object> basis = db.queryForMap("SELECT * FROM fn_subcontract_receipt_basis(?)", item);
        qty("30", (BigDecimal) basis.get("basis_qty"), "有效回厂物料口径 R");
        assertEquals(1, ((Number) basis.get("reversed_line_count")).intValue(), "一条红冲回厂行");
        Receipt r3 = registerReturn(w, item, p, "40", tag + "-r3");
        qty("70", consumed(item, a), "再回厂后 A 累计核销 f(70,1)");
        qty("140", consumed(item, b), "再回厂后 B 累计核销 f(70,2)");
        stockIn("SUBCONTRACT", r3.receiptId(), passIqc("SUBCONTRACT", r3.receiptId(), tag + "-r3-pass"),
                tag + "-r3-stock", w1);

        // ⑭ 最后一批 30: 累计回厂 100 = 订货量, 合格入库后关单; 委外商处结存归零; 成本 FINAL。
        Receipt r4 = registerReturn(w, item, p, "30", tag + "-r4");
        qty("100", consumed(item, a), "A 全部核销");
        qty("200", consumed(item, b), "B 全部核销");
        assertFalse(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, orderId),
                "结案按实际合格入库量: 最后一批还在质检, 不关单");
        stockIn("SUBCONTRACT", r4.receiptId(), passIqc("SUBCONTRACT", r4.receiptId(), tag + "-r4-pass"),
                tag + "-r4-stock", w1);
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, orderId),
                "合格入库 30 + 40 + 30 = 订货量 100, 订货单关单");
        qty("100", onHand(p, w1), "三批合格入库 30 + 40 + 30");
        qty("0", supplierEnding(item), "委外商处物料结存归零");
        qty("100", db.queryForObject("SELECT received_qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, item),
                "订货明细已收净量");
        InventoryValueWorkTestSupport.drain(inventoryValueWork, db, List.of(p, a, b));
        for (Receipt receipt : List.of(r1, r3, r4)) {
            assertEquals(Boolean.TRUE, db.queryForObject("SELECT fn_subcontract_receipt_material_complete(?)",
                    Boolean.class, receipt.receiptItemId()), "每种冻结物料都核销到目标: 物料成本完整");
            assertEquals("FINAL", db.queryForObject("""
                    SELECT state FROM stock_value_production_cost_objects WHERE execution_segment_id=?
                    """, String.class, receipt.receiptItemId()), "领料制回厂明细计价 FINAL");
        }
        var itemProgress = orderProgress.progress(orderId).items().getFirst();
        assertEquals("DRAW", itemProgress.materialMode());
        qty("100", itemProgress.drawnQty(), "进度: 已领");
        qty("100", itemProgress.receivedQty(), "进度: 已回厂");
    }

    // =====================================================================================
    // 撤回未发领料; 结束领料后短交重评
    // =====================================================================================

    @Test
    void withdrawRestoresDrawableAndCloseDrawWithdrawsPendingClosesLinesAndSettlesTolerableShortDelivery() {
        String tag = "scstep-close";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "自制");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID wh = w.warehouseId();
        Set<UUID> mine = new LinkedHashSet<>(List.of(p, a, b));
        otherIn(w, wh, a, null, "10", "10");
        otherIn(w, wh, b, null, "19", "5");
        UUID orderId = subcontractOrder(w, p, "10", BusinessTime.today().plusDays(5), new BigDecimal("10"));
        approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        mine.add(item);

        // 发 9.5 套(B 只够 19 → 9.5 套), 回厂 9 并入库: 料没发完不判短交。
        DrawTaskRow row = taskRow(orderId);
        assertRow(row, "0", "0", "9.5", "0.5", "DRAWABLE_PARTIAL");
        DrawSubmitResult issued = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-close-draw-1-" + item));
        issued.issueIds().forEach(materialIssues::approve);
        Receipt receipt = registerReturn(w, item, p, "9", tag + "-r1");
        stockIn("SUBCONTRACT", receipt.receiptId(), passIqc("SUBCONTRACT", receipt.receiptId(), tag + "-pass"),
                tag + "-stock", wh);
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_short_delivery_cases WHERE order_item_id=?", item),
                "料没发完(9.5/10)不开短交案件");

        // B 再到 1: 又够 0.5 套。提交后撤回: 草稿作废、占用释放、可领恢复、通知仓库已撤回。
        otherIn(w, wh, b, null, "1", "5");
        row = taskRow(orderId);
        assertRow(row, "9.5", "0", "0.5", "0", "DRAWABLE");
        DrawSubmitResult pending = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-close-draw-2-" + item));
        UUID withdrawnDraft = pending.issueIds().getFirst();
        mine.add(withdrawnDraft);
        assertRow(taskRow(orderId), "9.5", "0.5", "0", "0", "DRAW_SUBMITTED");
        DrawWithdrawResult withdrawn = drawCommands.withdraw(new DrawWithdrawRequest(List.of(item)));
        assertEquals(List.of(withdrawnDraft), withdrawn.withdrawnIssueIds());
        assertEquals(2, withdrawn.removedLineCount(), "撤回 A、B 两行");
        assertEquals(Boolean.TRUE, db.queryForObject("SELECT is_deleted FROM subcontract_material_issues WHERE id=?",
                Boolean.class, withdrawnDraft), "整张草稿撤空即作废");
        qty("0", reserved(withdrawnDraft), "撤回后不再占用库存");
        assertTrue(count("""
                SELECT COUNT(*) FROM stock_reservations
                WHERE source_doc_type='SUBCONTRACT_OUTBOUND_DRAFT' AND source_doc_id=?
                  AND status=1 AND release_reason='SUBCONTRACT_DRAW_WITHDRAWN'
                """, withdrawnDraft) >= 2, "两种物料的占用都以「撤回」原因释放");
        assertEquals(1, count("""
                SELECT COUNT(*) FROM business_outbox WHERE event_type='SUBCONTRACT_DRAW_WITHDRAWN' AND aggregate_id=?
                """, withdrawnDraft), "撤回通知草稿所在仓库");
        assertRow(taskRow(orderId), "9.5", "0", "0.5", "0", "DRAWABLE");
        ApiException nothing = assertThrows(ApiException.class,
                () -> drawCommands.withdraw(new DrawWithdrawRequest(List.of(item))));
        assertEquals(ErrorCode.CONFLICT, nothing.getCode(), "没有待发领料时撤回 409");

        // 撤回后已领 / 可领回到提交前的值, 页面若还拿旧幂等键重发: 不能当成「已提交过」静默成功,
        // 而是 409 让页面重新打开(换新键); 不建草稿、不占库存。
        ApiException stale = assertThrows(ApiException.class, () -> drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-close-draw-2-" + item)));
        assertEquals(ErrorCode.CONFLICT, stale.getCode());
        assertTrue(stale.getMessage().contains("已撤回或已变化"), stale.getMessage());
        assertEquals(Boolean.TRUE, db.queryForObject("SELECT is_deleted FROM subcontract_material_issues WHERE id=?",
                Boolean.class, withdrawnDraft), "旧草稿不会被复活");
        assertRow(taskRow(orderId), "9.5", "0", "0.5", "0", "DRAWABLE");

        // 再提交一次(新幂等键 → 新草稿, 待仓库发), 然后结束领料: 撤回未发领料、关闭计划行、按「料已发完」重评短交。
        DrawSubmitResult again = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-close-draw-3-" + item));
        assertFalse(again.replayed(), "新幂等键是一次新提交");
        UUID closedDraft = again.issueIds().getFirst();
        assertNotEquals(withdrawnDraft, closedDraft, "撤回后重新领料建出新草稿");
        assertRow(taskRow(orderId), "9.5", "0.5", "0", "0", "DRAW_SUBMITTED");
        mine.add(closedDraft);
        ApiException blank = assertThrows(ApiException.class,
                () -> drawCommands.close(item, new DrawCloseRequest("  ")));
        assertEquals(ErrorCode.VALIDATION_FAILED, blank.getCode(), "结束领料必须填原因");
        assertTrue(drawCommands.close(item, new DrawCloseRequest("委外商剩余半套不做了")).closed());
        assertEquals(Boolean.TRUE, db.queryForObject("SELECT is_deleted FROM subcontract_material_issues WHERE id=?",
                Boolean.class, closedDraft), "结束领料先撤回未发领料");
        qty("0", reserved(closedDraft), "结束领料释放占用");
        assertEquals(2, count("""
                SELECT COUNT(*) FROM subcontract_material_plan_items
                WHERE order_item_id=? AND NOT is_deleted AND draw_closed_at IS NOT NULL
                  AND draw_close_reason='委外商剩余半套不做了' AND draw_closed_by=?
                """, item, w.superAdminUserId()), "两条计划行都结束领料并记原因与操作人");
        assertNull(taskRow(orderId), "结束领料后不再出现在「领料」");
        Map<String, Object> summary = db.queryForMap("SELECT * FROM fn_subcontract_draw_summary(?)", item);
        assertEquals(Boolean.FALSE, summary.get("any_open"));
        qty("0", (BigDecimal) summary.get("drawable_qty"), "结束领料后可领 0");
        Map<String, Object> shortCase = db.queryForMap("""
                SELECT status, severity, loss_qty, waste_id FROM subcontract_short_delivery_cases
                WHERE order_item_id=? ORDER BY detected_at DESC LIMIT 1
                """, item);
        assertEquals("ACCEPTED_LOSS", shortCase.get("status"),
                "结束领料后按「料已发完」重评: 回厂 9 ≥ 下限 9, 按约定损耗自动结案");
        qty("1", (BigDecimal) shortCase.get("loss_qty"), "损耗 1 套");
        UUID wasteId = (UUID) shortCase.get("waste_id");
        assertNotNull(wasteId, "结案开损耗单");
        Map<UUID, BigDecimal> wasted = new HashMap<>();
        db.queryForList("SELECT goods_id, SUM(qty) AS qty FROM subcontract_waste_items WHERE waste_id=? GROUP BY goods_id",
                wasteId).forEach(r -> wasted.put((UUID) r.get("goods_id"), (BigDecimal) r.get("qty")));
        qty("0.5", wasted.get(a), "整单结损耗记委外商处 A 的全部剩余");
        qty("1", wasted.get(b), "整单结损耗记委外商处 B 的全部剩余(不按短交量 × 单耗重算)");
        qty("0", supplierEnding(item), "委外商处结存清零");
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, orderId),
                "合格回厂 9 + 损耗 1 = 订货 10, 关单");
        drainOutboxFor(mine);
        assertNoDrawAvailableCard(item, w.superAdminUserId());
        assertEquals(0, count("""
                SELECT COUNT(*) FROM notices
                WHERE source_event='SUBCONTRACT_DRAW_WITHDRAWN'
                  AND title IN (SELECT '委外领料已撤回：' || bill_no FROM subcontract_material_issues WHERE id IN (?, ?))
                  AND action_route IS DISTINCT FROM '/warehouse/subcontract-outbound'
                """, withdrawnDraft, closedDraft), "整张撤回的草稿已作废, 「已撤回」通知链接待发料列表而不是作废草稿的拣货页");
    }

    // =====================================================================================
    // 材料退货后再领; 超过可回厂量转财务(委外商自带料)
    // =====================================================================================

    @Test
    void materialReturnReopensTheDrawAndAReturnBeyondReturnableGoesToFinanceAsSupplierOwnMaterial() {
        String tag = "scstep-return";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "自制");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID wh = w.warehouseId();
        otherIn(w, wh, a, null, "10", "10");
        otherIn(w, wh, b, null, "20", "5");
        UUID orderId = subcontractOrder(w, p, "10", BusinessTime.today().plusDays(5), null);
        approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        DrawSubmitResult drawn = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-return-draw-1-" + item));
        drawn.issueIds().forEach(materialIssues::approve);
        assertNull(taskRow(orderId), "两种物料发满");
        qty("10", returnable(item), "可回厂 10");

        // 委外商退回 B 4: 已发净量 20 → 16, 已领按完整套数降到 8, 退回入库后又可领 2 套。
        UUID issueItemB = db.queryForObject("""
                SELECT item.id FROM subcontract_material_issue_items item
                WHERE item.order_item_id=? AND item.goods_id=? AND NOT item.is_deleted
                """, UUID.class, item, b);
        UUID returnId = materialReturn(w, wh, item, p, b, issueItemB, "4");
        qty("16", planLines(item).get(b).get("issued_qty"), "材料退货审核扣减已发净量");
        qty("8", returnable(item), "可回厂按委外商处 B 的完整套数 = 8");
        DrawTaskRow row = taskRow(orderId);
        assertNotNull(row, "退料让明细重新出现在「领料」");
        assertRow(row, "8", "0", "2", "0", "DRAWABLE");

        // 回厂 9 > 可回厂 8: 整单隔离、转财务; 超出的 1 是委外商自带料。采购允许超收快照对委外一律为空。
        WarehouseArrivalRegisterResult over = arrivals.register(arrival(w, item, p, "9", tag + "-over"));
        assertEquals("EXCESS_QUARANTINED", over.outcome(), "超过可回厂量整单隔离待财务");
        assertNotNull(over.exceptionId());
        Map<String, Object> exception = db.queryForMap("""
                SELECT status, declared_qty, approved_remaining_qty, order_qty_snapshot, allowed_over_receipt_pct_snapshot,
                       tolerance_qty_snapshot, prior_net_received_qty_snapshot
                FROM procurement_arrival_exceptions WHERE id=?
                """, over.exceptionId());
        assertEquals("PENDING_FINANCE", exception.get("status"));
        qty("9", (BigDecimal) exception.get("declared_qty"), "实到");
        qty("8", (BigDecimal) exception.get("approved_remaining_qty"), "我方物料能做出来的 8");
        assertNull(exception.get("order_qty_snapshot"), "委外不写采购允许超收快照");
        assertNull(exception.get("allowed_over_receipt_pct_snapshot"));
        assertNull(exception.get("tolerance_qty_snapshot"));
        assertNull(exception.get("prior_net_received_qty_snapshot"));
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_receipts WHERE id=? AND status=1", over.receiptId()),
                "财务定案前不审核");
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        fixture.loginAs(reviewer);
        var pendingTask = arrivalControl.financeDetail(over.exceptionId());
        var decided = arrivalControl.financeDecide(over.exceptionId(), new ArrivalDecisionRequest(
                pendingTask.version(), "APPROVE_ALL", null, "多出 1 件用的是委外商自己的材料, 按约定计价接收"));
        qty("1", decided.approvedExcessQty(), "财务批准的委外商自带料");
        fixture.loginAs(w.superAdminUserId());
        arrivalControl.stockInWithDecisionSession(over.exceptionId(),
                target -> subcontractReceipts.approveFromWarehouseDecision(target.receiptId()));
        UUID overItem = receiptItem(over.receiptId());
        qty("8", materialBasis(overItem), "物料口径 = 9 − 财务批准自带料 1");
        qty("8", consumed(item, a), "A 只核销我方物料 f(8,1)");
        qty("16", consumed(item, b), "B 只核销我方物料 f(8,2)");

        // ADR-143 §三.4a: 财务批准的自带料 1 件不用我方物料 → 我方供料套数 Qm = 10 − 1 = 9(不低于已领 8)。
        // 退回入库的 B 只再领 1 套(B 2), 不是补满原计划的 B 4; 恒等式按 Qm。
        DrawTaskRow afterOwn = taskRow(orderId);
        assertRow(afterOwn, "8", "0", "1", "0", "DRAWABLE");
        qty("10", afterOwn.orderQty(), "订货数量不变");
        qty("9", afterOwn.materialQty(), "我方供料套数 = 订货 − 财务批准自带料");
        DrawSubmitResult redraw = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-return-draw-2-" + item));
        assertEquals(1, redraw.documentCount());
        assertDraftLine(redraw.issueIds().getFirst(), b, "2", "2");
        materialIssues.approve(redraw.issueIds().getFirst());
        qty("18", planLines(item).get(b).get("issued_qty"), "B 发到我方需发量 f(9,2)");
        assertNull(taskRow(orderId), "每种物料都发到我方需发量, 明细离开「领料」");
        otherIn(w, wh, b, null, "4", "5");
        // 退料红冲把 B 4 加回会超过冻结计划量 20(18 + 4) → 409。
        ApiException reverseBlocked = assertThrows(ApiException.class, () -> materialReturns.reverse(returnId));
        assertEquals(ErrorCode.CONFLICT, reverseBlocked.getCode());
        assertTrue(reverseBlocked.getMessage().contains("退回的料已重新领出"), reverseBlocked.getMessage());
        qty("18", planLines(item).get(b).get("issued_qty"), "红冲被拒不改已发净量");
        qty("6", onHand(b, wh), "红冲被拒库存不动(退回 4 − 再领 2 + 其它入库 4)");

        // 最后 1 件回厂: 两批合格入库后关单(结案按实际合格入库量, 不按回厂登记量)。
        Receipt last = registerReturn(w, item, p, "1", tag + "-last");
        qty("1", materialBasis(last.receiptItemId()), "最后一批物料口径");
        qty("9", consumed(item, a), "A 累计核销 f(9,1)");
        qty("18", consumed(item, b), "B 累计核销 f(9,2)");
        assertFalse(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, orderId),
                "回厂 10 还没合格入库, 不关单");
        stockIn("SUBCONTRACT", over.receiptId(), passIqc("SUBCONTRACT", over.receiptId(), tag + "-over-pass"),
                tag + "-over-stock", wh);
        stockIn("SUBCONTRACT", last.receiptId(), passIqc("SUBCONTRACT", last.receiptId(), tag + "-last-pass"),
                tag + "-last-stock", wh);
        qty("10", onHand(p, wh), "合格入库 9 + 1");
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, orderId),
                "合格入库 10 = 订货量, 关单");
    }

    // =====================================================================================
    // 批准后改量: 扩量重算计划量; 缩量须先撤回待发领料; 不能低于委外商处结存折算套数
    // =====================================================================================

    @Test
    void approvedQuantityChangeRecomputesFrozenPlanLinesAndShrinkingNeedsPendingDrawsWithdrawnFirst() {
        String tag = "scstep-qty";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "自制");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID wh = w.warehouseId();
        otherIn(w, wh, a, null, "10", "10");
        otherIn(w, wh, b, null, "20", "5");
        UUID orderId = subcontractOrder(w, p, "10", BusinessTime.today().plusDays(5), null);
        UUID reviewer = approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        drawCommands.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item, new BigDecimal("4"))),
                "scstep-qty-draw-1-" + item)).issueIds().forEach(materialIssues::approve);
        DrawSubmitResult pending = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, new BigDecimal("3"))), "scstep-qty-draw-2-" + item));
        String pendingBillNo = pending.issueBillNos().getFirst();

        // 扩量 10 → 15: 每条计划行按新订货量整体重算 f(15, b), 不做增量累加。
        // ADR-156: 加量要有齐套物料; 加的 5 套在暂存仓补齐、改量后清掉。
        fixture.withSubcontractKitStaged(w, Map.of(p, "5"), () -> changeQty(orderId, item, "15"));
        reconfirm(reviewer, w, orderId);
        Map<UUID, Map<String, Object>> lines = planLines(item);
        qty("15", lines.get(a).get("planned_qty"), "A 计划量 = f(15,1)");
        qty("30", lines.get(b).get("planned_qty"), "B 计划量 = f(15,2)");
        DrawTaskRow row = taskRow(orderId);
        assertRow(row, "4", "3", "3", "5", "DRAWABLE_PARTIAL");
        qty("15", row.orderQty(), "订货数量");

        // 缩量 15 → 6: 已发 4 套 + 待仓库发 3 套 > 6 → 409 列出待撤回的领料单, 订货量与计划量不变。
        ApiException blocked = assertThrows(ApiException.class, () -> changeQty(orderId, item, "6"));
        assertEquals(ErrorCode.CONFLICT, blocked.getCode());
        assertTrue(blocked.getMessage().contains("请先撤回待仓库发的领料") && blocked.getMessage().contains(pendingBillNo),
                blocked.getMessage());
        qty("15", db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, item),
                "被拒的改量不落盘");
        qty("15", planLines(item).get(a).get("planned_qty"), "被拒的改量不改计划量");
        // 低于委外商处物料折算套数(A 4 / 1、B 8 / 2 → 4 套)的缩量同样被拒。
        ApiException belowIssued = assertThrows(ApiException.class, () -> changeQty(orderId, item, "3"));
        assertEquals(ErrorCode.CONFLICT, belowIssued.getCode());
        assertTrue(belowIssued.getMessage().contains("已锁定数量 4"), belowIssued.getMessage());

        // 先撤回待发领料再缩到 6: 计划量 f(6, b), 已发 4 套不受影响。
        drawCommands.withdraw(new DrawWithdrawRequest(List.of(item)));
        changeQty(orderId, item, "6");
        reconfirm(reviewer, w, orderId);
        lines = planLines(item);
        qty("6", lines.get(a).get("planned_qty"), "A 计划量 = f(6,1)");
        qty("12", lines.get(b).get("planned_qty"), "B 计划量 = f(6,2)");
        qty("4", lines.get(a).get("issued_qty"), "A 已发净量不变");
        qty("8", lines.get(b).get("issued_qty"), "B 已发净量不变");
        row = taskRow(orderId);
        assertRow(row, "4", "0", "2", "0", "DRAWABLE");
    }

    // =====================================================================================
    // 同一批量领料: 两个任务抢同一种物料, 按交期联合分配, 默认值直接提交成功
    // =====================================================================================

    @Test
    void twoTasksCompetingForTheSameMaterialInOneBatchSubmitTheJointlyAllocatedDefaults() {
        String tag = "scstep-joint";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "自制");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID wh = w.warehouseId();
        otherIn(w, wh, a, null, "10", "10");
        otherIn(w, wh, b, null, "14", "5");
        UUID earlyOrder = subcontractOrder(w, p, "5", BusinessTime.today().plusDays(3), null);
        UUID lateOrder = subcontractOrder(w, p, "5", BusinessTime.today().plusDays(9), null);
        approveSubcontract(w, earlyOrder);
        approveSubcontract(w, lateOrder);
        UUID early = itemOf(earlyOrder);
        UUID late = itemOf(lateOrder);
        // 各自单看都能领满 5 套(列表与通知各按当时可用量算)。
        assertRow(taskRow(earlyOrder), "0", "0", "5", "0", "DRAWABLE");
        assertRow(taskRow(lateOrder), "0", "0", "5", "0", "DRAWABLE");

        // 联合预览: 交期早的先分 B 10, 交期晚的只剩 B 4 → 本批可领 2 套。
        DrawPreview preview = drawQueries.preview(new DrawPreviewRequest(List.of(
                new DrawItemRequest(late, null), new DrawItemRequest(early, null))));
        Map<UUID, DrawPreviewTask> tasks = preview.tasks().stream()
                .collect(Collectors.toMap(DrawPreviewTask::orderItemId, task -> task));
        assertEquals(early, preview.tasks().getFirst().orderItemId(), "按交期、订货单号、行号排序");
        qty("5", tasks.get(early).drawableQty(), "早单单任务可领");
        qty("5", tasks.get(early).batchDrawableQty(), "早单本批可领");
        qty("5", tasks.get(late).drawableQty(), "晚单单任务可领");
        qty("2", tasks.get(late).batchDrawableQty(), "晚单本批可领(公共 B 已被早单分走 10)");
        qty("2", tasks.get(late).qty(), "默认值 = 联合分配后的本批可领");
        assertEquals(2, preview.documentCount(), "两张订货单各一张出仓单");
        ApiException exceeded = assertThrows(ApiException.class, () -> drawQueries.preview(new DrawPreviewRequest(List.of(
                new DrawItemRequest(early, null), new DrawItemRequest(late, new BigDecimal("3"))))));
        assertEquals(ErrorCode.CONFLICT, exceeded.getCode());
        assertTrue(exceeded.getMessage().contains("本批可领 2"), exceeded.getMessage());

        // 按默认值提交: 锁内按同一顺序重算, 成功。
        DrawSubmitResult submitted = drawCommands.submit(new DrawSubmitRequest(List.of(
                new DrawItemRequest(early, null), new DrawItemRequest(late, null)), "scstep-joint-draw-" + early));
        assertEquals(2, submitted.documentCount());
        UUID earlyDraft = draftOf(submitted.issueIds(), early);
        UUID lateDraft = draftOf(submitted.issueIds(), late);
        assertDraftLine(earlyDraft, a, "5", "5");
        assertDraftLine(earlyDraft, b, "10", "10");
        assertDraftLine(lateDraft, a, "2", "2");
        assertDraftLine(lateDraft, b, "4", "4");
        assertRow(taskRow(lateOrder), "0", "2", "0", "3", "DRAW_SUBMITTED");

        // 实时可领低于提交量: 409 并逐项给出实时值。
        otherIn(w, wh, a, null, "1", "10");
        ApiException stale = assertThrows(ApiException.class, () -> drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(late, new BigDecimal("1"))), "scstep-joint-stale-" + late)));
        assertEquals(ErrorCode.CONFLICT, stale.getCode());
        assertTrue(stale.getMessage().contains("本批可领 0"), stale.getMessage());
    }

    // =====================================================================================
    // BOM 边颜色为空: 冻结物料默认颜色, 只认该颜色的库存
    // =====================================================================================

    @Test
    void anEdgeWithoutColourFreezesTheComponentDefaultColourAndOnlyThatColourIsDrawable() {
        String tag = "scstep-colour";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID m = goods(w, tag, "M", "采购");
        db.update("UPDATE goods SET color_id=? WHERE id=?", w.colorId(), m);
        fixture.insertBom(p, m, "1");
        assertNull(db.queryForObject("SELECT color_id FROM goods_bom_items WHERE goods_id=? AND component_goods_id=?",
                UUID.class, p, m), "BOM 边本身不带颜色");
        assertEquals(w.colorId(), db.queryForObject("SELECT color_id FROM fn_subcontract_draw_edges(?)", UUID.class, p),
                "可发外边的颜色 = 物料默认颜色");
        UUID wh = w.warehouseId();
        UUID orderId = subcontractOrder(w, p, "5", BusinessTime.today().plusDays(5), null);
        approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        assertEquals(w.colorId(), db.queryForObject("""
                SELECT color_id FROM subcontract_material_plan_items WHERE order_item_id=? AND NOT is_deleted
                """, UUID.class, item), "计划行冻结物料默认颜色");

        otherIn(w, wh, m, null, "5", "5");
        assertRow(taskRow(orderId), "0", "0", "0", "5", "WAITING_PLANNING");
        otherIn(w, wh, m, w.colorId(), "5", "5");
        assertRow(taskRow(orderId), "0", "0", "5", "0", "DRAWABLE");
        DrawSubmitResult submitted = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-colour-draw-" + item));
        UUID draft = submitted.issueIds().getFirst();
        assertEquals(w.colorId(), db.queryForObject("""
                SELECT color_id FROM subcontract_material_issue_items WHERE issue_id=? AND NOT is_deleted
                """, UUID.class, draft), "领料行带冻结颜色");
        assertEquals(1, count("""
                SELECT COUNT(DISTINCT color_id) FROM stock_reservations
                WHERE source_doc_type='SUBCONTRACT_OUTBOUND_DRAFT' AND source_doc_id=? AND status=0 AND color_id=?
                """, draft, w.colorId()), "只占用该颜色的库存");
        materialIssues.approve(draft);
        qty("0", onHand(m, wh, w.colorId()), "发出的是有颜色的那 5 个");
        qty("5", onHand(m, wh, null), "无色库存不动");
    }

    // =====================================================================================
    // 嵌套委外: 直属物料 C 本身是委外件, C 回厂入库后父件 P 变可领
    // =====================================================================================

    @Test
    void aNestedSubcontractMaterialBecomesDrawableForItsParentOnceItsOwnReturnIsStocked() {
        String tag = "scstep-nested";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID c = goods(w, tag, "C", "委外");
        UUID d = goods(w, tag, "D", "采购");
        fixture.insertBom(p, c, "1");
        fixture.insertBom(c, d, "2");
        UUID wh = w.warehouseId();
        Set<UUID> mine = new LinkedHashSet<>(List.of(p, c, d));
        UUID childOrder = subcontractOrder(w, c, "10", BusinessTime.today().plusDays(3), null);
        approveSubcontract(w, childOrder);
        UUID childItem = itemOf(childOrder);
        UUID parentOrder = subcontractOrder(w, p, "10", BusinessTime.today().plusDays(9), null);
        approveSubcontract(w, parentOrder);
        UUID parentItem = itemOf(parentOrder);
        mine.add(parentItem);

        // P 的直属物料 C 有委外在途(C 的订货单) → 等待物料, 供应来源是委外。
        assertRow(taskRow(parentOrder), "0", "0", "0", "10", "WAITING_MATERIAL");
        DrawTaskMaterial cMaterial = material(drawQueries.materials(parentItem), c);
        assertTrue(cMaterial.supplySources().stream().anyMatch(source -> "SUBCONTRACT".equals(source.kind())
                        && childOrder.equals(source.docId())),
                "C 的供应来源是委外在途订货单, 现状 " + cMaterial.supplySources());

        // C 自己的委外任务: 领 D、发外、回厂、质检、入库。
        otherIn(w, wh, d, null, "20", "5");
        drawCommands.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(childItem, null)),
                "scstep-nested-child-" + childItem)).issueIds().forEach(materialIssues::approve);
        Receipt childReturn = registerReturn(w, childItem, c, "10", tag + "-c");
        // 回厂登记 10 = 订货量但还在质检: 结案按合格入库量, C 的订货单不关, 仍是 P 的委外在途。
        assertFalse(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, childOrder),
                "C 的第一张回厂单还在质检, 不能按登记量关单");
        assertTrue(material(drawQueries.materials(parentItem), c).supplySources().stream()
                        .anyMatch(source -> "SUBCONTRACT".equals(source.kind()) && childOrder.equals(source.docId())),
                "C 回厂待检期间仍是委外在途");
        assertRow(taskRow(parentOrder), "0", "0", "0", "10", "WAITING_MATERIAL");
        stockIn("SUBCONTRACT", childReturn.receiptId(),
                passIqc("SUBCONTRACT", childReturn.receiptId(), tag + "-c-pass"), tag + "-c-stock", wh);

        // C 合格入库 → P 可领 10 套, 委外人员收到可领提醒。
        assertRow(taskRow(parentOrder), "0", "0", "10", "0", "DRAWABLE");
        drainOutboxFor(mine);
        assertDrawAvailableCard(parentItem, w.superAdminUserId(), "可领 10");
        DrawSubmitResult submitted = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(parentItem, null)), "scstep-nested-parent-" + parentItem));
        assertDraftLine(submitted.issueIds().getFirst(), c, "10", "10");
    }

    // =====================================================================================
    // 可领提醒水位只记卡上写的数: 重算读到可领之后、发卡之前物料被用掉, 不能「水位抬了、卡没发」
    // =====================================================================================

    /**
     * 2026-10-06 CI 分区 1(上面嵌套委外用例偶发「现状 []」): 批准时的领料重算读到可领 10(下单时补齐的物料
     * 还在), 发卡前这批物料被出库, 卡按实时 0 只撤卡, 水位却记成重算读到的 10; 之后物料再入库算出 10 = 水位,
     * 再也不发卡。这里用水位行锁把重算固定在「读完可领、取水位」之间, 期间出库再放行: 水位只能记卡上的 0,
     * 物料再到时照常提醒。
     */
    @Test
    void materialUsedUpBetweenTheRecheckAndTheCardLeavesTheMarkAtWhatTheCardShows() throws Exception {
        String tag = "scstep-mark-race";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "采购");
        fixture.insertBom(p, a, "1");
        Set<UUID> mine = new LinkedHashSet<>(List.of(p, a));
        // 下单那一刻 A 是齐的(暂存仓补齐); 由本用例自己决定何时清掉, 不交给批准顺带清。
        var stage = fixture.stageSubcontractKit(w, Map.of(p, "10"));
        UUID orderId = orders.create(orderRequest(w, p, "10", BusinessTime.today().plusDays(5), null)).getId();
        UUID item = itemOf(orderId);
        mine.add(item);
        db.update("INSERT INTO subcontract_draw_notice_marks(order_item_id) VALUES (?)", item);
        var markLocked = new CountDownLatch(1);
        var releaseMark = new CountDownLatch(1);
        var holderPid = new java.util.concurrent.atomic.AtomicInteger();
        try (var holder = Executors.newSingleThreadExecutor()) {
            var held = holder.submit(() -> new TransactionTemplate(transactions).executeWithoutResult(status -> {
                holderPid.set(db.queryForObject("SELECT pg_backend_pid()", Integer.class));
                db.queryForObject("SELECT notified_drawable FROM subcontract_draw_notice_marks WHERE order_item_id=? FOR UPDATE",
                        BigDecimal.class, item);
                markLocked.countDown();
                try {
                    assertTrue(releaseMark.await(60, TimeUnit.SECONDS));
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new AssertionError(interrupted);
                }
            }));
            try {
                assertTrue(markLocked.await(60, TimeUnit.SECONDS));
                // 批准追加领料重算; 投递时读到可领 10(暂存的 A), 停在被占住的水位行上。
                approveSubcontract(w, orderId);
                awaitBlockedBy(holderPid.get(), "批准后的领料重算没有停在水位行锁上");
                fixture.releaseSubcontractKitStage(stage);
            } finally {
                releaseMark.countDown();
            }
            held.get(60, TimeUnit.SECONDS);
        }
        drainOutboxFor(mine);
        assertNoDrawAvailableCard(item, w.superAdminUserId());
        qty("0", db.queryForObject("SELECT notified_drawable FROM subcontract_draw_notice_marks WHERE order_item_id=?",
                BigDecimal.class, item), "发卡时 A 已出库, 卡只撤不发, 水位记卡上的 0");
        otherIn(w, w.warehouseId(), a, null, "10", "5");
        drainOutboxFor(mine);
        assertDrawAvailableCard(item, w.superAdminUserId(), "可领 10");
    }

    // =====================================================================================
    // 仓库整行不发: 软删保留提交量, 发料回执列出少发, 下次领料自动补齐
    // =====================================================================================

    @Test
    void aWholeLineTheWarehouseDropsKeepsItsRequestForTheShortIssueReceiptAndTheNextDrawTopsItUp() {
        String tag = "scstep-drop";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "自制");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID wh = w.warehouseId();
        Set<UUID> mine = new LinkedHashSet<>(List.of(p, a, b));
        otherIn(w, wh, a, null, "10", "10");
        otherIn(w, wh, b, null, "20", "5");
        UUID orderId = subcontractOrder(w, p, "10", BusinessTime.today().plusDays(5), null);
        approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        mine.add(item);
        DrawSubmitResult submitted = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-drop-draw-1-" + item));
        UUID draft = submitted.issueIds().getFirst();
        mine.add(draft);
        assertDraftLine(draft, a, "10", "10");
        assertDraftLine(draft, b, "20", "20");

        // 仓库发现 B 料损: 拣货页把 B 整行去掉(数量填 0 = 本次不发, 页面不回传这一行), 只发 A。
        warehouseDrop(draft, b);
        Map<String, Object> dropped = db.queryForMap("""
                SELECT is_deleted, warehouse_dropped_at, qty, requested_qty
                FROM subcontract_material_issue_items WHERE issue_id=? AND goods_id=?
                """, draft, b);
        assertEquals(Boolean.TRUE, dropped.get("is_deleted"), "不发的行软删, 不再参与库存与计划同步");
        assertNotNull(dropped.get("warehouse_dropped_at"), "记下「仓库整行不发」, 与委外撤回区分开");
        qty("20", dropped.get("requested_qty"), "提交的领料量原样保留, 发料回执据此列出少发");
        qty("10", reserved(draft, a), "A 照常占用");
        qty("0", reserved(draft, b), "不发的 B 立即释放占用");
        assertRow(taskRow(orderId), "0", "0", "10", "0", "DRAWABLE");
        DrawTaskMaterials detail = drawQueries.materials(item);
        assertTrue(pendingDraft(detail, draft).edited(), "整行不发也算仓库改过");
        assertFalse(detail.allowedActions().contains("WITHDRAW"), "唯一的待发草稿仓库改过 → 不给委外「撤回」");

        // 整张都不发不能靠删光物料行: 409 指向拣货页「退回委外」。
        ApiException dropAll = assertThrows(ApiException.class, () -> warehouseDrop(draft, a));
        assertEquals(ErrorCode.CONFLICT, dropAll.getCode());
        assertTrue(dropAll.getMessage().contains("退回"), dropAll.getMessage());

        // 审核出仓只发 A 10: 已领 0 套(B 一点没发), 发料回执写明少发 B 20、下次自动补齐。
        materialIssues.approve(draft);
        Map<UUID, Map<String, Object>> lines = planLines(item);
        qty("10", lines.get(a).get("issued_qty"), "A 已发净量");
        qty("0", lines.get(b).get("issued_qty"), "B 没发");
        assertRow(taskRow(orderId), "0", "0", "10", "0", "DRAWABLE");
        drainOutboxFor(mine);
        String orderNo = billNo(orderId);
        List<String> completions = db.queryForList("""
                SELECT content FROM notices WHERE audience_user_id=? AND title=?
                """, String.class, w.superAdminUserId(), "委外直属物料已发出：" + orderNo);
        assertTrue(completions.stream().anyMatch(text -> text.contains("少发") && text.contains("B-" + tag)
                        && text.contains("20") && text.contains("下次领料自动补齐")),
                "整行不发的 B 也要列进少发, 现状 " + completions);

        // 第二次领料只补落后的 B 20, 不多发 A。
        DrawPreview topUp = drawQueries.preview(new DrawPreviewRequest(List.of(new DrawItemRequest(item, null))));
        assertEquals(1, topUp.lines().size(), "只补 B, 现状 " + topUp.lines());
        assertEquals(b, topUp.lines().getFirst().goodsId());
        qty("20", topUp.lines().getFirst().qty(), "B 补 20");
        DrawSubmitResult second = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-drop-draw-2-" + item));
        assertDraftLine(second.issueIds().getFirst(), b, "20", "20");
        materialIssues.approve(second.issueIds().getFirst());
        assertNull(taskRow(orderId), "两种物料都发满");
        qty("10", returnable(item), "委外商处物料可做成 10 套");
    }

    // =====================================================================================
    // 仓库改过的草稿: 委外撤回不了, 仓库整张「退回委外」; 结束领料不论改没改过都撤回
    // =====================================================================================

    @Test
    void aWarehouseEditedDraftIsReturnedByTheWarehouseAndCloseDrawWithdrawsEvenAnEditedDraft() {
        String tag = "scstep-return-draw";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "自制");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID wh = w.warehouseId();
        Set<UUID> mine = new LinkedHashSet<>(List.of(p, a, b));
        otherIn(w, wh, a, null, "10", "10");
        otherIn(w, wh, b, null, "20", "5");
        UUID orderId = subcontractOrder(w, p, "10", BusinessTime.today().plusDays(5), null);
        approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        mine.add(item);
        DrawSubmitResult submitted = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-return-draw-1-" + item));
        UUID draft = submitted.issueIds().getFirst();
        mine.add(draft);

        // 仓库把 B 改少到 12 并保存: 委外撤回 409(提示请仓库退回), 任务详情不再给「撤回」, 「结束领料」照给。
        warehousePick(draft, b, "12");
        ApiException edited = assertThrows(ApiException.class,
                () -> drawCommands.withdraw(new DrawWithdrawRequest(List.of(item))));
        assertEquals(ErrorCode.CONFLICT, edited.getCode());
        assertTrue(edited.getMessage().contains("退回"), edited.getMessage());
        DrawTaskMaterials detail = drawQueries.materials(item);
        assertTrue(pendingDraft(detail, draft).edited());
        assertFalse(detail.allowedActions().contains("WITHDRAW"), "点了必然 409 的「撤回」不给");
        assertTrue(detail.allowedActions().contains("CLOSE"));

        // 退回必须写原因; 只有委外出仓执行权限的人能退回。
        ApiException blank = assertThrows(ApiException.class, () -> drawCommands.returnToDraw(draft, "  "));
        assertEquals(ErrorCode.VALIDATION_FAILED, blank.getCode());
        UUID viewer = fixture.createUserWithPerms(w, tag + "-viewer", "subcontract_outbound:view");
        fixture.loginAs(viewer);
        ApiException forbidden = assertThrows(ApiException.class, () -> drawCommands.returnToDraw(draft, "料损"));
        assertEquals(ErrorCode.FORBIDDEN, forbidden.getCode());
        fixture.loginAs(w.superAdminUserId());

        // 仓库整张退回: 草稿作废、全部占用释放、通知提交领料的人、可领恢复。
        DrawWithdrawResult returned = drawCommands.returnToDraw(draft, "B 料损, 本次不发");
        assertEquals(List.of(draft), returned.withdrawnIssueIds());
        assertEquals(2, returned.removedLineCount(), "A、B 两行一起退回");
        assertEquals(Boolean.TRUE, db.queryForObject("SELECT is_deleted FROM subcontract_material_issues WHERE id=?",
                Boolean.class, draft), "整张退回即作废");
        qty("0", reserved(draft), "退回后不再占用库存");
        assertTrue(count("""
                SELECT COUNT(*) FROM stock_reservations
                WHERE source_doc_type='SUBCONTRACT_OUTBOUND_DRAFT' AND source_doc_id=?
                  AND status=1 AND release_reason='SUBCONTRACT_DRAW_RETURNED_BY_WAREHOUSE'
                """, draft) >= 2, "两种物料的占用都以「仓库退回」原因释放");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM subcontract_material_issue_items
                WHERE issue_id=? AND warehouse_dropped_at IS NOT NULL
                """, draft), "整张退回不算「整行不发」, 不进少发");
        assertEquals(1, count("""
                SELECT COUNT(*) FROM business_outbox WHERE event_type='SUBCONTRACT_DRAW_RETURNED' AND aggregate_id=?
                """, draft), "通知提交领料的委外人员一次");
        assertRow(taskRow(orderId), "0", "0", "10", "0", "DRAWABLE");
        ApiException twice = assertThrows(ApiException.class, () -> drawCommands.returnToDraw(draft, "重复退回"));
        assertEquals(ErrorCode.NOT_FOUND, twice.getCode(), "已退回的草稿不在仓库待发池里");
        drainOutboxFor(mine);
        List<Map<String, Object>> returnedNotices = db.queryForList("""
                SELECT title, content, action_route FROM notices
                WHERE audience_user_id=? AND source_event='SUBCONTRACT_DRAW_RETURNED' AND title=?
                """, w.superAdminUserId(), "仓库退回了领料：" + billNo(orderId));
        assertTrue(returnedNotices.stream().anyMatch(notice -> String.valueOf(notice.get("content")).contains("B 料损")
                        && (DRAW_ROUTE + item).equals(notice.get("action_route"))),
                "提交领料的人收到带原因的退回通知, 直达「领料」分段的这条任务, 现状 " + returnedNotices);

        // 重新领料(新键 → 新草稿); 仓库又改过; 结束领料照样撤回它、释放占用、关闭计划行。
        DrawSubmitResult again = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-return-draw-2-" + item));
        UUID secondDraft = again.issueIds().getFirst();
        mine.add(secondDraft);
        assertNotEquals(draft, secondDraft);
        warehousePick(secondDraft, b, "12");
        assertTrue(drawCommands.close(item, new DrawCloseRequest("委外商停产, 不再发外")).closed());
        assertEquals(Boolean.TRUE, db.queryForObject("SELECT is_deleted FROM subcontract_material_issues WHERE id=?",
                Boolean.class, secondDraft), "结束领料就是不再发, 仓库改过的草稿也一并撤回");
        qty("0", reserved(secondDraft), "结束领料释放占用");
        assertEquals(2, count("""
                SELECT COUNT(*) FROM subcontract_material_plan_items
                WHERE order_item_id=? AND NOT is_deleted AND draw_closed_at IS NOT NULL
                """, item), "两条计划行都结束领料");
        assertNull(taskRow(orderId), "结束领料后不再出现在「领料」");
    }

    // =====================================================================================
    // 两张分析合并成一个订货明细: 领用的料按回厂先进先出归属, 后一张分析仍要补料
    // =====================================================================================

    @Test
    void twoAnalysesMergedIntoOneOrderItemAttributeConsumedMaterialFifoSoTheLaterAnalysisStillNeedsItsMaterial() {
        String tag = "scstep-merge";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID fa = goods(w, tag, "FA", "自制");
        UUID fb = goods(w, tag, "FB", "自制");
        UUID p = goods(w, tag, "P", "委外");
        UUID m = goods(w, tag, "M", "采购");
        fixture.insertBom(fa, p, "1");
        fixture.insertBom(fb, p, "1");
        fixture.insertBom(p, m, "1");
        UUID wh = w.warehouseId();

        // 两张分析各要 P 10: A1 交期早(先来源), A2 交期晚; 各自下达委外申请。
        PreviewItem source1 = new PreviewItem("OTHER", null, fa, null, w.unitId(), "MERGE-1-" + tag, "合并订货明细回归",
                BusinessTime.today().plusDays(3), new BigDecimal("10"));
        PreviewItem source2 = new PreviewItem("OTHER", null, fb, null, w.unitId(), "MERGE-2-" + tag, "合并订货明细回归",
                BusinessTime.today().plusDays(9), new BigDecimal("10"));
        UUID analysis1 = notifySubcontract(w, source1, p, tag + "-a1");
        UUID analysis2 = notifySubcontract(w, source2, p, tag + "-a2");
        UUID application1 = applicationItemOf(analysis1, p);
        UUID application2 = applicationItemOf(analysis2, p);

        // 委外人员把两张申请合并成一行订货 20; 批准冻结 M 计划量 20。
        var request = new OrderSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setDeliverDate(BusinessTime.today().plusDays(9));
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(wh);
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(settlementMethod());
        var line = new OrderItemLine();
        line.setGoodsId(p);
        line.setApplicationItemId(application1);
        line.setApplicationItemIds(List.of(application1, application2));
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("20"));
        line.setPrice(new BigDecimal("30"));
        request.setItems(List.of(line));
        var stage = fixture.stageSubcontractKit(w, Map.of(p, "20"));
        UUID orderId = orders.create(request).getId();
        fixture.stageSubcontractKitUntilApproval(orderId, stage);
        approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        assertEquals(2, count("SELECT COUNT(*) FROM subcontract_order_item_sources WHERE order_item_id=?", item),
                "一个订货明细合并了两张申请");
        qty("20", planLines(item).get(m).get("planned_qty"), "M 计划量 = 20");

        // M 公共库存 10: 领 10 套(全部来自公共库存, 没有专属交接)并发出; 委外商交回 10 个 P, 合格入库。
        otherIn(w, wh, m, null, "10", "5");
        DrawSubmitResult drawn = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, new BigDecimal("10"))), "scstep-merge-draw-" + item));
        drawn.issueIds().forEach(materialIssues::approve);
        qty("10", planLines(item).get(m).get("issued_qty"), "M 已发 10");
        qty("0", onHand(m, wh), "M 公共库存全部领走");
        Receipt receipt = registerReturn(w, item, p, "10", tag + "-r1");
        stockIn("SUBCONTRACT", receipt.receiptId(), passIqc("SUBCONTRACT", receipt.receiptId(), tag + "-r1-pass"),
                tag + "-r1-stock", wh);
        qty("10", onHand(p, wh), "回厂 10 合格入库");

        // 回厂按来源先进先出归 A1: A1 的 P 已满足, 不再需要 M; 发出的 10 套料已做进 A1 的 P,
        // A2 的 P 还要 10, 它的 M 一点没被覆盖, 还缺 10(不能被按比例分走的 5 套虚增成「已备」)。
        AnalysisView refreshed1 = refresh(analysis1, wh, source1, tag + "-a1-refresh");
        AnalysisView refreshed2 = refresh(analysis2, wh, source2, tag + "-a2-refresh");
        MaterialView m1 = childRow(refreshed1, m, p);
        MaterialView m2 = childRow(refreshed2, m, p);
        qty("0", m1.shortageQty(), "A1 的 M 不再缺");
        qty("10", m2.requiredQty(), "A2 的 P 还要 10 → M 需求 10");
        qty("10", m2.shortageQty(), "已领的料按先进先出做进了 A1 的 P, A2 的 M 还缺 10");
    }

    // =====================================================================================
    // 停用叶仓里还有货(例如停用后被红冲退回): 领料候选仓、锁发现、草稿占用同一个仓谓词
    // =====================================================================================

    @Test
    void aDisabledLeafStillHoldingStockIsDrawableAndItsDraftCanBeEditedAndIssuedInPlace() {
        String tag = "scstep-disabled";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID m = goods(w, tag, "M", "采购");
        fixture.insertBom(p, m, "1");
        UUID off = warehouse(tag + "-off");
        otherIn(w, off, m, null, "5", "5");
        disableKeepingStock(off);
        assertEquals(Boolean.FALSE, db.queryForObject("SELECT fn_warehouse_is_good_stock_leaf(?)", Boolean.class, off),
                "停用仓不能再被新选");
        assertEquals(Boolean.TRUE, db.queryForObject("SELECT fn_warehouse_counts_as_usable(?)", Boolean.class, off),
                "停用叶仓的既有库存仍计入可用量(V540 / ADR-146)");

        UUID orderId = subcontractOrder(w, p, "5", BusinessTime.today().plusDays(5), null);
        approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        assertRow(taskRow(orderId), "0", "0", "5", "0", "DRAWABLE");

        // 系统分出来的仓就是这个停用叶仓; 草稿占用与候选仓同一谓词, 提交不能 409。
        DrawSubmitResult submitted = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-disabled-draw-" + item));
        assertEquals(1, submitted.documentCount());
        UUID draft = submitted.issueIds().getFirst();
        assertEquals(off, db.queryForObject("SELECT warehouse_id FROM subcontract_material_issues WHERE id=?",
                UUID.class, draft), "出仓草稿落在停用叶仓");
        assertDraftLine(draft, m, "5", "5");
        qty("5", reserved(draft, m), "草稿在停用叶仓占用 5");

        // 仓库沿用原仓改少: require(原仓, 原仓) 不要求仍启用, 重整占用也不能拒。
        warehousePick(draft, m, "4");
        qty("4", reserved(draft, m), "改少后占用随之缩到 4");
        materialIssues.approve(draft);
        qty("1", onHand(m, off), "停用叶仓发出 4, 剩 1");
        qty("4", planLines(item).get(m).get("issued_qty"), "M 已发 4");
    }

    // =====================================================================================
    // 夹具
    // =====================================================================================

    private record PurchaseLine(UUID orderId, UUID orderItemId) {
    }

    private record Receipt(UUID receiptId, UUID receiptItemId) {
    }

    private record PassSlice(UUID passEventId, BigDecimal qty) {
    }

    private UUID goods(FullChainEndToEndTest.World w, String tag, String code, String sourceType) {
        UUID id = UUID.randomUUID();
        // 世界夹具已占用 A-/B-/C-/D-/E-{tag} 编号, 本类货品加前缀避开。
        String label = "SCS-" + code + "-" + tag;
        fixture.insertGoods(id, label, label, sourceType, w.unitId(), w.unitLegacy());
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?", w.supplierId(), id);
        return id;
    }

    private UUID warehouse(String tag) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id, code, name, status) VALUES (?, ?, ?, '使用')",
                id, "WH-" + tag, "测试仓库-" + tag);
        return id;
    }

    /**
     * 造出「停用叶仓里还有货」: 有库存的仓本不能停用(V800 停用前置条件), 现实里是停用后红冲把货退回;
     * 这里在一个事务里临时绕过仓库主档守卫直接停用。
     */
    private void disableKeepingStock(UUID warehouseId) {
        new TransactionTemplate(transactions).executeWithoutResult(status -> {
            db.execute("SET LOCAL session_replication_role = replica");
            db.update("UPDATE warehouses SET status='禁用' WHERE id=?", warehouseId);
        });
    }

    /** 其它入库单审核入库(库存内核入库方向, 追加领料重算)。 */
    private void otherIn(FullChainEndToEndTest.World w, UUID warehouseId, UUID goodsId, UUID colorId,
                         String qty, String price) {
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(warehouseId);
        request.setRemark("委外领料测试入库 " + qty);
        var line = new StockDocItemLine();
        line.setGoodsId(goodsId);
        line.setColorId(colorId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal(price));
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        var doc = stockDocs.create(request);
        stockDocs.approve(doc.getId());
    }

    /** 已审核采购申请 → 采购订货单 → 财务批准。 */
    private PurchaseLine approvedPurchase(FullChainEndToEndTest.World w, UUID warehouseId, UUID goodsId, String qty,
                                          String tag) {
        var request = new RequestSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(warehouseId);
        request.setDepartmentId(w.departmentId());
        request.setApplicantId(w.employeeId());
        var requestLine = new RequestItemLine();
        requestLine.setGoodsId(goodsId);
        requestLine.setUnitId(w.unitId());
        requestLine.setUnitRate(BigDecimal.ONE);
        requestLine.setQty(new BigDecimal(qty));
        request.setItems(List.of(requestLine));
        var created = purchaseRequests.create(request);
        purchaseRequests.approve(created.getId());
        UUID requestItemId = created.getItems().getFirst().getId();
        var order = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today());
        order.setSupplierId(w.supplierId());
        order.setWarehouseId(warehouseId);
        order.setCurrencyId(w.currencyId());
        order.setExchangeRate(BigDecimal.ONE);
        order.setTaxRate(BigDecimal.ZERO);
        order.setSettlementMethodId(settlementMethod());
        var orderLine = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        orderLine.setGoodsId(goodsId);
        orderLine.setRequestItemId(requestItemId);
        orderLine.setUnitId(w.unitId());
        orderLine.setUnitRate(BigDecimal.ONE);
        orderLine.setQty(new BigDecimal(qty));
        orderLine.setPrice(new BigDecimal("20"));
        order.setItems(List.of(orderLine));
        UUID orderId = purchaseOrders.createBatch(order).getFirst().getId();
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("PURCHASE", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("PURCHASE", orderId);
        fixture.loginAs(w.superAdminUserId());
        UUID orderItemId = db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?", UUID.class, orderId);
        return new PurchaseLine(orderId, orderItemId);
    }

    /** 采购到货登记 → 来料质检合格 → 仓库确认入库。 */
    private void receivePurchase(FullChainEndToEndTest.World w, UUID warehouseId, UUID goodsId, UUID orderItemId,
                                 String qty, String key) {
        WarehouseArrivalRegisterResult result = arrivals.register(new WarehouseArrivalRegisterRequest(
                "scstep-po-" + key + "-" + orderItemId, "PURCHASE", BusinessTime.today(),
                w.supplierId(), warehouseId, null, w.employeeId(), null,
                List.of(new ArrivalLine(goodsId, new BigDecimal(qty), orderItemId, null,
                        w.unitId(), BigDecimal.ONE, null, null))));
        assertEquals("SUBMITTED_FOR_INSPECTION", result.outcome(), "采购到货 " + qty + " 直接送检");
        stockIn("PURCHASE", result.receiptId(), passIqc("PURCHASE", result.receiptId(), key + "-pass"),
                key + "-stock", warehouseId);
    }

    private UUID subcontractOrder(FullChainEndToEndTest.World w, UUID goodsId, String qty, LocalDate deliverDate,
                                  BigDecimal allowedLossPct) {
        // ADR-156: 下单到财务批准时直属物料要齐。本类测的是批准之后的领料, 缺的部分在暂存仓补齐、批准后清掉,
        // 即「下单时物料是齐的, 之后被别处用掉了」。
        var stage = fixture.stageSubcontractKit(w, Map.of(goodsId, qty));
        UUID orderId = orders.create(orderRequest(w, goodsId, qty, deliverDate, allowedLossPct)).getId();
        fixture.stageSubcontractKitUntilApproval(orderId, stage);
        return orderId;
    }

    private OrderSaveRequest orderRequest(FullChainEndToEndTest.World w, UUID goodsId, String qty, LocalDate deliverDate,
                                          BigDecimal allowedLossPct) {
        var request = new OrderSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setDeliverDate(deliverDate);
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(settlementMethod());
        var line = new OrderItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("50"));
        line.setAllowedLossPct(allowedLossPct);
        request.setItems(List.of(line));
        return request;
    }

    /** 送财务并由合格审核人批准; 返回审核人(改量复核用)。 */
    private UUID approveSubcontract(FullChainEndToEndTest.World w, UUID orderId) {
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("SUBCONTRACT", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId);
        fixture.loginAs(w.superAdminUserId());
        assertEquals(1, ((Number) db.queryForObject("SELECT status FROM subcontract_orders WHERE id=?",
                Integer.class, orderId)).intValue(), "委外订货单已财务批准");
        return reviewer;
    }

    private void changeQty(UUID orderId, UUID orderItemId, String newQty) {
        orders.changeQty(orderId, new OrderQtyChangeRequest(
                List.of(new OrderQtyChangeItem(orderItemId, new BigDecimal(newQty)))));
    }

    private void reconfirm(UUID reviewer, FullChainEndToEndTest.World w, UUID orderId) {
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId);
        fixture.loginAs(w.superAdminUserId());
    }

    private UUID settlementMethod() {
        return ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId");
    }

    private UUID itemOf(UUID orderId) {
        return db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",
                UUID.class, orderId);
    }

    private String billNo(UUID orderId) {
        return db.queryForObject("SELECT bill_no FROM subcontract_orders WHERE id=?", String.class, orderId);
    }

    /** 本订货明细在「领料」里的行(按订货单筛选); 不在领料任务里返回 null。 */
    private DrawTaskRow taskRow(UUID orderId) {
        DrawTaskPage page = drawQueries.tasks(1, 50, "", "", orderId, null);
        List<DrawTaskRow> rows = page.page().getItems();
        assertTrue(rows.size() <= 1, "一张单只有一条明细, 现状 " + rows);
        if (rows.isEmpty()) {
            return null;
        }
        assertIdentity(rows.getFirst(), "列表行");
        return rows.getFirst();
    }

    private static void assertRow(DrawTaskRow row, String drawn, String pending, String drawable, String shortQty,
                                  String status) {
        assertNotNull(row, "订货明细应当在「领料」里");
        qty(drawn, row.drawnQty(), "已领");
        qty(pending, row.pendingQty(), "待仓库发");
        qty(drawable, row.drawableQty(), "可领");
        qty(shortQty, row.shortQty(), "还缺");
        assertEquals(status, row.status(), "行状态");
        assertIdentity(row, status);
    }

    /**
     * ADR-143 §三.4/§三.4a 恒等式: 已领 + 待仓库发 + 可领 + 还缺 = 我方供料套数 Qm
     * (没有财务批准的委外商自带料时 Qm = 订货数量)。
     */
    private static void assertIdentity(DrawTaskRow row, String step) {
        BigDecimal sum = row.drawnQty().add(row.pendingQty()).add(row.drawableQty()).add(row.shortQty());
        assertEquals(0, row.materialQty().compareTo(sum),
                step + ": 已领 " + row.drawnQty() + " + 待仓库发 " + row.pendingQty() + " + 可领 " + row.drawableQty()
                        + " + 还缺 " + row.shortQty() + " ≠ 我方供料套数 " + row.materialQty()
                        + "(订货数量 " + row.orderQty() + ")");
        assertTrue(row.materialQty().compareTo(row.orderQty()) <= 0, step + ": 我方供料套数不超过订货数量");
    }

    private static DrawTaskMaterial material(DrawTaskMaterials detail, UUID goodsId) {
        return detail.materials().stream().filter(material -> goodsId.equals(material.goodsId())).findFirst()
                .orElseThrow(() -> new AssertionError("任务详情缺物料 " + goodsId + ": " + detail.materials()));
    }

    private static BigDecimal previewQty(DrawPreview preview, UUID goodsId, UUID warehouseId) {
        return preview.lines().stream()
                .filter(line -> goodsId.equals(line.goodsId()) && warehouseId.equals(line.warehouseId()))
                .map(DrawPreviewLine::qty).reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    private Map<UUID, Map<String, Object>> planLines(UUID orderItemId) {
        Map<UUID, Map<String, Object>> lines = new HashMap<>();
        for (Map<String, Object> line : db.queryForList("""
                SELECT goods_id, color_id, bom_unit_qty, planned_qty, issued_qty, draw_closed_at
                FROM subcontract_material_plan_items WHERE order_item_id=? AND NOT is_deleted
                """, orderItemId)) {
            assertNull(lines.put((UUID) line.get("goods_id"), line), "同一物料只有一条计划行");
        }
        return lines;
    }

    private UUID draftIn(Collection<UUID> issueIds, UUID warehouseId) {
        List<UUID> found = issueIds.stream()
                .filter(id -> warehouseId.equals(db.queryForObject(
                        "SELECT warehouse_id FROM subcontract_material_issues WHERE id=?", UUID.class, id)))
                .toList();
        assertEquals(1, found.size(), "仓 " + warehouseId + " 应当恰好一张草稿");
        return found.getFirst();
    }

    private UUID draftOf(Collection<UUID> issueIds, UUID orderItemId) {
        List<UUID> found = issueIds.stream()
                .filter(id -> count("""
                        SELECT COUNT(*) FROM subcontract_material_issue_items
                        WHERE issue_id=? AND order_item_id=? AND NOT is_deleted
                        """, id, orderItemId) > 0)
                .toList();
        assertEquals(1, found.size(), "订货明细 " + orderItemId + " 应当恰好一张草稿");
        return found.getFirst();
    }

    private void assertDraftLine(UUID issueId, UUID goodsId, String qty, String requested) {
        Map<String, Object> line = db.queryForMap("""
                SELECT SUM(qty) AS qty, SUM(requested_qty) AS requested_qty, COUNT(*) AS lines,
                       BOOL_AND(plan_item_id IS NOT NULL) AS bound
                FROM subcontract_material_issue_items
                WHERE issue_id=? AND goods_id=? AND NOT is_deleted
                """, issueId, goodsId);
        assertEquals(1, ((Number) line.get("lines")).intValue(), "草稿里该物料一行");
        assertEquals(Boolean.TRUE, line.get("bound"), "领料行绑定冻结计划行");
        qty(qty, (BigDecimal) line.get("qty"), "草稿实发量");
        qty(requested, (BigDecimal) line.get("requested_qty"), "提交领料量 requested_qty");
    }

    private BigDecimal reserved(UUID issueId) {
        return db.queryForObject("""
                SELECT COALESCE(SUM(qty - consumed_qty - released_qty), 0) FROM stock_reservations
                WHERE source_doc_type='SUBCONTRACT_OUTBOUND_DRAFT' AND source_doc_id=? AND status=0 AND NOT is_deleted
                """, BigDecimal.class, issueId);
    }

    private BigDecimal reserved(UUID issueId, UUID goodsId) {
        return db.queryForObject("""
                SELECT COALESCE(SUM(qty - consumed_qty - released_qty), 0) FROM stock_reservations
                WHERE source_doc_type='SUBCONTRACT_OUTBOUND_DRAFT' AND source_doc_id=? AND goods_id=?
                  AND status=0 AND NOT is_deleted
                """, BigDecimal.class, issueId, goodsId);
    }

    /** 仓库在拣货页把某种物料改成实发量(其余行原样回传, 回传行身份)。 */
    private void warehousePick(UUID issueId, UUID goodsId, String qty) {
        MaterialIssueDetail draft = materialIssues.detail(issueId);
        var request = new MaterialIssueSaveRequest();
        request.setBillDate(draft.getBillDate());
        request.setSupplierId(draft.getSupplierId());
        request.setWarehouseId(draft.getWarehouseId());
        request.setDeliverDate(draft.getDeliverDate());
        request.setRemark(draft.getRemark());
        List<MaterialIssueItemLine> lines = new ArrayList<>();
        for (MaterialIssueItemDto item : draft.getItems()) {
            var line = new MaterialIssueItemLine();
            line.setId(item.getId());
            line.setLineNo(item.getLineNo());
            line.setGoodsId(item.getGoodsId());
            line.setColorId(item.getColorId());
            line.setUnitId(item.getUnitId());
            line.setUnitRate(item.getUnitRate());
            line.setQty(goodsId.equals(item.getGoodsId()) ? new BigDecimal(qty) : item.getQty());
            line.setOrderItemId(item.getOrderItemId());
            line.setPlanItemId(item.getPlanItemId());
            line.setParentGoodsId(item.getParentGoodsId());
            line.setParentColorId(item.getParentColorId());
            lines.add(line);
        }
        request.setItems(lines);
        materialIssues.update(issueId, request);
    }

    /** 仓库在拣货页把某种物料整行不发(数量 0 的行页面不回传), 其余行原样回传。 */
    private void warehouseDrop(UUID issueId, UUID goodsId) {
        MaterialIssueDetail draft = materialIssues.detail(issueId);
        var request = new MaterialIssueSaveRequest();
        request.setBillDate(draft.getBillDate());
        request.setSupplierId(draft.getSupplierId());
        request.setWarehouseId(draft.getWarehouseId());
        request.setDeliverDate(draft.getDeliverDate());
        request.setRemark(draft.getRemark());
        List<MaterialIssueItemLine> lines = new ArrayList<>();
        for (MaterialIssueItemDto item : draft.getItems()) {
            if (goodsId.equals(item.getGoodsId())) {
                continue;
            }
            var line = new MaterialIssueItemLine();
            line.setId(item.getId());
            line.setLineNo(item.getLineNo());
            line.setGoodsId(item.getGoodsId());
            line.setColorId(item.getColorId());
            line.setUnitId(item.getUnitId());
            line.setUnitRate(item.getUnitRate());
            line.setQty(item.getQty());
            line.setOrderItemId(item.getOrderItemId());
            line.setPlanItemId(item.getPlanItemId());
            line.setParentGoodsId(item.getParentGoodsId());
            line.setParentColorId(item.getParentColorId());
            lines.add(line);
        }
        request.setItems(lines);
        materialIssues.update(issueId, request);
    }

    private static DrawPendingDraft pendingDraft(DrawTaskMaterials detail, UUID issueId) {
        return detail.pendingDrafts().stream().filter(draft -> issueId.equals(draft.issueId())).findFirst()
                .orElseThrow(() -> new AssertionError("任务详情缺待发草稿 " + issueId + ": " + detail.pendingDrafts()));
    }

    /** OTHER 来源新建物料分析, 把委外件确认为委外并下达委外申请; 返回分析 id。 */
    private UUID notifySubcontract(FullChainEndToEndTest.World w, PreviewItem source, UUID subcontractGoodsId,
                                   String key) {
        AnalysisView view = analyses.preview(new PreviewRequest(null, null, null, w.warehouseId(),
                key + "-preview", List.of(source)));
        MaterialView row = analysisRow(view, subcontractGoodsId);
        AnalysisView routed = analyses.saveRoutes(view.analysisId(), new RouteRequest(view.version(),
                view.fingerprint(), key + "-route", List.of(new RouteDecision(row.materialLineId(),
                row.actionGroupKey(), "SUBCONTRACT", null))));
        MaterialView routedRow = analysisRow(routed, subcontractGoodsId);
        analysisCommands.notifySupply(view.analysisId(), new NotifyRequest(routed.version(), routed.fingerprint(),
                key + "-notify", "SUBCONTRACT", List.of(routedRow.materialLineId()), List.of(), null));
        return view.analysisId();
    }

    /** 同一来源原样重发预览 = 刷新这张分析。 */
    private AnalysisView refresh(UUID analysisId, UUID warehouseId, PreviewItem source, String key) {
        AnalysisView current = analyses.detail(analysisId);
        return analyses.preview(new PreviewRequest(analysisId, current.version(), current.fingerprint(),
                warehouseId, key, List.of(source)));
    }

    private UUID applicationItemOf(UUID analysisId, UUID goodsId) {
        return db.queryForObject("""
                SELECT item.id FROM preplan_supply_actions action
                JOIN subcontract_application_items item
                  ON item.application_id = action.external_document_id AND item.is_deleted = FALSE
                WHERE action.analysis_id=? AND action.route='SUBCONTRACT' AND action.status='CREATED'
                  AND item.goods_id=?
                """, UUID.class, analysisId, goodsId);
    }

    private static MaterialView analysisRow(AnalysisView view, UUID goodsId) {
        List<MaterialView> rows = view.flatMaterials().stream()
                .filter(material -> goodsId.equals(material.goodsId())).toList();
        assertEquals(1, rows.size(), "分析里该货品应当恰好一个节点, 现状 " + rows.size());
        return rows.getFirst();
    }

    private static MaterialView childRow(AnalysisView view, UUID goodsId, UUID parentGoodsId) {
        List<MaterialView> rows = view.flatMaterials().stream()
                .filter(material -> goodsId.equals(material.goodsId()) && parentGoodsId.equals(material.parentGoodsId()))
                .toList();
        assertEquals(1, rows.size(), "分析里 " + parentGoodsId + " 下面应当恰好一个 " + goodsId + " 节点, 现状 " + rows.size());
        return rows.getFirst();
    }

    /** 委外商退回我方材料(材料退货单建单 + 审核)。 */
    private UUID materialReturn(FullChainEndToEndTest.World w, UUID warehouseId, UUID orderItemId, UUID parentGoodsId,
                                UUID goodsId, UUID issueItemId, String qty) {
        var request = new MaterialReturnSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(warehouseId);
        var line = new MaterialReturnItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setMaterialIssueItemId(issueItemId);
        line.setOrderItemId(orderItemId);
        line.setParentGoodsId(parentGoodsId);
        request.setItems(List.of(line));
        UUID returnId = materialReturns.create(request).getId();
        materialReturns.approve(returnId);
        return returnId;
    }

    private WarehouseArrivalRegisterRequest arrival(FullChainEndToEndTest.World w, UUID orderItemId, UUID goodsId,
                                                    String qty, String key) {
        return new WarehouseArrivalRegisterRequest(
                "scstep-sc-" + key + "-" + orderItemId, "SUBCONTRACT", BusinessTime.today(),
                w.supplierId(), w.warehouseId(), null, w.employeeId(), null,
                List.of(new ArrivalLine(goodsId, new BigDecimal(qty), orderItemId, null,
                        w.unitId(), BigDecimal.ONE, null, null)));
    }

    /** 委外件回厂登记(送检审核); 期望不触发隔离。 */
    private Receipt registerReturn(FullChainEndToEndTest.World w, UUID orderItemId, UUID goodsId, String qty,
                                   String key) {
        WarehouseArrivalRegisterResult result = arrivals.register(arrival(w, orderItemId, goodsId, qty, key));
        assertEquals("SUBMITTED_FOR_INSPECTION", result.outcome(), "回厂 " + qty + " 在可回厂量内直接送检");
        return new Receipt(result.receiptId(), receiptItem(result.receiptId()));
    }

    private UUID receiptItem(UUID receiptId) {
        return db.queryForObject("""
                SELECT id FROM subcontract_receipt_items WHERE receipt_id=? AND COALESCE(is_deleted, FALSE)=FALSE
                """, UUID.class, receiptId);
    }

    private BigDecimal materialBasis(UUID receiptItemId) {
        return db.queryForObject("SELECT material_basis_qty FROM subcontract_receipt_items WHERE id=?",
                BigDecimal.class, receiptItemId);
    }

    private BigDecimal consumed(UUID orderItemId, UUID goodsId) {
        return db.queryForObject("""
                SELECT COALESCE(SUM(consumed_qty), 0) FROM subcontract_material_issue_items
                WHERE order_item_id=? AND goods_id=? AND NOT is_deleted
                """, BigDecimal.class, orderItemId, goodsId);
    }

    private BigDecimal supplierEnding(UUID orderItemId) {
        return db.queryForObject("""
                SELECT COALESCE(SUM(COALESCE(at_supplier_qty, 0) + COALESCE(compensated_qty, 0) - COALESCE(consumed_qty, 0)
                                    - COALESCE(returned_qty, 0) - COALESCE(wasted_qty, 0)), 0)
                FROM subcontract_material_issue_items WHERE order_item_id=? AND NOT is_deleted
                """, BigDecimal.class, orderItemId);
    }

    private BigDecimal returnable(UUID orderItemId) {
        return db.queryForObject("SELECT fn_subcontract_returnable_qty(?)", BigDecimal.class, orderItemId);
    }

    private BigDecimal markOf(UUID orderItemId) {
        List<BigDecimal> marks = db.queryForList(
                "SELECT notified_drawable FROM subcontract_draw_notice_marks WHERE order_item_id=?",
                BigDecimal.class, orderItemId);
        return marks.isEmpty() ? BigDecimal.ZERO : marks.getFirst();
    }

    private PassSlice passIqc(String receiptType, UUID receiptId, String key) {
        UUID inspectionItemId = db.queryForObject("""
                SELECT id FROM procurement_inspection_items WHERE receipt_type=? AND receipt_id=?
                """, UUID.class, receiptType, receiptId);
        inspections.dispose(receiptType, receiptId, inspectionItemId,
                new InspectionDispositionRequest("PASS", null, "检验合格", "scstep-iqc-" + key));
        Map<String, Object> pass = db.queryForMap("""
                SELECT id, base_qty FROM procurement_inspection_events
                WHERE inspection_item_id=? AND action='PASS'
                ORDER BY occurred_at DESC, id DESC LIMIT 1
                """, inspectionItemId);
        return new PassSlice((UUID) pass.get("id"), (BigDecimal) pass.get("base_qty"));
    }

    private void stockIn(String receiptType, UUID receiptId, PassSlice pass, String key, UUID warehouseId) {
        iqcStockIn.confirm(receiptType, receiptId, new ConfirmRequest("scstep-stock-" + key,
                List.of(new ConfirmItem(pass.passEventId(), pass.qty(), pass.qty(), "SCSTEP-01", warehouseId))));
    }

    private BigDecimal onHand(UUID goodsId, UUID warehouseId) {
        return db.queryForObject("""
                SELECT COALESCE(SUM(qty), 0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?
                """, BigDecimal.class, goodsId, warehouseId);
    }

    private BigDecimal onHand(UUID goodsId, UUID warehouseId, UUID colorId) {
        return db.queryForObject("""
                SELECT COALESCE(SUM(qty), 0) FROM stock_balances
                WHERE goods_id=? AND warehouse_id=? AND color_id IS NOT DISTINCT FROM ?
                """, BigDecimal.class, goodsId, warehouseId, colorId);
    }

    private void assertDrawAvailableCard(UUID orderItemId, UUID audience, String expectedFragment) {
        List<Map<String, Object>> cards = db.queryForList("""
                SELECT title, action_route FROM notices
                WHERE audience_user_id=? AND source_event='SUBCONTRACT_DRAW_AVAILABLE' AND aggregate_id=?
                  AND resolved_at IS NULL
                """, audience, orderItemId);
        assertEquals(1, cards.size(), "每个委外任务一张未办结的可领料卡, 现状 " + cards);
        assertTrue(String.valueOf(cards.getFirst().get("title")).contains(expectedFragment),
                "可领料卡按实时可领量生成, 期望含「" + expectedFragment + "」, 现状 " + cards.getFirst().get("title"));
        assertEquals(DRAW_ROUTE + orderItemId, cards.getFirst().get("action_route"), "卡片直达「领料」分段并按该明细筛选");
    }

    private void assertNoDrawAvailableCard(UUID orderItemId, UUID audience) {
        assertEquals(0, count("""
                SELECT COUNT(*) FROM notices
                WHERE audience_user_id=? AND source_event='SUBCONTRACT_DRAW_AVAILABLE' AND aggregate_id=?
                  AND resolved_at IS NULL
                """, audience, orderItemId), "提交领料 / 结束领料后可领料卡要收回");
    }

    /**
     * 投递 outbox 直到本用例自己的聚合(货品、订货明细、领料草稿)没有待投递事件。共享库里别的用例的
     * 积压也会顺带投掉; 投递期间的瞬时冲突不算失败, 下一轮重投。
     */
    private void drainOutboxFor(Collection<UUID> aggregateIds) {
        String ids = "{" + aggregateIds.stream().map(UUID::toString).collect(Collectors.joining(",")) + "}";
        long deadline = System.currentTimeMillis() + 90_000;
        while (true) {
            db.update("UPDATE business_outbox SET available_at=now() WHERE status=0 AND available_at>now()");
            try {
                for (int i = 0; i < 500 && outbox.processNext(); i++) {
                    // 投到取不出为止
                }
            } catch (RuntimeException transientDeliveryFailure) {
                // 瞬时冲突: 下一轮抹平退避后重投。
            }
            int pending = db.queryForObject("""
                    SELECT COUNT(*) FROM business_outbox WHERE status=0 AND aggregate_id = ANY(CAST(? AS uuid[]))
                    """, Integer.class, ids);
            if (pending == 0) {
                break;
            }
            if (System.currentTimeMillis() > deadline) {
                fail("本用例的 outbox 事件没有投递完: " + db.queryForList("""
                        SELECT event_type, attempts, last_error FROM business_outbox
                        WHERE status=0 AND aggregate_id = ANY(CAST(? AS uuid[]))
                        """, ids));
            }
            try {
                Thread.sleep(50);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                fail("等待 outbox 投递时被中断");
            }
        }
        List<Map<String, Object>> dead = db.queryForList("""
                SELECT event_type, last_error FROM business_outbox
                WHERE status=2 AND aggregate_id = ANY(CAST(? AS uuid[]))
                """, ids);
        assertTrue(dead.isEmpty(), "本用例有 outbox 事件投递失败进了死信: " + dead);
    }

    /** 等某个会话被指定后端(这里是占住水位行的事务)挡住。 */
    private void awaitBlockedBy(int blockerPid, String message) {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60);
        while (count("SELECT COUNT(*) FROM pg_stat_activity WHERE ? = ANY(pg_blocking_pids(pid))", blockerPid) == 0) {
            assertTrue(System.nanoTime() < deadline, message);
            try {
                Thread.sleep(20);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                fail(message);
            }
        }
    }

    private int count(String sql, Object... args) {
        Integer n = db.queryForObject(sql, Integer.class, args);
        return n == null ? 0 : n;
    }

    private static void qty(String expected, BigDecimal actual, String what) {
        assertNotNull(actual, what + ": 现状 null, 期望 " + expected);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), what + ": 现状 " + actual + " 期望 " + expected);
    }

    private static void qty(String expected, Object actual, String what) {
        assertNotNull(actual, what + ": 现状 null, 期望 " + expected);
        BigDecimal value = actual instanceof BigDecimal decimal ? decimal : new BigDecimal(actual.toString());
        qty(expected, value, what);
    }
}
