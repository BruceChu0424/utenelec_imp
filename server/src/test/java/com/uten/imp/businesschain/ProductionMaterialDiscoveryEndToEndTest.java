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
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
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
        "uten.production.readiness-reconcile.enabled=false",
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
    @Autowired com.uten.imp.features.stock.trace.GoodsProductionTraceQueryService traces;
    FullChainEndToEndTest fixture;
    FullChainEndToEndTest.World world;
    UUID plan,segment,workshop,worker;
    @BeforeEach void prepare(){createTask("100");}
    void createTask(String quantity){
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        world=fixture.seedWorld("discovery-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","discovery-"+UUID.randomUUID());
        workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        releaseTask(quantity);
    }
    void releaseTask(String quantity){
        releaseTask(world.goodsC(),quantity);
    }
    void releaseTask(UUID product,String quantity){
        UUID order=fixture.createApprovedOrder(world,product,quantity,"100");
        releaseOrder(order,quantity);
    }
    void releaseOrder(UUID order,String quantity){
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

    @Test void rememberedWorkshopMaterialsKeepIdentityWithoutReusingQuantityAndIgnoreCancelledHistory(){
        Detail first=discovery.request(segment,new Request(version(),"memory-first-"+segment,List.of(
                new RequestedMaterial(world.goodsD(),null,world.unitId(),new BigDecimal("12.5")),
                new RequestedMaterial(world.goodsE(),null,world.unitId(),null))));
        releaseTask("250");
        long before=version();
        Context context=discovery.context(segment);
        assertEquals("WORKSHOP_REQUESTED",context.memorySource());
        assertEquals(first.requestNo(),context.memoryRequestNo());
        assertEquals(Set.of(world.goodsD(),world.goodsE()),context.rememberedItems().stream().map(SuggestedItem::goodsId).collect(java.util.stream.Collectors.toSet()));
        assertTrue(context.rememberedItems().stream().allMatch(item->item.qty()==null));
        assertTrue(context.canRequest());assertFalse(ready());assertEquals(before,version());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",Integer.class,world.goodsC()));
        discovery.cancel(first.requestId(),new Request(first.version(),"memory-cancel-"+first.requestId()));
        assertTrue(discovery.context(segment).rememberedItems().isEmpty());
    }

    @Test void warehouseConfirmedMaterialsReplaceSuggestionsAndDisabledIdentityIsNotPartiallyReused(){
        Detail first=discovery.request(segment,new Request(version(),"confirmed-memory-"+segment,List.of(
                new RequestedMaterial(world.goodsD(),null,world.unitId(),new BigDecimal("12.5")))));
        receive(world.goodsE(),"30");
        Detail configured=discovery.configure(first.requestId(),new Configure(first.version(),"confirmed-config-"+segment,List.of(
                new Material(world.goodsE(),null,world.unitId(),world.warehouseId(),new BigDecimal("10")))));
        releaseTask("50");
        Context context=discovery.context(segment);
        assertEquals("WAREHOUSE_CONFIRMED",context.memorySource());
        assertEquals(configured.requestNo(),context.memoryRequestNo());
        assertEquals(List.of(world.goodsE()),context.rememberedItems().stream().map(SuggestedItem::goodsId).toList());
        assertNull(context.rememberedItems().getFirst().qty());assertFalse(ready());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM goods_bom_actual_usages WHERE goods_id=?",Integer.class,world.goodsC()));
        db.update("UPDATE goods SET status='禁用' WHERE id=?",world.goodsE());
        assertTrue(discovery.context(segment).rememberedItems().isEmpty());
    }

    @Test void materialRecognitionDoesNotLeakAcrossWorkshopsOrStoppedPlans(){
        UUID sourcePlan=plan;
        discovery.request(segment,new Request(version(),"scoped-memory-"+segment,List.of(
                new RequestedMaterial(world.goodsD(),null,world.unitId(),null))));
        releaseTask("20");
        assertFalse(discovery.context(segment).rememberedItems().isEmpty());
        db.update("UPDATE production_plans SET is_stopped=TRUE WHERE id=?",sourcePlan);
        assertTrue(discovery.context(segment).rememberedItems().isEmpty());
        db.update("UPDATE production_plans SET is_stopped=FALSE WHERE id=?",sourcePlan);
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","memory-other-"+UUID.randomUUID());
        workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        releaseTask("30");
        assertTrue(discovery.context(segment).rememberedItems().isEmpty());
    }

    @Test void warehouseDiscoveryUsesUnassignedPoolAndPhysicalWarehouseScopeBeforePagination(){
        UUID own=discoveryLeaf(),other=discoveryLeaf();
        receive(world.goodsD(),"6",own);receive(world.goodsD(),"6",other);
        UUID keeper=discoveryWarehouseUser(own),pool=discoveryWarehouseUser(null);
        Detail firstPending=discovery.request(segment,new Request(version(),"scope-other-request-"+segment));
        Detail otherConfigured=discovery.configure(firstPending.requestId(),new Configure(firstPending.version(),
                "scope-other-config-"+segment,List.of(new Material(world.goodsD(),null,world.unitId(),other,BigDecimal.ONE))));
        releaseTask("100");
        Detail secondPending=discovery.request(segment,new Request(version(),"scope-own-request-"+segment));
        Detail ownConfigured=discovery.configure(secondPending.requestId(),new Configure(secondPending.version(),
                "scope-own-config-"+segment,List.of(new Material(world.goodsD(),null,world.unitId(),own,BigDecimal.ONE))));
        releaseTask("100");
        Detail unknown=discovery.request(segment,new Request(version(),"scope-unknown-request-"+segment));
        Configure command=new Configure(unknown.version(),"scope-unknown-config-"+segment,
                List.of(new Material(world.goodsD(),null,world.unitId(),other,BigDecimal.ONE)));

        fixture.loginAs(keeper);
        assertEquals(0,discovery.list("PENDING",1,1).getTotal(),"子仓负责人不因知道UUID而取得未分仓任务");
        var visible=discovery.list("CONFIGURED",1,1);
        assertEquals(1,visible.getTotal());assertEquals(1,visible.getTotalPages());
        assertEquals(ownConfigured.requestId(),visible.getItems().getFirst().requestId());
        assertTrue(discovery.list("CONFIGURED",2,1).getItems().isEmpty());
        assertEquals(com.uten.imp.common.web.ErrorCode.NOT_FOUND,assertThrows(ApiException.class,
                ()->discovery.detail(otherConfigured.requestId())).getCode());
        assertEquals(com.uten.imp.common.web.ErrorCode.NOT_FOUND,assertThrows(ApiException.class,
                ()->discovery.detail(unknown.requestId())).getCode());
        assertEquals(com.uten.imp.common.web.ErrorCode.NOT_FOUND,assertThrows(ApiException.class,
                ()->discovery.configure(unknown.requestId(),command)).getCode());

        fixture.loginAs(pool);
        var scopes=beans.getBean(com.uten.imp.application.port.WarehouseTaskScopePort.class);
        assertEquals(com.uten.imp.application.port.WarehouseTaskScopePort.Role.OTHER,scopes.access().role());
        assertTrue(scopes.current(null).includeUnassigned());
        var pending=discovery.list("PENDING",1,100);
        assertTrue(pending.getItems().stream().anyMatch(item->unknown.requestId().equals(item.requestId())));
        var workbench=beans.getBean(com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService.class);
        assertEquals(workbench.warehouseStatusBreakdown(scopes.current(null)).get("MATERIALS_TO_DEFINE").longValue(),pending.getTotal());
        assertEquals(com.uten.imp.common.web.ErrorCode.FORBIDDEN,assertThrows(ApiException.class,
                ()->discovery.configure(unknown.requestId(),new Configure(unknown.version(),"scope-outside-source-"+segment,
                        List.of(new Material(world.goodsD(),null,world.unitId(),own,BigDecimal.ONE))))).getCode());
        assertEquals("PENDING",discovery.detail(unknown.requestId()).status());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_discovery_lines WHERE request_id=?",Integer.class,unknown.requestId()));
        Detail configured=discovery.configure(unknown.requestId(),command);
        assertEquals(configured,discovery.configure(unknown.requestId(),command));
        assertEquals(1,configured.items().size());assertEquals(other,configured.items().getFirst().warehouseId());

        // Scope is resolved live, including an old confirmation's idempotent replay.
        db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) SELECT ?,employee_id FROM users WHERE id=?",other,keeper);
        assertEquals(com.uten.imp.common.web.ErrorCode.NOT_FOUND,assertThrows(ApiException.class,
                ()->discovery.configure(unknown.requestId(),command)).getCode());
        fixture.loginAs(keeper);
        assertEquals(3,discovery.list("CONFIGURED",1,1).getTotal());
        assertEquals(otherConfigured.requestId(),discovery.detail(otherConfigured.requestId()).requestId());
        fixture.loginAs(pool);
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",world.departmentId(),pool);
        assertEquals(com.uten.imp.common.web.ErrorCode.FORBIDDEN,assertThrows(ApiException.class,
                ()->discovery.list("PENDING",1,1)).getCode());
        assertEquals(com.uten.imp.common.web.ErrorCode.FORBIDDEN,assertThrows(ApiException.class,
                ()->discovery.configure(unknown.requestId(),command)).getCode());
        fixture.loginAs(world.superAdminUserId());
        assertEquals(configured,discovery.detail(unknown.requestId()));
    }

    @Test void warehouseConfirmationRechecksKeeperChangesAfterWaitingForThePlanLock() throws Exception {
        UUID actual=discoveryLeaf();receive(world.goodsD(),"2",actual);
        Detail pending=discovery.request(segment,new Request(version(),"scope-lock-request-"+segment));
        UUID pool=discoveryWarehouseUser(null),keeper=discoveryWarehouseUser(discoveryLeaf());
        Configure command=new Configure(pending.version(),"scope-lock-config-"+segment,
                List.of(new Material(world.goodsD(),null,world.unitId(),actual,BigDecimal.ONE)));
        var executor=java.util.concurrent.Executors.newSingleThreadExecutor();
        try(var blocker=Objects.requireNonNull(db.getDataSource()).getConnection()) {
            blocker.setAutoCommit(false);
            try(var lock=blocker.prepareStatement("SELECT id FROM production_plans WHERE id=? FOR UPDATE")) {
                lock.setObject(1,plan);lock.executeQuery().close();
            }
            var attempted=executor.submit(()->{
                fixture.loginAs(pool);
                try {return assertThrows(ApiException.class,()->discovery.configure(pending.requestId(),command));}
                finally {SecurityContextHolder.clearContext();}
            });
            boolean waiting=false;
            long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(10);
            while(System.nanoTime()<deadline) {
                waiting=Boolean.TRUE.equals(db.queryForObject("""
                        SELECT EXISTS(SELECT 1 FROM pg_stat_activity
                          WHERE datname=current_database() AND wait_event_type='Lock'
                            AND lower(query) LIKE '%production_plans%')
                        """,Boolean.class));
                if(waiting)break;
                Thread.sleep(20);
            }
            assertTrue(waiting,"配置已通过初始未分仓与来源范围检查，正在等待计划锁");
            db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) SELECT ?,employee_id FROM users WHERE id=?",actual,keeper);
            blocker.commit();
            ApiException denied=attempted.get(30,java.util.concurrent.TimeUnit.SECONDS);
            assertEquals(com.uten.imp.common.web.ErrorCode.FORBIDDEN,denied.getCode(),denied::getMessage);
        } finally {executor.shutdownNow();}
        fixture.loginAs(world.superAdminUserId());
        assertEquals("PENDING",discovery.detail(pending.requestId()).status());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_discovery_lines WHERE request_id=?",Integer.class,pending.requestId()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
    }

    @Test void productionTraceUsesActualIssuesInBothDirectionsAndFiltersBeforePaging(){
        receive(world.goodsD(),"10");receive(world.goodsE(),"5");
        Detail pending=discovery.request(segment,new Request(version(),"trace-issue-"+segment));
        Detail configured=discovery.configure(pending.requestId(),new Configure(pending.version(),"trace-config-"+segment,List.of(
                new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),new BigDecimal("8")),
                new Material(world.goodsE(),null,world.unitId(),world.warehouseId(),new BigDecimal("2")))));
        assertEquals(0,traces.query(world.goodsC(),"materials",1,20).getTotal(),"预留和申请不能冒充实领");
        issue(configured);
        var forward=traces.query(world.goodsD(),"usage",1,20);
        assertEquals(1,forward.getTotal());
        var row=forward.getItems().getFirst();
        assertEquals("ORDER",row.kind());assertEquals(world.goodsC(),row.product().goodsId());
        assertEquals(world.goodsD(),row.material().goodsId());assertEquals(world.unitId(),row.material().unitId());
        assertEquals(0,new BigDecimal("8").compareTo(row.issuedQty()));
        assertNull(row.consumedQty(),"未登记实耗要留空，不能把实领8个当作已耗或已确认耗用0");assertTrue(row.receiptSources().isEmpty());
        assertEquals(configured.drawDocIds().size(),row.drawDocuments().size());
        assertEquals(2,traces.query(world.goodsC(),"materials",1,1).getTotal());
        assertEquals(1,traces.query(world.goodsC(),"materials",2,1).getItems().size());

        UUID outside=fixture.createUserWithPerms(world,"trace-outside-"+UUID.randomUUID(),"stock:view","production_execution:view");
        fixture.loginAs(outside);
        assertEquals(0,traces.query(world.goodsC(),"materials",1,1).getTotal(),"不能从总数旁路对象范围");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",workshop,outside);
        fixture.loginAs(outside);
        var assigned=traces.query(world.goodsD(),"usage",1,20).getItems().getFirst();
        assertTrue(assigned.drawDocuments().isEmpty(),"没有仓库单据阅读权限不泄漏源单");
        assertTrue(assigned.reports().isEmpty());
        UUID stockOnly=fixture.createUserWithPerms(world,"trace-stock-only-"+UUID.randomUUID(),"stock:view");
        fixture.loginAs(stockOnly);
        assertEquals(com.uten.imp.common.web.ErrorCode.FORBIDDEN,assertThrows(ApiException.class,
                ()->traces.query(world.goodsD(),"usage",1,20)).getCode());
        UUID stockDocOnly=fixture.createUserWithPerms(world,"trace-stock-doc-only-"+UUID.randomUUID(),"stock:view","stock_doc:view");
        fixture.loginAs(stockDocOnly);
        assertEquals(com.uten.imp.common.web.ErrorCode.FORBIDDEN,assertThrows(ApiException.class,
                ()->traces.query(world.goodsD(),"usage",1,20)).getCode(),"库存单据阅读权限本身不能扩大生产追溯范围");
        db.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted) WHERE id=(SELECT employee_id FROM users WHERE id=?)",stockDocOnly);
        fixture.loginAs(stockDocOnly);
        assertEquals(1,traces.query(world.goodsD(),"usage",1,20).getTotal(),"真实仓库任务参与者按现有跨模块阅读能力可追溯");

        fixture.loginAs(world.superAdminUserId());
        UUID draw=configured.drawDocIds().getFirst();
        StockDocIssueRequest reverse=new StockDocIssueRequest();reverse.setIdempotencyKey("trace-reverse-"+draw);reverse.setReason("追溯取消出库回归");
        reverse.setLines(db.query("SELECT id,qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",(rs,index)->{
            var line=new StockDocIssueRequest.Line();line.setItemId(rs.getObject(1,UUID.class));line.setQty(rs.getBigDecimal(2));return line;},draw));
        stock.reverseIssue(draw,reverse);
        var reversed=traces.query(world.goodsD(),"usage",1,20).getItems().getFirst();
        assertEquals(0,reversed.issuedQty().signum());assertFalse(reversed.drawDocuments().isEmpty(),"净额冲回后仍保留真实单据历史");
    }

    @Test void productionTraceShowsReviewedOutputParticipantsAndNetsReportReversal(){
        receive(world.goodsD(),"2");
        Detail pending=discovery.request(segment,new Request(version(),"trace-report-"+segment));
        Detail configured=discovery.configure(pending.requestId(),new Configure(pending.version(),"trace-report-config-"+segment,List.of(
                new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),new BigDecimal("2")))));
        issue(configured);segments.start(plan,segment,new SegmentTransitionRequest(version(),"trace-start-"+segment));
        UUID report=createReportDraft("1","0.6",configured.items().getFirst().demandId());
        assertTrue(traces.query(world.goodsD(),"usage",1,20).getItems().getFirst().reports().isEmpty());
        var reports=beans.getBean(com.uten.imp.features.production.dailyreport.ProductionDailyReportService.class);
        reports.approve(report,com.uten.imp.support.DailyReportApproveRequests.freshKey());
        var reviewed=traces.query(world.goodsD(),"usage",1,20).getItems().getFirst();
        assertEquals(0,new BigDecimal("0.6").compareTo(reviewed.consumedQty()));
        assertEquals(1,reviewed.reports().size());assertEquals(report,reviewed.reports().getFirst().id());
        assertEquals(BusinessTime.today(),reviewed.reports().getFirst().billDate());
        assertEquals(0,BigDecimal.ONE.compareTo(reviewed.reports().getFirst().productQty()));
        assertEquals(worker,reviewed.reports().getFirst().workers().getFirst().id());
        reports.reverse(report);
        var reversed=traces.query(world.goodsD(),"usage",1,20).getItems().getFirst();
        assertEquals(0,reversed.consumedQty().signum());assertTrue(reversed.reports().isEmpty());
        assertEquals(0,new BigDecimal("2").compareTo(reversed.issuedQty()));
    }

    @Test void productionTraceReturnsOnlyProvenPurchaseReceiptsAndMasksSupplierWithoutPermission(){
        fixture.insertBom(world.goodsC(),world.goodsD(),"1");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",world.supplierId(),world.goodsD());
        UUID orderItem=ReflectionTestUtils.invokeMethod(fixture,"procureDirectBuy",world,world.goodsC(),world.goodsD(),"4");
        UUID receipt=ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",world,orderItem,world.goodsD(),new BigDecimal("2"),"root-trace-first-"+orderItem);
        UUID secondReceipt=ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",world,orderItem,world.goodsD(),new BigDecimal("2"),"root-trace-second-"+orderItem);
        fixture.loginAs(world.superAdminUserId());
        UUID receiptPlan=db.queryForObject("SELECT DISTINCT demand.plan_id FROM production_material_receipt_allocations allocation JOIN production_material_demands demand ON demand.id=allocation.demand_id WHERE allocation.receipt_id IN (?,?)",UUID.class,receipt,secondReceipt);
        List<UUID> draws=db.queryForList("SELECT DISTINCT draw_id FROM production_material_receipt_allocations WHERE receipt_id IN (?,?)",UUID.class,receipt,secondReceipt);
        fixture.requestWorkshopDraws("trace-purchase-"+receipt,draws);
        for(UUID draw:draws){
            var issue=new StockDocIssueRequest();issue.setIdempotencyKey("trace-purchase-issue-"+draw);
            issue.setLines(db.query("SELECT id,qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",(rs,index)->{
                var line=new StockDocIssueRequest.Line();line.setItemId(rs.getObject(1,UUID.class));line.setQty(rs.getBigDecimal(2));return line;},draw));
            stock.approveAndIssue(draw,issue);
        }
        var proven=traces.query(world.goodsD(),"usage",1,20).getItems().stream().filter(row->row.planId().equals(receiptPlan)).findFirst().orElseThrow();
        assertEquals(2,proven.receiptSources().size());
        assertEquals(Set.of(receipt,secondReceipt),proven.receiptSources().stream().map(com.uten.imp.features.stock.trace.GoodsProductionTraceContracts.ReceiptSource::id).collect(java.util.stream.Collectors.toSet()));
        for(var source:proven.receiptSources()) {
            assertEquals("PURCHASE_RECEIPT",source.sourceDocType());assertEquals(world.supplierId(),source.supplierId());
            assertEquals(0,new BigDecimal("2").compareTo(source.qty()),"两张进货来源各只显示自己分配的2，不能各显示总实发4");
            assertTrue(source.sourceBasis().contains("非逐批实耗"));
        }
        UUID partialDraw=draws.getFirst();
        var reverse=new StockDocIssueRequest();reverse.setIdempotencyKey("trace-receipt-reverse-"+partialDraw);reverse.setReason("退回一部分，保留原分配来源");
        var reverseLine=new StockDocIssueRequest.Line();reverseLine.setItemId(db.queryForObject("SELECT id FROM stock_document_items WHERE doc_id=? AND NOT is_deleted ORDER BY line_no LIMIT 1",UUID.class,partialDraw));
        reverseLine.setQty(BigDecimal.ONE);reverse.setLines(List.of(reverseLine));stock.reverseIssue(partialDraw,reverse);
        var afterReverse=traces.query(world.goodsD(),"usage",1,20).getItems().getFirst();
        assertEquals(0,new BigDecimal("3").compareTo(afterReverse.issuedQty()));
        assertEquals(0,new BigDecimal("4").compareTo(afterReverse.receiptSources().stream().map(com.uten.imp.features.stock.trace.GoodsProductionTraceContracts.ReceiptSource::qty).reduce(BigDecimal.ZERO,BigDecimal::add)),
                "入库预留分配量保持原证据，不能凭一次退回猜改其中某批实际耗用");
        var admin=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var limited=new AuthUser(admin.getId(),admin.getEmployeeId(),admin.getUsername(),
                Set.of("stock:view","production_plan:view","production_plan:view:all","purchase_receipt:view","purchase:view:all"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(limited,null,limited.getAuthorities()));
        var masked=traces.query(world.goodsD(),"usage",1,20).getItems().getFirst().receiptSources();
        assertEquals(2,masked.size());assertTrue(masked.stream().allMatch(source->source.supplierId()==null&&source.supplierName()==null));
    }

    @Test void productionTraceNeverDuplicatesWholeReportOutputAcrossDifferentProducts(){
        receive(world.goodsD(),"10");
        Map<UUID,UUID> demands=new LinkedHashMap<>();
        for(int index=0;index<2;index++) {
            if(index==1) {
                UUID product=UUID.randomUUID();fixture.insertGoods(product,"TRACE-P-"+product,"第二个追溯产品","自制",world.unitId(),world.unitLegacy());
                releaseTask(product,"200");
            }
            Detail pending=discovery.request(segment,new Request(version(),"trace-multi-request-"+segment));
            Detail configured=discovery.configure(pending.requestId(),new Configure(pending.version(),"trace-multi-config-"+segment,List.of(
                    new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),new BigDecimal("3")))));
            demands.put(segment,configured.items().getFirst().demandId());issue(configured);
            segments.start(plan,segment,new SegmentTransitionRequest(version(),"trace-multi-start-"+segment));
        }
        var reportable=beans.getBean(ReportablePlanLineQueryService.class).list(1,50,null,workshop,List.copyOf(demands.keySet())).getItems();
        var request=new com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest();
        request.setIdempotencyKey("trace-multi-report-"+segment);request.setBillDate(BusinessTime.today());request.setDepartmentId(workshop);request.setWorkerIds(List.of(worker));
        var lines=new ArrayList<com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine>();
        var materialLines=new ArrayList<com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine>();
        Map<UUID,BigDecimal> outputs=new HashMap<>();int number=0;
        for(var source:reportable) {
            UUID sid=source.executionSegmentId();BigDecimal output=new BigDecimal(++number);outputs.put(sid,output);
            var line=new com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine();line.setLineNo(number);line.setPlanItemId(source.planItemId());line.setExecutionSegmentId(sid);
            line.setExecutionSegmentSalesAllocationId(source.executionSegmentSalesAllocationId());line.setSalesOrderItemId(source.orderItemId());
            line.setGoodsId(db.queryForObject("SELECT product_goods_id FROM production_execution_segments WHERE id=?",UUID.class,sid));
            line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(output);lines.add(line);
            var usage=new com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine();usage.setDemandId(demands.get(sid));usage.setQtyBase(output);materialLines.add(usage);
        }
        request.setItems(lines);request.setMaterialLines(materialLines);
        var reports=beans.getBean(com.uten.imp.features.production.dailyreport.ProductionDailyReportService.class);
        UUID report=reports.create(request).getId();reports.approve(report,com.uten.imp.support.DailyReportApproveRequests.freshKey());
        var traced=traces.query(world.goodsD(),"usage",1,20);assertEquals(2,traced.getTotal());
        for(var row:traced.getItems()) {
            assertEquals(1,row.reports().size());assertEquals(report,row.reports().getFirst().id());
            assertEquals(row.segmentId(),row.reports().getFirst().segmentId());
            assertEquals(0,outputs.get(row.segmentId()).compareTo(row.reports().getFirst().productQty()));
        }
    }

    @Test void productionTraceKeepsKilogramMaterialAndFrozenBoxReportingUnitsSeparate(){
        UUID box=UUID.randomUUID(),kg=UUID.randomUUID(),gram=UUID.randomUUID(),plastic=UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name) VALUES (?,?,'箱'),(?,?,'千克'),(?,?,'克')",
                box,"TRACE-BOX-"+box,kg,"TRACE-KG-"+kg,gram,"TRACE-G-"+gram);
        db.update("INSERT INTO goods(id,code,name,source_type,status,unit_id,price,code_sequence) VALUES (?,?,'追溯千克塑料','采购','使用',?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",
                plastic,"TRACE-PLASTIC-"+plastic,kg);
        var orderRequest=fixture.orderRequest(world,world.goodsC(),"2","100");
        orderRequest.getItems().getFirst().setUnitId(box);orderRequest.getItems().getFirst().setUnitRate(new BigDecimal("20"));
        var sales=beans.getBean(com.uten.imp.features.sales.order.SalesOrderService.class);
        UUID order=sales.create(orderRequest).getId();sales.approve(order);
        ReflectionTestUtils.invokeMethod(fixture,"confirmInitialSalesFinance",order);releaseOrder(order,"2");
        assertEquals(box,db.queryForObject("SELECT product_unit_id FROM production_execution_segments WHERE id=?",UUID.class,segment));
        assertEquals(0,new BigDecimal("20").compareTo(db.queryForObject("SELECT product_unit_rate FROM production_execution_segments WHERE id=?",BigDecimal.class,segment)));
        var inbound=new StockDocSaveRequest();inbound.setDocType("OTHER_IN");inbound.setWarehouseId(world.warehouseId());inbound.setBillDate(BusinessTime.today());
        var input=new StockDocItemLine();input.setGoodsId(plastic);input.setUnitId(gram);input.setUnitRate(new BigDecimal("0.001"));input.setQty(new BigDecimal("2000"));
        input.setPrice(new BigDecimal("0.01"));input.setAmountOriginal(new BigDecimal("20"));input.setAmountLocal(new BigDecimal("20"));inbound.setItems(List.of(input));stock.approve(stock.create(inbound).getId());
        Detail pending=discovery.request(segment,new Request(version(),"trace-units-"+segment));
        Detail configured=discovery.configure(pending.requestId(),new Configure(pending.version(),"trace-unit-config-"+segment,List.of(
                new Material(plastic,null,kg,world.warehouseId(),new BigDecimal("2")))));
        issue(configured);segments.start(plan,segment,new SegmentTransitionRequest(version(),"trace-unit-start-"+segment));
        UUID report=createReportDraft("1","0.6",configured.items().getFirst().demandId());
        beans.getBean(com.uten.imp.features.production.dailyreport.ProductionDailyReportService.class).approve(report,com.uten.imp.support.DailyReportApproveRequests.freshKey());
        var traced=traces.query(plastic,"usage",1,20).getItems().getFirst();
        assertEquals(kg,traced.material().unitId());assertEquals("千克",traced.material().unitName());
        assertEquals(0,new BigDecimal("2").compareTo(traced.issuedQty()));assertEquals(0,new BigDecimal("0.6").compareTo(traced.consumedQty()));
        assertEquals(box,traced.product().unitId());assertEquals("箱",traced.reports().getFirst().unitName());
        assertEquals(0,BigDecimal.ONE.compareTo(traced.reports().getFirst().productQty()),"20基本个不能显示成20箱");
    }

    @Test void workshopSuggestionsKeepOptionalQuantitiesAndReplayWithoutInstallingInventoryOrBom(){
        UUID user=fixture.createUserWithPerms(world,"discovery-workshop-"+UUID.randomUUID(),"production_execution:view","production_execution:start");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",workshop,user);
        fixture.loginAs(user);
        long expected=version();String key="suggestion-request-"+segment;
        var unknownQuantity=new RequestedMaterial(world.goodsE(),null,world.unitId(),null);
        var knownQuantity=new RequestedMaterial(world.goodsD(),null,world.unitId(),new BigDecimal("12.5"));
        Detail pending=discovery.request(segment,new Request(expected,key,List.of(unknownQuantity,knownQuantity)));
        assertEquals("PENDING",pending.status());assertEquals(2,pending.suggestedItems().size());
        assertEquals(0,pending.items().size());assertEquals(0,pending.drawDocIds().size());
        fixture.loginAs(world.superAdminUserId());
        var warehouse=beans.getBean(com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService.class);
        var queued=warehouse.query("WAREHOUSE","MATERIALS_TO_DEFINE",pending.segmentCode(),null,null,null,1,20);
        assertEquals(1,queued.total());var materialRow=queued.items().getFirst();
        assertTrue(materialRow.materialsDefined());assertEquals(2,materialRow.goodsCount());assertEquals(2,materialRow.openLineCount());
        assertEquals(pending.productName(),materialRow.productionProductName());
        for(SuggestedItem item:pending.suggestedItems()) {
            assertTrue(materialRow.goodsName().contains(item.goodsName()));
            assertEquals(1,warehouse.query("WAREHOUSE","MATERIALS_TO_DEFINE",item.goodsName(),null,null,null,1,20).total());
        }
        fixture.loginAs(user);
        assertNull(pending.suggestedItems().stream().filter(item->item.goodsId().equals(world.goodsE())).findFirst().orElseThrow().qty());
        assertEquals(pending,discovery.request(segment,new Request(expected,key,List.of(
                new RequestedMaterial(world.goodsD(),null,world.unitId(),new BigDecimal("12.5000")),unknownQuantity))));
        assertThrows(ApiException.class,()->discovery.request(segment,new Request(expected,key,List.of(unknownQuantity))));
        assertThrows(ApiException.class,()->discovery.request(segment,new Request(expected,key,List.of(
                new RequestedMaterial(world.goodsD(),null,world.unitId(),new BigDecimal("13")),unknownQuantity))));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",Integer.class,world.goodsC()));
        assertFalse(ready());
        assertThrows(ApiException.class,()->discovery.configure(pending.requestId(),new Configure(pending.version(),"suggestion-forbidden-"+segment,
                List.of(new Material(world.goodsD(),null,world.unitId(),world.warehouseId(),BigDecimal.ONE)))));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update(
                "UPDATE production_material_discovery_requests SET status='CANCELLED',row_version=row_version+1,cancelled_by=?,cancelled_at=now(),cancellation_key=?,cancellation_hash=?,requested_materials='[]'::jsonb WHERE id=?",
                user,"tamper-"+segment,"0".repeat(64),pending.requestId()));
        Detail cancelled=discovery.cancel(pending.requestId(),new Request(pending.version(),"suggestion-cancel-"+segment));
        assertEquals(pending.suggestedItems(),cancelled.suggestedItems());
        long retryVersion=version();String retryKey="suggestion-empty-"+segment;
        Detail noSuggestions=discovery.request(segment,new Request(retryVersion,retryKey,List.of()));
        assertEquals(noSuggestions,discovery.request(segment,new Request(retryVersion,retryKey)));
        assertTrue(noSuggestions.suggestedItems().isEmpty());
    }

    @Test void invalidWorkshopSuggestionLeavesNoRequestOrMaterialFacts(){
        var valid=new RequestedMaterial(world.goodsD(),null,world.unitId(),null);
        List<List<RequestedMaterial>> invalid=List.of(List.of(valid,valid),
                List.of(new RequestedMaterial(world.goodsC(),null,world.unitId(),BigDecimal.ONE)),
                List.of(new RequestedMaterial(world.goodsA(),null,world.unitId(),BigDecimal.ONE)),
                List.of(new RequestedMaterial(world.goodsD(),UUID.randomUUID(),world.unitId(),BigDecimal.ONE)),
                List.of(new RequestedMaterial(world.goodsD(),null,UUID.randomUUID(),BigDecimal.ONE)),
                List.of(new RequestedMaterial(world.goodsD(),null,world.unitId(),BigDecimal.ZERO)),
                List.of(new RequestedMaterial(world.goodsD(),null,world.unitId(),new BigDecimal("0.00001"))));
        long expected=version();
        for(List<RequestedMaterial> items:invalid)assertThrows(ApiException.class,()->discovery.request(segment,new Request(expected,"invalid-suggestion-"+UUID.randomUUID(),items)));
        db.update("UPDATE goods SET status='禁用' WHERE id=?",world.goodsD());
        assertThrows(ApiException.class,()->discovery.request(segment,new Request(expected,"disabled-suggestion-"+segment,List.of(valid))));
        db.update("UPDATE goods SET status='使用',auto_created=TRUE WHERE id=?",world.goodsD());
        assertThrows(ApiException.class,()->discovery.request(segment,new Request(expected,"placeholder-suggestion-"+segment,List.of(valid))));
        db.update("UPDATE goods SET auto_created=FALSE WHERE id=?",world.goodsD());
        db.update("UPDATE units SET status='禁用' WHERE id=?",world.unitId());
        assertThrows(ApiException.class,()->discovery.request(segment,new Request(expected,"disabled-unit-suggestion-"+segment,List.of(valid))));
        db.update("UPDATE units SET status='使用' WHERE id=?",world.unitId());
        assertEquals(expected,version());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_discovery_requests WHERE execution_segment_id=?",Integer.class,segment));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
    }

    @ParameterizedTest
    @ValueSource(strings={"GOODS_DISABLED","PLACEHOLDER","UNIT_DISABLED","COLOR_DISABLED"})
    void warehouseConfirmationRechecksActiveMaterialMasterData(String change){
        UUID color="COLOR_DISABLED".equals(change)?UUID.randomUUID():null;
        if(color!=null)db.update("INSERT INTO colors(id,code,name,status) VALUES (?,?,'停用前已存货颜色','使用')",color,"MEMORY-OFF-"+color);
        receive(world.goodsD(),"2",world.warehouseId(),color);
        Detail pending=discovery.request(segment,new Request(version(),"master-recheck-request-"+segment));
        long segmentVersion=version();
        switch(change) {
            case "GOODS_DISABLED" -> db.update("UPDATE goods SET status='禁用' WHERE id=?",world.goodsD());
            case "PLACEHOLDER" -> db.update("UPDATE goods SET auto_created=TRUE WHERE id=?",world.goodsD());
            case "UNIT_DISABLED" -> db.update("UPDATE units SET status='禁用' WHERE id=?",world.unitId());
            case "COLOR_DISABLED" -> db.update("UPDATE colors SET status='禁用' WHERE id=?",color);
            default -> throw new AssertionError(change);
        }
        UUID materialColor=color;
        ApiException failure=assertThrows(ApiException.class,()->discovery.configure(pending.requestId(),
                new Configure(pending.version(),"master-recheck-confirm-"+segment,List.of(
                        new Material(world.goodsD(),materialColor,world.unitId(),world.warehouseId(),BigDecimal.ONE)))));
        assertEquals(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,failure.getCode(),failure::getMessage);
        assertEquals(segmentVersion,version(),"拒绝过期主档不能推进车间任务版本");
        assertEquals("PENDING",discovery.detail(pending.requestId()).status());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_discovery_lines WHERE request_id=?",Integer.class,pending.requestId()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
    }

    @Test void unknownMaterialsRequireRealRequestedIssueBeforeStartAndReplayCreatesNothingTwice(){
        assertTrue(discovery.context(segment).materialDiscoveryRequired());assertFalse(ready());
        assertThrows(ApiException.class,()->segments.start(plan,segment,new SegmentTransitionRequest(version(),"early-start-"+segment)));
        Request request=new Request(version(),"discover-request-"+segment);Detail pending=discovery.request(segment,request);
        assertEquals(pending.requestId(),discovery.request(segment,request).requestId());assertEquals("PENDING",pending.status());assertFalse(ready());
        assertTrue(pending.requestNo().matches("LQ[0-9]{14}"));assertTrue(pending.drawDocuments().isEmpty());
        long afterRequest=version();
        var duplicated=assertThrows(ApiException.class,()->discovery.request(segment,new Request(afterRequest,"duplicate-pending-"+segment)));
        assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,duplicated.getCode());assertTrue(duplicated.getMessage().contains("已提交领料"));
        assertEquals(afterRequest,version());assertEquals(pending,discovery.detail(pending.requestId()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_material_discovery_requests WHERE execution_segment_id=?",Integer.class,segment));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
        var warehouse=beans.getBean(com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService.class);
        var queued=warehouse.query("WAREHOUSE","MATERIALS_TO_DEFINE",pending.segmentCode(),null,null,null,1,20);
        assertEquals(1,queued.total());assertEquals("MATERIAL_DISCOVERY",queued.items().getFirst().actionDocType());
        assertFalse(queued.items().getFirst().materialsDefined());assertNull(queued.items().getFirst().goodsId());assertNull(queued.items().getFirst().goodsName());
        assertEquals(0,queued.items().getFirst().goodsCount());assertEquals(1,queued.items().getFirst().openLineCount());
        assertEquals(pending.productCode(),queued.items().getFirst().productionProductCode());assertEquals(pending.productName(),queued.items().getFirst().productionProductName());
        assertEquals(pending.requestId(),queued.items().getFirst().actionDocId());assertTrue(queued.items().getFirst().actionDocCanEdit());
        assertEquals(pending.requestNo(),queued.items().getFirst().actionDocNo());
        assertEquals(pending.requestNo(),queued.items().getFirst().materialRequestNo());
        assertTrue(queued.facets().get("docNo").stream().anyMatch(facet->pending.requestNo().equals(facet.value())));
        var numberFilter=new com.uten.imp.features.operations.workbench.FulfillmentWorkbenchTableQuery("docNo","asc",Map.of("docNo",pending.requestNo()),null,null,null,null);
        assertEquals(1,warehouse.query("WAREHOUSE","MATERIALS_TO_DEFINE",pending.requestNo(),null,null,null,1,20,numberFilter).total());
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
        assertEquals(pending.requestNo(),configured.requestNo());
        assertEquals(configured.drawDocIds(),configured.drawDocuments().stream().map(DrawDocument::id).toList());
        assertTrue(configured.drawDocuments().getFirst().billNo().matches("SL[0-9]{14}"));
        assertEquals(pending.requestNo(),stock.detail(configured.drawDocIds().getFirst()).getMaterialRequestNo());
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
        assertEquals(pending.requestNo(),cancelled.requestNo());
        assertEquals(cancelled,discovery.cancel(pending.requestId(),new Request(pending.version(),"cancel-"+segment)));
        assertTrue(discovery.context(segment).canRequest());var next=discovery.request(segment,new Request(version(),"request-again-"+segment));assertNotEquals(pending.requestId(),next.requestId());
        assertNotEquals(pending.requestNo(),next.requestNo());
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
        assertEquals(pending.requestNo(),defined.requestNo());
        assertEquals(2,defined.drawDocuments().stream().map(DrawDocument::billNo).distinct().count());
        for(DrawDocument document:defined.drawDocuments()) {
            assertTrue(document.billNo().matches("SL[0-9]{14}"));
            assertNotEquals(defined.requestNo(),document.billNo());
            assertEquals(defined.requestNo(),stock.detail(document.id()).getMaterialRequestNo());
        }
        var warehouse=beans.getBean(com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService.class);
        var linked=warehouse.query("WAREHOUSE","OPEN_ANY",defined.requestNo(),null,null,null,1,20);
        assertEquals(2,linked.total());assertTrue(linked.items().stream().allMatch(row->defined.requestNo().equals(row.materialRequestNo())&&row.actionDocNo().startsWith("SL")));
        assertEquals(0,new BigDecimal("5").compareTo(linked.items().stream().map(com.uten.imp.features.operations.workbench.FulfillmentTaskRow::requiredQty).reduce(BigDecimal.ZERO,BigDecimal::add)));
        assertEquals(0,new BigDecimal("5").compareTo(linked.items().stream().map(com.uten.imp.features.operations.workbench.FulfillmentTaskRow::openQty).reduce(BigDecimal.ZERO,BigDecimal::add)));
        assertEquals(Set.of(first,second),new HashSet<>(linked.items().stream().map(com.uten.imp.features.operations.workbench.FulfillmentTaskRow::warehouseId).toList()));
        for(UUID actual:List.of(first,second)) {
            var scope=new com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope(true,List.of(actual),false);
            var scoped=warehouse.query("WAREHOUSE","OPEN_ANY",defined.requestNo(),null,null,null,1,20,null,scope);
            assertEquals(1,scoped.total());assertEquals(actual,scoped.items().getFirst().warehouseId());
            assertEquals(1L,warehouse.warehouseStatusBreakdown(scope).get("OPEN_ANY"));
        }
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
        db.update("UPDATE goods SET spec='PC-测试规格',stock_place='原料架 A-03' WHERE id=?",world.goodsD());
        Detail pending=discovery.request(segment,new Request(version(),"third-request-"+segment,
                List.of(new RequestedMaterial(world.goodsD(),null,world.unitId(),new BigDecimal("2")))));
        SuggestedItem suggested=pending.suggestedItems().getFirst();
        assertEquals(world.goodsD(),suggested.goodsId());
        assertEquals("PC-测试规格",suggested.spec());assertEquals("原料架 A-03",suggested.stockPlace());
        var warehouse=beans.getBean(com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService.class);
        var suggestedRow=warehouse.query("WAREHOUSE","MATERIALS_TO_DEFINE",pending.segmentCode(),null,null,null,1,20).items().getFirst();
        assertTrue(suggestedRow.materialsDefined());assertEquals(suggested.goodsId(),suggestedRow.goodsId());
        assertEquals(suggested.goodsName(),suggestedRow.goodsName());assertEquals(suggested.unitId(),suggestedRow.unitId());
        assertEquals(0,suggested.qty().compareTo(suggestedRow.openQty()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",Integer.class,world.goodsC()));
        var batch=beans.getBean(com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchService.class);
        assertEquals(1,batch.issue(new com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchContracts.Request(
                "third-batch-"+segment,List.of(),List.of(new com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchContracts.Discovery(
                        pending.requestId(),pending.version(),List.of(new Material(suggested.goodsId(),suggested.colorId(),suggested.unitId(),world.warehouseId(),suggested.qty())))),null)).issuedCount());
        Detail defined=discovery.detail(pending.requestId());
        assertEquals(suggested.spec(),defined.items().getFirst().spec());assertEquals(suggested.stockPlace(),defined.items().getFirst().stockPlace());
        var drawRow=warehouse.query("WAREHOUSE","DONE",defined.planNo(),null,null,null,1,20).items().getFirst();
        assertEquals("DRAW",drawRow.actionDocType());assertEquals(suggested.goodsId(),drawRow.goodsId());
        assertEquals(defined.productName(),drawRow.productionProductName());
        assertTrue(ready());
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
        UUID returnedItem=db.queryForObject("SELECT id FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",UUID.class,returned);
        // ADR-135 §3.9: 收料时逐行实称 -> 确认记录留证, 退料入库流水记实称, 登记退料观测(往来方 = 退料车间)。
        stock.confirmProductionMaterialReturn(returned,new ProductionMaterialReturnConfirmRequest(world.warehouseId(),"third-return-"+segment,
                List.of(new ProductionMaterialReturnConfirmRequest.Line(returnedItem,new BigDecimal("0.05")))));
        var traced=traces.query(world.goodsD(),"usage",1,20).getItems().getFirst();
        assertEquals(0,new BigDecimal("0.2").compareTo(traced.returnedQty()));
        assertEquals(0,new BigDecimal("1.8").compareTo(traced.consumedQty()));
        assertEquals(0,new BigDecimal("3").compareTo(traced.reports().getFirst().productQty()));
        assertEquals(Set.of("DRAW","WDRAW"),traced.drawDocuments().stream().map(com.uten.imp.features.stock.trace.GoodsProductionTraceContracts.DocumentRef::docType).collect(java.util.stream.Collectors.toSet()));
        Map<String,Object> receivedMovement=db.queryForMap("""
                SELECT weight,weight_source FROM stock_movements WHERE source_item_id=? AND direction=1 AND movement_type IN (6,7)""",returnedItem);
        assertEquals(0,new BigDecimal("0.05").compareTo((BigDecimal)receivedMovement.get("weight")));
        assertEquals("MEASURED",receivedMovement.get("weight_source"));
        assertEquals("WORKSHOP",db.queryForObject("SELECT counterpart_kind FROM goods_weight_observations WHERE source_item_id=? AND source_kind='RETURN'",String.class,returnedItem));
        assertEquals(0,new BigDecimal("0.05").compareTo(stock.detail(returned).getItems().getFirst().getIssuedWeightKg()));
        assertThrows(ApiException.class,()->stock.confirmProductionMaterialReturn(returned,new ProductionMaterialReturnConfirmRequest(world.warehouseId(),"third-return-"+segment,
                List.of(new ProductionMaterialReturnConfirmRequest.Line(returnedItem,new BigDecimal("0.06"))))),"同一确认键换了收料重量是另一份请求");
        assertEquals(0,new BigDecimal("0.6").compareTo(db.queryForObject("SELECT qty FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",BigDecimal.class,world.goodsC(),world.goodsD())));
        assertEquals(0,new BigDecimal("3").compareTo(db.queryForObject("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",BigDecimal.class,world.goodsC())));
        assertEquals(0,new BigDecimal("1.8").compareTo(db.queryForObject("SELECT net_qty FROM goods_bom_actual_usages WHERE goods_id=?",BigDecimal.class,world.goodsC())));
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
    // Outbox 按 SKIP LOCKED 多消费者投递(多实例; 测试 JVM 里每个缓存上下文各有一个消费者, 共用一个库)。
    // 门闩固定 CI 分区 2 命中的窗口: 待领料投递在计划停止前读到「仍在办」并插好卡、尚未提交,
    // 此时停止计划并投递可见性事件; 可见性投递不能先办结再让在途投递把卡提交回来。
    @Test void visibilityDeliveredWhilePendingDeliveryIsInFlightLeavesNoOpenNotice() throws Exception {
        UUID user=fixture.createUserWithPerms(world,"discovery-race-"+UUID.randomUUID(),"notice:read","stock_doc:view","stock_doc:approve","stock_doc:issue");
        db.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted) WHERE id=(SELECT employee_id FROM users WHERE id=?)",user);
        Detail pending=discovery.request(segment,new Request(version(),"race-request-"+segment));
        var notices=beans.getBean(com.uten.imp.features.notice.ChainNoticeService.class);
        var payload=beans.getBean(com.fasterxml.jackson.databind.ObjectMapper.class).createObjectNode();
        var delivery=new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        var pendingDelivered=new java.util.concurrent.CountDownLatch(1);var commitPending=new java.util.concurrent.CountDownLatch(1);
        var visibilityPid=new java.util.concurrent.CompletableFuture<Integer>();
        try(var consumers=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var inFlight=consumers.submit(()->delivery.executeWithoutResult(transaction->{
                notices.deliverOutboxEvent("PRODUCTION_MATERIAL_DISCOVERY_PENDING",pending.requestId(),payload);
                pendingDelivered.countDown();
                try{assertTrue(commitPending.await(60,java.util.concurrent.TimeUnit.SECONDS));}
                catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new AssertionError(interrupted);}
            }));
            java.util.concurrent.Future<?> visibility=null;
            try {
                assertTrue(pendingDelivered.await(60,java.util.concurrent.TimeUnit.SECONDS));
                db.update("UPDATE production_plans SET is_stopped=TRUE WHERE id=?",plan);
                visibility=consumers.submit(()->delivery.executeWithoutResult(transaction->{
                    visibilityPid.complete(db.queryForObject("SELECT pg_backend_pid()",Integer.class));
                    notices.deliverOutboxEvent("PRODUCTION_MATERIAL_DISCOVERY_VISIBILITY",pending.requestId(),payload);
                }));
                int pid=visibilityPid.get(60,java.util.concurrent.TimeUnit.SECONDS);
                // 放行在途投递前, 可见性投递要么已做完, 要么正等在途投递的同一申请投递锁(串行化后的唯一正确形态)。
                long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(60);
                while(true) {
                    try{visibility.get(50,java.util.concurrent.TimeUnit.MILLISECONDS);break;}
                    catch(java.util.concurrent.TimeoutException running) {
                        if(Boolean.TRUE.equals(db.queryForObject("SELECT wait_event_type='Lock' AND wait_event='advisory' FROM pg_stat_activity WHERE pid=?",Boolean.class,pid)))break;
                        assertTrue(System.nanoTime()<deadline,"可见性投递既没做完也没在等投递锁");
                    }
                }
            } finally {commitPending.countDown();}
            inFlight.get(60,java.util.concurrent.TimeUnit.SECONDS);visibility.get(60,java.util.concurrent.TimeUnit.SECONDS);
        }
        assertEquals(0,openNotices(pending.requestId()));
        // 乱序到达: 停止后才到的待领料事件只按现状撤卡; 恢复后可见性与迟到的待领料先后到达, 每人仍只有一张卡。
        delivery.executeWithoutResult(transaction->notices.deliverOutboxEvent("PRODUCTION_MATERIAL_DISCOVERY_PENDING",pending.requestId(),payload));
        assertEquals(0,openNotices(pending.requestId()));
        db.update("UPDATE production_plans SET is_stopped=FALSE WHERE id=?",plan);
        for(String event:List.of("VISIBILITY","PENDING"))
            delivery.executeWithoutResult(transaction->notices.deliverOutboxEvent("PRODUCTION_MATERIAL_DISCOVERY_"+event,pending.requestId(),payload));
        assertTrue(openNotices(pending.requestId())>0);
        assertEquals(0,db.queryForObject("SELECT count(*)-count(DISTINCT audience_user_id) FROM notices WHERE aggregate_kind='PRODUCTION_MATERIAL_DISCOVERY_REQUEST' AND aggregate_id=? AND resolved_at IS NULL",Integer.class,pending.requestId()));
    }
    int openNotices(UUID request){return db.queryForObject("SELECT count(*) FROM notices WHERE aggregate_kind='PRODUCTION_MATERIAL_DISCOVERY_REQUEST' AND aggregate_id=? AND resolved_at IS NULL",Integer.class,request);}
    UUID createReportDraft(String output,String material,UUID demand){
        var reportable=beans.getBean(ReportablePlanLineQueryService.class).list(1,50,null,workshop,List.of(segment)).getItems().getFirst();
        var request=new com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest();
        request.setIdempotencyKey("trace-report-draft-"+segment);request.setBillDate(BusinessTime.today());request.setDepartmentId(workshop);request.setWorkerIds(List.of(worker));
        var line=new com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine();line.setLineNo(1);line.setPlanItemId(reportable.planItemId());line.setExecutionSegmentId(segment);
        line.setExecutionSegmentSalesAllocationId(reportable.executionSegmentSalesAllocationId());line.setSalesOrderItemId(reportable.orderItemId());line.setGoodsId(world.goodsC());
        line.setUnitId(db.queryForObject("SELECT product_unit_id FROM production_execution_segments WHERE id=?",UUID.class,segment));
        line.setUnitRate(db.queryForObject("SELECT product_unit_rate FROM production_execution_segments WHERE id=?",BigDecimal.class,segment));line.setQty(new BigDecimal(output));
        request.setItems(List.of(line));
        var usage=new com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine();usage.setDemandId(demand);usage.setQtyBase(new BigDecimal(material));request.setMaterialLines(List.of(usage));
        return beans.getBean(com.uten.imp.features.production.dailyreport.ProductionDailyReportService.class).create(request).getId();
    }
    void issue(Detail defined){
        for(UUID draw:defined.drawDocIds()){
            var issue=new StockDocIssueRequest();issue.setIdempotencyKey("discovery-issue-"+draw);
            issue.setLines(db.query("SELECT id,qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",(rs,index)->{var line=new StockDocIssueRequest.Line();line.setItemId(rs.getObject(1,UUID.class));line.setQty(rs.getBigDecimal(2));return line;},draw));
            stock.approveAndIssue(draw,issue);
        }
    }
    void receive(UUID goods,String qty){receive(goods,qty,world.warehouseId());}
    UUID discoveryLeaf(){
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                id,"DISC-SCOPE-"+id,"责任实际仓",world.warehouseId());
        return id;
    }
    UUID discoveryWarehouseUser(UUID warehouse){
        UUID user=fixture.createUserWithPerms(world,"discovery-scope-"+UUID.randomUUID(),
                "stock:view","stock_doc:view","stock_doc:approve","stock_doc:issue");
        if(warehouse!=null)db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) SELECT ?,employee_id FROM users WHERE id=?",warehouse,user);
        else db.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted) WHERE id=(SELECT employee_id FROM users WHERE id=?)",user);
        return user;
    }
    void receive(UUID goods,String qty,UUID warehouse){
        receive(goods,qty,warehouse,null);
    }
    void receive(UUID goods,String qty,UUID warehouse,UUID color){
        var request=new StockDocSaveRequest();request.setDocType("OTHER_IN");request.setWarehouseId(warehouse);request.setBillDate(BusinessTime.today());
        var line=new StockDocItemLine();line.setGoodsId(goods);line.setColorId(color);line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(BigDecimal.TEN);
        line.setAmountOriginal(new BigDecimal(qty).multiply(BigDecimal.TEN));line.setAmountLocal(line.getAmountOriginal());request.setItems(List.of(line));stock.approve(stock.create(request).getId());
    }
    long version(){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
    boolean ready(){return Boolean.TRUE.equals(db.queryForObject("SELECT fn_execution_start_material_ready(?)",Boolean.class,segment));}
}
