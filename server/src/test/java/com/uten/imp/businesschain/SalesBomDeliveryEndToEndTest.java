package com.uten.imp.businesschain;

import com.uten.imp.common.delivery.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.shipment.SalesShipmentDeliveryService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import com.uten.imp.features.production.execution.DeliveryProcessingContracts;
import com.uten.imp.features.production.execution.DeliveryProcessingService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real PostgreSQL, all migrations, production stock kernel and commercial/warehouse review state machines. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev","uten.audit.retention.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.production.readiness-reconcile.enabled=false"})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = SalesBomDeliveryEndToEndTest.DatabaseCleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class SalesBomDeliveryEndToEndTest {
    // Legacy unresolved jobs conservatively fence cost publication across the
    // database. This test owns the entire cost graph whose readiness it asserts.
    private static final PostgreSQLContainer DATABASE = new PostgreSQLContainer("postgres:16-alpine");

    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry, DATABASE);
    }

    static class DatabaseCleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) { DATABASE.stop(); }
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesOrderService orders;
    @Autowired SalesShipmentService shipments;
    @Autowired SalesShipmentDeliveryService components;
    @Autowired BomDeliveryService boms;
    @Autowired PlatformTransactionManager transactions;
    @Autowired com.uten.imp.features.stock.valuation.InventoryValuationService values;
    @Autowired com.uten.imp.features.stock.InventoryMutationLock inventoryLocks;
    FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    record Ready(FullChainEndToEndTest.World world,UUID order,UUID orderItem,UUID shipment){}
    Ready ready(String tag,String stockB,String stockE,boolean laser){
        var w=fixture.seedWorld(tag+UUID.randomUUID().toString().substring(0,7));fixture.loginAs(w.superAdminUserId());
        if(new BigDecimal(stockB).signum()>0)stock(w,w.goodsB(),stockB);
        if(new BigDecimal(stockE).signum()>0)stock(w,w.goodsE(),stockE);
        var snapshot=boms.snapshot(w.goodsA());
        UUID edge=snapshot.root().children().stream().filter(n->n.goodsId().equals(w.goodsB())).findFirst().orElseThrow().edgeId();
        var plan=new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,List.of(),
            laser?List.of(new DeliveryPlan.Process(List.of(edge),DeliveryPlan.Operation.LASER,true)):List.of(),snapshot.bomFingerprint());
        var request=fixture.orderRequest(w,w.goodsA(),"5","100");request.getItems().getFirst().setDeliveryPlan(plan);
        UUID order=orders.create(request).getId();orders.approve(order);fixture.confirmInitialSalesFinance(order);
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        UUID shipment=fixture.createShipment(w,item,w.goodsA(),"5");
        shipments.confirmSales(shipment,0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        return new Ready(w,order,item,shipment);
    }
    void stock(FullChainEndToEndTest.World w,UUID goods,String qty){
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStockZeroPriceAt",w,goods,new BigDecimal(qty),w.warehouseId());
    }
    List<SalesShipmentDeliveryService.Component> physical(UUID shipment){
        return new TransactionTemplate(transactions).execute(s->components.components(shipment,false));
    }
    WarehouseWorkTransitionRequest pick(Ready r){
        var request=new WarehouseWorkTransitionRequest();request.setTargetStatus("SHIPPED");request.setWarehouseId(r.world().warehouseId());
        request.setItemIds(db.queryForList("SELECT id FROM sales_shipment_items WHERE shipment_id=? AND NOT is_deleted",UUID.class,r.shipment()));
        request.setDeliveryComponents(physical(r.shipment()).stream().map(c->new SalesShipmentDeliveryService.Pick(c.id(),r.world().warehouseId(),"测试库位")).toList());
        return request;
    }
    BigDecimal balance(UUID warehouse,UUID goods){return db.queryForObject("SELECT COALESCE((SELECT sum(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?),0)",BigDecimal.class,warehouse,goods);}

    @Test void componentStockAndCommercialRootArePostedOnceAndPhysicalHandoverCannotBeDirectlyReversed(){
        Ready r=ready("bom-ship","10","5",false);var w=r.world();
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,r.orderItem())).isZero();
        assertThat(physical(r.shipment())).hasSize(2);
        shipments.transitionWarehouseWork(r.shipment(),pick(r));
        assertThat(balance(w.warehouseId(),w.goodsA())).isZero();
        assertThat(balance(w.warehouseId(),w.goodsB())).isZero();
        assertThat(balance(w.warehouseId(),w.goodsE())).isZero();
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,r.orderItem())).isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=? AND direction=-1",Integer.class,r.shipment())).isEqualTo(2);
        assertThatThrownBy(()->shipments.transitionWarehouseWork(r.shipment(),pick(r))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->shipments.reverse(r.shipment())).isInstanceOf(ApiException.class).hasMessageContaining("退货");
        assertThat(balance(w.warehouseId(),w.goodsA())).isZero();
        assertThat(balance(w.warehouseId(),w.goodsB())).isZero();
        assertThat(balance(w.warehouseId(),w.goodsE())).isZero();
        ReflectionTestUtils.invokeMethod(fixture,"drainCosts",w);
        assertThat(db.queryForObject("SELECT bool_or(pending) FROM v_stock_actual_sales_cost_coverage WHERE shipment_id=?",Boolean.class,r.shipment())).isFalse();
    }
    @Test void shortageAndIncompleteSelectionRollBackEveryComponentAndCommercialFact(){
        Ready r=ready("bom-short","10","1",false);
        var complete=pick(r);var incomplete=pick(r);incomplete.setDeliveryComponents(incomplete.getDeliveryComponents().subList(0,1));
        assertThatThrownBy(()->shipments.transitionWarehouseWork(r.shipment(),incomplete)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->shipments.transitionWarehouseWork(r.shipment(),complete)).isInstanceOf(ApiException.class);
        assertThat(balance(r.world().warehouseId(),r.world().goodsB())).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",Integer.class,r.shipment())).isZero();
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,r.orderItem())).isZero();
        stock(r.world(),r.world().goodsE(),"4");shipments.transitionWarehouseWork(r.shipment(),complete);
        assertThat(balance(r.world().warehouseId(),r.world().goodsE())).isZero();
    }

    @Test void nonzeroComponentCostsMapOnceToTheCommercialParentAndKeepLateCostPendingUntilRealPropagation(){
        Ready r=ready("bom-valued","0","0",false);var w=r.world();
        // Existing fixture goes through StockDocService create + approve, with
        // synthetic unit cost 10. No movement or valuation fact is hand-written.
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsB(),"10");
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsE(),"5");
        shipments.transitionWarehouseWork(r.shipment(),pick(r));
        ReflectionTestUtils.invokeMethod(fixture,"drainCosts",w);
        UUID parent=db.queryForObject("SELECT id FROM sales_shipment_items WHERE shipment_id=? AND NOT is_deleted",UUID.class,r.shipment());
        assertThat(db.queryForObject("SELECT count(DISTINCT shipment_item_id) FROM v_stock_actual_cogs_postings WHERE shipment_id=?",Integer.class,r.shipment())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT min(shipment_item_id::text) FROM v_stock_actual_cogs_postings WHERE shipment_id=?",String.class,r.shipment())).isEqualTo(parent.toString());
        assertThat(db.queryForObject("SELECT count(DISTINCT source_item_id) FROM v_stock_actual_cogs_postings WHERE shipment_id=?",Integer.class,r.shipment())).isEqualTo(2);
        assertThat(db.queryForObject("SELECT sum(amount_local) FROM v_stock_actual_cogs_postings WHERE shipment_id=?",BigDecimal.class,r.shipment())).isEqualByComparingTo("150");
        assertThat(db.queryForObject("SELECT bool_or(pending) FROM v_stock_actual_sales_cost_coverage WHERE shipment_id=?",Boolean.class,r.shipment())).isFalse();
        Map<String,Object> source=db.queryForMap("""
            SELECT node.id,event.source_doc_id,event.source_item_id FROM stock_value_nodes node
            JOIN stock_value_pools pool ON pool.id=node.pool_id
            JOIN stock_value_events event ON event.result_node_id=node.id AND event.operation='RECEIVE'
            WHERE pool.goods_id=? AND pool.warehouse_id=? AND node.kind='SOURCE'
            """,w.goodsB(),w.warehouseId());
        new TransactionTemplate(transactions).executeWithoutResult(status->{
            inventoryLocks.lock(new com.uten.imp.features.stock.InventoryKey(w.goodsB(),null));
            UUID adjustment=UUID.randomUUID();
            var context=new com.uten.imp.application.port.InventoryValuationPort.EventContext(adjustment,"STOCK_DOC",
                    (UUID)source.get("source_doc_id"),(UUID)source.get("source_item_id"),2L,w.superAdminUserId(),w.employeeId(),
                    "delivery-component-late-cost-"+adjustment,java.time.OffsetDateTime.now());
            values.adjustSource(new com.uten.imp.application.port.InventoryValuationPort.SourceAdjustment(context,
                    (UUID)source.get("id"),new BigDecimal("100"),true));
            // Observe within this transaction so an asynchronous worker cannot
            // settle the job before the authoritative pending fence is checked.
            assertThat(db.queryForObject("SELECT bool_or(pending) FROM v_stock_actual_sales_cost_coverage WHERE shipment_id=?",Boolean.class,r.shipment())).isTrue();
            assertThat(db.queryForObject("SELECT bool_or(pending) FROM v_stock_actual_cogs_postings WHERE shipment_id=?",Boolean.class,r.shipment())).isTrue();
        });
        ReflectionTestUtils.invokeMethod(fixture,"drainCosts",w);
        assertThat(db.queryForObject("SELECT sum(amount_local) FROM v_stock_actual_cogs_postings WHERE shipment_id=?",BigDecimal.class,r.shipment())).isEqualByComparingTo("250");
        assertThat(db.queryForObject("SELECT count(DISTINCT shipment_item_id) FROM v_stock_actual_cogs_postings WHERE shipment_id=?",Integer.class,r.shipment())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT bool_or(pending) FROM v_stock_actual_sales_cost_coverage WHERE shipment_id=?",Boolean.class,r.shipment())).isFalse();
        assertThat(db.queryForObject("SELECT bool_or(pending) FROM v_stock_actual_cogs_postings WHERE shipment_id=?",Boolean.class,r.shipment())).isFalse();
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=? AND direction=-1",Integer.class,r.shipment())).isEqualTo(2);
    }
    @Test void requiredProcessingCannotBeAcknowledgedByWarehouseOrOmittedFromFullSelection(){
        Ready r=ready("bom-laser","10","5",true);
        assertThat(physical(r.shipment()).stream().filter(c->!c.operations().isEmpty())).hasSize(1);
        assertThatThrownBy(()->shipments.transitionWarehouseWork(r.shipment(),pick(r))).isInstanceOf(ApiException.class).hasMessageContaining("加工");
        assertThat(balance(r.world().warehouseId(),r.world().goodsB())).isEqualByComparingTo("10");
    }
    @Test void periodicGoodsRemainInDeliveryConfigurationAndOnlyExplicitFrontiersShipThem(){
        var w=fixture.seedWorld("bom-periodic-"+UUID.randomUUID().toString().substring(0,7));fixture.loginAs(w.superAdminUserId());
        UUID kg=UUID.randomUUID(),periodic=UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,'千克','使用')",kg,"BOM-DELIVERY-KG-"+kg);
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(?,'MASS','KG','MANUAL_GOVERNANCE')",kg);
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,issue_method,periodic_cost_basis,default_supplier_id,code_sequence)
                VALUES(?,?,'客户实际交付重量料','采购','使用',?,'PERIODIC','OWN',?,(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))
                """,periodic,"BOM-DELIVERY-PERIODIC-"+periodic,kg,w.supplierId());
        db.update("UPDATE goods_bom_items SET component_goods_id=?,hard_gate=false WHERE goods_id=? AND component_goods_id=?",periodic,w.goodsB(),w.goodsC());
        var before=boms.snapshot(w.goodsA());
        var assembly=before.root().children().stream().filter(n->n.goodsId().equals(w.goodsB())).findFirst().orElseThrow();
        var periodicNode=assembly.children().stream().filter(n->n.goodsId().equals(periodic)).findFirst().orElseThrow();
        var whole=new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,List.of(),List.of(),before.bomFingerprint());
        assertThat(DeliveryFrontier.resolve(before,new BigDecimal("5"),whole).items()).extracting(DeliveryBom.Item::goodsId)
                .containsExactlyInAnyOrder(w.goodsB(),w.goodsE()).doesNotContain(periodic);
        var split=new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,
                List.of(new DeliveryPlan.NodeMode(assembly.path(),DeliveryPlan.NodeDelivery.CHILDREN)),List.of(),before.bomFingerprint());
        assertThat(DeliveryFrontier.resolve(before,new BigDecimal("5"),split).items()).filteredOn(item->item.goodsId().equals(periodic)).singleElement()
                .satisfies(item->assertThat(item.quantity()).isEqualByComparingTo("30"));
        assertThat(boms.hasRequiredOperations(w.goodsA())).isFalse();
        var changed=boms.updateRule(periodicNode.edgeId(),false,DeliveryBom.MaterialRole.PART,List.of(DeliveryPlan.Operation.LASER),before.bomFingerprint(),w.goodsA());
        assertThat(changed.bomFingerprint()).isNotEqualTo(before.bomFingerprint());
        assertThat(boms.hasRequiredOperations(w.goodsA())).isTrue();
        assertThat(changed.root().children().stream().filter(n->n.goodsId().equals(w.goodsB())).findFirst().orElseThrow().children())
                .filteredOn(n->n.goodsId().equals(periodic)).singleElement().satisfies(n->assertThat(n.requiredOperations()).containsExactly(DeliveryPlan.Operation.LASER));
    }

    @Test void changedBomCannotSilentlyReplaceTheApprovedPhysicalFrontier(){
        Ready r=ready("bom-drift","10","5",false);
        db.update("UPDATE goods_bom_items SET qty=3 WHERE goods_id=? AND component_goods_id=?",r.world().goodsA(),r.world().goodsB());
        assertThatThrownBy(()->shipments.transitionWarehouseWork(r.shipment(),pick(r))).isInstanceOf(ApiException.class).hasMessageContaining("变化");
        assertThat(balance(r.world().warehouseId(),r.world().goodsB())).isEqualByComparingTo("10");
    }

    @Test void publicBOMLaserFlow(){
        Ready r=ready("bom-public-laser-flow","10","5",true);var w=r.world();
        var processing=beans.getBean(DeliveryProcessingService.class);
        UUID productionDepartment=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD' AND NOT is_deleted",UUID.class);
        UUID workshop=UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES (?,?,?,?,'二级班组')",
                workshop,"WS-DLV-"+workshop,"散件激光回归车间",productionDepartment);
        db.update("UPDATE employees SET department_id=? WHERE id=?",workshop,w.employeeId());
        fixture.loginAs(w.superAdminUserId());

        var laser=physical(r.shipment()).stream().filter(c->c.goodsId().equals(w.goodsB())).findFirst().orElseThrow();
        assertThat(laser.quantity()).isEqualByComparingTo("10");
        assertThat(laser.operations()).containsExactly("LASER");
        var assigned=processing.assign(laser.id(),new DeliveryProcessingContracts.Assignment(
                laser.revision(),workshop,w.employeeId(),UUID.randomUUID()));
        assertThat(assigned.workshopDepartmentId()).isEqualTo(workshop);
        assertThat(assigned.responsibleEmployeeId()).isEqualTo(w.employeeId());
        assertThatThrownBy(()->processing.start(laser.id(),new DeliveryProcessingContracts.Start(
                assigned.version(),w.warehouseId(),UUID.randomUUID())))
                .isInstanceOf(ApiException.class).hasMessageContaining("仓库");

        var issueRequest=new SalesShipmentDeliveryService.ProcessingWarehouseAction(assigned.version(),
                w.warehouseId(),"激光实际发料库位",UUID.randomUUID(),"仓库交接B实物10个至激光车间");
        var issued=shipments.processingWarehouseWork(r.shipment(),laser.id(),"ISSUE",issueRequest);
        assertThat(issued.processingIssuedAt()).isNotNull();
        assertThat(shipments.processingWarehouseWork(r.shipment(),laser.id(),"ISSUE",issueRequest).revision())
                .isEqualTo(issued.revision());
        assertThat(db.queryForObject("SELECT count(*) FROM sales_delivery_warehouse_actions WHERE request_id=?",Integer.class,
                issueRequest.requestId())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT workshop_id FROM sales_delivery_warehouse_actions WHERE request_id=?",UUID.class,
                issueRequest.requestId())).isEqualTo(workshop);
        assertThat(db.queryForObject("SELECT responsible_id FROM sales_delivery_warehouse_actions WHERE request_id=?",UUID.class,
                issueRequest.requestId())).isEqualTo(w.employeeId());
        assertThat(processing.get(laser.id()).canAssign()).isFalse();
        assertThatThrownBy(()->processing.assign(laser.id(),new DeliveryProcessingContracts.Assignment(
                issued.revision(),workshop,w.employeeId(),UUID.randomUUID())))
                .isInstanceOf(ApiException.class).hasMessageContaining("仓库");
        assertThatThrownBy(()->db.update("UPDATE sales_shipment_delivery_components SET processing_responsible_id=NULL WHERE id=?",laser.id()))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(processing.get(laser.id()).version()).isEqualTo(issued.revision());
        var started=processing.start(laser.id(),new DeliveryProcessingContracts.Start(
                issued.revision(),w.warehouseId(),UUID.randomUUID()));
        assertThat(started.startedAt()).isNotNull();

        UUID sixRequestId=UUID.randomUUID();
        var sixRequest=new DeliveryProcessingContracts.Report(started.version(),new BigDecimal("6"),
                "LASER","第一批激光打印及检验完成6个",sixRequestId);
        var afterSix=processing.report(laser.id(),sixRequest);
        assertThat(afterSix.completedQtyExact()).isEqualTo("6");
        assertThat(afterSix.remainingQtyExact()).isEqualTo("4");
        var replayedSix=processing.report(laser.id(),sixRequest);
        assertThat(replayedSix.version()).isEqualTo(afterSix.version());
        assertThat(replayedSix.completedQtyExact()).isEqualTo("6");
        assertThat(db.queryForObject("SELECT count(*) FROM sales_delivery_processing_events WHERE request_id=?",Integer.class,
                sixRequestId)).isEqualTo(1);
        assertThatThrownBy(()->processing.report(laser.id(),new DeliveryProcessingContracts.Report(
                afterSix.version(),new BigDecimal("5"),"LASER","不得超出余下4个",UUID.randomUUID())))
                .isInstanceOf(ApiException.class).hasMessageContaining("超过");
        assertThat(processing.get(laser.id()).version()).isEqualTo(afterSix.version());
        var completed=processing.report(laser.id(),new DeliveryProcessingContracts.Report(afterSix.version(),
                new BigDecimal("4"),"LASER","第二批激光打印及检验完成4个",UUID.randomUUID()));
        assertThat(completed.completedQtyExact()).isEqualTo("10");
        assertThat(completed.remainingQtyExact()).isEqualTo("0");
        assertThat(completed.completedAt()).isNotNull();
        assertThat(completed.receivedAt()).isNull();
        assertThat(db.queryForObject("SELECT count(*) FROM sales_delivery_processing_events WHERE component_id=?",Integer.class,
                laser.id())).isEqualTo(2);
        assertThat(db.queryForObject("SELECT sum(quantity) FROM sales_delivery_processing_events WHERE component_id=?",BigDecimal.class,
                laser.id())).isEqualByComparingTo("10");
        assertThat(balance(w.warehouseId(),w.goodsA())).isZero();
        assertThat(balance(w.warehouseId(),w.goodsB())).isEqualByComparingTo("10");
        assertThat(balance(w.warehouseId(),w.goodsE())).isEqualByComparingTo("5");

        assertThatThrownBy(()->shipments.transitionWarehouseWork(r.shipment(),pick(r)))
                .isInstanceOf(ApiException.class).hasMessageContaining("收回");
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,r.orderItem())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",Integer.class,
                r.shipment())).isZero();
        var received=shipments.processingWarehouseWork(r.shipment(),laser.id(),"RECEIVE",
                new SalesShipmentDeliveryService.ProcessingWarehouseAction(completed.version(),w.warehouseId(),
                        "激光实际收回库位",UUID.randomUUID(),"仓库按原发出实物收回已加工B共10个"));
        assertThat(received.processingReceivedAt()).isNotNull();
        assertThat(received.processedQty()).isEqualByComparingTo("10");
        shipments.transitionWarehouseWork(r.shipment(),pick(r));
        assertThat(balance(w.warehouseId(),w.goodsA())).isZero();
        assertThat(balance(w.warehouseId(),w.goodsB())).isZero();
        assertThat(balance(w.warehouseId(),w.goodsE())).isZero();
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,r.orderItem()))
                .isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,r.orderItem())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=? AND direction=-1",Integer.class,
                r.shipment())).isEqualTo(2);
        assertThatThrownBy(()->shipments.reverse(r.shipment())).isInstanceOf(ApiException.class).hasMessageContaining("退货");
    }
}
