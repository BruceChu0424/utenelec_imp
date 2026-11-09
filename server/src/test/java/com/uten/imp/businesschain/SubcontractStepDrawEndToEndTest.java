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
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawLineRequest;
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
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
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
class SubcontractStepDrawEndToEndTest extends SubcontractFullChainTestContext {

    private static final String DRAW_ROUTE = "/operations/workbench/subcontract?segment=DRAW&orderItemId=";


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
    @Autowired com.uten.imp.features.subcontract.waste.SubcontractWasteService materialWaste;
    @Autowired com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService shortDelivery;
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
    @Autowired com.uten.imp.features.notice.NoticeService notices;
    @Autowired com.uten.imp.features.notice.NoticeRepository noticeRows;
    @Autowired com.uten.imp.features.notice.ReviewNoticeAudience noticeAudience;
    @Autowired com.uten.imp.features.notice.ChainNoticeService chainNotices;

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

    /**
     * 真实授出权限码(个人加授): 发卡池按 grantedPermsOf 解析(ADR-063 追加修订),
     * 超管的全量镜像不算任务归属——本测试的超管操作员需要真实拿到领料链的码。
     */
    private void grantAuthorities(UUID userId, String... codes) {
        db.update("""
                INSERT INTO user_permission_overrides(user_id, permission_id, effect)
                SELECT ?, p.id, 'grant' FROM permissions p
                WHERE p.code = ANY(string_to_array(?, ','))
                """, userId, String.join(",", codes));
    }

    @Test
    void sharedOutboundEventSeparatesActualRecipientsBeforeDeliveryAndEverySqlRead() {
        String tag="scstep-purpose";
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());
        grantAuthorities(w.superAdminUserId(),"subcontract_order:view","subcontract_order:draw","subcontract:view:all");
        UUID product=goods(w,tag,"P","委外"),component=goods(w,tag,"A","自制");
        fixture.insertBom(product,component,"1");otherIn(w,w.warehouseId(),component,null,"10","5");
        UUID order=subcontractOrder(w,product,"10",BusinessTime.today().plusDays(5),BigDecimal.ZERO);
        approveSubcontract(w,order);UUID item=itemOf(order);
        UUID issue=drawCommands.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item,null)),tag+"-draw")).issueIds().getFirst();
        materialIssues.approve(issue);drainOutboxFor(Set.of(order,issue));
        qty("10",returnable(item),"真实已发材料可回厂");

        UUID drawer=fixture.createUserWithPerms(w,tag+"-drawer","notice:read","subcontract_order:view","subcontract_order:draw","subcontract:view:all");
        UUID planner=fixture.createUserWithPerms(w,tag+"-planner","notice:read","production_material_analysis:view","production_material_analysis:notify");
        UUID keeper=fixture.createUserWithPerms(w,tag+"-keeper","notice:read","warehouse_inbound:view","warehouse_inbound:stock_in");
        UUID viewer=fixture.createUserWithPerms(w,tag+"-viewer","notice:read","subcontract_order:view","production_material_analysis:view","warehouse_inbound:view");
        UUID library=fixture.createUserWithPerms(w,tag+"-library","notice:read","subcontract_order:view","production_material_analysis:view","warehouse_inbound:view",
                "company_file:view","company_file:create","company_file:edit","company_file:delete","company_file:move","company_file:restore","company_file:upload","company_file:manage_permissions","attachment:view","attachment:upload");
        UUID keeperEmployee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,keeper);
        db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) VALUES(?,?)",w.warehouseId(),keeperEmployee);
        UUID implicit=fixture.seedWorld(tag+"-implicit").superAdminUserId();
        String event="SUBCONTRACT_OUTBOUND_COMPLETED",orderRoute="/subcontract/orders/"+order;
        // Historical result receipts do not depend on the source record still existing.
        String analysisRoute="/production/material-analyses/"+UUID.randomUUID()+"/summary";
        var valid=new java.util.LinkedHashMap<UUID,UUID>();
        for(UUID user:List.of(drawer,planner,keeper,viewer,library,implicit)) {
            long before=count("SELECT count(*) FROM notices WHERE audience_user_id=?",user);
            long beforeStates=count("SELECT count(*) FROM notice_user_states WHERE user_id=?",user);
            var orderReceipt=notices.publishForUser(user,"purpose order","已发物料回执","workflow","系统",orderRoute,event);
            var analysisReceipt=notices.publishForUser(user,"purpose analysis","分析供料结果回执","workflow","系统",analysisRoute,event);
            var warehouseAction=notices.publishForUser(user,"purpose warehouse","真实预计回厂行动","task","系统","/warehouse/inbound/expectations",event,null,order);
            assertEquals(user.equals(drawer),orderReceipt!=null,"仅实际委外领料资格接订单结果");
            assertEquals(user.equals(planner),analysisReceipt!=null,"仅实际计划资格接分析结果");
            assertEquals(user.equals(keeper),warehouseAction!=null,"仓库行动仍须自己的精确资格");
            assertEquals(before+(user.equals(drawer)||user.equals(planner)||user.equals(keeper)?1:0),
                    count("SELECT count(*) FROM notices WHERE audience_user_id=?",user),"门禁先于notice/state写入");
            assertEquals(beforeStates+(user.equals(drawer)||user.equals(planner)||user.equals(keeper)?1:0),count("SELECT count(*) FROM notice_user_states WHERE user_id=?",user));
            var result=orderReceipt!=null?orderReceipt:analysisReceipt!=null?analysisReceipt:warehouseAction;
            if(result!=null)valid.put(user,result.getId());
        }
        assertNull(notices.publishForUser(keeper,"bad route","fixture","workflow","系统","/warehouse/inbound/expectations",event));
        assertNull(notices.publishForUser(drawer,"bad type","fixture","task","系统",orderRoute,event,null,order));
        assertNull(notices.publishForUser(planner,"unknown route","fixture","workflow","系统",analysisRoute+"/extra",event));
        for(var entry:valid.entrySet()) {
            UUID user=entry.getKey(),id=entry.getValue();fixture.loginAs(user);
            assertEquals(id.toString(),notices.getById(id).id());
            var actor=(com.uten.imp.security.AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
            var scope=noticeAudience.readScope(actor);
            assertTrue(noticeRows.findScopedVisibleNoticeIds(user,Set.of(id),scope).contains(id));
            assertTrue(noticeRows.findVisible(user,false,scope,org.springframework.data.domain.PageRequest.of(0,1)).stream().anyMatch(n->n.getId().equals(id)));
            assertEquals(notices.list(true).size(),notices.unreadCount());
            String state=db.queryForObject("SELECT to_jsonb(s)::text FROM notice_user_states s WHERE notice_id=? AND user_id=?",String.class,id,user);
            // Corrupt/legacy stored shapes must remain invisible before paging.
            for(int changed=0;changed<5;changed++) {
                var bad=new com.uten.imp.features.notice.Notice();bad.setTitle("unsupported purpose");bad.setContent("fixture shape");bad.setPublisher("系统");
                bad.setSourceEvent(event);bad.setType("workflow");bad.setKind("NORMAL");bad.setAudienceUserId(user);bad.setAudienceScope("selected");bad.setAudienceCount(1);
                bad.setActionRoute(orderRoute);bad.setPublishedAt(java.time.Instant.now().plusSeconds(30));
                switch(changed) {
                    case 0->bad.setActionRoute("/subcontract/orders/not-a-uuid");
                    case 1->bad.setType("task");
                    case 2->{bad.setAggregateKind("SUBCONTRACT_ORDER");bad.setAggregateId(order);}
                    case 3->bad.setSourceRevision(1L);
                    case 4->bad.setActionRoute("/warehouse/inbound/expectations");
                }
                var saved=noticeRows.saveAndFlush(bad);
                assertTrue(noticeRows.findScopedVisibleNoticeIds(user,Set.of(saved.getId()),scope).isEmpty());
                assertThrows(ApiException.class,()->notices.getById(saved.getId()));
            }
            assertEquals(id,noticeRows.findVisible(user,false,scope,org.springframework.data.domain.PageRequest.of(0,1)).getFirst().getId(),"非法新行不能占据第一页");
            assertEquals(notices.list(true).size(),notices.unreadCount());
            assertEquals(state,db.queryForObject("SELECT to_jsonb(s)::text FROM notice_user_states s WHERE notice_id=? AND user_id=?",String.class,id,user));
            assertEquals(event,db.queryForObject("SELECT source_event FROM notices WHERE id=?",String.class,id));
        }
        fixture.loginAs(w.superAdminUserId());
        Receipt received=registerReturn(w,item,product,"10",tag+"-return");
        stockIn("SUBCONTRACT",received.receiptId(),passIqc("SUBCONTRACT",received.receiptId(),tag+"-pass"),tag+"-stock",w.warehouseId());
        qty("0",db.queryForObject("""
                SELECT GREATEST(fn_subcontract_returnable_qty(?) - COALESCE((
                    SELECT SUM(detail.material_basis_qty) FROM subcontract_receipt_items detail
                    JOIN subcontract_receipts receipt ON receipt.id=detail.receipt_id
                    WHERE detail.order_item_id=? AND NOT detail.is_deleted AND receipt.status=1 AND NOT receipt.is_deleted),0),0)
                """,BigDecimal.class,item,item),"正式预计到货口径：累计可制套数减已登记回厂基数");
        fixture.loginAs(keeper);assertThrows(ApiException.class,()->notices.getById(valid.get(keeper)));
        long beforeLate=count("SELECT count(*) FROM notices WHERE audience_user_id=? AND source_event=?",keeper,event);
        fixture.loginAs(w.superAdminUserId());chainNotices.notifySubcontractOutboundCompleted(issue);drainOutboxFor(Set.of(order,issue));
        assertEquals(beforeLate,count("SELECT count(*) FROM notices WHERE audience_user_id=? AND source_event=?",keeper,event),"迟到事件不能复活仓库行动卡");
        fixture.loginAs(drawer);assertEquals(valid.get(drawer).toString(),notices.getById(valid.get(drawer)).id(),"普通结果仍是历史事实");
    }

    // =====================================================================================
    // 主链
    // =====================================================================================

    @Test
    void applicationSourceFilterPrecedesPagingAndCountsAndKeepsTaskAuthority() {
        String tag = "scstep-source-page";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID product = goods(w, tag, "P", "委外");
        UUID material = goods(w, tag, "M", "采购");
        db.update("UPDATE goods SET name=? WHERE id=?", tag + "螺丝 M3_20%", product);
        UUID unrelatedProduct = goods(w, tag, "UNRELATED", "委外");
        fixture.insertBom(product, material, "1");
        var stage = fixture.stageSubcontractKit(w, Map.of(product, "401"));
        // Stock arrival legitimately wakes the kit-notice worker. Finish that
        // existing side effect before creating 201 new sources; this test owns
        // read scope/paging, not a race against notification FK key-share locks.
        drainOutboxFor(Set.of(product, material));
        var applicationDocument = sourceScopeApplication(w, product, unrelatedProduct, 201);
        var otherDocument = sourceScopeApplication(w, product, unrelatedProduct, 1);
        UUID application = applicationDocument.applicationId();
        UUID target = db.queryForObject(
                "SELECT id FROM subcontract_application_items WHERE application_id=? AND goods_id=?",
                UUID.class, application, product);
        UUID unrelated = otherDocument.lines().getFirst().applicationItemId();
        var request = orderRequest(w, product, "1", BusinessTime.today().plusDays(5), null);
        List<OrderItemLine> lines = new ArrayList<>();
        for (int i = 0; i <= 400; i++) {
            var line = new OrderItemLine();
            line.setLineNo(i + 1);
            line.setGoodsId(product);
            line.setUnitId(w.unitId());
            line.setUnitRate(BigDecimal.ONE);
            line.setQty(BigDecimal.ONE);
            line.setPrice(new BigDecimal("50"));
            UUID source = i == 0 || i > 200 ? target : unrelated;
            line.setApplicationItemId(source);
            line.setApplicationItemIds(i == 400 ? List.of(target, unrelated) : List.of(source));
            lines.add(line);
        }
        request.setItems(lines);
        var order = orders.create(request);
        UUID orderId = order.getId();
        UUID originalItem = order.getItems().getFirst().getId();
        Set<UUID> phaseAggregates = new LinkedHashSet<>(Set.of(product, material, orderId, application,
                otherDocument.applicationId(), target, unrelated));
        applicationDocument.lines().forEach(line -> phaseAggregates.add(line.applicationItemId()));
        otherDocument.lines().forEach(line -> phaseAggregates.add(line.applicationItemId()));
        order.getItems().forEach(line -> phaseAggregates.add(line.getId()));
        drainOutboxFor(phaseAggregates);
        // Legitimate pre-review legacy shape: the validated primary source remains,
        // but older rows have no multi-source table entry. Never mutate approved facts.
        db.update("DELETE FROM subcontract_order_item_sources WHERE order_item_id=?", originalItem);
        fixture.stageSubcontractKitUntilApproval(orderId, stage);
        approveSubcontract(w, orderId);
        drainOutboxFor(phaseAggregates);
        List<UUID> linked = order.getItems().stream()
                .filter(row -> row.getLineNo() == 1 || row.getLineNo() > 201)
                .map(row -> row.getId()).toList();
        DrawTaskPage broad = drawQueries.tasks(1, 200, "", "", orderId, null);
        assertEquals(401, broad.page().getTotal());
        assertEquals(200, broad.page().getItems().size());
        DrawTaskPage compound = drawQueries.tasks(1, 1, tag + " M3_20%", "", orderId, null);
        assertEquals(401, compound.page().getTotal());
        assertEquals(401L, compound.statusCounts().get("ALL"));
        assertEquals(1, compound.page().getItems().size());
        assertEquals(0, drawQueries.tasks(1, 1, tag + " M3X20A", "", orderId, null).page().getTotal());

        DrawTaskPage first = drawQueries.tasks(1, 200, "", "", orderId, null, List.of(target));
        assertEquals(201, first.page().getTotal(), "source filtering must happen before total and LIMIT");
        assertEquals(2, first.page().getTotalPages());
        assertEquals(200, first.page().getItems().size());
        assertEquals(201L, first.statusCounts().get("ALL"));
        assertEquals(201L, first.statusCounts().get("WAITING_PLANNING"));
        DrawTaskPage parent = drawQueries.tasks(2, 200, "", "", orderId, null, null, application);
        assertEquals(201, parent.page().getTotal(), "parent navigation supports applications with over 200 source lines");
        assertEquals(List.of(linked.getLast()), parent.page().getItems().stream().map(DrawTaskRow::orderItemId).toList());
        DrawTaskPage last = drawQueries.tasks(2, 200, "", "", orderId, null, List.of(target));
        assertEquals(201, last.page().getTotal());
        assertEquals(List.of(linked.getLast()), last.page().getItems().stream().map(DrawTaskRow::orderItemId).toList());
        assertEquals(Set.of(target, unrelated), Set.copyOf(last.page().getItems().getFirst().applicationItemIds()),
                "merged source IDs remain exact, without counting one task twice");
        DrawTaskPage other = drawQueries.tasks(1, 200, "", "", orderId, null, List.of(unrelated));
        assertEquals(201, other.page().getTotal(), "200 unrelated tasks and the one genuinely merged task");
        assertFalse(other.page().getItems().stream().anyMatch(row -> originalItem.equals(row.orderItemId())),
                "legacy-only target source is not in the other application");
        DrawTaskPage drawable = drawQueries.tasks(1, 200, "", "DRAWABLE", orderId, null, List.of(target));
        assertEquals(0, drawable.page().getTotal());
        assertEquals(201L, drawable.statusCounts().get("ALL"), "status facets retain the same source scope");
        assertEquals(0, drawQueries.tasks(1, 200, "", "", UUID.randomUUID(), null, List.of(target)).page().getTotal());
        assertEquals(1, drawQueries.tasks(1, 200, "", "", orderId, List.of(originalItem), List.of(target)).page().getTotal());
        assertEquals(ErrorCode.VALIDATION_FAILED, assertThrows(ApiException.class, () ->
                drawQueries.tasks(1, 200, "", "", orderId, null,
                        java.util.stream.IntStream.range(0, 201).mapToObj(i -> UUID.randomUUID()).toList())).getCode());

        UUID ownerRestricted = fixture.createUserWithPerms(w, tag + "-owner-restricted",
                "subcontract_order:view", "subcontract_application:view");
        fixture.loginAs(ownerRestricted);
        assertEquals(0, drawQueries.tasks(1, 200, "", "", orderId, null, List.of(target)).page().getTotal(),
                "knowing a source ID cannot bypass the existing task owner scope");
        assertEquals(0, drawQueries.tasks(1, 200, "", "", orderId, null, null, application).page().getTotal(),
                "knowing the parent application does not bypass the task owner scope either");
        UUID noSourcePermission = fixture.createUserWithPerms(w, tag + "-no-source",
                "subcontract_order:view", "subcontract:view:all");
        fixture.loginAs(noSourcePermission);
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () ->
                drawQueries.tasks(1, 200, "", "", orderId, null, List.of(target))).getCode());
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () ->
                drawQueries.tasks(1, 200, "", "", orderId, null, null, application)).getCode());
        UUID viewer = fixture.createUserWithPerms(w, tag + "-source-viewer",
                "subcontract_order:view", "subcontract_application:view", "subcontract:view:all");
        fixture.loginAs(viewer);
        DrawTaskPage readOnly = drawQueries.tasks(2, 200, "", "", orderId, null, List.of(target));
        assertEquals(201, readOnly.page().getTotal());
        assertFalse(readOnly.capabilities().canSubmitDraw(), "source navigation does not grant draw authority");
        assertFalse(readOnly.page().getItems().getFirst().canDraw());
        fixture.loginAs(w.superAdminUserId());
        db.update("UPDATE subcontract_orders SET is_closed=true WHERE id=?", orderId);
        assertEquals(0, drawQueries.tasks(1, 200, "", "", orderId, null, List.of(target)).page().getTotal(),
                "source navigation retains the active/open task boundary");
    }

    private com.uten.imp.application.port.ProductionSubcontractRequestPort.DraftResult sourceScopeApplication(
            FullChainEndToEndTest.World w, UUID product, UUID unrelatedProduct, int lineCount) {
        List<com.uten.imp.application.port.ProductionSubcontractRequestPort.DraftLine> items = new ArrayList<>();
        for (int i = 1; i <= lineCount; i++) {
            items.add(new com.uten.imp.application.port.ProductionSubcontractRequestPort.DraftLine(
                    UUID.randomUUID(), i == 1 ? product : unrelatedProduct, null, w.unitId(), new BigDecimal("200.5"),
                    BusinessTime.today().plusDays(5), "source scope pagination fixture"));
        }
        return new TransactionTemplate(transactions).execute(ignored -> {
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
            var locks = beans.getBean(com.uten.imp.application.concurrency.FulfillmentMutationLocks.class);
            var plan = new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan(
                    Set.of(), Set.of(), Set.of(w.warehouseId()), Set.of(), "source-scope-create");
            locks.acquire(() -> plan).verifyUnchanged();
            return beans.getBean(com.uten.imp.application.port.ProductionSubcontractRequestPort.class)
                    .createProductionDraft("SOURCE-SCOPE", null, BusinessTime.today().plusDays(5),
                            w.warehouseId(), items, w.employeeId(), w.employeeId());
        });
    }

    @Test
    void baseCoverageAndExactMaterialDrawStayDistinctFromTheLossBudget() {
        String tag = "scstep-budget-grid";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID product = goods(w, tag, "P", "委外");
        UUID material = goods(w, tag, "M", "采购");
        fixture.insertBom(product, material, "1");
        UUID order = subcontractOrder(w, product, "10000", BusinessTime.today().plusDays(5), new BigDecimal("10"));
        approveSubcontract(w, order);
        UUID item = itemOf(order);
        otherIn(w, w.warehouseId(), material, null, "10000", "1");

        var task = taskRow(order);
        // 2026-11-09: 列表不再给单种物料的实物合计(多物料时一个数说不清), 改为逐种分桶;
        // 实物数量看任务详情物料表(每行一种物料)。
        assertEquals(1, task.materialKindCount(), "物料种数");
        assertEquals(1, task.drawableKindCount(), "唯一物料仓库有货 → 可领 1 种");
        assertEquals(0, task.shortKindCount(), "可领优先于缺口: 仅差损耗额度的物料仍落「可领」桶");
        assertEquals(0, task.sentFullKindCount() + task.pendingKindCount() + task.closedKindCount());

        var detail = drawQueries.materials(item);
        qty("10000", detail.task().orderQty(), "订货目标");
        qty("9090.909", detail.task().drawableQty(), "按含损耗备料上限折算的可领套数");
        qty("10000", detail.baseMaterialCoverageQty(), "冻结基础单耗覆盖原成品目标");
        assertTrue(detail.allowedActions().contains("DRAW"), "有可领物料且在写范围内 → 可按物料领料");
        var line = detail.materials().getFirst();
        qty("11000", line.requiredQty(), "损耗备料上限");
        assertEquals("10000", line.getBaseRequiredQtyExact());
        assertEquals("1000", line.getLossRequiredQtyExact());
        qty("1000", line.shortQty(), "仅差损耗备料额度");
        qty("10000", line.drawableQty(), "本次可领恰好是实际库存");
        assertEquals("DRAWABLE", line.state(), "本次可领 > 0 → 可领(下一步动作优先于缺口)");
        var progress = orderProgress.progress(order).items().getFirst();
        qty("10000", progress.materials().getFirst().drawableQty(),
                "委外订货进度与任务详情的实物领料量一致");
        assertTrue(progress.timeline().stream().anyMatch(node ->
                node.detail() != null && node.detail().contains("可领 10000") && !node.detail().contains("9090")));

        var selection = List.of(new DrawItemRequest(item, null));
        var preview = drawQueries.preview(new DrawPreviewRequest(selection));
        qty("10000", preview.lines().getFirst().qty(), "预览与详情量一致");
        var previewTask = preview.tasks().getFirst();
        assertEquals("10000", previewTask.getMaterialBatchDrawableQtyExact());
        assertEquals(line.planItemId(), previewTask.materialPlanItemId());
        for (String amount : List.of("4000.0001", "5999.9999")) {
            var edited = List.of(new DrawItemRequest(item, null, new BigDecimal(amount), line.planItemId()));
            var editedPreview = drawQueries.preview(new DrawPreviewRequest(edited));
            qty(amount, editedPreview.lines().getFirst().qty(), "手填实物量不经套数舍入");
            var submitted = drawCommands.submit(new DrawSubmitRequest(edited, "budget-grid-" + amount + "-" + item));
            UUID issue = submitted.issueIds().getFirst();
            assertDraftLine(issue, material, amount, amount);
            materialIssues.approve(issue);
        }
        qty("10000", returnable(item), "实际发料足以回厂 10000，不强制先发出损耗预算");
    }

    @Test
    void normalLossAddsSupplyOnceKeepsFinishedTargetAndClosesAllMaterialOnBatchReceipts() {
        String tag = "scstep-normal-loss";
        var w = fixture.seedWorld(tag);
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "自制");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID orderId = subcontractOrder(w, p, "100", BusinessTime.today().plusDays(5), new BigDecimal("10"));
        UUID reviewer = approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        var lines = planLines(item);
        qty("1", lines.get(a).get("base_bom_unit_qty"), "A 原始 BOM 快照");
        qty("10", lines.get(a).get("material_loss_pct"), "正常损耗快照");
        qty("1.1", lines.get(a).get("bom_unit_qty"), "A 含损耗供料单耗");
        qty("110", lines.get(a).get("planned_qty"), "目标100、损耗10%，A计划110");
        qty("220", lines.get(b).get("planned_qty"), "B 基准200加成10%");
        qty("100", db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, item),
                "成品目标仍为100");

        // Approved quantity increases still require enough real material for the
        // enlarged frozen supply plan; the allowance never bypasses kit checks.
        otherIn(w, w.warehouseId(), a, null, "132", "10");
        otherIn(w, w.warehouseId(), b, null, "264", "5");
        changeQty(orderId, item, "120");
        reconfirm(reviewer, w, orderId);
        qty("132", planLines(item).get(a).get("planned_qty"), "改量沿用冻结供料单耗");
        changeQty(orderId, item, "100");
        reconfirm(reviewer, w, orderId);
        qty("110", planLines(item).get(a).get("planned_qty"), "再次改量不重复叠加损耗");

        assertRow(taskRow(orderId), "0", "0", "100", "0", "DRAWABLE");
        var drawn = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "normal-loss-draw-" + item));
        assertEquals(1, drawn.documentCount());
        UUID issue = drawn.issueIds().getFirst();
        assertDraftLine(issue, a, "110", "110");
        assertDraftLine(issue, b, "220", "220");
        assertTrue(drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "normal-loss-draw-" + item)).replayed(),
                "重放不重复增加损耗或发料");
        materialIssues.approve(issue);
        qty("110", returnable(item), "按原始BOM，110/220材料最多可回厂110件；原成品目标仍100");
        var firstRequest=arrival(w,item,p,"90",tag+"-first");
        var firstResult=arrivals.register(new WarehouseArrivalRegisterRequest(firstRequest.idempotencyKey(),firstRequest.orderType(),
                firstRequest.billDate(),firstRequest.supplierId(),firstRequest.warehouseId(),firstRequest.purchaserId(),
                firstRequest.receiverEmployeeId(),firstRequest.remark(),firstRequest.items(),null,true));
        assertEquals("SUBMITTED_FOR_INSPECTION",firstResult.outcome());
        Receipt first=new Receipt(firstResult.receiptId(),receiptItem(firstResult.receiptId()));
        var partialCase=db.queryForMap("SELECT id,version FROM subcontract_short_delivery_cases WHERE order_item_id=? AND status IN('PENDING_OWNER','WAITING_MORE') ORDER BY detected_at DESC LIMIT 1",item);
        shortDelivery.decide((UUID)partialCase.get("id"),new com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest(
                "WAIT_MORE",BusinessTime.today().plusDays(1),"确认分批回厂，仍须补齐原成品目标100",((Number)partialCase.get("version")).longValue()));
        qty("90", consumed(item, a), "首批90件只按原始BOM核销90；损耗预算不是实际损耗");
        qty("180", consumed(item, b), "第二种物料按实际90件的原始单耗独立核销");
        stockIn("SUBCONTRACT", first.receiptId(), passIqc("SUBCONTRACT", first.receiptId(), tag + "-pass1"),
                tag + "-stock1", w.warehouseId());
        InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a,b));
        assertFalse(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, orderId),
                "损耗已加料，回厂90不能按原10%容差自动结案");
        qty("0", db.queryForObject("SELECT fn_subcontract_settled_loss_qty(?)", BigDecimal.class, item),
                "未有人受控确认时不生成成品损耗履约");
        Receipt last = registerReturn(w, item, p, "10", tag + "-last");
        stockIn("SUBCONTRACT", last.receiptId(), passIqc("SUBCONTRACT", last.receiptId(), tag + "-pass2"),
                tag + "-stock2", w.warehouseId());
        InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a,b));
        qty("100", consumed(item, a), "100件累计只核销实际基准材料100");
        qty("200", consumed(item, b), "B累计核销原始单耗所需200材料");
        qty("30", supplierEnding(item), "未实际耗用的A10与B20仍为供应商处余料，不能自动抹为损耗");
        qty("100", onHand(p, w.warehouseId()), "实际成品回厂目标100全部入库");
        qty("22", onHand(a, w.warehouseId()), "仓库只扣本单含损耗所需110，不多发");
        qty("44", onHand(b, w.warehouseId()), "第二种物料仓库只扣220");
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, orderId));
        for (Receipt receipt : List.of(first, last)) {
            assertTrue(db.queryForObject("SELECT fn_subcontract_receipt_material_complete(?)", Boolean.class,
                    receipt.receiptItemId()), "实际BOM核销满足数据库成本完整性守卫，预算余料仍独立保留");
        }
        var loss = new com.uten.imp.features.subcontract.waste.dto.WasteItemLine();
        loss.setGoodsId(a); loss.setUnitId(w.unitId()); loss.setUnitRate(BigDecimal.ONE);
        loss.setQty(new BigDecimal("10"));loss.setStandardQty(new BigDecimal("10"));loss.setCause("供应商确认实际材料损耗10，单独登记");
        loss.setMaterialIssueItemId(db.queryForObject(
                "SELECT id FROM subcontract_material_issue_items WHERE issue_id=? AND goods_id=? AND NOT is_deleted",
                UUID.class, issue, a));
        var request = new com.uten.imp.features.subcontract.waste.dto.WasteSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId()); request.setItems(List.of(loss));
        var wasteDraft = materialWaste.create(request);
        materialWaste.approve(wasteDraft.getId());
        InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a,b));
        qty("20",supplierEnding(item),"只扣实际登记的A损耗10，B余料20仍保留");
        var duplicateWaste=materialWaste.create(request);
        assertThrows(ApiException.class,()->materialWaste.approve(duplicateWaste.getId()),"同一份A实际损耗不能重复登记");
        qty("20",supplierEnding(item),"重复报损失败后供应商处事实不变");
        var returnedLine=new MaterialReturnItemLine();returnedLine.setGoodsId(b);returnedLine.setUnitId(w.unitId());
        returnedLine.setUnitRate(BigDecimal.ONE);returnedLine.setQty(new BigDecimal("20"));returnedLine.setOrderItemId(item);
        returnedLine.setParentGoodsId(p);returnedLine.setMaterialIssueItemId(db.queryForObject(
                "SELECT id FROM subcontract_material_issue_items WHERE issue_id=? AND goods_id=? AND NOT is_deleted",UUID.class,issue,b));
        var returned=new MaterialReturnSaveRequest();returned.setBillDate(BusinessTime.today());returned.setSupplierId(w.supplierId());
        returned.setWarehouseId(w.warehouseId());returned.setItems(List.of(returnedLine));
        materialReturns.approve(materialReturns.create(returned).getId());
        InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a,b));
        qty("0",supplierEnding(item),"实际材料报损与余料退回逐笔收口，绝不靠成品回厂强制抹掉预算");
        qty("64",onHand(b,w.warehouseId()),"B未用余料20实际回仓并增加原始库存");
    }

    @Test
    void tinyBomAndHundredthPercentLossRemainExactInPlanIssueAndCumulativeBatchConsumption() {
        for (String loss : List.of("10", "0.01")) {
            String tag = "scstep-tiny-" + loss.replace(".", "");
            var w = fixture.seedWorld(tag);
            grantAuthorities(w.superAdminUserId(),
                    "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
            fixture.loginAs(w.superAdminUserId());
            UUID p = goods(w, tag, "P", "委外");
            UUID a = goods(w, tag, "A", "采购");
            // BOM stores five fractional places; order-unit conversion produces
            // the permitted six-place frozen base without truncating the source BOM.
            fixture.insertBom(p, a, "0.00001");
            UUID orderUnit = UUID.randomUUID();
            db.update("INSERT INTO units(id,code,name,status) VALUES (?,?,'十分之一件','使用')",
                    orderUnit, "TENTH-" + UUID.randomUUID());
            var request = orderRequest(w, p, "10000", BusinessTime.today().plusDays(5), new BigDecimal(loss));
            request.getItems().getFirst().setUnitId(orderUnit);
            request.getItems().getFirst().setUnitRate(new BigDecimal("0.1"));
            var staged = fixture.stageSubcontractKit(w, Map.of(p, "10000"));
            UUID order = fixture.createWithFullMaterialBudget(request).getId();
            fixture.stageSubcontractKitUntilApproval(order, staged);
            approveSubcontract(w, order);
            UUID item = itemOf(order);
            String supplyUnit = "10".equals(loss) ? "0.0000011" : "0.0000010001";
            String total = "10".equals(loss) ? "0.0110" : "0.0101";
            String firstUsed = "0.0050";
            var line = planLines(item).get(a);
            qty("0.000001", line.get("base_bom_unit_qty"), "最小原始BOM单耗不变");
            qty(supplyUnit, line.get("bom_unit_qty"), "损耗加成保留第7至10位");
            qty(total, line.get("planned_qty"), "先保留精确供料单耗，再按总量向上保留4位");
            otherIn(w, w.warehouseId(), a, null, total, "10");
            var draw = drawCommands.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item, null)),
                    tag + "-draw-" + item));
            UUID issue = draw.issueIds().getFirst();
            assertDraftLine(issue, a, total, total);
            materialIssues.approve(issue);
            qty(supplyUnit, db.queryForObject("""
                    SELECT frozen_unit_qty FROM subcontract_material_issue_items
                    WHERE issue_id=? AND goods_id=? AND NOT is_deleted
                    """, BigDecimal.class, issue, a), "发料快照不能截断精确供料单耗");
            var firstResult = arrivals.register(new WarehouseArrivalRegisterRequest(
                    tag + "-first-" + item, "SUBCONTRACT", BusinessTime.today(), w.supplierId(), w.warehouseId(),
                    null,w.employeeId(),null,List.of(new ArrivalLine(p,new BigDecimal("5000"),item,null,
                            orderUnit,new BigDecimal("0.1"),null,null)),null,true));
            assertEquals("SUBMITTED_FOR_INSPECTION", firstResult.outcome());
            Receipt first = new Receipt(firstResult.receiptId(), receiptItem(firstResult.receiptId()));
            var partialCase = db.queryForMap("""
                    SELECT id,version FROM subcontract_short_delivery_cases WHERE order_item_id=?
                    ORDER BY detected_at DESC LIMIT 1
                    """, item);
            shortDelivery.decide((UUID) partialCase.get("id"),
                    new com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest(
                            "WAIT_MORE", BusinessTime.today().plusDays(1), "分两批回厂，继续补齐10000目标",
                            ((Number) partialCase.get("version")).longValue()));
            qty(firstUsed, consumed(item, a), "首批按累积5000件向上核销");
            stockIn("SUBCONTRACT", first.receiptId(), passIqc("SUBCONTRACT", first.receiptId(), tag + "-pass1"),
                    tag + "-stock1", w.warehouseId());
            InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a));
            var lastResult = arrivals.register(new WarehouseArrivalRegisterRequest(
                    tag + "-last-" + item,"SUBCONTRACT",BusinessTime.today(),w.supplierId(),w.warehouseId(),
                    null,w.employeeId(),null,List.of(new ArrivalLine(p,new BigDecimal("5000"),item,null,
                            orderUnit,new BigDecimal("0.1"),null,null))));
            assertEquals("SUBMITTED_FOR_INSPECTION",lastResult.outcome());
            Receipt last = new Receipt(lastResult.receiptId(),receiptItem(lastResult.receiptId()));
            qty("0.0100", consumed(item, a), "实际回厂只累计核销base用量，不能把预算加成或逐批ceil计为实际耗损");
            stockIn("SUBCONTRACT", last.receiptId(), passIqc("SUBCONTRACT", last.receiptId(), tag + "-pass2"),
                    tag + "-stock2", w.warehouseId());
            InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a));
            qty(new BigDecimal(total).subtract(new BigDecimal("0.0100")).toPlainString(), supplierEnding(item),
                    "小单耗损耗预算尾料仍留在供应商处，不能自动核销成实际损耗");
            qty("1000", onHand(p, w.warehouseId()), "10000订货单位按0.1换算，成品基本量1000完整入库");
            assertTrue(db.queryForObject("SELECT fn_subcontract_receipt_material_complete(?)", Boolean.class,
                    last.receiptItemId()), "精确损耗单耗满足数据库累计核销守卫");
        }
    }

    @Test
    void twoMaterialsDrawInBatchesWarehouseShortIssueTopsUpAndBatchReturnsCloseWithFinalCost() {
        String tag = "scstep-main";
        var w = fixture.seedWorld(tag);
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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
        PurchaseLine purchase = approvedPurchase(w, w2, b, "200");
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
        assertEquals(2, row.shortKindCount(), "两种都无货可领 → 缺 2 种");
        assertEquals(0, row.drawableKindCount() + row.pendingKindCount() + row.sentFullKindCount(),
                "无货、无待发、无已发");
        assertEquals(1, row.unplannedShortKindCount(), "只有 A 没有在途供应");
        assertFalse(row.canDraw(), "没有可领就不能勾选领料");
        DrawTaskMaterials detail = drawQueries.materials(item);
        assertFalse(detail.allowedActions().contains("DRAW"), "没有任何物料可领 → 不能按物料领料");
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
        // 2026-11-09 按物料领料: 整套还配不出(状态仍按整套「等待物料」), 但 A 已到可以先领。
        assertEquals(1, row.drawableKindCount(), "A 可领 1 种");
        assertEquals(1, row.shortKindCount(), "B 缺 1 种");
        assertFalse(row.canDraw(), "批量领料仍按整套: 配不出一套不能勾选");
        detail = drawQueries.materials(item);
        assertTrue(detail.allowedActions().contains("DRAW"), "A 可领 → 可从「物料」弹窗按物料领料");
        qty("100", material(detail, a).drawableQty(), "A 逐种可领上限 = MIN(可用 100, 需求 100)");
        assertEquals("DRAWABLE", material(detail, a).state());
        assertEquals("SHORT", material(detail, b).state());

        // ④ B 到货一半 80(仓 2): 来料质检合格 → 仓库确认入库 → 按短板可领 40 套(部分可领)。
        receivePurchase(w, w2, b, purchase.orderItemId(), "80", tag + "-b1");
        row = taskRow(orderId);
        assertRow(row, "0", "0", "40", "60", "DRAWABLE_PARTIAL");
        assertTrue(row.canDraw(), "有可领且有领料权限才能勾选");
        assertEquals(2, row.drawableKindCount(), "两种物料都有货可领");
        assertEquals(0, row.shortKindCount(), "可领优先于缺口: B 还差 120 但先落「可领」");
        detail = drawQueries.materials(item);
        ma = material(detail, a);
        qty("100", ma.availableQty(), "A 仓库可用");
        qty("100", ma.drawableQty(), "A 逐种可领上限 = MIN(可用 100, 需求 100), 不按整套折成 40");
        qty("0", ma.shortQty(), "A 还缺");
        assertEquals("DRAWABLE", ma.state());
        mb = material(detail, b);
        qty("80", mb.availableQty(), "B 仓库可用");
        qty("80", mb.drawableQty(), "B 逐种可领上限 = MIN(可用 80, 需求 200)");
        qty("120", mb.shortQty(), "B 还缺");
        assertEquals("DRAWABLE", mb.state(), "B 有货可领, 下一步动作优先于缺口");
        assertTrue(drawQueries.countDrawable() >= 1, "「领料」红数含本任务");
        drainOutboxFor(mine);
        assertDrawAvailableCard(item, w.superAdminUserId());
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
        Long draftVersion = db.queryForObject(
                "SELECT xmin::text::bigint FROM subcontract_material_issues WHERE id=?", Long.class, draftB);
        assertNotNull(draftVersion);
        assertEquals(draftVersion.longValue(), pick.version(), "拣货页版本必须保持数据库草稿行的真实 xmin");

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
        assertDrawAvailableCard(item, w.superAdminUserId());
        qty("70", markOf(item), "可领提醒水位抬到 70");

        // ⑩ 第二次只领 10 套: 领先的 A 已够 40 套不多发, 只补齐落后的 B(再发 20)。
        // 2026-11-09 契约: 候选行含所有开放计划行 × 有量的仓, 有分配量的只有 B。
        DrawPreview topUp = drawQueries.preview(new DrawPreviewRequest(
                List.of(new DrawItemRequest(item, new BigDecimal("10")))));
        DrawPreviewLine topUpLine = topUp.lines().stream()
                .filter(line -> line.qty().signum() > 0).findFirst().orElseThrow();
        assertEquals(b, topUpLine.goodsId());
        assertEquals(w2, topUpLine.warehouseId());
        qty("20", topUpLine.qty(), "B 补 f(40,2) − 60 = 20");
        assertTrue(topUp.lines().stream().anyMatch(line -> line.goodsId().equals(a)
                        && line.qty().signum() == 0), "A 保留 0 候选行, 现状 " + topUp.lines());
        // 2026-11-09 按行领料: 同一批量改用「B@w2 = 20」定向提交, 结果与套数 10 完全一致。
        // 先试单仓超限: 409 明细必须带 (计划行, 仓), 前端据此标红对应输入格。
        UUID bPlan = db.queryForObject(
                "SELECT id FROM subcontract_material_plan_items WHERE order_item_id=? AND goods_id=? AND NOT is_deleted",
                UUID.class, item, b);
        ApiException overDraw = assertThrows(ApiException.class, () -> drawQueries.preview(new DrawPreviewRequest(
                List.of(new DrawItemRequest(item, null, null, null,
                        List.of(new DrawLineRequest(bPlan, w2, new BigDecimal("999"))))))));
        assertEquals("SUBCONTRACT_DRAW_QUANTITY_EXCEEDED", overDraw.details().get("kind"));
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> overRows = (List<Map<String, Object>>) overDraw.details().get("quantities");
        assertEquals(1, overRows.size());
        assertEquals(bPlan, overRows.getFirst().get("planItemId"));
        assertNull(overRows.getFirst().get("warehouseId"), "B 库存全在 w2, 999 超的是整行上限 → 行级明细不带仓");
        assertEquals("140", overRows.getFirst().get("maximumQtyExact"));
        DrawSubmitResult second = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null, null, null,
                        List.of(new DrawLineRequest(bPlan, w2, new BigDecimal("20"))))), "scstep-main-draw-2-" + item));
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
        ApiException shortAcknowledgment=assertThrows(ApiException.class,
                ()->arrivals.register(arrival(w,item,p,"30",tag+"-r1")));
        assertEquals(ErrorCode.SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED,shortAcknowledgment.getCode());
        assertEquals(0,count("SELECT COUNT(*) FROM subcontract_receipt_items WHERE order_item_id=?",item),
                "未确认分批回厂不保存收货，仍沿同一提交键确认");
        qty("0",consumed(item,a),"未确认不核销A");qty("0",consumed(item,b),"未确认不核销B");
        Receipt r1 = registerPartialReturnAndWaitMore(w, item, p, "30", tag + "-r1");
        qty("30", materialBasis(r1.receiptItemId()), "第一批物料口径回厂量");
        qty("30", consumed(item, a), "A 核销 f(30,1)");
        qty("60", consumed(item, b), "B 核销 f(30,2)");
        stockIn("SUBCONTRACT", r1.receiptId(), passIqc("SUBCONTRACT", r1.receiptId(), tag + "-r1-pass"),
                tag + "-r1-stock", w1);
        InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a,b));

        // ⑬ 第二批 40 回厂、质检已判但未入库时红冲: 核销按记录的切片原样退回; 再回厂 40 不因尾差被拦。
        Receipt r2 = registerPartialReturnAndWaitMore(w, item, p, "40", tag + "-r2");
        qty("70", consumed(item, a), "第二批后 A 累计核销");
        qty("140", consumed(item, b), "第二批后 B 累计核销");
        passIqc("SUBCONTRACT", r2.receiptId(), tag + "-r2-pass");
        subcontractReceipts.reverse(r2.receiptId());
        InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a,b));
        qty("30", consumed(item, a), "红冲后 A 核销退回");
        qty("60", consumed(item, b), "红冲后 B 核销退回");
        assertTrue(count("""
                SELECT COUNT(*) FROM subcontract_receipt_material_consumptions
                WHERE receipt_item_id=? AND reversal_of IS NOT NULL
                """, r2.receiptItemId()) >= 2, "两种物料的核销切片都按原样冲回");
        Map<String, Object> basis = db.queryForMap("SELECT * FROM fn_subcontract_receipt_basis(?)", item);
        qty("30", (BigDecimal) basis.get("basis_qty"), "有效回厂物料口径 R");
        assertEquals(1, ((Number) basis.get("reversed_line_count")).intValue(), "一条红冲回厂行");
        Receipt r3 = registerPartialReturnAndWaitMore(w, item, p, "40", tag + "-r3");
        qty("70", consumed(item, a), "再回厂后 A 累计核销 f(70,1)");
        qty("140", consumed(item, b), "再回厂后 B 累计核销 f(70,2)");
        stockIn("SUBCONTRACT", r3.receiptId(), passIqc("SUBCONTRACT", r3.receiptId(), tag + "-r3-pass"),
                tag + "-r3-stock", w1);
        InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a,b));
        qty("0",db.queryForObject("SELECT fn_subcontract_settled_loss_qty(?)",BigDecimal.class,item),
                "三次明确等待剩余目标，不自动认成品损耗");

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
    // 2026-11-09 任务中心「物料」列 → 弹窗按物料领料(整套没齐也能先领已到的物料, 分批)
    // =====================================================================================

    @Test
    void materialDialogDrawsArrivedMaterialInBatchesBeforeTheKitIsComplete() {
        String tag = "scstep-material-path";
        var w = fixture.seedWorld(tag);
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "采购");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID w1 = w.warehouseId();
        UUID orderId = subcontractOrder(w, p, "100", BusinessTime.today().plusDays(10), null);
        approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        // A 到货 60, B 一件没到: 一套也配不出。
        otherIn(w, w1, a, null, "60", "10");

        // 列表逐种分桶: 可领 1 种(A)、缺 1 种(B); 批量领料仍按整套, 不能勾选。
        DrawTaskRow row = taskRow(orderId);
        assertEquals(2, row.materialKindCount());
        assertEquals(1, row.drawableKindCount(), "A 可领");
        assertEquals(1, row.shortKindCount(), "B 缺");
        assertEquals(0, row.sentFullKindCount() + row.pendingKindCount() + row.closedKindCount());
        assertFalse(row.canDraw(), "整套配不出, 批量领料不可勾选");

        // 任务详情: A 逐种可领上限 60, 给出 DRAW 动作(物料弹窗的勾选门)。
        DrawTaskMaterials detail = drawQueries.materials(item);
        assertTrue(detail.allowedActions().contains("DRAW"), "有物料可领 → 可按物料领料");
        DrawTaskMaterial ma = material(detail, a);
        qty("60", ma.drawableQty(), "A 逐种可领 = MIN(可用 60, 需求 100)");
        assertEquals("DRAWABLE", ma.state());
        assertEquals("SHORT", material(detail, b).state());

        // 按物料预览: 只选 A, 默认量 = A 的可领上限 60; 没选中的 B 不分配, 套数进度仍 0。
        DrawPreview preview = drawQueries.preview(new DrawPreviewRequest(List.of(
                new DrawItemRequest(item, null, null, null, null, List.of(ma.planItemId())))));
        DrawPreviewLine aLine = preview.lines().stream()
                .filter(line -> a.equals(line.goodsId())).findFirst().orElseThrow();
        assertEquals(w1, aLine.warehouseId());
        qty("60", aLine.qty(), "A 默认 = 逐种可领上限");
        assertTrue(preview.lines().stream().filter(line -> b.equals(line.goodsId()))
                .allMatch(line -> line.qty().signum() == 0), "未选中的 B 不分配, 现状 " + preview.lines());
        qty("0", preview.tasks().getFirst().qty(), "B 一件没领, 套数进度仍为 0");
        ApiException stale = assertThrows(ApiException.class, () -> drawQueries.preview(new DrawPreviewRequest(
                List.of(new DrawItemRequest(item, null, null, null, null, List.of(UUID.randomUUID()))))));
        assertEquals(ErrorCode.CONFLICT, stale.getCode(), "选中的物料已不属于本任务 → 回任务中心重选");
        ApiException direct = assertThrows(ApiException.class, () -> drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null, null, null, null, List.of(ma.planItemId()))),
                "scstep-material-direct-" + item)));
        assertEquals(ErrorCode.VALIDATION_FAILED, direct.getCode(), "提交必须逐行填写数量");

        // 分批第一批: 只领 A 40(少于默认 60)。A 还剩 20 可领(可领优先于待发), B 仍缺。
        DrawSubmitResult first = drawCommands.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item, null,
                null, null, List.of(new DrawLineRequest(ma.planItemId(), w1, new BigDecimal("40"))))),
                "scstep-material-1-" + item));
        assertEquals(1, first.documentCount());
        assertDraftLine(first.issueIds().getFirst(), a, "40", "40");
        row = taskRow(orderId);
        assertEquals("DRAW_SUBMITTED", row.status());
        assertEquals(1, row.drawableKindCount(), "A 还剩 20 可领");
        assertEquals(1, row.shortKindCount(), "B 缺");
        detail = drawQueries.materials(item);
        qty("20", material(detail, a).drawableQty(), "A 剩余可领 = MIN(可用 20, 需求 100 − 待发 40)");
        qty("40", material(detail, a).pendingQty(), "A 待仓库发 40");

        // 分批第二批: 领完 A 剩下的 20 → A 只剩待仓库发, 落「待发」桶。
        DrawSubmitResult second = drawCommands.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item, null,
                null, null, List.of(new DrawLineRequest(ma.planItemId(), w1, new BigDecimal("20"))))),
                "scstep-material-2-" + item));
        assertEquals(1, second.documentCount());
        row = taskRow(orderId);
        assertEquals(0, row.drawableKindCount(), "A 已没有可领");
        assertEquals(1, row.pendingKindCount(), "A 待仓库发");
        assertEquals(1, row.shortKindCount(), "B 缺");
        detail = drawQueries.materials(item);
        assertEquals("PENDING", material(detail, a).state());
        assertFalse(detail.allowedActions().contains("DRAW"), "没有物料可领 → 物料弹窗不能再勾选");
    }

    // =====================================================================================
    // 撤回未发领料; 结束领料后短交重评
    // =====================================================================================

    @Test
    void withdrawRestoresDrawableAndCloseDrawWithdrawsPendingClosesLinesAndSettlesTolerableShortDelivery() {
        String tag = "scstep-close";
        var w = fixture.seedWorld(tag);
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "自制");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID wh = w.warehouseId();
        Set<UUID> mine = new LinkedHashSet<>(List.of(p, a, b));
        otherIn(w, wh, a, null, "11", "10");
        otherIn(w, wh, b, null, "20.9", "5");
        UUID orderId = subcontractOrder(w, p, "10", BusinessTime.today().plusDays(5), new BigDecimal("10"));
        approveSubcontract(w, orderId);
        UUID item = itemOf(orderId);
        mine.add(item);

        // 发 9.5 套(B 只够 20.9（含损耗单耗 2.2）→ 9.5 套), 回厂 9 并入库: 料没发完不判短交。
        DrawTaskRow row = taskRow(orderId);
        assertRow(row, "0", "0", "9.5", "0.5", "DRAWABLE_PARTIAL");
        DrawSubmitResult issued = drawCommands.submit(new DrawSubmitRequest(
                List.of(new DrawItemRequest(item, null)), "scstep-close-draw-1-" + item));
        issued.issueIds().forEach(materialIssues::approve);
        Receipt receipt = registerReturn(w, item, p, "9", tag + "-r1");
        stockIn("SUBCONTRACT", receipt.receiptId(), passIqc("SUBCONTRACT", receipt.receiptId(), tag + "-pass"),
                tag + "-stock", wh);
        InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a,b));
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_short_delivery_cases WHERE order_item_id=?", item),
                "料没发完(9.5/10)不开短交案件");

        // B 再到 1.1: 又够 0.5 套。提交后撤回: 草稿作废、占用释放、可领恢复、通知仓库已撤回。
        otherIn(w, wh, b, null, "1.1", "5");
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
        Map<String, Object> pendingShortCase = db.queryForMap("""
                SELECT id, status, version, severity, loss_qty, waste_id FROM subcontract_short_delivery_cases
                WHERE order_item_id=? ORDER BY detected_at DESC LIMIT 1
                """, item);
        assertEquals("PENDING_OWNER", pendingShortCase.get("status"), "新计划已加损耗用料，短交须人工明确接受");
        assertNotEquals("WITHIN_TOLERANCE",pendingShortCase.get("severity"),"成品9尚未达到目标10，材料预算不降低成品下限");
        assertNull(pendingShortCase.get("loss_qty"),"结束领料仍未判定成品损耗，不能把未判定默认成确认");
        assertNull(pendingShortCase.get("waste_id"),"负责人决定前不生成材料报损");
        qty("0",db.queryForObject("SELECT fn_subcontract_settled_loss_qty(?)",BigDecimal.class,item),"负责人决定前履约损耗为零");
        qty("9",consumed(item,a),"实际成品9只核销A原始用量9");
        qty("18",consumed(item,b),"实际成品9只核销B原始用量18");
        qty("1.45",db.queryForObject("SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=?",BigDecimal.class,item,a),
                "A真实发出10.45减实际核销9，结存1.45未被预算自动抹掉");
        qty("2.9",db.queryForObject("SELECT SUM(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=?",BigDecimal.class,item,b),
                "B真实发出20.9减实际核销18，结存2.9保留");
        assertFalse(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?",Boolean.class,orderId),"结束领料本身不能把9当成目标10完成");
        shortDelivery.decide((UUID) pendingShortCase.get("id"),
                new com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest(
                        "ACCEPT_LOSS", null, "供应商确认不再交付，经负责人确认接受本次成品短交",
                        ((Number) pendingShortCase.get("version")).longValue()));
        Map<String, Object> shortCase = db.queryForMap("""
                SELECT status, severity, loss_qty, waste_id FROM subcontract_short_delivery_cases
                WHERE id=?
                """, pendingShortCase.get("id"));
        assertEquals("ACCEPTED_LOSS", shortCase.get("status"),
                "负责人显式接受成品损耗后结案，仍保留原订货目标");
        qty("1", (BigDecimal) shortCase.get("loss_qty"), "损耗 1 套");
        UUID wasteId = (UUID) shortCase.get("waste_id");
        assertNotNull(wasteId, "结案开损耗单");
        Map<UUID, BigDecimal> wasted = new HashMap<>();
        db.queryForList("SELECT goods_id, SUM(qty) AS qty FROM subcontract_waste_items WHERE waste_id=? GROUP BY goods_id",
                wasteId).forEach(r -> wasted.put((UUID) r.get("goods_id"), (BigDecimal) r.get("qty")));
        qty("1.45", wasted.get(a), "负责人结损按A真实结存1.45逐笔报损，不能按旧预算核销尾数0.55记账");
        qty("2.9", wasted.get(b), "B按真实结存2.9报损，不按成品短交量重算");
        qty("1",db.queryForObject("SELECT SUM(standard_qty) FROM subcontract_waste_items WHERE waste_id=? AND goods_id=?",BigDecimal.class,wasteId,a),"A正常材料损耗仍只获原冻结预算1");
        qty("2",db.queryForObject("SELECT SUM(standard_qty) FROM subcontract_waste_items WHERE waste_id=? AND goods_id=?",BigDecimal.class,wasteId,b),"B正常材料损耗仍只获原冻结预算2");
        qty("0.45",db.queryForObject("SELECT SUM(qty-standard_qty) FROM subcontract_waste_items WHERE waste_id=? AND goods_id=?",BigDecimal.class,wasteId,a),"A超出预算0.45保留责任差额");
        qty("0.9",db.queryForObject("SELECT SUM(qty-standard_qty) FROM subcontract_waste_items WHERE waste_id=? AND goods_id=?",BigDecimal.class,wasteId,b),"B超出预算0.9不能自动免责");
        assertEquals(1,count("SELECT COUNT(*) FROM subcontract_short_delivery_case_events WHERE case_id=? AND event_type='ACCEPT_LOSS_DECIDED'",pendingShortCase.get("id")),"保留负责人的唯一明确接受事件");
        InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a,b));
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
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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
        assertEquals("原收仓之后已有实际耗用或成本来源变化，请先处理对应后续业务",reverseBlocked.getMessage());
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
        InventoryValueWorkTestSupport.drain(inventoryValueWork,db,List.of(p,a,b));
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
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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
        assertDrawAvailableCard(parentItem, w.superAdminUserId());
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
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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
        assertDrawAvailableCard(item, w.superAdminUserId());
    }

    // =====================================================================================
    // 仓库整行不发: 软删保留提交量, 发料回执列出少发, 下次领料自动补齐
    // =====================================================================================

    @Test
    void aWholeLineTheWarehouseDropsKeepsItsRequestForTheShortIssueReceiptAndTheNextDrawTopsItUp() {
        String tag = "scstep-drop";
        var w = fixture.seedWorld(tag);
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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

        // 第二次领料只补落后的 B 20, 不多发 A。2026-11-09 契约: 候选行含所有开放计划行
        // (A 已发满、四处无库存 → 一条未定仓 0 行), 有分配量的只有 B。
        DrawPreview topUp = drawQueries.preview(new DrawPreviewRequest(List.of(new DrawItemRequest(item, null))));
        assertEquals(2, topUp.lines().size(), "A 保留 0 行 + B 一行, 现状 " + topUp.lines());
        DrawPreviewLine topUpLine = topUp.lines().stream()
                .filter(line -> line.goodsId().equals(b)).findFirst().orElseThrow();
        qty("20", topUpLine.qty(), "B 补 20");
        DrawPreviewLine zeroA = topUp.lines().stream()
                .filter(line -> line.goodsId().equals(a)).findFirst().orElseThrow();
        qty("0", zeroA.qty(), "A 不多发");
        assertNull(zeroA.warehouseId(), "A 无任何可用仓, 行落在未定仓");
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
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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
        DrawTaskRow linkedTask = drawQueries.tasks(1, 50, "", "", orderId, null)
                .page().getItems().getFirst();
        assertEquals(Set.of(application1, application2), Set.copyOf(linkedTask.applicationItemIds()),
                "领料任务保留全部真实申请来源，不能只认主锚点或按比例伪造逐申请领料数量");

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
    void automaticOutboundDeliveryDateFreezesOnlyWithCommittedApprovalAndManualDatesStayFixed() {
        String tag="scstep-delivery-day";
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());
        UUID p=goods(w,tag,"P","委外"),m=goods(w,tag,"M","采购"),leaf=warehouse(tag+"-leaf");
        fixture.insertBom(p,m,"1");otherIn(w,leaf,m,null,"10","5");
        UUID order=subcontractOrder(w,p,"10",BusinessTime.today().plusDays(9),null);approveSubcontract(w,order);
        UUID item=itemOf(order);
        UUID automatic=drawCommands.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item,new BigDecimal("5"))),"scstep-auto-day-"+item)).issueIds().getFirst();
        assertNull(materialIssues.detail(automatic).getDeliverDate(),"自动日期在服务器草稿里应保持未指定");
        warehousePick(automatic,m,"5");
        assertNull(materialIssues.detail(automatic).getDeliverDate(),"保存拣货草稿不能提前冻结自动日期");
        new TransactionTemplate(beans.getBean(PlatformTransactionManager.class)).executeWithoutResult(transaction->{
            assertEquals(BusinessTime.today(),materialIssues.approve(automatic).getDeliverDate());
            transaction.setRollbackOnly(); // A later part of the outbound command failed.
        });
        assertNull(materialIssues.detail(automatic).getDeliverDate(),"失败事务必须连自动日期一起回滚");
        assertEquals(0,materialIssues.detail(automatic).getStatus().intValue());qty("10",onHand(m,leaf),"失败不能留下出库");
        var approved=materialIssues.approve(automatic);assertEquals(BusinessTime.today(),approved.getDeliverDate());
        LocalDate recorded=approved.getDeliverDate();assertThrows(ApiException.class,()->materialIssues.approve(automatic));
        assertEquals(recorded,materialIssues.detail(automatic).getDeliverDate(),"重复动作不能改已审单据日期");
        UUID manual=drawCommands.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item,new BigDecimal("5"))),"scstep-manual-day-"+item)).issueIds().getFirst();
        LocalDate chosen=BusinessTime.today().minusDays(3);warehousePick(manual,m,"5",chosen);
        assertEquals(chosen,materialIssues.approve(manual).getDeliverDate(),"明确填写的日期始终保留");
    }

    @Test
    void aDisabledLeafStillHoldingStockIsDrawableAndItsDraftCanBeEditedAndIssuedInPlace() {
        String tag = "scstep-disabled";
        var w = fixture.seedWorld(tag);
        // 2026-10-09 真实授权口径(ADR-063 追加修订): 超管镜像不算任务归属——发卡池按
        // grantedPermsOf 解析, 操作员必须真实拿到领料链的码才收得到可领料卡。
        grantAuthorities(w.superAdminUserId(),
                "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all");
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
    private PurchaseLine approvedPurchase(FullChainEndToEndTest.World w, UUID warehouseId, UUID goodsId, String qty) {
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
        UUID orderId = fixture.createWithFullMaterialBudget(
                orderRequest(w, goodsId, qty, deliverDate, allowedLossPct)).getId();
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
        // 本测试不经申请分解下单, source_doc_no 为空 → 来源计划列回落订货单号(V836 订货段同口径)。
        assertEquals(billNo(orderId), rows.getFirst().planNo(), "来源计划 = 订货单号(source_doc_no 为空回落)");
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
                SELECT goods_id, color_id, base_bom_unit_qty, material_loss_pct, bom_unit_qty, planned_qty, issued_qty, draw_closed_at
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
        warehousePick(issueId,goodsId,qty,materialIssues.detail(issueId).getDeliverDate());
    }

    private void warehousePick(UUID issueId,UUID goodsId,String qty,LocalDate deliveryDate) {
        MaterialIssueDetail draft = materialIssues.detail(issueId);
        var request = new MaterialIssueSaveRequest();
        request.setBillDate(draft.getBillDate());
        request.setSupplierId(draft.getSupplierId());
        request.setWarehouseId(draft.getWarehouseId());
        request.setDeliverDate(deliveryDate);
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

    /** This scenario explicitly acknowledges a partial delivery and its owner chooses WAIT_MORE. */
    private Receipt registerPartialReturnAndWaitMore(FullChainEndToEndTest.World w,UUID orderItemId,UUID goodsId,String qty,String key) {
        var request=arrival(w,orderItemId,goodsId,qty,key);
        var result=arrivals.register(new WarehouseArrivalRegisterRequest(request.idempotencyKey(),request.orderType(),
                request.billDate(),request.supplierId(),request.warehouseId(),request.purchaserId(),request.receiverEmployeeId(),
                request.remark(),request.items(),null,true));
        assertEquals("SUBMITTED_FOR_INSPECTION",result.outcome(),"明确确认分批数量后按实数送检");
        var open=db.queryForMap("SELECT id,version FROM subcontract_short_delivery_cases WHERE order_item_id=? AND status IN('PENDING_OWNER','WAITING_MORE') ORDER BY detected_at DESC LIMIT 1",orderItemId);
        shortDelivery.decide((UUID)open.get("id"),new com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest(
                "WAIT_MORE",BusinessTime.today().plusDays(1),"确认本次实际分批回厂，继续等待原成品目标的剩余数量",((Number)open.get("version")).longValue()));
        return new Receipt(result.receiptId(),receiptItem(result.receiptId()));
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

    private void assertDrawAvailableCard(UUID orderItemId, UUID audience) {
        List<Map<String, Object>> cards = db.queryForList("""
                SELECT title, action_route FROM notices
                WHERE audience_user_id=? AND source_event='SUBCONTRACT_DRAW_AVAILABLE' AND aggregate_id=?
                  AND resolved_at IS NULL
                """, audience, orderItemId);
        assertEquals(1, cards.size(), "每个委外任务一张未办结的可领料卡, 现状 " + cards);
        String title = String.valueOf(cards.getFirst().get("title"));
        assertTrue(title.startsWith("委外可领料：") && !title.contains("预算可领"), title);
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

    private static void qtyDecimal(String expected, BigDecimal actual, String what) {
        assertNotNull(actual, what + ": 现状 null, 期望 " + expected);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), what + ": 现状 " + actual + " 期望 " + expected);
    }

    private static void qty(String expected, Object actual, String what) {
        assertNotNull(actual, what + ": 现状 null, 期望 " + expected);
        BigDecimal value = actual instanceof BigDecimal decimal ? decimal : new BigDecimal(actual.toString());
        qtyDecimal(expected, value, what);
    }
}
