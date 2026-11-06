package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.payables.*;
import com.uten.imp.features.finance.statement.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.transaction.support.TransactionTemplate;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Enabled cutover through real procurement, IQC, warehouse, return, AP, bank and symmetric reversal. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
 "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
 "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProcurementFirstPayablePostgresTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
 @Autowired AutowireCapableBeanFactory beans;
 @Autowired JdbcTemplate db;
 @Autowired TransactionTemplate transactions;
 @Autowired ProcurementPayableRecognitionService first;
 @Autowired FinanceAuxiliaryService auxiliaries;
 @Autowired SupplierOpenItemOffsetService offsets;
 @Autowired com.uten.imp.features.finance.payment.FinancePaymentService payments;
 @Autowired com.uten.imp.features.purchase.ret.PurchaseReturnService returns;
 @Autowired com.uten.imp.features.purchase.receipt.PurchaseReceiptService receipts;
 @Autowired com.uten.imp.features.finance.gl.GlPostingService gl;
 @Autowired com.uten.imp.application.port.ProcurementCreditBookAllocationPort creditBooks;
 @Autowired com.uten.imp.features.finance.gl.NativeFinancialPostingAccountService nativeAccounts;
 @Autowired com.uten.imp.application.port.ProcurementArchiveEligibilityPort archiveFinance;
 private FullChainEndToEndTest fixture;
 private FullChainEndToEndTest.World w;
 @AfterEach void cleanup(){if(fixture!=null&&w!=null){fixture.loginAs(w.superAdminUserId());var p=first.policy();first.configure(new ProcurementPayableRecognitionService.PolicyInput(((Number)p.get("revision")).longValue(),false,null,"隔离回归完成后关闭此测试政策"));}SecurityContextHolder.clearContext();}

 @Test void realEnabledCutoverCreatesNoPayableUntilIndependentConfirmedFileAndReversesInDependencyOrder(){
  fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);w=fixture.seedWorld("first-ap");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  assertThat(beans.getBean(com.uten.imp.features.subcontract.receipt.SubcontractReceiptRepository.class).findById(UUID.randomUUID())).isEmpty();
  assertThat(beans.getBean(com.uten.imp.features.subcontract.ret.SubcontractReturnRepository.class).findById(UUID.randomUUID())).isEmpty();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID currency=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,'匿名实际原币',7,'使用')",currency,"FIRST-"+currency);
  var nativeFixture=new SupplierPrepaymentPostgresTest();beans.autowireBean(nativeFixture);
  UUID oldPayable=nativeFixture.receipt(fixture,w,currency);
  Map<String,Object> oldBefore=db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",oldPayable);
  prepare("2202","AP_CONTROL","LIABILITY",base);prepare("299901","PROCUREMENT_GRNI_PENDING","LIABILITY",base);prepare("122199","PROCUREMENT_RETURN_PENDING_ASSET","ASSET",base);
  var policy=first.policy();var policyCommand=new ProcurementPayableRecognitionService.PolicyInput(((Number)policy.get("revision")).longValue(),true,BusinessTime.today(),"匿名财务明确启用今日新审核来源对账后立应付");var changed=first.configure(policyCommand);assertThat(first.configure(policyCommand)).isEqualTo(changed);
  UUID receipt=nativeFixture.receipt(fixture,w,currency,true);
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=? AND NOT is_deleted",Integer.class,receipt)).isZero();
  var candidate=db.queryForMap("SELECT * FROM finance_procurement_payable_candidates WHERE source_id=?",receipt);amount(candidate,"amount_original","80");amount(candidate,"amount_local","560");assertThat(candidate.get("status")).isEqualTo("PENDING");
  assertThatThrownBy(()->db.update("UPDATE finance_procurement_payable_candidates SET amount_local=amount_local+1 WHERE id=?",candidate.get("id"))).isInstanceOf(org.springframework.dao.DataAccessException.class);
  assertThat(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",oldPayable)).isEqualTo(oldBefore);
  assertThat(db.queryForObject("SELECT count(*) FROM finance_procurement_payable_routes WHERE source_id=?",Integer.class,oldBefore.get("source_doc_id"))).isZero();
  UUID receiptItem=db.queryForObject("SELECT id FROM purchase_receipt_items WHERE receipt_id=? AND NOT is_deleted",UUID.class,receipt);
  UUID orderItem=db.queryForObject("SELECT order_item_id FROM purchase_receipt_items WHERE id=?",UUID.class,receiptItem);
  UUID archiveOrder=db.queryForObject("SELECT order_id FROM purchase_order_items WHERE id=?",UUID.class,orderItem);
  assertThat(archiveFinance.purchaseOrderFacts(List.of(archiveOrder)).get(archiveOrder))
    .isEqualTo(new com.uten.imp.application.port.ProcurementArchiveEligibilityPort.Facts(1,1,0));
  assertThat(archiveFinance.purchaseOrderFacts(List.of(UUID.randomUUID()))).isEmpty();
  var ret=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();ret.setBillDate(BusinessTime.today());ret.setSupplierId(w.supplierId());ret.setWarehouseId(w.warehouseId());ret.setCurrencyId(currency);ret.setExchangeRate(n("7"));ret.setTaxRate(BigDecimal.ZERO);ret.setSettlementMethodId(db.queryForObject("SELECT settlement_method_id FROM purchase_receipts WHERE id=?",UUID.class,receipt));
  var returned=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();returned.setReceiptItemId(receiptItem);returned.setOrderItemId(orderItem);returned.setGoodsId(w.goodsA());returned.setUnitId(w.unitId());returned.setUnitRate(BigDecimal.ONE);returned.setQty(n("0.5"));returned.setPrice(n("40"));ret.setItems(List.of(returned));UUID returnedId=returns.create(ret).getId();returns.approve(returnedId);
  var creditCandidate=db.queryForMap("SELECT * FROM finance_procurement_payable_candidates WHERE source_id=?",returnedId);amount(creditCandidate,"amount_original","-20");amount(creditCandidate,"amount_local","-140");
  assertThat(archiveFinance.purchaseOrderFacts(List.of(archiveOrder)).get(archiveOrder))
    .isEqualTo(new com.uten.imp.application.port.ProcurementArchiveEligibilityPort.Facts(2,2,0));
  var pendingPlan=transactions.execute(t->creditBooks.planPending((UUID)candidate.get("id"),n("20")));
  assertThat(pendingPlan.sourceApLedgerId()).isNull();assertThat(pendingPlan.sourceCandidateId()).isEqualTo(candidate.get("id"));
  assertThat(pendingPlan.amountLocal()).isEqualByComparingTo("140");assertThat(pendingPlan.offsetOriginal()).isZero();
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=? AND NOT is_deleted",Integer.class,returnedId)).isZero();
  var selected=List.of(selected(candidate),selected(creditCandidate));
  var command=new ProcurementPayableRecognitionService.Submission(UUID.randomUUID(),w.supplierId(),currency,BusinessTime.today(),"匿名实际逐来源对账确认件", "匿名供应商确认人",BusinessTime.today(),selected);
  byte[] proof=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVb8AAAAASUVORK5CYII=");
  UUID review=(UUID)first.submit(command,"anonymous-reconciliation.png","image/png",proof).get("id");assertThat(first.submit(command,"anonymous-reconciliation.png","image/png",proof).get("id")).isEqualTo(review);assertThat(first.confirmationFile(review)).containsExactly(proof);assertThat(first.operation(command.requestId()).get("id")).isEqualTo(review);
  assertThatThrownBy(()->first.submit(command,"changed-name.png","image/png",proof)).isInstanceOf(ApiException.class).hasMessageContaining("不能覆盖");
  assertThatThrownBy(()->first.approve(review)).isInstanceOf(ApiException.class).hasMessageContaining("不同人员");
  UUID reviewer=fixture.createUserWithPerms(w,"first-ap-reviewer","finance_report:view","ar_ap_ledger:view","finance:view:all","supplier_settlement:confirm","finance_post:execute");fixture.loginAs(reviewer);assertThatThrownBy(()->first.operation(command.requestId())).isInstanceOf(ApiException.class).hasMessageContaining("本人原请求");assertThatThrownBy(()->first.submit(command,"anonymous-reconciliation.png","image/png",proof)).isInstanceOf(ApiException.class).hasMessageContaining("另一提交人");first.approve(review);first.approve(review);fixture.loginAs(w.superAdminUserId());assertThat(first.operation(command.requestId()).get("id")).isEqualTo(review);
  UUID ap=db.queryForObject("SELECT ledger_id FROM finance_procurement_payable_candidates WHERE id=?",UUID.class,candidate.get("id")),credit=db.queryForObject("SELECT ledger_id FROM finance_procurement_payable_candidates WHERE id=?",UUID.class,creditCandidate.get("id"));
  assertThat(db.queryForObject("SELECT bill_no FROM ar_ap_ledger WHERE id=?",String.class,ap)).startsWith("APC-");
  assertThat(archiveFinance.purchaseOrderFacts(List.of(archiveOrder)).get(archiveOrder))
    .isEqualTo(new com.uten.imp.application.port.ProcurementArchiveEligibilityPort.Facts(2,0,2));
  assertThat(db.queryForObject("SELECT source_doc_no FROM ar_ap_ledger WHERE id=?",String.class,ap)).isEqualTo(candidate.get("bill_no"));
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND NOT is_deleted",Integer.class,receipt)).isEqualTo(1);
  int controlled=db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_type IN('PROCUREMENT_PENDING','PROCUREMENT_AP_RECOGNITION')",Integer.class);
  gl.generate(YearMonth.from(BusinessTime.today()).toString());
  assertThat(db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_type='AP_POST' AND source_doc_id IN(?,?)",Integer.class,receipt,returnedId)).isZero();
  assertThat(db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_type IN('PROCUREMENT_PENDING','PROCUREMENT_AP_RECOGNITION')",Integer.class)).isEqualTo(controlled);
  assertThatThrownBy(()->receipts.reverse(receipt)).isInstanceOf(ApiException.class);
  UUID bankStyle=style("ACCOUNT"),bank=UUID.randomUUID();db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id,init_balance,balance_current)VALUES(?,?,'匿名真实银行','BANK',?,'使用',?,1000,1000)",bank,"FIRST-BANK-"+bank,currency,bankStyle);
  for(String role:List.of("FX_GAIN_LOSS","BANK_FEE_EXPENSE"))if(db.queryForObject("SELECT system_posting_style_id(?) IS NULL",Boolean.class,role))db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key=?",style("EXPENSE"),role);
  var pay=new com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest();pay.setBillDate(BusinessTime.today());pay.setSupplierId(w.supplierId());pay.setAccountId(bank);pay.setCurrencyId(currency);pay.setExchangeRate(n("7.2"));pay.setAmountOriginal(n("10"));pay.setAccountCurrencyId(currency);pay.setAccountAmount(n("10"));pay.setBankFeeAccountAmount(BigDecimal.ZERO);pay.setBankReference("匿名真实首次应付付款回单");pay.setBankBookedAt(OffsetDateTime.now());pay.setCreateIdempotencyKey("first-pay-"+UUID.randomUUID());
  var line=new com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput();line.setAppliedLedgerId(ap);line.setSupplierId(w.supplierId());line.setAmountOriginal(n("10"));pay.setItems(List.of(line));UUID payment=payments.create(pay).getId();UUID payer=fixture.createUserWithPerms(w,"first-ap-bank-reviewer","finance_payment:view","finance_payment:approve","finance_payment:reverse","finance:view:all");fixture.grantDataScope(payer,"finance",w.employeeId());fixture.loginAs(payer);payments.approve(payment);fixture.loginAs(w.superAdminUserId());
  UUID offset=UUID.randomUUID();transactions.executeWithoutResult(t->offsets.applyBatch(offset,null,credit,w.supplierId(),currency,BusinessTime.today(),List.of(new SupplierOpenItemOffsetService.Target(ap,n("20"))),"真实已确认退货贷项抵本来源应付"));
  amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",ap),"amount_balance","350");assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,bank)).isEqualByComparingTo("990");
  assertThatThrownBy(()->first.reverse(review,"未撤付款与抵销不能反审")).isInstanceOfAny(ApiException.class,IllegalStateException.class);
  transactions.executeWithoutResult(t->offsets.reverseBatch(offset,"按后发生的抵销先撤回"));fixture.loginAs(payer);payments.reverse(payment);fixture.loginAs(w.superAdminUserId());first.reverse(review,"所有真实付款/抵销已经撤回");
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id IN(?,?) AND status=1 AND NOT is_deleted",Integer.class,receipt,returnedId)).isZero();
  var againCommand=new ProcurementPayableRecognitionService.Submission(UUID.randomUUID(),w.supplierId(),currency,BusinessTime.today(),"反审后重新确认，历史原件不覆盖","匿名供应商再次确认人",BusinessTime.today(),selected);
  UUID again=(UUID)first.submit(againCommand,"anonymous-reconciliation-again.png","image/png",proof).get("id");fixture.loginAs(reviewer);first.approve(again);fixture.loginAs(w.superAdminUserId());
  assertThat(db.queryForObject("SELECT ledger_id FROM finance_procurement_payable_candidates WHERE id=?",UUID.class,candidate.get("id"))).isNotEqualTo(ap);
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND NOT is_deleted",Integer.class,receipt)).isEqualTo(1);
  first.reverse(again,"重确认后按原记录对称撤回");
  returns.reverse(returnedId);receipts.reverse(receipt);
  assertThat(db.queryForObject("SELECT count(*) FROM finance_procurement_payable_candidates WHERE source_id IN(?,?) AND status='SOURCE_REVERSED'",Integer.class,receipt,returnedId)).isEqualTo(2);
  assertThat(archiveFinance.purchaseOrderFacts(List.of(archiveOrder)).get(archiveOrder))
    .isEqualTo(new com.uten.imp.application.port.ProcurementArchiveEligibilityPort.Facts(2,0,0));
  assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,bank)).isEqualByComparingTo("1000");
  assertThat(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",oldPayable)).isEqualTo(oldBefore);
 }
 @Test void subcontractOwnedMaterialCostAndOriginalApMarkerFollowTheRealFinancialConfirmationWithoutRepricingStock(){
  fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);w=fixture.seedWorld("first-ap-sc");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID terms=db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class);
  var orders=beans.getBean(com.uten.imp.features.subcontract.order.SubcontractOrderService.class);
  var financialOrders=beans.getBean(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService.class);
  var scReceipts=beans.getBean(com.uten.imp.features.subcontract.receipt.SubcontractReceiptService.class);
  var scReturns=beans.getBean(com.uten.imp.features.subcontract.ret.SubcontractReturnService.class);
  var inspections=beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.class);
  var stock=beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService.class);
  UUID material=fixture.addSubcontractDirectMaterial(w,w.goodsE(),"1");fixture.receiveSubcontractMaterial(w,material,"10");
  var ordered=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();ordered.setBillDate(BusinessTime.today());ordered.setSupplierId(w.supplierId());ordered.setWarehouseId(w.warehouseId());ordered.setCurrencyId(base);ordered.setExchangeRate(BigDecimal.ONE);ordered.setTaxRate(BigDecimal.ZERO);ordered.setSettlementMethodId(terms);
  var orderLine=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();orderLine.setGoodsId(w.goodsE());orderLine.setUnitId(w.unitId());orderLine.setUnitRate(BigDecimal.ONE);orderLine.setQty(n("2"));orderLine.setPrice(n("40"));ordered.setItems(List.of(orderLine));UUID order=orders.create(ordered).getId();
  financialOrders.submit("SUBCONTRACT",order);UUID orderReviewer=fixture.createApprover(w);fixture.loginAs(orderReviewer);fixture.approvePendingFinance("SUBCONTRACT",order,BigDecimal.ONE);fixture.loginAs(w.superAdminUserId());
  UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);fixture.drawAndIssueSubcontract(orderItem,n("2"),"first-ap-sc-draw-"+orderItem);
  prepare("2202","AP_CONTROL","LIABILITY",base);prepare("299901","PROCUREMENT_GRNI_PENDING","LIABILITY",base);prepare("122199","PROCUREMENT_RETURN_PENDING_ASSET","ASSET",base);
  if(db.queryForObject("SELECT system_posting_style_id('PROCUREMENT_RETURN_VARIANCE') IS NULL",Boolean.class))db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='PROCUREMENT_RETURN_VARIANCE'",style("EXPENSE"));
  var policy=first.policy();first.configure(new ProcurementPayableRecognitionService.PolicyInput(((Number)policy.get("revision")).longValue(),true,BusinessTime.today(),"匿名委外新审核先对账确认，原材料价值保持原源"));
  var received=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();received.setBillDate(BusinessTime.today());received.setSupplierId(w.supplierId());received.setWarehouseId(w.warehouseId());received.setCurrencyId(base);received.setExchangeRate(BigDecimal.ONE);received.setTaxRate(BigDecimal.ZERO);received.setSettlementMethodId(terms);
  var receiptLine=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();receiptLine.setOrderItemId(orderItem);receiptLine.setGoodsId(w.goodsE());receiptLine.setUnitId(w.unitId());receiptLine.setUnitRate(BigDecimal.ONE);receiptLine.setQty(n("2"));receiptLine.setPrice(n("40"));received.setItems(List.of(receiptLine));UUID receipt=scReceipts.create(received).getId();scReceipts.approve(receipt);
  assertThat(scReceipts.detail(receipt).isApPosted()).isFalse();
  UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receipt);inspections.dispose("SUBCONTRACT",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"实际委外合格成本来源","first-ap-sc-pass-"+receipt));
  UUID event=db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",UUID.class,inspection);fixture.loginAs(fixture.createIqcWarehouseConfirmer(w,"first-ap-sc-stock-"+receipt));
  stock.confirm("SUBCONTRACT",receipt,new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest("first-ap-sc-stock-"+receipt,List.of(new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem(event,n("2"),n("2"),"SC-FIRST-A01",w.warehouseId()))));fixture.loginAs(w.superAdminUserId());
  org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"drainCosts",w);
  BigDecimal acquired=db.queryForObject("SELECT amount_local FROM stock_balances WHERE goods_id=? AND warehouse_id=?",BigDecimal.class,w.goodsE(),w.warehouseId());assertThat(acquired).isEqualByComparingTo("100");
  var returned=new com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest();returned.setBillDate(BusinessTime.today());returned.setSupplierId(w.supplierId());returned.setWarehouseId(w.warehouseId());returned.setCurrencyId(base);returned.setExchangeRate(BigDecimal.ONE);returned.setTaxRate(BigDecimal.ZERO);returned.setSettlementMethodId(terms);
  var retLine=new com.uten.imp.features.subcontract.ret.dto.ReturnItemLine();retLine.setReceiptItemId(scReceipts.detail(receipt).getItems().getFirst().getId());retLine.setOrderItemId(orderItem);retLine.setGoodsId(w.goodsE());retLine.setUnitId(w.unitId());retLine.setUnitRate(BigDecimal.ONE);retLine.setQty(n("0.5"));retLine.setPrice(n("40"));returned.setItems(List.of(retLine));UUID ret=scReturns.create(returned).getId();scReturns.approve(ret);
  BigDecimal afterReturn=db.queryForObject("SELECT amount_local FROM stock_balances WHERE goods_id=? AND warehouse_id=?",BigDecimal.class,w.goodsE(),w.warehouseId());assertThat(afterReturn).isEqualByComparingTo("75");assertThat(scReturns.detail(ret).isApPosted()).isFalse();
  var receiptCandidate=db.queryForMap("SELECT * FROM finance_procurement_payable_candidates WHERE source_id=?",receipt);var retCandidate=db.queryForMap("SELECT * FROM finance_procurement_payable_candidates WHERE source_id=?",ret);
  var command=new ProcurementPayableRecognitionService.Submission(UUID.randomUUID(),w.supplierId(),base,BusinessTime.today(),"匿名委外实际逐单确认，不能把自有材料再计应付","匿名供应商核对人",BusinessTime.today(),List.of(selected(receiptCandidate),selected(retCandidate)));
  byte[] proof=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVb8AAAAASUVORK5CYII=");UUID review=(UUID)first.submit(command,"subcontract-original-confirmation.png","image/png",proof).get("id");
  UUID reviewer=fixture.createUserWithPerms(w,"first-ap-sc-reviewer","finance_report:view","ar_ap_ledger:view","finance:view:all","supplier_settlement:confirm","finance_post:execute");fixture.loginAs(reviewer);first.approve(review);fixture.loginAs(w.superAdminUserId());
  assertThat(scReceipts.detail(receipt).isApPosted()).isTrue();assertThat(scReturns.detail(ret).isApPosted()).isTrue();
  assertThat(db.queryForObject("SELECT ap_posted FROM subcontract_receipts WHERE id=?",Boolean.class,receipt)).isFalse();
  assertThat(db.queryForObject("SELECT amount_local FROM stock_balances WHERE goods_id=? AND warehouse_id=?",BigDecimal.class,w.goodsE(),w.warehouseId())).isEqualByComparingTo(afterReturn);
  gl.generate(YearMonth.from(BusinessTime.today()).toString());
  assertThat(db.queryForObject("SELECT sum(e.direction*e.amount) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_type='PROC_RETURN_VARIANCE' AND v.source_doc_id=? AND e.style_id=system_posting_style_id('PROCUREMENT_RETURN_VARIANCE')",BigDecimal.class,ret)).isEqualByComparingTo("5");
  first.reverse(review,"先撤财务应付，再撤回真实库存");assertThat(scReceipts.detail(receipt).isApPosted()).isFalse();assertThat(scReturns.detail(ret).isApPosted()).isFalse();scReturns.reverse(ret);
  transactions.executeWithoutResult(t->{try{scReceipts.reverse(receipt);}catch(RuntimeException failure){diagnoseWithdrawal(receipt,failure);throw failure;}});
  assertThat(db.queryForObject("SELECT count(*) FROM finance_procurement_payable_candidates WHERE source_id IN(?,?) AND status='SOURCE_REVERSED'",Integer.class,receipt,ret)).isEqualTo(2);
 }
 @Test void actualIqcCreditUsesTypedPendingSourceAndReviewedPrecisionWithoutInventingPositiveAp()throws Exception{
  fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);w=fixture.seedWorld("first-ap-iqc");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID currency=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,'匿名实际信用原币',7,'使用')",currency,"FIRST-IQC-"+currency);
  prepare("2202","AP_CONTROL","LIABILITY",base);prepare("299901","PROCUREMENT_GRNI_PENDING","LIABILITY",base);prepare("122199","PROCUREMENT_RETURN_PENDING_ASSET","ASSET",base);
  if(db.queryForObject("SELECT system_posting_style_id('PROCUREMENT_RETURN_VARIANCE') IS NULL",Boolean.class))db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='PROCUREMENT_RETURN_VARIANCE'",style("EXPENSE"));
  var policy=first.policy();first.configure(new ProcurementPayableRecognitionService.PolicyInput(((Number)policy.get("revision")).longValue(),true,BusinessTime.today(),"实际供应商贷项可先确认，原正收货仍待对账"));
  var nativeFixture=new SupplierPrepaymentPostgresTest();beans.autowireBean(nativeFixture);UUID receipt=nativeFixture.receipt(fixture,w,currency,true,false);
  UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?",UUID.class,receipt);
  var inspections=beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.class);
  inspections.dispose("PURCHASE",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("FAIL",n("1"),"第一实际失败份额","first-iqc-fail-one-"+receipt));
  inspections.dispose("PURCHASE",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("FAIL",null,"第二实际失败份额","first-iqc-fail-rest-"+receipt));
  UUID caseId=fixture.awaitIqcRejection("PURCHASE",receipt);var rejections=beans.getBean(ProcurementIqcRejectionService.class);
  long version=db.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",Long.class,caseId);
  rejections.recordReturn(caseId,new ProcurementIqcRejectionContracts.RecordReturnRequest(version,UUID.randomUUID(),"ANON-REAL-RETURN",BusinessTime.today(),"两件实物已经按原来源退回供应商"));
  version=db.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",Long.class,caseId);
  UUID candidate=db.queryForObject("SELECT id FROM finance_procurement_payable_candidates WHERE source_id=?",UUID.class,receipt);
  var detail=rejections.detail(caseId);assertThat(detail.creditSources()).anySatisfy(source->{assertThat(source.sourceApLedgerId()).isNull();assertThat(source.sourceCandidateId()).isEqualTo(candidate);});
  var input=new ProcurementIqcRejectionContracts.ActualCreditAllocation(caseId,version,n("1.5"),n("1"));UUID commandId=UUID.randomUUID();
  var draft=new ProcurementIqcRejectionContracts.ConfirmCreditRequest(version,commandId,"ANON-ACTUAL-CREDIT",BusinessTime.today(),"按实际供应商接受金额，不用原价凑贷项",n("1.5"),n("1"),null,List.of(input),null,candidate);
  assertThatThrownBy(()->rejections.previewCredit(caseId,draft)).isInstanceOf(com.uten.imp.common.finance.BusinessPrecisionRequiredException.class);
  assertThat(db.queryForObject("SELECT count(*) FROM procurement_iqc_credit_documents WHERE id=?",Integer.class,commandId)).isZero();
  ProcurementIqcRejectionContracts.CreditBookPreview preview;
  try(var choice=com.uten.imp.common.finance.BusinessPrecisionContext.use(Map.of(
      "procurement.credit.actual-share",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(4,"DOWN"),
      "money.book-share",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(4,"HALF_UP")))){
   preview=rejections.previewCredit(caseId,draft);
  }
  assertThat(new BigDecimal(preview.amountLocal())).isEqualByComparingTo("7");assertThat(preview.precisionPolicy()).isNotNull();
  var reviewed=new ProcurementIqcRejectionContracts.ConfirmCreditRequest(version,commandId,draft.creditReference(),draft.creditDate(),draft.reason(),draft.baseQty(),draft.actualAmountOriginal(),null,draft.allocations(),preview.bookAllocationHash(),candidate,preview.precisionPolicy());
  rejections.confirmCredit(caseId,reviewed);rejections.confirmCredit(caseId,reviewed);
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND NOT is_deleted",Integer.class,receipt)).isZero();
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=? AND amount_original=-1 AND amount_original_local=-7 AND status=1 AND NOT is_deleted",Integer.class,commandId)).isEqualTo(1);
  assertThat(db.queryForObject("SELECT sum(amount_original) FROM procurement_iqc_credit_slices WHERE credit_document_id=?",BigDecimal.class,commandId)).isEqualByComparingTo("1");
  assertThat(db.queryForObject("SELECT sum(amount_local) FROM procurement_iqc_credit_slices WHERE credit_document_id=?",BigDecimal.class,commandId)).isEqualByComparingTo("7");
  assertThat(db.queryForObject("SELECT amount_original FROM procurement_iqc_credit_slices WHERE credit_document_id=? AND allocation_sequence=2",BigDecimal.class,commandId)).isEqualByComparingTo("0.3334");
  assertThat(db.queryForObject("SELECT amount_local FROM procurement_iqc_credit_slices WHERE credit_document_id=? AND allocation_sequence=2",BigDecimal.class,commandId)).isEqualByComparingTo("2.3333");
  assertThat(db.queryForObject("SELECT count(*) FROM supplier_open_item_offsets WHERE source_ledger_id=(SELECT id FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND NOT is_deleted)",Integer.class,commandId)).isZero();
  gl.generate(YearMonth.from(BusinessTime.today()).toString());
  assertThat(db.queryForObject("SELECT sum(e.direction*e.amount) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_type='PROC_RETURN_VARIANCE' AND v.source_doc_id=? AND e.style_id=system_posting_style_id('PROCUREMENT_RETURN_VARIANCE')",BigDecimal.class,commandId)).isEqualByComparingTo("413");
  version=db.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",Long.class,caseId);
  rejections.reverseCredit(caseId,new ProcurementIqcRejectionContracts.ReverseRequest(version,UUID.randomUUID(),"撤回实际贷项，恢复原托管和所有资金份额",commandId));
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND NOT is_deleted",Integer.class,commandId)).isZero();
  assertThat(new BigDecimal(rejections.detail(caseId).resolution().creditableBaseQty())).isEqualByComparingTo("2");
  assertThat(db.queryForObject("SELECT status FROM finance_procurement_payable_candidates WHERE id=?",String.class,candidate)).isEqualTo("PENDING");
 }
 @Test void reviewedCurrencyPartyMappingAndLaterChangeKeepTwoOriginalDebtsAndCashInTheirOwnAccounts(){
  fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);w=fixture.seedWorld("native-frozen-debt");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID currency=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,'匿名实际交易币别',7,'使用')",currency,"NATIVE-"+currency);
  prepare("2202","AP_CONTROL","LIABILITY",base);
  UUID account1=explicitPayableAccount("2202091",currency),account2=explicitPayableAccount("2202092",currency);
  UUID reviewer=fixture.createUserWithPerms(w,"native-map-reviewer","finance_report:view","finance:view:all","payment_style:edit","finance_post:execute");
  var party=new com.uten.imp.application.port.NativeFinancialPostingAccountPort.Party("SUPPLIER",w.supplierId());
  var firstConfig=new com.uten.imp.features.finance.gl.NativeFinancialPostingAccountService.Configuration(UUID.randomUUID(),"AP_CONTROL",currency,party,BusinessTime.today(),true,account1,"2202091",currency,null,"财务明确按实际交易币别及真实供应商对应，独立审核");
  UUID config1=(UUID)nativeAccounts.submit(firstConfig).get("id");assertThat(nativeAccounts.submit(firstConfig).get("id")).isEqualTo(config1);
  assertThatThrownBy(()->nativeAccounts.approve(config1)).isInstanceOf(ApiException.class).hasMessageContaining("另一名");fixture.loginAs(reviewer);nativeAccounts.approve(config1);fixture.loginAs(w.superAdminUserId());
  var nativeFixture=new SupplierPrepaymentPostgresTest();beans.autowireBean(nativeFixture);UUID ap1=nativeFixture.receipt(fixture,w,currency);
  var changed=new com.uten.imp.features.finance.gl.NativeFinancialPostingAccountService.Configuration(UUID.randomUUID(),"AP_CONTROL",currency,party,BusinessTime.today(),true,account2,"2202092",currency,null,"后续业务改用第二个真实对应版本，不修改已发生债务");
  UUID config2=(UUID)nativeAccounts.submit(changed).get("id");fixture.loginAs(reviewer);nativeAccounts.approve(config2);fixture.loginAs(w.superAdminUserId());UUID ap2=nativeFixture.receipt(fixture,w,currency);
  transactions.executeWithoutResult(t->{assertThat(nativeAccounts.frozenArAp(ap1).styleId()).isEqualTo(account1);assertThat(nativeAccounts.frozenArAp(ap1).configurationId()).isEqualTo(config1);assertThat(nativeAccounts.frozenArAp(ap2).styleId()).isEqualTo(account2);});
  gl.generate(YearMonth.from(BusinessTime.today()).toString());
  for(var item:Map.of(ap1,account1,ap2,account2).entrySet())assertThat(db.queryForObject("SELECT count(*) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id JOIN ar_ap_ledger l ON l.source_doc_id=v.source_doc_id JOIN finance_gl_entry_allocations a ON a.entry_id=e.id WHERE l.id=? AND v.source_type='AP_POST' AND e.line_no=2 AND e.style_id=? AND a.original_currency_id=? AND a.currency_id=?",Integer.class,item.getKey(),item.getValue(),currency,currency)).isEqualTo(1);
  var originalEntries=db.queryForList("SELECT ledger_id,entry_id,voucher_id FROM finance_native_debt_entry_refs WHERE ledger_id IN(?,?)ORDER BY ledger_id",ap1,ap2);
  assertThat(originalEntries).hasSize(2);
  UUID bankStyle=style("ACCOUNT"),bank=UUID.randomUUID();db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id,init_balance,balance_current)VALUES(?,?,'匿名真实银行','BANK',?,'使用',?,1000,1000)",bank,"NATIVE-BANK-"+bank,currency,bankStyle);
  for(String role:List.of("FX_GAIN_LOSS","BANK_FEE_EXPENSE"))if(db.queryForObject("SELECT system_posting_style_id(?) IS NULL",Boolean.class,role))db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key=?",style("EXPENSE"),role);
  var pay=new com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest();pay.setBillDate(BusinessTime.today());pay.setSupplierId(w.supplierId());pay.setAccountId(bank);pay.setCurrencyId(currency);pay.setExchangeRate(n("7.2"));pay.setAmountOriginal(n("20"));pay.setAccountCurrencyId(currency);pay.setAccountAmount(n("20"));pay.setBankFeeAccountAmount(BigDecimal.ZERO);pay.setBankReference("匿名两科目真实银行回单");pay.setBankBookedAt(OffsetDateTime.now());pay.setCreateIdempotencyKey("native-map-pay-"+UUID.randomUUID());
  List<com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput> lines=new ArrayList<>();for(UUID ap:List.of(ap1,ap2)){var line=new com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput();line.setAppliedLedgerId(ap);line.setSupplierId(w.supplierId());line.setAmountOriginal(n("10"));lines.add(line);}pay.setItems(lines);UUID payment=payments.create(pay).getId();
  UUID payer=fixture.createUserWithPerms(w,"native-map-payer","finance_payment:view","finance_payment:approve","finance_payment:reverse","finance:view:all");fixture.grantDataScope(payer,"finance",w.employeeId());fixture.loginAs(payer);payments.approve(payment);
  assertThat(db.queryForObject("SELECT count(*) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id JOIN finance_gl_entry_allocations a ON a.entry_id=e.id WHERE v.source_type='PAYMENT' AND v.source_doc_id=? AND e.line_no>1000 AND e.direction=1 AND e.style_id IN(?,?) AND a.original_currency_id=?",Integer.class,payment,account1,account2,currency)).isEqualTo(2);
  assertThat(db.queryForObject("SELECT sum(e.amount) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_type='PAYMENT' AND v.source_doc_id=? AND e.line_no>1000",BigDecimal.class,payment)).isEqualByComparingTo("140");
  assertThat(db.queryForObject("SELECT count(*) FROM finance_native_cash_debt_entry_links WHERE kind='PAYMENT' AND cash_id=?",Integer.class,payment)).isEqualTo(2);
  fixture.loginAs(w.superAdminUserId());gl.generate(YearMonth.from(BusinessTime.today()).toString());
  assertThat(db.queryForList("SELECT ledger_id,entry_id,voucher_id FROM finance_native_debt_entry_refs WHERE ledger_id IN(?,?)ORDER BY ledger_id",ap1,ap2)).isEqualTo(originalEntries);
  assertThatThrownBy(()->db.update("DELETE FROM gl_vouchers WHERE id=?",originalEntries.getFirst().get("voucher_id"))).isInstanceOf(org.springframework.dao.DataAccessException.class);
  fixture.loginAs(payer);
  assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,bank)).isEqualByComparingTo("980");payments.reverse(payment);
  assertThat(db.queryForObject("SELECT count(*) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id JOIN finance_gl_entry_allocations a ON a.entry_id=e.id WHERE v.source_type='PAYMENT_REV' AND v.source_doc_id=? AND e.line_no>1000 AND e.direction=-1",Integer.class,payment)).isEqualTo(2);
  assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,bank)).isEqualByComparingTo("1000");fixture.loginAs(w.superAdminUserId());
 }
 private UUID explicitPayableAccount(String code,UUID currency){
  UUID style=style("LIABILITY");db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by)VALUES(?,?,'明确外币属性',?,'LIABILITY','MANUAL','匿名明确维护',1,1,?)",code,"匿名财务独立对应科目",currency,w.superAdminUserId());db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by)VALUES(?,?,?)",code,style,w.superAdminUserId());
  var rule=auxiliaries.readRule(code);auxiliaries.saveRule(code,new FinanceAuxiliaryContracts.RuleInput(rule.version(),true,List.of("SUPPLIER"),"明确供应商辅助维度"));auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名首次应付账套","SUP-"+w.supplierId(),"匿名源供应商","SUPPLIER",w.supplierId(),"明确真实供应商UUID并逐科目绑定",code));return style;
 }
 @Test void historicalNativeCorrespondenceAddsReviewedEvidenceToOneRealEntryWithoutReplayingAnyAmount(){
  fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);w=fixture.seedWorld("native-debt-evidence");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID currency=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,'匿名实际原币',7,'使用')",currency,"DEBT-REVIEW-"+currency);
  var nativeFixture=new SupplierPrepaymentPostgresTest();beans.autowireBean(nativeFixture);UUID ledger=nativeFixture.receipt(fixture,w,currency);
  transactions.executeWithoutResult(t->{assertThat(nativeAccounts.frozenArAp(ledger).complete()).isFalse();});
  gl.generate(YearMonth.from(BusinessTime.today()).toString());prepare("2202","AP_CONTROL","LIABILITY",base);
  var preview=nativeAccounts.debtCorrespondencePreview(ledger);@SuppressWarnings("unchecked")var entries=(List<Map<String,Object>>)preview.get("entries");assertThat(entries).hasSize(1);UUID entry=(UUID)entries.getFirst().get("entryId");
  UUID auxiliary=transactions.execute(t->auxiliaries.resolveNative("2202","SUPPLIER",w.supplierId(),base).auxiliaryId());
  var command=new com.uten.imp.features.finance.gl.NativeFinancialPostingAccountService.DebtCorrespondence(UUID.randomUUID(),ledger,entry,"2202",auxiliary,"按原真实分录和实际供应商辅助项目逐项核对，只补证据不改金额");
  UUID review=(UUID)nativeAccounts.submitDebtCorrespondence(command).get("id");assertThat(nativeAccounts.submitDebtCorrespondence(command).get("id")).isEqualTo(review);
  assertThatThrownBy(()->nativeAccounts.approveDebtCorrespondence(review)).isInstanceOf(ApiException.class).hasMessageContaining("另一名");
  UUID reviewer=fixture.createUserWithPerms(w,"native-debt-reviewer","finance_report:view","finance:view:all","ar_ap_ledger:view","payment_style:edit","finance_post:execute");fixture.loginAs(reviewer);nativeAccounts.approveDebtCorrespondence(review);nativeAccounts.approveDebtCorrespondence(review);fixture.loginAs(w.superAdminUserId());
  var allocation=db.queryForMap("SELECT * FROM finance_gl_entry_allocations WHERE entry_id=?",entry);amount(allocation,"amount_local","560");amount(allocation,"amount_original","80");assertThat(allocation.get("currency_id")).isEqualTo(base);assertThat(allocation.get("original_currency_id")).isEqualTo(currency);assertThat(allocation.get("auxiliary_id")).isEqualTo(auxiliary);
  transactions.executeWithoutResult(t->{assertThat(nativeAccounts.frozenArAp(ledger).complete()).isTrue();var debt=nativeAccounts.readArAp(List.of(ledger)).get(ledger);assertThat(debt.complete()).isTrue();assertThat(debt.entries()).hasSize(1);assertThat(debt.entries().getFirst().entryId()).isEqualTo(entry);});
  gl.generate(YearMonth.from(BusinessTime.today()).toString());assertThat(db.queryForObject("SELECT entry_id FROM finance_native_debt_entry_refs WHERE ledger_id=?",UUID.class,ledger)).isEqualTo(entry);
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE id=? AND amount_original=80 AND amount_original_local=560 AND status=1 AND NOT is_deleted",Integer.class,ledger)).isEqualTo(1);
  assertThat(db.queryForObject("SELECT count(*) FROM gl_entries WHERE id=? AND amount=560",Integer.class,entry)).isEqualTo(1);
 }
 @Test void actualIqcOffsetBetweenTwoFrozenAccountsMovesNoCashAndReversesBothOriginalDebtSides(){
  fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);w=fixture.seedWorld("native-offset-accounts");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID currency=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,'匿名真实交易原币',7,'使用')",currency,"OFFSET-"+currency);
  prepare("2202","AP_CONTROL","LIABILITY",base);UUID positiveStyle=explicitPayableAccount("2202093",currency),creditStyle=explicitPayableAccount("2202094",currency);
  UUID reviewer=fixture.createUserWithPerms(w,"offset-account-reviewer","finance_report:view","finance:view:all","payment_style:edit","finance_post:execute");var party=new com.uten.imp.application.port.NativeFinancialPostingAccountPort.Party("SUPPLIER",w.supplierId());
  UUID firstMapping=(UUID)nativeAccounts.submit(new com.uten.imp.features.finance.gl.NativeFinancialPostingAccountService.Configuration(UUID.randomUUID(),"AP_CONTROL",currency,party,BusinessTime.today(),true,positiveStyle,"2202093",currency,null,"本次原收货确认使用第一个真实应付科目")).get("id");fixture.loginAs(reviewer);nativeAccounts.approve(firstMapping);fixture.loginAs(w.superAdminUserId());
  var nativeFixture=new SupplierPrepaymentPostgresTest();beans.autowireBean(nativeFixture);UUID receipt=nativeFixture.receipt(fixture,w,currency,true,false);UUID positive=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND NOT is_deleted",UUID.class,receipt);
  UUID secondMapping=(UUID)nativeAccounts.submit(new com.uten.imp.features.finance.gl.NativeFinancialPostingAccountService.Configuration(UUID.randomUUID(),"AP_CONTROL",currency,party,BusinessTime.today(),true,creditStyle,"2202094",currency,null,"后续实际供应商贷项确认使用第二个真实应付科目")).get("id");fixture.loginAs(reviewer);nativeAccounts.approve(secondMapping);fixture.loginAs(w.superAdminUserId());
  if(db.queryForObject("SELECT system_posting_style_id('PROCUREMENT_RETURN_VARIANCE') IS NULL",Boolean.class))db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='PROCUREMENT_RETURN_VARIANCE'",style("EXPENSE"));
  UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?",UUID.class,receipt);beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.class).dispose("PURCHASE",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("FAIL",null,"原实物不合格全部退回","offset-fail-"+receipt));
  UUID caseId=fixture.awaitIqcRejection("PURCHASE",receipt);var rejections=beans.getBean(ProcurementIqcRejectionService.class);long version=db.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",Long.class,caseId);rejections.recordReturn(caseId,new ProcurementIqcRejectionContracts.RecordReturnRequest(version,UUID.randomUUID(),"ANON-OFFSET-RETURN",BusinessTime.today(),"原实物按原来源真实退还"));
  version=db.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",Long.class,caseId);UUID creditDocument=UUID.randomUUID();var allocation=new ProcurementIqcRejectionContracts.ActualCreditAllocation(caseId,version,n("1"),n("1"));var draft=new ProcurementIqcRejectionContracts.ConfirmCreditRequest(version,creditDocument,"ANON-TWO-ACCOUNT-CREDIT",BusinessTime.today(),"真实接受贷项并应用原应付，两端科目保持原版本",n("1"),n("1"),positive,List.of(allocation),null);
  var preview=rejections.previewCredit(caseId,draft);var command=new ProcurementIqcRejectionContracts.ConfirmCreditRequest(version,creditDocument,draft.creditReference(),draft.creditDate(),draft.reason(),draft.baseQty(),draft.actualAmountOriginal(),positive,draft.allocations(),preview.bookAllocationHash(),null,preview.precisionPolicy());rejections.confirmCredit(caseId,command);
  UUID offset=db.queryForObject("SELECT id FROM supplier_open_item_offsets WHERE offset_batch_id=? AND status='APPLIED'",UUID.class,creditDocument);var journal=db.queryForMap("SELECT * FROM finance_native_supplier_offset_journals WHERE offset_id=?",offset);assertThat(journal.get("voucher_id")).isNotNull();
  assertThat(db.queryForObject("SELECT sum(direction*amount) FROM gl_entries WHERE voucher_id=? AND style_id=?",BigDecimal.class,journal.get("voucher_id"),positiveStyle)).isEqualByComparingTo("7");assertThat(db.queryForObject("SELECT sum(direction*amount) FROM gl_entries WHERE voucher_id=? AND style_id=?",BigDecimal.class,journal.get("voucher_id"),creditStyle)).isEqualByComparingTo("-7");
  assertThat(db.queryForObject("SELECT count(*) FROM finance_reconciliations WHERE source_doc_id IN(?,?)",Integer.class,creditDocument,offset)).isZero();amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",positive),"amount_balance","553");
  gl.generate(YearMonth.from(BusinessTime.today()).toString());version=db.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",Long.class,caseId);rejections.reverseCredit(caseId,new ProcurementIqcRejectionContracts.ReverseRequest(version,UUID.randomUUID(),"先按实际原抵销顺序撤回，再反向实际贷项，不造资金",creditDocument));
  amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",positive),"amount_balance","560");assertThat(db.queryForObject("SELECT reversal_voucher_id IS NOT NULL FROM finance_native_supplier_offset_journals WHERE offset_id=?",Boolean.class,offset)).isTrue();
  assertThat(db.queryForObject("SELECT sum(e.direction*e.amount) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_type IN('NATIVE_SUPPLIER_OFFSET','NATIVE_SUPPLIER_OFFSET_REV') AND v.source_ref IN(?,?)",BigDecimal.class,"NATIVE_SUPPLIER_OFFSET:"+offset,"NATIVE_SUPPLIER_OFFSET_REV:"+offset)).isEqualByComparingTo("0");
 }
 private void diagnoseWithdrawal(UUID receipt,RuntimeException failure){
  try{
   String state=db.queryForObject("""
    WITH pools AS(SELECT * FROM stock_value_pools WHERE goods_id=? AND warehouse_id=?),originals AS(
      SELECT event.* FROM stock_value_events event JOIN procurement_iqc_stock_in_batch_items item ON item.stock_movement_id=event.movement_id
      JOIN procurement_inspection_items inspection ON inspection.id=item.inspection_item_id WHERE inspection.receipt_type='SUBCONTRACT' AND inspection.receipt_id=? AND event.operation='POSITION_STORE')
    SELECT jsonb_build_object('receipt',?::text,'pools',(SELECT jsonb_agg(to_jsonb(pool))FROM pools pool),
      'originals',(SELECT jsonb_agg(to_jsonb(original))FROM originals original),
      'proofs',(SELECT jsonb_agg(jsonb_build_object('current',pool.head_node_id,'original',original.result_head_id,
        'unused',fn_stock_value_unused_receipt_head(pool.head_node_id,original.result_head_id),
        'wholeParent',fn_stock_value_completed_issue_return_parent_before_v1008(pool.head_node_id),
        'partialParent',fn_stock_value_completed_partial_issue_return_parent(pool.head_node_id)))FROM pools pool CROSS JOIN originals original),
      'nodes',(SELECT jsonb_agg(to_jsonb(node)ORDER BY node.id)FROM stock_value_nodes node WHERE node.pool_id IN(SELECT id FROM pools)),
      'events',(SELECT jsonb_agg(to_jsonb(event)ORDER BY event.id)FROM stock_value_events event WHERE event.pool_id IN(SELECT id FROM pools)),
      'edges',(SELECT jsonb_agg(to_jsonb(edge)ORDER BY edge.id)FROM stock_value_edges edge JOIN stock_value_nodes child ON child.id=edge.child_node_id WHERE child.pool_id IN(SELECT id FROM pools)),
      'transfers',(SELECT jsonb_agg(to_jsonb(transfer)ORDER BY transfer.id)FROM stock_value_position_transfers transfer JOIN stock_value_nodes child ON child.id=transfer.target_node_id WHERE child.pool_id IN(SELECT id FROM pools)))::text
    """,String.class,w.goodsE(),w.warehouseId(),receipt,receipt);
   java.nio.file.Path target=java.nio.file.Path.of("..","tmp","finance-party","subcontract-firstap-withdrawal-anonymous.json");java.nio.file.Files.writeString(target,state);
  }catch(Exception diagnostic){failure.addSuppressed(diagnostic);}
 }
 private void prepare(String code,String role,String category,UUID base){UUID style=db.queryForObject("SELECT system_posting_style_id(?)",UUID.class,role);if(style==null){style=style(category.equals("ASSET")?"ACCOUNT":"LIABILITY");db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key=?",style,role);}
  db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by)VALUES(?,?,'',?,?,'MANUAL','匿名明确配置，不按名称匹配',1,1,?)ON CONFLICT(code)DO UPDATE SET currency_id=excluded.currency_id",code,"匿名用途财务科目",base,category,w.superAdminUserId());
  db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by)VALUES(?,?,?)ON CONFLICT(style_id)DO NOTHING",code,style,w.superAdminUserId());
  var rule=auxiliaries.readRule(code);auxiliaries.saveRule(code,new FinanceAuxiliaryContracts.RuleInput(rule.version(),true,List.of("SUPPLIER"),"明确供应商辅助维度"));
  auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名首次应付账套","SUP-"+w.supplierId(),"匿名源供应商","SUPPLIER",w.supplierId(),"明确真实供应商UUID并逐科目绑定",code));
 }
 private UUID style(String category){UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status)VALUES(?,?,?, ?,0,'使用')",id,"FIRST-ST-"+id,"匿名实际用途科目-"+id,category);return id;}
 private static ProcurementPayableRecognitionService.Selected selected(Map<String,Object> row){return new ProcurementPayableRecognitionService.Selected((UUID)row.get("id"),row.get("source_fingerprint").toString());}
 private static BigDecimal n(String s){return new BigDecimal(s);}
 private static void amount(Map<String,Object> row,String key,String expected){assertThat(new BigDecimal(row.get(key).toString())).as(key).isEqualByComparingTo(expected);}
}
