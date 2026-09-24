package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.fulfillment.ProductionMaterialIncrementService;
import com.uten.imp.features.production.fulfillment.ProductionMaterialIncrementContracts.*;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.support.DailyReportApproveRequests;
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
class ProductionMaterialIncrementEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionMaterialIncrementService increments;
    WorkshopPublicSurplusEndToEndTest fixture;
    Object task; UUID segment,plan,demand;
    @BeforeEach void prepare(){
        fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();
        task=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","increment-"+UUID.randomUUID(),false,"100");
        segment=ReflectionTestUtils.invokeMethod(task,"segment");plan=ReflectionTestUtils.invokeMethod(task,"plan");demand=ReflectionTestUtils.invokeMethod(task,"demand");
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void ordinary110OutputCanReallyConsume130AfterPlanningApprovesOnly30ExtraMaterial(){
        var context=increments.context(segment);assertEquals(1,context.demands().size());
        var original=context.demands().getFirst();amount("100",original.requiredQty());amount("100",original.netIssuedQty());
        var command=new SubmitRequest(demand,segment,null,new BigDecimal("30"),"本批实际需要多投入30原料",original.lockVersion(),"material-submit-"+UUID.randomUUID());
        var pending=increments.submit(command);assertEquals("PENDING",pending.status());
        assertEquals(pending.id(),increments.submit(command).id());amount("100",originalQuantity());
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
        amount("100",pending.beforeSnapshot().path("items").get(0).path("authorizedQty").decimalValue());
        amount("130",pending.afterSnapshot().path("items").get(0).path("authorizedQty").decimalValue());
        amount("30",pending.afterSnapshot().path("items").get(0).path("approvedIncrementQty").decimalValue());
        var approval=new DecisionRequest(0L,"material-approve-"+UUID.randomUUID(),"核对实际用料后批准");
        var approved=increments.decide(pending.id(),approval,true);assertEquals("APPROVED",approved.status());assertNotNull(approved.authorizedDemandId());
        assertEquals(approved.authorizedDemandId(),increments.decide(pending.id(),approval,true).authorizedDemandId());
        amount("100",originalQuantity());amount("30",db.queryForObject("SELECT required_qty FROM production_material_demands WHERE id=?",BigDecimal.class,approved.authorizedDemandId()));
        amount("100",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,segment));
        issue(segment);
        amount("130",increments.context(segment).demands().getFirst().netIssuedQty());
        @SuppressWarnings("unchecked") List<ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(fixture,"sources",task);
        DailyReportSaveRequest report=ReflectionTestUtils.invokeMethod(fixture,"reportRequest",task,sources.getFirst(),"110","100");
        var extra=new DailyReportMaterialUsageLine();extra.setDemandId(approved.authorizedDemandId());extra.setQtyBase(new BigDecimal("30"));
        var usages=new ArrayList<>(report.getMaterialLines());usages.add(extra);report.setMaterialLines(usages);
        var reviewed=fixture.reports.approve(fixture.reports.create(report).getId(),DailyReportApproveRequests.freshKey());
        amount("110",reviewed.getItems().stream().map(DailyReportItemDto::getQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        amount("100",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,demand));
        amount("30",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,approved.authorizedDemandId()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_material_increment_decisions WHERE request_id=?",Integer.class,pending.id()));
        assertThrows(RuntimeException.class,()->db.update("UPDATE production_material_demands SET required_qty=31 WHERE id=?",approved.authorizedDemandId()));
    }

    @Test void returnAndPermissionFailuresDoNotCreateMaterialSupply(){
        var original=increments.context(segment).demands().getFirst();
        var pending=increments.submit(new SubmitRequest(demand,segment,null,BigDecimal.TEN,"申请实际补料",original.lockVersion(),"return-submit-"+UUID.randomUUID()));
        increments.decide(pending.id(),new DecisionRequest(0L,"return-review-"+UUID.randomUUID(),"先核对现场余料"),false);
        assertEquals("RETURNED",increments.detail(pending.id()).status());
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,segment));
        var admin=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var limited=new AuthUser(admin.getId(),admin.getEmployeeId(),admin.getUsername(),Set.of("production_execution:view","production_daily_report:create"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(limited,null,limited.getAuthorities()));
        assertThrows(ApiException.class,()->increments.submit(new SubmitRequest(demand,segment,null,BigDecimal.TEN,"未授权申请",original.lockVersion(),"denied-submit-"+UUID.randomUUID())));
        assertThrows(ApiException.class,increments::count);amount("100",originalQuantity());
    }

    @Test void reviewedSupplementCanIssueOnlyItsAuthorized30AndConsumeTheShared100ExactlyOnce(){
        @SuppressWarnings("unchecked") List<ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(fixture,"sources",task);
        DailyReportSaveRequest report=ReflectionTestUtils.invokeMethod(fixture,"reportRequest",task,sources.getFirst(),"130","100");
        var preview=fixture.supplements.previewReport(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.ReportPreviewRequest(report,null));
        var created=fixture.supplements.create(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.CreateRequest(
                segment,new BigDecimal("130"),sources.getFirst().executionSegmentSalesAllocationId(),preview.lines().getFirst().fingerprint(),
                com.uten.imp.common.time.BusinessTime.today(),com.uten.imp.common.time.BusinessTime.today().plusDays(1),
                "额外30独立计划，原料亦需增加30","supplement-material-"+UUID.randomUUID(),null,report,0));
        fixture.productionPlans.approve(created.planId());var supplement=fixture.supplements.detail(created.id());
        var context=increments.context(supplement.supplementSegmentId());assertEquals(supplement.proofId(),context.supplementProofId());
        assertEquals(demand,context.demands().getFirst().originalDemandId());
        assertThrows(ApiException.class,()->increments.submit(new SubmitRequest(demand,supplement.supplementSegmentId(),null,BigDecimal.TEN,
                "不能省略追加证明",context.demands().getFirst().lockVersion(),"no-proof-"+UUID.randomUUID())));
        var pending=increments.submit(new SubmitRequest(demand,supplement.supplementSegmentId(),supplement.proofId(),new BigDecimal("30"),
                "追加产出所需真实增量材料",context.demands().getFirst().lockVersion(),"supplement-delta-"+UUID.randomUUID()));
        var approved=increments.decide(pending.id(),new DecisionRequest(0L,"supplement-delta-approve-"+UUID.randomUUID(),null),true);
        issue(supplement.supplementSegmentId());
        long version=db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,supplement.supplementSegmentId());
        fixture.segments.start(supplement.planId(),supplement.supplementSegmentId(),new SegmentTransitionRequest(version,"supplement-material-start-"+UUID.randomUUID()));
        report.getItems().getFirst().setSupplementProofId(supplement.proofId());
        var delta=new DailyReportMaterialUsageLine();delta.setDemandId(approved.authorizedDemandId());delta.setQtyBase(new BigDecimal("30"));
        var usages=new ArrayList<>(report.getMaterialLines());usages.add(delta);report.setMaterialLines(usages);
        var reviewed=fixture.reports.approve(fixture.reports.create(report).getId(),DailyReportApproveRequests.freshKey());
        amount("130",reviewed.getItems().stream().map(DailyReportItemDto::getQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        amount("100",originalQuantity());
        amount("100",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,demand));
        amount("30",db.queryForObject("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,approved.authorizedDemandId()));
        amount("130",db.queryForObject("SELECT fn_production_execution_cost_target(?)",BigDecimal.class,segment));
        assertEquals(segment,db.queryForObject("SELECT fn_production_execution_cost_scope(?)",UUID.class,supplement.supplementSegmentId()));
    }

    @Test void cancellingOneIncrementWithdrawsOnlyItsLineFromASharedDraw(){
        stockMove("OTHER_OUT","1900");
        var first=approveIncrement("30");var second=approveIncrement("20");
        stockMove("OTHER_IN","50");
        UUID firstItem=drawItem(first.authorizedDemandId()),secondItem=drawItem(second.authorizedDemandId());
        assertEquals(db.queryForObject("SELECT doc_id FROM stock_document_items WHERE id=?",UUID.class,firstItem),
                db.queryForObject("SELECT doc_id FROM stock_document_items WHERE id=?",UUID.class,secondItem));
        var command=new DecisionRequest(first.rowVersion(),"cancel-increment-"+UUID.randomUUID(),"实际复核不再需要这一份30补料");
        assertTrue(increments.detail(first.id()).canCancel());assertEquals("CANCELLED",increments.cancel(first.id(),command).status());
        assertEquals("CANCELLED",increments.cancel(first.id(),command).status());
        amount("0",db.queryForObject("SELECT fn_production_draw_item_effective_qty(?)",BigDecimal.class,firstItem));
        amount("20",db.queryForObject("SELECT fn_production_draw_item_effective_qty(?)",BigDecimal.class,secondItem));
        amount("30",db.queryForObject("SELECT qty FROM stock_document_items WHERE id=?",BigDecimal.class,firstItem));
        amount("20",increments.context(segment).demands().getFirst().approvedIncrementQty());amount("100",originalQuantity());
        assertEquals("RELEASED",db.queryForObject("SELECT status FROM production_material_demands WHERE id=?",String.class,first.authorizedDemandId()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_material_increment_reversals WHERE request_id=?",Integer.class,first.id()));
    }

    @Test void issuedMaterialMustActuallyReturnBeforeCancellingItsAuthorityAndCannotBeRestoredAfterwards(){
        var approved=approveIncrement("30");issue(segment);
        assertFalse(increments.detail(approved.id()).canCancel());
        assertThrows(ApiException.class,()->increments.cancel(approved.id(),new DecisionRequest(1L,"cancel-held-"+UUID.randomUUID(),"尚未退回不可撤销")));
        var returns=beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService.class);
        var source=returns.sources(plan,segment).stream().filter(item->approved.authorizedDemandId().equals(item.demandId())).findFirst().orElseThrow();
        var submitted=returns.submit(plan,new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Submit(
                segment,"return-increment-"+UUID.randomUUID(),"全部补料实物退仓",List.of(new com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("30"))))).getFirst();
        assertFalse(increments.detail(approved.id()).canCancel());
        fixture.stock.approve(submitted.documentId());
        assertTrue(increments.detail(approved.id()).canCancel());
        increments.cancel(approved.id(),new DecisionRequest(1L,"cancel-returned-"+UUID.randomUUID(),"补料已全部真实退回，撤销授权"));
        amount("30",db.queryForObject("SELECT qty_base FROM production_material_stock_postings WHERE id=?",BigDecimal.class,source.issuePostingId()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_material_stock_postings WHERE source_posting_id=? AND posting_type='GOOD_RETURN'",Integer.class,source.issuePostingId()));
        assertThrows(RuntimeException.class,()->fixture.stock.reverse(submitted.documentId()),"撤销后不得反退料把已取消授权的实物放回车间");
        amount("0",increments.context(segment).demands().getFirst().approvedIncrementQty());amount("100",originalQuantity());
    }

    private RequestView approveIncrement(String qty){
        var context=increments.context(segment).demands().getFirst();
        var pending=increments.submit(new SubmitRequest(demand,segment,null,new BigDecimal(qty),"真实增量原料需求",context.lockVersion(),"increment-"+UUID.randomUUID()));
        return increments.decide(pending.id(),new DecisionRequest(0L,"approve-"+UUID.randomUUID(),null),true);
    }
    private UUID drawItem(UUID demandId){return db.queryForObject("SELECT document_item_id FROM production_planning_package_document_items WHERE demand_id=? AND document_type='DRAW'",UUID.class,demandId);}
    private void stockMove(String type,String qty){
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(task,"world");UUID material=ReflectionTestUtils.invokeMethod(task,"material");
        var request=new com.uten.imp.features.stock.dto.StockDocSaveRequest();request.setDocType(type);request.setWarehouseId(world.warehouseId());request.setBillDate(com.uten.imp.common.time.BusinessTime.today());
        var item=new com.uten.imp.features.stock.dto.StockDocItemLine();item.setGoodsId(material);item.setUnitId(world.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(new BigDecimal(qty));
        if("OTHER_IN".equals(type)){item.setPrice(BigDecimal.TEN);item.setAmountOriginal(new BigDecimal(qty).multiply(BigDecimal.TEN));item.setAmountLocal(new BigDecimal(qty).multiply(BigDecimal.TEN));}
        request.setItems(List.of(item));fixture.stock.approve(fixture.stock.create(request).getId());
    }

    private void issue(UUID id){
        long version=db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,id);
        var tasks=List.of(new ProductionDrawRequest.Item(id,version));var preview=fixture.drawRequests.preview(new ProductionDrawRequest.PreviewRequest(tasks));
        assertFalse(preview.lines().isEmpty());
        amount("30",preview.lines().stream().map(ProductionDrawRequest.Line::qty).reduce(BigDecimal.ZERO,BigDecimal::add));
        fixture.drawRequests.submit(new ProductionDrawRequest.SubmitRequest(tasks,"increment-draw-"+UUID.randomUUID(),preview.fingerprint()));
        for(UUID document:preview.lines().stream().map(ProductionDrawRequest.Line::drawId).distinct().toList()){
            var command=new StockDocIssueRequest();command.setIdempotencyKey("increment-issue-"+UUID.randomUUID());
            command.setLines(preview.lines().stream().filter(line->document.equals(line.drawId())).map(line->{
                var item=new StockDocIssueRequest.Line();item.setItemId(line.drawItemId());item.setQty(line.qty());return item;}).toList());
            fixture.stock.approveAndIssue(document,command);
        }
    }
    private BigDecimal originalQuantity(){return db.queryForObject("SELECT required_qty FROM production_material_demands WHERE id=?",BigDecimal.class,demand);}
    private static void amount(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual));}
}
