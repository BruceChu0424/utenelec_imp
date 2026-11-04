package com.uten.imp.businesschain;

import com.uten.imp.application.port.FinanceSubcontractQuantityEvidenceReadPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.statement.FinanceSubcontractQuantityEvidenceService;
import com.uten.imp.features.finance.statement.FinanceSubcontractQuantityEvidenceContracts;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.nio.file.*;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.application.port.FinanceSubcontractQuantityEvidenceReadPort.*;
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
class FinanceSubcontractQuantityEvidencePostgresTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
 @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;
 @Autowired FinanceSubcontractQuantityEvidenceService evidence;
 @Autowired com.uten.imp.features.finance.statement.FinanceStatementService statements;
 private FullChainEndToEndTest fixture;private FullChainEndToEndTest.World w;
 private static final byte[] FILE=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVb8AAAAASUVORK5CYII=");
 @BeforeEach void prepare()throws Exception{
  if(!Boolean.TRUE.equals(db.queryForObject("SELECT to_regclass('public.finance_subcontract_quantity_evidence') IS NOT NULL",Boolean.class)))db.execute(Files.readString(Path.of("../tmp/finance-research/V1027__subcontract_statement_quantity_evidence.sql.draft")));
  var shared=new FinanceSubcontractOriginalPostgresTest();beans.autowireBean(shared);ReflectionTestUtils.invokeMethod(shared,"world","fin02-evidence-"+UUID.randomUUID());fixture=(FullChainEndToEndTest)ReflectionTestUtils.getField(shared,"fixture");w=(FullChainEndToEndTest.World)ReflectionTestUtils.getField(shared,"w");
 }
 @AfterEach void logout(){SecurityContextHolder.clearContext();}
 private Scope scope(){return new Scope(w.supplierId(),BusinessTime.today().withDayOfMonth(1),BusinessTime.today());}
 private UUID reviewer(){return fixture.createUserWithPerms(w,"quantity-review-"+w.supplierId(),"finance_report:view","finance:view:all","payment_style:edit","finance_post:execute");}
 private Map<String,Object> save(FinanceSubcontractQuantityEvidenceContracts.Save input){return evidence.save(input,"anonymous-actual-count.png","image/png",FILE);}
 private void approve(UUID id,UUID reviewer){fixture.loginAs(reviewer);evidence.decide(id,new FinanceSubcontractQuantityEvidenceContracts.Decision(true,"独立核对原行UUID、实际凭据和本期采用用途"));fixture.loginAs(w.superAdminUserId());}
 @Test void openingAndTailCountsAreExactReviewedVersionsAndDoNotWriteBusinessLedgers(){
  UUID material=fixture.ensureSubcontractDirectMaterial(w,w.goodsE()),reviewer=reviewer();
  var input=new Input(scope(),Purpose.PERIOD_OPENING,EvidenceType.PHYSICAL_COUNT,null,null,new StockGroup(material,null,w.unitId()),new BigDecimal("12.000000000000000000000001"),scope().dateFrom().minusDays(1),true,true,"原期间开始前实际盘点单，原值完整保留");
  var command=new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,input);int movements=count("stock_movements"),ledger=count("ar_ap_ledger"),gl=count("gl_entries");
  var saved=save(command);UUID id=(UUID)saved.get("id");assertThat(save(command).get("id")).isEqualTo(id);assertThat(evidence.operation(command.requestId()).get("id")).isEqualTo(id);assertThat(evidence.approved(scope()).evidence()).isEmpty();
  assertThatThrownBy(()->evidence.decide(id,new FinanceSubcontractQuantityEvidenceContracts.Decision(true,"禁止自己审核"))).isInstanceOf(ApiException.class).hasMessageContaining("不可相同");approve(id,reviewer);
  var approved=evidence.approved(scope()).evidence();assertThat(approved).singleElement().satisfies(row->{assertThat(row.input().quantityPcs()).isEqualByComparingTo("12.000000000000000000000001");assertThat(row.bookEstimatedPcs()).isNull();assertThat(row.input().applyToStatement()).isTrue();});
  fixture.loginAs(reviewer);assertThat(evidence.attachment(id)).containsExactly(FILE);assertThatThrownBy(()->evidence.operation(command.requestId())).isInstanceOf(ApiException.class).hasMessageContaining("本人");fixture.loginAs(w.superAdminUserId());
  assertThatThrownBy(()->db.update("UPDATE finance_subcontract_quantity_evidence SET quantity_pcs=13 WHERE id=?",id)).isInstanceOf(org.springframework.dao.DataAccessException.class);
  var stopped=new Input(scope(),Purpose.PERIOD_OPENING,EvidenceType.PHYSICAL_COUNT,null,null,input.stockGroup(),input.quantityPcs(),input.evidenceDate(),false,true,"保留旧盘点原值并受审停用");
  var next=evidence.save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),0,stopped,id),null,null,null);approve((UUID)next.get("id"),reviewer);assertThat(evidence.approved(scope()).evidence()).isEmpty();assertThat(evidence.attachment(id)).containsExactly(FILE);
  assertThat(count("stock_movements")).isEqualTo(movements);assertThat(count("ar_ap_ledger")).isEqualTo(ledger);assertThat(count("gl_entries")).isEqualTo(gl);
 }
 @Test void excessivePcsPrecisionRequiresAChoiceAndRetainsTheOriginalInput()throws Exception{
  UUID material=fixture.ensureSubcontractDirectMaterial(w,w.goodsE());var original=new BigDecimal("12.0000000000000000000000001");
  var input=new Input(scope(),Purpose.PERIOD_OPENING,EvidenceType.PHYSICAL_COUNT,null,null,new StockGroup(material,null,w.unitId()),original,scope().dateFrom(),true,true,"原PCS量超本字段24位，必须明确选择且保原数");
  var command=new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,input);
  assertThatThrownBy(()->save(command)).isInstanceOf(com.uten.imp.common.finance.BusinessPrecisionRequiredException.class);assertThat(db.queryForObject("SELECT count(*) FROM finance_subcontract_quantity_evidence WHERE request_id=?",Integer.class,command.requestId())).isZero();
  try(var policy=com.uten.imp.common.finance.BusinessPrecisionContext.use(Map.of("finance.subcontract.statement-pcs",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(24,"DOWN")))){
   var saved=save(command);assertThat(((Input)saved.get("input")).quantityPcs()).isEqualByComparingTo(original);assertThat((BigDecimal)saved.get("appliedQuantityPcs")).isEqualByComparingTo("12");assertThat(saved.get("precisionPolicy").toString()).contains("DOWN");
  }
 }
 @Test void bilateralEquivalentAndActualUsageStaySeparateAndOnlyExplicitlyChosenQuantityApplies(){
  UUID material=fixture.ensureSubcontractDirectMaterial(w,w.goodsE());fixture.insertBom(w.goodsE(),w.goodsD(),"2");fixture.receiveSubcontractMaterial(w,material,"20");fixture.receiveSubcontractMaterial(w,w.goodsD(),"40");var submitted=fixture.submitLeafSubcontractForFinance(w,new BigDecimal("10"));fixture.loginAs(submitted.reviewerUserId());fixture.approvePendingFinance("SUBCONTRACT",submitted.orderId());fixture.loginAs(w.superAdminUserId());
  UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,submitted.orderId());fixture.drawAndIssueSubcontract(orderItem,new BigDecimal("10"),"actual-evidence-"+orderItem);UUID issueItem=db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=? AND NOT is_deleted",UUID.class,orderItem,material);UUID secondIssueItem=db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=? AND NOT is_deleted",UUID.class,orderItem,w.goodsD());
  var receipts=beans.getBean(com.uten.imp.features.subcontract.receipt.SubcontractReceiptService.class);var received=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();received.setBillDate(BusinessTime.today());received.setSupplierId(w.supplierId());received.setWarehouseId(w.warehouseId());received.setCurrencyId(w.currencyId());received.setExchangeRate(BigDecimal.ONE);received.setTaxRate(BigDecimal.ZERO);received.setSettlementMethodId(db.queryForObject("SELECT settlement_method_id FROM subcontract_orders WHERE id=?",UUID.class,submitted.orderId()));
  var line=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();line.setOrderItemId(orderItem);line.setGoodsId(w.goodsE());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("3"));line.setPrice(new BigDecimal("50"));received.setItems(List.of(line));UUID receipt=receipts.create(received).getId();UUID receiptItem=receipts.approve(receipt).getItems().getFirst().getId();
  var before=business(issueItem,receiptItem);UUID reviewer=reviewer();var group=new StockGroup(material,null,w.unitId());var source=new SourceRef(SourceKind.RECEIPT,receiptItem);
  var agreed=new Input(scope(),Purpose.ROW_CORRESPONDENCE,EvidenceType.BILATERAL_SETTLEMENT_EQUIVALENCE,source,issueItem,group,new BigDecimal("4"),BusinessTime.today(),true,true,"双方确认本期结算当量4PCS，与冻结估计3分别保留");
  var saved=save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,agreed));UUID first=(UUID)saved.get("id");approve(first,reviewer);
  var actual=new Input(scope(),Purpose.ROW_CORRESPONDENCE,EvidenceType.RECEIPT_USAGE_DOCUMENT,source,issueItem,group,new BigDecimal("3"),BusinessTime.today(),true,false,"实际回厂耗用凭据3PCS，仅作差异核对，未选择代替结算当量");
  var compared=evidence.save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,actual,first),null,null,null);approve((UUID)compared.get("id"),reviewer);
  var snapshot=evidence.approved(scope());assertThat(snapshot.evidence()).hasSize(2);assertThat(snapshot.evidence().stream().filter(e->e.input().applyToStatement()).toList()).singleElement().satisfies(e->{assertThat(e.input().quantityPcs()).isEqualByComparingTo("4");assertThat(e.bookEstimatedPcs()).isEqualByComparingTo("3");assertThat(e.source().quantityOriginal()).isEqualByComparingTo("3");assertThat(e.source().priceOriginal()).isEqualByComparingTo("50");assertThat(e.source().amountOriginal()).isEqualByComparingTo("150");});
  assertThat(snapshot.evidence()).anySatisfy(e->{assertThat(e.input().evidenceType()).isEqualTo(EvidenceType.RECEIPT_USAGE_DOCUMENT);assertThat(e.input().applyToStatement()).isFalse();});
  var conflict=new Input(scope(),Purpose.ROW_CORRESPONDENCE,EvidenceType.RECEIPT_USAGE_DOCUMENT,source,issueItem,group,new BigDecimal("3"),BusinessTime.today(),true,true,"未撤双方结算采用时不得自动改用实际耗用");
  var rejected=evidence.save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),0,conflict,first),null,null,null);fixture.loginAs(reviewer);assertThatThrownBy(()->evidence.decide((UUID)rejected.get("id"),new FinanceSubcontractQuantityEvidenceContracts.Decision(true,"不得同时采用两个不同用途来源"))).isInstanceOf(org.springframework.dao.DataAccessException.class);fixture.loginAs(w.superAdminUserId());
  var incomplete=statements.subcontractStatement(null,scope().dateFrom(),scope().dateTo(),null,w.supplierId(),w.currencyId(),1,100,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);assertThat(incomplete.rows().stream().filter(r->"STOCK".equals(r.get("__quantityRole")))).allSatisfy(r->{assertThat(r.get("balance")).isNull();assertThat(r.get("__pending")).isEqualTo(true);});
  var secondGroup=new StockGroup(w.goodsD(),null,w.unitId());
  var secondQuantity=new Input(scope(),Purpose.ROW_CORRESPONDENCE,EvidenceType.BILATERAL_SETTLEMENT_EQUIVALENCE,source,secondIssueItem,secondGroup,new BigDecimal("7"),BusinessTime.today(),true,true,"第二真实材料7PCS与第一材料4PCS分别受审；加工原额150只保留一次");
  approve((UUID)evidence.save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,secondQuantity,first),null,null,null).get("id"),reviewer);
  for(var stock:List.of(group,secondGroup)){
   var opening=new Input(scope(),Purpose.PERIOD_OPENING,EvidenceType.PHYSICAL_COUNT,null,null,stock,BigDecimal.ZERO,scope().dateFrom(),true,true,"本期开始前实盘0PCS，不将未知期初默认为0");approve((UUID)save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,opening)).get("id"),reviewer);
  }
  var tail=new Input(scope(),Purpose.PERIOD_ENDING,EvidenceType.PHYSICAL_COUNT,null,null,group,new BigDecimal("5"),scope().dateTo(),true,true,"尾料实际5PCS与原表公式5.7PCS分别核对，不默判账实一致");approve((UUID)save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,tail)).get("id"),reviewer);
  var projected=statements.subcontractStatement(null,scope().dateFrom(),scope().dateTo(),null,w.supplierId(),w.currencyId(),1,100,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
  assertThat(projected.rows()).hasSize(3);
  var firstStock=projected.rows().stream().filter(r->material.toString().equals(Objects.toString(r.get("__goodsId")))).findFirst().orElseThrow();
  assertThat((BigDecimal)firstStock.get("prevStock")).isEqualByComparingTo("0");assertThat((BigDecimal)firstStock.get("issueTotalQty")).isEqualByComparingTo("10");assertThat((BigDecimal)firstStock.get("receiptTotalQty")).isEqualByComparingTo("4");assertThat((BigDecimal)firstStock.get("lossAllowed")).isEqualByComparingTo("0.3");assertThat((BigDecimal)firstStock.get("balance")).isEqualByComparingTo("5.7");assertThat((BigDecimal)firstStock.get("__confirmedEndingQty")).isEqualByComparingTo("5");assertThat((BigDecimal)firstStock.get("__tailDifferenceQty")).isEqualByComparingTo("0.7");assertThat(firstStock.get("processAmount")).isNull();
  var secondStock=projected.rows().stream().filter(r->w.goodsD().toString().equals(Objects.toString(r.get("__goodsId")))).findFirst().orElseThrow();assertThat((BigDecimal)secondStock.get("receiptTotalQty")).isEqualByComparingTo("7");assertThat((BigDecimal)secondStock.get("balance")).isEqualByComparingTo("12.4");assertThat(secondStock.get("processAmount")).isNull();
  var fees=projected.rows().stream().filter(r->"FEE".equals(r.get("__quantityRole"))).toList();assertThat(fees).singleElement().satisfies(r->{assertThat((BigDecimal)r.get("__billingQty")).isEqualByComparingTo("3");assertThat((BigDecimal)r.get("processPrice")).isEqualByComparingTo("50");assertThat((BigDecimal)r.get("processAmount")).isEqualByComparingTo("150");assertThat(r.get("balance")).isNull();assertThat(r.get("__notApplicable").toString()).contains("prevStock","balance");});
  assertThat(sum(projected.rows(),"processAmount")).isEqualByComparingTo("150");assertThat(sum(projected.rows(),"__billingQty")).isEqualByComparingTo("3");assertThat(fees.getFirst().get("__basis").toString()).contains("原计价数量=","PCS");assertThat(projected.documentMetadata()).containsKeys("subcontractQuantityEvidence","subcontractQuantityFingerprint");
  var filtered=statements.subcontractStatement(null,scope().dateFrom(),scope().dateTo(),null,w.supplierId(),w.currencyId(),1,10,new com.uten.imp.features.finance.report.FinanceReportColumnOptions(Map.of("search.processAmount","150"),null,null));assertThat(filtered.rows()).hasSize(1);assertThat(filtered.rows().getFirst().get("__quantityRole")).isEqualTo("FEE");
  assertThat(business(issueItem,receiptItem)).isEqualTo(before);
 }
 @Test void originalSourceQuantityEvidenceMirrorsRealLaterReversalsWithoutCreatingAnotherPeriodIdentity(){
  UUID material=fixture.ensureSubcontractDirectMaterial(w,w.goodsE());fixture.receiveSubcontractMaterial(w,material,"20");var order=fixture.submitLeafSubcontractForFinance(w,BigDecimal.TEN);fixture.loginAs(order.reviewerUserId());fixture.approvePendingFinance("SUBCONTRACT",order.orderId());fixture.loginAs(w.superAdminUserId());
  UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,order.orderId());LocalDate day=BusinessTime.today().minusMonths(1).withDayOfMonth(15);var old=new Scope(w.supplierId(),day.withDayOfMonth(1),day.withDayOfMonth(day.lengthOfMonth()));
  var issues=beans.getBean(com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService.class);var returns=beans.getBean(com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService.class);
  UUID issue=fixture.submitSubcontractDraw(orderItem,BigDecimal.TEN,"evidence-mirror-"+orderItem).getFirst();var outgoing=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();outgoing.setBillDate(day);outgoing.setSupplierId(w.supplierId());outgoing.setWarehouseId(w.warehouseId());var line=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();line.setPlanItemId(issues.detail(issue).getItems().getFirst().getPlanItemId());line.setQty(BigDecimal.TEN);outgoing.setItems(List.of(line));issues.update(issue,outgoing);UUID issueItem=issues.approve(issue).getItems().getFirst().getId();
  var returned=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest();returned.setBillDate(day.plusDays(1));returned.setSupplierId(w.supplierId());returned.setWarehouseId(w.warehouseId());var returnLine=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine();returnLine.setGoodsId(material);returnLine.setUnitId(w.unitId());returnLine.setUnitRate(BigDecimal.ONE);returnLine.setQty(new BigDecimal("2"));returnLine.setMaterialIssueItemId(issueItem);returnLine.setOrderItemId(orderItem);returnLine.setParentGoodsId(w.goodsE());returned.setItems(List.of(returnLine));UUID returnId=returns.create(returned).getId();UUID returnItem=returns.approve(returnId).getItems().getFirst().getId();
  UUID reviewer=reviewer();var group=new StockGroup(material,null,w.unitId());var original=new Input(old,Purpose.ROW_CORRESPONDENCE,EvidenceType.BILATERAL_SETTLEMENT_EQUIVALENCE,new SourceRef(SourceKind.MATERIAL_ISSUE,issueItem),issueItem,group,new BigDecimal("12"),day,true,true,"原发料10PCS与双方结算当量12PCS分别保留，后期反向镜像同原行版本");UUID proof=(UUID)save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,original)).get("id");approve(proof,reviewer);
  var returnProof=new Input(old,Purpose.ROW_CORRESPONDENCE,EvidenceType.BILATERAL_SETTLEMENT_EQUIVALENCE,new SourceRef(SourceKind.MATERIAL_RETURN,returnItem),issueItem,group,new BigDecimal("3"),day.plusDays(1),true,true,"原退料2PCS与双方结算当量3PCS分别保留且FK仍为真实原发料");approve((UUID)save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,returnProof)).get("id"),reviewer);
  var opening=new Input(old,Purpose.PERIOD_OPENING,EvidenceType.PHYSICAL_COUNT,null,null,group,BigDecimal.ZERO,old.dateFrom(),true,true,"原期开始前真实0PCS盘点凭据");approve((UUID)save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,opening)).get("id"),reviewer);
  var before=statements.subcontractStatement(null,old.dateFrom(),old.dateTo(),null,w.supplierId(),w.currencyId(),1,100,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);assertThat(sum(before.rows(),"issueQty")).isEqualByComparingTo("9");
  var changedRange=new Scope(w.supplierId(),old.dateFrom().minusDays(1),old.dateTo());assertThat(evidence.relevant(changedRange).evidence()).filteredOn(r->r.input().purpose()==Purpose.ROW_CORRESPONDENCE).hasSize(2);assertThatThrownBy(()->save(new FinanceSubcontractQuantityEvidenceContracts.Save(UUID.randomUUID(),-1,new Input(changedRange,original.purpose(),original.evidenceType(),original.source(),original.materialIssueItemId(),original.stockGroup(),original.quantityPcs(),original.evidenceDate(),true,true,original.sourceReference())))).isInstanceOf(ApiException.class).hasMessageContaining("版本");
  returns.reverse(returnId);issues.reverse(issue);
  var historical=statements.subcontractStatement(null,old.dateFrom(),old.dateTo(),null,w.supplierId(),w.currencyId(),1,100,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);assertThat(sum(historical.rows(),"issueQty")).isEqualByComparingTo("9");assertThat(sum(historical.rows(),"lossAllowed")).isEqualByComparingTo("0.27");
  var current=statements.subcontractStatement(null,scope().dateFrom(),scope().dateTo(),null,w.supplierId(),w.currencyId(),1,100,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);assertThat(sum(current.rows(),"issueQty")).isEqualByComparingTo("-9");assertThat(sum(current.rows(),"lossAllowed")).isEqualByComparingTo("-0.27");assertThat(evidence.relevant(scope()).evidence()).filteredOn(r->r.input().purpose()==Purpose.ROW_CORRESPONDENCE).hasSize(2);assertThat(evidence.relevant(scope()).evidence()).noneMatch(r->r.input().purpose()==Purpose.PERIOD_OPENING);assertThat((SourceSnapshot)evidence.get(proof).get("source")).satisfies(s->assertThat(s.quantityOriginal()).isEqualByComparingTo("10"));
  assertThat((List<?>)evidence.list(scope(),1,50).get("items")).hasSize(2);assertThat(evidence.list(scope(),1,50).get("total")).isEqualTo(2L);
 }
 private BigDecimal sum(List<Map<String,Object>> rows,String key){return rows.stream().map(r->(BigDecimal)r.get(key)).filter(Objects::nonNull).reduce(BigDecimal.ZERO,BigDecimal::add);}
 private int count(String table){return Objects.requireNonNull(db.queryForObject("SELECT count(*) FROM "+table,Integer.class));}
 private List<Object> business(UUID issue,UUID receipt){return List.of(db.queryForMap("SELECT * FROM subcontract_material_issue_items WHERE id=?",issue),db.queryForMap("SELECT * FROM subcontract_receipt_items WHERE id=?",receipt),db.queryForList("SELECT * FROM stock_movements ORDER BY id"),db.queryForList("SELECT * FROM ar_ap_ledger ORDER BY id"),db.queryForList("SELECT * FROM gl_entries ORDER BY id"));}
}
