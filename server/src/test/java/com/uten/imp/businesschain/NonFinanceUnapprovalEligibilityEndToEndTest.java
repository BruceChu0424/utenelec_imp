package com.uten.imp.businesschain;

import com.uten.imp.application.port.DocumentUnapprovalPort.Eligibility;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.*;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.subcontract.inquiry.SubcontractInquiryService;
import com.uten.imp.features.subcontract.inquiry.dto.*;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService;
import com.uten.imp.features.subcontract.waste.SubcontractWasteService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.*;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import static org.assertj.core.api.Assertions.*;

/** Real source/permission/cost refusals are observable read-only decisions, never reversal simulations. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
 "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
 "uten.inventory.value-work.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
 "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class NonFinanceUnapprovalEligibilityEndToEndTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
 @Autowired AutowireCapableBeanFactory beans;
 @Autowired JdbcTemplate db;
 @Autowired PlatformTransactionManager transactions;
 @Autowired ProductionPlanService plans;
 @Autowired ProductionDailyReportService reports;
 @Autowired SalesOrderService sales;
 @Autowired SalesShipmentService shipments;
 @Autowired PurchaseOrderService purchases;
 @Autowired PurchaseReceiptService receipts;
 @Autowired SubcontractOrderService subcontract;
 @Autowired SubcontractInquiryService inquiries;
 @Autowired SubcontractMaterialIssueService issues;
 @Autowired SubcontractMaterialReturnService returns;
 @Autowired SubcontractWasteService wastes;
 @Autowired StockDocService stock;
 @Autowired com.uten.imp.features.sales.ret.SalesReturnService customerReturns;
 @Autowired com.uten.imp.features.sales.ret.SalesReturnQualityService customerReturnQuality;
 @Autowired com.uten.imp.features.sales.other_shipment.SalesOtherShipmentService historicalShipments;
 @Autowired com.uten.imp.features.documents.DocumentUnapprovalService unapproval;
 FullChainEndToEndTest harness;
 @BeforeEach void setup(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
 @AfterEach void clear(){SecurityContextHolder.clearContext();}

 @Test void manualPlanAndInquiryOnlyBecomeReadyWhenApprovedAndPureReadsDoNotChangeAnyLedger(){
   var w=world("plan-inquiry");var request=new PlanSaveRequest();request.setBillDate(BusinessTime.today());
   var item=new PlanItemLine();item.setGoodsId(w.goodsC());item.setUnitId(w.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal("10.1256"));request.setItems(List.of(item));
   var draft=plans.create(request);blocked(plans.unapprovalEligibility(draft.getId()),"审核");plans.approve(draft.getId());
   Map<String,Long> before=factsCounts();ready(plans.unapprovalEligibility(draft.getId()));ready(plans.unapprovalEligibility(draft.getId()));assertThat(factsCounts()).isEqualTo(before);
   plans.reverse(draft.getId());blocked(plans.unapprovalEligibility(draft.getId()),"审核");
   var inquiry=new InquirySaveRequest();inquiry.setBillDate(BusinessTime.today());inquiry.setSupplierId(w.supplierId());inquiry.setWarehouseId(w.warehouseId());inquiry.setCurrencyId(w.currencyId());inquiry.setExchangeRate(BigDecimal.ONE);
   var quoted=new InquiryItemLine();quoted.setGoodsId(w.goodsE());quoted.setUnitId(w.unitId());quoted.setUnitRate(BigDecimal.ONE);quoted.setQty(new BigDecimal("2.1256"));quoted.setPrice(new BigDecimal("3.5"));inquiry.setItems(List.of(quoted));
   var quote=inquiries.create(inquiry);blocked(inquiries.unapprovalEligibility(quote.getId()),"审核");inquiries.approve(quote.getId());ready(inquiries.unapprovalEligibility(quote.getId()));inquiries.reverse(quote.getId());blocked(inquiries.unapprovalEligibility(quote.getId()),"审核");
 }

 @Test void salesWarehouseDraftBlocksAnOtherwiseUnusedOrderAndDeletingItRestoresReadiness(){
   var w=world("sales-draft");harness.receiveSubcontractMaterial(w,w.goodsC(),"5");UUID order=call(harness,"createApprovedOrder",w,w.goodsC(),"5","100");ready(sales.unapprovalEligibility(order));
   UUID line=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
   com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest draft=call(harness,"shipmentRequest",w,line,w.goodsC(),"1");
   UUID shipment=shipments.create(draft).getId();Map<String,Long> before=factsCounts();blocked(sales.unapprovalEligibility(order),"待备货");assertThat(factsCounts()).isEqualTo(before);
   assertThatThrownBy(()->sales.reverse(order)).isInstanceOf(ApiException.class);shipments.delete(shipment);ready(sales.unapprovalEligibility(order));sales.reverse(order);
 }

 @Test void purchaseReceiptDraftIsARealReversalDependencyEvenBeforeReceivedCountersAdvance(){
   var fixture=new StandaloneDepartmentLifecycleConservationEndToEndTest();beans.autowireBean(fixture);fixture.prepare();
   FullChainEndToEndTest.World w=call(fixture,"world","purchase-unapproval-draft");UUID reviewer=call(fixture,"reviewer",w,"purchase-unapproval");
   UUID order=call(fixture,"purchaseOrder",w,null,"2.1256");call(fixture,"approve",w,reviewer,"PURCHASE",order);ready(purchases.unapprovalEligibility(order));
   var seen=purchases.detail(order);var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
   request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
   var source=seen.getItems().getFirst();var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
   line.setOrderItemId(source.getId());line.setGoodsId(source.getGoodsId());line.setUnitId(source.getUnitId());line.setUnitRate(source.getUnitRate());line.setQty(BigDecimal.ONE);request.setItems(List.of(line));
   UUID draft=receipts.create(request).getId();assertThat(db.queryForObject("SELECT received_qty FROM purchase_order_items WHERE id=?",BigDecimal.class,source.getId())).isZero();
   Map<String,Long> before=factsCounts();blocked(purchases.unapprovalEligibility(order),"收货");assertThat(factsCounts()).isEqualTo(before);
   assertThatThrownBy(()->purchases.reverse(order)).isInstanceOf(ApiException.class).hasMessageContaining("收货");
   assertThat(db.queryForObject("SELECT status FROM purchase_orders WHERE id=?",Integer.class,order)).isEqualTo(1);
   receipts.delete(draft);ready(purchases.unapprovalEligibility(order));purchases.reverse(order);
 }

 @Test void subcontractIssueCanBeWithdrawnBeforeConsumptionButItsOrderCannotIgnoreTheActualIssue(){
   var fixture=new SubcontractStepDrawEndToEndTest();beans.autowireBean(fixture);fixture.setup();var w=fixture.fixture.seedWorld("sc-eligibility-"+UUID.randomUUID());fixture.fixture.loginAs(w.superAdminUserId());
   call(fixture,"grantAuthorities",w.superAdminUserId(),new String[]{"subcontract_order:view","subcontract_order:draw","subcontract:view:all"});
   UUID parent=call(fixture,"goods",w,"eligibility-"+UUID.randomUUID(),"P","委外"),material=call(fixture,"goods",w,"eligibility-"+UUID.randomUUID(),"M","采购");fixture.fixture.insertBom(parent,material,"1");
   call(fixture,"otherIn",w,w.warehouseId(),material,null,"10","10");UUID order=call(fixture,"subcontractOrder",w,parent,"10",BusinessTime.today().plusDays(5),null);call(fixture,"approveSubcontract",w,order);ready(subcontract.unapprovalEligibility(order));
   UUID orderItem=call(fixture,"itemOf",order);var draws=beans.getBean(com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService.class).submit(new com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSubmitRequest(List.of(new com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawItemRequest(orderItem,null)),"sc-elig-draw-"+orderItem));
   UUID issue=draws.issueIds().getFirst();issues.approve(issue);blocked(subcontract.unapprovalEligibility(order),"发料");Map<String,Long> before=factsCounts();ready(issues.unapprovalEligibility(issue));assertThat(factsCounts()).isEqualTo(before);issues.reverse(issue);ready(subcontract.unapprovalEligibility(order));
 }

 @Test void reportWithActualMaterialUseHasPureSourceChecksAndAStaffReaderCannotWithdrawAnotherOwnersReport(){
   var fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();Object task=call(fixture,"createStartedTask","daily-eligibility-"+UUID.randomUUID(),true,"10");
   FullChainEndToEndTest.World w=call(task,"world");List<ReportablePlanLine> sources=call(fixture,"sources",task);var source=sources.stream().filter(i->i.orderItemId()!=null).findFirst().orElseThrow();
   DailyReportSaveRequest request=call(fixture,"reportRequest",task,source,"4","4");var draft=reports.create(request);reports.approve(draft.getId(),com.uten.imp.support.DailyReportApproveRequests.freshKey());
   Map<String,Long> before=factsCounts();new TransactionTemplate(transactions).executeWithoutResult(status->{ready(reports.unapprovalEligibility(draft.getId()));assertThat(db.queryForObject("SELECT 1",Integer.class)).isEqualTo(1);});assertThat(factsCounts()).isEqualTo(before);
   UUID scoped=harness.createUserWithPerms(w,"daily-scoped-"+UUID.randomUUID(),"production_daily_report:view","production_daily_report:reverse");harness.loginAs(scoped);
   // The existing Daily reverse duty may read across authors. It still cannot
   // withdraw another workshop's actual material without that source authority.
   blocked(reports.unapprovalEligibility(draft.getId()),"材料");
   UUID hidden=harness.createUserWithPerms(w,"daily-hidden-"+UUID.randomUUID(),"production_daily_report:view");harness.loginAs(hidden);
   assertThatThrownBy(()->reports.detail(draft.getId())).isInstanceOf(ApiException.class);
   harness.loginAs(w.superAdminUserId());reports.reverse(draft.getId());
 }

 @Test void missingReversePermissionAndHiddenOwnerReadDoNotBecomeAReadinessOracle(){
   var w=world("authority");var input=new PlanSaveRequest();input.setBillDate(BusinessTime.today());var item=new PlanItemLine();item.setGoodsId(w.goodsC());item.setUnitId(w.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(BigDecimal.ONE);input.setItems(List.of(item));var plan=plans.create(input);plans.approve(plan.getId());
   UUID reader=harness.createUserWithPerms(w,"plan-readonly-"+UUID.randomUUID(),"production_plan:view");harness.loginAs(reader);assertThatThrownBy(()->plans.unapprovalEligibility(plan.getId())).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
   UUID hidden=harness.createUserWithPerms(w,"plan-hidden-"+UUID.randomUUID(),"production_plan:view","production_plan:reverse");harness.loginAs(hidden);assertThatThrownBy(()->plans.unapprovalEligibility(plan.getId())).isInstanceOf(ApiException.class);
 }

 @Test void originalStockCostReadinessChangesWithLaterReceiptOrActualUseAndRetiredMaterialReturnIsNotCloneable(){
   var w=world("stock-eligibility");var request=new StockDocSaveRequest();request.setDocType("OTHER_IN");request.setBillDate(BusinessTime.today());request.setWarehouseId(w.warehouseId());
   var item=new StockDocItemLine();item.setGoodsId(w.goodsD());item.setUnitId(w.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal("2"));item.setPrice(new BigDecimal("25"));request.setItems(List.of(item));
   var original=stock.create(request);stock.approve(original.getId());ready(stock.unapprovalEligibility(original.getId()));
   item.setQty(BigDecimal.ONE);item.setPrice(new BigDecimal("100"));var later=stock.create(request);stock.approve(later.getId());
   Map<String,Long> before=factsCounts();assertThat(stock.unapprovalEligibility(original.getId()).eligible()).isFalse();assertThat(factsCounts()).isEqualTo(before);
   ready(stock.unapprovalEligibility(later.getId()));stock.reverse(later.getId());ready(stock.unapprovalEligibility(original.getId()));stock.reverse(original.getId());
   var retired=new StockDocSaveRequest();retired.setDocType("WDRAW");retired.setBillDate(BusinessTime.today());retired.setWarehouseId(w.warehouseId());retired.setItems(List.of(item));assertThatThrownBy(()->stock.create(retired)).isInstanceOf(ApiException.class).hasMessageContaining("车间任务");
 }

 @Test void customerReturnBeforeQualityDispositionCanReverseButAConfirmedCustomerDecisionCannot(){
   var w=world("return-eligibility");harness.receiveSubcontractMaterial(w,w.goodsC(),"3");
   com.uten.imp.features.sales.shipment.dto.ShipmentDetail source=call(harness,"directFreeShipmentForReturn",w,w.goodsC());
   com.uten.imp.features.sales.ret.dto.ReturnSaveRequest request=call(harness,"directReturnRequest",w,source,"1");
   var created=customerReturns.create(request);customerReturns.approve(created.getId());Map<String,Long> before=factsCounts();ready(customerReturns.unapprovalEligibility(created.getId()));assertThat(factsCounts()).isEqualTo(before);
   customerReturns.reverse(created.getId());
   var second=customerReturns.create(request);customerReturns.approve(second.getId());
   var decision=new com.uten.imp.features.sales.ret.dto.CustomerDispositionRequest("REFUND_CLOSED","已确认客户退款处置","return-decision-"+second.getId());
   customerReturns.setDisposition(second.getId(),decision);blocked(customerReturns.unapprovalEligibility(second.getId()),"处置");
 }

 @Test void untouchedSupplierWasteRestoresTheOriginalMaterialAndRetiredOtherShipmentNeverCreatesADraft(){
   var fixture=new SubcontractLossValueEndToEndTest();beans.autowireBean(fixture);fixture.fixture();Object c=call(fixture,"readyInBaseCurrency","waste-eligibility-"+UUID.randomUUID(),"5","50");
   UUID loss=call(fixture,"loss",c,"2","2");Map<String,Long> before=factsCounts();ready(wastes.unapprovalEligibility(loss));assertThat(factsCounts()).isEqualTo(before);wastes.reverse(loss);
   FullChainEndToEndTest.World w=call(c,"world");harness.loginAs(w.superAdminUserId());
   UUID historical=UUID.randomUUID();String number=beans.getBean(com.uten.imp.common.docnumber.DocNumberService.class).nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.SALES_OTHER_SHIPMENT);
   // The current database also forbids creating new rows in this retired family.
   // Preserve that boundary instead of inventing an approved historical fixture.
   assertThatThrownBy(()->db.update("INSERT INTO sales_other_shipments(id,bill_no,bill_date,owner_employee_id,maker_id,warehouse_id,status,created_by) VALUES(?,?,?,?,?,?,1,?)",historical,number,BusinessTime.today(),w.employeeId(),w.employeeId(),w.warehouseId(),w.superAdminUserId()))
       .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class).hasMessageContaining("historical other shipments are read-only");
   assertThatThrownBy(()->historicalShipments.create(new com.uten.imp.features.sales.other_shipment.dto.OtherShipmentSaveRequest())).isInstanceOf(RuntimeException.class);
   assertThat(db.queryForObject("SELECT COUNT(*) FROM document_unapprovals WHERE original_id=?",Integer.class,historical)).isZero();
   assertThat(db.queryForObject("SELECT COUNT(*) FROM sales_other_shipments WHERE id=?",Integer.class,historical)).isZero();
 }

 @ParameterizedTest
 @ValueSource(strings={"GOOD_RELEASE","SCRAP","REWORK"})
 void partialCustomerQualityDispositionReturnsBlockedCapabilityWithoutPoisoningCallerTransaction(String action) throws Exception {
   var w=world("quality-partial-"+action);var returned=approvedCustomerReturn(w,"1");
   customerReturnQuality.dispose(returned.getId(),returned.getItems().getFirst().getId(),
       new com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest(action,new BigDecimal("0.5"),"半件品质处置","partial-quality-"+returned.getId()));
   var quality=customerReturnQuality.list(returned.getId()).getFirst();assertThat(quality.status()).isEqualTo("PARTIAL");
   assertThat(quality.receivedBaseQty()).isEqualByComparingTo("1");assertThat(quality.remainingBaseQty()).isEqualByComparingTo("0.5");
   assertThat(quality.releasedBaseQty()).isEqualByComparingTo("GOOD_RELEASE".equals(action)?"0.5":"0");
   assertThat(quality.scrappedBaseQty()).isEqualByComparingTo("SCRAP".equals(action)?"0.5":"0");
   assertThat(quality.reworkBaseQty()).isEqualByComparingTo("REWORK".equals(action)?"0.5":"0");
   assertCustomerQualityCapabilityBlockedWithoutEffects(returned.getId());
 }

 @Test void fullyDisposedCustomerQualityReturnsBlockedHttpCapabilityAndConflictPostWithoutEffects() throws Exception {
   var w=world("quality-full");var returned=approvedCustomerReturn(w,"3");var item=returned.getItems().getFirst();
   customerReturnQuality.dispose(returned.getId(),item.getId(),new com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest("GOOD_RELEASE",new BigDecimal("2"),"良品释放","full-good-"+returned.getId()));
   customerReturnQuality.dispose(returned.getId(),item.getId(),new com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest("SCRAP",new BigDecimal("0.5"),"报废","full-scrap-"+returned.getId()));
   customerReturnQuality.dispose(returned.getId(),item.getId(),new com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest("REWORK",new BigDecimal("0.5"),"返工","full-rework-"+returned.getId()));
   var quality=customerReturnQuality.list(returned.getId()).getFirst();assertThat(quality.status()).isEqualTo("DISPOSED");
   assertThat(quality.receivedBaseQty()).isEqualByComparingTo("3");assertThat(quality.releasedBaseQty()).isEqualByComparingTo("2");
   assertThat(quality.scrappedBaseQty()).isEqualByComparingTo("0.5");assertThat(quality.reworkBaseQty()).isEqualByComparingTo("0.5");assertThat(quality.remainingBaseQty()).isZero();
   assertThat(db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,w.warehouseId(),w.goodsC())).isEqualByComparingTo("2");
   assertCustomerQualityCapabilityBlockedWithoutEffects(returned.getId());
 }

 @Test void directQualityPreflightMissingAndPartialFactsAllowCallerToCatchConflictAndCommit() {
   var w=world("quality-helper");var returned=approvedCustomerReturn(w,"1");Map<String,String> before=qualityFacts();
   new TransactionTemplate(transactions).executeWithoutResult(status->{
     // Legacy absence is intentionally left to the domain's explicit history guard.
     call(customerReturnQuality,"requireUntouchedReceiptReversible",UUID.randomUUID(),1);
     assertThatThrownBy(()->call(customerReturnQuality,"requireUntouchedReceiptReversible",returned.getId(),2))
         .isInstanceOf(ApiException.class).hasMessageContaining("不完整");
     assertThat(db.queryForObject("SELECT 1",Integer.class)).isEqualTo(1);assertThat(status.isRollbackOnly()).isFalse();
   });assertThat(qualityFacts()).isEqualTo(before);
   customerReturnQuality.dispose(returned.getId(),returned.getItems().getFirst().getId(),new com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest("SCRAP",new BigDecimal("0.5"),"半件报废","helper-partial-"+returned.getId()));
   before=qualityFacts();new TransactionTemplate(transactions).executeWithoutResult(status->{
     assertThatThrownBy(()->call(customerReturnQuality,"requireUntouchedReceiptReversible",returned.getId(),1))
         .isInstanceOf(ApiException.class).hasMessageContaining("处置");
     assertThat(db.queryForObject("SELECT 1",Integer.class)).isEqualTo(1);assertThat(status.isRollbackOnly()).isFalse();
   });assertThat(qualityFacts()).isEqualTo(before);
 }

 private com.uten.imp.features.sales.ret.dto.ReturnDetail approvedCustomerReturn(FullChainEndToEndTest.World w,String qty){
   harness.receiveSubcontractMaterial(w,w.goodsC(),"3");
   com.uten.imp.features.sales.shipment.dto.ShipmentDetail source=call(harness,"directFreeShipmentForReturn",w,w.goodsC());
   com.uten.imp.features.sales.ret.dto.ReturnSaveRequest request=call(harness,"directReturnRequest",w,source,qty);
   return customerReturns.approve(customerReturns.create(request).getId());
 }

 private void assertCustomerQualityCapabilityBlockedWithoutEffects(UUID id) throws Exception {
   Map<String,String> before=qualityFacts();
   var http=org.springframework.test.web.servlet.setup.MockMvcBuilders.standaloneSetup(
       new com.uten.imp.features.documents.DocumentUnapprovalController(unapproval))
       .setControllerAdvice(new com.uten.imp.common.web.GlobalExceptionHandler()).build();
   http.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/documents/salesReturn/{id}/unapproval-capability",id))
       .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isOk())
       .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$.eligible").value(false))
       .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$.reasons[0].message").value(org.hamcrest.Matchers.containsString("处置")));
   var capability=unapproval.capability("salesReturn",id);assertThat(capability.eligible()).isFalse();
   assertThat(capability.reasons()).anySatisfy(reason->assertThat(reason.message()).contains("处置"));
   new TransactionTemplate(transactions).executeWithoutResult(status->{
     var nested=unapproval.capability("salesReturn",id);assertThat(nested.eligible()).isFalse();
     assertThat(nested.factsSnapshot()).isEqualTo(capability.factsSnapshot());
     assertThat(db.queryForObject("SELECT 1",Integer.class)).isEqualTo(1);assertThat(status.isRollbackOnly()).isFalse();
   });
   // Both current snapshot submissions and older callers without a snapshot retain writer guards.
   for(String snapshot:List.of("",capability.factsSnapshot())){
     String body="{\"idempotencyKey\":\"quality-blocked-"+UUID.randomUUID()+"\",\"reason\":\"不应撤掉已经处置的实物\""+(snapshot.isEmpty()?"":",\"expectedSnapshot\":\""+snapshot+"\"")+"}";
     http.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/documents/salesReturn/{id}/unapprove",id)
         .contentType(org.springframework.http.MediaType.APPLICATION_JSON).content(body))
         .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isConflict());
   }
   assertThat(qualityFacts()).isEqualTo(before);assertThat(db.queryForObject("SELECT status FROM sales_returns WHERE id=?",Integer.class,id)).isEqualTo(1);
   assertThat(db.queryForObject("SELECT count(*) FROM document_unapprovals WHERE original_id=?",Long.class,id)).isZero();
 }

 private Map<String,String> qualityFacts(){
   Map<String,String> result=new TreeMap<>();
   for(String table:List.of("sales_returns","sales_return_items","sales_return_quality_items","sales_return_quality_events","sales_shipment_items","stock_balances","stock_movements","stock_value_events","stock_value_nodes","stock_value_edges","stock_value_postings","ar_ap_ledger","document_unapprovals"))
     result.put(table,db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb)::text FROM "+table+" t",String.class));
   return result;
 }

 private FullChainEndToEndTest.World world(String label){var w=harness.seedWorld(label+"-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());return w;}
 private Map<String,Long> factsCounts(){Map<String,Long> r=new TreeMap<>();for(String table:List.of("stock_movements","stock_value_events","stock_value_nodes","stock_value_edges","stock_value_postings","stock_value_position_transfers","document_unapprovals"))r.put(table,db.queryForObject("SELECT COUNT(*) FROM "+table,Long.class));return r;}
 private static void ready(Eligibility value){assertThat(value.eligible()).isTrue();assertThat(value.reasons()).isEmpty();assertThat(value.factsSnapshot()).matches("[0-9a-f]{64}");}
 private static void blocked(Eligibility value,String phrase){assertThat(value.eligible()).isFalse();assertThat(value.reasons()).anySatisfy(r->assertThat(r.message()).contains(phrase));}
 @SuppressWarnings("unchecked")private static <T>T call(Object target,String method,Object...args){return (T)ReflectionTestUtils.invokeMethod(target,method,args);}
}
