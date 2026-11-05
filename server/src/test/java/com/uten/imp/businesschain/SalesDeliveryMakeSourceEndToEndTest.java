package com.uten.imp.businesschain;

import com.uten.imp.common.delivery.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.stock.StockDocService;
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

/** Original sales source → real child manufacture/quality/private stock → actual component shipment. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.production.readiness-reconcile.enabled=false"})
class SalesDeliveryMakeSourceEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FullChainEndToEndTest.registerDataSource(r);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesOrderService orders;
    @Autowired SalesShipmentService shipments;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired BomDeliveryService boms;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionDrawRequestService draws;
    @Autowired StockDocService stock;
    FullChainEndToEndTest fixture;
    SalesBomDeliveryEndToEndTest support;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);support=new SalesBomDeliveryEndToEndTest();beans.autowireBean(support);support.fixture=fixture;}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void wholeFrontierIsReallyManufacturedAndQualifiedBeforeItsPrivateStockShipsWithoutParentAssembly() {
        var w=fixture.seedWorld("delivery-make-"+UUID.randomUUID().toString().substring(0,6));
        fixture.loginAs(w.superAdminUserId());
        // Real OTHER_IN source stock: B's original recipe consumes C3 and D5
        // per B, while E is independently delivered alongside the finished B.
        for(var entry:List.of(new Input(w.goodsC(),"30"),new Input(w.goodsD(),"50"),new Input(w.goodsE(),"5")))
            ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,entry.goods(),entry.qty());
        var snapshot=boms.snapshot(w.goodsA());
        var request=fixture.orderRequest(w,w.goodsA(),"5","100");
        request.getItems().getFirst().setDeliveryPlan(new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,
                List.of(),List.of(),snapshot.bomFingerprint()));
        UUID order=orders.create(request).getId();orders.approve(order);fixture.confirmInitialSalesFinance(order);
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"delivery-make-"+order,
                List.of(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,BusinessTime.today(),new BigDecimal("5")))));
        var b=view.flatMaterials().stream().filter(m->m.deliveryFrontier()&&m.goodsId().equals(w.goodsB())).findFirst().orElseThrow();
        assertThat(b.requiredQty()).isEqualByComparingTo("10");assertThat(b.actionable()).isTrue();
        assertThat(view.products().getFirst().canSchedule()).isFalse();
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","delivery-make-"+item);
        UUID workshop=(UUID)ReflectionTestUtils.getField(assignment,"workshopId");
        UUID worker=(UUID)ReflectionTestUtils.getField(assignment,"workerId");
        var issued=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "delivery-make-plan-"+item,w.warehouseId(),BusinessTime.today(),null,true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(b.materialLineId(),null,new BigDecimal("10"),
                        BusinessTime.today(),null,workshop,null,worker,null,null))));
        assertThat(issued.plans()).hasSize(1);
        var plan=issued.plans().getFirst();assertThat(plan.segmentIds()).hasSize(1);
        UUID segment=plan.segmentIds().getFirst();
        assertThat(db.queryForObject("SELECT goods_id FROM production_plan_items WHERE id=(SELECT source_plan_item_id FROM production_execution_segments WHERE id=?)",UUID.class,segment)).isEqualTo(w.goodsB());
        segments.confirmRoute(plan.planId(),segment,new SegmentRouteConfirmRequest(version(segment),"delivery-make-route-"+segment,"FULL_KIT"));
        List<UUID> drawDocs=db.queryForList("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW' ORDER BY document_id",UUID.class,segment);
        assertThat(drawDocs).isNotEmpty();
        var selections=List.of(new ProductionDrawRequest.Item(segment,version(segment)));
        var drawPreview=draws.preview(new ProductionDrawRequest.PreviewRequest(selections));
        draws.submit(new ProductionDrawRequest.SubmitRequest(selections,"delivery-make-draw-"+segment,drawPreview.fingerprint()));
        var issue=new StockDocIssueBatchRequest();issue.setIdempotencyKey("delivery-make-issue-"+segment);issue.setDocIds(drawDocs);stock.issueFullBatch(issue);
        assertThat(db.queryForObject("SELECT fn_execution_start_material_ready(?)",Boolean.class,segment)).isTrue();
        segments.start(plan.planId(),segment,new SegmentTransitionRequest(version(segment),"delivery-make-start-"+segment));
        UUID planItem=db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,segment);
        UUID report=fixture.reportAndApproveExecutionSegment(w,planItem,null,w.goodsB(),segment,null,"10",false,"0",null,null);
        assertConsumed(report,w.goodsC(),"30");assertConsumed(report,w.goodsD(),"50");
        fixture.confirmFinishedInboundFully(fixture.finishedInDocForReport(report));
        ReflectionTestUtils.invokeMethod(fixture,"drainCostsWithFreshRunnerWithoutSession",w);
        fixture.loginAs(w.superAdminUserId());
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isEqualByComparingTo("10");
        assertThat(db.queryForObject("""
                SELECT sum(event.qty) FROM preplan_stock_entitlement_events event
                JOIN stock_reservations reservation ON reservation.id=event.stock_reservation_id
                WHERE event.event_type='ORIGIN_MAKE' AND event.beneficiary_analysis_id=? AND reservation.goods_id=?
                """,BigDecimal.class,view.analysisId(),w.goodsB())).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE goods_id=?",Integer.class,w.goodsA())).isZero();
        UUID shipment=fixture.createShipment(w,item,w.goodsA(),"5");shipments.confirmSales(shipment,0L);
        ReflectionTestUtils.invokeMethod(fixture,"confirmShipmentFinance",shipment);
        shipments.transitionWarehouseWork(shipment,support.pick(new SalesBomDeliveryEndToEndTest.Ready(w,order,item,shipment)));
        assertThat(support.balance(w.warehouseId(),w.goodsB())).isZero();assertThat(support.balance(w.warehouseId(),w.goodsE())).isZero();
        assertThat(support.balance(w.warehouseId(),w.goodsC())).isZero();assertThat(support.balance(w.warehouseId(),w.goodsD())).isZero();
        assertThat(db.queryForObject("""
                SELECT sum(handoff.quantity) FROM sales_delivery_entitlement_handoffs handoff
                JOIN preplan_stock_entitlement_events origin ON origin.id=handoff.source_entitlement_event_id
                WHERE handoff.source_material_id=? AND origin.event_type='ORIGIN_MAKE'
                """,BigDecimal.class,b.materialLineId())).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,view.products().getFirst().analysisLineId())).isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=?",Integer.class,view.analysisId())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE goods_id=?",Integer.class,w.goodsA())).isZero();
        assertThat(db.queryForObject("SELECT shipped_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT produced_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item)).isZero();
    }

    private void assertConsumed(UUID report,UUID goods,String expected) {
        assertThat(db.queryForObject("""
                SELECT sum(posting.qty_base) FROM production_material_settlement_postings posting
                JOIN production_material_settlement_events event ON event.id=posting.event_id
                JOIN production_material_demands demand ON demand.id=posting.demand_id
                WHERE event.daily_report_id=? AND event.event_type='POST' AND posting.settlement_type='CONSUMED' AND demand.goods_id=?
                """,BigDecimal.class,report,goods)).isEqualByComparingTo(expected);
    }
    private long version(UUID segment){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
    private record Input(UUID goods,String qty){}
}
