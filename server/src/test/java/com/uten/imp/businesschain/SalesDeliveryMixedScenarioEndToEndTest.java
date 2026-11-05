package com.uten.imp.businesschain;

import com.uten.imp.common.delivery.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.shipment.SalesShipmentDeliveryService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
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
import java.util.UUID;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.*;

/** Different per-order boundaries and actual partial production/processing stay separate on the same recipe. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.production.readiness-reconcile.enabled=false"})
class SalesDeliveryMixedScenarioEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesOrderService orders;
    @Autowired SalesShipmentService shipments;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired BomDeliveryService boms;
    @Autowired DeliveryProcessingService processing;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionDrawRequestService draws;
    @Autowired ProductionMaterialSettlementService settlements;
    @Autowired StockDocService stock;
    FullChainEndToEndTest fixture;
    SalesBomDeliveryEndToEndTest support;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);support=new SalesBomDeliveryEndToEndTest();beans.autowireBean(support);support.fixture=fixture;}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void sameProductKeepsAssembledWholeAndChildrenOrdersIndependentInOneAnalysisAndShipment() {
        var w=world("delivery-mixed-orders");
        input(w,w.goodsB(),"14");input(w,w.goodsC(),"30");input(w,w.goodsD(),"50");input(w,w.goodsE(),"12");
        var recipe=boms.snapshot(w.goodsA());
        var b=child(recipe.root(),w.goodsB());var c=child(b,w.goodsC());
        var assembled=order(w,"2",DeliveryPlan.assembled());
        var whole=order(w,"5",plan(recipe,List.of(),c.path()));
        var split=order(w,"5",plan(recipe,List.of(new DeliveryPlan.NodeMode(b.path(),DeliveryPlan.NodeDelivery.CHILDREN)),c.path()));
        var view=analyze(w,List.of(assembled,whole,split));
        var assembledProduct=product(view,assembled);var wholeProduct=product(view,whole);var splitProduct=product(view,split);
        assertThat(assembledProduct.rootMaterialLineId()).isNotNull();assertThat(assembledProduct.canSchedule()).isTrue();
        assertThat(wholeProduct.rootMaterialLineId()).isNull();assertThat(wholeProduct.canSchedule()).isFalse();
        assertThat(splitProduct.rootMaterialLineId()).isNull();assertThat(splitProduct.canSchedule()).isFalse();
        assertThat(view.flatMaterials().stream().filter(m->m.level()==0&&m.goodsId().equals(w.goodsA()))).hasSize(1);
        var wholeB=material(view,whole,w.goodsB());var wholeC=material(view,whole,w.goodsC());
        var splitB=material(view,split,w.goodsB());var splitC=material(view,split,w.goodsC());
        assertThat(wholeB.deliveryFrontier()).isTrue();assertThat(wholeB.deliveryContext()).isFalse();
        assertThat(wholeB.requiredQty()).isEqualByComparingTo("10");assertThat(wholeB.deliveryOperations()).contains("LASER");
        assertThat(wholeC.deliveryFrontier()).isFalse();assertThat(wholeC.requiredQty()).isZero();
        assertThat(splitB.deliveryContext()).isTrue();assertThat(splitB.requiredQty()).isZero();
        assertThat(splitB.actionable()).isFalse();assertThat(splitB.flowStage()).isNotEqualTo("ROUTE_PENDING");
        assertThat(splitC.deliveryFrontier()).isTrue();assertThat(splitC.requiredQty()).isEqualByComparingTo("30");
        assertThat(material(view,split,w.goodsD()).requiredQty()).isEqualByComparingTo("50");
        assertThat(material(view,assembled,w.goodsC()).deliveryOperations()).isEmpty();
        UUID wholeShipment=shipment(w,whole,"5"),splitShipment=shipment(w,split,"5");
        assertThat(support.physical(wholeShipment)).extracting(SalesShipmentDeliveryService.Component::goodsId)
                .containsExactlyInAnyOrder(w.goodsB(),w.goodsE());
        assertThat(support.physical(splitShipment)).extracting(SalesShipmentDeliveryService.Component::goodsId)
                .containsExactlyInAnyOrder(w.goodsC(),w.goodsD(),w.goodsE());
        var wholeComponent=component(wholeShipment,w.goodsB());var splitComponent=component(splitShipment,w.goodsC());
        assertTarget(wholeComponent,w.goodsC(),c.path(),"30");assertTarget(splitComponent,w.goodsC(),c.path(),"30");
        assertThat(wholeComponent.quantity()).isEqualByComparingTo("10");assertThat(splitComponent.quantity()).isEqualByComparingTo("30");
        assertThatThrownBy(()->shipments.transitionWarehouseWork(splitShipment,support.pick(ready(w,split,splitShipment))))
                .isInstanceOf(ApiException.class).hasMessageContaining("加工");
        process(w,splitShipment,splitComponent,"12");
        shipments.transitionWarehouseWork(splitShipment,support.pick(ready(w,split,splitShipment)));
        var current=analyses.detail(view.analysisId());
        assertThat(product(current,split).remainingQty()).isZero();
        assertThat(product(current,whole).remainingQty()).isEqualByComparingTo("5");
        assertThat(product(current,assembled).remainingQty()).isEqualByComparingTo("2");
        assertThat(material(current,whole,w.goodsB()).requiredQty()).isEqualByComparingTo("10");
        assertThat(material(current,whole,w.goodsC()).deliveryFrontier()).isFalse();
        assertThat(component(wholeShipment,w.goodsB()).processedQty()).isZero();
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isEqualByComparingTo("14");
        assertThat(support.balance(w.warehouseId(),w.goodsE())).isEqualByComparingTo("7");
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,whole.item())).isZero();
        assertNoParentStock(w);
    }

    @Test void partialManufactureAndPhysicalChildProcessingThenTwoKitShipmentsRefreshOnlyTheTrueRemainder() {
        var w=world("delivery-partial-make");
        input(w,w.goodsC(),"30");input(w,w.goodsD(),"50");input(w,w.goodsE(),"5");
        var recipe=boms.snapshot(w.goodsA());var c=child(child(recipe.root(),w.goodsB()),w.goodsC());
        var order=order(w,"5",plan(recipe,List.of(),c.path()));
        var view=analyze(w,List.of(order));var originalB=material(view,order,w.goodsB());
        var stockedE=material(view,order,w.goodsE());
        assertThat(stockedE.shortageQty()).isZero();assertThat(stockedE.actionable()).isFalse();
        assertThat(stockedE.flowStage()).isNotEqualTo("ROUTE_PENDING");
        assertThat(product(view,order).rootMaterialLineId()).isNull();assertThat(product(view,order).canSchedule()).isFalse();
        var make=startManufacture(w,view,originalB.materialLineId());
        UUID firstReport=reportManufacture(w,make,"4");
        assertConsumed(firstReport,w.goodsC(),"12");assertConsumed(firstReport,w.goodsD(),"20");
        assertWip(make,w.goodsC(),"18");assertWip(make,w.goodsD(),"30");
        var afterProduction=refresh(w,view.analysisId(),List.of(order));
        assertThat(product(afterProduction,order).remainingQty()).isEqualByComparingTo("5");
        assertThat(material(afterProduction,order,w.goodsB()).requiredQty()).isEqualByComparingTo("10");
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isEqualByComparingTo("4");
        UUID firstShipment=shipment(w,order,"2");var firstComponent=component(firstShipment,w.goodsB());
        assertThat(firstComponent.quantity()).isEqualByComparingTo("4");assertTarget(firstComponent,w.goodsC(),c.path(),"12");
        process(w,firstShipment,firstComponent,"1");
        // LASER reports count whole delivered B units. Their C targets do not
        // consume another batch of production materials or manufacture inventory.
        assertConsumed(firstReport,w.goodsC(),"12");assertConsumed(firstReport,w.goodsD(),"20");
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isEqualByComparingTo("4");
        shipments.transitionWarehouseWork(firstShipment,support.pick(ready(w,order,firstShipment)));
        var remaining=refresh(w,view.analysisId(),List.of(order));
        assertThat(product(remaining,order).remainingQty()).isEqualByComparingTo("3");
        assertThat(material(remaining,order,w.goodsB()).requiredQty()).isEqualByComparingTo("6");
        assertThat(material(remaining,order,w.goodsE()).requiredQty()).isEqualByComparingTo("3");
        assertThat(material(remaining,order,w.goodsC()).deliveryFrontier()).isFalse();
        assertThat(material(remaining,order,w.goodsD()).deliveryFrontier()).isFalse();
        assertWip(make,w.goodsC(),"18");assertWip(make,w.goodsD(),"30");
        assertThat(db.queryForObject("SELECT count(*) FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",Integer.class,make.plan())).isEqualTo(1);
        UUID secondReport=reportManufacture(w,make,"6");
        assertConsumed(secondReport,w.goodsC(),"18");assertConsumed(secondReport,w.goodsD(),"30");
        assertWip(make,w.goodsC(),"0");assertWip(make,w.goodsD(),"0");
        UUID secondShipment=shipment(w,order,"3");var secondComponent=component(secondShipment,w.goodsB());
        assertThat(secondComponent.quantity()).isEqualByComparingTo("6");assertTarget(secondComponent,w.goodsC(),c.path(),"18");
        process(w,secondShipment,secondComponent,"2");
        shipments.transitionWarehouseWork(secondShipment,support.pick(ready(w,order,secondShipment)));
        var finished=analyses.detail(view.analysisId());
        assertThat(product(finished,order).remainingQty()).isZero();
        assertThat(material(finished,order,w.goodsB()).requiredQty()).isZero();
        assertThat(material(finished,order,w.goodsE()).requiredQty()).isZero();
        assertThat(db.queryForObject("SELECT sum(quantity) FROM sales_delivery_entitlement_handoffs WHERE source_material_id=?",BigDecimal.class,originalB.materialLineId())).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT sum(event.order_qty) FROM sales_delivery_fulfillment_events event JOIN sales_delivery_fulfillment_allocations allocation ON allocation.id=event.allocation_id WHERE allocation.analysis_item_id=? AND event.event_type='FULFILL'",BigDecimal.class,product(finished,order).analysisLineId())).isEqualByComparingTo("5");
        for(UUID goods:List.of(w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE()))assertThat(support.balance(w.warehouseId(),goods)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=?",Integer.class,view.analysisId())).isZero();
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,order.item())).isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT produced_qty FROM sales_order_items WHERE id=?",BigDecimal.class,order.item())).isZero();
        assertNoParentStock(w);
    }

    private FullChainEndToEndTest.World world(String tag){var w=fixture.seedWorld(tag+UUID.randomUUID().toString().substring(0,6));fixture.loginAs(w.superAdminUserId());return w;}
    private void input(FullChainEndToEndTest.World w,UUID goods,String qty){ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,goods,qty);}
    private Order order(FullChainEndToEndTest.World w,String qty,DeliveryPlan plan){
        var request=fixture.orderRequest(w,w.goodsA(),qty,"100");request.getItems().getFirst().setDeliveryPlan(plan);
        UUID id=orders.create(request).getId();orders.approve(id);fixture.confirmInitialSalesFinance(id);
        return new Order(id,db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,id),qty);
    }
    private DeliveryPlan plan(DeliveryBom.Snapshot recipe,List<DeliveryPlan.NodeMode> modes,List<UUID> target){return new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,modes,List.of(new DeliveryPlan.Process(target,DeliveryPlan.Operation.LASER,true)),recipe.bomFingerprint());}
    private static DeliveryBom.Node child(DeliveryBom.Node node,UUID goods){return node.children().stream().filter(n->n.goodsId().equals(goods)).findFirst().orElseThrow();}
    private List<PreviewItem> sources(List<Order> orders){return orders.stream().map(order->new PreviewItem("SALES_ORDER_ITEM",order.item(),null,null,null,null,null,BusinessTime.today(),new BigDecimal(order.qty()))).toList();}
    private AnalysisView analyze(FullChainEndToEndTest.World w,List<Order> orders){return analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"mixed-analysis-"+UUID.randomUUID(),sources(orders)));}
    private AnalysisView refresh(FullChainEndToEndTest.World w,UUID id,List<Order> orders){fixture.loginAs(w.superAdminUserId());var old=analyses.detail(id);return analyses.preview(new PreviewRequest(id,old.version(),old.fingerprint(),w.warehouseId(),"mixed-refresh-"+UUID.randomUUID(),sources(orders)));}
    private static ProductView product(AnalysisView view,Order order){return view.products().stream().filter(p->order.item().equals(p.salesOrderItemId())).findFirst().orElseThrow();}
    private static MaterialView material(AnalysisView view,Order order,UUID goods){UUID source=product(view,order).analysisLineId();return view.flatMaterials().stream().filter(m->m.analysisLineId().equals(source)&&m.goodsId().equals(goods)).findFirst().orElseThrow();}
    private UUID shipment(FullChainEndToEndTest.World w,Order order,String qty){fixture.loginAs(w.superAdminUserId());UUID id=fixture.createShipment(w,order.item(),w.goodsA(),qty);shipments.confirmSales(id,0L);ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",id);return id;}
    private SalesShipmentDeliveryService.Component component(UUID shipment,UUID goods){return support.physical(shipment).stream().filter(c->c.goodsId().equals(goods)).findFirst().orElseThrow();}
    private static SalesBomDeliveryEndToEndTest.Ready ready(FullChainEndToEndTest.World w,Order order,UUID shipment){return new SalesBomDeliveryEndToEndTest.Ready(w,order.id(),order.item(),shipment);}
    private static void assertTarget(SalesShipmentDeliveryService.Component component,UUID goods,List<UUID> path,String qty){assertThat(component.processingTargets()).singleElement().satisfies(target->{assertThat(target.goodsId()).isEqualTo(goods);assertThat(target.path()).isEqualTo(path);assertThat(new BigDecimal(target.quantityExact())).isEqualByComparingTo(qty);assertThat(target.operations()).containsExactly("LASER");});}
    private void process(FullChainEndToEndTest.World w,UUID shipment,SalesShipmentDeliveryService.Component component,String firstQty){
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","mixed-laser-"+component.id());
        UUID workshop=(UUID)ReflectionTestUtils.getField(assignment,"workshopId"),worker=(UUID)ReflectionTestUtils.getField(assignment,"workerId");
        var task=processing.assign(component.id(),new DeliveryProcessingContracts.Assignment(component.revision(),workshop,worker,UUID.randomUUID()));
        var issued=shipments.processingWarehouseWork(shipment,component.id(),"ISSUE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(task.version(),w.warehouseId(),"原交付件发加工",UUID.randomUUID(),"实际交付件及冻结子件加工目标已交接"));
        task=processing.start(component.id(),new DeliveryProcessingContracts.Start(issued.revision(),w.warehouseId(),UUID.randomUUID()));
        task=processing.report(component.id(),new DeliveryProcessingContracts.Report(task.version(),new BigDecimal(firstQty),"LASER","本次所报交付件均已完成其全部子件激光要求",UUID.randomUUID()));
        long partialVersion=task.version();
        assertThatThrownBy(()->shipments.processingWarehouseWork(shipment,component.id(),"RECEIVE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(partialVersion,w.warehouseId(),"未完整加工不得收回",UUID.randomUUID(),"完整加工闸门核验"))).isInstanceOf(ApiException.class);
        var orderItem=db.queryForObject("SELECT order_item_id FROM sales_shipment_items WHERE id=?",UUID.class,component.shipmentItemId());
        UUID orderId=db.queryForObject("SELECT order_id FROM sales_order_items WHERE id=?",UUID.class,orderItem);
        assertThatThrownBy(()->shipments.transitionWarehouseWork(shipment,support.pick(new SalesBomDeliveryEndToEndTest.Ready(w,orderId,orderItem,shipment)))).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",Integer.class,shipment)).isZero();
        task=processing.report(component.id(),new DeliveryProcessingContracts.Report(task.version(),new BigDecimal(task.remainingQtyExact()),"LASER","剩余交付件的全部实际加工目标已完成并检验",UUID.randomUUID()));
        shipments.processingWarehouseWork(shipment,component.id(),"RECEIVE",new SalesShipmentDeliveryService.ProcessingWarehouseAction(task.version(),w.warehouseId(),"原加工件合格收回",UUID.randomUUID(),"逐交付件核对全部冻结加工对象后实际收回"));
    }
    private Make startManufacture(FullChainEndToEndTest.World w,AnalysisView view,UUID material){
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","mixed-make-"+view.analysisId());
        UUID workshop=(UUID)ReflectionTestUtils.getField(assignment,"workshopId"),worker=(UUID)ReflectionTestUtils.getField(assignment,"workerId");
        var plan=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"mixed-make-plan-"+view.analysisId(),w.warehouseId(),BusinessTime.today(),null,true,List.of(new IssueWorkshopPlansRequest.IssuePlanLine(material,null,new BigDecimal("10"),BusinessTime.today(),null,workshop,null,worker,null,null)))).plans().getFirst();
        UUID segment=plan.segmentIds().getFirst();segments.confirmRoute(plan.planId(),segment,new SegmentRouteConfirmRequest(version(segment),"mixed-make-route-"+segment,"FULL_KIT"));
        var documents=db.queryForList("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW' ORDER BY document_id",UUID.class,segment);
        assertThat(documents).isNotEmpty();var selections=List.of(new ProductionDrawRequest.Item(segment,version(segment)));var preview=draws.preview(new ProductionDrawRequest.PreviewRequest(selections));
        draws.submit(new ProductionDrawRequest.SubmitRequest(selections,"mixed-make-draw-"+segment,preview.fingerprint()));
        var issue=new StockDocIssueBatchRequest();issue.setIdempotencyKey("mixed-make-issue-"+segment);issue.setDocIds(documents);stock.issueFullBatch(issue);
        segments.start(plan.planId(),segment,new SegmentTransitionRequest(version(segment),"mixed-make-start-"+segment));
        return new Make(plan.planId(),segment,db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,segment));
    }
    private UUID reportManufacture(FullChainEndToEndTest.World w,Make make,String qty){fixture.loginAs(w.superAdminUserId());UUID report=fixture.reportAndApproveExecutionSegment(w,make.item(),null,w.goodsB(),make.segment(),null,qty,false,"0",null,null);fixture.confirmFinishedInboundFully(fixture.finishedInDocForReport(report));ReflectionTestUtils.invokeMethod(fixture,"drainCostsWithFreshRunnerWithoutSession",w);fixture.loginAs(w.superAdminUserId());return report;}
    private void assertConsumed(UUID report,UUID goods,String expected){assertThat(db.queryForObject("SELECT sum(posting.qty_base) FROM production_material_settlement_postings posting JOIN production_material_settlement_events event ON event.id=posting.event_id JOIN production_material_demands demand ON demand.id=posting.demand_id WHERE event.daily_report_id=? AND event.event_type='POST' AND posting.settlement_type='CONSUMED' AND demand.goods_id=?",BigDecimal.class,report,goods)).isEqualByComparingTo(expected);}
    private void assertWip(Make make,UUID goods,String expected){assertThat(settlements.clearance(make.plan(),make.segment()).stream().filter(row->row.goodsId().equals(goods)).map(row->row.availableToSettleQty()).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo(expected);}
    private void assertNoParentStock(FullChainEndToEndTest.World w){assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE goods_id=?",Integer.class,w.goodsA())).isZero();assertThat(support.balance(w.warehouseId(),w.goodsA())).isZero();}
    private long version(UUID segment){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
    private record Order(UUID id,UUID item,String qty){}
    private record Make(UUID plan,UUID segment,UUID item){}
}
