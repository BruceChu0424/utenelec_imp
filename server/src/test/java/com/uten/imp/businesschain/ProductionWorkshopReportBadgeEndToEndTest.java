package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.*;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.nio.file.*;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;

/** Real approval of six fully reported products plus one partial product; list, count and badge facts share employee scope. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
"spring.profiles.active=dev","uten.audit.retention.enabled=false",
"uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
"uten.workshop-material.auto-close.enabled=false","uten.policy-intelligence.enabled=false",
"uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
"uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
"uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
"uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
"uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=ProductionWorkshopReportBadgeEndToEndTest.Cleanup.class,
 mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class ProductionWorkshopReportBadgeEndToEndTest {
 private static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine");
 @DynamicPropertySource static void database(DynamicPropertyRegistry registry){
  DATABASE.start();registry.add("spring.datasource.url",DATABASE::getJdbcUrl);
  registry.add("spring.datasource.username",DATABASE::getUsername);registry.add("spring.datasource.password",DATABASE::getPassword);
  try{Path attachments=Files.createTempDirectory("uten-workshop-report-badge-");registry.add("uten.storage.local-dir",attachments::toString);}
  catch(java.io.IOException error){throw new IllegalStateException(error);}
 }
 public static class Cleanup extends AbstractTestExecutionListener{
  @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
  @Override public void afterTestClass(TestContext ignored){DATABASE.stop();}
 }
 @Autowired AutowireCapableBeanFactory beans;
 @Autowired JdbcTemplate db;
 @Autowired MockMvc http;
 @Autowired ObjectMapper json;
 @Autowired MaterialAnalysisService analyses;
 @Autowired MaterialAnalysisCommandService commands;
 @Autowired ProductionExecutionSegmentService segments;
 @Autowired ProductionOverproductionRateService productionRates;
 @Autowired ProductionDrawRequestService draws;
 @Autowired ProductionDailyReportService reports;
 @Autowired ReportablePlanLineQueryService reportable;
 @Autowired StockDocService stock;
 static final BigDecimal QTY=new BigDecimal("5000");
 static final String OUTPUT=System.getProperty("uten.badge.diagnostic.directory");
 @AfterEach void clear(){SecurityContextHolder.clearContext();}
 record Case(DailyReportSaveRequest request,FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,List<UUID> segmentIds,UUID workshop,UUID readerUser){}

 @Test void normalApprovalSixFullyReportedOnePartialListCountAndRealContributionStayConsistent() throws Exception {
  var c=prepareSevenSources();
  c.fixture().loginAs(c.readerUser());
  Authentication actor=SecurityContextHolder.getContext().getAuthentication();
  phase("started",actor,c,0,7);
  c.fixture().loginAs(c.world().superAdminUserId());
  UUID report=reports.create(c.request()).getId();
  phase("unapproved-draft",actor,c,0,7);
  c.fixture().loginAs(c.world().superAdminUserId());
  reports.approve(report,DailyReportApproveRequests.freshKey());
  phase("approved-six-full-one-partial",actor,c,6,1);
  c.fixture().loginAs(c.world().superAdminUserId());
  reports.reverse(report);
  phase("reversed",actor,c,0,7);
  c.fixture().loginAs(c.world().superAdminUserId());
  UUID other=c.fixture().createUserWithPerms(c.world(),"other-badge-"+UUID.randomUUID().toString().substring(0,8),"production_execution:view");
  c.fixture().loginAs(other);
  Authentication otherActor=SecurityContextHolder.getContext().getAuthentication();
  assertEquals(0,getJson("/api/production/workshop-tasks/count",otherActor).path("count").asLong());
  assertEquals(0,getJson("/api/production/workshop-tasks?status=IN_PROGRESS",otherActor).path("total").asLong());
  assertEquals(0,getJson("/api/workbench/badges",otherActor).path("facts").path("workshopTask.count").asLong());
  c.fixture().loginAs(c.world().superAdminUserId());
  UUID noPermissions=c.fixture().createUserWithPerms(c.world(),"no-badge-"+UUID.randomUUID().toString().substring(0,8));
  c.fixture().loginAs(noPermissions);
  Authentication denied=SecurityContextHolder.getContext().getAuthentication();
  assertEquals(403,http.perform(get("/api/production/workshop-tasks/count").with(authentication(denied))).andReturn().getResponse().getStatus());
  JsonNode noPerm=getJson("/api/workbench/badges",denied);
  assertFalse(noPerm.path("facts").has("workshopTask.count"));
  assertFalse(noPerm.path("entries").has("productionWorkshop"));
 }
 private void phase(String name,Authentication actor,Case c,int full,int partial)throws Exception{
  JsonNode count=getJson("/api/production/workshop-tasks/count",actor);
  JsonNode badge=getJson("/api/workbench/badges",actor);
  Map<String,Object> evidence=new LinkedHashMap<>(); evidence.put("phase",name);
  evidence.put("count",count);evidence.put("badgeGeneratedAt",badge.path("generatedAt"));evidence.put("facts",badge.path("facts"));
  evidence.put("staleSources",badge.path("staleSources"));evidence.put("productionWorkshop",badge.path("entries").path("productionWorkshop"));
  evidence.put("segments",db.queryForList("SELECT task.segment_id,task.segment_code,task.segment_status,task.planned_qty,task.reported_qty,task.remaining_qty,task.inbound_qty,segment.allowed_overproduction_rate,task.planned_qty*(1+segment.allowed_overproduction_rate) AS allowed_report_cap_qty FROM v_production_execution_workbench_segments task JOIN production_execution_segments segment ON segment.id=task.segment_id WHERE task.segment_id IN ("+String.join(",",Collections.nCopies(c.segmentIds().size(),"?"))+") ORDER BY task.segment_code",c.segmentIds().toArray()));
  Map<String,JsonNode> lists=new LinkedHashMap<>();
  for(String bucket:List.of("PREPARING","IN_PROGRESS","REPORT_INSPECTION"))lists.put(bucket,getJson("/api/production/workshop-tasks?size=200&status="+bucket,actor));
  evidence.put("lists",lists);
  if(OUTPUT!=null&&!OUTPUT.isBlank()){Path out=Path.of(OUTPUT);Files.createDirectories(out);json.writerWithDefaultPrettyPrinter().writeValue(out.resolve(name+".json").toFile(),evidence);}
  for(UUID segment:c.segmentIds()){
   quantity(new BigDecimal(".1"),db.queryForObject("SELECT allowed_overproduction_rate FROM production_execution_segments WHERE id=?",BigDecimal.class,segment));
   quantity(new BigDecimal("5500"),db.queryForObject("SELECT planned_qty*(1+allowed_overproduction_rate) FROM production_execution_segments WHERE id=?",BigDecimal.class,segment));
  }
  for(String key:List.of("count","preparing","inProgress","reportInspection"))assertEquals(count.path(key).asLong(),badge.path("facts").path("workshopTask."+key).asLong(),name+" fact "+key);
  assertEquals(count.path("preparing").asLong(),badge.path("entries").path("productionWorkshop").path("todo").asLong());
  assertEquals(count.path("inProgress").asLong()+count.path("reportInspection").asLong(),badge.path("entries").path("productionWorkshop").path("inProgress").asLong());
  for(JsonNode source:badge.path("staleSources"))assertNotEquals("workshopTask",source.asText());
  Map<String,String> field=Map.of("PREPARING","preparing","IN_PROGRESS","inProgress","REPORT_INSPECTION","reportInspection");
  for(var entry:lists.entrySet())assertEquals(count.path(field.get(entry.getKey())).asLong(),entry.getValue().path("total").asLong(),name+" list total "+entry.getKey());
  assertEquals(full,ownRows(lists.get("REPORT_INSPECTION"),c));assertEquals(partial,ownRows(lists.get("IN_PROGRESS"),c));
  System.out.println("ISOLATED-WORKSHOP-PHASE "+name+" count="+count+" ownFull="+full+" ownPartial="+partial);
 }
 private long ownRows(JsonNode list,Case c){long found=0;for(JsonNode row:list.path("items"))if(c.segmentIds().stream().anyMatch(id->id.toString().equals(row.path("segmentId").asText())))found++;return found;}
 private JsonNode getJson(String path,Authentication actor)throws Exception{var response=http.perform(get(path).with(authentication(actor))).andReturn().getResponse();assertEquals(200,response.getStatus(),path+" "+response.getContentAsString());return json.readTree(response.getContentAsByteArray());}
 private long version(UUID segment){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
 private static void quantity(BigDecimal expected,BigDecimal actual){assertEquals(0,expected.compareTo(actual));}
    private Case prepareSevenSources() {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        String tag="badge-seven-"+UUID.randomUUID().toString().substring(0,8);
        var world=fixture.seedWorld(tag);fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");
        UUID readerUser=fixture.createUserWithPerms(world,"badge-worker-"+tag,"production_execution:view");
        UUID worker=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,readerUser);
        db.update("UPDATE employees SET department_id=? WHERE id=?",workshop,worker);
        List<PreviewItem> sources=new ArrayList<>();List<StockDocItemLine> inputs=new ArrayList<>();List<UUID> products=new ArrayList<>();
        for(int index=0;index<7;index++) {
            UUID product=UUID.randomUUID(),material=UUID.randomUUID();products.add(product);
            fixture.insertGoods(product,"COMPLEX-P-"+product,"多来源成品 "+index,"自制",world.unitId(),world.unitLegacy());
            fixture.insertGoods(material,"COMPLEX-M-"+material,"多来源原料 "+index,"采购",world.unitId(),world.unitLegacy());
            fixture.insertBom(product,material,"1");
            UUID order=fixture.createApprovedOrder(world,product,"5000","100");
            UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
            sources.add(new PreviewItem("SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),QTY));
            var opening=new StockDocItemLine();opening.setGoodsId(material);opening.setUnitId(world.unitId());opening.setUnitRate(BigDecimal.ONE);
            opening.setQty(QTY);opening.setPrice(BigDecimal.TEN);opening.setAmountOriginal(QTY.multiply(BigDecimal.TEN));opening.setAmountLocal(QTY.multiply(BigDecimal.TEN));inputs.add(opening);
        }
        var inbound=new StockDocSaveRequest();inbound.setDocType("OTHER_IN");inbound.setBillDate(BusinessTime.today());
        inbound.setWarehouseId(world.warehouseId());inbound.setItems(inputs);stock.approve(stock.create(inbound).getId());
        var view=analyses.preview(new PreviewRequest(null,null,null,world.warehouseId(),"complex-preview-"+tag,sources));
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"complex-routes-"+tag,
                view.flatMaterials().stream().filter(MaterialView::actionable).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),products.contains(row.goodsId())?"MAKE":"BUY",null)).toList()));
        view=analyses.detail(view.analysisId());
        var issue=new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"complex-plans-"+tag,world.warehouseId(),
                BusinessTime.today(),BusinessTime.today().plusDays(10),true,view.products().stream().map(root->
                new IssueWorkshopPlansRequest.IssuePlanLine(null,root.analysisLineId(),QTY,null,null,workshop,null,worker,null,null,false)).toList());
        var planned=commands.issueWorkshopPlans(view.analysisId(),issue);assertEquals(7,planned.plans().size());
        List<UUID> segmentIds=new ArrayList<>();
        for(var plan:planned.plans()) {
            UUID segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",UUID.class,plan.planId());
            segmentIds.add(segment);segments.confirmRoute(plan.planId(),segment,new SegmentRouteConfirmRequest(version(segment),"complex-route-"+segment,"CONTINUOUS"));
        }
        var tasks=segmentIds.stream().map(segment->new ProductionDrawRequest.Item(segment,version(segment))).toList();
        var preview=draws.preview(new ProductionDrawRequest.PreviewRequest(tasks));assertEquals(7,preview.lines().size());
        draws.submit(new ProductionDrawRequest.SubmitRequest(tasks,"complex-draw-"+tag,preview.fingerprint()));
        for(UUID document:preview.lines().stream().map(ProductionDrawRequest.Line::drawId).distinct().toList()) {
            var request=new StockDocIssueRequest();request.setIdempotencyKey("complex-issue-"+document);
            request.setLines(preview.lines().stream().filter(line->document.equals(line.drawId())).map(line->{
                var item=new StockDocIssueRequest.Line();item.setItemId(line.drawItemId());item.setQty(line.qty());return item;}).toList());
            stock.approveAndIssue(document,request);
        }
        for(UUID segment:segmentIds){
            var initialRate=productionRates.context(segment);
            if(initialRate.effectiveRate().compareTo(new BigDecimal(".1"))!=0){
                var rate=productionRates.submit(new ProductionOverproductionRateContracts.SubmitRequest(segment,initialRate.rateVersion(),new BigDecimal(".1"),
                        "真实车间报工分类回归：计划审批允许超产百分之十","badge-rate-"+segment));
                productionRates.decide(rate.id(),new ProductionOverproductionRateContracts.DecisionRequest(rate.rowVersion(),"badge-rate-approve-"+rate.id(),null),true);
            }
            quantity(new BigDecimal("5000"),productionRates.context(segment).plannedQty());
            quantity(new BigDecimal("5500"),productionRates.context(segment).limitQty());
        }
        for(UUID segment:segmentIds)segments.start(db.queryForObject("SELECT plan_id FROM production_execution_segments WHERE id=?",UUID.class,segment),segment,
                new SegmentTransitionRequest(version(segment),"complex-start-"+segment));
        var available=reportable.list(1,100,null,workshop,segmentIds).getItems();assertEquals(7,available.size());
        var request=new DailyReportSaveRequest();request.setIdempotencyKey("complex-report-"+UUID.randomUUID());request.setBillDate(BusinessTime.today());
        request.setDepartmentId(workshop);request.setWorkerIds(List.of(worker));
        List<DailyReportItemLine> items=new ArrayList<>();List<DailyReportMaterialUsageLine> uses=new ArrayList<>();
        for(var source:available) {
            var item=new DailyReportItemLine();item.setLineNo(items.size()+1);item.setPlanItemId(source.planItemId());item.setExecutionSegmentId(source.executionSegmentId());
            item.setExecutionSegmentSalesAllocationId(source.executionSegmentSalesAllocationId());item.setSalesOrderItemId(source.orderItemId());
            item.setGoodsId(source.goodsId());item.setUnitId(world.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(items.size()==6?new BigDecimal("2500"):QTY);items.add(item);
            UUID demand=db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,source.executionSegmentId());
            quantity(QTY,db.queryForObject("SELECT COALESCE(SUM(fn_material_issue_available(id,NULL)),0) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",BigDecimal.class,demand));
            var use=new DailyReportMaterialUsageLine();use.setDemandId(demand);use.setQtyBase(uses.size()==6?new BigDecimal("2500"):QTY);uses.add(use);
        }
        request.setItems(items);request.setMaterialLines(uses);return new Case(request,fixture,world,segmentIds,workshop,readerUser);
    }

}
