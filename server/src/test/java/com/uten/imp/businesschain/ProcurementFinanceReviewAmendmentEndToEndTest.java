package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProcurementFinanceReviewAmendmentEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired com.uten.imp.features.sales.order.SalesOrderService salesOrders;
    @Autowired com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService salesFinance;
    @Autowired com.uten.imp.features.subcontract.order.SubcontractOrderService subcontractOrders;
    FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}

    @Test void financeEditKeepsSourceIdentityAndHistoricalAmountsThenApprovesExactlyOnce() {
        var w=fixture.seedWorld("review-amend"); fixture.loginAs(w.superAdminUserId());
        var request=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today());request.setWarehouseId(w.warehouseId());
        request.setDepartmentId(w.departmentId());request.setApplicantId(w.employeeId());
        var requested=new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(w.goodsD());requested.setUnitId(w.unitId());requested.setUnitRate(BigDecimal.ONE);requested.setQty(new BigDecimal("3"));
        request.setItems(List.of(requested));var source=requests.create(request);requests.approve(source.getId());
        var orderRequest=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        orderRequest.setBillDate(BusinessTime.today());orderRequest.setSupplierId(w.supplierId());orderRequest.setWarehouseId(w.warehouseId());
        orderRequest.setCurrencyId(w.currencyId());orderRequest.setExchangeRate(BigDecimal.ONE);orderRequest.setTaxRate(BigDecimal.ZERO);
        orderRequest.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("3"));line.setPrice(new BigDecimal("0.1"));line.setRequestItemId(source.getItems().getFirst().getId());
        orderRequest.setItems(List.of(line));var order=orders.create(orderRequest);UUID item=order.getItems().getFirst().getId();
        UUID reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",w);
        var submitted=finance.submit("PURCHASE",order.getId());fixture.loginAs(reviewer);
        var claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",submitted.caseId().toString());
        String original=db.queryForObject("SELECT submission_snapshot::text FROM procurement_order_approval_cases WHERE id=?",String.class,submitted.caseId());
        assertThatThrownBy(() -> finance.amend(submitted.caseId(),new ProcurementApprovalContracts.ReviewAmendmentRequest(submitted.version(),UUID.randomUUID(),
                List.of(new ProcurementApprovalContracts.ReviewAmountEdit(item,BigDecimal.ZERO,null))))).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> finance.amend(submitted.caseId(),new ProcurementApprovalContracts.ReviewAmendmentRequest(submitted.version(),claim.claimId(),
                List.of(new ProcurementApprovalContracts.ReviewAmountEdit(UUID.randomUUID(),BigDecimal.ZERO,null))))).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,submitted.caseId())).isEqualTo("PENDING");
        assertThat(db.queryForObject("SELECT price FROM purchase_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("0.1");
        var amended=finance.amend(submitted.caseId(),new ProcurementApprovalContracts.ReviewAmendmentRequest(submitted.version(),claim.claimId(),
                List.of(new ProcurementApprovalContracts.ReviewAmountEdit(item,new BigDecimal("0.1234567891"),null))));
        assertThat(amended.caseId()).isNotEqualTo(submitted.caseId());assertThat(amended.attempt()).isEqualTo(submitted.attempt()+1);
        assertThat(amended.totalOriginal()).isEqualByComparingTo("0.3703703673");
        assertThat(amended.previousItems()).singleElement().satisfies(old -> assertThat(old.price()).isEqualByComparingTo("0.1"));
        assertThat(db.queryForObject("SELECT submission_snapshot::text FROM procurement_order_approval_cases WHERE id=?",String.class,submitted.caseId())).isEqualTo(original);
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,submitted.caseId())).isEqualTo("CANCELED");
        assertThat(db.queryForObject("SELECT request_item_id FROM purchase_order_items WHERE id=?",UUID.class,item)).isEqualTo(line.getRequestItemId());
        assertThat(db.queryForObject("SELECT qty FROM purchase_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("3");
        assertThat(db.queryForObject("SELECT ordered_qty FROM purchase_request_items WHERE id=?",BigDecimal.class,line.getRequestItemId())).isZero();
        assertThatThrownBy(() -> finance.approveBatch(List.of(new ProcurementApprovalContracts.BatchDecisionItem(submitted.caseId(),submitted.version(),claim.claimId())),null)).isInstanceOf(ApiException.class);
        var newClaim=claims.claim("PROCUREMENT_FINANCE_APPROVE",amended.caseId().toString());
        var decision=new ProcurementApprovalContracts.BatchDecisionItem(amended.caseId(),amended.version(),newClaim.claimId());
        finance.approveBatch(List.of(decision),null);
        assertThat(db.queryForObject("SELECT ordered_qty FROM purchase_request_items WHERE id=?",BigDecimal.class,line.getRequestItemId())).isEqualByComparingTo("3");
        assertThatThrownBy(() -> finance.approveBatch(List.of(decision),null)).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT ordered_qty FROM purchase_request_items WHERE id=?",BigDecimal.class,line.getRequestItemId())).isEqualByComparingTo("3");
    }

    @Test void salesReviewRecalculatesMoneyRetainsReservationsAndRejectsOldRevisionAndForeignRows() {
        var w=fixture.seedWorld("sales-review-amend");fixture.loginAs(w.superAdminUserId());
        var order=salesOrders.create(fixture.orderRequest(w,w.goodsC(),"3","100"));salesOrders.approve(order.getId());
        UUID item=order.getItems().getFirst().getId();
        BigDecimal reserved=db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item);
        var claim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.getId().toString());
        var valid=new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceLineEdit(item,new BigDecimal("90.1234567891"),new BigDecimal("0.9"));
        var foreign=new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceLineEdit(UUID.randomUUID(),BigDecimal.ZERO,null);
        assertThatThrownBy(() -> salesFinance.amend(order.getId(),new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceAmendmentRequest(
                0L,claim.claimId(),List.of(valid,foreign)))).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT price FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("100");
        var amended=salesFinance.amend(order.getId(),new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceAmendmentRequest(
                0L,claim.claimId(),List.of(valid)));
        assertThat(amended.financeReviewRevision()).isEqualTo(1);
        assertThat(amended.totalOriginal()).isEqualByComparingTo(new BigDecimal("3").multiply(valid.price()).multiply(valid.discount()));
        assertThat(amended.revisionDiff()).isNotNull();
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo(reserved);
        assertThat(db.queryForObject("SELECT qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("3");
        assertThatThrownBy(() -> salesFinance.confirm(order.getId(),new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,0L,claim.claimId())))
                .isInstanceOf(ApiException.class);
        salesFinance.confirm(order.getId(),new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,1L,claim.claimId()));
        assertThat(salesFinance.review(order.getId()).financeConfirmed()).isTrue();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM sales_order_revision_logs WHERE order_id=?",Integer.class,order.getId())).isEqualTo(1);
    }

    @Test void independentSubcontractReviewAmendsTotalInputWithoutReplacingMaterialOrSourceIdentity() {
        var w=fixture.seedWorld("subcontract-review-amend");fixture.loginAs(w.superAdminUserId());
        fixture.ensureSubcontractDirectMaterial(w,w.goodsE());
        UUID reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",w);
        fixture.withSubcontractKitStaged(w,java.util.Map.of(w.goodsE(),"3"),() -> {
            var request=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
            request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
            request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
            request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));
            var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
            line.setGoodsId(w.goodsE());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("3"));
            line.setTotalAmountInput(new BigDecimal("10.1234567891"));request.setItems(List.of(line));
            var order=subcontractOrders.create(request);UUID item=order.getItems().getFirst().getId();
            var submitted=finance.submit("SUBCONTRACT",order.getId());fixture.loginAs(reviewer);
            var claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",submitted.caseId().toString());
            BigDecimal total=new BigDecimal("11.123456789123456789");
            var amended=finance.amend(submitted.caseId(),new ProcurementApprovalContracts.ReviewAmendmentRequest(
                    submitted.version(),claim.claimId(),List.of(new ProcurementApprovalContracts.ReviewAmountEdit(item,null,total))));
            assertThat(amended.totalOriginal()).isEqualByComparingTo(total);
            assertThat(amended.items()).singleElement().satisfies(row -> {
                assertThat(row.orderItemId()).isEqualTo(item);assertThat(row.sourceItemId()).isNull();
                assertThat(row.qty()).isEqualByComparingTo("3");assertThat(row.totalAmountInput()).isEqualByComparingTo(total);
            });
            assertThat(amended.previousItems()).singleElement().satisfies(row -> assertThat(row.totalAmountInput()).isEqualByComparingTo("10.1234567891"));
            var current=claims.claim("PROCUREMENT_FINANCE_APPROVE",amended.caseId().toString());
            finance.approveBatch(List.of(new ProcurementApprovalContracts.BatchDecisionItem(amended.caseId(),amended.version(),current.claimId())),null);
            assertThat(db.queryForObject("SELECT total_original FROM subcontract_orders WHERE id=?",BigDecimal.class,order.getId())).isEqualByComparingTo(total);
            return null;
        });
    }
}
