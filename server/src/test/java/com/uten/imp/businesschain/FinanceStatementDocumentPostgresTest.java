package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.statement.*;
import com.uten.imp.features.finance.gl.FinanceControlledJournalService;
import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
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
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static com.uten.imp.features.finance.statement.FinanceStatementDocumentContracts.*;

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
@TestExecutionListeners(listeners=FinanceStatementDocumentPostgresTest.Cleanup.class,mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class FinanceStatementDocumentPostgresTest {
 private static MigratedSchemaBaseline.ScopedDatabase database;
 @DynamicPropertySource static void database(DynamicPropertyRegistry r)throws Exception{
  database=MigratedSchemaBaseline.openDatabase("statement_original");
  FixtureDatabaseProperties.bindSameRole(r,database::getJdbcUrl,database::getUsername,database::getPassword);
  String directory=java.nio.file.Files.createTempDirectory("uten-statement-original-").toString();r.add("uten.storage.local-dir",()->directory);
 }
 public static class Cleanup extends AbstractTestExecutionListener {
  @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
  @Override public void afterTestClass(TestContext ignored)throws Exception{if(database!=null)database.close();}
 }
 @Autowired AutowireCapableBeanFactory beans;
 @Autowired JdbcTemplate db;
 @Autowired TransactionTemplate transactions;
 @Autowired FinanceStatementDocumentService documents;
 @Autowired FinanceAuxiliaryService auxiliaries;
 @Autowired FinanceControlledJournalService journals;
 @Autowired FinanceAuxiliaryLedgerReader ledgerReader;
 @Autowired com.uten.imp.features.finance.report.FinanceTemplateSourceService templateSources;
 @Autowired FinanceStatementComparisonService comparisons;
 @AfterEach void logout(){SecurityContextHolder.clearContext();}

 @Test void twoExplicitWorksheetsKeepSeparateImmutableSourcesAndRepeatWithoutFinancialWrites()throws Exception{
  var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var world=fixture.seedWorld("source-worksheet");fixture.loginAs(world.superAdminUserId());
  byte[] bytes;try(var book=new org.apache.poi.xssf.usermodel.XSSFWorkbook();var out=new java.io.ByteArrayOutputStream()){
   for(String name:List.of("附件甲","附件乙")){var sheet=book.createSheet(name);var header=sheet.createRow(2);for(int column=0;column<6;column++){header.createCell(column).setCellValue(com.uten.imp.features.finance.gl.FinanceTemplateContract.header("copperDetail",column));}var row=sheet.createRow(3);row.createCell(0).setCellValue("2026-09-01");row.createCell(1).setCellValue(name);row.createCell(2).setCellValue("1.000000000000000000000001");row.createCell(3).setCellValue("KG");row.createCell(4).setCellValue("3");row.createCell(5).setCellValue("PCS");}
   book.write(out);bytes=out.toByteArray();
  }
  int journals=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class),debt=db.queryForObject("SELECT count(*) FROM ar_ap_ledger",Integer.class),stock=db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class),cash=db.queryForObject("SELECT count(*) FROM finance_reconciliations",Integer.class);
  assertThatThrownBy(()->templateSources.preview("copperDetail","2026-09","原多附件.xlsx",bytes,false)).isInstanceOf(ApiException.class).hasMessageContaining("工作表");
  var alpha=templateSources.preview("copperDetail","2026-09","原多附件.xlsx",bytes,false,"附件甲");var beta=templateSources.preview("copperDetail","2026-09","原多附件.xlsx",bytes,false,"附件乙");
  assertThat(alpha.importId()).isNotEqualTo(beta.importId());assertThat(alpha.sourceSheet()).isEqualTo("附件甲");assertThat(beta.sourceSheet()).isEqualTo("附件乙");
  assertThat(templateSources.preview("copperDetail","2026-09","原多附件.xlsx",bytes,false,"附件甲").importId()).isEqualTo(alpha.importId());assertThat(templateSources.get(beta.importId()).sourceSheet()).isEqualTo("附件乙");
  assertThatThrownBy(()->templateSources.preview("copperDetail","2026-09 ","原多附件.xlsx",bytes,false,"附件甲")).isInstanceOf(ApiException.class).hasMessageContaining("会计月份");
  assertThat(db.queryForObject("SELECT count(*) FROM finance_template_sources WHERE actor_id=? AND sha256=?",Integer.class,world.superAdminUserId(),alpha.sha256())).isEqualTo(2);
  assertThatThrownBy(()->db.update("UPDATE finance_template_sources SET source_selection='改名' WHERE id=?",alpha.importId())).isInstanceOf(org.springframework.dao.DataAccessException.class);
  var audits=db.queryForList("SELECT \"after\"::text AS payload FROM audit_log WHERE target_type='finance_template_sources'");assertThat(audits).isNotEmpty();for(var audit:audits)assertThat(audit.get("payload").toString()).doesNotContain("preview","rows","1.000000000000000000000001","storage_key");
  assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(journals);assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger",Integer.class)).isEqualTo(debt);assertThat(db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class)).isEqualTo(stock);assertThat(db.queryForObject("SELECT count(*) FROM finance_reconciliations",Integer.class)).isEqualTo(cash);
 }

 @Test void reviewedProfilesFreezeExactNativeStatementAndRejectStaleSignedCopyWithoutWritingAnyMoney(){
  var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var w=fixture.seedWorld("statement-doc");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID currency=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,'匿名原币',7,'使用')",currency,"DOC-CUR-"+currency);
  UUID ap=db.queryForObject("SELECT system_posting_style_id('AP_CONTROL')",UUID.class),inventory=db.queryForObject("SELECT system_posting_style_id('INVENTORY_ASSET')",UUID.class);
  db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by) VALUES('2202','匿名应付原科目','',?,'LIABILITY','MANUAL','匿名账载来源明确选择',1,1,?) ON CONFLICT(code) DO UPDATE SET currency_id=excluded.currency_id",base,w.superAdminUserId());
  db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES('2202',?,?) ON CONFLICT(style_id) DO NOTHING",ap,w.superAdminUserId());
  var auxiliary=auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名页尾账套","SUP-"+w.supplierId(),"匿名供应商","SUPPLIER",w.supplierId(),"真实供应商UUID，非名称配对","2202"));
  var nativeFixture=new SupplierPrepaymentPostgresTest();beans.autowireBean(nativeFixture);UUID payable=nativeFixture.receipt(fixture,w,currency);
  var ref=auxiliaries.resolveNative("2202","SUPPLIER",w.supplierId(),base);
  // The selected accounting book is explicit; this statement workflow does not add an ERP balance to it.
  transactions.executeWithoutResult(status->journals.post("ANON-BOOK-AP",BusinessTime.today(),"ANON_BOOK_AP",payable,"ANON_BOOK_AP","匿名账载事实，打印流程不得再立账",List.of(
    new FinanceControlledJournalService.Entry(inventory,1,new BigDecimal("560"),"匿名已记账存货"),
    new FinanceControlledJournalService.Entry(ap,-1,new BigDecimal("560"),"匿名已记账应付",new FinanceControlledJournalService.Allocation("2202",base,ref,"ANON-AP",1,"{}",currency,new BigDecimal("80"),new BigDecimal("7")))),w.superAdminUserId()));
  int gl=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class),ledger=db.queryForObject("SELECT count(*) FROM ar_ap_ledger",Integer.class),movements=db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class);
  UUID reviewer=fixture.createUserWithPerms(w,"statement-reviewer","finance_report:view","finance:view:all","finance_post:execute","supplier_settlement:confirm");
  var own=profile(fixture,w,reviewer,"OWN","ALL",null,null,currency,org("匿名本方公司","TEST-BANK-OWN"),null,-1);
  profile(fixture,w,reviewer,"COUNTERPART","ALL","SUPPLIER",w.supplierId(),currency,org("匿名供应商公司","TEST-BANK-SUPPLIER"),null,-1);
  profile(fixture,w,reviewer,"CONTEXT","supplierStatement","SUPPLIER",w.supplierId(),currency,null,new Settings(new BalanceSelection("2202",auxiliary.id(),base,currency,true,-1),List.of(),"以上为实际原单对账资料，请核对确认。"),-1);
  var context=new Context("supplierStatement","SUPPLIER",w.supplierId(),currency,BusinessTime.today().withDayOfMonth(1),BusinessTime.today());
  var preview=documents.preview(context);assertThat(map(preview.get("documentMetadata")).get("periodAmount")).isEqualTo("80.0000");
  var row=map(((List<?>)preview.get("rows")).getFirst());assertThat(row.get("amount")).isInstanceOf(String.class);assertThat(new BigDecimal(row.get("amount").toString())).isEqualByComparingTo("80");
  byte[] external=externalStatement(preview);
  var imported=templateSources.preview("supplierStatement",BusinessTime.today().toString().substring(0,7),"anonymous-supplier-original.xlsx",external,false);
  assertThat(templateSources.preview("supplierStatement",imported.period(),"anonymous-supplier-original.xlsx",external,false).importId()).isEqualTo(imported.importId());
  var compared=comparisons.compare(new FinanceStatementComparisonService.Input(imported.importId(),context,preview.get("sourceFingerprint").toString(),List.of(new FinanceStatementComparisonService.Selection(7,1))));
  assertThat(map(((List<?>)compared.get("results")).getFirst()).get("status")).isEqualTo("EQUAL");
  var preciseDifference=comparisons.compare(new FinanceStatementComparisonService.Input(imported.importId(),context,preview.get("sourceFingerprint").toString(),List.of(new FinanceStatementComparisonService.Selection(8,1))));
  assertThat(map(((List<?>)preciseDifference.get("results")).getFirst()).get("status")).isEqualTo("DIFFERENT");
  fixture.loginAs(reviewer);assertThatThrownBy(()->templateSources.get(imported.importId())).isInstanceOf(ApiException.class).hasMessageContaining("账号");fixture.loginAs(w.superAdminUserId());
  var request=new ReviewSave(UUID.randomUUID(),context,preview.get("sourceFingerprint").toString());var submitted=documents.submitReview(request);UUID id=(UUID)submitted.get("id");assertThat(documents.submitReview(request).get("id")).isEqualTo(id);
  assertThatThrownBy(()->documents.decideReview(id,new Decision(true,"禁止自己审核自己的原件"))).isInstanceOf(ApiException.class).hasMessageContaining("不可相同");
  fixture.loginAs(reviewer);documents.decideReview(id,new Decision(true,"已核原单、账载与全部原页尾资料"));fixture.loginAs(w.superAdminUserId());
  profile(fixture,w,reviewer,"OWN","ALL",null,null,currency,org("匿名本方新资料版本","TEST-BANK-UPDATED"),null,0);
  byte[] proof=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVb8AAAAASUVORK5CYII=");
  assertThatThrownBy(()->documents.confirmCounterpart(id,new CounterpartConfirmation(preview.get("documentSha256").toString(),"匿名对方核对人",BusinessTime.today(),"实际回传件绑定此原件"),"anonymous-confirmation.png","image/png",proof)).isInstanceOf(ApiException.class).hasMessageContaining("变化");
  assertThat(map(map(documents.review(id).get("original")).get("documentMetadata")).get("sourceFingerprint")).isEqualTo(map(preview.get("documentMetadata")).get("sourceFingerprint"));
  var next=documents.preview(context);var nextReview=documents.submitReview(new ReviewSave(UUID.randomUUID(),context,next.get("sourceFingerprint").toString()));UUID nextId=(UUID)nextReview.get("id");fixture.loginAs(reviewer);documents.decideReview(nextId,new Decision(true,"新资料版本重新核对，不覆盖旧原件"));fixture.loginAs(w.superAdminUserId());
  var confirmation=new CounterpartConfirmation(next.get("documentSha256").toString(),"匿名对方核对人",BusinessTime.today(),"实际回传件绑定新原件");documents.confirmCounterpart(nextId,confirmation,"anonymous-confirmation.png","image/png",proof);
  assertThat(documents.confirmCounterpart(nextId,confirmation,"anonymous-confirmation.png","image/png",proof).get("status")).isEqualTo("BOTH_CONFIRMED");assertThat(documents.counterpartFile(nextId)).containsExactly(proof);
  var table=documents.originalTable(nextId,1,50);assertThat(table.documentMetadata().get("templateKey")).isEqualTo("supplierStatement");assertThat(table.documentMetadata().get("partyRole")).isEqualTo("SUPPLIER");assertThat(table.rows().getFirst().get("amount")).isInstanceOf(String.class);assertThat(map(table.documentMetadata().get("confirmationMetadata")).get("counterpartConfirmed")).isEqualTo(true);
  var scope=new BalanceSelection("2202",auxiliary.id(),base,currency,true,-1);
  assertThatThrownBy(()->documents.saveProfile(new ProfileSave(UUID.randomUUID(),0,"CONTEXT","supplierStatement","SUPPLIER",w.supplierId(),currency,null,new Settings(scope,List.of(),"禁止重复余额",List.of(scope)),"重复来源拒绝"))).isInstanceOf(ApiException.class).hasMessageContaining("重复");
  assertThatThrownBy(()->documents.saveProfile(new ProfileSave(UUID.randomUUID(),0,"CONTEXT","supplierStatement","SUPPLIER",w.supplierId(),currency,null,new Settings(scope,List.of(),"禁止混加口径",List.of(new BalanceSelection("2202",auxiliary.id(),base,currency,false,-1))),"原币与账面不可混加"))).isInstanceOf(ApiException.class).hasMessageContaining("混加");
  assertThat(db.queryForObject("SELECT body_cipher FROM finance_statement_profiles WHERE id=?",String.class,own)).doesNotContain("TEST-BANK-OWN");
  assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(gl);assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger",Integer.class)).isEqualTo(ledger);assertThat(db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class)).isEqualTo(movements);
 }

 private static byte[] externalStatement(Map<String,Object> snapshot){
  try(var workbook=new org.apache.poi.xssf.usermodel.XSSFWorkbook();var bytes=new java.io.ByteArrayOutputStream()){
   var sheet=workbook.createSheet("匿名原8列供应商对账单");var columns=(List<?>)snapshot.get("columns");var actual=map(((List<?>)snapshot.get("rows")).getFirst());
   var header=sheet.createRow(5);for(int index=0;index<columns.size();index++)header.createCell(index).setCellValue(Objects.toString(map(columns.get(index)).get("label"),""));
   for(int r=6;r<=7;r++){var row=sheet.createRow(r);for(int index=0;index<columns.size();index++){
    String key=map(columns.get(index)).get("key").toString();Object value=actual.getOrDefault(key+"Exact",actual.get(key));String text=Objects.toString(value,"");
    if(r==7&&key.equals("amount")){text=new BigDecimal(text).add(new BigDecimal("0.000000000000000000000001")).toPlainString();}row.createCell(index).setCellValue(text);
   }}workbook.write(bytes);return bytes.toByteArray();
  }catch(java.io.IOException e){throw new IllegalStateException(e);}
 }

 @Test void laterRealReversalChangesItsOwnPeriodAndRetainsTheEarlierLedgerFingerprint(){
  var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var w=fixture.seedWorld("statement-old-fp");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID ap=db.queryForObject("SELECT system_posting_style_id('AP_CONTROL')",UUID.class),inventory=db.queryForObject("SELECT system_posting_style_id('INVENTORY_ASSET')",UUID.class);
  db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by) VALUES('2202','匿名应付原科目','',?,'LIABILITY','MANUAL','匿名明确账载来源',1,1,?) ON CONFLICT(code) DO UPDATE SET currency_id=excluded.currency_id",base,w.superAdminUserId());
  db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES('2202',?,?) ON CONFLICT(style_id) DO NOTHING",ap,w.superAdminUserId());
  var auxiliary=auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名历史页尾账套","SUP-"+w.supplierId(),"匿名供应商","SUPPLIER",w.supplierId(),"按真实UUID明确对应","2202"));
  var ref=auxiliaries.resolveNative("2202","SUPPLIER",w.supplierId(),base);
  LocalDate oldDate=BusinessTime.today().withDayOfMonth(1).minusDays(1),reverseDate=BusinessTime.today();
  UUID source=UUID.randomUUID();
  UUID voucher=transactions.execute(status->journals.post("ANON-OLD-FP-"+source,oldDate,"ANON_OLD_FP",source,"ANON_OLD_FP","匿名真实跨期红冲来源",List.of(
      new FinanceControlledJournalService.Entry(inventory,1,new BigDecimal("123.1234567"),"匿名原存货"),
      new FinanceControlledJournalService.Entry(ap,-1,new BigDecimal("123.1234567"),"匿名原应付",new FinanceControlledJournalService.Allocation("2202",base,ref,"ANON-OLD-FP",1,"{}",base,new BigDecimal("123.1234567"),BigDecimal.ONE))),w.superAdminUserId()).voucherId());
  var oldScope=new com.uten.imp.application.port.FinanceAuxiliaryLedgerReadPort.Scope("2202",auxiliary.id(),base,base,oldDate.withDayOfMonth(1),oldDate);
  var before=ledgerReader.read(oldScope);
  transactions.executeWithoutResult(status->journals.reverse(voucher,"ANON-OLD-FP-REV-"+source,reverseDate,"ANON_OLD_FP_REV",source,"ANON_OLD_FP_REV","匿名本期真实反向，不改旧原件",w.superAdminUserId()));
  var after=ledgerReader.read(oldScope);
  assertThat(after.fingerprint()).isEqualTo(before.fingerprint());assertThat(after.local()).isEqualTo(before.local());assertThat(after.original()).isEqualTo(before.original());
  var current=ledgerReader.read(new com.uten.imp.application.port.FinanceAuxiliaryLedgerReadPort.Scope("2202",auxiliary.id(),base,base,reverseDate.withDayOfMonth(1),reverseDate));
  assertThat(current.fingerprint()).isNotEqualTo(before.fingerprint());assertThat(current.sourceRows()).isEqualTo(before.sourceRows()+1);
 }

 @Test void anotherKnownOriginalUnitCannotChangeTheUsdProofOrProveAnUnseenUnitIsZero(){
  var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var w=fixture.seedWorld("statement-unit-fp");fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID usd=UUID.randomUUID(),unseen=UUID.randomUUID();
  for(UUID unit:List.of(usd,unseen))db.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,'匿名实际原币',7,'使用')",unit,"FP-UNIT-"+unit);
  UUID ap=db.queryForObject("SELECT system_posting_style_id('AP_CONTROL')",UUID.class),inventory=db.queryForObject("SELECT system_posting_style_id('INVENTORY_ASSET')",UUID.class);
  db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by) VALUES('2202','匿名应付原科目','',?,'LIABILITY','MANUAL','明确账簿属性及真实单位分别核对',1,1,?) ON CONFLICT(code) DO UPDATE SET currency_id=excluded.currency_id",base,w.superAdminUserId());
  db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES('2202',?,?) ON CONFLICT(style_id) DO NOTHING",ap,w.superAdminUserId());
  var auxiliary=auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名多原币账套","SUP-"+w.supplierId(),"匿名供应商","SUPPLIER",w.supplierId(),"按实际UUID分别核对，不按同名币别混加","2202"));
  var ref=auxiliaries.resolveNative("2202","SUPPLIER",w.supplierId(),base);LocalDate day=BusinessTime.today();
  transactions.executeWithoutResult(status->journals.post("UNIT-USD-"+usd,day,"ANON_UNIT_USD",usd,"ANON_UNIT_USD","匿名真实美元事实",List.of(
    new FinanceControlledJournalService.Entry(inventory,1,new BigDecimal("70"),"原存货"),
    new FinanceControlledJournalService.Entry(ap,-1,new BigDecimal("70"),"原应付",new FinanceControlledJournalService.Allocation("2202",base,ref,"UNIT-USD",1,"{}",usd,BigDecimal.TEN,new BigDecimal("7")))),w.superAdminUserId()));
  var scope=new com.uten.imp.application.port.FinanceAuxiliaryLedgerReadPort.Scope("2202",auxiliary.id(),base,usd,day.withDayOfMonth(1),day);
  var before=ledgerReader.read(scope);
  transactions.executeWithoutResult(status->journals.post("UNIT-CNY-"+usd,day,"ANON_UNIT_CNY",usd,"ANON_UNIT_CNY","已明确其它原币，不改变美元原件",List.of(
    new FinanceControlledJournalService.Entry(inventory,1,new BigDecimal("13"),"另一本币存货"),
    new FinanceControlledJournalService.Entry(ap,-1,new BigDecimal("13"),"另一本币应付",new FinanceControlledJournalService.Allocation("2202",base,ref,"UNIT-CNY",1,"{}",base,new BigDecimal("13"),BigDecimal.ONE))),w.superAdminUserId()));
  var after=ledgerReader.read(scope);
  assertThat(after.originalFingerprint()).isEqualTo(before.originalFingerprint());assertThat(after.fingerprint()).isNotEqualTo(before.fingerprint());
  assertThat(after.original()).isEqualTo(before.original());assertThat(after.original().credit()).isEqualByComparingTo("10");
  var missing=ledgerReader.read(new com.uten.imp.application.port.FinanceAuxiliaryLedgerReadPort.Scope("2202",auxiliary.id(),base,unseen,day.withDayOfMonth(1),day));
  assertThat(missing.original().known()).isFalse();assertThat(missing.original().closing()).isNull();
 }

 private UUID profile(FullChainEndToEndTest fixture,FullChainEndToEndTest.World w,UUID reviewer,String kind,String template,String role,UUID party,UUID currency,Organization organization,Settings settings,long previous){
  fixture.loginAs(w.superAdminUserId());var request=new ProfileSave(UUID.randomUUID(),previous,kind,template,role,party,currency,organization,settings,"匿名实际资料来源");var saved=documents.saveProfile(request);UUID id=(UUID)saved.get("id");assertThat(documents.saveProfile(request).get("id")).isEqualTo(id);
  fixture.loginAs(reviewer);documents.decideProfile(id,new Decision(true,"已按实际资料核对"));fixture.loginAs(w.superAdminUserId());return id;
 }
 private static Organization org(String name,String bank){return new Organization(name,"匿名实际地址","TEST-CONTACT","TEST-FAX",name,"匿名开户行",bank,"匿名收货方","TEST-RECEIVER","按实际资料维护，不填附件样例账号");}
 @SuppressWarnings("unchecked")private static Map<String,Object> map(Object value){return (Map<String,Object>)value;}
}
