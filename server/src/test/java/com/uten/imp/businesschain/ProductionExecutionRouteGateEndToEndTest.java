package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.execution.ProductionExecutionBatch;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentRouteConfirmRequest;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.mrp.ProductionExecutionBatchService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest;
import static org.junit.jupiter.api.Assertions.*;

/** Real PostgreSQL coverage of explicit workshop routes, incremental picking and material capacity. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionExecutionRouteGateEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired com.uten.imp.features.production.execution.ProductionDrawRequestService drawRequests;
    @Autowired ProductionExecutionBatchService batches;
    @Autowired StockDocService stock;
    FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
    }

    @Test
    void newTaskWaitsForRouteEvenWhenMaterialsArrive() {
        Case c=create("rg-kit",false);
        assertNull(route(c.segment()));
        assertFalse(allowsAutoPromote(c.segment()));
        receive(c,c.material(),c.leaf(),"100");
        assertEquals("WAITING",status(c.segment()));
        assertEquals(0,drawCount(c.segment()));
        fixture.loginAs(c.workerUser());
        assertTrue(assertThrows(ApiException.class,()->segments.start(c.plan(),c.segment(),
                new SegmentTransitionRequest(version(c.segment()),"rg-unconfirmed-start"))).getMessage().contains("确认生产路线"));
        assertThrows(ApiException.class,()->drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(
                List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment()))))));
        assertThrows(ApiException.class,()->batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),null)));
        confirm(c,"FULL_KIT");
        assertEquals("READY",status(c.segment()));
        issueDraws(c);
        start(c);
        assertEquals("IN_PROGRESS",status(c.segment()));
    }

    @Test
    void warehouseOnlyHundredThenNineHundredUsesOneContinuousTask() {
        Case c=create("rg-thousand",false,"1000");
        confirm(c,"CONTINUOUS");
        assertEquals("WAITING",status(c.segment()));
        receive(c,c.material(),c.leaf(),"100");
        assertEquals("READY",status(c.segment()));
        fixture.loginAs(c.workerUser());
        assertThrows(ApiException.class,()->start(c),"库存已到但还没实领不得开工");
        issueDraws(c);
        start(c);
        qty("100",capacity(c));
        receive(c,c.material(),c.leaf(),"900");
        assertEquals("IN_PROGRESS",status(c.segment()));
        issueDraws(c);
        qty("1000",capacity(c));
        qty("1000",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,c.segment()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_execution_segment_splits WHERE source_segment_id=?",Integer.class,c.segment()));
        assertEquals(2,drawCount(c.segment()),"实际发料历史保留，续料不拆生产任务");
        qty("1000",db.queryForObject("SELECT SUM(qty-released_qty) FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",BigDecimal.class,parentDemand(c)));
    }

    @Test
    void unsubmittedArrivalsMergeInOneWarehouseDraft() {
        Case c=create("rg-merge",false);
        confirm(c,"CONTINUOUS");
        receive(c,c.material(),c.leaf(),"10");
        receive(c,c.material(),c.leaf(),"20");
        assertEquals(1,drawCount(c.segment()));
        issueDraws(c);
        qty("30",capacity(c));
        start(c);
    }

    @Test
    void mixedSupplyRequiresEveryStartMaterialAndKeepsReplenishing() {
        Case c=create("rg-mixed",true);
        confirm(c,"CONTINUOUS");
        transfer(c,"20");
        assertEquals("READY",status(c.segment()));
        qty("0",capacity(c));
        assertThrows(ApiException.class,()->start(c),"仅直送料到货而仓库必需料未到不可空开工");
        receive(c,c.extraMaterial(),c.leaf(),"20");
        issueDraws(c);
        start(c);
        qty("20",capacity(c));
        transfer(c,"30");
        qty("20",capacity(c));
        receive(c,c.extraMaterial(),c.leaf(),"30");
        issueDraws(c);
        qty("50",capacity(c));
        assertEquals("IN_PROGRESS",status(c.segment()));
    }

    @Test
    void incompleteFixedBatchCannotStartAndReportCannotExceedExactCapacity() {
        Case c=create("rg-fixed",false);
        confirm(c,"CONTINUOUS");
        receive(c,c.material(),c.leaf(),"1");
        issueDraws(c);
        qty("0",capacity(c));
        assertThrows(ApiException.class,()->start(c));
        receive(c,c.material(),c.leaf(),"1");
        issueDraws(c);
        qty("10",capacity(c));
        start(c);
        fixture.loginAs(c.world().superAdminUserId());
        var report=new com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest();
        report.setIdempotencyKey("rg-fixed-over-"+c.segment());
        report.setBillDate(BusinessTime.today()); report.setWarehouseId(c.leaf());
        report.setDepartmentId(c.workshop()); report.setWorkerIds(List.of(c.worker()));
        var item=new com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine();
        item.setLineNo(1); item.setExecutionSegmentId(c.segment()); item.setPlanItemId(c.planItem());
        item.setGoodsId(c.parent()); item.setUnitId(c.world().unitId()); item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal("11")); report.setItems(List.of(item));
        assertThrows(ApiException.class,()->reports().create(report));
    }

    @Test
    void explicitBatchChoicePreservesIndependentBatchLineage() {
        Case c=create("rg-batch",false);
        confirm(c,"BATCH");
        receive(c,c.material(),c.leaf(),"40");
        fixture.loginAs(c.workerUser());
        var preview=batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),null));
        qty("40",preview.maxReadyQty());
        var result=batches.submit(new ProductionExecutionBatch.SubmitRequest(c.segment(),preview.expectedVersion(),
                preview.quantity(),preview.fingerprint(),"rg-batch-split-"+c.segment()));
        assertEquals("FULL_KIT",route(result.batchSegmentId()));
        assertEquals("BATCH",route(result.remainingSegmentId()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='ROUTE_CONFIRMED'",Integer.class,c.segment()));
    }

    @Test
    void routeConfirmationIsIdempotentAndActualIssueFreezesIt() {
        Case c=create("rg-freeze",false);
        fixture.loginAs(c.workerUser());
        var request=new SegmentRouteConfirmRequest(version(c.segment()),"rg-freeze-route","CONTINUOUS");
        segments.confirmRoute(c.plan(),c.segment(),request);
        segments.confirmRoute(c.plan(),c.segment(),request);
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='ROUTE_CONFIRMED'",Integer.class,c.segment()));
        receive(c,c.material(),c.leaf(),"10"); issueDraws(c);
        fixture.loginAs(c.workerUser());
        assertThrows(ApiException.class,()->segments.confirmRoute(c.plan(),c.segment(),
                new SegmentRouteConfirmRequest(version(c.segment()),"rg-freeze-change","FULL_KIT")));
    }

    @Test
    void pendingAndActualReturnsReduceCapacityAndCancellationRestoresOnlyTheFreeze() {
        Case c=create("rg-return",false);
        confirm(c,"CONTINUOUS");
        receive(c,c.material(),c.leaf(),"10"); issueDraws(c); start(c);
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        fixture.loginAs(c.workerUser());
        var source=returns.sources(c.plan(),c.segment()).getFirst();
        var first=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"rg-return-first-"+c.segment(),"余料先退三件",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(
                        source.issuePostingId(),new BigDecimal("3"))))).getFirst();
        qty("7",capacity(c));
        returns.cancel(c.plan(),first.documentId(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Cancel(
                "rg-return-cancel-"+c.segment(),"继续使用，撤回未收退料"));
        qty("10",capacity(c));
        var second=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"rg-return-second-"+c.segment(),"实际退回三件",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(
                        source.issuePostingId(),new BigDecimal("3"))))).getFirst();
        fixture.loginAs(c.world().superAdminUserId());
        stock.approve(second.documentId());
        qty("7",capacity(c));
        qty("3",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.leaf(),c.material()));
        qty("10",db.queryForObject("SELECT SUM(qty-released_qty) FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",BigDecimal.class,parentDemand(c)));
    }

    @Test
    void backgroundPreparedDirectMaterialKeepsAnExplicitStartEntry() {
        Case c=create("rg-system-direct",true);
        transfer(c,"20");
        assertEquals("WAITING",status(c.segment()));
        // Exact upgrade fixture: V606 saved the old route and V611 activates its supply mode.
        // Physical stock and transfer provenance still come from the real report/approval path.
        db.update("UPDATE production_execution_segments SET start_route='CONTINUOUS',continuous_supply=TRUE,route_confirmed_at=now() WHERE id=?",c.segment());
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
        var reconciler=beans.getBean(com.uten.imp.features.production.fulfillment.ProductionReadinessReconciler.class);
        for(int attempt=0;attempt<4 && !"READY".equals(status(c.segment()));attempt++)reconciler.runBatch();
        assertEquals("READY",status(c.segment()));
        qty("0",capacity(c));
        assertEquals(Boolean.TRUE,db.queryForObject("SELECT fn_execution_start_material_ready(?)",Boolean.class,c.segment()));
        fixture.loginAs(c.world().superAdminUserId());
        assertTrue(segments.list(c.plan()).stream().filter(task->task.id().equals(c.segment())).findFirst().orElseThrow().canStart());
        start(c);
        qty("20",capacity(c));
    }

    private void confirm(Case c,String route) {
        fixture.loginAs(c.workerUser());
        segments.confirmRoute(c.plan(),c.segment(),new SegmentRouteConfirmRequest(version(c.segment()),
                "rg-confirm-"+route+"-"+c.segment(),route));
    }

    @Test
    void preparedLegacyRouteChangesPreserveReservationAndDrawIdentity() {
        Case c=create("adv-preserve",false);
        confirm(c,"FULL_KIT");
        receive(c,c.material(),c.leaf(),"100");
        var reservations=db.queryForList("SELECT id FROM stock_reservations WHERE demand_id=? ORDER BY id",UUID.class,parentDemand(c));
        var draws=db.queryForList("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW' ORDER BY document_id",UUID.class,c.segment());
        confirm(c,"CONTINUOUS");
        assertEquals(reservations,db.queryForList("SELECT id FROM stock_reservations WHERE demand_id=? ORDER BY id",UUID.class,parentDemand(c)));
        assertEquals(draws,db.queryForList("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW' ORDER BY document_id",UUID.class,c.segment()));
        qty("100",db.queryForObject("SELECT SUM(qty-released_qty) FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",BigDecimal.class,parentDemand(c)));
        assertEquals(1,drawCount(c.segment()));
        issueDraws(c); start(c);
    }

    @Test
    void routeHashAndVersionRejectChangedCommandsWithoutSideEffects() {
        Case c=create("adv-idem",false);
        long original=version(c.segment());
        var command=new SegmentRouteConfirmRequest(original,"adv-route-idempotency","CONTINUOUS");
        segments.confirmRoute(c.plan(),c.segment(),command);
        long changed=version(c.segment());
        assertThrows(ApiException.class,()->segments.confirmRoute(c.plan(),c.segment(),
                new SegmentRouteConfirmRequest(original,command.idempotencyKey(),"FULL_KIT")));
        assertThrows(ApiException.class,()->segments.confirmRoute(c.plan(),c.segment(),
                new SegmentRouteConfirmRequest(original,"adv-stale-version","FULL_KIT")));
        segments.confirmRoute(c.plan(),c.segment(),command);
        assertEquals(changed,version(c.segment()));
        assertEquals("CONTINUOUS",route(c.segment()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='ROUTE_CONFIRMED'",Integer.class,c.segment()));
        receive(c,c.material(),c.leaf(),"10");
        fixture.loginAs(c.workerUser());
        assertThrows(ApiException.class,()->segments.confirmRoute(c.plan(),c.segment(),
                new SegmentRouteConfirmRequest(version(c.segment()),"adv-incomplete-to-kit","FULL_KIT")));
        assertEquals("CONTINUOUS",route(c.segment()));
        qty("10",db.queryForObject("SELECT SUM(qty-released_qty) FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",BigDecimal.class,parentDemand(c)));
    }

    @Test
    void knownForeignUuidAndInactiveResponsibleCannotConfirmOrPick() {
        Case c=create("adv-scope",false);
        fixture.loginAs(c.world().superAdminUserId());
        UUID outsider=fixture.createUserWithPerms(c.world(),"adv-other-workshop","production_execution:view","production_execution:start");
        fixture.loginAs(outsider);
        assertThrows(ApiException.class,()->segments.confirmRoute(c.plan(),c.segment(),
                new SegmentRouteConfirmRequest(version(c.segment()),"adv-foreign-route","CONTINUOUS")));
        assertNull(route(c.segment()));
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10");
        fixture.loginAs(outsider);
        assertThrows(ApiException.class,()->drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(
                List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment()))))));
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,c.workerUser());
        db.update("UPDATE production_execution_segments SET responsible_employee_id=? WHERE id=?",employee,c.segment());
        db.update("UPDATE employees SET status='resigned' WHERE id=?",employee);
        fixture.loginAs(c.workerUser());
        assertThrows(ApiException.class,()->segments.confirmRoute(c.plan(),c.segment(),
                new SegmentRouteConfirmRequest(version(c.segment()),"adv-inactive-owner","CONTINUOUS")));
        assertEquals(0,beans.getBean(com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService.class)
                .workshopTasks(1,50,null,null,c.workshop(),null,null).getTotal());
    }

    @Test
    void suspendedPlanAndUnassignedTaskCannotUnlockUnusableRoute() {
        Case c=create("adv-stopped",false);
        fixture.loginAs(c.world().superAdminUserId());
        segments.assign(c.plan(),c.segment(),new com.uten.imp.features.production.execution.SegmentAssignmentRequest(
                version(c.segment()),"adv-clear-assignment",null,null,null,null,null));
        assertThrows(ApiException.class,()->segments.confirmRoute(c.plan(),c.segment(),
                new SegmentRouteConfirmRequest(version(c.segment()),"adv-defer-batch","BATCH")));
        assertNull(route(c.segment()));
        segments.assign(c.plan(),c.segment(),new com.uten.imp.features.production.execution.SegmentAssignmentRequest(
                version(c.segment()),"adv-restore-assignment",c.workshop(),null,c.worker(),BusinessTime.today(),BusinessTime.today().plusDays(10)));
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10");
        fixture.loginAs(c.workerUser());
        var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        db.update("UPDATE production_plans SET is_stopped=TRUE WHERE id=?",c.plan());
        long unchanged=version(c.segment());
        assertThrows(ApiException.class,()->drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(items,"adv-stopped-pick",preview.fingerprint())));
        assertThrows(ApiException.class,()->segments.start(c.plan(),c.segment(),new SegmentTransitionRequest(unchanged,"adv-stopped-start")));
        assertThrows(ApiException.class,()->segments.confirmRoute(c.plan(),c.segment(),new SegmentRouteConfirmRequest(unchanged,"adv-stopped-route","CONTINUOUS")));
        assertEquals(unchanged,version(c.segment()));
        qty("0",capacity(c));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='DRAW_REQUEST'",Integer.class,c.segment()));
        beans.getBean(com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService.class)
                .workshopTasks(1,50,null,null,c.workshop(),null,null).getItems().stream()
                .filter(task->task.segmentId().equals(c.segment())).findFirst().ifPresent(task->{
                    assertFalse(task.canStart(),"暂停计划不可给开工入口");
                    assertFalse(task.canRequestDraw(),"暂停计划不可给领料入口");
                    assertFalse(task.routeChangeable(),"暂停计划不可给路线调整入口");
                });
    }

    @Test
    void concurrentIdenticalPickAndStartEachCommitOnlyOneSemanticEvent() throws Exception {
        Case c=create("adv-concurrent",false);
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10");
        fixture.loginAs(c.workerUser());
        var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        var request=new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(items,"adv-concurrent-pick",preview.fingerprint());
        concurrently(c.workerUser(),()->drawRequests.submit(request),()->drawRequests.submit(request));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='DRAW_REQUEST'",Integer.class,c.segment()));
        issueRequestedDraws(c);
        long prepared=version(c.segment());
        var start=new SegmentTransitionRequest(prepared,"adv-concurrent-start");
        concurrently(c.workerUser(),()->segments.start(c.plan(),c.segment(),start),()->segments.start(c.plan(),c.segment(),start));
        assertEquals("IN_PROGRESS",status(c.segment()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='START'",Integer.class,c.segment()));
        assertEquals(prepared+1,version(c.segment()));
        qty("10",capacity(c));
    }

    private void concurrently(UUID actor,java.util.concurrent.Callable<?> first,java.util.concurrent.Callable<?> second) throws Exception {
        try(var pool=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var barrier=new java.util.concurrent.CyclicBarrier(2);
            var results=List.of(first,second).stream().map(work->pool.submit(()->{
                fixture.loginAs(actor);
                try { barrier.await(10,java.util.concurrent.TimeUnit.SECONDS); return work.call(); }
                finally { org.springframework.security.core.context.SecurityContextHolder.clearContext(); }
            })).toList();
            for(var result:results) result.get(40,java.util.concurrent.TimeUnit.SECONDS);
        }
    }

    @Test
    void dispatchedAssignmentMustStillBeValidWhenWorkActuallyStarts() {
        Case c=create("adv-dispatched",false);
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c);
        fixture.loginAs(c.world().superAdminUserId());
        segments.dispatch(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-dispatch-first"));
        assertEquals("DISPATCHED",status(c.segment()));
        db.update("UPDATE employees SET status='resigned' WHERE id=?",c.worker());
        fixture.loginAs(c.workerUser());
        long unchanged=version(c.segment());
        assertThrows(ApiException.class,()->segments.start(c.plan(),c.segment(),new SegmentTransitionRequest(unchanged,"adv-inactive-start")),
                "派工后的负责人离职必须在实际开工时重新验证，不可沿用派工时的有效性");
        assertEquals("DISPATCHED",status(c.segment()));
        assertEquals(unchanged,version(c.segment()));
    }

    @Test
    void inactivePlanMakerCannotRegainWorkshopWriteAccessThroughOwnerFallback() {
        Case c=create("adv-maker",false);
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,c.workerUser());
        db.update("UPDATE production_plans SET maker_id=? WHERE id=?",employee,c.plan());
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10");
        fixture.loginAs(c.workerUser());
        var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        db.update("UPDATE employees SET status='resigned' WHERE id=?",employee);
        fixture.loginAs(c.workerUser());
        long unchanged=version(c.segment());
        assertFalse(segments.list(c.plan()).stream().filter(task->task.id().equals(c.segment()))
                .findFirst().orElseThrow().canRequestDraw(),"历史归属可读不代表离职员工可以继续领料");
        assertThrows(ApiException.class,()->segments.confirmRoute(c.plan(),c.segment(),
                new SegmentRouteConfirmRequest(unchanged,"adv-inactive-maker-route","CONTINUOUS")));
        assertThrows(ApiException.class,()->drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(
                items,"adv-inactive-maker-pick",preview.fingerprint())));
        assertEquals(unchanged,version(c.segment()));
    }

    @Test
    void activePlanMakerRetainsExplicitManagementAuthorityOutsideWorkshopMembership() {
        Case c=create("adv-active-maker",false);
        fixture.loginAs(c.world().superAdminUserId());
        UUID manager=fixture.createUserWithPerms(c.world(),"adv-active-planner","production_execution:view","production_execution:start");
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,manager);
        db.update("UPDATE production_plans SET maker_id=? WHERE id=?",employee,c.plan());
        fixture.loginAs(manager);
        segments.confirmRoute(c.plan(),c.segment(),new SegmentRouteConfirmRequest(version(c.segment()),"adv-plan-owner-route","CONTINUOUS"));
        assertEquals("CONTINUOUS",route(c.segment()));
        receive(c,c.material(),c.leaf(),"10");
        fixture.loginAs(manager);
        var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        assertEquals(1,drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(
                items,"adv-plan-owner-pick",preview.fingerprint())).taskCount());
    }

    @Test
    void workshopMemberWithoutStartPermissionDoesNotReceiveMaterialMutationCapabilities() {
        Case c=create("adv-view-only",false);
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10");
        fixture.loginAs(c.world().superAdminUserId());
        UUID viewer=fixture.createUserWithPerms(c.world(),"adv-workshop-viewer","production_execution:view");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",c.workshop(),viewer);
        db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions WHERE code='production_execution:start'",viewer);
        fixture.loginAs(viewer);
        assertFalse(beans.getBean(com.uten.imp.features.production.ProductionDocumentAccessPolicy.class).hasAuthority("production_execution:start"));
        var task=beans.getBean(com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService.class)
                .workshopTasks(1,50,null,null,c.workshop(),null,null).getItems().stream()
                .filter(row->row.segmentId().equals(c.segment())).findFirst().orElseThrow();
        assertFalse(task.canRecheckMaterial());
        assertFalse(task.canRequestDraw());
        assertFalse(task.canStart());
        assertFalse(task.canConfirmRoute());
        assertFalse(task.routeChangeable());
    }

    @Test
    void planMakerWithoutStartPermissionCannotInvokeExecutionCommandsThroughTheService() {
        Case c=create("adv-service-auth",false);
        confirm(c,"CONTINUOUS");
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,c.workerUser());
        db.update("UPDATE production_plans SET maker_id=? WHERE id=?",employee,c.plan());
        db.update("UPDATE user_permission_overrides override SET effect='revoke' FROM permissions permission WHERE override.permission_id=permission.id AND permission.code='production_execution:start' AND override.user_id=?",c.workerUser());
        fixture.loginAs(c.workerUser());
        var policy=beans.getBean(com.uten.imp.features.production.ProductionDocumentAccessPolicy.class);
        assertTrue(policy.hasAuthority("production_execution:view"));
        assertFalse(policy.hasAuthority("production_execution:start"));
        long unchanged=version(c.segment());
        List<Runnable> commands=List.of(
                ()->segments.confirmRoute(c.plan(),c.segment(),new SegmentRouteConfirmRequest(unchanged,"adv-no-action-route","CONTINUOUS")),
                ()->segments.recheckMaterial(c.plan(),c.segment(),new SegmentTransitionRequest(unchanged,"adv-no-action-recheck")),
                ()->segments.start(c.plan(),c.segment(),new SegmentTransitionRequest(unchanged,"adv-no-action-start")),
                ()->segments.batchStart(c.plan(),new com.uten.imp.features.production.execution.BatchStartRequest(List.of(
                        new com.uten.imp.features.production.execution.BatchStartRequest.Item(c.segment(),unchanged,"adv-no-action-batch")))));
        for(Runnable command:commands) {
            assertEquals(com.uten.imp.common.web.ErrorCode.FORBIDDEN,assertThrows(ApiException.class,command::run).getCode());
        }
        assertEquals(unchanged,version(c.segment()));
        assertEquals("WAITING",status(c.segment()));
    }

    @Test
    void workshopReassignmentRequiresPhysicalCustodyToBeReversedFirst() {
        Case c=create("adv-move-issued",false);
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c);
        var target=otherWorkshopAssignment(c,"adv-move-issued");
        assertThrows(ApiException.class,()->segments.assign(c.plan(),c.segment(),target),
                "未开工不代表物料仍在仓库，已有实领不能将旧车间的持料随任务改到另一车间");
        assertEquals(c.workshop(),db.queryForObject("SELECT workshop_department_id FROM production_execution_segments WHERE id=?",UUID.class,c.segment()));
        qty("10",capacity(c));
        UUID nextOwner=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,c.workerUser());
        var reassigned=segments.assign(c.plan(),c.segment(),new com.uten.imp.features.production.execution.SegmentAssignmentRequest(
                version(c.segment()),"adv-same-workshop-owner",c.workshop(),null,nextOwner,BusinessTime.today(),BusinessTime.today().plusDays(10)));
        assertEquals(nextOwner,reassigned.responsibleEmployeeId());
    }

    @Test
    void directReceiptBeforeRouteConfirmationAlsoFreezesWorkshopCustody() {
        Case c=create("adv-move-direct",true);
        transfer(c,"20");
        assertNull(route(c.segment()));
        var target=otherWorkshopAssignment(c,"adv-move-direct");
        assertThrows(ApiException.class,()->segments.assign(c.plan(),c.segment(),target),
                "路线确认前已经实际收到的直送料也属于原车间");
        assertEquals(c.workshop(),db.queryForObject("SELECT workshop_department_id FROM production_execution_segments WHERE id=?",UUID.class,c.segment()));
    }

    @Test
    void untouchedTaskCanStillMoveToAnotherValidWorkshop() {
        Case c=create("adv-move-unused",false);
        var target=otherWorkshopAssignment(c,"adv-move-unused");
        segments.assign(c.plan(),c.segment(),target);
        assertEquals(target.workshopDepartmentId(),db.queryForObject("SELECT workshop_department_id FROM production_execution_segments WHERE id=?",UUID.class,c.segment()));
    }

    @Test
    void fixedBatchSharedMaterialsCannotBeSeparatedIntoDifferentWorkshopsBeforeIssue() {
        Case c=create("adv-fixed-share",false);
        confirm(c,"BATCH"); receive(c,c.material(),c.leaf(),"4");
        fixture.loginAs(c.workerUser());
        var preview=batches.preview(new ProductionExecutionBatch.PreviewRequest(c.segment(),version(c.segment()),new BigDecimal("5")));
        var split=batches.submit(new ProductionExecutionBatch.SubmitRequest(c.segment(),preview.expectedVersion(),
                preview.quantity(),preview.fingerprint(),"adv-fixed-shared-split"));
        assertTrue(Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM production_execution_segments s CROSS JOIN LATERAL jsonb_array_elements(s.split_material_snapshot) r WHERE s.id=? AND (r->>'requiresPrior')::boolean)",Boolean.class,split.remainingSegmentId())));
        var destination=otherWorkshopAssignment(c,"adv-shared-workshop");
        for(UUID member:List.of(split.batchSegmentId(),split.remainingSegmentId())) {
            var request=new com.uten.imp.features.production.execution.SegmentAssignmentRequest(version(member),
                    "adv-shared-move-"+member,destination.workshopDepartmentId(),null,destination.responsibleEmployeeId(),
                    BusinessTime.today(),BusinessTime.today().plusDays(10));
            assertThrows(ApiException.class,()->segments.assign(c.plan(),member,request),
                    "共用物料的前后批在实领前也不能分开改到其他车间");
        }
    }

    @Test
    void unissuedDraftAndExistingDrawRequestFollowReassignmentWithoutChangingMaterialHistory() {
        for(boolean requested:List.of(false,true)) {
            Case c=create(requested?"adv-pending-request":"adv-pending-draft",false);
            confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10");
            fixture.loginAs(c.workerUser());
            var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
            var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
            UUID document=preview.lines().getFirst().drawId(),line=preview.lines().getFirst().drawItemId();
            if(requested) drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(
                    items,"adv-original-pick-"+c.segment(),preview.fingerprint()));
            var before=db.queryForList("SELECT id,request_hash,draw_item_quantities::text FROM production_execution_segment_events WHERE execution_segment_id=? AND action='DRAW_REQUEST'",c.segment());
            var target=otherWorkshopAssignment(c,requested?"adv-request-destination":"adv-draft-destination");
            segments.assign(c.plan(),c.segment(),target);
            assertEquals(target.workshopDepartmentId(),db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,document));
            assertEquals(target.responsibleEmployeeId(),db.queryForObject("SELECT worker_id FROM stock_documents WHERE id=?",UUID.class,document));
            assertEquals(before,db.queryForList("SELECT id,request_hash,draw_item_quantities::text FROM production_execution_segment_events WHERE execution_segment_id=? AND action='DRAW_REQUEST'",c.segment()));
            qty("10",db.queryForObject("SELECT qty FROM stock_document_items WHERE id=? AND doc_id=?",BigDecimal.class,line,document));
            assertThrows(org.springframework.dao.DataIntegrityViolationException.class,()->db.update(
                    "UPDATE stock_documents SET department_id=? WHERE id=?",c.workshop(),document),
                    "已提交的改派事件不能给后续任意SQL修改领料身份授权");
            if(!requested) {
                var updatedItems=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
                var updated=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(updatedItems));
                drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(updatedItems,
                        "adv-moved-pick-"+c.segment(),updated.fingerprint()));
            }
            issueRequestedDraws(c);
            qty("10",capacity(c));
            assertEquals(target.workshopDepartmentId(),db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,document));
        }
    }

    @Test
    void warehouseIssueAndReassignmentSerializeDeliveryCustody() throws Exception {
        Case c=create("adv-assign-race",false);
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10");
        fixture.loginAs(c.workerUser());
        var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(items,"adv-assignment-race-pick",preview.fingerprint()));
        var target=otherWorkshopAssignment(c,"adv-assignment-race-target");
        concurrently(c.world().superAdminUserId(),()->{
            try { issueRequestedDraws(c); }
            catch(ApiException concurrentChange) { assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,concurrentChange.getCode()); }
            return null;
        },()->{
            try { segments.assign(c.plan(),c.segment(),target); }
            catch(ApiException concurrentChange) { assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,concurrentChange.getCode()); }
            return null;
        });
        // Either command may reject its stale footprint. A warehouse refresh must
        // then issue once to the committed assignment, never to an old recipient.
        assertTrue(capacity(c).signum()==0 || capacity(c).compareTo(new BigDecimal("10"))==0);
        if(capacity(c).signum()==0) issueRequestedDraws(c);
        qty("10",capacity(c));
        UUID actualWorkshop=db.queryForObject("SELECT workshop_department_id FROM production_execution_segments WHERE id=?",UUID.class,c.segment());
        assertTrue(List.of(c.workshop(),target.workshopDepartmentId()).contains(actualWorkshop));
        assertEquals(actualWorkshop,db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,preview.lines().getFirst().drawId()));
        qty("10",db.queryForObject("SELECT SUM(qty_base) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",BigDecimal.class,parentDemand(c)));
    }

    @Test
    void finalTargetProvenanceRejectsForgedSqlAndSurvivesReverseThenNewFinal() {
        Case c=create("adv-cap-proof",false,"10");
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"4"); issueDraws(c); start(c);
        fixture.loginAs(c.world().superAdminUserId());
        var request=adversarialFinalReport(c);
        UUID report=reports().create(request).getId();
        var transactions=new org.springframework.transaction.support.TransactionTemplate(
                beans.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        assertTrue(assertSqlIntegrity(()->transactions.executeWithoutResult(ignored->{
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
            db.queryForObject("SELECT set_config('app.cap_segment_allocations','on',true)",String.class);
            db.queryForObject("SELECT set_config('app.cap_segment_report_id',?,true)",String.class,report.toString());
            db.update("UPDATE production_plan_items SET qty=4,capped_qty=6 WHERE id=?",c.planItem());
        }),"55000").contains("material-analysis plan item identity and quantity are immutable"));
        assertTrue(assertSqlIntegrity(()->transactions.executeWithoutResult(ignored->{
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
            db.update("INSERT INTO production_daily_report_target_events(report_id,plan_item_id,event_type,before_qty,after_qty,created_by) VALUES(?,?,'CAP',10,3,?)",
                    report,c.planItem(),c.world().superAdminUserId());
        })).contains("physically reported"));
        assertTrue(assertSqlIntegrity(()->transactions.executeWithoutResult(ignored->{
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
            db.update("INSERT INTO production_daily_report_target_events(report_id,plan_item_id,event_type,before_qty,after_qty,created_by) VALUES(?,?,'CAP',10,4,?)",
                    report,c.planItem(),c.world().superAdminUserId());
        })).contains("commit together"));
        qty("10",db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE plan_item_id=?",Integer.class,c.planItem()));
        reports().approve(report);
        assertEquals(report,reports().create(request).getId(),"已审核final的相同创建请求只能重放原单");
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE report_id=?",Integer.class,report));
        reports().reverse(report);
        assertThrows(ApiException.class,()->reports().reverse(report));
        qty("10",db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        UUID replacement=reports().approve(reports().create(adversarialFinalReport(c)).getId()).getId();
        assertNotEquals(report,replacement);
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE report_id=?",Integer.class,report));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE report_id=?",Integer.class,replacement));
        qty("4",db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("6",db.queryForObject("SELECT released_qty FROM production_material_demands WHERE id=?",BigDecimal.class,parentDemand(c)));
    }

    @Test
    void assignmentEventsRemainAppendOnlyEvenWhenValuesDoNotChange() {
        Case c=create("adv-immutable-assignment",false);
        segments.assign(c.plan(),c.segment(),otherWorkshopAssignment(c,"adv-event-assignment"));
        UUID event=db.queryForObject("SELECT id FROM production_execution_segment_events WHERE execution_segment_id=? AND action='ASSIGNMENT'",UUID.class,c.segment());
        String hash=db.queryForObject("SELECT request_hash FROM production_execution_segment_events WHERE id=?",String.class,event);
        for(String attack:List.of("UPDATE production_execution_segment_events SET resulting_version=resulting_version WHERE id=?",
                "DELETE FROM production_execution_segment_events WHERE id=?")) {
            var failure=assertThrows(org.springframework.dao.DataAccessException.class,()->db.update(attack,event));
            assertEquals("55000",assertInstanceOf(java.sql.SQLException.class,failure.getMostSpecificCause()).getSQLState());
        }
        assertEquals(hash,db.queryForObject("SELECT request_hash FROM production_execution_segment_events WHERE id=?",String.class,event));
    }

    @Test
    void reversedIssueDoesNotMakeAnActiveHistoricalDrawSafeForAnotherWorkshop() {
        Case c=create("adv-reversed-custody",false);
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c);
        var item=db.queryForMap("SELECT item.id,item.doc_id FROM stock_document_items item JOIN production_planning_package_documents mapping ON mapping.document_id=item.doc_id WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW'",c.segment());
        var line=new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line(); line.setItemId((UUID)item.get("id")); line.setQty(new BigDecimal("10"));
        var reverse=new com.uten.imp.features.stock.dto.StockDocIssueRequest(); reverse.setIdempotencyKey("adv-reversed-history"); reverse.setReason("实物未投入，撤回原领料出库"); reverse.setLines(List.of(line));
        stock.reverseIssue((UUID)item.get("doc_id"),reverse);
        qty("0",capacity(c));
        var target=otherWorkshopAssignment(c,"adv-reversed-destination");
        assertThrows(ApiException.class,()->segments.assign(c.plan(),c.segment(),target));
        assertEquals(c.workshop(),db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,item.get("doc_id")));
        var reissue=new com.uten.imp.features.stock.dto.StockDocIssueRequest(); reissue.setIdempotencyKey("adv-reissue-same-workshop"); reissue.setLines(List.of(line));
        stock.approveAndIssue((UUID)item.get("doc_id"),reissue);
        qty("10",capacity(c)); start(c);
    }

    @Test
    void explicitSameAssignmentRepairsLegacyUnissuedRecipientAndPreservesActualLeafWarehouse() {
        Case c=create("adv-legacy-unissued",false);
        receive(c,c.material(),c.leaf(),"10");
        var historical=otherWorkshopAssignment(c,"adv-legacy-receiver");
        UUID document=legacyPendingDraw(c,historical,true);
        assertEquals(historical.workshopDepartmentId(),db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,document));
        segments.assign(c.plan(),c.segment(),new com.uten.imp.features.production.execution.SegmentAssignmentRequest(
                version(c.segment()),"adv-legacy-explicit-save",c.workshop(),null,c.worker(),BusinessTime.today(),BusinessTime.today().plusDays(10)));
        assertEquals(c.workshop(),db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,document));
        assertEquals(c.leaf(),db.queryForObject("SELECT warehouse_id FROM stock_documents WHERE id=?",UUID.class,document));
        issueDraws(c);
        assertTrue(custodyValid(c),"同主仓的实际叶仓不等于生产车间，正常领料不可被误拦");
        start(c);
    }

    @Test
    void historicalWrongWorkshopIssueCannotStartAndIssuedHistoryIsNotRewritten() {
        Case c=create("adv-legacy-start",false);
        receive(c,c.material(),c.leaf(),"10");
        var historical=otherWorkshopAssignment(c,"adv-legacy-physical");
        UUID document=legacyPendingDraw(c,historical,true);
        issueDraws(c);
        assertFalse(custodyValid(c));
        qty("0",capacity(c));
        assertTrue(assertThrows(ApiException.class,()->start(c)).getMessage().contains("原车间"));
        fixture.loginAs(c.world().superAdminUserId());
        assertFalse(segments.list(c.plan()).stream().filter(row->row.id().equals(c.segment())).findFirst().orElseThrow().canStart());
        assertEquals(historical.workshopDepartmentId(),db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,document));
    }

    @Test
    void historicalWrongWorkshopIssueBlocksReportingButRealSourceReturnRestoresIt() {
        Case c=create("adv-legacy-report",false);
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c); start(c);
        var historical=otherWorkshopAssignment(c,"adv-legacy-late");
        UUID wrongDraw=legacyPendingDraw(c,historical,false);
        receive(c,c.material(),c.leaf(),"5"); issueDraws(c);
        assertFalse(custodyValid(c));
        fixture.loginAs(c.world().superAdminUserId());
        var task=beans.getBean(com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService.class)
                .workshopTasks(1,50,null,null,c.workshop(),null,null).getItems().stream()
                .filter(row->row.segmentId().equals(c.segment())).findFirst().orElseThrow();
        assertFalse(task.canReport()); assertTrue(task.blockedReason().contains("车间不一致"));
        var report=adversarialFinalReport(c); report.getItems().getFirst().setIsFinal(false); report.getItems().getFirst().setQty(BigDecimal.ONE);
        assertTrue(assertThrows(ApiException.class,()->reports().create(report)).getMessage().contains("车间"));
        assertTrue(beans.getBean(com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService.class)
                .list(1,50,null,c.workshop(),List.of(c.segment())).getItems().isEmpty());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).stream().filter(row->row.drawId().equals(wrongDraw)).findFirst().orElseThrow();
        var pending=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-legacy-source-return","按原始领料来源退回错误车间的五件",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("5"))))).getFirst();
        assertFalse(custodyValid(c),"待退申请不等于实物已经回仓");
        stock.approve(pending.documentId());
        assertTrue(custodyValid(c)); qty("10",capacity(c));
        assertEquals(historical.workshopDepartmentId(),db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,wrongDraw));
        reports().approve(reports().create(report).getId());
    }

    @Test
    void realSurplusCanReturnBeforeStartWithNoFakeStartEvent() {
        for(String stage:List.of("READY","DISPATCHED")) {
            Case c=create("adv-return-"+stage.toLowerCase(),false,"10");
            confirm(c,"FULL_KIT"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c);
            if("DISPATCHED".equals(stage)) segments.dispatch(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-return-dispatched"));
            fixture.loginAs(c.workerUser());
            assertTrue(beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService.class)
                    .capabilities(c.plan(),c.segment()).canRequestReturn());
            var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
            var source=returns.sources(c.plan(),c.segment()).getFirst();
            assertNull(source.returnBlockedReason()); qty("10",source.availableQty());
            var pending=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                    c.segment(),"adv-return-before-start-"+stage,"已实际领取但尚未投入，三件按原来源真实退仓",
                    List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("3"))))).getFirst();
            fixture.loginAs(c.world().superAdminUserId()); stock.approve(pending.documentId());
            assertEquals(stage,status(c.segment()));
            assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='START'",Integer.class,c.segment()));
            qty("7",capacity(c)); qty("3",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.leaf(),c.material()));
            assertEquals(c.workshop(),db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,pending.documentId()));
            fixture.loginAs(c.workerUser());
            segments.recheckMaterial(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-before-start-repick"));
            issueDraws(c); qty("10",capacity(c)); start(c);
            assertEquals("IN_PROGRESS",status(c.segment()));
        }
    }

    @Test
    void materialActionsUseActiveActorBeforePlanOwnerFallback() {
        Case c=create("adv-material-maker",false,"10");
        confirm(c,"FULL_KIT"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c); start(c);
        fixture.loginAs(c.world().superAdminUserId());
        UUID manager=fixture.createUserWithPerms(c.world(),"adv-material-owner",
                "production_plan:view","production_execution:view","production_material:settle");
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,manager);
        db.update("UPDATE production_plans SET maker_id=? WHERE id=?",employee,c.plan());
        fixture.loginAs(manager);
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var settlements=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService.class);
        var source=returns.sources(c.plan(),c.segment()).getFirst();
        assertTrue(settlements.capabilities(c.plan(),c.segment()).canRequestReturn());
        var pending=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-owner-return-active","在职计划负责人办理原来源退料",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),BigDecimal.ONE)))).getFirst();
        returns.cancel(c.plan(),pending.documentId(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Cancel(
                "adv-owner-cancel-active","本次实物尚未交接，取消原退料申请"));
        var request=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        request.setExecutionSegmentId(c.segment()); request.setIdempotencyKey("adv-owner-use-active"); request.setReason("在职负责人登记实际投入一件");
        var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
        line.setDemandId(parentDemand(c)); line.setSettlementType("CONSUMED"); line.setQtyBase(BigDecimal.ONE); request.setLines(List.of(line));
        settlements.post(c.plan(),request,manager);
        db.update("UPDATE employees SET status='resigned' WHERE id=?",employee);
        fixture.loginAs(manager);
        var capabilities=settlements.capabilities(c.plan(),c.segment());
        assertFalse(capabilities.canRequestReturn()); assertFalse(capabilities.canSettle());
        assertFalse(returns.sources(c.plan(),c.segment()).isEmpty(),"历史负责人仍可按原只读范围核对历史");
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,()->returns.submit(c.plan(),
                new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(c.segment(),"adv-owner-return-inactive","离职负责人不能再写材料",
                        List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),BigDecimal.ONE))))).getCode());
        request.setIdempotencyKey("adv-owner-use-inactive");
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,()->settlements.post(c.plan(),request,manager)).getCode());
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_material_return_requests WHERE execution_segment_id=?",Integer.class,c.segment()));
    }

    @Test
    void returnsAutomaticallySeparateOriginalDepartmentsInOneWarehouse() {
        Case c=create("adv-return-departments",false,"20");
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c); start(c);
        var historical=otherWorkshopAssignment(c,"adv-return-origin");
        legacyPendingDraw(c,historical,false); receive(c,c.material(),c.leaf(),"5"); issueDraws(c);
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var sources=returns.sources(c.plan(),c.segment());
        assertEquals(2,sources.size());
        var request=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(c.segment(),
                "adv-return-two-origins","按两个真实原领料部门分别退回同一仓库",
                sources.stream().map(source->new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),BigDecimal.ONE)).toList());
        var documents=returns.submit(c.plan(),request);
        assertEquals(2,documents.size());
        assertEquals(documents.stream().map(row->row.documentId()).sorted().toList(),returns.submit(c.plan(),request).stream().map(row->row.documentId()).sorted().toList());
        var departments=new java.util.HashSet<UUID>();
        fixture.loginAs(c.world().superAdminUserId());
        for(var returned:documents) {
            departments.add(db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,returned.documentId()));
            stock.approve(returned.documentId());
            assertEquals(c.leaf(),returned.warehouseId());
        }
        assertEquals(java.util.Set.of(c.workshop(),historical.workshopDepartmentId()),departments);
        qty("2",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.leaf(),c.material()));
    }

    @Test
    void returnedMaterialCanBePickedAgainOnTheSameTaskWithoutReversingReturn() {
        for(String route:List.of("FULL_KIT","CONTINUOUS")) {
        Case c=create("adv-repick-"+route.toLowerCase(),false,"10");
        confirm(c,route); receive(c,c.material(),c.leaf(),"10"); issueDraws(c); start(c);
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).getFirst();
        var returned=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-repick-real-return","三件已真实退到仓库，之后需要重新领取",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("3"))))).getFirst();
        fixture.loginAs(c.world().superAdminUserId()); stock.approve(returned.documentId());
        qty("7",capacity(c));
        fixture.loginAs(c.workerUser());
        var recheck=new SegmentTransitionRequest(version(c.segment()),"adv-repick-explicit-prepare");
        segments.recheckMaterial(c.plan(),c.segment(),recheck);
        segments.recheckMaterial(c.plan(),c.segment(),recheck);
        segments.recheckMaterial(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-repick-repeat-prepare"));
        var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        qty("3",preview.lines().stream().map(row->row.qty()).reduce(BigDecimal.ZERO,BigDecimal::add));
        qty("10",db.queryForObject("SELECT fn_execution_demand_draw_commitment_qty(?)",BigDecimal.class,parentDemand(c)));
        var task=beans.getBean(com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService.class)
                .workshopTasks(1,50,null,null,c.workshop(),null,null).getItems().stream().filter(row->row.segmentId().equals(c.segment())).findFirst().orElseThrow();
        assertTrue(task.canRequestDraw(),"已有真实退回的齐套或持续任务均可再领料");
        drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(items,"adv-repick-new-issue",preview.fingerprint()));
        issueRequestedDraws(c); qty("10",capacity(c));
        qty("3",db.queryForObject("SELECT SUM(qty_base) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='GOOD_RETURN'",BigDecimal.class,parentDemand(c)));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='GOOD_RETURN_REVERSE'",Integer.class,parentDemand(c)));
        qty("13",db.queryForObject("SELECT SUM(qty_base) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",BigDecimal.class,parentDemand(c)));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",Integer.class,parentDemand(c)));
        qty("10",db.queryForObject("SELECT SUM(qty) FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",BigDecimal.class,parentDemand(c)));
        }
    }

    @Test
    void warehouseConfirmsARealOrdinaryDestinationWithReplayAndScopeGuards() {
        Case c=create("adv-return-destination",false,"10");
        confirm(c,"FULL_KIT"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c);
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).getFirst();
        var request=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-receive-normal-request","由仓库选择实际接收本车间余料的正常仓",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("3"))))).getFirst();
        UUID received=ordinarySibling(c,"adv-return-received");
        fixture.loginAs(c.world().superAdminUserId());
        UUID outsider=fixture.createUserWithPerms(c.world(),"adv-return-outside-warehouse","stock_doc:view","stock_doc:approve");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",c.workshop(),outsider);
        fixture.loginAs(outsider);
        var command=new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(received,"adv-normal-receive-command");
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,()->stock.confirmProductionMaterialReturn(request.documentId(),command)).getCode());
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_material_return_receiving_confirmations WHERE stock_document_id=?",Integer.class,request.documentId()));
        fixture.loginAs(c.world().superAdminUserId());
        assertThrows(ApiException.class,()->stock.confirmProductionMaterialReturn(request.documentId(),
                new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(c.world().warehouseId(),"adv-normal-parent-reject")));
        var detail=stock.confirmProductionMaterialReturn(request.documentId(),command);
        assertTrue(detail.isProductionMaterialReturn()); assertEquals(c.leaf(),detail.getMaterialReturnSourceWarehouseId());
        assertEquals(c.world().warehouseId(),detail.getMaterialReturnMainWarehouseId()); assertEquals(received,detail.getWarehouseId());
        assertEquals(request.documentId(),stock.confirmProductionMaterialReturn(request.documentId(),command).getId());
        assertThrows(ApiException.class,()->stock.confirmProductionMaterialReturn(request.documentId(),
                new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(c.leaf(),command.idempotencyKey())));
        qty("3",physical(received,c.material())); qty("0",physical(c.leaf(),c.material()));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_material_return_receiving_confirmations WHERE stock_document_id=?",Integer.class,request.documentId()));
        var immutable=assertThrows(org.springframework.dao.DataAccessException.class,()->db.update(
                "UPDATE production_material_return_receiving_confirmations SET received_warehouse_id=received_warehouse_id WHERE stock_document_id=?",request.documentId()));
        assertEquals("55000",assertInstanceOf(java.sql.SQLException.class,immutable.getMostSpecificCause()).getSQLState());
        fixture.loginAs(c.workerUser());
        segments.recheckMaterial(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-new-location-repick"));
        issueDraws(c); qty("10",capacity(c)); start(c);
    }

    @Test
    void unissuedDirectMaterialCanGoToNormalStockBeforeAnyRouteOrIssue() {
        Case c=create("adv-free-direct-return",true,"10"); transfer(c,"10");
        assertThrows(ApiException.class,()->confirm(c,"BATCH"),"已有真实直送料不能再进入未使用任务的独立拆批路线");
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).stream().filter(row->"DIRECT_LOT".equals(row.sourceType())).findFirst().orElseThrow();
        assertNull(source.issuePostingId()); qty("10",source.availableQty());
        assertTrue(beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService.class).capabilities(c.plan(),c.segment()).canRequestReturn());
        var unissuedTask=beans.getBean(com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService.class)
                .workshopTasks(1,50,null,null,c.workshop(),null,null).getItems().stream()
                .filter(task->task.segmentId().equals(c.segment())).findFirst().orElseThrow();
        assertTrue(unissuedTask.hasMaterialActivity(),"未选路线的已到直送料必须在车间任务显示物料入口");
        assertFalse(unissuedTask.hasUnregisteredMaterial(),"尚未实际领入的直送料不能虚标待登记实耗");
        var request=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-free-direct-to-normal","当前车间收到的三件直送料实际送到正常仓库",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(null,new BigDecimal("3"),source.directTransferItemId())))).getFirst();
        assertNull(request.warehouseId()); assertEquals(source.sourceWarehouseId(),request.sourceWarehouseId());
        assertThrows(ApiException.class,()->returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-free-direct-overdraw","已有三件待退，不能再承诺八件",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(null,new BigDecimal("8"),source.directTransferItemId())))));
        fixture.loginAs(c.world().superAdminUserId());
        assertThrows(ApiException.class,()->stock.approve(request.documentId()));
        assertThrows(ApiException.class,()->stock.confirmProductionMaterialReturn(request.documentId(),
                new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(source.sourceWarehouseId(),"adv-reject-tech-as-receiving")));
        stock.confirmProductionMaterialReturn(request.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(c.leaf(),"adv-free-direct-received"));
        qty("7",physical(source.sourceWarehouseId(),c.material())); qty("3",physical(c.leaf(),c.material()));
        assertEquals("WAITING",status(c.segment())); assertNull(route(c.segment()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_material_stock_postings WHERE demand_id=?",Integer.class,parentDemand(c)));
        qty("3",db.queryForObject("SELECT COALESCE(SUM(qty-consumed_qty-released_qty),0) FROM stock_reservations WHERE warehouse_id=? AND goods_id=? AND owner_type='WORKSHOP_CUSTODY' AND NOT is_deleted",BigDecimal.class,c.leaf(),c.material()));
        confirm(c,"FULL_KIT"); issueDraws(c); start(c); qty("10",capacity(c));
        fixture.loginAs(c.world().superAdminUserId());
        int originalMovements=db.queryForObject("SELECT COUNT(*) FROM stock_movements WHERE source_doc_id=?",Integer.class,request.documentId());
        assertTrue(assertSqlIntegrity(()->stock.reverse(request.documentId())).contains("already been issued"),
                "实际再领后数据库必须按精确后继来源拒绝撤回，不能靠界面隐藏");
        assertEquals(1,db.queryForObject("SELECT status FROM stock_documents WHERE id=?",Integer.class,request.documentId()));
        assertEquals(originalMovements,db.queryForObject("SELECT COUNT(*) FROM stock_movements WHERE source_doc_id=?",Integer.class,request.documentId()));
        qty("0",physical(c.leaf(),c.material())); qty("0",physical(source.sourceWarehouseId(),c.material())); qty("10",capacity(c));
    }

    @Test
    void unusedPreparedDirectReturnAndReversalAdjustOnlyExactPickingInstructions() {
        Case c=create("adv-held-direct-return",true,"10"); transfer(c,"10");
        // An upgrade-era saved route is reconciled without impersonating staff;
        // every physical direct receipt and formal allocation remains genuine.
        db.update("UPDATE production_execution_segments SET start_route='FULL_KIT',route_confirmed_at=now() WHERE id=?",c.segment());
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
        var reconciler=beans.getBean(com.uten.imp.features.production.fulfillment.ProductionReadinessReconciler.class);
        for(int attempt=0;attempt<4 && !"READY".equals(status(c.segment()));attempt++)reconciler.runBatch();
        assertEquals("READY",status(c.segment())); qty("0",capacity(c));
        UUID original=db.queryForObject("SELECT item.id FROM stock_document_items item JOIN production_planning_package_documents mapping ON mapping.document_id=item.doc_id WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW'",UUID.class,c.segment());
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).stream().filter(row->"DIRECT_LOT".equals(row.sourceType())).findFirst().orElseThrow();
        var request=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-held-direct-to-normal","四件已备但尚未投入，当前车间送正常库",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(null,new BigDecimal("4"),source.directTransferItemId())))).getFirst();
        assertThrows(ApiException.class,()->start(c)); qty("0",capacity(c));
        fixture.loginAs(c.world().superAdminUserId());
        stock.confirmProductionMaterialReturn(request.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(c.leaf(),"adv-held-direct-received"));
        qty("10",db.queryForObject("SELECT qty FROM stock_document_items WHERE id=?",BigDecimal.class,original));
        qty("6",db.queryForObject("SELECT fn_production_draw_item_effective_qty(?)",BigDecimal.class,original));
        fixture.loginAs(c.workerUser());
        segments.recheckMaterial(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-held-normal-prepare"));
        qty("6",capacity(c));
        UUID normal=db.queryForObject("SELECT item.id FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id JOIN production_planning_package_documents mapping ON mapping.document_id=document.id WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW' AND document.warehouse_id=?",UUID.class,c.segment(),c.leaf());
        fixture.loginAs(c.world().superAdminUserId()); stock.reverse(request.documentId());
        qty("0",db.queryForObject("SELECT fn_production_draw_item_effective_qty(?)",BigDecimal.class,normal));
        qty("10",db.queryForObject("SELECT fn_production_draw_item_effective_qty(?)",BigDecimal.class,original));
        qty("4",physical(source.sourceWarehouseId(),c.material())); qty("0",physical(c.leaf(),c.material()));
        UUID originalDoc=db.queryForObject("SELECT doc_id FROM stock_document_items WHERE id=?",UUID.class,original);
        assertEquals(Boolean.FALSE,db.queryForObject("SELECT fn_production_draw_pending(?)",Boolean.class,originalDoc));
        var forbiddenIssue=new com.uten.imp.features.stock.dto.StockDocIssueRequest();
        forbiddenIssue.setIdempotencyKey("adv-warehouse-tech-reject");
        var forbiddenLine=new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line(); forbiddenLine.setItemId(original); forbiddenLine.setQty(new BigDecimal("4"));
        forbiddenIssue.setLines(List.of(forbiddenLine));
        assertTrue(assertThrows(ApiException.class,()->stock.issue(originalDoc,forbiddenIssue)).getMessage().contains("自动投入"));
        qty("6",capacity(c));
        start(c); qty("10",capacity(c));
        qty("10",db.queryForObject("SELECT qty FROM stock_document_items WHERE id=?",BigDecimal.class,original));
        qty("4",db.queryForObject("SELECT qty FROM stock_document_items WHERE id=?",BigDecimal.class,normal));
    }

    @Test
    void actuallyIssuedDirectSurplusReturnsToNormalWithoutAnotherTechnicalOutflow() {
        Case c=create("adv-issued-direct-return",true,"10"); confirm(c,"CONTINUOUS"); transfer(c,"10");
        qty("10",capacity(c));
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).stream().filter(row->"ISSUE".equals(row.sourceType())).findFirst().orElseThrow();
        qty("0",physical(source.sourceWarehouseId(),c.material()));
        var request=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-issued-direct-surplus","本车间实际领入但未使用的三件送正常仓",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("3"))))).getFirst();
        assertNull(request.warehouseId()); fixture.loginAs(c.world().superAdminUserId());
        stock.confirmProductionMaterialReturn(request.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(c.leaf(),"adv-issued-direct-normal-received"));
        qty("0",physical(source.sourceWarehouseId(),c.material())); qty("3",physical(c.leaf(),c.material())); qty("7",capacity(c));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM stock_movements WHERE source_doc_id=? AND warehouse_id=?",Integer.class,request.documentId(),source.sourceWarehouseId()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='START'",Integer.class,c.segment()));
        fixture.loginAs(c.workerUser()); segments.recheckMaterial(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-issued-direct-repick"));
        issueDraws(c); qty("10",capacity(c)); start(c);
    }

    private UUID ordinarySibling(Case c,String tag) {
        UUID id=UUID.randomUUID(); db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                id,tag,tag,c.world().warehouseId()); return id;
    }

    @Test
    void fullyReturnedMaterialCanMoveWorkshopAndBeNewlyPickedFromNormalStock() {
        Case c=create("adv-normal-reassign",true,"10"); confirm(c,"CONTINUOUS"); transfer(c,"10");
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).stream().filter(row->"ISSUE".equals(row.sourceType())).findFirst().orElseThrow();
        var request=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-full-normal-return","已领十件全部由当前车间送到正常仓库",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),BigDecimal.TEN)))).getFirst();
        fixture.loginAs(c.world().superAdminUserId());
        stock.confirmProductionMaterialReturn(request.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(c.leaf(),"adv-full-normal-confirm"));
        var assignment=otherWorkshopAssignment(c,"adv-full-return-move");
        segments.assign(c.plan(),c.segment(),assignment);
        assertTrue(assertThrows(ApiException.class,()->stock.reverse(request.documentId())).getMessage().contains("改回"));
        qty("10",physical(c.leaf(),c.material())); qty("0",physical(source.sourceWarehouseId(),c.material()));
        assertEquals(1,db.queryForObject("SELECT status FROM stock_documents WHERE id=?",Integer.class,request.documentId()));
        assertEquals(c.workshop(),db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,source.drawId()));
        UUID worker=fixture.createUserWithPerms(c.world(),"adv-normal-new-workshop","production_execution:view","production_execution:start");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",assignment.workshopDepartmentId(),worker);
        fixture.loginAs(worker);
        segments.recheckMaterial(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-new-workshop-material"));
        var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        assertEquals(1,preview.lines().size()); qty("10",preview.lines().getFirst().qty());
        assertEquals(assignment.workshopDepartmentId(),db.queryForObject("SELECT department_id FROM stock_documents WHERE id=?",UUID.class,preview.lines().getFirst().drawId()));
        drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(items,"adv-new-workshop-pick",preview.fingerprint()));
        issueRequestedDraws(c); qty("10",capacity(c));
        fixture.loginAs(worker); segments.start(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-new-workshop-start"));
        assertEquals("IN_PROGRESS",status(c.segment()));
    }

    @Test
    void continuousStartUsesOnlyTheUnfrozenDirectQuantityWhileSurplusWaitsForReceipt() {
        Case c=create("adv-cont-direct-freeze",true,"10"); transfer(c,"10");
        db.update("UPDATE production_execution_segments SET start_route='CONTINUOUS',continuous_supply=TRUE,route_confirmed_at=now() WHERE id=?",c.segment());
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
        var reconciler=beans.getBean(com.uten.imp.features.production.fulfillment.ProductionReadinessReconciler.class);
        for(int attempt=0;attempt<4 && !"READY".equals(status(c.segment()));attempt++)reconciler.runBatch();
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).stream().filter(row->"DIRECT_LOT".equals(row.sourceType())).findFirst().orElseThrow();
        var pending=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-cont-freeze-four","四件待送正常库，其他六件可真实投入",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(null,new BigDecimal("4"),source.directTransferItemId())))).getFirst();
        assertEquals(Boolean.TRUE,db.queryForObject("SELECT fn_execution_start_material_ready(?)",Boolean.class,c.segment()));
        start(c); qty("6",capacity(c));
        qty("4",physical(source.sourceWarehouseId(),c.material()));
        returns.cancel(c.plan(),pending.documentId(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Cancel(
                "adv-cont-cancel-unreceived","这四件仍需使用，取消尚未交仓的原申请"));
        segments.recheckMaterial(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-cont-pick-remaining-four"));
        qty("10",capacity(c)); qty("0",physical(source.sourceWarehouseId(),c.material()));
        assertEquals(1,drawCount(c.segment()),"原技术DRAW可按真实事实继续投入，不重复拆单");
    }
    private BigDecimal physical(UUID warehouse,UUID goods) {
        return db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,warehouse,goods);
    }

    @Test
    void automaticArrivalsAndReconciliationDoNotReclaimReturnedMaterialWithoutWorkshopIntent() {
        Case c=create("adv-explicit-return-intent",true,"10"); confirm(c,"FULL_KIT"); transfer(c,"3");
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).stream().filter(row->"DIRECT_LOT".equals(row.sourceType())).findFirst().orElseThrow();
        var pending=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-return-intent-request","三件先送正常仓，是否再次领用由本车间明确核料",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(null,new BigDecimal("3"),source.directTransferItemId())))).getFirst();
        fixture.loginAs(c.world().superAdminUserId());
        stock.confirmProductionMaterialReturn(pending.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(c.leaf(),"adv-return-intent-received"));
        transfer(c,"7");
        assertEquals("WAITING",status(c.segment())); assertEquals(0,drawCount(c.segment()));
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
        beans.getBean(com.uten.imp.features.production.fulfillment.ProductionReadinessReconciler.class).runBatch();
        assertEquals("WAITING",status(c.segment())); assertEquals(0,drawCount(c.segment()),"后台不得把已送正常仓的余料自动变成新待发承诺");
        qty("3",db.queryForObject("SELECT COALESCE(SUM(qty-consumed_qty-released_qty),0) FROM stock_reservations WHERE owner_type='WORKSHOP_CUSTODY' AND owner_id=? AND NOT is_deleted",BigDecimal.class,parentDemand(c)));
        fixture.loginAs(c.workerUser());
        assertTrue(beans.getBean(com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService.class)
                .workshopTasks(1,50,null,null,c.workshop(),null,null).getItems().stream().filter(row->row.segmentId().equals(c.segment()))
                .findFirst().orElseThrow().canRecheckMaterial(),"等待中的退库专属材料必须有明确核料入口");
        segments.recheckMaterial(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"adv-return-intent-explicit-reclaim"));
        assertEquals("READY",status(c.segment())); qty("7",capacity(c));
        issueDraws(c); start(c); qty("10",capacity(c));
    }

    @Test
    void materialReturnUsesExactBaseQuantitiesAfterSevenOfTwelveWereConsumed() {
        Case c=create("adv-return-base-twelve",false,"12");
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"12"); issueDraws(c); start(c);
        fixture.loginAs(c.workerUser());
        var settlement=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        settlement.setExecutionSegmentId(c.segment());settlement.setIdempotencyKey("adv-base-consume-seven");settlement.setReason("十二基本件中实际耗用七件");
        var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
        line.setDemandId(parentDemand(c));line.setSettlementType("CONSUMED");line.setQtyBase(new BigDecimal("7"));settlement.setLines(List.of(line));
        beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService.class).post(c.plan(),settlement,c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).getFirst();
        assertEquals(c.world().unitId(),source.unitId());qty("1",source.unitRate());qty("12",source.issuedQty());qty("5",source.availableQty());
        assertThrows(ApiException.class,()->returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-base-excess-return","不能把已经耗用的基本件也退回",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("5.0001"))))));
        var pending=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"adv-base-return-five","五基本件精确送正常仓，不把包装换算四舍五入",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("5"))))).getFirst();
        qty("5",pending.lines().getFirst().qty());qty("5",pending.lines().getFirst().baseQty());
        fixture.loginAs(c.world().superAdminUserId());
        stock.confirmProductionMaterialReturn(pending.documentId(),new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(c.leaf(),"adv-base-receive-five"));
        qty("5",physical(c.leaf(),c.material()));qty("7",capacity(c));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_material_return_receiving_confirmations WHERE stock_document_id=?",Integer.class,pending.documentId()));
        stock.reverse(pending.documentId());qty("0",physical(c.leaf(),c.material()));qty("12",capacity(c));
        qty("5",returns.sources(c.plan(),c.segment()).getFirst().availableQty());
    }

    /** Import-shaped pending header; formal allocation, issue and stock movements still use real services. */
    private UUID legacyPendingDraw(Case c,com.uten.imp.features.production.execution.SegmentAssignmentRequest historical,boolean confirmRoute) {
        fixture.loginAs(c.world().superAdminUserId());
        return new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class))
                .execute(ignored->{
                    beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
                    var document=new com.uten.imp.features.stock.StockDocument();
                    document.setDocType("DRAW"); document.setBillDate(BusinessTime.today());
                    document.setBillNo(beans.getBean(com.uten.imp.common.docnumber.DocNumberService.class).nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.STOCK_DRAW));
                    document.setWarehouseId(c.leaf()); document.setDepartmentId(historical.workshopDepartmentId());
                    document.setWorkerId(historical.responsibleEmployeeId()); document.setStatus((short)0);
                    document.setMakerId(beans.getBean(com.uten.imp.security.SecurityContextCurrentUser.class).requireEmployeeId());
                    String planNo=db.queryForObject("SELECT bill_no FROM production_plans WHERE id=?",String.class,c.plan());
                    document.setPlanNo(planNo); document.setSourceDocNo(planNo);
                    beans.getBean(com.uten.imp.features.stock.StockDocumentRepository.class).saveAndFlush(document);
                    UUID packageId=db.queryForObject("SELECT package_id FROM production_execution_segments WHERE id=?",UUID.class,c.segment());
                    beans.getBean(com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService.class)
                            .recordDocument(packageId,c.segment(),"DRAW",document.getId(),document.getBillNo(),c.world().superAdminUserId());
                    db.update("INSERT INTO plan_draw_links(plan_id,draw_id,created_by) VALUES(?,?,?)",c.plan(),document.getId(),c.world().superAdminUserId());
                    if(confirmRoute) segments.confirmRoute(c.plan(),c.segment(),new SegmentRouteConfirmRequest(version(c.segment()),"adv-legacy-confirm-"+c.segment(),"CONTINUOUS"));
                    return document.getId();
                });
    }

    private boolean custodyValid(Case c) {
        return Boolean.TRUE.equals(db.queryForObject("SELECT fn_execution_material_custody_valid(?)",Boolean.class,c.segment()));
    }

    private com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest adversarialFinalReport(Case c) {
        var request=new com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest();
        request.setIdempotencyKey("adv-final-"+UUID.randomUUID()); request.setBillDate(BusinessTime.today());
        request.setWarehouseId(c.leaf()); request.setDepartmentId(c.workshop()); request.setWorkerIds(List.of(c.worker()));
        var line=new com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine();
        line.setLineNo(1); line.setExecutionSegmentId(c.segment()); line.setPlanItemId(c.planItem());
        line.setGoodsId(c.parent()); line.setUnitId(c.world().unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("4")); line.setIsFinal(true);
        var allocation=db.queryForMap("SELECT id,sales_order_item_id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",c.segment());
        line.setExecutionSegmentSalesAllocationId((UUID)allocation.get("id")); line.setSalesOrderItemId((UUID)allocation.get("sales_order_item_id"));
        request.setItems(List.of(line)); return request;
    }

    private static String assertSqlIntegrity(Runnable attack) {
        return assertSqlIntegrity(attack,"23514");
    }

    private static String assertSqlIntegrity(Runnable attack,String expectedState) {
        RuntimeException failure=assertThrows(RuntimeException.class,attack::run);
        Throwable cause=failure;
        while(cause!=null) {
            if(cause instanceof java.sql.SQLException sql && expectedState.equals(sql.getSQLState())) return sql.getMessage();
            cause=cause.getCause();
        }
        return fail("应由完整性约束拒绝，不得把其他测试错误当作拒绝证据",failure);
    }

    private com.uten.imp.features.production.execution.SegmentAssignmentRequest otherWorkshopAssignment(Case c,String key) {
        fixture.loginAs(c.world().superAdminUserId());
        UUID workshop=UUID.randomUUID(),employee=UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,parent_id,level) SELECT ?,?,?,parent_id,'二级班组' FROM departments WHERE id=?",
                workshop,key+"-W",key,c.workshop());
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",
                employee,key+"-E",key,workshop);
        return new com.uten.imp.features.production.execution.SegmentAssignmentRequest(version(c.segment()),key,workshop,null,employee,
                BusinessTime.today(),BusinessTime.today().plusDays(10));
    }

    @Test
    void warehouseIssueRacingWorkshopStartCannotDeadlockOrStartWithoutRealMaterials() throws Exception {
        Case c=create("adv-issue-start",false);
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10");
        fixture.loginAs(c.workerUser());
        var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(items,"adv-before-issue-start",preview.fingerprint()));
        var request=new SegmentTransitionRequest(version(c.segment()),"adv-racing-start");
        concurrently(c.workerUser(),()->{issueRequestedDraws(c); return null;},()->{
            try { segments.start(c.plan(),c.segment(),request); }
            catch(ApiException changedOrNotIssued) {
                assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,changedOrNotIssued.getCode());
            }
            return null;
        });
        qty("10",capacity(c));
        if(!"IN_PROGRESS".equals(status(c.segment()))) start(c);
        assertEquals("IN_PROGRESS",status(c.segment()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='START'",Integer.class,c.segment()));
        qty("10",db.queryForObject("SELECT SUM(qty_base) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",BigDecimal.class,parentDemand(c)));
    }
    private void start(Case c) {
        fixture.loginAs(c.workerUser());
        segments.start(c.plan(),c.segment(),new SegmentTransitionRequest(version(c.segment()),"rg-start-"+c.segment()));
    }
    private BigDecimal capacity(Case c) {
        return db.queryForObject("SELECT fn_execution_material_output_capacity(?,TRUE)",BigDecimal.class,c.segment());
    }

    // ===================== 夹具 =====================

    private record Case(
            FullChainEndToEndTest.World world,
            UUID parent, UUID material,
            UUID plan, UUID segment,
            UUID childPlan, UUID childSegment,
            UUID workshop, UUID worker, UUID workerUser,
            UUID leaf, UUID planItem, UUID extraMaterial) {
    }

    /**
     * 父件(自制) → 唯一子件(自制零料直制)。issueChild=true 时先下达并开工子件计划
     * Both roots remain unconfirmed until the workshop chooses its production route.
     */
    private Case create(String tag, boolean issueChild) { return create(tag, issueChild, "100"); }

    private Case create(String tag, boolean issueChild, String total) {
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID parent = UUID.randomUUID(), child = UUID.randomUUID();
        fixture.insertGoods(parent, "RG-P-" + tag, "路线父件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertGoods(child, "RG-C-" + tag, "路线子件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertBom(parent, child, tag.contains("fixed")?"2":"1");
        if(tag.contains("fixed"))db.update("UPDATE goods_bom_items SET consumption_basis='FIXED_BATCH',basis_output_qty=10 WHERE goods_id=?",parent);
        UUID extra=null;
        if(tag.contains("mixed")) {
            extra=UUID.randomUUID();
            fixture.insertGoods(extra,"RG-X-"+tag,"仓库辅料-"+tag,"采购",w.unitId(),w.unitLegacy());
            fixture.insertBom(parent,extra,"1");
        }
        UUID production = db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'", UUID.class);
        UUID workshop = UUID.randomUUID(), worker = UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",
                workshop, "RG-W-" + tag, "路线车间-" + tag, production);
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """, worker, "RG-EMP-" + tag, "路线负责人-" + tag, workshop);
        UUID workerUser = fixture.createUserWithPerms(w, "rg-worker-" + tag,
                "production_execution:view", "production_execution:start", "production_material:settle",
                "production_daily_report:view", "production_daily_report:create", "production_daily_report:approve",
                "production_direct_transfer:approve");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                workshop, workerUser);
        UUID leaf = UUID.randomUUID();
        db.update("""
                INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable)
                VALUES(?,?,?,?,'使用',TRUE)
                """, leaf, "RG-SUB-" + tag, "路线子仓-" + tag, w.warehouseId());

        UUID order = fixture.createApprovedOrder(w, parent, total, "100");
        UUID orderItem = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, order);
        var view = analyses.preview(new PreviewRequest(null, null, null, w.warehouseId(),
                "rg-preview-" + tag, List.of(new PreviewItem("SALES_ORDER_ITEM", orderItem,
                null, null, null, null, null, BusinessTime.today().plusDays(10), new BigDecimal(total)))));
        analyses.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(),
                "rg-routes-" + tag, view.flatMaterials().stream()
                        .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                                row.goodsId().equals(parent) || row.goodsId().equals(child) ? "MAKE" : "BUY", null))
                        .toList()));
        view = analyses.detail(view.analysisId());
        UUID childPlan = null;
        UUID childSegment = null;
        if (issueChild) {
            UUID childLineId = view.flatMaterials().stream()
                    .filter(row -> row.goodsId().equals(child)).findFirst().orElseThrow().materialLineId();
            var childResult = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                    view.version(), view.fingerprint(), "rg-child-" + tag, w.warehouseId(),
                    BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                    List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                            childLineId, null, new BigDecimal(total),
                            BusinessTime.today(), BusinessTime.today().plusDays(10),
                            workshop, null, worker, null, null))));
            childPlan = childResult.plans().getFirst().planId();
            childSegment = childResult.plans().getFirst().segmentIds().getFirst();
            assertEquals("READY", status(childSegment), "零料直制子件任务直接可开工");
            // The zero-material child still confirms its route before explicit start.
            fixture.loginAs(workerUser);
            segments.confirmRoute(childPlan, childSegment,new SegmentRouteConfirmRequest(version(childSegment),"rg-child-route-"+childSegment,"FULL_KIT"));
            segments.start(childPlan, childSegment,
                    new SegmentTransitionRequest(version(childSegment), "rg-child-open-start-" + childSegment));
            fixture.loginAs(w.superAdminUserId());
        }

        view = analyses.detail(view.analysisId());
        var rootResult = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                view.version(), view.fingerprint(), "rg-root-" + tag, w.warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        null, view.products().getFirst().analysisLineId(), new BigDecimal(total),
                        BusinessTime.today(), BusinessTime.today().plusDays(10),
                        workshop, null, worker, null, null))));
        UUID plan = rootResult.plans().getFirst().planId();
        UUID segment = db.queryForObject(
                "SELECT id FROM production_execution_segments WHERE plan_id=? AND status='WAITING'", UUID.class, plan);
        UUID planItem = db.queryForObject(
                "SELECT source_plan_item_id FROM production_execution_segments WHERE id=?", UUID.class, segment);
        fixture.loginAs(workerUser);
        return new Case(w, parent, child, plan, segment, childPlan, childSegment,
                workshop, worker, workerUser, leaf, planItem, extra);
    }

    /** 子件报工「转下一道工序」，直送给父件对本子件的需求。 */
    private void transfer(Case c, String quantity) {
        fixture.loginAs(c.workerUser());
        var report = new com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest();
        report.setIdempotencyKey("rg-report-" + c.childSegment() + "-" + quantity + "-" + UUID.randomUUID());
        report.setBillDate(BusinessTime.today());
        report.setWarehouseId(c.leaf());
        report.setDepartmentId(c.workshop());
        report.setWorkerIds(List.of(c.worker()));
        var item = new com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine();
        item.setLineNo(1);
        item.setExecutionSegmentId(c.childSegment());
        item.setPlanItemId(db.queryForObject(
                "SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",
                UUID.class, c.childSegment()));
        item.setGoodsId(childGoods(c));
        item.setUnitId(c.world().unitId());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(quantity));
        item.setDestination("WORKSHOP");
        item.setDirectTransferDemandId(parentDemand(c));
        report.setItems(List.of(item));
        reports().approve(reports().create(report).getId());
    }

    private UUID childGoods(Case c) {
        return c.material();
    }

    private com.uten.imp.features.production.dailyreport.ProductionDailyReportService reports() {
        return beans.getBean(com.uten.imp.features.production.dailyreport.ProductionDailyReportService.class);
    }

    private void receive(Case c, UUID goods, UUID warehouse, String quantity) {
        fixture.loginAs(c.world().superAdminUserId());
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setWarehouseId(warehouse);
        request.setBillDate(BusinessTime.today());
        var line = new StockDocItemLine();
        line.setGoodsId(goods);
        line.setUnitId(c.world().unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity));
        line.setPrice(BigDecimal.TEN);
        line.setAmountOriginal(line.getQty().multiply(BigDecimal.TEN));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        stock.approve(stock.create(request).getId());
    }

    /** 提升生成的草稿领料单：车间先确认领料汇总(领料申请)，再由仓库一次发料
     * （开工要求「待发料=0」，申请确认与发料都仍是车间/仓库各自的职责）。 */
    private void issueDraws(Case c) {
        fixture.loginAs(c.workerUser());
        var items = List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(
                c.segment(), version(c.segment())));
        var preview = drawRequests.preview(
                new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
        drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(
                items, "rg-request-" + c.segment()+"-"+version(c.segment()), preview.fingerprint()));
        issueRequestedDraws(c);
    }

    private void issueRequestedDraws(Case c) {
        fixture.loginAs(c.world().superAdminUserId());
        for (UUID docId : db.queryForList("""
                SELECT DISTINCT document.id FROM production_planning_package_documents mapping
                JOIN stock_documents document ON document.id=mapping.document_id
                 AND document.doc_type='DRAW' AND document.status=0 AND NOT document.is_deleted
                WHERE mapping.execution_segment_id=?
                """, UUID.class, c.segment())) {
            var issue = new com.uten.imp.features.stock.dto.StockDocIssueRequest();
            issue.setIdempotencyKey("rg-issue-" + docId);
            issue.setLines(db.queryForList("""
                    SELECT id, qty FROM stock_document_items
                    WHERE doc_id=? AND NOT is_deleted ORDER BY line_no
                    """, docId).stream().map(row -> {
                var line = new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line();
                line.setItemId((UUID) row.get("id"));
                line.setQty((BigDecimal) row.get("qty"));
                return line;
            }).toList());
            stock.approveAndIssue(docId, issue);
        }
    }

    private String route(UUID segmentId) {
        return db.queryForObject(
                "SELECT start_route FROM production_execution_segments WHERE id=?", String.class, segmentId);
    }

    private boolean allowsAutoPromote(UUID segmentId) {
        return Boolean.TRUE.equals(db.queryForObject(
                "SELECT fn_execution_route_allows_auto_promote(?)", Boolean.class, segmentId));
    }

    private UUID parentDemand(Case c) {
        return db.queryForObject(
                "SELECT id FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",
                UUID.class, c.segment(), childGoods(c));
    }

    private int drawCount(UUID segmentId) {
        return db.queryForObject("""
                SELECT count(*) FROM production_planning_package_documents mapping
                JOIN stock_documents document ON document.id=mapping.document_id AND NOT document.is_deleted
                WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW'
                """, Integer.class, segmentId);
    }

    private long version(UUID id) {
        return db.queryForObject(
                "SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, id);
    }

    private String status(UUID id) {
        return db.queryForObject(
                "SELECT status FROM production_execution_segments WHERE id=?", String.class, id);
    }

    private static void qty(String expected, BigDecimal value) {
        assertEquals(0, new BigDecimal(expected).compareTo(value), "expected " + expected + " but was " + value);
    }
}
