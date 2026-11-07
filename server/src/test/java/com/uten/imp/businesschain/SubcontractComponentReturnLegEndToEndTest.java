package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawQueryService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskRow;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.CaseDetail;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.CaseRow;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.Counts;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
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
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static com.uten.imp.support.BusinessNoticeFixtures.grant;

/**
 * 委外件只有一种直属物料时(ADR-143 §二.2: 与多种物料同一流程, 计划行只有一条; 发出去的是直属物料
 * goodsD, 回来的是委外件 goodsE)的回厂段真库全链, 按用户第 4 条逐场景验收 (1000 / 允许损耗 10% /
 * 物料:委外件 = 1:1 / 料已全部发出):
 *
 * <ul>
 *   <li>T1 一次到 950：成品目标仍为 1000。仓库照实登记，负责人认损 50 后再入库；
 *       实收与认损分别保留，不改订货量或生成财务改量复核。</li>
 *   <li>T2 800 → 分批 → 150：严重短交先锁住，负责人判定分批后允许已合格批次入库。
 *       累计 950 仍短交，逾期继续受控，负责人明确认损后按独立事实结案。</li>
 *   <li>T3 超收 1050 (料只发了 1000): 登记落到货异常通知财务, 文案点明「委外商自带料」; 财务批准后
 *       仓库一键入库必须走得通 —— 回厂只核销我方发出的 1000, 多出的 50 按自带料入库, 守恒不放松
 *       (ADR-143 §二.12)。</li>
 *   <li>T4 下单不受物料库存限制 (ADR-143 §六.7); 物料只在不良品仓有货时领料任务没有可领 (ADR-143 §三.5
 *       作业叶仓口径 = ADR-146 计入可用量的仓); 普通调拨不能把不良品搬回良品仓, 只有「不良复判转回」后才可领
 *       (ADR-146 不良品专门通道)。</li>
 * </ul>
 *
 * <p>骨架复制自 {@link SubcontractToleranceAutoSettleEndToEndTest} 与 {@link SubcontractShortDeliveryEndToEndTest}。
 * 物料到货一律走其它入库单审核; 财务批准后由委外人员提交领料、仓库审核发出 (ADR-143 §4.2), 系统不自动建出仓草稿。
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
class SubcontractComponentReturnLegEndToEndTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractOrderService orders;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired SubcontractMaterialIssueService materialIssues;
    @Autowired SubcontractShortDeliveryService shortDeliveries;
    @Autowired SubcontractReceiptService subcontractReceipts;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired ProcurementArrivalControlService arrivalControl;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcStockInService iqcStockIn;
    @Autowired StockDocService stockDocs;
    @Autowired BusinessOutboxProcessor outbox;
    @Autowired SubcontractDrawQueryService drawQueries;

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

    // ===================== T1 =====================

    @Test
    void singleReturnOf950RequiresOwnerDecisionAndPreservesActualReceiptAndCommercialQuantity() {
        var w = fixture.seedWorld("sc-comp-return-950");
        fixture.loginAs(w.superAdminUserId());
        bindDirectMaterialBom(w);
        receiveChildStock(w, "1000", w.warehouseId());

        // ① 物料已到 1000 → 建单 1000 / 允许损耗 10% → 送审批准 → 委外人员领满 1000 → 仓库全部发出。
        Ordered ordered = orderApproveAndIssueAll(w, "1000");
        qty("1000", db.queryForObject(
                "SELECT COALESCE(SUM(at_supplier_qty),0) FROM subcontract_material_issue_items WHERE order_item_id=?",
                BigDecimal.class, ordered.itemId()), "料必须全部发出, 否则短交程度根本不判 (ADR-101 §2.5)");
        qty("0", onHand(w.goodsD(), w.warehouseId()), "子件应全部发给委外商, 现状仓里还有余量");
        assertEquals(1, count("""
                SELECT COUNT(*) FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_plan_items plan_item ON plan_item.id=issue_item.plan_item_id
                WHERE issue_item.order_item_id=? AND issue_item.is_deleted=FALSE
                  AND issue_item.frozen_unit_qty=plan_item.bom_unit_qty
                """, ordered.itemId()),
                "发料行冻结单耗 frozen_unit_qty 必须等于计划行 bom_unit_qty (1:1), 否则回厂消费口径漂移");

        // ② 950 仍低于成品目标 1000，供料预算不能替仓库填足实收。
        var unacknowledged=assertThrows(ApiException.class,()->registerReturn(w,ordered.itemId(),"950","t1-950",false));
        assertEquals(ErrorCode.SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED,unacknowledged.getCode());
        assertEquals(0,count("SELECT COUNT(*) FROM subcontract_short_delivery_cases WHERE order_item_id=?",ordered.itemId()));
        WarehouseArrivalRegisterResult receipt = registerReturn(w, ordered.itemId(), "950", "t1-950", true);
        assertEquals("SUBMITTED_FOR_INSPECTION", receipt.outcome());
        Map<String, Object> pending = caseRow(ordered.itemId());
        assertEquals("PENDING_OWNER", pending.get("status"), "登记后案件现状 " + pending.get("status") + " 期望 PENDING_OWNER");
        assertEquals("BELOW_FLOOR", pending.get("severity"));
        qty("1000",(BigDecimal)pending.get("floor_qty"),"短交门槛保留原成品目标");
        qty("950",(BigDecimal)pending.get("delivered_qty"),"登记保留实收数");
        assertNotNull(shortDeliveries.stockInHoldReason(receipt.receiptId()));

        // ③ 来料质检合格仍不能绕过待判定。负责人明确认损后才允许仓库入库。
        PassSlice pass = passIqc(receipt.receiptId(), "sc-comp-t1-pass");
        qty("950", pass.qty(), "放行切片量");
        UUID keeper = ReflectionTestUtils.invokeMethod(fixture, "createIqcWarehouseConfirmer", w, "sc-comp-t1-keeper");
        var held=assertThrows(ApiException.class,()->stockIn(keeper,receipt.receiptId(),pass,"sc-comp-t1-stock-in",w));
        assertEquals(ErrorCode.CONFLICT,held.getCode());
        assertEquals(0,count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?",receipt.receiptId()));
        fixture.loginAs(w.superAdminUserId());
        acceptShortDelivery(pending,"委外商确认 50 件加工报废");
        assertNull(shortDeliveries.stockInHoldReason(receipt.receiptId()));
        stockIn(keeper, receipt.receiptId(), pass, "sc-comp-t1-stock-in", w);
        fixture.loginAs(w.superAdminUserId());
        qty("950", onHand(w.goodsE(), w.warehouseId()), "委外件库存现状 " + onHand(w.goodsE(), w.warehouseId()) + " 期望 +950");
        qty("0", onHand(w.goodsD(), w.warehouseId()), "子件库存现状 " + onHand(w.goodsD(), w.warehouseId()) + " 期望 0");

        Map<String, Object> settled = caseRow(ordered.itemId());
        assertEquals(pending.get("id"), settled.get("id"), "结的必须是同一个案件, 不是另开一张");
        assertEquals("ACCEPTED_LOSS", settled.get("status"), "结案来自负责人的明确认损");
        qty("50", (BigDecimal) settled.get("loss_qty"), "损耗量");
        qty("5", (BigDecimal) settled.get("loss_pct"), "损耗率 50/1000");
        UUID wasteId = (UUID) settled.get("waste_id");
        assertNotNull(wasteId, "接受损耗结案必须先开一张损耗单核销供应商处剩料, 现状 waste_id 为空");
        assertEquals(1, count("SELECT COUNT(*) FROM subcontract_wastes WHERE id=? AND status=1", wasteId), "损耗单必须已审核");
        qty("50", db.queryForObject("SELECT SUM(qty) FROM subcontract_waste_items WHERE waste_id=?", BigDecimal.class, wasteId),
                "损耗单核销的是发出去的子件 50");
        assertEquals(w.goodsD(), db.queryForObject(
                "SELECT goods_id FROM subcontract_waste_items WHERE waste_id=? LIMIT 1", UUID.class, wasteId),
                "路线 B 损耗单上的货品必须是子件 goodsD, 不是委外件");
        qty("1000", db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, ordered.itemId()),
                "允许损耗独立结清履约, 原订货数量不变");
        qty("950", db.queryForObject("SELECT received_qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, ordered.itemId()),
                "真实回厂数量不加上损耗冒充足额实收");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM procurement_order_qty_change_logs
                WHERE order_type='SUBCONTRACT' AND order_item_id=?
                """, ordered.itemId()), "按约定损耗结案不生成改量日志");
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, ordered.orderId()),
                "合格实收 950 + 已接受损耗 50 = 原订货 1000, 应正常关单");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM procurement_order_approval_cases
                WHERE order_type='SUBCONTRACT' AND order_id=? AND status='PENDING'
                """, ordered.orderId()), "实际损耗结案不另开财务改量复核");
        assertEquals(1, count("""
                SELECT COUNT(*) FROM procurement_order_approval_cases
                WHERE order_type='SUBCONTRACT' AND order_id=?
                """, ordered.orderId()), "保留首次订货批准, 不增加第二条改量审批");
        assertNull(settled.get("qty_change_log_id"), "新损耗履约事实不关联缩单日志");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM subcontract_short_delivery_cases
                WHERE order_item_id=? AND status IN ('PENDING_OWNER','WAITING_MORE')
                """, ordered.itemId()), "结完之后不再有开放案件");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM subcontract_material_issue_items item
                JOIN subcontract_material_issues issue ON issue.id=item.issue_id
                WHERE item.plan_item_id=? AND issue.status=0 AND issue.is_deleted=FALSE
                """, ordered.planItemId()), "关单后不得再留未审出仓草稿");
    }

    // ===================== T2 =====================

    @ParameterizedTest(name = "分批短交保留待办直至明确认损, 已逾期={0}")
    @ValueSource(booleans = {true, false})
    void severeShortReturnOf800Then150RemainsBelowTargetUntilTheOwnerAcceptsLoss(boolean overdue) {
        var w = fixture.seedWorld("sc-comp-return-split-" + overdue);
        // The owner performs the decision; the SA marker alone never subscribes to business cards.
        grant(db, w.superAdminUserId(), "notice:read", "subcontract_order:view", "subcontract_short_delivery:decide");
        fixture.loginAs(w.superAdminUserId());
        bindDirectMaterialBom(w);
        receiveChildStock(w, "1000", w.warehouseId());
        Ordered ordered = orderApproveAndIssueAll(w, "1000");

        // ① 第一批 800 < 成品目标 1000 → 严重短交，仓库确认后登记实收。
        ApiException blocked = assertThrows(ApiException.class,
                () -> registerReturn(w, ordered.itemId(), "800", "t2-800", false),
                "严重短交未经仓库确认不得登记");
        assertEquals(ErrorCode.SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED, blocked.getCode(),
                "错误码现状 " + blocked.getCode() + " 期望 SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED");
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_short_delivery_cases WHERE order_item_id=?", ordered.itemId()),
                "409 之前不得留下任何案件");
        WarehouseArrivalRegisterResult first = registerReturn(w, ordered.itemId(), "800", "t2-800", true);
        assertEquals("SUBMITTED_FOR_INSPECTION", first.outcome());
        Map<String, Object> detected = caseRow(ordered.itemId());
        UUID caseId = (UUID) detected.get("id");
        assertEquals("PENDING_OWNER", detected.get("status"), "案件现状 " + detected.get("status") + " 期望 PENDING_OWNER");
        assertEquals("SEVERE", detected.get("severity"), "程度现状 " + detected.get("severity") + " 期望 SEVERE");
        qty("800", (BigDecimal) detected.get("delivered_qty"), "累计回厂");
        qty("1000", (BigDecimal) detected.get("floor_qty"), "成品短交门槛");
        drainOutbox("SUBCONTRACT_SHORT_DELIVERY_%");
        assertEquals(1, count("""
                SELECT COUNT(*) FROM notices
                WHERE source_event='SUBCONTRACT_SHORT_DELIVERY_DETECTED' AND audience_user_id=?
                """, w.superAdminUserId()), "订货单制单人必须收到短交待判定通知");

        // ② 判定前先锁住不入库 (ADR-098 §2.8): 质检合格也不放行。
        PassSlice firstPass = passIqc(first.receiptId(), "sc-comp-t2-pass-1");
        qty("800", firstPass.qty(), "第一批放行切片量");
        assertNotNull(shortDeliveries.stockInHoldReason(first.receiptId()), "待判定期间入库闸必须拦住, 现状为空");
        UUID keeper = ReflectionTestUtils.invokeMethod(fixture, "createIqcWarehouseConfirmer", w, "sc-comp-t2-keeper-" + overdue);
        fixture.loginAs(keeper);
        ApiException held = assertThrows(ApiException.class,
                () -> stockIn(keeper, first.receiptId(), firstPass, "sc-comp-t2-stock-in-1", w),
                "判定前这批货不能入库");
        assertEquals(ErrorCode.CONFLICT, held.getCode());
        assertTrue(held.getMessage().contains("先不入库"), held.getMessage());
        assertEquals(0, count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?", first.receiptId()),
                "被锁期间不得留下入库批次");
        fixture.loginAs(w.superAdminUserId());
        qty("0", onHand(w.goodsE(), w.warehouseId()), "判定前委外件库存必须仍为 0");

        // ③ 制单人判定「分批到货」(明天到齐) → 闸解除 → 先到的 800 入库; 案件仍在等, 订单未关。
        long version = ((Number) detected.get("version")).longValue();
        CaseDetail waiting = shortDeliveries.decide(caseId,
                new DecisionRequest("WAIT_MORE", BusinessTime.today().plusDays(1), "委外商答复明天补齐", version));
        assertEquals("WAITING_MORE", waiting.row().status(), "判定后案件现状 " + waiting.row().status() + " 期望 WAITING_MORE");
        assertNull(shortDeliveries.stockInHoldReason(first.receiptId()), "判定完成后入库闸必须放行, 现状仍挂闸");
        stockIn(keeper, first.receiptId(), firstPass, "sc-comp-t2-stock-in-1", w);
        fixture.loginAs(w.superAdminUserId());
        qty("800", onHand(w.goodsE(), w.warehouseId()), "第一批 800 入库后委外件库存");
        assertEquals("WAITING_MORE", db.queryForObject(
                "SELECT status FROM subcontract_short_delivery_cases WHERE id=?", String.class, caseId),
                "800 入库后累计仍低于下限, 案件必须仍在分批等待");
        assertFalse(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, ordered.orderId()),
                "累计 800 < 1000, 订货单不得关单");
        qty("1000", db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, ordered.itemId()),
                "分批等待期间订货量不动");
        // A new receipt starts after the prior warehouse confirmation's
        // durable valuation becomes available for the same goods and warehouse.
        ReflectionTestUtils.invokeMethod(fixture,"drainCosts",w);

        if (overdue) {
            db.update("UPDATE subcontract_short_delivery_cases SET expected_complete_by=CURRENT_DATE-1 WHERE id=?", caseId);
            assertNotNull(shortDeliveries.stockInHoldReason(first.receiptId()), "低于成品目标的逾期案件须重新判定");
            assertEquals(1, shortDeliveries.publishOverdueWaiting(BusinessTime.today()), "逾期仍须催货");
        }

        // ④ 第二批 150 使累计到 950，仍低于目标。实际批次与原分批决定分别保留。
        var secondUnacknowledged=assertThrows(ApiException.class,()->registerReturn(w,ordered.itemId(),"150","t2-150",false));
        assertEquals(ErrorCode.SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED,secondUnacknowledged.getCode());
        WarehouseArrivalRegisterResult second = registerReturn(w, ordered.itemId(), "150", "t2-150", true);
        assertEquals("SUBMITTED_FOR_INSPECTION", second.outcome());
        Map<String, Object> refreshed = caseRow(ordered.itemId());
        assertEquals(caseId, refreshed.get("id"), "不得另开案件");
        assertEquals("WAITING_MORE", refreshed.get("status"), "登记不结案, 案件现状 " + refreshed.get("status") + " 期望 WAITING_MORE");
        assertEquals("BELOW_FLOOR", refreshed.get("severity"));
        qty("950", (BigDecimal) refreshed.get("delivered_qty"), "累计回厂");
        qty("50",(BigDecimal)refreshed.get("shortfall_qty"),"真实短交未被预算抹掉");
        assertEquals(w.employeeId(), refreshed.get("owner_employee_id"));
        assertEquals(overdue,shortDeliveries.stockInHoldReason(second.receiptId())!=null);
        assertEquals(overdue,orders.detail(ordered.orderId()).getShortDeliveryHold()!=null);
        assertOrderTasks("PENDING", ordered.orderId(), overdue ? List.of(caseId) : List.of());
        assertOrderTasks("WAITING", ordered.orderId(), overdue ? List.of() : List.of(caseId));
        assertEquals(new Counts(overdue ? 1 : 0, 0, overdue ? 0 : 1), owningBadgeCounts());
        assertEquals(0, shortDeliveries.list("TOLERANT", null, null, ordered.orderId(), null, null, 1, 20).getTotal());
        assertEquals(overdue,shortDeliveries.detail(caseId).row().overdue());
        drainOutbox("SUBCONTRACT_SHORT_DELIVERY_%");
        assertEquals(overdue,count("SELECT COUNT(*) FROM notices WHERE aggregate_id=? AND resolved_at IS NULL",caseId)>0);

        // ⑤ 撤回第二批时入库闸重读净回厂。未逾期批次可以先入库，但不会自动认损。
        PassSlice secondPass = passIqc(second.receiptId(), "sc-comp-t2-pass-2");
        qty("150", secondPass.qty(), "第二批放行切片量");
        if (overdue) {
            subcontractReceipts.reverse(second.receiptId());
            String holdAfterReverse=shortDeliveries.stockInHoldReason(first.receiptId());
            assertNotNull(holdAfterReverse,"第二批撤回后累计回到 800，入库闸继续受控");
            assertTrue(holdAfterReverse.contains("累计到 800")&&holdAfterReverse.contains("少 200"),holdAfterReverse);
            ReflectionTestUtils.invokeMethod(fixture,"drainCosts",w);
            second=registerReturn(w,ordered.itemId(),"150","t2-150-replacement",true);
            secondPass=passIqc(second.receiptId(),"sc-comp-t2-pass-replacement");
            assertNotNull(shortDeliveries.stockInHoldReason(second.receiptId()),"累计仍为 950，逾期仍须负责人判定");
            acceptShortDelivery(caseRow(ordered.itemId()),"到货仍少 50 件，委外商确认加工报废");
            assertNull(shortDeliveries.stockInHoldReason(second.receiptId()));
            ReflectionTestUtils.invokeMethod(fixture,"drainCosts",w);
        }
        stockIn(keeper, second.receiptId(), secondPass, "sc-comp-t2-stock-in-2", w);
        fixture.loginAs(w.superAdminUserId());
        qty("950", onHand(w.goodsE(), w.warehouseId()), "两批入库后委外件库存现状 " + onHand(w.goodsE(), w.warehouseId()) + " 期望 950");
        if (!overdue) {
            Map<String,Object> waitingAfterStock=caseRow(ordered.itemId());
            assertEquals("WAITING_MORE",waitingAfterStock.get("status"));
            assertNull(waitingAfterStock.get("waste_id"));
            assertFalse(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?",Boolean.class,ordered.orderId()));
            ReflectionTestUtils.invokeMethod(fixture,"drainCosts",w);
            acceptShortDelivery(waitingAfterStock,"到货仍少 50 件，委外商确认加工报废");
        }
        Map<String, Object> settled = caseRow(ordered.itemId());
        assertEquals(caseId, settled.get("id"));
        assertEquals("ACCEPTED_LOSS", settled.get("status"),
                "案件按负责人明确认损结案");
        qty("50", (BigDecimal) settled.get("loss_qty"), "损耗量");
        qty("5", (BigDecimal) settled.get("loss_pct"), "损耗率");
        UUID wasteId = (UUID) settled.get("waste_id");
        assertNotNull(wasteId, "结案必须开损耗单, 现状 waste_id 为空");
        qty("50", db.queryForObject("SELECT SUM(qty) FROM subcontract_waste_items WHERE waste_id=?", BigDecimal.class, wasteId),
                "损耗单核销子件 50");
        qty("1000", db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, ordered.itemId()),
                "分批回厂按损耗结案仍保留原订货 1000");
        qty("950", db.queryForObject("SELECT received_qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, ordered.itemId()),
                "两批实际回厂仍为 950");
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, ordered.orderId()),
                "合格实收 950 加损耗 50 完成原订货 1000");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM procurement_order_approval_cases
                WHERE order_type='SUBCONTRACT' AND order_id=? AND status='PENDING'
                """, ordered.orderId()), "分批后正常损耗结案同样不另开财务改量复核");
        assertEquals(1, count("""
                SELECT COUNT(*) FROM procurement_order_approval_cases
                WHERE order_type='SUBCONTRACT' AND order_id=?
                """, ordered.orderId()), "保留首次订货批准");
        assertEquals(0,count("SELECT COUNT(*) FROM procurement_order_qty_change_logs WHERE order_item_id=?",ordered.itemId()));
        assertNull(settled.get("qty_change_log_id"));
        assertOrderTasks("PENDING", ordered.orderId(), List.of());
        assertOrderTasks("WAITING", ordered.orderId(), List.of());
        assertEquals(new Counts(0, 0, 0), owningBadgeCounts(), "结案后该负责人的徽章消失");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM subcontract_short_delivery_cases
                WHERE order_item_id=? AND status IN ('PENDING_OWNER','WAITING_MORE')
                """, ordered.itemId()), "不得残留开放案件");
    }

    @ParameterizedTest(name = "短交制单人无动作订阅不收卡, 仅查看={0}")
    @ValueSource(booleans = {false, true})
    void shortDeliveryDoesNotSubscribeAnImplicitSuperAdminOrReadOnlyOwner(boolean readOnly) {
        var w = fixture.seedWorld("sc-comp-unsubscribed-" + readOnly);
        if (readOnly) grant(db, w.superAdminUserId(), "notice:read", "subcontract_order:view");
        fixture.loginAs(w.superAdminUserId());
        bindDirectMaterialBom(w);
        receiveChildStock(w, "1000", w.warehouseId());
        Ordered ordered = orderApproveAndIssueAll(w, "1000");
        WarehouseArrivalRegisterResult arrived = registerReturn(w, ordered.itemId(), "800", "unsubscribed-800", true);
        assertEquals("SUBMITTED_FOR_INSPECTION", arrived.outcome());
        Map<String, Object> detected = caseRow(ordered.itemId());
        assertEquals("PENDING_OWNER", detected.get("status"));
        assertEquals("SEVERE", detected.get("severity"));
        qty("800", (BigDecimal) detected.get("delivered_qty"), "真实短交累计回厂");
        assertNotNull(shortDeliveries.stockInHoldReason(arrived.receiptId()), "未判定的入库闸仍生效");
        drainOutbox("SUBCONTRACT_SHORT_DELIVERY_%");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM notices WHERE source_event='SUBCONTRACT_SHORT_DELIVERY_DETECTED'
                  AND audience_user_id=?
                """, w.superAdminUserId()),
                "超级管理员隐式目录或仅查看权限都不能订阅短交判定卡");
        CaseDetail closed = shortDeliveries.decide((UUID) detected.get("id"),
                new DecisionRequest("ACCEPT_LOSS", null, "供方确认实际损耗，按真实业务结案",
                        ((Number) detected.get("version")).longValue()));
        assertEquals("ACCEPTED_LOSS", closed.row().status(), "反例也走真实结案，不污染共享待判定计数");
    }

    // ===================== T3 =====================

    @Test
    void shortDeliveryFactsCountMaterialAsFullyIssuedOnlyWhenTheLineIsSentOrItsDrawIsClosed() {
        var w = fixture.seedWorld("sc-partial-draw");
        fixture.loginAs(w.superAdminUserId());
        bindDirectMaterialBom(w);
        receiveChildStock(w, "1000", w.warehouseId());
        UUID orderId = orders.create(orderRequest(w, "1000")).getId();
        UUID orderItemId = db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?", UUID.class, orderId);

        // 执行生产代码的真实 PostgreSQL facts 查询。CTE 仅提供不同发出阶段的冻结计划行
        // (ADR-143 §二.13: 「发完」= 每一种直属物料的已发净量 = 计划量, 或该物料已结束领料)。
        assertFalse(materialFullyIssuedInFacts(orderItemId, "1000", "800", false),
                "已发 800, 计划仍有 200 未发, 不能判短交或提前接受损耗");
        assertFalse(materialFullyIssuedInFacts(orderItemId, "1000", "0", false),
                "一件都没发不能算全部发完");
        assertTrue(materialFullyIssuedInFacts(orderItemId, "1000", "1000", false));
        assertTrue(materialFullyIssuedInFacts(orderItemId, "1000", "800", true),
                "结束领料(不再发外)后仍允许按最终回厂量判定损耗 (ADR-143 §二.15)");
    }

    @Test
    void oneHundredIssuedAndNinetyFiveReturnedClosesOnceAfterExplicitLossWithoutConsumingCompanyStock() {
        var w = fixture.seedWorld("sc-comp-exact-floor");
        fixture.loginAs(w.superAdminUserId());
        bindDirectMaterialBom(w);
        receiveChildStock(w, "1000", w.warehouseId());
        Ordered ordered = orderApproveAndIssueAll(w, "100", "5");
        qty("900", onHand(w.goodsD(), w.warehouseId()), "只发 100 个子件, 其余 900 个仍在公司仓");
        qty("0", onHand(w.goodsE(), w.warehouseId()), "外发前不用持有加工后的委外件");

        var unacknowledged=assertThrows(ApiException.class,()->registerReturn(w,ordered.itemId(),"95","exact-floor",false));
        assertEquals(ErrorCode.SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED,unacknowledged.getCode());
        var receipt = registerReturn(w, ordered.itemId(), "95", "exact-floor", true);
        PassSlice pass = passIqc(receipt.receiptId(), "sc-exact-floor-pass");
        UUID keeper = ReflectionTestUtils.invokeMethod(fixture, "createIqcWarehouseConfirmer", w, "sc-exact-floor-keeper");
        Map<String,Object> pending=caseRow(ordered.itemId());
        qty("100",(BigDecimal)pending.get("floor_qty"),"5% 供料预算不减少成品目标");
        qty("95",(BigDecimal)pending.get("delivered_qty"),"实际到货 95 不变");
        assertNotNull(shortDeliveries.stockInHoldReason(receipt.receiptId()));
        fixture.loginAs(w.superAdminUserId());
        var accepted=acceptShortDelivery(pending,"委外商确认实际报废 5 件");
        stockIn(keeper, receipt.receiptId(), pass, "sc-exact-floor-stock", w);
        var replay = iqcStockIn.confirm("SUBCONTRACT", receipt.receiptId(), new ConfirmRequest("sc-exact-floor-stock",
                List.of(new ConfirmItem(pass.passEventId(), pass.qty(), pass.qty(), "SC-COMP-01", w.warehouseId()))));
        assertTrue(replay.replayed(), "相同入库命令重放不得重复库存或损耗履约事实");

        fixture.loginAs(w.superAdminUserId());
        qty("95", onHand(w.goodsE(), w.warehouseId()), "合格入库的是加工后的委外件");
        qty("900", onHand(w.goodsD(), w.warehouseId()), "损耗只核销供应商处材料, 不再扣公司子件库存");
        Map<String, Object> settled = caseRow(ordered.itemId());
        assertEquals("ACCEPTED_LOSS", settled.get("status"));
        assertEquals(accepted.row().wasteId(),settled.get("waste_id"),"入库重放不能追加另一笔认损事实");
        qty("5", (BigDecimal) settled.get("loss_qty"), "负责人确认的实际损耗");
        qty("5", (BigDecimal) settled.get("loss_pct"), "损耗率");
        qty("5", db.queryForObject("SELECT SUM(qty) FROM subcontract_waste_items WHERE waste_id=?",
                BigDecimal.class, settled.get("waste_id")), "供应商处子件核销 5");
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, ordered.orderId()));
        qty("100",db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?",BigDecimal.class,ordered.itemId()),"原订货保留 100");
        qty("95",db.queryForObject("SELECT received_qty FROM subcontract_order_items WHERE id=?",BigDecimal.class,ordered.itemId()),"实际回厂保留 95");
        assertEquals(0, count("SELECT COUNT(*) FROM procurement_order_qty_change_logs WHERE order_item_id=?", ordered.itemId()));
        assertEquals(0,count("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_type='SUBCONTRACT' AND order_id=? AND status='PENDING'",ordered.orderId()));
        assertEquals(1, count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?", receipt.receiptId()));
    }

    @Test
    void overReturnOf1050AgainstIssued1000GoesToFinanceAsSupplierOwnMaterialAndStocksInAfterApproval() {
        var w = fixture.seedWorld("sc-comp-return-excess");
        fixture.loginAs(w.superAdminUserId());
        bindDirectMaterialBom(w);
        receiveChildStock(w, "1000", w.warehouseId());
        Ordered ordered = orderApproveAndIssueAll(w, "1000");
        String orderNo = db.queryForObject("SELECT bill_no FROM subcontract_orders WHERE id=?", String.class, ordered.orderId());

        // ① 回厂 1050 > 我方供料 1000: 登记不拒收, 审核落 PENDING_FINANCE 到货异常 (货不入库、不立应付)。
        WarehouseArrivalRegisterResult receipt = registerReturn(w, ordered.itemId(), "1050", "t3-1050", false);
        assertEquals("EXCESS_QUARANTINED", receipt.outcome(), "超收 outcome 现状 " + receipt.outcome() + " 期望 EXCESS_QUARANTINED");
        assertNotNull(receipt.exceptionId(), "超收必须留下到货异常 id");
        assertEquals("PENDING_FINANCE", db.queryForObject(
                "SELECT status FROM procurement_arrival_exceptions WHERE id=?", String.class, receipt.exceptionId()));
        qty("50", db.queryForObject(
                "SELECT declared_qty - approved_remaining_qty FROM procurement_arrival_exceptions WHERE id=?",
                BigDecimal.class, receipt.exceptionId()), "超出我方供料的量 = 1050 - 1000");
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_receipts WHERE id=? AND status=1", receipt.receiptId()),
                "财务定案前收货单不得审核");
        qty("0", onHand(w.goodsE(), w.warehouseId()), "财务定案前委外件一件都不许入库");
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_short_delivery_cases WHERE order_item_id=?", ordered.itemId()),
                "超收不是短交, 不得开短交案件");

        // ② 通知财务: 标题「到货超量」, 正文点明多出来的是委外商自带料 (ADR-103 §2.6)。
        drainOutbox("PROCUREMENT_ARRIVAL_%");
        List<String> financeNotices = db.queryForList("""
                SELECT title || '|' || content FROM notices
                WHERE title LIKE '到货超量%' AND title LIKE ? ORDER BY created_at
                """, String.class, "%" + orderNo + "%");
        assertFalse(financeNotices.isEmpty(), "财务必须收到「到货超量」通知, 现状一条都没有");
        assertTrue(financeNotices.stream().anyMatch(text -> text.contains("自带料")),
                "到货超量正文必须点明「委外商自带料」, 现状=" + financeNotices);

        // ③ 财务账号批准全部超量 (多出的 50 是委外商自带料)。
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        fixture.loginAs(reviewer);
        var pending = arrivalControl.financeDetail(receipt.exceptionId());
        var decided = arrivalControl.financeDecide(receipt.exceptionId(),
                new ArrivalDecisionRequest(pending.version(), "APPROVE_ALL", null, "委外商自带料 50 件, 按约定计价接收"));
        qty("50", decided.approvedExcessQty(), "财务批准的自带料量");
        assertEquals("RECEIPT_ADJUSTED", db.queryForObject(
                "SELECT status FROM procurement_arrival_exceptions WHERE id=?", String.class, receipt.exceptionId()),
                "APPROVE_ALL 后异常状态");
        qty("1050", db.queryForObject(
                "SELECT SUM(qty) FROM subcontract_receipt_items WHERE receipt_id=? AND COALESCE(is_deleted,FALSE)=FALSE",
                BigDecimal.class, receipt.receiptId()), "批准全部后收货草稿行仍是 1050");

        // ④ 仓库一键入库 (到货异常任务中心的入库路径): 收货单审核必须走得通 —— 回厂消费我方子件只消费 1000,
        //    多出的 50 按委外商自带料入库, 不能在「消费我方发出的子件」这一步 409 整笔回滚 (ADR-103 §2.5 / §三.6)。
        fixture.loginAs(w.superAdminUserId());
        arrivalControl.stockInWithDecisionSession(receipt.exceptionId(),
                target -> subcontractReceipts.approveFromWarehouseDecision(target.receiptId()));
        assertEquals(1, count("SELECT COUNT(*) FROM subcontract_receipts WHERE id=? AND status=1", receipt.receiptId()),
                "财务批准后收货单必须审核通过, 现状仍未审核");
        assertFalse(List.of("PENDING_FINANCE", "RETURN_REQUIRED").contains(db.queryForObject(
                "SELECT status FROM procurement_arrival_exceptions WHERE id=?", String.class, receipt.exceptionId())),
                "一键入库后异常不得退回待财务/待退回");
        qty("1000", db.queryForObject(
                "SELECT COALESCE(SUM(consumed_qty),0) FROM subcontract_material_issue_items WHERE order_item_id=? AND is_deleted=FALSE",
                BigDecimal.class, ordered.itemId()), "回厂只消费我方发出的 1000 个子件, 现状消费量不对 (多出的 50 是自带料)");
        qty("0", db.queryForObject("""
                SELECT COALESCE(SUM(COALESCE(at_supplier_qty,0) - COALESCE(consumed_qty,0)
                                    - COALESCE(returned_qty,0) - COALESCE(wasted_qty,0)),0)
                FROM subcontract_material_issue_items WHERE order_item_id=? AND is_deleted=FALSE
                """, BigDecimal.class, ordered.itemId()), "子件在供应商处余量必须为 0");

        // ⑤ 来料质检合格 → 仓库账号确认入库 1050 → 委外件库存 1050、关单、无短交案件。
        PassSlice pass = passIqc(receipt.receiptId(), "sc-comp-t3-pass");
        qty("1050", pass.qty(), "放行切片量");
        UUID keeper = ReflectionTestUtils.invokeMethod(fixture, "createIqcWarehouseConfirmer", w, "sc-comp-t3-keeper");
        stockIn(keeper, receipt.receiptId(), pass, "sc-comp-t3-stock-in", w);
        fixture.loginAs(w.superAdminUserId());
        qty("1050", onHand(w.goodsE(), w.warehouseId()), "委外件库存现状 " + onHand(w.goodsE(), w.warehouseId()) + " 期望 1050");
        qty("0", onHand(w.goodsD(), w.warehouseId()), "子件库存");
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, ordered.orderId()),
                "实收 1050 >= 订货 1000, 订货单现状未关, 期望关单");
        qty("1000", db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, ordered.itemId()),
                "超收不改订货量");
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_short_delivery_cases WHERE order_item_id=?", ordered.itemId()),
                "超收全程不得开短交案件");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM procurement_order_approval_cases
                WHERE order_type='SUBCONTRACT' AND order_id=? AND status='PENDING'
                """, ordered.orderId()), "超收入库不开财务复核 case");
    }

    // ===================== T4 =====================

    @Test
    void materialOnlyInADefectiveWarehouseIsNotDrawableUntilReleasedBackByQualityRecheck() {
        var w = fixture.seedWorld("sc-comp-return-transfer");
        fixture.loginAs(w.superAdminUserId());
        bindDirectMaterialBom(w);
        // 不良品仓是记账叶仓, 但不计入可用量 (ADR-143 §三.5 作业叶仓口径 / ADR-146)。
        UUID defectiveWarehouseId = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id, code, name, status, is_defective) VALUES (?, ?, ?, '使用', TRUE)",
                defectiveWarehouseId, "WH-DEF-sc-comp-transfer", "不良品仓-sc-comp-transfer");
        // ADR-146: 正常到货不能直接入不良品仓。
        ApiException refused = assertThrows(ApiException.class,
                () -> receiveChildStock(w, "1000", defectiveWarehouseId));
        assertTrue(refused.getMessage().contains("是不良品仓"), refused.getMessage());
        // 判为不良的物料只能经「转不良品仓」从良品仓转进来。
        receiveChildStock(w, "1000", w.warehouseId());
        defectiveMove(w, "TO_DEFECTIVE", w.warehouseId(), defectiveWarehouseId, "1000", "物料来料划伤, 判不良");
        qty("1000", onHand(w.goodsD(), defectiveWarehouseId), "物料必须真的进了不良品仓");
        qty("0", onHand(w.goodsD(), w.warehouseId()), "良品仓已转空");

        // ① ADR-156: 下单到批准时直属物料要齐(不良品仓里的不算); 在暂存仓补齐、批准后清掉,
        // 即「下单时物料是齐的, 之后被判不良转走了」。批准冻结一条计划行。
        var kitStage = fixture.stageSubcontractKit(w, Map.of(w.goodsE(), "1000"));
        UUID orderId = orders.create(orderRequest(w, "1000")).getId();
        fixture.stageSubcontractKitUntilApproval(orderId, kitStage);
        UUID itemId = db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?", UUID.class, orderId);
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("SUBCONTRACT", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId); fixture.seedHistoricalSubcontractLossPlanBeforeExecution(orderId);
        fixture.loginAs(w.superAdminUserId());
        assertEquals(1, count("SELECT COUNT(*) FROM subcontract_material_plan_items WHERE order_item_id=? AND is_deleted=FALSE",
                itemId), "批准后按唯一直属边冻结一条计划行");

        // ② 物料只在不良品仓 → 仓库可用 0, 可领 0。
        DrawTaskRow before = drawRow(orderId);
        qty("0", before.drawableQty(), "不良品仓里的物料不算可领");
        assertFalse(before.canDraw(), "没有可领就不能勾选领料");
        qty("0", drawQueries.materials(itemId).materials().getFirst().availableQty(), "物料仓库可用只看计入可用量的仓");

        // ③ 普通调拨不能把不良品搬回良品仓 (两端必须同类)。
        ApiException mixed = assertThrows(ApiException.class,
                () -> transferChildStock(w, defectiveWarehouseId, w.warehouseId(), "1000"));
        assertTrue(mixed.getMessage().contains("普通调拨的调出仓和调入仓必须同是良品仓或同是不良品仓"),
                mixed.getMessage());

        // ④ 品质复判合格 →「不良复判转回」→ 整单可领 1000。
        defectiveMove(w, "DEFECT_RELEASE", defectiveWarehouseId, w.warehouseId(), "1000", "复判合格, 转回良品仓");
        qty("1000", onHand(w.goodsD(), w.warehouseId()), "复判转回后良品仓物料量");
        qty("0", onHand(w.goodsD(), defectiveWarehouseId), "复判转回后不良品仓物料量");
        DrawTaskRow after = drawRow(orderId);
        qty("1000", after.drawableQty(), "物料复判转回良品仓后可领");
        assertEquals("DRAWABLE", after.status());
    }

    /** ADR-146 不良品专门通道: 一次建单并过账。 */
    private void defectiveMove(FullChainEndToEndTest.World w, String kind, UUID from, UUID to, String qty,
                               String reason) {
        stockDocs.createDefectiveMove(new com.uten.imp.features.stock.dto.StockDefectiveMoveRequest(
                kind, from, to, reason, BusinessTime.today(), "sc-comp-" + kind + "-" + UUID.randomUUID(),
                List.of(childLine(w, qty))));
    }

    // ===================== 夹具 =====================

    private boolean materialFullyIssuedInFacts(UUID orderItemId, String planned, String issued, boolean drawClosed) {
        String facts = (String) ReflectionTestUtils.getField(SubcontractShortDeliveryService.class, "FACT_SQL");
        assertNotNull(facts);
        String stages = """
                WITH subcontract_material_plan_items AS (
                    SELECT ?::uuid AS order_item_id,
                           '00000000-0000-0000-0000-000000000001'::uuid AS plan_id,
                           FALSE AS is_deleted, ?::numeric AS planned_qty, ?::numeric AS issued_qty,
                           -- 单耗 1: 没有委外商自带料时我方需发量 LEAST(计划量, f(Qm)) = 计划量(ADR-143 §三.4a)
                           1::numeric AS bom_unit_qty, 0::numeric AS material_loss_pct,
                           CASE WHEN ?::boolean THEN now() END AS draw_closed_at
                ), subcontract_material_plans AS (
                    SELECT '00000000-0000-0000-0000-000000000001'::uuid AS id,
                           'OPEN'::text AS status, FALSE AS is_deleted
                )
                """;
        return db.queryForObject(stages + facts.formatted("95::numeric", "?"),
                (rs, row) -> rs.getBoolean("material_fully_issued"),
                orderItemId, new BigDecimal(planned), new BigDecimal(issued), drawClosed, orderItemId);
    }

    /** 本订货单在「领料」里的行(按订货单筛选)。 */
    private DrawTaskRow drawRow(UUID orderId) {
        List<DrawTaskRow> rows = drawQueries.tasks(1, 50, "", "", orderId, null).page().getItems();
        assertEquals(1, rows.size(), "一张单一条明细, 现状 " + rows);
        return rows.getFirst();
    }

    private record Ordered(UUID orderId, UUID itemId, UUID planItemId) {}

    private record PassSlice(UUID passEventId, BigDecimal qty) {}

    /** 委外件 goodsE 挂唯一一条 PER_UNIT 直属边到采购件 goodsD (1:1), 是 fn_subcontract_draw_edges 唯一的可发外边。 */
    private void bindDirectMaterialBom(FullChainEndToEndTest.World w) {
        db.update("""
                INSERT INTO goods_bom_items(id, goods_id, component_goods_id, qty, sort_order,
                    control_stage, consumption_basis, basis_output_qty, allow_partial_package, hard_gate)
                VALUES (?, ?, ?, 1, 1, 'START', 'PER_UNIT', 1, TRUE, TRUE)
                """, UUID.randomUUID(), w.goodsE(), w.goodsD());
        assertEquals(List.of(w.goodsD()), db.queryForList(
                "SELECT component_goods_id FROM fn_subcontract_draw_edges(?)", UUID.class, w.goodsE()),
                "夹具必须只有一条可发外直属边");
    }

    /** 建单 (允许损耗 10%) → 送审 → 财务批准 → 委外人员领满订货量 → 仓库审核发出。 */
    private Ordered orderApproveAndIssueAll(FullChainEndToEndTest.World w, String qty) {
        return orderApproveAndIssueAll(w, qty, "10");
    }

    private Ordered orderApproveAndIssueAll(FullChainEndToEndTest.World w, String qty, String allowedLossPct) {
        var request = orderRequest(w, qty);
        request.getItems().getFirst().setAllowedLossPct(new BigDecimal(allowedLossPct));
        UUID orderId = orders.create(request).getId();
        UUID itemId = db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?", UUID.class, orderId);
        qty(allowedLossPct, db.queryForObject("SELECT allowed_loss_pct FROM subcontract_order_items WHERE id=?", BigDecimal.class, itemId),
                "允许损耗必须冻结在订货行");
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("SUBCONTRACT", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId); fixture.seedHistoricalSubcontractLossPlanBeforeExecution(orderId);
        fixture.loginAs(w.superAdminUserId());
        UUID planItemId = db.queryForObject("""
                SELECT id FROM subcontract_material_plan_items WHERE order_item_id=? AND is_deleted=FALSE
                """, UUID.class, itemId);
        assertEquals(w.goodsD(), db.queryForObject(
                "SELECT goods_id FROM subcontract_material_plan_items WHERE id=?", UUID.class, planItemId),
                "发出去的必须是直属物料 goodsD");
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_material_issue_items WHERE order_item_id=?", itemId),
                "财务批准不再自动建出仓草稿 (ADR-143 §五)");
        List<UUID> drafts = fixture.submitSubcontractDraw(itemId, new BigDecimal(qty), "sc-comp-draw-" + itemId);
        assertEquals(1, drafts.size(), "物料都在一个仓, 一张领料草稿");
        UUID issueId = drafts.getFirst();
        qty(qty, db.queryForObject(
                "SELECT COALESCE(SUM(qty),0) FROM subcontract_material_issue_items WHERE issue_id=?", BigDecimal.class, issueId),
                "物料现货足额时领满即开整笔草稿");
        materialIssues.approve(issueId);
        qty(qty, db.queryForObject(
                "SELECT issued_qty FROM subcontract_material_plan_items WHERE id=?", BigDecimal.class, planItemId),
                "料必须全部发出");
        return new Ordered(orderId, itemId, planItemId);
    }

    private OrderSaveRequest orderRequest(FullChainEndToEndTest.World w, String qty) {
        var request = new OrderSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setDeliverDate(BusinessTime.today().plusDays(3));
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId"));
        var line = new OrderItemLine();
        line.setGoodsId(w.goodsE());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("10"));
        line.setAllowedLossPct(new BigDecimal("10"));
        request.setItems(List.of(line));
        return request;
    }

    /** 物料按采购件到货 (其它入库审核), 入库方向由 StockService 内核追加领料重算, 不手工 wake。 */
    private void receiveChildStock(FullChainEndToEndTest.World w, String qty, UUID warehouseId) {
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setBillDate(LocalDate.of(2026, 1, 1));
        request.setWarehouseId(warehouseId);
        request.setRemark("委外子件到货 " + qty);
        request.setItems(List.of(childLine(w, qty)));
        var doc = stockDocs.create(request);
        stockDocs.approve(doc.getId());
    }

    /** 子件从一个仓调到另一个仓 (调拨单审核: 出仓方向 + 入仓方向)。 */
    private void transferChildStock(FullChainEndToEndTest.World w, UUID fromWarehouseId, UUID toWarehouseId, String qty) {
        var request = new StockDocSaveRequest();
        request.setDocType("TRANSFER");
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(fromWarehouseId);
        request.setToWarehouseId(toWarehouseId);
        request.setRemark("委外子件调进作业叶仓 " + qty);
        request.setItems(List.of(childLine(w, qty)));
        var doc = stockDocs.create(request);
        stockDocs.approve(doc.getId());
    }

    private StockDocItemLine childLine(FullChainEndToEndTest.World w, String qty) {
        var line = new StockDocItemLine();
        line.setGoodsId(w.goodsD());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("10"));
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));
        line.setAmountLocal(line.getAmountOriginal());
        return line;
    }

    /** 回厂登记的是委外件 goodsE (发出去的是子件, 回来的是委外件)。 */
    private WarehouseArrivalRegisterResult registerReturn(
            FullChainEndToEndTest.World w, UUID itemId, String qty, String key, boolean shortDeliveryAcknowledged) {
        return arrivals.register(new WarehouseArrivalRegisterRequest(
                "sc-comp-return-" + key + "-" + itemId, "SUBCONTRACT", BusinessTime.today(),
                w.supplierId(), w.warehouseId(), null, w.employeeId(), null,
                List.of(new ArrivalLine(w.goodsE(), new BigDecimal(qty), itemId, null,
                        w.unitId(), BigDecimal.ONE, null, null)),
                null, shortDeliveryAcknowledged ? Boolean.TRUE : null));
    }

    /** 来料质检合格 (委外跟单员做), 返回可入库的放行切片。 */
    private PassSlice passIqc(UUID receiptId, String key) {
        UUID inspectionItemId = db.queryForObject("""
                SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?
                """, UUID.class, receiptId);
        inspections.dispose("SUBCONTRACT", receiptId, inspectionItemId,
                new InspectionDispositionRequest("PASS", null, "回厂件检查合格", key));
        UUID passEventId = db.queryForObject("""
                SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'
                """, UUID.class, inspectionItemId);
        BigDecimal passedQty = db.queryForObject(
                "SELECT base_qty FROM procurement_inspection_events WHERE id=?", BigDecimal.class, passEventId);
        return new PassSlice(passEventId, passedQty);
    }

    /** 切到仓库账号确认入库; 调用后当前登录仍是仓库账号, 调用方按需切回。 */
    private void stockIn(UUID keeper, UUID receiptId, PassSlice pass, String key, FullChainEndToEndTest.World w) {
        fixture.loginAs(keeper);
        iqcStockIn.confirm("SUBCONTRACT", receiptId, new ConfirmRequest(key,
                List.of(new ConfirmItem(pass.passEventId(), pass.qty(), pass.qty(), "SC-COMP-01", w.warehouseId()))));
    }

    private Map<String, Object> caseRow(UUID itemId) {
        return db.queryForMap("""
                SELECT * FROM subcontract_short_delivery_cases
                WHERE order_item_id=? ORDER BY detected_at DESC LIMIT 1
                """, itemId);
    }

    private void assertOrderTasks(String segment, UUID orderId, List<UUID> caseIds) {
        var page = shortDeliveries.list(segment, null, null, orderId, null, null, 1, 20);
        assertEquals(caseIds.size(), page.getTotal());
        assertEquals(caseIds, page.getItems().stream().map(CaseRow::id).toList());
    }

    private Counts owningBadgeCounts() {
        var context = SecurityContextHolder.getContext();
        var original = context.getAuthentication();
        var administrator = (AuthUser) original.getPrincipal();
        // Shared fixtures can leave valid open work for other owners. Read the
        // actual badge with this employee's decision permissions and own scope.
        var owner = new AuthUser(administrator.getId(), administrator.getEmployeeId(), administrator.getLoginAccount(),
                Set.of(SubcontractShortDeliveryService.VIEW_AUTHORITY, SubcontractShortDeliveryService.DECIDE_AUTHORITY),
                administrator.isMustChangePassword(), administrator.isAccountNonLocked(), false);
        context.setAuthentication(new UsernamePasswordAuthenticationToken(owner, null, owner.getAuthorities()));
        try {
            return shortDeliveries.counts();
        } finally {
            context.setAuthentication(original);
        }
    }

    private CaseDetail acceptShortDelivery(Map<String,Object> currentCase,String note) {
        var accepted=shortDeliveries.decide((UUID)currentCase.get("id"),new DecisionRequest(
                "ACCEPT_LOSS",null,note,((Number)currentCase.get("version")).longValue()));
        assertEquals("ACCEPTED_LOSS",accepted.row().status());
        return accepted;
    }

    private BigDecimal onHand(UUID goodsId, UUID warehouseId) {
        BigDecimal balance = db.queryForObject("""
                SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?
                """, BigDecimal.class, goodsId, warehouseId);
        return balance == null ? BigDecimal.ZERO : balance;
    }

    /**
     * 把指定前缀的 outbox 事件投递干净 (复制自 SubcontractShortDeliveryEndToEndTest.drainOutbox):
     * 每轮先抹平退避再投递, 本线程投递时抛出的瞬时冲突不记 attempts, 下一轮直接重投。
     */
    private void drainOutbox(String eventTypePattern) {
        String pending = "SELECT COUNT(*) FROM business_outbox WHERE status<>1 AND event_type LIKE ?";
        long deadline = System.currentTimeMillis() + 60_000;
        while (true) {
            db.update("UPDATE business_outbox SET available_at=now() WHERE status=0 AND available_at>now()");
            try {
                for (int i = 0; i < 200 && outbox.processNext(); i++) { /* 投到取不出为止 */ }
            } catch (RuntimeException transientDeliveryFailure) {
                // 瞬时冲突: 本线程没走失败记录器, attempts 未加, 下一轮抹平退避后重投。
            }
            if (count(pending, eventTypePattern) == 0) return;
            if (System.currentTimeMillis() > deadline) break;
            try {
                Thread.sleep(50);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        assertFalse(count(pending, eventTypePattern) > 0, "事件 " + eventTypePattern + " 必须全部投递完成");
    }

    private int count(String sql, Object... args) {
        Integer n = db.queryForObject(sql, Integer.class, args);
        return n == null ? 0 : n;
    }

    private static void qty(String expected, BigDecimal actual, String what) {
        assertNotNull(actual, what + ": 现状 null, 期望 " + expected);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), what + ": 现状 " + actual + " 期望 " + expected);
    }
}
