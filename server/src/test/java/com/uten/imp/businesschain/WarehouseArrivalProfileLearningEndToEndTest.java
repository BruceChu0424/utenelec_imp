package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.*;
import static org.assertj.core.api.Assertions.*;

/** Source-bound learning shares the real arrival/receipt transaction, including retries and rollback. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false", "uten.inventory.value-work.enabled=false",
        "uten.jwt.secret=profile-learning-regression-jwt-key-0123456789", // gitleaks:allow synthetic fixture.
        "uten.crypto.pgp-master-key=profile-learning-regression-pgp-key-0123456789", // gitleaks:allow synthetic fixture.
        "uten.crypto.hmac-key=profile-learning-regression-hmac-key-0123456789",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WarehouseArrivalProfileLearningEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    private FullChainEndToEndTest harness;
    private record F(FullChainEndToEndTest.World world, UUID orderItem) {}

    @BeforeEach void prepare() { harness = new FullChainEndToEndTest(); beans.autowireBean(harness); }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test void onlyActualReceiptGoodsAreLearnedAndOriginalReplayDoesNotOverwriteLaterMaintenance() {
        F first = fixture(), second = fixture();
        String untouched = profile(first.world().goodsA());
        String existingCode = db.queryForObject("SELECT code FROM goods WHERE id=?", String.class, first.world().goodsD());
        var command = command(first, second, "SERIES-FIRST", "SERIES-SECOND");
        var result = arrivals.registerBatch(command);
        assertThat(result.groupCount()).isEqualTo(2);
        assertThat(result.replay()).isFalse();
        assertThat(profile(first.world().goodsD())).contains("SERIES-FIRST", "P-01");
        assertThat(profile(second.world().goodsD())).contains("SERIES-SECOND", "P-02");
        assertThat(db.queryForObject("SELECT code FROM goods WHERE id=?", String.class, first.world().goodsD())).isEqualTo(existingCode);
        assertThat(profile(first.world().goodsA())).isEqualTo(untouched);
        assertThat(receiptCount(first, second)).isEqualTo(2);

        db.update("UPDATE goods SET series='LATER-MAINTENANCE',version=version+1 WHERE id=?", first.world().goodsD());
        String later = profile(first.world().goodsD());
        var replay = arrivals.registerBatch(command);
        assertThat(replay.replay()).isTrue();
        assertThat(replay.items()).extracting(WarehouseArrivalBatchRegisterItem::receiptId)
                .containsExactlyElementsOf(result.items().stream().map(WarehouseArrivalBatchRegisterItem::receiptId).toList());
        assertThat(profile(first.world().goodsD())).isEqualTo(later);
        assertThat(receiptCount(first, second)).isEqualTo(2);
        var changed = new WarehouseArrivalBatchRegisterRequest(command.idempotencyKey(), command.billDate(),
                command.receiverEmployeeId(), command.remark(), false, false,
                List.of(line(first, "CHANGED", "P-01", first.world().goodsD()), line(second, "SERIES-SECOND", "P-02", second.world().goodsD())));
        assertThatThrownBy(() -> arrivals.registerBatch(changed)).isInstanceOf(ApiException.class);
        assertThat(profile(first.world().goodsD())).isEqualTo(later);
    }

    @Test void viewOnlyStaffAndForgedSourceGoodsCannotWriteProfilesOrCreateReceipts() {
        F source = fixture();
        String goods = profile(source.world().goodsD()), other = profile(source.world().goodsA());
        var command = command(source, null, "FORBIDDEN", null);
        UUID viewer = harness.createUserWithPerms(source.world(), "profile-view-" + UUID.randomUUID(), "warehouse_inbound:view");
        harness.loginAs(viewer);
        assertThatThrownBy(() -> arrivals.registerBatch(command)).isInstanceOf(AccessDeniedException.class);
        harness.loginAs(source.world().superAdminUserId());
        var forged = new WarehouseArrivalBatchRegisterRequest("profile-forged-" + UUID.randomUUID(), BusinessTime.today(),
                source.world().employeeId(), null, false, false,
                List.of(line(source, "FORGED", "OTHER", source.world().goodsA())));
        assertThatThrownBy(() -> arrivals.registerBatch(forged)).isInstanceOf(ApiException.class);
        assertThat(profile(source.world().goodsD())).isEqualTo(goods);
        assertThat(profile(source.world().goodsA())).isEqualTo(other);
        assertThat(receiptCount(source, null)).isZero();
    }

    @Test void learningFailureRollsBackEveryReceiptCommandSourceQuantityAndEarlierProfileUpdate() {
        F first = fixture(), second = fixture();
        String beforeFirst = profile(first.world().goodsD()), beforeSecond = profile(second.world().goodsD());
        var command = command(first, second, "ROLLBACK-PROFILE", "ROLLBACK-PROFILE");
        String constraint = "test_profile_" + UUID.randomUUID().toString().replace("-", "");
        UUID lastGoods = java.util.stream.Stream.of(first.world().goodsD(), second.world().goodsD())
                .max(com.uten.imp.common.util.PostgresUuidOrder.INSTANCE).orElseThrow();
        db.execute("ALTER TABLE goods ADD CONSTRAINT " + constraint + " CHECK (id<>'" + lastGoods
                + "'::uuid OR series IS DISTINCT FROM 'ROLLBACK-PROFILE')");
        try {
            assertThatThrownBy(() -> arrivals.registerBatch(command)).isInstanceOf(RuntimeException.class);
            assertThat(receiptCount(first, second)).isZero();
            assertThat(profile(first.world().goodsD())).isEqualTo(beforeFirst);
            assertThat(profile(second.world().goodsD())).isEqualTo(beforeSecond);
            assertThat(db.queryForObject("SELECT count(*) FROM warehouse_arrival_registration_commands WHERE batch_idempotency_key=?",
                    Integer.class, command.idempotencyKey())).isZero();
            for (F source : List.of(first, second)) {
                assertThat(db.queryForObject("SELECT received_qty FROM purchase_order_items WHERE id=?", BigDecimal.class, source.orderItem())).isZero();
            }
        } finally { db.execute("ALTER TABLE goods DROP CONSTRAINT " + constraint); }
    }

    private String profile(UUID goods) {
        return db.queryForObject("SELECT json_build_array(code,series,stock_place,version)::text FROM goods WHERE id=?", String.class, goods);
    }
    private int receiptCount(F first, F second) {
        return db.queryForObject("SELECT count(DISTINCT receipt_id) FROM purchase_receipt_items WHERE order_item_id=? OR order_item_id=?",
                Integer.class, first.orderItem(), second == null ? first.orderItem() : second.orderItem());
    }
    private WarehouseArrivalBatchRegisterRequest command(F first, F second, String seriesFirst, String seriesSecond) {
        return new WarehouseArrivalBatchRegisterRequest("profile-register-" + UUID.randomUUID(), BusinessTime.today(),
                first.world().employeeId(), "同事务资料学习", false, false, second == null
                ? List.of(line(first, seriesFirst, "P-01", first.world().goodsD()))
                : List.of(line(first, seriesFirst, "P-01", first.world().goodsD()), line(second, seriesSecond, "P-02", second.world().goodsD())));
    }
    private BatchArrivalLine line(F source, String series, String place, UUID goods) {
        return new BatchArrivalLine("PURCHASE", source.world().warehouseId(), null, goods, BigDecimal.ONE,
                source.orderItem(), null, source.world().unitId(), BigDecimal.ONE, null, null, null, null, null,
                BigDecimal.ZERO, new GoodsProfileLearning("MUST-NOT-REPLACE", series, place));
    }
    private F fixture() {
        var w = harness.seedWorld("profile-arrival-" + UUID.randomUUID());
        harness.loginAs(w.superAdminUserId());
        var request = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setWarehouseId(w.warehouseId());
        var requested = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(w.goodsD()); requested.setUnitId(w.unitId()); requested.setUnitRate(BigDecimal.ONE);
        requested.setQty(BigDecimal.TEN); request.setItems(List.of(requested));
        var source = requests.create(request); requests.approve(source.getId());
        UUID reviewer = harness.createUserWithPerms(w, "profile-finance-" + UUID.randomUUID(),
                "finance_order_approval:view", "finance_order_approval:approve");
        harness.loginAs(w.superAdminUserId());
        var order = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today()); order.setSupplierId(w.supplierId()); order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted", UUID.class));
        order.setExchangeRate(BigDecimal.ONE); order.setTaxRate(BigDecimal.ZERO);
        order.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1", UUID.class));
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(w.goodsD()); line.setUnitId(w.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.TEN); line.setPrice(BigDecimal.TEN); line.setRequestItemId(source.getItems().getFirst().getId());
        order.setItems(List.of(line));
        UUID orderId = orders.create(order).getId(); var submitted = finance.submit("PURCHASE", orderId);
        harness.loginAs(reviewer);
        UUID claim = claims.claim("PROCUREMENT_FINANCE_APPROVE", submitted.caseId().toString()).claimId();
        finance.approveBatch(List.of(new BatchDecisionItem(submitted.caseId(), submitted.version(), claim)), null, BigDecimal.ONE);
        harness.loginAs(w.superAdminUserId());
        return new F(w, db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?", UUID.class, orderId));
    }
}
