package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.MaterialAnalysisController;
import com.uten.imp.features.production.analysis.MaterialAnalysisPlanWithdrawalService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.directtransfer.ProductionWorkshopDirectTransferService;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.*;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

/** Actual source responsibility, execution, inventory and exact shared-parent regression. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialAnalysisPlanWithdrawalEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired MaterialAnalysisPlanWithdrawalService withdrawals;
    @Autowired MaterialAnalysisController controller;
    @Autowired ProductionPlanningPackageService packages;
    AggregateMaterialOrderEndToEndTest h;

    @BeforeEach void before(){h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before();}
    @AfterEach void after(){h.after();}

    @Test void cancelledOldExecutionPackageStillWithdrawsOnlyItsThousandUnitParentAndKeepsSharedChild() {
        var c=h.createWithChild("1000",5);
        var shared=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE","5000",false)))).batches().getFirst();
        var roots=issueRoots(c,true);
        UUID plan=roots.getFirst().planId(),source=roots.getFirst().analysisLineId(),oldPackage=packageId(plan);
        packages.cancel(plan,oldPackage,new PlanningPackageLifecycleRequest("old-package-"+UUID.randomUUID(),"只取消旧执行安排"));
        AnalysisView before=h.analyses.detail(c.analysis());
        amount("1000",product(before,source).approvedQty());
        amount("1000",product(before,source).issuedPlanQty());
        amount("0",product(before,source).remainingQty());
        assertEquals(1,status(plan));
        var request=request(before,"withdraw-old-");
        AnalysisView restored=withdrawals.withdraw(c.analysis(),plan,request);
        assertReleased(restored,source,plan,"1000");
        assertEquals("CANCELLED",packageState(oldPackage));
        assertEquals(1,status(shared.planId()));
        amount("5000",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,shared.planId()));
        amount("5000",h.db.queryForObject("SELECT SUM(allocated_qty) FROM preplan_supply_action_allocations WHERE action_id=(SELECT action_id FROM preplan_aggregate_batches WHERE id=?)",BigDecimal.class,shared.batchId()));
        for(var other:roots.subList(1,roots.size())){
            assertEquals(1,status(other.planId()));amount("1000",product(restored,other.analysisLineId()).approvedQty());
        }
        UUID sharedSegment=segment(shared.planId());
        h.receive(c,c.child(),"5000");issueMaterials(sharedSegment,true);
        var destinations=beans.getBean(ProductionWorkshopDirectTransferService.class).candidates(sharedSegment,c.common(),null);
        assertEquals(4,destinations.candidates().size());
        assertTrue(destinations.candidates().stream().noneMatch(target->target.planId().equals(plan)));
        var replay=withdrawals.withdraw(c.analysis(),plan,request);
        assertReleased(replay,source,plan,"1000");
        assertEquals(1,h.count("SELECT COUNT(*) FROM production_material_analysis_commands WHERE analysis_id=? AND result_payload->>'commandKind'='PLAN_WITHDRAWAL_V1'",c.analysis()));
        assertCode(ErrorCode.CONFLICT,()->withdrawals.withdraw(c.analysis(),plan,
                new PlanWithdrawalRequest(request.version(),request.fingerprint(),request.idempotencyKey(),"改变撤回原因")));
    }

    @Test void livePackageAndDraftPlanWithdrawThroughTheSameAnalysisApiWithoutPlanView() {
        var c=h.create(true,false,"1000");
        var approved=issueRoots(c,true).getFirst();
        AuthUser original=current();
        grantOnly(original,Set.of("production_material_analysis:view","production_material_analysis:generate","production_plan:reverse"));
        var before=h.analyses.detail(c.analysis());
        UUID pack=packageId(approved.planId());
        var restored=controller.withdrawPlan(c.analysis(),approved.planId(),request(before,"approved-withdraw-"));
        assertReleased(restored,approved.analysisLineId(),approved.planId(),"1000");
        assertEquals("REVERSED",packageState(pack));
        authenticate(original);
        var draft=issueRoots(c,false).getFirst();
        grantOnly(original,Set.of("production_material_analysis:view","production_material_analysis:generate","production_plan:delete"));
        var draftBefore=h.analyses.detail(c.analysis());
        var draftRequest=request(draftBefore,"draft-withdraw-");
        var draftAfter=controller.withdrawPlan(c.analysis(),draft.planId(),draftRequest);
        amount("1000",product(draftAfter,draft.analysisLineId()).remainingQty());
        amount("0",product(draftAfter,draft.analysisLineId()).issuedPlanQty());
        assertTrue(h.db.queryForObject("SELECT is_deleted FROM production_plans WHERE id=?",Boolean.class,draft.planId()));
        assertEquals("RELEASED",h.db.queryForObject("SELECT allocation_status FROM production_material_analysis_plan_links WHERE plan_id=?",String.class,draft.planId()));
        controller.withdrawPlan(c.analysis(),draft.planId(),draftRequest);
    }

    @Test void staleWrongAnalysisSharedAndMissingPermissionsCannotWithdrawAnything() {
        var c=h.create(true,false,"1");
        AnalysisView stale=h.analyses.detail(c.analysis());
        var root=issueRoots(c,true).getFirst();
        assertCode(ErrorCode.CONFLICT,()->withdrawals.withdraw(c.analysis(),root.planId(),request(stale,"stale-withdraw-")));
        var foreign=h.create(true,false,"1");
        assertCode(ErrorCode.NOT_FOUND,()->withdrawals.withdraw(foreign.analysis(),root.planId(),request(h.analyses.detail(foreign.analysis()),"foreign-withdraw-")));
        h.fixture.loginAs(c.world().superAdminUserId());
        AuthUser original=current();
        for(String absent:List.of("production_material_analysis:generate","production_plan:reverse")){
            var grants=new HashSet<>(original.getPermissions());grants.remove(absent);grantOnly(original,grants);
            var current=h.analyses.detail(c.analysis());
            assertCode(ErrorCode.FORBIDDEN,()->withdrawals.withdraw(c.analysis(),root.planId(),request(current,"forbidden-withdraw-")));
        }
        authenticate(original);
        var shared=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE","3",false)))).batches().getFirst();
        var now=h.analyses.detail(c.analysis());
        var error=assertThrows(ApiException.class,()->withdrawals.withdraw(c.analysis(),shared.planId(),request(now,"shared-withdraw-")));
        assertTrue(error.getMessage().contains("共享制造"));
        assertEquals(1,status(root.planId()));assertEquals(1,status(shared.planId()));
        assertEquals(0,h.count("SELECT COUNT(*) FROM production_material_analysis_commands WHERE analysis_id=? AND result_payload->>'commandKind'='PLAN_WITHDRAWAL_V1'",c.analysis()));
    }

    @Test void ordinaryComponentKeepsItsOriginalTaskAndMaterialTreeWhenWithdrawnAndReissued() {
        var c=h.createWithChild("1");var initial=h.analyses.detail(c.analysis());
        var material=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow();
        UUID originalLine=material.materialLineId();
        var issued=h.ordinary.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(initial.version(),initial.fingerprint(),
                "ordinary-component-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(originalLine,null,BigDecimal.ONE,null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO))));
        UUID plan=issued.plans().getFirst().planId();
        UUID source=h.db.queryForObject("SELECT material_analysis_item_id FROM production_plans WHERE id=?",UUID.class,plan);
        assertEquals("MAKE_COMPONENT",product(issued.analysis(),source).sourceType());
        // Current issue-plans deliberately creates no action. Seed only the legacy
        // notification reference using its historical schema shape; all source/plan
        // quantities and the actual BOM tree still come from the real issue command.
        UUID action=legacyMakeAction(c,originalLine,source,material.actionGroupKey());
        var withAction=h.analyses.detail(c.analysis());
        assertEquals(source,withAction.supplyActions().stream().filter(row->row.actionId().equals(action)).findFirst().orElseThrow().documentId());
        // Ordinary anchors retain the original root's material tree, rather than
        // constructing another copy underneath the task's analysisLineId.
        List<UUID> children=initial.flatMaterials().stream()
                .filter(row->row.analysisLineId().equals(material.analysisLineId())&&row.level()>material.level())
                .map(MaterialView::materialLineId).toList();
        assertFalse(children.isEmpty());
        var restored=withdrawals.withdraw(c.analysis(),plan,request(withAction,"component-withdraw-"));
        assertReleased(restored,source,plan,"1");
        assertEquals(originalLine,h.db.queryForObject("SELECT parent_analysis_material_id FROM production_material_analysis_items WHERE id=? AND NOT is_deleted",UUID.class,source));
        amount("1",product(restored,source).requestedQty());
        assertFalse(restored.supplyActions().stream().filter(row->row.actionId().equals(action)).anyMatch(row->"CANCELLED".equals(row.status())));
        assertTrue(restored.flatMaterials().stream().map(MaterialView::materialLineId).toList().containsAll(children));
        assertTrue(restored.flatMaterials().stream().filter(row->children.contains(row.materialLineId())).anyMatch(row->row.requiredQty().signum()>0));
        var next=h.ordinary.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(restored.version(),restored.fingerprint(),
                "component-reissue-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,source,BigDecimal.ONE,null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO))));
        UUID nextPlan=next.plans().getFirst().planId();
        assertNotEquals(plan,nextPlan);
        assertEquals(source,h.db.queryForObject("SELECT material_analysis_item_id FROM production_plans WHERE id=?",UUID.class,nextPlan));
        amount("1",product(next.analysis(),source).approvedQty());amount("1",product(next.analysis(),source).issuedPlanQty());
        assertEquals(List.of(nextPlan),product(next.analysis(),source).planReferences().stream().map(PlanReference::planId).toList());
        assertEquals(1,next.analysis().supplyActions().stream().filter(row->source.equals(row.documentId())).count());
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void actualIssuedInventoryAndStartedWorkRejectAtomically(boolean started) {
        var c=h.create(true,false,"1",false,1,"1");var root=issueRoots(c,true).getFirst();
        h.receive(c,c.common(),"1");issueMaterials(segment(root.planId()),started);
        var before=h.analyses.detail(c.analysis());UUID pack=packageId(root.planId());
        String segmentState=h.db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,segment(root.planId()));
        assertThrows(ApiException.class,()->withdrawals.withdraw(c.analysis(),root.planId(),request(before,"executed-withdraw-")));
        assertEquals("CONFIRMED",packageState(pack));assertEquals(1,status(root.planId()));
        assertEquals(segmentState,h.db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,segment(root.planId())));
        var after=h.analyses.detail(c.analysis());amount("1",product(after,root.analysisLineId()).approvedQty());
        assertEquals(before.version(),after.version());
        assertEquals(0,h.count("SELECT COUNT(*) FROM production_material_analysis_commands WHERE analysis_id=? AND result_payload->>'commandKind'='PLAN_WITHDRAWAL_V1'",c.analysis()));
    }

    @Test void approvedDailyReportCannotWithdrawItsPlanOrChangePhysicalAndCostFacts() {
        var c=h.create(true,false,"1",false,1,"1");var root=issueRoots(c,true).getFirst();
        UUID execution=segment(root.planId()),pack=packageId(root.planId());
        h.receive(c,c.common(),"1");issueMaterials(execution,true);
        var segment=h.db.queryForMap("SELECT source_plan_item_id,product_goods_id FROM production_execution_segments WHERE id=?",execution);
        UUID planItem=(UUID)segment.get("source_plan_item_id"),outputGoods=(UUID)segment.get("product_goods_id");
        var allocation=h.db.queryForMap("SELECT id,sales_order_item_id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",execution);
        UUID demand=h.db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,execution);
        var use=new com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine();
        use.setDemandId(demand);use.setQtyBase(BigDecimal.ONE);
        UUID report=h.fixture.reportAndApproveExecutionSegment(c.world(),planItem,(UUID)allocation.get("sales_order_item_id"),
                outputGoods,execution,(UUID)allocation.get("id"),"1",false,"0",null,null,List.of(use));
        assertEquals(1,h.db.queryForObject("SELECT status FROM production_daily_reports WHERE id=?",Integer.class,report));
        amount("1",h.db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=?",BigDecimal.class,planItem));
        // The output has passed FQC but is not physically received yet. Its real
        // consumed cost lives in COST_WIP; production output inputs register at stock-in.
        assertTrue(h.count("""
                SELECT COUNT(*) FROM stock_value_events event
                JOIN stock_value_nodes node ON node.id=event.result_node_id
                WHERE event.source_doc_type='PRODUCTION_CONSUMED_VALUE'
                    AND node.owner_kind='COST_WIP'
                    AND node.owner_id=fn_production_execution_cost_scope(?) AND node.basis_value_local>0
                """,execution)>0,"The approved report must have real positive consumed-material cost provenance");
        AnalysisView before=h.analyses.detail(c.analysis());
        String facts=reportedWithdrawalFacts(c,root,execution,pack,report,outputGoods);
        assertThrows(ApiException.class,()->withdrawals.withdraw(c.analysis(),root.planId(),request(before,"reported-withdraw-")));
        assertEquals(facts,reportedWithdrawalFacts(c,root,execution,pack,report,outputGoods),
                "Rejected withdrawal preserves plan/package/link/quantities, approved report, physical stock and the cost ledger");
        AnalysisView after=h.analyses.detail(c.analysis());
        assertEquals(before.version(),after.version());assertEquals(before.fingerprint(),after.fingerprint());
        amount("1",product(after,root.analysisLineId()).approvedQty());
        assertEquals(0,h.count("SELECT COUNT(*) FROM production_material_analysis_commands WHERE analysis_id=? AND result_payload->>'commandKind'='PLAN_WITHDRAWAL_V1'",c.analysis()));
    }

    @Test void reusedSupplyActionWithdrawalKeyCannotReplayAPlanWithdrawal() {
        var c=h.create(false,false,"1");var root=issueRoots(c,true).getFirst();
        var batch=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.material(),"BUY","6",false)))).batches().getFirst();
        UUID action=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,batch.batchId());
        var now=h.analyses.detail(c.analysis());String key="cross-kind-"+UUID.randomUUID();
        // Store the existing generic action command proof, then exercise the collision check.
        h.db.update("INSERT INTO production_material_analysis_commands(analysis_id,operation,idempotency_key,request_hash,result_payload,created_by) VALUES(?,'CANCEL_ACTION',?,?,'{}'::jsonb,?)",
                c.analysis(),key,"a".repeat(64),c.world().superAdminUserId());
        assertCode(ErrorCode.CONFLICT,()->withdrawals.withdraw(c.analysis(),root.planId(),new PlanWithdrawalRequest(now.version(),now.fingerprint(),key,"不能混用撤回意图")));
        assertEquals(1,status(root.planId()));assertEquals("CONFIRMED",packageState(packageId(root.planId())));
        assertNotNull(action);
    }

    private record IssuedRoot(UUID planId, UUID analysisLineId) { }
    private List<IssuedRoot> issueRoots(AggregateMaterialOrderEndToEndTest.Case c,boolean approve) {
        AnalysisView view=h.analyses.detail(c.analysis());
        return h.ordinary.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"withdraw-roots-"+UUID.randomUUID(),
                c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),approve,
                view.products().stream().filter(row->row.salesOrderItemId()!=null&&row.remainingQty().signum()>0)
                        .map(row->new IssueWorkshopPlansRequest.IssuePlanLine(null,row.analysisLineId(),row.remainingQty(),null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO)).toList())).plans()
                .stream().map(plan->new IssuedRoot(plan.planId(),h.db.queryForObject(
                        "SELECT material_analysis_item_id FROM production_plans WHERE id=?",UUID.class,plan.planId()))).toList();
    }

    private void issueMaterials(UUID segment,boolean start) {
        var execution=beans.getBean(ProductionExecutionSegmentService.class);
        UUID plan=h.db.queryForObject("SELECT plan_id FROM production_execution_segments WHERE id=?",UUID.class,segment);
        if("WAITING".equals(h.db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,segment))) {
            execution.recheckMaterial(plan,segment,new SegmentTransitionRequest(h.version(segment),"withdraw-recheck-"+segment));
        }
        var draws=beans.getBean(ProductionDrawRequestService.class);var stock=beans.getBean(StockDocService.class);
        var item=new ProductionDrawRequest.Item(segment,h.version(segment));
        var shown=draws.preview(new ProductionDrawRequest.PreviewRequest(List.of(item)));
        draws.submit(new ProductionDrawRequest.SubmitRequest(List.of(item),"withdraw-draw-"+segment,shown.fingerprint()));
        for(UUID doc:shown.lines().stream().map(ProductionDrawRequest.Line::drawId).distinct().toList()){
            var issue=new StockDocIssueRequest();issue.setIdempotencyKey("withdraw-issue-"+doc);
            issue.setLines(shown.lines().stream().filter(line->doc.equals(line.drawId())).map(row->{var line=new StockDocIssueRequest.Line();line.setItemId(row.drawItemId());line.setQty(row.qty());return line;}).toList());
            stock.approveAndIssue(doc,issue);
        }
        if(start) execution.start(plan,segment,
                new SegmentTransitionRequest(h.version(segment),"withdraw-start-"+segment));
    }

    private UUID legacyMakeAction(AggregateMaterialOrderEndToEndTest.Case c,UUID material,UUID source,String group) {
        UUID action=UUID.randomUUID();String proof="legacy-notify-"+action;
        String hash=com.uten.imp.common.util.CanonicalFingerprint.sha256(List.of(proof,source.toString()));
        new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class)).executeWithoutResult(status->{
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
            Object target=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(h.ordinary);
            Object guard=org.springframework.test.util.ReflectionTestUtils.invokeMethod(target,"lockAnalysisWithClaimableShared",c.analysis());
            org.springframework.test.util.ReflectionTestUtils.invokeMethod(guard,"verifyUnchanged");
            h.db.update("""
                    INSERT INTO preplan_supply_actions(id,analysis_id,warehouse_id,goods_id,color_id,unit_id,need_date,
                        route,requested_qty,status,idempotency_key,action_group_key,request_business_key,generation,request_hash,created_by)
                    SELECT ?,analysis_id,?,goods_id,color_id,unit_id,expected_ready_date,'MAKE',1,'OPEN',?,?,?,1,?,?
                    FROM production_material_analysis_materials WHERE id=? AND analysis_id=?
                    """,action,c.world().warehouseId(),proof,group,hash,hash,c.world().superAdminUserId(),material,c.analysis());
            h.db.update("""
                    INSERT INTO preplan_supply_action_allocations(action_id,analysis_id,analysis_material_id,allocated_qty)
                    VALUES(?,?,?,1)
                    """,action,c.analysis(),material);
            h.db.update("""
                    UPDATE preplan_supply_actions SET status='CREATED',external_document_type='PREPLAN_MAKE_TASK',
                        external_document_id=?,external_document_no=(SELECT source_ref FROM production_material_analysis_items WHERE id=?)
                    WHERE id=?
                    """,source,source,action);
            h.db.update("UPDATE preplan_supply_action_allocations SET external_item_id=? WHERE action_id=?",source,action);
        });
        return action;
    }

    private String reportedWithdrawalFacts(AggregateMaterialOrderEndToEndTest.Case c,IssuedRoot root,
            UUID segment,UUID pack,UUID report,UUID outputGoods) {
        return h.db.queryForObject("""
                WITH scope AS (SELECT ?::uuid AS plan_id,?::uuid AS package_id,?::uuid AS analysis_id,
                    ?::uuid AS source_id,?::uuid AS segment_id,?::uuid AS report_id,
                    ?::uuid AS input_goods,?::uuid AS output_goods)
                SELECT jsonb_build_object(
                    'plan',(SELECT to_jsonb(p) FROM production_plans p WHERE p.id=s.plan_id),
                    'package',(SELECT to_jsonb(p) FROM production_planning_packages p WHERE p.id=s.package_id),
                    'segment',(SELECT to_jsonb(p) FROM production_execution_segments p WHERE p.id=s.segment_id),
                    'analysis',(SELECT to_jsonb(p) FROM production_material_analyses p WHERE p.id=s.analysis_id),
                    'source',(SELECT to_jsonb(p) FROM production_material_analysis_items p WHERE p.id=s.source_id),
                    'links',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM production_material_analysis_plan_links p WHERE p.plan_id=s.plan_id),
                    'report',(SELECT to_jsonb(p) FROM production_daily_reports p WHERE p.id=s.report_id),
                    'reportItems',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM production_daily_report_items p WHERE p.report_id=s.report_id),
                    'planItems',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM production_plan_items p WHERE p.plan_id=s.plan_id),
                    'stock',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM stock_balances p WHERE p.goods_id IN(s.input_goods,s.output_goods)),
                    'movements',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM stock_movements p WHERE p.goods_id IN(s.input_goods,s.output_goods)),
                    'costEvents',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM stock_value_events e JOIN stock_value_pools p ON p.id=e.pool_id WHERE p.goods_id IN(s.input_goods,s.output_goods)),
                    'costNodes',(SELECT jsonb_agg(to_jsonb(n) ORDER BY n.id) FROM stock_value_nodes n JOIN stock_value_pools p ON p.id=n.pool_id WHERE p.goods_id IN(s.input_goods,s.output_goods)),
                    'costObject',(SELECT to_jsonb(p) FROM stock_value_production_cost_objects p WHERE p.execution_segment_id=s.segment_id),
                    'costInputs',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.input_node_id) FROM stock_value_production_cost_inputs p WHERE p.execution_segment_id=s.segment_id),
                    'costOutputs',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.source_node_id) FROM stock_value_production_cost_outputs p WHERE p.execution_segment_id=s.segment_id),
                    'costTasks',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM stock_value_production_cost_tasks p WHERE p.execution_segment_id=s.segment_id),
                    'costShares',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.input_node_id,p.output_source_node_id) FROM stock_value_production_cost_shares p JOIN stock_value_production_cost_outputs o ON o.source_node_id=p.output_source_node_id WHERE o.execution_segment_id=s.segment_id))::text
                FROM scope s
                """,String.class,root.planId(),pack,c.analysis(),root.analysisLineId(),segment,report,c.common(),outputGoods);
    }

    private void assertReleased(AnalysisView view,UUID source,UUID plan,String qty){
        assertEquals(-1,status(plan));assertEquals("REVERSED",h.db.queryForObject("SELECT allocation_status FROM production_material_analysis_plan_links WHERE plan_id=?",String.class,plan));
        amount(qty,product(view,source).remainingQty());amount("0",product(view,source).approvedQty());amount("0",product(view,source).issuedPlanQty());
        assertTrue(product(view,source).planReferences().stream().noneMatch(reference->reference.planId().equals(plan)));
        assertTrue(view.flatMaterials().stream().filter(row->row.analysisLineId().equals(source)&&row.nodeRole().equals("ROOT_SUPPLY"))
                .noneMatch(row->"MAKE_WAITING_MATERIAL".equals(row.flowStage())));
    }
    private static ProductView product(AnalysisView view,UUID source){return view.products().stream().filter(row->row.analysisLineId().equals(source)).findFirst().orElseThrow();}
    private static PlanWithdrawalRequest request(AnalysisView view,String prefix){return new PlanWithdrawalRequest(view.version(),view.fingerprint(),prefix+UUID.randomUUID(),"整批撤回原生产责任");}
    private int status(UUID plan){return h.db.queryForObject("SELECT status FROM production_plans WHERE id=?",Integer.class,plan);}
    private UUID packageId(UUID plan){return h.db.queryForObject("SELECT id FROM production_planning_packages WHERE plan_id=? AND NOT is_deleted ORDER BY created_at DESC LIMIT 1",UUID.class,plan);}
    private String packageState(UUID pack){return h.db.queryForObject("SELECT status FROM production_planning_packages WHERE id=?",String.class,pack);}
    private UUID segment(UUID plan){return h.db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted ORDER BY created_at DESC LIMIT 1",UUID.class,plan);}
    private static AuthUser current(){return (AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();}
    private static void grantOnly(AuthUser user,Set<String> grants){authenticate(new AuthUser(user.getId(),user.getEmployeeId(),user.getUsername(),grants,false,true,false));}
    private static void authenticate(AuthUser user){SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));}
    private static void assertCode(ErrorCode code,org.junit.jupiter.api.function.Executable action){assertEquals(code,assertThrows(ApiException.class,action).getCode());}
}
