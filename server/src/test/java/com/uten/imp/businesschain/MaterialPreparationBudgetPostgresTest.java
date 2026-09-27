package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import jakarta.persistence.EntityManager;
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
class MaterialPreparationBudgetPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired EntityManager em;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired AggregateMaterialOrderWriteService writer;
    AggregateMaterialOrderEndToEndTest support;
    @BeforeEach void prepare(){support=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(support);support.before();}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void threeBomOccurrencesShareOnePhysicalWarehousePoolInsteadOfTriplingIt(){
        var c=support.create(false,false,"10");support.receive(c,c.material(),"100");
        var view=analyses.detail(c.analysis());var budget=read(view);
        var rows=view.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())).toList();assertEquals(3,rows.size());
        Set<String> pools=new HashSet<>(),sliceKeys=new HashSet<>();for(var row:rows){pools.add(budget.pools().get(row.materialLineId()));amount("100",shared(budget,row.materialLineId()));sliceKeys.add(slice(row,"100",true));}
        assertEquals(1,pools.size());amount("100",budget.shared().get(pools.iterator().next()));
        assertEquals(1,sliceKeys.size(),"the repeated physical pool exposes one stable opaque identity");
        amount("100",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.material()));
    }
    @Test void aTenThousandMakeOrderHasOneThousandPrivateAndNineThousandShared(){
        var c=support.create(true,true,"1000");var before=analyses.detail(c.analysis());
        UUID original=before.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        UUID plan=issue(c,before,original,"10000");
        var view=analyses.detail(c.analysis());var budget=read(view);
        amount("1000",budget.privatePending().get(original));amount("9000",shared(budget,original));
        Set<String> slices=new HashSet<>();
        for(var row:view.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).toList()){
            amount(row.materialLineId().equals(original)?"1000":"0",owned(row));amount("9000",shared(budget,row.materialLineId()));
            slices.add(slice(row,"9000",!row.materialLineId().equals(original)));
        }
        assertEquals(1,slices.size());assertFalse(slices.iterator().next().contains(plan.toString()));
        amount("10000",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=?",BigDecimal.class,plan));
        amount("0",db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.common()));
    }
    @Test void receiptAndReversalChangeFutureToPhysicalWithoutPublishingPrivateStock(){
        var c=support.create(true,true,"1");var before=analyses.detail(c.analysis());
        UUID original=before.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        UUID plan=issue(c,before,original,"5");var pendingView=analyses.detail(c.analysis());var pending=read(pendingView);
        amount("1",pending.privatePending().get(original));amount("4",shared(pending,original));
        String futureSlice=slice(material(pendingView,original),"4",false);
        support.produce(c,new AggregateMaterialOrderContracts.BatchResult(null,null,"MAKE",null,null,null,plan,null,new BigDecimal("5"),new BigDecimal("4"),List.of()));
        var receivedView=analyses.detail(c.analysis());var received=read(receivedView);
        UUID actualWarehouse=db.queryForObject("SELECT DISTINCT document.warehouse_id FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id JOIN production_plan_items source ON source.id=item.upstream_item_id WHERE source.plan_id=? AND document.doc_type='FINISHED_IN' AND document.status=1 AND NOT document.is_deleted AND NOT item.is_deleted",UUID.class,plan);
        String actualWarehouseName=db.queryForObject("SELECT name FROM warehouses WHERE id=?",String.class,actualWarehouse);
        assertEquals(actualWarehouse,db.queryForObject("SELECT owning_warehouse_id FROM goods WHERE id=?",UUID.class,c.common()));
        assertOwner(receivedView,c.common(),actualWarehouse,actualWarehouseName);
        amount("0",received.privatePending().getOrDefault(original,BigDecimal.ZERO));amount("4",shared(received,original));
        amount("1",owned(material(receivedView,original)));
        assertNotEquals(futureSlice,slice(material(receivedView,original),"4",true));
        amount("0",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_make_public_supply_state WHERE source_plan_id=?",BigDecimal.class,plan));
        var other=otherAnalysis(c,c.common(),"2");var otherRow=other.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow();
        amount("4",shared(read(other),otherRow.materialLineId()));amount("0",owned(otherRow));
        UUID inbound=db.queryForObject("SELECT DISTINCT item.doc_id FROM stock_document_items item JOIN production_plan_items source ON source.id=item.upstream_item_id WHERE source.plan_id=? AND fn_finished_in_is_public_output(item.id) AND NOT item.is_deleted",UUID.class,plan);
        InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),db,List.of(c.common(),c.material()));
        beans.getBean(com.uten.imp.features.stock.StockDocService.class).reverseFinishedInbound(inbound);
        var reversedView=analyses.detail(c.analysis());var reversed=read(reversedView);
        amount("4",shared(reversed,original));amount("0",reversed.privatePending().getOrDefault(original,BigDecimal.ZERO));amount("1",owned(material(reversedView,original)));
        assertEquals(futureSlice,slice(material(reversedView,original),"4",false));
        amount("4",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_make_public_supply_state WHERE source_plan_id=?",BigDecimal.class,plan));
        amount("1",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.common()));
        UUID reassigned=UUID.randomUUID();String reassignedName="新的货品归属仓";
        db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",reassigned,"OWNER-"+reassigned,reassignedName);
        long unchangedVersion=reversedView.version();String unchangedFingerprint=reversedView.fingerprint();
        beans.getBean(GoodsOwningWarehouseWriteService.class).applyOwningWarehouses(List.of(new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(c.common(),reassigned)));
        var reassignedView=analyses.detail(c.analysis());assertEquals(unchangedVersion,reassignedView.version());assertEquals(unchangedFingerprint,reassignedView.fingerprint());
        assertOwner(reassignedView,c.common(),reassigned,reassignedName);
        amount("1",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",BigDecimal.class,c.common(),actualWarehouse));
        amount("0",db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",BigDecimal.class,c.common(),reassigned));
    }
    @Test void inheritedChildPromiseLeavesItsOriginalEditingBudgetExactlyOnce(){
        var c=support.create(true,true,"1");var supply=writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","5",true)))).batches().getFirst();
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?",UUID.class,supply.planId());
        UUID parent=UUID.randomUUID();support.fixture.insertGoods(parent,"BUDGET-PARENT-"+parent,"预算继承父件","自制",c.world().unitId(),c.world().unitLegacy());support.fixture.insertBom(parent,c.common(),"1");
        var target=otherAnalysis(c,parent,"3");UUID original=target.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow().materialLineId();
        commands.claimMakePublicSupply(target.analysisId(),new PreplanMakePublicSupplyService.ClaimRequest(target.version(),target.fingerprint(),"budget-claim-"+UUID.randomUUID(),planItem,original,BigDecimal.ONE));
        var targetCase=new AggregateMaterialOrderEndToEndTest.Case(c.world(),target.analysisId(),parent,c.common(),c.material(),c.workshop(),c.worker());
        var issued=writer.submit(target.analysisId(),support.command(targetCase,List.of(support.input(targetCase,parent,"MAKE","3",false)))).batches().getFirst();
        UUID canonical=db.queryForObject("SELECT id FROM production_material_analysis_materials WHERE analysis_item_id=? AND goods_id=? AND active",UUID.class,issued.anchorAnalysisItemId(),c.common());
        var current=analyses.detail(target.analysisId());var budget=read(current);
        amount("1",budget.outgoingPending().get(original));amount("1",shared(budget,canonical));
        // The old row first loses its outgoing promise, then receives the canonical
        // row's one-unit display share back. Without outgoing subtraction it shows 2.
        amount("1",owned(material(current,original)));amount("1",owned(material(current,canonical)));
    }
    @Test void aLaterParentMergePreservesAPrivateMakeCommitmentThenOnlyBAdoptsItsPublicRemainder(){
        var seed=support.create(true,true,"1");UUID parent=UUID.randomUUID();
        support.fixture.insertGoods(parent,"PRIVATE-PARENT-"+parent,"已有私有制造供给的共同父件","自制",seed.world().unitId(),seed.world().unitLegacy());
        support.fixture.insertBom(parent,seed.common(),"1");List<PreviewItem> inputs=new ArrayList<>();
        for(int index=0;index<2;index++){
            UUID root=UUID.randomUUID();support.fixture.insertGoods(root,"PRIVATE-ROOT-"+root,"私有归属产品"+index,"自制",seed.world().unitId(),seed.world().unitLegacy());
            support.fixture.insertBom(root,parent,"1");inputs.add(new PreviewItem("OTHER",null,root,null,seed.world().unitId(),"private-source-"+root,"合单后仍保留私有权益",BusinessTime.today().plusDays(10),new BigDecimal("1000")));
        }
        var view=analyses.preview(new PreviewRequest(null,null,null,seed.world().warehouseId(),"private-parent-analysis-"+UUID.randomUUID(),inputs));
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"private-parent-routes-"+UUID.randomUUID(),
                view.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(seed.material())?"BUY":"MAKE",null)).toList()));
        var c=new AggregateMaterialOrderEndToEndTest.Case(seed.world(),view.analysisId(),seed.common(),parent,seed.material(),seed.workshop(),seed.worker());
        var rows=view.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).toList();assertEquals(2,rows.size());
        UUID originalA=rows.getFirst().materialLineId(),originalB=rows.getLast().materialLineId();
        UUID sourcePlan=issue(c,view,originalA,"10000");
        var parentBatch=writer.submit(c.analysis(),support.command(c,List.of(support.input(c,parent,"MAKE","2000",false)))).batches().getFirst();
        UUID canonical=db.queryForObject("SELECT id FROM production_material_analysis_materials WHERE analysis_item_id=? AND goods_id=? AND active",UUID.class,parentBatch.anchorAnalysisItemId(),c.common());
        var merged=analyses.detail(c.analysis());
        System.out.println("MAKE-PRIVATE-INHERIT "+db.queryForList("""
                SELECT item.qty plan_qty,link.submitted_qty private_qty,link.public_surplus_qty public_qty,
                  link.submitted_qty-link.public_surplus_qty old_double_subtracted_qty,
                  (SELECT COALESCE(sum(fn_preplan_aggregate_alias_qty(alias.id)),0) FROM preplan_aggregate_material_aliases alias WHERE alias.source_material_id=? AND alias.aggregate_material_id=?) alias_quota,
                  (SELECT COALESCE(sum(arranged_qty),0) FROM fn_preplan_aggregate_direct_make_sources(?)) direct_arranged_qty,
                  (SELECT COALESCE(sum(pending_qty),0) FROM fn_preplan_aggregate_direct_make_sources(?)) direct_pending_qty
                FROM production_plan_items item JOIN production_material_analysis_plan_links link ON link.plan_id=item.plan_id
                WHERE item.plan_id=? AND NOT item.is_deleted
                """,originalA,canonical,originalA,originalA,sourcePlan));
        amount("1000",owned(material(merged,canonical)));
        amount("1000",owned(material(merged,originalA)));amount("0",owned(material(merged,originalB)));
        amount("1000",db.queryForObject("SELECT COALESCE(sum(fn_preplan_aggregate_alias_qty(id)),0) FROM preplan_aggregate_material_aliases WHERE source_material_id=? AND aggregate_material_id=?",BigDecimal.class,originalA,canonical));
        var group=new AggregateMaterialOrderContracts.GroupInput("private-parent-adopt-b",List.of(originalB),"MAKE",new BigDecimal("1000"),false,
                c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO,Map.of(originalB,new BigDecimal("1000")));
        var request=support.command(c,List.of(group));
        assertTrue(writer.submit(c.analysis(),request).batches().isEmpty());
        assertTrue(writer.submit(c.analysis(),request).replayed());
        var adopted=analyses.detail(c.analysis());amount("2000",owned(material(adopted,canonical)));
        amount("1000",owned(material(adopted,originalA)));amount("1000",owned(material(adopted,originalB)));
        amount("0",material(adopted,originalA).preparationAdoptedQty());amount("1000",material(adopted,originalB).preparationAdoptedQty());
        amount("8000",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_make_public_supply_state WHERE source_plan_id=?",BigDecimal.class,sourcePlan));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id WHERE plan.material_analysis_id=? AND item.goods_id=? AND NOT plan.is_deleted AND NOT item.is_deleted",Integer.class,c.analysis(),c.common()));
        amount("10000",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=?",BigDecimal.class,sourcePlan));
    }
    @Test void threeIndependentContributionsTotalTenThousandAndLeaveSevenThousandUnassigned(){
        for(String route:List.of("BUY","MAKE"))wholeAnalysisContribution(route,false);
    }
    @Test void independentTenThousandPlusTwoThousandsRemainTwelveThousand(){
        for(String route:List.of("BUY","MAKE"))wholeAnalysisContribution(route,true);
    }
    private void wholeAnalysisContribution(String route,boolean manualSiblings){
        var c=support.createWithChild("1000");UUID goods=c.child();
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",c.world().supplierId(),goods);support.setRoute(c,goods,route);
        var before=analyses.detail(c.analysis());
        List<UUID> originals=before.flatMaterials().stream().filter(row->row.goodsId().equals(goods)).map(MaterialView::materialLineId).toList();
        assertEquals(3,originals.size());for(UUID id:originals)amount("1000",material(before,id).requiredQty());
        writer.submit(c.analysis(),support.command(c,List.of(support.input(c,c.common(),"MAKE","3000",false))));
        BigDecimal sibling=new BigDecimal("1000");
        BigDecimal total=new BigDecimal(manualSiblings?"12000":"10000");
        Map<UUID,BigDecimal> contributions=Map.of(originals.get(0),new BigDecimal(manualSiblings?"10000":"8000"),originals.get(1),sibling,originals.get(2),sibling);
        var input=new AggregateMaterialOrderContracts.GroupInput("whole-analysis-copper",originals,route,total,true,
                route.equals("MAKE")?c.workshop():null,route.equals("MAKE")?c.worker():null,null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO,contributions);
        var command=support.command(c,List.of(input));var result=writer.submit(c.analysis(),command);
        assertEquals(1,result.batches().size());var batch=result.batches().getFirst();amount(total.toPlainString(),batch.qty());
        assertTrue(writer.submit(c.analysis(),command).replayed());
        UUID action=db.queryForObject("SELECT id FROM preplan_supply_actions WHERE analysis_id=? AND goods_id=? AND operation_type IN('SUPPLY','AGGREGATE_SUPPLY') AND status<>'CANCELLED'",UUID.class,c.analysis(),goods);
        amount("3000",db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,action));
        amount("3000",db.queryForObject("SELECT sum(allocated_qty) FROM preplan_supply_action_allocations WHERE action_id=?",BigDecimal.class,action));
        String free=manualSiblings?"9000":"7000";
        amount(free,db.queryForObject("SELECT public_surplus_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,action));
        if(route.equals("BUY"))amount(total.toPlainString(),db.queryForObject("SELECT sum(qty*unit_rate) FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,batch.documentId()));
        else amount(total.toPlainString(),db.queryForObject("SELECT sum(qty*unit_rate) FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,batch.planId()));
        for(UUID id:originals){var row=material(result.analysis(),id);amount("1000",row.preparationOwnedAvailableQty());amount(free,row.preparationSharedAvailableQty());
            amount(contributions.get(id).toPlainString(),row.aggregatePreparation().orderedQty());}
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND goods_id=? AND operation_type='SHARED_FUTURE_CLAIM'",Integer.class,c.analysis(),goods));
    }
    private UUID issue(AggregateMaterialOrderEndToEndTest.Case c,AnalysisView view,UUID original,String qty){
        var line=new IssueWorkshopPlansRequest.IssuePlanLine(original,null,new BigDecimal(qty),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO);
        return commands.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"budget-order-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(line))).plans().getFirst().planId();
    }
    private AnalysisView otherAnalysis(AggregateMaterialOrderEndToEndTest.Case c,UUID component,String qty){
        UUID root=UUID.randomUUID();support.fixture.insertGoods(root,"BUDGET-ROOT-"+root,"预算核对产品","自制",c.world().unitId(),c.world().unitLegacy());support.fixture.insertBom(root,component,"1");
        var view=analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),"budget-analysis-"+root,List.of(new PreviewItem("OTHER",null,root,null,c.world().unitId(),"budget-source-"+root,"可用预算专项",BusinessTime.today().plusDays(10),new BigDecimal(qty)))));
        return analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"budget-route-"+root,view.flatMaterials().stream().filter(MaterialView::actionable).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(c.material())?"BUY":"MAKE",null)).toList()));
    }
    private MaterialPreparationBudgetTestAccess.Facts read(AnalysisView view){var transaction=new TransactionTemplate(transactions);transaction.setReadOnly(true);return transaction.execute(status->MaterialPreparationBudgetTestAccess.read(em,view));}
    private static BigDecimal shared(MaterialPreparationBudgetTestAccess.Facts facts,UUID material){return facts.shared().getOrDefault(facts.pools().get(material),BigDecimal.ZERO);}
    private static BigDecimal owned(MaterialView row){return ReflectionTestUtils.invokeMethod(row,"preparationOwnedAvailableQty");}
    private static void assertOwner(AnalysisView view,UUID goods,UUID warehouse,String name){
        var materials=view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)).toList();assertFalse(materials.isEmpty());
        for(var material:materials){assertEquals(warehouse,material.owningWarehouseId());assertEquals(name,material.owningWarehouseName());}
        for(var product:view.products().stream().filter(row->row.goodsId().equals(goods)).toList()){assertEquals(warehouse,product.owningWarehouseId());assertEquals(name,product.owningWarehouseName());}
    }
    private static String slice(MaterialView row,String qty,boolean adoptable){
        var slices=row.preparationSharedSupplySlices();assertNotNull(slices);assertEquals(1,slices.size());
        var slice=slices.getFirst();assertTrue(slice.key().matches("[0-9a-f]{64}"),"only an opaque digest leaves the reader");
        amount(qty,slice.availableQty());assertEquals(adoptable,slice.adoptable());return slice.key();
    }
    private static MaterialView material(AnalysisView view,UUID id){return view.flatMaterials().stream().filter(row->row.materialLineId().equals(id)).findFirst().orElseThrow();}
    private static void amount(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+" actual "+actual);}
}
