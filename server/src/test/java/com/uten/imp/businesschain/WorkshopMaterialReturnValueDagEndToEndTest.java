package com.uten.imp.businesschain;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.test.util.ReflectionTestUtils;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.stock.allocation.*;
import com.uten.imp.features.stock.allocation.dto.*;
import com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest;
import static org.junit.jupiter.api.Assertions.*;
@org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WorkshopMaterialReturnValueDagEndToEndTest extends WorkshopMaterialReturnAuditSupport {
 @ParameterizedTest @CsvSource({"false,true","false,false","true,true","true,false"})
 void twoPrivateReturnsMustReverseInEitherOrderAfterAnotherActualReceipt(boolean valued,boolean oldestFirst){
  String tag="audit-dag-"+valued+"-"+oldestFirst;Object c;UUID[] target;
  if(valued){Object family=read(this,"manualFamily",tag,false,true);c=read(family,"context");target=read(family,"first");}
  else {c=read(this,"create",tag,false);target=new UUID[]{read(c,"plan"),read(c,"segment"),read(this,"parentDemand",c)};}
  FullChainEndToEndTest.World world=read(c,"world");UUID worker=read(c,"workerUser"),warehouse=read(c,"leaf"),goods=read(c,"child");
  if(valued){
   UUID childSegment=read(c,"childSegment"),childPlan=read(c,"childPlan");
   UUID demand=db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=?",UUID.class,childSegment);
   var request=new ProductionMaterialSettlementRequest();request.setExecutionSegmentId(childSegment);request.setIdempotencyKey(tag+"-cost");request.setReason("Actual input cost");
   var line=new ProductionMaterialSettlementRequest.Line();line.setDemandId(demand);line.setSettlementType("CONSUMED");line.setQtyBase(BigDecimal.TEN);request.setLines(List.of(line));
   fixture.loginAs(world.superAdminUserId());beans.getBean(ProductionMaterialSettlementService.class).post(childPlan,request,world.superAdminUserId());
  }
  read(this,"transferTo",c,target[2],"5");read(this,"transferTo",c,target[2],"5");
  if(valued)read(this,"drainValue",c,List.of(goods,db.queryForObject("SELECT goods_id FROM production_material_demands WHERE execution_segment_id=?",UUID.class,(Object)read(c,"childSegment"))));
  read(this,"confirmRoute",target[0],target[1],"CONTINUOUS");fixture.loginAs(worker);
  segments.start(target[0],target[1],new SegmentTransitionRequest(db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,target[1]),tag+"-start"));
  var ids=db.queryForList("SELECT source.id FROM production_workshop_direct_source_allocations source JOIN stock_reservations held ON held.id=source.stock_reservation_id WHERE held.demand_id=? ORDER BY allocation_no",UUID.class,target[2]);
  UUID issueA=db.queryForObject("SELECT stock_posting_id FROM production_workshop_direct_source_events WHERE source_allocation_id=? AND event_type='ISSUE'",UUID.class,ids.get(0));
  UUID issueB=db.queryForObject("SELECT stock_posting_id FROM production_workshop_direct_source_events WHERE source_allocation_id=? AND event_type='ISSUE'",UUID.class,ids.get(1));
  UUID a=returned(world,worker,target,issueA,warehouse,"3",tag+"a"),b=returned(world,worker,target,issueB,warehouse,"5",tag+"b");
  read(this,"receiveAt",c,goods,warehouse,"10","99");fixture.loginAs(world.superAdminUserId());
  stock.reverse(oldestFirst?a:b);stock.reverse(oldestFirst?b:a);
  read(this,"poolValue",warehouse,goods,"10","990");
  assertEquals(0,BigDecimal.TEN.compareTo(db.queryForObject("SELECT SUM(consumed_qty) FROM stock_reservations WHERE demand_id=?",BigDecimal.class,target[2])));
  assertTrue(db.queryForObject("SELECT COALESCE(MAX(children),0) FROM (SELECT COUNT(*) children FROM stock_value_edges GROUP BY parent_node_id) counts",Integer.class)<=2);
  assertTrue(db.queryForObject("SELECT COUNT(*) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE node.kind='VALUE_REFERENCE' AND pool.goods_id=?",Integer.class,goods)>=2);
  assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM stock_value_nodes WHERE kind='VALUE_REFERENCE' AND (active OR owned_value_local<>0 OR owner_kind IS NOT NULL)",Integer.class));
  // Exercise the internal cost propagation port separately from price approval:
  // the later real inbound still owns its full correction after both reversals.
  var incoming=db.queryForMap("""
      SELECT event.result_node_id,pool.color_id,event.source_doc_id,event.source_item_id
      FROM stock_value_events event JOIN stock_value_pools pool ON pool.id=event.pool_id
      JOIN stock_movements movement ON movement.id=event.movement_id
      WHERE pool.warehouse_id=? AND pool.goods_id=? AND event.operation='RECEIVE'
        AND movement.movement_type=11 AND movement.direction=1
      ORDER BY event.created_at DESC LIMIT 1
      """,warehouse,goods);
  var user=beans.getBean(com.uten.imp.security.SecurityContextCurrentUser.class);
  new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class)).executeWithoutResult(status->{
   beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
   beans.getBean(com.uten.imp.features.stock.InventoryMutationLock.class).lock(new com.uten.imp.features.stock.InventoryKey(goods,(UUID)incoming.get("color_id")));
   var context=new com.uten.imp.application.port.InventoryValuationPort.EventContext(UUID.randomUUID(),"TEST_COST",(UUID)incoming.get("source_doc_id"),
      (UUID)incoming.get("source_item_id"),0,user.requireId(),user.requireEmployeeId(),tag+"-later-cost",java.time.OffsetDateTime.now());
   beans.getBean(com.uten.imp.application.port.InventoryValuationPort.class).adjustSource(new com.uten.imp.application.port.InventoryValuationPort.SourceAdjustment(
      context,(UUID)incoming.get("result_node_id"),BigDecimal.TEN,true));
  });
  read(this,"drainValue",c,List.of(goods));
  read(this,"poolValue",warehouse,goods,"10","1000");
  assertTrue(db.queryForObject("SELECT COALESCE(MAX(children),0) FROM (SELECT COUNT(*) children FROM stock_value_edges GROUP BY parent_node_id) counts",Integer.class)<=2);
 }
 private UUID returned(FullChainEndToEndTest.World world,UUID worker,UUID[] target,UUID issue,UUID receiving,String qty,String key){
  fixture.loginAs(worker);var request=beans.getBean(ProductionMaterialReturnRequestService.class).submit(target[0],new ProductionMaterialReturnRequest.Submit(target[1],key,"Audit exact return",List.of(new ProductionMaterialReturnRequest.Item(issue,new BigDecimal(qty))))).getFirst();
  fixture.loginAs(world.superAdminUserId());stock.confirmProductionMaterialReturn(request.documentId(),new ProductionMaterialReturnConfirmRequest(receiving,key+"-received"));return request.documentId();
 }
}
