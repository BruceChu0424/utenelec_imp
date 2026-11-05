package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.payables.*;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput;
import com.uten.imp.features.finance.report.*;
import com.uten.imp.features.finance.statement.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
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

/** Real anonymous native advances: cash, formal AP and the original net statement are separate facts. */
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
class SupplierAdvanceStatementReplayPostgresTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FinanceScopedChainDatabase.register(r,SupplierAdvanceStatementReplayPostgresTest.class);}
 @Autowired AutowireCapableBeanFactory beans;
 @Autowired JdbcTemplate db;
 @Autowired FinancePaymentService payments;
 @Autowired SupplierPrepaymentService advances;
 @Autowired SupplierSettlementService settlements;
 @Autowired FinanceAuxiliaryService auxiliaries;
 @Autowired FinanceOpenItemClassificationService classifications;
 @Autowired FinanceReportService reports;
 @Autowired PartyMonthlySummaryService monthly;
 @Autowired org.springframework.transaction.PlatformTransactionManager manager;
 @jakarta.persistence.PersistenceContext jakarta.persistence.EntityManager em;
 @AfterEach void logout(){SecurityContextHolder.clearContext();}

 @Test void nativeCashNeverBecomesFormalApAndApplicationConsumesBothFrozenFxBasesExactlyOnce(){
  var s=setup("advance-statement-fx");
  var helper=new SupplierPrepaymentPostgresTest();beans.autowireBean(helper);
  UUID payable=helper.receipt(s.fixture,s.world,s.currency);
  classifications.classifySource(payable,new FinanceOpenItemClassificationContracts.SourceInput(UUID.randomUUID(),-1,null,"原应付全货款",List.of(new FinanceOpenItemClassificationContracts.Part("GOODS",n("80"),n("560")))));
  UUID payment=payment(s,BusinessTime.today(),"6.9");
  advances.classify(payment,new SupplierPrepaymentService.Classify("实际预付用途",List.of(new SupplierPrepaymentService.Category("GOODS",n("40"),n("276")))));
  assertNoSyntheticAp(payment);amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",payable),"amount_balance","560");
  var before=basic(s);amount(before,"paidAmount","276");amount(before,"settledAmount","0");amount(before,"balance","284");
  amount(before,"__formalPayableBalance","560");amount(before,"__unappliedAdvanceLocal","276");
  monthly.reconcileNow("AP",s.world.supplierId());
  var app=advances.apply(payment,new SupplierPrepaymentService.Apply(UUID.randomUUID(),payable,"GOODS","GOODS",n("20"),"两端冻结汇率不同"));
  assertThat(db.queryForObject("SELECT count(*) FROM party_month_dirty WHERE side='AP' AND party_id=? AND month_start=?",Integer.class,s.world.supplierId(),BusinessTime.today().withDayOfMonth(1))).as("an application dirties a previously healed projection in its own transaction").isPositive();
  amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",payable),"amount_balance","420");
  var after=basic(s);amount(after,"paidAmount","276");amount(after,"settledAmount","0");amount(after,"offsetAmount","140");
  amount(after,"__formalPayableBalance","420");amount(after,"__unappliedAdvanceLocal","138");amount(after,"balance","282");
  amount(template(s),"totalBalance","282");var annual=yearMonth(s,BusinessTime.today());amount(annual,"balance","282");
  amount(annual,"actualCashLocal","276");amount(annual,"__actualCashLocal","276");amount(annual,"__formalApClosingLocal","420");amount(annual,"__advanceAssetClosingLocal","138");
  amount(annual,"__formalApDeltaLocal","420");amount(annual,"__advanceAssetDeltaLocal","138");amount(annual,"__netDeltaLocal","282");
  assertThat(annual.get("__settledMeaning")).isEqualTo("BOOK_NET_MOVEMENT");
  monthly.reconcileNow("AP",s.world.supplierId());
  var refund=advances.createRefund(payment,new SupplierPrepaymentService.Refund(UUID.randomUUID(),"GOODS",n("10"),s.account,s.currency,n("9"),n("7.2"),n("1"),"实际退款净到9、手续费1，原资产按6.9释放",OffsetDateTime.now(),"匿名真实退款回单"));
  UUID refundReviewer=s.fixture.createUserWithPerms(s.world,"statement-refund-"+UUID.randomUUID(),"finance_receipt:view","finance_receipt:approve","finance_receipt:reverse","finance_report:view","ar_ap_ledger:view","finance:view:all");
  s.fixture.loginAs(refundReviewer);advances.approveRefund((UUID)refund.get("id"));s.fixture.loginAs(s.world.superAdminUserId());
  assertThat(db.queryForObject("SELECT count(*) FROM party_month_dirty WHERE side='AP' AND party_id=? AND month_start=?",Integer.class,s.world.supplierId(),BusinessTime.today().withDayOfMonth(1))).as("actual refund invalidates the healed month").isPositive();
  var refunded=basic(s);amount(refunded,"paidAmount","204");amount(refunded,"settledAmount","0");amount(refunded,"exchangeDifferenceLocal","-3");
  amount(refunded,"__formalPayableBalance","420");amount(refunded,"__unappliedAdvanceLocal","69");amount(refunded,"balance","351");amount(template(s),"totalBalance","351");
  var refundMonth=yearMonth(s,BusinessTime.today());amount(refundMonth,"balance","351");amount(refundMonth,"__actualCashLocal","211.2");amount(refundMonth,"__formalApClosingLocal","420");amount(refundMonth,"__advanceAssetClosingLocal","69");
  assertThat(actualBankOutLocal(s.account)).as("bank receives 9 at 7.2; withheld fee is an expense, not another bank receipt").isEqualByComparingTo("211.2");
  var details=reports.partyStatementDetail(s.world.supplierId(),"AP",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),1,500).rows();
  var assetRelease=details.stream().filter(r->"预付资产应用".equals(r.get("__eventType"))).findFirst().orElseThrow();amount(assetRelease,"__actualCashLocal","0");amount(assetRelease,"__advanceAssetDeltaLocal","-138");amount(assetRelease,"__formalApDeltaLocal","0");
  var targetApply=details.stream().filter(r->"预付应用".equals(r.get("__eventType"))).findFirst().orElseThrow();amount(targetApply,"__actualCashLocal","0");amount(targetApply,"__formalApDeltaLocal","-140");
  var refundCash=details.stream().filter(r->"预付退款".equals(r.get("__eventType"))).findFirst().orElseThrow();amount(refundCash,"actualCashLocal","-64.8");amount(refundCash,"__actualCashLocal","-64.8");amount(refundCash,"__advanceAssetDeltaLocal","0");
  var refundAsset=details.stream().filter(r->"预付资产退款".equals(r.get("__eventType"))).findFirst().orElseThrow();amount(refundAsset,"__actualCashLocal","0");amount(refundAsset,"__advanceAssetDeltaLocal","-69");assertThat(details.indexOf(refundCash)).isLessThan(details.indexOf(refundAsset));
  var flow=reports.partyStatementFlow(s.world.supplierId(),"AP",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),1,500);
  var keys=flow.columns().stream().map(ReportColumn::key).toList();assertThat(keys.indexOf("actualCashLocal")).isEqualTo(keys.indexOf("receiptLocal")+1);
  assertThat(keys.indexOf("type")).isEqualTo(keys.indexOf("refNo")+1);
  assertThat(flow.columns().stream().filter(c->c.key().equals("receiptLocal")).findFirst().orElseThrow().label()).isEqualTo("往来冲减金额(本)");
  assertThat(flow.columns().stream().filter(c->c.key().equals("salesLocal")).findFirst().orElseThrow().label()).isEqualTo("往来立账金额(本)");
  assertThat(flow.columns().stream().filter(c->c.key().equals("actualCashLocal")).findFirst().orElseThrow().label()).isEqualTo("实际付款净额(本)");
  amountTotal(flow,"actualCashLocal","211.2");
  var onlyApplication=reports.partyStatementFlow(s.world.supplierId(),"AP",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),1,500,Map.of("type","预付应用"),null,null);assertThat(onlyApplication.rows()).hasSize(1);amount(onlyApplication.rows().getFirst(),"actualCashLocal","0");amountTotal(onlyApplication,"actualCashLocal","0");
  var onlyActualCash=reports.partyStatementFlow(s.world.supplierId(),"AP",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),1,500,Map.of("search.actualCashLocal","276"),"actualCashLocal","desc");assertThat(onlyActualCash.rows()).hasSize(1);amountTotal(onlyActualCash,"actualCashLocal","276");
  var annualReport=reports.partyAnnualStatement(s.world.supplierId(),"AP",BusinessTime.today().getYear(),1,50);
  var annualKeys=annualReport.columns().stream().map(ReportColumn::key).toList();assertThat(annualKeys.indexOf("actualCashLocal")).isEqualTo(annualKeys.indexOf("settled")+1);
  assertThat(annualReport.columns().stream().filter(c->c.key().equals("settled")).findFirst().orElseThrow().label()).isEqualTo("往来冲减金额");amountTotal(annualReport,"actualCashLocal","211.2");
  assertThat(annualReport.columns().stream().filter(c->c.key().equals("posted")).findFirst().orElseThrow().label()).isEqualTo("往来立账金额");
  s.fixture.loginAs(refundReviewer);advances.reverseRefund((UUID)refund.get("id"),"实际退款对称撤回");s.fixture.loginAs(s.world.superAdminUserId());
  amount(basic(s),"balance","282");amount(yearMonth(s,BusinessTime.today()),"balance","282");
  amount(yearMonth(s,BusinessTime.today()),"actualCashLocal","276");assertThat(actualBankOutLocal(s.account)).isEqualByComparingTo("276");
  advances.reverseApplication((UUID)app.get("id"),"原应用对称撤回");s.fixture.loginAs(s.reviewer);payments.reverse(payment);s.fixture.loginAs(s.world.superAdminUserId());
  assertNoSyntheticAp(payment);amount(db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",payable),"amount_balance","560");
  var reversed=basic(s);amount(reversed,"paidAmount","0");amount(reversed,"settledAmount","0");amount(reversed,"offsetAmount","0");
  amount(reversed,"__formalPayableBalance","560");amount(reversed,"__unappliedAdvanceLocal","0");amount(reversed,"balance","560");amount(yearMonth(s,BusinessTime.today()),"balance","560");
  amount(yearMonth(s,BusinessTime.today()),"actualCashLocal","0");assertThat(actualBankOutLocal(s.account)).isZero();
 }

 @ParameterizedTest @CsvSource({"false,false","false,true","true,false","true,true"})
 void actualBankMovementKeepsPaymentFeesOutsidePrincipalAcrossLinesAndBothSupportedAccountCurrencies(boolean withLines,boolean baseBank){
  var s=setup("actual-bank-fee-"+withLines+"-"+baseBank);UUID account=s.account,currency=s.currency;
  if(baseBank){
   currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted AND status='使用' ORDER BY id LIMIT 1",UUID.class);account=UUID.randomUUID();
   db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id,init_balance,balance_current) VALUES(?,?,'匿名本币真实银行','BANK',?,'使用',?,1000,1000)",account,"ST-BASE-"+account,currency,style("ACCOUNT"));
  }
  UUID payable=null,sourceClassification=null;
  if(withLines){
   var helper=new SupplierPrepaymentPostgresTest();beans.autowireBean(helper);payable=helper.receipt(s.fixture,s.world,s.currency);
   sourceClassification=classifications.classifySource(payable,new FinanceOpenItemClassificationContracts.SourceInput(UUID.randomUUID(),-1,null,"原应付全部货款",List.of(new FinanceOpenItemClassificationContracts.Part("GOODS",n("80"),n("560"))))).batchId();
  }
  var request=paymentRequest(s,BusinessTime.today(),"6.9");request.setAccountId(account);request.setAccountCurrencyId(currency);
  request.setAccountAmount(n(baseBank?"289.8":"42"));request.setBankFeeAccountAmount(n(baseBank?"13.8":"2"));
  if(withLines){var line=new FinancePaymentLineInput();line.setAppliedLedgerId(payable);line.setSupplierId(s.world.supplierId());line.setAmountOriginal(n("40"));request.setItems(List.of(line));}
  UUID payment=payments.create(request).getId();s.fixture.loginAs(s.reviewer);payments.approve(payment);s.fixture.loginAs(s.world.superAdminUserId());
  if(withLines){UUID line=db.queryForObject("SELECT id FROM finance_payment_lines WHERE payment_id=? AND NOT is_deleted",UUID.class,payment);classifications.classifyPayment(line,new FinanceOpenItemClassificationContracts.PaymentInput(UUID.randomUUID(),-1,sourceClassification,"原货款/账面分别冻结",List.of(new FinanceOpenItemClassificationContracts.PaymentPart("GOODS",n("40"),n("276"),n("280")))));}
  else advances.classify(payment,new SupplierPrepaymentService.Classify("原资产本金不含银行费用",List.of(new SupplierPrepaymentService.Category("GOODS",n("40"),n("276")))));
  var stored=db.queryForMap("SELECT amount_local,account_amount_local,bank_fee_local FROM finance_payments WHERE id=?",payment);
  amount(stored,"amount_local","276");amount(stored,"account_amount_local","289.8");amount(stored,"bank_fee_local","13.8");
  assertThat(actualBankOutLocal(account)).isEqualByComparingTo("289.8");
  var flow=reports.partyStatementFlow(s.world.supplierId(),"AP",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),1,500);
  var bankEvent=flow.rows().stream().filter(r->"付款".equals(r.get("type"))).findFirst().orElseThrow();amount(bankEvent,"actualCashLocal","289.8");amount(bankEvent,"__actualCashLocal","289.8");
  amount(bankEvent,"receiptLocal",withLines?"280":"0");amountTotal(flow,"actualCashLocal","289.8");amount(yearMonth(s,BusinessTime.today()),"actualCashLocal","289.8");
  flow.rows().stream().filter(r->!"付款".equals(r.get("type"))).forEach(r->amount(r,"actualCashLocal","0"));
  reports.partyAnnualStatement(s.world.supplierId(),"AP",BusinessTime.today().getYear(),1,50).rows().stream()
    .filter(r->!BusinessTime.today().toString().substring(0,7).equals(r.get("ym"))).forEach(r->amount(r,"actualCashLocal","0"));
  amount(basic(s),"paidAmount","276");amount(basic(s),"balance",withLines?"280":"-276");
  s.fixture.loginAs(s.reviewer);payments.reverse(payment);s.fixture.loginAs(s.world.superAdminUserId());
  assertThat(actualBankOutLocal(account)).isZero();amount(yearMonth(s,BusinessTime.today()),"actualCashLocal","0");
  var reversed=reports.partyStatementFlow(s.world.supplierId(),"AP",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),1,500);amountTotal(reversed,"actualCashLocal","0");
  var reversal=reversed.rows().stream().filter(r->"付款反审".equals(r.get("type"))).findFirst().orElseThrow();amount(reversal,"actualCashLocal","-289.8");
  amount(basic(s),"paidAmount","0");amount(basic(s),"balance",withLines?"560":"0");
  assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,account)).isEqualByComparingTo("1000");
 }

 @Test void actualCashTotalsKeepARealUnknownPendingWithoutChangingOtherBookTotals()throws Exception{
  var columns=List.of(ReportColumn.money("actualCashLocal","实际付款净额(本)").withUnitLabel("元").totaled("合计实际付款净额(本)"),ReportColumn.money("receiptLocal","往来冲减金额(本)").withUnitLabel("元").totaled("合计往来冲减金额(本)"));
  var method=FinanceReportService.class.getDeclaredMethod("reportTotalSpecs",List.class,List.class);method.setAccessible(true);
  var raw=(List<?>)method.invoke(null,columns,columns);var specs=raw.stream().map(com.uten.imp.common.report.ReportTotalsCalculator.Spec.class::cast).toList();
  assertThat(specs.stream().filter(s->s.key().equals("actualCashLocal")).findFirst().orElseThrow().requireComplete()).isTrue();
  assertThat(specs.stream().filter(s->s.key().equals("receiptLocal")).findFirst().orElseThrow().requireComplete()).isFalse();
  String source="SELECT 9::numeric AS \"actualCashLocal\",9::numeric AS \"receiptLocal\" UNION ALL SELECT NULL::numeric,1::numeric";
  var totals=new org.springframework.transaction.support.TransactionTemplate(manager).execute(status->com.uten.imp.common.report.ReportTotalsCalculator.compute(em,source,"","",Map.of(),specs));
  assertThat(totals).isNotNull();assertThat(totals.stream().filter(t->t.key().equals("actualCashLocal")).findFirst().orElseThrow().groups().getFirst().value()).isNull();
  assertThat(new BigDecimal(totals.stream().filter(t->t.key().equals("receiptLocal")).findFirst().orElseThrow().groups().getFirst().value().toString())).isEqualByComparingTo("10");
 }

 @Test void crossYearNativeAdvanceReversalUsesItsActualDatedBankAndGlProofWithoutInventingAp() throws Exception {
  var s=setup("advance-replay-year");LocalDate original=LocalDate.of(BusinessTime.today().getYear()-1,12,15);
  UUID payment=payment(s,original,"6.9");monthly.reconcileNow("AP",s.world.supplierId());
  amount(yearMonth(s,original),"balance","-276");
  s.fixture.loginAs(s.reviewer);payments.reverse(payment);s.fixture.loginAs(s.world.superAdminUserId());
  assertNoSyntheticAp(payment);
  var dates=db.queryForMap("SELECT p.reversed_at payment_reverse,a.reversed_at advance_reverse,v.voucher_date FROM finance_payments p JOIN finance_supplier_advances a ON a.payment_id=p.id JOIN gl_vouchers v ON v.source_doc_id=p.id AND v.source_type='PAYMENT_REV' WHERE p.id=?",payment);
  assertThat(dates.get("payment_reverse")).isEqualTo(dates.get("advance_reverse"));assertThat(dates.get("voucher_date").toString()).isEqualTo(BusinessTime.today().toString());
  UUID cashTerms=db.queryForObject("SELECT id FROM settlement_methods WHERE system_role='CASH' AND NOT is_deleted AND status='使用' ORDER BY id LIMIT 1",UUID.class);
  var frozen=settlements.freeze(new SupplierSettlementContracts.FreezeRequest(s.world.supplierId(),s.currency,original.withDayOfMonth(1),cashTerms,null));
  assertThat(frozen.lines()).isEmpty();assertThat(new BigDecimal(frozen.summary().closingBalanceLocal())).isZero();
  var previous=yearMonth(s,original);amount(previous,"balance","-276");amount(previous,"__actualCashLocal","276");amount(previous,"__formalApClosingLocal","0");amount(previous,"__advanceAssetClosingLocal","276");
  var current=yearMonth(s,BusinessTime.today());amount(current,"prevBalance","-276");amount(current,"balance","0");amount(current,"__actualCashLocal","-276");amount(current,"__formalApClosingLocal","0");amount(current,"__advanceAssetClosingLocal","0");
  assertThat(db.queryForObject("SELECT fn_finance_supplier_advance_replayable(?)",Boolean.class,payment)).isTrue();
  db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='SUPPLIER_PREPAYMENT_ASSET'",style("ACCOUNT"));
  assertThat(db.queryForObject("SELECT fn_finance_supplier_advance_replayable(?)",Boolean.class,payment)).as("replay uses the frozen asset identity, not today's role").isTrue();
  assertRejectedProofMutations(s,payment);
 }

 /** Shadow only this connection's read fixture. No actual immutable fact or production guard is edited. */
 private void assertRejectedProofMutations(Setup setup,UUID payment) {
  new org.springframework.transaction.support.TransactionTemplate(manager).executeWithoutResult(status->{
   try {em.unwrap(org.hibernate.Session.class).doWork(connection->{try{proofMutations(connection,setup,payment);}catch(java.sql.SQLException failure){throw failure;}catch(Exception failure){throw new java.sql.SQLException("historical read proof failed",failure);}});}
   finally {status.setRollbackOnly();}
  });
 }
 private void proofMutations(java.sql.Connection connection,Setup setup,UUID payment) throws Exception {
   try(var sql=connection.createStatement()) {
    sql.execute("SET LOCAL search_path=pg_temp,public");
    for(String table:List.of("finance_payments","finance_supplier_advances","gl_vouchers","gl_entries","finance_reconciliations","finance_gl_entry_allocations","ar_ap_ledger","finance_payment_lines","party_monthly_summaries","party_month_dirty"))
     sql.execute("CREATE TEMP TABLE "+table+" ON COMMIT DROP AS SELECT * FROM public."+table);
    assertThat(proof(connection,payment)).isTrue();
    for(String mutation:List.of(
      "DELETE FROM finance_supplier_advances WHERE payment_id='"+payment+"'",
      "UPDATE finance_supplier_advances SET amount_local=amount_local+1 WHERE payment_id='"+payment+"'",
      "UPDATE finance_supplier_advances SET currency_id='"+UUID.randomUUID()+"' WHERE payment_id='"+payment+"'",
      "UPDATE finance_supplier_advances SET supplier_id='"+UUID.randomUUID()+"' WHERE payment_id='"+payment+"'",
      "UPDATE finance_supplier_advances SET style_id='"+UUID.randomUUID()+"' WHERE payment_id='"+payment+"'",
      "UPDATE finance_payments SET reversed_at=reversed_at+INTERVAL '1 second' WHERE id='"+payment+"'",
      "UPDATE gl_vouchers SET voucher_date=voucher_date+1 WHERE source_type='PAYMENT_REV' AND source_doc_id='"+payment+"'",
      "UPDATE gl_entries SET amount=amount+1 WHERE voucher_id IN(SELECT id FROM gl_vouchers WHERE source_type='PAYMENT_REV' AND source_doc_id='"+payment+"')",
      "DELETE FROM finance_reconciliations WHERE source_doc_id='"+payment+"' AND entry_kind='REVERSAL'",
      "UPDATE finance_reconciliations SET account_id='"+UUID.randomUUID()+"' WHERE source_doc_id='"+payment+"' AND entry_kind='REVERSAL'",
      "DELETE FROM finance_gl_entry_allocations WHERE entry_id IN(SELECT e.id FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_type='PAYMENT_REV' AND v.source_doc_id='"+payment+"')")) {
      var point=connection.setSavepoint();sql.executeUpdate(mutation);assertThat(proof(connection,payment)).as(mutation.split(" ")[0]+" proof fault must not become a dated zero").isFalse();
      try(var guard=connection.prepareStatement("SELECT count(*) FROM finance_payments payment WHERE payment.id=? AND "+com.uten.imp.features.finance.SupplierAdvanceReplaySql.unknown("payment"))){guard.setObject(1,payment);try(var row=guard.executeQuery()){assertThat(row.next()).isTrue();assertThat(row.getInt(1)).as("both report and freeze use this exact unknown-proof guard").isEqualTo(1);}}
      connection.rollback(point);
     }
    for(String view:List.of("v_finance_supplier_advance_asset_events","v_finance_supplier_advance_ap_events"))
     sql.execute("CREATE TEMP VIEW "+view+" AS SELECT * FROM public."+view+" WHERE payment_id<>'"+payment+"'");
    assertLegacyReadProof(connection,setup,payment);
   }
 }
 private static boolean proof(java.sql.Connection connection,UUID payment) throws Exception {
  try(var query=connection.prepareStatement("SELECT public.fn_finance_supplier_advance_replayable(?)")){query.setObject(1,payment);try(var row=query.executeQuery()){assertThat(row.next()).isTrue();return row.getBoolean(1);}}
 }
 private void assertLegacyReadProof(java.sql.Connection connection,Setup setup,UUID payment) throws Exception {
  try(var sql=connection.createStatement()) {
   sql.executeUpdate("DELETE FROM finance_supplier_advances WHERE payment_id='"+payment+"'");
   sql.executeUpdate("UPDATE finance_payments SET amount_authority_version=1,reversed_at=NULL,updated_at=now()+INTERVAL '2 years' WHERE id='"+payment+"'");
   assertThat(unknownProof(connection,payment)).as("legacy reversed header cannot use updated_at as an invented event date").isEqualTo(1);
   for(int version:List.of(0,1))for(int status:List.of(1,-1)){sql.executeUpdate("UPDATE finance_payments SET amount_authority_version="+version+",status="+status+" WHERE id='"+payment+"'");assertThat(unknownProof(connection,payment)).as("unproved legacy original/reverse cannot acquire a native fallback").isEqualTo(1);}
   sql.executeUpdate("UPDATE finance_payments SET amount_authority_version=1,status=-1 WHERE id='"+payment+"'");
   UUID ledger=UUID.randomUUID();
   sql.executeUpdate("INSERT INTO ar_ap_ledger(id,direction,open_item_kind,source_doc_type,source_doc_id,bill_no,bill_date,supplier_id,currency_id,amount_original,amount_original_local,status,is_deleted,deleted_at) "
     +"SELECT '"+ledger+"','AP','PREPAYMENT','DIRECT_PAYMENT',id,bill_no,bill_date,supplier_id,currency_id,-amount_original,-amount_local,-1,true,(SELECT reversed_at FROM public.finance_payments WHERE id='"+payment+"') FROM finance_payments WHERE id='"+payment+"'");
   sql.executeUpdate("UPDATE ar_ap_ledger SET amount_balance_original=amount_original,amount_balance=amount_original_local,amount_settled=0,amount_received_original=0,amount_received_local=0 WHERE id='"+ledger+"'");
   assertThat(unknownProof(connection,payment)).as("retained single negative AP is the dated legacy proof").isZero();
   try(var query=connection.prepareStatement("SELECT "+com.uten.imp.features.finance.SupplierAdvanceReplaySql.legacyReversalDate("payment")+"=(SELECT reversed_at FROM public.finance_payments WHERE id=payment.id) FROM finance_payments payment WHERE payment.id=?")){query.setObject(1,payment);try(var row=query.executeQuery()){assertThat(row.next()).isTrue();assertThat(row.getBoolean(1)).as("only the independent ledger deletion date is used").isTrue();}}
   for(String mutation:List.of("supplier_id='"+UUID.randomUUID()+"'","currency_id='"+UUID.randomUUID()+"'","amount_original=amount_original-1","amount_original_local=amount_original_local-1","deleted_at=NULL","status=1","open_item_kind='PAYABLE'")) {
    var point=connection.setSavepoint();sql.executeUpdate("UPDATE ar_ap_ledger SET "+mutation+" WHERE id='"+ledger+"'");assertThat(unknownProof(connection,payment)).as("legacy proof "+mutation.split("=")[0]).isEqualTo(1);connection.rollback(point);
   }
   UUID supplier=db.queryForObject("SELECT supplier_id FROM finance_payments WHERE id=?",UUID.class,payment);
   LocalDate original=db.queryForObject("SELECT bill_date FROM finance_payments WHERE id=?",LocalDate.class,payment);
   var method=Class.forName("com.uten.imp.features.finance.report.FinancePartyStatementSql").getDeclaredMethod("events",boolean.class,String.class);method.setAccessible(true);
   String events=((String)method.invoke(null,false,"1=1")).replace(":pid","'"+supplier+"'::uuid");
   try(var row=sql.executeQuery(events+"SELECT sum(posted_local-settled_local) FROM party_events WHERE event_date<=DATE '"+original+"'")){assertThat(row.next()).isTrue();assertThat(row.getBigDecimal(1)).as("retained negative AP and its cash header are one net source").isEqualByComparingTo("-276");}
   try(var row=sql.executeQuery(events+"SELECT sum(posted_local-settled_local) FROM party_events")){assertThat(row.next()).isTrue();assertThat(row.getBigDecimal(1)).as("legacy original and dated reverse close exactly once").isZero();}
   sql.executeUpdate("DELETE FROM party_monthly_summaries WHERE side='AP' AND party_id='"+supplier+"'");
   sql.executeUpdate("INSERT INTO party_monthly_summaries(side,party_id,currency_id,month_start,net_original,posted_local_sum,settled_local_sum,net_local,event_count,null_original_count) SELECT 'AP',supplier_id,currency_id,date_trunc('month',bill_date)::date,-999,0,999,-999,1,0 FROM finance_payments WHERE id='"+payment+"'");
   sql.executeUpdate("DELETE FROM party_month_dirty WHERE side='AP' AND party_id='"+supplier+"'");
   sql.executeUpdate("ALTER TABLE party_month_dirty ADD PRIMARY KEY(side,party_id,month_start)");
   String migration;try(var input=Objects.requireNonNull(getClass().getClassLoader().getResourceAsStream("db/migration/V1078__supplier_advance_statement_replay.sql"))){migration=new String(input.readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);}
   int backfill=migration.indexOf("INSERT INTO party_month_dirty(side,party_id,month_start,reason)");assertThat(backfill).isGreaterThan(0);sql.executeUpdate(migration.substring(backfill,migration.indexOf(';',backfill)));
   try(var row=sql.executeQuery("SELECT count(*) FROM party_month_dirty WHERE side='AP' AND party_id='"+supplier+"' AND month_start=DATE '1900-01-01'")){assertThat(row.next()).isTrue();assertThat(row.getInt(1)).as("the real forward migration invalidates an old clean legacy cache").isEqualTo(1);}
   assertLegacyPublic(setup,original,"-276","276");
   assertLegacyPublic(setup,BusinessTime.today(),"0","-276");
   sql.executeUpdate("UPDATE finance_payments SET status=1 WHERE id='"+payment+"'");
   sql.executeUpdate("UPDATE ar_ap_ledger SET status=1,is_deleted=false,deleted_at=NULL,exchange_rate=6.9,amount_balance_original=amount_original,amount_balance=amount_original_local WHERE id='"+ledger+"'");
   assertThat(unknownProof(connection,payment)).isZero();assertLegacyPublic(setup,original,"-276","276");
   UUID target=UUID.randomUUID(),line=UUID.randomUUID();
   sql.executeUpdate("INSERT INTO ar_ap_ledger(id,direction,business_type,open_item_kind,source_doc_type,source_doc_id,bill_no,bill_date,supplier_id,currency_id,exchange_rate,amount_original,amount_original_local,amount_balance_original,amount_balance,amount_settled,status,is_deleted) "
     +"SELECT '"+target+"','AP','PURCHASE','PAYABLE','PURCHASE_RECEIPT','"+target+"','ANONYMOUS-RETAINED-AP',bill_date,supplier_id,currency_id,7,80,560,70,490,70,1,false FROM finance_payments WHERE id='"+payment+"'");
   sql.executeUpdate("UPDATE ar_ap_ledger SET amount_original=-30,amount_original_local=-207,amount_balance_original=-30,amount_balance=-207 WHERE id='"+ledger+"'");
   sql.executeUpdate("INSERT INTO finance_payment_lines(id,payment_id,applied_ledger_id,supplier_id,line_no,amount_original,amount_local,applied_amount_local,exchange_diff,is_deleted) SELECT '"+line+"',id,'"+target+"',supplier_id,1,10,69,70,-1,false FROM finance_payments WHERE id='"+payment+"'");
   sql.executeUpdate("UPDATE ar_ap_ledger SET amount_received_original=10,amount_received_local=69 WHERE id='"+target+"'");
   assertThat(unknownProof(connection,payment)).as("partial legacy AP application retains a separately proved remaining advance").isZero();
   assertLegacyPublic(setup,original,"283","276");
   var partial=connection.setSavepoint();
   sql.executeUpdate("DELETE FROM ar_ap_ledger WHERE id='"+ledger+"'");
   assertThat(unknownProof(connection,payment)).as("partial allocation cannot silently discard its unproved residual").isEqualTo(1);
   assertThatThrownBy(()->reports.payableSummary(code(setup),original.withDayOfMonth(1),original.withDayOfMonth(original.lengthOfMonth()),1,50)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
   connection.rollback(partial);
   sql.executeUpdate("DELETE FROM ar_ap_ledger WHERE id='"+ledger+"'");
   sql.executeUpdate("UPDATE finance_payment_lines SET amount_original=40,amount_local=276,applied_amount_local=280,exchange_diff=-4 WHERE id='"+line+"'");
   sql.executeUpdate("UPDATE ar_ap_ledger SET amount_received_original=40,amount_received_local=276,amount_balance_original=40,amount_balance=280,amount_settled=280 WHERE id='"+target+"'");
   assertThat(unknownProof(connection,payment)).as("fully allocated legacy line facts conserve both header currencies").isZero();assertLegacyPublic(setup,original,"280","276");
   UUID credit=UUID.randomUUID();
   sql.executeUpdate("INSERT INTO ar_ap_ledger(id,direction,business_type,open_item_kind,source_doc_type,source_doc_id,bill_no,bill_date,supplier_id,currency_id,exchange_rate,amount_original,amount_original_local,amount_balance_original,amount_balance,status,is_deleted) "
     +"SELECT '"+credit+"','AP','PURCHASE','CREDIT','PURCHASE_RETURN','"+credit+"','ANONYMOUS-RETAINED-CREDIT',bill_date,supplier_id,currency_id,7,-5,-35,-5,-35,1,false FROM finance_payments WHERE id='"+payment+"'");
   assertLegacyPublic(setup,original,"245","276");
   sql.executeUpdate("UPDATE finance_payments SET amount_authority_version=0,amount_local=NULL WHERE id='"+payment+"'");assertThat(unknownProof(connection,payment)).as("authority zero has no guessed cash basis").isEqualTo(1);
  }
 }
 private void assertLegacyPublic(Setup setup,LocalDate month,String balance,String cash) {
  LocalDate start=month.withDayOfMonth(1),end=month.withDayOfMonth(month.lengthOfMonth());
  var basic=reports.payableSummary(code(setup),start,end,1,50);assertThat(basic.rows()).hasSize(1);amount(basic.rows().getFirst(),"balance",balance);amount(basic.rows().getFirst(),"paidAmount",cash);
  var classified=reports.arApSummaryTemplate("AP",start,end,code(setup),1,50,FinanceReportColumnOptions.NONE);assertThat(classified.rows()).hasSize(1);amount(classified.rows().getFirst(),"totalBalance",balance);
  var annual=yearMonth(setup,month);amount(annual,"balance",balance);amount(annual,"actualCashLocal",cash);
 }
 private static int unknownProof(java.sql.Connection connection,UUID payment) throws Exception {
  try(var query=connection.prepareStatement("SELECT count(*) FROM finance_payments payment WHERE payment.id=? AND "+com.uten.imp.features.finance.SupplierAdvanceReplaySql.unknown("payment"))){query.setObject(1,payment);try(var row=query.executeQuery()){assertThat(row.next()).isTrue();return row.getInt(1);}}
 }

 private record Setup(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,UUID currency,UUID account,UUID reviewer){}
 private Setup setup(String name){
  var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var world=fixture.seedWorld(name);fixture.loginAs(world.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted AND status='使用' ORDER BY id LIMIT 1",UUID.class);
  UUID currency=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,'匿名原币',6.9,'使用')",currency,"ST-"+currency);
  UUID bankStyle=style("ACCOUNT"),assetStyle=style("ACCOUNT"),apStyle=db.queryForObject("SELECT system_posting_style_id('AP_CONTROL')",UUID.class);
  for(var binding:List.of(Map.entry("1123",assetStyle),Map.entry("2202",apStyle))){
   db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by) VALUES(?,?,'',?,?,'MANUAL','匿名测试明确选择',1,1,?) ON CONFLICT(code) DO UPDATE SET currency_id=excluded.currency_id",binding.getKey(),"匿名原财务科目",base,binding.getKey().equals("1123")?"ASSET":"LIABILITY",world.superAdminUserId());
   db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES(?,?,?) ON CONFLICT(style_id) DO NOTHING",binding.getKey(),binding.getValue(),world.superAdminUserId());
   auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名预付账套","SUP-"+world.supplierId(),"匿名来源供应商","SUPPLIER",world.supplierId(),"真实供应商UUID",binding.getKey()));
  }
  db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='SUPPLIER_PREPAYMENT_ASSET'",assetStyle);
  for(String role:List.of("FX_GAIN_LOSS","BANK_FEE_EXPENSE"))if(db.queryForObject("SELECT system_posting_style_id(?) IS NULL",Boolean.class,role))db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key=?",style("EXPENSE"),role);
  UUID account=UUID.randomUUID();db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id,init_balance,balance_current) VALUES(?,?,'匿名真实银行','BANK',?,'使用',?,1000,1000)",account,"ST-BANK-"+account,currency,bankStyle);
  UUID reviewer=fixture.createUserWithPerms(world,"advance-replay-reviewer-"+UUID.randomUUID(),"finance_payment:view","finance_payment:approve","finance_payment:reverse","finance:view:all");fixture.grantDataScope(reviewer,"finance",world.employeeId());
  return new Setup(fixture,world,currency,account,reviewer);
 }
 private UUID payment(Setup s,LocalDate date,String rate){
  var r=paymentRequest(s,date,rate);
  UUID payment=payments.create(r).getId();s.fixture.loginAs(s.reviewer);payments.approve(payment);s.fixture.loginAs(s.world.superAdminUserId());return payment;
 }
 private FinancePaymentSaveRequest paymentRequest(Setup s,LocalDate date,String rate){
  var r=new FinancePaymentSaveRequest();r.setBillDate(date);r.setSupplierId(s.world.supplierId());r.setAccountId(s.account);r.setCurrencyId(s.currency);r.setExchangeRate(n(rate));r.setAmountOriginal(n("40"));r.setAccountCurrencyId(s.currency);r.setAccountAmount(n("40"));r.setBankFeeAccountAmount(BigDecimal.ZERO);r.setBankReference("ST-BANK-"+UUID.randomUUID());r.setBankBookedAt(date.equals(BusinessTime.today())?OffsetDateTime.now().minusSeconds(1):date.atTime(12,0).atOffset(ZoneOffset.ofHours(8)));r.setCreateIdempotencyKey("statement-"+UUID.randomUUID());r.setItems(List.of());
  return r;
 }
 private BigDecimal actualBankOutLocal(UUID account){return db.queryForObject("SELECT COALESCE(SUM(CASE WHEN out_amount>0 THEN amount_local WHEN in_amount>0 THEN -amount_local END),0) FROM finance_reconciliations WHERE account_id=? AND NOT is_deleted AND entry_kind IN('POSTING','REVERSAL') AND source_doc_type IN('PAYMENT','SUPPLIER_ADVANCE_REFUND')",BigDecimal.class,account);}
 private UUID style(String category){UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,?,0,'使用')",id,"ST-ST-"+id,"匿名明确科目-"+id,category);return id;}
 private Map<String,Object> basic(Setup s){var r=reports.payableSummary(code(s),BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),1,50);assertThat(r.rows()).hasSize(1);return r.rows().getFirst();}
 private Map<String,Object> template(Setup s){var r=reports.arApSummaryTemplate("AP",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),code(s),1,50,FinanceReportColumnOptions.NONE);assertThat(r.rows()).hasSize(1);return r.rows().getFirst();}
 private Map<String,Object> yearMonth(Setup s,LocalDate date){return reports.partyAnnualStatement(s.world.supplierId(),"AP",date.getYear(),1,50).rows().stream().filter(r->date.toString().substring(0,7).equals(r.get("ym"))).findFirst().orElseThrow();}
 private String code(Setup s){return db.queryForObject("SELECT code FROM suppliers WHERE id=?",String.class,s.world.supplierId());}
 private void assertNoSyntheticAp(UUID payment){assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=?",Integer.class,payment)).isZero();}
 private static BigDecimal n(String s){return new BigDecimal(s);}
 private static void amount(Map<String,Object> row,String key,String expected){assertThat(row.get(key)).as(key).isNotNull();assertThat(new BigDecimal(row.get(key).toString())).as(key).isEqualByComparingTo(expected);}
 private static void amountTotal(ReportTableResponse report,String key,String expected){var total=report.totals().stream().filter(t->t.key().equals(key)).findFirst().orElseThrow();assertThat(total.groups()).hasSize(1);assertThat(new BigDecimal(total.groups().getFirst().value().toString())).as("unfiltered authoritative cash total").isEqualByComparingTo(expected);}
}
