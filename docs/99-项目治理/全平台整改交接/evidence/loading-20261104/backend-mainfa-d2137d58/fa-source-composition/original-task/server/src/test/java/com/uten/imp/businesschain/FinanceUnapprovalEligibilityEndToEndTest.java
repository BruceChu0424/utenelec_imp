package com.uten.imp.businesschain;

import com.uten.imp.testsupport.FixtureDatabaseProperties;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseItemInput;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeSaveRequest;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeItemInput;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferSaveRequest;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferLineInput;
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
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.ReflectionTestUtils;
import com.uten.imp.support.MigratedSchemaBaseline;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=FinanceUnapprovalEligibilityEndToEndTest.Cleanup.class,
        mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class FinanceUnapprovalEligibilityEndToEndTest {
    // This suite intentionally leaves confirmed and closed-period documents intact.
    // Whole-period GL regeneration in other suites must see its own business facts;
    // the production guard against rebuilding confirmed vouchers remains enforced.
    private static MigratedSchemaBaseline.ScopedDatabase database;
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) throws Exception {
        database=MigratedSchemaBaseline.openDatabase("finance_unapproval_eligibility");
        FixtureDatabaseProperties.bindSameRole(registry, database::getJdbcUrl,
                database::getUsername, database::getPassword);
        try {
            var attachments=java.nio.file.Files.createTempDirectory("uten-finance-unapproval-attachments-");
            registry.add("uten.storage.local-dir",attachments::toString);
        } catch (java.io.IOException failure) {
            throw new java.io.UncheckedIOException(failure);
        }
    }
    static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder()-1; }
        @Override public void afterTestClass(TestContext ignored) throws Exception { if(database!=null)database.close(); }
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired FinanceReceiptService receipts;
    @Autowired FinancePaymentService payments;
    @Autowired FinanceExpenseService expenses;
    @Autowired FinanceOtherIncomeService incomes;
    @Autowired FinanceBankTransferService transfers;
    @Autowired com.uten.imp.features.purchase.request.PurchaseRequestService purchaseRequests;
    @Autowired com.uten.imp.features.purchase.order.PurchaseOrderService purchaseOrders;
    @Autowired com.uten.imp.features.purchase.receipt.PurchaseReceiptService purchaseReceipts;
    @Autowired com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService procurementFinance;
    private FullChainEndToEndTest harness;
    @BeforeEach void prepare() { harness=new FullChainEndToEndTest();beans.autowireBean(harness); }
    @AfterEach void clearSecurity() { SecurityContextHolder.clearContext(); }


    @Autowired com.uten.imp.features.finance.gl.GlPostingService gl;
    @Autowired com.uten.imp.features.documents.DocumentUnapprovalService unapproval;
    @Autowired com.uten.imp.features.sales.shipment.SalesShipmentService shipments;
    @Autowired com.uten.imp.features.finance.receivables.CustomerPrepaymentOffsetService offsets;
    @Autowired com.uten.imp.features.finance.payables.SupplierSettlementService supplierStatements;

    @Test void allFiveReadyPreflightsAreReadOnlyAndMatchActualAtomicUnapproval() {
        Fixture f=fixture("all-five");
        var expense=seedApprove(f,()->expenses.create(expense(f,"10")).getId(),expenses::approve);
        var income=seedApprove(f,()->incomes.create(income(f,"15")).getId(),incomes::approve);
        var receipt=seedApprove(f,()->receipts.create(receipt(f,"40")).getId(),receipts::approve);
        var pay=payment(f,"25");var payment=seedApprove(f,()->payments.create(pay).getId(),payments::approve);
        var transfer=seedApprove(f,()->transfers.create(transfer(f,"30")).getId(),transfers::approve);
        harness.loginAs(f.reviewer());
        var before=databaseFacts(f);
        for(var eligible:List.of(expenses.unapprovalEligibility(expense.getId()),incomes.unapprovalEligibility(income.getId()),
                receipts.unapprovalEligibility(receipt.getId()),payments.unapprovalEligibility(payment.getId()),transfers.unapprovalEligibility(transfer.getId()))) {
            assertThat(eligible.eligible()).as(eligible.reasons().toString()).isTrue();
            assertThat(eligible.factsSnapshot()).matches("[a-f0-9]{64}");assertThat(eligible.relatedDocuments()).isEmpty();
        }
        assertThat(databaseFacts(f)).isEqualTo(before);
        var ids=List.of(expense.getId(),income.getId(),receipt.getId(),payment.getId(),transfer.getId());
        var families=List.of("financeExpense","financeOtherIncome","financeReceipt","financePayment","financeBankTransfer");
        for(int i=0;i<ids.size();i++)unapproval.unapprove(families.get(i),ids.get(i),command("ready-"+ids.get(i)));
        assertBalance(f.bank(),"500");assertBalance(f.otherBank(),"500");
        assertThat(db.queryForObject("SELECT COUNT(*) FROM document_unapprovals WHERE original_id IN(?,?,?,?,?)",Integer.class,ids.toArray())).isEqualTo(5);
    }

    @Test void previousPeriodGeneralCashDocumentsExposeTheSameBlockAsTheWriterWithoutChangingMoney() {
        Fixture f=fixture("old-period");var old=BusinessTime.today().minusMonths(1);
        com.uten.imp.features.finance.expense.dto.FinanceExpenseDetail ei;
        com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeDetail oi;
        com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferDetail ti;
        // Generate legitimate original-period business facts, then let the business calendar advance.
        try(var calendar=org.mockito.Mockito.mockStatic(BusinessTime.class,org.mockito.Mockito.CALLS_REAL_METHODS)){
            calendar.when(BusinessTime::today).thenReturn(old);
            var e=expense(f,"10");e.setBillDate(old);ei=seedApprove(f,()->expenses.create(e).getId(),expenses::approve);
            var o=income(f,"15");o.setBillDate(old);oi=seedApprove(f,()->incomes.create(o).getId(),incomes::approve);
            var t=transfer(f,"30");t.setBillDate(old);t.getItems().getFirst().setOccurDate(old);ti=seedApprove(f,()->transfers.create(t).getId(),transfers::approve);
        }
        harness.loginAs(f.reviewer());String before=databaseFacts(f);
        for(var check:List.of(expenses.unapprovalEligibility(ei.getId()),incomes.unapprovalEligibility(oi.getId()),transfers.unapprovalEligibility(ti.getId()))) {
            assertThat(check.eligible()).isFalse();assertThat(check.reasons().getFirst().code()).isEqualTo("GL_PROJECTION_BLOCKED");
            assertThat(check.reasons().getFirst().message()).contains("会计期间");
        }
        assertThatThrownBy(()->unapproval.unapprove("financeExpense",ei.getId(),command("old-"+ei.getId()))).hasMessageContaining("会计期间");
        assertThatThrownBy(()->unapproval.unapprove("financeOtherIncome",oi.getId(),command("old-"+oi.getId()))).hasMessageContaining("会计期间");
        assertThatThrownBy(()->unapproval.unapprove("financeBankTransfer",ti.getId(),command("old-"+ti.getId()))).hasMessageContaining("会计期间");
        assertThat(databaseFacts(f)).isEqualTo(before);
    }

    @Test void confirmedExpenseIsBlockedBeforeAndAfterAttemptedUnapproval() {
        Fixture f=fixture("confirmed");var e=seedApprove(f,()->expenses.create(expense(f,"10")).getId(),expenses::approve);
        harness.loginAs(f.world().superAdminUserId());expenses.glConfirm(e.getId());harness.loginAs(f.reviewer());
        String before=databaseFacts(f);var check=expenses.unapprovalEligibility(e.getId());
        assertThat(check.eligible()).isFalse();assertThat(check.reasons().getFirst().message()).contains("已财务确认");
        assertThatThrownBy(()->unapproval.unapprove("financeExpense",e.getId(),command("confirmed-"+e.getId()))).hasMessageContaining("已财务确认");
        assertThat(databaseFacts(f)).isEqualTo(before);
    }

    @Test void inactiveAccountIsBlockedBySharedReadAndLockedReversalGuards() {
        Fixture f=fixture("inactive");var o=seedApprove(f,()->incomes.create(income(f,"15")).getId(),incomes::approve);
        db.update("UPDATE accounts SET status='禁用' WHERE id=?",f.bank());harness.loginAs(f.reviewer());
        String before=databaseFacts(f);var check=incomes.unapprovalEligibility(o.getId());
        assertThat(check.eligible()).isFalse();assertThat(check.reasons().getFirst().code()).isEqualTo("BANK_POSTING_BLOCKED");
        assertThatThrownBy(()->unapproval.unapprove("financeOtherIncome",o.getId(),command("inactive-"+o.getId()))).hasMessageContaining("停用");
        assertThat(databaseFacts(f)).isEqualTo(before);
    }

    @Test void aReadableDocumentWithoutReversePermissionNeverExposesAReadyActionOrRelatedReferences() {
        Fixture f=fixture("view-only");var o=seedApprove(f,()->incomes.create(income(f,"15")).getId(),incomes::approve);
        UUID viewer=harness.createUserWithPerms(f.world(),"preflight-viewer-"+o.getId(),"finance:view:all","finance_other_income:view");harness.loginAs(viewer);
        String before=databaseFacts(f);var check=incomes.unapprovalEligibility(o.getId());
        assertThat(check.eligible()).isFalse();assertThat(check.reasons().getFirst().code()).isEqualTo("MISSING_REVERSE_PERMISSION");
        assertThat(check.relatedDocuments()).isEmpty();assertThat(databaseFacts(f)).isEqualTo(before);
    }

    @Test void repeatedOriginalDoesNotCreateASecondSuccessorAndTheApprovedSuccessorCanUnapproveAgain() {
        Fixture f=fixture("generations");UUID original=seedApprove(f,()->transfers.create(transfer(f,"30")).getId(),transfers::approve).getId();
        harness.loginAs(f.reviewer());var first=unapproval.unapprove("financeBankTransfer",original,command("gen-first-"+original));
        UUID successor=((com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferDetail)first).getId();
        harness.loginAs(f.reviewer());transfers.approve(successor);
        String before=databaseFacts(f);var retry=unapproval.unapprove("financeBankTransfer",original,command("gen-retry-"+original));
        assertThat(((com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferDetail)retry).getId()).isEqualTo(successor);
        assertThat(databaseFacts(f)).isEqualTo(before);assertThat(transfers.unapprovalEligibility(successor).eligible()).isTrue();
        var second=unapproval.unapprove("financeBankTransfer",successor,command("gen-next-"+successor));
        assertThat(((com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferDetail)second).getId()).isNotEqualTo(successor);
        assertBalance(f.bank(),"500");assertBalance(f.otherBank(),"500");
    }

    private com.uten.imp.features.documents.DocumentUnapprovalService.UnapproveRequest command(String key) {
        return new com.uten.imp.features.documents.DocumentUnapprovalService.UnapproveRequest(key,"实际金融资格与拒绝原子性验证");
    }
    private <T> T seedApprove(Fixture f,java.util.function.Supplier<UUID> create,java.util.function.Function<UUID,T> approve) {
        harness.loginAs(f.world().superAdminUserId());UUID id=create.get();harness.loginAs(f.reviewer());return approve.apply(id);
    }

    @Test void appliedCustomerPrepaymentIsBlockedUntilItsRealApplicationIsReversed() {
        Fixture f=fixture("prepayment-applied");var ar=salesReceivable(f);
        var receipt=seedApprove(f,()->receipts.create(receipt(f,"40")).getId(),receipts::approve);
        UUID source=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_id=? AND source_doc_type='DIRECT_RECEIPT' AND NOT is_deleted",UUID.class,receipt.getId());
        harness.loginAs(f.world().superAdminUserId());
        var applied=offsets.apply(new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.ApplyRequest(
            "preflight-advance-"+receipt.getId(),source,List.of(new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.Target(ar.ledger(),ar.order(),new BigDecimal("20"))),"真实预收应用"));
        harness.loginAs(f.reviewer());String before=databaseFacts(f);var check=receipts.unapprovalEligibility(receipt.getId());
        assertThat(check.eligible()).isFalse();assertThat(check.reasons().getFirst().message()).contains("预收已有转销");
        assertThatThrownBy(()->unapproval.unapprove("financeReceipt",receipt.getId(),command("applied-"+receipt.getId()))).hasMessageContaining("预收已有转销");
        assertThat(databaseFacts(f)).isEqualTo(before);
        harness.loginAs(f.world().superAdminUserId());offsets.reverse(applied.batchId(),new com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.ReverseRequest(applied.rowVersion(),"按真实应用先反向"));
        harness.loginAs(f.reviewer());assertThat(receipts.unapprovalEligibility(receipt.getId()).eligible()).isTrue();
        unapproval.unapprove("financeReceipt",receipt.getId(),command("released-"+receipt.getId()));assertBalance(f.bank(),"500");
    }

    @Test void aReceiptWithLaterRealSourceAllocationMustReverseInLifoOrder() {
        Fixture f=fixture("receipt-lifo");var ar=salesReceivable(f);
        FinanceReceiptSaveRequest firstRequest=ReflectionTestUtils.invokeMethod(harness,"receiptRequest",f.world(),ar.ledger(),f.bank(),null,"20","20","0","0",BigDecimal.ONE,BusinessTime.today());
        FinanceReceiptSaveRequest secondRequest=ReflectionTestUtils.invokeMethod(harness,"receiptRequest",f.world(),ar.ledger(),f.bank(),null,"30","30","0","0",BigDecimal.ONE,BusinessTime.today());
        firstRequest.getItems().getFirst().setCurrencyId(f.currency());
        secondRequest.getItems().getFirst().setCurrencyId(f.currency());
        var first=seedApprove(f,()->receipts.create(firstRequest).getId(),receipts::approve);
        var second=seedApprove(f,()->receipts.create(secondRequest).getId(),receipts::approve);
        String before=databaseFacts(f);var check=receipts.unapprovalEligibility(first.getId());
        assertThat(check.eligible()).isFalse();assertThat(check.reasons().getFirst().message()).contains("后续收款");
        assertThatThrownBy(()->unapproval.unapprove("financeReceipt",first.getId(),command("lifo-first-"+first.getId()))).hasMessageContaining("后续收款");
        assertThat(databaseFacts(f)).isEqualTo(before);assertThat(receipts.unapprovalEligibility(second.getId()).eligible()).isTrue();
        unapproval.unapprove("financeReceipt",second.getId(),command("lifo-second-"+second.getId()));
        assertThat(receipts.unapprovalEligibility(first.getId()).eligible()).isTrue();unapproval.unapprove("financeReceipt",first.getId(),command("lifo-after-"+first.getId()));
        assertBalance(f.bank(),"500");
    }

    @Test void aNormallyFrozenSupplierMonthBlocksPaymentReversalOnTheActualClosingBusinessDay() {
        Fixture f=fixture("supplier-closed");var end=java.time.YearMonth.from(BusinessTime.today()).atEndOfMonth();
        try(var calendar=org.mockito.Mockito.mockStatic(BusinessTime.class,org.mockito.Mockito.CALLS_REAL_METHODS)){
            calendar.when(BusinessTime::today).thenReturn(end);
            var request=payment(f,"25");var p=seedApprove(f,()->payments.create(request).getId(),payments::approve);
            UUID method=db.queryForObject("SELECT settlement_method_id FROM purchase_orders WHERE supplier_id=? AND NOT is_deleted ORDER BY created_at DESC LIMIT 1",UUID.class,f.world().supplierId());
            harness.loginAs(f.world().superAdminUserId());supplierStatements.freeze(new com.uten.imp.features.finance.payables.SupplierSettlementContracts.FreezeRequest(
                f.world().supplierId(),f.currency(),end.withDayOfMonth(1),method,null));
            harness.loginAs(f.reviewer());String before=databaseFacts(f);var check=payments.unapprovalEligibility(p.getId());
            assertThat(check.eligible()).isFalse();assertThat(check.reasons().getFirst().message()).contains("封账");
            assertThatThrownBy(()->unapproval.unapprove("financePayment",p.getId(),command("closed-"+p.getId()))).hasMessageContaining("封账");
            assertThat(databaseFacts(f)).isEqualTo(before);
        }
    }

    private record SalesReceivable(UUID order,UUID ledger){}
    private SalesReceivable salesReceivable(Fixture f) {
        payable(f);var original=f.world();
        var world=new FullChainEndToEndTest.World(original.departmentId(),original.employeeId(),original.superAdminUserId(),
            original.goodsA(),original.goodsB(),original.goodsC(),original.goodsD(),original.goodsE(),original.clientId(),original.supplierId(),
            original.warehouseId(),original.unitId(),f.currency(),original.colorId(),original.unitLegacy());
        harness.loginAs(world.superAdminUserId());UUID order=harness.createApprovedOrder(world,world.goodsD(),"2","100");
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        var request=ReflectionTestUtils.<com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest>invokeMethod(harness,"shipmentRequest",world,item,world.goodsD(),"2");
        request.setBillDate(BusinessTime.today());harness.loginAs(world.superAdminUserId());UUID shipment=shipments.create(request).getId();harness.shipThroughWarehouse(shipment);
        UUID ledger=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_id=? AND source_doc_type='SALES_SHIPMENT' AND status=1 AND NOT is_deleted",UUID.class,shipment);
        return new SalesReceivable(order,ledger);
    }
    private String databaseFacts(Fixture f) {
        return db.queryForObject("""
            SELECT jsonb_build_object(
                'accounts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM accounts a WHERE id IN(?,?)),
                'bank',(SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM finance_reconciliations r WHERE account_id IN(?,?)),
                'unapprovals',(SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) FROM document_unapprovals u),
                'headers',(SELECT jsonb_agg(doc.row ORDER BY doc.id) FROM(
                    SELECT id,to_jsonb(e) row FROM finance_expenses e UNION ALL SELECT id,to_jsonb(o) FROM finance_other_incomes o
                    UNION ALL SELECT id,to_jsonb(r) FROM finance_receipts r UNION ALL SELECT id,to_jsonb(p) FROM finance_payments p
                    UNION ALL SELECT id,to_jsonb(t) FROM finance_bank_transfers t) doc),
                'ledger',(SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM ar_ap_ledger l),
                'allocations',(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM finance_receipt_source_allocations a),
                'offsets',(SELECT jsonb_agg(to_jsonb(o) ORDER BY o.id) FROM customer_open_item_offsets o),
                'gl',(SELECT jsonb_agg(to_jsonb(v) ORDER BY v.id) FROM gl_vouchers v))::text
            """,String.class,f.bank(),f.otherBank(),f.bank(),f.otherBank());
    }
    private Fixture fixture(String tag) {
        var world=harness.seedWorld("unapproval-check-"+tag+"-"+UUID.randomUUID()); harness.loginAs(world.superAdminUserId()); harness.seedChartOfAccounts();
        UUID bankStyle=style("ACCOUNT",tag+"-bank"),expenseStyle=style("EXPENSE",tag+"-expense"),incomeStyle=style("INCOME",tag+"-income");
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted",UUID.class);
        UUID bank=bank(currency,bankStyle,tag+"-a"),other=bank(currency,bankStyle,tag+"-b");
        UUID reviewer=harness.createUserWithPerms(world,"preflight-reviewer-"+tag+"-"+world.goodsD(),
                "finance:view:all","customer_prepayment:view","finance_receipt:view","finance_receipt:approve",
                "finance_payment:view","finance_payment:approve","finance_expense:view","finance_expense:approve",
                "finance_other_income:view","finance_other_income:approve","finance_bank_transfer:view","finance_bank_transfer:approve",
                "finance_receipt:reverse","finance_payment:reverse","finance_expense:reverse",
                "finance_other_income:reverse","finance_bank_transfer:reverse");
        db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code IN ('finance_order_approval:view','finance_order_approval:approve')",reviewer);
        db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions WHERE code IN ('finance_receipt:edit','finance_payment:edit','finance_expense:edit','finance_other_income:edit','finance_bank_transfer:edit')",reviewer);
        return new Fixture(world,reviewer,bank,other,expenseStyle,incomeStyle,currency);
    }
    private UUID style(String category,String tag) {
        UUID id=UUID.randomUUID(); db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES (?,?,?, ?,0,'使用')",id,"RV-"+tag,"审核测试"+tag,category); return id;
    }
    private UUID bank(UUID currency,UUID style,String tag) {
        UUID id=UUID.randomUUID(); db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id,init_balance,balance_current) VALUES (?,?,?,'BANK',?,'使用',?,500,500)",id,"RV-"+tag,"审核测试账户"+tag,currency,style); return id;
    }
    private FinanceReceiptSaveRequest receipt(Fixture f,String amount) {
        FinanceReceiptSaveRequest req=ReflectionTestUtils.invokeMethod(harness,"receiptRequest",f.world(),null,f.bank(),f.expenseStyle(),amount,amount,"0","0",BigDecimal.ONE,BusinessTime.today());
        req.setReceiptKind("CUSTOMER_PREPAYMENT"); req.setCurrencyId(f.currency()); req.setExchangeRate(BigDecimal.ONE);
        req.setAmountOriginal(new BigDecimal(amount));req.setOtherFeeStyleId(null);req.setItems(List.of());return req;
    }
    private FinancePaymentSaveRequest payment(Fixture f,String amount) {
        var req=new FinancePaymentSaveRequest();req.setBillDate(BusinessTime.today());req.setCreateIdempotencyKey("review-payment-"+UUID.randomUUID());
        req.setSupplierId(f.world().supplierId());req.setAccountId(f.bank());req.setCurrencyId(f.currency());req.setExchangeRate(BigDecimal.ONE);
        req.setAmountOriginal(new BigDecimal(amount));req.setAccountCurrencyId(f.currency());req.setAccountAmount(new BigDecimal(amount));
        req.setBankFeeAccountAmount(BigDecimal.ZERO);req.setBankReference("REVIEW-"+UUID.randomUUID());req.setBankBookedAt(BusinessTime.today().atTime(10,0).atOffset(java.time.ZoneOffset.UTC));
        var line=new com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput();
        line.setAppliedLedgerId(payable(f));line.setSupplierId(f.world().supplierId());line.setAmountOriginal(new BigDecimal(amount));
        req.setItems(List.of(line));return req;
    }

    private UUID payable(Fixture f) {
        harness.loginAs(f.world().superAdminUserId());
        var requested=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        requested.setBillDate(BusinessTime.today());requested.setDepartmentId(f.world().departmentId());
        requested.setApplicantId(f.world().employeeId());requested.setWarehouseId(f.world().warehouseId());
        var demand=new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        demand.setGoodsId(f.world().goodsD());demand.setUnitId(f.world().unitId());demand.setUnitRate(BigDecimal.ONE);demand.setQty(new BigDecimal("5"));
        requested.setItems(List.of(demand));var request=purchaseRequests.create(requested);purchaseRequests.approve(request.getId());
        UUID method=db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class);
        var ordered=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        ordered.setBillDate(BusinessTime.today());ordered.setSupplierId(f.world().supplierId());ordered.setWarehouseId(f.world().warehouseId());
        ordered.setCurrencyId(f.currency());ordered.setExchangeRate(BigDecimal.ONE);ordered.setTaxRate(BigDecimal.ZERO);ordered.setSettlementMethodId(method);
        var orderLine=new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        orderLine.setRequestItemId(request.getItems().getFirst().getId());orderLine.setGoodsId(f.world().goodsD());
        orderLine.setUnitId(f.world().unitId());orderLine.setUnitRate(BigDecimal.ONE);orderLine.setQty(new BigDecimal("5"));orderLine.setPrice(new BigDecimal("100"));
        ordered.setItems(List.of(orderLine));var order=purchaseOrders.create(ordered);
        procurementFinance.submit("PURCHASE",order.getId());harness.loginAs(f.reviewer());harness.approvePendingFinance("PURCHASE",order.getId());
        harness.loginAs(f.world().superAdminUserId());
        var received=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        received.setBillDate(BusinessTime.today());received.setSupplierId(f.world().supplierId());received.setWarehouseId(f.world().warehouseId());
        received.setCurrencyId(f.currency());received.setExchangeRate(BigDecimal.ONE);received.setTaxRate(BigDecimal.ZERO);received.setSettlementMethodId(method);
        var receiptLine=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        receiptLine.setOrderItemId(order.getItems().getFirst().getId());receiptLine.setGoodsId(f.world().goodsD());
        receiptLine.setUnitId(f.world().unitId());receiptLine.setUnitRate(BigDecimal.ONE);receiptLine.setQty(new BigDecimal("5"));receiptLine.setPrice(new BigDecimal("100"));
        received.setItems(List.of(receiptLine));var receipt=purchaseReceipts.create(received);purchaseReceipts.approve(receipt.getId());
        ReflectionTestUtils.invokeMethod(harness,"passAndStockPurchaseReceipt",f.world(),receipt.getId(),new BigDecimal("5"));
        harness.loginAs(f.world().superAdminUserId());
        return db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='PURCHASE_RECEIPT' AND source_doc_id=? AND status=1",UUID.class,receipt.getId());
    }
    private FinanceExpenseSaveRequest expense(Fixture f,String amount) {
        var req=new FinanceExpenseSaveRequest();req.setBillDate(BusinessTime.today());req.setAccountId(f.bank());req.setCurrencyId(f.currency());req.setExchangeRate(BigDecimal.ONE);
        var line=new FinanceExpenseItemInput();line.setExpenseStyleId(f.expenseStyle());line.setAmountOriginal(new BigDecimal(amount));req.setItems(List.of(line));return req;
    }
    private FinanceOtherIncomeSaveRequest income(Fixture f,String amount) {
        var req=new FinanceOtherIncomeSaveRequest();req.setBillDate(BusinessTime.today());req.setAccountId(f.bank());req.setCurrencyId(f.currency());req.setExchangeRate(BigDecimal.ONE);
        var line=new FinanceOtherIncomeItemInput();line.setIncomeStyleId(f.incomeStyle());line.setAmountOriginal(new BigDecimal(amount));req.setItems(List.of(line));return req;
    }
    private FinanceBankTransferSaveRequest transfer(Fixture f,String amount) {
        var req=new FinanceBankTransferSaveRequest();req.setBillDate(BusinessTime.today());req.setOutAccountId(f.bank());req.setCurrencyId(f.currency());req.setExchangeRate(BigDecimal.ONE);
        var line=new FinanceBankTransferLineInput();line.setInAccountId(f.otherBank());line.setOccurDate(BusinessTime.today());line.setAmountOriginal(new BigDecimal(amount));req.setItems(List.of(line));return req;
    }
    private void assertBalance(UUID account,String value) { assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,account)).isEqualByComparingTo(value); }
    private record Fixture(FullChainEndToEndTest.World world,UUID reviewer,UUID bank,UUID otherBank,UUID expenseStyle,UUID incomeStyle,UUID currency) { }
}
