package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.nio.file.*;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import java.util.function.Supplier;
import java.util.stream.Collectors;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real independent manufacture groups share raw material; scale counts groups, not quantity ticks. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
    "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
    "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
    "uten.bootstrap.admin-password=HarnessAdminPass-1!",
    // Benchmark production behavior; ordinary correctness suites retain the stronger diagnostic default.
    "uten.concurrency.verify-nested-footprint=${uten.material.order.verifyNestedFootprint:false}"})
@Import({ProductionJdbcMeasurement.Configuration.class,MaterialOrderServiceTiming.Configuration.class})
class MaterialAggregateOrderScalePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper mapper;
    @Autowired Environment environment;
    @MockitoSpyBean MaterialAnalysisService analysis;
    @Autowired AggregateMaterialOrderPreviewService preview;
    @Autowired AggregateMaterialOrderWriteService writer;
    @Autowired MaterialAnalysisCommandService commands;
    FullChainEndToEndTest fixture;
    private Object spy(){return AopTestUtils.getUltimateTargetObject(analysis);}
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void cleanup(){SecurityContextHolder.clearContext();ProductionJdbcMeasurement.end();}

    @RepeatedTest(3) void independentExternalGroupsShareRecalculationAndPreserveEverySource() throws Exception {
        exerciseExternalBatch(Integer.getInteger("uten.material.external.size",30),false);
    }

    @Test void independentExternalPartialOrdersAppendToTheSameDocuments() throws Exception {
        exerciseExternalBatch(3,true);
    }

    @Test void independentExternalGroupsAfterRootIssueStillShareRecalculation() throws Exception {
        exerciseExternalBatch(8,false,true);
    }

    @Test void topLevelWorkshopBatchConservesEverySalesSourceAtConfiguredScale() throws Exception {
        for(int repetition=0;repetition<measurementRepetitions();repetition++)exerciseTopLevelWorkshopBatch();
    }

    private void exerciseTopLevelWorkshopBatch() throws Exception {
        int size=Integer.getInteger("uten.material.root.size",10);
        assertTrue(size>=1&&size<=100);
        String tag="root-order-"+UUID.randomUUID();var world=fixture.seedWorld(tag);fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId"),worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        UUID raw=goods(world,"共同采购原料",false);List<PreviewItem> sources=new ArrayList<>();
        for(int index=0;index<size;index++) {
            UUID root=goods(world,"顶层产品"+index,true);fixture.insertBom(root,raw,"2");
            UUID order=fixture.createApprovedOrder(world,root,"10","100");
            UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
            sources.add(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,BusinessTime.today().plusDays(10),BigDecimal.TEN));
        }
        AnalysisView initial=analysis.preview(new MaterialAnalysisContracts.PreviewRequest(null,null,null,world.warehouseId(),tag,sources));
        AnalysisView before=analysis.saveRoutes(initial.analysisId(),new RouteRequest(initial.version(),initial.fingerprint(),tag+"-routes",
                initial.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.level()==0?"MAKE":"BUY",null)).toList()));
        List<IssueWorkshopPlansRequest.IssuePlanLine> lines=before.products().stream()
                .filter(product->"SALES_ORDER_ITEM".equals(product.sourceType()))
                .map(product->new IssueWorkshopPlansRequest.IssuePlanLine(null,product.analysisLineId(),BigDecimal.TEN,
                        BusinessTime.today(),BusinessTime.today().plusDays(10),workshop,null,worker,null,null,false,BigDecimal.ZERO)).toList();
        assertEquals(size,lines.size());
        var request=new IssueWorkshopPlansRequest(before.version(),before.fingerprint(),tag+"-submit",world.warehouseId(),
                BusinessTime.today(),BusinessTime.today().plusDays(10),true,lines);
        Scenario scenario=new Scenario(world,before.analysisId(),raw,workshop,worker,size,false,Map.of(),Map.of());
        if(measureAllPreviews()) {
            String factsBefore=previewFacts(before.analysisId());
            var previewRequest=new PreviewIssuePlansRequest(request.version(),request.fingerprint(),request.idempotencyKey(),request.warehouseId(),
                    request.billDate(),request.deliveryDate(),request.approveNow(),request.lines(),List.of());
            var projected=measure(scenario,"root-preview",()->commands.previewIssuePlans(before.analysisId(),previewRequest));
            assertEquals(before.analysisId(),projected.value().analysisId());
            assertEquals(factsBefore,previewFacts(before.analysisId()),"root preview must not change durable analysis or order facts");
        }
        var submitted=measure(scenario,"root-submit",()->commands.issueWorkshopPlans(before.analysisId(),request));
        assertFalse(submitted.value().replayed());assertEquals(size,submitted.value().plans().size());
        var facts=db.queryForList("SELECT link.id,link.analysis_item_id,link.plan_id,link.submitted_qty FROM production_material_analysis_plan_links link WHERE link.analysis_id=? ORDER BY link.id",before.analysisId());
        assertEquals(size,facts.size());facts.forEach(row->amount(BigDecimal.TEN,(BigDecimal)row.get("submitted_qty")));
        var replayed=measure(scenario,"root-replay",()->commands.issueWorkshopPlans(before.analysisId(),request));
        assertTrue(replayed.value().replayed());
        assertEquals(submitted.value().plans().stream().map(GeneratedPlan::planId).toList(),replayed.value().plans().stream().map(GeneratedPlan::planId).toList());
        assertEquals(facts,db.queryForList("SELECT link.id,link.analysis_item_id,link.plan_id,link.submitted_qty FROM production_material_analysis_plan_links link WHERE link.analysis_id=? ORDER BY link.id",before.analysisId()));
    }

    private void exerciseExternalBatch(int size,boolean partial) throws Exception {
        exerciseExternalBatch(size,partial,false);
    }

    private void exerciseExternalBatch(int size,boolean partial,boolean issueRoots) throws Exception {
        for(String route:List.of("BUY","SUBCONTRACT")) {
            String tag="ma-external-"+UUID.randomUUID();var world=fixture.seedWorld(tag);fixture.loginAs(world.superAdminUserId());
            List<UUID> materials=new ArrayList<>();
            UUID raw=goods(world,"共同直属原料",false);
            for(int index=0;index<size;index++) {
                UUID material=goods(world,"独立外部物料"+index,false);materials.add(material);
                db.update("UPDATE goods SET source_type=?,default_supplier_id=? WHERE id=?","BUY".equals(route)?"采购":"委外",world.supplierId(),material);
                if("SUBCONTRACT".equals(route))fixture.insertBom(material,raw,"1");
            }
            List<PreviewItem> sources=new ArrayList<>();
            for(int index=0;index<2;index++) {
                UUID root=goods(world,"销售产品"+index,true);for(UUID material:materials)fixture.insertBom(root,material,"1");
                UUID order=fixture.createApprovedOrder(world,root,"10","100");
                UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
                sources.add(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,BusinessTime.today().plusDays(10),BigDecimal.TEN));
            }
            AnalysisView initial=analysis.preview(new MaterialAnalysisContracts.PreviewRequest(null,null,null,world.warehouseId(),"external-analysis-"+UUID.randomUUID(),sources));
            AnalysisView routed=analysis.saveRoutes(initial.analysisId(),new RouteRequest(initial.version(),initial.fingerprint(),"external-routes-"+UUID.randomUUID(),initial.flatMaterials().stream()
                    .filter(row->materials.contains(row.goodsId())).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),route,null)).toList()));
            AnalysisView before=issueRoots?issueRoots(routed,world):routed;
            assertTrue(before.flatMaterials().stream().filter(row->materials.contains(row.goodsId())).allMatch(row->row.planAnchorAnalysisLineId()==null),
                    "root plans do not turn unrelated external components into MAKE anchors");
            Scenario scenario=new Scenario(world,before.analysisId(),raw,null,null,size,false,Map.of(),Map.of());
            List<GroupInput> groups=materials.stream().map(material->group(scenario,before,material,route,new BigDecimal("20")))
                    .map(input->!partial?input:new GroupInput(input.clientGroupKey(),input.materialLineIds(),route,BigDecimal.TEN,false,
                            null,null,null,null,null,null,null,BigDecimal.ZERO,input.materialLineIds().stream()
                            .collect(Collectors.toMap(id->id,id->new BigDecimal("5"))))).toList();
            var request=new AggregateMaterialOrderContracts.PreviewRequest(before.version(),before.fingerprint(),"external-order-"+UUID.randomUUID(),world.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,groups);
            String factsBefore=measureAllPreviews()?previewFacts(scenario.analysisId()):null;
            var reviewed=measureAllPreviews()?measure(scenario,route+"-preview",()->preview.preview(scenario.analysisId(),request)).value()
                    :preview.preview(scenario.analysisId(),request);
            if(measureAllPreviews())assertEquals(factsBefore,previewFacts(scenario.analysisId()),"external preview must not change durable analysis or order facts");
            var command=new SubmitRequest(request.version(),request.fingerprint(),request.idempotencyKey(),request.warehouseId(),request.billDate(),request.deliveryDate(),true,groups,reviewed.previewFingerprint());
            var ordered=measure(scenario,route+"-submit",()->writer.submit(scenario.analysisId(),command));
            assertFalse(ordered.value().replayed());assertEquals(size,ordered.value().batches().size());
            for(BatchResult batch:ordered.value().batches()) {
                amount(partial?BigDecimal.TEN:new BigDecimal("20"),batch.qty());assertEquals(route,batch.route());assertEquals(2,batch.sources().size());
                for(SourcePreview source:batch.sources())amount(partial?new BigDecimal("5"):BigDecimal.TEN,source.allocatedQty());
            }
            List<Map<String,Object>> facts=db.queryForList("SELECT id,action_id,analysis_material_id,allocated_qty FROM preplan_supply_action_allocations WHERE analysis_id=? ORDER BY id",scenario.analysisId());
            assertEquals(size*2,facts.size());
            var replayed=measure(scenario,route+"-replay",()->writer.submit(scenario.analysisId(),command));
            assertTrue(replayed.value().replayed());
            org.assertj.core.api.Assertions.assertThat(replayed.value().batches()).usingRecursiveComparison()
                    .withComparatorForType(BigDecimal::compareTo,BigDecimal.class).isEqualTo(ordered.value().batches());
            assertEquals(facts,db.queryForList("SELECT id,action_id,analysis_material_id,allocated_qty FROM preplan_supply_action_allocations WHERE analysis_id=? ORDER BY id",scenario.analysisId()));
            if(!"before".equals(System.getProperty("uten.material.order.run"))) {
                assertTrue(ordered.analysisCalls().getOrDefault("refreshLocked/2",0L)<=3,"external sibling refresh count "+ordered.analysisCalls());
                assertTrue(ordered.analysisCalls().getOrDefault("detailInternal/2",0L)<=3,"external sibling detail count "+ordered.analysisCalls());
                assertEquals(1L,ordered.sqlCalls().getOrDefault("insert.preplan_supply_actions",0L),
                        "one proven stage must create its supply facts in one statement");
            }
            if(partial) {
                AnalysisView remaining=ordered.value().analysis();
                var nextRequest=new AggregateMaterialOrderContracts.PreviewRequest(remaining.version(),remaining.fingerprint(),"external-append-"+UUID.randomUUID(),world.warehouseId(),request.billDate(),request.deliveryDate(),true,groups);
                var nextReviewed=preview.preview(scenario.analysisId(),nextRequest);
                var nextCommand=new SubmitRequest(nextRequest.version(),nextRequest.fingerprint(),nextRequest.idempotencyKey(),nextRequest.warehouseId(),nextRequest.billDate(),nextRequest.deliveryDate(),true,groups,nextReviewed.previewFingerprint());
                var appended=measure(scenario,route+"-append",()->writer.submit(scenario.analysisId(),nextCommand));
                assertEquals(ordered.value().batches().stream().map(BatchResult::batchId).toList(),appended.value().batches().stream().map(BatchResult::batchId).toList());
                assertEquals(ordered.value().batches().stream().map(BatchResult::documentId).toList(),appended.value().batches().stream().map(BatchResult::documentId).toList());
                List<BigDecimal> allocated=db.queryForList("SELECT allocated_qty FROM preplan_supply_action_allocations WHERE analysis_id=?",BigDecimal.class,scenario.analysisId());
                assertEquals(size*2,allocated.size());allocated.forEach(qty->amount(BigDecimal.TEN,qty));
                assertTrue(appended.analysisCalls().getOrDefault("refreshLocked/2",0L)<=3,"append sibling refresh count "+appended.analysisCalls());
                assertTrue(writer.submit(scenario.analysisId(),nextCommand).replayed());
                List<GroupInput> publicGroups=groups.stream().map(input->new GroupInput(input.clientGroupKey(),input.materialLineIds(),route,
                        new BigDecimal("2"),true,null,null,null,null,null,null,null,BigDecimal.ZERO,
                        input.materialLineIds().stream().collect(Collectors.toMap(id->id,id->BigDecimal.ONE)))).toList();
                AnalysisView fulfilled=appended.value().analysis();
                var publicRequest=new AggregateMaterialOrderContracts.PreviewRequest(fulfilled.version(),fulfilled.fingerprint(),"external-public-"+UUID.randomUUID(),world.warehouseId(),request.billDate(),request.deliveryDate(),true,publicGroups);
                var publicReviewed=preview.preview(scenario.analysisId(),publicRequest);
                var publicCommand=new SubmitRequest(publicRequest.version(),publicRequest.fingerprint(),publicRequest.idempotencyKey(),world.warehouseId(),request.billDate(),request.deliveryDate(),true,publicGroups,publicReviewed.previewFingerprint());
                var extra=writer.submit(scenario.analysisId(),publicCommand);
                assertEquals(ordered.value().batches().stream().map(BatchResult::documentId).toList(),extra.batches().stream().map(BatchResult::documentId).toList());
                extra.batches().forEach(batch->{amount(new BigDecimal("2"),batch.publicExtraQty());amount(new BigDecimal("2"),batch.qty());});
                amount(BigDecimal.valueOf(size*20L),db.queryForObject("SELECT sum(requested_qty) FROM preplan_supply_actions WHERE analysis_id=? AND route=?",BigDecimal.class,scenario.analysisId(),route));
                amount(BigDecimal.valueOf(size*2L),db.queryForObject("SELECT sum(public_surplus_qty) FROM preplan_supply_actions WHERE analysis_id=? AND route=?",BigDecimal.class,scenario.analysisId(),route));
                assertTrue(writer.submit(scenario.analysisId(),publicCommand).replayed());
            }
        }
    }

    private AnalysisView issueRoots(AnalysisView view,FullChainEndToEndTest.World world) {
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","external-roots-"+UUID.randomUUID());
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId"),worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        List<IssueWorkshopPlansRequest.IssuePlanLine> lines=view.products().stream().filter(product->"SALES_ORDER_ITEM".equals(product.sourceType()))
                .map(product->new IssueWorkshopPlansRequest.IssuePlanLine(null,product.analysisLineId(),BigDecimal.TEN,
                        BusinessTime.today(),BusinessTime.today().plusDays(10),workshop,null,worker,null,null,false,BigDecimal.ZERO)).toList();
        assertEquals(2,lines.size());
        return commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "external-roots-"+UUID.randomUUID(),world.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,lines)).analysis();
    }

    @Test void externalChildrenOfSharedMakeBatchKeepOriginalIntentAndBatchTheRefresh() throws Exception {
        for(String route:List.of("BUY","SUBCONTRACT")) {
            String tag="external-alias-"+UUID.randomUUID();var world=fixture.seedWorld(tag);fixture.loginAs(world.superAdminUserId());
            Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);
            UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId"),worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
            UUID parent=goods(world,"共享制造父件",true),raw=goods(world,"委外直属原料",false);
            List<UUID> materials=new ArrayList<>();
            for(int index=0;index<8;index++) {
                UUID material=goods(world,"共享制造外部子件"+index,false);materials.add(material);
                db.update("UPDATE goods SET source_type=?,default_supplier_id=? WHERE id=?","BUY".equals(route)?"采购":"委外",world.supplierId(),material);
                fixture.insertBom(parent,material,"1");if("SUBCONTRACT".equals(route))fixture.insertBom(material,raw,"1");
            }
            List<PreviewItem> sources=new ArrayList<>();
            for(int index=0;index<2;index++) {
                UUID root=goods(world,"外层产品"+index,true);fixture.insertBom(root,parent,"1");
                UUID order=fixture.createApprovedOrder(world,root,"10","100");
                UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
                sources.add(new PreviewItem("SALES_ORDER_ITEM",item,null,null,null,null,null,BusinessTime.today().plusDays(10),BigDecimal.TEN));
            }
            AnalysisView initial=analysis.preview(new MaterialAnalysisContracts.PreviewRequest(null,null,null,world.warehouseId(),tag,sources));
            AnalysisView routed=analysis.saveRoutes(initial.analysisId(),new RouteRequest(initial.version(),initial.fingerprint(),"alias-routes-"+UUID.randomUUID(),initial.flatMaterials().stream()
                    .filter(row->materials.contains(row.goodsId())||parent.equals(row.goodsId()))
                    .map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),parent.equals(row.goodsId())?"MAKE":route,null)).toList()));
            Scenario scenario=new Scenario(world,routed.analysisId(),raw,workshop,worker,8,false,Map.of(),Map.of());
            List<GroupInput> external=materials.stream().map(material->group(scenario,routed,material,route,new BigDecimal("20"))).toList();
            GroupInput make=group(scenario,routed,parent,"MAKE",new BigDecimal("20"));
            var parentRequest=new AggregateMaterialOrderContracts.PreviewRequest(routed.version(),routed.fingerprint(),"alias-parent-"+UUID.randomUUID(),world.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(make));
            var parentPreview=preview.preview(scenario.analysisId(),parentRequest);
            AnalysisView current=writer.submit(scenario.analysisId(),new SubmitRequest(parentRequest.version(),parentRequest.fingerprint(),parentRequest.idempotencyKey(),world.warehouseId(),parentRequest.billDate(),parentRequest.deliveryDate(),true,List.of(make),parentPreview.previewFingerprint())).analysis();
            var request=new AggregateMaterialOrderContracts.PreviewRequest(current.version(),current.fingerprint(),"alias-external-"+UUID.randomUUID(),world.warehouseId(),parentRequest.billDate(),parentRequest.deliveryDate(),true,external);
            var reviewed=preview.preview(scenario.analysisId(),request);
            assertTrue(reviewed.groups().stream().allMatch(group->group.sources().size()==1),"two originals resolve to each shared batch child");
            var command=new SubmitRequest(request.version(),request.fingerprint(),request.idempotencyKey(),world.warehouseId(),request.billDate(),request.deliveryDate(),true,external,reviewed.previewFingerprint());
            var ordered=measure(scenario,route+"-shared-make-children",()->writer.submit(scenario.analysisId(),command));
            assertEquals(8,ordered.value().batches().size());
            for(BatchResult batch:ordered.value().batches()) {
                amount(new BigDecimal("20"),batch.qty());assertEquals(1,batch.sources().size());
                amount(new BigDecimal("20"),batch.sources().getFirst().allocatedQty());
                assertEquals(2,batch.sources().getFirst().originalMaterialLineIds().size());
            }
            Map<UUID,MaterialView> after=ordered.value().analysis().flatMaterials().stream().collect(Collectors.toMap(MaterialView::materialLineId,row->row));
            for(GroupInput input:external)for(UUID original:input.materialLineIds())amount(BigDecimal.TEN,after.get(original).aggregatePreparation().orderedQty());
            assertTrue(ordered.analysisCalls().getOrDefault("refreshLocked/2",0L)<=3,"shared children still refreshed per group: "+ordered.analysisCalls());
            assertTrue(ordered.analysisCalls().getOrDefault("detailInternal/2",0L)<=3,"shared children still read details per group: "+ordered.analysisCalls());
            assertTrue(writer.submit(scenario.analysisId(),command).replayed());
        }
    }

    @Test void independentAndDependentGroupsConserveRealOrdersAtConfiguredScales() throws Exception {
        List<Integer> scales=Arrays.stream(System.getProperty("uten.material.order.sizes","10").split(","))
            .map(String::trim).filter(value->!value.isEmpty()).map(com.uten.imp.testsupport.FixtureNumbers::integer).toList();
        List<String> shapes=Arrays.stream(System.getProperty("uten.material.order.shapes","independent,mixed").split(","))
            .map(String::trim).toList();
        List<String> incomplete=new ArrayList<>();
        for(int repetition=0;repetition<measurementRepetitions();repetition++)for(int size:scales)for(String shape:shapes){
            assertTrue(size>=1&&size<=100);assertTrue(Set.of("independent","mixed").contains(shape));
            Scenario scenario=create(size,shape.equals("mixed"));
            AnalysisView before=analysis.detail(scenario.analysisId());
            List<GroupInput> groups=scenario.manufacturedQty().entrySet().stream().map(entry->group(scenario,before,entry.getKey(),"MAKE",entry.getValue())).collect(Collectors.toCollection(ArrayList::new));
            groups.add(group(scenario,before,scenario.raw(),"BUY",BigDecimal.valueOf(size*40L)));
            var request=new AggregateMaterialOrderContracts.PreviewRequest(before.version(),before.fingerprint(),"scale-order-"+UUID.randomUUID(),scenario.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,groups);
            String factsBefore=measureAllPreviews()?previewFacts(scenario.analysisId()):null;
            preview.preview(scenario.analysisId(),request); // Read-only warmup, excluded from command timing.
            var reviewed=measure(scenario,"preview",()->preview.preview(scenario.analysisId(),request));
            if(measureAllPreviews())assertEquals(factsBefore,previewFacts(scenario.analysisId()),"manufacturing previews must not change durable analysis or order facts");
            SubmitRequest command=new SubmitRequest(request.version(),request.fingerprint(),request.idempotencyKey(),request.warehouseId(),request.billDate(),request.deliveryDate(),true,groups,reviewed.value().previewFingerprint());
            Measured<SubmitResult> ordered;
            try{ordered=measure(scenario,"submit",()->writer.submit(scenario.analysisId(),command));}
            catch(RuntimeException failure){
                if(!timeout(failure))throw failure;
                assertEquals(0,planIds(scenario).size(),"timed-out batch must not leave plans");
                assertEquals(0,taskCodes(scenario).size(),"timed-out batch must not leave ZX tasks");
                assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=?",Integer.class,scenario.analysisId()),"timed-out batch must not leave supply actions");
                assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_analysis_commands WHERE analysis_id=? AND operation='AGGREGATE_ORDER'",Integer.class,scenario.analysisId()),"timed-out batch must not leave a success receipt");
                assertEquals(before.version(),db.queryForObject("SELECT version FROM production_material_analyses WHERE id=?",Long.class,scenario.analysisId()));
                System.out.println("MATERIAL-ORDER-ROLLBACK components="+size+" shape="+shape+" plans=0 tasks=0 actions=0 commandReceipts=0 versionUnchanged=true");
                if(!Boolean.getBoolean("uten.material.order.allowTimeout"))incomplete.add(shape+"/"+size+": "+failure.getClass().getSimpleName());
                continue;
            }
            assertFalse(ordered.value().replayed());
            verifyFacts(scenario,ordered.value());
            List<UUID> plans=planIds(scenario);List<String> tasks=taskCodes(scenario);
            var replayed=measure(scenario,"replay",()->writer.submit(scenario.analysisId(),command));
            assertTrue(replayed.value().replayed());assertEquals(plans,planIds(scenario));assertEquals(tasks,taskCodes(scenario));
            verifyFacts(scenario,replayed.value());
            assertEquals(1,db.queryForObject("SELECT count(*) FROM production_material_analysis_commands WHERE analysis_id=? AND operation='AGGREGATE_ORDER' AND idempotency_key=?",Integer.class,scenario.analysisId(),request.idempotencyKey()));
            if(!"before".equals(System.getProperty("uten.material.order.run")))verifyWorkBudget(scenario,reviewed,ordered,replayed);
            // Opt-in acceptance budget: capture the old baseline without silently declaring it fast.
            long budget=Long.getLong("uten.material.order.maxMillis",0L);
            if(budget>0)assertTrue(ordered.millis()<=budget,"batch order took "+ordered.millis()+"ms, budget "+budget);
        }
        assertTrue(incomplete.isEmpty(),"requested scenarios did not complete: "+incomplete);
    }

    private static int measurementRepetitions() {
        int repetitions=Integer.getInteger("uten.material.order.repetitions",1);
        assertTrue(repetitions>=1&&repetitions<=5,"measurement repetitions must be between one and five");
        return repetitions;
    }

    private static boolean measureAllPreviews() {
        return Boolean.getBoolean("uten.material.order.measureAllPreviews");
    }

    /** Read outside the resource window; compare identities, quantities and versions, not just row counts. */
    private String previewFacts(UUID analysisId) {
        return db.queryForObject("""
                WITH target AS (SELECT CAST(? AS uuid) id)
                SELECT md5(jsonb_build_object(
                    'header',(SELECT to_jsonb(header) FROM production_material_analyses header WHERE header.id=target.id),
                    'items',(SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id) FROM production_material_analysis_items item WHERE item.analysis_id=target.id),
                    'materials',(SELECT jsonb_agg(to_jsonb(material) ORDER BY material.id) FROM production_material_analysis_materials material WHERE material.analysis_id=target.id),
                    'actions',(SELECT jsonb_agg(to_jsonb(action) ORDER BY action.id) FROM preplan_supply_actions action WHERE action.analysis_id=target.id),
                    'allocations',(SELECT jsonb_agg(to_jsonb(allocation) ORDER BY allocation.id) FROM preplan_supply_action_allocations allocation WHERE allocation.analysis_id=target.id),
                    'makeClaims',(SELECT jsonb_agg(to_jsonb(claim) ORDER BY claim.id) FROM preplan_make_public_claims claim WHERE claim.target_analysis_id=target.id),
                    'plans',(SELECT jsonb_agg(to_jsonb(plan) ORDER BY plan.id) FROM production_plans plan WHERE plan.material_analysis_id=target.id),
                    'batches',(SELECT jsonb_agg(to_jsonb(batch) ORDER BY batch.id) FROM preplan_aggregate_batches batch WHERE batch.analysis_id=target.id),
                    'commands',(SELECT jsonb_agg(to_jsonb(command) ORDER BY command.id) FROM production_material_analysis_commands command WHERE command.analysis_id=target.id)
                )::text) FROM target
                """,String.class,analysisId);
    }

    private record Scenario(FullChainEndToEndTest.World world,UUID analysisId,UUID raw,
        UUID workshop,UUID worker,int size,boolean mixed,Map<UUID,BigDecimal> manufacturedQty,
        Map<UUID,BigDecimal> originalDemand){}
    private Scenario create(int size,boolean mixed){
        String tag="ma-scale-"+UUID.randomUUID();var world=fixture.seedWorld(tag);fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId"),worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        UUID raw=goods(world,"共同原料",false);db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",world.supplierId(),raw);
        List<UUID> top=new ArrayList<>();Map<UUID,BigDecimal> manufactured=new LinkedHashMap<>();
        for(int index=0;index<size;index++){
            UUID component=goods(world,"独立制造组件"+index,true);top.add(component);manufactured.put(component,new BigDecimal("20"));
            if(mixed&&index%2==0){UUID child=goods(world,"下一层制造组件"+index,true);manufactured.put(child,new BigDecimal("40"));fixture.insertBom(component,child,"2");fixture.insertBom(child,raw,"1");}
            else fixture.insertBom(component,raw,"2");
        }
        List<PreviewItem> sources=new ArrayList<>();
        for(int index=0;index<2;index++){
            UUID root=goods(world,"销售产品"+index,true);for(UUID component:top)fixture.insertBom(root,component,"1");
            UUID order=fixture.createApprovedOrder(world,root,"10","100");
            UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
            sources.add(new PreviewItem("SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),BigDecimal.TEN));
        }
        var view=analysis.preview(new MaterialAnalysisContracts.PreviewRequest(null,null,null,world.warehouseId(),"scale-analysis-"+UUID.randomUUID(),sources));
        analysis.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"scale-routes-"+UUID.randomUUID(),view.flatMaterials().stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(raw)?"BUY":"MAKE",null)).toList()));
        Map<UUID,BigDecimal> originalDemand=view.flatMaterials().stream().filter(row->"BOM_COMPONENT".equals(row.nodeRole()))
                .collect(Collectors.toMap(MaterialView::materialLineId,MaterialView::requiredQty));
        return new Scenario(world,view.analysisId(),raw,workshop,worker,size,mixed,Map.copyOf(manufactured),Map.copyOf(originalDemand));
    }
    private UUID goods(FullChainEndToEndTest.World world,String name,boolean make){UUID id=UUID.randomUUID();fixture.insertGoods(id,"MS-"+id,name,make?"自制":"采购",world.unitId(),world.unitLegacy());return id;}
    private GroupInput group(Scenario scenario,AnalysisView view,UUID goods,String route,BigDecimal qty){
        var rows=view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)&&"BOM_COMPONENT".equals(row.nodeRole())).toList();
        Map<UUID,BigDecimal> intent=rows.stream().collect(Collectors.toMap(MaterialView::materialLineId,MaterialView::requiredQty));
        amount(qty,intent.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add));
        return new GroupInput(goods.toString(),rows.stream().map(MaterialView::materialLineId).toList(),route,qty,false,
            "MAKE".equals(route)?scenario.workshop():null,"MAKE".equals(route)?scenario.worker():null,null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO,intent);
    }
    private record Measured<T>(T value,double millis,long statements,Map<String,Long> analysisCalls,Map<String,Long> sqlCalls){}
    private <T> Measured<T> measure(Scenario scenario,String phase,Supplier<T> operation) throws Exception {
        clearInvocations(spy());ProductionJdbcMeasurement.Sample sql=ProductionJdbcMeasurement.begin();MaterialOrderServiceTiming.begin();
        var resources=CommandResourceMeasurement.begin((org.testcontainers.containers.GenericContainer<?>)
                ReflectionTestUtils.getField(FullChainEndToEndTest.class,"POSTGRES"));Map<String,Object> resourceMetrics;
        long started=System.nanoTime();T result=null;RuntimeException failure=null;
        Map<String,Map<String,Number>> timings;double millis;
        try{result=operation.get();}catch(RuntimeException rejected){failure=rejected;}
        finally{millis=(System.nanoTime()-started)/1_000_000.0;resourceMetrics=resources.finish();ProductionJdbcMeasurement.end();timings=MaterialOrderServiceTiming.end();}
        Map<String,Long> methods=new TreeMap<>();
        mockingDetails(spy()).getInvocations().forEach(call->{
            String name=call.getMethod().getName();int args=call.getMethod().getParameterCount();
            if(Set.of("detailInternal","issuePreviewView","refreshLocked","refreshWithAnchorGrowth","projectIssuePreviewBase").contains(name))methods.merge(name+"/"+args,1L,Long::sum);
        });
        Map<String,Object> record=new LinkedHashMap<>();record.put("timestamp",Instant.now().toString());record.put("run",System.getProperty("uten.material.order.run","measurement"));
        record.put("phase",phase);record.put("shape",scenario.mixed()?"mixed":"independent");record.put("components",scenario.size());record.put("expectedPlans",phase.startsWith("root-")?scenario.size():scenario.manufacturedQty().size());record.put("elapsedMillis",millis);record.put("analysisCalls",methods);
        record.put("outcome",failure==null?"completed":failure.getClass().getSimpleName());
        record.put("verifyNestedFootprint",environment.getProperty("uten.concurrency.verify-nested-footprint",Boolean.class));
        record.put("serviceTimings",timings);
        record.put("resources",resourceMetrics);
        record.put("writerClassSha256",classHash(AggregateMaterialOrderWriteService.class));record.put("analysisClassSha256",classHash(MaterialAnalysisService.class));record.put("sql",sql.result());
        Map<String,String> dependencies=new TreeMap<>();
        for(String name:List.of("com.uten.imp.features.production.analysis.MaterialAnalysisCommandService",
                "com.uten.imp.features.production.analysis.AggregateExternalOrderCohort",
                "com.uten.imp.features.production.plan.ProductionPlanService",
                "com.uten.imp.features.production.mrp.ProductionPlanningPackageService",
                "com.uten.imp.features.production.mrp.ProductionExecutionPackageCommandService",
                "com.uten.imp.features.production.mrp.AnalysisExecutionSnapshotScope")){
            try{Class<?> type=Class.forName(name);dependencies.put(type.getSimpleName(),classHash(type));}
            catch(ClassNotFoundException missing){dependencies.put(name,"ABSENT");}
        }
        record.put("dependencyClassSha256",dependencies);
        var hot=sql.nanosByFingerprint.entrySet().stream().sorted(Map.Entry.<String,Long>comparingByValue().reversed()).limit(12).map(entry->{
            Map<String,Object> row=new LinkedHashMap<>();row.put("fingerprint",entry.getKey());row.put("label",sql.labelsByFingerprint.get(entry.getKey()));row.put("calls",sql.fingerprints.get(entry.getKey()));row.put("millis",entry.getValue()/1_000_000.0);return row;
        }).toList();record.put("hotSql",hot);
        Path path=Path.of(System.getProperty("uten.build.directory","target")).resolve(System.getProperty("uten.material.order.evidenceFile","material-order-scale.jsonl"));Files.createDirectories(path.getParent());Files.writeString(path,mapper.writeValueAsString(record)+System.lineSeparator(),StandardOpenOption.CREATE,StandardOpenOption.APPEND);
        System.out.println("MATERIAL-ORDER-SCALE "+mapper.writeValueAsString(Map.of("phase",phase,"shape",record.get("shape"),"components",scenario.size(),"millis",millis,"statements",sql.logicalStatements,"analysisCalls",methods,"hotSql",hot,"outcome",record.get("outcome"))));
        if(failure!=null)throw failure;
        Map<String,Long> sqlCalls=new TreeMap<>();
        sql.fingerprints.forEach((fingerprint,calls)->sqlCalls.merge(sql.labelsByFingerprint.get(fingerprint),calls,Long::sum));
        return new Measured<>(result,millis,sql.logicalStatements,Map.copyOf(methods),Map.copyOf(sqlCalls));
    }
    private void verifyWorkBudget(Scenario scenario,Measured<?> previewed,Measured<?> ordered,Measured<?> replayed){
        int levels=scenario.mixed()?2:1;
        // Per-plan create/approve work is linear. Tree refresh and complete detail
        // reads are bounded by dependency levels, never by number of sibling groups.
        // Keep modest headroom over the measured batched-read/approval path;
        // the old 200 statements per plan allowed almost a full N+1 regression.
        long sqlLimit=700L+110L*scenario.manufacturedQty().size()+250L*(levels-1);
        assertTrue(ordered.statements()<=sqlLimit,"submit SQL "+ordered.statements()+" exceeds "+sqlLimit);
        assertTrue(ordered.analysisCalls().getOrDefault("refreshLocked/2",0L)<=3L*levels+3,"full refresh grew with sibling count: "+ordered.analysisCalls());
        assertTrue(ordered.analysisCalls().getOrDefault("detailInternal/2",0L)<=2L*levels+3,"full detail grew with sibling count: "+ordered.analysisCalls());
        assertTrue(previewed.statements()<=140,"preview SQL must remain a bounded batch read");
        assertTrue(replayed.statements()<=100,"idempotent replay must not repeat command work");
        assertEquals(1L,replayed.analysisCalls().getOrDefault("detailInternal/2",0L));
        assertEquals(0L,replayed.analysisCalls().getOrDefault("refreshLocked/2",0L));
    }
    private void verifyFacts(Scenario scenario,SubmitResult result){
        Map<UUID,MaterialView> shown=result.analysis().flatMaterials().stream().collect(Collectors.toMap(MaterialView::materialLineId,row->row));
        scenario.originalDemand().forEach((id,qty)->{
            assertNotNull(shown.get(id),"original row identity survives every aggregate level");
            assertNotNull(shown.get(id).aggregatePreparation(),"original row has an exact preparation projection");
            amount(qty,shown.get(id).aggregatePreparation().orderedQty());
        });
        assertEquals(scenario.manufacturedQty().size()+1,result.batches().size());
        assertEquals(scenario.manufacturedQty().size(),planIds(scenario).size());
        for(var entry:scenario.manufacturedQty().entrySet()){
            amount(entry.getValue(),db.queryForObject("SELECT sum(item.qty*item.unit_rate) FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id WHERE plan.material_analysis_id=? AND item.goods_id=? AND NOT plan.is_deleted AND NOT item.is_deleted",BigDecimal.class,scenario.analysisId(),entry.getKey()));
        }
        assertEquals(scenario.manufacturedQty().size(),taskCodes(scenario).size());
        assertTrue(taskCodes(scenario).stream().allMatch(code->code!=null&&code.startsWith("ZX")));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM purchase_request_items item JOIN preplan_supply_actions action ON action.external_document_id=item.request_id WHERE action.analysis_id=? AND action.route='BUY' AND NOT item.is_deleted",Integer.class,scenario.analysisId()));
        amount(BigDecimal.valueOf(scenario.size()*40L),db.queryForObject("SELECT sum(item.qty*item.unit_rate) FROM purchase_request_items item JOIN preplan_supply_actions action ON action.external_document_id=item.request_id WHERE action.analysis_id=? AND action.route='BUY' AND NOT item.is_deleted",BigDecimal.class,scenario.analysisId()));
        amount(BigDecimal.valueOf(scenario.size()*40L),db.queryForObject("SELECT sum(allocation.allocated_qty) FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE action.analysis_id=? AND action.route='BUY'",BigDecimal.class,scenario.analysisId()));
        amount(BigDecimal.ZERO,db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,scenario.raw()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_execution_segments segment JOIN production_plans plan ON plan.id=segment.plan_id WHERE plan.material_analysis_id=? AND segment.status<>'WAITING' AND NOT segment.is_deleted",Integer.class,scenario.analysisId()));
    }
    private List<UUID> planIds(Scenario scenario){return db.queryForList("SELECT id FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted ORDER BY id",UUID.class,scenario.analysisId());}
    private List<String> taskCodes(Scenario scenario){return db.queryForList("SELECT segment.segment_code FROM production_execution_segments segment JOIN production_plans plan ON plan.id=segment.plan_id WHERE plan.material_analysis_id=? AND NOT segment.is_deleted ORDER BY segment.segment_code",String.class,scenario.analysisId());}
    private static String classHash(Class<?> type) throws Exception {try(var stream=type.getResourceAsStream(type.getSimpleName()+".class")){return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Objects.requireNonNull(stream).readAllBytes()));}}
    private static boolean timeout(Throwable failure){for(Throwable cause=failure;cause!=null;cause=cause.getCause()){ if(cause.getClass().getSimpleName().contains("Timeout")||cause.getClass().getSimpleName().contains("TimedOut")||cause instanceof org.hibernate.TransactionException&&"transaction timeout expired".equals(cause.getMessage())){ return true; } }return false;}
    private static void amount(BigDecimal expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,expected.compareTo(actual),"expected "+expected+" actual "+actual);}
}
