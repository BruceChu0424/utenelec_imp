package com.uten.imp.businesschain;

import com.uten.imp.common.delivery.BomDeliveryService;
import com.uten.imp.common.delivery.DeliveryPlan;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.production.execution.DeliveryProcessingService;
import com.uten.imp.features.production.execution.DeliveryProcessingContracts;
import com.uten.imp.features.sales.shipment.SalesShipmentDeliveryService;
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
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** Real private IQC receipts, exact component fulfillment and unprocessed custody returned to its original lot. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.production.readiness-reconcile.enabled=false"})
class SalesDeliveryPrivateSourceEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesOrderService orders;
    @Autowired SalesShipmentService shipments;
    @Autowired MaterialAnalysisService analyses;
    @Autowired BomDeliveryService boms;
    @Autowired DeliveryProcessingService processing;
    FullChainEndToEndTest fixture;
    SalesBomDeliveryEndToEndTest support;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);support=new SalesBomDeliveryEndToEndTest();beans.autowireBean(support);support.fixture=fixture;}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void customerFrontierIncludesPeriodicGoodsOnlyThroughTransparentDeliveryAncestors() {
        var w=fixture.seedWorld("delivery-periodic-"+UUID.randomUUID().toString().substring(0,6));
        fixture.loginAs(w.superAdminUserId());
        UUID kg=UUID.randomUUID(),periodicC=UUID.randomUUID(),periodicE=UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,'千克','使用')",kg,"DELIVERY-KG-"+kg);
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(?,'MASS','KG','MANUAL_GOVERNANCE')",kg);
        for(UUID goods:List.of(periodicC,periodicE)) db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,issue_method,periodic_cost_basis,default_supplier_id,code_sequence)
                VALUES(?,?,'客户按BOM交付的重量料','采购','使用',?,'PERIODIC','OWN',?,(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))
                """,goods,"DELIVERY-PERIODIC-"+goods,kg,w.supplierId());
        db.update("UPDATE goods_bom_items SET component_goods_id=?,hard_gate=false WHERE goods_id=? AND component_goods_id=?",periodicC,w.goodsB(),w.goodsC());
        db.update("UPDATE goods_bom_items SET component_goods_id=?,hard_gate=false WHERE goods_id=? AND component_goods_id=?",periodicE,w.goodsA(),w.goodsE());
        var snapshot=boms.snapshot(w.goodsA());
        var b=snapshot.root().children().stream().filter(n->n.goodsId().equals(w.goodsB())).findFirst().orElseThrow();
        for(boolean splitB:List.of(false,true)) {
            var request=fixture.orderRequest(w,w.goodsA(),"5","100");
            request.getItems().getFirst().setDeliveryPlan(new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,
                    splitB?List.of(new DeliveryPlan.NodeMode(b.path(),DeliveryPlan.NodeDelivery.CHILDREN)):List.of(),List.of(),snapshot.bomFingerprint()));
            UUID order=orders.create(request).getId();orders.approve(order);fixture.confirmInitialSalesFinance(order);
            UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
            var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"delivery-periodic-"+order,
                    List.of(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,LocalDate.now(),new BigDecimal("5")))));
            var e=view.flatMaterials().stream().filter(m->m.goodsId().equals(periodicE)).findFirst().orElseThrow();
            assertThat(e.deliveryFrontier()).isTrue();assertThat(e.requiredQty()).isEqualByComparingTo("5");
            var cs=view.flatMaterials().stream().filter(m->m.goodsId().equals(periodicC)).toList();
            if(splitB) {
                assertThat(cs).singleElement().satisfies(c->{assertThat(c.deliveryFrontier()).isTrue();assertThat(c.requiredQty()).isEqualByComparingTo("30");});
            } else assertThat(cs).isEmpty();
        }
    }

    @Test void qualifiedPrivateComponentShipsWithoutBorrowingPublicAndDirectReversalCannotInventReturnedStock() {
        var w=fixture.seedWorld("delivery-private-"+UUID.randomUUID().toString().substring(0,6));
        fixture.loginAs(w.superAdminUserId());
        db.update("UPDATE goods SET source_type='采购',default_supplier_id=? WHERE id=?",w.supplierId(),w.goodsB());
        support.stock(w,w.goodsE(),"5");
        var snapshot=boms.snapshot(w.goodsA());
        var plan=new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,List.of(),List.of(),snapshot.bomFingerprint());
        var request=fixture.orderRequest(w,w.goodsA(),"5","100");request.getItems().getFirst().setDeliveryPlan(plan);
        UUID order=orders.create(request).getId();orders.approve(order);fixture.confirmInitialSalesFinance(order);
        UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        var analysis=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"delivery-private-"+order,
                List.of(new PreviewItem("SALES_ORDER_ITEM",orderItem,null,null,null,null,null,LocalDate.now(),new BigDecimal("5")))));
        assertThat(analysis.products().getFirst().canSchedule()).isFalse();
        assertThat(analysis.flatMaterials().stream().filter(m->m.level()==0)).isEmpty();
        UUID purchaseItem=ReflectionTestUtils.invokeMethod(fixture,"approvePurchaseForAnalysis",w,analysis,w.goodsB());
        fixture.receiveAndPassPurchase(w,purchaseItem,w.goodsB(),new BigDecimal("10"),"delivery-private-"+order);
        fixture.loginAs(w.superAdminUserId());
        UUID material=analyses.detail(analysis.analysisId()).flatMaterials().stream()
                .filter(m->m.deliveryFrontier()&&m.goodsId().equals(w.goodsB())).findFirst().orElseThrow().materialLineId();
        UUID originalReservation=db.queryForObject("""
                SELECT DISTINCT reservation.id FROM preplan_stock_entitlement_events event
                JOIN stock_reservations reservation ON reservation.id=event.stock_reservation_id
                WHERE event.beneficiary_analysis_material_id=? AND event.event_type='ORIGIN_IQC'
                """,UUID.class,material);
        assertThat(db.queryForObject("SELECT qty-consumed_qty-released_qty FROM stock_reservations WHERE id=?",BigDecimal.class,originalReservation))
                .isEqualByComparingTo("10");
        fixture.loginAs(w.superAdminUserId());
        UUID shipment=fixture.createShipment(w,orderItem,w.goodsA(),"5");shipments.confirmSales(shipment,0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        var ready=new SalesBomDeliveryEndToEndTest.Ready(w,order,orderItem,shipment);
        shipments.transitionWarehouseWork(shipment,support.pick(ready));
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isZero();
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isZero();
        assertThat(db.queryForObject("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,
                analysis.products().getFirst().analysisLineId())).isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT sum(quantity) FROM sales_delivery_entitlement_handoffs WHERE source_reservation_id=?",BigDecimal.class,originalReservation))
                .isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=?",Integer.class,analysis.analysisId())).isZero();
        assertThatThrownBy(()->shipments.reverse(shipment)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isZero();
        assertThat(db.queryForObject("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,
                analysis.products().getFirst().analysisLineId())).isEqualByComparingTo("5");
        assertThat(analyses.detail(analysis.analysisId()).products().getFirst().remainingQty()).isZero();
    }

    @Test void unprocessedWarehouseCustodyReturnsToTheExactPrivateReceiptAfterWorkerCancelsStart() {
        var w=fixture.seedWorld("delivery-return-"+UUID.randomUUID().toString().substring(0,6));
        fixture.loginAs(w.superAdminUserId());
        db.update("UPDATE goods SET source_type='采购',default_supplier_id=? WHERE id=?",w.supplierId(),w.goodsB());
        support.stock(w,w.goodsE(),"5");
        var snapshot=boms.snapshot(w.goodsA());
        var edge=snapshot.root().children().stream().filter(n->n.goodsId().equals(w.goodsB())).findFirst().orElseThrow().path();
        var request=fixture.orderRequest(w,w.goodsA(),"5","100");
        request.getItems().getFirst().setDeliveryPlan(new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,
                List.of(),List.of(new DeliveryPlan.Process(edge,DeliveryPlan.Operation.LASER,true)),snapshot.bomFingerprint()));
        UUID order=orders.create(request).getId();orders.approve(order);fixture.confirmInitialSalesFinance(order);
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"delivery-return-"+order,
                List.of(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,LocalDate.now(),new BigDecimal("5")))));
        UUID purchase=ReflectionTestUtils.invokeMethod(fixture,"approvePurchaseForAnalysis",w,view,w.goodsB());
        fixture.receiveAndPassPurchase(w,purchase,w.goodsB(),new BigDecimal("10"),"delivery-return-"+order);
        fixture.loginAs(w.superAdminUserId());
        UUID shipment=fixture.createShipment(w,item,w.goodsA(),"5");shipments.confirmSales(shipment,0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        UUID component=support.physical(shipment).stream().filter(c->c.goodsId().equals(w.goodsB())).findFirst().orElseThrow().id();
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","delivery-return-"+component);
        UUID workshop=(UUID)ReflectionTestUtils.getField(assignment,"workshopId");
        UUID worker=(UUID)ReflectionTestUtils.getField(assignment,"workerId");
        var task=processing.get(component);
        task=processing.assign(component,new DeliveryProcessingContracts.Assignment(task.version(),workshop,worker,UUID.randomUUID()));
        var issued=shipments.processingWarehouseWork(shipment,component,"ISSUE",
                new SalesShipmentDeliveryService.ProcessingWarehouseAction(task.version(),w.warehouseId(),"原私有物料库位",UUID.randomUUID(),"仓库实际发至激光车间"));
        assertThatThrownBy(()->shipments.delete(shipment)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(db.queryForObject("SELECT sum(quantity) FROM sales_delivery_entitlement_handoffs WHERE component_id=?",BigDecimal.class,component))
                .isEqualByComparingTo("10");
        task=processing.start(component,new DeliveryProcessingContracts.Start(issued.revision(),w.warehouseId(),UUID.randomUUID()));
        task=processing.cancelStart(component,new DeliveryProcessingContracts.CancelStart(task.version(),UUID.randomUUID()));
        assertThat(db.queryForObject("SELECT sum(qty-consumed_qty-released_qty) FROM stock_reservations WHERE owner_id=? AND owner_type IN('SALES_DELIVERY_COMPONENT_SHIPMENT','SALES_DELIVERY_PROCESSING') AND status=0",BigDecimal.class,component))
                .isEqualByComparingTo("10");
        shipments.processingWarehouseWork(shipment,component,"CANCEL_ISSUE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(
                task.version(),w.warehouseId(),"原私有物料库位",UUID.randomUUID(),"尚未加工，仓库实际收回原件"));
        assertThat(db.queryForObject("SELECT count(*) FROM sales_delivery_entitlement_restores restored JOIN sales_delivery_entitlement_handoffs handoff ON handoff.id=restored.handoff_id WHERE handoff.component_id=?",Integer.class,component))
                .isEqualTo(1);
        assertThat(db.queryForObject("SELECT sum(lot.remaining_qty) FROM v_preplan_stock_entitlement_lot_balance lot JOIN production_material_analysis_materials material ON material.id=lot.beneficiary_analysis_material_id WHERE material.analysis_id=? AND material.goods_id=?",BigDecimal.class,view.analysisId(),w.goodsB()))
                .isEqualByComparingTo("10");
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,view.products().getFirst().analysisLineId())).isZero();
        shipments.delete(shipment);
        assertThat(db.queryForObject("SELECT state FROM sales_delivery_fulfillment_groups WHERE shipment_id=?",String.class,shipment))
                .isEqualTo("CANCELLED");
        assertThat(db.queryForObject("SELECT count(*) FROM sales_shipment_delivery_components WHERE id=?",Integer.class,component)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM sales_delivery_warehouse_actions WHERE component_id=?",Integer.class,component)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT sum(lot.remaining_qty) FROM v_preplan_stock_entitlement_lot_balance lot JOIN production_material_analysis_materials material ON material.id=lot.beneficiary_analysis_material_id WHERE material.analysis_id=? AND material.goods_id=?",BigDecimal.class,view.analysisId(),w.goodsB()))
                .isEqualByComparingTo("10");
    }

    @Test void splitAssemblyForwardsDepthTwoPrivateSupplyAndShipsOnlyItsActualChildren() {
        var w=fixture.seedWorld("delivery-deep-"+UUID.randomUUID().toString().substring(0,6));
        fixture.loginAs(w.superAdminUserId());
        db.update("UPDATE goods SET source_type='采购',default_supplier_id=? WHERE id=?",w.supplierId(),w.goodsC());
        support.stock(w,w.goodsD(),"50");support.stock(w,w.goodsE(),"5");
        var snapshot=boms.snapshot(w.goodsA());
        var b=snapshot.root().children().stream().filter(n->n.goodsId().equals(w.goodsB())).findFirst().orElseThrow();
        var request=fixture.orderRequest(w,w.goodsA(),"5","100");
        request.getItems().getFirst().setDeliveryPlan(new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,
                List.of(new DeliveryPlan.NodeMode(b.path(),DeliveryPlan.NodeDelivery.CHILDREN)),List.of(),snapshot.bomFingerprint()));
        UUID order=orders.create(request).getId();orders.approve(order);fixture.confirmInitialSalesFinance(order);
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"delivery-deep-"+order,
                List.of(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,LocalDate.now(),new BigDecimal("5")))));
        var c=view.flatMaterials().stream().filter(m->m.deliveryFrontier()&&m.goodsId().equals(w.goodsC())).findFirst().orElseThrow();
        assertThat(c.level()).isEqualTo(2);assertThat(c.actionable()).isTrue();assertThat(c.requiredQty()).isEqualByComparingTo("30");
        assertThat(db.queryForObject("SELECT fn_preplan_original_material_capacity(?)",BigDecimal.class,c.materialLineId()))
                .isEqualByComparingTo("30");
        UUID purchase=ReflectionTestUtils.invokeMethod(fixture,"approvePurchaseForAnalysis",w,view,w.goodsC());
        fixture.receiveAndPassPurchase(w,purchase,w.goodsC(),new BigDecimal("30"),"delivery-deep-"+order);
        fixture.loginAs(w.superAdminUserId());
        UUID shipment=fixture.createShipment(w,item,w.goodsA(),"5");shipments.confirmSales(shipment,0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        assertThat(support.physical(shipment)).extracting(SalesShipmentDeliveryService.Component::goodsId)
                .containsExactlyInAnyOrder(w.goodsC(),w.goodsD(),w.goodsE());
        shipments.transitionWarehouseWork(shipment,support.pick(new SalesBomDeliveryEndToEndTest.Ready(w,order,item,shipment)));
        assertThat(support.balance(w.warehouseId(),w.goodsA())).isZero();assertThat(support.balance(w.warehouseId(),w.goodsB())).isZero();
        assertThat(support.balance(w.warehouseId(),w.goodsC())).isZero();
        assertThat(db.queryForObject("SELECT sum(quantity) FROM sales_delivery_entitlement_handoffs WHERE source_material_id=?",BigDecimal.class,c.materialLineId()))
                .isEqualByComparingTo("30");
        assertThat(db.queryForObject("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,view.products().getFirst().analysisLineId()))
                .isEqualByComparingTo("5");
    }

    @Test void returnedPrivateProcessingLotCanBeIssuedAgainAndShipsItsOriginalKitOnlyOnce() {
        var w=fixture.seedWorld("delivery-reissue-"+UUID.randomUUID().toString().substring(0,6));
        fixture.loginAs(w.superAdminUserId());
        db.update("UPDATE goods SET source_type='采购',default_supplier_id=? WHERE id=?",w.supplierId(),w.goodsB());
        support.stock(w,w.goodsE(),"5");
        var snapshot=boms.snapshot(w.goodsA());
        var edge=snapshot.root().children().stream().filter(n->n.goodsId().equals(w.goodsB())).findFirst().orElseThrow().path();
        var request=fixture.orderRequest(w,w.goodsA(),"5","100");
        request.getItems().getFirst().setDeliveryPlan(new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,
                List.of(),List.of(new DeliveryPlan.Process(edge,DeliveryPlan.Operation.LASER,true)),snapshot.bomFingerprint()));
        UUID order=orders.create(request).getId();orders.approve(order);fixture.confirmInitialSalesFinance(order);
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"delivery-reissue-"+order,
                List.of(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,LocalDate.now(),new BigDecimal("5")))));
        UUID purchase=ReflectionTestUtils.invokeMethod(fixture,"approvePurchaseForAnalysis",w,view,w.goodsB());
        fixture.receiveAndPassPurchase(w,purchase,w.goodsB(),new BigDecimal("10"),"delivery-reissue-"+order);
        fixture.loginAs(w.superAdminUserId());
        UUID shipment=fixture.createShipment(w,item,w.goodsA(),"5");shipments.confirmSales(shipment,0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        var ready=new SalesBomDeliveryEndToEndTest.Ready(w,order,item,shipment);
        UUID component=support.physical(shipment).stream().filter(c->c.goodsId().equals(w.goodsB())).findFirst().orElseThrow().id();
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","delivery-reissue-"+component);
        UUID workshop=(UUID)ReflectionTestUtils.getField(assignment,"workshopId"),worker=(UUID)ReflectionTestUtils.getField(assignment,"workerId");
        var task=processing.get(component);
        task=processing.assign(component,new DeliveryProcessingContracts.Assignment(task.version(),workshop,worker,UUID.randomUUID()));
        var issued=shipments.processingWarehouseWork(shipment,component,"ISSUE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(
                task.version(),w.warehouseId(),"原私有到货实际发出",UUID.randomUUID(),"原私有采购件交至激光车间"));
        UUID original=db.queryForObject("SELECT source_reservation_id FROM sales_delivery_entitlement_handoffs WHERE component_id=?",UUID.class,component);
        task=processing.start(component,new DeliveryProcessingContracts.Start(issued.revision(),w.warehouseId(),UUID.randomUUID()));
        task=processing.cancelStart(component,new DeliveryProcessingContracts.CancelStart(task.version(),UUID.randomUUID()));
        var returned=shipments.processingWarehouseWork(shipment,component,"CANCEL_ISSUE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(
                task.version(),w.warehouseId(),"原件未加工退回",UUID.randomUUID(),"未加工的原10件实物已由仓库实际收回"));
        assertThat(db.queryForObject("SELECT sum(lot.remaining_qty) FROM v_preplan_stock_entitlement_lot_balance lot WHERE lot.stock_reservation_id=?",BigDecimal.class,original))
                .isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,view.products().getFirst().analysisLineId())).isZero();
        issued=shipments.processingWarehouseWork(shipment,component,"ISSUE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(
                returned.revision(),w.warehouseId(),"同源原件再次发出",UUID.randomUUID(),"重新实际发出恢复的同一原私有批次10件"));
        assertThat(db.queryForObject("SELECT count(DISTINCT source_reservation_id) FROM sales_delivery_entitlement_handoffs WHERE component_id=?",Integer.class,component)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM sales_delivery_entitlement_handoffs WHERE component_id=?",Integer.class,component)).isEqualTo(2);
        assertThat(db.queryForObject("""
                SELECT sum(handoff.quantity) FROM sales_delivery_entitlement_handoffs handoff
                WHERE handoff.component_id=? AND NOT EXISTS(SELECT 1 FROM sales_delivery_entitlement_restores restored WHERE restored.handoff_id=handoff.id)
                """,BigDecimal.class,component)).isEqualByComparingTo("10");
        task=processing.start(component,new DeliveryProcessingContracts.Start(issued.revision(),w.warehouseId(),UUID.randomUUID()));
        task=processing.report(component,new DeliveryProcessingContracts.Report(task.version(),new BigDecimal("4"),"LASER","本次4件已完成全部激光及检验要求",UUID.randomUUID()));
        assertThatThrownBy(()->shipments.transitionWarehouseWork(shipment,support.pick(ready))).isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("加工");
        task=processing.report(component,new DeliveryProcessingContracts.Report(task.version(),new BigDecimal("6"),"LASER","剩余6件全部完成并检验，原10件均已完成",UUID.randomUUID()));
        shipments.processingWarehouseWork(shipment,component,"RECEIVE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(
                task.version(),w.warehouseId(),"原10件加工合格收回",UUID.randomUUID(),"按原发出数量核对并实际收回完整10件加工成品"));
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isEqualByComparingTo("10");
        shipments.transitionWarehouseWork(shipment,support.pick(ready));
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isZero();assertThat(support.balance(w.warehouseId(),w.goodsE())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM sales_delivery_entitlement_restores restored JOIN sales_delivery_entitlement_handoffs handoff ON handoff.id=restored.handoff_id WHERE handoff.component_id=?",Integer.class,component)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_reservations WHERE owner_id=? AND owner_type IN('SALES_DELIVERY_COMPONENT_SHIPMENT','SALES_DELIVERY_PROCESSING') AND status=0 AND NOT is_deleted",Integer.class,component)).isZero();
        assertThat(db.queryForObject("SELECT sum(event.order_qty) FROM sales_delivery_fulfillment_events event JOIN sales_delivery_fulfillment_allocations allocation ON allocation.id=event.allocation_id WHERE allocation.analysis_item_id=? AND event.event_type='FULFILL'",BigDecimal.class,view.products().getFirst().analysisLineId())).isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,view.products().getFirst().analysisLineId())).isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE goods_id=? AND direction=1",Integer.class,w.goodsB())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=? AND direction=-1",Integer.class,shipment)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE goods_id IN(?,?,?)",Integer.class,w.goodsA(),w.goodsC(),w.goodsD())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=?",Integer.class,view.analysisId())).isZero();
    }
}
