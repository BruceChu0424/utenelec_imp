package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
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
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Real warehouse, owner-decision, rollback, cost and permission boundaries for partial actual receipts. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
// Historical supply snapshots stay frozen; new actual receipts preserve the full finished target.
class SubcontractToleranceAutoSettleEndToEndTest extends SubcontractFullChainTestContext {


    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractOrderService orders;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired SubcontractMaterialIssueService materialIssues;
    @Autowired SubcontractShortDeliveryService shortDeliveries;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcStockInService iqcStockIn;
    @Autowired com.uten.imp.features.stock.valuation.InventoryValueWorkService inventoryValueWork;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;

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
    void warehouseStockInPreservesTheShortfallUntilItsOwnerExplicitlyDecidesAndAllWritesRemainAtomic() {
        var w = fixture.seedWorld("sc-actual-shortfall");
        fixture.loginAs(w.superAdminUserId());
        UUID material = fixture.ensureSubcontractDirectMaterial(w, w.goodsE());
        fixture.receiveSubcontractMaterial(w, material, "1000");
        UUID orderId = fixture.createWithFullMaterialBudget(orderRequest(w, "1000", "10")).getId();
        UUID itemId = db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?", UUID.class, orderId);
        UUID makerId = db.queryForObject("SELECT maker_id FROM subcontract_orders WHERE id=?", UUID.class, orderId);
        assertNotNull(makerId);
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("SUBCONTRACT", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId);
        // Preserve an old frozen supply plan while all new receipts obey the actual-quantity rule.
        fixture.seedHistoricalSubcontractLossPlanBeforeExecution(orderId);
        fixture.loginAs(w.superAdminUserId());
        fixture.drawAndIssueSubcontract(itemId, new BigDecimal("1000"), "actual-shortfall-draw-" + itemId);
        qty("1000", db.queryForObject("SELECT SUM(at_supplier_qty) FROM subcontract_material_issue_items WHERE order_item_id=?", BigDecimal.class, itemId));

        var unconfirmed = arrival(w, itemId, "950", "partial");
        assertThrows(ApiException.class, () -> arrivals.register(unconfirmed));
        assertEquals(0, count("SELECT COUNT(*) FROM subcontract_receipt_items WHERE order_item_id=?", itemId));
        qty("0", db.queryForObject("SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=?", BigDecimal.class, itemId));
        var receipt = arrivals.register(new WarehouseArrivalRegisterRequest(unconfirmed.idempotencyKey(),
                "SUBCONTRACT", BusinessTime.today(), w.supplierId(), w.warehouseId(), null,
                w.employeeId(), null, unconfirmed.items(), null, true));
        assertEquals("SUBMITTED_FOR_INSPECTION", receipt.outcome());
        Map<String, Object> pending = caseRow(itemId);
        UUID caseId = (UUID) pending.get("id");
        assertEquals("PENDING_OWNER", pending.get("status"));
        assertEquals("BELOW_FLOOR", pending.get("severity"));
        qty("1000", (BigDecimal) pending.get("floor_qty"));
        qty("50", (BigDecimal) pending.get("shortfall_qty"));
        assertNotNull(shortDeliveries.stockInHoldReason(receipt.receiptId()));
        shortDeliveries.decide(caseId, new com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest(
                "WAIT_MORE", BusinessTime.today().plusDays(3), "实际先到950，剩余50分批等待", ((Number) pending.get("version")).longValue()));
        assertNull(shortDeliveries.stockInHoldReason(receipt.receiptId()));

        UUID inspectionItemId = db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?", UUID.class, receipt.receiptId());
        inspections.dispose("SUBCONTRACT", receipt.receiptId(), inspectionItemId,
                new InspectionDispositionRequest("PASS", null, "实际950检查合格", "actual-shortfall-pass"));
        UUID passEventId = db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'", UUID.class, inspectionItemId);
        BigDecimal passedQty = db.queryForObject("SELECT base_qty FROM procurement_inspection_events WHERE id=?", BigDecimal.class, passEventId);
        qty("950", passedQty);

        UUID keeper = fixture.createUserWithPerms(w, "sc-actual-shortfall-keeper",
                "warehouse_iqc_stock_in:view", "warehouse_iqc_stock_in:confirm", "subcontract_order:change_qty");
        UUID keeperEmployeeId = db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, keeper);
        assertNotEquals(makerId, keeperEmployeeId);
        fixture.loginAs(keeper);
        Set<String> permissions = SecurityContextHolder.getContext().getAuthentication().getAuthorities()
                .stream().map(GrantedAuthority::getAuthority).collect(Collectors.toSet());
        assertFalse(permissions.contains("subcontract:view:all"));
        assertFalse(permissions.contains("subcontract_order:view"));
        assertFalse(db.queryForObject("SELECT is_super_admin FROM users WHERE id=?", Boolean.class, keeper));
        var confirmation = new ConfirmRequest("actual-shortfall-stock", List.of(
                new ConfirmItem(passEventId, passedQty, passedQty, "SC-ACTUAL", w.warehouseId())));
        BigDecimal before = onHand(w.goodsE(), w.warehouseId());
        String apBefore = apSnapshot(receipt.receiptId());
        assertThrows(ApiException.class, () -> new org.springframework.transaction.support.TransactionTemplate(transactionManager)
                .executeWithoutResult(status -> {
                    iqcStockIn.confirm("SUBCONTRACT", receipt.receiptId(), confirmation);
                    org.springframework.transaction.support.TransactionSynchronizationManager.registerSynchronization(
                            new org.springframework.transaction.support.TransactionSynchronization() {
                                @Override public void beforeCommit(boolean readOnly) {
                                    assertEquals("WAITING_MORE", caseRow(itemId).get("status"));
                                    assertNull(caseRow(itemId).get("waste_id"));
                                    throw new ApiException(ErrorCode.CONFLICT, "模拟实际入库提交中断");
                                }
                            });
                }));
        assertEquals(0, count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?", receipt.receiptId()));
        assertEquals(0, before.compareTo(onHand(w.goodsE(), w.warehouseId())));
        assertEquals(apBefore, apSnapshot(receipt.receiptId()));
        assertFalse(iqcStockIn.confirm("SUBCONTRACT", receipt.receiptId(), confirmation).replayed());
        qty("950", onHand(w.goodsE(), w.warehouseId()).subtract(before));
        assertEquals("WAITING_MORE", caseRow(itemId).get("status"));
        assertNull(caseRow(itemId).get("waste_id"), "仓库入库不得替负责人自动认损耗");
        assertFalse(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, orderId));

        fixture.loginAs(w.superAdminUserId());
        // The harness disables the production worker poller. Complete the real stock
        // value work before the next department makes an independent loss decision.
        InventoryValueWorkTestSupport.drain(inventoryValueWork, db, List.of(material, w.goodsE()));
        long version = ((Number) caseRow(itemId).get("version")).longValue();
        var decision = new com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest(
                "ACCEPT_LOSS", null, "负责人核实后明确接受实际少交50并追踪责任", version);
        var published = new java.util.concurrent.atomic.AtomicBoolean();
        ApiException publicationFailure = assertThrows(ApiException.class, () -> new org.springframework.transaction.support.TransactionTemplate(transactionManager)
                .executeWithoutResult(status -> {
                    shortDeliveries.decide(caseId, decision);
                    org.springframework.transaction.support.TransactionSynchronizationManager.registerSynchronization(
                            new org.springframework.transaction.support.TransactionSynchronization() {
                                @Override public void beforeCommit(boolean readOnly) {
                                    UUID waste = (UUID) caseRow(itemId).get("waste_id");
                                    assertNotNull(waste);
                                    assertEquals(1, count("SELECT COUNT(*) FROM subcontract_loss_cases WHERE waste_id=?", waste));
                                    published.set(true);
                                    throw new ApiException(ErrorCode.CONFLICT, "模拟实际责任发布后的提交中断");
                                }
                            });
                }));
        assertTrue(published.get(), publicationFailure.getMessage());
        assertEquals("模拟实际责任发布后的提交中断", publicationFailure.getMessage());
        assertEquals("WAITING_MORE", caseRow(itemId).get("status"));
        assertNull(caseRow(itemId).get("waste_id"));
        qty("950", onHand(w.goodsE(), w.warehouseId()).subtract(before));
        assertEquals(apBefore, apSnapshot(receipt.receiptId()));
        qty("0", db.queryForObject("SELECT SUM(wasted_qty) FROM subcontract_material_issue_items WHERE order_item_id=?", BigDecimal.class, itemId));

        shortDeliveries.decide(caseId, decision);
        Map<String, Object> accepted = caseRow(itemId);
        assertEquals(caseId, accepted.get("id"));
        assertEquals("ACCEPTED_LOSS", accepted.get("status"));
        assertEquals(makerId, accepted.get("decided_by_employee_id"));
        qty("50", (BigDecimal) accepted.get("loss_qty"));
        qty("1000", db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, itemId));
        qty("950", db.queryForObject("SELECT received_qty FROM subcontract_order_items WHERE id=?", BigDecimal.class, itemId));
        UUID waste = (UUID) accepted.get("waste_id");
        assertNotNull(waste);
        assertEquals(1, count("SELECT COUNT(*) FROM subcontract_wastes WHERE id=? AND status=1", waste));
        qty("50", db.queryForObject("SELECT SUM(qty) FROM subcontract_waste_items WHERE waste_id=?", BigDecimal.class, waste));
        qty("0", db.queryForObject("SELECT SUM(standard_qty) FROM subcontract_waste_items WHERE waste_id=?", BigDecimal.class, waste));
        assertEquals(1, count("SELECT COUNT(*) FROM subcontract_loss_cases WHERE waste_id=?", waste));
        assertEquals(0, count("SELECT COUNT(*) FROM procurement_order_qty_change_logs WHERE order_type='SUBCONTRACT' AND order_item_id=?", itemId));
        assertEquals(1, count("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_type='SUBCONTRACT' AND order_id=?", orderId));
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, orderId));
        InventoryValueWorkTestSupport.drain(inventoryValueWork, db, List.of(material, w.goodsE()));
        assertTrue(db.queryForObject("SELECT complete FROM v_subcontract_waste_actual_value WHERE waste_item_id=(SELECT id FROM subcontract_waste_items WHERE waste_id=?)", Boolean.class, waste));
        assertThrows(ApiException.class, () -> shortDeliveries.decide(caseId, decision));
        assertEquals(1, count("SELECT COUNT(*) FROM subcontract_loss_cases WHERE waste_id=?", waste));

        fixture.loginAs(keeper);
        assertTrue(iqcStockIn.confirm("SUBCONTRACT", receipt.receiptId(), confirmation).replayed());
        qty("950", onHand(w.goodsE(), w.warehouseId()).subtract(before));
        ApiException denied = assertThrows(ApiException.class, () -> orders.changeQty(orderId,
                new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(itemId, new BigDecimal("900"))))));
        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
        assertTrue(denied.getMessage().contains("只能操作本人负责的委外订货单"));
        assertEquals(0, count("SELECT COUNT(*) FROM procurement_order_qty_change_logs WHERE order_type='SUBCONTRACT' AND order_item_id=? AND new_qty=900", itemId));
    }

    private String apSnapshot(UUID receiptId) {
        return db.queryForObject("SELECT md5(COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.id)::text,'[]')) FROM ar_ap_ledger l WHERE l.source_doc_id=?", String.class, receiptId);
    }

    // ===================== 夹具 =====================

    private OrderSaveRequest orderRequest(FullChainEndToEndTest.World w, String qty, String allowedLossPct) {
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
        line.setPrice(BigDecimal.ONE);
        line.setAllowedLossPct(new BigDecimal(allowedLossPct));
        request.setItems(List.of(line));
        return request;
    }

    private WarehouseArrivalRegisterRequest arrival(
            FullChainEndToEndTest.World w, UUID itemId, String qty, String key) {
        return new WarehouseArrivalRegisterRequest(
                "sc-tolerance-arrival-" + key + "-" + itemId, "SUBCONTRACT", BusinessTime.today(),
                w.supplierId(), w.warehouseId(), null, w.employeeId(), null,
                List.of(new ArrivalLine(w.goodsE(), new BigDecimal(qty), itemId, null,
                        w.unitId(), BigDecimal.ONE, null, null)),
                null, null);
    }

    private Map<String, Object> caseRow(UUID itemId) {
        return db.queryForMap("""
                SELECT * FROM subcontract_short_delivery_cases
                WHERE order_item_id=? ORDER BY detected_at DESC LIMIT 1
                """, itemId);
    }

    private BigDecimal onHand(UUID goodsId, UUID warehouseId) {
        BigDecimal balance = db.queryForObject("""
                SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?
                """, BigDecimal.class, goodsId, warehouseId);
        return balance == null ? BigDecimal.ZERO : balance;
    }

    private int count(String sql, Object... args) {
        Integer n = db.queryForObject(sql, Integer.class, args);
        return n == null ? 0 : n;
    }

    private static void qty(String expected, BigDecimal actual) {
        assertNotNull(actual);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), "expected " + expected + " but was " + actual);
    }
}
