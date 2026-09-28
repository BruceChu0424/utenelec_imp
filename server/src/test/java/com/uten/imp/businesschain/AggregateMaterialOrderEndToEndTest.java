package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import com.uten.imp.security.AuthUser;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.*;
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
class AggregateMaterialOrderEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService ordinary;
    @Autowired AggregateMaterialOrderPreviewService preview;
    @Autowired AggregateMaterialOrderWriteService writer;
    FullChainEndToEndTest fixture;
    @BeforeEach void before(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void after(){SecurityContextHolder.clearContext();}

    @Test void threeSourcesProduceOneRealPurchaseLineAndOnePublicAppend(){
        Case c=create(false,false,"10");GroupInput group=input(c,c.material(),"BUY","60",false);
        AuthUser admin=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();Set<String> grants=new HashSet<>(admin.getPermissions());grants.remove("production_plan:approve");grants.remove("production_material_analysis:generate");
        AuthUser buyer=new AuthUser(admin.getId(),admin.getEmployeeId(),admin.getUsername(),grants,false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(buyer,null,buyer.getAuthorities()));
        var command=command(c,List.of(group));var result=writer.submit(c.analysis(),command);
        assertEquals(1,result.batches().size());var batch=result.batches().getFirst();assertEquals("PURCHASE_REQUEST",batch.documentType());
        assertEquals(1,count("SELECT count(*) FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",batch.documentId()));
        amount("60",db.queryForObject("SELECT qty FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,batch.documentId()));
        assertEquals(3,count("SELECT count(*) FROM preplan_supply_action_allocations WHERE action_id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",batch.batchId()));
        assertTrue(writer.submit(c.analysis(),command).replayed());
        var extra=writer.submit(c.analysis(),command(c,List.of(input(c,c.material(),"BUY","12",true))));
        assertEquals(batch.batchId(),extra.batches().getFirst().batchId());assertEquals(batch.documentId(),extra.batches().getFirst().documentId());
        amount("72",db.queryForObject("SELECT qty FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,batch.documentId()));
        amount("60",db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",BigDecimal.class,batch.batchId()));
        amount("12",db.queryForObject("SELECT public_surplus_qty FROM preplan_supply_actions WHERE id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",BigDecimal.class,batch.batchId()));
        var displayed=preview.preview(c.analysis(),request(c,List.of(input(c,c.material(),"BUY","0",false))));
        amount("72",displayed.groups().getFirst().orderedQty());amount("0",displayed.groups().getFirst().remainingQty());
    }

    @Test void sharedManufacturingFreezesOneRoundedPhysicalRecipe(){
        Case c=create(true,true,"1");var shown=preview.preview(c.analysis(),request(c,List.of(input(c,c.common(),"MAKE","3",false))));
        amount("1",shown.groups().getFirst().sharedBomChildren().getFirst().requiredQty());
        var result=writer.submit(c.analysis(),submit(shown,request(c,List.of(input(c,c.common(),"MAKE","3",false)))));
        var batch=result.batches().getFirst();assertEquals(1,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        assertNotEquals("CANCELLED",db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",String.class,batch.batchId()));
        amount("3",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,batch.planId()));
        amount("1",db.queryForObject("SELECT required_qty FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,batch.planId()));
        assertEquals(3,count("SELECT count(*) FROM preplan_supply_action_allocations WHERE action_id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",batch.batchId()));
        amount("1",analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.goodsId().equals(c.material())).map(MaterialView::requiredQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        assertEquals(1,count("SELECT count(*) FROM production_material_analysis_materials WHERE analysis_item_id=? AND node_role='BOM_COMPONENT' AND active",batch.anchorAnalysisItemId()));
        var after=preview.preview(c.analysis(),request(c,List.of(input(c,c.common(),"MAKE","0",false))));amount("3",after.groups().getFirst().orderedQty());amount("0",after.groups().getFirst().remainingQty());
        for(MaterialView row:analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.goodsId().equals(c.common())&&row.nodeRole().equals("BOM_COMPONENT")).toList()){
            amount("1",row.internalCommittedOutputQty());amount("1",row.plannedOutputQty());amount("0",row.planningUncoveredQty());
        }
    }

    @Test void priorThreeChildPlansAreInheritedByTheSharedParentWithoutAnotherChildOrder(){
        Case c=createWithChild("10");
        AnalysisView initial=analyses.detail(c.analysis());
        List<UUID> childSources=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.child())).map(MaterialView::materialLineId).toList();
        ordinary.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(initial.version(),initial.fingerprint(),"old-children-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                childSources.stream().map(id->new IssueWorkshopPlansRequest.IssuePlanLine(id,null,BigDecimal.TEN,null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO)).toList()));
        assertEquals(3,count("SELECT count(*) FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id WHERE plan.material_analysis_id=? AND item.goods_id='"+c.child()+"'",c.analysis()));
        var shared=writer.submit(c.analysis(),command(c,List.of(input(c,c.common(),"MAKE","30",false)))).batches().getFirst();
        assertNotEquals("CANCELLED",db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",String.class,shared.batchId()));
        assertEquals(4,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        amount("30",db.queryForObject("SELECT SUM(fn_preplan_aggregate_alias_qty(id)) FROM preplan_aggregate_material_aliases WHERE batch_id=?",BigDecimal.class,shared.batchId()));
        MaterialView canonical=analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.analysisLineId().equals(shared.anchorAnalysisItemId())&&row.goodsId().equals(c.child())).findFirst().orElseThrow();
        amount("30",canonical.requiredQty());amount("0",canonical.planningUncoveredQty());
        amount("60",analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.goodsId().equals(c.material())).map(MaterialView::requiredQty).reduce(BigDecimal.ZERO,BigDecimal::add));
    }

    @Test void parentAndDescendantCannotCommitWithStaleChildQuantities(){
        Case c=create(true,true,"1");var request=request(c,List.of(input(c,c.common(),"MAKE","3",false),input(c,c.material(),"BUY","3",false)));
        var shown=preview.preview(c.analysis(),request);assertThrows(ApiException.class,()->writer.submit(c.analysis(),submit(shown,request)));
        assertEquals(0,count("SELECT count(*) FROM preplan_aggregate_batches WHERE analysis_id=?",c.analysis()));
    }

    @Test void unstartedSharedAppendUsesCumulativeFixedBatchAndMakePublicKeepsNormalPermissions(){
        Case c=create(true,true,"10");
        var first=writer.submit(c.analysis(),command(c,List.of(input(c,c.common(),"MAKE","3",false)))).batches().getFirst();
        var secondInput=input(c,c.common(),"MAKE","2",false);var secondRequest=request(c,List.of(secondInput));var shown=preview.preview(c.analysis(),secondRequest);
        amount("3",shown.groups().getFirst().priorOutputQty());amount("0",shown.groups().getFirst().sharedBomChildren().getFirst().requiredQty());
        var second=writer.submit(c.analysis(),submit(shown,secondRequest)).batches().getFirst();
        assertEquals(first.batchId(),second.batchId());assertEquals(first.planId(),second.planId());
        amount("5",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,first.planId()));
        amount("1",db.queryForObject("SELECT required_qty FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,first.planId()));
        Case publicCase=create(true,true,"1");
        var original=writer.submit(publicCase.analysis(),command(publicCase,List.of(input(publicCase,publicCase.common(),"MAKE","3",false)))).batches().getFirst();
        AuthUser admin=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();Set<String> grants=new HashSet<>(admin.getPermissions());grants.remove("production_material_analysis:over_supply");
        AuthUser planner=new AuthUser(admin.getId(),admin.getEmployeeId(),admin.getUsername(),grants,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(planner,null,planner.getAuthorities()));
        var extra=writer.submit(publicCase.analysis(),command(publicCase,List.of(input(publicCase,publicCase.common(),"MAKE","2",true)))).batches().getFirst();
        assertEquals(original.planId(),extra.planId());amount("2",extra.publicExtraQty());
        amount("3",db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",BigDecimal.class,extra.batchId()));
        amount("1",db.queryForObject("SELECT required_qty FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,extra.planId()));
    }

    @Test void sharedMakeActuallyIssuesReportsPassesFqcAndPreservesThreePrivateOutputSources(){
        Case c=create(true,true,"1");var batch=writer.submit(c.analysis(),command(c,List.of(input(c,c.common(),"MAKE","3",false)))).batches().getFirst();
        UUID inbound=produce(c,batch);
        amount("3",db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id='"+c.common()+"'",BigDecimal.class,c.world().warehouseId()));
        amount("0",db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_document_items WHERE doc_id=? AND fn_finished_in_is_public_output(id)",BigDecimal.class,inbound));
        assertEquals(3,count("SELECT COUNT(DISTINCT origin_analysis_material_id) FROM preplan_analysis_stock_exact_pegs WHERE source_receipt_id=?",inbound));
        amount("3",db.queryForObject("SELECT SUM(qty) FROM preplan_analysis_stock_exact_pegs WHERE source_receipt_id=?",BigDecimal.class,inbound));
        var current=analyses.detail(c.analysis());UUID action=db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,batch.batchId());
        assertThrows(ApiException.class,()->ordinary.cancelAction(c.analysis(),action,new CancelRequest(current.version(),current.fingerprint(),"shared-cancel-"+action,"单来源不得撤销他人份额")));
        assertThrows(ApiException.class,()->writer.cancel(c.analysis(),action,new CancelRequest(current.version(),current.fingerprint(),"executed-cancel-"+action,"已有实际执行不可整批抹去")));
        assertEquals("DONE",db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action));
        InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),db,List.of(c.common(),c.material()));
        beans.getBean(com.uten.imp.features.stock.StockDocService.class).reverseFinishedInbound(inbound);analyses.detail(c.analysis());
        assertEquals("IN_PROGRESS",db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action));
    }

    @Test void wholeBatchCancelRestoresEverySourceAndReplaysWithoutRepeating(){
        for(boolean make:List.of(false,true)){
            Case c=create(make,make,"1");UUID goods=make?c.common():c.material();String route=make?"MAKE":"BUY",qty=make?"3":"6";
            var batch=writer.submit(c.analysis(),command(c,List.of(input(c,goods,route,qty,false)))).batches().getFirst();
            UUID action=db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,batch.batchId());
            if(make){AuthUser admin=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();Set<String> grants=new HashSet<>(admin.getPermissions());grants.remove("production_material_analysis:notify");grants.remove("production_material_analysis:claim_shared_future");
                AuthUser planner=new AuthUser(admin.getId(),admin.getEmployeeId(),admin.getUsername(),grants,false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(planner,null,planner.getAuthorities()));}
            var current=analyses.detail(c.analysis());var cancellation=new CancelRequest(current.version(),current.fingerprint(),"whole-cancel-"+action,"整批建错，恢复全部来源");
            assertTrue(current.allowedActions().contains("CANCEL_ACTION"));
            writer.cancel(c.analysis(),action,cancellation);writer.cancel(c.analysis(),action,cancellation);
            assertEquals("CANCELLED",db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action));
            var restored=preview.preview(c.analysis(),request(c,List.of(input(c,goods,route,"0",false)))).groups().getFirst();amount("0",restored.orderedQty());amount(qty,restored.remainingQty());
            assertEquals(1,count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='CANCEL'",batch.batchId()));
            assertThrows(ApiException.class,()->writer.cancel(c.analysis(),action,new CancelRequest(cancellation.version(),cancellation.fingerprint(),cancellation.idempotencyKey(),"不能把同键改成另一意图")));
        }
    }

    @Test void directSubcontractIsOneApplicationLineWithThreeExactSources(){
        Case c=create(false,false,"1");setRoute(c,c.material(),"SUBCONTRACT");
        var batch=writer.submit(c.analysis(),command(c,List.of(input(c,c.material(),"SUBCONTRACT","6",false)))).batches().getFirst();
        assertEquals("SUBCONTRACT_APPLICATION",batch.documentType());assertNull(batch.planId());
        assertEquals(1,count("SELECT count(*) FROM subcontract_application_items WHERE application_id=? AND NOT is_deleted",batch.documentId()));
        amount("6",db.queryForObject("SELECT qty FROM subcontract_application_items WHERE application_id=? AND NOT is_deleted",BigDecimal.class,batch.documentId()));
        assertEquals(3,count("SELECT count(*) FROM preplan_supply_action_allocations WHERE action_id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",batch.batchId()));
    }

    @Test void sharedSubcontractPreparationActuallyProducesAndNotifiesOneQualifiedBatch(){
        Case c=create(true,true,"1");setRoute(c,c.common(),"SUBCONTRACT");
        var raw=input(c,c.common(),"SUBCONTRACT","3",false);
        var group=new GroupInput(raw.clientGroupKey(),raw.materialLineIds(),raw.route(),raw.qty(),false,c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO);
        var batch=writer.submit(c.analysis(),command(c,List.of(group))).batches().getFirst();
        UUID task=db.queryForObject("SELECT id FROM preplan_subcontract_make_tasks WHERE preparation_item_id=? AND status='ACTIVE'",UUID.class,batch.anchorAnalysisItemId());
        var visible=beans.getBean(SubcontractMakeTaskService.class).task(task);assertEquals(3,visible.sources().size());assertEquals("WAITING_MATERIALS",visible.workshopStatus());
        UUID preparedInbound=produce(c,batch);
        assertEquals(0,count("SELECT count(*) FROM preplan_analysis_stock_exact_pegs WHERE source_receipt_id=?",preparedInbound));
        amount("3",db.queryForObject("SELECT SUM(qty-consumed_qty-released_qty) FROM stock_reservations WHERE owner_type='SUBCONTRACT_PREPARE_TASK' AND owner_id=? AND status=0 AND NOT is_deleted",BigDecimal.class,task));
        amount("3",db.queryForObject("SELECT produced_qty FROM preplan_subcontract_make_tasks WHERE id=?",BigDecimal.class,task));
        amount("3",db.queryForObject("SELECT notified_qty FROM preplan_subcontract_make_tasks WHERE id=?",BigDecimal.class,task));
        UUID application=db.queryForObject("SELECT application_id FROM preplan_subcontract_make_task_batches WHERE task_id=?",UUID.class,task);
        assertEquals(1,count("SELECT count(*) FROM subcontract_application_items WHERE application_id=? AND NOT is_deleted",application));
        assertEquals(3,count("SELECT COUNT(DISTINCT allocation.analysis_material_id) FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE action.external_document_id=?",application));
        amount("3",db.queryForObject("SELECT SUM(allocation.allocated_qty) FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE action.external_document_id=?",BigDecimal.class,application));
        var displayed=preview.preview(c.analysis(),request(c,List.of(input(c,c.common(),"SUBCONTRACT","0",false)))).groups().getFirst();amount("3",displayed.orderedQty());
        for(SourcePreview source:displayed.sources())amount("1",source.orderedQty());
        finishSubcontract(c,application);
    }

    @Test void newPurePublicBatchKeepsContextAndRecipeWithoutFabricatingPrivateShares(){
        Case c=create(true,true,"1");var initial=analyses.detail(c.analysis());
        var commonSources=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())&&row.nodeRole().equals("BOM_COMPONENT")).map(MaterialView::materialLineId).toList();
        ordinary.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(initial.version(),initial.fingerprint(),"ordinary-before-public-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                commonSources.stream().map(id->new IssueWorkshopPlansRequest.IssuePlanLine(id,null,BigDecimal.ONE,null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO)).toList()));
        var batch=writer.submit(c.analysis(),command(c,List.of(input(c,c.common(),"MAKE","2",true)))).batches().getFirst();
        amount("2",batch.publicExtraQty());
        assertEquals(0,count("SELECT count(*) FROM preplan_supply_action_allocations WHERE action_id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",batch.batchId()));
        amount("0",db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,batch.anchorAnalysisItemId()));
        amount("2",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,batch.planId()));
        MaterialView raw=analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.analysisLineId().equals(batch.anchorAnalysisItemId())&&row.goodsId().equals(c.material())).findFirst().orElseThrow();
        assertEquals("BUY",raw.sourceConfirmed());amount("1",raw.requiredQty());
        var shown=preview.preview(c.analysis(),request(c,List.of(input(c,c.common(),"MAKE","0",false)))).groups().getFirst();amount("5",shown.orderedQty());amount("0",shown.remainingQty());
    }

    @Test void subcontractRenotificationFillsTheReversedPrivateSourceEvenAfterPublicWasNotified(){
        Case c=create(true,true,"1");setRoute(c,c.common(),"SUBCONTRACT");var input=input(c,c.common(),"SUBCONTRACT","5",true);
        var group=new GroupInput(input.clientGroupKey(),input.materialLineIds(),input.route(),input.qty(),true,c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO);
        var batch=writer.submit(c.analysis(),command(c,List.of(group))).batches().getFirst();produce(c,batch);
        UUID task=db.queryForObject("SELECT id FROM preplan_subcontract_make_tasks WHERE preparation_item_id=? AND status='ACTIVE'",UUID.class,batch.anchorAnalysisItemId());
        UUID automatic=db.queryForObject("SELECT application_id FROM preplan_subcontract_make_task_batches WHERE task_id=?",UUID.class,task);cancelNotification(c,automatic);
        var service=beans.getBean(SubcontractMakeTaskService.class);
        var first=service.notifyBatch(task,new SubcontractMakeTaskService.NotifyRequest(BigDecimal.ONE,"first-private-"+task));
        service.notifyBatch(task,new SubcontractMakeTaskService.NotifyRequest(BigDecimal.ONE,"second-private-"+task));
        service.notifyBatch(task,new SubcontractMakeTaskService.NotifyRequest(new BigDecimal("3"),"last-private-and-public-"+task));
        UUID original=db.queryForObject("SELECT allocation.analysis_material_id FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE action.external_document_id=?",UUID.class,first.applicationId());
        cancelNotification(c,first.applicationId());
        var replacement=service.notifyBatch(task,new SubcontractMakeTaskService.NotifyRequest(BigDecimal.ONE,"replace-private-hole-"+task));
        assertEquals(original,db.queryForObject("SELECT allocation.analysis_material_id FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE action.external_document_id=?",UUID.class,replacement.applicationId()));
        amount("0",db.queryForObject("SELECT public_surplus_qty FROM preplan_supply_actions WHERE external_document_id=?",BigDecimal.class,replacement.applicationId()));
        List<BigDecimal> quantities=db.queryForList("SELECT SUM(sent.allocated_qty) FROM preplan_subcontract_make_task_batches notified JOIN preplan_supply_action_allocations marker ON marker.id=notified.allocation_id JOIN preplan_supply_action_allocations sent ON sent.action_id=marker.action_id WHERE notified.task_id=? AND NOT EXISTS(SELECT 1 FROM preplan_subcontract_make_batch_reversals reversal WHERE reversal.batch_id=notified.id) GROUP BY sent.analysis_material_id",BigDecimal.class,task);
        assertEquals(3,quantities.size());quantities.forEach(qty->amount("1",qty));
        amount("5",db.queryForObject("SELECT notified_qty FROM preplan_subcontract_make_tasks WHERE id=?",BigDecimal.class,task));
    }

    @Test void productViewProjectsDelegatedSharesTargetsAndStagesAtEveryDepthAfterSelectAll(){
        // 三层共享结构(顶层→共享件→子件→采购料)全选下单后的产品视图投影：
        // 原树任意深度的行都要拿回自己的 BOM 份额、共享批次树上的目标行与真实
        // 进度阶段(2026-09-26 用户实机「深层行全是 0/未下达、下达委外幻影红 1」)。
        Case c=createWithChild("1");setRoute(c,c.common(),"SUBCONTRACT");
        var raw=input(c,c.common(),"SUBCONTRACT","3",false);
        var group=new GroupInput(raw.clientGroupKey(),raw.materialLineIds(),raw.route(),raw.qty(),false,c.workshop(),c.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO);
        var shared=writer.submit(c.analysis(),command(c,List.of(group))).batches().getFirst();
        // 全选下单的其余两层也走汇总：子件(制造批)与采购料各成一批，嵌套共享批次。
        writer.submit(c.analysis(),command(c,List.of(input(c,c.child(),"MAKE","3",false),input(c,c.material(),"BUY","6",false))));
        AnalysisView view=analyses.detail(c.analysis());
        Set<UUID> originalProducts=view.products().stream().filter(product->!Set.of("AGGREGATE_MAKE","MAKE_COMPONENT","SUBCONTRACT_MAKE").contains(product.sourceType()))
                .map(ProductView::analysisLineId).collect(java.util.stream.Collectors.toSet());
        List<MaterialView> originals=view.flatMaterials().stream()
                .filter(row->originalProducts.contains(row.analysisLineId())).toList();
        // 原树分层断言：成员行(共享件本体的原行)仍持有毛需求——它的「还缺」必须由
        // 共享委外批次的先自制备料任务按 INTERNAL 覆盖清零；覆盖要落到**批次成员行**
        // 上：锚点树没有 ROOT_SUPPLY 行(锚点树只长 BOM 组件)，关联锚点根行永远落空
        // (2026-09-26 用户实机「等待下发委外」幻影计数的根因)。子层/孙层份额按 BOM
        // 折算，目标行经嵌套解析落到最终真实下达行——不再有可填的 0 或找不到目标。
        for(MaterialView row:originals){
            if(row.goodsId().equals(c.common()))amount("0",row.additionalSupplyRecommendedQty());
            if(row.goodsId().equals(c.child())){
                amount("1",row.aggregateDelegatedQty());assertNotNull(row.aggregatePreparation());
                assertTrue(row.aggregateTargetMaterialLineId()!=null||!row.downstreamReferences().isEmpty(),
                        "An original path must have an exact target or its own real shared-order reference");
                assertTrue(row.aggregatePreparation().orderedQty().signum()>0);
            }
            if(row.goodsId().equals(c.material())&&"BOM_COMPONENT".equals(row.nodeRole())){
                amount("2",row.aggregateDelegatedQty());assertNotNull(row.aggregateTargetMaterialLineId());}
        }
        // 进度取最终真实下达行的阶段：孙层已随采购批下单，不得再报「未下达」。
        assertTrue(originals.stream().filter(row->row.goodsId().equals(c.material())&&"BOM_COMPONENT".equals(row.nodeRole()))
                .allMatch(row->!"BUY_PENDING_ISSUE".equals(row.flowStage())));
    }

    @Test void rootAssignmentsComeFromTheRealDraftAndTaskWhenGoodsMemoryChanges() {
        Case c=create(false,false,"1");AnalysisView view=analyses.detail(c.analysis());
        ProductView product=view.products().getFirst();
        var line=new MaterialAnalysisContracts.IssueWorkshopPlansRequest.IssuePlanLine(null,product.analysisLineId(),BigDecimal.ONE,
                null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO);
        var result=ordinary.issueWorkshopPlans(c.analysis(),new MaterialAnalysisContracts.IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "assignment-draft-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),false,List.of(line)));
        UUID plan=result.plans().getFirst().planId();
        ProductView draft=result.analysis().products().stream().filter(row->row.analysisLineId().equals(product.analysisLineId())).findFirst().orElseThrow();
        assertEquals(c.workshop(),draft.planExecutionWorkshopId());assertEquals(c.worker(),draft.planExecutionResponsibleId());
        assertFalse(draft.planExecutionWorkshopName().isBlank());assertFalse(draft.planExecutionResponsibleName().isBlank());
        beans.getBean(com.uten.imp.features.production.plan.ProductionPlanService.class).approve(plan);
        Object other=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","other-memory-"+UUID.randomUUID());
        UUID otherWorkshop=ReflectionTestUtils.invokeMethod(other,"workshopId");
        // Goods memory is mutable master data; the previously issued plan and task stay unchanged.
        db.update("UPDATE goods SET owning_workshop_department_id=? WHERE id=?",otherWorkshop,product.goodsId());
        ProductView current=analyses.detail(c.analysis()).products().stream().filter(row->row.analysisLineId().equals(product.analysisLineId())).findFirst().orElseThrow();
        assertEquals(otherWorkshop,current.owningWorkshopId());
        assertEquals(c.workshop(),current.planExecutionWorkshopId());assertEquals(c.worker(),current.planExecutionResponsibleId());
        assertEquals(c.workshop(),db.queryForObject("SELECT department_id FROM production_plans WHERE id=?",UUID.class,plan));
    }

    @Test void originalDeepChildCanBeOrderedAndAppendedAfterItsParentsWereCombined() {
        Case c=createWithChild("1");
        AnalysisView initial=analyses.detail(c.analysis());
        List<UUID> originalLeaves=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())).map(MaterialView::materialLineId).toList();
        writer.submit(c.analysis(),command(c,List.of(input(c,c.common(),"MAKE","3",false),input(c,c.child(),"MAKE","3",false))));
        UUID original=originalLeaves.getFirst();
        GroupInput first=new GroupInput("original-leaf",List.of(original),"BUY",new BigDecimal("2"),false,
                null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(original,new BigDecimal("2")));
        var ordered=writer.submit(c.analysis(),command(c,List.of(first)));
        assertEquals(1,ordered.batches().size());
        MaterialView shown=ordered.analysis().flatMaterials().stream().filter(row->row.materialLineId().equals(original)).findFirst().orElseThrow();
        assertNotNull(shown.aggregatePreparation());
        amount("2",shown.aggregatePreparation().orderedQty());
        assertTrue(shown.aggregatePreparation().orderedQtyExact());
        for(UUID id:originalLeaves) {
            var row=ordered.analysis().flatMaterials().stream().filter(material->material.materialLineId().equals(id)).findFirst().orElseThrow();
            amount(id.equals(original)?"0":"2",row.aggregatePreparation().planningUncoveredQty());
            amount(id.equals(original)?"2":"0",row.aggregatePreparation().allocatedOrderedQty());
        }
        GroupInput append=new GroupInput("original-leaf",List.of(original),"BUY",new BigDecimal("3"),true,
                null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(original,new BigDecimal("3")));
        var after=writer.submit(c.analysis(),command(c,List.of(append)));
        assertEquals(ordered.batches().getFirst().documentId(),after.batches().getFirst().documentId());
        shown=after.analysis().flatMaterials().stream().filter(row->row.materialLineId().equals(original)).findFirst().orElseThrow();
        amount("5",shown.aggregatePreparation().orderedQty());
        amount("5",db.queryForObject("SELECT qty FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,ordered.batches().getFirst().documentId()));
        amount("2",shown.aggregatePreparation().allocatedOrderedQty());
        amount("0",shown.aggregatePreparation().planningUncoveredQty());
        UUID sibling=originalLeaves.get(1);
        GroupInput adopt=new GroupInput("original-sibling",List.of(sibling),"BUY",new BigDecimal("2"),false,
                null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(sibling,new BigDecimal("2")));
        var adopted=writer.submit(c.analysis(),command(c,List.of(adopt)));
        assertTrue(adopted.batches().isEmpty(),"An independent original sibling may use the first row's public remainder after both parents were merged");
        var siblingRow=adopted.analysis().flatMaterials().stream().filter(row->row.materialLineId().equals(sibling)).findFirst().orElseThrow();
        amount("0",siblingRow.aggregatePreparation().orderedQty());amount("2",siblingRow.preparationAdoptedQty());
        amount("0",siblingRow.aggregatePreparation().planningUncoveredQty());
        amount("5",db.queryForObject("SELECT qty FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,ordered.batches().getFirst().documentId()));
    }

    @Test void actualSourceOrderInputsRemainDistinctFromThePrivateDemandAllocations() {
        Case c=create(false,false,"1");GroupInput base=input(c,c.material(),"BUY","11001",true);
        List<UUID> ids=base.materialLineIds();
        Map<UUID,BigDecimal> intended=Map.of(ids.get(0),new BigDecimal("10000"),ids.get(1),new BigDecimal("1000"),ids.get(2),BigDecimal.ONE);
        GroupInput exact=new GroupInput(base.clientGroupKey(),ids,"BUY",new BigDecimal("11001"),true,
                null,null,null,null,null,null,null,BigDecimal.ZERO,intended);
        var result=writer.submit(c.analysis(),command(c,List.of(exact)));
        for(MaterialView row:result.analysis().flatMaterials())if(intended.containsKey(row.materialLineId())) {
            assertNotNull(row.aggregatePreparation());assertTrue(row.aggregatePreparation().orderedQtyExact());
            assertEquals(0,intended.get(row.materialLineId()).compareTo(row.aggregatePreparation().orderedQty()));
            assertTrue(row.aggregatePreparation().allocatedOrderedQty().compareTo(new BigDecimal("2"))<=0);
        }
        amount("11001",db.queryForObject("SELECT qty FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,result.batches().getFirst().documentId()));
    }

    @Test void deepSupplyIssuedBeforeParentsCombinedKeepsItsExactOriginalResponsibility() {
        Case c=createWithChild("1");
        List<UUID> originals=analyses.detail(c.analysis()).flatMaterials().stream()
                .filter(row->row.goodsId().equals(c.material())).map(MaterialView::materialLineId).toList();
        UUID first=originals.getFirst(),sibling=originals.get(1);
        GroupInput order=new GroupInput("deep-before-parent",List.of(first),"BUY",new BigDecimal("5"),true,
                null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(first,new BigDecimal("5")));
        var supplied=writer.submit(c.analysis(),command(c,List.of(order)));
        UUID request=supplied.batches().getFirst().documentId();
        writer.submit(c.analysis(),command(c,List.of(input(c,c.common(),"MAKE","3",false),input(c,c.child(),"MAKE","3",false))));
        amount("2",db.queryForObject("SELECT SUM(fn_preplan_aggregate_alias_qty(id)) FROM preplan_aggregate_material_aliases WHERE source_material_id=? AND cardinality(relative_bom_path)=2",BigDecimal.class,sibling));
        long aliases=count("SELECT COUNT(*) FROM preplan_aggregate_material_aliases alias JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id WHERE batch.analysis_id=?",c.analysis());
        for(int turn=1;turn<=2;turn++) {
            GroupInput adopt=new GroupInput("deep-partial-original",List.of(sibling),"BUY",BigDecimal.ONE,false,
                    null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(sibling,BigDecimal.ONE));
            SubmitRequest intent=command(c,List.of(adopt));
            var result=writer.submit(c.analysis(),intent);
            assertTrue(result.batches().isEmpty());
            MaterialView row=result.analysis().flatMaterials().stream().filter(value->value.materialLineId().equals(sibling)).findFirst().orElseThrow();
            amount(Integer.toString(turn),row.preparationAdoptedQty());
            amount(Integer.toString(2-turn),row.aggregatePreparation().planningUncoveredQty());
            assertTrue(writer.submit(c.analysis(),intent).replayed());
        }
        assertEquals(aliases,count("SELECT COUNT(*) FROM preplan_aggregate_material_aliases alias JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id WHERE batch.analysis_id=?",c.analysis()));
        amount("5",db.queryForObject("SELECT SUM(qty) FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,request));
    }

    @Test void fixedBatchClaimCreatedAfterMergeCoversOnlyItsCurrentOriginalShare() {
        Case c=createForkedFixed();
        List<UUID> originals=analyses.detail(c.analysis()).flatMaterials().stream()
                .filter(row->row.goodsId().equals(c.material())).map(MaterialView::materialLineId).toList();
        UUID source=originals.getFirst(),target=originals.get(1);
        GroupInput order=new GroupInput("rounded-source",List.of(source),"BUY",new BigDecimal("2"),true,
                null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(source,new BigDecimal("2")));
        writer.submit(c.analysis(),command(c,List.of(order)));
        writer.submit(c.analysis(),command(c,List.of(input(c,c.common(),"MAKE","2",false))));
        BigDecimal share=db.queryForObject("SELECT SUM(fn_preplan_aggregate_alias_qty(id)) FROM preplan_aggregate_material_aliases WHERE source_material_id=?",BigDecimal.class,target);
        assertTrue(share.signum()>0&&share.compareTo(BigDecimal.ONE)<0);
        GroupInput adopt=new GroupInput("rounded-target",List.of(target),"BUY",share,false,
                null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(target,share));
        var result=writer.submit(c.analysis(),command(c,List.of(adopt)));
        assertTrue(result.batches().isEmpty());
        MaterialView row=result.analysis().flatMaterials().stream().filter(value->value.materialLineId().equals(target)).findFirst().orElseThrow();
        amount(share.toPlainString(),row.preparationAdoptedQty());
        amount("0",row.aggregatePreparation().planningUncoveredQty());
        // The first row's real pre-merge private remainder still belongs to it.
        BigDecimal sourceShare=db.queryForObject("SELECT SUM(fn_preplan_aggregate_alias_qty(id)) FROM preplan_aggregate_material_aliases WHERE source_material_id=?",BigDecimal.class,source);
        amount(BigDecimal.ONE.subtract(sourceShare).toPlainString(),db.queryForObject("SELECT fn_preplan_aggregate_source_retained_qty(?)",BigDecimal.class,source));
    }

    @Test void historicalDirectOnlyParentBridgesAreCompletedBeforePartialOriginalClaims() {
        historicalDirectOnlyParentBridgesAreCompletedBeforePartialOriginalClaims(false);
    }
    @Test void historicalPrivateReceiptIsDelegatedWhenItsMissingDeepBridgeIsCompleted() {
        historicalDirectOnlyParentBridgesAreCompletedBeforePartialOriginalClaims(true);
    }
    private void historicalDirectOnlyParentBridgesAreCompletedBeforePartialOriginalClaims(boolean receivePrivate) {
        Case c=createWithChild("1");
        List<UUID> originals=analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.goodsId().equals(c.material()))
                .map(MaterialView::materialLineId).toList();
        UUID source=originals.getFirst(),target=originals.get(1);
        GroupInput order=new GroupInput("historic-source",List.of(source),"BUY",new BigDecimal("5"),true,
                null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(source,new BigDecimal("5")));
        UUID request=writer.submit(c.analysis(),command(c,List.of(order))).batches().getFirst().documentId();
        createLegacyDirectOnlyParent(c,input(c,c.common(),"MAKE","3",false));
        assertEquals(0,count("SELECT COUNT(*) FROM preplan_aggregate_material_aliases WHERE source_material_id=?",target));
        writer.submit(c.analysis(),command(c,List.of(input(c,c.child(),"MAKE","3",false))));
        if(receivePrivate) {
            var purchases=new PreplanPublicFutureReplenishmentEndToEndTest();beans.autowireBean(purchases);
            ReflectionTestUtils.setField(purchases,"fixture",fixture);
            UUID requestItem=db.queryForObject("SELECT id FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",UUID.class,request);
            UUID orderItem=ReflectionTestUtils.invokeMethod(purchases,"approveOrder",c.world(),requestItem,c.material(),"5",BusinessTime.today().plusDays(5));
            ReflectionTestUtils.invokeMethod(purchases,"receive",c.world(),orderItem,c.material(),"2");
            fixture.loginAs(c.world().superAdminUserId());
            amount("2",db.queryForObject("SELECT COALESCE(SUM(effective_qty),0) FROM v_preplan_stock_entitlement_beneficiary_balance WHERE beneficiary_analysis_material_id=?",BigDecimal.class,source));
        }
        for(int turn=1;turn<=2;turn++) {
            GroupInput adopt=new GroupInput("historic-target",List.of(target),"BUY",BigDecimal.ONE,false,
                    null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(target,BigDecimal.ONE));
            SubmitRequest intent=command(c,List.of(adopt));
            var result=writer.submit(c.analysis(),intent);assertTrue(result.batches().isEmpty());
            MaterialView row=result.analysis().flatMaterials().stream().filter(value->value.materialLineId().equals(target)).findFirst().orElseThrow();
            amount(Integer.toString(turn),row.preparationAdoptedQty());
            amount(Integer.toString(2-turn),row.aggregatePreparation().planningUncoveredQty());
            amount("2",db.queryForObject("SELECT SUM(fn_preplan_aggregate_alias_qty(id)) FROM preplan_aggregate_material_aliases WHERE source_material_id=? AND cardinality(relative_bom_path)=2",BigDecimal.class,target));
            assertTrue(writer.submit(c.analysis(),intent).replayed());
        }
        MaterialView first=analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.materialLineId().equals(source)).findFirst().orElseThrow();
        amount("0",first.aggregatePreparation().planningUncoveredQty());
        if(receivePrivate)amount("2",db.queryForObject("SELECT COALESCE(SUM(fn_preplan_aggregate_alias_delegated_qty(id)),0) FROM preplan_aggregate_material_aliases WHERE source_material_id=?",BigDecimal.class,source));
        amount("5",db.queryForObject("SELECT SUM(qty) FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,request));
    }

    @Test void sharedPurchaseKeepsTheConfirmedSafetySliceSeparateFromSourceQuantities() {
        Case c=create(false,false,"10");db.update("UPDATE goods SET min_qty=6 WHERE id=?",c.material());
        GroupInput raw=input(c,c.material(),"BUY","60",false);
        GroupInput order=new GroupInput(raw.clientGroupKey(),raw.materialLineIds(),"BUY",raw.qty(),false,
                null,null,null,null,null,null,null,new BigDecimal("6"));
        var result=writer.submit(c.analysis(),command(c,List.of(order)));var batch=result.batches().getFirst();
        amount("66",db.queryForObject("SELECT SUM(qty) FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,batch.documentId()));
        amount("6",db.queryForObject("SELECT safety_replenishment_qty FROM preplan_supply_actions WHERE id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",BigDecimal.class,batch.batchId()));
        amount("60",db.queryForObject("SELECT SUM(allocated_qty) FROM preplan_supply_action_allocations WHERE action_id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",BigDecimal.class,batch.batchId()));
    }

    @Test void selectAllThreeProductsIssuesEveryLayerUsingOnlyTheOriginalClientPathIds() {
        Case c=createWithChild("1");AnalysisView initial=analyses.detail(c.analysis());
        List<ProductView> roots=initial.products().stream().filter(row->row.salesOrderItemId()!=null).toList();
        Set<UUID> rootIds=roots.stream().map(ProductView::analysisLineId).collect(java.util.stream.Collectors.toSet());
        List<MaterialView> original=initial.flatMaterials().stream().filter(row->rootIds.contains(row.analysisLineId())).toList();
        List<GroupInput> groups=new ArrayList<>();
        for(UUID goods:List.of(c.common(),c.child(),c.material())) {
            boolean buy=goods.equals(c.material());BigDecimal perSource=new BigDecimal(buy?"2":"1");
            List<UUID> ids=original.stream().filter(row->goods.equals(row.goodsId())&&row.level()>0).map(MaterialView::materialLineId).toList();
            assertEquals(3,ids.size());Map<UUID,BigDecimal> intent=new LinkedHashMap<>();ids.forEach(id->intent.put(id,perSource));
            groups.add(new GroupInput("original-level-"+goods,ids,buy?"BUY":"MAKE",perSource.multiply(new BigDecimal("3")),false,
                    buy?null:c.workshop(),buy?null:c.worker(),null,BusinessTime.today(),BusinessTime.today().plusDays(10),null,buy?null:BigDecimal.ZERO,BigDecimal.ZERO,intent));
        }
        ordinary.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(initial.version(),initial.fingerprint(),"all-original-roots-"+UUID.randomUUID(),
                c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                roots.stream().map(root->new IssueWorkshopPlansRequest.IssuePlanLine(null,root.analysisLineId(),BigDecimal.ONE,null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO)).toList()));
        for(GroupInput group:groups) {
            var shown=preview.preview(c.analysis(),request(c,List.of(group)));
            assertNull(shown.groups().getFirst().blockedReason(),"original path stage "+group.clientGroupKey());
            Set<UUID> proved=shown.groups().getFirst().sources().stream().flatMap(source->source.originalMaterialLineIds().stream()).collect(java.util.stream.Collectors.toSet());
            assertEquals(new HashSet<>(group.materialLineIds()),proved,"the preview must prove exactly the original client scope even when effective ids changed");
            var issued=writer.submit(c.analysis(),submit(shown,request(c,List.of(group))));
            assertEquals(1,issued.batches().size(),"every selected level must issue a real document");
        }
        assertEquals(5,count("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted",c.analysis()));
        amount("6",db.queryForObject("SELECT SUM(item.qty) FROM purchase_request_items item WHERE NOT item.is_deleted AND item.request_id IN(SELECT external_document_id FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY' AND status<>'CANCELLED')",BigDecimal.class,c.analysis()));
        AnalysisView after=analyses.detail(c.analysis());
        for(GroupInput group:groups)for(UUID id:group.materialLineIds()) {
            MaterialView row=after.flatMaterials().stream().filter(value->value.materialLineId().equals(id)).findFirst().orElseThrow();
            assertNotNull(row.aggregatePreparation());assertTrue(row.aggregatePreparation().orderedQtyExact());
            assertEquals(0,group.sourceRequestedQtyByMaterialLineId().get(id).compareTo(row.aggregatePreparation().orderedQty()));
            assertFalse(row.flowStage().endsWith("PENDING_ISSUE"),"issued original path must expose its real downstream progress");
        }
    }

    @Test void independentManufacturingCohortStillReservesSharedScarceMaterialSequentially() {
        CohortCase cohort=createIndependentCohort();Case c=cohort.c();
        receive(c,c.material(),"1");
        List<GroupInput> groups=new ArrayList<>();
        for(UUID output:cohort.outputs())groups.add(input(c,output,"MAKE","1",false));
        var command=command(c,groups);var result=writer.submit(c.analysis(),command);
        assertEquals(2,result.batches().size());
        List<UUID> plans=result.batches().stream().map(BatchResult::planId).toList();
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_execution_segments WHERE plan_id IN(?,?) AND status='READY' AND NOT is_deleted",Integer.class,plans.get(0),plans.get(1)));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_execution_segments WHERE plan_id IN(?,?) AND status='WAITING' AND NOT is_deleted",Integer.class,plans.get(0),plans.get(1)));
        amount("1",db.queryForObject("SELECT COALESCE(SUM(reservation.qty-reservation.released_qty-reservation.consumed_qty),0) FROM stock_reservations reservation JOIN production_material_demands demand ON demand.id=reservation.owner_id WHERE reservation.owner_type='PRODUCTION_MATERIAL_DEMAND' AND demand.plan_id IN(?,?) AND reservation.status=0 AND NOT reservation.is_deleted",BigDecimal.class,plans.get(0),plans.get(1)));
        assertTrue(writer.submit(c.analysis(),command).replayed());
        assertEquals(2,count("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted",c.analysis()));
    }

    @Test void aSecondPlanFailureRollsBackTheAlreadyApprovedFirstPlanAndItsReservation() {
        CohortCase cohort=createIndependentCohort();Case c=cohort.c();receive(c,c.material(),"1");
        List<GroupInput> groups=cohort.outputs().stream().map(output->input(c,output,"MAKE","1",false)).toList();
        SubmitRequest intent=command(c,groups);
        String outputs=cohort.outputs().stream().map(id->"'"+id+"'::uuid").collect(java.util.stream.Collectors.joining(","));
        String fault="test_aggregate_second_"+UUID.randomUUID().toString().replace("-","");
        db.execute("CREATE FUNCTION "+fault+"() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.goods_id IN("+outputs+") AND EXISTS(SELECT 1 FROM production_plans p WHERE p.material_analysis_id='"+c.analysis()+"'::uuid AND p.status=1 AND NOT p.is_deleted) THEN RAISE EXCEPTION 'TEST_SECOND_PLAN_AFTER_FIRST_APPROVED' USING ERRCODE='23514'; END IF; RETURN NEW; END $$");
        db.execute("CREATE TRIGGER "+fault+" BEFORE INSERT ON production_plan_items FOR EACH ROW EXECUTE FUNCTION "+fault+"()");
        try {
            RuntimeException rejected=assertThrows(RuntimeException.class,()->writer.submit(c.analysis(),intent));
            StringBuilder causes=new StringBuilder();for(Throwable current=rejected;current!=null;current=current.getCause())causes.append(current.getMessage());
            assertTrue(causes.toString().contains("TEST_SECOND_PLAN_AFTER_FIRST_APPROVED"),causes.toString());
        } finally {
            db.execute("DROP TRIGGER "+fault+" ON production_plan_items");db.execute("DROP FUNCTION "+fault+"()");
        }
        assertEquals(0,count("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        assertEquals(0,count("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=?",c.analysis()));
        assertEquals(0,count("SELECT COUNT(*) FROM production_material_analysis_commands WHERE analysis_id=? AND operation='AGGREGATE_ORDER'",c.analysis()));
        assertEquals(intent.version(),db.queryForObject("SELECT version FROM production_material_analyses WHERE id=?",Long.class,c.analysis()));
        amount("0",db.queryForObject("SELECT COALESCE(SUM(reservation.qty-reservation.released_qty-reservation.consumed_qty),0) FROM stock_reservations reservation WHERE reservation.goods_id=? AND reservation.status=0 AND NOT reservation.is_deleted",BigDecimal.class,c.material()));
        amount("1",db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.material()));
        var retry=writer.submit(c.analysis(),intent);assertEquals(2,retry.batches().size());assertTrue(writer.submit(c.analysis(),intent).replayed());
    }

    private record CohortCase(Case c,List<UUID> outputs) { }
    private CohortCase createIndependentCohort() {
        Case seed=create(true,false,"1");var world=seed.world();
        List<MaterialAnalysisContracts.PreviewItem> roots=new ArrayList<>();List<UUID> outputs=new ArrayList<>();
        for(int index=0;index<2;index++) {
            UUID root=UUID.randomUUID(),output=UUID.randomUUID();outputs.add(output);
            fixture.insertGoods(root,"COHORT-ROOT-"+root,"独立父产品","自制",world.unitId(),world.unitLegacy());
            fixture.insertGoods(output,"COHORT-OUT-"+output,"共用原料的独立子件","自制",world.unitId(),world.unitLegacy());
            fixture.insertBom(root,output,"1");fixture.insertBom(output,seed.material(),"1");
            roots.add(new MaterialAnalysisContracts.PreviewItem("OTHER",null,root,null,world.unitId(),"cohort-"+root,"验证共享原料不重复预留",BusinessTime.today().plusDays(10),BigDecimal.ONE));
        }
        var view=analyses.preview(new MaterialAnalysisContracts.PreviewRequest(null,null,null,world.warehouseId(),"cohort-analysis-"+UUID.randomUUID(),roots));
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"cohort-routes-"+UUID.randomUUID(),view.flatMaterials().stream()
                .map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(seed.material())?"BUY":"MAKE",null)).toList()));
        Case c=new Case(world,view.analysisId(),seed.common(),null,seed.material(),seed.workshop(),seed.worker());
        return new CohortCase(c,List.copyOf(outputs));
    }

    void cancelNotification(Case c,UUID application){var current=analyses.detail(c.analysis());UUID action=db.queryForObject("SELECT id FROM preplan_supply_actions WHERE external_document_id=?",UUID.class,application);
        ordinary.cancelAction(c.analysis(),action,new CancelRequest(current.version(),current.fingerprint(),"cancel-notification-"+UUID.randomUUID(),"按本次通知完整撤回并保留准备成品"));}

    UUID produce(Case c,BatchResult batch){
        var stock=beans.getBean(com.uten.imp.features.stock.StockDocService.class);
        receive(c,c.material(),"1");
        UUID segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",UUID.class,batch.planId());
        var draws=beans.getBean(com.uten.imp.features.production.execution.ProductionDrawRequestService.class);
        var item=new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(segment,version(segment));
        var draft=draws.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(List.of(item)));
        draws.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(List.of(item),"aggregate-draw-"+segment,draft.fingerprint()));
        for(UUID doc:draft.lines().stream().map(com.uten.imp.features.production.execution.ProductionDrawRequest.Line::drawId).distinct().toList()){
            var issue=new com.uten.imp.features.stock.dto.StockDocIssueRequest();issue.setIdempotencyKey("aggregate-issue-"+doc);
            issue.setLines(draft.lines().stream().filter(row->doc.equals(row.drawId())).map(row->{var line=new com.uten.imp.features.stock.dto.StockDocIssueRequest.Line();line.setItemId(row.drawItemId());line.setQty(row.qty());return line;}).toList());stock.approveAndIssue(doc,issue);
        }
        beans.getBean(com.uten.imp.features.production.execution.ProductionExecutionSegmentService.class).start(batch.planId(),segment,new com.uten.imp.features.production.execution.SegmentTransitionRequest(version(segment),"aggregate-start-"+segment));
        var sources=beans.getBean(com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService.class).list(1,50,null,c.workshop(),List.of(segment)).getItems();
        assertEquals(1,sources.size());assertNull(sources.getFirst().orderItemId());
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",UUID.class,batch.planId());
        UUID demand=db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,segment);
        var use=new com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine();use.setDemandId(demand);use.setQtyBase(BigDecimal.ONE);
        BigDecimal output=db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?",BigDecimal.class,planItem);
        UUID report=fixture.reportAndApproveExecutionSegment(c.world(),planItem,null,c.common(),segment,null,output.toPlainString(),false,"0",null,null,List.of(use));
        List<UUID> inbound=db.queryForList("SELECT id FROM stock_documents WHERE doc_type='FINISHED_IN' AND source_daily_report_id=? AND NOT is_deleted ORDER BY created_at,id",UUID.class,report);
        for(UUID document:inbound)fixture.confirmFinishedInboundFully(document);
        return inbound.getFirst();
    }

    void setRoute(Case c,UUID goods,String route){var view=analyses.detail(c.analysis());analyses.saveRoutes(c.analysis(),new RouteRequest(view.version(),view.fingerprint(),"route-change-"+UUID.randomUUID(),view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),route,"汇总委外测试明确路线")).toList()));}

    void finishSubcontract(Case c,UUID application){
        var orders=beans.getBean(com.uten.imp.features.subcontract.order.SubcontractOrderService.class);
        var order=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();UUID settlement=ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId");order.setSettlementMethodId(settlement);
        order.setBillDate(BusinessTime.today());order.setSupplierId(c.world().supplierId());order.setWarehouseId(c.world().warehouseId());order.setCurrencyId(c.world().currencyId());order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);
        UUID applicationItem=db.queryForObject("SELECT id FROM subcontract_application_items WHERE application_id=? AND NOT is_deleted",UUID.class,application);
        var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();line.setGoodsId(c.common());line.setApplicationItemId(applicationItem);line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("3"));line.setPrice(BigDecimal.TEN);order.setItems(List.of(line));
        UUID orderId=orders.create(order).getId(),reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",c.world());
        beans.getBean(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService.class).submit("SUBCONTRACT",orderId);fixture.loginAs(reviewer);ReflectionTestUtils.invokeMethod(fixture,"approvePendingFinance","SUBCONTRACT",orderId);fixture.loginAs(c.world().superAdminUserId());
        assertEquals(1,count("SELECT count(*) FROM subcontract_material_plan_items item JOIN subcontract_material_plans plan ON plan.id=item.plan_id WHERE plan.order_id=? AND item.flow_mode='PREPARED_OUTBOUND' AND item.preparation_status='READY_OUTBOUND' AND item.prepared_qty=3 AND NOT item.is_deleted",orderId));
        UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,orderId);
        UUID issueId=db.queryForObject("SELECT issue.id FROM subcontract_material_issues issue JOIN subcontract_material_issue_items item ON item.issue_id=issue.id WHERE item.order_item_id=? AND issue.status=0 AND NOT issue.is_deleted AND NOT item.is_deleted",UUID.class,orderItem);
        beans.getBean(com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService.class).approve(issueId);
        amount("0",db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id='"+c.common()+"'",BigDecimal.class,c.world().warehouseId()));
        var receipts=beans.getBean(com.uten.imp.features.subcontract.receipt.SubcontractReceiptService.class);var receipt=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        receipt.setBillDate(BusinessTime.today());receipt.setSupplierId(c.world().supplierId());receipt.setWarehouseId(c.world().warehouseId());receipt.setCurrencyId(c.world().currencyId());receipt.setExchangeRate(BigDecimal.ONE);receipt.setTaxRate(BigDecimal.ZERO);receipt.setSettlementMethodId(settlement);
        var receiptLine=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();receiptLine.setGoodsId(c.common());receiptLine.setOrderItemId(orderItem);receiptLine.setUnitId(c.world().unitId());receiptLine.setUnitRate(BigDecimal.ONE);receiptLine.setQty(new BigDecimal("3"));receiptLine.setPrice(BigDecimal.TEN);receipt.setItems(List.of(receiptLine));
        UUID receiptId=receipts.create(receipt).getId();receipts.approve(receiptId);
        UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receiptId);
        var inspections=beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.class);
        inspections.dispose("SUBCONTRACT",receiptId,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"共享委外质量合格","shared-inspection-"+inspection));
        var stockIn=beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService.class);
        com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest incoming=ReflectionTestUtils.invokeMethod(fixture,"latestIqcStockInRequest","SUBCONTRACT",receiptId,inspection,new BigDecimal("3"),"shared-iqc-"+inspection,"AGG-SUB");
        stockIn.confirm("SUBCONTRACT",receiptId,incoming);
        amount("3",db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id='"+c.common()+"'",BigDecimal.class,c.world().warehouseId()));
        assertEquals(3,count("SELECT COUNT(DISTINCT origin_analysis_material_id) FROM preplan_analysis_stock_exact_pegs WHERE source_receipt_id=?",receiptId));
        amount("3",db.queryForObject("SELECT SUM(qty) FROM preplan_analysis_stock_exact_pegs WHERE source_receipt_id=?",BigDecimal.class,receiptId));
    }

    void receive(Case c,UUID goods,String qty){var stock=beans.getBean(com.uten.imp.features.stock.StockDocService.class);var request=new com.uten.imp.features.stock.dto.StockDocSaveRequest();request.setDocType("OTHER_IN");request.setWarehouseId(c.world().warehouseId());request.setBillDate(BusinessTime.today());
        var line=new com.uten.imp.features.stock.dto.StockDocItemLine();line.setGoodsId(goods);line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setPrice(BigDecimal.TEN);line.setAmountOriginal(new BigDecimal(qty).multiply(BigDecimal.TEN));line.setAmountLocal(line.getAmountOriginal());request.setItems(List.of(line));stock.approve(stock.create(request).getId());}
    long version(UUID segment){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}

    Case create(boolean manufacture,boolean fixed,String quantity){return create(manufacture,fixed,quantity,false);}
    Case createWithChild(String quantity){return create(true,false,quantity,true);}
    Case createForkedFixed() {
        Case seed=create(true,true,"1");var world=seed.world();
        UUID root=UUID.randomUUID(),left=UUID.randomUUID(),right=UUID.randomUUID();
        for(UUID goods:List.of(root,left,right))fixture.insertGoods(goods,"AG-FORK-"+goods,"同产品不同BOM分支","自制",world.unitId(),world.unitLegacy());
        fixture.insertBom(root,left,"1");fixture.insertBom(root,right,"1");
        fixture.insertBom(left,seed.common(),"1");fixture.insertBom(right,seed.common(),"1");
        UUID order=fixture.createApprovedOrder(world,root,"1","100");
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        var view=analyses.preview(new MaterialAnalysisContracts.PreviewRequest(null,null,null,world.warehouseId(),"forked-fixed-"+UUID.randomUUID(),
                List.of(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,BusinessTime.today().plusDays(10),BigDecimal.ONE))));
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"fork-routes-"+UUID.randomUUID(),
                view.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(world.goodsD())?"BUY":"MAKE",null)).toList()));
        return new Case(world,view.analysisId(),seed.common(),null,seed.material(),seed.workshop(),seed.worker());
    }
    /** Replays the former writer's direct-child-only construction using real
     * application primitives and DB guards. No immutable alias is deleted or altered. */
    void createLegacyDirectOnlyParent(Case c,GroupInput input) {
        var reviewed=preview.preview(c.analysis(),request(c,List.of(input)));
        var intent=new SubmitRequest(reviewed.analysis().version(),reviewed.analysis().fingerprint(),"historic-parent-"+UUID.randomUUID(),
                c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(input),reviewed.previewFingerprint());
        var group=reviewed.groups().getFirst();
        new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class)).executeWithoutResult(status->{
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
            Object commandTarget=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(ordinary);
            Object writerTarget=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(writer);
            Object analysisTarget=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(analyses);
            Object guard=ReflectionTestUtils.invokeMethod(commandTarget,"lockAnalysisWithClaimableShared",c.analysis());
            ReflectionTestUtils.invokeMethod(guard,"verifyUnchanged");
            AnalysisView current=analyses.detail(c.analysis());
            Map<UUID,Object> captured=ReflectionTestUtils.invokeMethod(writerTarget,"captureSourceCapacities",group,current);
            // The current writer returns an immutable phase snapshot. Trim a fixture
            // copy to reproduce the legacy direct-only writer, never mutate it.
            Map<UUID,Object> capacities=new HashMap<>(captured);
            Set<String> parentNodes=current.flatMaterials().stream().filter(row->input.materialLineIds().contains(row.materialLineId()))
                    .map(MaterialView::nodeKey).collect(java.util.stream.Collectors.toSet());
            Set<UUID> direct=current.flatMaterials().stream().filter(row->parentNodes.contains(row.parentNodeKey()))
                    .map(MaterialView::materialLineId).collect(java.util.stream.Collectors.toSet());
            capacities.keySet().retainAll(direct);
            String hash=ReflectionTestUtils.invokeMethod(writerTarget,"hashRequest",c.analysis(),intent);
            Object batch=ReflectionTestUtils.invokeMethod(writerTarget,"createBatch",c.analysis(),group,input,intent,hash,true,current,null,null);
            UUID batchId=ReflectionTestUtils.invokeMethod(batch,"id"),action=ReflectionTestUtils.invokeMethod(batch,"action"),anchor=ReflectionTestUtils.invokeMethod(batch,"anchor");
            ReflectionTestUtils.invokeMethod(analysisTarget,"refreshLocked",c.analysis());
            ReflectionTestUtils.invokeMethod(writerTarget,"installAliases",batch,group,capacities,intent.idempotencyKey());
            ReflectionTestUtils.invokeMethod(writerTarget,"copySharedRoutes",batch);
            ReflectionTestUtils.invokeMethod(analysisTarget,"refreshLocked",c.analysis());
            beans.getBean(PreplanStockEntitlementService.class).delegateAggregateMakeEntitlements(c.analysis(),action);
            ReflectionTestUtils.invokeMethod(commandTarget,"issueAggregateAnchor",c.analysis(),batchId,anchor,group,c.world().warehouseId(),true,intent.idempotencyKey()+"-plan");
            ReflectionTestUtils.invokeMethod(analysisTarget,"refreshWithAnchorGrowth",c.analysis());
        });
    }
    Case create(boolean manufacture,boolean fixed,String quantity,boolean nested) {
        String tag="aggregate-"+UUID.randomUUID();var world=fixture.seedWorld(tag);fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId"),worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        UUID common=manufacture?UUID.randomUUID():world.goodsD(),child=nested?UUID.randomUUID():null;
        if(manufacture)fixture.insertGoods(common,"AG-H-"+common,"共享制造父件","自制",world.unitId(),world.unitLegacy());
        if(nested){fixture.insertGoods(child,"AG-C-"+child,"先下达制造子件","自制",world.unitId(),world.unitLegacy());fixture.insertBom(common,child,"1");fixture.insertBom(child,world.goodsD(),"2");}
        else if(manufacture){fixture.insertBom(common,world.goodsD(),"1");if(fixed)db.update("UPDATE goods_bom_items SET consumption_basis='FIXED_BATCH',basis_output_qty=5 WHERE goods_id=?",common);}
        List<PreviewItem> sources=new ArrayList<>();
        for(int index=0;index<3;index++){UUID root=UUID.randomUUID();fixture.insertGoods(root,"AG-R-"+root,"不同顶层"+index,"自制",world.unitId(),world.unitLegacy());fixture.insertBom(root,common,manufacture?"1":"2");
            UUID order=fixture.createApprovedOrder(world,root,quantity,"100");UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
            sources.add(new PreviewItem("SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal(quantity)));}
        var view=analyses.preview(new MaterialAnalysisContracts.PreviewRequest(null,null,null,world.warehouseId(),"analysis-"+UUID.randomUUID(),sources));
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"routes-"+UUID.randomUUID(),view.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(world.goodsD())?"BUY":"MAKE",null)).toList()));
        return new Case(world,view.analysisId(),common,child,world.goodsD(),workshop,worker);
    }
    GroupInput input(Case c,UUID goods,String route,String qty,boolean extra){var view=analyses.detail(c.analysis());return new GroupInput(goods.toString(),view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)&&row.nodeRole().equals("BOM_COMPONENT")).map(MaterialView::materialLineId).toList(),route,new BigDecimal(qty),extra,"MAKE".equals(route)?c.workshop():null,"MAKE".equals(route)?c.worker():null,null,null,null,null,"MAKE".equals(route)?BigDecimal.ZERO:null,BigDecimal.ZERO);}
    AggregateMaterialOrderContracts.PreviewRequest request(Case c,List<GroupInput> groups){var view=analyses.detail(c.analysis());return new AggregateMaterialOrderContracts.PreviewRequest(view.version(),view.fingerprint(),"aggregate-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,groups);}
    SubmitRequest command(Case c,List<GroupInput> groups){var request=request(c,groups);return submit(preview.preview(c.analysis(),request),request);}
    SubmitRequest submit(Preview view,AggregateMaterialOrderContracts.PreviewRequest request){return new SubmitRequest(request.version(),request.fingerprint(),request.idempotencyKey(),request.warehouseId(),request.billDate(),request.deliveryDate(),request.approveNow(),request.groups(),view.previewFingerprint());}
    long count(String sql,UUID id){return db.queryForObject(sql,Long.class,id);}
    static void amount(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+", actual "+actual);}
    record Case(FullChainEndToEndTest.World world,UUID analysis,UUID common,UUID child,UUID material,UUID workshop,UUID worker){}
}
