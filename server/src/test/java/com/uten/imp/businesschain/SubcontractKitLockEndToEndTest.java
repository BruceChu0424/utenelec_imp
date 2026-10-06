package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.operations.workbench.FulfillmentTaskRow;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.NotifyRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.subcontract.application.SubcontractApplicationService;
import com.uten.imp.features.subcontract.application.dto.DecompositionPreviewItem;
import com.uten.imp.features.subcontract.kit.SubcontractKitService.ApplicationKit;
import com.uten.imp.features.subcontract.kit.SubcontractKitService.MaterialFact;
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

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * ADR-156 委外申请物料齐套才解锁下单的真库验收。
 *
 * <p>主链: 成品 F(自制) 的直属子件 P(委外), P 的直属物料 A(单耗 1)与 B(单耗 2)。计划员下达委外申请 P 100:
 * <ol>
 *   <li>一点物料都没有: 任务中心行「等物料齐套」(留在待处理, 不能生成订货单), 齐套情况逐种列还缺, 下单 409;</li>
 *   <li>A 到 100、B 到 80: 够做 40 套 → 「可部分下单」可下单 40, 采购委外部门的人收到「委外可下单 40」行动卡;</li>
 *   <li>下 41 被拒, 下 40 放行; 草稿占住物料后申请剩下的 60 又锁住, 另一张申请也锁住;</li>
 *   <li>送审、批准放行; 再到 B 20 → 两张申请各自可下单 10, 一起带单时按需求日期先后只够前一张;</li>
 *   <li>后一张先下了草稿 → 前一张的可下单卡撤回; B 被别处领走 → 那张草稿送审 409; 删掉草稿放出物料;</li>
 *   <li>批准后加量没有物料 409, 减量不拦。</li>
 * </ol>
 *
 * <p>另一用例: 没有来源申请的手工委外单同样要直属物料齐套, 只能用公共库存, 已批准的单还要领的量先占住。
 * 专属批次(物料分析分给申请的库存)的口径由 SubcontractApplicationKitPostgresTest 按真函数体覆盖。
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
class SubcontractKitLockEndToEndTest {

    private static final String PENDING_ROUTE = "/operations/workbench/subcontract?segment=pending&keyword=";

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractOrderService orders;
    @Autowired SubcontractApplicationService applications;
    @Autowired FulfillmentWorkbenchQueryService workbench;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired StockDocService stockDocs;
    @Autowired BusinessOutboxProcessor outbox;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService analysisCommands;

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

    @Test
    void anApplicationStaysLockedUntilItsDirectMaterialsKitAndOnlyTheKittedQuantityCanBeOrdered() {
        String tag = "sckit-main";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID f = goods(w, tag, "F", "自制");
        UUID p = goods(w, tag, "P", "委外");
        UUID a = goods(w, tag, "A", "采购");
        UUID b = goods(w, tag, "B", "采购");
        fixture.insertBom(f, p, "1");
        fixture.insertBom(p, a, "1");
        fixture.insertBom(p, b, "2");
        UUID wh = w.warehouseId();
        UUID buyer = subcontractBuyer(w, tag);
        Set<UUID> mine = new LinkedHashSet<>(List.of(f, p, a, b));

        PreviewItem source1 = new PreviewItem("OTHER", null, f, null, w.unitId(), "KIT-1-" + tag, "委外齐套锁定",
                BusinessTime.today().plusDays(5), new BigDecimal("100"));
        UUID application1 = applicationItemOf(notifySubcontract(w, source1, p, tag + "-a1"), p);
        mine.add(application1);
        String bill1 = billNo(application1);

        // ① 一点物料都没有: 锁住, 留在「待处理」, 不能生成订货单。
        FulfillmentTaskRow row = applicationRow(application1);
        assertEquals("WAITING_ORDER", row.taskStatus(), "锁住的申请仍在「待处理」分段(照计红数)");
        assertEquals("WAITING_KIT", row.displayStage(), "状态列显示等物料齐套");
        assertFalse(row.canCreateOrder(), "锁住的申请不能勾选生成订货单");
        qty("0", row.orderableQty(), "可下单");
        ApplicationKit kit = applications.kit(application1);
        qty("100", kit.openQty(), "剩余未下单");
        qty("0", kit.kitQty(), "够做套数");
        qty("0", kit.orderableQty(), "可下单");
        assertFalse(kit.bomMissing());
        assertEquals(2, kit.materials().size(), "两种直属物料");
        qty("100", fact(kit, a).shortQty(), "A 还缺 100");
        qty("200", fact(kit, b).shortQty(), "B 还缺 200");
        qty("0", preview(application1).orderableQty(), "带单预填 0");
        ApiException locked = assertThrows(ApiException.class, () -> orderFrom(w, p, "1", application1));
        assertEquals(ErrorCode.CONFLICT, locked.getCode());
        assertTrue(locked.getMessage().contains("直属物料还没齐套，不能生成委外订货单"), locked.getMessage());
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_order_item_sources WHERE application_item_id=?",
                application1), "被拒的下单整笔回滚");

        // ② A 到 100、B 到 80: 够做 40 套, 可部分下单; 采购委外部门收到「可下单 40」行动卡。
        otherIn(w, wh, a, "100");
        otherIn(w, wh, b, "80");
        row = applicationRow(application1);
        assertEquals("KIT_PARTIAL", row.displayStage());
        assertTrue(row.canCreateOrder(), "够做一部分就解锁");
        qty("40", row.orderableQty(), "可下单 = MIN(100, 40)");
        kit = applications.kit(application1);
        qty("40", kit.kitQty(), "够做 40 套");
        qty("100", fact(kit, a).freeQty(), "A 现在能用");
        qty("80", fact(kit, b).freeQty(), "B 现在能用");
        qty("120", fact(kit, b).shortQty(), "B 剩余 100 套还缺 120");
        DecompositionPreviewItem previewed = preview(application1);
        qty("40", previewed.orderableQty(), "带单预填 40");
        qty("40", previewed.kitQty(), "预览够做套数");
        drainOutboxFor(mine);
        qty("40", markOf(application1), "可下单提醒水位");
        assertKitCard(application1, buyer, "可下单 40", bill1);

        // ③ 下 41 被拒(B 需要 82 只有 80), 下 40 放行; 草稿占住物料后剩下的 60 又锁住。
        ApiException tooMany = assertThrows(ApiException.class, () -> orderFrom(w, p, "41", application1));
        assertEquals(ErrorCode.CONFLICT, tooMany.getCode());
        assertTrue(tooMany.getMessage().contains("本单需要 82"), tooMany.getMessage());
        assertTrue(tooMany.getMessage().contains("现在能用的只有 80"), tooMany.getMessage());
        UUID order1 = orderFrom(w, p, "40", application1);
        row = applicationRow(application1);
        assertEquals("WAITING_KIT", row.displayStage(), "物料被草稿占住, 剩下的申请数量重新锁住");
        qty("0", row.orderableQty(), "可下单");
        kit = applications.kit(application1);
        qty("40", fact(kit, a).publicClaimedQty(), "A 被本申请的草稿占用 40");
        qty("80", fact(kit, b).publicClaimedQty(), "B 被占用 80");
        PreviewItem source2 = new PreviewItem("OTHER", null, f, null, w.unitId(), "KIT-2-" + tag, "委外齐套锁定",
                BusinessTime.today().plusDays(9), new BigDecimal("10"));
        UUID application2 = applicationItemOf(notifySubcontract(w, source2, p, tag + "-a2"), p);
        mine.add(application2);
        assertEquals("WAITING_KIT", applicationRow(application2).displayStage(), "另一张申请也拿不到被占住的物料");

        // ④ 送审、批准放行(物料仍齐); 申请已下单 40 → 剩 60。
        approve(w, order1);
        UUID orderItem1 = itemOf(order1);
        mine.add(orderItem1);
        qty("60", applications.kit(application1).openQty(), "批准回写已下单后剩 60");

        // ⑤ B 再到 20: 两张申请各自看都能下 10; 一起带单时按需求日期先后, 只够前一张。
        otherIn(w, wh, b, "20");
        qty("10", applicationRow(application1).orderableQty(), "申请 1 可下单 10");
        qty("10", applicationRow(application2).orderableQty(), "申请 2 可下单 10");
        List<DecompositionPreviewItem> joint = applications.decompositionPreview(List.of(application2, application1));
        qty("10", previewOf(joint, application1).orderableQty(), "需求日期早的申请 1 先分");
        qty("0", previewOf(joint, application2).orderableQty(), "申请 2 只能用分剩的公共库存");
        drainOutboxFor(mine);
        assertKitCard(application1, buyer, "可下单 10", bill1);

        // ⑥ 申请 2 先下了草稿 → 申请 1 的可下单卡撤回、水位降到 0。
        UUID order2 = orderFrom(w, p, "10", application2);
        qty("0", applicationRow(application1).orderableQty(), "B 被申请 2 的草稿占走");
        drainOutboxFor(mine);
        qty("0", markOf(application1), "可下单归零降水位");
        assertNoKitCard(application1, buyer);

        // ⑦ B 被别处领走 20 → 申请 2 的草稿送审 409; 删掉草稿放出物料(A 还在, B 没了, 仍锁)。
        otherOut(w, wh, b, "20");
        ApiException submit = assertThrows(ApiException.class, () -> financeApproval.submit("SUBCONTRACT", order2));
        assertEquals(ErrorCode.CONFLICT, submit.getCode());
        assertTrue(submit.getMessage().contains("直属物料还没齐套，不能提交财务"), submit.getMessage());
        orders.delete(order2);
        assertEquals("WAITING_KIT", applicationRow(application1).displayStage(), "B 没有了, 申请 1 仍锁住");

        // ⑧ 批准后加量没有物料 409; 减量不拦。
        ApiException increase = assertThrows(ApiException.class, () -> orders.changeQty(order1,
                new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(orderItem1, new BigDecimal("45"))))));
        assertEquals(ErrorCode.CONFLICT, increase.getCode());
        assertTrue(increase.getMessage().contains("不能加量"), increase.getMessage());
        orders.changeQty(order1, new OrderQtyChangeRequest(
                List.of(new OrderQtyChangeItem(orderItem1, new BigDecimal("35")))));
        qty("35", db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class,
                orderItem1), "减量生效");
    }

    @Test
    void aManualOrderWithoutAnApplicationAlsoNeedsItsDirectMaterialsAndUsesPublicStockOnly() {
        String tag = "sckit-manual";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID m = goods(w, tag, "M", "采购");
        fixture.insertBom(p, m, "3");
        UUID wh = w.warehouseId();

        ApiException none = assertThrows(ApiException.class, () -> orderFrom(w, p, "1", null));
        assertEquals(ErrorCode.CONFLICT, none.getCode(), "手工委外单同样要直属物料齐套");
        assertTrue(none.getMessage().contains("本单需要 3"), none.getMessage());
        otherIn(w, wh, m, "10");
        ApiException four = assertThrows(ApiException.class, () -> orderFrom(w, p, "4", null));
        assertTrue(four.getMessage().contains("本单需要 12") && four.getMessage().contains("现在能用的只有 10"),
                four.getMessage());
        UUID orderId = orderFrom(w, p, "3", null);
        approve(w, orderId);
        ApiException second = assertThrows(ApiException.class, () -> orderFrom(w, p, "1", null),
                "第一张单还要领 9, 公共库存只剩 1, 不够再做 1 套");
        assertEquals(ErrorCode.CONFLICT, second.getCode());
    }

    // =====================================================================================

    private UUID goods(FullChainEndToEndTest.World w, String tag, String code, String sourceType) {
        UUID id = UUID.randomUUID();
        String label = "SCK-" + code + "-" + tag;
        fixture.insertGoods(id, label, label, sourceType, w.unitId(), w.unitLegacy());
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?", w.supplierId(), id);
        return id;
    }

    /** 采购委外部门里能读通知、能看委外申请、能生成委外订货单的人(可下单卡的收件人)。 */
    private UUID subcontractBuyer(FullChainEndToEndTest.World w, String tag) {
        UUID user = fixture.createUserWithPerms(w, tag + "-buyer", "notice:read", "subcontract_application:view",
                "subcontract_order:decompose");
        db.update("""
                UPDATE employees SET department_id = (SELECT id FROM departments
                                                       WHERE code='SUB_PURCHASE' AND NOT is_deleted LIMIT 1)
                WHERE id = (SELECT employee_id FROM users WHERE id=?)
                """, user);
        return user;
    }

    private void otherIn(FullChainEndToEndTest.World w, UUID warehouseId, UUID goodsId, String qty) {
        stockDoc(w, "OTHER_IN", warehouseId, goodsId, qty);
    }

    private void otherOut(FullChainEndToEndTest.World w, UUID warehouseId, UUID goodsId, String qty) {
        stockDoc(w, "OTHER_OUT", warehouseId, goodsId, qty);
    }

    private void stockDoc(FullChainEndToEndTest.World w, String type, UUID warehouseId, UUID goodsId, String qty) {
        fixture.loginAs(w.superAdminUserId());
        var request = new StockDocSaveRequest();
        request.setDocType(type);
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(warehouseId);
        request.setRemark("委外齐套锁定测试 " + type + " " + qty);
        var line = new StockDocItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        if ("OTHER_IN".equals(type)) {
            line.setPrice(BigDecimal.TEN);
            line.setAmountOriginal(line.getQty().multiply(BigDecimal.TEN));
            line.setAmountLocal(line.getAmountOriginal());
        }
        request.setItems(List.of(line));
        stockDocs.approve(stockDocs.create(request).getId());
    }

    /** 从委外任务中心带单下单(applicationItem 为 null 时是没有来源申请的手工委外单)。 */
    private UUID orderFrom(FullChainEndToEndTest.World w, UUID goodsId, String qty, UUID applicationItem) {
        fixture.loginAs(w.superAdminUserId());
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
        if (applicationItem != null) {
            line.setApplicationItemId(applicationItem);
            line.setApplicationItemIds(List.of(applicationItem));
        }
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("30"));
        request.setItems(List.of(line));
        return orders.create(request).getId();
    }

    private void approve(FullChainEndToEndTest.World w, UUID orderId) {
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("SUBCONTRACT", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId);
        fixture.loginAs(w.superAdminUserId());
        assertEquals(1, ((Number) db.queryForObject("SELECT status FROM subcontract_orders WHERE id=?",
                Integer.class, orderId)).intValue(), "委外订货单已财务批准");
    }

    private UUID itemOf(UUID orderId) {
        return db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",
                UUID.class, orderId);
    }

    private FulfillmentTaskRow applicationRow(UUID applicationItemId) {
        UUID applicationId = db.queryForObject(
                "SELECT application_id FROM subcontract_application_items WHERE id=?", UUID.class, applicationItemId);
        List<FulfillmentTaskRow> rows = workbench.query("SUBCONTRACT", "WAITING_ORDER", billNo(applicationItemId),
                "", null, null, 1, 50).items().stream()
                .filter(candidate -> applicationId.equals(candidate.actionDocId())).toList();
        assertEquals(1, rows.size(), "任务中心待处理里这张申请恰好一行, 现状 " + rows);
        return rows.getFirst();
    }

    private String billNo(UUID applicationItemId) {
        return db.queryForObject("""
                SELECT application.bill_no FROM subcontract_application_items item
                JOIN subcontract_applications application ON application.id = item.application_id
                WHERE item.id=?
                """, String.class, applicationItemId);
    }

    private DecompositionPreviewItem preview(UUID applicationItemId) {
        return previewOf(applications.decompositionPreview(List.of(applicationItemId)), applicationItemId);
    }

    private static DecompositionPreviewItem previewOf(List<DecompositionPreviewItem> items, UUID applicationItemId) {
        return items.stream().filter(item -> applicationItemId.equals(item.sourceItemId())).findFirst()
                .orElseThrow(() -> new AssertionError("预览里没有申请明细 " + applicationItemId));
    }

    private static MaterialFact fact(ApplicationKit kit, UUID goodsId) {
        return kit.materials().stream().filter(material -> goodsId.equals(material.goodsId())).findFirst()
                .orElseThrow(() -> new AssertionError("齐套情况里没有物料 " + goodsId));
    }

    private BigDecimal markOf(UUID applicationItemId) {
        List<BigDecimal> marks = db.queryForList("""
                SELECT notified_orderable FROM subcontract_application_kit_notice_marks WHERE application_item_id=?
                """, BigDecimal.class, applicationItemId);
        return marks.isEmpty() ? BigDecimal.ZERO : marks.getFirst();
    }

    private void assertKitCard(UUID applicationItemId, UUID audience, String expectedFragment, String billNo) {
        List<Map<String, Object>> cards = db.queryForList("""
                SELECT title, action_route FROM notices
                WHERE audience_user_id=? AND source_event='SUBCONTRACT_ORDER_KIT_READY' AND aggregate_id=?
                  AND resolved_at IS NULL
                """, audience, applicationItemId);
        assertEquals(1, cards.size(), "每个委外申请明细一张未办结的可下单卡, 现状 " + cards);
        assertTrue(String.valueOf(cards.getFirst().get("title")).contains(expectedFragment),
                "可下单卡按实时可下单量生成, 期望含「" + expectedFragment + "」, 现状 " + cards.getFirst().get("title"));
        assertEquals(PENDING_ROUTE + billNo, cards.getFirst().get("action_route"), "卡片直达「待处理」并按申请单号搜索");
    }

    private void assertNoKitCard(UUID applicationItemId, UUID audience) {
        assertEquals(0, count("""
                SELECT COUNT(*) FROM notices
                WHERE audience_user_id=? AND source_event='SUBCONTRACT_ORDER_KIT_READY' AND aggregate_id=?
                  AND resolved_at IS NULL
                """, audience, applicationItemId), "可下单归零后卡片要收回");
    }

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

    /** 投递 outbox 直到本用例自己的聚合没有待投递事件(与委外领料真库验收同一做法)。 */
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
        qty(expected, actual instanceof BigDecimal decimal ? decimal : new BigDecimal(actual.toString()), what);
    }
}
