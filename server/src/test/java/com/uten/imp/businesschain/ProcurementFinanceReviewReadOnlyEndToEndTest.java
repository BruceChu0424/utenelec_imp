package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.order.PurchaseOrderPrintService;
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
@FinanceScopedChain
@SuppressWarnings("try")
class ProcurementFinanceReviewReadOnlyEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FinanceScopedChainDatabase.register(registry,ProcurementFinanceReviewReadOnlyEndToEndTest.class);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired PurchaseOrderPrintService prints;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    @Autowired com.uten.imp.security.TxSessionVars transactionIdentity;
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
        assertExportShowsPendingWithoutApprovalSignature(order.getId(), "草稿");
        UUID itemId = order.getItems().getFirst().getId();
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        var submitted = finance.submit("PURCHASE", order.getId());
        assertExportShowsPendingWithoutApprovalSignature(order.getId(), "等待财务审核");
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

        fixture.loginAs(w.superAdminUserId());
        assertThat(prints.read(order.getId()).id()).isEqualTo(order.getId());
        UUID outsider = fixture.createUserWithPerms(w, "purchase-print-outsider", "purchase_order:view");
        fixture.loginAs(outsider);
        assertThatThrownBy(() -> prints.read(order.getId()))
                .isInstanceOfSatisfying(ApiException.class, failure ->
                        assertThat(failure.getCode()).isEqualTo(ErrorCode.NOT_FOUND));

        fixture.loginAs(w.superAdminUserId());
        String frozenBeforeChange=db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE id=?",String.class,itemId);
        assertThatThrownBy(()->db.update("UPDATE purchase_order_items SET qty=2,amount_original=0.2,amount_local=0.2 WHERE id=?",itemId))
                .hasRootCauseInstanceOf(org.postgresql.util.PSQLException.class)
                .hasMessageContaining("frozen reference price operands are immutable without their actual source revision")
                .rootCause().isInstanceOfSatisfying(java.sql.SQLException.class,
                    sql -> assertThat(sql.getSQLState()).isEqualTo("55000"));
        assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE id=?",String.class,itemId)).isEqualTo(frozenBeforeChange);
        UUID incompleteRevision=UUID.randomUUID();
        var incompleteUpdateReached=new java.util.concurrent.atomic.AtomicBoolean();
        assertThatThrownBy(()->new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(status->{
            transactionIdentity.bind();
            db.update("""
                INSERT INTO procurement_order_source_revisions(id,order_type,order_id,order_item_id,old_qty,new_qty,unit_rate,
                    before_item,approval_attempt_before,actor_user_id,actor_employee_id)
                SELECT ?,'PURCHASE',i.order_id,i.id,i.qty,2,i.unit_rate,to_jsonb(i),
                    (SELECT COALESCE(max(attempt),0) FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=i.order_id),?,?
                FROM purchase_order_items i WHERE i.id=?
                """,incompleteRevision,w.superAdminUserId(),w.employeeId(),itemId);
            db.update("UPDATE purchase_order_items SET qty=2,amount_original=0.2,amount_local=0.2 WHERE id=?",itemId);
            incompleteUpdateReached.set(true);
        })).isInstanceOf(RuntimeException.class);
        assertThat(incompleteUpdateReached).as("a matching source proof alone cannot commit without allocation, log and reconfirmation facts").isTrue();
        assertThat(db.queryForObject("SELECT count(*) FROM procurement_order_source_revisions WHERE id=?",Integer.class,incompleteRevision)).isZero();
        assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE id=?",String.class,itemId)).isEqualTo(frozenBeforeChange);
        var changed = orders.changeQty(order.getId(), new OrderQtyChangeRequest(
                List.of(new OrderQtyChangeItem(itemId, new BigDecimal("2")))));
        assertThat(changed.getStatus()).isEqualTo((short) 1);
        assertThat(changed.getFinanceApproval().status()).isEqualTo("PENDING");
        assertThat(db.queryForObject("SELECT before_item::text FROM procurement_order_source_revisions WHERE order_item_id=? ORDER BY revision_sequence DESC LIMIT 1",String.class,itemId)).isEqualTo(frozenBeforeChange);
        assertThat(db.queryForObject("SELECT charged_base_qty FROM purchase_order_items WHERE id=?",BigDecimal.class,itemId)).isEqualByComparingTo("2");
        assertThat(db.queryForObject("SELECT gift_base_qty FROM purchase_order_items WHERE id=?",BigDecimal.class,itemId)).isZero();
        assertExportShowsPendingWithoutApprovalSignature(order.getId(), "改量待财务复核");

        fixture.loginAs(reviewer);
        var reconfirmation = changed.getFinanceApproval();
        var reconfirmationClaim = claims.claim("PROCUREMENT_FINANCE_APPROVE", reconfirmation.caseId().toString());
        finance.approveBatch(List.of(new BatchDecisionItem(reconfirmation.caseId(),
                reconfirmation.version(), reconfirmationClaim.claimId())), "复核通过", BigDecimal.ONE);
        fixture.loginAs(w.superAdminUserId());
        assertThat(new BigDecimal(prints.read(order.getId()).lines().getFirst().chargedQty()))
                .isEqualByComparingTo("2");
        orders.reverse(order.getId());
        assertExportShowsPendingWithoutApprovalSignature(order.getId(), "已反审");
    }

    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.CsvSource({"10,HALF_UP,3.3744855964","24,DOWN,3.374485596366666666666666"})
    void independentSubcontractCanBeReviewedAndRejectedWithoutChangingTotalInputOrMaterialIdentity(int creationScale,String creationRounding,String expectedPrice) throws Exception {
        var w = fixture.seedWorld("subcontract-review-readonly-"+UUID.randomUUID());
        fixture.loginAs(w.superAdminUserId());
        fixture.ensureSubcontractDirectMaterial(w, w.goodsE());
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        db.update("""
                INSERT INTO user_permission_overrides(user_id, permission_id, effect)
                SELECT ?, id, 'grant' FROM permissions WHERE code='finance_order_approval:reject'
                """, reviewer);
        // 2026-11-04 显式精度选择契约：总金额 10.1234567891 / 数量 3 除不尽，建单与送财重推
        // 参考单价(money.reference-unit-price)都须由本次操作明确保留位与取舍（真实入口经
        // X-Uten-Precision-Choices 头绑定；E2E 直调服务按 MoneyPolicy 测试同款绑定）。
        // 参考单价只是展示投影，不回乘成成交总额，下方原额断言不受该选择影响。
        try (var precision = com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of(
                "money.reference-unit-price",
                new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(creationScale, creationRounding)))) {
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
                assertThat(order.getItems().getFirst().getPrice()).isEqualByComparingTo(expectedPrice);
                String referencePolicy = db.queryForObject("SELECT reference_price_precision_policy::text FROM subcontract_order_items WHERE id=?", String.class, itemId);
                assertThat(db.queryForObject("SELECT reference_price_precision_policy#>>'{precisionPolicy,choices,money.reference-unit-price,scale}' FROM subcontract_order_items WHERE id=?", String.class, itemId))
                        .isEqualTo(Integer.toString(creationScale));
                var submitted = submitUnderDifferentPrecision("SUBCONTRACT", order.getId());
                assertThat(db.queryForObject("SELECT reference_price_precision_policy::text FROM subcontract_order_items WHERE id=?", String.class, itemId))
                        .isEqualTo(referencePolicy);
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
    }

    @Test void pendingTotalPricedPurchaseKeepsItsReviewCaseAndOriginalEvidenceAcrossAnExplicitQuantityRevision() throws Exception {
        var w = fixture.seedWorld("pending-total-policy"); fixture.loginAs(w.superAdminUserId());
        var request = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setWarehouseId(w.warehouseId()); request.setDepartmentId(w.departmentId()); request.setApplicantId(w.employeeId());
        var requested = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(w.goodsD()); requested.setUnitId(w.unitId()); requested.setUnitRate(BigDecimal.ONE); requested.setQty(new BigDecimal("10"));
        request.setItems(List.of(requested)); var source = requests.create(request); requests.approve(source.getId());
        var orderRequest = new OrderSaveRequest(); orderRequest.setBillDate(BusinessTime.today()); orderRequest.setSupplierId(w.supplierId());
        orderRequest.setWarehouseId(w.warehouseId()); orderRequest.setCurrencyId(w.currencyId()); orderRequest.setExchangeRate(BigDecimal.ONE); orderRequest.setTaxRate(BigDecimal.ZERO);
        orderRequest.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId"));
        var line = new OrderItemLine(); line.setGoodsId(w.goodsD()); line.setUnitId(w.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("3")); line.setTotalAmountInput(BigDecimal.ONE); line.setRequestItemId(source.getItems().getFirst().getId()); orderRequest.setItems(List.of(line));
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        try (var ignored = com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of(
                "money.reference-unit-price", new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(4, "HALF_UP"),
                "money.revised-total", new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(4, "HALF_UP")))) {
            var order = orders.create(orderRequest); UUID item = order.getItems().getFirst().getId();
            var pending = submitUnderDifferentPrecision("PURCHASE", order.getId()); String original = snapshot(pending.caseId());
            var changed = orders.changeQty(order.getId(), new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(item, new BigDecimal("4")))));
            var updated = changed.getFinanceApproval();
            assertThat(updated.caseId()).isEqualTo(pending.caseId()); assertThat(updated.version()).isEqualTo(pending.version()+1);
            assertThat(changed.getTotalOriginal()).isEqualByComparingTo("1.3333");
            assertThat(db.queryForObject("SELECT price FROM purchase_order_items WHERE id=?", BigDecimal.class, item)).isEqualByComparingTo("0.3333");
            assertThat(db.queryForObject("SELECT ordered_qty FROM purchase_request_items WHERE id=?", BigDecimal.class, line.getRequestItemId())).isZero();
            assertThat(db.queryForObject("SELECT event_snapshot->>'previousSubmissionSnapshot' FROM procurement_order_approval_events WHERE case_id=? AND event_type='QUANTITY_CHANGED'", String.class, pending.caseId())).isEqualTo(original);
            fixture.loginAs(reviewer); var claim = claims.claim("PROCUREMENT_FINANCE_APPROVE", updated.caseId().toString());
            try (var different = com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of(
                    "money.reference-unit-price", new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(0, "DOWN")))) {
                finance.approveBatch(List.of(new BatchDecisionItem(updated.caseId(), updated.version(), claim.claimId())), "核对原总额和改量", BigDecimal.ONE);
            }
            assertThat(db.queryForObject("SELECT ordered_qty FROM purchase_request_items WHERE id=?", BigDecimal.class, line.getRequestItemId())).isEqualByComparingTo("4");
        }
    }

    private String snapshot(UUID caseId) {
        return db.queryForObject("SELECT submission_snapshot::text FROM procurement_order_approval_cases WHERE id=?", String.class, caseId);
    }

    private FinanceApproval submitUnderDifferentPrecision(String kind, UUID order) {
        String original = db.queryForObject("SELECT current_setting('app.business_precision_choices',true)", String.class);
        FinanceApproval result;
        try (var ignored = com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of(
                "money.reference-unit-price", new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(0, "DOWN")))) {
            db.queryForObject("SELECT set_config('app.business_precision_choices',?,true)", String.class,
                    com.uten.imp.common.finance.BusinessPrecisionContext.json());
            result = finance.submit(kind, order);
        } catch (RuntimeException failure) { throw failure; }
        catch (Exception failure) { throw new IllegalStateException("Precision test scope could not close", failure); }
        db.queryForObject("SELECT set_config('app.business_precision_choices',?,true)", String.class,
                java.util.Objects.toString(original, ""));
        return result;
    }

    /**
     * 2026-10-27 起采购/委外打印与批量输出取消财务审核前提（见 docs/99-项目治理/
     * 2026-10-27-采购委外导出与差异数同步及分析恢复检查.md）：导出是只读事实快照，
     * 待审状态如实显示，财务未通过不得生成审核人签名，也不得伪称已通过。
     */
    private void assertExportShowsPendingWithoutApprovalSignature(UUID orderId, String statusLabel) {
        var document = prints.read(orderId);
        assertThat(document.financeApproved()).isFalse();
        assertThat(document.reviewerName()).isEmpty();
        assertThat(document.statusLabel()).isEqualTo(statusLabel);
    }
}
