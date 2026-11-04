package com.uten.imp.businesschain;

import com.uten.imp.application.port.FinancePayableStatementAdjustmentPort.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.*;
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
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Actual purchase/IQC/stock, immutable reviewed original, two bank payments and an independently reviewed credit. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only","uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=PayableStatementAdjustmentPostgresTest.Cleanup.class,mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class PayableStatementAdjustmentPostgresTest {
 private static MigratedSchemaBaseline.ScopedDatabase database;
 @DynamicPropertySource static void database(DynamicPropertyRegistry r)throws Exception{database=MigratedSchemaBaseline.openDatabase("statement_fee");FixtureDatabaseProperties.bindSameRole(r,database::getJdbcUrl,database::getUsername,database::getPassword);String attachments=java.nio.file.Files.createTempDirectory("uten-statement-fee-").toString();r.add("uten.storage.local-dir",()->attachments);}
 public static class Cleanup extends AbstractTestExecutionListener {
  @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
  @Override public void afterTestClass(TestContext ignored)throws Exception{if(database!=null)database.close();}
 }
 @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;
 @Autowired FinancePayableStatementAdjustmentService adjustments;@Autowired FinanceStatementDocumentService documents;
 @Autowired FinanceAuxiliaryService auxiliaries;@Autowired FinanceOpenItemClassificationService classifications;
 @Autowired FinanceClassificationCorrectionService corrections;
 @Autowired GlPostingService gl;@Autowired FinancePaymentService payments;
 @Autowired com.uten.imp.features.finance.gl.GlReportService reports;
 @Autowired com.uten.imp.features.finance.gl.GlReportLineBindingService reportBindings;
 @Autowired SupplierOffsetCommandService offsetCommands;
 @Autowired com.uten.imp.features.finance.report.FinanceReportService partyReports;
 @AfterEach void logout(){SecurityContextHolder.clearContext();}
 @Test void originalFeeDecisionKeepsPeriodNetApartFromRemainingCashAndReversesOnlyAfterLaterRealPayments(){
  var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var w=fixture.seedWorld("statement-fee");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID unit=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,'匿名实际付款原币',7,'使用')",unit,"FEE-"+unit);
  UUID ap=db.queryForObject("SELECT system_posting_style_id('AP_CONTROL')",UUID.class);
  db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by)VALUES('2202','匿名原应付','',?,'LIABILITY','MANUAL','按真实应付来源维护',1,1,?) ON CONFLICT(code)DO UPDATE SET currency_id=excluded.currency_id",base,w.superAdminUserId());
  db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by)VALUES('2202',?,?) ON CONFLICT(style_id)DO NOTHING",ap,w.superAdminUserId());
  var aux=auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名逐单处理账套","SUP-"+w.supplierId(),"匿名原供应商","SUPPLIER",w.supplierId(),"真实供应商UUID对应，不按名称猜配","2202"));
  UUID income=style("INCOME"),bankStyle=style("ACCOUNT");
  db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by)VALUES('630199','匿名财务逐单选择的损益科目','',?,'PROFIT','MANUAL','财务明确选择，不从手续费名称自动定科目',2,1,?)",base,w.superAdminUserId());
  db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by)VALUES('630199',?,?)",income,w.superAdminUserId());
  for(String role:List.of("FX_GAIN_LOSS","BANK_FEE_EXPENSE"))if(db.queryForObject("SELECT system_posting_style_id(?) IS NULL",Boolean.class,role))db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key=?",style("EXPENSE"),role);
  UUID bank=UUID.randomUUID();db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id,init_balance,balance_current)VALUES(?,?,'匿名真实银行','BANK',?,'使用',?,1000,1000)",bank,"FEE-BANK-"+bank,unit,bankStyle);
  var nativeFixture=new SupplierPrepaymentPostgresTest();beans.autowireBean(nativeFixture);UUID target=nativeFixture.receipt(fixture,w,unit);
  var sourceClass=classifications.classifySource(target,new FinanceOpenItemClassificationContracts.SourceInput(UUID.randomUUID(),-1,null,"原实际应付明确货款20与模具60独立组成",List.of(new FinanceOpenItemClassificationContracts.Part("GOODS",n("20"),n("140")),new FinanceOpenItemClassificationContracts.Part("MOULD",n("60"),n("420")))));
  gl.generate(YearMonth.from(BusinessTime.today()).toString());
  UUID reviewer=fixture.createUserWithPerms(w,"fee-independent-reviewer","finance_report:view","ar_ap_ledger:view","finance:view:all","finance_post:execute","supplier_settlement:confirm","finance_payment:approve","finance_payment:view","finance_payment:reverse");fixture.grantDataScope(reviewer,"finance",w.employeeId());
  for(String kind:List.of("OWN","COUNTERPART","CONTEXT")){
   var organization=kind.equals("CONTEXT")?null:new FinanceStatementDocumentContracts.Organization("匿名实际"+kind,"真实维护地址","TEST-PHONE","TEST-FAX","实际户名","实际开户行","ANON-EXACT-ACCOUNT-"+kind,"实际收货人","TEST-RECEIVER","实际资料，不复制附件账号");
   var settings=kind.equals("CONTEXT")?new FinanceStatementDocumentContracts.Settings(new FinanceStatementDocumentContracts.BalanceSelection("2202",aux.id(),base,unit,true,-1),List.of(),"原8列供应商对账单"):null;
   UUID profile=(UUID)documents.saveProfile(new FinanceStatementDocumentContracts.ProfileSave(UUID.randomUUID(),-1,kind,kind.equals("CONTEXT")?"supplierStatement":"ALL",kind.equals("OWN")?null:"SUPPLIER",kind.equals("OWN")?null:w.supplierId(),unit,organization,settings,"原件资料由财务明确维护")).get("id");
   fixture.loginAs(reviewer);documents.decideProfile(profile,new FinanceStatementDocumentContracts.Decision(true,"另一财务核对实际资料"));fixture.loginAs(w.superAdminUserId());
  }
  var documentContext=new FinanceStatementDocumentContracts.Context("supplierStatement","SUPPLIER",w.supplierId(),unit,BusinessTime.today().withDayOfMonth(1),BusinessTime.today());
  var preview=documents.preview(documentContext);var footer=(List<?>)((Map<?,?>)preview.get("documentMetadata")).get("footerLines");var closing=footer.stream().map(v->(Map<?,?>)v).filter(v->"closingBalance".equals(v.get("key"))).findFirst().orElseThrow();assertThat(closing.get("pending")).as("Exact original closing balance must have its real source evidence: %s",closing).isEqualTo(false);UUID review=(UUID)documents.submitReview(new FinanceStatementDocumentContracts.ReviewSave(UUID.randomUUID(),documentContext,preview.get("sourceFingerprint").toString())).get("id");
  fixture.loginAs(reviewer);documents.decideReview(review,new FinanceStatementDocumentContracts.Decision(true,"已核真实原8列全部来源"));fixture.loginAs(w.superAdminUserId());
  var context=new Context(review,preview.get("sourceFingerprint").toString());String originalSha=preview.get("documentSha256").toString();
  int stock=db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class),cash=db.queryForObject("SELECT count(*) FROM finance_reconciliations",Integer.class),entries=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class);
  var owed=new Line(target,fingerprint(context,target),Decision.STILL_OWED,FeeKind.HANDLING_FEE,n("5"),null,null,"明确属于此原货款","本单手续费仍欠，实付不自动凑整","GOODS");var owedPreview=adjustments.preview(context,List.of(owed));
  UUID owedId=adjustments.submit(new Submit(UUID.randomUUID(),context,List.of(owed),owedPreview.planHash(),"财务逐笔明确仍欠",owedPreview.precisionChoicesJson()));fixture.loginAs(reviewer);adjustments.approve(owedId);fixture.loginAs(w.superAdminUserId());
  assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(entries);assertThat(db.queryForObject("SELECT count(*) FROM finance_reconciliations",Integer.class)).isEqualTo(cash);balance(target,"80","560");
  var staleInput=new Line(target,fingerprint(context,target),Decision.RELEASED,FeeKind.ROUNDING,n("0.01"),income,null,"原应付货款归属","等待另一人审核时仍要复核原余额","GOODS");var stalePreview=adjustments.preview(context,List.of(staleInput));UUID staleDraft=adjustments.submit(new Submit(UUID.randomUUID(),context,List.of(staleInput),stalePreview.planHash(),"保留原草稿，后付款不能静默改审核金额",stalePreview.precisionChoicesJson()));
  UUID earlier=pay(fixture,w,reviewer,target,unit,bank,"20",sourceClass.batchId());
  fixture.loginAs(reviewer);assertThatThrownBy(()->adjustments.approve(staleDraft)).isInstanceOf(ApiException.class).hasMessageContaining("指纹");fixture.loginAs(w.superAdminUserId());assertThat(db.queryForObject("SELECT status FROM finance_payable_statement_adjustments WHERE id=?",String.class,staleDraft)).isEqualTo("DRAFT");
  String fp=fingerprint(context,target);
  assertThatThrownBy(()->adjustments.preview(context,List.of(new Line(target,fp,Decision.RELEASED,FeeKind.HANDLING_FEE,n("5"),income,null,"货款已耗尽不能占模具剩余","当前整票仍欠60但货款分类剩余为0","GOODS")))).isInstanceOf(ApiException.class).hasMessageContaining("分类剩余");
  var release=new Line(target,fp,Decision.RELEASED,FeeKind.HANDLING_FEE,n("5"),income,null,"此原模具款的手续费不再欠","对方真实确认本单免除5原币，非银行手续费","MOULD");
  var tiny=new Line(target,fp,Decision.RELEASED,FeeKind.ROUNDING,n("0.000000000000000000000001"),income,null,"此原模具款的明确尾数归属","对方真实确认最小原币份额，不截断为零","MOULD");
  assertThatThrownBy(()->adjustments.preview(context,List.of(new Line(target,fp,Decision.RELEASED,FeeKind.HANDLING_FEE,n("5"),bankStyle,null,"真实银行不能变成免债科目","必须走真实银行业务来源","GOODS")))).isInstanceOf(ApiException.class).hasMessageContaining("损益科目");
  var releasePreview=adjustments.preview(context,List.of(release,tiny));assertThat(releasePreview.periodAmountOriginal()).isEqualTo("80.0000");assertThat(releasePreview.releasedOriginal()).isEqualTo("5.000000000000000000000001");
  var command=new Submit(UUID.randomUUID(),context,List.of(release,tiny),releasePreview.planHash(),"两个逐笔决定，不设全局默认",releasePreview.precisionChoicesJson());UUID adjustment=adjustments.submit(command);assertThat(adjustments.submit(command)).isEqualTo(adjustment);
  assertThatThrownBy(()->adjustments.approve(adjustment)).isInstanceOf(ApiException.class).hasMessageContaining("另一名");fixture.loginAs(reviewer);var effects=adjustments.approve(adjustment);assertThat(adjustments.approve(adjustment)).isEqualTo(effects);fixture.loginAs(w.superAdminUserId());
  balance(target,"54.999999999999999999999999","384.999999999999999999999993");assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,bank)).isEqualByComparingTo("980");
  // Original approved fee labels and SHA survive a live whole-graph correction. Current evidence follows actual offset parts.
  var correctionRoots=new ArrayList<UUID>();correctionRoots.add(target);effects.stream().filter(e->e.decision()==Decision.RELEASED).map(Effect::creditLedgerId).forEach(correctionRoots::add);
  String moneyBeforeCorrection=allFinancialFacts();var corrected=swapClassification(corrections.graph(correctionRoots));var classificationReceipt=corrections.submit(corrected);
  var effectiveDecisions=adjustments.readConfirmed(context).stream().filter(e->e.decision()==Decision.RELEASED).toList();assertThat(effectiveDecisions).hasSize(2);assertThat(effectiveDecisions).allSatisfy(e->{assertThat(e.category()).isEqualTo("MOULD");assertThat(e.effectiveParts()).allSatisfy(p->{assertThat(p.category()).isEqualTo("GOODS");assertThat(p.correctionId()).isNotNull();});});assertThat(documents.review(review).get("document_sha256")).isEqualTo(originalSha);assertThat(allFinancialFacts()).isEqualTo(moneyBeforeCorrection);
  corrections.submit(swapClassification(corrections.graph(correctionRoots)));assertThat(corrections.submit(corrected)).isEqualTo(classificationReceipt);assertThat(allFinancialFacts()).isEqualTo(moneyBeforeCorrection);
  var partySummary=partyReports.arApSummaryTemplate("AP",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),db.queryForObject("SELECT code FROM suppliers WHERE id=?",String.class,w.supplierId()),1,50,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE).rows().getFirst();
  assertThat(partySummary.get("totalBalance")).as("完整应付合计；实际取数依据：%s",partySummary.get("__basis")).isNotNull();
  assertThat(partySummary.get("goodsBalance")).as("货款分类余额；实际取数依据：%s",partySummary.get("__basis")).isNotNull();
  assertThat(partySummary.get("mouldBalance")).as("模具分类余额；实际取数依据：%s",partySummary.get("__basis")).isNotNull();
  assertThat(new BigDecimal(partySummary.get("totalBalance").toString())).isEqualByComparingTo("384.999999999999999999999993");assertThat(new BigDecimal(partySummary.get("goodsBalance").toString())).isZero();assertThat(new BigDecimal(partySummary.get("mouldBalance").toString())).isEqualByComparingTo("384.999999999999999999999993");
  assertThat(db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class)).isEqualTo(stock);assertThat(db.queryForObject("SELECT count(*) FROM finance_reconciliations",Integer.class)).isEqualTo(cash+1);
  assertThat(adjustments.readConfirmed(context).stream().filter(e->e.decision()==Decision.RELEASED).map(e->new BigDecimal(e.amountOriginal())).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("5.000000000000000000000001");
  assertThat(documents.review(review).get("document_sha256")).isEqualTo(originalSha);
  assertThatThrownBy(()->db.update("UPDATE finance_statement_document_reviews SET status='CANCELLED' WHERE id=?",review)).isInstanceOf(org.springframework.dao.DataAccessException.class).hasMessageContaining("active document debt decisions");
  var finalEffect=effects.getLast();assertThatThrownBy(()->offsetCommands.reverse(finalEffect.offsetBatchId(),new SupplierOffsetContracts.ReverseRequest("不能从通用抵销入口拆掉独立减免的受审金额链"))).isInstanceOf(org.springframework.dao.DataAccessException.class);
  balance(target,"54.999999999999999999999999","384.999999999999999999999993");
  gl.generate(YearMonth.from(BusinessTime.today()).toString());for(var effect:effects)assertThat(db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_type='AP_POST' AND source_doc_id=?",Integer.class,effect.lineId())).isZero();
  fixture.loginAs(reviewer);assertThatThrownBy(()->payments.reverse(earlier)).isInstanceOf(ApiException.class);fixture.loginAs(w.superAdminUserId());
  UUID later=pay(fixture,w,reviewer,target,unit,bank,"10",(UUID)classifications.source(target).get("classificationId"),"MOULD");assertThatThrownBy(()->adjustments.reverse(adjustment,"不能越过后付款反审减免")).isInstanceOf(ApiException.class);
  fixture.loginAs(reviewer);payments.reverse(later);adjustments.reverse(adjustment,"后付款反向后撤回原减免，保留原件和历史");payments.reverse(earlier);fixture.loginAs(w.superAdminUserId());
  balance(target,"80","560");assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,bank)).isEqualByComparingTo("1000");assertThat(db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class)).isEqualTo(stock);
  assertThat(documents.review(review).get("document_sha256")).isEqualTo(originalSha);assertThat(adjustments.readConfirmed(context)).allMatch(e->e.decision()==Decision.STILL_OWED);
  // A genuine reduction of an explicitly selected expense is a credit occurrence, not an ignored cost transfer.
  UUID expense=style("EXPENSE");db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by)VALUES('660299','匿名明确办公费用冲减','',?,'PROFIT','MANUAL','财务明确该笔货款免除冲减此实际费用',3,1,?)",base,w.superAdminUserId());
  db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by)VALUES('660299',?,?)",expense,w.superAdminUserId());
  reportBindings.replace("ADM_OFFICE",List.of(expense));reportBindings.replace("PL_14",List.of(expense));
  // In this anonymous isolated world all other profit sources have no net occurrence; finance confirms each one explicitly.
  for(var binding:reportBindings.list())if("PROFIT".equals(binding.sheet())&&!"PL_14".equals(binding.lineKey()))reportBindings.replace(binding.lineKey(),List.of(),true);
  BigDecimal expenseBefore=office(),adminBefore=profit(14),netBefore=profit(32);
  var expenseInput=new Line(target,fingerprint(context,target),Decision.RELEASED,FeeKind.HANDLING_FEE,n("2"),expense,null,"实际货款的费用冲减归属","财务明确冲减办公费用，不作为制造成本转出","GOODS");
  var expensePreview=adjustments.preview(context,List.of(expenseInput));UUID expenseAdjustment=adjustments.submit(new Submit(UUID.randomUUID(),context,List.of(expenseInput),expensePreview.planHash(),"明确费用冲减分支",expensePreview.precisionChoicesJson()));
  fixture.loginAs(reviewer);adjustments.approve(expenseAdjustment);fixture.loginAs(w.superAdminUserId());
  assertThat(office()).isEqualByComparingTo(expenseBefore.subtract(n("14")));assertThat(profit(14)).isEqualByComparingTo(adminBefore.subtract(n("14")));assertThat(profit(32)).isEqualByComparingTo(netBefore.add(n("14")));
  fixture.loginAs(reviewer);adjustments.reverse(expenseAdjustment,"原费用冲减按真实凭证对称反向");fixture.loginAs(w.superAdminUserId());
  assertThat(office()).isEqualByComparingTo(expenseBefore);assertThat(profit(14)).isEqualByComparingTo(adminBefore);assertThat(profit(32)).isEqualByComparingTo(netBefore);balance(target,"80","560");
 }
 @SuppressWarnings("unchecked") private FinanceClassificationCorrectionService.Command swapClassification(Map<String,Object> graph){var nodes=new ArrayList<FinanceClassificationCorrectionService.Node>();for(var row:(List<Map<String,Object>>)graph.get("nodes")){var parts=new ArrayList<Map<String,String>>();for(var original:(List<Map<String,Object>>)row.get("parts")){var part=new LinkedHashMap<String,String>();original.forEach((k,v)->part.put(k,v.toString()));for(String key:List.of("category","sourceCategory","targetCategory")){String old=part.get(key);if("GOODS".equals(old))part.put(key,"MOULD");else if("MOULD".equals(old))part.put(key,"GOODS");}parts.add(part);}nodes.add(new FinanceClassificationCorrectionService.Node(row.get("kind").toString(),(UUID)row.get("objectId"),(UUID)row.get("expectedBatchId"),((Number)row.get("expectedRevision")).longValue(),parts));}return new FinanceClassificationCorrectionService.Command(UUID.randomUUID(),(List<UUID>)graph.get("ledgerIds"),graph.get("graphFingerprint").toString(),"原批减免标签不变，当前真实来源与抵销两端共同更正",nodes);}
 private String allFinancialFacts(){return db.queryForObject("SELECT jsonb_build_object('ledgers',(SELECT jsonb_agg(to_jsonb(l)ORDER BY id)FROM ar_ap_ledger l),'payments',(SELECT jsonb_agg(to_jsonb(p)ORDER BY id)FROM finance_payments p),'lines',(SELECT jsonb_agg(to_jsonb(l)ORDER BY id)FROM finance_payment_lines l),'offsets',(SELECT jsonb_agg(to_jsonb(o)ORDER BY id)FROM supplier_open_item_offsets o),'banks',(SELECT jsonb_agg(to_jsonb(a)ORDER BY id)FROM accounts a),'gl',(SELECT jsonb_agg(to_jsonb(e)ORDER BY id)FROM gl_entries e),'stock',(SELECT jsonb_agg(to_jsonb(m)ORDER BY id)FROM stock_movements m),'decisions',(SELECT jsonb_agg(to_jsonb(d)ORDER BY id)FROM finance_payable_statement_adjustment_lines d))::text",String.class);}
 private BigDecimal office(){Object value=reports.adminExpense(BusinessTime.today().getYear(),BusinessTime.today().getMonthValue(),com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE).rows().stream().filter(row->"ADM_OFFICE".equals(row.get("__lineKey"))).findFirst().orElseThrow().get("m"+BusinessTime.today().getMonthValue());assertThat(value).isNotNull();return new BigDecimal(value.toString());}
 private BigDecimal profit(int number){Object value=reports.profitMonthly(BusinessTime.today().getYear(),BusinessTime.today().getMonthValue()).rows().stream().filter(row->Integer.valueOf(number).equals(row.get("lineNo"))).findFirst().orElseThrow().get("monthAmount");assertThat(value).isNotNull();return new BigDecimal(value.toString());}
 private String fingerprint(Context context,UUID target){return ((List<?>)adjustments.choices(context).get("targets")).stream().map(v->(Map<?,?>)v).filter(v->target.equals(v.get("ledgerId"))).findFirst().orElseThrow().get("fingerprint").toString();}
 private UUID pay(FullChainEndToEndTest fixture,FullChainEndToEndTest.World w,UUID reviewer,UUID target,UUID unit,UUID bank,String amount,UUID classification){
  return pay(fixture,w,reviewer,target,unit,bank,amount,classification,"GOODS");
 }
 private UUID pay(FullChainEndToEndTest fixture,FullChainEndToEndTest.World w,UUID reviewer,UUID target,UUID unit,UUID bank,String amount,UUID classification,String category){
  var request=new FinancePaymentSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setAccountId(bank);request.setCurrencyId(unit);request.setExchangeRate(n("7.2"));request.setAmountOriginal(n(amount));request.setAccountCurrencyId(unit);request.setAccountAmount(n(amount));request.setBankFeeAccountAmount(BigDecimal.ZERO);request.setBankReference("ANON-FEE-BANK-"+UUID.randomUUID());request.setBankBookedAt(OffsetDateTime.now());request.setCreateIdempotencyKey("fee-payment-"+UUID.randomUUID());
  var line=new FinancePaymentLineInput();line.setAppliedLedgerId(target);line.setSupplierId(w.supplierId());line.setAmountOriginal(n(amount));request.setItems(List.of(line));UUID id=payments.create(request).getId();fixture.loginAs(reviewer);payments.approve(id);fixture.loginAs(w.superAdminUserId());
  UUID lineId=db.queryForObject("SELECT id FROM finance_payment_lines WHERE payment_id=? AND NOT is_deleted",UUID.class,id);classifications.classifyPayment(lineId,new FinanceOpenItemClassificationContracts.PaymentInput(UUID.randomUUID(),-1,classification,"真实银行付款的明确货款或模具归属",List.of(new FinanceOpenItemClassificationContracts.PaymentPart(category,n(amount),n(amount).multiply(n("7.2")),n(amount).multiply(n("7"))))));return id;
 }
 private UUID style(String category){UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status)VALUES(?,?,?,?,0,'使用')",id,"FEE-ST-"+id,"匿名明确科目-"+id,category);return id;}
 private void balance(UUID id,String original,String local){var row=db.queryForMap("SELECT amount_balance_original,amount_balance FROM ar_ap_ledger WHERE id=?",id);assertThat((BigDecimal)row.get("amount_balance_original")).isEqualByComparingTo(original);assertThat((BigDecimal)row.get("amount_balance")).isEqualByComparingTo(local);}
 private static BigDecimal n(String value){return new BigDecimal(value);}
}
