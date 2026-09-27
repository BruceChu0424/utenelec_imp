package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.math.BigDecimal;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
    "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
    "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
    "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MakePublicSupplyEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired AggregateMaterialOrderWriteService writer;
    @Autowired PlatformTransactionManager transactions;
    AggregateMaterialOrderEndToEndTest support;
    @BeforeEach void prepare(){support=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(support);support.before();}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void aggregatePublicPromiseReceivesItsOwnExactStockAndReversalRestoresOnlyThePromise(){
        aggregateReceipt(false);
    }
    @Test void publicReceiptFormalizesTheWaitingTargetWithoutPretendingThePromiseWasStock(){
        aggregateReceipt(true);
    }
    private void aggregateReceipt(boolean formalize){
        var c=support.create(true,true,"1");
        var batch=writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","5",true)))).batches().getFirst();
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,batch.planId());
        amount("2",available(planItem));
        AnalysisView target=target(c,"2");UUID material=target.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        var request=new PreplanMakePublicSupplyService.ClaimRequest(target.version(),target.fingerprint(),"claim-make-"+UUID.randomUUID(),planItem,material,new BigDecimal("2"));
        target=ReflectionTestUtils.invokeMethod(commands,"claimMakePublicSupply",target.analysisId(),request);
        ReflectionTestUtils.invokeMethod(commands,"claimMakePublicSupply",target.analysisId(),request);
        UUID claim=db.queryForObject("SELECT id FROM preplan_make_public_claims WHERE target_analysis_id=?",UUID.class,target.analysisId());
        amount("0",available(planItem));amount("2",pending(claim));
        amount("0",db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.common()));
        UUID targetPlan=null;
        if(formalize){
            var root=target.products().stream().filter(row->row.sourceType().equals("OTHER")).findFirst().orElseThrow();
            var planLine=new IssueWorkshopPlansRequest.IssuePlanLine(null,root.analysisLineId(),new BigDecimal("2"),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO);
            targetPlan=commands.issueWorkshopPlans(target.analysisId(),new IssueWorkshopPlansRequest(target.version(),target.fingerprint(),"target-plan-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(planLine))).plans().getFirst().planId();
            assertEquals("WAITING",db.queryForObject("SELECT status FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",String.class,targetPlan));
        }
        assertThrows(RuntimeException.class,()->db.update("UPDATE production_plans SET is_canceled=true WHERE id=?",batch.planId()));
        support.produce(c,batch);
        UUID inbound=db.queryForObject("SELECT DISTINCT source_stock_document_id FROM preplan_analysis_stock_exact_pegs WHERE make_public_claim_id=?",UUID.class,claim);
        amount("0",pending(claim));amount("2",received(claim));
        amount("2",db.queryForObject("SELECT sum(qty) FROM preplan_analysis_stock_exact_pegs WHERE source_stock_document_id=? AND make_public_claim_id=?",BigDecimal.class,inbound,claim));
        amount("3",db.queryForObject("SELECT sum(e.qty) FROM preplan_analysis_stock_exact_pegs e JOIN stock_document_items i ON i.id=e.source_stock_document_item_id WHERE i.upstream_item_id=? AND e.make_public_claim_id IS NULL",BigDecimal.class,planItem));
        amount("5",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.common()));
        RuntimeException rewritten=assertThrows(RuntimeException.class,()->db.update("UPDATE preplan_analysis_stock_exact_pegs SET make_public_claim_id=gen_random_uuid() WHERE make_public_claim_id=?",claim));
        assertTrue(rewritten.getMessage().contains("public manufacturing exact origin is immutable"));
        if(formalize)amount("2",db.queryForObject("SELECT COALESCE(sum(r.qty-r.released_qty-r.consumed_qty),0) FROM stock_reservations r JOIN production_material_demands d ON d.id=r.demand_id WHERE d.plan_id=? AND NOT r.is_deleted",BigDecimal.class,targetPlan));
        InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),db,List.of(c.common(),c.material()));
        var stock=beans.getBean(com.uten.imp.features.stock.StockDocService.class);
        if(formalize){
            assertThrows(com.uten.imp.common.web.ApiException.class,()->stock.reverseFinishedInbound(inbound),"restore the receiving package before reversing its source");
            UUID receivingPackage=db.queryForObject("SELECT id FROM production_planning_packages WHERE plan_id=? AND status='CONFIRMED'",UUID.class,targetPlan);
            beans.getBean(com.uten.imp.features.production.mrp.ProductionPlanningPackageService.class).cancel(targetPlan,receivingPackage,
                new com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest("make-claim-package-cancel-"+receivingPackage,"撤回未领料的接收计划包，恢复原公共供给实收权益"));
        }
        stock.reverseFinishedInbound(inbound);
        amount("0",received(claim));amount("2",pending(claim));amount("0",available(planItem));
        target=analyses.detail(target.analysisId());
        var cancel=new PreplanMakePublicSupplyService.CancelRequest(target.version(),target.fingerprint(),"cancel-make-"+UUID.randomUUID(),new BigDecimal("2"),"实收已红冲，撤回该公共供给采用");
        ReflectionTestUtils.invokeMethod(commands,"cancelMakePublicClaim",target.analysisId(),claim,cancel);
        ReflectionTestUtils.invokeMethod(commands,"cancelMakePublicClaim",target.analysisId(),claim,cancel);
        amount("0",pending(claim));amount("2",available(planItem));
    }

    @Test void databaseRejectsOverClaimAndCancellationOfReceivedOrAlreadyCancelledQuantity(){
        var c=support.create(true,true,"1");
        var batch=writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","5",true)))).batches().getFirst();
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,batch.planId());
        AnalysisView target=target(c,"3");UUID material=target.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        assertThrows(RuntimeException.class,()->insertClaim(c,planItem,target.analysisId(),material,"3"));amount("2",available(planItem));
        UUID claim=insertClaim(c,planItem,target.analysisId(),material,"2");amount("0",available(planItem));
        assertThrows(RuntimeException.class,()->db.update("UPDATE preplan_make_public_claims SET qty=1 WHERE id=?",claim));
        assertThrows(RuntimeException.class,()->cancel(c,claim,"3"));
        cancel(c,claim,"1");amount("1",available(planItem));amount("1",pending(claim));
        assertThrows(RuntimeException.class,()->cancel(c,claim,"2"));amount("1",available(planItem));
    }
    @Test void orderingAnotherProductsSameMaterialAdoptsPublicMakeWithoutCreatingDuplicateProduction(){
        var c=support.create(true,true,"1");
        var original=writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","5",true)))).batches().getFirst();
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,original.planId());
        var target=target(c,"2");
        var next=new AggregateMaterialOrderEndToEndTest.Case(c.world(),target.analysisId(),c.common(),null,c.material(),c.workshop(),c.worker());
        var command=support.command(next,List.of(support.input(next,c.common(),"MAKE","2",false)));
        var result=writer.submit(next.analysis(),command);assertTrue(writer.submit(next.analysis(),command).replayed());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted",Integer.class,next.analysis()));
        amount("2",db.queryForObject("SELECT sum(qty) FROM preplan_make_public_claims WHERE target_analysis_id=?",BigDecimal.class,next.analysis()));
        amount("0",available(planItem));
        var material=result.analysis().flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow();
        amount("0",material.additionalSupplyRecommendedQty());amount("2",material.preparationAdoptedQty());
    }
    @Test void ordinaryMakeComponentPublicShareUsesTheSamePromiseAndReceiptChain(){
        var c=support.create(true,true,"1");var source=analyses.detail(c.analysis());
        UUID sourceMaterial=source.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        var line=new IssueWorkshopPlansRequest.IssuePlanLine(sourceMaterial,null,new BigDecimal("3"),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO);
        UUID plan=commands.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(source.version(),source.fingerprint(),"ordinary-public-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(line))).plans().getFirst().planId();
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,plan);
        amount("2",available(planItem));
        var target=target(c,"2");UUID material=target.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        var request=new PreplanMakePublicSupplyService.ClaimRequest(target.version(),target.fingerprint(),"ordinary-claim-"+UUID.randomUUID(),planItem,material,new BigDecimal("2"));
        ReflectionTestUtils.invokeMethod(commands,"claimMakePublicSupply",target.analysisId(),request);
        UUID claim=db.queryForObject("SELECT id FROM preplan_make_public_claims WHERE target_analysis_id=?",UUID.class,target.analysisId());
        var batch=new AggregateMaterialOrderContracts.BatchResult(null,null,"MAKE",null,null,null,plan,null,new BigDecimal("3"),new BigDecimal("2"),List.of());
        support.produce(c,batch);
        amount("2",received(claim));amount("0",pending(claim));
        amount("1",db.queryForObject("SELECT sum(e.qty) FROM preplan_analysis_stock_exact_pegs e JOIN stock_document_items i ON i.id=e.source_stock_document_item_id WHERE i.upstream_item_id=? AND e.make_public_claim_id IS NULL",BigDecimal.class,planItem));
        amount("2",db.queryForObject("SELECT sum(qty) FROM preplan_analysis_stock_exact_pegs WHERE make_public_claim_id=?",BigDecimal.class,claim));
    }
    @Test void anotherProductInTheSameAnalysisCanAdoptButTheManufacturingSourceCannotClaimItself(){
        var c=support.create(true,true,"1");var source=analyses.detail(c.analysis());
        var originals=source.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).toList();
        UUID own=originals.get(0).materialLineId(),other=originals.get(1).materialLineId();
        var line=new IssueWorkshopPlansRequest.IssuePlanLine(own,null,new BigDecimal("3"),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO);
        UUID plan=commands.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(source.version(),source.fingerprint(),"same-analysis-source-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(line))).plans().getFirst().planId();
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,plan);
        assertTrue(db.queryForObject("SELECT fn_preplan_make_public_target_is_source(?,?)",Boolean.class,planItem,own));
        assertFalse(db.queryForObject("SELECT fn_preplan_make_public_target_is_source(?,?)",Boolean.class,planItem,other));
        assertThrows(RuntimeException.class,()->insertClaim(c,planItem,c.analysis(),own,"1"));amount("2",available(planItem));
        source=analyses.detail(c.analysis());
        var claimRequest=new PreplanMakePublicSupplyService.ClaimRequest(source.version(),source.fingerprint(),"same-analysis-claim-"+UUID.randomUUID(),planItem,other,BigDecimal.ONE);
        ReflectionTestUtils.invokeMethod(commands,"claimMakePublicSupply",c.analysis(),claimRequest);
        ReflectionTestUtils.invokeMethod(commands,"claimMakePublicSupply",c.analysis(),claimRequest);
        UUID claim=db.queryForObject("SELECT id FROM preplan_make_public_claims WHERE source_plan_item_id=?",UUID.class,planItem);
        amount("1",available(planItem));amount("1",pending(claim));
        var batch=new AggregateMaterialOrderContracts.BatchResult(null,null,"MAKE",null,null,null,plan,null,new BigDecimal("3"),new BigDecimal("2"),List.of());
        support.produce(c,batch);amount("1",received(claim));amount("0",pending(claim));
    }
    @Test void canonicalAliasesCannotDisguiseAClaimBackToTheOriginalManufacturingSource(){
        var c=support.createWithChild("1");
        var before=analyses.detail(c.analysis());UUID originalChild=before.flatMaterials().stream().filter(row->row.goodsId().equals(c.child())).findFirst().orElseThrow().materialLineId();
        writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","3",false))));
        var child=writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.child(),"MAKE","5",true)))).batches().getFirst();
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,child.planId());
        assertTrue(db.queryForObject("SELECT fn_preplan_make_public_target_is_source(?,?)",Boolean.class,planItem,originalChild));
        assertThrows(RuntimeException.class,()->insertClaim(c,planItem,c.analysis(),originalChild,"1"));amount("2",available(planItem));
    }
    @Test void aChildClaimMadeBeforeItsParentOrderFollowsTheExactAliasWithoutOrderingThatShareAgain(){
        var c=support.create(true,true,"1");
        var source=writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","5",true)))).batches().getFirst();
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,source.planId());
        UUID parent=UUID.randomUUID();support.fixture.insertGoods(parent,"LATER-PARENT-"+parent,"后下达的父件","自制",c.world().unitId(),c.world().unitLegacy());support.fixture.insertBom(parent,c.common(),"1");
        List<PreviewItem> roots=new ArrayList<>();
        for(int index=0;index<3;index++){UUID root=UUID.randomUUID();support.fixture.insertGoods(root,"LATER-ROOT-"+root,"父件来源产品","自制",c.world().unitId(),c.world().unitLegacy());support.fixture.insertBom(root,parent,"1");
            roots.add(new PreviewItem("OTHER",null,root,null,c.world().unitId(),"later-root-"+root,"先采用子件、后下达父件",BusinessTime.today().plusDays(10),BigDecimal.ONE));}
        var target=analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),"later-analysis-"+parent,roots));
        target=analyses.saveRoutes(target.analysisId(),new RouteRequest(target.version(),target.fingerprint(),"later-routes-"+parent,target.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(c.material())?"BUY":"MAKE",null)).toList()));
        UUID original=target.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        ReflectionTestUtils.invokeMethod(commands,"claimMakePublicSupply",target.analysisId(),new PreplanMakePublicSupplyService.ClaimRequest(target.version(),target.fingerprint(),"later-claim-"+parent,planItem,original,BigDecimal.ONE));
        UUID claim=db.queryForObject("SELECT id FROM preplan_make_public_claims WHERE target_material_id=?",UUID.class,original);
        var targetCase=new AggregateMaterialOrderEndToEndTest.Case(c.world(),target.analysisId(),parent,c.common(),c.material(),c.workshop(),c.worker());
        var parentBatch=writer.submit(target.analysisId(),support.command(targetCase,List.of(support.input(targetCase,parent,"MAKE","3",false)))).batches().getFirst();
        UUID canonical=db.queryForObject("SELECT id FROM production_material_analysis_materials WHERE analysis_item_id=? AND goods_id=? AND active",UUID.class,parentBatch.anchorAnalysisItemId(),c.common());
        amount("1",db.queryForObject("SELECT inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(?) WHERE analysis_material_id=?",BigDecimal.class,target.analysisId(),canonical));
        amount("2",analyses.detail(target.analysisId()).flatMaterials().stream().filter(row->row.materialLineId().equals(canonical)).findFirst().orElseThrow().additionalSupplyRecommendedQty());
        support.produce(c,source);amount("1",received(claim));
        amount("1",db.queryForObject("SELECT sum(fn_preplan_aggregate_alias_delegated_qty(id)) FROM preplan_aggregate_material_aliases WHERE source_material_id=? AND aggregate_material_id=?",BigDecimal.class,original,canonical));
    }
    @Test void adoptingOnlyOneOriginalChildKeepsThatOriginalIntentAfterItsParentWasMerged(){
        var c=support.create(true,true,"1");
        writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","5",true))));
        UUID parent=UUID.randomUUID();support.fixture.insertGoods(parent,"INTENT-PARENT-"+parent,"采用原行父件","自制",c.world().unitId(),c.world().unitLegacy());support.fixture.insertBom(parent,c.common(),"1");
        List<PreviewItem> roots=new ArrayList<>();
        for(int index=0;index<3;index++){UUID root=UUID.randomUUID();support.fixture.insertGoods(root,"INTENT-ROOT-"+root,"采用原行产品","自制",c.world().unitId(),c.world().unitLegacy());support.fixture.insertBom(root,parent,"1");
            roots.add(new PreviewItem("OTHER",null,root,null,c.world().unitId(),"intent-root-"+root,"原路径独立采用",BusinessTime.today().plusDays(10),BigDecimal.ONE));}
        var target=analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),"intent-analysis-"+parent,roots));
        target=analyses.saveRoutes(target.analysisId(),new RouteRequest(target.version(),target.fingerprint(),"intent-routes-"+parent,target.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(c.material())?"BUY":"MAKE",null)).toList()));
        List<UUID> originals=target.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).map(MaterialView::materialLineId).toList();UUID selected=originals.getFirst();
        var targetCase=new AggregateMaterialOrderEndToEndTest.Case(c.world(),target.analysisId(),parent,c.common(),c.material(),c.workshop(),c.worker());
        writer.submit(target.analysisId(),support.command(targetCase,List.of(support.input(targetCase,parent,"MAKE","3",false))));
        var input=new AggregateMaterialOrderContracts.GroupInput("original-child-"+selected,List.of(selected),"MAKE",BigDecimal.ONE,false,
                c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO,Map.of(selected,BigDecimal.ONE));
        var request=support.command(targetCase,List.of(input));var result=writer.submit(target.analysisId(),request);
        assertTrue(result.batches().isEmpty());assertTrue(writer.submit(target.analysisId(),request).replayed());
        var current=analyses.detail(target.analysisId());
        for(UUID id:originals){MaterialView row=current.flatMaterials().stream().filter(material->material.materialLineId().equals(id)).findFirst().orElseThrow();
            amount(id.equals(selected)?"1":"0",row.preparationAdoptedQty());amount("0",row.aggregatePreparation().orderedQty());
            amount(id.equals(selected)?"0":"1",row.aggregatePreparation().planningUncoveredQty());
            if(id.equals(selected))assertFalse(row.flowStage().endsWith("PENDING_ISSUE"));}
        UUID claim=db.queryForObject("SELECT id FROM preplan_make_public_claims WHERE target_analysis_id=?",UUID.class,target.analysisId());
        var cancel=new PreplanMakePublicSupplyService.CancelRequest(current.version(),current.fingerprint(),"intent-cancel-"+selected,BigDecimal.ONE,"撤回该原行采用");
        commands.cancelMakePublicClaim(target.analysisId(),claim,cancel);
        amount("0",analyses.detail(target.analysisId()).flatMaterials().stream().filter(row->row.materialLineId().equals(selected)).findFirst().orElseThrow().preparationAdoptedQty());
    }
    @Test void aRootProductCanAdoptAllItsOutputWithoutGeneratingAPlanOrItsChildMaterialDemand(){
        var c=support.create(true,true,"1");
        writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","5",true))));
        var target=analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),"root-adopt-"+UUID.randomUUID(),List.of(new PreviewItem("OTHER",null,c.common(),null,c.world().unitId(),"root-adopt-source-"+UUID.randomUUID(),"采用已安排公共成品",BusinessTime.today().plusDays(10),new BigDecimal("2")))));
        target=analyses.saveRoutes(target.analysisId(),new RouteRequest(target.version(),target.fingerprint(),"root-adopt-routes-"+target.analysisId(),target.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(c.common())?"MAKE":"BUY",null)).toList()));
        var root=target.products().getFirst();var line=new IssueWorkshopPlansRequest.IssuePlanLine(null,root.analysisLineId(),new BigDecimal("2"),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO);
        var request=new IssueWorkshopPlansRequest(target.version(),target.fingerprint(),"root-adopt-order-"+target.analysisId(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(line));
        var adopted=commands.issueWorkshopPlans(target.analysisId(),request);assertTrue(adopted.plans().isEmpty());
        assertTrue(commands.issueWorkshopPlans(target.analysisId(),request).plans().isEmpty());
        var current=analyses.detail(target.analysisId());
        amount("2",current.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().preparationAdoptedQty());
        amount("0",current.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())).findFirst().orElseThrow().requiredQty());
        var extra=new IssueWorkshopPlansRequest.IssuePlanLine(null,root.analysisLineId(),BigDecimal.ONE,null,null,c.workshop(),null,c.worker(),null,null,true,BigDecimal.ZERO);
        var appended=commands.issueWorkshopPlans(target.analysisId(),new IssueWorkshopPlansRequest(current.version(),current.fingerprint(),"root-adopt-extra-"+target.analysisId(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(extra)));
        assertEquals(1,appended.plans().size());
        UUID extraPlan=appended.plans().getFirst().planId();
        amount("0",db.queryForObject("SELECT submitted_qty FROM production_material_analysis_plan_links WHERE plan_id=?",BigDecimal.class,extraPlan));
        amount("1",db.queryForObject("SELECT public_surplus_qty FROM production_material_analysis_plan_links WHERE plan_id=?",BigDecimal.class,extraPlan));
        current=analyses.detail(target.analysisId());
        amount("2",current.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().preparationAdoptedQty());
        amount("1",current.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())).findFirst().orElseThrow().requiredQty());
    }
    @Test void aPurchasedRootCanUseExistingManufacturingOutputWithoutOpeningAnotherRequest(){
        var c=support.create(true,true,"1");
        writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","5",true))));
        var target=analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),"root-buy-adopt-"+UUID.randomUUID(),List.of(new PreviewItem("OTHER",null,c.common(),null,c.world().unitId(),"root-buy-source-"+UUID.randomUUID(),"采购路线采用同货品已有自制公共供给",BusinessTime.today().plusDays(10),new BigDecimal("2")))));
        UUID root=target.products().getFirst().rootMaterialLineId();
        target=analyses.saveRoutes(target.analysisId(),new RouteRequest(target.version(),target.fingerprint(),"root-buy-route-"+target.analysisId(),List.of(new RouteDecision(root,target.flatMaterials().stream().filter(row->row.materialLineId().equals(root)).findFirst().orElseThrow().actionGroupKey(),"BUY",null))));
        var request=new NotifyRequest(target.version(),target.fingerprint(),"root-buy-order-"+target.analysisId(),"BUY",List.of(root),List.of(),List.of(new SupplyQuantityInput(null,root,new BigDecimal("2"),BigDecimal.ZERO)));
        var adopted=commands.notifySupply(target.analysisId(),request);commands.notifySupply(target.analysisId(),request);
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",Integer.class,target.analysisId()));
        amount("2",adopted.flatMaterials().stream().filter(row->row.materialLineId().equals(root)).findFirst().orElseThrow().preparationAdoptedQty());
    }
    @Test void explicitSalesPublicOutputCanArriveFirstWithoutTakingTheLaterSalesShare(){
        var mixed=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(mixed);mixed.prepare();
        Object c=ReflectionTestUtils.invokeMethod(mixed,"createStartedTask","public-claim-sales-"+UUID.randomUUID(),true);
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(c,"world");
        UUID product=ReflectionTestUtils.invokeMethod(c,"product"),planItem=ReflectionTestUtils.invokeMethod(c,"planItem");
        amount("1000",available(planItem));
        UUID targetRoot=UUID.randomUUID();support.fixture.insertGoods(targetRoot,"PUBLIC-SALES-TARGET-"+targetRoot,"销售公共份接收产品","自制",world.unitId(),world.unitLegacy());support.fixture.insertBom(targetRoot,product,"1");
        var target=analyses.preview(new PreviewRequest(null,null,null,world.warehouseId(),"sales-public-target-"+targetRoot,List.of(new PreviewItem("OTHER",null,targetRoot,null,world.unitId(),"sales-public-target-"+targetRoot,"销售公共份接收",BusinessTime.today().plusDays(10),new BigDecimal("1000")))));
        target=analyses.saveRoutes(target.analysisId(),new RouteRequest(target.version(),target.fingerprint(),"sales-public-route-"+targetRoot,target.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(product)||row.goodsId().equals(targetRoot)?"MAKE":"BUY",null)).toList()));
        UUID material=target.flatMaterials().stream().filter(row->row.goodsId().equals(product)).findFirst().orElseThrow().materialLineId();
        var request=new PreplanMakePublicSupplyService.ClaimRequest(target.version(),target.fingerprint(),"sales-public-claim-"+UUID.randomUUID(),planItem,material,new BigDecimal("1000"));
        ReflectionTestUtils.invokeMethod(commands,"claimMakePublicSupply",target.analysisId(),request);
        UUID claim=db.queryForObject("SELECT id FROM preplan_make_public_claims WHERE target_analysis_id=?",UUID.class,target.analysisId());
        List<com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(mixed,"sources",c);
        var publicSource=sources.stream().filter(row->row.orderItemId()==null).findFirst().orElseThrow();
        UUID publicReport=ReflectionTestUtils.invokeMethod(mixed,"approveReport",c,publicSource);
        UUID publicInbound=ReflectionTestUtils.invokeMethod(mixed,"finishInbound",c,publicReport);
        amount("1000",received(claim));amount("0",pending(claim));
        amount("1000",db.queryForObject("SELECT sum(qty) FROM preplan_analysis_stock_exact_pegs WHERE make_public_claim_id=?",BigDecimal.class,claim));
        sources=ReflectionTestUtils.invokeMethod(mixed,"sources",c);
        var salesSource=sources.stream().filter(row->row.orderItemId()!=null).findFirst().orElseThrow();
        UUID salesReport=ReflectionTestUtils.invokeMethod(mixed,"approveReport",c,salesSource);
        UUID salesInbound=ReflectionTestUtils.invokeMethod(mixed,"finishInbound",c,salesReport);
        amount("1000",received(claim));amount("0",available(planItem));
        amount("2000",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,product));
        ReflectionTestUtils.invokeMethod(mixed,"drainValuation",c);
        var stock=beans.getBean(com.uten.imp.features.stock.StockDocService.class);
        assertThrows(com.uten.imp.common.web.ApiException.class,()->stock.reverseFinishedInbound(publicInbound),"later receipt cost must be reversed first");
        stock.reverseFinishedInbound(salesInbound);ReflectionTestUtils.invokeMethod(mixed,"drainValuation",c);
        stock.reverseFinishedInbound(publicInbound);
        amount("0",received(claim));amount("1000",pending(claim));
        amount("0",db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,product));
    }
    @Test void aBoxPlanPublishesAndClaimsOnlyItsConvertedBasicUnitPublicShare(){
        var c=support.create(true,true,"1");UUID box=UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name) VALUES(?,?,'box')",box,"MAKE-PUBLIC-BOX-"+box);
        var order=support.fixture.orderRequest(c.world(),c.common(),"1","100");order.getItems().getFirst().setUnitId(box);order.getItems().getFirst().setUnitRate(new BigDecimal("20"));
        var sales=beans.getBean(com.uten.imp.features.sales.order.SalesOrderService.class);
        UUID orderId=sales.create(order).getId();sales.approve(orderId);ReflectionTestUtils.invokeMethod(support.fixture,"confirmInitialSalesFinance",orderId);
        UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,orderId);
        var source=analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),"box-public-analysis-"+orderId,List.of(new PreviewItem("SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),BigDecimal.ONE))));
        source=analyses.saveRoutes(source.analysisId(),new RouteRequest(source.version(),source.fingerprint(),"box-public-route-"+orderId,source.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(c.common())?"MAKE":"BUY",null)).toList()));
        var root=source.products().getFirst();assertEquals(box,root.unitId());
        var line=new IssueWorkshopPlansRequest.IssuePlanLine(null,root.analysisLineId(),new BigDecimal("2"),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO);
        UUID plan=commands.issueWorkshopPlans(source.analysisId(),new IssueWorkshopPlansRequest(source.version(),source.fingerprint(),"box-public-plan-"+orderId,c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),false,List.of(line))).plans().getFirst().planId();
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,plan);
        amount("20",available(planItem));
        assertEquals(c.world().unitId(),db.queryForObject("SELECT unit_id FROM v_preplan_make_public_supply_state WHERE source_plan_item_id=?",UUID.class,planItem));
        var target=target(c,"20");UUID material=target.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        var request=new PreplanMakePublicSupplyService.ClaimRequest(target.version(),target.fingerprint(),"box-public-claim-"+UUID.randomUUID(),planItem,material,new BigDecimal("20"));
        ReflectionTestUtils.invokeMethod(commands,"claimMakePublicSupply",target.analysisId(),request);
        amount("0",available(planItem));
        amount("20",db.queryForObject("SELECT sum(qty) FROM preplan_make_public_claims WHERE source_plan_item_id=?",BigDecimal.class,planItem));
        beans.getBean(com.uten.imp.features.production.plan.ProductionPlanService.class).approve(plan);
        amount("20",db.queryForObject("SELECT sum(fn_preplan_make_public_claim_pending_qty(id)) FROM preplan_make_public_claims WHERE source_plan_item_id=?",BigDecimal.class,planItem));
    }
    @Test void subcontractPreparationIsNotOfferedAsFinishedManufacturingSupply(){
        var c=support.create(true,true,"1");support.setRoute(c,c.common(),"SUBCONTRACT");
        var original=support.input(c,c.common(),"SUBCONTRACT","5",true);
        var group=new AggregateMaterialOrderContracts.GroupInput(original.clientGroupKey(),original.materialLineIds(),original.route(),original.qty(),true,c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO);
        var batch=writer.submit(c.analysis(),support.command(c,List.of(group))).batches().getFirst();
        assertNotNull(batch.planId());
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,batch.planId());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM v_preplan_make_public_supply_state WHERE source_plan_item_id=?",Integer.class,planItem));
        var target=target(c,"2");UUID material=target.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        assertThrows(RuntimeException.class,()->insertClaim(c,planItem,target.analysisId(),material,"1"));
    }
    @Test void cancellingAnUnreceivedAdoptionReleasesItsSourcePromiseAndReplaysWithoutAnotherEvent() {
        cancelAdoptingAnalysis(false,false);
    }
    @Test void cancellingAnUnusedReceivedAdoptionReleasesRealStockThenClosesItsPromise() {
        cancelAdoptingAnalysis(true,false);
    }
    @Test void cancellingAnAdoptingAnalysisWithADownstreamPlanKeepsItsClaimAndInventoryIntact() {
        cancelAdoptingAnalysis(true,true);
    }
    private void cancelAdoptingAnalysis(boolean receive,boolean downstream) {
        var c=support.create(true,true,"1");
        var source=writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","5",true)))).batches().getFirst();
        UUID item=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,source.planId());
        AnalysisView target=target(c,"2");UUID targetId=target.analysisId();
        UUID material=target.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        target=commands.claimMakePublicSupply(targetId,new PreplanMakePublicSupplyService.ClaimRequest(target.version(),target.fingerprint(),
                "cancel-target-adopt-"+UUID.randomUUID(),item,material,new BigDecimal("2")));
        UUID claim=db.queryForObject("SELECT id FROM preplan_make_public_claims WHERE target_analysis_id=?",UUID.class,targetId);
        if(receive)support.produce(c,source);
        if(downstream) {
            target=analyses.detail(targetId);ProductView root=target.products().stream().filter(row->"OTHER".equals(row.sourceType())).findFirst().orElseThrow();
            var line=new IssueWorkshopPlansRequest.IssuePlanLine(null,root.analysisLineId(),new BigDecimal("2"),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO);
            commands.issueWorkshopPlans(targetId,new IssueWorkshopPlansRequest(target.version(),target.fingerprint(),"cancel-target-plan-"+UUID.randomUUID(),
                    c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(line)));
        }
        target=analyses.detail(targetId);
        var cancelRequest=new CancelRequest(target.version(),target.fingerprint(),"cancel-target-analysis-"+UUID.randomUUID(),"取消接收分析，按真实原库存链释放未使用权益");
        if(downstream) {
            assertThrows(com.uten.imp.common.web.ApiException.class,()->commands.cancelAnalysis(targetId,cancelRequest));
            assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_make_public_claim_cancellations WHERE claim_id=?",Integer.class,claim));
            amount("2",received(claim));return;
        }
        assertEquals("CANCELLED",commands.cancelAnalysis(targetId,cancelRequest).status());
        assertEquals("CANCELLED",commands.cancelAnalysis(targetId,cancelRequest).status());
        amount("2",db.queryForObject("SELECT SUM(qty) FROM preplan_make_public_claim_cancellations WHERE claim_id=?",BigDecimal.class,claim));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM preplan_make_public_claim_cancellations WHERE claim_id=?",Integer.class,claim));
        amount("0",pending(claim));
        if(receive) {
            amount("0",available(item));
            amount("0",db.queryForObject("SELECT COALESCE(SUM(effective_qty),0) FROM v_preplan_stock_entitlement_beneficiary_balance WHERE beneficiary_analysis_id=?",BigDecimal.class,targetId));
            amount("5",db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.common()));
            UUID inbound=db.queryForObject("SELECT source_stock_document_id FROM preplan_analysis_stock_exact_pegs WHERE make_public_claim_id=?",UUID.class,claim);
            InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),db,List.of(c.common(),c.material()));
            beans.getBean(com.uten.imp.features.stock.StockDocService.class).reverseFinishedInbound(inbound);
            amount("0",pending(claim));amount("0",received(claim));amount("2",available(item));
            assertEquals("CANCELLED",analyses.detail(targetId).status());
        } else amount("2",available(item));
    }

    private UUID insertClaim(AggregateMaterialOrderEndToEndTest.Case c,UUID planItem,UUID analysis,UUID material,String qty){
        return new TransactionTemplate(transactions).execute(status->db.queryForObject("INSERT INTO preplan_make_public_claims(source_plan_item_id,target_analysis_id,target_material_id,qty,idempotency_key,request_hash,created_by) VALUES(?,?,?,?,?,?,?) RETURNING id",UUID.class,planItem,analysis,material,new BigDecimal(qty),"guard-"+UUID.randomUUID(),"0".repeat(64),c.world().superAdminUserId()));
    }
    private void cancel(AggregateMaterialOrderEndToEndTest.Case c,UUID claim,String qty){db.update("INSERT INTO preplan_make_public_claim_cancellations(claim_id,qty,reason,idempotency_key,request_hash,created_by) VALUES(?,?,?,?,?,?)",claim,new BigDecimal(qty),"撤回未实收供给","guard-cancel-"+UUID.randomUUID(),"0".repeat(64),c.world().superAdminUserId());}
    private AnalysisView target(AggregateMaterialOrderEndToEndTest.Case c,String qty){
        UUID root=UUID.randomUUID();support.fixture.insertGoods(root,"MAKE-PUBLIC-TARGET-"+root,"公共制造供给目标","自制",c.world().unitId(),c.world().unitLegacy());support.fixture.insertBom(root,c.common(),"1");
        var view=analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),"make-target-"+root,List.of(new PreviewItem("OTHER",null,root,null,c.world().unitId(),"make-target-"+root,"公共制造供给接收",BusinessTime.today().plusDays(10),new BigDecimal(qty)))));
        return analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"make-route-"+root,view.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(c.material())?"BUY":"MAKE",null)).toList()));
    }
    private BigDecimal available(UUID plan){return db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_make_public_supply_state WHERE source_plan_item_id=?",BigDecimal.class,plan);}
    private BigDecimal pending(UUID claim){return db.queryForObject("SELECT fn_preplan_make_public_claim_pending_qty(?)",BigDecimal.class,claim);}
    private BigDecimal received(UUID claim){return db.queryForObject("SELECT fn_preplan_make_public_claim_received_qty(?)",BigDecimal.class,claim);}
    private static void amount(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+" actual "+actual);}
}
