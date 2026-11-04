package com.uten.imp.businesschain;

import com.uten.imp.application.port.FinancePayableStatementAdjustmentPort.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import java.nio.file.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
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
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Actual purchase/IQC/stock, immutable reviewed original, two bank payments and an independently reviewed credit. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only","uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})

@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=FinanceStatementSettlementVersionPostgresTest.Cleanup.class,mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class FinanceStatementSettlementVersionPostgresTest {
 private static MigratedSchemaBaseline.ScopedDatabase database;
 @DynamicPropertySource static void database(DynamicPropertyRegistry r)throws Exception{
  database=MigratedSchemaBaseline.openDatabase("statement_settlement_version");
  FixtureDatabaseProperties.bindSameRole(r,database::getJdbcUrl,database::getUsername,database::getPassword);
  String directory=Files.createTempDirectory("uten-settlement-version-").toString();r.add("uten.storage.local-dir",()->directory);
 }
 public static class Cleanup extends AbstractTestExecutionListener {
  @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
  @Override public void afterTestClass(TestContext ignored)throws Exception{if(database!=null)database.close();}
 }
 @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;
 @Autowired FinancePayableStatementAdjustmentService adjustments;@Autowired FinanceStatementDocumentService documents;
 @Autowired FinanceAuxiliaryService auxiliaries;@Autowired FinanceOpenItemClassificationService classifications;
 @Autowired GlPostingService gl;
 @AfterEach void logout(){SecurityContextHolder.clearContext();}
 @Test void reviewedDeductionsCreateNewOriginalVersionsWithoutEditingTheBasisOrDoubleSubtractingItsNet(){

  var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var w=fixture.seedWorld("statement-version");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID unit=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,'匿名实际付款原币',7,'使用')",unit,"FEE-"+unit);
  UUID ap=db.queryForObject("SELECT system_posting_style_id('AP_CONTROL')",UUID.class);
  db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by)VALUES('2202','匿名原应付','',?,'LIABILITY','MANUAL','按真实应付来源维护',1,1,?) ON CONFLICT(code)DO UPDATE SET currency_id=excluded.currency_id",base,w.superAdminUserId());
  db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by)VALUES('2202',?,?) ON CONFLICT(style_id)DO NOTHING",ap,w.superAdminUserId());
  var aux=auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名逐单处理账套","SUP-"+w.supplierId(),"匿名原供应商","SUPPLIER",w.supplierId(),"真实供应商UUID对应，不按名称猜配","2202"));
  var nativeFixture=new SupplierPrepaymentPostgresTest();beans.autowireBean(nativeFixture);UUID target=nativeFixture.receipt(fixture,w,unit);
  classifications.classifySource(target,new FinanceOpenItemClassificationContracts.SourceInput(UUID.randomUUID(),-1,null,"原实际应付明确货款20与模具60独立组成",List.of(new FinanceOpenItemClassificationContracts.Part("GOODS",n("20"),n("140")),new FinanceOpenItemClassificationContracts.Part("MOULD",n("60"),n("420")))));
  gl.generate(YearMonth.from(BusinessTime.today()).toString());
  UUID reviewer=fixture.createUserWithPerms(w,"statement-version-reviewer","finance_report:view","ar_ap_ledger:view","finance:view:all","finance_post:execute","supplier_settlement:confirm","finance_payment:approve","finance_payment:view","finance_payment:reverse");fixture.grantDataScope(reviewer,"finance",w.employeeId());
  for(String kind:List.of("OWN","COUNTERPART","CONTEXT")){
   var organization=kind.equals("CONTEXT")?null:new FinanceStatementDocumentContracts.Organization("匿名实际"+kind,"真实维护地址","TEST-PHONE","TEST-FAX","实际户名","实际开户行","ANON-EXACT-ACCOUNT-"+kind,"实际收货人","TEST-RECEIVER","实际资料，不复制附件账号");
   var settings=kind.equals("CONTEXT")?new FinanceStatementDocumentContracts.Settings(new FinanceStatementDocumentContracts.BalanceSelection("2202",aux.id(),base,unit,true,-1),List.of(),"原8列供应商对账单"):null;
   UUID profile=(UUID)documents.saveProfile(new FinanceStatementDocumentContracts.ProfileSave(UUID.randomUUID(),-1,kind,kind.equals("CONTEXT")?"supplierStatement":"ALL",kind.equals("OWN")?null:"SUPPLIER",kind.equals("OWN")?null:w.supplierId(),unit,organization,settings,"原件资料由财务明确维护")).get("id");
   fixture.loginAs(reviewer);documents.decideProfile(profile,new FinanceStatementDocumentContracts.Decision(true,"另一财务核对实际资料"));fixture.loginAs(w.superAdminUserId());
  }
  var documentContext=new FinanceStatementDocumentContracts.Context("supplierStatement","SUPPLIER",w.supplierId(),unit,BusinessTime.today().withDayOfMonth(1),BusinessTime.today());
  var preview=documents.preview(documentContext);UUID review=(UUID)documents.submitReview(new FinanceStatementDocumentContracts.ReviewSave(UUID.randomUUID(),documentContext,preview.get("sourceFingerprint").toString())).get("id");
  fixture.loginAs(reviewer);documents.decideReview(review,new FinanceStatementDocumentContracts.Decision(true,"已核真实原8列全部来源"));fixture.loginAs(w.superAdminUserId());

  var deductionContext=new Context(review,preview.get("sourceFingerprint").toString());
  String originalSha=preview.get("documentSha256").toString();
  var noFee=new FinanceStatementDocumentContracts.SettlementPreview(review,preview.get("sourceFingerprint").toString(),true,"本单原件逐项核实暂无扣款");
  var firstPreview=documents.previewSettlement(noFee);
  assertThat(net(firstPreview)).isEqualByComparingTo("80");
  var firstCommand=new FinanceStatementDocumentContracts.SettlementSave(UUID.randomUUID(),noFee,firstPreview.get("sourceFingerprint").toString());
  UUID first=(UUID)documents.submitSettlement(firstCommand).get("id");
  assertThatThrownBy(()->documents.decideReview(first,new FinanceStatementDocumentContracts.Decision(true,"同人不能审核"))).isInstanceOf(ApiException.class);
  fixture.loginAs(reviewer);documents.decideReview(first,new FinanceStatementDocumentContracts.Decision(true,"已核第一份结算原件"));fixture.loginAs(w.superAdminUserId());
  int entries=count("gl_entries"),cash=count("finance_reconciliations"),stock=count("stock_movements"),debt=count("ar_ap_ledger");
  owed(fixture,w,reviewer,deductionContext,target,"5",FeeKind.HANDLING_FEE);
  var basedFirst=new FinanceStatementDocumentContracts.SettlementPreview(first,firstPreview.get("sourceFingerprint").toString(),false,"本单处理以基础80原币为起点");
  var secondPreview=documents.previewSettlement(basedFirst);assertThat(net(secondPreview)).isEqualByComparingTo("75");
  UUID second=(UUID)documents.submitSettlement(new FinanceStatementDocumentContracts.SettlementSave(UUID.randomUUID(),basedFirst,secondPreview.get("sourceFingerprint").toString())).get("id");
  owed(fixture,w,reviewer,deductionContext,target,"0.000000000000000000000001",FeeKind.ROUNDING);
  fixture.loginAs(reviewer);assertThatThrownBy(()->documents.decideReview(second,new FinanceStatementDocumentContracts.Decision(true,"旧预览不能盖新扣款"))).isInstanceOf(ApiException.class).hasMessageContaining("扣款");fixture.loginAs(w.superAdminUserId());
  var thirdPreview=documents.previewSettlement(basedFirst);assertThat(net(thirdPreview)).isEqualByComparingTo("74.999999999999999999999999");
  var thirdCommand=new FinanceStatementDocumentContracts.SettlementSave(UUID.randomUUID(),basedFirst,thirdPreview.get("sourceFingerprint").toString());
  UUID third=(UUID)documents.submitSettlement(thirdCommand).get("id");
  fixture.loginAs(reviewer);documents.decideReview(third,new FinanceStatementDocumentContracts.Decision(true,"原金额与仍欠分别核验"));fixture.loginAs(w.superAdminUserId());
  assertThat(documents.submitSettlement(firstCommand).get("id")).isEqualTo(first);
  assertThat(documents.submitSettlement(thirdCommand).get("id")).isEqualTo(third);
  assertThatThrownBy(()->documents.previewSettlement(noFee)).isInstanceOf(ApiException.class).hasMessageContaining("已有");
  var fourth=documents.previewSettlement(new FinanceStatementDocumentContracts.SettlementPreview(third,thirdPreview.get("sourceFingerprint").toString(),false,"后续版本仍从原80起算，不重复减旧75"));
  assertThat(net(fourth)).isEqualByComparingTo("74.999999999999999999999999");
  var paper=documents.originalTable(third,1,50).documentMetadata();var version=map(paper.get("settlementVersion"));
  assertThat(version.get("rootReviewId")).isEqualTo(review.toString());
  assertThat(version.get("stillOwedOriginal")).isEqualTo("5.000000000000000000000001");
  assertThat(version.get("releasedOriginal")).isEqualTo("0");
  var footer=(List<?>)map(map(paper.get("paperLayout")).get("footer")).get("cells");
  assertThat(footer.stream().map(FinanceStatementSettlementVersionPostgresTest::map).filter(cell->Objects.equals(cell.get("column"),6)&&Objects.equals(cell.get("rowOffset"),1)).map(cell->cell.get("value"))).contains("74.999999999999999999999999");
  assertThat(documents.review(review).get("document_sha256")).isEqualTo(originalSha);
  assertThat(map(documents.review(review).get("original")).get("rows")).isEqualTo(preview.get("rows"));
  assertThat(db.queryForObject("SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",BigDecimal.class,target)).isEqualByComparingTo("80");
  assertThat(count("gl_entries")).isEqualTo(entries);assertThat(count("finance_reconciliations")).isEqualTo(cash);assertThat(count("stock_movements")).isEqualTo(stock);assertThat(count("ar_ap_ledger")).isEqualTo(debt);
  assertThatThrownBy(()->db.update("UPDATE finance_statement_settlement_versions SET source_reference='tampered' WHERE review_id=?",third)).hasMessageContaining("cannot be rewritten");
  UUID income=UUID.randomUUID();String code="63"+Integer.toUnsignedString(income.hashCode());
  db.update("INSERT INTO payment_styles(id,code,name,category,level,status)VALUES(?,?,?,'INCOME',0,'使用')",income,"SETTLEMENT-INCOME-"+income,"匿名本单独立损益科目");
  db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by)VALUES(?,?,'',?,'PROFIT','MANUAL','财务明确本次不再欠款的对方科目',9,1,?)",code,"匿名结算免债收入",base,w.superAdminUserId());
  db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by)VALUES(?,?,?)",code,income,w.superAdminUserId());
  var release=new Line(target,targetFingerprint(deductionContext,target),Decision.RELEASED,FeeKind.HANDLING_FEE,n("2"),income,null,"原货款的逐单免债","实际确认本单2原币不再欠；不是银行手续费","GOODS");
  var releasePlan=adjustments.preview(deductionContext,List.of(release));UUID released=adjustments.submit(new Submit(UUID.randomUUID(),deductionContext,List.of(release),releasePlan.planHash(),"独立审核本单免债",releasePlan.precisionChoicesJson()));
  fixture.loginAs(reviewer);adjustments.approve(released);fixture.loginAs(w.superAdminUserId());
  assertThat(db.queryForObject("SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",BigDecimal.class,target)).isEqualByComparingTo("78");
  int releasedEntries=count("gl_entries"),releasedDebt=count("ar_ap_ledger");
  var combinedBasis=new FinanceStatementDocumentContracts.SettlementPreview(third,thirdPreview.get("sourceFingerprint").toString(),false,"仍欠与已免2原币只从原80扣一次");
  var combined=documents.previewSettlement(combinedBasis);assertThat(net(combined)).isEqualByComparingTo("72.999999999999999999999999");
  var combinedCommand=new FinanceStatementDocumentContracts.SettlementSave(UUID.randomUUID(),combinedBasis,combined.get("sourceFingerprint").toString());UUID combinedId=(UUID)documents.submitSettlement(combinedCommand).get("id");
  fixture.loginAs(reviewer);documents.decideReview(combinedId,new FinanceStatementDocumentContracts.Decision(true,"分别核实免债2与仍欠5及原尾数"));fixture.loginAs(w.superAdminUserId());
  assertThat(n(map(map(combined.get("documentMetadata")).get("settlementVersion")).get("releasedOriginal").toString())).isEqualByComparingTo("2");
  assertThat(count("gl_entries")).isEqualTo(releasedEntries);assertThat(count("ar_ap_ledger")).isEqualTo(releasedDebt);assertThat(count("stock_movements")).isEqualTo(stock);assertThat(count("finance_reconciliations")).isEqualTo(cash);
  adjustments.reverse(released,"实际撤销免债，仍欠约定保留");
  var afterReverse=documents.previewSettlement(new FinanceStatementDocumentContracts.SettlementPreview(combinedId,combined.get("sourceFingerprint").toString(),false,"原免债已真实反向，旧原件不覆盖"));
  assertThat(net(afterReverse)).isEqualByComparingTo("74.999999999999999999999999");
  assertThat(documents.submitSettlement(combinedCommand).get("id")).isEqualTo(combinedId);
  assertThat(documents.review(review).get("document_sha256")).isEqualTo(originalSha);
 }
 private String targetFingerprint(Context context,UUID target){
  return ((List<?>)adjustments.choices(context,1,100,1).get("targets")).stream().map(FinanceStatementSettlementVersionPostgresTest::map).filter(item->target.equals(item.get("ledgerId"))).findFirst().orElseThrow().get("fingerprint").toString();
 }
 private void owed(FullChainEndToEndTest fixture,FullChainEndToEndTest.World w,UUID reviewer,Context context,UUID target,String amount,FeeKind kind){
  var line=new Line(target,targetFingerprint(context,target),Decision.STILL_OWED,kind,n(amount),null,null,"原货款的真实组成","逐笔决定仅减少本次支付参考，仍欠保留","GOODS");
  var plan=adjustments.preview(context,List.of(line));UUID id=adjustments.submit(new Submit(UUID.randomUUID(),context,List.of(line),plan.planHash(),"财务明确仍欠",plan.precisionChoicesJson()));
  fixture.loginAs(reviewer);adjustments.approve(id);fixture.loginAs(w.superAdminUserId());
 }
 private int count(String table){return db.queryForObject("SELECT count(*) FROM "+table,Integer.class);}
 private static BigDecimal net(Map<String,Object> snapshot){return n(map(map(snapshot.get("documentMetadata")).get("settlementVersion")).get("netOriginal").toString());}
 private static BigDecimal n(String value){return new BigDecimal(value);}
 @SuppressWarnings("unchecked")private static Map<String,Object> map(Object value){return value instanceof Map<?,?> data?(Map<String,Object>)data:Map.of();}
}
