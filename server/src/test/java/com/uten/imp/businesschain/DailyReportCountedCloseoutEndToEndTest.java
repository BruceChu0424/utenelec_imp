package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import com.uten.imp.features.production.execution.ProductionExecutionBatch;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.mrp.ProductionExecutionBatchService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
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

import static org.junit.jupiter.api.Assertions.*;

/** ADR-129 §2.7: the last report's physically counted leftover decides its consumption and the return. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class DailyReportCountedCloseoutEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionDailyReportService reports;
    private WorkshopPublicSurplusEndToEndTest fixture;

    @BeforeEach void prepare(){fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void countedLeftoverReplacesTheLastReportsPrefilledUseAndIsExactlyWhatReturns(){
        Object task=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","counted-"+UUID.randomUUID(),false,"10");
        UUID demand=ReflectionTestUtils.invokeMethod(task,"demand");
        ReflectionTestUtils.invokeMethod(fixture,"approveReport",task,source(task),"4");
        qty("6",bookAvailable(demand));

        // The page pre-fills 5.9 as used; the worker counts what is physically left instead.
        DailyReportSaveRequest last=lastReport(task,"7");
        UUID tooMuch=reports.create(last).getId();
        ApiException rejected=assertThrows(ApiException.class,()->reports.approve(tooMuch,DailyReportApproveRequests.freshKey()));
        assertTrue(rejected.getMessage().contains("实际剩余 7 超过账面可用 6"),rejected.getMessage());
        reports.delete(tooMuch);
        qty("6",bookAvailable(demand));

        UUID report=reports.approve(reports.create(lastReport(task,"0.5")).getId(),DailyReportApproveRequests.freshKey()).getId();
        var usage=reports.detail(report).getMaterialUsages().getFirst();
        qty("5.5",usage.getQtyBase());qty("0.5",usage.getCountedLeftoverQty());
        qty("5.5",db.queryForObject("""
                SELECT COALESCE(SUM(posting.qty_base),0) FROM production_material_settlement_postings posting
                JOIN production_material_settlement_events event ON event.id=posting.event_id
                WHERE event.daily_report_id=? AND event.event_type='POST' AND posting.settlement_type='CONSUMED'
                """,BigDecimal.class,report));
        qty("0.5",db.queryForObject("""
                SELECT COALESCE(SUM(fn_material_issue_pending_return(id,NULL)),0) FROM production_material_stock_postings
                WHERE demand_id=? AND posting_type='ISSUE'
                """,BigDecimal.class,demand));
        qty("0",bookAvailable(demand));
    }

    @Test void aCountThatLeavesOutputWithoutAnyUseIsRejectedInPlainLanguage(){
        Object task=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","counted-zero-"+UUID.randomUUID(),false,"10");
        UUID demand=ReflectionTestUtils.invokeMethod(task,"demand");
        DailyReportSaveRequest only=ReflectionTestUtils.invokeMethod(fixture,"reportRequest",task,source(task),"10","10");
        only.getItems().getFirst().setIsFinal(true);only.setSurplusReturnRequested(true);
        only.getMaterialLines().getFirst().setCountedLeftoverQty(new BigDecimal("10"));
        UUID draft=reports.create(only).getId();
        ApiException rejected=assertThrows(ApiException.class,()->reports.approve(draft,DailyReportApproveRequests.freshKey()));
        assertTrue(rejected.getMessage().contains("本次报工没有用掉任何物料"),rejected.getMessage());
        qty("10",bookAvailable(demand));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_settlement_events WHERE daily_report_id=?",Integer.class,draft));
    }

    /**
     * ADR-129 end to end: a parent with a manual design usage of 1 learns its real usage from
     * the physically counted close-out, keeps the design value, and a new material analysis
     * computes with the real usage.
     */
    @Test void countedCloseoutTeachesTheManualBomParentAndANewAnalysisUsesTheRealUsage(){
        Object task=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","counted-learn-"+UUID.randomUUID(),false,"10");
        UUID product=ReflectionTestUtils.invokeMethod(task,"product");
        UUID material=ReflectionTestUtils.invokeMethod(task,"material");
        UUID plan=ReflectionTestUtils.invokeMethod(task,"plan");
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(task,"world");
        ReflectionTestUtils.invokeMethod(fixture,"approveReport",task,source(task),"4");
        // Six more made; one unit physically left: this report used 6 - 1 = 5, nine in total.
        reports.approve(reports.create(lastReport(task,"1")).getId(),DailyReportApproveRequests.freshKey());
        assertNull(db.queryForObject("SELECT (SELECT actual_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?)",
                BigDecimal.class,product,material),"the leftover has not reached the warehouse yet");
        UUID returned=db.queryForObject("SELECT id FROM stock_documents WHERE doc_type='WDRAW' AND plan_no=(SELECT bill_no FROM production_plans WHERE id=?) AND NOT is_deleted",UUID.class,plan);
        beans.getBean(com.uten.imp.features.stock.StockDocService.class).confirmProductionMaterialReturn(returned,
                new com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest(world.warehouseId(),"counted-learn-return-"+returned));
        qty("0.9",db.queryForObject("SELECT actual_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",
                BigDecimal.class,product,material));
        qty("1",db.queryForObject("SELECT qty FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",
                BigDecimal.class,product,material));
        assertEquals("ACTUAL",db.queryForObject("SELECT usage.usage_basis FROM v_goods_bom_item_usage usage "
                + "JOIN goods_bom_items edge ON edge.id=usage.bom_item_id WHERE edge.goods_id=? AND edge.component_goods_id=? AND NOT edge.is_deleted",
                String.class,product,material));

        FullChainEndToEndTest chain=(FullChainEndToEndTest)ReflectionTestUtils.getField(fixture,"fixture");
        UUID order=chain.createApprovedOrder(world,product,"10","100");
        UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        var analyses=beans.getBean(com.uten.imp.features.production.analysis.MaterialAnalysisService.class);
        var view=analyses.preview(new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest(
                null,null,null,world.warehouseId(),"counted-learn-preview-"+order,
                List.of(new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem("SALES_ORDER_ITEM",orderItem,
                        null,null,null,null,null,com.uten.imp.common.time.BusinessTime.today().plusDays(10),new BigDecimal("10")))));
        var node=view.flatMaterials().stream().filter(row->material.equals(row.goodsId())).findFirst().orElseThrow();
        assertEquals("ACTUAL",node.usageBasis());
        qty("0.9",node.bomQty());qty("1",node.designBomQty());
        qty("9",node.requiredQty());
    }

    /**
     * Split batches: the later batch counts the leftover of the material the earlier batch drew.
     * That material is committed to the later batch, so it may not go back to the warehouse, but it
     * is still on the books: the count decides the consumption and the leftover stays in the workshop.
     */
    @Test void aLaterBatchCountsTheEarlierBatchsMaterialAndTheLeftoverStaysInTheWorkshop(){
        var batch=new ProductionExecutionBatchEndToEndTest();beans.autowireBean(batch);batch.prepare();
        FullChainEndToEndTest chain=(FullChainEndToEndTest)ReflectionTestUtils.getField(batch,"fixture");
        Object c=ReflectionTestUtils.invokeMethod(batch,"create","counted-split-"+UUID.randomUUID().toString().substring(0,8),true);
        UUID plan=ReflectionTestUtils.invokeMethod(c,"plan"),segment=ReflectionTestUtils.invokeMethod(c,"segment");
        UUID workerUser=ReflectionTestUtils.invokeMethod(c,"workerUser");
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(c,"world");
        var batches=beans.getBean(ProductionExecutionBatchService.class);
        var segments=beans.getBean(ProductionExecutionSegmentService.class);
        ReflectionTestUtils.invokeMethod(batch,"confirmRoute",plan,segment,"BATCH","counted-split-route-"+segment);
        ReflectionTestUtils.invokeMethod(batch,"receive",c,"1");
        chain.loginAs(workerUser);
        var preview=batches.preview(new ProductionExecutionBatch.PreviewRequest(segment,version(segment),new BigDecimal("20")));
        var first=batches.submit(new ProductionExecutionBatch.SubmitRequest(segment,preview.expectedVersion(),preview.quantity(),
                preview.fingerprint(),"counted-split-first-"+segment));
        UUID demand=db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",
                UUID.class,first.batchSegmentId());
        chain.loginAs(world.superAdminUserId());
        var issue=new StockDocIssueBatchRequest();issue.setIdempotencyKey("counted-split-issue-"+segment);issue.setDocIds(first.documentIds());
        beans.getBean(StockDocService.class).issueFullBatch(issue);
        chain.loginAs(workerUser);
        segments.start(plan,first.batchSegmentId(),new SegmentTransitionRequest(version(first.batchSegmentId()),"counted-split-start-"+segment));
        UUID earlier=splitReport(c,first.batchSegmentId(),"20",demand,"0.25",null);
        chain.loginAs(world.superAdminUserId());
        reports.approve(earlier,DailyReportApproveRequests.freshKey());
        qty("0.75",bookAvailable(demand));

        chain.loginAs(workerUser);
        var rest=batches.preview(new ProductionExecutionBatch.PreviewRequest(first.remainingSegmentId(),version(first.remainingSegmentId()),new BigDecimal("30")));
        var second=batches.submit(new ProductionExecutionBatch.SubmitRequest(rest.segmentId(),rest.expectedVersion(),rest.quantity(),
                rest.fingerprint(),"counted-split-second-"+segment));
        assertTrue(second.documentIds().isEmpty(),"the later batch continues on the earlier batch's material");
        segments.start(plan,second.batchSegmentId(),new SegmentTransitionRequest(version(second.batchSegmentId()),"counted-split-start-second-"+segment));
        // The report registered 0.4 as used; the worker counts 0.25 left and asks to return it.
        // The count, not the registered use, decides the consumption: 0.75 - 0.25 = 0.5.
        UUID later=splitReport(c,second.batchSegmentId(),"30",demand,"0.4","0.25");
        chain.loginAs(world.superAdminUserId());
        var sources=beans.getBean(ProductionMaterialReturnRequestService.class).sources(plan,first.batchSegmentId());
        assertFalse(sources.isEmpty());
        assertTrue(sources.stream().allMatch(source->source.returnBlockedReason()!=null),
                "the earlier batch's material may not go back to the warehouse");
        reports.approve(later,DailyReportApproveRequests.freshKey());

        var usage=reports.detail(later).getMaterialUsages().getFirst();
        qty("0.5",usage.getQtyBase());qty("0.25",usage.getCountedLeftoverQty());
        qty("0.5",db.queryForObject("""
                SELECT COALESCE(SUM(posting.qty_base),0) FROM production_material_settlement_postings posting
                JOIN production_material_settlement_events event ON event.id=posting.event_id
                WHERE event.daily_report_id=? AND event.event_type='POST' AND posting.settlement_type='CONSUMED'
                """,BigDecimal.class,later));
        qty("0.25",bookAvailable(demand));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_documents WHERE doc_type='WDRAW' AND plan_no=(SELECT bill_no FROM production_plans WHERE id=?) AND NOT is_deleted",
                Integer.class,plan),"material committed to the later batch stays in the workshop");
    }

    private UUID splitReport(Object c,UUID segment,String quantity,UUID demand,String used,String counted){
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(c,"world");
        UUID workshop=ReflectionTestUtils.invokeMethod(c,"workshop"),worker=ReflectionTestUtils.invokeMethod(c,"worker");
        var request=new DailyReportSaveRequest();request.setIdempotencyKey("counted-split-report-"+UUID.randomUUID());
        request.setBillDate(BusinessTime.today());request.setDepartmentId(workshop);request.setWorkerIds(List.of(worker));
        var item=new DailyReportItemLine();item.setLineNo(1);item.setExecutionSegmentId(segment);
        item.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,segment));
        item.setGoodsId(ReflectionTestUtils.invokeMethod(c,"root"));item.setUnitId(world.unitId());
        item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal(quantity));
        request.setItems(List.of(item));
        var use=new DailyReportMaterialUsageLine();use.setDemandId(demand);use.setQtyBase(new BigDecimal(used));
        if(counted!=null){use.setCountedLeftoverQty(new BigDecimal(counted));request.setSurplusReturnRequested(true);}
        request.setMaterialLines(List.of(use));
        return reports.create(request).getId();
    }
    private long version(UUID segment){
        return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);
    }

    private DailyReportSaveRequest lastReport(Object task,String countedLeftover){
        DailyReportSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"reportRequest",task,source(task),"6","5.9");
        request.getItems().getFirst().setIsFinal(true);request.setSurplusReturnRequested(true);
        request.getMaterialLines().getFirst().setCountedLeftoverQty(new BigDecimal(countedLeftover));
        return request;
    }
    private ReportablePlanLine source(Object task){
        List<ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(fixture,"sources",task);
        return sources.getFirst();
    }
    private BigDecimal bookAvailable(UUID demand){
        return db.queryForObject("""
                SELECT COALESCE(SUM(fn_material_issue_available(id,NULL)),0) FROM production_material_stock_postings
                WHERE demand_id=? AND posting_type='ISSUE'
                """,BigDecimal.class,demand);
    }
    private static void qty(String expected,BigDecimal actual){
        assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+" but was "+actual);
    }
}
