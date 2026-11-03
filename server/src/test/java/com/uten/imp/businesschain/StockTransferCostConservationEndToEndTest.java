package com.uten.imp.businesschain;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.*;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.DynamicPropertyRegistry;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
 "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
 "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
 "uten.jwt.secret=stock-review-test-isolated-jwt-0123456789-abcdef",
 "uten.crypto.pgp-master-key=stock-review-test-isolated-pgp-0123456789-abcdef",
 "uten.crypto.hmac-key=stock-review-test-isolated-hmac-0123456789-abcdef",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class StockTransferCostConservationEndToEndTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
 @Autowired com.uten.imp.application.port.InventoryValuationPort values;
 @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;@Autowired StockDocService stock;@Autowired DocumentUnapprovalService unapproval;
 private FullChainEndToEndTest harness;
 @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
 @AfterEach void clear(){SecurityContextHolder.clearContext();}

 @Test void movingFullyReservedStockPreservesEveryClaimAndTheGlobalBudget(){
  var w=world();UUID b=warehouse();sameMain(w,b);db.update("UPDATE goods SET min_qty=0 WHERE id=?",w.goodsD());
  stock.approve(create(w,"OTHER_IN","20","200").getId());
  UUID order=harness.createApprovedOrder(w,w.goodsD(),"20","100");
  db.update("UPDATE stock_reservations SET warehouse_id=? WHERE order_item_id IN (SELECT id FROM sales_order_items WHERE order_id=?)",w.warehouseId(),order);
  String before=claims(w);assertThat(before).doesNotContain("[]");
  db.update("UPDATE goods SET min_qty=100 WHERE id=?",w.goodsD());
  BigDecimal budget=number("SELECT fn_stock_global_usable(?,NULL)",w.goodsD());
  var doc=transfer(w,b,"20");stock.approve(doc.getId());
  balances(w,b,"0","0","20","200");assertThat(claims(w)).isEqualTo(before);
  assertThat(number("SELECT fn_stock_global_usable(?,NULL)",w.goodsD())).isEqualByComparingTo(budget);
  assertThat(number("SELECT fn_stock_storage_movable(?,?,NULL,NULL,FALSE)",b,w.goodsD())).isZero();
  assertThatThrownBy(()->stock.approve(doc.getId())).isInstanceOf(ApiException.class);
  balances(w,b,"0","0","20","200");assertThat(claims(w)).isEqualTo(before);
  unapproval.unapprove("stockDocument",doc.getId(),new DocumentUnapprovalService.UnapproveRequest("locked-transfer-"+doc.getId(),"保留锁定调回原仓"));
  balances(w,b,"20","200","0","0");assertThat(claims(w)).isEqualTo(before);
 }

 @Test void partialMovesKeepSafetyOnceAndInsufficientPhysicalStockRollsBackBothLegs(){
  var w=world();UUID b=warehouse();sameMain(w,b);db.update("UPDATE goods SET min_qty=10 WHERE id=?",w.goodsD());
  stock.approve(create(w,"OTHER_IN","20","200").getId());
  assertThat(number("SELECT fn_stock_global_usable(?,NULL)",w.goodsD())).isEqualByComparingTo("10");
  stock.approve(transfer(w,b,"10").getId());balances(w,b,"10","100","10","100");
  assertThat(number("SELECT fn_stock_global_usable(?,NULL)",w.goodsD())).isEqualByComparingTo("10");
  var tooMuch=transfer(w,b,"11");
  assertThatThrownBy(()->stock.approve(tooMuch.getId())).isInstanceOf(ApiException.class);
  balances(w,b,"10","100","10","100");
  assertThat(number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",tooMuch.getId())).isZero();
 }

 private String claims(FullChainEndToEndTest.World w){return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb)::text FROM stock_reservations r WHERE goods_id=?",String.class,w.goodsD());}

 @Test void relocatedOrderKeepsItsClaimAndShipsFromTheDestinationWarehouse(){
  var w=world();UUID b=warehouse();sameMain(w,b);db.update("UPDATE goods SET min_qty=0 WHERE id=?",w.goodsD());
  stock.approve(create(w,"OTHER_IN","20","200").getId());
  UUID order=harness.createApprovedOrder(w,w.goodsD(),"20","100");
  UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
  db.update("UPDATE stock_reservations SET warehouse_id=? WHERE order_item_id=?",w.warehouseId(),orderItem);
  String before=claims(w);stock.approve(transfer(w,b,"20").getId());assertThat(claims(w)).isEqualTo(before);
  UUID claim=db.queryForObject("SELECT id FROM stock_reservations WHERE order_item_id=?",UUID.class,orderItem);
  assertThat(number("SELECT fn_stock_claim_open_at(?,?)",claim,w.warehouseId())).isZero();
  assertThat(number("SELECT fn_stock_claim_open_at(?,?)",claim,b)).isEqualByComparingTo("20");
  var shipments=beans.getBean(com.uten.imp.features.sales.shipment.SalesShipmentService.class);
  var warehouse=beans.getBean(com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundProjectionService.class);
  com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest request=org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness,"shipmentRequest",w,orderItem,w.goodsD(),"20");
  request.setWarehouseId(null);var shipment=shipments.create(request);
  org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness,"confirmShipmentFinance",shipment.getId());
  assertThat(warehouse.detail(shipment.getId()).lines().getFirst().warehouseChoices()).anyMatch(choice->choice.warehouseId().equals(b)&&choice.canFulfill());
  var outbound=new com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest();outbound.setTargetStatus("SHIPPED");outbound.setWarehouseId(b);
  outbound.setStockPlaces(List.of(new com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest.StockPlace(shipment.getItems().getFirst().getId(),"B-01")));
  warehouse.transition(shipment.getId(),outbound);
  assertThat(number("SELECT consumed_qty FROM stock_reservations WHERE id=?",claim)).isEqualByComparingTo("20");
  assertThat(number("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",b,w.goodsD())).isZero();
  assertThat(number("SELECT fn_stock_claim_open_at(?,?)",claim,b)).isZero();
  assertThatThrownBy(()->warehouse.transition(shipment.getId(),outbound)).isInstanceOf(ApiException.class);
 }

 private void sameMain(FullChainEndToEndTest.World w,UUID b){UUID root=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,?,?,'使用',FALSE)",root,"ROOT-"+root,"移仓共同主仓");db.update("UPDATE warehouses SET parent_id=? WHERE id IN (?,?)",root,w.warehouseId(),b);}

 @Test void actualMadeFinishedGoodsCanMoveFromHardwareToFinishedWarehouseAndShipWithoutReleasingTheOrder(){
  var w=world();UUID target=warehouse();sameMain(w,target);
  db.update("UPDATE warehouses SET name='五金仓库' WHERE id=?",w.warehouseId());
  db.update("UPDATE warehouses SET name='成品仓库' WHERE id=?",target);
  var production=harness.produceFinishedFromOpeningInputs(w,w.goodsA(),"20","20");
  UUID orderItem=production.orderItemId(),inbound=production.finishedInId();
  org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness,"drainCosts",w);
  assertThat(db.queryForObject("SELECT doc_type FROM stock_documents WHERE id=?",String.class,inbound)).isEqualTo("FINISHED_IN");
  assertThat(number("SELECT SUM(qty) FROM stock_movements WHERE source_doc_id=? AND direction=1 AND movement_type=13",inbound)).isEqualByComparingTo("20");
  moveAndShipFinished(w,w.goodsA(),orderItem,target,"20","PRODUCTION_INBOUND");
  assertThat(number("SELECT produced_qty FROM sales_order_items WHERE id=?",orderItem)).isEqualByComparingTo("20");
 }

 @Test void actualSubcontractFinishedRootSupplyKeepsItsOriginalReceiptAndOrderWhenMovedToFinishedWarehouse(){
  var target=new java.util.concurrent.atomic.AtomicReference<UUID>();
  harness.subcontractRootStockFixture(w->{UUID id=warehouse();sameMain(w,id);target.set(id);
   db.update("UPDATE warehouses SET name='五金仓库' WHERE id=?",w.warehouseId());db.update("UPDATE warehouses SET name='成品仓库' WHERE id=?",id);
  },source->{
   harness.settleRootStockCosts(source);
   String roots=db.queryForObject("SELECT jsonb_agg(to_jsonb(event) ORDER BY event.id)::text FROM preplan_root_output_events event WHERE analysis_item_id=?",String.class,source.analysisItem());
   assertThat(db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,source.goods())).isEqualTo("委外");
   assertThat(number("SELECT SUM(qty) FROM stock_movements WHERE source_doc_id=? AND movement_type=17 AND direction=1",source.receipt())).isEqualByComparingTo("10");
   moveAndShipFinished(source.world(),source.goods(),source.salesOrderItem(),target.get(),"10","ROOT_SUPPLY_INBOUND");
   assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(event) ORDER BY event.id)::text FROM preplan_root_output_events event WHERE analysis_item_id=?",String.class,source.analysisItem())).isEqualTo(roots);
   assertThat(number("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",source.analysisItem())).isEqualByComparingTo("10");
   assertThat(db.queryForObject("SELECT warehouse_id FROM subcontract_receipts WHERE id=?",UUID.class,source.receipt())).isEqualTo(source.world().warehouseId());
  });
 }

 @Test void actualHistoricalStoppedSubcontractFinishedStockCanMoveWhileCostIsPendingWithoutResumingOrReleasing(){
  var target=new java.util.concurrent.atomic.AtomicReference<UUID>();
  harness.subcontractRootStockFixture(w->{UUID id=warehouse();sameMain(w,id);target.set(id);},source->{
   assertThat(number("SELECT node.pending_parents FROM stock_value_pools pool JOIN stock_value_nodes node ON node.id=pool.head_node_id WHERE pool.warehouse_id=? AND pool.goods_id=?",source.world().warehouseId(),source.goods())).isPositive();
   UUID order=db.queryForObject("SELECT order_id FROM sales_order_items WHERE id=?",UUID.class,source.salesOrderItem());
   // Reconstruct the observed historical row. Current cancel has release semantics;
   // this fixture must not pretend it produced the persisted stopped+reserved state.
   db.update("UPDATE sales_orders SET is_stopped=TRUE WHERE id=?",order);
   UUID claim=moveFinishedPreservingClaim(source.world(),source.goods(),source.salesOrderItem(),target.get(),"10","ROOT_SUPPLY_INBOUND");
   assertThat(db.queryForObject("SELECT is_stopped FROM sales_orders WHERE id=?",Boolean.class,order)).isTrue();
   assertThat(number("SELECT node.pending_parents FROM stock_value_pools pool JOIN stock_value_nodes node ON node.id=pool.head_node_id WHERE pool.warehouse_id=? AND pool.goods_id=?",target.get(),source.goods())).isPositive();
   var shipments=beans.getBean(com.uten.imp.features.sales.shipment.SalesShipmentService.class);
   com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest sale=org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness,"shipmentRequest",source.world(),source.salesOrderItem(),source.goods(),"10");
   sale.setWarehouseId(target.get());assertThatThrownBy(()->shipments.create(sale)).isInstanceOf(ApiException.class);
   assertThat(number("SELECT consumed_qty+released_qty FROM stock_reservations WHERE id=?",claim)).isZero();
   assertThat(number("SELECT reserved_qty FROM sales_order_items WHERE id=?",source.salesOrderItem())).isEqualByComparingTo("10");
   harness.settleRootStockCosts(source);
   assertThat(number("SELECT node.pending_parents FROM stock_value_pools pool JOIN stock_value_nodes node ON node.id=pool.head_node_id WHERE pool.warehouse_id=? AND pool.goods_id=?",target.get(),source.goods())).isZero();
   assertThat(number("SELECT fn_stock_claim_open_at(?,?)",claim,target.get())).isEqualByComparingTo("10");
  });
 }

 private UUID moveFinishedPreservingClaim(FullChainEndToEndTest.World w,UUID goods,UUID orderItem,UUID target,String qty,String reservationSource){
  UUID claim=db.queryForObject("SELECT id FROM stock_reservations WHERE order_item_id=? AND status=0 AND NOT is_deleted",UUID.class,orderItem);
  String before=db.queryForObject("SELECT to_jsonb(r)::text FROM stock_reservations r WHERE id=?",String.class,claim);
  assertThat(db.queryForObject("SELECT source_doc_type FROM stock_reservations WHERE id=?",String.class,claim)).isEqualTo(reservationSource);
  var request=new StockDocSaveRequest();request.setDocType("OTHER_OUT");request.setBillDate(BusinessTime.today());request.setWarehouseId(w.warehouseId());
  var line=new StockDocItemLine();line.setGoodsId(goods);line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));request.setItems(List.of(line));
  UUID rejected=stock.create(request).getId();assertThatThrownBy(()->stock.approve(rejected)).isInstanceOf(ApiException.class);
  assertThat(number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",rejected)).isZero();
  request.setDocType("TRANSFER");request.setToWarehouseId(target);UUID document=stock.create(request).getId();stock.approve(document);
  assertThat(db.queryForObject("SELECT to_jsonb(r)::text FROM stock_reservations r WHERE id=?",String.class,claim)).isEqualTo(before);
  assertThat(number("SELECT fn_stock_claim_open_at(?,?)",claim,target)).isEqualByComparingTo(qty);
  assertThat(number("SELECT qty FROM stock_balances WHERE goods_id=? AND warehouse_id=?",goods,w.warehouseId())).isZero();
  assertThat(number("SELECT qty FROM stock_balances WHERE goods_id=? AND warehouse_id=?",goods,target)).isEqualByComparingTo(qty);
  assertThat(db.queryForObject("SELECT owning_warehouse_id FROM goods WHERE id=?",UUID.class,goods)).isEqualTo(target);
  return claim;
 }

 private void moveAndShipFinished(FullChainEndToEndTest.World w,UUID goods,UUID orderItem,UUID target,String qty,String reservationSource){
  UUID claim=moveFinishedPreservingClaim(w,goods,orderItem,target,qty,reservationSource);
  var shipments=beans.getBean(com.uten.imp.features.sales.shipment.SalesShipmentService.class);
  var warehouse=beans.getBean(com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundProjectionService.class);
  com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest sale=org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness,"shipmentRequest",w,orderItem,goods,qty);
  sale.setWarehouseId(null);var shipment=shipments.create(sale);org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness,"confirmShipmentFinance",shipment.getId());
  assertThat(warehouse.detail(shipment.getId()).lines().getFirst().warehouseChoices()).anyMatch(choice->choice.warehouseId().equals(target)&&choice.canFulfill());
  var outbound=new com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest();outbound.setTargetStatus("SHIPPED");outbound.setWarehouseId(target);
  outbound.setStockPlaces(List.of(new com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest.StockPlace(shipment.getItems().getFirst().getId(),"成品库位")));
  warehouse.transition(shipment.getId(),outbound);
  assertThat(number("SELECT shipped_qty FROM sales_order_items WHERE id=?",orderItem)).isEqualByComparingTo(qty);
  assertThat(number("SELECT consumed_qty FROM stock_reservations WHERE id=?",claim)).isEqualByComparingTo(qty);
  assertThat(number("SELECT qty FROM stock_balances WHERE goods_id=? AND warehouse_id=?",goods,target)).isZero();
 }

 @Test void concurrentDuplicateApprovalMovesPhysicalStockAndClaimsOnlyOnce()throws Exception{
  var w=world();UUID b=warehouse();sameMain(w,b);db.update("UPDATE goods SET min_qty=0 WHERE id=?",w.goodsD());
  stock.approve(create(w,"OTHER_IN","20","200").getId());UUID order=harness.createApprovedOrder(w,w.goodsD(),"20","100");
  db.update("UPDATE stock_reservations SET warehouse_id=? WHERE order_item_id IN(SELECT id FROM sales_order_items WHERE order_id=?)",w.warehouseId(),order);
  String before=claims(w);UUID document=transfer(w,b,"20").getId();
  try(var pool=java.util.concurrent.Executors.newFixedThreadPool(2)){
   var start=new java.util.concurrent.CountDownLatch(1);List<java.util.concurrent.Future<Boolean>> results=new ArrayList<>();
   for(int i=0;i<2;i++)results.add(pool.submit(()->{start.await();harness.loginAs(w.superAdminUserId());try{stock.approve(document);return true;}catch(ApiException rejected){return false;}finally{SecurityContextHolder.clearContext();}}));
   start.countDown();int successes=0;for(var result:results)if(result.get(30,java.util.concurrent.TimeUnit.SECONDS))successes++;
   assertThat(successes).isEqualTo(1);
  }
  balances(w,b,"0","0","20","200");assertThat(claims(w)).isEqualTo(before);
  assertThat(number("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",document)).isEqualByComparingTo("2");
  assertThat(number("SELECT SUM(qty) FROM stock_reservation_storage_events WHERE document_id=? AND event_type='TRANSFER'",document)).isEqualByComparingTo("20");
 }

 @Test void untouchedTransferReversesOriginalFiftyAcrossWarehousesAndReplayAndNewApprovalAreOnceOnly(){
  var w=world();UUID b=warehouse();stock.approve(create(w,"OTHER_IN","10","100").getId());
  var transfer=transfer(w,b,"5");stock.approve(transfer.getId());balances(w,b,"5","50","5","50");
  String fingerprint=probe(w,b,transfer);assertThat(fingerprint).hasSize(64);assertThat(probe(w,b,transfer)).isEqualTo(fingerprint);
  String key="transfer-return-"+transfer.getId();var request=new DocumentUnapprovalService.UnapproveRequest(key,"两仓按原50反向");
  var draft=(StockDocDetail)unapproval.unapprove("stockDocument",transfer.getId(),request);balances(w,b,"10","100","0","0");
  var replay=(StockDocDetail)unapproval.unapprove("stockDocument",transfer.getId(),new DocumentUnapprovalService.UnapproveRequest(key+"-retry","换键重试仍同一代草稿"));
  assertThat(replay.getId()).isEqualTo(draft.getId());balances(w,b,"10","100","0","0");
  stock.approve(draft.getId());balances(w,b,"5","50","5","50");
 }
 @Test void laterMixedPriceDestinationReceiptBlocksTransferUntilItsOwnUnusedSourceIsReversed(){
  var w=world();UUID b=warehouse();stock.approve(create(w,"OTHER_IN","10","100").getId());var transfer=transfer(w,b,"5");stock.approve(transfer.getId());
  var input=createInput(w,b,"5","150");stock.approve(input.getId());balances(w,b,"5","50","10","200");
  conflict(()->probe(w,b,transfer));
  conflict(()->unapproval.unapprove("stockDocument",transfer.getId(),new DocumentUnapprovalService.UnapproveRequest("transfer-mixed-"+transfer.getId(),"不能按混价100退原调入50")));
  balances(w,b,"5","50","10","200");assertThat(stock.detail(transfer.getId()).getStatus()).isEqualTo((short)1);
  unapproval.unapprove("stockDocument",input.getId(),new DocumentUnapprovalService.UnapproveRequest("remove-newer-"+input.getId(),"先按后进先出撤回后入150"));balances(w,b,"5","50","5","50");
  unapproval.unapprove("stockDocument",transfer.getId(),new DocumentUnapprovalService.UnapproveRequest("transfer-mixed-retry-"+transfer.getId(),"后入已撤，现可准确退原调入50"));balances(w,b,"10","100","0","0");
 }
 @Test void consumedDestinationCannotReverseTransferEvenWhenQuantityStillCoversItsOriginalFive(){
  var w=world();UUID b=warehouse();stock.approve(create(w,"OTHER_IN","10","100").getId());var transfer=transfer(w,b,"5");stock.approve(transfer.getId());stock.approve(createInput(w,b,"5","150").getId());
  var out=new StockDocSaveRequest();out.setDocType("OTHER_OUT");out.setBillDate(BusinessTime.today());out.setWarehouseId(b);var line=new StockDocItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ONE);line.setWarehouseId(b);out.setItems(List.of(line));stock.approve(stock.create(out).getId());
  balances(w,b,"5","50","9","180");BigDecimal count=number("SELECT COUNT(*) FROM stock_value_events");
  conflict(()->probe(w,b,transfer));
  conflict(()->unapproval.unapprove("stockDocument",transfer.getId(),new DocumentUnapprovalService.UnapproveRequest("transfer-consumed-"+transfer.getId(),"原B批已承接出库，不能借足量库存抹来源")));
  balances(w,b,"5","50","9","180");assertThat(number("SELECT COUNT(*) FROM stock_value_events")).isEqualByComparingTo(count);
 }
 @Test void destinationPriorDifferentCostRemainsOneHundredFiftyWhileOriginalTransferReturnsFifty(){
  var w=world();UUID b=warehouse();stock.approve(create(w,"OTHER_IN","10","100").getId());stock.approve(createInput(w,b,"5","150").getId());
  var transfer=transfer(w,b,"5");stock.approve(transfer.getId());balances(w,b,"5","50","10","200");assertThat(probe(w,b,transfer)).hasSize(64);
  unapproval.unapprove("stockDocument",transfer.getId(),new DocumentUnapprovalService.UnapproveRequest("transfer-prior-"+transfer.getId(),"B原有150不能按混价误退100"));balances(w,b,"10","100","5","150");
 }
 @Test void legacyStoredNegativeGiftCannotPost(){
  var w=world();var old=create(w,"OTHER_IN","1",null);
  // Reconstruct the actually observed R5 accepted malformed draft; normal current API already refuses this input.
  db.update("UPDATE stock_document_items SET gift_qty=-1 WHERE doc_id=?",old.getId());
  BigDecimal eventCount=number("SELECT COUNT(*) FROM stock_value_events");
  assertThatThrownBy(()->stock.approve(old.getId())).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
  assertThat(quantity(w)).isZero();assertThat(value(w)).isZero();assertThat(stock.detail(old.getId()).getStatus()).isZero();
  assertThat(number("SELECT qty FROM stock_document_items WHERE doc_id=?",old.getId())).isEqualByComparingTo("1");
  assertThat(number("SELECT gift_qty FROM stock_document_items WHERE doc_id=?",old.getId())).isEqualByComparingTo("-1");
  assertThat(number("SELECT COUNT(*) FROM stock_value_events")).isEqualByComparingTo(eventCount);
 }
 private String probe(FullChainEndToEndTest.World w,UUID b,StockDocDetail doc){
  UUID in=db.queryForObject("SELECT id FROM stock_movements WHERE source_doc_id=? AND movement_type=7 AND direction=1",UUID.class,doc.getId());
  UUID out=db.queryForObject("SELECT id FROM stock_movements WHERE source_doc_id=? AND movement_type=8 AND direction=-1",UUID.class,doc.getId());
  var target=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(b,w.goodsD(),null);var source=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(w.warehouseId(),w.goodsD(),null);
  return values.requireTransfersReversible(List.of(new com.uten.imp.application.port.InventoryValuationPort.TransferWithdrawalSource(target,in,source,out)));
 }

 @Test void historicalPostedUnpricedZeroSourceCanBeRemovedWithoutErasingPredecessorValueOrPretendingItWasFree(){
  var w=world();stock.approve(create(w,"OTHER_IN","10","100").getId());var old=create(w,"OTHER_IN","1",null);stock.approve(old.getId());
  // Reconstruct the old accepted malformed annotation while preserving its actual already-posted movement/source facts.
  db.update("UPDATE stock_document_items SET gift_qty=-1 WHERE doc_id=?",old.getId());
  assertThat(quantity(w)).isEqualByComparingTo("11");assertThat(value(w)).isEqualByComparingTo("100");
  assertThat(number("SELECT COUNT(*) FROM stock_value_events event JOIN stock_value_nodes source ON source.id=event.result_node_id WHERE event.source_doc_id=? AND event.operation='RECEIVE' AND NOT source.source_final",old.getId())).isEqualByComparingTo("1");
  var draft=(StockDocDetail)unapproval.unapprove("stockDocument",old.getId(),new DocumentUnapprovalService.UnapproveRequest("legacy-zero-"+old.getId(),"反审镜像真实入库1和已知成本0，不把未知当成最终免费"));
  assertThat(quantity(w)).isEqualByComparingTo("10");assertThat(value(w)).isEqualByComparingTo("100");
  assertThat(number("SELECT COUNT(*) FROM stock_value_events event WHERE event.source_doc_id=? AND event.operation='POSITION_STORE_REVERSE' AND event.result_state='PENDING' AND event.known_value_local=0",old.getId())).isEqualByComparingTo("1");
  assertThat(number("SELECT COUNT(*) FROM stock_value_postings posting JOIN stock_value_events event ON event.id=posting.event_id WHERE event.source_doc_id=? AND event.operation='POSITION_STORE_REVERSE'",old.getId())).isZero();
  assertThatThrownBy(()->stock.approve(draft.getId())).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
  assertThat(quantity(w)).isEqualByComparingTo("10");assertThat(value(w)).isEqualByComparingTo("100");
 }
 private UUID warehouse(){UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,?,?,'使用',TRUE)",id,"TRANSFER-"+id,"调拨独立实物仓");return id;}
 private StockDocDetail transfer(FullChainEndToEndTest.World w,UUID b,String qty){var req=new StockDocSaveRequest();req.setDocType("TRANSFER");req.setBillDate(BusinessTime.today());req.setWarehouseId(w.warehouseId());req.setToWarehouseId(b);var line=new StockDocItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));req.setItems(List.of(line));return stock.create(req);}
 private StockDocDetail createInput(FullChainEndToEndTest.World w,UUID b,String qty,String cost){var req=new StockDocSaveRequest();req.setDocType("OTHER_IN");req.setBillDate(BusinessTime.today());req.setWarehouseId(b);var line=new StockDocItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setWarehouseId(b);line.setPrice(new BigDecimal(cost).divide(new BigDecimal(qty)));line.setAmountOriginal(new BigDecimal(cost));line.setAmountLocal(new BigDecimal(cost));req.setItems(List.of(line));return stock.create(req);}
 private void balances(FullChainEndToEndTest.World w,UUID b,String aq,String av,String bq,String bv){assertThat(amount(w.warehouseId(),w.goodsD(),"qty")).isEqualByComparingTo(aq);assertThat(amount(w.warehouseId(),w.goodsD(),"amount_local")).isEqualByComparingTo(av);assertThat(amount(b,w.goodsD(),"qty")).isEqualByComparingTo(bq);assertThat(amount(b,w.goodsD(),"amount_local")).isEqualByComparingTo(bv);}
 private BigDecimal amount(UUID warehouse,UUID goods,String column){return number("SELECT COALESCE(SUM("+column+"),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",warehouse,goods);}
 private FullChainEndToEndTest.World world(){var w=harness.seedWorld("stock-review-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());return w;}
 private UUID reviewer(FullChainEndToEndTest.World w,boolean finance,boolean edit){
  List<String> permissions=new ArrayList<>(List.of("stock_doc:view","stock_doc:approve"));if(finance){ permissions.add("stock:count:finance_review"); }if(edit){ permissions.add("stock_doc:edit"); }
  UUID user=harness.createUserWithPerms(w,"stock-reviewer-"+UUID.randomUUID(),permissions.toArray(String[]::new));
  db.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,'stock_doc',?)",user,w.employeeId());return user;
 }
 private StockDocDetail create(FullChainEndToEndTest.World w,String type,String quantity,String amount){
  var request=new StockDocSaveRequest();request.setDocType(type);request.setBillDate(BusinessTime.today());request.setWarehouseId(w.warehouseId());
  var line=new StockDocItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(quantity));
  if(amount!=null){line.setAmountOriginal(new BigDecimal(amount));line.setAmountLocal(new BigDecimal(amount));line.setPrice(new BigDecimal(amount).divide(new BigDecimal(quantity)));}
  request.setItems(List.of(line));return stock.create(request);
 }
 private StockDocDetail createCount(FullChainEndToEndTest.World w,String counted){
  var request=new StockDocSaveRequest();request.setDocType("CHECK");request.setBillDate(BusinessTime.today());request.setWarehouseId(w.warehouseId());
  var line=new StockDocItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ZERO);line.setCountQty(new BigDecimal(counted));request.setItems(List.of(line));return stock.create(request);
 }
 private StockDocSaveRequest input(StockDocDetail original,String quantity,String count){
  var request=new StockDocSaveRequest();request.setDocType(original.getDocType());request.setBillDate(original.getBillDate());request.setWarehouseId(original.getWarehouseId());
  request.setToWarehouseId(original.getToWarehouseId());request.setSupplierId(original.getSupplierId());request.setClientId(original.getClientId());request.setWorkerId(original.getWorkerId());
  request.setDepartmentId(original.getDepartmentId());request.setAssTeam(original.getAssTeam());request.setPlanNo(original.getPlanNo());request.setRemark("审核实物核改");
  var source=original.getItems().getFirst();var line=new StockDocItemLine();line.setSourceItemId(source.getId());line.setGoodsId(source.getGoodsId());line.setColorId(source.getColorId());line.setUnitId(source.getUnitId());line.setUnitRate(source.getUnitRate());
  line.setQty(new BigDecimal(quantity));if(count!=null){ line.setCountQty(new BigDecimal(count)); }request.setItems(List.of(line));return request;
 }
 private void conflict(org.assertj.core.api.ThrowableAssert.ThrowingCallable command){assertThatThrownBy(command).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));}
 private BigDecimal number(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
 private BigDecimal quantity(FullChainEndToEndTest.World w){return number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",w.goodsD());}
 private BigDecimal value(FullChainEndToEndTest.World w){return number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id=?",w.goodsD());}
}
