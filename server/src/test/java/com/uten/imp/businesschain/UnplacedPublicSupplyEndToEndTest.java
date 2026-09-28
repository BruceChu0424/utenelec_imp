package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderWriteService;
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
import java.util.concurrent.*;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
    "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
    "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
    "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class UnplacedPublicSupplyEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired AggregateMaterialOrderWriteService aggregateWriter;
    @Autowired PlatformTransactionManager transactions;
    FullChainEndToEndTest fixture;
    PreplanPublicFutureReplenishmentEndToEndTest support;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        support=new PreplanPublicFutureReplenishmentEndToEndTest();beans.autowireBean(support);ReflectionTestUtils.setField(support,"fixture",fixture);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void issuedRequestSurplusCanBeClaimedBeforeOrderingThenReceivedToItsExactOwner(){
        Case c=create("BUY");
        amount("900",available(c));amount("0",approved(c));
        amount("0",db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.goods));
        var first=claim(c,c.target,"400","first");
        amount("500",available(c));amount("400",material(first,c.goods).sharedFuturePendingQty());
        var excess=request(first,material(first,c.goods),"501",c.action,"too-much");
        assertThrows(ApiException.class,()->commands.claimSharedFuture(first.analysisId(),excess));
        amount("500",available(c));
        UUID claim=db.queryForObject("SELECT id FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SHARED_FUTURE_CLAIM'",UUID.class,first.analysisId());
        var cancel=new CancelRequest(first.version(),first.fingerprint(),"cancel-"+claim,"取消尚未商业订货的供给认领");
        var cancelled=commands.cancelAction(first.analysisId(),claim,cancel);commands.cancelAction(first.analysisId(),claim,cancel);
        amount("900",available(c));amount("0",material(cancelled,c.goods).sharedFuturePendingQty());
        var all=claim(c,cancelled,"900","all");amount("0",available(c));
        var source=analyses.detail(c.source.analysisId());
        ApiException rejected=assertThrows(ApiException.class,()->commands.cancelAction(source.analysisId(),c.action,
            new CancelRequest(source.version(),source.fingerprint(),"cancel-source-"+c.action,"来源仍被采用")));
        assertTrue(rejected.toString().contains("已被其他订单采用"));
        UUID order=ReflectionTestUtils.invokeMethod(support,"approveOrder",c.world,c.item,c.goods,"1000",BusinessTime.today().plusDays(5));
        amount("900",approved(c));amount("0",available(c));
        ReflectionTestUtils.invokeMethod(support,"receive",c.world,order,c.goods,"1000");fixture.loginAs(c.world.superAdminUserId());
        var received=analyses.detail(all.analysisId());
        amount("0",material(received,c.goods).sharedFuturePendingQty());
        amount("900",db.queryForObject("SELECT COALESCE(sum(exact.qty),0) FROM preplan_analysis_stock_exact_pegs exact JOIN preplan_supply_action_allocations a ON a.id=exact.supply_action_allocation_id WHERE a.analysis_id=?",BigDecimal.class,all.analysisId()));
        amount("1000",db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.goods));
        amount("0",available(c));
    }

    @Test void unplacedSubcontractSurplusUsesTheSameExactClaimBudget(){
        Case c=create("SUBCONTRACT");amount("900",available(c));amount("0",approved(c));
        var target=claim(c,c.target,"600","subcontract");amount("300",available(c));
        amount("600",material(target,c.goods).sharedFuturePendingQty());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM subcontract_order_items WHERE goods_id=? AND NOT is_deleted",Integer.class,c.goods));
    }

    @Test void competingAnalysesCannotBothSpendTheSameUnplacedSurplus() throws Exception {
        Case c=create("BUY");var another=target(c.world,c.goods,"competing");
        var ready=new CountDownLatch(2);var start=new CountDownLatch(1);
        try(var pool=Executors.newFixedThreadPool(2)){
            List<Future<Boolean>> futures=new ArrayList<>();
            for(var target:List.of(c.target,another)) futures.add(pool.submit(()->{
                fixture.loginAs(c.world.superAdminUserId());ready.countDown();start.await();
                try{claim(c,target,"600","race-"+target.analysisId());return true;}
                catch(ApiException rejected){return false;}finally{SecurityContextHolder.clearContext();}
            }));
            assertTrue(ready.await(10,TimeUnit.SECONDS));start.countDown();int successes=0;
            for(var result:futures)if(result.get(60,TimeUnit.SECONDS))successes++;
            assertEquals(1,successes);amount("300",available(c));
        }
    }

    @Test void anotherProductInTheSameAnalysisAdoptsUnplacedSupplyThenTheWholeAnalysisCancelsInDependencyOrder(){
        for(String route:List.of("BUY","SUBCONTRACT")){
            SameAnalysis c=sameAnalysis(route,false);
            var before=analyses.detail(c.view.analysisId());
            var request=notify(before,c.targetMaterial,route,"1000","same-target-"+UUID.randomUUID());
            var adopted=commands.notifySupply(before.analysisId(),request);commands.notifySupply(before.analysisId(),request);
            assertSameAnalysisFacts(c,adopted);
            assertSelfClaimRejected(c,c.sourceMaterial);
            var cancel=new CancelRequest(adopted.version(),adopted.fingerprint(),"cancel-same-"+UUID.randomUUID(),"先关闭内部认领再撤回同分析原申请");
            assertEquals("CANCELLED",commands.cancelAnalysis(adopted.analysisId(),cancel).status());
            assertEquals("CANCELLED",commands.cancelAnalysis(adopted.analysisId(),cancel).status());
            assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND status<>'CANCELLED'",Integer.class,adopted.analysisId()));
        }
    }

    @Test void aSourceCannotAdoptItsOwnSurplusThroughAnAggregateAlias(){
        for(String route:List.of("BUY","SUBCONTRACT")){
            SameAnalysis c=sameAnalysis(route,true);
            var before=analyses.detail(c.view.analysisId());
            var adopted=commands.notifySupply(before.analysisId(),notify(before,c.targetMaterial,route,"1000","same-alias-target-"+UUID.randomUUID()));
            assertSameAnalysisFacts(c,adopted);
            var aggregate=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(aggregate);aggregate.before();
            Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","same-alias-"+UUID.randomUUID());
            UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId"),worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
            var aggregateCase=new AggregateMaterialOrderEndToEndTest.Case(c.world,adopted.analysisId(),c.parent,c.parent,c.goods,workshop,worker);
            var batch=aggregateWriter.submit(adopted.analysisId(),aggregate.command(aggregateCase,List.of(aggregate.input(aggregateCase,c.parent,"MAKE","3000",true)))).batches().getFirst();
            UUID canonical=db.queryForObject("SELECT id FROM production_material_analysis_materials WHERE analysis_item_id=? AND goods_id=? AND active",UUID.class,batch.anchorAnalysisItemId(),c.goods);
            assertTrue(db.queryForObject("SELECT fn_preplan_public_target_is_source(?,?)",Boolean.class,c.action,canonical));
            assertSelfClaimRejected(c,canonical);
            amount("8000",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,c.action));
            // B's earlier, legal adoption remains reversible after A and B acquire a
            // common canonical row. New aliases must not rewrite historical identity.
            UUID claim=db.queryForObject("SELECT id FROM preplan_supply_actions WHERE claim_source_action_id=? AND status<>'CANCELLED'",UUID.class,c.action);
            var current=analyses.detail(adopted.analysisId());
            var cancel=new CancelRequest(current.version(),current.fingerprint(),"same-alias-cancel-"+UUID.randomUUID(),"撤回合单前已合法建立的认领");
            commands.cancelAction(current.analysisId(),claim,cancel);commands.cancelAction(current.analysisId(),claim,cancel);
            amount("9000",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,c.action));
        }
    }

    @Test void aMakeRootAdoptsExistingPurchasedGoodsWithoutCreatingAPlanOrItsChildDemand(){
        Case c=create("BUY");UUID raw=UUID.randomUUID();
        fixture.insertGoods(raw,"PUBLIC-ROOT-RAW-"+raw,"自制根件原料","采购",c.world.unitId(),c.world.unitLegacy());
        fixture.insertBom(c.goods,raw,"1");
        var target=analyses.preview(new PreviewRequest(null,null,null,c.world.warehouseId(),"public-root-"+UUID.randomUUID(),
                List.of(new PreviewItem("OTHER",null,c.goods,null,c.world.unitId(),"public-root-source-"+UUID.randomUUID(),"采用现有采购供给的自制根件",BusinessTime.today().plusDays(10),new BigDecimal("2")))));
        target=analyses.saveRoutes(target.analysisId(),new RouteRequest(target.version(),target.fingerprint(),"public-root-route-"+UUID.randomUUID(),
                target.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(c.goods)?"MAKE":"BUY",null)).toList()));
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","public-root-"+UUID.randomUUID());
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId"),worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        var root=target.products().getFirst();
        var line=new IssueWorkshopPlansRequest.IssuePlanLine(null,root.analysisLineId(),new BigDecimal("2"),null,null,workshop,null,worker,null,null,false,BigDecimal.ZERO);
        var request=new IssueWorkshopPlansRequest(target.version(),target.fingerprint(),"public-root-order-"+UUID.randomUUID(),c.world.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(line));
        assertTrue(commands.issueWorkshopPlans(target.analysisId(),request).plans().isEmpty());
        assertTrue(commands.issueWorkshopPlans(target.analysisId(),request).plans().isEmpty());
        var adopted=analyses.detail(target.analysisId());var supplied=material(adopted,c.goods);
        amount("2",supplied.preparationAdoptedQty());assertEquals("BUY_REQUESTED",supplied.flowStage());
        amount("0",material(adopted,raw).requiredQty());amount("898",available(c));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted",Integer.class,target.analysisId()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",Integer.class,target.analysisId()));
    }
    @Test void onlyOriginalBCanAdoptAfterItsParentHasAlreadyMergedWithSourceA(){
        for(String route:List.of("BUY","SUBCONTRACT")){
            SameAnalysis c=sameAnalysis(route,true);
            var aggregate=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(aggregate);aggregate.before();
            Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","claim-after-parent-"+UUID.randomUUID());
            UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId"),worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
            var aggregateCase=new AggregateMaterialOrderEndToEndTest.Case(c.world,c.view.analysisId(),c.parent,c.parent,c.goods,workshop,worker);
            var batch=aggregateWriter.submit(c.view.analysisId(),aggregate.command(aggregateCase,List.of(aggregate.input(aggregateCase,c.parent,"MAKE","2000",false)))).batches().getFirst();
            UUID canonical=db.queryForObject("SELECT id FROM production_material_analysis_materials WHERE analysis_item_id=? AND goods_id=? AND active",UUID.class,batch.anchorAnalysisItemId(),c.goods);
            var merged=analyses.detail(c.view.analysisId());
            amount("1000",byId(merged,canonical).preparationOwnedAvailableQty());
            amount("1000",byId(merged,c.sourceMaterial).preparationOwnedAvailableQty());amount("0",byId(merged,c.targetMaterial).preparationOwnedAvailableQty());
            var group=new com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput("after-parent-b",List.of(c.targetMaterial),route,
                    new BigDecimal("1000"),false,null,null,null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO,Map.of(c.targetMaterial,new BigDecimal("1000")));
            var request=aggregate.command(aggregateCase,List.of(group));
            var result=aggregateWriter.submit(merged.analysisId(),request);assertTrue(result.batches().isEmpty());
            assertTrue(aggregateWriter.submit(merged.analysisId(),request).replayed());var adopted=result.analysis();
            assertSameAnalysisFacts(c,adopted);amount("2000",byId(adopted,canonical).preparationOwnedAvailableQty());
            amount("0",byId(adopted,c.sourceMaterial).preparationAdoptedQty());amount("1000",byId(adopted,c.targetMaterial).preparationAdoptedQty());
            amount("1000",db.queryForObject("SELECT sum(allocation.allocated_qty) FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE action.claim_source_action_id=? AND allocation.analysis_material_id=? AND action.status<>'CANCELLED'",BigDecimal.class,c.action,c.targetMaterial));
            assertSelfClaimRejected(c,c.sourceMaterial);assertSelfClaimRejected(c,canonical);
        }
    }

    private SameAnalysis sameAnalysis(String route,boolean nested){
        var world=fixture.seedWorld("same-public-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        UUID goods=UUID.randomUUID();fixture.insertGoods(goods,"SAME-PUBLIC-"+goods,"同单共享物料",route.equals("BUY")?"采购":"委外",world.unitId(),world.unitLegacy());
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",world.supplierId(),goods);
        UUID parent=nested?UUID.randomUUID():goods;
        if(nested){fixture.insertGoods(parent,"SAME-PARENT-"+parent,"同单共有父件","自制",world.unitId(),world.unitLegacy());fixture.insertBom(parent,goods,"1");}
        List<PreviewItem> inputs=new ArrayList<>();
        for(int index=0;index<2;index++){
            UUID root=UUID.randomUUID();fixture.insertGoods(root,"SAME-ROOT-"+root,"同单产品"+index,"自制",world.unitId(),world.unitLegacy());fixture.insertBom(root,parent,"1");
            inputs.add(new PreviewItem("OTHER",null,root,null,world.unitId(),"same-source-"+root,"同单供给认领回归",BusinessTime.today().plusDays(10),new BigDecimal("1000")));
        }
        var view=analyses.preview(new PreviewRequest(null,null,null,world.warehouseId(),"same-analysis-"+UUID.randomUUID(),inputs));
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"same-route-"+UUID.randomUUID(),view.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(goods)?route:"MAKE",null)).toList()));
        var targets=view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)).toList();assertEquals(2,targets.size());
        var source=commands.notifySupply(view.analysisId(),notify(view,targets.getFirst().materialLineId(),route,"10000","same-source-"+UUID.randomUUID()));
        UUID action=db.queryForObject("SELECT id FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",UUID.class,view.analysisId());
        amount("9000",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,action));
        UUID allocation=db.queryForObject("SELECT id FROM preplan_supply_action_allocations WHERE action_id=?",UUID.class,action);
        amount("0",db.queryForObject("SELECT fn_preplan_future_source_private_capacity_qty(?)",BigDecimal.class,allocation));
        amount("1000",db.queryForObject("SELECT fn_preplan_future_source_planning_private_capacity_qty(?)",BigDecimal.class,allocation));
        amount("1000",db.queryForObject("SELECT fn_preplan_future_allocation_pending_qty(?)",BigDecimal.class,allocation));
        return new SameAnalysis(world,goods,parent,source,targets.getFirst().materialLineId(),targets.getLast().materialLineId(),action);
    }
    private NotifyRequest notify(AnalysisView view,UUID material,String route,String qty,String key){return new NotifyRequest(view.version(),view.fingerprint(),key,route,List.of(material),List.of(),List.of(new SupplyQuantityInput(null,material,new BigDecimal(qty),BigDecimal.ZERO)));}
    private void assertSameAnalysisFacts(SameAnalysis c,AnalysisView adopted){
        assertEquals(1,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND goods_id=? AND operation_type='SUPPLY'",Integer.class,adopted.analysisId(),c.goods));
        amount("10000",db.queryForObject("SELECT requested_qty+public_surplus_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,c.action));
        amount("10000",db.queryForObject("""
                SELECT COALESCE((SELECT item.qty*item.unit_rate FROM purchase_request_items item WHERE item.id=action.public_surplus_external_item_id),
                    (SELECT item.qty*item.unit_rate FROM subcontract_application_items item WHERE item.id=action.public_surplus_external_item_id))
                FROM preplan_supply_actions action WHERE action.id=?
                """,BigDecimal.class,c.action));
        amount("1000",db.queryForObject("SELECT sum(requested_qty) FROM preplan_supply_actions WHERE claim_source_action_id=? AND status<>'CANCELLED'",BigDecimal.class,c.action));
        amount("8000",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,c.action));
        amount("1000",adopted.flatMaterials().stream().filter(row->row.materialLineId().equals(c.targetMaterial)).findFirst().orElseThrow().preparationAdoptedQty());
        var source=adopted.flatMaterials().stream().filter(row->row.materialLineId().equals(c.sourceMaterial)).findFirst().orElseThrow();
        var target=adopted.flatMaterials().stream().filter(row->row.materialLineId().equals(c.targetMaterial)).findFirst().orElseThrow();
        assertEquals(1,source.preparationSharedSupplySlices().size());assertEquals(1,target.preparationSharedSupplySlices().size());
        var sourceSlice=source.preparationSharedSupplySlices().getFirst();var targetSlice=target.preparationSharedSupplySlices().getFirst();
        assertEquals(sourceSlice.key(),targetSlice.key());assertTrue(sourceSlice.key().matches("[0-9a-f]{64}"));
        assertFalse(sourceSlice.key().contains(c.action.toString()));
        amount("8000",sourceSlice.availableQty());amount("8000",targetSlice.availableQty());
        assertFalse(sourceSlice.adoptable());assertTrue(targetSlice.adoptable());
    }
    private void assertSelfClaimRejected(SameAnalysis c,UUID material){
        assertTrue(db.queryForObject("SELECT fn_preplan_public_target_is_source(?,?)",Boolean.class,c.action,material));
        UUID probe=UUID.randomUUID();
        RuntimeException rejected=assertThrows(RuntimeException.class,()->new TransactionTemplate(transactions).executeWithoutResult(status->{
            db.update("""
                INSERT INTO preplan_supply_actions(id,analysis_id,warehouse_id,goods_id,color_id,unit_id,need_date,route,requested_qty,status,
                  external_document_type,external_document_id,external_document_no,operation_type,claim_source_action_id,
                  idempotency_key,action_group_key,request_business_key,generation,predecessor_action_id,request_hash,created_by)
                SELECT ?,analysis_id,warehouse_id,goods_id,color_id,unit_id,need_date,route,1,'CREATED',
                  external_document_type,external_document_id,external_document_no,operation_type,claim_source_action_id,
                  ?,action_group_key,?,generation+1,id,request_hash,created_by
                FROM preplan_supply_actions WHERE claim_source_action_id=? AND status<>'CANCELLED'
                """,probe,"same-self-"+probe,probe.toString().replace("-","").repeat(2),c.action);
            db.update("""
                INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty,external_item_id,created_by)
                SELECT ?,analysis_id,?,?,1,public_surplus_external_item_id,created_by FROM preplan_supply_actions WHERE id=?
                """,UUID.randomUUID(),probe,material,c.action);
            db.execute("SET CONSTRAINTS ALL IMMEDIATE");
        }));
        assertTrue(rejected.toString().contains("invalid or over-capacity shared future claim"),rejected.toString());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE id=?",Integer.class,probe));
    }
    private record SameAnalysis(FullChainEndToEndTest.World world,UUID goods,UUID parent,AnalysisView view,UUID sourceMaterial,UUID targetMaterial,UUID action){}

    private Case create(String route){
        var world=fixture.seedWorld("unplaced-"+route+"-"+UUID.randomUUID().toString().substring(0,8));fixture.loginAs(world.superAdminUserId());
        UUID goods=UUID.randomUUID();fixture.insertGoods(goods,"UNPLACED-"+goods,"未操作公共物料",route.equals("BUY")?"采购":"委外",world.unitId(),world.unitLegacy());
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",world.supplierId(),goods);
        var source=target(world,goods,"source");var sm=material(source,goods);
        if(!route.equals(sm.sourceConfirmed()))source=analyses.saveRoutes(source.analysisId(),new RouteRequest(source.version(),source.fingerprint(),"route-"+source.analysisId(),List.of(new RouteDecision(sm.materialLineId(),sm.actionGroupKey(),route,null))));
        sm=material(source,goods);
        commands.notifySupply(source.analysisId(),new NotifyRequest(source.version(),source.fingerprint(),"source-"+source.analysisId(),route,
            List.of(sm.materialLineId()),List.of(),List.of(new SupplyQuantityInput(null,sm.materialLineId(),new BigDecimal("1000"),BigDecimal.ZERO))));
        Map<String,Object> row=db.queryForMap("SELECT id,public_surplus_external_item_id item FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",source.analysisId());
        var target=target(world,goods,"target");
        if(!route.equals(material(target,goods).sourceConfirmed()))target=analyses.saveRoutes(target.analysisId(),new RouteRequest(target.version(),target.fingerprint(),"route-"+target.analysisId(),List.of(new RouteDecision(material(target,goods).materialLineId(),material(target,goods).actionGroupKey(),route,null))));
        return new Case(world,goods,source,target,(UUID)row.get("id"),(UUID)row.get("item"));
    }
    private AnalysisView target(FullChainEndToEndTest.World world,UUID goods,String label){
        UUID product=UUID.randomUUID();fixture.insertGoods(product,"UNPLACED-P-"+product,"公共供给接收产品","自制",world.unitId(),world.unitLegacy());fixture.insertBom(product,goods,"1");
        return ReflectionTestUtils.invokeMethod(support,"preview",world,world.warehouseId(),product,goods,label,label.equals("source")?"100":"1000",BusinessTime.today().plusDays(10));
    }
    private AnalysisView claim(Case c,AnalysisView target,String qty,String key){return commands.claimSharedFuture(target.analysisId(),request(target,material(target,c.goods),qty,c.action,key+target.analysisId()));}
    private ClaimSharedFutureRequest request(AnalysisView target,MaterialView m,String qty,UUID source,String key){return new ClaimSharedFutureRequest(target.version(),target.fingerprint(),key,List.of(m.actionGroupKey()),List.of(new SharedFutureClaimQuantity(m.actionGroupKey(),new BigDecimal(qty),source)),true);}
    private BigDecimal available(Case c){return db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,c.action);}
    private BigDecimal approved(Case c){return db.queryForObject("SELECT approved_open_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,c.action);}
    private MaterialView material(AnalysisView view,UUID goods){return view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)).findFirst().orElseThrow();}
    private MaterialView byId(AnalysisView view,UUID material){return view.flatMaterials().stream().filter(row->row.materialLineId().equals(material)).findFirst().orElseThrow();}
    private static void amount(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+" actual "+actual);}
    private record Case(FullChainEndToEndTest.World world,UUID goods,AnalysisView source,AnalysisView target,UUID action,UUID item){}
}
