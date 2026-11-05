package com.uten.imp.businesschain;

import com.uten.imp.common.delivery.BomDeliveryService;
import com.uten.imp.common.delivery.DeliveryPlan;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.execution.DeliveryProcessingContracts;
import com.uten.imp.features.production.execution.DeliveryProcessingService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
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

/** The row credit uses boxes; custody and stock use the original twenty basic units. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.production.readiness-reconcile.enabled=false"})
class SalesDeliverySourceReverseUnitsEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesOrderService orders;
    @Autowired SalesShipmentService shipments;
    @Autowired MaterialAnalysisService analyses;
    @Autowired BomDeliveryService boms;
    @Autowired DeliveryProcessingService processing;
    @Autowired PurchaseReceiptService receipts;
    FullChainEndToEndTest fixture;
    SalesBomDeliveryEndToEndTest support;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);support=new SalesBomDeliveryEndToEndTest();beans.autowireBean(support);support.fixture=fixture;}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    private record Ready(FullChainEndToEndTest.World world,UUID order,UUID item,UUID shipment,UUID receipt,
            UUID analysisItem,UUID originalReservation,SalesShipmentDeliveryService.Component component) {}

    @Test void cancelledUnprocessedBoxCustodyAllowsItsReceiptToReverseInRowUnits() {
        Ready r=ready("box-return");var w=r.world();
        var issued=issue(r);
        assertThatThrownBy(()->receipts.reverse(r.receipt())).isInstanceOf(ApiException.class);
        assertOriginal(r,"20","0","0","1");
        var returned=shipments.processingWarehouseWork(r.shipment(),r.component().id(),"CANCEL_ISSUE",
                new SalesShipmentDeliveryService.ProcessingWarehouseAction(issued.revision(),w.warehouseId(),
                        "原箱产品实物退回库位",UUID.randomUUID(),"未开工的二十个基本单位全部实际退回原仓"));
        assertThat(returned.processingIssuedAt()).isNull();
        assertThat(db.queryForObject("SELECT count(*) FROM v_sales_delivery_order_claim_active WHERE component_id=?",Integer.class,r.component().id())).isZero();
        receipts.reverse(r.receipt());
        assertThat(db.queryForObject("SELECT status FROM purchase_receipts WHERE id=?",Integer.class,r.receipt())).isEqualTo(-1);
        assertThat(db.queryForObject("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,r.analysisItem())).isZero();
        assertOriginal(r,"20","0","20","0");
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isZero();
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,r.item())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM preplan_root_output_events WHERE analysis_item_id=? AND event_kind='REVERSE'",Integer.class,r.analysisItem())).isEqualTo(1);
    }

    @Test void reportedOrShippedBoxKeepsItsOriginalReceiptAndCannotInventReturnedStock() {
        Ready r=ready("box-used");var w=r.world();
        var issued=issue(r);
        var task=processing.start(r.component().id(),new DeliveryProcessingContracts.Start(issued.revision(),w.warehouseId(),UUID.randomUUID()));
        task=processing.report(r.component().id(),new DeliveryProcessingContracts.Report(task.version(),new BigDecimal("20"),"LASER",
                "原箱二十个基本单位逐个加工检验完成",UUID.randomUUID()));
        assertThatThrownBy(()->receipts.reverse(r.receipt())).isInstanceOf(ApiException.class);
        assertOriginal(r,"20","0","0","1");
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isEqualByComparingTo("20");
        shipments.processingWarehouseWork(r.shipment(),r.component().id(),"RECEIVE",
                new SalesShipmentDeliveryService.ProcessingWarehouseAction(task.version(),w.warehouseId(),"加工收回原箱库位",
                        UUID.randomUUID(),"仓库实际收回二十个已加工基本单位，数量没有新增"));
        shipments.transitionWarehouseWork(r.shipment(),support.pick(new SalesBomDeliveryEndToEndTest.Ready(w,r.order(),r.item(),r.shipment())));
        assertOriginal(r,"20","20","0","0");
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,r.item())).isEqualByComparingTo("1");
        assertThatThrownBy(()->receipts.reverse(r.receipt())).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->shipments.reverse(r.shipment())).isInstanceOf(ApiException.class).hasMessageContaining("退货");
        assertThat(db.queryForObject("SELECT status FROM purchase_receipts WHERE id=?",Integer.class,r.receipt())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM preplan_root_output_events WHERE analysis_item_id=? AND event_kind='REVERSE'",Integer.class,r.analysisItem())).isZero();
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isZero();
        assertOriginal(r,"20","20","0","0");
    }

    private Ready ready(String prefix) {
        String tag=prefix+"-"+UUID.randomUUID().toString().substring(0,7);
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());fixture.seedGoodsSources(Map.of(w.goodsA(),"BUY"));
        UUID box=UUID.randomUUID();BigDecimal rate=new BigDecimal("20");
        db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,'箱','使用')",box,"DELIVERY-BOX-"+box);
        var snapshot=boms.snapshot(w.goodsA());
        var request=fixture.orderRequest(w,w.goodsA(),"1","100");var line=request.getItems().getFirst();
        line.setUnitId(box);line.setUnitRate(rate);
        line.setDeliveryPlan(boms.resolve(w.goodsA(),box,rate,BigDecimal.ONE,new DeliveryPlan(1,DeliveryPlan.Mode.ASSEMBLED,
                DeliveryPlan.Packaging.ORIGINAL,List.of(),List.of(new DeliveryPlan.Process(List.of(),DeliveryPlan.Operation.LASER,true)),snapshot.bomFingerprint())).deliveryPlan());
        UUID order=orders.create(request).getId();orders.approve(order);fixture.confirmInitialSalesFinance(order);
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        var analysis=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),tag,List.of(
                new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,com.uten.imp.common.time.BusinessTime.today(),BigDecimal.ONE))));
        UUID analysisItem=analysis.products().getFirst().analysisLineId();
        UUID purchase=ReflectionTestUtils.invokeMethod(fixture,"approvePurchaseForAnalysis",w,analysis,w.goodsA());
        UUID receipt=fixture.receiveAndPassPurchase(w,purchase,w.goodsA(),new BigDecimal("20"),tag+"-receipt");
        fixture.loginAs(w.superAdminUserId());
        UUID original=db.queryForObject("SELECT sales_reservation_id FROM preplan_root_output_events WHERE analysis_item_id=? AND event_kind='FULFILL'",UUID.class,analysisItem);
        assertThat(db.queryForObject("SELECT qty_source FROM preplan_root_output_events WHERE sales_reservation_id=? AND event_kind='FULFILL'",BigDecimal.class,original)).isEqualByComparingTo("1");
        var shipmentRequest=fixture.shipmentRequest(w,item,w.goodsA(),"1");
        shipmentRequest.getItems().getFirst().setUnitId(box);shipmentRequest.getItems().getFirst().setUnitRate(rate);
        UUID shipment=shipments.create(shipmentRequest).getId();shipments.confirmSales(shipment,0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        var component=support.physical(shipment).getFirst();
        assertThat(component.quantity()).isEqualByComparingTo("20");
        Ready ready=new Ready(w,order,item,shipment,receipt,analysisItem,original,component);
        assertOriginal(ready,"20","0","0","1");return ready;
    }
    private SalesShipmentDeliveryService.Component issue(Ready r) {
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","box-source-"+r.item());
        UUID workshop=(UUID)ReflectionTestUtils.getField(assignment,"workshopId"),worker=(UUID)ReflectionTestUtils.getField(assignment,"workerId");
        var task=processing.assign(r.component().id(),new DeliveryProcessingContracts.Assignment(r.component().revision(),workshop,worker,UUID.randomUUID()));
        return shipments.processingWarehouseWork(r.shipment(),r.component().id(),"ISSUE",
                new SalesShipmentDeliveryService.ProcessingWarehouseAction(task.version(),r.world().warehouseId(),"原箱实物库位",UUID.randomUUID(),
                        "将本订单原箱二十个基本单位实际交接加工"));
    }
    private void assertOriginal(Ready r,String quantity,String consumed,String released,String reservedRow) {
        assertThat(db.queryForObject("SELECT qty FROM stock_reservations WHERE id=?",BigDecimal.class,r.originalReservation())).isEqualByComparingTo(quantity);
        assertThat(db.queryForObject("SELECT consumed_qty FROM stock_reservations WHERE id=?",BigDecimal.class,r.originalReservation())).isEqualByComparingTo(consumed);
        assertThat(db.queryForObject("SELECT released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,r.originalReservation())).isEqualByComparingTo(released);
        assertThat(db.queryForObject("SELECT reserved_qty FROM sales_order_items WHERE id=?",BigDecimal.class,r.item())).isEqualByComparingTo(reservedRow);
    }
}
