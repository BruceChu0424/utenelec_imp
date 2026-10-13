package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.order.dto.*;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.request.dto.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real physical FIFO -> financial commitment -> counters -> symmetric unapproval. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
 "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
 "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", // gitleaks:allow shared synthetic FullChain cryptographic fixture.
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow shared synthetic FullChain cryptographic fixture.
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class PurchaseGiftSourceAllocationEndToEndTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
 @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;
 @Autowired PurchaseRequestService requests;@Autowired PurchaseOrderService orders;
 @Autowired ProcurementFinanceApprovalService finance;@Autowired DocumentUnapprovalService unapproval;
 private FullChainEndToEndTest harness;
 @BeforeEach void setup(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
 @AfterEach void clear(){SecurityContextHolder.clearContext();}
 private record Source(UUID requestId,UUID itemId){}
 private record Fixture(FullChainEndToEndTest.World world,UUID reviewer,Source first,Source second){}

 @Test void mixedGiftResidualAndPaidSourceKeepBothSourceIdentitiesThroughPendingApprovalAndUnapproval(){
  var f=fixture("mixed-source","1","0");payOriginalTen(f,f.first());
  assertAvailable(f.first(),"1");assertAvailable(f.second(),"10");
  var order=create(f,List.of(line(f,"10","1")));
  assertPhysicalShares(order.getId(),Map.of(f.first().itemId(),n("1"),f.second().itemId(),n("10")),"10","1");
  submit(f,order.getId());assertPending(f.first(),"1");assertPending(f.second(),"10");
  assertAvailable(f.first(),"0");assertAvailable(f.second(),"0");
  assertThat(requests.detail(f.first().requestId()).isClosed()).isFalse();
  assertThatThrownBy(()->requests.decompositionPreview(List.of(f.first().itemId(),f.second().itemId()))).isInstanceOf(ApiException.class);
  approve(f,order.getId());assertAvailable(f.first(),"0");assertAvailable(f.second(),"0");
  assertThat(requests.detail(f.first().requestId()).isClosed()).isTrue();assertThat(requests.detail(f.second().requestId()).isClosed()).isTrue();
  var command=new DocumentUnapprovalService.UnapproveRequest("mixed-source-undo-"+order.getId(),"逐来源恢复实物，不把赠品挪到另一个申请");
  var draft=(OrderDetail)unapproval.unapprove("purchaseOrder",order.getId(),command);
  assertAvailable(f.first(),"1");assertAvailable(f.second(),"10");assertPending(f.first(),"0");assertPending(f.second(),"0");
  assertPhysicalShares(draft.getId(),Map.of(f.first().itemId(),n("1"),f.second().itemId(),n("10")),"10","1");
  assertThat(((OrderDetail)unapproval.unapprove("purchaseOrder",order.getId(),command)).getId()).isEqualTo(draft.getId());
  assertAvailable(f.first(),"1");assertAvailable(f.second(),"10");
  submit(f,draft.getId());approve(f,draft.getId());assertAvailable(f.first(),"0");assertAvailable(f.second(),"0");
 }

 @Test void mergedAllFreeResidualsRetainBothZeroPaidSourcesAndReverseExactlyTheirOriginalShares(){
  var f=fixture("free-sources","1","2");payOriginalTen(f,f.first());payOriginalTen(f,f.second());
  var order=create(f,List.of(line(f,"0","3")));
  assertPhysicalShares(order.getId(),Map.of(f.first().itemId(),n("1"),f.second().itemId(),n("2")),"0","3");
  assertThat(db.queryForList("SELECT alloc_qty FROM purchase_order_item_sources source JOIN purchase_order_items item ON item.id=source.order_item_id WHERE item.order_id=?",BigDecimal.class,order.getId())).allSatisfy(value->assertThat(value).isZero());
  submit(f,order.getId());assertPending(f.first(),"1");assertPending(f.second(),"2");approve(f,order.getId());
  assertAvailable(f.first(),"0");assertAvailable(f.second(),"0");assertThat(orders.detail(order.getId()).getTotalOriginal()).isZero();
  var draft=(OrderDetail)unapproval.unapprove("purchaseOrder",order.getId(),new DocumentUnapprovalService.UnapproveRequest("all-free-undo-"+order.getId(),"两个来源免费实物各自恢复"));
  assertAvailable(f.first(),"1");assertAvailable(f.second(),"2");assertPhysicalShares(draft.getId(),Map.of(f.first().itemId(),n("1"),f.second().itemId(),n("2")),"0","3");
 }

 @Test void multipleLinesConsumeTheSameRequestsPhysicalFifoBudgetOnceWithinTheOrder(){
  var f=fixture("multiple-lines","1","2");payOriginalTen(f,f.first());payOriginalTen(f,f.second());
  var order=create(f,List.of(line(f,"0","1"),line(f,"0","1"),line(f,"0","1")));
  assertThat(order.getItems()).hasSize(3);
  assertThat(db.queryForList("SELECT source.request_item_id FROM purchase_order_item_sources source JOIN purchase_order_items item ON item.id=source.order_item_id WHERE item.order_id=? ORDER BY item.line_no,source.line_no",UUID.class,order.getId()))
      .containsExactly(f.first().itemId(),f.second().itemId(),f.second().itemId());
  assertPhysicalShares(order.getId(),Map.of(f.first().itemId(),n("1"),f.second().itemId(),n("2")),"0","3");
  submit(f,order.getId());approve(f,order.getId());assertAvailable(f.first(),"0");assertAvailable(f.second(),"0");
  orders.reverse(order.getId());assertAvailable(f.first(),"1");assertAvailable(f.second(),"2");
 }

 @Test void pendingGiftSharesReduceTheNextPhysicalFifoBudgetBeforeAnyApprovalCounterChanges(){
  var f=fixture("pending-gifts","2","2");payOriginalTen(f,f.first());payOriginalTen(f,f.second());
  var first=line(f,"0","1");first.setRequestItemIds(null);first.setRequestItemId(f.first().itemId());
  var pending=create(f,List.of(first));submit(f,pending.getId());assertPending(f.first(),"1");assertAvailable(f.first(),"1");
  var next=create(f,List.of(line(f,"0","3")));
  assertPhysicalShares(next.getId(),Map.of(f.first().itemId(),n("1"),f.second().itemId(),n("2")),"0","3");
  // An unsubmitted draft consumes neither counters nor the financial pending bucket.
  assertPending(f.first(),"1");assertPending(f.second(),"0");assertAvailable(f.first(),"1");assertAvailable(f.second(),"2");
  orders.cancel(pending.getId());assertPending(f.first(),"0");assertAvailable(f.first(),"2");
 }

 private Fixture fixture(String label,String firstGift,String secondGift){
  var w=harness.seedWorld(label+"-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
  UUID reviewer=harness.createUserWithPerms(w,"source-review-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");
  harness.loginAs(w.superAdminUserId());
  return new Fixture(w,reviewer,source(w,firstGift,1),source(w,secondGift,2));
 }
 private Source source(FullChainEndToEndTest.World w,String gift,int dateOrder){
  var request=new RequestSaveRequest();request.setBillDate(BusinessTime.today());request.setNeedDate(BusinessTime.today().plusDays(dateOrder));request.setWarehouseId(w.warehouseId());
  var item=new RequestItemLine();item.setGoodsId(w.goodsD());item.setUnitId(w.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(n("10"));item.setGiftQty(n(gift));request.setItems(List.of(item));
  var created=requests.create(request);requests.approve(created.getId());return new Source(created.getId(),created.getItems().getFirst().getId());
 }
 private void payOriginalTen(Fixture f,Source source){
  var line=line(f,"10","0");line.setRequestItemIds(null);line.setRequestItemId(source.itemId());
  var order=create(f,List.of(line));submit(f,order.getId());approve(f,order.getId());
 }
 private OrderItemLine line(Fixture f,String paid,String gift){
  var line=new OrderItemLine();line.setGoodsId(f.world().goodsD());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(n(paid));line.setGiftQty(n(gift));line.setPrice(n(paid).signum()==0?BigDecimal.ZERO:n("50"));
  // Input order deliberately opposes due-date FIFO; stable source discovery owns ordering.
  line.setRequestItemIds(List.of(f.second().itemId(),f.first().itemId()));return line;
 }
 private OrderDetail create(Fixture f,List<OrderItemLine> lines){
  harness.loginAs(f.world().superAdminUserId());var request=new OrderSaveRequest();request.setBillDate(BusinessTime.today());request.setWarehouseId(f.world().warehouseId());request.setSupplierId(f.world().supplierId());
  request.setCurrencyId(db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class));request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
  request.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));request.setItems(lines);return orders.create(request);
 }
 private void submit(Fixture f,UUID order){harness.loginAs(f.world().superAdminUserId());finance.submit("PURCHASE",order);}
 private void approve(Fixture f,UUID order){harness.loginAs(f.reviewer());harness.approvePendingFinance("PURCHASE",order);harness.loginAs(f.world().superAdminUserId());}
 private void assertAvailable(Source source,String quantity){assertThat(requests.detail(source.requestId()).getItems().getFirst().getPhysicalRemainingQty()).isEqualByComparingTo(quantity);}
 private void assertPending(Source source,String quantity){assertThat(requests.detail(source.requestId()).getItems().getFirst().getPhysicalPendingQty()).isEqualByComparingTo(quantity);}
 private void assertPhysicalShares(UUID order,Map<UUID,BigDecimal> expected,String paid,String gift){
  var actual=new LinkedHashMap<UUID,BigDecimal>();
  for(var row:db.queryForList("SELECT source.request_item_id,SUM(source.alloc_qty+source.allocated_gift_qty) physical FROM purchase_order_item_sources source JOIN purchase_order_items item ON item.id=source.order_item_id WHERE item.order_id=? GROUP BY source.request_item_id",order))actual.put((UUID)row.get("request_item_id"),(BigDecimal)row.get("physical"));
  assertThat(actual.keySet()).containsExactlyInAnyOrderElementsOf(expected.keySet());expected.forEach((id,quantity)->assertThat(actual.get(id)).isEqualByComparingTo(quantity));
  assertThat(db.queryForObject("SELECT SUM(source.alloc_qty) FROM purchase_order_item_sources source JOIN purchase_order_items item ON item.id=source.order_item_id WHERE item.order_id=?",BigDecimal.class,order)).isEqualByComparingTo(paid);
  assertThat(db.queryForObject("SELECT SUM(source.allocated_gift_qty) FROM purchase_order_item_sources source JOIN purchase_order_items item ON item.id=source.order_item_id WHERE item.order_id=?",BigDecimal.class,order)).isEqualByComparingTo(gift);
 }
 private static BigDecimal n(String value){return new BigDecimal(value);}
}
