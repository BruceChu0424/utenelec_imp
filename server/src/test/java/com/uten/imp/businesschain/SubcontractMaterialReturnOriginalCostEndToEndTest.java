package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.*;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import static org.assertj.core.api.Assertions.*;

/** A returned material batch carries its real original cost, even beside a later different-price receipt. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
 "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
 "uten.inventory.value-work.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
 "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractMaterialReturnOriginalCostEndToEndTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
 @Autowired AutowireCapableBeanFactory beans;
 @Autowired JdbcTemplate db;
 @Autowired SubcontractDrawCommandService draws;
 @Autowired SubcontractMaterialIssueService issues;
 @Autowired SubcontractMaterialReturnService returns;
 @Autowired StockDocService stock;
 SubcontractStepDrawEndToEndTest fixture;
 @BeforeEach void setup(){fixture=new SubcontractStepDrawEndToEndTest();beans.autowireBean(fixture);fixture.setup();}
 @AfterEach void clear(){SecurityContextHolder.clearContext();}

 @Test void reverseRestoresOriginalFortyToSupplierAndRetainsLaterOneHundredTwentyInWarehouse(){
   Scenario s=scenario();
   pool(s,"10","160");
   BigDecimal original=decimal("SELECT known_value_local FROM stock_value_events WHERE source_doc_type='SUBCONTRACT_MATERIAL_RETURN' AND source_doc_id=? AND operation='POSITION_STORE'",s.returnId());
   assertThat(original).isEqualByComparingTo("40");
   returns.reverse(s.returnId());
   pool(s,"6","120");
   assertThat(decimal("SELECT known_value_local FROM stock_value_events WHERE source_doc_type='SUBCONTRACT_MATERIAL_RETURN' AND source_doc_id=? AND operation='POSITION_STORE_REVERSE'",s.returnId())).isEqualByComparingTo("40");
   assertThat(supplierValue(s)).isEqualByComparingTo("100");
   assertThat(decimal("SELECT returned_qty FROM subcontract_material_issue_items WHERE id=?",s.issueItem())).isEqualByComparingTo("0");
   assertThat(decimal("SELECT issued_qty FROM subcontract_material_plan_items WHERE order_item_id=?",s.orderItem())).isEqualByComparingTo("10");
   assertThatThrownBy(()->returns.reverse(s.returnId())).isInstanceOf(ApiException.class);
   pool(s,"6","120");
 }

 @Test void laterActualConsumptionBlocksWithdrawalEvenWhenPhysicalStockStillExceedsTheReturnedBatch(){
   Scenario s=scenario();
   var request=new StockDocSaveRequest();request.setDocType("OTHER_OUT");request.setBillDate(BusinessTime.today());request.setWarehouseId(s.world().warehouseId());
   var line=new StockDocItemLine();line.setGoodsId(s.material());line.setUnitId(s.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ONE);request.setItems(List.of(line));
   stock.approve(stock.create(request).getId());
   pool(s,"9","144");
   assertThatThrownBy(()->returns.reverse(s.returnId())).isInstanceOf(RuntimeException.class);
   pool(s,"9","144");
   assertThat(supplierValue(s)).isEqualByComparingTo("60");
   assertThat(decimal("SELECT returned_qty FROM subcontract_material_issue_items WHERE id=?",s.issueItem())).isEqualByComparingTo("4");
   assertThat(db.queryForObject("SELECT status FROM subcontract_material_returns WHERE id=?",Integer.class,s.returnId())).isEqualTo(1);
   assertThat(db.queryForObject("SELECT COUNT(*) FROM stock_value_events WHERE source_doc_type='SUBCONTRACT_MATERIAL_RETURN' AND source_doc_id=? AND operation='POSITION_STORE_REVERSE'",Integer.class,s.returnId())).isZero();
 }

 private Scenario scenario(){
   String tag="sc-return-value-"+UUID.randomUUID();var w=fixture.fixture.seedWorld(tag);fixture.fixture.loginAs(w.superAdminUserId());
   call(fixture,"grantAuthorities",w.superAdminUserId(),new String[]{"subcontract_order:view","subcontract_order:draw","subcontract:view:all"});
   UUID parent=call(fixture,"goods",w,tag,"P","委外"),material=call(fixture,"goods",w,tag,"M","采购");fixture.fixture.insertBom(parent,material,"1");
   call(fixture,"otherIn",w,w.warehouseId(),material,null,"10","10");
   UUID order=call(fixture,"subcontractOrder",w,parent,"10",BusinessTime.today().plusDays(5),null);call(fixture,"approveSubcontract",w,order);
   UUID orderItem=call(fixture,"itemOf",order);
   var issued=draws.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(orderItem,null)),"draw-original-return-"+orderItem));issued.issueIds().forEach(issues::approve);
   UUID issueItem=db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE issue_id=? AND NOT is_deleted",UUID.class,issued.issueIds().getFirst());
   UUID returned=call(fixture,"materialReturn",w,w.warehouseId(),orderItem,parent,material,issueItem,"4");
   call(fixture,"otherIn",w,w.warehouseId(),material,null,"6","20");
   return new Scenario(w,material,orderItem,issueItem,returned);
 }
 private BigDecimal supplierValue(Scenario s){return db.queryForObject("""
   SELECT COALESCE(SUM(head.owned_value_local),0) FROM stock_value_nodes root
   JOIN stock_value_nodes head ON head.id=root.return_head_id
   WHERE root.root_issue_id=root.id AND head.active AND head.owner_kind='SUBCONTRACT_WIP' AND head.owner_id=?
   """,BigDecimal.class,s.issueItem());}
 private void pool(Scenario s,String qty,String value){
   assertThat(db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",BigDecimal.class,s.material(),s.world().warehouseId())).isEqualByComparingTo(qty);
   assertThat(db.queryForObject("SELECT head.basis_value_local FROM stock_value_pools p JOIN stock_value_nodes head ON head.id=p.head_node_id WHERE p.goods_id=? AND p.warehouse_id=? AND p.color_id IS NULL",BigDecimal.class,s.material(),s.world().warehouseId())).isEqualByComparingTo(value);
 }
 private BigDecimal decimal(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
 @SuppressWarnings("unchecked") private static <T>T call(Object target,String method,Object...args){return (T)ReflectionTestUtils.invokeMethod(target,method,args);}
 private record Scenario(FullChainEndToEndTest.World world,UUID material,UUID orderItem,UUID issueItem,UUID returnId){}
}
