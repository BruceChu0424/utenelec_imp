package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/** Real source facts plus the original pre-V729 SELECT prove exact compatibility.
 * Probe helpers reject unrelated source IDs, so performance scope is an invariant,
 * independent of wall clock, JVM warmup, query cost estimates, or test machine load. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
    "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
    "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
    "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ScopedPublicSurplusReaderPostgresTest {
    private static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("scoped_public_sources").withUsername("uten").withPassword("uten");
    private static String legacyDefinition;
    private static List<Map<String,Object>> legacyColumns;
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) throws Exception {
        DATABASE.start();
        Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                .locations("classpath:db/migration").target("728").load().migrate();
        var before=new JdbcTemplate(new DriverManagerDataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword()));
        legacyDefinition=before.queryForObject("SELECT pg_get_viewdef('v_preplan_public_surplus_source_state'::regclass,true)",String.class).strip().replaceFirst(";$","");
        legacyColumns=before.queryForList(COLUMN_QUERY);
        registry.add("spring.datasource.url",DATABASE::getJdbcUrl);
        registry.add("spring.datasource.username",DATABASE::getUsername);
        registry.add("spring.datasource.password",DATABASE::getPassword);
        registry.add("uten.storage.local-dir",()->System.getProperty("java.io.tmpdir")+"/scoped-public-reader-"+DATABASE.getContainerId());
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired PlatformTransactionManager transactions;
    UnplacedPublicSupplyEndToEndTest support;
    @BeforeEach void prepare(){support=new UnplacedPublicSupplyEndToEndTest();beans.autowireBean(support);support.prepare();}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void compatibilityViewAndScopedReaderPreserveEveryColumnAcrossClaimAndActualReceipt(){
        assertEquals(legacyColumns,db.queryForList(COLUMN_QUERY));
        for(String route:List.of("BUY","SUBCONTRACT")) {
            Supply supply=create(route);
            String pointPlan=String.join("\n",db.queryForList("EXPLAIN (COSTS FALSE) SELECT * FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",String.class,supply.action()));
            assertFalse(pointPlan.contains("Function Scan on fn_preplan_public_surplus_sources"),pointPlan);
            assertEquals(db.queryForObject("SELECT to_jsonb(source)::text FROM ("+legacyDefinition+") source WHERE source_action_id=?",String.class,supply.action()),
                    db.queryForObject("SELECT to_jsonb(source)::text FROM v_preplan_public_surplus_source_state source WHERE source_action_id=?",String.class,supply.action()));
            assertExact(supply.target().analysisId());
            MaterialView target=material(supply.target(),supply.goods());
            var claimed=commands.claimSharedFuture(supply.target().analysisId(),new ClaimSharedFutureRequest(
                    supply.target().version(),supply.target().fingerprint(),"scoped-claim-"+UUID.randomUUID(),
                    List.of(target.actionGroupKey()),List.of(new SharedFutureClaimQuantity(target.actionGroupKey(),new BigDecimal("400"),supply.action())),true));
            assertExact(claimed.analysisId());
            assertEquals(0,new BigDecimal("500").compareTo(db.queryForObject(
                    "SELECT available_to_claim_qty FROM fn_preplan_public_surplus_sources(?) WHERE source_action_id=?",BigDecimal.class,claimed.analysisId(),supply.action())));
            // A scoped reader retains exact source identity, including a source's own
            // dimensions. Admission still rejects self-adoption in the existing guard.
            assertExact(supply.source().analysisId());
            UUID ownMaterial=material(analyses.detail(supply.source().analysisId()),supply.goods()).materialLineId();
            assertTrue(db.queryForObject("SELECT fn_preplan_public_target_is_source(?,?)",Boolean.class,supply.action(),ownMaterial));
            if("BUY".equals(route)) {
                var receiptSupport=support.support;
                UUID orderItem=ReflectionTestUtils.invokeMethod(receiptSupport,"approveOrder",supply.world(),supply.item(),supply.goods(),"1000",BusinessTime.today().plusDays(5));
                ReflectionTestUtils.invokeMethod(receiptSupport,"receive",supply.world(),orderItem,supply.goods(),"600");
                support.fixture.loginAs(supply.world().superAdminUserId());
                assertExact(claimed.analysisId());
            }
        }
        assertEquals(jsonRows("("+legacyDefinition+")"),jsonRows("v_preplan_public_surplus_source_state"));
    }

    @Test void sameMainColorUnitAndActiveTargetBoundariesAreAppliedBeforeSourceEvaluation(){
        Supply supply=create("BUY");UUID analysis=supply.target().analysisId();
        UUID target=material(supply.target(),supply.goods()).materialLineId();
        assertExact(analysis);assertEquals(1,count(analysis));
        Supply other=create("BUY");
        var transaction=new TransactionTemplate(transactions);
        transaction.executeWithoutResult(status->{
            db.update("UPDATE production_material_analysis_materials SET color_id=? WHERE id=?",supply.world().colorId(),target);
            assertEquals(0,count(analysis));assertExact(analysis);status.setRollbackOnly();
        });
        transaction.executeWithoutResult(status->{
            db.update("UPDATE production_material_analysis_materials SET unit_id=? WHERE id=?",other.world().unitId(),target);
            assertEquals(0,count(analysis));assertExact(analysis);status.setRollbackOnly();
        });
        transaction.executeWithoutResult(status->{
            db.update("UPDATE production_material_analysis_materials SET active=FALSE WHERE id=?",target);
            assertEquals(0,count(analysis));assertExact(analysis);status.setRollbackOnly();
        });
        assertEquals(0,db.queryForObject("SELECT count(*) FROM fn_preplan_public_surplus_sources(?) WHERE source_action_id=?",Integer.class,other.target().analysisId(),supply.action()));
        UUID leaf=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",leaf,"SCOPE-"+leaf,"同主仓范围",supply.world().warehouseId());
        transaction.executeWithoutResult(status->{
            db.update("UPDATE production_material_analyses SET warehouse_id=?,participating_warehouse_ids=ARRAY[?]::uuid[] WHERE id=?",leaf,leaf,analysis);
            assertEquals(1,count(analysis));assertExact(analysis);status.setRollbackOnly();
        });
    }

    @Test void unrelatedWorldsNeverEvaluateCapacityClaimReceiptOrEtaHelpers(){
        Supply target=create("BUY");
        claim(target,"100");
        UUID targetOrder=approveOrder(target);
        // Independent real purchase requests, each with its own source/analysis/main
        // warehouse, expose the former growth-by-unrelated-worlds defect.
        for(int i=0;i<16;i++) {
            Supply unrelated=create(i%2==0?"BUY":"SUBCONTRACT");
            if(i<2)claim(unrelated,"100");
            if(i==0)approveOrder(unrelated);
        }
        support.fixture.loginAs(target.world().superAdminUserId());
        String expected=legacyScopedRows(target.target().analysisId());
        Set<UUID> allowed=new HashSet<>(db.queryForList("SELECT source_action_id FROM fn_preplan_public_surplus_sources(?)",UUID.class,target.target().analysisId()));
        allowed.addAll(db.queryForList("SELECT id FROM preplan_supply_actions WHERE claim_source_action_id IN (SELECT source_action_id FROM fn_preplan_public_surplus_sources(?))",UUID.class,target.target().analysisId()));
        assertTrue(allowed.contains(target.action()));
        assertTrue(db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE operation_type='SUPPLY'",Integer.class)>=17);
        Map<String,String> originals=new LinkedHashMap<>();
        try {
            for(String helper:List.of("fn_preplan_public_source_approved_capacity","fn_preplan_public_source_open_qty",
                    "fn_preplan_public_source_planning_capacity","fn_preplan_public_source_planning_open_qty")) {
                installProbe(helper,"uuid,uuid",allowed,1,originals);
            }
            installProbe("fn_preplan_action_received_qty","uuid",allowed,1,originals);
            installProbe("fn_procurement_order_source_remaining_qty","text,uuid,uuid",Set.of(targetOrder),2,originals);
            installProbe("fn_procurement_order_source_pending_qty","text,uuid,uuid",Set.of(targetOrder),2,originals);
            assertEquals(expected,scopedRows(target.target().analysisId()));
            // This negative control proves the probes catch the old algorithm's
            // evaluation of sources that only the outer WHERE would discard.
            RuntimeException failure=assertThrows(RuntimeException.class,()->legacyScopedRows(target.target().analysisId()));
            assertTrue(failure.toString().contains("UNRELATED_PUBLIC_SOURCE_EVALUATED"),failure.toString());
        } finally {
            originals.values().forEach(db::execute);
        }
    }

    private void installProbe(String name,String types,Set<UUID> allowed,int sourcePosition,Map<String,String> originals){
        String definition=db.queryForObject("SELECT pg_get_functiondef(CAST(? AS regprocedure))",String.class,name+"("+types+")");
        originals.put(name,definition);
        String saved=name+"_scope_probe_original";
        db.execute(definition.replace("FUNCTION public."+name+"(","FUNCTION public."+saved+"("));
        String parameters=db.queryForObject("SELECT pg_get_function_arguments(CAST(? AS regprocedure))",String.class,name+"("+types+")");
        String arguments=String.join(",",java.util.stream.IntStream.rangeClosed(1,types.split(",").length).mapToObj(index->"$"+index).toList());
        String source="$"+sourcePosition;
        String ids=String.join(",",allowed.stream().map(id->"'"+id+"'::uuid").toList());
        db.execute("CREATE OR REPLACE FUNCTION "+name+"("+parameters+") RETURNS numeric LANGUAGE plpgsql STABLE AS $probe$ BEGIN "
                +"IF "+source+" NOT IN("+ids+") THEN RAISE EXCEPTION 'UNRELATED_PUBLIC_SOURCE_EVALUATED: %',"+source+"; END IF; "
                +"RETURN "+saved+"("+arguments+"); END $probe$");
    }
    private void assertExact(UUID analysis){assertEquals(legacyScopedRows(analysis),scopedRows(analysis));}
    private int count(UUID analysis){return db.queryForObject("SELECT count(*) FROM fn_preplan_public_surplus_sources(?)",Integer.class,analysis);}
    private String scopedRows(UUID analysis){return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(source) ORDER BY source_action_id,claim_external_item_id),'[]'::jsonb)::text FROM fn_preplan_public_surplus_sources(?) source",String.class,analysis);}
    private String legacyScopedRows(UUID analysis){return db.queryForObject("""
            SELECT COALESCE(jsonb_agg(to_jsonb(source) ORDER BY source_action_id,claim_external_item_id),'[]'::jsonb)::text
            FROM (%s) source WHERE EXISTS(SELECT 1 FROM production_material_analyses target
              JOIN production_material_analysis_materials material ON material.analysis_id=target.id AND material.active
              WHERE target.id=? AND NOT target.is_deleted AND fn_warehouse_same_main(target.warehouse_id,source.warehouse_id)
                AND material.goods_id=source.goods_id AND material.color_id IS NOT DISTINCT FROM source.color_id AND material.unit_id=source.unit_id)
            """.formatted(legacyDefinition),String.class,analysis);}
    private String jsonRows(String source){return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(source) ORDER BY source_action_id,claim_external_item_id),'[]'::jsonb)::text FROM "+source+" source",String.class);}
    private Supply create(String route){
        Object original=ReflectionTestUtils.invokeMethod(support,"create",route);
        return new Supply(ReflectionTestUtils.invokeMethod(original,"world"),ReflectionTestUtils.invokeMethod(original,"goods"),
                ReflectionTestUtils.invokeMethod(original,"source"),ReflectionTestUtils.invokeMethod(original,"target"),
                ReflectionTestUtils.invokeMethod(original,"action"),ReflectionTestUtils.invokeMethod(original,"item"));
    }
    private void claim(Supply supply,String qty){
        var view=analyses.detail(supply.target().analysisId());var material=material(view,supply.goods());
        commands.claimSharedFuture(view.analysisId(),new ClaimSharedFutureRequest(view.version(),view.fingerprint(),"scope-claim-"+UUID.randomUUID(),
                List.of(material.actionGroupKey()),List.of(new SharedFutureClaimQuantity(material.actionGroupKey(),new BigDecimal(qty),supply.action())),true));
    }
    private UUID approveOrder(Supply supply){return ReflectionTestUtils.invokeMethod(support.support,"approveOrder",supply.world(),supply.item(),supply.goods(),"1000",BusinessTime.today().plusDays(5));}
    private MaterialView material(AnalysisView view,UUID goods){return view.flatMaterials().stream().filter(item->goods.equals(item.goodsId())).findFirst().orElseThrow();}
    private record Supply(FullChainEndToEndTest.World world,UUID goods,AnalysisView source,AnalysisView target,UUID action,UUID item){}
    private static final String COLUMN_QUERY="SELECT attname,format_type(atttypid,atttypmod) type FROM pg_attribute WHERE attrelid='v_preplan_public_surplus_source_state'::regclass AND attnum>0 AND NOT attisdropped ORDER BY attnum";
}
