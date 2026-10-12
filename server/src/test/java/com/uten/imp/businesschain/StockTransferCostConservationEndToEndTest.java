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
  List<String> permissions=new ArrayList<>(List.of("stock_doc:view","stock_doc:approve"));if(finance)permissions.add("stock:count:finance_review");if(edit)permissions.add("stock_doc:edit");
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
  line.setQty(new BigDecimal(quantity));if(count!=null)line.setCountQty(new BigDecimal(count));request.setItems(List.of(line));return request;
 }
 private void conflict(org.assertj.core.api.ThrowableAssert.ThrowingCallable command){assertThatThrownBy(command).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));}
 private BigDecimal number(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
 private BigDecimal quantity(FullChainEndToEndTest.World w){return number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",w.goodsD());}
 private BigDecimal value(FullChainEndToEndTest.World w){return number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id=?",w.goodsD());}
}
