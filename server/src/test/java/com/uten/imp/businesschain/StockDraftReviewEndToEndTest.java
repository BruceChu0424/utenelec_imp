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
 "uten.bootstrap.admin-login=stock-review-regression","uten.bootstrap.admin-password=StockReviewRegression-1!"})
class StockDraftReviewEndToEndTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
 @Autowired com.uten.imp.application.port.InventoryValuationPort values;
 @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;@Autowired StockDocService stock;@Autowired DocumentUnapprovalService unapproval;
 private FullChainEndToEndTest harness;
 @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
 @AfterEach void clear(){SecurityContextHolder.clearContext();}

 @Test void approveOnlySharedReaderCanReviewQuantityWithoutTakingMakerRowIdentityOrClearingHiddenCost(){
  var w=world();var original=create(w,"OTHER_IN","2","50");UUID reviewer=reviewer(w,false,false);harness.loginAs(reviewer);
  assertThat(stock.detail(original.getId()).isCostMasked()).isTrue();
  assertThatThrownBy(()->stock.update(original.getId(),input(original,"3",null))).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
  var review=stock.reviewDraft(original.getId());var changed=stock.updateReviewed(original.getId(),input(original,"3",null),review.snapshot(),true);
  assertThat(changed.getMakerId()).isEqualTo(w.employeeId());assertThat(changed.getStatus()).isEqualTo((short)1);
  assertThat(changed.getItems().getFirst().getId()).isEqualTo(original.getItems().getFirst().getId());
  assertThat(number("SELECT amount_local FROM stock_document_items WHERE id=?",original.getItems().getFirst().getId())).isEqualByComparingTo("50");
  assertThat(quantity(w)).isEqualByComparingTo("3");assertThat(value(w)).isEqualByComparingTo("50");
 }
 @Test void makerRevisionMakesReviewSnapshotStaleWithoutAnyStockOrApprovalEffect(){
  var w=world();var original=create(w,"OTHER_IN","2",null);UUID reviewer=reviewer(w,false,false);harness.loginAs(reviewer);
  var review=stock.reviewDraft(original.getId());harness.loginAs(w.superAdminUserId());var owner=input(original,"2.5",null);owner.setRemark("制单员新修订");stock.update(original.getId(),owner);
  harness.loginAs(reviewer);conflict(()->stock.updateReviewed(original.getId(),input(original,"3",null),review.snapshot(),true));
  assertThat(number("SELECT qty FROM stock_document_items WHERE doc_id=?",original.getId())).isEqualByComparingTo("2.5");assertThat(quantity(w)).isZero();
  assertThat(stock.detail(original.getId()).getStatus()).isZero();
 }
 @Test void externalStockChangeMakesReviewSnapshotStaleEvenWhenDocumentInputsDidNotChange(){
  var w=world();var incoming=create(w,"OTHER_IN","5","50");stock.approve(incoming.getId());var original=create(w,"OTHER_OUT","1",null);
  UUID reviewer=reviewer(w,false,false);harness.loginAs(reviewer);var review=stock.reviewDraft(original.getId());
  harness.loginAs(w.superAdminUserId());stock.approve(create(w,"OTHER_IN","1","10").getId());harness.loginAs(reviewer);
  conflict(()->stock.updateReviewed(original.getId(),input(original,"2",null),review.snapshot(),true));
  assertThat(quantity(w)).isEqualByComparingTo("6");assertThat(value(w)).isEqualByComparingTo("60");assertThat(stock.detail(original.getId()).getStatus()).isZero();
 }
 @Test void amendedOutboundRefusesOldFingerprintAndApprovesOnlyItsNewQuantity(){
  var w=world();stock.approve(create(w,"OTHER_IN","5","50").getId());var original=create(w,"OTHER_OUT","1",null);
  UUID reviewer=reviewer(w,false,false);harness.loginAs(reviewer);var old=stock.reviewOutbound(original.getId());var review=stock.reviewDraft(original.getId());
  stock.updateReviewed(original.getId(),input(original,"2",null),review.snapshot(),false);
  harness.loginAs(w.superAdminUserId());
  conflict(()->stock.approveReviewed(original.getId(),new StockDocReviewedApproveRequest(old.reviewToken())));
  assertThat(quantity(w)).isEqualByComparingTo("5");harness.loginAs(reviewer);var latest=stock.reviewDraft(original.getId());
  stock.updateReviewed(original.getId(),input(original,"2",null),latest.snapshot(),true);
  assertThat(quantity(w)).isEqualByComparingTo("3");assertThat(value(w)).isEqualByComparingTo("30");
 }
 @Test void countNeedsFinancePrivilegeAndRecalculatesBookAndDifferenceFromTheLockedBalance(){
  var w=world();stock.approve(create(w,"OTHER_IN","3","30").getId());var original=createCount(w,"5");
  UUID insufficient=reviewer(w,false,false);harness.loginAs(insufficient);
  assertThatThrownBy(()->stock.reviewDraft(original.getId())).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
  UUID reviewer=reviewer(w,true,false);harness.loginAs(reviewer);var review=stock.reviewDraft(original.getId());var request=input(original,"999","4");request.getItems().getFirst().setSurplusQty(new BigDecimal("999"));
  var result=stock.updateReviewed(original.getId(),request,review.snapshot(),true);
  assertThat(result.getItems().getFirst().getQty()).isEqualByComparingTo("3");assertThat(result.getItems().getFirst().getSurplusQty()).isEqualByComparingTo("1");
  assertThat(quantity(w)).isEqualByComparingTo("4");assertThat(value(w)).isEqualByComparingTo("30");assertThat(result.getMakerId()).isEqualTo(w.employeeId());
  assertThat(number("SELECT COUNT(*) FROM stock_value_events event JOIN stock_value_nodes source ON source.id=event.result_node_id WHERE event.source_doc_type='STOCK_DOC' AND event.source_doc_id=? AND event.operation='RECEIVE' AND NOT source.source_final AND event.qty_base=1",original.getId())).isEqualByComparingTo("1");
 }
 @Test void crossDocumentIdentityAndChangedTypeRefuseAtomicallyAndReviewContextDoesNotLeak(){
  var w=world();var original=create(w,"OTHER_IN","2",null);var other=create(w,"OTHER_IN","4",null);UUID reviewer=reviewer(w,false,true);harness.loginAs(reviewer);
  var review=stock.reviewDraft(original.getId());var wrong=input(original,"3",null);wrong.getItems().getFirst().setSourceItemId(other.getItems().getFirst().getId());
  conflict(()->stock.updateReviewed(original.getId(),wrong,review.snapshot(),false));var type=input(original,"3",null);type.setDocType("OTHER_OUT");conflict(()->stock.updateReviewed(original.getId(),type,review.snapshot(),false));
  assertThat(number("SELECT qty FROM stock_document_items WHERE doc_id=?",original.getId())).isEqualByComparingTo("2");assertThat(quantity(w)).isZero();
  assertThat(com.uten.imp.common.platformcolumns.PlatformColumnReviewedSave.isActiveFor("stock_doc_item",original.getId(),reviewer)).isFalse();
  assertThat(stock.canEditPlatformFields(original.getId())).isFalse();
 }
 @Test void earlierIncomingCannotBeErasedAcrossALaterReceiptAndNewestUnusedIncomingReversesItsActualCost(){
  var w=world();var first=create(w,"OTHER_IN","2","50");stock.approve(first.getId());var last=create(w,"OTHER_IN","1","100");stock.approve(last.getId());
  assertThat(quantity(w)).isEqualByComparingTo("3");assertThat(value(w)).isEqualByComparingTo("150");
  conflict(()->unapproval.unapprove("stockDocument",first.getId(),new DocumentUnapprovalService.UnapproveRequest("stock-cost-unapprove-"+first.getId(),"原入库不能借其它入库的新均价撤销")));
  assertThat(quantity(w)).isEqualByComparingTo("3");assertThat(value(w)).isEqualByComparingTo("150");
  var newest=(StockDocDetail)unapproval.unapprove("stockDocument",last.getId(),new DocumentUnapprovalService.UnapproveRequest("stock-last-"+last.getId(),"按最后入库的真实100撤回"));
  assertThat(quantity(w)).isEqualByComparingTo("2");assertThat(value(w)).isEqualByComparingTo("50");stock.approve(newest.getId());
  assertThat(quantity(w)).isEqualByComparingTo("3");assertThat(value(w)).isEqualByComparingTo("150");
 }

 @Test void outgoingUsesRealAverageCostAndUnapprovalMirrorsTheOriginalIssueDespiteHintPriceNinetyNine(){
  var w=world();stock.approve(create(w,"OTHER_IN","10","100").getId());stock.approve(create(w,"OTHER_IN","10","200").getId());
  var outgoing=create(w,"OTHER_OUT","5","495");stock.approve(outgoing.getId());
  assertThat(quantity(w)).isEqualByComparingTo("15");assertThat(value(w)).isEqualByComparingTo("225");
  var draft=(StockDocDetail)unapproval.unapprove("stockDocument",outgoing.getId(),new DocumentUnapprovalService.UnapproveRequest("stock-out-cost-unapprove-"+outgoing.getId(),"按原出库实际75回滚，不能使用参考99单价重建"));
  assertThat(quantity(w)).isEqualByComparingTo("20");assertThat(value(w)).isEqualByComparingTo("300");
  stock.approve(draft.getId());assertThat(quantity(w)).isEqualByComparingTo("15");assertThat(value(w)).isEqualByComparingTo("225");
 }
 @Test void pureIssueGuardSharesOriginalRootAndRejectsAggregatedExcessWithoutAnyEvents(){
  var w=world();stock.approve(create(w,"OTHER_IN","10","100").getId());var out=create(w,"OTHER_OUT","5",null);stock.approve(out.getId());
  UUID movement=movement(out,-1);var key=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(w.warehouseId(),w.goodsD(),null);
  var first=new com.uten.imp.application.port.InventoryValuationPort.IssueReturnSource(key,movement,new BigDecimal("3"));
  var second=new com.uten.imp.application.port.InventoryValuationPort.IssueReturnSource(key,movement,new BigDecimal("2"));
  BigDecimal before=number("SELECT COUNT(*) FROM stock_value_events");
  String fp=values.requireIssueReturnsAvailable(List.of(first,second));assertThat(fp).hasSize(64);
  assertThat(values.requireIssueReturnsAvailable(List.of(first,second))).isEqualTo(fp);
  conflict(()->values.requireIssueReturnsAvailable(List.of(first,first)));
  conflict(()->values.requireIssueReturnsAvailable(List.of(new com.uten.imp.application.port.InventoryValuationPort.IssueReturnSource(key,UUID.randomUUID(),BigDecimal.ONE))));
  assertThat(number("SELECT COUNT(*) FROM stock_value_events")).isEqualByComparingTo(before);
  assertThat(quantity(w)).isEqualByComparingTo("5");assertThat(value(w)).isEqualByComparingTo("50");
  unapproval.unapprove("stockDocument",out.getId(),new DocumentUnapprovalService.UnapproveRequest("pure-issue-"+out.getId(),"纯核对之后仍按原值反审"));
  assertThat(quantity(w)).isEqualByComparingTo("10");assertThat(value(w)).isEqualByComparingTo("100");
  conflict(()->values.requireIssueReturnsAvailable(List.of(first)));
 }

 @Test void pureReceiveGuardRefusesUsedThenReturnedHistoryAndLeavesBothBalancesAndDocuments(){
  var w=world();var incoming=create(w,"OTHER_IN","10","100");stock.approve(incoming.getId());
  var key=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(w.warehouseId(),w.goodsD(),null);
  var probe=List.of(new com.uten.imp.application.port.InventoryValuationPort.ReceiveWithdrawalSource(key,movement(incoming,1)));
  String untouched=values.requireReceivesReversible(probe);assertThat(untouched).hasSize(64);
  var out=create(w,"OTHER_OUT","5",null);stock.approve(out.getId());
  unapproval.unapprove("stockDocument",out.getId(),new DocumentUnapprovalService.UnapproveRequest("stock-used-history-"+out.getId(),"恢复原出库成本，不抹历史"));
  assertThat(quantity(w)).isEqualByComparingTo("10");assertThat(value(w)).isEqualByComparingTo("100");
  BigDecimal eventCount=number("SELECT COUNT(*) FROM stock_value_events");conflict(()->values.requireReceivesReversible(probe));
  conflict(()->unapproval.unapprove("stockDocument",incoming.getId(),new DocumentUnapprovalService.UnapproveRequest("stock-source-history-"+incoming.getId(),"不能把补偿库存当成未使用")));
  assertThat(number("SELECT COUNT(*) FROM stock_value_events")).isEqualByComparingTo(eventCount);
  assertThat(quantity(w)).isEqualByComparingTo("10");assertThat(value(w)).isEqualByComparingTo("100");assertThat(stock.detail(incoming.getId()).getStatus()).isEqualTo((short)1);
 }

 @Test void samePoolTwoLineIncomingReversesInSourceOrderAndRestoresItsTwoActualCosts(){
  var w=world();var req=new StockDocSaveRequest();req.setDocType("OTHER_IN");req.setBillDate(BusinessTime.today());req.setWarehouseId(w.warehouseId());
  var a=new StockDocItemLine();a.setGoodsId(w.goodsD());a.setUnitId(w.unitId());a.setUnitRate(BigDecimal.ONE);a.setQty(new BigDecimal("2"));a.setAmountLocal(new BigDecimal("50"));a.setAmountOriginal(new BigDecimal("50"));a.setPrice(new BigDecimal("25"));
  var b=new StockDocItemLine();b.setGoodsId(w.goodsD());b.setUnitId(w.unitId());b.setUnitRate(BigDecimal.ONE);b.setQty(BigDecimal.ONE);b.setAmountLocal(new BigDecimal("100"));b.setAmountOriginal(new BigDecimal("100"));b.setPrice(new BigDecimal("100"));
  req.setItems(List.of(a,b));var original=stock.create(req);stock.approve(original.getId());assertThat(quantity(w)).isEqualByComparingTo("3");assertThat(value(w)).isEqualByComparingTo("150");
  var key=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(w.warehouseId(),w.goodsD(),null);
  // Movement time can be identical; business line order is the canonical approval order.
  var order=db.queryForList("SELECT move.id FROM stock_document_items item JOIN stock_movements move ON move.source_item_id=item.id AND move.source_doc_id=item.doc_id AND move.direction=1 WHERE item.doc_id=? ORDER BY item.line_no DESC",UUID.class,original.getId());
  assertThat(values.requireReceivesReversible(order.stream().map(id->new com.uten.imp.application.port.InventoryValuationPort.ReceiveWithdrawalSource(key,id)).toList())).hasSize(64);
  var draft=(StockDocDetail)unapproval.unapprove("stockDocument",original.getId(),new DocumentUnapprovalService.UnapproveRequest("stock-multiple-"+original.getId(),"两来源逐笔原值回退"));
  assertThat(quantity(w)).isZero();assertThat(value(w)).isZero();stock.approve(draft.getId());assertThat(quantity(w)).isEqualByComparingTo("3");assertThat(value(w)).isEqualByComparingTo("150");
 }

 private UUID movement(StockDocDetail doc,int direction){return db.queryForObject("SELECT id FROM stock_movements WHERE source_doc_id=? AND direction=?",UUID.class,doc.getId(),direction);}
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
