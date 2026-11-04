package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinanceMaterialStatementSourcePort;
import com.uten.imp.application.port.FinanceMaterialStatementSourcePort.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.statement.*;
import com.uten.imp.features.finance.report.FinanceReportColumnOptions;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.*;
import com.uten.imp.features.warehouse.inbound.*;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
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
import static com.uten.imp.features.finance.statement.FinanceMaterialStatementContracts.*;
import static org.assertj.core.api.Assertions.*;

/** Anonymous true procurement/IQC/stock/evidence chain. No warehouse or journal facts are fabricated. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
 "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
 "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class FinanceMaterialStatementPostgresTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
 @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;@Autowired ObjectMapper json;
 @Autowired FinanceMaterialStatementService statements;@Autowired FinanceMaterialStatementSourcePort physical;
 @Autowired FinanceAuxiliaryService auxiliaries;@Autowired ProcurementInspectionService inspections;
 @Autowired ProcurementIqcStockInService stockIn;
 @Autowired com.uten.imp.features.stock.StockDocService stockDocs;
 @Autowired com.uten.imp.features.subcontract.order.SubcontractOrderService subcontractOrders;
 @Autowired com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService procurementFinance;
 @Autowired com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService materialReturns;
 @Autowired FinanceMaterialStatementReferences references;
 @Autowired com.uten.imp.features.finance.report.FinanceTemplateSourceService originalTemplates;
 @Autowired com.uten.imp.application.port.FinanceAuxiliaryLedgerReadPort auxiliaryLedger;
 @Autowired com.uten.imp.features.finance.gl.FinanceControlledJournalService journals;
 @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
 UUID arStyle;
 FullChainEndToEndTest full;FullChainEndToEndTest.World w;UUID reviewer;LocalDate day;
 @BeforeEach void setup(){full=new FullChainEndToEndTest();beans.autowireBean(full);w=full.seedWorld("material-"+UUID.randomUUID().toString().substring(0,8));full.loginAs(w.superAdminUserId());full.seedChartOfAccounts();day=BusinessTime.today();reviewer=full.createUserWithPerms(w,"material-review-"+UUID.randomUUID().toString().substring(0,8),"finance_report:view","finance:view:all","finance_post:execute","payment_style:edit");}
 @AfterEach void logout(){SecurityContextHolder.clearContext();}
 @Test void realPendingReceiptIsNotInventoryAndTwoActualStockInsRemainSeparateAndConserveExactKg()throws Exception{
  var procurement=new SupplierPrepaymentPostgresTest();beans.autowireBean(procurement);UUID receipt=procurement.receipt(full,w,w.currencyId(),true,false);
  UUID line=db.queryForObject("SELECT id FROM purchase_receipt_items WHERE receipt_id=?",UUID.class,receipt);var key=new Key(Kind.PURCHASE_RECEIPT_LINE,line);
  assertThat(physical.readForIdentity(List.of(key)).getFirst().effects()).isEmpty();
  assertThat(physical.candidates(new Query(Kind.PURCHASE_RECEIPT_LINE,w.supplierId(),null,w.goodsA(),null,day,day,null,1,200)).items()).isEmpty();
  UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_id=?",UUID.class,receipt);
  inspections.dispose("PURCHASE",receipt,inspection,new InspectionDispositionRequest("PASS",null,"匿名实物全部合格","material-pass-"+receipt));
  UUID event=db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",UUID.class,inspection);
  UUID confirmer=full.createIqcWarehouseConfirmer(w,"material-stock-"+receipt);full.loginAs(confirmer);
  stockIn.confirm("PURCHASE",receipt,new ConfirmRequest("material-stock-a-"+receipt,List.of(new ConfirmItem(event,n("0.75"),n("2"),"MAT-A",w.warehouseId()))));
  stockIn.confirm("PURCHASE",receipt,new ConfirmRequest("material-stock-b-"+receipt,List.of(new ConfirmItem(event,n("1.25"),n("1.25"),"MAT-B",w.warehouseId()))));
  full.loginAs(w.superAdminUserId());var fact=physical.readForIdentity(List.of(key)).getFirst();assertThat(fact.identityComplete()).isTrue();assertThat(fact.effects()).hasSize(2);
  assertThat(fact.effects()).allSatisfy(e->{assertThat(e.stockInItemId()).isNotNull();assertThat(e.sourceBusinessDate()).isEqualTo(day);assertThat(e.businessDate()).isEqualTo(day);assertThat(e.eventSign()).isEqualTo(1);});
  assertThat(fact.effects().stream().map(Effect::baseQuantity).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("2");
  UUID context=materialContext();approveDraft(context,EvidenceKind.GOODS,new SourceGoods(context,Kind.PURCHASE_RECEIPT_LINE,w.goodsA(),null,FlowRole.INBOUND,"匿名原铜条对应，原料和成品UUID不同",true,"财务原文铜条","财务57#规格"));
  approveDraft(context,EvidenceKind.NATIVE_PARTY,new NativePartyLink(UUID.randomUUID(),context,0,"SUPPLIER",w.supplierId(),Kind.PURCHASE_RECEIPT_LINE,"匿名真实供应商对应财务客户",true));
  approveDraft(context,EvidenceKind.UNIT,new UnitEvidence(UUID.randomUUID(),context,0,w.unitId(),n("12.345678901234567890123456"),null,"匿名已核基础单位为明确重量",w.goodsA(),null,"BASE",null,"EXACT_UNIT"));
  approveDraft(context,EvidenceKind.OPENING,new OpeningEvidence(UUID.randomUUID(),context,0,day,n("100.000000000000000000000001"),"匿名签认期初重量"));
  assertThat(references.options("accounts",null,1,100).get("items")).isInstanceOf(List.class);assertThat(references.labels(Map.of("goods",List.of(w.goodsA().toString()))).get("goods")).isInstanceOf(Map.class);assertThat(references.sources(context,Kind.PURCHASE_RECEIPT_LINE,day,day,w.supplierId(),null,null,1,100).items()).hasSize(1);assertThat(statements.source(key).identityComplete()).isTrue();
  var table=statements.snapshotFromAnchorCohort(context,day,day);assertThat(table.columns()).hasSize(10);assertThat(table.rows()).hasSize(4);
  var actual=table.rows().stream().filter(row->"PHYSICAL".equals(row.get("__rowKind"))).toList();assertThat(actual).hasSize(2);
  assertThat(actual.stream().map(row->new BigDecimal(row.get("inWeight").toString())).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("24.691357802469135780246912");
  assertThat(actual.stream().map(row->new BigDecimal(row.get("loss").toString())).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("0.123456789012345678901234560");
  assertThat(new BigDecimal(table.documentMetadata().get("closingWeightKg").toString())).isEqualByComparingTo("124.567901013456790101345678440");
  assertThat(actual).allSatisfy(row->{assertThat(row.get("outQty")).isNull();assertThat(row.get("processAmount")).isNull();assertThat(row.get("goodsName")).isEqualTo("财务原文铜条");});
  assertThat(table.documentMetadata().get("materialContextIds")).isEqualTo(List.of(context));
  int stockBefore=db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class),glBefore=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class);
  byte[] file=originalWorkbook(table);var imported=originalTemplates.preview("otherReceivableStatement",java.time.YearMonth.from(day).toString(),"anonymous-material.xlsx",file,false);
  var mappings=new ArrayList<CompareRow>();for(int i=0;i<table.rows().size();i++)mappings.add(new CompareRow(i+4,table.rows().get(i).get("__rowKey").toString()));
  var compared=statements.compare(new Compare(imported.importId(),(UUID)statements.get(context).get("auxiliary_id"),(UUID)statements.get(context).get("accounting_currency_id"),context,day,day,mappings,true));
  assertThat((List<?>)compared.get("unmappedSourceRows")).isEmpty();for(Object value:(List<?>)compared.get("results"))assertThat((List<?>)((Map<?,?>)value).get("differences")).isEmpty();
  assertThat(db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class)).isEqualTo(stockBefore);assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(glBefore);

 }
 @Test void exactRawDraftSurvivesUnknownOperationReplayAndMakerCannotApproveOwnContext(){
  UUID context=materialContext();UUID request=UUID.randomUUID();var draft=new Draft(request,null,-1,context,contextVersion(context),null,EvidenceKind.OPENING,json.valueToTree(Map.of("contextId",context,"effectiveFrom",day,"balanceWeightKg","0.1234567890123456789012345678901","sourceReference","匿名暂存超支持精度原文")));
  var saved=statements.saveDraft(draft);assertThat(statements.saveDraft(draft).get("evidenceId").toString()).isEqualTo(saved.get("evidenceId").toString());UUID evidence=UUID.fromString(saved.get("evidenceId").toString());
  assertThat(statements.evidence(evidence).get("input").toString()).contains("0.1234567890123456789012345678901");
  assertThatThrownBy(()->statements.submit(evidence,action(evidence,context))).isInstanceOf(ApiException.class).hasMessageContaining("无损");
  assertThat(statements.operation(request).get("evidenceId").toString()).isEqualTo(saved.get("evidenceId").toString());
  assertThat(statements.verifyOperation(request,new VerifyOperation("/finance/material-statements/drafts",json.valueToTree(draft))).get("evidenceId").toString()).isEqualTo(evidence.toString());
  var tampered=json.valueToTree(draft);((com.fasterxml.jackson.databind.node.ObjectNode)tampered.path("input")).put("balanceWeightKg","999");assertThatThrownBy(()->statements.verifyOperation(request,new VerifyOperation("/finance/material-statements/drafts",tampered))).isInstanceOf(ApiException.class).hasMessageContaining("不同");full.loginAs(reviewer);assertThatThrownBy(()->statements.operation(request)).isInstanceOf(ApiException.class);full.loginAs(w.superAdminUserId());
  assertThat(db.queryForObject("SELECT count(*) FROM finance_material_evidence WHERE id=? AND status='DRAFT'",Integer.class,evidence)).isEqualTo(1);
 }
 @Test void individualUnitRuleCanBeDisabledAndRestoredWithAnotherReviewerWithoutClosingMaterialGroup(){
  UUID context=materialContext();approveDraft(context,EvidenceKind.GOODS,new SourceGoods(context,Kind.PURCHASE_RECEIPT_LINE,w.goodsA(),null,FlowRole.INBOUND,"真实原料规则",true,"财务原料名","57#"));
  var unit=new UnitEvidence(UUID.randomUUID(),context,0,w.unitId(),n("2.5"),null,"真实已核原单位系数",w.goodsA(),null,"BASE",null,"EXACT_UNIT");approveDraft(context,EvidenceKind.UNIT,unit);UUID before=currentRule(context,"UNIT");
  var disabled=new UnitEvidence(UUID.randomUUID(),context,0,w.unitId(),n("2.5"),null,"只停用这一错误规则，不撤组不造0",w.goodsA(),null,"BASE",null,"EXACT_UNIT",false);approveDraft(context,EvidenceKind.UNIT,disabled,before);assertThat(statements.evidence(currentRule(context,"UNIT")).get("input").toString()).contains("false");assertThat(db.queryForObject("SELECT active FROM finance_material_contexts WHERE id=?",Boolean.class,context)).isTrue();
  approveDraft(context,EvidenceKind.UNIT,unit,currentRule(context,"UNIT"));assertThat(db.queryForObject("SELECT count(*) FROM finance_material_evidence WHERE context_id=? AND kind='UNIT'",Integer.class,context)).isEqualTo(3);assertThat(statements.evidence(before).get("current_approved")).isEqualTo(false);
 }
 @Test void independentSidebarReferenceKeepsOriginalNameAndPeriodPriceWithoutInventingBodyGroupQuantityOrGl(){
  UUID context=materialContext();var before=statements.snapshotFromAnchorCohort(context,day,day);int groups=db.queryForObject("SELECT count(*) FROM finance_material_contexts",Integer.class),stock=db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class),gl=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class);UUID base=(UUID)statements.get(context).get("accounting_currency_id");
  var line=new SidebarLine(context,3,day.withDayOfMonth(1),day.withDayOfMonth(day.lengthOfMonth()),null,"原旁算16A圆插铜粒","PCS",n("0.036"),base,"原附件4 L7/O7本型号本期间参考报价",true);approveDraft(context,EvidenceKind.SIDEBAR,line);
  var after=statements.snapshotFromAnchorCohort(context,day,day);assertThat(after.rows()).hasSize(before.rows().size());assertThat(sideCell(after,"L7").get("value")).isEqualTo("原旁算16A圆插铜粒");assertThat(sideCell(after,"O7").get("value")).isEqualTo("0.036");for(String cell:List.of("N7","P7","Q7")){assertThat(sideCell(after,cell).get("value")).isNull();assertThat(sideCell(after,cell).get("pending")).isEqualTo(true);}
  var next=day.plusMonths(1);assertThat(sideCell(statements.snapshotFromAnchorCohort(context,next,next),"O7").get("value")).isNull();assertThat(db.queryForObject("SELECT count(*) FROM finance_material_contexts",Integer.class)).isEqualTo(groups);assertThat(db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class)).isEqualTo(stock);assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(gl);
  var disabled=new SidebarLine(context,3,line.dateFrom(),line.dateTo(),null,line.productNameCaption(),"PCS",line.referencePrice(),base,"明确停用本期间参考资料",false);approveDraft(context,EvidenceKind.SIDEBAR,disabled,currentRule(context,"SIDEBAR"));assertThat(sideCell(statements.snapshotFromAnchorCohort(context,day,day),"O7").get("value")).isNull();
 }
 UUID currentRule(UUID context,String kind){return db.queryForObject("SELECT id FROM finance_material_evidence WHERE context_id=? AND kind=? AND current_approved",UUID.class,context,kind);}
 @SuppressWarnings("unchecked")Map<String,Object> sideCell(com.uten.imp.features.finance.report.ReportTableResponse table,String address){return ((List<Map<String,Object>>)table.documentMetadata().get("supplementalCells")).stream().filter(cell->address.equals(cell.get("sourceCell"))).findFirst().orElseThrow();}
 @Test void durableUnwrittenCancellationMatchesOriginalActorAndBodyAndRejectsEveryLateOriginalWrite(){
  UUID context=materialContext(),request=UUID.randomUUID();var draft=new Draft(request,null,-1,context,contextVersion(context),null,EvidenceKind.OPENING,json.valueToTree(Map.of("contextId",context,"effectiveFrom",day,"balanceWeightKg","2.125","sourceReference","匿名未写入原请求")));var command=new VerifyOperation("/finance/material-statements/drafts",json.valueToTree(draft));
  var cancelled=statements.cancelUnwrittenOperation(request,command);assertThat(cancelled.get("receiptState")).isEqualTo("CANCELLED_NOT_WRITTEN");assertThat(statements.cancelUnwrittenOperation(request,command).get("requestId").toString()).isEqualTo(request.toString());assertThat(statements.verifyOperation(request,command).get("receiptState")).isEqualTo("CANCELLED_NOT_WRITTEN");
  assertThatThrownBy(()->statements.saveDraft(draft)).isInstanceOf(ApiException.class).hasMessageContaining("已明确终止");assertThat(db.queryForObject("SELECT count(*) FROM finance_material_evidence WHERE id=?",Integer.class,request)).isZero();
  var altered=json.valueToTree(draft);((com.fasterxml.jackson.databind.node.ObjectNode)altered.path("input")).put("balanceWeightKg","2.126");assertThatThrownBy(()->statements.cancelUnwrittenOperation(request,new VerifyOperation(command.path(),altered))).isInstanceOf(ApiException.class).hasMessageContaining("参数");
  full.loginAs(reviewer);assertThatThrownBy(()->statements.cancelUnwrittenOperation(request,command)).isInstanceOf(ApiException.class);full.loginAs(w.superAdminUserId());
  UUID actualRequest=UUID.randomUUID();var actual=new Draft(actualRequest,null,-1,context,contextVersion(context),null,EvidenceKind.OPENING,draft.input());var saved=statements.saveDraft(actual);var completed=statements.cancelUnwrittenOperation(actualRequest,new VerifyOperation(command.path(),json.valueToTree(actual)));assertThat(completed.get("evidenceId").toString()).isEqualTo(saved.get("evidenceId").toString());assertThat(completed).doesNotContainKey("receiptState");
 }
 @Test void simultaneousCancelAndSaveChooseOneDurableOutcomeInBothCommitOrders()throws Exception{
  UUID context=materialContext();var executor=java.util.concurrent.Executors.newFixedThreadPool(2);var held=new java.util.concurrent.CountDownLatch(1);var release=new java.util.concurrent.CountDownLatch(1);
  try{
   UUID request=UUID.randomUUID();var draft=new Draft(request,null,-1,context,contextVersion(context),null,EvidenceKind.OPENING,json.valueToTree(Map.of("contextId",context,"effectiveFrom",day,"balanceWeightKg","1.125","sourceReference","匿名并发原请求")));var command=new VerifyOperation("/finance/material-statements/drafts",json.valueToTree(draft));
   var first=actor(executor,()->new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->{requestLock(request);var result=statements.saveDraft(draft);held.countDown();await(release);return result;}));assertThat(held.await(20,java.util.concurrent.TimeUnit.SECONDS)).isTrue();var second=actor(executor,()->statements.cancelUnwrittenOperation(request,command));assertThatThrownBy(()->second.get(100,java.util.concurrent.TimeUnit.MILLISECONDS)).isInstanceOf(java.util.concurrent.TimeoutException.class);release.countDown();
   assertThat(second.get(20,java.util.concurrent.TimeUnit.SECONDS).get("evidenceId").toString()).isEqualTo(first.get(20,java.util.concurrent.TimeUnit.SECONDS).get("evidenceId").toString());assertThat(db.queryForObject("SELECT count(*) FROM finance_material_evidence WHERE id=?",Integer.class,request)).isEqualTo(1);
   var cancelledHeld=new java.util.concurrent.CountDownLatch(1);var cancelRelease=new java.util.concurrent.CountDownLatch(1);
   try{UUID next=UUID.randomUUID();var nextDraft=new Draft(next,null,-1,context,contextVersion(context),null,EvidenceKind.OPENING,draft.input());var nextCommand=new VerifyOperation(command.path(),json.valueToTree(nextDraft));
    var cancelFirst=actor(executor,()->new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->{requestLock(next);var result=statements.cancelUnwrittenOperation(next,nextCommand);cancelledHeld.countDown();await(cancelRelease);return result;}));assertThat(cancelledHeld.await(20,java.util.concurrent.TimeUnit.SECONDS)).isTrue();var late=actor(executor,()->statements.saveDraft(nextDraft));assertThatThrownBy(()->late.get(100,java.util.concurrent.TimeUnit.MILLISECONDS)).isInstanceOf(java.util.concurrent.TimeoutException.class);cancelRelease.countDown();assertThat(cancelFirst.get(20,java.util.concurrent.TimeUnit.SECONDS).get("receiptState")).isEqualTo("CANCELLED_NOT_WRITTEN");assertThatThrownBy(()->late.get(20,java.util.concurrent.TimeUnit.SECONDS)).hasRootCauseInstanceOf(ApiException.class);assertThat(db.queryForObject("SELECT count(*) FROM finance_material_evidence WHERE id=?",Integer.class,next)).isZero();
   }finally{cancelRelease.countDown();}
  }finally{release.countDown();executor.shutdownNow();}
 }
 <T>java.util.concurrent.Future<T> actor(java.util.concurrent.ExecutorService executor,java.util.concurrent.Callable<T> task){return executor.submit(()->{full.loginAs(w.superAdminUserId());try{return task.call();}finally{SecurityContextHolder.clearContext();}});}
 void requestLock(UUID id){db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,1005))",row->{},"finance-material:request:"+id);}
 static void await(java.util.concurrent.CountDownLatch latch){try{if(!latch.await(20,java.util.concurrent.TimeUnit.SECONDS))throw new IllegalStateException("anonymous request gate timed out");}catch(InterruptedException error){Thread.currentThread().interrupt();throw new IllegalStateException(error);}}
 @Test void trueSubcontractMaterialIssueAndReturnAreSignedKgOnlyAndRealReturnReversalDoesNotInventPcsOrProcessing(){
  UUID material=full.ensureSubcontractDirectMaterial(w,w.goodsE());full.receiveSubcontractMaterial(w,material,"20");
  var order=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();order.setBillDate(day);order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(w.currencyId());order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
  var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();line.setGoodsId(w.goodsE());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(n("10"));line.setPrice(n("5"));order.setItems(List.of(line));UUID orderId=subcontractOrders.create(order).getId();UUID approver=full.createApprover(w);procurementFinance.submit("SUBCONTRACT",orderId);full.loginAs(approver);full.approvePendingFinance("SUBCONTRACT",orderId,BigDecimal.ONE);full.loginAs(w.superAdminUserId());UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,orderId);
  var issues=full.drawAndIssueSubcontract(orderItem,n("10"),"material-real-issue-"+orderItem);UUID issueLine=db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE issue_id=?",UUID.class,issues.getFirst());
  var returned=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest();returned.setBillDate(day);returned.setSupplierId(w.supplierId());returned.setWarehouseId(w.warehouseId());var returnedLine=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine();returnedLine.setGoodsId(material);returnedLine.setUnitId(w.unitId());returnedLine.setUnitRate(BigDecimal.ONE);returnedLine.setQty(n("4"));returnedLine.setMaterialIssueItemId(issueLine);returnedLine.setOrderItemId(orderItem);returnedLine.setParentGoodsId(w.goodsE());returned.setItems(List.of(returnedLine));UUID returnId=materialReturns.create(returned).getId();materialReturns.approve(returnId);UUID returnLine=db.queryForObject("SELECT id FROM subcontract_material_return_items WHERE material_return_id=?",UUID.class,returnId);
  var issue=physical.readForIdentity(List.of(new Key(Kind.SUBCONTRACT_MATERIAL_ISSUE_LINE,issueLine))).getFirst();var back=physical.readForIdentity(List.of(new Key(Kind.SUBCONTRACT_MATERIAL_RETURN_LINE,returnLine))).getFirst();assertThat(issue.effects()).hasSize(1);assertThat(back.effects()).hasSize(1);assertThat(issue.effects().getFirst().eventSign()).isEqualTo(1);assertThat(back.effects().getFirst().eventSign()).isEqualTo(-1);assertThat(back.effects().getFirst().reversal()).isFalse();
  UUID context=materialContext(Kind.SUBCONTRACT_MATERIAL_ISSUE_LINE,Kind.SUBCONTRACT_MATERIAL_RETURN_LINE);
  for(var kind:List.of(Kind.SUBCONTRACT_MATERIAL_ISSUE_LINE,Kind.SUBCONTRACT_MATERIAL_RETURN_LINE)){approveDraft(context,EvidenceKind.GOODS,new SourceGoods(context,kind,material,null,kind==Kind.SUBCONTRACT_MATERIAL_ISSUE_LINE?FlowRole.MATERIAL_OUT:FlowRole.MATERIAL_RETURN,"真实委外材料，不是加工产物"));approveDraft(context,EvidenceKind.NATIVE_PARTY,new NativePartyLink(UUID.randomUUID(),context,0,"SUPPLIER",w.supplierId(),kind,"真实委外商原材料归户",true));}
  approveDraft(context,EvidenceKind.UNIT,new UnitEvidence(UUID.randomUUID(),context,0,w.unitId(),n("2.5"),n("999"),"仅明确原料每基本量2.5KG，PCS系数不能用于委外原料",material,null,"BASE",null,"EXACT_UNIT"));approveDraft(context,EvidenceKind.OPENING,new OpeningEvidence(UUID.randomUUID(),context,0,day,n("100"),"已核原料100KG期初"));
  var table=statements.snapshot(context,day,day);var rows=table.rows().stream().filter(row->"PHYSICAL".equals(row.get("__rowKind"))).toList();assertThat(rows).hasSize(2);assertThat(rows).allSatisfy(row->{assertThat(row.get("outQty")).isNull();assertThat(row.get("processAmount")).isNull();assertThat(row.get("inWeight")).isNull();assertThat(row.get("loss")).isNull();});assertThat(new BigDecimal(table.documentMetadata().get("closingWeightKg").toString())).isEqualByComparingTo("85");
  materialReturns.reverse(returnId);var history=physical.readForIdentity(List.of(new Key(Kind.SUBCONTRACT_MATERIAL_RETURN_LINE,returnLine))).getFirst();assertThat(history.identityComplete()).isTrue();assertThat(history.effects()).hasSize(2);assertThat(history.effects().stream().filter(Effect::reversal)).allSatisfy(effect->assertThat(effect.eventSign()).isEqualTo(1));assertThat(new BigDecimal(statements.snapshot(context,day,day).documentMetadata().get("closingWeightKg").toString())).isEqualByComparingTo("75");
 }
 @Test void sameProductCurrencyCohortsNeverDuplicateCustodyAndKnownOtherCurrencyDoesNotPolluteOriginalFingerprint(){
  UUID local=materialContext();var c=statements.get(local);UUID base=(UUID)c.get("accounting_currency_id"),aux=(UUID)c.get("auxiliary_id"),foreign=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,?,7,'使用')",foreign,"MAT-USD-"+foreign,"匿名美元-"+foreign);assertThat(foreign).isNotEqualTo(base);
  UUID usd=variant(local,AmountBasis.ORIGINAL,foreign),cny=variant(local,AmountBasis.ORIGINAL,base);
  assertThat(statements.snapshotFromAnchorCohort(usd,day,day).documentMetadata().get("materialContextIds")).isEqualTo(List.of(usd));assertThat(statements.snapshotFromAnchorCohort(cny,day,day).documentMetadata().get("materialContextIds")).isEqualTo(List.of(cny));
  assertThatThrownBy(()->statements.snapshot(aux,base,null,day,day)).isInstanceOf(ApiException.class).hasMessageContaining("金额口径");
  var ref=auxiliaries.inspect(new com.uten.imp.application.port.FinancialAuxiliaryValidationPort.Selection("1221",aux,base));UUID income=style("INCOME");
  new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->journals.post("MAT-FX-"+UUID.randomUUID(),day,"MATERIAL_FX",UUID.randomUUID(),"MATERIAL_FX_SOURCE","匿名实际USD原币1本币7",List.of(new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(arStyle,1,n("7"),"原USD1",new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Allocation("1221",base,ref,"USD",1,"{}",foreign,BigDecimal.ONE,n("7"))),new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(income,-1,n("7"),"实际平衡分录")),w.superAdminUserId()));
  var onlyOther=auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名只有CNY的独立辅助",UUID.randomUUID().toString(),"匿名独立原码","CUSTOMER",w.clientId(),"仅实际CNY来源不能证明USD为0","1221"));var otherRef=auxiliaries.inspect(new com.uten.imp.application.port.FinancialAuxiliaryValidationPort.Selection("1221",onlyOther.id(),base));
  new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->journals.post("MAT-ONLY-CNY-"+UUID.randomUUID(),day,"MATERIAL_ONLY_CNY",UUID.randomUUID(),"MATERIAL_CNY_SOURCE","匿名只有其他原币事实",List.of(new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(arStyle,1,n("2"),"实际CNY2",new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Allocation("1221",base,otherRef,"CNY",1,"{}",base,n("2"),BigDecimal.ONE)),new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(income,-1,n("2"),"实际平衡分录")),w.superAdminUserId()));
  assertThat(auxiliaryLedger.read(new com.uten.imp.application.port.FinanceAuxiliaryLedgerReadPort.Scope("1221",onlyOther.id(),base,foreign,day,day)).original().closing()).isNull();
  var before=statements.snapshotFromAnchorCohort(usd,day,day);String fp=before.documentMetadata().get("sourceFingerprint").toString();
  new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->journals.post("MAT-CNY-"+UUID.randomUUID(),day,"MATERIAL_CNY",UUID.randomUUID(),"MATERIAL_CNY_SOURCE","匿名同辅助完整CNY2本币2",List.of(new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(arStyle,1,n("2"),"原CNY2",new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Allocation("1221",base,ref,"CNY",1,"{}",base,n("2"),BigDecimal.ONE)),new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(income,-1,n("2"),"实际平衡分录")),w.superAdminUserId()));
  assertThat(statements.snapshotFromAnchorCohort(usd,day,day).documentMetadata().get("sourceFingerprint")).isEqualTo(fp);
  var procurement=new SupplierPrepaymentPostgresTest();beans.autowireBean(procurement);UUID receipt=procurement.receipt(full,w,w.currencyId(),true);UUID line=db.queryForObject("SELECT id FROM purchase_receipt_items WHERE receipt_id=?",UUID.class,receipt);var source=new Key(Kind.PURCHASE_RECEIPT_LINE,line);var fact=physical.readForIdentity(List.of(source)).getFirst();
  for(UUID context:List.of(local,usd)){approveDraft(context,EvidenceKind.GOODS,new SourceGoods(context,Kind.PURCHASE_RECEIPT_LINE,w.goodsA(),null,FlowRole.INBOUND,"同一真实原料，只维护明确展示族"));approveDraft(context,EvidenceKind.UNIT,new UnitEvidence(UUID.randomUUID(),context,0,w.unitId(),BigDecimal.ONE,null,"原料基本单位已核为KG",w.goodsA(),null,"BASE",null,"EXACT_UNIT"));approveDraft(context,EvidenceKind.OPENING,new OpeningEvidence(UUID.randomUUID(),context,0,day,BigDecimal.ZERO,"真实原料开期0，非金额证明"));}
  approveDraft(local,EvidenceKind.NATIVE_PARTY,new NativePartyLink(UUID.randomUUID(),local,0,"SUPPLIER",w.supplierId(),Kind.PURCHASE_RECEIPT_LINE,"原供应商唯一归户",true));
  assertThatThrownBy(()->approveDraft(usd,EvidenceKind.NATIVE_PARTY,new NativePartyLink(UUID.randomUUID(),usd,0,"SUPPLIER",w.supplierId(),Kind.PURCHASE_RECEIPT_LINE,"不能仅因新币别族重复领同一实物",true))).isInstanceOf(ApiException.class).hasMessageContaining("另一已审分组");full.loginAs(w.superAdminUserId());
  int movements=db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class),entries=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class);
  approveDraft(usd,EvidenceKind.SOURCE_RELATION,new SourceRelation(usd,source,fact.identityFingerprint(),"明确把这一原单归USD纸面组；只移动资料归属，不新增库存或GL"));
  approveDraft(usd,EvidenceKind.COVERAGE,new SourceCoverage(usd,Kind.PURCHASE_RECEIPT_LINE,day,day,List.of(source),true,"逐源核对本段完整归属"));
  var localTable=statements.snapshotFromAnchorCohort(local,day,day);var usdTable=statements.snapshotFromAnchorCohort(usd,day,day);assertThat(localTable.rows().stream().filter(row->"PHYSICAL".equals(row.get("__rowKind")))).isEmpty();assertThat(usdTable.rows().stream().filter(row->"PHYSICAL".equals(row.get("__rowKind")))).hasSize(1);
  assertThat(db.queryForObject("SELECT count(*) FROM stock_movements",Integer.class)).isEqualTo(movements);assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(entries);
  db.update("UPDATE purchase_receipts SET remark='anonymous changed source routing basis' WHERE id=?",receipt);
  var uncertain=statements.snapshotFromAnchorCohort(usd,day,day);assertThat(uncertain.documentMetadata().get("closingWeightKg")).isNull();assertThat(uncertain.rows().stream().filter(row->"PHYSICAL".equals(row.get("__rowKind")))).isEmpty();
  var refreshed=physical.readForIdentity(List.of(source)).getFirst();approveDraft(usd,EvidenceKind.SOURCE_RELATION,new SourceRelation(usd,source,refreshed.identityFingerprint(),"重读变化摘要并重新确认原单归属"),currentRule(usd,"SOURCE_RELATION"));approveDraft(usd,EvidenceKind.COVERAGE,new SourceCoverage(usd,Kind.PURCHASE_RECEIPT_LINE,day,day,List.of(source),true,"重读完整源范围，不将失效原来源当0"),currentRule(usd,"COVERAGE"));assertThat(statements.snapshotFromAnchorCohort(usd,day,day).documentMetadata().get("closingWeightKg")).isNotNull();

 }
 UUID variant(UUID original,AmountBasis basis,UUID unit){var c=statements.get(original);UUID request=UUID.randomUUID();var input=new ContextInput(request,null,null,(UUID)c.get("auxiliary_id"),(UUID)c.get("accounting_currency_id"),basis,unit,(UUID)c.get("goods_id"),(UUID)c.get("color_id"),day,"匿名原实际单位及纸面族","1221",1,Set.of(Kind.PURCHASE_RECEIPT_LINE),"原稿产品名称57#","原规格",w.unitId(),"PCS",null,null,1);var result=statements.saveContext(input);UUID context=UUID.fromString(result.get("contextId").toString()),evidence=UUID.fromString(result.get("evidenceId").toString());statements.submit(evidence,action(evidence,context));full.loginAs(reviewer);statements.decide(evidence,"approve",action(evidence,context));full.loginAs(w.superAdminUserId());return context;}
 @Test void chargedAndGiftActualTranchesAreElevenPhysicalUnitsAndNativeReversalUsesRealMovementDates(){
  var procurement=new PurchaseReturnActualCostGlEndToEndTest();beans.autowireBean(procurement);org.springframework.test.util.ReflectionTestUtils.setField(procurement,"harness",full);
  Object fixture=org.springframework.test.util.ReflectionTestUtils.invokeMethod(procurement,"fixture",false);
  var world=org.springframework.test.util.ReflectionTestUtils.<FullChainEndToEndTest.World>invokeMethod(fixture,"w");
  UUID receipt=org.springframework.test.util.ReflectionTestUtils.invokeMethod(procurement,"receipt",fixture,"10","1");procurement.receipts.approve(receipt);
  UUID line=db.queryForObject("SELECT id FROM purchase_receipt_items WHERE receipt_id=?",UUID.class,receipt);var key=new Key(Kind.PURCHASE_RECEIPT_LINE,line);
  assertThat(physical.readForIdentity(List.of(key)).getFirst().effects()).isEmpty();org.springframework.test.util.ReflectionTestUtils.invokeMethod(procurement,"passAndStock",fixture,receipt);
  var original=physical.read(List.of(key)).getFirst();assertThat(original.quantity()).isEqualByComparingTo("11");assertThat(original.effects()).hasSize(2);
  assertThat(original.effects().stream().map(e->e.sourceSnapshot().get("quantity_tranche").toString()).toList()).containsExactlyInAnyOrder("CHARGED","GIFT");
  full.loginAs(world.superAdminUserId());procurement.receipts.reverse(receipt);var historical=physical.readForIdentity(List.of(key)).getFirst();assertThat(historical.identityComplete()).isTrue();assertThat(historical.identityFingerprint()).isEqualTo(original.identityFingerprint());assertThat(historical.effects()).hasSize(4);
  assertThat(historical.effects().stream().map(e->e.baseQuantity().multiply(BigDecimal.valueOf(e.eventSign()))).reduce(BigDecimal.ZERO,BigDecimal::add)).isZero();
  assertThat(historical.effects().stream().filter(Effect::reversal)).allSatisfy(effect->{assertThat(effect.businessDate()).isEqualTo(effect.confirmationDate());assertThat(effect.eventSign()).isEqualTo(-1);});
 }
 @Test void actualProcessingVatAndZeroWaiverPreserveOneReceivableAndRealReversalWithNoTaxGuess(){
  UUID context=materialContext(Kind.STOCK_OTHER_OUT_LINE);var c=statements.get(context);UUID aux=UUID.fromString(c.get("auxiliary_id").toString()),base=UUID.fromString(c.get("accounting_currency_id").toString());
  full.receiveSubcontractMaterial(w,w.goodsA(),"5");
  var out=new com.uten.imp.features.stock.dto.StockDocSaveRequest();out.setDocType("OTHER_OUT");out.setBillDate(day);out.setWarehouseId(w.warehouseId());out.setClientId(w.clientId());
  var item=new com.uten.imp.features.stock.dto.StockDocItemLine();item.setGoodsId(w.goodsA());item.setUnitId(w.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(n("2"));item.setWeight(n("2"));item.setPlace("MAT-OUT");out.setItems(List.of(item));UUID doc=stockDocs.create(out).getId();stockDocs.approve(doc);
  UUID line=db.queryForObject("SELECT id FROM stock_document_items WHERE doc_id=?",UUID.class,doc);var source=new Key(Kind.STOCK_OTHER_OUT_LINE,line);var fact=physical.readForIdentity(List.of(source)).getFirst();var effect=fact.effects().getFirst();
  approveDraft(context,EvidenceKind.GOODS,new SourceGoods(context,Kind.STOCK_OTHER_OUT_LINE,w.goodsA(),null,FlowRole.FINISHED_OUT,"匿名原成品对应",true,"财务原文铜粒（酸洗）","财务成品规格"));
  approveDraft(context,EvidenceKind.NATIVE_PARTY,new NativePartyLink(UUID.randomUUID(),context,0,"CUSTOMER",w.clientId(),Kind.STOCK_OTHER_OUT_LINE,"匿名真实原客户对应",true));
  approveDraft(context,EvidenceKind.UNIT,new UnitEvidence(UUID.randomUUID(),context,0,w.unitId(),BigDecimal.ONE,BigDecimal.ONE,"匿名实物单位明确KG及PCS",w.goodsA(),null,"BASE",null,"EXACT_UNIT"));
  approveDraft(context,EvidenceKind.OPENING,new OpeningEvidence(UUID.randomUUID(),context,0,day,n("5"),"匿名开期实物重量5KG"));
  var zero=new ZeroProcessing(context,source,fact.identityFingerprint(),effect.movementId(),effect.identityFingerprint(),true,"匿名明确免加工款，保留取消出口");approveDraft(context,EvidenceKind.ZERO,zero);
  assertThat(statements.snapshot(context,day,day).rows().stream().filter(row->"PHYSICAL".equals(row.get("__rowKind"))).findFirst().orElseThrow().get("processAmount").toString()).isEqualTo("0");
  UUID income=style("INCOME"),tax=style("LIABILITY");db.update("INSERT INTO finance_report_line_bindings(line_key,binding_kind,style_id,created_by) VALUES('BS_36','STYLE',?,?)",tax,w.superAdminUserId());
  var ref=auxiliaries.inspect(new com.uten.imp.application.port.FinancialAuxiliaryValidationPort.Selection("1221",aux,base));
  var posted=new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->journals.post("MAT-INV-"+UUID.randomUUID(),day,"MATERIAL_TEST",UUID.randomUUID(),"MATERIAL_BILL","匿名真实平衡应收加工及实际税",List.of(new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(arStyle,1,n("113"),"实际应收113",new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Allocation("1221",base,ref,"original",1,"{}")),new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(income,-1,n("100"),"实际加工100"),new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(tax,-1,n("13"),"本单真实VAT13")),w.superAdminUserId()));
  var quote=references.quote(context,posted.entryIds().getFirst(),1);var credit=references.adjustmentQuote(context,posted.entryIds().getFirst(),1,posted.entryIds().get(2),0,AdjustmentPurpose.VAT);
  var creditKey=new GlAllocationKey(posted.entryIds().get(2),0);var part=new FeePart(context,source,n("100"),n("100"),n("50"),base,"真实成交每PCS50",effect.movementId(),"EXCLUDED",true,List.of(new AdjustmentPart(creditKey,n("13"),n("13"),false)));
  var fee=new FeeAssignment(null,new GlAllocationKey(posted.entryIds().getFirst(),1),0,List.of(part),BigDecimal.ZERO,BigDecimal.ZERO,"原应收113完整分配加工100实际VAT13",quote.get("identityFingerprint").toString(),List.of(new AdjustmentSource(creditKey,credit.get("identityFingerprint").toString(),AdjustmentPurpose.VAT,BigDecimal.ZERO,BigDecimal.ZERO,"原贷方实际VAT逐额核对")));
  var blocked=statements.saveDraft(new Draft(UUID.randomUUID(),null,-1,context,contextVersion(context),null,EvidenceKind.FEE,json.valueToTree(fee)));UUID blockedId=UUID.fromString(blocked.get("evidenceId").toString());assertThatThrownBy(()->statements.submit(blockedId,action(blockedId,context))).isInstanceOf(ApiException.class).hasMessageContaining("免加工款");
  UUID zeroId=db.queryForObject("SELECT id FROM finance_material_evidence WHERE context_id=? AND kind='ZERO' AND current_approved",UUID.class,context);approveDraft(context,EvidenceKind.ZERO,new ZeroProcessing(context,source,fact.identityFingerprint(),effect.movementId(),effect.identityFingerprint(),false,"匿名取消免款后按真实GL认领"),zeroId);
  approveDraft(context,EvidenceKind.FEE,fee);var original=statements.snapshotFromAnchorCohort(context,day,day);var money=original.rows().stream().filter(row->"PHYSICAL".equals(row.get("__rowKind"))).findFirst().orElseThrow();assertThat(new BigDecimal(money.get("processAmount").toString())).isEqualByComparingTo("100");assertThat(new BigDecimal(original.documentMetadata().get("processingAdjustedTotal").toString())).isEqualByComparingTo("113");
  @SuppressWarnings("unchecked") var cells=(List<Map<String,Object>>)original.documentMetadata().get("supplementalCells");assertThat(cells).anySatisfy(cell->{assertThat(cell.get("sourceCell")).isEqualTo("Q5");assertThat(cell.get("value")).isEqualTo("113");});assertThat(cells).anySatisfy(cell->{assertThat(cell.get("sourceCell")).isEqualTo("O13");assertThat(cell.get("value")).isEqualTo("56.5");});
  UUID ordinaryCounter=style("ACCOUNT");new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->journals.post("MAT-CREDIT-"+UUID.randomUUID(),day,"MATERIAL_CREDIT_TEST",UUID.randomUUID(),"MATERIAL_ORDINARY_CREDIT","匿名普通AR贷方，不作加工负数",List.of(new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(ordinaryCounter,1,n("13"),"实际对方分录"),new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Entry(arStyle,-1,n("13"),"普通AR贷方13",new com.uten.imp.features.finance.gl.FinanceControlledJournalService.Allocation("1221",base,ref,"credit",1,"{}"))),w.superAdminUserId()));
  var credited=statements.snapshotFromAnchorCohort(context,day,day);assertThat(new BigDecimal(credited.documentMetadata().get("processingAdjustedTotal").toString())).isEqualByComparingTo("113");assertThat(credited.rows().stream().filter(row->"PHYSICAL".equals(row.get("__rowKind"))).findFirst().orElseThrow().get("processAmount").toString()).isEqualTo("100");original=credited;
  String oldFp=original.documentMetadata().get("sourceFingerprint").toString();LocalDate reverseDate=day.plusMonths(1).withDayOfMonth(1);new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->journals.reverse(posted.voucherId(),"MAT-REV-"+UUID.randomUUID(),reverseDate,"MATERIAL_TEST_REV",UUID.randomUUID(),"MATERIAL_BILL_REV","匿名按真实日期对称红冲",w.superAdminUserId()));
  assertThat(statements.snapshotFromAnchorCohort(context,day,day).documentMetadata().get("sourceFingerprint")).isEqualTo(oldFp);var reversed=statements.snapshotFromAnchorCohort(context,reverseDate,reverseDate);assertThat(new BigDecimal(reversed.documentMetadata().get("processingAdjustedTotal").toString())).isEqualByComparingTo("-113");assertThat(reversed.rows().stream().filter(row->"FEE_ADJUSTMENT".equals(row.get("__rowKind"))).findFirst().orElseThrow().get("processAmount").toString()).isEqualTo("-100");
 }
 byte[] originalWorkbook(com.uten.imp.features.finance.report.ReportTableResponse table)throws Exception{
  try(var book=new org.apache.poi.xssf.usermodel.XSSFWorkbook();var output=new java.io.ByteArrayOutputStream()){
   var sheet=book.createSheet("匿名财务原表");var header=sheet.createRow(2);for(int i=0;i<10;i++)header.createCell(i).setCellValue(table.columns().get(i).label());
   for(int at=0;at<table.rows().size();at++){var row=sheet.createRow(at+3);for(int col=0;col<10;col++){Object value=table.rows().get(at).get(table.columns().get(col).key());if(value==null)continue;var cell=row.createCell(col);if(value instanceof BigDecimal number){cell.setCellValue(0);cell.getCTCell().setV(number.toPlainString());}else cell.setCellValue(value.toString());}}
   for(int col=11;col<=16;col++){sheet.setColumnHidden(col,true);}book.write(output);return output.toByteArray();
  }
 }
 UUID style(String category){UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,?,0,'使用')",id,"MAT-S-"+id,"匿名真实科目-"+id,category);return id;}
 UUID materialContext(){return materialContext(Kind.PURCHASE_RECEIPT_LINE);}
 UUID materialContext(Kind... required){
  UUID base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);UUID style=UUID.randomUUID();arStyle=style;db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,'ACCOUNT',0,'使用')",style,"MAT-"+style,"匿名其他应收-"+style);
  db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by) VALUES('1221','匿名财务其他应收','',?,'ASSET','MANUAL','匿名明确资产往来',1,1,?) ON CONFLICT(code) DO UPDATE SET currency_id=excluded.currency_id",base,w.superAdminUserId());
  db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES('1221',?,?)",style,w.superAdminUserId());db.update("INSERT INTO finance_report_line_bindings(line_key,binding_kind,style_id,created_by) VALUES('BS_8','STYLE',?,?)",style,w.superAdminUserId());
  var aux=auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名材料账套",UUID.randomUUID().toString(),"匿名财务对象","CUSTOMER",w.clientId(),"真实UUID关系核对","1221"));
  UUID req=UUID.randomUUID();var input=new ContextInput(req,null,null,aux.id(),base,AmountBasis.LOCAL,null,w.goodsB(),null,day,"匿名财务原表资料","1221",1,Set.of(required),"原稿产品名称57#","原规格",w.unitId(),"PCS",null,null,1);
  var receipt=statements.saveContext(input);UUID context=UUID.fromString(receipt.get("contextId").toString()),evidence=UUID.fromString(receipt.get("evidenceId").toString());statements.submit(evidence,action(evidence,context));
  assertThat(statements.evidence(evidence).get("submission_reason")).isEqualTo("匿名双人核对原来源");assertThatThrownBy(()->db.update("UPDATE finance_material_evidence SET submission_reason='anonymous tamper' WHERE id=?",evidence)).hasMessageContaining("frozen");
  assertThatThrownBy(()->statements.decide(evidence,"approve",action(evidence,context))).isInstanceOf(ApiException.class).hasMessageContaining("另一位");
  full.loginAs(reviewer);statements.decide(evidence,"approve",action(evidence,context));full.loginAs(w.superAdminUserId());return context;
 }
 void approveDraft(UUID context,EvidenceKind kind,Object value){approveDraft(context,kind,value,null);}
 void approveDraft(UUID context,EvidenceKind kind,Object value,UUID previous){var saved=statements.saveDraft(new Draft(UUID.randomUUID(),null,-1,context,contextVersion(context),previous,kind,json.valueToTree(value)));UUID e=UUID.fromString(saved.get("evidenceId").toString());statements.submit(e,action(e,context));full.loginAs(reviewer);statements.decide(e,"approve",action(e,context));full.loginAs(w.superAdminUserId());}
 Action action(UUID e,UUID context){return new Action(UUID.randomUUID(),((Number)statements.evidence(e).get("version")).longValue(),contextVersion(context),"匿名双人核对原来源");}
 long contextVersion(UUID c){return ((Number)statements.get(c).get("row_version")).longValue();}
 static BigDecimal n(String s){return new BigDecimal(s);}
}
