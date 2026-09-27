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
    "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
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
    FullChainEndToEndTest fixture;
    private Object spy(){return AopTestUtils.getUltimateTargetObject(analysis);}
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void cleanup(){SecurityContextHolder.clearContext();ProductionJdbcMeasurement.end();}

    @Test void independentAndDependentGroupsConserveRealOrdersAtConfiguredScales() throws Exception {
        List<Integer> scales=Arrays.stream(System.getProperty("uten.material.order.sizes","10").split(","))
            .map(String::trim).filter(value->!value.isEmpty()).map(Integer::parseInt).toList();
        List<String> shapes=Arrays.stream(System.getProperty("uten.material.order.shapes","independent,mixed").split(","))
            .map(String::trim).toList();
        List<String> incomplete=new ArrayList<>();
        for(int size:scales)for(String shape:shapes){
            assertTrue(size>=1&&size<=100);assertTrue(Set.of("independent","mixed").contains(shape));
            Scenario scenario=create(size,shape.equals("mixed"));
            AnalysisView before=analysis.detail(scenario.analysisId());
            List<GroupInput> groups=scenario.manufacturedQty().entrySet().stream().map(entry->group(scenario,before,entry.getKey(),"MAKE",entry.getValue())).collect(Collectors.toCollection(ArrayList::new));
            groups.add(group(scenario,before,scenario.raw(),"BUY",BigDecimal.valueOf(size*40L)));
            var request=new AggregateMaterialOrderContracts.PreviewRequest(before.version(),before.fingerprint(),"scale-order-"+UUID.randomUUID(),scenario.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,groups);
            preview.preview(scenario.analysisId(),request); // Read-only warmup, excluded from command timing.
            var reviewed=measure(scenario,"preview",()->preview.preview(scenario.analysisId(),request));
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
    private record Measured<T>(T value,double millis,long statements,Map<String,Long> analysisCalls){}
    private <T> Measured<T> measure(Scenario scenario,String phase,Supplier<T> operation) throws Exception {
        clearInvocations(spy());ProductionJdbcMeasurement.Sample sql=ProductionJdbcMeasurement.begin();MaterialOrderServiceTiming.begin();
        long started=System.nanoTime();T result=null;RuntimeException failure=null;
        Map<String,Map<String,Number>> timings;
        try{result=operation.get();}catch(RuntimeException rejected){failure=rejected;}finally{ProductionJdbcMeasurement.end();timings=MaterialOrderServiceTiming.end();}
        double millis=(System.nanoTime()-started)/1_000_000.0;
        Map<String,Long> methods=new TreeMap<>();
        mockingDetails(spy()).getInvocations().forEach(call->{
            String name=call.getMethod().getName();int args=call.getMethod().getParameterCount();
            if(Set.of("detailInternal","issuePreviewView","refreshLocked","refreshWithAnchorGrowth","projectIssuePreviewBase").contains(name))methods.merge(name+"/"+args,1L,Long::sum);
        });
        Map<String,Object> record=new LinkedHashMap<>();record.put("timestamp",Instant.now().toString());record.put("run",System.getProperty("uten.material.order.run","measurement"));
        record.put("phase",phase);record.put("shape",scenario.mixed()?"mixed":"independent");record.put("components",scenario.size());record.put("expectedPlans",scenario.manufacturedQty().size());record.put("elapsedMillis",millis);record.put("analysisCalls",methods);
        record.put("outcome",failure==null?"completed":failure.getClass().getSimpleName());
        record.put("verifyNestedFootprint",environment.getProperty("uten.concurrency.verify-nested-footprint",Boolean.class));
        record.put("serviceTimings",timings);
        record.put("writerClassSha256",classHash(AggregateMaterialOrderWriteService.class));record.put("analysisClassSha256",classHash(MaterialAnalysisService.class));record.put("sql",sql.result());
        Map<String,String> dependencies=new TreeMap<>();
        for(String name:List.of("com.uten.imp.features.production.analysis.MaterialAnalysisCommandService",
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
        return new Measured<>(result,millis,sql.logicalStatements,Map.copyOf(methods));
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
    private static boolean timeout(Throwable failure){for(Throwable cause=failure;cause!=null;cause=cause.getCause())if(cause.getClass().getSimpleName().contains("Timeout")||cause.getClass().getSimpleName().contains("TimedOut")||cause instanceof org.hibernate.TransactionException&&"transaction timeout expired".equals(cause.getMessage()))return true;return false;}
    private static void amount(BigDecimal expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,expected.compareTo(actual),"expected "+expected+" actual "+actual);}
}
