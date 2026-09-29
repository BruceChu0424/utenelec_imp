package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
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

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionPlannedOverproductionAllowanceEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionPlanService plans;
    @Autowired com.uten.imp.features.production.execution.ProductionOverproductionRateService rates;
    @Autowired com.uten.imp.features.production.mrp.ProductionExecutionBatchService batches;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID workshop;
    private UUID worker;

    @BeforeEach void prepare() {
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        world=fixture.seedWorld("planned-rate-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","planned-rate-"+UUID.randomUUID());
        workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
    }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test void structuralDefaultsAndOnlyRatesAPersonConfirmedAreRemembered() {
        var defaults=rates.defaults(java.util.Set.of(world.goodsA(),world.goodsB(),world.goodsC(),world.goodsD(),world.goodsE()));
        assertDecimal("0",defaults.get(world.goodsA()));
        assertDecimal("0",defaults.get(world.goodsB()));
        assertDecimal(".1",defaults.get(world.goodsC()));
        assertDecimal("0",defaults.get(world.goodsD()));
        assertDecimal("0",defaults.get(world.goodsE()));
        // Purchased and undecided raw materials without their own BOM are not manufacturing stages.
        fixture.insertBom(world.goodsC(),world.goodsD(),".125");
        UUID onSiteMaterial=UUID.randomUUID();
        fixture.insertGoods(onSiteMaterial,"RAW-"+onSiteMaterial,"现场登记原料-"+onSiteMaterial,null,world.unitId(),world.unitLegacy());
        fixture.insertBom(world.goodsC(),onSiteMaterial,".5");
        assertDecimal(".1",rates.defaults(java.util.Set.of(world.goodsC())).get(world.goodsC()));

        // Omitted rate: the goods default, marked DEFAULT and never remembered.
        var request=manual(null);request.getItems().getFirst().setGoodsId(world.goodsC());
        var draft=plans.create(request);
        assertAllowance(draft.getItems().getFirst(),".1","DEFAULT");
        assertNull(memory(world.goodsC()));
        var explicitZero=manual("0");explicitZero.getItems().getFirst().setGoodsId(world.goodsC());
        assertAllowance(plans.create(explicitZero).getItems().getFirst(),"0","EXPLICIT");
        assertDecimal("0",memory(world.goodsC()));
        // Editing the first draft echoes its saved 10% untouched on the same saved line: it stays a
        // system default and does not bring the remembered zero back to 10%.
        request.getItems().getFirst().setSourceItemId(draft.getItems().getFirst().getId());
        request.getItems().getFirst().setAllowedOverproductionRate(new BigDecimal(".100000"));
        var echoed=plans.update(draft.getId(),request).getItems().getFirst();
        assertAllowance(echoed,".1","DEFAULT");
        assertDecimal("0",memory(world.goodsC()));
        request.getItems().getFirst().setSourceItemId(null);
        request.getItems().getFirst().setAllowedOverproductionRate(null);
        assertAllowance(plans.create(request).getItems().getFirst(),"0","DEFAULT");
        assertDecimal("0",analyses.detail(analysis().analysisId()).overproductionDefaults().get(world.goodsC()));
        // Changing the rate while editing is a person's decision.
        request.getItems().getFirst().setSourceItemId(echoed.getId());
        request.getItems().getFirst().setAllowedOverproductionRate(new BigDecimal(".2"));
        assertAllowance(plans.update(draft.getId(),request).getItems().getFirst(),".2","EXPLICIT");
        assertDecimal(".2",memory(world.goodsC()));
        request.getItems().getFirst().setAllowedOverproductionRate(new BigDecimal("-.1"));
        assertThrows(ApiException.class,()->plans.create(request));
        assertDecimal(".2",rates.defaults(java.util.Set.of(world.goodsC())).get(world.goodsC()));
        // MRP sub-plans, report remakes and actual-output supplements write the column default.
        UUID generatedItem=UUID.randomUUID();
        db.update("""
                INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,line_no,product_no,goods_id,unit_id,unit_rate,qty,allowed_overproduction_rate)
                VALUES(?,?,?,CURRENT_DATE,2,?,?,?,1,5,.7)
                """,generatedItem,draft.getId(),draft.getBillNo(),"generated-"+generatedItem,world.goodsC(),world.unitId());
        assertEquals("DEFAULT",db.queryForObject("SELECT allowed_overproduction_rate_source FROM production_plan_items WHERE id=?",String.class,generatedItem));
        assertDecimal(".2",memory(world.goodsC()));
    }

    /**
     * ADR-129 §2.10: "the same line" is the saved line id. Deleting a row no longer lets the next row
     * inherit its position, and an untouched system default keeps the rate the page showed.
     */
    @Test void draftEditMatchesTheSavedLineByItsIdNotByItsPosition() {
        var request=manual(null);
        var second=new PlanItemLine();second.setGoodsId(world.goodsC());second.setUnitId(world.unitId());
        second.setUnitRate(BigDecimal.ONE);second.setQty(BigDecimal.TEN);
        request.setItems(List.of(request.getItems().getFirst(),second));
        var draft=plans.create(request);
        assertAllowance(draft.getItems().get(0),"0","DEFAULT");assertAllowance(draft.getItems().get(1),".1","DEFAULT");
        // The first row is deleted; the page echoes the second row's saved 10% with its saved line id.
        second.setSourceItemId(draft.getItems().get(1).getId());second.setAllowedOverproductionRate(new BigDecimal(".1"));
        request.setItems(List.of(second));
        var edited=plans.update(draft.getId(),request).getItems();
        assertEquals(1,edited.size());assertAllowance(edited.getFirst(),".1","DEFAULT");
        assertNull(memory(world.goodsC()));
        // A later confirmation elsewhere does not re-resolve the untouched default row.
        var elsewhere=manual(".25");elsewhere.getItems().getFirst().setGoodsId(world.goodsC());
        assertAllowance(plans.create(elsewhere).getItems().getFirst(),".25","EXPLICIT");
        assertDecimal(".25",memory(world.goodsC()));
        second.setSourceItemId(edited.getFirst().getId());second.setAllowedOverproductionRate(null);
        var untouched=plans.update(draft.getId(),request).getItems().getFirst();
        assertAllowance(untouched,".1","DEFAULT");
        // A saved line of other goods is not the same line: the echoed rate is a new confirmation.
        second.setSourceItemId(untouched.getId());second.setGoodsId(world.goodsA());second.setAllowedOverproductionRate(new BigDecimal(".1"));
        assertAllowance(plans.update(draft.getId(),request).getItems().getFirst(),".1","EXPLICIT");
        assertDecimal(".1",memory(world.goodsA()));
        assertDecimal(".25",memory(world.goodsC()));
    }

    /**
     * ADR-129 §2.10: re-saving a draft re-inserts its unchanged lines; that is not a new confirmation,
     * so it must not overwrite a rate approved later on another task of the same goods.
     */
    @Test void reSavingAnUnchangedConfirmedLineKeepsANewerApprovedRateInMemory() {
        var batchFixture=new ProductionExecutionBatchEndToEndTest();beans.autowireBean(batchFixture);batchFixture.prepare();
        Object task=ReflectionTestUtils.invokeMethod(batchFixture,"create","rate-resave-"+UUID.randomUUID().toString().substring(0,8),false);
        UUID segment=ReflectionTestUtils.invokeMethod(task,"segment");UUID goods=ReflectionTestUtils.invokeMethod(task,"root");
        var batchWorld=(FullChainEndToEndTest.World)ReflectionTestUtils.invokeMethod(task,"world");
        fixture.loginAs(batchWorld.superAdminUserId());
        // A newly created confirmed line is remembered.
        var request=manual(".20");request.getItems().getFirst().setGoodsId(goods);request.getItems().getFirst().setUnitId(batchWorld.unitId());
        var draft=plans.create(request);
        assertAllowance(draft.getItems().getFirst(),".20","EXPLICIT");assertDecimal(".20",memory(goods));
        // Later a 5% adjustment on another task of the same goods is approved and becomes the memory.
        var pending=rates.submit(new com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.SubmitRequest(
                segment,0L,new BigDecimal(".05"),"试产稳定后调低允许超产","resave-rate-request-"+segment));
        rates.decide(pending.id(),new com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.DecisionRequest(
                pending.rowVersion(),"resave-rate-approve-"+segment,"已核对"),true);
        assertDecimal(".05",memory(goods));
        // Re-saving the draft with only a header change keeps the line's 20% and the newer 5% memory.
        request.setDeliveryDate(BusinessTime.today().plusDays(20));
        request.getItems().getFirst().setSourceItemId(draft.getItems().getFirst().getId());
        var resaved=plans.update(draft.getId(),request).getItems().getFirst();
        assertAllowance(resaved,".20","EXPLICIT");assertDecimal(".05",memory(goods));
        // Changing the line's rate is a new confirmation and is remembered again.
        request.getItems().getFirst().setSourceItemId(resaved.getId());
        request.getItems().getFirst().setAllowedOverproductionRate(new BigDecimal(".15"));
        assertAllowance(plans.update(draft.getId(),request).getItems().getFirst(),".15","EXPLICIT");
        assertDecimal(".15",memory(goods));
    }

    @Test void initialPlanRateFlowsThroughReadOnlyPreviewApprovalAndSameRateGrowthWithoutOverwritingAnotherRate() {
        AnalysisView analysis=analysis();UUID line=analysis.products().getFirst().analysisLineId();
        var first=request(analysis,line,"4",".20");
        int before=db.queryForObject("SELECT count(*) FROM production_plans",Integer.class);
        commands.previewIssuePlans(analysis.analysisId(),preview(first));
        assertEquals(before,db.queryForObject("SELECT count(*) FROM production_plans",Integer.class));
        assertDecimal("0",rates.defaults(java.util.Set.of(world.goodsA())).get(world.goodsA()));
        var firstResult=commands.issueWorkshopPlans(analysis.analysisId(),first);
        UUID original=firstResult.plans().getFirst().planId();
        assertPlanAndSegments(original,".20");
        assertAllowance(plans.detail(original).getItems().getFirst(),".20","EXPLICIT");
        assertDecimal(".20",memory(world.goodsA()));
        assertEquals(original,commands.issueWorkshopPlans(analysis.analysisId(),first).plans().getFirst().planId());
        var changedIntentSameKey=new IssueWorkshopPlansRequest(first.version(),first.fingerprint(),first.idempotencyKey(),
                first.warehouseId(),first.billDate(),first.deliveryDate(),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,line,new BigDecimal("4"),null,null,
                        workshop,null,worker,null,null,true,new BigDecimal(".20"))));
        assertThrows(ApiException.class,()->commands.issueWorkshopPlans(analysis.analysisId(),changedIntentSameKey));
        var changedRateSameKey=new IssueWorkshopPlansRequest(first.version(),first.fingerprint(),first.idempotencyKey(),
                first.warehouseId(),first.billDate(),first.deliveryDate(),true,
                List.of(issueLine(line,"4",".30")));
        assertThrows(ApiException.class,()->commands.issueWorkshopPlans(analysis.analysisId(),changedRateSameKey));

        plans.create(manual(".30"));
        assertDecimal(".30",rates.defaults(java.util.Set.of(world.goodsA())).get(world.goodsA()));
        var sameRate=request(analyses.detail(analysis.analysisId()),line,"2",".200000");
        var grown=commands.issueWorkshopPlans(analysis.analysisId(),sameRate).plans().getFirst();
        assertTrue(grown.mergedIntoExisting());assertEquals(original,grown.planId());assertPlanAndSegments(original,".20");
        assertDecimal(".20",rates.defaults(java.util.Set.of(world.goodsA())).get(world.goodsA()));

        // Omission takes the remembered 20%; an explicit 10% remains a different intention.
        var defaultRate=request(analyses.detail(analysis.analysisId()),line,"4",null);
        commands.previewIssuePlans(analysis.analysisId(),preview(defaultRate));
        var remembered=commands.issueWorkshopPlans(analysis.analysisId(),defaultRate).plans().getFirst();
        assertEquals(original,remembered.planId());assertTrue(remembered.mergedIntoExisting());
        assertPlanAndSegments(original,".20");
        // Growth without a rate keeps the line's confirmed source and writes no memory of its own.
        assertAllowance(plans.detail(original).getItems().getFirst(),".20","EXPLICIT");
        assertDecimal(".20",memory(world.goodsA()));
        var differentIntentionSameKey = new IssueWorkshopPlansRequest(defaultRate.version(),defaultRate.fingerprint(),
                defaultRate.idempotencyKey(),defaultRate.warehouseId(),defaultRate.billDate(),defaultRate.deliveryDate(),
                defaultRate.approveNow(),List.of(issueLine(line,"4",".10")));
        assertThrows(ApiException.class,()->commands.issueWorkshopPlans(analysis.analysisId(),differentIntentionSameKey));
        var explicitTen=request(analyses.detail(analysis.analysisId()),line,"1",".10");
        explicitTen=new IssueWorkshopPlansRequest(explicitTen.version(),explicitTen.fingerprint(),explicitTen.idempotencyKey(),
                explicitTen.warehouseId(),explicitTen.billDate(),explicitTen.deliveryDate(),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,line,BigDecimal.ONE,null,null,
                        workshop,null,worker,null,null,true,new BigDecimal(".10"))));
        var separate=commands.issueWorkshopPlans(analysis.analysisId(),explicitTen).plans().getFirst();
        assertNotEquals(original,separate.planId());assertFalse(separate.mergedIntoExisting());
        assertPlanAndSegments(original,".20");assertPlanAndSegments(separate.planId(),".10");
        var full=analyses.detail(analysis.analysisId());
        var publicOnly=new IssueWorkshopPlansRequest(full.version(),full.fingerprint(),"public-only-rate-"+UUID.randomUUID(),
                world.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,line,BigDecimal.ONE,null,null,
                        workshop,null,worker,null,null,true,new BigDecimal(".1"))));
        var publicPlan=commands.issueWorkshopPlans(analysis.analysisId(),publicOnly).plans().getFirst().planId();
        assertEquals(publicPlan,commands.issueWorkshopPlans(analysis.analysisId(),publicOnly).plans().getFirst().planId());
        assertDecimal("2",db.queryForObject("SELECT sum(public_surplus_qty) FROM production_material_analysis_plan_links WHERE analysis_id=?",BigDecimal.class,analysis.analysisId()));
        UUID originalItem=plans.detail(original).getItems().getFirst().getId();
        assertThrows(RuntimeException.class,()->db.update(
                "UPDATE production_plan_items SET allowed_overproduction_rate=.50 WHERE id=?",originalItem));
        assertPlanAndSegments(original,".20");
    }

    @Test void draftPlansCanSetZeroOrMoreThanOneHundredPercentAndRejectInvalidPrecisionBeforeWriting() {
        PlanSaveRequest create=manual("0");
        var draft=plans.create(create);assertDecimal("0",draft.getItems().getFirst().getAllowedOverproductionRate());
        var changed=plans.update(draft.getId(),manual("1.50"));
        assertAllowance(changed.getItems().getFirst(),"1.5","EXPLICIT");
        // Clearing the rate while editing hands it back to the goods default (the remembered 150%).
        assertAllowance(plans.update(draft.getId(),manual(null)).getItems().getFirst(),"1.5","DEFAULT");
        assertThrows(ApiException.class,()->plans.update(draft.getId(),manual("0.0000001")));
        assertDecimal("1.5",plans.detail(draft.getId()).getItems().getFirst().getAllowedOverproductionRate());
        assertThrows(ApiException.class,()->plans.create(manual("-0.01")));
        assertThrows(ApiException.class,()->plans.create(manual("1000")));
        assertDecimal("1.5",plans.create(manual(null)).getItems().getFirst().getAllowedOverproductionRate());
    }

    @Test void invalidAnalysisRateIsRejectedByBothPreviewAndIssueWithoutCreatingAPlan() {
        var analysis=analysis();UUID line=analysis.products().getFirst().analysisLineId();
        int before=db.queryForObject("SELECT count(*) FROM production_plans",Integer.class);
        var invalid=request(analysis,line,"10","-.1");
        assertThrows(ApiException.class,()->commands.previewIssuePlans(analysis.analysisId(),preview(invalid)));
        assertThrows(ApiException.class,()->commands.issueWorkshopPlans(analysis.analysisId(),invalid));
        assertEquals(before,db.queryForObject("SELECT count(*) FROM production_plans",Integer.class));
    }

    @Test void batchSplitInheritsTheApprovedEffectiveRateInsteadOfReturningToTheOriginalPlanRate() {
        var batchFixture=new ProductionExecutionBatchEndToEndTest();beans.autowireBean(batchFixture);batchFixture.prepare();
        Object original=ReflectionTestUtils.invokeMethod(batchFixture,"create","rate-inherited-split",false);
        UUID plan=ReflectionTestUtils.invokeMethod(original,"plan");UUID segment=ReflectionTestUtils.invokeMethod(original,"segment");
        BigDecimal initial=plans.detail(plan).getItems().getFirst().getAllowedOverproductionRate();
        UUID goods=db.queryForObject("SELECT product_goods_id FROM production_execution_segments WHERE id=?",UUID.class,segment);
        var batchWorld=(FullChainEndToEndTest.World)ReflectionTestUtils.invokeMethod(original,"world");
        fixture.loginAs(batchWorld.superAdminUserId());
        var pending=rates.submit(new com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.SubmitRequest(
                segment,0L,new BigDecimal(".25"),"分批生产应继承已批准比例","split-rate-request-"+segment));
        assertEquals(0,initial.compareTo(rates.defaults(java.util.Set.of(goods)).get(goods)));
        rates.decide(pending.id(),new com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.DecisionRequest(
                pending.rowVersion(),"split-rate-approve-"+segment,"已核对"),true);
        assertDecimal(".25",rates.defaults(java.util.Set.of(goods)).get(goods));
        ReflectionTestUtils.invokeMethod(batchFixture,"confirmRoute",plan,segment,"BATCH","split-approved-rate-route-"+segment);
        ReflectionTestUtils.invokeMethod(batchFixture,"receive",original,"40");
        fixture.loginAs(batchWorld.superAdminUserId());
        long version=db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);
        var preview=batches.preview(new com.uten.imp.features.production.execution.ProductionExecutionBatch.PreviewRequest(segment,version,null));
        var result=batches.submit(new com.uten.imp.features.production.execution.ProductionExecutionBatch.SubmitRequest(
                segment,preview.expectedVersion(),preview.quantity(),preview.fingerprint(),"split-approved-rate-submit-"+segment));
        assertEquals(0,initial.compareTo(plans.detail(plan).getItems().getFirst().getAllowedOverproductionRate()));
        for(UUID child:List.of(result.batchSegmentId(),result.remainingSegmentId())) {
            assertDecimal(".25",db.queryForObject("SELECT allowed_overproduction_rate FROM production_execution_segments WHERE id=?",BigDecimal.class,child));
            assertEquals(0L,db.queryForObject("SELECT overproduction_rate_version FROM production_execution_segments WHERE id=?",Long.class,child));
        }
        assertDecimal(".25",db.queryForObject("SELECT allowed_overproduction_rate FROM production_execution_segments WHERE id=?",BigDecimal.class,segment));
    }

    private AnalysisView analysis() {
        var view=analyses.preview(new PreviewRequest(null,null,null,world.warehouseId(),"planned-rate-preview-"+UUID.randomUUID(),
                List.of(new PreviewItem("OTHER",null,world.goodsA(),null,world.unitId(),"rate-"+UUID.randomUUID(),
                        "计划设置允许超产比例",BusinessTime.today().plusDays(10),BigDecimal.TEN))));
        ReflectionTestUtils.invokeMethod(fixture,"confirmRootMakeRoute",view.analysisId(),analyses.detail(view.analysisId()));
        return analyses.detail(view.analysisId());
    }
    private IssueWorkshopPlansRequest request(AnalysisView view,UUID line,String qty,String rate) {
        return new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"planned-rate-issue-"+UUID.randomUUID(),
                world.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(issueLine(line,qty,rate)));
    }
    private IssueWorkshopPlansRequest.IssuePlanLine issueLine(UUID line,String qty,String rate) {
        return new IssueWorkshopPlansRequest.IssuePlanLine(null,line,new BigDecimal(qty),null,null,
                workshop,null,worker,null,null,null,rate==null?null:new BigDecimal(rate));
    }
    private PreviewIssuePlansRequest preview(IssueWorkshopPlansRequest request) {
        return new PreviewIssuePlansRequest(request.version(),request.fingerprint(),request.idempotencyKey(),request.warehouseId(),
                request.billDate(),request.deliveryDate(),request.approveNow(),request.lines(),List.of());
    }
    private PlanSaveRequest manual(String rate) {
        var request=new PlanSaveRequest();request.setBillDate(BusinessTime.today());request.setDepartmentId(workshop);request.setWorkerId(worker);
        var line=new PlanItemLine();line.setGoodsId(world.goodsA());line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.TEN);line.setAllowedOverproductionRate(rate==null?null:new BigDecimal(rate));request.setItems(List.of(line));return request;
    }
    private void assertAllowance(com.uten.imp.features.production.plan.dto.PlanItemDto item,String rate,String source) {
        assertDecimal(rate,item.getAllowedOverproductionRate());assertEquals(source,item.getAllowedOverproductionRateSource());
    }
    private BigDecimal memory(UUID goods) {
        return db.queryForObject("SELECT production_overproduction_rate FROM goods WHERE id=?",BigDecimal.class,goods);
    }
    private void assertPlanAndSegments(UUID plan,String expected) {
        assertDecimal(expected,plans.detail(plan).getItems().getFirst().getAllowedOverproductionRate());
        var rates=db.queryForList("SELECT allowed_overproduction_rate FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,plan);
        assertFalse(rates.isEmpty());rates.forEach(rate->assertDecimal(expected,rate));
    }
    private static void assertDecimal(String expected,BigDecimal actual) { assertEquals(0,new BigDecimal(expected).compareTo(actual)); }
}
