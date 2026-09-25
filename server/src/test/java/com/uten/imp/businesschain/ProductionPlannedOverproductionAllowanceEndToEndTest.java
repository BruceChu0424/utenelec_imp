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
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
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

    @Test void manufacturingDefaultsRememberZeroAndWeightedBomRawMaterialChildrenDoNotChangeTheManufacturingLeaf() {
        var defaults=rates.defaults(java.util.Set.of(world.goodsA(),world.goodsB(),world.goodsC(),world.goodsD(),world.goodsE()));
        assertDecimal("0",defaults.get(world.goodsA()));
        assertDecimal("0",defaults.get(world.goodsB()));
        assertDecimal(".1",defaults.get(world.goodsC()));
        assertDecimal("0",defaults.get(world.goodsD()));
        assertDecimal("0",defaults.get(world.goodsE()));
        fixture.insertBom(world.goodsC(),world.goodsD(),".125");
        assertDecimal(".1",rates.defaults(java.util.Set.of(world.goodsC())).get(world.goodsC()));
        var request=manual(null);request.getItems().getFirst().setGoodsId(world.goodsC());
        var draft=plans.create(request);
        assertDecimal(".1",draft.getItems().getFirst().getAllowedOverproductionRate());
        request.getItems().getFirst().setAllowedOverproductionRate(BigDecimal.ZERO);
        plans.update(draft.getId(),request);
        assertDecimal("0",rates.defaults(java.util.Set.of(world.goodsC())).get(world.goodsC()));
        request.getItems().getFirst().setAllowedOverproductionRate(null);
        assertDecimal("0",plans.create(request).getItems().getFirst().getAllowedOverproductionRate());
        assertDecimal("0",analyses.detail(analysis().analysisId()).overproductionDefaults().get(world.goodsC()));
        request.getItems().getFirst().setAllowedOverproductionRate(new BigDecimal("-.1"));
        assertThrows(ApiException.class,()->plans.create(request));
        assertDecimal("0",rates.defaults(java.util.Set.of(world.goodsC())).get(world.goodsC()));
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
        assertDecimal("1.5",changed.getItems().getFirst().getAllowedOverproductionRate());
        assertThrows(ApiException.class,()->plans.update(draft.getId(),manual(null)));
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
    private void assertPlanAndSegments(UUID plan,String expected) {
        assertDecimal(expected,plans.detail(plan).getItems().getFirst().getAllowedOverproductionRate());
        var rates=db.queryForList("SELECT allowed_overproduction_rate FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,plan);
        assertFalse(rates.isEmpty());rates.forEach(rate->assertDecimal(expected,rate));
    }
    private static void assertDecimal(String expected,BigDecimal actual) { assertEquals(0,new BigDecimal(expected).compareTo(actual)); }
}
