package com.uten.imp.businesschain;

import com.uten.imp.common.delivery.BomDeliveryService;
import com.uten.imp.common.delivery.DeliveryPlan;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.execution.DeliveryProcessingContracts;
import com.uten.imp.features.production.execution.DeliveryProcessingService;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.shipment.SalesShipmentDeliveryService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
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
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** A real ROOT_OUTPUT private reservation survives actual whole-product laser processing and shipment. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.production.readiness-reconcile.enabled=false"})
class SalesDeliveryOrderClaimEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesOrderService orders;
    @Autowired com.uten.imp.features.sales.order.SalesOrderDeliveryService savedDeliveries;
    @Autowired com.uten.imp.features.sales.order.SalesOrderItemRepository orderItems;
    @Autowired SalesShipmentService shipments;
    @Autowired MaterialAnalysisService analyses;
    @Autowired BomDeliveryService boms;
    @Autowired DeliveryProcessingService processing;
    FullChainEndToEndTest fixture;
    SalesBomDeliveryEndToEndTest support;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);support=new SalesBomDeliveryEndToEndTest();beans.autowireBean(support);support.fixture=fixture;}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void roundedPhysicalClaimConsumesOnlyItsFrozenMarginalOrderCreditAndCannotUseAnotherWarehouse() throws Exception {
        smallUnitClaim("0.06","0.0001","0.06",false,true);
    }

    @Test void mixedOriginalClaimAndPublicRemainderDoNotDebitThePublicPartAsOrderReservation() throws Exception {
        smallUnitClaim("0.16","0.0001","0.1",true,false);
    }

    private void smallUnitClaim(String rowQty,String receiptQty,String rowCredit,boolean publicRemainder,boolean otherWarehouseNegative) throws Exception {
        String tag="claim-small-"+UUID.randomUUID().toString().substring(0,7);
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());fixture.seedGoodsSources(Map.of(w.goodsA(),"BUY"));
        UUID alt=UUID.randomUUID();BigDecimal rate=new BigDecimal("0.001");
        db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,'微量订单单位','使用')",alt,"CLAIM-ALT-"+alt);
        var snapshot=boms.snapshot(w.goodsA());
        var request=fixture.orderRequest(w,w.goodsA(),rowQty,"100");
        var line=request.getItems().getFirst();line.setUnitId(alt);line.setUnitRate(rate);
        var plan=new DeliveryPlan(1,DeliveryPlan.Mode.ASSEMBLED,DeliveryPlan.Packaging.ORIGINAL,List.of(),
                List.of(new DeliveryPlan.Process(List.of(),DeliveryPlan.Operation.LASER,true)),snapshot.bomFingerprint());
        line.setDeliveryPlan(boms.resolve(w.goodsA(),alt,rate,new BigDecimal(rowQty),plan).deliveryPlan());
        UUID order=orders.create(request).getId();orders.approve(order);fixture.confirmInitialSalesFinance(order);
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        var analysis=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),tag,List.of(
                new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,com.uten.imp.common.time.BusinessTime.today(),new BigDecimal(rowQty)))));
        UUID purchase=ReflectionTestUtils.invokeMethod(fixture,"approvePurchaseForAnalysis",w,analysis,w.goodsA());
        fixture.receiveAndPassPurchase(w,purchase,w.goodsA(),new BigDecimal(receiptQty),tag+"-receipt");
        fixture.loginAs(w.superAdminUserId());
        UUID original=db.queryForObject("SELECT sales_reservation_id FROM preplan_root_output_events WHERE analysis_item_id=? AND event_kind='FULFILL' ORDER BY created_at,id LIMIT 1",UUID.class,analysis.products().getFirst().analysisLineId());
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo(rowCredit);
        assertThat(db.queryForObject("SELECT qty-consumed_qty-released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isEqualByComparingTo(receiptQty);
        if(publicRemainder) ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStockZeroPriceAt",w,w.goodsA(),new BigDecimal("0.0001"),w.warehouseId());
        var shipmentRequest=fixture.shipmentRequest(w,item,w.goodsA(),rowQty);
        shipmentRequest.getItems().getFirst().setUnitId(alt);shipmentRequest.getItems().getFirst().setUnitRate(rate);
        String precisionKey="delivery.physical:"+com.uten.imp.common.util.CanonicalFingerprint.sha256(List.of(w.goodsA().toString(),"[]"));
        UUID shipment;
        try(var ignored=com.uten.imp.common.finance.BusinessPrecisionContext.use(Map.of(precisionKey,
                new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(4,"HALF_UP")))) {
            shipment=shipments.create(shipmentRequest).getId();
        }
        shipments.confirmSales(shipment,0L);ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        var component=support.physical(shipment).getFirst();
        BigDecimal physical=new BigDecimal(publicRemainder?"0.0002":"0.0001");
        assertThat(component.quantity()).isEqualByComparingTo(physical);
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);
        UUID workshop=(UUID)ReflectionTestUtils.getField(assignment,"workshopId"),worker=(UUID)ReflectionTestUtils.getField(assignment,"workerId");
        var task=processing.assign(component.id(),new DeliveryProcessingContracts.Assignment(component.revision(),workshop,worker,UUID.randomUUID()));
        UUID alternateWarehouse=null;
        if(otherWarehouseNegative) {
            alternateWarehouse=UUID.randomUUID();
            db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,'非原订单实物仓','使用')",alternateWarehouse,"CLAIM-OTHER-"+alternateWarehouse);
            ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStockZeroPriceAt",w,w.goodsA(),new BigDecimal("0.0001"),alternateWarehouse);
            UUID wrongWarehouse=alternateWarehouse;long version=task.version();
            assertThatThrownBy(()->shipments.processingWarehouseWork(shipment,component.id(),"ISSUE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(
                    version,wrongWarehouse,"异仓公共实物不能冒充原订单占用",UUID.randomUUID(),"错误尝试以异仓公共实物替代原仓订单原件"))).isInstanceOf(ApiException.class);
            assertThat(db.queryForObject("SELECT count(*) FROM v_sales_delivery_order_claim_active WHERE component_id=?",Integer.class,component.id())).isZero();
            assertThat(db.queryForObject("SELECT consumed_qty+released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isZero();
        }
        var issued=shipments.processingWarehouseWork(shipment,component.id(),"ISSUE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(
                task.version(),w.warehouseId(),"原订单微量实物",UUID.randomUUID(),"交接原订单实物及明确公共余量至加工"));
        assertThat(db.queryForObject("SELECT sum(quantity) FROM v_sales_delivery_order_claim_active WHERE component_id=?",BigDecimal.class,component.id())).isEqualByComparingTo(receiptQty);
        task=processing.start(component.id(),new DeliveryProcessingContracts.Start(issued.revision(),w.warehouseId(),UUID.randomUUID()));
        task=processing.report(component.id(),new DeliveryProcessingContracts.Report(task.version(),physical,"LASER","所报微量交付件全部完成激光并检验",UUID.randomUUID()));
        shipments.processingWarehouseWork(shipment,component.id(),"RECEIVE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(
                task.version(),w.warehouseId(),"原订单加工收回库位",UUID.randomUUID(),"实际收回并核验完整加工交付件"));
        shipments.transitionWarehouseWork(shipment,support.pick(new SalesBomDeliveryEndToEndTest.Ready(w,order,item,shipment)));
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isZero();
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo(rowQty);
        assertThat(db.queryForObject("SELECT consumed_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isEqualByComparingTo(receiptQty);
        assertThat(db.queryForObject("SELECT sum(quantity_row) FROM sales_delivery_order_claim_row_events WHERE component_id=? AND event_type='CONSUME'",BigDecimal.class,component.id())).isEqualByComparingTo(rowCredit);
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isZero();
        if(alternateWarehouse!=null)assertThat(support.balance(alternateWarehouse,w.goodsA())).isEqualByComparingTo("0.0001");
    }

    @Test void rootOutputOrderReservationIsClaimedOnceAndConsumedOnlyByItsRealProcessedShipment() {
        String tag="order-claim-"+UUID.randomUUID().toString().substring(0,7);
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());fixture.seedGoodsSources(Map.of(w.goodsA(),"BUY"));
        var snapshot=boms.snapshot(w.goodsA());
        var request=fixture.orderRequest(w,w.goodsA(),"10","100");
        var preview=boms.resolve(w.goodsA(),w.unitId(),BigDecimal.ONE,BigDecimal.TEN,
                new DeliveryPlan(1,DeliveryPlan.Mode.ASSEMBLED,DeliveryPlan.Packaging.ORIGINAL,
                    List.of(),List.of(new DeliveryPlan.Process(List.of(),DeliveryPlan.Operation.LASER,true)),snapshot.bomFingerprint()));
        assertThat(preview.issues()).isEmpty();request.getItems().getFirst().setDeliveryPlan(preview.deliveryPlan());
        UUID order=orders.create(request).getId();orders.approve(order);fixture.confirmInitialSalesFinance(order);
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        var analysis=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),tag,
                List.of(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,com.uten.imp.common.time.BusinessTime.today(),BigDecimal.TEN))));
        assertThat(analysis.products().getFirst().rootMaterialLineId()).isNotNull();
        UUID purchase=ReflectionTestUtils.invokeMethod(fixture,"approvePurchaseForAnalysis",w,analysis,w.goodsA());
        fixture.receiveAndPassPurchase(w,purchase,w.goodsA(),BigDecimal.TEN,tag+"-receipt");
        fixture.loginAs(w.superAdminUserId());
        UUID original=db.queryForObject("""
                SELECT sales_reservation_id FROM preplan_root_output_events
                WHERE analysis_item_id=? AND event_kind='FULFILL' ORDER BY created_at,id LIMIT 1
                """,UUID.class,analysis.products().getFirst().analysisLineId());
        assertThat(original).isNotNull();
        String identity=db.queryForObject("SELECT fn_sales_delivery_order_claim_identity(reservation)::text FROM stock_reservations reservation WHERE id=?",String.class,original);
        assertThat(db.queryForObject("SELECT qty-consumed_qty-released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("10");
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isEqualByComparingTo("10");
        // Separate proxied transactions: the public preview and admitted continuation both need real KEY SHARE unit locks.
        var continued=savedDeliveries.resolveOrderItem(orderItems.findById(item).orElseThrow(),BigDecimal.TEN);
        assertThat(continued.items()).singleElement().satisfies(actual->{
            assertThat(actual.path()).isEmpty();assertThat(actual.quantityExact()).isEqualTo("10");assertThat(actual.operations()).contains(DeliveryPlan.Operation.LASER);
        });

        UUID shipment=fixture.createShipment(w,item,w.goodsA(),"10");shipments.confirmSales(shipment,0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        var ready=new SalesBomDeliveryEndToEndTest.Ready(w,order,item,shipment);
        var component=support.physical(shipment).getFirst();
        assertThat(support.physical(shipment)).hasSize(1);assertThat(component.path()).isEmpty();
        assertThat(component.operations()).containsExactly("LASER");
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);
        UUID workshop=(UUID)ReflectionTestUtils.getField(assignment,"workshopId"),worker=(UUID)ReflectionTestUtils.getField(assignment,"workerId");
        var task=processing.assign(component.id(),new DeliveryProcessingContracts.Assignment(component.revision(),workshop,worker,UUID.randomUUID()));
        var issueRequest=new SalesShipmentDeliveryService.ProcessingWarehouseAction(task.version(),w.warehouseId(),"原订单实物库位",UUID.randomUUID(),"仓库交接本订单原有已装好产品10个至激光车间");
        var issued=shipments.processingWarehouseWork(shipment,component.id(),"ISSUE",issueRequest);
        shipments.processingWarehouseWork(shipment,component.id(),"ISSUE",issueRequest);
        assertThat(db.queryForObject("SELECT sum(quantity) FROM v_sales_delivery_order_claim_active WHERE component_id=?",BigDecimal.class,component.id())).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT count(*) FROM stock_reservations WHERE owner_id=? AND owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')",Integer.class,component.id())).isZero();
        assertThat(db.queryForObject("SELECT released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isZero();
        assertThat(db.queryForObject("SELECT consumed_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM stock_reservations WHERE order_item_id=?",Integer.class,item)).isEqualTo(1);

        var cancelled=shipments.processingWarehouseWork(shipment,component.id(),"CANCEL_ISSUE",
                new SalesShipmentDeliveryService.ProcessingWarehouseAction(issued.revision(),w.warehouseId(),"原订单未加工实物退回库位",UUID.randomUUID(),"车间尚未开工，仓库实际收回原10个产品"));
        assertThat(cancelled.processingIssuedAt()).isNull();
        assertThat(db.queryForObject("SELECT count(*) FROM v_sales_delivery_order_claim_active WHERE component_id=?",Integer.class,component.id())).isZero();
        assertThat(db.queryForObject("SELECT qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT consumed_qty+released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isZero();
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("10");
        issued=shipments.processingWarehouseWork(shipment,component.id(),"ISSUE",
                new SalesShipmentDeliveryService.ProcessingWarehouseAction(cancelled.revision(),w.warehouseId(),"原订单再次交接库位",UUID.randomUUID(),"按新请求重新实际交接原10个产品至激光车间"));
        assertThat(db.queryForObject("SELECT sum(quantity) FROM v_sales_delivery_order_claim_active WHERE component_id=?",BigDecimal.class,component.id())).isEqualByComparingTo("10");

        task=processing.start(component.id(),new DeliveryProcessingContracts.Start(issued.revision(),w.warehouseId(),UUID.randomUUID()));
        task=processing.report(component.id(),new DeliveryProcessingContracts.Report(task.version(),BigDecimal.TEN,"LASER","原成品10个逐个激光打印并检验完成",UUID.randomUUID()));
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT consumed_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isZero();
        assertThatThrownBy(()->shipments.transitionWarehouseWork(shipment,support.pick(ready))).isInstanceOf(ApiException.class).hasMessageContaining("收回");
        shipments.processingWarehouseWork(shipment,component.id(),"RECEIVE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(
                task.version(),w.warehouseId(),"原订单激光收回库位",UUID.randomUUID(),"仓库实际收回原产品10个，数量不新增"));
        shipments.transitionWarehouseWork(shipment,support.pick(ready));
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isZero();
        assertThat(db.queryForObject("SELECT qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT consumed_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isZero();
        assertThat(db.queryForObject("SELECT fn_sales_delivery_order_claim_identity(reservation)::text FROM stock_reservations reservation WHERE id=?",String.class,original)).isEqualTo(identity);
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isZero();
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT count(*) FROM sales_delivery_order_claim_events event JOIN sales_delivery_order_claims claim ON claim.id=event.claim_id WHERE claim.reservation_id=? AND event.event_type='CONSUME'",Integer.class,original)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=? AND source_item_id=? AND direction=-1",Integer.class,shipment,component.id())).isEqualTo(1);
        assertThatThrownBy(()->shipments.reverse(shipment)).isInstanceOf(ApiException.class).hasMessageContaining("退货");
        assertThat(db.queryForObject("SELECT consumed_qty FROM stock_reservations WHERE id=?",BigDecimal.class,original)).isEqualByComparingTo("10");
    }
}
