package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.notice.outbox.BusinessOutboxScheduler;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;

/** Real multi-source material settlement and multi-receiver inventory/valuation workload. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@EnabledIfEnvironmentVariable(named="UTEN_RUN_PRODUCTION_STRESS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.workshop-material.auto-close.enabled=false",
        "uten.concurrency.verify-nested-footprint=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=false","uten.inventory.value-work-initial-delay-ms=3600000"})
@Import(ProductionJdbcMeasurement.Configuration.class)
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=DailyReportComplexPerformancePostgresTest.Cleanup.class,
        mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class DailyReportComplexPerformancePostgresTest {
    private static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine")
            .withCommand("postgres","-c","fsync=on","-c","synchronous_commit=on","-c","full_page_writes=on");
    private static final String SECRET=UUID.randomUUID()+"-"+UUID.randomUUID();
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        DATABASE.start();properties.add("spring.datasource.url",DATABASE::getJdbcUrl);
        properties.add("spring.datasource.username",DATABASE::getUsername);properties.add("spring.datasource.password",DATABASE::getPassword);
        properties.add("uten.jwt.secret",()->SECRET);properties.add("uten.crypto.pgp-master-key",()->SECRET);
        properties.add("uten.crypto.hmac-key",()->SECRET);properties.add("uten.bootstrap.admin-login",()->"report-complex-perf-bootstrap");
        properties.add("uten.bootstrap.admin-password",()->SECRET+"Aa1!");
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored){DATABASE.stop();}
    }
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProductionDailyReportService reports;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionDrawRequestService draws;
    @Autowired StockDocService stock;
    @Autowired ReportablePlanLineQueryService reportable;
    @Autowired BusinessOutboxScheduler outbox;
    @Autowired com.uten.imp.features.stock.valuation.InventoryValueWorkService valueWork;
    @Autowired com.uten.imp.application.concurrency.FulfillmentMutationLocks fulfillmentLocks;
    @Autowired org.springframework.core.env.Environment environment;
    @BeforeEach void quietOutbox(){
        outbox.close();
        assertEquals(Boolean.FALSE,ReflectionTestUtils.getField(fulfillmentLocks,"verifyNestedFootprint"));
        assertFalse(environment.getProperty("uten.concurrency.verify-nested-footprint",Boolean.class,true));
    }
    @AfterEach void cleanup(){ProductionJdbcMeasurement.end();SecurityContextHolder.clearContext();}

    @Test void tenDistinctSourcesMeasureCreateApproveAndReplayWithActualMaterialSettlement() throws Exception {
        for(int repetition=0;repetition<repetitions();repetition++) {
            DailyReportSaveRequest request=prepareTenSources();
            var goods=new java.util.LinkedHashSet<>(request.getItems().stream().map(DailyReportItemLine::getGoodsId).toList());
            String demands=String.join(",",request.getMaterialLines().stream().map(row->row.getDemandId().toString()).toList());
            goods.addAll(db.queryForList("SELECT goods_id FROM production_material_demands WHERE id=ANY(string_to_array(?,',')::uuid[])",UUID.class,demands));
            InventoryValueWorkTestSupport.drain(valueWork,db,List.copyOf(goods));
            byte[] frozen=json.writeValueAsBytes(request);
            var created=measure("report-ten-segments-create",repetition,()->reports.create(request));
            assertEquals(10,created.getItems().size());
            assertEquals(10,created.getItems().stream().map(DailyReportItemDto::getExecutionSegmentId).distinct().count());
            var approval=new DailyReportApproveRequest();approval.setIdempotencyKey("complex-approve-"+created.getId());
            measure("report-ten-segments-approve",repetition,()->reports.approve(created.getId(),approval));
            assertEquals(1,db.queryForObject("SELECT status FROM production_daily_reports WHERE id=?",Integer.class,created.getId()));
            for(var item:created.getItems()) {
                quantity(BigDecimal.ONE,db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=?",BigDecimal.class,item.getPlanItemId()));
                quantity(BigDecimal.ZERO,db.queryForObject("SELECT produced_qty FROM sales_order_items WHERE id=?",BigDecimal.class,item.getSalesOrderItemId()));
                quantity(BigDecimal.ONE,db.queryForObject("SELECT produced_qty FROM plan_order_item_links WHERE plan_item_id=? AND order_item_id=? AND NOT is_deleted",
                        BigDecimal.class,item.getPlanItemId(),item.getSalesOrderItemId()));
            }
            for(var usage:request.getMaterialLines()) {
                quantity(BigDecimal.ONE,db.queryForObject("""
                        SELECT COALESCE(SUM(CASE WHEN event.event_type='POST' THEN posting.qty_base ELSE -posting.qty_base END),0)
                        FROM production_material_settlement_postings posting
                        JOIN production_material_settlement_events event ON event.id=posting.event_id
                        WHERE event.daily_report_id=? AND posting.demand_id=? AND posting.settlement_type='CONSUMED'
                        """,BigDecimal.class,created.getId(),usage.getDemandId()));
            }
            var facts=facts(created.getId());
            var replay=json.readValue(frozen,DailyReportSaveRequest.class);
            assertEquals(created.getId(),measure("report-ten-segments-create-replay",repetition,()->reports.create(replay)).getId());
            measure("report-ten-segments-approve-replay",repetition,()->reports.approve(created.getId(),approval));
            assertEquals(facts,facts(created.getId()));
        }
    }

    @Test void elevenDirectReceiversIncludeRealStockCostAndExactHandoverSources() throws Exception {
        for(int repetition=0;repetition<repetitions();repetition++) {
            var prepared=ControlledDailyReportInputs.prepare(beans,db,11,"complex-"+UUID.randomUUID());
            InventoryValueWorkTestSupport.drain(valueWork,db,List.copyOf(prepared.goodsIds()));
            assertEquals(11,db.queryForObject("SELECT count(*) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",Integer.class,prepared.reportId()));
            measure("report-eleven-receivers-approve",repetition,prepared.command());
            prepared.verify().run();
            var facts=facts(prepared.reportId());
            measure("report-eleven-receivers-approve-replay",repetition,prepared.command());
            prepared.verify().run();assertEquals(facts,facts(prepared.reportId()));
        }
    }

    private DailyReportSaveRequest prepareTenSources() {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        String tag="complex-ten-"+UUID.randomUUID().toString().substring(0,8);
        var world=fixture.seedWorld(tag);fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId"),worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        List<PreviewItem> sources=new ArrayList<>();List<StockDocItemLine> inputs=new ArrayList<>();List<UUID> products=new ArrayList<>();
        for(int index=0;index<10;index++) {
            UUID product=UUID.randomUUID(),material=UUID.randomUUID();products.add(product);
            fixture.insertGoods(product,"COMPLEX-P-"+product,"多来源成品 "+index,"自制",world.unitId(),world.unitLegacy());
            fixture.insertGoods(material,"COMPLEX-M-"+material,"多来源原料 "+index,"采购",world.unitId(),world.unitLegacy());
            fixture.insertBom(product,material,"1");
            UUID order=fixture.createApprovedOrder(world,product,"1","100");
            UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
            sources.add(new PreviewItem("SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),BigDecimal.ONE));
            var opening=new StockDocItemLine();opening.setGoodsId(material);opening.setUnitId(world.unitId());opening.setUnitRate(BigDecimal.ONE);
            opening.setQty(BigDecimal.ONE);opening.setPrice(BigDecimal.TEN);opening.setAmountOriginal(BigDecimal.TEN);opening.setAmountLocal(BigDecimal.TEN);inputs.add(opening);
        }
        var inbound=new StockDocSaveRequest();inbound.setDocType("OTHER_IN");inbound.setBillDate(BusinessTime.today());
        inbound.setWarehouseId(world.warehouseId());inbound.setItems(inputs);stock.approve(stock.create(inbound).getId());
        var view=analyses.preview(new PreviewRequest(null,null,null,world.warehouseId(),"complex-preview-"+tag,sources));
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"complex-routes-"+tag,
                view.flatMaterials().stream().filter(MaterialView::actionable).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),products.contains(row.goodsId())?"MAKE":"BUY",null)).toList()));
        view=analyses.detail(view.analysisId());
        var issue=new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"complex-plans-"+tag,world.warehouseId(),
                BusinessTime.today(),BusinessTime.today().plusDays(10),true,view.products().stream().map(root->
                new IssueWorkshopPlansRequest.IssuePlanLine(null,root.analysisLineId(),BigDecimal.ONE,null,null,workshop,null,worker,null,null,false)).toList());
        var planned=commands.issueWorkshopPlans(view.analysisId(),issue);assertEquals(10,planned.plans().size());
        List<UUID> segmentIds=new ArrayList<>();
        for(var plan:planned.plans()) {
            UUID segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",UUID.class,plan.planId());
            segmentIds.add(segment);segments.confirmRoute(plan.planId(),segment,new SegmentRouteConfirmRequest(version(segment),"complex-route-"+segment,"CONTINUOUS"));
        }
        var tasks=segmentIds.stream().map(segment->new ProductionDrawRequest.Item(segment,version(segment))).toList();
        var preview=draws.preview(new ProductionDrawRequest.PreviewRequest(tasks));assertEquals(10,preview.lines().size());
        draws.submit(new ProductionDrawRequest.SubmitRequest(tasks,"complex-draw-"+tag,preview.fingerprint()));
        for(UUID document:preview.lines().stream().map(ProductionDrawRequest.Line::drawId).distinct().toList()) {
            var request=new StockDocIssueRequest();request.setIdempotencyKey("complex-issue-"+document);
            request.setLines(preview.lines().stream().filter(line->document.equals(line.drawId())).map(line->{
                var item=new StockDocIssueRequest.Line();item.setItemId(line.drawItemId());item.setQty(line.qty());return item;}).toList());
            stock.approveAndIssue(document,request);
        }
        for(UUID segment:segmentIds)segments.start(db.queryForObject("SELECT plan_id FROM production_execution_segments WHERE id=?",UUID.class,segment),segment,
                new SegmentTransitionRequest(version(segment),"complex-start-"+segment));
        var available=reportable.list(1,100,null,workshop,segmentIds).getItems();assertEquals(10,available.size());
        var request=new DailyReportSaveRequest();request.setIdempotencyKey("complex-report-"+UUID.randomUUID());request.setBillDate(BusinessTime.today());
        request.setDepartmentId(workshop);request.setWorkerIds(List.of(worker));
        List<DailyReportItemLine> items=new ArrayList<>();List<DailyReportMaterialUsageLine> uses=new ArrayList<>();
        for(var source:available) {
            var item=new DailyReportItemLine();item.setLineNo(items.size()+1);item.setPlanItemId(source.planItemId());item.setExecutionSegmentId(source.executionSegmentId());
            item.setExecutionSegmentSalesAllocationId(source.executionSegmentSalesAllocationId());item.setSalesOrderItemId(source.orderItemId());
            item.setGoodsId(source.goodsId());item.setUnitId(world.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(BigDecimal.ONE);items.add(item);
            UUID demand=db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,source.executionSegmentId());
            quantity(BigDecimal.ONE,db.queryForObject("SELECT COALESCE(SUM(fn_material_issue_available(id,NULL)),0) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",BigDecimal.class,demand));
            var use=new DailyReportMaterialUsageLine();use.setDemandId(demand);use.setQtyBase(BigDecimal.ONE);uses.add(use);
        }
        request.setItems(items);request.setMaterialLines(uses);return request;
    }

    private <T>T measure(String phase,int repetition,Supplier<T> action)throws Exception {
        var sample=ProductionJdbcMeasurement.begin();long started=System.nanoTime();T result;long elapsed;
        try{result=action.get();}finally{elapsed=System.nanoTime()-started;ProductionJdbcMeasurement.end();}
        assertEquals(1,sample.commits);assertEquals(0,sample.rollbacks);
        Map<String,Object> record=new LinkedHashMap<>(sample.result());record.put("statementOrigins",sample.statementOrigins);
        record.put("phase",phase);record.put("repetition",repetition);record.put("elapsedMillis",elapsed/1_000_000.0);
        record.put("scope","real service and commit; real material/stock/cost sources; fixture, HTTP and outbox delivery excluded");
        record.put("sourceIdentity",System.getProperty("uten.perf.source-identity","unspecified"));
        record.put("diagnostic",System.getProperty("uten.jdbc.measurement.trace-directory")!=null);
        record.put("verifyNestedFootprint",environment.getProperty("uten.concurrency.verify-nested-footprint",Boolean.class));
        record.put("fixture",phase.startsWith("report-eleven")?"one manufactured child, eleven actual direct-transfer receivers, real issued and consumed raw materials":
                "ten products/materials/sales sources/plans/execution segments, same workshop, one real issued and consumed unit per source");
        record.put("backgroundWork","outbox dispatcher closed; audit retention, materialized view refresh, readiness reconcile, workshop auto-close and policy intelligence disabled; inventory value worker delayed one hour");
        record.put("initialCostSettlement","relevant input/output goods drained by the real value worker before measurement");
        record.put("databaseSettings",db.queryForMap("SELECT current_setting('fsync') AS fsync,current_setting('synchronous_commit') AS synchronous_commit,current_setting('full_page_writes') AS full_page_writes"));
        String output=System.getProperty("uten.perf.report-directory");if(output!=null&&!output.isBlank()){
            Files.createDirectories(Path.of(output));json.writerWithDefaultPrettyPrinter().writeValue(Path.of(output).resolve(phase+"-"+repetition+".json").toFile(),record);}
        System.out.println("REPORT-COMPLEX-PERF phase="+phase+" elapsedMillis="+elapsed/1_000_000.0+" jdbcCalls="+sample.jdbcCalls+" commitMillis="+sample.commitNanos/1_000_000.0);return result;
    }
    private Map<String,Object> facts(UUID report){return db.queryForMap("""
            SELECT (SELECT count(*) FROM production_daily_report_commands WHERE report_id=?) AS commands,
                   (SELECT count(*) FROM production_material_settlement_events WHERE daily_report_id=?) AS material_events,
                   (SELECT count(*) FROM stock_movements movement JOIN stock_documents document ON document.id=movement.source_doc_id WHERE document.source_daily_report_id=?) AS movements
            """,report,report,report);}
    private long version(UUID segment){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
    private static int repetitions(){return Integer.getInteger("uten.perf.repetitions",1);}
    private static void quantity(BigDecimal expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,expected.compareTo(actual));}
}
