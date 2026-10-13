package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
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

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Approval reads submitted commercial facts; corrections return to the original business draft. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProcurementFinanceReviewReadOnlyEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired SubcontractOrderService subcontractOrders;
    FullChainEndToEndTest fixture;

    @BeforeEach void setup() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach void logout() {
        SecurityContextHolder.clearContext();
    }

    @Test void pendingPurchaseIsFrozenAndApprovalPreservesAmountsAndSourceAllocationExactlyOnce() {
        var w = fixture.seedWorld("purchase-review-readonly");
        fixture.loginAs(w.superAdminUserId());
        var request = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(w.warehouseId());
        request.setDepartmentId(w.departmentId());
        request.setApplicantId(w.employeeId());
        var requested = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(w.goodsD());
        requested.setUnitId(w.unitId());
        requested.setUnitRate(BigDecimal.ONE);
        requested.setQty(new BigDecimal("3"));
        request.setItems(List.of(requested));
        var source = requests.create(request);
        requests.approve(source.getId());

        var orderRequest = new OrderSaveRequest();
        orderRequest.setBillDate(BusinessTime.today());
        orderRequest.setSupplierId(w.supplierId());
        orderRequest.setWarehouseId(w.warehouseId());
        orderRequest.setCurrencyId(w.currencyId());
        orderRequest.setExchangeRate(BigDecimal.ONE);
        orderRequest.setTaxRate(BigDecimal.ZERO);
        orderRequest.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId"));
        var line = new OrderItemLine();
        line.setGoodsId(w.goodsD());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("3"));
        line.setPrice(new BigDecimal("0.1"));
        line.setRequestItemId(source.getItems().getFirst().getId());
        orderRequest.setItems(List.of(line));
        var order = orders.create(orderRequest);
        UUID itemId = order.getItems().getFirst().getId();
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        var submitted = finance.submit("PURCHASE", order.getId());
        String original = snapshot(submitted.caseId());

        line.setPrice(BigDecimal.ZERO);
        assertThatThrownBy(() -> orders.update(order.getId(), orderRequest)).isInstanceOf(ApiException.class);
        fixture.loginAs(reviewer);
        var claim = claims.claim("PROCUREMENT_FINANCE_APPROVE", submitted.caseId().toString());
        assertThatThrownBy(() -> orders.update(order.getId(), orderRequest))
                .isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        var review = finance.review(submitted.caseId());
        assertThat(review.allowedActions()).containsExactly("APPROVE");
        assertThat(review.items()).singleElement().satisfies(row -> {
            assertThat(row.orderItemId()).isEqualTo(itemId);
            assertThat(row.sourceItemId()).isEqualTo(line.getRequestItemId());
            assertThat(row.qty()).isEqualByComparingTo("3");
            assertThat(row.price()).isEqualByComparingTo("0.1");
        });
        assertThat(review.totalOriginal()).isEqualByComparingTo("0.3");
        assertThat(snapshot(submitted.caseId())).isEqualTo(original);
        assertThat(db.queryForObject("SELECT ordered_qty FROM purchase_request_items WHERE id=?", BigDecimal.class, line.getRequestItemId())).isZero();

        var decision = new BatchDecisionItem(submitted.caseId(), submitted.version(), claim.claimId());
        finance.approveBatch(List.of(decision), "已核对", BigDecimal.ONE);
        assertThat(snapshot(submitted.caseId())).isEqualTo(original);
        assertThat(db.queryForObject("SELECT price FROM purchase_order_items WHERE id=?", BigDecimal.class, itemId)).isEqualByComparingTo("0.1");
        assertThat(db.queryForObject("SELECT ordered_qty FROM purchase_request_items WHERE id=?", BigDecimal.class, line.getRequestItemId())).isEqualByComparingTo("3");
        assertThatThrownBy(() -> finance.approveBatch(List.of(decision), null)).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT ordered_qty FROM purchase_request_items WHERE id=?", BigDecimal.class, line.getRequestItemId())).isEqualByComparingTo("3");
        assertThat(db.queryForObject("SELECT COUNT(*) FROM procurement_order_approval_events WHERE case_id=? AND event_type='FINANCE_EDIT'", Integer.class, submitted.caseId())).isZero();
    }

    @Test void independentSubcontractCanBeReviewedAndRejectedWithoutChangingTotalInputOrMaterialIdentity() {
        var w = fixture.seedWorld("subcontract-review-readonly");
        fixture.loginAs(w.superAdminUserId());
        fixture.ensureSubcontractDirectMaterial(w, w.goodsE());
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        db.update("""
                INSERT INTO user_permission_overrides(user_id, permission_id, effect)
                SELECT ?, id, 'grant' FROM permissions WHERE code='finance_order_approval:reject'
                """, reviewer);
        fixture.withSubcontractKitStaged(w, java.util.Map.of(w.goodsE(), "3"), () -> {
            var request = new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
            request.setBillDate(BusinessTime.today());
            request.setSupplierId(w.supplierId());
            request.setWarehouseId(w.warehouseId());
            request.setCurrencyId(w.currencyId());
            request.setExchangeRate(BigDecimal.ONE);
            request.setTaxRate(BigDecimal.ZERO);
            request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId"));
            var line = new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
            line.setGoodsId(w.goodsE());
            line.setUnitId(w.unitId());
            line.setUnitRate(BigDecimal.ONE);
            line.setQty(new BigDecimal("3"));
            line.setTotalAmountInput(new BigDecimal("10.1234567891"));
            request.setItems(List.of(line));
            var order = subcontractOrders.create(request);
            UUID itemId = order.getItems().getFirst().getId();
            var submitted = finance.submit("SUBCONTRACT", order.getId());
            String original = snapshot(submitted.caseId());
            line.setTotalAmountInput(BigDecimal.ZERO);
            assertThatThrownBy(() -> subcontractOrders.update(order.getId(), request)).isInstanceOf(ApiException.class);
            fixture.loginAs(reviewer);
            var claim = claims.claim("PROCUREMENT_FINANCE_APPROVE", submitted.caseId().toString());
            assertThatThrownBy(() -> subcontractOrders.update(order.getId(), request))
                    .isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
            var review = finance.review(submitted.caseId());
            assertThat(review.allowedActions()).containsExactly("APPROVE", "REJECT");
            assertThat(review.items()).singleElement().satisfies(row -> {
                assertThat(row.orderItemId()).isEqualTo(itemId);
                assertThat(row.sourceItemId()).isNull();
                assertThat(row.qty()).isEqualByComparingTo("3");
                assertThat(row.totalAmountInput()).isEqualByComparingTo("10.1234567891");
            });
            finance.rejectBatch(List.of(new BatchDecisionItem(submitted.caseId(), submitted.version(), claim.claimId())), "请原制单人核对金额");
            assertThat(snapshot(submitted.caseId())).isEqualTo(original);
            assertThat(db.queryForObject("SELECT total_amount_input FROM subcontract_order_items WHERE id=?", BigDecimal.class, itemId)).isEqualByComparingTo("10.1234567891");
            assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?", String.class, submitted.caseId())).isEqualTo("REJECTED");
            assertThat(db.queryForObject("SELECT status FROM subcontract_orders WHERE id=?", Short.class, order.getId())).isZero();
            assertThat(db.queryForObject("SELECT COUNT(*) FROM procurement_order_approval_events WHERE case_id=? AND event_type='FINANCE_EDIT'", Integer.class, submitted.caseId())).isZero();
            return null;
        });
    }

    private String snapshot(UUID caseId) {
        return db.queryForObject("SELECT submission_snapshot::text FROM procurement_order_approval_cases WHERE id=?", String.class, caseId);
    }
}
