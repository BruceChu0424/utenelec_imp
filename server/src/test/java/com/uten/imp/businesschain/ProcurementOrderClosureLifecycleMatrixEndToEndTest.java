package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService.ClosureRequest;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.ret.PurchaseReturnService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
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
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Stage-by-stage purchase/quality/finance lifecycle; all quantities and ledgers use real commands. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", // gitleaks:allow shared synthetic fixture.
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow shared synthetic fixture.
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProcurementOrderClosureLifecycleMatrixEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired PurchaseReceiptService receipts;
    @Autowired PurchaseReturnService returns;
    @Autowired ProcurementOrderClosureService closure;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired ProcurementInspectionService inspection;
    @Autowired ProcurementIqcStockInService stockIn;
    @Autowired ProcurementArrivalControlService arrivals;
    @Autowired ProcurementIqcRejectionService rejections;
    @Autowired BusinessOutboxProcessor outbox;
    @Autowired com.uten.imp.features.notice.outbox.BusinessOutboxScheduler outboxScheduler;
    @Autowired FinancePaymentService payments;
    FullChainEndToEndTest harness;

    record F(FullChainEndToEndTest.World world,UUID reviewer,UUID quality,UUID keeper,
             UUID request,UUID source,UUID order,UUID item,UUID currency,String billNo) { }

    @BeforeEach void setup() {
        // Domain handlers remain real; advance their durable queue explicitly to keep no-write assertions deterministic.
        outboxScheduler.close();
        harness=new FullChainEndToEndTest(); beans.autowireBean(harness);
    }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @ParameterizedTest @ValueSource(strings={"DRAFT","PENDING","REJECTED","CANCELED","REVERSED"})
    void ineffectiveOrdersCannotRequestClosureAndLeaveAllDepartmentsUnchanged(String stage) {
        F f=draft("ineligible-"+stage);
        if(!stage.equals("DRAFT")) {
            var submitted=finance.submit("PURCHASE",f.order());
            if(stage.equals("REJECTED"))reject(f,submitted,"原商业资料退回");
            else if(stage.equals("CANCELED"))orders.cancel(f.order());
            else if(stage.equals("REVERSED")){approve(f,submitted);orders.reverse(f.order());}
        }
        owner(f); var preview=closure.preview("PURCHASE",f.order());
        assertThat(preview.canSubmit()).isFalse(); String before=facts(f);
        assertThatThrownBy(()->closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE","未生效单不能伪装成结束",preview.fingerprint())))
                .isInstanceOf(ApiException.class).hasMessageContaining("已生效");
        assertThat(facts(f)).isEqualTo(before);
        assertThat(number("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=? AND request_type<>'ORDER'",f.order())).isZero();
        assertThat(number("SELECT COUNT(*) FROM inbound_expectations WHERE order_id=? AND status='OPEN'",f.order())).isZero();
    }

    @ParameterizedTest @ValueSource(strings={"CLOSE","CLOSE_AND_REORDER"})
    void approvedUnreceivedOrdersReleaseExactlyTheirUndeliveredCommitment(String mode) {
        F f=approved("unreceived-"+mode); assertWarehouseVisible(f);
        var closing=requestClosure(f,mode);
        approve(f,closing); assertClosed(f);
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isZero();
        assertThat(number("SELECT SUM(released_qty) FROM procurement_order_termination_sources WHERE case_id=?",closing.caseId())).isEqualByComparingTo("10");
        assertThat(number("SELECT qty FROM purchase_order_items WHERE id=?",f.item())).isEqualByComparingTo("10");
        assertThat(number("SELECT COUNT(*) FROM purchase_receipt_items WHERE order_item_id=?",f.item())).isZero();
        assertThat(number("SELECT COUNT(*) FROM ar_ap_ledger WHERE supplier_id=?",f.world().supplierId())).isZero();
        UUID replacement=replacement(closing);
        if(mode.equals("CLOSE")) {
            assertThat(replacement).isNull();
            assertThat(requests.detail(f.request()).getItems().getFirst().getPhysicalRemainingQty()).isEqualByComparingTo("10");
        } else {
            assertThat(replacement).isNotNull(); var detail=orders.detail(replacement);
            assertThat(detail.getSupplierId()).isNull(); assertThat(detail.getStatus()).isEqualTo((short)0);
            assertThat(detail.getItems()).singleElement().satisfies(line->assertThat(line.getQty()).isEqualByComparingTo("10"));
            assertThat(requests.detail(f.request()).getItems().getFirst().getPhysicalRemainingQty()).isZero();
            assertThat(number("SELECT COUNT(*) FROM inbound_expectations WHERE order_id=?",replacement)).isZero();
        }
    }

    @ParameterizedTest @ValueSource(strings={"DELETE","COMPLETE"})
    void warehouseReceiptDraftMustBeCanceledOrActuallyInspectedBeforeClosure(String action) {
        F f=approved("receipt-draft-"+action); UUID receipt=receiptDraft(f,"4");
        assertBlocked(f,"收货草稿");
        if(action.equals("DELETE")) { owner(f);receipts.delete(receipt); }
        else {
            owner(f);receipts.approve(receipt);assertBlocked(f,"质检");
            dispose(f,receipt,"PASS","2");assertBlocked(f,"质检");
            dispose(f,receipt,"PASS",null);
        }
        var closing=requestClosure(f,"CLOSE");approve(f,closing);assertClosed(f);
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isEqualByComparingTo(action.equals("DELETE")?"0":"4");
        if(action.equals("COMPLETE")) {
            stock(f,receipt,"4");
            assertThat(number("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",f.world().goodsD())).isEqualByComparingTo("4");
        } else assertThat(number("SELECT COUNT(*) FROM procurement_inspection_items WHERE receipt_id=?",receipt)).isZero();
    }

    @ParameterizedTest @ValueSource(strings={"DELETE","APPROVE"})
    void businessReturnDraftMustFinishOrBeDeletedBeforeTheReviewedNetReceiptIsFinal(String action) {
        F f=approved("return-draft-"+action);UUID receipt=received(f,"4");dispose(f,receipt,"PASS",null);stock(f,receipt,"4");
        owner(f);UUID returned=returns.create(returnRequest(f,receipt,"1")).getId();assertBlocked(f,"退货草稿");
        owner(f);if(action.equals("DELETE"))returns.delete(returned);else returns.approve(returned);
        var closing=requestClosure(f,"CLOSE");approve(f,closing);assertClosed(f);
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isEqualByComparingTo(action.equals("DELETE")?"4":"3");
        assertThat(number("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",f.world().goodsD())).isEqualByComparingTo(action.equals("DELETE")?"4":"3");
        if(action.equals("APPROVE")) {
            String before=facts(f);assertThatThrownBy(()->returns.reverse(returned)).isInstanceOf(ApiException.class).hasMessageContaining("结束");
            assertThat(facts(f)).isEqualTo(before);
        }
    }

    @Test void pendingPartialAndFailedQualityCannotBeSkippedAndFinancialCreditSurvivesTheOrderClosure() {
        F f=approved("quality-stages");UUID receipt=received(f,"4");assertBlocked(f,"质检");
        dispose(f,receipt,"PASS","1");assertBlocked(f,"质检");
        dispose(f,receipt,"FAIL","1");assertBlocked(f,"质检");
        dispose(f,receipt,"PASS",null);UUID rejection=awaitRejection(f,receipt);assertBlocked(f,"实物退回");
        owner(f);var returnCommand=new ProcurementIqcRejectionContracts.RecordReturnRequest(caseVersion(rejection),UUID.randomUUID(),
                "MATRIX-RET-"+rejection,BusinessTime.today(),"品质确认后仓库实际退回不合格的一件");
        rejections.recordReturn(rejection,returnCommand);
        var preview=closure.preview("PURCHASE",f.order());assertThat(preview.canSubmit()).isTrue();
        assertThat(preview.items()).singleElement().satisfies(line->assertThat(line.remainingQty()).isEqualByComparingTo("7"));
        var closing=requestClosure(f,"CLOSE");approve(f,closing);assertClosed(f);
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isEqualByComparingTo("3");
        assertThat(number("SELECT SUM(amount_original_local) FROM ar_ap_ledger WHERE supplier_id=? AND direction='AP' AND status=1",f.world().supplierId())).isEqualByComparingTo("40");
        harness.loginAs(f.reviewer());
        assertThat(rejections.detail(rejection).caseItem().allowedActions()).contains("CONFIRM_CREDIT");
        assertThat(rejections.list("PURCHASE","RETURN_RECORDED",f.billNo(),1,20).items()).extracting(ProcurementIqcRejectionContracts.CaseItem::id).contains(rejection);
        confirmCredit(f,rejection,"1","10");
        assertThat(rejections.detail(rejection).caseItem().status()).isEqualTo("CREDIT_CONFIRMED");
        owner(f);assertThat(number("SELECT SUM(amount_original_local) FROM ar_ap_ledger WHERE supplier_id=? AND direction='AP' AND status=1",f.world().supplierId())).isEqualByComparingTo("30");
        String before=facts(f);rejections.recordReturn(rejection,returnCommand);assertThat(facts(f)).isEqualTo(before);
        assertThatThrownBy(()->rejections.recordReturn(rejection,new ProcurementIqcRejectionContracts.RecordReturnRequest(caseVersion(rejection),UUID.randomUUID(),
                "MATRIX-DOUBLE-RET",BusinessTime.today(),"结束后不能再改实物基数"))).isInstanceOf(ApiException.class).hasMessageContaining("结束");
        assertThat(facts(f)).isEqualTo(before);
        stock(f,receipt,"3");assertThat(number("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",f.world().goodsD())).isEqualByComparingTo("3");
    }

    @Test void allFailedGoodsActuallyReturnedMakeTheWholeOriginalQuantityAvailableForAReplacementDraft() {
        F f=approved("all-iqc-returned");UUID receipt=received(f,"4");dispose(f,receipt,"FAIL",null);
        UUID rejection=awaitRejection(f,receipt);assertBlocked(f,"实物退回");recordReturn(f,rejection);
        var closing=requestClosure(f,"CLOSE_AND_REORDER");approve(f,closing);assertClosed(f);
        UUID replacement=replacement(closing);assertThat(orders.detail(replacement).getItems()).singleElement().satisfies(line->assertThat(line.getQty()).isEqualByComparingTo("10"));
        assertThat(number("SELECT received_qty FROM purchase_order_items WHERE id=?",f.item())).isEqualByComparingTo("4");
        assertThat(number("SELECT returned_qty FROM purchase_order_items WHERE id=?",f.item())).isZero();
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isZero();
        assertThat(number("SELECT COUNT(*) FROM procurement_iqc_rejection_cases WHERE id=? AND status='RETURN_RECORDED'",rejection)).isEqualByComparingTo("1");
        assertThat(number("SELECT SUM(amount_original_local) FROM ar_ap_ledger WHERE supplier_id=? AND direction='AP' AND status=1",f.world().supplierId())).isEqualByComparingTo("40");
    }

    @Test void reversingAnIqcPhysicalReturnAfterAPreviewRequiresRecheckingAndCannotRepeatAfterDirectCompletion() {
        F f=approved("iqc-return-reversal");UUID receipt=received(f,"4");dispose(f,receipt,"FAIL","2");dispose(f,receipt,"PASS",null);
        UUID rejection=awaitRejection(f,receipt);recordReturn(f,rejection);long firstReturnVersion=caseVersion(rejection);var preview=closure.preview("PURCHASE",f.order());
        owner(f);rejections.reverseReturn(rejection,new ProcurementIqcRejectionContracts.ReverseRequest(caseVersion(rejection),UUID.randomUUID(),"实物退回凭证需重新核对，先撤销登记"));
        String changed=facts(f);
        assertThatThrownBy(()->closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE","旧实退凭证",preview.fingerprint())))
                .isInstanceOf(ApiException.class);
        assertThat(facts(f)).isEqualTo(changed);
        owner(f);assertBlocked(f,"实物退回");var returnAgain=recordReturn(f,rejection);
        assertThat(caseVersion(rejection)).isEqualTo(firstReturnVersion+2);
        assertThat(number("SELECT COUNT(*) FROM business_outbox WHERE aggregate_id=? AND event_type='PROCUREMENT_IQC_REJECTION_RETURNED'",rejection)).isEqualByComparingTo("2");
        assertThat(number("SELECT COUNT(DISTINCT payload->>'version') FROM business_outbox WHERE aggregate_id=? AND event_type='PROCUREMENT_IQC_REJECTION_RETURNED'",rejection)).isEqualByComparingTo("2");
        assertThat(number("SELECT COUNT(DISTINCT dedupe_key) FROM business_outbox WHERE aggregate_id=? AND event_type='PROCUREMENT_IQC_REJECTION_RETURNED'",rejection)).isEqualByComparingTo("2");
        String replayBefore=facts(f);rejections.recordReturn(rejection,returnAgain);assertThat(facts(f)).isEqualTo(replayBefore);
        assertThat(number("SELECT COUNT(*) FROM business_outbox WHERE aggregate_id=? AND event_type='PROCUREMENT_IQC_REJECTION_RETURNED'",rejection)).isEqualByComparingTo("2");
        approve(f,requestClosure(f,"CLOSE"));assertClosed(f);
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isEqualByComparingTo("2");
        String stopped=facts(f);
        assertThatThrownBy(()->rejections.reverseReturn(rejection,new ProcurementIqcRejectionContracts.ReverseRequest(caseVersion(rejection),UUID.randomUUID(),"结束后旧页面再次撤销")))
                .isInstanceOf(ApiException.class).hasMessageContaining("结束");
        assertThat(facts(f)).isEqualTo(stopped);
    }

    @Test void closingFutureDeliveryDoesNotErasePostedPayablesActualPaymentBankFlowOrGeneralLedger() {
        F f=approved("paid-partial");UUID receipt=received(f,"4");dispose(f,receipt,"PASS",null);stock(f,receipt,"4");owner(f);harness.seedChartOfAccounts();
        UUID bankStyle=UUID.randomUUID(),account=UUID.randomUUID();String suffix=account.toString().substring(0,8).toUpperCase(java.util.Locale.ROOT);
        db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,'ACCOUNT',0,'使用')",bankStyle,"MXB"+suffix,"链路矩阵银行科目"+suffix);
        db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id,init_balance,balance_current) VALUES(?,?,?,'BANK',?,'使用',?,500,500)",account,"MXA"+suffix,"链路矩阵银行账户"+suffix,f.currency(),bankStyle);
        UUID ap=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_id=? AND source_doc_type='PURCHASE_RECEIPT' AND status=1",UUID.class,receipt);
        var pay=new FinancePaymentSaveRequest();pay.setBillDate(BusinessTime.today());pay.setCreateIdempotencyKey("closure-matrix-pay-"+UUID.randomUUID());
        pay.setSupplierId(f.world().supplierId());pay.setAccountId(account);pay.setCurrencyId(f.currency());pay.setExchangeRate(BigDecimal.ONE);
        pay.setAmountOriginal(new BigDecimal("20"));pay.setAccountCurrencyId(f.currency());pay.setAccountAmount(new BigDecimal("20"));pay.setBankFeeAccountAmount(BigDecimal.ZERO);
        pay.setBankReference("MATRIX-BANK-"+suffix);pay.setBankBookedAt(OffsetDateTime.now());
        var applied=new FinancePaymentLineInput();applied.setAppliedLedgerId(ap);applied.setSupplierId(f.world().supplierId());applied.setAmountOriginal(new BigDecimal("20"));pay.setItems(List.of(applied));
        UUID payment=payments.create(pay).getId();harness.loginAs(f.reviewer());payments.approve(payment);owner(f);
        assertThat(number("SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ap)).isEqualByComparingTo("20");
        assertThat(number("SELECT balance_current FROM accounts WHERE id=?",account)).isEqualByComparingTo("480");
        assertThat(number("SELECT SUM(out_amount) FROM finance_reconciliations WHERE source_doc_type='PAYMENT' AND source_doc_id=?",payment)).isEqualByComparingTo("20");
        assertThat(number("SELECT COUNT(*) FROM gl_vouchers WHERE source_doc_id=? AND status=1 AND NOT is_deleted",payment)).isPositive();
        String financial=financialFacts(f,account,payment);
        var closing=requestClosure(f,"CLOSE");approve(f,closing);assertClosed(f);
        assertThat(financialFacts(f,account,payment)).isEqualTo(financial);
        assertThat(number("SELECT amount_received_original FROM ar_ap_ledger WHERE id=?",ap)).isEqualByComparingTo("20");
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isEqualByComparingTo("4");
        assertThat(number("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",f.world().goodsD())).isEqualByComparingTo("4");
    }

    @ParameterizedTest @ValueSource(strings={"RECEIPT_APPROVAL","STOCK_IN","RECEIPT_REVERSE","PRODUCT_RETURN"})
    void departmentProgressAfterPreviewInvalidatesTheFingerprintWithoutLosingTheNewFacts(String action) {
        F f=approved("pending-change-"+action);UUID receipt=received(f,"4");dispose(f,receipt,"PASS",null);
        if(action.equals("PRODUCT_RETURN"))stock(f,receipt,"4");
        var preview=closure.preview("PURCHASE",f.order());
        switch(action) {
            case "RECEIPT_APPROVAL"->{UUID additional=received(f,"1");dispose(f,additional,"PASS",null);}
            case "STOCK_IN"->stock(f,receipt,"4");
            case "RECEIPT_REVERSE"->{owner(f);receipts.reverse(receipt);}
            case "PRODUCT_RETURN"->{owner(f);returns.approve(returns.create(returnRequest(f,receipt,"1")).getId());}
            default->throw new IllegalArgumentException(action);
        }
        owner(f);String before=facts(f);
        assertThatThrownBy(()->closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE","各部门已继续处理",preview.fingerprint())))
                .isInstanceOf(ApiException.class).hasMessageContaining("变化");
        assertThat(facts(f)).isEqualTo(before);assertThat(orderClosed(f)).isFalse();
        owner(f);assertThat(closure.preview("PURCHASE",f.order()).canSubmit()).isTrue();
        var resubmitted=requestClosure(f,"CLOSE");approve(f,resubmitted);assertClosed(f);
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void directlyClosedOriginalOrderCannotBeReversedRegardlessOfTheOldClientClaimFlag(boolean claimed) {
        F f=approved("reverse-claim-"+claimed);var closing=requestClosure(f,"CLOSE");
        owner(f);String before=facts(f);
        assertThatThrownBy(()->orders.reverse(f.order())).isInstanceOf(ApiException.class);
        assertThat(facts(f)).isEqualTo(before);
        assertThat(orders.detail(f.order()).getStatus()).isEqualTo((short)1);
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,closing.caseId())).isEqualTo("APPROVED");
        assertThat(number("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=? AND status='PENDING'",f.order())).isZero();
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isZero();
        assertThat(number("SELECT COUNT(*) FROM inbound_expectations WHERE order_id=? AND status='OPEN'",f.order())).isZero();
    }

    @Test void oldPendingClosureMustBeRecheckedByBuyerAndCannotBeDecidedByFinance() {
        F f=approved("legacy-closure-followup");
        var closing=LegacyProcurementClosureFixture.pending(db,closure.preview("PURCHASE",f.order()),f.world(),"CLOSE_AND_REORDER");
        assertWarehouseVisible(f);assertThat(orderClosed(f)).isFalse();
        harness.loginAs(f.reviewer());
        assertThatThrownBy(()->finance.approveBatch(List.of(new BatchDecisionItem(closing.caseId(),closing.version())),null)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->finance.rejectBatch(List.of(new BatchDecisionItem(closing.caseId(),closing.version())),"旧页退回")).isInstanceOf(ApiException.class);
        owner(f);
        assertThat(db.queryForObject("SELECT fn_procurement_order_latest_approval_status('PURCHASE',?)",String.class,f.order())).isEqualTo("APPROVED");
        UUID receipt=received(f,"2");dispose(f,receipt,"PASS",null);stock(f,receipt,"2");
        assertThat(number("SELECT received_qty FROM purchase_order_items WHERE id=?",f.item())).isEqualByComparingTo("2");
        var second=requestClosure(f,"CLOSE_AND_REORDER");approve(f,second);assertClosed(f);
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,closing.caseId())).isEqualTo("CANCELED");
        assertThat(orders.detail(replacement(second)).getItems()).singleElement().satisfies(line->assertThat(line.getQty()).isEqualByComparingTo("8"));
    }

    @Test void repeatedFinanceDecisionAndOldWarehousePageCannotChangeADirectlyCompletedClosure() {
        F f=approved("repeat-old-page");UUID expectation=db.queryForObject("SELECT id FROM inbound_expectations WHERE order_id=? AND status='OPEN'",UUID.class,f.order());
        assertThat(arrivals.expectationsByIds(List.of(expectation))).hasSize(1);
        var closing=requestClosure(f,"CLOSE_AND_REORDER");harness.loginAs(f.reviewer());var decision=new BatchDecisionItem(closing.caseId(),closing.version());
        owner(f);assertClosed(f);UUID replacement=replacement(closing);String before=facts(f);
        harness.loginAs(f.reviewer());assertThatThrownBy(()->finance.approveBatch(List.of(decision),null)).isInstanceOf(ApiException.class);owner(f);
        assertThatThrownBy(()->receipts.create(receiptRequest(f,"1"))).isInstanceOf(ApiException.class).hasMessageContaining("结束");
        assertThatThrownBy(()->arrivals.expectationsByIds(List.of(expectation))).isInstanceOf(ApiException.class);
        assertThat(facts(f)).isEqualTo(before);assertThat(replacement(closing)).isEqualTo(replacement);
        assertThat(number("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=? AND request_type='CLOSE_AND_REORDER' AND status='APPROVED'",f.order())).isEqualByComparingTo("1");
    }

    @Test void qualityCompletingAfterAnOldPreviewRequiresANewQuantityReviewEvenBeforeSubmission() {
        F f=approved("quality-old-preview");UUID receipt=received(f,"4");var before=closure.preview("PURCHASE",f.order());
        assertThat(before.canSubmit()).isFalse();dispose(f,receipt,"PASS",null);String facts=facts(f);
        assertThatThrownBy(()->closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE","使用检验前旧预览",before.fingerprint())))
                .isInstanceOf(ApiException.class).hasMessageContaining("变化");assertThat(facts(f)).isEqualTo(facts);
        approve(f,requestClosure(f,"CLOSE"));assertClosed(f);
    }

    private F draft(String tag) {
        var w=harness.seedWorld("closure-matrix-"+tag+"-"+UUID.randomUUID());owner(w);
        UUID reviewer=harness.createUserWithPerms(w,"matrix-finance-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve","finance_order_approval:reject",
                "finance:view:all","finance_payment:view","finance_payment:approve","procurement_iqc_rejection:view","procurement_iqc_rejection:confirm_credit","procurement_iqc_rejection:amount:view");
        UUID quality=harness.createUserWithPerms(w,"matrix-quality-"+UUID.randomUUID(),"procurement_inspection:view","procurement_inspection:handle");
        UUID keeper=harness.createUserWithPerms(w,"matrix-warehouse-"+UUID.randomUUID(),"warehouse_iqc_stock_in:view","warehouse_iqc_stock_in:confirm");owner(w);
        var req=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();req.setBillDate(BusinessTime.today());req.setWarehouseId(w.warehouseId());
        var demand=new com.uten.imp.features.purchase.request.dto.RequestItemLine();demand.setGoodsId(w.goodsD());demand.setUnitId(w.unitId());demand.setUnitRate(BigDecimal.ONE);demand.setQty(BigDecimal.TEN);
        req.setItems(List.of(demand));var source=requests.create(req);requests.approve(source.getId());UUID sourceItem=source.getItems().getFirst().getId();
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.TEN);line.setPrice(BigDecimal.TEN);line.setRequestItemId(sourceItem);order.setItems(List.of(line));var saved=orders.create(order);
        return new F(w,reviewer,quality,keeper,source.getId(),sourceItem,saved.getId(),saved.getItems().getFirst().getId(),currency,saved.getBillNo());
    }
    private F approved(String tag){F f=draft(tag);approve(f,finance.submit("PURCHASE",f.order()));return f;}
    private void owner(F f){owner(f.world());}private void owner(FullChainEndToEndTest.World w){harness.loginAs(w.superAdminUserId());}
    private FinanceApproval requestClosure(F f,String mode){owner(f);var preview=closure.preview("PURCHASE",f.order());assertThat(preview.canSubmit()).withFailMessage("%s",preview.blockReason()).isTrue();return closure.submit("PURCHASE",f.order(),new ClosureRequest(mode,"按当前真实执行事实申请结束",preview.fingerprint()));}
    private BatchDecisionItem decision(FinanceApproval item){var claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",item.caseId().toString());return new BatchDecisionItem(item.caseId(),item.version(),claim.claimId());}
    private void approve(F f,FinanceApproval item){if("APPROVED".equals(item.status()))return;harness.loginAs(f.reviewer());finance.approveBatch(List.of(decision(item)),null,BigDecimal.ONE);owner(f);}
    private void reject(F f,FinanceApproval item,String reason){harness.loginAs(f.reviewer());finance.rejectBatch(List.of(decision(item)),reason);owner(f);}
    private UUID replacement(FinanceApproval closing){return db.queryForObject("SELECT replacement_order_id FROM procurement_order_approval_cases WHERE id=?",UUID.class,closing.caseId());}
    private boolean orderClosed(F f){return Boolean.TRUE.equals(db.queryForObject("SELECT is_closed FROM purchase_orders WHERE id=?",Boolean.class,f.order()));}
    private void assertClosed(F f){owner(f);assertThat(orderClosed(f)).isTrue();assertThat(number("SELECT COUNT(*) FROM inbound_expectations WHERE order_id=? AND status='OPEN'",f.order())).isZero();assertThat(orders.detail(f.order()).isCanReverse()).isFalse();}
    private void assertWarehouseVisible(F f){owner(f);assertThat(arrivals.expectations(1,50,"PURCHASE",null,f.world().supplierId()).getItems()).extracting(row->row.orderId()).contains(f.order());}
    private void assertBlocked(F f,String text){owner(f);var preview=closure.preview("PURCHASE",f.order());assertThat(preview.canSubmit()).isFalse();assertThat(preview.blockReason()).contains(text);String before=facts(f);assertThatThrownBy(()->closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE","仍有其他部门待处理",preview.fingerprint()))).isInstanceOf(ApiException.class).hasMessageContaining(text);assertThat(facts(f)).isEqualTo(before);}
    private com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest receiptRequest(F f,String qty){var req=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();req.setBillDate(BusinessTime.today());req.setSupplierId(f.world().supplierId());req.setWarehouseId(f.world().warehouseId());var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setGoodsId(f.world().goodsD());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setOrderItemId(f.item());req.setItems(List.of(line));return req;}
    private UUID receiptDraft(F f,String qty){owner(f);return receipts.create(receiptRequest(f,qty)).getId();}
    private UUID received(F f,String qty){UUID id=receiptDraft(f,qty);receipts.approve(id);return id;}
    private UUID inspection(UUID receipt){return db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?",UUID.class,receipt);}
    private void dispose(F f,UUID receipt,String action,String qty){harness.loginAs(f.quality());inspection.dispose("PURCHASE",receipt,inspection(receipt),new InspectionDispositionRequest(action,qty==null?null:new BigDecimal(qty),action.equals("FAIL")?"按实检记录不合格":"按实检记录合格","matrix-iqc-"+UUID.randomUUID()));owner(f);}
    private void stock(F f,UUID receipt,String qty){
        harness.loginAs(f.keeper());var detail=stockIn.detail("PURCHASE",receipt);BigDecimal remaining=new BigDecimal(qty);
        var confirmed=new java.util.ArrayList<ProcurementIqcStockInContracts.ConfirmItem>();UUID inspectionId=inspection(receipt);
        for(var slice:detail.items()) {
            if(!inspectionId.equals(slice.inspectionItemId())||slice.remainingBaseQty().signum()<=0||remaining.signum()<=0)continue;
            BigDecimal quantity=remaining.min(slice.remainingBaseQty());
            confirmed.add(new ProcurementIqcStockInContracts.ConfirmItem(slice.passEventId(),quantity,slice.remainingBaseQty(),"MATRIX-BIN",f.world().warehouseId()));
            remaining=remaining.subtract(quantity);
        }
        assertThat(remaining).as("Requested stock-in must be covered by the actual PASS event slices").isZero();
        assertThat(confirmed).isNotEmpty();
        stockIn.confirm("PURCHASE",receipt,new ProcurementIqcStockInContracts.ConfirmRequest("matrix-stock-"+UUID.randomUUID(),confirmed));
        owner(f);ReflectionTestUtils.invokeMethod(harness,"drainCosts",f.world());
    }
    private com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest returnRequest(F f,UUID receipt,String qty){var req=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();req.setBillDate(BusinessTime.today());req.setSupplierId(f.world().supplierId());req.setWarehouseId(f.world().warehouseId());var line=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();line.setGoodsId(f.world().goodsD());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setOrderItemId(f.item());line.setReceiptItemId(receipts.detail(receipt).getItems().getFirst().getId());req.setItems(List.of(line));return req;}
    private UUID awaitRejection(F f,UUID receipt){owner(f);for(int n=0;n<2000;n++){var ids=db.queryForList("SELECT id FROM procurement_iqc_rejection_cases WHERE receipt_type='PURCHASE' AND receipt_id=? AND NOT is_deleted",UUID.class,receipt);if(!ids.isEmpty()){for(int drain=0;drain<2000&&outbox.processNext();drain++){}owner(f);return ids.getFirst();}outbox.processNext();}throw new AssertionError("IQC不合格事件没有投影案件");}
    private long caseVersion(UUID rejection){return db.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",Long.class,rejection);}
    private ProcurementIqcRejectionContracts.RecordReturnRequest recordReturn(F f,UUID rejection){owner(f);var request=new ProcurementIqcRejectionContracts.RecordReturnRequest(caseVersion(rejection),UUID.randomUUID(),"MATRIX-RETURN-"+rejection,BusinessTime.today(),"不合格实物已经实际退给供应商");rejections.recordReturn(rejection,request);return request;}
    private void confirmCredit(F f,UUID rejection,String qty,String amount){harness.loginAs(f.reviewer());long version=caseVersion(rejection);UUID ap=db.queryForObject("SELECT source_ap_ledger_id FROM procurement_iqc_rejection_cases WHERE id=?",UUID.class,rejection);var allocation=new ProcurementIqcRejectionContracts.ActualCreditAllocation(rejection,version,new BigDecimal(qty),new BigDecimal(amount));var draft=new ProcurementIqcRejectionContracts.ConfirmCreditRequest(version,UUID.randomUUID(),"MATRIX-CREDIT-"+rejection,BusinessTime.today(),"按供应商实际贷项单确认金额",new BigDecimal(qty),new BigDecimal(amount),ap,List.of(allocation));var preview=rejections.previewCredit(rejection,draft);rejections.confirmCredit(rejection,new ProcurementIqcRejectionContracts.ConfirmCreditRequest(version,draft.commandId(),draft.creditReference(),draft.creditDate(),draft.reason(),draft.baseQty(),draft.actualAmountOriginal(),ap,draft.allocations(),preview.bookAllocationHash()));}
    private BigDecimal number(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
    private String table(String table,String column,UUID id){return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY fact.id),'[]'::jsonb)::text FROM "+table+" fact WHERE fact."+column+"=?",String.class,id);}
    private String cases(F f,String table){return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY fact.id),'[]'::jsonb)::text FROM "+table+" fact WHERE fact.case_id IN(SELECT id FROM procurement_order_approval_cases WHERE order_id=?)",String.class,f.order());}
    private String facts(F f){return table("purchase_orders","id",f.order())+table("purchase_order_items","order_id",f.order())+table("purchase_request_items","id",f.source())
            +table("purchase_order_item_sources","order_item_id",f.item())
            +table("purchase_receipts","supplier_id",f.world().supplierId())+table("purchase_receipt_items","order_item_id",f.item())+table("purchase_returns","supplier_id",f.world().supplierId())+table("purchase_return_items","order_item_id",f.item())
            +table("procurement_inspection_items","goods_id",f.world().goodsD())+table("procurement_iqc_rejection_cases","order_item_id",f.item())+table("stock_balances","goods_id",f.world().goodsD())+table("stock_movements","goods_id",f.world().goodsD())
            +table("ar_ap_ledger","supplier_id",f.world().supplierId())+table("procurement_order_approval_cases","order_id",f.order())+cases(f,"procurement_order_approval_events")+cases(f,"procurement_order_termination_sources")+table("inbound_expectations","order_id",f.order())
            +db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(event) ORDER BY event.id),'[]'::jsonb)::text FROM procurement_inspection_events event JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.goods_id=?",String.class,f.world().goodsD());}
    private String financialFacts(F f,UUID account,UUID payment){return table("ar_ap_ledger","supplier_id",f.world().supplierId())+table("accounts","id",account)+table("finance_payments","id",payment)+table("finance_payment_lines","payment_id",payment)+table("finance_reconciliations","source_doc_id",payment)+table("gl_vouchers","source_doc_id",payment)+db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(entry) ORDER BY entry.id),'[]'::jsonb)::text FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id=?",String.class,payment);}
}
