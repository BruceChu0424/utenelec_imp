package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionDecideRequest;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionReportRequest;
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
import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.*;
import static com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.*;
import static org.assertj.core.api.Assertions.*;

/** Real arrival commands, source queue, IQC identities and inventory/AP postings on migrated PostgreSQL. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {"spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.inventory.value-work.enabled=false",
        "uten.jwt.secret=gift-regression-isolated-jwt-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
        "uten.crypto.pgp-master-key=gift-regression-isolated-pgp-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
        "uten.crypto.hmac-key=gift-regression-isolated-hmac-key-0123456789-abcdef",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class GiftWarehouseArrivalConservationEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired PurchaseReceiptService receipts;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired ProcurementInspectionService inspection;
    @Autowired ProcurementIqcStockInService stockIn;
    @Autowired WarehouseArrivalRegistrationService arrival;
    @Autowired ProcurementArrivalControlService queue;
    private FullChainEndToEndTest harness;

    private record F(FullChainEndToEndTest.World w, UUID requestItem, UUID order, UUID orderItem) {}

    @BeforeEach void prepare() {
        harness = new FullChainEndToEndTest();
        beans.autowireBean(harness);
    }

    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void twoSourceBatchRetainsTwoChargedAndGiftInspectionsPerReceiptAndReplayPostsNoDuplicate() {
        var world = harness.seedWorld("gift-arrival-batch-" + UUID.randomUUID());
        F first = fixture(world);
        F second = fixture(world);
        var command = batch("gift-two-orders-" + first.order(), first, "10", "1", second);
        var registered = arrival.registerBatch(command);
        assertThat(registered.groupCount()).isEqualTo(2);
        assertThat(registered.replay()).isFalse();
        var replay = arrival.registerBatch(command);
        assertThat(replay.replay()).isTrue();
        assertThat(replay.items()).extracting(WarehouseArrivalBatchRegisterItem::receiptId)
                .containsExactlyElementsOf(registered.items().stream().map(WarehouseArrivalBatchRegisterItem::receiptId).toList());
        assertThat(number("SELECT count(*) FROM purchase_receipts WHERE id IN (?,?)",
                registered.items().get(0).receiptId(), registered.items().get(1).receiptId())).isEqualByComparingTo("2");
        for (var result : registered.items()) {
            assertThat(result.outcome()).isEqualTo("SUBMITTED_FOR_INSPECTION");
            assertTranches(result.receiptId(), "CHARGED", "GIFT");
            assertThat(ap(result.receiptId())).isEqualByComparingTo("100");
            assertThat(number("SELECT SUM(qty+gift_qty) FROM purchase_receipt_items WHERE receipt_id=?", result.receiptId()))
                    .isEqualByComparingTo("11");
            passAndStock(first, result.receiptId());
        }
        assertThat(stock(first)).isEqualByComparingTo("22");
        assertThat(value(first)).isEqualByComparingTo("200");
        assertThat(number("SELECT SUM(received_qty) FROM purchase_order_items WHERE id IN (?,?)", first.orderItem(), second.orderItem()))
                .isEqualByComparingTo("20");
        assertThat(number("SELECT SUM(gift_received_qty) FROM purchase_order_items WHERE id IN (?,?)", first.orderItem(), second.orderItem()))
                .isEqualByComparingTo("2");
        assertThat(arrival.registerBatch(command).items()).extracting(WarehouseArrivalBatchRegisterItem::receiptId)
                .containsExactlyElementsOf(replay.items().stream().map(WarehouseArrivalBatchRegisterItem::receiptId).toList());
        assertThat(stock(first)).isEqualByComparingTo("22");
        assertThat(value(first)).isEqualByComparingTo("200");
    }

    @Test void giftOnlySourceStaysVisibleAfterPaidStockAndPendingDraftOccupancyAndChangedKeyPayloadAreIndependent() {
        F f = fixture(harness.seedWorld("gift-arrival-late-" + UUID.randomUUID()));
        var paid = arrival.register(new WarehouseArrivalRegisterRequest(
                "gift-paid-first-" + f.order(), "PURCHASE", BusinessTime.today(), f.w().supplierId(), f.w().warehouseId(),
                null, f.w().employeeId(), "先到收费十件", List.of(new WarehouseArrivalRegisterRequest.ArrivalLine(
                f.w().goodsD(), new BigDecimal("10"), f.orderItem(), null, f.w().unitId(), BigDecimal.ONE,
                null, null, null, null, null, BigDecimal.ZERO))));
        assertThat(paid.outcome()).isEqualTo("SUBMITTED_FOR_INSPECTION");
        passAndStock(f, paid.receiptId());
        assertThat(stock(f)).isEqualByComparingTo("10");
        assertThat(ap(paid.receiptId())).isEqualByComparingTo("100");
        var source = source(f);
        assertThat(source.remainingQty()).isZero();
        assertThat(source.remainingGiftQty()).isEqualByComparingTo("1");
        assertThat(source.registeredGiftQty()).isZero();

        UUID pending = giftDraft(f, "0.4");
        var occupied = source(f);
        assertThat(occupied.remainingQty()).isZero();
        assertThat(occupied.registeredQty()).isZero();
        assertThat(occupied.remainingGiftQty()).isEqualByComparingTo("1");
        assertThat(occupied.registeredGiftQty()).isEqualByComparingTo("0.4");
        assertThat(source(f).registeredGiftQty()).isEqualByComparingTo("0.4");

        String key = "gift-late-only-" + f.order();
        var command = batch(key, f, "0", "0.6", null);
        var free = arrival.registerBatch(command).items().getFirst();
        assertThat(free.outcome()).isEqualTo("SUBMITTED_FOR_INSPECTION");
        assertTranches(free.receiptId(), "GIFT");
        assertThat(ap(free.receiptId())).isZero();
        assertThat(number("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=?", free.receiptId())).isZero();
        assertThat(arrival.registerBatch(command).items().getFirst().receiptId()).isEqualTo(free.receiptId());
        assertThatThrownBy(() -> arrival.registerBatch(batch(key, f, "0", "0.7", null)))
                .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(number("SELECT gift_received_qty FROM purchase_order_items WHERE id=?", f.orderItem()))
                .isEqualByComparingTo("0.6");
        assertThat(source(f, false).registeredGiftQty()).isEqualByComparingTo("0.4");
        passAndStock(f, free.receiptId());
        assertThat(stock(f)).isEqualByComparingTo("10.6");
        assertThat(value(f)).isEqualByComparingTo("100");

        assertThat(arrival.complete(pending).outcome()).isEqualTo("SUBMITTED_FOR_INSPECTION");
        passAndStock(f, pending);
        assertThat(stock(f)).isEqualByComparingTo("11");
        assertThat(value(f)).isEqualByComparingTo("100");
        assertThat(ap(paid.receiptId())).isEqualByComparingTo("100");
        assertThat(ap(pending)).isZero();
        assertThat(number("SELECT gift_received_qty FROM purchase_order_items WHERE id=?", f.orderItem()))
                .isEqualByComparingTo("1");
        assertThat(number("SELECT count(*) FROM procurement_arrival_exceptions WHERE receipt_id IN (?,?)", free.receiptId(), pending)).isZero();
    }

    @Test void mixedBatchQualityKeepsChargedAndGiftCostIntervalsSeparateAndReplaysExactly() {
        F f = fixture(harness.seedWorld("gift-quality-batch-" + UUID.randomUUID()));
        UUID receipt = arrival.registerBatch(batch("gift-quality-arrival-" + f.order(), f, "10", "1", null))
                .items().getFirst().receiptId();
        assertTranches(receipt, "CHARGED", "GIFT");
        var items = db.queryForList("SELECT id,quantity_tranche FROM procurement_inspection_items WHERE receipt_id=? ORDER BY quantity_tranche", receipt)
                .stream().map(row -> {
                    UUID id = (UUID) row.get("id");
                    boolean charged = "CHARGED".equals(row.get("quantity_tranche"));
                    return new BatchInspectionDecideRequest.Item(id, new BigDecimal(charged ? "10" : "1"),
                            new BigDecimal(charged ? "8" : "0.4"), new BigDecimal(charged ? "2" : "0.6"), "gift-quality-decision-" + id);
                }).toList();
        var command = new BatchInspectionReportRequest(List.of(
                new BatchInspectionReportRequest.Receipt("PURCHASE", receipt, items)), "收费与免费份额分别部分合格");
        var result = inspection.decideReport(command);
        assertThat(result.replay()).isFalse();
        assertThat(result.lineCount()).isEqualTo(2);
        assertThat(number("SELECT count(*) FROM procurement_inspection_items WHERE receipt_id=? AND status='RESOLVED'", receipt))
                .isEqualByComparingTo("2");
        assertThat(number("""
                SELECT count(*) FROM procurement_iqc_quality_consideration_parts quality
                JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
                JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
                JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id
                JOIN stock_value_events value ON value.source_doc_type='PROCUREMENT_QUALITY' AND value.source_event_id=quality.id
                WHERE inspection.receipt_id=? AND (part.quantity_tranche<>inspection.quantity_tranche
                    OR value.source_doc_id<>event.id OR value.source_item_id<>quality.id
                    OR value.qty_base<>quality.base_qty OR value.known_value_local<>quality.amount_local)
                """, receipt)).isZero();
        for (String tranche : List.of("CHARGED", "GIFT")) {
            for (String action : List.of("PASS", "FAIL")) {
                BigDecimal amount = number("""
                        SELECT sum(quality.amount_local) FROM procurement_iqc_quality_consideration_parts quality
                        JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
                        JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id
                        WHERE inspection.receipt_id=? AND inspection.quantity_tranche=? AND event.action=?
                        """, receipt, tranche, action);
                assertThat(amount).isEqualByComparingTo(tranche.equals("GIFT") ? "0" : action.equals("PASS") ? "80" : "20");
            }
        }
        List<String> before = qualityCostFacts(receipt);
        assertThat(before).hasSize(4);
        assertThat(inspection.decideReport(command).replay()).isTrue();
        assertThat(qualityCostFacts(receipt)).isEqualTo(before);
        assertThat(ap(receipt)).isEqualByComparingTo("100");
        assertThat(stock(f)).isZero();
    }

    private List<String> qualityCostFacts(UUID receipt) {
        return db.queryForList("""
                SELECT jsonb_build_object('quality',to_jsonb(quality),'value',to_jsonb(value))::text
                FROM procurement_iqc_quality_consideration_parts quality
                JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
                JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id
                JOIN stock_value_events value ON value.source_doc_type='PROCUREMENT_QUALITY' AND value.source_event_id=quality.id
                WHERE inspection.receipt_id=? ORDER BY quality.id
                """, String.class, receipt);
    }

    private F fixture(FullChainEndToEndTest.World w) {
        harness.loginAs(w.superAdminUserId());
        UUID currency = db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted", UUID.class);
        var req = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        req.setBillDate(BusinessTime.today()); req.setWarehouseId(w.warehouseId());
        var rl = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        rl.setGoodsId(w.goodsD()); rl.setUnitId(w.unitId()); rl.setUnitRate(BigDecimal.ONE);
        rl.setQty(new BigDecimal("10")); rl.setGiftQty(BigDecimal.ONE); req.setItems(List.of(rl));
        var source = requests.create(req); requests.approve(source.getId());
        UUID requestItem = source.getItems().getFirst().getId();
        UUID reviewer = harness.createUserWithPerms(w, "gift-arrival-finance-" + UUID.randomUUID(),
                "finance_order_approval:view", "finance_order_approval:approve");
        harness.loginAs(w.superAdminUserId());
        var order = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today()); order.setSupplierId(w.supplierId()); order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(currency); order.setExchangeRate(BigDecimal.ONE); order.setTaxRate(BigDecimal.ZERO);
        order.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1", UUID.class));
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(w.goodsD()); line.setUnitId(w.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("10")); line.setGiftQty(BigDecimal.ONE); line.setPrice(new BigDecimal("10"));
        line.setRequestItemId(requestItem); order.setItems(List.of(line));
        UUID id = orders.create(order).getId(); finance.submit("PURCHASE", id); harness.loginAs(reviewer);
        var approval = db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING'", id);
        UUID caseId = (UUID) approval.get("id");
        UUID claim = claims.claim("PROCUREMENT_FINANCE_APPROVE", caseId.toString()).claimId();
        finance.approveBatch(List.of(new BatchDecisionItem(caseId, ((Number) approval.get("version")).longValue(), claim)), null, BigDecimal.ONE);
        harness.loginAs(w.superAdminUserId());
        return new F(w, requestItem, id, db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?", UUID.class, id));
    }

    private WarehouseArrivalBatchRegisterRequest batch(String key, F first, String charged, String gift, F second) {
        var lines = second == null ? List.of(line(first, charged, gift)) : List.of(line(first, charged, gift), line(second, charged, gift));
        return new WarehouseArrivalBatchRegisterRequest(key, BusinessTime.today(), first.w().employeeId(),
                "收费与免费实物分开验收", false, false, lines);
    }

    private BatchArrivalLine line(F f, String charged, String gift) {
        return new BatchArrivalLine("PURCHASE", f.w().warehouseId(), null, f.w().goodsD(), new BigDecimal(charged),
                f.orderItem(), null, f.w().unitId(), BigDecimal.ONE, null, null, null, null, null, new BigDecimal(gift));
    }

    private UUID giftDraft(F f, String gift) {
        var request = new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setSupplierId(f.w().supplierId()); request.setWarehouseId(f.w().warehouseId());
        var line = new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        line.setGoodsId(f.w().goodsD()); line.setUnitId(f.w().unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ZERO); line.setGiftQty(new BigDecimal(gift)); line.setOrderItemId(f.orderItem());
        request.setItems(List.of(line));
        return receipts.create(request).getId();
    }

    private InboundExpectationItem source(F f) {
        return source(f, true);
    }

    private InboundExpectationItem source(F f, boolean canCreate) {
        UUID expectation = db.queryForObject("SELECT id FROM inbound_expectations WHERE order_type='PURCHASE' AND order_id=?", UUID.class, f.order());
        var tasks = queue.expectationsByIds(List.of(expectation));
        assertThat(tasks).hasSize(1);
        if (canCreate) assertThat(tasks.getFirst().allowedActions()).contains("CREATE_PURCHASE_RECEIPT");
        else assertThat(tasks.getFirst().allowedActions()).doesNotContain("CREATE_PURCHASE_RECEIPT");
        return tasks.getFirst().items().stream().filter(item -> item.orderItemId().equals(f.orderItem())).findFirst().orElseThrow();
    }

    private void assertTranches(UUID receipt, String... tranches) {
        assertThat(db.queryForList("SELECT quantity_tranche FROM procurement_inspection_items WHERE receipt_id=? ORDER BY quantity_tranche", String.class, receipt))
                .containsExactly(tranches);
    }

    private void passAndStock(F f, UUID receipt) {
        harness.loginAs(f.w().superAdminUserId());
        List<UUID> ids = db.queryForList("SELECT id FROM procurement_inspection_items WHERE receipt_id=? ORDER BY quantity_tranche", UUID.class, receipt);
        for (UUID id : ids) inspection.dispose("PURCHASE", receipt, id,
                new InspectionDispositionRequest("PASS", null, "收费与免费份额分别验收", "gift-arrival-pass-" + id));
        UUID keeper = ReflectionTestUtils.invokeMethod(harness, "createIqcWarehouseConfirmer", f.w(), "gift-arrival-keeper-" + receipt);
        harness.loginAs(keeper);
        for (UUID id : ids) {
            BigDecimal qty = number("SELECT received_base_qty FROM procurement_inspection_items WHERE id=?", id);
            var command = ReflectionTestUtils.<com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest>
                    invokeMethod(harness, "latestIqcStockInRequest", "PURCHASE", receipt, id, qty, "gift-arrival-stock-" + id, "GIFT-ARRIVAL-BIN");
            var result = stockIn.confirm("PURCHASE", receipt, command);
            assertThat(stockIn.confirm("PURCHASE", receipt, command).batchId()).isEqualTo(result.batchId());
        }
        harness.loginAs(f.w().superAdminUserId());
        ReflectionTestUtils.invokeMethod(harness, "drainCosts", f.w());
    }

    private BigDecimal number(String sql, Object... args) { return db.queryForObject(sql, BigDecimal.class, args); }
    private BigDecimal stock(F f) { return number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?", f.w().goodsD()); }
    private BigDecimal value(F f) { return number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id=?", f.w().goodsD()); }
    private BigDecimal ap(UUID receipt) { return number("SELECT COALESCE(SUM(amount_original_local),0) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND direction='AP'", receipt); }
}
