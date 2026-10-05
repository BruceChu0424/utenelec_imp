package com.uten.imp.businesschain;

import com.uten.imp.application.port.ProcurementArrivalBlockedException;
import com.uten.imp.common.columns.BusinessColumnService;
import com.uten.imp.common.columns.ExtraColumnInput;
import com.uten.imp.common.finance.ProcurementOrderQuantityBounds;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine;
import com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.request.dto.RequestItemLine;
import com.uten.imp.features.purchase.request.dto.RequestSaveRequest;
import com.uten.imp.features.purchase.ret.PurchaseReturnService;
import com.uten.imp.features.purchase.ret.dto.ReturnItemLine;
import com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawItemRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSubmitRequest;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
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
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.sql.SQLException;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-144 §五 采购允许超收比例真库验收。每个用例自己的世界(供应商独立, 应付按供应商合计互不干扰),
 * 订货 100、单价 20、允许超收 5%(最多可收 105)。
 *
 * <ul>
 *   <li>一次到 103: 直接送检入库、立应付 2060, 不打扰财务;</li>
 *   <li>分两批 60 + 45: 第二批用掉剩余容差照常入库; 再多 1 件转财务, 隔离快照写全订货量/比例/容差/此前已收;</li>
 *   <li>一次到 110: 整单隔离; 财务「拒收超量」收窄到 105 入库并生成退 5 的供应商退回任务;
 *       财务「全部接收」110 入库, 只有财务批准的 5 记进已过账超量;</li>
 *   <li>收满 100(预计到货关闭)后, 采购员手工收货 3 直接入库; 再收 3 超出转财务;</li>
 *   <li>扩展列(模具费)明细收满 100, 应付 = 订单金额分毫不差; 容差部分按单价另计;</li>
 *   <li>收 100、质检退 10 并实退, 自动来源登记 10 按质检补回入库(免费), 容差最后才用;</li>
 *   <li>退货红冲守卫放行比例内的收货; 改量下限按比例算; 已批准订单改比例被数据库触发器拒绝;</li>
 *   <li>保存订单回写货品记忆(空行不清空), {@code /last-terms} 预填带来源 GOODS_MASTER;</li>
 *   <li>委外回厂不受采购比例影响(委外件主档有记忆值也一样)。</li>
 * </ul>
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
class PurchaseOverReceiptToleranceEndToEndTest {

    private static final String PRICE = "20";

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired EntityManager em;
    @Autowired PlatformTransactionManager transactions;
    @Autowired PurchaseRequestService purchaseRequests;
    @Autowired PurchaseOrderService purchaseOrders;
    @Autowired PurchaseReceiptService purchaseReceipts;
    @Autowired PurchaseReturnService purchaseReturns;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired ProcurementArrivalControlService arrivalControl;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcStockInService iqcStockIn;
    @Autowired ProcurementIqcRejectionService iqcRejections;
    @Autowired BusinessColumnService businessColumns;
    @Autowired BusinessOutboxProcessor outbox;
    @Autowired StockDocService stockDocs;
    @Autowired SubcontractOrderService subcontractOrders;
    @Autowired SubcontractDrawCommandService drawCommands;
    @Autowired SubcontractMaterialIssueService materialIssues;

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
    // 比例内: 一次 103 / 分两批 60 + 45
    // =====================================================================================

    @Test
    void oneArrivalOfOneHundredThreeIsWithinFivePercentAndStocksAndPostsPayableWithoutFinance() {
        String tag = "por-103";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID b = goods(w, tag, "B", "采购");
        Purchase po = approvedPurchase(w, b, "100", "5", null, tag);
        qty("5", db.queryForObject("SELECT allowed_over_receipt_pct FROM purchase_order_items WHERE id=?",
                BigDecimal.class, po.orderItemId()), "允许超收% 冻结在订货明细上");

        UUID receiptId = registerPurchase(w, b, po.orderItemId(), "103", tag + "-a1");
        assertEquals(0, exceptionCount(po.orderItemId()), "比例内不进到货异常, 不通知财务");
        assertAp(w, "2060");
        assertFalse(db.queryForObject("SELECT is_closed FROM purchase_orders WHERE id=?", Boolean.class, po.orderId()),
                "结案按合格入库量: 第一张收货单还在质检, 不按登记量关单");
        stockIn("PURCHASE", receiptId, passIqc("PURCHASE", receiptId, tag + "-a1"), tag + "-a1", w.warehouseId());
        assertTrue(db.queryForObject("SELECT is_closed FROM purchase_orders WHERE id=?", Boolean.class, po.orderId()),
                "合格入库 103 ≥ 订货量 100, 订货单关单");
        qty("103", onHand(b, w.warehouseId()), "103 全部入库");
        qty("103", db.queryForObject("SELECT received_qty FROM purchase_order_items WHERE id=?", BigDecimal.class,
                po.orderItemId()), "已收 103");
        qty("0", db.queryForObject("SELECT COALESCE(arrival_overage_posted_qty, 0) FROM purchase_order_items WHERE id=?",
                BigDecimal.class, po.orderItemId()), "容差永远不写进已过账超量");
        assertEquals("CLOSED", expectationStatus(po.orderId()), "累计收满订货量即关闭预计到货");
    }

    @Test
    void twoBatchesSixtyAndFortyFiveUseTheRemainingToleranceAndOneMoreGoesToFinanceWithSnapshots() {
        String tag = "por-60-45";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID b = goods(w, tag, "B", "采购");
        Purchase po = approvedPurchase(w, b, "100", "5", null, tag);

        UUID first = registerPurchase(w, b, po.orderItemId(), "60", tag + "-a1");
        stockIn("PURCHASE", first, passIqc("PURCHASE", first, tag + "-a1"), tag + "-a1", w.warehouseId());
        assertEquals("OPEN", expectationStatus(po.orderId()), "收 60 还欠 40");
        UUID second = registerPurchase(w, b, po.orderItemId(), "45", tag + "-a2");
        stockIn("PURCHASE", second, passIqc("PURCHASE", second, tag + "-a2"), tag + "-a2", w.warehouseId());
        assertEquals(0, exceptionCount(po.orderItemId()), "按累计净收货计: 60 + 45 = 105 ≤ 最多可收 105");
        qty("105", onHand(b, w.warehouseId()), "两批全部入库");
        assertAp(w, "2100");
        assertEquals("CLOSED", expectationStatus(po.orderId()));

        // 再多 1 件(手工收货): 超过最多可收, 整张转财务, 快照写全订 Q / 允许 p% / 容差 T / 此前已收 R。
        assertThrows(ProcurementArrivalBlockedException.class,
                () -> manualReceipt(w, b, po.orderItemId(), "1", null));
        Map<String, Object> exception = theOnlyException(po.orderItemId());
        assertEquals("PENDING_FINANCE", exception.get("status"));
        qty("1", exception.get("declared_qty"), "本次实到");
        qty("0", exception.get("approved_remaining_qty"), "容差已用完");
        qty("100", exception.get("order_qty_snapshot"), "订货量快照");
        qty("5", exception.get("allowed_over_receipt_pct_snapshot"), "允许超收%快照");
        qty("5", exception.get("tolerance_qty_snapshot"), "允许超收量快照 = ROUND(100 × 5%, 4)");
        qty("105", exception.get("prior_net_received_qty_snapshot"), "此前已收净量快照");
        assertAp(w, "2100");
    }

    // =====================================================================================
    // 超过最多可收: 财务拒收超量收窄到 105 并退 5 / 全部接收 110
    // =====================================================================================

    @Test
    void arrivalBeyondMaxReceivableIsQuarantinedAndRejectExcessNarrowsToMaxReceivableWithAReturnTask() {
        String tag = "por-110-reject";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID b = goods(w, tag, "B", "采购");
        Purchase po = approvedPurchase(w, b, "100", "5", null, tag);

        WarehouseArrivalRegisterResult over = arrivals.register(purchaseArrival(w, b, po.orderItemId(), "110", tag));
        assertEquals("EXCESS_QUARANTINED", over.outcome(), "超过最多可收 105 → 整单隔离");
        assertNotNull(over.exceptionId());
        Map<String, Object> exception = theOnlyException(po.orderItemId());
        assertEquals("PENDING_FINANCE", exception.get("status"));
        qty("110", exception.get("declared_qty"), "实到");
        qty("105", exception.get("approved_remaining_qty"), "最多可收 = 订货 100 + 允许超收 5");
        qty("100", exception.get("order_qty_snapshot"), "订货量快照");
        qty("5", exception.get("allowed_over_receipt_pct_snapshot"), "允许超收%快照");
        qty("5", exception.get("tolerance_qty_snapshot"), "允许超收量快照");
        qty("0", exception.get("prior_net_received_qty_snapshot"), "此前已收 0");
        assertAp(w, "0");
        qty("0", onHand(b, w.warehouseId()), "隔离不入库");

        fixture.loginAs(po.reviewer());
        var pending = arrivalControl.financeDetail(over.exceptionId());
        qty("100", pending.orderQtySnapshot(), "财务任务卡: 订货量");
        qty("5", pending.allowedOverReceiptPctSnapshot(), "财务任务卡: 允许超收%");
        qty("5", pending.toleranceQtySnapshot(), "财务任务卡: 允许超收量");
        qty("0", pending.priorNetReceivedQtySnapshot(), "财务任务卡: 此前已收");
        var decided = arrivalControl.financeDecide(over.exceptionId(),
                new ArrivalDecisionRequest(pending.version(), "REJECT_EXCESS", null, null));
        assertEquals("RECEIPT_ADJUSTED", decided.status());
        qty("105", decided.acceptedQty(), "拒收超量 → 收窄到最多可收量");
        qty("5", decided.unacceptedQty(), "超出的 5 不收");
        qty("0", decided.approvedExcessQty(), "没有批准任何超量");
        Map<String, Object> returnTask = db.queryForMap(
                "SELECT qty, status FROM supplier_return_tasks WHERE arrival_exception_id=?", over.exceptionId());
        qty("5", returnTask.get("qty"), "生成退供应商 5 的任务");
        assertEquals("PENDING_RETURN", returnTask.get("status"));

        fixture.loginAs(w.superAdminUserId());
        arrivalControl.stockInWithDecisionSession(over.exceptionId(),
                target -> purchaseReceipts.approveFromWarehouseDecision(target.receiptId()));
        qty("105", db.queryForObject("""
                SELECT SUM(qty) FROM purchase_receipt_items WHERE receipt_id=? AND COALESCE(is_deleted, FALSE)=FALSE
                """, BigDecimal.class, over.receiptId()), "收货单按收窄后的 105 审核");
        assertAp(w, "2100");
        stockIn("PURCHASE", over.receiptId(), passIqc("PURCHASE", over.receiptId(), tag), tag, w.warehouseId());
        qty("105", onHand(b, w.warehouseId()), "105 入库");
        qty("0", db.queryForObject("SELECT COALESCE(arrival_overage_posted_qty, 0) FROM purchase_order_items WHERE id=?",
                BigDecimal.class, po.orderItemId()), "拒收超量不产生已过账超量");
    }

    @Test
    void approveAllAcceptsTheWholeArrivalAndOnlyTheApprovedExcessIsPosted() {
        String tag = "por-110-approve";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID b = goods(w, tag, "B", "采购");
        Purchase po = approvedPurchase(w, b, "100", "5", null, tag);

        WarehouseArrivalRegisterResult over = arrivals.register(purchaseArrival(w, b, po.orderItemId(), "110", tag));
        assertEquals("EXCESS_QUARANTINED", over.outcome());
        fixture.loginAs(po.reviewer());
        var pending = arrivalControl.financeDetail(over.exceptionId());
        var decided = arrivalControl.financeDecide(over.exceptionId(), new ArrivalDecisionRequest(
                pending.version(), "APPROVE_ALL", null, "供应商多送的 5 件按原价接收"));
        assertEquals("RECEIPT_ADJUSTED", decided.status());
        qty("110", decided.acceptedQty(), "全部接收");
        qty("5", decided.approvedExcessQty(), "财务只需批准超过最多可收的 5");
        assertEquals(0, count("SELECT COUNT(*) FROM supplier_return_tasks WHERE arrival_exception_id=? AND status='PENDING_RETURN'",
                over.exceptionId()), "全部接收不退货");

        fixture.loginAs(w.superAdminUserId());
        arrivalControl.stockInWithDecisionSession(over.exceptionId(),
                target -> purchaseReceipts.approveFromWarehouseDecision(target.receiptId()));
        assertAp(w, "2200");
        qty("5", db.queryForObject("SELECT arrival_overage_posted_qty FROM purchase_order_items WHERE id=?",
                BigDecimal.class, po.orderItemId()), "已过账超量只记财务批准的 5, 不含容差");
        stockIn("PURCHASE", over.receiptId(), passIqc("PURCHASE", over.receiptId(), tag), tag, w.warehouseId());
        qty("110", onHand(b, w.warehouseId()), "110 入库");
    }

    // =====================================================================================
    // 收满订货量后手工收货
    // =====================================================================================

    @Test
    void afterTheOrderIsFulfilledAManualReceiptWithinToleranceStocksDirectlyAndBeyondItGoesToFinance() {
        String tag = "por-manual";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID b = goods(w, tag, "B", "采购");
        Purchase po = approvedPurchase(w, b, "100", "5", null, tag);
        UUID full = registerPurchase(w, b, po.orderItemId(), "100", tag + "-a1");
        stockIn("PURCHASE", full, passIqc("PURCHASE", full, tag + "-a1"), tag + "-a1", w.warehouseId());
        assertEquals("CLOSED", expectationStatus(po.orderId()), "收满 100 预计到货关闭, 不再催仓库");
        assertAp(w, "2000");

        // 供应商又送来 3: 采购员手工收货单登记, 比例内直接送检入库、立应付。
        UUID manual = manualReceipt(w, b, po.orderItemId(), "3", null);
        assertEquals(0, exceptionCount(po.orderItemId()), "比例内不转财务");
        assertAp(w, "2060");
        stockIn("PURCHASE", manual, passIqc("PURCHASE", manual, tag + "-m1"), tag + "-m1", w.warehouseId());
        qty("103", onHand(b, w.warehouseId()), "手工收货的 3 入库");

        // 再送 3: 累计 106 > 105, 整张转财务, 不入库不立应付。
        assertThrows(ProcurementArrivalBlockedException.class, () -> manualReceipt(w, b, po.orderItemId(), "3", null));
        Map<String, Object> exception = theOnlyException(po.orderItemId());
        assertEquals("PENDING_FINANCE", exception.get("status"));
        qty("3", exception.get("declared_qty"), "本次实到");
        qty("2", exception.get("approved_remaining_qty"), "容差只剩 2");
        qty("103", exception.get("prior_net_received_qty_snapshot"), "此前已收 103");
        assertAp(w, "2060");
        qty("103", onHand(b, w.warehouseId()), "超出的不入库");
    }

    // =====================================================================================
    // 扩展列(模具费)明细: 收满订货量时应付 = 订单金额
    // =====================================================================================

    @Test
    void anExtraColumnLinePostsExactlyTheOrderAmountWhenReceivedInFullAndPricesToleranceAtTheUnitPrice() {
        String tag = "por-extra";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID b = goods(w, tag, "B", "采购");
        var mould = businessColumns.create(new BusinessColumnService.Create("purchase_order", "模具费", "AMOUNT", "ADD"));
        Purchase po = approvedPurchase(w, b, "100", "5", List.of(new ExtraColumnInput(mould.id(), "300")), tag);
        qty("2300", db.queryForObject("SELECT amount_original FROM purchase_order_items WHERE id=?", BigDecimal.class,
                po.orderItemId()), "订单金额 = 100 × 20 + 模具费 300");

        registerPurchase(w, b, po.orderItemId(), "60", tag + "-a1");
        registerPurchase(w, b, po.orderItemId(), "40", tag + "-a2");
        assertAp(w, "2300");

        manualReceipt(w, b, po.orderItemId(), "2", null);
        assertAp(w, "2340");
    }

    // =====================================================================================
    // 质检退回后自动来源登记按补回, 容差最后才用
    // =====================================================================================

    @Test
    void anIqcFailureReturnedToTheSupplierIsReplacedByAnAutomaticSourceArrivalAndToleranceIsConsumedLast() {
        String tag = "por-iqc";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID b = goods(w, tag, "B", "采购");
        Purchase po = approvedPurchase(w, b, "100", "5", null, tag);
        UUID receiptId = registerPurchase(w, b, po.orderItemId(), "100", tag + "-a1");
        assertAp(w, "2000");

        // 质检判 10 件不合格, 其余 90 合格入库; 不合格的 10 实物退回供应商。
        UUID inspectionItem = inspectionItemOf("PURCHASE", receiptId);
        inspections.dispose("PURCHASE", receiptId, inspectionItem,
                new InspectionDispositionRequest("FAIL", new BigDecimal("10"), "10 件尺寸不合格", "por-iqc-fail-" + receiptId));
        UUID rejection = awaitIqcRejection("PURCHASE", receiptId);
        stockIn("PURCHASE", receiptId, passIqc("PURCHASE", receiptId, tag + "-a1"), tag + "-a1", w.warehouseId());
        qty("90", onHand(b, w.warehouseId()), "合格 90 入库");
        long version = db.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",
                Long.class, rejection);
        iqcRejections.recordReturn(rejection, new RecordReturnRequest(version, UUID.randomUUID(),
                "POR-IQC-RET-" + rejection, BusinessTime.today(), "不合格 10 件已实物退回供应商"));
        assertAp(w, "2000");

        // 供应商补来 10, 仓库按自动来源登记: 欠交为 0、补回 10 → 按补回入库, 不另立应付。
        UUID replacement = registerPurchase(w, b, po.orderItemId(), "10", tag + "-r1");
        qty("10", db.queryForObject("""
                SELECT COALESCE(SUM(allocated_base_qty), 0) FROM procurement_iqc_replacement_allocations
                WHERE case_id=? AND status='ACTIVE'
                """, BigDecimal.class, rejection), "自动来源的 10 全部按质检补回分配");
        assertEquals(0, count("""
                SELECT COUNT(*) FROM ar_ap_ledger WHERE source_doc_type='PURCHASE_RECEIPT' AND source_doc_id=? AND status=1
                """, replacement), "免费补回不产生应付");
        assertAp(w, "2000");
        stockIn("PURCHASE", replacement, passIqc("PURCHASE", replacement, tag + "-r1"), tag + "-r1", w.warehouseId());
        qty("100", onHand(b, w.warehouseId()), "补回后合格库存 100");

        // 补回、欠交都用完了, 允许超收的 5 还在: 再收 5 直接入库并按单价立应付。
        UUID tolerance = manualReceipt(w, b, po.orderItemId(), "5", null);
        assertEquals(0, exceptionCount(po.orderItemId()), "容差内不转财务");
        assertAp(w, "2100");
        stockIn("PURCHASE", tolerance, passIqc("PURCHASE", tolerance, tag + "-t1"), tag + "-t1", w.warehouseId());
        qty("105", onHand(b, w.warehouseId()), "容差 5 入库");
        assertThrows(ProcurementArrivalBlockedException.class,
                () -> manualReceipt(w, b, po.orderItemId(), "0.0001", null));
    }

    // =====================================================================================
    // 退货红冲守卫、改量下限、已批准订单改比例
    // =====================================================================================

    @Test
    void returnReversalWithinToleranceIsAllowedChangeQtyLowerBoundUsesThePercentageAndApprovedPercentIsFrozen() {
        String tag = "por-guards";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID b = goods(w, tag, "B", "采购");
        Purchase po = approvedPurchase(w, b, "100", "5", null, tag);
        UUID receiptId = registerPurchase(w, b, po.orderItemId(), "105", tag + "-a1");
        stockIn("PURCHASE", receiptId, passIqc("PURCHASE", receiptId, tag + "-a1"), tag + "-a1", w.warehouseId());
        qty("105", onHand(b, w.warehouseId()), "比例内 105 入库");

        // 退 5 再红冲: 红冲后净收 105 ≤ 订货 100 + 容差 5, 数据库退货红冲守卫放行。
        UUID receiptItemId = db.queryForObject("""
                SELECT id FROM purchase_receipt_items WHERE receipt_id=? AND COALESCE(is_deleted, FALSE)=FALSE
                """, UUID.class, receiptId);
        UUID returnId = purchaseReturn(w, b, po.orderItemId(), receiptItemId, "5");
        qty("100", onHand(b, w.warehouseId()), "退货出库 5");
        purchaseReturns.reverse(returnId);
        qty("105", onHand(b, w.warehouseId()), "红冲退货, 库存回到 105");

        // 改量下限: 最小 N 使 N + T(N, 5%) ≥ 105 → 100(不按比例时会是 105)。
        qty("100", new TransactionTemplate(transactions).execute(status -> ProcurementOrderQuantityBounds
                .receipts(em, "PURCHASE", po.orderItemId()).minimumOrderedQty(BigDecimal.ONE)), "改量下限按比例算");
        ApiException belowBound = assertThrows(ApiException.class, () -> purchaseOrders.changeQty(po.orderId(),
                new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(po.orderItemId(), new BigDecimal("99.9999"))))));
        assertEquals(ErrorCode.CONFLICT, belowBound.getCode(), "99.9999 + T(99.9999, 5%) = 104.9999 < 105");
        qty("100", db.queryForObject("SELECT qty FROM purchase_order_items WHERE id=?", BigDecimal.class,
                po.orderItemId()), "被拒的改量不落盘");

        // 财务批准后比例冻结: 直接改库被采购专用冻结触发器拒绝; 原值重写不算修改。
        DataAccessException frozen = assertThrows(DataAccessException.class, () -> db.update(
                "UPDATE purchase_order_items SET allowed_over_receipt_pct = 10 WHERE id=?", po.orderItemId()));
        SQLException root = rootSql(frozen);
        assertEquals("23514", root.getSQLState(), "冻结触发器按 CHECK 类违约拒绝");
        assertTrue(root.getMessage().contains("over-receipt allowances are immutable"), root.getMessage());
        assertEquals(1, db.update(
                "UPDATE purchase_order_items SET allowed_over_receipt_pct = allowed_over_receipt_pct WHERE id=?",
                po.orderItemId()), "原值重写不触发冻结");
        qty("5", db.queryForObject("SELECT allowed_over_receipt_pct FROM purchase_order_items WHERE id=?",
                BigDecimal.class, po.orderItemId()), "比例仍是 5");
    }

    // =====================================================================================
    // 货品记忆与 /last-terms 预填
    // =====================================================================================

    @Test
    void savingAnOrderWritesTheGoodsMemoryBlankLinesKeepItAndLastTermsPrefillsItFromTheGoodsMaster() {
        String tag = "por-memory";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID g = goods(w, tag, "G", "采购");
        UUID h = goods(w, tag, "H", "采购");
        assertNull(memoryOf(g), "新货品没有允许超收记忆");

        purchaseOrder(w, g, "10", "5", null);
        qty("5", memoryOf(g), "保存订货单把 5% 写回货品记忆");
        var terms = purchaseOrders.masterDefaultTermsPerGoods(List.of(g, h));
        qty("5", terms.get(g).allowedOverReceiptPct(), "last-terms 预填比例");
        assertEquals("GOODS_MASTER", terms.get(g).allowedOverReceiptPctSource(), "预填来源 = 货品主档");
        assertNotNull(terms.get(h), "H 有默认供应商, 照样返回主档条款");
        assertNull(terms.get(h).allowedOverReceiptPct(), "H 没有记忆值");
        assertNull(terms.get(h).allowedOverReceiptPctSource(), "没有记忆就没有来源");

        Purchase blank = purchaseOrder(w, g, "10", null, null);
        assertNull(purchaseOrders.detail(blank.orderId()).getItems().getFirst().getAllowedOverReceiptPct(),
                "空行保存为空(= 0%)");
        qty("5", memoryOf(g), "空行不清空货品记忆");

        purchaseOrder(w, g, "10", "7.5", null);
        qty("7.5", memoryOf(g), "最近一次填写的值成为新记忆");
        qty("7.5", purchaseOrders.masterDefaultTermsPerGoods(List.of(g)).get(g).allowedOverReceiptPct(),
                "预填跟着记忆走");
    }

    // =====================================================================================
    // 委外回厂不受采购比例影响
    // =====================================================================================

    @Test
    void subcontractReturnsIgnoreThePurchaseToleranceEvenWhenTheGoodsHasAMemory() {
        String tag = "por-subcontract";
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID p = goods(w, tag, "P", "委外");
        UUID m = goods(w, tag, "M", "采购");
        fixture.insertBom(p, m, "1");
        db.update("UPDATE goods SET purchase_allowed_over_receipt_pct = 5 WHERE id IN (?, ?)", p, m);
        otherIn(w, m, "10", "5");
        UUID orderId = subcontractOrder(w, p, "10");
        UUID reviewer = financeReviewer(w, tag + "-sc");
        financeApproval.submit("SUBCONTRACT", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId);
        fixture.loginAs(w.superAdminUserId());
        UUID item = db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",
                UUID.class, orderId);
        drawCommands.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(item, null)), "por-sc-draw-" + item))
                .issueIds().forEach(materialIssues::approve);
        qty("10", db.queryForObject("SELECT fn_subcontract_returnable_qty(?)", BigDecimal.class, item), "可回厂 10");

        // 回厂 10.5(恰好是 10 + 5%): 委外没有允许超收, 超出的 0.5 是委外商自带料, 整单隔离转财务。
        WarehouseArrivalRegisterResult over = arrivals.register(new WarehouseArrivalRegisterRequest(
                "por-sc-return-" + item, "SUBCONTRACT", BusinessTime.today(), w.supplierId(), w.warehouseId(), null,
                w.employeeId(), null, List.of(new ArrivalLine(p, new BigDecimal("10.5"), item, null, w.unitId(),
                BigDecimal.ONE, null, null))));
        assertEquals("EXCESS_QUARANTINED", over.outcome(), "委外回厂超过可回厂量照旧隔离");
        Map<String, Object> exception = db.queryForMap("""
                SELECT approved_remaining_qty, order_qty_snapshot, allowed_over_receipt_pct_snapshot,
                       tolerance_qty_snapshot, prior_net_received_qty_snapshot
                FROM procurement_arrival_exceptions WHERE id=?
                """, over.exceptionId());
        qty("10", exception.get("approved_remaining_qty"), "可收只到可回厂量 10, 不加任何容差");
        assertNull(exception.get("order_qty_snapshot"), "委外不写采购允许超收快照");
        assertNull(exception.get("allowed_over_receipt_pct_snapshot"));
        assertNull(exception.get("tolerance_qty_snapshot"));
        assertNull(exception.get("prior_net_received_qty_snapshot"));
    }

    // =====================================================================================
    // 夹具
    // =====================================================================================

    private record Purchase(UUID orderId, UUID orderItemId, UUID reviewer) {
    }

    private record PassSlice(UUID passEventId, BigDecimal qty) {
    }

    private UUID goods(FullChainEndToEndTest.World w, String tag, String code, String sourceType) {
        UUID id = UUID.randomUUID();
        // 世界夹具已占用 A-/B-/C-/D-/E-{tag} 编号, 本类货品加前缀避开。
        String label = "POR-" + code + "-" + tag;
        fixture.insertGoods(id, label, label, sourceType, w.unitId(), w.unitLegacy());
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?", w.supplierId(), id);
        return id;
    }

    private UUID settlementMethod() {
        return ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId");
    }

    /** 有采购、财务审批与驳回权限的审核人(财务审核组成员)。 */
    private UUID financeReviewer(FullChainEndToEndTest.World w, String tag) {
        return fixture.createUserWithPerms(w, tag + "-finance", "finance_order_approval:view",
                "finance_order_approval:approve", "finance_order_approval:reject", "notice:read");
    }

    /** 已审核采购申请 → 采购订货单(单价 20, 允许超收 pct%, 可带扩展列), 不送审。 */
    private Purchase purchaseOrder(FullChainEndToEndTest.World w, UUID goodsId, String qty, String pct,
                                   List<ExtraColumnInput> extraColumns) {
        var request = new RequestSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(w.warehouseId());
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
        var order = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today());
        order.setSupplierId(w.supplierId());
        order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(w.currencyId());
        order.setExchangeRate(BigDecimal.ONE);
        order.setTaxRate(BigDecimal.ZERO);
        order.setSettlementMethodId(settlementMethod());
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(goodsId);
        line.setRequestItemId(created.getItems().getFirst().getId());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal(PRICE));
        line.setAllowedOverReceiptPct(pct == null ? null : new BigDecimal(pct));
        if (extraColumns != null) {
            line.setExtraColumns(extraColumns);
        }
        order.setItems(List.of(line));
        UUID orderId = purchaseOrders.createBatch(order).getFirst().getId();
        UUID itemId = db.queryForObject(
                "SELECT id FROM purchase_order_items WHERE order_id=? AND COALESCE(is_deleted, FALSE)=FALSE",
                UUID.class, orderId);
        return new Purchase(orderId, itemId, null);
    }

    /** 采购订货单送财务并批准; 返回的审核人同时有到货异常的批准与驳回权限。 */
    private Purchase approvedPurchase(FullChainEndToEndTest.World w, UUID goodsId, String qty, String pct,
                                      List<ExtraColumnInput> extraColumns, String tag) {
        Purchase draft = purchaseOrder(w, goodsId, qty, pct, extraColumns);
        UUID reviewer = financeReviewer(w, tag);
        financeApproval.submit("PURCHASE", draft.orderId());
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("PURCHASE", draft.orderId());
        fixture.loginAs(w.superAdminUserId());
        assertEquals(1, ((Number) db.queryForObject("SELECT status FROM purchase_orders WHERE id=?", Integer.class,
                draft.orderId())).intValue(), "采购订货单已财务批准");
        return new Purchase(draft.orderId(), draft.orderItemId(), reviewer);
    }

    private WarehouseArrivalRegisterRequest purchaseArrival(FullChainEndToEndTest.World w, UUID goodsId,
                                                            UUID orderItemId, String qty, String key) {
        return new WarehouseArrivalRegisterRequest(
                "por-arrival-" + key + "-" + orderItemId, "PURCHASE", BusinessTime.today(),
                w.supplierId(), w.warehouseId(), null, w.employeeId(), null,
                List.of(new ArrivalLine(goodsId, new BigDecimal(qty), orderItemId, null,
                        w.unitId(), BigDecimal.ONE, null, null)));
    }

    /** 仓库到货登记(自动来源); 期望不触发隔离, 直接送检(收货单已审核、已立应付)。 */
    private UUID registerPurchase(FullChainEndToEndTest.World w, UUID goodsId, UUID orderItemId, String qty,
                                  String key) {
        WarehouseArrivalRegisterResult result = arrivals.register(purchaseArrival(w, goodsId, orderItemId, qty, key));
        assertEquals("SUBMITTED_FOR_INSPECTION", result.outcome(), "到货 " + qty + " 在最多可收以内直接送检");
        return result.receiptId();
    }

    /** 采购员手工采购收货单: 建单 + 审核(审核走同一到货闸门, 超出最多可收时抛隔离异常)。 */
    private UUID manualReceipt(FullChainEndToEndTest.World w, UUID goodsId, UUID orderItemId, String qty,
                               String replacementIntent) {
        var request = new ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(settlementMethod());
        var line = new ReceiptItemLine();
        line.setGoodsId(goodsId);
        line.setOrderItemId(orderItemId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setReplacementIntent(replacementIntent);
        line.setPrice(new BigDecimal(PRICE));
        request.setItems(List.of(line));
        UUID receiptId = purchaseReceipts.create(request).getId();
        purchaseReceipts.approve(receiptId);
        return receiptId;
    }

    private UUID purchaseReturn(FullChainEndToEndTest.World w, UUID goodsId, UUID orderItemId, UUID receiptItemId,
                                String qty) {
        var request = new ReturnSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(settlementMethod());
        var line = new ReturnItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal(PRICE));
        line.setOrderItemId(orderItemId);
        line.setReceiptItemId(receiptItemId);
        request.setItems(List.of(line));
        UUID returnId = purchaseReturns.create(request).getId();
        purchaseReturns.approve(returnId);
        return returnId;
    }

    /** 其它入库单审核入库(公共库存)。 */
    private void otherIn(FullChainEndToEndTest.World w, UUID goodsId, String qty, String price) {
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(w.warehouseId());
        request.setRemark("允许超收测试入库 " + qty);
        var line = new StockDocItemLine();
        line.setGoodsId(goodsId);
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

    private UUID subcontractOrder(FullChainEndToEndTest.World w, UUID goodsId, String qty) {
        var request = new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setDeliverDate(BusinessTime.today().plusDays(10));
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(settlementMethod());
        var line = new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        line.setGoodsId(goodsId);
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("50"));
        request.setItems(List.of(line));
        return subcontractOrders.create(request).getId();
    }

    private UUID inspectionItemOf(String receiptType, UUID receiptId) {
        return db.queryForObject("""
                SELECT id FROM procurement_inspection_items WHERE receipt_type=? AND receipt_id=?
                """, UUID.class, receiptType, receiptId);
    }

    private PassSlice passIqc(String receiptType, UUID receiptId, String key) {
        UUID inspectionItemId = inspectionItemOf(receiptType, receiptId);
        inspections.dispose(receiptType, receiptId, inspectionItemId,
                new InspectionDispositionRequest("PASS", null, "检验合格", "por-iqc-" + key));
        Map<String, Object> pass = db.queryForMap("""
                SELECT id, base_qty FROM procurement_inspection_events
                WHERE inspection_item_id=? AND action='PASS'
                ORDER BY occurred_at DESC, id DESC LIMIT 1
                """, inspectionItemId);
        return new PassSlice((UUID) pass.get("id"), (BigDecimal) pass.get("base_qty"));
    }

    private void stockIn(String receiptType, UUID receiptId, PassSlice pass, String key, UUID warehouseId) {
        iqcStockIn.confirm(receiptType, receiptId, new ConfirmRequest("por-stock-" + key,
                List.of(new ConfirmItem(pass.passEventId(), pass.qty(), pass.qty(), "POR-01", warehouseId))));
    }

    /** 不合格判定经 outbox 投影成 IQC 退回案件后才能登记实物退回。 */
    private UUID awaitIqcRejection(String receiptType, UUID receiptId) {
        long deadline = System.currentTimeMillis() + 20_000;
        do {
            outbox.processNext();
            List<UUID> cases = db.queryForList(
                    "SELECT id FROM procurement_iqc_rejection_cases WHERE receipt_type=? AND receipt_id=?",
                    UUID.class, receiptType, receiptId);
            int pending = count("""
                    SELECT COUNT(*) FROM business_outbox event
                    JOIN procurement_inspection_items inspection ON inspection.id = event.aggregate_id
                    WHERE event.event_type='PROCUREMENT_IQC_REJECTION_DETECTED' AND event.status<>1
                      AND inspection.receipt_type=? AND inspection.receipt_id=?
                    """, receiptType, receiptId);
            if (cases.size() == 1 && pending == 0) {
                return cases.getFirst();
            }
            try {
                Thread.sleep(25);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException(interrupted);
            }
        } while (System.currentTimeMillis() < deadline);
        throw new AssertionError("IQC 不合格事件没有投影成退回案件: " + receiptId);
    }

    private int exceptionCount(UUID orderItemId) {
        return count("SELECT COUNT(*) FROM procurement_arrival_exceptions WHERE order_type='PURCHASE' AND order_item_id=?",
                orderItemId);
    }

    private Map<String, Object> theOnlyException(UUID orderItemId) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT status, declared_qty, approved_remaining_qty, order_qty_snapshot, allowed_over_receipt_pct_snapshot,
                       tolerance_qty_snapshot, prior_net_received_qty_snapshot
                FROM procurement_arrival_exceptions WHERE order_type='PURCHASE' AND order_item_id=?
                """, orderItemId);
        assertEquals(1, rows.size(), "该订货明细恰好一条到货异常, 现状 " + rows);
        return rows.getFirst();
    }

    private String expectationStatus(UUID orderId) {
        return db.queryForObject("SELECT status FROM inbound_expectations WHERE order_type='PURCHASE' AND order_id=?",
                String.class, orderId);
    }

    private BigDecimal memoryOf(UUID goodsId) {
        return db.queryForObject("SELECT purchase_allowed_over_receipt_pct FROM goods WHERE id=?", BigDecimal.class,
                goodsId);
    }

    private BigDecimal onHand(UUID goodsId, UUID warehouseId) {
        return db.queryForObject("SELECT COALESCE(SUM(qty), 0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",
                BigDecimal.class, goodsId, warehouseId);
    }

    /** 本供应商已过账应付(原币与本币, 汇率 1)。 */
    private void assertAp(FullChainEndToEndTest.World w, String expected) {
        Map<String, Object> ap = db.queryForMap("""
                SELECT COALESCE(SUM(amount_original), 0) AS original, COALESCE(SUM(amount_original_local), 0) AS local
                FROM ar_ap_ledger
                WHERE supplier_id=? AND currency_id=? AND direction='AP' AND status=1 AND is_deleted=FALSE
                """, w.supplierId(), w.currencyId());
        qty(expected, ap.get("original"), "应付原币合计");
        qty(expected, ap.get("local"), "应付本币合计");
    }

    private static SQLException rootSql(Throwable error) {
        Throwable cause = error;
        SQLException sql = null;
        while (cause != null) {
            if (cause instanceof SQLException found) {
                sql = found;
            }
            cause = cause.getCause();
        }
        assertNotNull(sql, "应当由数据库拒绝: " + error);
        return sql;
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
