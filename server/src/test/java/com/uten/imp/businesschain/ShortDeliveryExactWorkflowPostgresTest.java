package com.uten.imp.businesschain;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.expenseclaim.ExpenseClaimService;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimCreateRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimItemInput;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

/** Same private current-schema harness as the physical shipment tests. */
class ShortDeliveryExactWorkflowPostgresTest extends ShipmentExactQuantityPostgresTest {
 @Autowired SubcontractOrderService orders;
 @Autowired SubcontractShortDeliveryService shortDeliveries;
 @Autowired WarehouseArrivalRegistrationService arrivals;
 @Autowired com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService financeApproval;
 @Autowired ExpenseClaimService expenses;

 @Test void repeatingRatioIsExplicitAndLaterStateChangeCannotRetagItsOriginalPrecision() throws Exception {
  var setup=order("short-exact-repeat","3","5");var w=setup.world();UUID item=setup.item();
  WarehouseArrivalRegisterRequest arrival=ReflectionTestUtils.invokeMethod(setup.helper(),"arrival",w,item,"2",true,"exact");
  assertThrows(BusinessPrecisionRequiredException.class,()->arrivals.register(arrival));
  assertEquals(0,db.queryForObject("SELECT count(*) FROM subcontract_short_delivery_cases WHERE order_item_id=?",Integer.class,item));
  try(var ignored=choice("subcontract.shortfall.percent",24,"DOWN")){arrivals.register(arrival);}
  var row=db.queryForMap("SELECT * FROM subcontract_short_delivery_cases WHERE order_item_id=?",item);UUID id=(UUID)row.get("id");
  decimal("33.333333333333333333333333",(BigDecimal)row.get("shortfall_pct"));
  String policy=db.queryForObject("SELECT shortfall_pct_precision_policy::text FROM subcontract_short_delivery_cases WHERE id=?",String.class,id);
  try(var ignored=choice("subcontract.shortfall.percent",0,"HALF_UP")){
   shortDeliveries.decide(id,new DecisionRequest("WAIT_MORE",BusinessTime.today().plusDays(2),"later batch",((Number)row.get("version")).longValue()));
  }
  assertEquals(policy,db.queryForObject("SELECT shortfall_pct_precision_policy::text FROM subcontract_short_delivery_cases WHERE id=?",String.class,id));
  decimal("33.333333333333333333333333",db.queryForObject("SELECT shortfall_pct FROM subcontract_short_delivery_cases WHERE id=?",BigDecimal.class,id));
  long version=db.queryForObject("SELECT version FROM subcontract_short_delivery_cases WHERE id=?",Long.class,id);
  try(var ignored=choice("subcontract.shortfall.percent",2,"HALF_UP")){
   shortDeliveries.decide(id,new DecisionRequest("ACCEPT_LOSS",null,"supplier confirms original loss",version));
  }
  decimal("1",db.queryForObject("SELECT loss_qty FROM subcontract_short_delivery_cases WHERE id=?",BigDecimal.class,id));
  decimal("33.33",db.queryForObject("SELECT loss_pct FROM subcontract_short_delivery_cases WHERE id=?",BigDecimal.class,id));
  assertEquals(policy,db.queryForObject("SELECT shortfall_pct_precision_policy::text FROM subcontract_short_delivery_cases WHERE id=?",String.class,id));
  assertEquals("33.33",db.queryForObject("SELECT event_snapshot->>'lossPct' FROM subcontract_short_delivery_case_events WHERE case_id=? AND event_type='ACCEPT_LOSS_DECIDED'",String.class,id));
  try(var ignored=choice("subcontract.loss-summary.percent",24,"DOWN")){
   decimal("33.333333333333333333333333",shortDeliveries.supplierSummary(w.supplierId()).lossPct());
  }
 }

 @Test void originalReimbursementMetadataKeepsOneNativeClaimAndItsCompleteAmount(){
  var w=fixture.seedWorld("expense-original-source");fixture.loginAs(w.superAdminUserId());
  var request=new ExpenseClaimCreateRequest("original reimbursement","source only",List.of(
    new ExpenseClaimItemInput("MEAL",new BigDecimal("1.000000000000000000000001"),BusinessTime.today(),"fixture")),null,"GENERAL","REIMBURSEMENT",null,null);
  var claim=expenses.create(request);
  decimal("1.000000000000000000000001",claim.totalAmount());
  assertEquals("REIMBURSEMENT",claim.applicationKind());assertNull(claim.financialApplication());
  assertEquals(1,db.queryForObject("SELECT count(*) FROM expense_claim_source_links WHERE claim_id=?",Integer.class,claim.id()));
  assertEquals(0,db.queryForObject("SELECT count(*) FROM finance_applications WHERE source_kind='EXPENSE_CLAIM' AND source_id=?",Integer.class,claim.id()));
  var independentTravel=expenses.create(new ExpenseClaimCreateRequest("independent travel","existing native path",request.items(),null,"TRAVEL"));
  assertEquals("TRAVEL",independentTravel.expenseKind());assertNull(independentTravel.travelApplicationId());
 }

 private Setup order(String label,String qty,String pct) throws Exception {
  var w=fixture.seedWorld(label);fixture.loginAs(w.superAdminUserId());
  UUID material=fixture.ensureSubcontractDirectMaterial(w,w.goodsE());
  fixture.receiveSubcontractMaterial(w,material,new BigDecimal(qty).multiply(BigDecimal.valueOf(2)).toPlainString());
  var helper=new SubcontractShortDeliveryEndToEndTest();beans.autowireBean(helper);helper.fixture=fixture;
  var request=ReflectionTestUtils.<com.uten.imp.features.subcontract.order.dto.OrderSaveRequest>invokeMethod(helper,"orderRequest",w,qty,pct);
  UUID order=orders.create(request).getId();UUID item=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,order);
  UUID reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",w);financeApproval.submit("SUBCONTRACT",order);
  fixture.loginAs(reviewer);
  fixture.approvePendingFinance("SUBCONTRACT",order);
  fixture.loginAs(w.superAdminUserId());
  fixture.drawAndIssueSubcontract(item,new BigDecimal(qty),"exact-short-"+item);
  return new Setup(w,item,helper);
 }
 private record Setup(FullChainEndToEndTest.World world,UUID item,SubcontractShortDeliveryEndToEndTest helper){}
 private static AutoCloseable choice(String key,int scale,String mode){return BusinessPrecisionContext.use(Map.of(key,new BusinessPrecisionContext.Choice(scale,mode)));}
 private static void decimal(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual));}
}
