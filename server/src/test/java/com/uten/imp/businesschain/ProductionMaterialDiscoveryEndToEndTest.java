package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryService;
import com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.*;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.*;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionMaterialDiscoveryEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionMaterialDiscoveryService discovery;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired StockDocService stock;
    FullChainEndToEndTest fixture;
    FullChainEndToEndTest.World world;
    UUID plan,segment,workshop,worker;
    @BeforeEach void prepare(){createTask("100");}
    void createTask(String quantity){
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        world=fixture.seedWorld("discovery-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","discovery-"+UUID.randomUUID());
        workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        UUID order=fixture.createApprovedOrder(world,world.goodsC(),quantity,"100");
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        var view=analyses.preview(new PreviewRequest(null,null,null,world.warehouseId(),"discovery-analysis-"+order,
                List.of(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal(quantity)))));
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"discovery-route-"+order,
                view.flatMaterials().stream().filter(MaterialView::actionable).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),"MAKE",null)).toList()));
        view=analyses.detail(view.analysisId());
        var issued=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"discovery-plan-"+order,
                world.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,view.products().getFirst().analysisLineId(),new BigDecimal(quantity),null,null,workshop,null,worker,null,null,false))));
        plan=issued.plans().getFirst().planId();segment=issued.plans().getFirst().segmentIds().getFirst();
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void unknownMaterialsRequireRealRequestedIssueBeforeStartAndReplayCreatesNothingTwice(){
        assertTrue(discovery.context(segment).materialDiscoveryRequired());assertFalse(ready());
        assertThrows(ApiException.class,()->segments.start(plan,segment,new SegmentTransitionRequest(version(),"early-start-"+segment)));
        Request request=new Request(version(),"discover-request-"+segment);Detail pending=discovery.request(segment,request);
        assertEquals(pending.requestId(),discovery.request(segment,request).requestId());assertEquals("PENDING",pending.status());assertFalse(ready());
        var warehouse=beans.getBean(com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService.class);
        var queued=warehouse.query("WAREHOUSE","MATERIALS_TO_DEFINE",pending.segmentCode(),null,null,null,1,20);
        assertEquals(1,queued.total());assertEquals("MATERIAL_DISCOVERY",queued.items().getFirst().actionDocType());
        assertEquals(pending.requestId(),queued.items().getFirst().actionDocId());assertTrue(queued.items().getFirst().actionDocCanEdit());
        assertTrue(warehouse.warehouseStatusBreakdown().get("MATERIALS_TO_DEFINE")>=1);
        var workshopTasks=beans.getBean(ProductionExecutionWorkbenchService.class);
        var row=workshopTasks.workshopTasks(1,50,pending.segmentCode(),"PREPARING",workshop,null,null).getItems().getFirst();
        assertTrue(row.materialDiscoveryRequired());assertEquals(pending.requestId(),row.materialDiscoveryRequestId());assertEquals("PENDING",row.materialDiscoveryStatus());assertFalse(row.canStart());
        receive(world.goodsD(),"30");receive(world.goodsE(),"20");
        Configure configure=new Configure(pending.version(),"discover-configure-"+segment,List.of(
                new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),new BigDecimal("20")),
                new Material(world.goodsE(),null,world.unitId(),world.warehouseId(),new BigDecimal("10"))));
        Detail configured=discovery.configure(pending.requestId(),configure);
        assertEquals(0,warehouse.query("WAREHOUSE","MATERIALS_TO_DEFINE",pending.segmentCode(),null,null,null,1,20).total());
        assertEquals("CONFIGURED",configured.status());assertEquals(2,configured.items().size());assertEquals(1,configured.drawDocIds().size());
        assertEquals(configured,discovery.configure(pending.requestId(),configure));
        assertThrows(ApiException.class,()->discovery.configure(pending.requestId(),new Configure(pending.version(),configure.idempotencyKey(),
                List.of(new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),new BigDecimal("19"))))));
        assertEquals(2,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_stock_postings WHERE demand_id IN(SELECT id FROM production_material_demands WHERE execution_segment_id=?)",Integer.class,segment));
        assertFalse(ready());assertThrows(ApiException.class,()->segments.start(plan,segment,new SegmentTransitionRequest(version(),"reserved-start-"+segment)));
        UUID draw=configured.drawDocIds().getFirst();var issue=new StockDocIssueRequest();issue.setIdempotencyKey("discovery-issue-"+draw);
        issue.setLines(db.query("SELECT id,qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",(rs,index)->{var line=new StockDocIssueRequest.Line();line.setItemId(rs.getObject(1,UUID.class));line.setQty(rs.getBigDecimal(2));return line;},draw));
        stock.approveAndIssue(draw,issue);assertTrue(ready());
        segments.start(plan,segment,new SegmentTransitionRequest(version(),"real-start-"+segment));
        assertEquals("IN_PROGRESS",db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,segment));
        assertTrue(db.queryForObject("SELECT material_discovery_required FROM production_execution_segments WHERE id=?",Boolean.class,segment));
    }

    @Test void insufficientStockAndWrongWarehouseRollBackEveryDemandAndCancellationAllowsNewRequest(){
        Detail pending=discovery.request(segment,new Request(version(),"request-"+segment));receive(world.goodsD(),"5");
        assertThrows(ApiException.class,()->discovery.configure(pending.requestId(),new Configure(pending.version(),"bad-stock-"+segment,
                List.of(new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),new BigDecimal("6"))))));
        assertEquals("PENDING",discovery.detail(pending.requestId()).status());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
        var cancelled=discovery.cancel(pending.requestId(),new Request(pending.version(),"cancel-"+segment));assertEquals("CANCELLED",cancelled.status());
        assertEquals(cancelled,discovery.cancel(pending.requestId(),new Request(pending.version(),"cancel-"+segment)));
        assertTrue(discovery.context(segment).canRequest());var next=discovery.request(segment,new Request(version(),"request-again-"+segment));assertNotEquals(pending.requestId(),next.requestId());
        assertThrows(ApiException.class,()->discovery.cancel(next.requestId(),new Request(next.version(),"cancel-"+segment)));
        assertEquals("PENDING",discovery.detail(next.requestId()).status());
    }

    @Test void workshopPermissionCannotConfigureWarehouseMaterials(){
        Detail pending=discovery.request(segment,new Request(version(),"request-"+segment));
        var admin=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var limited=new AuthUser(admin.getId(),admin.getEmployeeId(),admin.getUsername(),Set.of("production_execution:view","production_execution:start"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(limited,null,limited.getAuthorities()));
        assertThrows(ApiException.class,()->discovery.configure(pending.requestId(),new Configure(pending.version(),"denied-"+segment,
                List.of(new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),BigDecimal.ONE)))));
    }
    @Test void oneMaterialFromTwoLeafWarehousesKeepsOneDemandAndTwoExactDraws(){
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        for(UUID leaf:List.of(first,second))db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",leaf,"DISC-"+leaf,"实际料仓",world.warehouseId());
        receive(world.goodsD(),"2",first);receive(world.goodsD(),"3",second);
        Detail pending=discovery.request(segment,new Request(version(),"multiwarehouse-"+segment));
        Detail defined=discovery.configure(pending.requestId(),new Configure(pending.version(),"multiwarehouse-config-"+segment,List.of(
                new Material(world.goodsD(),null,world.unitId(),first,new BigDecimal("2")),
                new Material(world.goodsD(),null,world.unitId(),second,new BigDecimal("3")))));
        assertEquals(2,defined.items().size());assertEquals(1,defined.items().stream().map(Item::demandId).distinct().count());assertEquals(2,defined.drawDocIds().size());
        assertEquals(0,new BigDecimal("5").compareTo(db.queryForObject("SELECT required_qty FROM production_material_demands WHERE execution_segment_id=?",BigDecimal.class,segment)));
        assertEquals(Set.of(first,second),new HashSet<>(db.queryForList("SELECT warehouse_id FROM stock_reservations WHERE demand_id IN(SELECT id FROM production_material_demands WHERE execution_segment_id=?)",UUID.class,segment)));
        for(UUID draw:defined.drawDocIds()){
            var issue=new StockDocIssueRequest();issue.setIdempotencyKey("cross-leaf-"+draw);
            issue.setLines(db.query("SELECT id,qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",(rs,index)->{var line=new StockDocIssueRequest.Line();line.setItemId(rs.getObject(1,UUID.class));line.setQty(rs.getBigDecimal(2));return line;},draw));
            stock.approveAndIssue(draw,issue);
        }
        assertTrue(ready());assertEquals(0,new BigDecimal("5").compareTo(db.queryForObject("SELECT SUM(qty_base) FROM production_material_stock_postings WHERE demand_id IN(SELECT id FROM production_material_demands WHERE execution_segment_id=?) AND posting_type='ISSUE'",BigDecimal.class,segment)));
    }
    @Test void invalidMaterialIdentityAndStaleOrChangedIntentNeverInstallDemands(){
        Detail pending=discovery.request(segment,new Request(version(),"invalid-request-"+segment));
        Material valid=new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),BigDecimal.ONE);
        UUID foreign=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,?,?,'使用',TRUE)",foreign,"FOREIGN-"+foreign,"其他主仓");receive(world.goodsD(),"1",foreign);
        List<List<Material>> invalid=List.of(List.of(valid,valid),List.of(new Material(world.goodsC(),null,world.unitId(),world.warehouseId(),BigDecimal.ONE)),
                List.of(new Material(world.goodsA(),null,world.unitId(),world.warehouseId(),BigDecimal.ONE)),
                List.of(new Material(world.goodsD(),null,UUID.randomUUID(),world.warehouseId(),BigDecimal.ONE)),
                List.of(new Material(world.goodsD(),null,world.unitId(),UUID.randomUUID(),BigDecimal.ONE)),
                List.of(new Material(world.goodsD(),null,world.unitId(),foreign,BigDecimal.ONE)),
                List.of(new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),new BigDecimal("0.00001"))));
        for(List<Material> values:invalid)assertThrows(ApiException.class,()->discovery.configure(pending.requestId(),new Configure(pending.version(),"invalid-config-"+UUID.randomUUID(),values)));
        assertThrows(ApiException.class,()->discovery.configure(pending.requestId(),new Configure(pending.version()+1,"stale-config-"+segment,List.of(valid))));
        assertThrows(ApiException.class,()->discovery.request(segment,new Request(version(),"invalid-request-"+segment)));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
        segments.confirmRoute(plan,segment,new SegmentRouteConfirmRequest(version(),"changed-route-"+segment,"FULL_KIT"));
        ApiException changed=assertThrows(ApiException.class,()->discovery.configure(pending.requestId(),new Configure(pending.version(),"changed-config-"+segment,List.of(valid))));
        assertTrue(changed.getMessage().contains("申请后生产任务已变化"));
    }
    @Test void nonDivisibleMaterialQuantityReportsActualOutputAndLearnsOnlyAfterWarehouseReceivesSurplus(){
        createTask("3");receive(world.goodsD(),"2");
        Detail pending=discovery.request(segment,new Request(version(),"third-request-"+segment));
        Detail defined=discovery.configure(pending.requestId(),new Configure(pending.version(),"third-config-"+segment,
                List.of(new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),new BigDecimal("2")))));
        issue(defined);assertTrue(ready());
        assertEquals(0,new BigDecimal("3").compareTo(db.queryForObject("SELECT fn_execution_material_output_capacity(?,TRUE)",BigDecimal.class,segment)));
        segments.start(plan,segment,new SegmentTransitionRequest(version(),"third-start-"+segment));
        var reportable=beans.getBean(ReportablePlanLineQueryService.class).list(1,50,null,workshop,List.of(segment)).getItems().getFirst();
        var request=new com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest();
        request.setIdempotencyKey("third-report-"+segment);request.setBillDate(BusinessTime.today());request.setDepartmentId(workshop);request.setWorkerIds(List.of(worker));
        var line=new com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine();line.setLineNo(1);line.setPlanItemId(reportable.planItemId());line.setExecutionSegmentId(segment);
        line.setExecutionSegmentSalesAllocationId(reportable.executionSegmentSalesAllocationId());line.setSalesOrderItemId(reportable.orderItemId());line.setGoodsId(world.goodsC());line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("3"));line.setIsFinal(true);
        request.setItems(List.of(line));request.setSurplusReturnRequested(true);
        var usage=new com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine();usage.setDemandId(defined.items().getFirst().demandId());usage.setQtyBase(new BigDecimal("1.8"));request.setMaterialLines(List.of(usage));
        var reports=beans.getBean(com.uten.imp.features.production.dailyreport.ProductionDailyReportService.class);
        reports.approve(reports.create(request).getId(),com.uten.imp.support.DailyReportApproveRequests.freshKey());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",Integer.class,world.goodsC()),"待仓库接收的余料尚未减少实际用料");
        UUID returned=db.queryForObject("SELECT id FROM stock_documents WHERE doc_type='WDRAW' AND plan_no=(SELECT bill_no FROM production_plans WHERE id=?) AND NOT is_deleted",UUID.class,plan);
        stock.confirmProductionMaterialReturn(returned,new ProductionMaterialReturnConfirmRequest(world.warehouseId(),"third-return-"+segment));
        assertEquals(0,new BigDecimal("0.6").compareTo(db.queryForObject("SELECT qty FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",BigDecimal.class,world.goodsC(),world.goodsD())));
        assertEquals(0,new BigDecimal("3").compareTo(db.queryForObject("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",BigDecimal.class,world.goodsC())));
        assertEquals(0,new BigDecimal("1.8").compareTo(db.queryForObject("SELECT net_qty FROM goods_bom_learning_material_totals WHERE goods_id=?",BigDecimal.class,world.goodsC())));
    }
    @Test void stoppedPlanHidesPendingWarehouseTaskAndResolvesItsNoticeWithoutReleasingInventory(){
        UUID user=fixture.createUserWithPerms(world,"discovery-warehouse-"+UUID.randomUUID(),"notice:read","stock_doc:view","stock_doc:approve","stock_doc:issue");
        db.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted) WHERE id=(SELECT employee_id FROM users WHERE id=?)",user);
        Detail pending=discovery.request(segment,new Request(version(),"notice-request-"+segment));
        var notices=beans.getBean(com.uten.imp.features.notice.ChainNoticeService.class);
        var payload=beans.getBean(com.fasterxml.jackson.databind.ObjectMapper.class).createObjectNode();
        var delivery=new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        delivery.executeWithoutResult(transaction->notices.deliverOutboxEvent("PRODUCTION_MATERIAL_DISCOVERY_PENDING",pending.requestId(),payload));
        assertTrue(db.queryForObject("SELECT count(*) FROM notices WHERE aggregate_kind='PRODUCTION_MATERIAL_DISCOVERY_REQUEST' AND aggregate_id=? AND resolved_at IS NULL",Integer.class,pending.requestId())>0);
        db.update("UPDATE production_plans SET is_stopped=TRUE WHERE id=?",plan);
        assertTrue(db.queryForObject("SELECT count(*) FROM business_outbox WHERE aggregate_id=? AND event_type='PRODUCTION_MATERIAL_DISCOVERY_VISIBILITY'",Integer.class,pending.requestId())>0);
        delivery.executeWithoutResult(transaction->notices.deliverOutboxEvent("PRODUCTION_MATERIAL_DISCOVERY_VISIBILITY",pending.requestId(),payload));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM notices WHERE aggregate_kind='PRODUCTION_MATERIAL_DISCOVERY_REQUEST' AND aggregate_id=? AND resolved_at IS NULL",Integer.class,pending.requestId()));
        var warehouse=beans.getBean(com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService.class);
        assertEquals(0,warehouse.query("WAREHOUSE","MATERIALS_TO_DEFINE",pending.segmentCode(),null,null,null,1,20).total());
        assertThrows(ApiException.class,()->discovery.configure(pending.requestId(),new Configure(pending.version(),"stop-config-"+segment,List.of(new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),BigDecimal.ONE)))));
        assertEquals("PENDING",discovery.detail(pending.requestId()).status());
    }
    void issue(Detail defined){
        for(UUID draw:defined.drawDocIds()){
            var issue=new StockDocIssueRequest();issue.setIdempotencyKey("discovery-issue-"+draw);
            issue.setLines(db.query("SELECT id,qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",(rs,index)->{var line=new StockDocIssueRequest.Line();line.setItemId(rs.getObject(1,UUID.class));line.setQty(rs.getBigDecimal(2));return line;},draw));
            stock.approveAndIssue(draw,issue);
        }
    }
    void receive(UUID goods,String qty){receive(goods,qty,world.warehouseId());}
    void receive(UUID goods,String qty,UUID warehouse){
        var request=new StockDocSaveRequest();request.setDocType("OTHER_IN");request.setWarehouseId(warehouse);request.setBillDate(BusinessTime.today());
        var line=new StockDocItemLine();line.setGoodsId(goods);line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(BigDecimal.TEN);
        line.setAmountOriginal(new BigDecimal(qty).multiply(BigDecimal.TEN));line.setAmountLocal(line.getAmountOriginal());request.setItems(List.of(line));stock.approve(stock.create(request).getId());
    }
    long version(){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
    boolean ready(){return Boolean.TRUE.equals(db.queryForObject("SELECT fn_execution_start_material_ready(?)",Boolean.class,segment));}
}
