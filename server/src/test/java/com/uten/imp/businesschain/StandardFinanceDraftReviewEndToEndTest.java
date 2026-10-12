package com.uten.imp.businesschain;

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
import org.springframework.test.util.ReflectionTestUtils;

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
class StandardFinanceDraftReviewEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired FinanceReceiptService receipts;
    @Autowired FinancePaymentService payments;
    @Autowired FinanceExpenseService expenses;
    @Autowired FinanceOtherIncomeService incomes;
    @Autowired FinanceBankTransferService transfers;
    @Autowired com.uten.imp.common.platformcolumns.PlatformColumnService platformColumns;
    @Autowired com.uten.imp.features.purchase.request.PurchaseRequestService purchaseRequests;
    @Autowired com.uten.imp.features.purchase.order.PurchaseOrderService purchaseOrders;
    @Autowired com.uten.imp.features.purchase.receipt.PurchaseReceiptService purchaseReceipts;
    @Autowired com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService procurementFinance;
    private FullChainEndToEndTest harness;
    @BeforeEach void prepare() { harness=new FullChainEndToEndTest();beans.autowireBean(harness); }
    @AfterEach void clearSecurity() { SecurityContextHolder.clearContext(); }

    @Test
    void receiptReviewerWithoutOrdinaryEditChangesRealArrivalAndPostsOnlyTheReviewedAmountThenReverses() {
        Fixture f=fixture("receipt");
        var request=receipt(f,"100"); var draft=receipts.create(request);
        request.setExpectedVersion(draft.getVersion()); request.setAmountOriginal(new BigDecimal("150"));
        request.setAccountAmount(new BigDecimal("150"));
        harness.loginAs(f.reviewer());
        assertThatThrownBy(()->receipts.update(draft.getId(),request)).isInstanceOf(AccessDeniedException.class);
        var review=receipts.review(draft.getId());
        var approved=receipts.updateReviewed(draft.getId(),request,review.snapshot(),true);
        assertThat(approved.getMakerId()).isEqualTo(f.world().employeeId());
        assertThat(approved.getAmountOriginal()).isEqualByComparingTo("150");
        assertBalance(f.bank(),"650");
        assertThatThrownBy(()->receipts.updateReviewed(draft.getId(),request,review.snapshot(),true)).isInstanceOf(ApiException.class);
        assertBalance(f.bank(),"650");
        harness.loginAs(f.world().superAdminUserId()); receipts.reverse(draft.getId());
        assertBalance(f.bank(),"500");
    }

    @Test
    void paymentReviewerWithoutOrdinaryEditKeepsMakerAndUsesActualBankDebitThroughApprovalAndReverse() {
        Fixture f=fixture("payment");
        var request=payment(f,"100"); var draft=payments.create(request);
        request.setExpectedVersion(draft.getVersion()); request.setAmountOriginal(new BigDecimal("125"));
        request.setAccountAmount(new BigDecimal("125"));
        request.getItems().getFirst().setAmountOriginal(new BigDecimal("125"));
        harness.loginAs(f.reviewer());
        assertThatThrownBy(()->payments.update(draft.getId(),request)).isInstanceOf(AccessDeniedException.class);
        var review=payments.review(draft.getId());
        var approved=payments.updateReviewed(draft.getId(),request,review.snapshot(),true);
        assertThat(approved.getMakerId()).isEqualTo(f.world().employeeId());
        assertThat(approved.getAmountOriginal()).isEqualByComparingTo("125");
        assertBalance(f.bank(),"375");
        UUID source=request.getItems().getFirst().getAppliedLedgerId();
        assertThat(db.queryForObject("SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",BigDecimal.class,source)).isEqualByComparingTo("375");
        harness.loginAs(f.world().superAdminUserId()); payments.reverse(draft.getId());
        assertBalance(f.bank(),"500");
        assertThat(db.queryForObject("SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",BigDecimal.class,source)).isEqualByComparingTo("500");
    }

    @Test
    void expenseIncomeAndTransferReuseTheirFormsAndPostReviewedValuesWithoutChangingOwner() {
        Fixture f=fixture("allocations");
        var expense=expense(f,"10");
        var column=platformColumns.create("finance_expense_item",new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CreateDefinition("费用凭证说明","TEXT",false,null));
        expense.getItems().getFirst().setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(null,0,
                List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(column.id(),"原始凭证说明"))));
        var expenseDraft=expenses.create(expense);
        UUID oldLine=expenseDraft.getItems().getFirst().getId();
        var fields=platformColumns.read("finance_expense_item",new com.uten.imp.common.platformcolumns.PlatformColumnContracts.BatchRead(List.of(oldLine),null)).getFirst();
        expense.getItems().getFirst().setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(oldLine,fields.version(),
                List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(column.id(),"审核补充凭证说明"))));
        var income=income(f,"10"); var incomeDraft=incomes.create(income);
        var transfer=transfer(f,"10"); var transferDraft=transfers.create(transfer);
        var otherExpenseDraft=expenses.create(expense(f,"10"));
        expense.getItems().getFirst().setAmountOriginal(new BigDecimal("20"));
        income.getItems().getFirst().setAmountOriginal(new BigDecimal("30"));
        transfer.getItems().getFirst().setAmountOriginal(new BigDecimal("40"));
        harness.loginAs(f.reviewer());
        var expenseReview=expenses.review(expenseDraft.getId());
        expense.getItems().getFirst().setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(
                otherExpenseDraft.getItems().getFirst().getId(),0,List.of()));
        assertThatThrownBy(()->expenses.updateReviewed(expenseDraft.getId(),expense,expenseReview.snapshot(),true))
                .isInstanceOf(ApiException.class);
        assertThat(expenses.review(expenseDraft.getId()).snapshot()).isEqualTo(expenseReview.snapshot());
        assertBalance(f.bank(),"500");
        assertThatThrownBy(()->platformColumns.create("finance_expense_item",new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CreateDefinition(
                "审核员不能创建定义","TEXT",false,null))).isInstanceOf(ApiException.class);
        expense.getItems().getFirst().setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(oldLine,fields.version(),
                List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(column.id(),"审核补充凭证说明"))));
        var approvedExpense=expenses.updateReviewed(expenseDraft.getId(),expense,expenseReview.snapshot(),true);
        assertThat(approvedExpense.getMakerId()).isEqualTo(f.world().employeeId());
        assertThat(platformColumns.read("finance_expense_item",new com.uten.imp.common.platformcolumns.PlatformColumnContracts.BatchRead(
                List.of(approvedExpense.getItems().getFirst().getId()),null)).getFirst().cells().getFirst().value()).isEqualTo("审核补充凭证说明");
        assertBalance(f.bank(),"480");
        var incomeReview=incomes.review(incomeDraft.getId());
        var approvedIncome=incomes.updateReviewed(incomeDraft.getId(),income,incomeReview.snapshot(),true);
        assertThat(approvedIncome.getMakerId()).isEqualTo(f.world().employeeId());
        assertBalance(f.bank(),"510");
        var transferReview=transfers.review(transferDraft.getId());
        var approvedTransfer=transfers.updateReviewed(transferDraft.getId(),transfer,transferReview.snapshot(),true);
        assertThat(approvedTransfer.getMakerId()).isEqualTo(f.world().employeeId());
        assertBalance(f.bank(),"470"); assertBalance(f.otherBank(),"540");
        harness.loginAs(f.world().superAdminUserId());
        transfers.reverse(transferDraft.getId()); incomes.reverse(incomeDraft.getId()); expenses.reverse(expenseDraft.getId());
        assertBalance(f.bank(),"500"); assertBalance(f.otherBank(),"500");
    }

    @Test
    void staleReviewAndFailedCombinedApprovalNeverOverwriteAcceptedChangesOrLeavePartialPostings() {
        Fixture f=fixture("stale");
        var request=payment(f,"100"); var draft=payments.create(request);
        request.setExpectedVersion(draft.getVersion());
        harness.loginAs(f.reviewer());
        var original=payments.review(draft.getId());
        request.setRemark("第一位审核员完成核对");
        var saved=payments.updateReviewed(draft.getId(),request,original.snapshot(),false);
        request.setExpectedVersion(saved.getVersion()); request.setRemark("陈旧窗口试图覆盖");
        assertThatThrownBy(()->payments.updateReviewed(draft.getId(),request,original.snapshot(),false))
                .isInstanceOf(ApiException.class).hasMessageContaining("审核中的单据已被修改");
        assertThat(payments.detail(draft.getId()).getRemark()).isEqualTo("第一位审核员完成核对");
        assertBalance(f.bank(),"500");
        var fresh=payments.review(draft.getId());
        request.setAccountAmount(new BigDecimal("99"));
        assertThatThrownBy(()->payments.updateReviewed(draft.getId(),request,fresh.snapshot(),true)).isInstanceOf(ApiException.class);
        assertThat(payments.review(draft.getId()).snapshot()).isEqualTo(fresh.snapshot());
        assertThat(db.queryForObject("SELECT count(*) FROM finance_reconciliations WHERE source_doc_id=?",Integer.class,draft.getId())).isZero();
        assertBalance(f.bank(),"500");
        UUID outsider=harness.createUserWithPerms(f.world(),"review-outsider-"+UUID.randomUUID(),"finance_payment:view","finance_payment:approve");
        harness.loginAs(outsider);
        assertThatThrownBy(()->payments.review(draft.getId())).isInstanceOf(ApiException.class);
    }

    private Fixture fixture(String tag) {
        var world=harness.seedWorld("standard-review-"+tag); harness.loginAs(world.superAdminUserId()); harness.seedChartOfAccounts();
        UUID bankStyle=style("ACCOUNT",tag+"-bank"),expenseStyle=style("EXPENSE",tag+"-expense"),incomeStyle=style("INCOME",tag+"-income");
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted",UUID.class);
        UUID bank=bank(currency,bankStyle,tag+"-a"),other=bank(currency,bankStyle,tag+"-b");
        UUID reviewer=harness.createUserWithPerms(world,"standard-reviewer-"+tag,
                "finance:view:all","customer_prepayment:view","finance_receipt:view","finance_receipt:approve",
                "finance_payment:view","finance_payment:approve","finance_expense:view","finance_expense:approve",
                "finance_other_income:view","finance_other_income:approve","finance_bank_transfer:view","finance_bank_transfer:approve");
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
