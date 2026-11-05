package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.payables.*;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.statement.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Anonymous real native bank/receipt/IQC sources through the full migration chain. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
 "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
 "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class SupplierPrepaymentPostgresTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FinanceScopedChainDatabase.register(r,SupplierPrepaymentPostgresTest.class);}
 @Autowired AutowireCapableBeanFactory beans;
 @Autowired JdbcTemplate db;
 @Autowired FinancePaymentService payments;
 @Autowired SupplierPrepaymentService advances;
 @Autowired FinanceAuxiliaryService auxiliaries;
 @Autowired FinanceOpenItemClassificationService classifications;
 @Autowired com.uten.imp.features.finance.report.FinanceReportService reports;
 @Autowired com.uten.imp.features.purchase.order.PurchaseOrderService orders;
 @Autowired com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService procurementFinance;
 @Autowired com.uten.imp.features.purchase.receipt.PurchaseReceiptService receipts;
 @Autowired com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspections;
 @Autowired com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService stockIn;
 @Autowired SupplierSettlementService monthly;
 @AfterEach void logout(){SecurityContextHolder.clearContext();}

 @Test void futureSupplierRefundStaysDraftWithoutChangingAdvanceBankOrPostingFacts(){
  var setup=createAdvance("supplier-future-refund");var fixture=setup.fixture();var world=setup.world();
  advances.classify(setup.payment(),new SupplierPrepaymentService.Classify("真实预付全货款",
      List.of(new SupplierPrepaymentService.Category("GOODS",n("100"),n("700")))));
  var advanceBefore=db.queryForMap("SELECT * FROM finance_supplier_advances WHERE payment_id=?",setup.payment());
  BigDecimal bankBefore=db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,setup.account());
  OffsetDateTime future=OffsetDateTime.now().plusDays(1).withNano(0);
  var draft=advances.createRefund(setup.payment(),new SupplierPrepaymentService.Refund(UUID.randomUUID(),"GOODS",n("10"),
      setup.account(),setup.currency(),n("9"),n("7.2"),n("1"),"尚未发生的退款原币10，计划净到9/费1保留草稿",future,"未来退款原输入保留"));
  UUID id=(UUID)draft.get("id");
  UUID reviewer=fixture.createUserWithPerms(world,"future-refund-reviewer","finance_receipt:view","finance_receipt:approve",
      "finance_receipt:reverse","finance_report:view","ar_ap_ledger:view","finance:view:all");
  fixture.loginAs(reviewer);
  assertThatThrownBy(()->advances.approveRefund(id)).isInstanceOf(ApiException.class).hasMessageContaining("尚未发生");
  assertThat(db.queryForObject("SELECT status FROM finance_supplier_advance_refunds WHERE id=?",String.class,id)).isEqualTo("DRAFT");
  assertThat(db.queryForObject("SELECT extract(epoch FROM bank_booked_at) FROM finance_supplier_advance_refunds WHERE id=?",BigDecimal.class,id))
      .isEqualByComparingTo(BigDecimal.valueOf(future.toEpochSecond()));
  assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,setup.account())).isEqualByComparingTo(bankBefore);
  assertThat(db.queryForMap("SELECT * FROM finance_supplier_advances WHERE payment_id=?",setup.payment())).isEqualTo(advanceBefore);
  assertThat(db.queryForObject("SELECT count(*) FROM finance_gl_settlement_reservations WHERE owner_kind='SUPPLIER_ADVANCE_REFUND' AND owner_id=?",Integer.class,id)).isZero();
  assertThat(db.queryForObject("SELECT count(*) FROM finance_reconciliations WHERE source_doc_id=?",Integer.class,id)).isZero();
  assertThat(db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_doc_id=?",Integer.class,id)).isZero();
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE supplier_id=? AND direction='AP'",Integer.class,world.supplierId())).isZero();
 }

 @Test void actualAdvanceApplicationAndBankRefundPreserveTwoCurrenciesAndReverseOnlyActualFacts(){
  var setup=createAdvance("supplier-advance");
  var fixture=setup.fixture();var world=setup.world();var base=setup.base();var currency=setup.currency();
  var account=setup.account();var reviewer=setup.reviewer();var payment=setup.payment();
  assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=?",Integer.class,payment)).isZero();
  assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,account)).isEqualByComparingTo("900");
  assertThat(db.queryForObject("SELECT sum(e.direction*e.amount) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_type='PAYMENT' AND v.source_doc_id=?",BigDecimal.class,payment)).isZero();
  var original=db.queryForMap("SELECT a.* FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_type='PAYMENT' AND v.source_doc_id=?",payment);
  assertThat(original.get("currency_id")).isEqualTo(base);assertThat(original.get("original_currency_id")).isEqualTo(currency);amount(original,"amount_local","700");amount(original,"amount_original","100");
  advances.classify(payment,new SupplierPrepaymentService.Classify("匿名原付款用途明确分配",List.of(new SupplierPrepaymentService.Category("GOODS",n("60"),n("420")),new SupplierPrepaymentService.Category("MOULD",n("40"),n("280")))));
  UUID payable=receipt(fixture,world,currency);classifications.classifySource(payable,new FinanceOpenItemClassificationContracts.SourceInput(UUID.randomUUID(),-1,null,"匿名采购正式应付全货款",List.of(new FinanceOpenItemClassificationContracts.Part("GOODS",n("80"),n("560")))));
  var applyInput=new SupplierPrepaymentService.Apply(UUID.randomUUID(),payable,"MOULD","GOODS",n("20"),"明确原预付转到本笔货款");
  var applied=advances.apply(payment,applyInput);assertThat(advances.apply(payment,applyInput).get("id")).isEqualTo(applied.get("id"));
  amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",payable),"amount_balance","420");
  var summary=summary(world.supplierId());amount(summary,"goodsBalance","0");amount(summary,"mouldBalance","-140");amount(summary,"totalBalance","-140");amount(summary,"__formalPayableBalance","420");amount(summary,"__unappliedAdvanceLocal","560");amount(summary,"goodsPaidAmount","420");amount(summary,"mouldPaidAmount","280");amount(summary,"goodsOffsetAmount","140");amount(summary,"mouldOffsetAmount","-140");
  assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,account)).isEqualByComparingTo("900");
  amount(advances.detail(payment),"remainingOriginal","80");
  fixture.loginAs(reviewer);assertThat(payments.unapprovalEligibility(payment).eligible()).isFalse();assertThatThrownBy(()->payments.reverse(payment)).isInstanceOf(ApiException.class).hasMessageContaining("预付应用");fixture.loginAs(world.superAdminUserId());
  var refund=advances.createRefund(payment,new SupplierPrepaymentService.Refund(UUID.randomUUID(),"GOODS",n("10"),account,currency,n("9"),n("7.2"),n("1"),"真实退回原币10，银行净到9手续费1",OffsetDateTime.now(),"匿名真实退款回单"));UUID refundId=(UUID)refund.get("id");
  assertThatThrownBy(()->advances.approveRefund(refundId)).isInstanceOf(ApiException.class).hasMessageContaining("制单人");
  UUID refundReviewer=fixture.createUserWithPerms(world,"refund-reviewer","finance_receipt:view","finance_receipt:approve","finance_receipt:reverse","finance_report:view","ar_ap_ledger:view","finance:view:all");fixture.loginAs(refundReviewer);advances.approveRefund(refundId);fixture.loginAs(world.superAdminUserId());
  amount(db.queryForMap("SELECT * FROM finance_supplier_advance_refunds WHERE id=?",refundId),"source_local","70");
  assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,account)).isEqualByComparingTo("909");
  amount(advances.detail(payment),"remainingOriginal","70");
  summary=summary(world.supplierId());amount(summary,"goodsBalance","70");amount(summary,"mouldBalance","-140");amount(summary,"totalBalance","-70");amount(summary,"__formalPayableBalance","420");amount(summary,"__unappliedAdvanceLocal","490");amount(summary,"__goodsCashBookDelta","-2");amount(summary,"goodsPaidAmount","348");
  assertThat(db.queryForObject("SELECT count(*) FROM finance_gl_settlement_reservations WHERE owner_kind IN('SUPPLIER_ADVANCE_APPLICATION','SUPPLIER_ADVANCE_REFUND') AND owner_id IN(?,?) AND status='COMMITTED'",Integer.class,applied.get("id"),refundId)).isEqualTo(2);
  advances.reverseApplication((UUID)applied.get("id"),"按原应用对称撤回");fixture.loginAs(refundReviewer);advances.reverseRefund(refundId,"按实际退款原资金对称撤回");fixture.loginAs(reviewer);payments.reverse(payment);fixture.loginAs(world.superAdminUserId());
  amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",payable),"amount_balance","560");
  assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,account)).isEqualByComparingTo("1000");
  assertThat(db.queryForObject("SELECT status FROM finance_supplier_advances WHERE payment_id=?",String.class,payment)).isEqualTo("REVERSED");
  summary=summary(world.supplierId());amount(summary,"totalBalance","560");amount(summary,"__formalPayableBalance","560");amount(summary,"__unappliedAdvanceLocal","0");
  assertThat(db.queryForObject("SELECT count(*) FROM finance_gl_settlement_reservations WHERE owner_kind IN('SUPPLIER_ADVANCE_APPLICATION','SUPPLIER_ADVANCE_REFUND') AND owner_id IN(?,?) AND status='RELEASED'",Integer.class,applied.get("id"),refundId)).isEqualTo(2);
 }

 @Test void monthlyFreezeUsesTheApplicationsTargetBookAndNextMonthReversalPreservesFrozenHistory(){
  LocalDate month=BusinessTime.today().withDayOfMonth(1).minusMonths(1),eventDay=month.plusDays(9);
  AdvanceFixture setup;UUID payable,application;
  try(var calendar=org.mockito.Mockito.mockStatic(BusinessTime.class,org.mockito.Mockito.CALLS_REAL_METHODS)){
   calendar.when(BusinessTime::today).thenReturn(eventDay);
   setup=createAdvance("supplier-advance-monthly");
   advances.classify(setup.payment(),new SupplierPrepaymentService.Classify("真实月结预付按原币与本币分类",
      List.of(new SupplierPrepaymentService.Category("GOODS",n("60"),n("420")),new SupplierPrepaymentService.Category("MOULD",n("40"),n("280")))));
   payable=receipt(setup.fixture(),setup.world(),setup.currency());
   classifications.classifySource(payable,new FinanceOpenItemClassificationContracts.SourceInput(UUID.randomUUID(),-1,null,
      "真实月结应付货款归类",List.of(new FinanceOpenItemClassificationContracts.Part("GOODS",n("80"),n("560")))));
   application=(UUID)advances.apply(setup.payment(),new SupplierPrepaymentService.Apply(UUID.randomUUID(),payable,"MOULD","GOODS",n("20"),"真实预付应用进入原发生月月结")).get("id");
  }
  amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",payable),"amount_balance_original","60");
  amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",payable),"amount_balance","420");
  amount(summary(setup.world().supplierId()),"__formalPayableBalance","420");
  UUID method=db.queryForObject("SELECT settlement_type_id FROM ar_ap_ledger WHERE id=?",UUID.class,payable);
  var frozen=monthly.freeze(new SupplierSettlementContracts.FreezeRequest(setup.world().supplierId(),setup.currency(),month,method,null));
  assertThat(new BigDecimal(frozen.summary().closingBalanceOriginal())).isEqualByComparingTo("60");
  assertThat(new BigDecimal(frozen.summary().closingBalanceLocal())).isEqualByComparingTo("420");
  assertThat(new BigDecimal(frozen.summary().periodOffsetOriginal())).isEqualByComparingTo("20");
  assertThat(new BigDecimal(frozen.summary().periodOffsetLocal())).isEqualByComparingTo("140");
  assertThat(frozen.lines()).hasSize(1);assertThat(frozen.lines().getFirst().ledgerId()).isEqualTo(payable);
  try(var calendar=org.mockito.Mockito.mockStatic(BusinessTime.class,org.mockito.Mockito.CALLS_REAL_METHODS)){
   calendar.when(BusinessTime::today).thenReturn(eventDay.plusDays(1));
   assertThatThrownBy(()->advances.apply(setup.payment(),new SupplierPrepaymentService.Apply(UUID.randomUUID(),payable,"MOULD","GOODS",n("1"),"冻结月份不可倒填新的预付应用")))
      .isInstanceOf(ApiException.class).hasMessageContaining("封账");
  }
  advances.reverseApplication(application,"在下一开放月份按原应用对称撤回");
  amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",payable),"amount_balance_original","80");
  amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",payable),"amount_balance","560");
  amount(summary(setup.world().supplierId()),"__formalPayableBalance","560");
  var retained=monthly.detail(frozen.summary().id());
  assertThat(retained.summary().snapshotHash()).isEqualTo(frozen.summary().snapshotHash());
  assertThat(retained.lines()).isEqualTo(frozen.lines());
  assertThat(retained.summary().closingBalanceOriginal()).isEqualTo(frozen.summary().closingBalanceOriginal());
  assertThat(retained.summary().closingBalanceLocal()).isEqualTo(frozen.summary().closingBalanceLocal());
 }

 private AdvanceFixture createAdvance(String tag){
  var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var world=fixture.seedWorld(tag);fixture.loginAs(world.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted AND status='使用' ORDER BY id LIMIT 1",UUID.class);
  UUID currency=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,'匿名原币',7,'使用')",currency,"ADV-"+currency);
  UUID bankStyle=style("ACCOUNT"),assetStyle=style("ACCOUNT"),apStyle=db.queryForObject("SELECT system_posting_style_id('AP_CONTROL')",UUID.class);
  for(var binding:List.of(Map.entry("1123",assetStyle),Map.entry("2202",apStyle))){
   db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by) VALUES(?,?,'',?,?,'MANUAL','匿名测试明确选择',1,1,?) ON CONFLICT(code) DO UPDATE SET currency_id=excluded.currency_id",binding.getKey(),"匿名原财务科目",base,binding.getKey().equals("1123")?"ASSET":"LIABILITY",world.superAdminUserId());
   db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES(?,?,?) ON CONFLICT(style_id) DO NOTHING",binding.getKey(),binding.getValue(),world.superAdminUserId());
   auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名预付账套","SUP-"+world.supplierId(),"匿名来源供应商","SUPPLIER",world.supplierId(),"真实供应商UUID，非同名匹配",binding.getKey()));
  }
  db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='SUPPLIER_PREPAYMENT_ASSET'",assetStyle);
  for(String role:List.of("FX_GAIN_LOSS","BANK_FEE_EXPENSE"))if(db.queryForObject("SELECT system_posting_style_id(?) IS NULL",Boolean.class,role))db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key=?",style("EXPENSE"),role);
  UUID account=UUID.randomUUID();db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id,init_balance,balance_current) VALUES(?,?,'匿名真实银行','BANK',?,'使用',?,1000,1000)",account,"ADV-BANK-"+account,currency,bankStyle);
  UUID reviewer=fixture.createUserWithPerms(world,tag+"-reviewer","finance_payment:view","finance_payment:approve","finance_payment:reverse","finance:view:all");fixture.grantDataScope(reviewer,"finance",world.employeeId());
  var request=new FinancePaymentSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(world.supplierId());request.setAccountId(account);request.setCurrencyId(currency);request.setExchangeRate(n("7"));request.setAmountOriginal(n("100"));request.setAccountCurrencyId(currency);request.setAccountAmount(n("100"));request.setBankFeeAccountAmount(BigDecimal.ZERO);request.setBankReference("ADV-BANK-"+UUID.randomUUID());request.setBankBookedAt(BusinessTime.startOfDay(BusinessTime.today()));request.setCreateIdempotencyKey("advance-"+UUID.randomUUID());request.setItems(List.of());
  UUID payment=payments.create(request).getId();fixture.loginAs(reviewer);payments.approve(payment);fixture.loginAs(world.superAdminUserId());
  return new AdvanceFixture(fixture,world,base,currency,account,reviewer,payment);
 }
 private record AdvanceFixture(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,UUID base,UUID currency,UUID account,UUID reviewer,UUID payment){}

 UUID receipt(FullChainEndToEndTest fixture,FullChainEndToEndTest.World w,UUID currency){return receipt(fixture,w,currency,false);}
 UUID receipt(FullChainEndToEndTest fixture,FullChainEndToEndTest.World w,UUID currency,boolean nativeSource){return receipt(fixture,w,currency,nativeSource,true);}
 UUID receipt(FullChainEndToEndTest fixture,FullChainEndToEndTest.World w,UUID currency,boolean nativeSource,boolean qualify){
  UUID terms=db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class);UUID finance=fixture.createApprover(w);
  var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(terms);
  var ordered=new com.uten.imp.features.purchase.order.dto.OrderItemLine();ordered.setGoodsId(w.goodsA());ordered.setUnitId(w.unitId());ordered.setUnitRate(BigDecimal.ONE);ordered.setQty(n("2"));ordered.setPrice(n("40"));order.setItems(List.of(ordered));UUID orderId=orders.create(order).getId();procurementFinance.submit("PURCHASE",orderId);fixture.loginAs(finance);fixture.approvePendingFinance("PURCHASE",orderId,n("7"));fixture.loginAs(w.superAdminUserId());
  UUID orderItem=db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,orderId);
  var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());request.setCurrencyId(currency);request.setExchangeRate(n("7"));request.setTaxRate(BigDecimal.ZERO);request.setSettlementMethodId(terms);
  var received=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();received.setGoodsId(w.goodsA());received.setUnitId(w.unitId());received.setUnitRate(BigDecimal.ONE);received.setQty(n("2"));received.setPrice(n("40"));received.setOrderItemId(orderItem);request.setItems(List.of(received));UUID receipt=receipts.create(request).getId();receipts.approve(receipt);
  if(!qualify)return receipt;
  UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?",UUID.class,receipt);
  inspections.dispose("PURCHASE",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"匿名原货全部合格","advance-pass-"+receipt));
  UUID event=db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",UUID.class,inspection);fixture.loginAs(fixture.createIqcWarehouseConfirmer(w,"advance-stock-"+receipt));
  stockIn.confirm("PURCHASE",receipt,new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest("advance-stock-"+receipt,List.of(new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem(event,n("2"),n("2"),"ADV-A01",w.warehouseId()))));fixture.loginAs(w.superAdminUserId());
  if(nativeSource)return receipt;
  return db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='PURCHASE_RECEIPT' AND source_doc_id=? AND NOT is_deleted",UUID.class,receipt);
 }
 private UUID style(String category){UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,?,0,'使用')",id,"ADV-ST-"+id,"匿名明确科目-"+id,category);return id;}
 private Map<String,Object> summary(UUID supplier){String code=db.queryForObject("SELECT code FROM suppliers WHERE id=?",String.class,supplier);var response=reports.arApSummaryTemplate("AP",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),code,1,50,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);var matching=response.rows().stream().filter(row->supplier.toString().equals(Objects.toString(row.get("__supplierId"),""))).toList();assertThat(matching).hasSize(1);return matching.getFirst();}
 private static BigDecimal n(String s){return new BigDecimal(s);}
 private static void amount(Map<String,Object> row,String key,String expected){assertThat(row.get(key)).isNotNull();assertThat(new BigDecimal(row.get(key).toString())).as(key).isEqualByComparingTo(expected);}
}
