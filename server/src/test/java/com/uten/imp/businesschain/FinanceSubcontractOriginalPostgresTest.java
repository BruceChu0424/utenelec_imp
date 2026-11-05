package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.statement.*;
import com.uten.imp.features.finance.report.FinanceReportColumnOptions;
import com.uten.imp.features.subcontract.material_issue.*;
import com.uten.imp.features.subcontract.material_return.*;
import com.uten.imp.features.subcontract.receipt.*;
import com.uten.imp.features.subcontract.ret.*;
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
import static com.uten.imp.features.finance.statement.FinanceSubcontractLossPolicyService.*;

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
class FinanceSubcontractOriginalPostgresTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FinanceScopedChainDatabase.register(registry,FinanceSubcontractOriginalPostgresTest.class);}
 @Autowired AutowireCapableBeanFactory beans; @Autowired JdbcTemplate db;
 @Autowired FinanceSubcontractLossPolicyService policies; @Autowired FinanceStatementService statements;
 @Autowired SubcontractMaterialIssueService issues; @Autowired SubcontractMaterialReturnService materialReturns;
 @Autowired SubcontractReceiptService receipts; @Autowired SubcontractReturnService returns;
 @AfterEach void logout(){SecurityContextHolder.clearContext();}
 private FullChainEndToEndTest fixture; private FullChainEndToEndTest.World w;
 private void world(String name){
  fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);w=fixture.seedWorld(name);fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
  // Explicit fixture master identity: the original template requires exactly PCS, not a name or PCS-prefix guess.
  var pcs=db.queryForList("SELECT id FROM units WHERE code='PCS' AND NOT is_deleted",UUID.class);
  UUID unit;if(pcs.isEmpty()){unit=UUID.randomUUID();db.update("INSERT INTO units(id,code,name,status)VALUES(?,'PCS','原表PCS实际单位','使用')",unit);}else unit=pcs.getFirst();
  // Existing BOM/quantity unit protection is retained. Create fresh fixture masters with PCS from their first write.
  UUID goodsD=masterGoods(name+"-D","采购",unit),goodsE=masterGoods(name+"-E","委外",unit),material=masterGoods(name+"-M","采购",unit);
  db.update("UPDATE goods SET default_supplier_id=? WHERE id IN(?,?)",w.supplierId(),goodsD,material);fixture.insertBom(goodsE,material,"1");
  w=new FullChainEndToEndTest.World(w.departmentId(),w.employeeId(),w.superAdminUserId(),w.goodsA(),w.goodsB(),w.goodsC(),goodsD,goodsE,w.clientId(),w.supplierId(),w.warehouseId(),unit,w.currencyId(),w.colorId(),w.unitLegacy());
 }
 private UUID masterGoods(String code,String type,UUID unit){UUID id=UUID.randomUUID();db.update("INSERT INTO goods(id,code,name,source_type,status,unit_id,price,code_sequence)VALUES(?,?,?,?,'使用',?,100,(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))",id,code,code,type,unit);return id;}
 private List<Object> originalBusinessState(UUID receipt,UUID returned){return List.of(
  db.queryForList("SELECT * FROM subcontract_receipts WHERE id=? ORDER BY id",receipt),db.queryForList("SELECT * FROM subcontract_receipt_items WHERE receipt_id=? ORDER BY id",receipt),
  db.queryForList("SELECT * FROM subcontract_returns WHERE id=? ORDER BY id",returned),db.queryForList("SELECT * FROM subcontract_return_items WHERE return_id=? ORDER BY id",returned),
  db.queryForList("SELECT * FROM ar_ap_ledger WHERE source_doc_id IN(?,?) ORDER BY id",receipt,returned),
  db.queryForList("SELECT * FROM gl_vouchers WHERE source_doc_id IN(?,?) ORDER BY id",receipt,returned),
  db.queryForList("SELECT entry.* FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id IN(?,?) ORDER BY entry.id",receipt,returned),
  db.queryForList("SELECT * FROM stock_movements WHERE source_doc_id IN(?,?) ORDER BY id",receipt,returned));}
 private static BigDecimal n(String value){return new BigDecimal(value);}
 private UUID reviewUser(){return fixture.createUserWithPerms(w,"loss-policy-review-"+w.supplierId(),"finance_report:view","finance:view:all","payment_style:edit","finance_post:execute");}
 private Save command(UUID request,long revision,UUID goods,LocalDate from,LocalDate to,String percent,boolean enabled){return new Save(request,revision,w.supplierId(),goods,null,w.unitId(),from,to,n(percent),enabled,"原表实际商品及有效期间损耗依据");}
 private void approve(UUID id,UUID reviewer){fixture.loginAs(reviewer);policies.decide(id,new Decision(true,"已独立核对真实来源与该商品适用期间"));fixture.loginAs(w.superAdminUserId());}
 private List<Map<String,Object>> report(LocalDate from,LocalDate to){return statements.subcontractStatement(null,from,to,null,w.supplierId(),w.currencyId(),1,100,FinanceReportColumnOptions.NONE).rows();}
 private static BigDecimal total(List<Map<String,Object>> rows,String key){return rows.stream().map(r->(BigDecimal)r.get(key)).filter(Objects::nonNull).reduce(BigDecimal.ZERO,BigDecimal::add);}
 @Test void policyRequiresSeparateReviewerExactVersionSourceDimensionAndImmutableRequest(){
  world("fin02-policy");UUID reviewer=reviewUser();LocalDate from=BusinessTime.today().minusMonths(1).withDayOfMonth(1);
  var save=command(UUID.randomUUID(),-1,w.goodsE(),from,null,"3",true);var submitted=policies.save(save);UUID id=(UUID)submitted.get("id");
  assertThat(policies.save(save).get("id")).isEqualTo(id);assertThat(policies.operation(save.requestId()).get("id")).isEqualTo(id);
  assertThatThrownBy(()->policies.save(command(save.requestId(),-1,w.goodsE(),from,null,"5",true))).isInstanceOf(ApiException.class).hasMessageContaining("原请求");
  assertThatThrownBy(()->policies.decide(id,new Decision(null,"不能把缺失结果当作退回"))).isInstanceOf(ApiException.class).hasMessageContaining("明确");
  assertThatThrownBy(()->policies.decide(id,new Decision(true,"不能由本人审核"))).isInstanceOf(ApiException.class).hasMessageContaining("不可相同");
  approve(id,reviewer);assertThat((BigDecimal)policies.get(id).get("ratePercent")).isEqualByComparingTo("3");
  assertThatThrownBy(()->policies.save(command(UUID.randomUUID(),-1,w.goodsE(),from,null,"5",true))).isInstanceOf(ApiException.class).hasMessageContaining("后续版本");
  var originalPrecise=command(UUID.randomUUID(),-1,w.goodsD(),from,null,"5.000000000000000000000001",true);
  assertThatThrownBy(()->policies.save(originalPrecise)).isInstanceOf(com.uten.imp.common.finance.BusinessPrecisionRequiredException.class);
  assertThat(db.queryForObject("SELECT count(*) FROM finance_subcontract_loss_policies WHERE request_id=?",Integer.class,originalPrecise.requestId())).isZero();
  try(var precision=com.uten.imp.common.finance.BusinessPrecisionContext.use(Map.of("finance.subcontract.loss-percent",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(24,"DOWN")))){
   var explicit=policies.save(originalPrecise);assertThat((BigDecimal)explicit.get("rate_percent_original")).isEqualByComparingTo("5.000000000000000000000001");assertThat((BigDecimal)explicit.get("ratePercent")).isEqualByComparingTo("5");assertThat(explicit.get("precision_policy").toString()).contains("DOWN");
  }catch(Exception failure){throw new IllegalStateException(failure);}
  var beyondRawField=command(UUID.randomUUID(),0,w.goodsD(),from,null,"5.0000000000000000000000001",true);
  assertThatThrownBy(()->policies.save(beyondRawField)).isInstanceOf(com.uten.imp.common.finance.BusinessPrecisionRequiredException.class);
  try(var explicit=com.uten.imp.common.finance.BusinessPrecisionContext.use(Map.of("finance.subcontract.loss-percent",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(24,"DOWN")))){var kept=policies.save(beyondRawField);assertThat((BigDecimal)kept.get("rate_percent_original")).isEqualByComparingTo("5.0000000000000000000000001");}catch(Exception failure){throw new IllegalStateException(failure);}
  var revised=policies.save(command(UUID.randomUUID(),0,w.goodsE(),from,null,"5.0000000000000000000001",true));
  approve((UUID)revised.get("id"),reviewer);assertThat((BigDecimal)policies.get((UUID)revised.get("id")).get("ratePercent")).isEqualByComparingTo("5.0000000000000000000001");
  assertThat((BigDecimal)policies.get(id).get("ratePercent")).isEqualByComparingTo("3");
  fixture.loginAs(reviewer);assertThatThrownBy(()->policies.operation(save.requestId())).isInstanceOf(ApiException.class).hasMessageContaining("本人");fixture.loginAs(w.superAdminUserId());
  var overlapping=policies.save(command(UUID.randomUUID(),-1,w.goodsE(),from.plusDays(1),null,"3",true));
  fixture.loginAs(reviewer);assertThatThrownBy(()->policies.decide((UUID)overlapping.get("id"),new Decision(true,"重叠有效区间应受保护"))).isInstanceOf(org.springframework.dao.DataAccessException.class);fixture.loginAs(w.superAdminUserId());
  var disabled=policies.save(command(UUID.randomUUID(),1,w.goodsE(),from,null,"5.0000000000000000000001",false));approve((UUID)disabled.get("id"),reviewer);
  assertThat(db.queryForObject("SELECT enabled FROM v_finance_subcontract_loss_policy_current WHERE id=?",Boolean.class,disabled.get("id"))).isFalse();
  assertThat(policies.sourceChoices(w.supplierId(),null,1,50).get("items")).isInstanceOf(List.class);
  assertThatThrownBy(()->db.update("UPDATE finance_subcontract_loss_policies SET rate=.1 WHERE id=?",id)).isInstanceOf(org.springframework.dao.DataAccessException.class);
  assertThatThrownBy(()->db.update("DELETE FROM finance_subcontract_loss_policies WHERE id=?",id)).isInstanceOf(org.springframework.dao.DataAccessException.class);
 }
 @Test void actualMaterialReturnAndItsLaterReversalPreserveTheOriginalNineteenColumns(){
  world("fin02-material-return");UUID material=fixture.ensureSubcontractDirectMaterial(w,w.goodsE());fixture.receiveSubcontractMaterial(w,material,"20");
  var order=fixture.submitLeafSubcontractForFinance(w,BigDecimal.TEN);fixture.loginAs(order.reviewerUserId());fixture.approvePendingFinance("SUBCONTRACT",order.orderId());fixture.loginAs(w.superAdminUserId());
  UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,order.orderId());
  LocalDate day=BusinessTime.today().minusMonths(1).withDayOfMonth(15),start=day.withDayOfMonth(1),end=day.withDayOfMonth(day.lengthOfMonth());
  UUID issue=fixture.submitSubcontractDraw(orderItem,BigDecimal.TEN,"fin02-material-"+orderItem).getFirst();
  var request=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();request.setBillDate(day);request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
  var line=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();line.setPlanItemId(issues.detail(issue).getItems().getFirst().getPlanItemId());line.setQty(BigDecimal.TEN);request.setItems(List.of(line));issues.update(issue,request);var issued=issues.approve(issue).getItems().getFirst();
  UUID reviewer=reviewUser();var policy=policies.save(command(UUID.randomUUID(),-1,material,start,null,"5",true));approve((UUID)policy.get("id"),reviewer);
  var ret=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest();ret.setBillDate(day.plusDays(1));ret.setSupplierId(w.supplierId());ret.setWarehouseId(w.warehouseId());
  var r=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine();r.setGoodsId(material);r.setUnitId(w.unitId());r.setUnitRate(BigDecimal.ONE);r.setQty(n("2"));r.setMaterialIssueItemId(issued.getId());r.setOrderItemId(orderItem);r.setParentGoodsId(w.goodsE());ret.setItems(List.of(r));UUID returned=materialReturns.create(ret).getId();materialReturns.approve(returned);
  var original=report(start,end);assertThat(original).hasSize(2);assertThat(total(original,"issueQty")).isEqualByComparingTo("8");assertThat(total(original,"lossAllowed")).isEqualByComparingTo("0.4");assertThat(total(original,"processAmount")).isZero();
  assertThat(original.getFirst().get("__lossPolicyId")).isEqualTo(policy.get("id").toString());
  materialReturns.reverse(returned);issues.reverse(issue);
  var after=report(start,end);assertThat(total(after,"issueQty")).isEqualByComparingTo("8");assertThat(total(after,"lossAllowed")).isEqualByComparingTo("0.4");
  var next=report(BusinessTime.today().withDayOfMonth(1),BusinessTime.today());assertThat(total(next,"issueQty")).isEqualByComparingTo("-8");assertThat(total(next,"lossAllowed")).isEqualByComparingTo("-0.4");assertThat(next).allSatisfy(row->assertThat(row.get("issueBillNo").toString()).contains("反审"));
  assertThat(statements.subcontractStatement(null,start,end,null,w.supplierId(),w.currencyId(),1,100,FinanceReportColumnOptions.NONE).columns()).hasSize(19);
 }
 @org.junit.jupiter.params.ParameterizedTest @org.junit.jupiter.params.provider.ValueSource(booleans={false,true})
 void actualStoredReceiptProductReturnAndReversalsKeepTheirOwnPeriodAndOriginalAmounts(boolean previousPeriod){
  world("fin02-product-return-"+previousPeriod);UUID material=fixture.ensureSubcontractDirectMaterial(w,w.goodsE());fixture.receiveSubcontractMaterial(w,material,"20");
  var order=fixture.submitLeafSubcontractForFinance(w,BigDecimal.TEN);fixture.loginAs(order.reviewerUserId());fixture.approvePendingFinance("SUBCONTRACT",order.orderId());fixture.loginAs(w.superAdminUserId());
  UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,order.orderId());fixture.drawAndIssueSubcontract(orderItem,BigDecimal.TEN,"fin02-product-draw-"+orderItem);
  LocalDate day=previousPeriod?BusinessTime.today().minusMonths(1).withDayOfMonth(15):BusinessTime.today().withDayOfMonth(1),start=day.withDayOfMonth(1),end=day.withDayOfMonth(day.lengthOfMonth());
  UUID terms=db.queryForObject("SELECT settlement_method_id FROM subcontract_orders WHERE id=?",UUID.class,order.orderId());
  var received=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();received.setBillDate(day);received.setSupplierId(w.supplierId());received.setWarehouseId(w.warehouseId());received.setCurrencyId(w.currencyId());received.setExchangeRate(BigDecimal.ONE);received.setTaxRate(BigDecimal.ZERO);received.setSettlementMethodId(terms);
  var receiptLine=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();receiptLine.setOrderItemId(orderItem);receiptLine.setGoodsId(w.goodsE());receiptLine.setUnitId(w.unitId());receiptLine.setUnitRate(BigDecimal.ONE);receiptLine.setQty(n("2"));receiptLine.setPrice(n("50"));received.setItems(List.of(receiptLine));UUID receipt=receipts.create(received).getId();receipts.approve(receipt);
  var inspections=beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.class);var stocks=beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService.class);
  UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receipt);inspections.dispose("SUBCONTRACT",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"原回厂真实合格入库","fin02-pass-"+receipt));
  UUID event=db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",UUID.class,inspection);fixture.loginAs(fixture.createIqcWarehouseConfirmer(w,"fin02-stock-"+receipt));stocks.confirm("SUBCONTRACT",receipt,new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest("fin02-stock-"+receipt,List.of(new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem(event,n("2"),n("2"),"FIN02-REAL",w.warehouseId()))));fixture.loginAs(w.superAdminUserId());org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"drainCosts",w);
  var returned=new com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest();returned.setBillDate(day.plusDays(1));returned.setSupplierId(w.supplierId());returned.setWarehouseId(w.warehouseId());returned.setCurrencyId(w.currencyId());returned.setExchangeRate(BigDecimal.ONE);returned.setTaxRate(BigDecimal.ZERO);returned.setSettlementMethodId(terms);
  var returnLine=new com.uten.imp.features.subcontract.ret.dto.ReturnItemLine();returnLine.setReceiptItemId(receipts.detail(receipt).getItems().getFirst().getId());returnLine.setOrderItemId(orderItem);returnLine.setGoodsId(w.goodsE());returnLine.setUnitId(w.unitId());returnLine.setUnitRate(BigDecimal.ONE);returnLine.setQty(n("0.5"));returnLine.setPrice(n("50"));returned.setItems(List.of(returnLine));UUID ret=returns.create(returned).getId();returns.approve(ret);
  assertThat(db.queryForObject("SELECT amount_original FROM subcontract_receipt_items WHERE receipt_id=?",BigDecimal.class,receipt)).isEqualByComparingTo("100");assertThat(db.queryForObject("SELECT amount_original FROM subcontract_return_items WHERE return_id=?",BigDecimal.class,ret)).isEqualByComparingTo("25");
  var original=report(start,end);assertThat(total(original,"processAmount")).isEqualByComparingTo("75");assertThat(original).allSatisfy(row->{assertThat(row.get("__pending")).isEqualTo(true);assertThat(row.get("prevStock")).isNull();assertThat(row.get("balance")).isNull();assertThat(row.get("__basis").toString()).contains("冻结BOM估计");});assertThat(total(original,"__billingQty")).isEqualByComparingTo("1.5");assertThat(original).anySatisfy(row->assertThat(row.get("receiptBillNo").toString()).contains("成品退货"));
  if(previousPeriod){
   var businessBefore=originalBusinessState(receipt,ret);
   assertThatThrownBy(()->returns.reverse(ret)).isInstanceOf(ApiException.class).hasMessageContaining("跨会计期间");
   assertThat(total(report(start,end),"processAmount")).isEqualByComparingTo("75");assertThat(originalBusinessState(receipt,ret)).isEqualTo(businessBefore);return;
  }
  returns.reverse(ret);receipts.reverse(receipt);
  var after=report(start,end);assertThat(total(after,"processAmount")).isZero();assertThat(total(after,"receiptQty")).isZero();
  assertThat(after.stream().filter(row->row.get("receiptBillNo")!=null).toList()).hasSize(4).anySatisfy(row->assertThat(row.get("receiptBillNo").toString()).contains("反审"));
  assertThat(total(report(start.plusMonths(1),end.plusMonths(1)),"prevStock")).isEqualByComparingTo("10");
 }

 @Test void actualLossAndSupplierMaterialReplacementUseDatedFactsInsteadOfCurrentIssueCounters(){
  world("fin02-loss-compensation");UUID material=fixture.ensureSubcontractDirectMaterial(w,w.goodsE());fixture.receiveSubcontractMaterial(w,material,"20");
  var order=fixture.submitLeafSubcontractForFinance(w,BigDecimal.TEN);fixture.loginAs(order.reviewerUserId());fixture.approvePendingFinance("SUBCONTRACT",order.orderId());fixture.loginAs(w.superAdminUserId());
  UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,order.orderId());LocalDate day=BusinessTime.today().minusMonths(1).withDayOfMonth(15);
  UUID issue=fixture.submitSubcontractDraw(orderItem,BigDecimal.TEN,"fin02-comp-draw-"+orderItem).getFirst();var outgoing=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();outgoing.setBillDate(day);outgoing.setSupplierId(w.supplierId());outgoing.setWarehouseId(w.warehouseId());var outboundLine=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();outboundLine.setPlanItemId(issues.detail(issue).getItems().getFirst().getPlanItemId());outboundLine.setQty(BigDecimal.TEN);outgoing.setItems(List.of(outboundLine));issues.update(issue,outgoing);UUID issueItem=issues.approve(issue).getItems().getFirst().getId();
  LocalDate current=BusinessTime.today().withDayOfMonth(1),next=current.plusMonths(1);assertThat(total(report(current,BusinessTime.today()),"prevStock")).isEqualByComparingTo("10");
  var wastes=beans.getBean(com.uten.imp.features.subcontract.waste.SubcontractWasteService.class);var claims=beans.getBean(com.uten.imp.features.finance.payables.SubcontractLossClaimService.class);
  var loss=new com.uten.imp.features.subcontract.waste.dto.WasteSaveRequest();loss.setBillDate(BusinessTime.today());loss.setSupplierId(w.supplierId());loss.setWarehouseId(w.warehouseId());var line=new com.uten.imp.features.subcontract.waste.dto.WasteItemLine();line.setGoodsId(material);line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setMaterialIssueItemId(issueItem);line.setQty(n("3"));line.setStandardQty(n("2"));line.setCause("真实已核损耗而非允许损耗估计");loss.setItems(List.of(line));UUID waste=wastes.create(loss).getId();wastes.approve(waste);
  assertThat(total(report(current,BusinessTime.today()),"prevStock")).isEqualByComparingTo("10");assertThat(total(report(next,next.withDayOfMonth(next.lengthOfMonth())),"prevStock")).isEqualByComparingTo("7");
  UUID caseId=db.queryForObject("SELECT id FROM subcontract_loss_cases WHERE waste_id=?",UUID.class,waste);var detail=claims.detail(caseId);
  claims.decide(caseId,new com.uten.imp.features.finance.payables.SubcontractLossClaimContracts.DecisionRequest(detail.summary().version(),false,"由供应商真实补回一件原料",List.of(new com.uten.imp.features.finance.payables.SubcontractLossClaimContracts.ResolutionInput(detail.lines().getFirst().id(),"MATERIAL_REPLACEMENT",BigDecimal.ONE,BigDecimal.ZERO,BusinessTime.today(),"原料不构造加工款或现金",List.of()))));
  detail=claims.detail(caseId);UUID resolution=detail.resolutions().getFirst().id();claims.fulfill(caseId,resolution,new com.uten.imp.features.finance.payables.SubcontractLossClaimContracts.FulfillmentRequest(detail.summary().version(),BigDecimal.ONE,BigDecimal.ZERO,"真实供应商现场补料确认","SUPPLIER_MATERIAL_REPLACEMENT",null,null,null,null,null,"按原发料行登记"));
  assertThat(total(report(next,next.withDayOfMonth(next.lengthOfMonth())),"prevStock")).isEqualByComparingTo("8");assertThat(total(report(current,BusinessTime.today()),"prevStock")).isEqualByComparingTo("10");assertThat(total(report(current,BusinessTime.today()),"processAmount")).isZero();
  detail=claims.detail(caseId);claims.reverseFulfillment(caseId,resolution,new com.uten.imp.features.finance.payables.SubcontractLossClaimContracts.ReverseFulfillmentRequest(detail.summary().version(),"按原履约分配撤回补料"));
  assertThat(total(report(next,next.withDayOfMonth(next.lengthOfMonth())),"prevStock")).isEqualByComparingTo("7");detail=claims.detail(caseId);claims.reverse(caseId,new com.uten.imp.features.finance.payables.SubcontractLossClaimContracts.ReverseRequest(detail.summary().version(),"先撤处理方案后反审损耗"));wastes.reverse(waste);
  assertThat(total(report(next,next.withDayOfMonth(next.lengthOfMonth())),"prevStock")).isEqualByComparingTo("10");assertThat(total(report(current,BusinessTime.today()),"prevStock")).isEqualByComparingTo("10");
 }

}
