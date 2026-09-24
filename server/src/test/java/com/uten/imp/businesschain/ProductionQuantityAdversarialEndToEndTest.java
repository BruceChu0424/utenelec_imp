package com.uten.imp.businesschain;

import com.uten.imp.support.DailyReportApproveRequests;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
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
class ProductionQuantityAdversarialEndToEndTest {
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
    void fullKitPendingReturnCannotFundOrdinaryReport() {
        Case c=create("aq-kit-return",false,"10");
        confirm(c,"FULL_KIT"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c); start(c);
        var draft=reports().create(report(c,"8",false,"8"));
        var pendingOther=reports().create(report(c,"2",false,"2"));
        var reloaded=reports().detail(draft.getId()).getItems().getFirst();
        assertEquals(c.plan(),reloaded.getPlanId());
        qty("10",reloaded.getRemainingPlanQty());
        reports().delete(pendingOther.getId());
        requestReturn(c,"3");
        qty("7",capacity(c));
        fixture.loginAs(c.world().superAdminUserId());
        assertApprovalRejected(c,draft.getId(),"本次清账超过准确原领料未耗用数量");
        reports().delete(draft.getId());
        qty("10",beans.getBean(com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService.class)
                .list(1,50,null,c.workshop(),List.of(c.segment())).getItems().getFirst().maxReportQty());
        var request=reports().create(report(c,"8",false,"8"));
        assertApprovalRejected(c,request.getId(),"本次清账超过准确原领料未耗用数量");
        qty("7",capacity(c));
    }

    @Test
    void fullKitActualReturnKeepsActualOutputSeparateFromTheMaterialThatMayBeConsumed() {
        Case c=create("aq-kit-real-return",false,"10");
        confirm(c,"FULL_KIT"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c); start(c);
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).getFirst();
        var requested=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"aq-real-return-"+UUID.randomUUID(),"剩余三件实际退仓",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("3"))))).getFirst();
        fixture.loginAs(c.world().superAdminUserId()); stock.approve(requested.documentId());
        qty("7",capacity(c));
        var candidates=beans.getBean(com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService.class)
                .list(1,50,null,c.workshop(),List.of(c.segment())).getItems();
        assertEquals(1,candidates.size(),"a started FULL_KIT task must remain reportable after a real surplus return");
        qty("10",candidates.getFirst().maxReportQty());
        var overuse=reports().create(report(c,"8",false,"8"));
        assertApprovalRejected(c,overuse.getId(),"本次清账超过准确原领料未耗用数量");
        reports().delete(overuse.getId());
        // The workshop measured eight outputs from seven genuinely consumed
        // units. Source quota is ten; returned stock is never usable material.
        reports().approve(reports().create(report(c,"8",false,"7")).getId(), DailyReportApproveRequests.freshKey());
        qty("8",db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("7",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,parentDemand(c)));
        qty("3",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",BigDecimal.class,c.leaf(),c.material()));
        qty("7",capacity(c));
    }

    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.ValueSource(booleans={false,true})
    void fullKitActualReturnCanFinishTheSupportedQuantityAndReverseItsFinalTarget(boolean anotherNormalLeaf) {
        Case c=create("aq-kit-return-final-"+anotherNormalLeaf,false,"10");
        confirm(c,"FULL_KIT"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c); start(c);
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).getFirst();
        var returned=returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                c.segment(),"aq-kit-final-return-"+UUID.randomUUID(),"齐套开工后实际退回三件",
                List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("3"))))).getFirst();
        fixture.loginAs(c.world().superAdminUserId());
        UUID receiving=c.leaf();
        if(anotherNormalLeaf) {
            receiving=UUID.randomUUID();
            db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                    receiving,"AQ-RTN-"+receiving,"余料实际收仓",c.world().warehouseId());
            stock.confirmProductionMaterialReturn(returned.documentId(),
                    new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(receiving,"aq-final-receive-"+returned.documentId()));
            assertFalse(db.queryForObject("SELECT fn_daily_report_has_unissued_material(?)",Boolean.class,c.planItem()),
                    "true previously issued surplus keeps its issue history across actual receiving warehouses");
            qty("3",db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,receiving,c.material()));
            qty("0",db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.leaf(),c.material()));
        } else stock.approve(returned.documentId());
        qty("7",capacity(c));
        var request=report(c,"7",true,"7");
        UUID report=reports().approve(reports().create(request).getId(), DailyReportApproveRequests.freshKey()).getId();
        UUID reportItem=db.queryForObject("SELECT id FROM production_daily_report_items WHERE report_id=?",UUID.class,report);
        beans.getBean(com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService.class).register(report,
                new com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest(
                        "aq-kit-final-arrival-"+report,c.leaf(),List.of(new com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest(reportItem,"正常叶仓实收七件")),null));
        UUID inspection=db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?",UUID.class,reportItem);
        beans.getBean(com.uten.imp.features.production.quality.ProductionFqcInspectionService.class).decide(inspection,
                new com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest("PASS",new BigDecimal("7"),null,null,null,"aq-kit-final-pass-"+report));
        UUID finished=db.queryForObject("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted",UUID.class,report);
        fixture.confirmFinishedInboundFully(finished);
        assertEquals("COMPLETED",db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,c.segment()));
        qty("7",db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("3",db.queryForObject("SELECT reservation.released_qty FROM stock_reservations reservation JOIN production_material_stock_postings issue ON issue.reservation_id=reservation.id WHERE issue.id=?",BigDecimal.class,source.issuePostingId()));
        qty("0",db.queryForObject("SELECT SUM(qty-consumed_qty-released_qty) FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",BigDecimal.class,parentDemand(c)));
        var operator=org.springframework.security.core.context.SecurityContextHolder.getContext();
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
        try {InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),db,List.of(c.parent(),c.material()));}
        finally {org.springframework.security.core.context.SecurityContextHolder.setContext(operator);}
        stock.reverseFinishedInbound(finished);
        reports().reverse(report);
        qty("10",db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("0",db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("0",db.queryForObject("SELECT iqty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("7",capacity(c));
    }

    @Test
    void fullKitLossCannotFundOrdinaryReport() {
        Case c=create("aq-kit-loss",false,"10");
        confirm(c,"FULL_KIT"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c); start(c);
        settle(c,"APPROVED_LOSS","3");
        qty("7",capacity(c));
        var overuse=reports().create(report(c,"8",false,"8"));
        assertApprovalRejected(c,overuse.getId(),"本次清账超过准确原领料未耗用数量");
    }

    @Test
    void reversingEarlyFinalReportRestoresRemainingDemandAndReplenishment() {
        Case c=create("aq-final-reverse",false,"10");
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"4"); issueDraws(c); start(c);
        fixture.loginAs(c.world().superAdminUserId());
        var completed=reports().approve(reports().create(report(c,"4",true,"4")).getId(), DailyReportApproveRequests.freshKey());
        qty("6",db.queryForObject("SELECT released_qty FROM production_material_demands WHERE id=?",BigDecimal.class,parentDemand(c)));
        qty("10",db.queryForObject("SELECT qty+COALESCE(capped_qty,0) FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("10",db.queryForObject("SELECT submitted_qty FROM production_material_analysis_plan_links WHERE plan_id=?",BigDecimal.class,c.plan()));
        qty("0",db.queryForObject("SELECT requested_qty-submitted_qty-approved_qty FROM production_material_analysis_items WHERE id=(SELECT material_analysis_item_id FROM production_plans WHERE id=?)",BigDecimal.class,c.plan()));
        qty("6",db.queryForObject("SELECT SUM(item.qty) FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id WHERE plan.source_daily_report_id=? AND NOT plan.is_deleted",BigDecimal.class,completed.getId()));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update(
                "UPDATE production_daily_report_target_events SET after_qty=5 WHERE report_id=?",completed.getId()));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update(
                "UPDATE production_daily_report_material_release_events SET qty_base=5 WHERE report_id=?",completed.getId()));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update(
                "UPDATE production_plan_items SET qty=5,capped_qty=5 WHERE id=?",c.planItem()));
        reports().reverse(completed.getId());
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE report_id=?",Integer.class,completed.getId()));
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_material_release_events WHERE report_id=?",Integer.class,completed.getId()));
        qty("10",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,c.segment()));
        qty("0",db.queryForObject("SELECT released_qty FROM production_material_demands WHERE id=?",BigDecimal.class,parentDemand(c)));
        receive(c,c.material(),c.leaf(),"6"); issueDraws(c);
        qty("10",capacity(c));
    }

    @Test
    void fixedBatchCapacityIsTheMaximalFeasibleOutputAcrossBoundaryPerturbations() {
        Case c=create("aq-fixed-duality",false,"11");
        UUID demand=parentDemand(c);
        for(String available:List.of("0","0.0001","1.9999","2","2.0001","3.9999","4","10")) {
            BigDecimal stock=new BigDecimal(available);
            BigDecimal output=db.queryForObject("SELECT fn_demand_material_output_capacity(?,?)",BigDecimal.class,demand,stock);
            BigDecimal required=db.queryForObject("SELECT fn_material_snapshot_required(consumption_snapshot,?) FROM production_material_demands WHERE id=?",BigDecimal.class,output,demand);
            assertTrue(required.compareTo(stock)<=0,"capacity must always be feasible at stock "+stock);
            assertTrue(output.compareTo(new BigDecimal("11"))<=0,"capacity must not exceed the frozen target");
            if(output.compareTo(new BigDecimal("11"))<0) {
                BigDecimal next=db.queryForObject("SELECT fn_material_snapshot_required(consumption_snapshot,?) FROM production_material_demands WHERE id=?",BigDecimal.class,output.add(new BigDecimal("0.0001")),demand);
                assertTrue(next.compareTo(stock)>0,"capacity must be maximal at stock "+stock);
            }
        }
        db.update("UPDATE goods_bom_items SET qty=200 WHERE goods_id=?",c.parent());
        qty("10",db.queryForObject("SELECT fn_demand_material_output_capacity(?,2)",BigDecimal.class,demand));
    }

    @Test
    void actualProcessConsumptionIncludingFrozenNormalWasteDoesNotReduceCumulativeOutput() {
        Case c=create("aq-normal-waste",false,"10");
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"11"); issueDraws(c); start(c);
        fixture.loginAs(c.world().superAdminUserId());
        // This batch actually consumed six units including its process waste;
        // the second batch consumed the five remaining units. Record each once.
        reports().approve(reports().create(report(c,"5",false,"6")).getId(), DailyReportApproveRequests.freshKey());
        qty("10",capacity(c));
        reports().approve(reports().create(report(c,"5",false,"5")).getId(), DailyReportApproveRequests.freshKey());
        qty("10",db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("11",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,parentDemand(c)));
    }

    @Test
    void reversingLaterFinalWithoutReductionCannotRestoreAnotherReportsCap() {
        Case c=create("aq-final-owner",false,"10");
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10"); issueDraws(c); start(c);
        var first=reports().approve(reports().create(report(c,"2",false,"2")).getId(), DailyReportApproveRequests.freshKey());
        // Finish after explicitly consuming all eight units still on site.
        var owner=reports().approve(reports().create(report(c,"2",true,"8")).getId(), DailyReportApproveRequests.freshKey());
        reports().reverse(first.getId());
        var later=reports().approve(reports().create(report(c,"2",true,"2")).getId(), DailyReportApproveRequests.freshKey());
        reports().reverse(later.getId());
        qty("4",db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("6",db.queryForObject("SELECT capped_qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE report_id=?",Integer.class,later.getId()));
        reports().reverse(owner.getId());
        qty("10",db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
    }

    @Test
    void failureAfterCappingRollsBackTargetReleaseRemakeAndReportTogether() {
        Case c=create("aq-final-rollback",false,"10");
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"4"); issueDraws(c); start(c);
        var request=report(c,"4",true,"5");
        var draft=reports().create(request);
        assertApprovalRejected(c,draft.getId(),"本次清账超过准确原领料未耗用数量");
        qty("10",db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("0",db.queryForObject("SELECT COALESCE(capped_qty,0) FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("0",db.queryForObject("SELECT released_qty FROM production_material_demands WHERE id=?",BigDecimal.class,parentDemand(c)));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE report_id=?",Integer.class,draft.getId()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_material_release_events WHERE report_id=?",Integer.class,draft.getId()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE source_daily_report_id=?",Integer.class,draft.getId()));
        assertEquals((short)0,reports().detail(draft.getId()).getStatus());
    }

    @Test
    void futurePurchaseCommitmentKeepsOrdinaryReportingOpenButPreventsEarlyFinal() {
        Case c=create("aq-future-peg",false,"10");
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"4"); issueDraws(c); start(c);
        fixture.loginAs(c.world().superAdminUserId());
        var purchase=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        purchase.setBillDate(BusinessTime.today()); purchase.setNeedDate(BusinessTime.today().plusDays(1));
        purchase.setWarehouseId(c.leaf());
        var purchaseLine=new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        purchaseLine.setLineNo(1); purchaseLine.setGoodsId(c.material());
        purchaseLine.setUnitId(c.world().unitId()); purchaseLine.setUnitRate(BigDecimal.ONE);
        purchaseLine.setQty(new BigDecimal("6")); purchase.setItems(List.of(purchaseLine));
        var request=beans.getBean(com.uten.imp.features.purchase.request.PurchaseRequestService.class).create(purchase);
        UUID requestItem=db.queryForObject("SELECT id FROM purchase_request_items WHERE request_id=?",UUID.class,request.getId());
        new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class))
                .executeWithoutResult(ignored -> {
                    beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
                    var demand=beans.getBean(jakarta.persistence.EntityManager.class).find(
                            com.uten.imp.features.production.fulfillment.ProductionMaterialDemand.class,parentDemand(c));
                    var ledger=beans.getBean(com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService.class);
                    ledger.createSupplyPeg(demand,"PURCHASE_REQUEST_ITEM",requestItem,new BigDecimal("6"),BusinessTime.today().plusDays(1));
                    ledger.refreshDemandStatuses(List.of(demand.getId()));
                });
        var finalDraft=reports().create(report(c,"4",true,"4"));
        assertApprovalRejected(c,finalDraft.getId(),"未兑现的采购、委外或生产供给承诺");
        reports().delete(finalDraft.getId());
        reports().approve(reports().create(report(c,"4",false,"4")).getId(), DailyReportApproveRequests.freshKey());
        qty("10",db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        qty("4",db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE plan_item_id=?",Integer.class,c.planItem()));
        qty("6",db.queryForObject("SELECT SUM(allocated_qty-consumed_qty-released_qty) FROM production_material_supply_pegs WHERE demand_id=?",BigDecimal.class,parentDemand(c)));
        qty("0",db.queryForObject("SELECT released_qty FROM production_material_demands WHERE id=?",BigDecimal.class,parentDemand(c)));
    }

    @Test
    void internalChildShortFinalIsRejectedWhileOrdinaryReportsKeepOriginalParentResponsibility() {
        Case c=create("aq-internal-final",true,"10");
        fixture.loginAs(c.world().superAdminUserId());
        var request=new com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest();
        request.setIdempotencyKey("aq-internal-"+UUID.randomUUID()); request.setBillDate(BusinessTime.today());
        request.setWarehouseId(c.leaf()); request.setDepartmentId(c.workshop()); request.setWorkerIds(List.of(c.worker()));
        var item=new com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine();
        item.setLineNo(1); item.setExecutionSegmentId(c.childSegment());
        UUID childItem=db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,c.childSegment());
        item.setPlanItemId(childItem); item.setGoodsId(c.material()); item.setUnitId(c.world().unitId());
        item.setUnitRate(BigDecimal.ONE); item.setQty(new BigDecimal("4")); item.setIsFinal(true); request.setItems(List.of(item));
        ApiException blocked=assertThrows(ApiException.class,()->reports().create(request));
        assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,blocked.getCode());
        assertTrue(blocked.getMessage().contains("尚差 6"),blocked.getMessage());
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_items WHERE execution_segment_id=?",Integer.class,c.childSegment()));
        item.setIsFinal(false);
        reports().approve(reports().create(request).getId(), DailyReportApproveRequests.freshKey());
        qty("10",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,c.childSegment()));
        qty("10",db.queryForObject("SELECT required_qty FROM production_material_demands WHERE id=?",BigDecimal.class,parentDemand(c)));
        request.setIdempotencyKey("aq-internal-complete-"+UUID.randomUUID());
        item.setQty(new BigDecimal("6")); item.setIsFinal(true);
        reports().approve(reports().create(request).getId(), DailyReportApproveRequests.freshKey());
        qty("10",db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=?",BigDecimal.class,childItem));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE plan_item_id=?",Integer.class,childItem));
    }

    @Test
    void preparedButUnissuedMaterialsCannotBeLeftBehindByEarlyFinal() {
        Case c=create("aq-prepared-final",false,"10");
        confirm(c,"CONTINUOUS"); receive(c,c.material(),c.leaf(),"10"); issueSlice(c,"5"); start(c);
        qty("10",db.queryForObject("SELECT SUM(qty-released_qty) FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",BigDecimal.class,parentDemand(c)));
        qty("5",capacity(c));
        var finalDraft=reports().create(report(c,"5",true,"5"));
        assertApprovalRejected(c,finalDraft.getId(),"已备料但未实发");
        qty("10",db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE plan_item_id=?",Integer.class,c.planItem()));
        reports().delete(finalDraft.getId());
        reports().approve(reports().create(report(c,"5",false,"5")).getId(), DailyReportApproveRequests.freshKey());
        issueSlice(c,"5");
        reports().approve(reports().create(report(c,"5",true,"5")).getId(), DailyReportApproveRequests.freshKey());
        qty("10",db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=?",BigDecimal.class,c.planItem()));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",Integer.class,c.plan()));
    }

    private void issueSlice(Case c,String quantity) {
        fixture.loginAs(c.workerUser());
        var tasks=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(c.segment(),version(c.segment())));
        var preview=drawRequests.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(tasks));
        var line=preview.lines().getFirst();
        drawRequests.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(
                tasks,"aq-request-slice-"+UUID.randomUUID(),preview.fingerprint(),
                List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Selection(line.drawItemId(),new BigDecimal(quantity)))));
        fixture.loginAs(c.world().superAdminUserId());
        var request=new com.uten.imp.features.stock.dto.StockDocIssueRequest();
        request.setIdempotencyKey("aq-issue-slice-"+UUID.randomUUID());
        var issued=new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line();
        issued.setItemId(line.drawItemId()); issued.setQty(new BigDecimal(quantity)); request.setLines(List.of(issued));
        stock.approveAndIssue(line.drawId(),request);
    }

    private com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest report(Case c,String quantity,boolean last,String actualMaterialQuantity) {
        fixture.loginAs(c.world().superAdminUserId());
        var report=new com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest();
        report.setIdempotencyKey("aq-report-"+UUID.randomUUID()); report.setBillDate(BusinessTime.today());
        report.setWarehouseId(c.leaf()); report.setDepartmentId(c.workshop()); report.setWorkerIds(List.of(c.worker()));
        var item=new com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine();
        item.setLineNo(1); item.setExecutionSegmentId(c.segment()); item.setPlanItemId(c.planItem());
        item.setGoodsId(c.parent()); item.setUnitId(c.world().unitId()); item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(quantity)); item.setIsFinal(last);
        var allocation=db.queryForMap("SELECT id,sales_order_item_id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",c.segment());
        item.setExecutionSegmentSalesAllocationId((UUID)allocation.get("id"));
        item.setSalesOrderItemId((UUID)allocation.get("sales_order_item_id"));
        report.setItems(List.of(item));
        var usage=new com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine();
        usage.setDemandId(parentDemand(c));usage.setQtyBase(new BigDecimal(actualMaterialQuantity));
        report.setMaterialLines(List.of(usage));return report;
    }

    private void assertApprovalRejected(Case c,UUID reportId,String reason) {
        var before=materialFacts(c);
        ApiException failure=assertThrows(ApiException.class,()->reports().approve(reportId,DailyReportApproveRequests.freshKey()));
        assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,failure.getCode());
        assertTrue(failure.getMessage().contains(reason),failure.getMessage());
        assertEquals(before,materialFacts(c),"Rejected approval must leave every quantity and material source unchanged");
        assertEquals((short)0,reports().detail(reportId).getStatus());
    }

    private java.util.Map<String,String> materialFacts(Case c) {
        var facts=new java.util.LinkedHashMap<String,String>();
        for(String table:List.of("production_plan_items","production_execution_segments","production_material_demands"))
            facts.put(table,db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY fact.id),'[]')::text FROM "+table+" fact WHERE plan_id=?",String.class,c.plan()));
        for(String table:List.of("stock_reservations","production_material_stock_postings","production_material_settlement_postings","production_material_supply_pegs","production_daily_report_material_release_events"))
            facts.put(table,db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY fact.id),'[]')::text FROM "+table+" fact WHERE demand_id=?",String.class,parentDemand(c)));
        facts.put("target-events",db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY fact.id),'[]')::text FROM production_daily_report_target_events fact WHERE plan_item_id=?",String.class,c.planItem()));
        return facts;
    }

    private void requestReturn(Case c,String quantity) {
        fixture.loginAs(c.workerUser());
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(c.plan(),c.segment()).getFirst();
        returns.submit(c.plan(),new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
            c.segment(),"aq-return-"+UUID.randomUUID(),"真实余料退回",
            List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal(quantity)))));
    }

    private void settle(Case c,String kind,String quantity) {
        fixture.loginAs(c.world().superAdminUserId());
        var request=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        request.setExecutionSegmentId(c.segment()); request.setIdempotencyKey("aq-settle-"+UUID.randomUUID());
        request.setReason("对抗验证实际损耗");
        var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
        line.setDemandId(parentDemand(c));line.setSettlementType(kind);line.setQtyBase(new BigDecimal(quantity));
        request.setLines(List.of(line));
        beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService.class).post(c.plan(),request,c.world().superAdminUserId());
    }

    private void confirm(Case c,String route) {
        fixture.loginAs(c.workerUser());
        segments.confirmRoute(c.plan(),c.segment(),new SegmentRouteConfirmRequest(version(c.segment()),
                "rg-confirm-"+route+"-"+c.segment(),route));
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
        fixture.insertGoods(child, "RG-C-" + tag, "路线子件-" + tag,
                tag.contains("future-peg") ? "采购" : "自制", w.unitId(), w.unitLegacy());
        fixture.insertBom(parent, child, tag.contains("fixed")?"2":tag.contains("normal-waste")?"1.1":"1");
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
                                row.goodsId().equals(parent)
                                        || row.goodsId().equals(child) && !tag.contains("future-peg") ? "MAKE" : "BUY", null))
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
        reports().approve(reports().create(report).getId(), DailyReportApproveRequests.freshKey());
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
