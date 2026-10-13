package com.uten.imp.businesschain;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.security.core.context.SecurityContextHolder;
import java.io.IOException;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
 "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
 "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
 "uten.jwt.secret=gift-regression-isolated-jwt-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
 "uten.crypto.pgp-master-key=gift-regression-isolated-pgp-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
 "uten.crypto.hmac-key=gift-regression-isolated-hmac-key-0123456789-abcdef",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class PurchaseGiftRequestFulfilmentEndToEndTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
 @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;
 @Autowired PurchaseOrderService orders;@Autowired PurchaseRequestService requests;
 @Autowired ProcurementFinanceApprovalService finance;@Autowired TaskClaimService claims;
 @Autowired DocumentUnapprovalService unapproval;
 @Autowired com.uten.imp.features.purchase.receipt.PurchaseReceiptService receipts;
 @Autowired com.uten.imp.features.purchase.request.ProductionPurchaseRequestFacade productionRequests;
 @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
 FullChainEndToEndTest harness;
 @BeforeEach void setup(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
 @AfterEach void clear(){SecurityContextHolder.clearContext();}
 private record Source(FullChainEndToEndTest.World world,UUID request,UUID item) { }

 @Test void ninePaidOneFreeClosesTenThenUnapprovalReopensAndReapprovalPostsTheSameTenOnlyOnce(){
  Source s=source("10","0");UUID order=order(s,"9","1");approve(s,order);
  assertSource(s,"9","1","0","0",true);assertThat(requests.detail(s.request()).getItems().getFirst().getQty()).isEqualByComparingTo("10");
  assertThatThrownBy(()->requests.decompositionPreview(List.of(s.item()))).isInstanceOf(ApiException.class);
  var capability=unapproval.capability("purchaseOrder",order);assertThat(capability.eligible()).isTrue();
  var command=new DocumentUnapprovalService.UnapproveRequest("request-gift-undo-"+order,"实物需求与收费赠品对称",capability.factsSnapshot());
  var draft=(com.uten.imp.features.purchase.order.dto.OrderDetail)unapproval.unapprove("purchaseOrder",order,command);
  var retry=(com.uten.imp.features.purchase.order.dto.OrderDetail)unapproval.unapprove("purchaseOrder",order,new DocumentUnapprovalService.UnapproveRequest("changed-key-"+order,"重试不双减"));
  assertThat(retry.getId()).isEqualTo(draft.getId());assertSource(s,"0","0","10","0",false);
  var preview=requests.decompositionPreview(List.of(s.item())).getFirst();assertThat(preview.remainingQty()).isEqualByComparingTo("10");assertThat(preview.physicalRemainingQty()).isEqualByComparingTo("10");
  approve(s,draft.getId());assertSource(s,"9","1","0","0",true);
  var later=(com.uten.imp.features.purchase.order.dto.OrderDetail)unapproval.unapprove("purchaseOrder",order,command);
  assertThat(later.getId()).isEqualTo(draft.getId());assertThat(later.getStatus()).isEqualTo((short)1);assertSource(s,"9","1","0","0",true);
 }
 @Test void aRequestedFreeUnitStaysFreeWhenOnlyTheTenPaidUnitsHaveBeenOrdered(){
  Source s=source("10","1");UUID order=order(s,"10","0");approve(s,order);
  assertSource(s,"10","0","0","1",false);
  var preview=requests.decompositionPreview(List.of(s.item())).getFirst();assertThat(new BigDecimal(preview.getRequestedQtyExact())).isEqualByComparingTo("10");
  assertThat(preview.remainingQty()).isZero();assertThat(preview.remainingGiftQty()).isEqualByComparingTo("1");assertThat(preview.physicalRemainingQty()).isEqualByComparingTo("1");
  var free=order(s,"0","1");approve(s,free);assertSource(s,"10","1","0","0",true);
  assertThat(orders.detail(free).getTotalOriginal()).isZero();orders.reverse(free);assertSource(s,"10","0","0","1",false);
 }
 @Test void pendingFreeOnlyOrderConsumesItsPhysicalNeedAndPreventsQuantityCorrectionUntilCancelled(){
  Source s=source("1","0");UUID order=order(s,"0","1");harness.createUserWithPerms(s.world(),"pending-review-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(s.world().superAdminUserId());finance.submit("PURCHASE",order);
  var item=requests.detail(s.request()).getItems().getFirst();assertThat(item.getPendingQty()).isZero();assertThat(item.getPendingGiftQty()).isEqualByComparingTo("1");assertThat(item.getPhysicalPendingQty()).isEqualByComparingTo("1");assertThat(item.getPhysicalRemainingQty()).isZero();
  assertThat(closed(s)).isFalse();assertThatThrownBy(()->requests.decompositionPreview(List.of(s.item()))).isInstanceOf(ApiException.class);
  assertThatThrownBy(()->requests.adjustItemQty(s.request(),s.item(),new BigDecimal("2"),item.getRowVersion())).isInstanceOf(ApiException.class).hasMessageContaining("待财务");
  String sourceBefore=db.queryForObject("SELECT to_jsonb(r)::text FROM purchase_requests r WHERE id=?",String.class,s.request());
  assertThatThrownBy(()->new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(tx->productionRequests.cancelGeneratedDraft(s.request(),com.uten.imp.features.purchase.request.ProductionPurchaseRequestFacade.LifecycleAction.REVERSE))).isInstanceOf(ApiException.class).hasMessageContaining("下游");
  assertThat(db.queryForObject("SELECT to_jsonb(r)::text FROM purchase_requests r WHERE id=?",String.class,s.request())).isEqualTo(sourceBefore);
  orders.cancel(order);assertSource(s,"0","0","1","0",false);assertThat(requests.decompositionPreview(List.of(s.item())).getFirst().remainingQty()).isEqualByComparingTo("1");
 }
 @Test void mergedEighteenPaidTwoFreeAllocatesTenPhysicalToEachSourceAndReverseRestoresBoth(){
  Source first=source("10","0");Source second=additional(first,"10","0");
  var request=orderRequest(first,"18","2");request.getItems().getFirst().setRequestItemIds(List.of(first.item(),second.item()));request.getItems().getFirst().setRequestItemId(null);
  UUID order=orders.create(request).getId();approve(first,order);assertSource(first,"9","1","0","0",true);assertSource(second,"9","1","0","0",true);
  assertThat(db.queryForObject("SELECT SUM(alloc_qty) FROM purchase_order_item_sources src JOIN purchase_order_items item ON item.id=src.order_item_id WHERE item.order_id=?",BigDecimal.class,order)).isEqualByComparingTo("18");
  assertThat(db.queryForObject("SELECT SUM(allocated_gift_qty) FROM purchase_order_item_sources src JOIN purchase_order_items item ON item.id=src.order_item_id WHERE item.order_id=?",BigDecimal.class,order)).isEqualByComparingTo("2");
  orders.reverse(order);assertSource(first,"0","0","10","0",false);assertSource(second,"0","0","10","0",false);
 }
 @Test void aFreeOnlyRequestRemainsFreeThroughPendingApprovalReversalAndSourceViews(){
  Source s=source("0","1");UUID order=order(s,"0","1");approve(s,order);assertSource(s,"0","1","0","0",true);
  assertThat(orders.detail(order).getTotalOriginal()).isZero();
  assertThatThrownBy(()->new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(tx->productionRequests.cancelGeneratedDraft(s.request(),com.uten.imp.features.purchase.request.ProductionPurchaseRequestFacade.LifecycleAction.REVERSE))).isInstanceOf(ApiException.class).hasMessageContaining("下游");
  assertThat(requests.detail(s.request()).getStatus()).isEqualTo((short)1);orders.reverse(order);assertSource(s,"0","0","0","1",false);
  var preview=requests.decompositionPreview(List.of(s.item())).getFirst();assertThat(preview.remainingQty()).isZero();assertThat(preview.remainingGiftQty()).isEqualByComparingTo("1");
 }
 @Test void draftGiftChangesRecomputePendingPhysicalCommitmentAndPendingReviewCannotEditTheFrozenGift(){
  Source s=source("10","0");UUID order=order(s,"9","0");
  orders.update(order,orderRequest(s,"9","1"));
  harness.createUserWithPerms(s.world(),"gift-edit-review-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(s.world().superAdminUserId());finance.submit("PURCHASE",order);
  var committed=requests.detail(s.request()).getItems().getFirst();assertThat(committed.getPendingQty()).isEqualByComparingTo("9");assertThat(committed.getPendingGiftQty()).isEqualByComparingTo("1");assertThat(committed.getPhysicalRemainingQty()).isZero();
  String before=db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE order_id=? AND NOT is_deleted",String.class,order);
  assertThatThrownBy(()->orders.update(order,orderRequest(s,"9","0"))).isInstanceOf(ApiException.class);
  assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE order_id=? AND NOT is_deleted",String.class,order)).isEqualTo(before);
  orders.cancel(order);assertSource(s,"0","0","10","0",false);
  UUID next=order(s,"9","0");finance.submit("PURCHASE",next);var waiting=requests.detail(s.request()).getItems().getFirst();assertThat(waiting.getPendingQty()).isEqualByComparingTo("9");assertThat(waiting.getPendingGiftQty()).isZero();assertThat(waiting.getPhysicalRemainingQty()).isEqualByComparingTo("1");orders.cancel(next);
 }
 @Test void paidArrivalLeavesOnePhysicalGiftPendingWithZeroMoneyAndGiftArrivalClearsOnlyThatRemainder(){
  var fixture=new GiftPhysicalDemandCoverageEndToEndTest();beans.autowireBean(fixture);fixture.prepare();Object f=ReflectionTestUtils.invokeMethod(fixture,"fixture");FullChainEndToEndTest.World w=ReflectionTestUtils.invokeMethod(f,"w");
  assertPending(w,"11","100");UUID paid=ReflectionTestUtils.invokeMethod(fixture,"receipt",f,"10","0");receipts.approve(paid);ReflectionTestUtils.invokeMethod(fixture,"passAndStock",f,paid);
  assertPending(w,"1","0");assertThat(db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,w.goodsD())).isEqualByComparingTo("10");
  UUID gift=ReflectionTestUtils.invokeMethod(fixture,"receipt",f,"0","1");receipts.approve(gift);ReflectionTestUtils.invokeMethod(fixture,"passAndStock",f,gift);assertPending(w,"0","0");
  assertThat(db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,w.goodsD())).isEqualByComparingTo("11");assertThat(db.queryForObject("SELECT SUM(amount_local) FROM stock_balances WHERE goods_id=?",BigDecimal.class,w.goodsD())).isEqualByComparingTo("100");
 }
 private void assertPending(FullChainEndToEndTest.World w,String physical,String money){assertThat(db.queryForObject("SELECT COALESCE(SUM(pending_qty),0) FROM purchase_order_pending_v WHERE goods_id=?",BigDecimal.class,w.goodsD())).isEqualByComparingTo(physical);assertThat(db.queryForObject("SELECT COALESCE(SUM(pending_amt),0) FROM purchase_order_pending_v WHERE goods_id=?",BigDecimal.class,w.goodsD())).isEqualByComparingTo(money);}
 @Test void legacyAnnotationDoesNotIncreasePhysicalNeedAndForwardRepairChangesOnlyTheStaleDerivedFlag() throws IOException {
  Resource forwardMigration=physicalFulfilmentMigration();
  var w=harness.seedWorld("request-legacy-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
  var input=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();input.setBillDate(BusinessTime.today());input.setWarehouseId(w.warehouseId());
  var line=new com.uten.imp.features.purchase.request.dto.RequestItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("10"));line.setGiftQty(BigDecimal.ONE);input.setItems(List.of(line));
  var draft=requests.create(input);UUID item=draft.getItems().getFirst().getId();
  // Historical recorded semantics are a controlled migration-shaped fixture, never accepted from a public new-order command.
  db.update("UPDATE purchase_requests SET quantity_semantics='LEGACY_RECORDED' WHERE id=?",draft.getId());db.update("UPDATE purchase_request_items SET quantity_semantics='LEGACY_RECORDED' WHERE id=?",item);
  requests.approve(draft.getId());Source s=new Source(w,draft.getId(),item);UUID order=order(s,"9","1");approve(s,order);
  assertSource(s,"9","1","0","0",true);assertThat(new BigDecimal(requests.detail(s.request()).getItems().getFirst().getPhysicalQtyExact())).isEqualByComparingTo("10");
  String originalItem=db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_request_items i WHERE id=?",String.class,item);
  String originalHeader=db.queryForObject("SELECT to_jsonb(r)::text FROM purchase_requests r WHERE id=?",String.class,s.request());
  String latestProjection=db.queryForObject("SELECT pg_get_viewdef('v_procurement_decomposition_tasks'::regclass,true)",String.class);
  // FullChain shares its latest schema: V853 replay must not leave its pre-V854 view behind.
  new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(tx->{
   tx.setRollbackOnly();
   db.update("UPDATE purchase_requests SET is_closed=false WHERE id=?",s.request());assertThat(closed(s)).isFalse();
   new ResourceDatabasePopulator(forwardMigration).execute(Objects.requireNonNull(db.getDataSource()));
   assertThat(closed(s)).isTrue();assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_request_items i WHERE id=?",String.class,item)).isEqualTo(originalItem);
   String headerDigest=db.queryForObject("SELECT encode(digest(to_jsonb(r)::text,'sha256'),'hex') FROM purchase_requests r WHERE id=?",String.class,s.request());
   new ResourceDatabasePopulator(forwardMigration).execute(Objects.requireNonNull(db.getDataSource()));
   assertThat(db.queryForObject("SELECT encode(digest(to_jsonb(r)::text,'sha256'),'hex') FROM purchase_requests r WHERE id=?",String.class,s.request())).isEqualTo(headerDigest);
  });
  assertThat(db.queryForObject("SELECT to_jsonb(r)::text FROM purchase_requests r WHERE id=?",String.class,s.request())).isEqualTo(originalHeader);
  assertThat(db.queryForObject("SELECT pg_get_viewdef('v_procurement_decomposition_tasks'::regclass,true)",String.class)).isEqualTo(latestProjection);
 }
 private static Resource physicalFulfilmentMigration() throws IOException {
  Resource[] migrations=new PathMatchingResourcePatternResolver().getResources("classpath:db/migration/V853__*.sql");
  assertThat(migrations).as("exactly one V853 physical fulfilment migration on the test classpath").hasSize(1);
  assertThat(migrations[0].isReadable()).as("V853 physical fulfilment migration is readable").isTrue();
  return migrations[0];
 }
 @Test void legalAlternateRateKeepsPhysicalAndSourceBillingQuantitiesAndRejectsMixedFrozenBases(){
  var w=harness.seedWorld("request-unit-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());UUID unit=UUID.randomUUID();
  db.update("INSERT INTO units(id,code,name) VALUES(?,?,?)",unit,"REQUEST-ALT-"+unit,"alternate");
  for(String rate:List.of("2","1.00005","999999999999.999999")){
   String qty=rate.startsWith("999")?"0.0002":"10";String paid=rate.startsWith("999")?"0.0001":"9";String free=rate.startsWith("999")?"0.0001":"1";
   Source s=create(w,qty,"0",unit,new BigDecimal(rate));UUID order=order(s,paid,free);approve(s,order);
   assertSource(s,paid,free,"0","0",true);assertThat(orders.detail(order).getItems().getFirst().getUnitRate()).isEqualByComparingTo(rate);
   Source unmatched=create(w,qty,"0",unit,new BigDecimal(rate));
   var before=db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_request_items i WHERE id=?",String.class,unmatched.item());
   var wrong=orderRequest(unmatched,paid,free);wrong.getItems().getFirst().setUnitId(w.unitId());wrong.getItems().getFirst().setUnitRate(BigDecimal.ONE);
   assertThatThrownBy(()->{UUID draft=orders.create(wrong).getId();finance.submit("PURCHASE",draft);}).isInstanceOf(ApiException.class).hasMessageContaining("来源申请");
   assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_request_items i WHERE id=?",String.class,unmatched.item())).isEqualTo(before);
  }
 }
 private Source source(String paid,String gift){var w=harness.seedWorld("request-physical-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());return create(w,paid,gift);}
 private Source additional(Source prior,String paid,String gift){return create(prior.world(),paid,gift);}
 private Source create(FullChainEndToEndTest.World w,String paid,String gift){
  return create(w,paid,gift,w.unitId(),BigDecimal.ONE);
 }
 private Source create(FullChainEndToEndTest.World w,String paid,String gift,UUID unit,BigDecimal rate){
  var r=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();r.setBillDate(BusinessTime.today());r.setWarehouseId(w.warehouseId());
  var line=new com.uten.imp.features.purchase.request.dto.RequestItemLine();line.setGoodsId(w.goodsD());line.setUnitId(unit);line.setUnitRate(rate);line.setQty(new BigDecimal(paid));line.setGiftQty(new BigDecimal(gift));r.setItems(List.of(line));
  var created=requests.create(r);requests.approve(created.getId());return new Source(w,created.getId(),created.getItems().getFirst().getId());
 }
 private com.uten.imp.features.purchase.order.dto.OrderSaveRequest orderRequest(Source s,String paid,String gift){
  var r=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();r.setBillDate(BusinessTime.today());r.setSupplierId(s.world().supplierId());r.setWarehouseId(s.world().warehouseId());r.setCurrencyId(db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class));r.setExchangeRate(BigDecimal.ONE);r.setTaxRate(BigDecimal.ZERO);r.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
  var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(s.world().goodsD());line.setUnitId(db.queryForObject("SELECT unit_id FROM purchase_request_items WHERE id=?",UUID.class,s.item()));line.setUnitRate(db.queryForObject("SELECT unit_rate FROM purchase_request_items WHERE id=?",BigDecimal.class,s.item()));line.setQty(new BigDecimal(paid));line.setGiftQty(new BigDecimal(gift));line.setPrice(new BigDecimal(paid).signum()==0?BigDecimal.ZERO:new BigDecimal("10"));line.setRequestItemId(s.item());r.setItems(List.of(line));return r;
 }
 private UUID order(Source s,String paid,String gift){return orders.create(orderRequest(s,paid,gift)).getId();}
 private void approve(Source s,UUID order){harness.loginAs(s.world().superAdminUserId());UUID reviewer=harness.createUserWithPerms(s.world(),"request-review-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(s.world().superAdminUserId());finance.submit("PURCHASE",order);harness.loginAs(reviewer);
  var row=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING'",order);UUID id=(UUID)row.get("id");UUID claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",id.toString()).claimId();finance.approveBatch(List.of(new BatchDecisionItem(id,((Number)row.get("version")).longValue(),claim)),null,BigDecimal.ONE);harness.loginAs(s.world().superAdminUserId());}
 private boolean closed(Source s){return db.queryForObject("SELECT is_closed FROM purchase_requests WHERE id=?",Boolean.class,s.request());}
 private void assertSource(Source s,String paid,String gift,String remainingPaid,String remainingGift,boolean closed){var actual=requests.detail(s.request()).getItems().getFirst();assertThat(actual.getOrderedQty()).isEqualByComparingTo(paid);assertThat(actual.getGiftOrderedQty()).isEqualByComparingTo(gift);assertThat(actual.getRemainingQty()).isEqualByComparingTo(remainingPaid);assertThat(actual.getRemainingGiftQty()).isEqualByComparingTo(remainingGift);assertThat(actual.getPhysicalRemainingQty()).isEqualByComparingTo(new BigDecimal(remainingPaid).add(new BigDecimal(remainingGift)));assertThat(closed(s)).isEqualTo(closed);
  assertThat(db.queryForObject("SELECT COALESCE(SUM(open_qty),0) FROM v_procurement_decomposition_tasks WHERE action_doc_type='PURCHASE_REQUEST' AND action_item_id=?",BigDecimal.class,s.item())).isEqualByComparingTo(actual.getPhysicalRemainingQty());
 }
}
