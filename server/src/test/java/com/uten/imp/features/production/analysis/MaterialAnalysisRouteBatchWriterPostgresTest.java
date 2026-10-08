package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.junit.jupiter.api.Assertions.*;

/** Executes the production SQL and an independent frozen SQL oracle on PostgreSQL.
 * The small schema isolates join plans; migrated business-chain tests remain the release gate. */
@Testcontainers(disabledWithoutDocker=true)
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MaterialAnalysisRouteBatchWriterPostgresTest {
    @Container static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static final MaterialSnapshotInput ROUTES=new MaterialSnapshotInput(
            "material_id uuid","group_key varchar","route varchar","reason varchar","suggestion varchar");
    private static final String LEGACY_GUARD=resource("guard").formatted(ROUTES.recordset("selected"),
            ROUTES.recordset("guarded").replace(":snapshots",":supplySnapshots"));
    private static final String LEGACY_UPDATE=resource("update").formatted(ROUTES.recordset("selected"));
    private Connection connection;
    private JdbcTemplate db;
    private NamedParameterJdbcTemplate named;
    private UUID analysis,actor,goods;
    private List<MaterialAnalysisRouteBatchWriter.Change> changes;
    private final List<Statement> statements=new ArrayList<>();
    private record Statement(String sql,Map<String,Object> parameters) {}

    @BeforeEach void before()throws Exception {
        connection=java.sql.DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        connection.setAutoCommit(false);
        var source=new SingleConnectionDataSource(connection,true);db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        db.execute("CREATE SCHEMA route_test");db.execute("SET LOCAL search_path=route_test");
        db.execute("""
                CREATE TABLE goods(id uuid PRIMARY KEY,source_type varchar,is_deleted boolean DEFAULT false,version bigint DEFAULT 0,updated_at timestamptz,updated_by uuid);
                CREATE FUNCTION fn_goods_has_order_bom(uuid) RETURNS boolean LANGUAGE SQL AS 'SELECT false';
                CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY,analysis_id uuid NOT NULL,analysis_item_id uuid NOT NULL,
                    node_role varchar DEFAULT 'BOM_COMPONENT',active boolean DEFAULT true,confirmed_route varchar,source_suggestion varchar,
                    route_reason varchar,route_confirmed_by uuid,route_confirmed_at timestamptz,updated_at timestamptz,updated_by uuid);
                CREATE UNIQUE INDEX material_analysis ON production_material_analysis_materials(analysis_id,id);
                CREATE UNIQUE INDEX material_source ON production_material_analysis_materials(analysis_item_id,id);
                CREATE TABLE production_material_analysis_items(id uuid PRIMARY KEY,analysis_id uuid NOT NULL,is_deleted boolean DEFAULT false,parent_analysis_material_id uuid);
                CREATE UNIQUE INDEX source_parent ON production_material_analysis_items(parent_analysis_material_id) WHERE NOT is_deleted AND parent_analysis_material_id IS NOT NULL;
                CREATE UNIQUE INDEX source_analysis ON production_material_analysis_items(analysis_id,id);
                CREATE TABLE production_material_analysis_plan_links(analysis_id uuid NOT NULL,analysis_item_id uuid NOT NULL,
                    allocation_status varchar,submitted_qty numeric NOT NULL,public_surplus_qty numeric NOT NULL,plan_id uuid DEFAULT gen_random_uuid() UNIQUE);
                CREATE INDEX link_source ON production_material_analysis_plan_links(analysis_item_id,allocation_status,plan_id);
                CREATE TABLE preplan_supply_actions(id uuid PRIMARY KEY,analysis_id uuid NOT NULL,action_group_key varchar,route varchar,status varchar);
                CREATE INDEX action_group ON preplan_supply_actions(analysis_id,action_group_key);
                CREATE TABLE preplan_supply_action_allocations(analysis_id uuid NOT NULL,analysis_material_id uuid NOT NULL,action_id uuid NOT NULL);
                CREATE INDEX allocation_material ON preplan_supply_action_allocations(analysis_material_id,action_id);
                CREATE TABLE preplan_aggregate_batches(id uuid PRIMARY KEY,analysis_id uuid NOT NULL,action_id uuid NOT NULL,configuration_snapshot jsonb);
                CREATE INDEX batch_analysis ON preplan_aggregate_batches(analysis_id);
                CREATE TABLE preplan_aggregate_batch_events(batch_id uuid NOT NULL,event_type varchar,intent_snapshot jsonb);
                CREATE INDEX event_batch ON preplan_aggregate_batch_events(batch_id);
                CREATE TABLE row_audit(old_row jsonb,new_row jsonb);
                CREATE FUNCTION audit_material() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO row_audit VALUES(to_jsonb(OLD),to_jsonb(NEW));RETURN NEW;END $$;
                CREATE TRIGGER audit_material AFTER UPDATE ON production_material_analysis_materials FOR EACH ROW EXECUTE FUNCTION audit_material();
                """);
        analysis=UUID.randomUUID();actor=UUID.randomUUID();goods=UUID.randomUUID();
        db.update("INSERT INTO goods(id,source_type) VALUES(?,'采购')",goods);
    }
    @AfterEach void after()throws Exception {if(connection!=null){connection.rollback();connection.close();}}

    @Test void allFourSupplyProofsAndExpandedScopeMatchTheFrozenGuardBeforeAnyWrite()throws Exception {
        seed(4);
        var selected=List.of(changes.get(0));var guarded=changes.get(3);
        for(String kind:List.of("GROUP","ALLOCATION","INTENT","INTENT_FALLBACK","ROOT_PLAN","CHILD_PLAN")) {
            var savepoint=connection.setSavepoint();
            insertProof(kind,guarded,"MAKE","SUBMITTED",false,"0.0001");
            List<String> before=snapshot();
            for(boolean legacy:List.of(true,false)) {
                conflict(()->writer(legacy).apply(analysis,actor,selected,List.of(guarded)));
                assertEquals(before,snapshot(),kind+" must reject the entire batch before material or goods writes");
            }
            connection.rollback(savepoint);
        }
    }

    @Test void matchingCanceledUnissuedForeignAndDeletedFactsDoNotBecomeFalseConflicts()throws Exception {
        seed(4);var guarded=changes.get(3);
        for(String kind:List.of("GROUP","ALLOCATION","INTENT","INTENT_FALLBACK","ROOT_PLAN","CHILD_PLAN")) {
            for(String variant:List.of("MATCH","CANCELLED","ZERO","FOREIGN","DELETED")) {
                if((variant.equals("ZERO")||variant.equals("DELETED"))&&!kind.endsWith("PLAN"))continue;
                var checkpoint=connection.setSavepoint();
                insertProof(kind,guarded,variant.equals("MATCH")?"BUY":"MAKE",
                        variant.equals("CANCELLED")?"CANCELLED":"SUBMITTED",variant.equals("DELETED"),variant.equals("ZERO")?"0":"0.0001");
                if(variant.equals("FOREIGN")) {
                    db.update("UPDATE preplan_supply_actions SET analysis_id=?",UUID.randomUUID());
                    db.update("UPDATE preplan_aggregate_batches SET analysis_id=?",UUID.randomUUID());
                    db.update("UPDATE production_material_analysis_plan_links SET analysis_id=?",UUID.randomUUID());
                }
                if(variant.equals("MATCH")&&kind.endsWith("PLAN")) {connection.rollback(checkpoint);continue;}
                compareWriters(List.of(guarded),List.of(guarded));
                connection.rollback(checkpoint);
            }
        }
    }

    @Test void intentJsonPriorityAndInactiveAliasProofRemainAuthoritative()throws Exception {
        seed(4);var guarded=changes.get(3);var selected=List.of(changes.get(0));
        insertProof("INTENT_FALLBACK",guarded,"MAKE","OPEN",false,"0.0001");
        db.update("UPDATE production_material_analysis_materials SET active=false WHERE id=?",guarded.materialId());
        for(String event:List.of("{\"originalMaterialLineIds\":[\""+guarded.materialId()+"\"]}",
                "{\"originalMaterialLineIds\":{\""+guarded.materialId()+"\":true}}")) {
            db.update("UPDATE preplan_aggregate_batch_events SET intent_snapshot=CAST(? AS jsonb)",event);
            for(boolean legacy:List.of(true,false))conflict(()->writer(legacy).apply(analysis,actor,selected,List.of(guarded)));
        }
        db.update("UPDATE preplan_aggregate_batch_events SET intent_snapshot='{\"originalMaterialLineIds\":null}'::jsonb");
        compareWriters(selected,List.of(guarded));
        db.update("UPDATE preplan_aggregate_batch_events SET intent_snapshot='{}'::jsonb,event_type='CANCEL'");
        compareWriters(selected,List.of(guarded));
    }

    @Test void approvedOrdinaryRootAndAnchorUseIndividualPositiveLinksWithoutNetting()throws Exception {
        seed(4);var guarded=changes.get(3);
        for(String kind:List.of("ROOT_PLAN","CHILD_PLAN")) {
            var checkpoint=connection.setSavepoint();insertProof(kind,guarded,"MAKE","APPROVED",false,"0.0001");
            UUID source=db.queryForObject("SELECT analysis_item_id FROM production_material_analysis_materials WHERE id=?",UUID.class,guarded.materialId());
            // Negative input cannot offset a separate positive proof, even in imported legacy rows.
            db.update("INSERT INTO production_material_analysis_plan_links(analysis_id,analysis_item_id,allocation_status,submitted_qty,public_surplus_qty) VALUES(?,?,'APPROVED',-1,0)",analysis,source);
            for(boolean legacy:List.of(true,false))conflict(()->writer(legacy).apply(analysis,actor,List.of(changes.get(0)),List.of(guarded)));
            connection.rollback(checkpoint);
        }
    }

    @Test void ordinaryProofScopeQuantityAndMakeExceptionsMatchTheFrozenGuard()throws Exception {
        seed(4);var guarded=changes.get(3);var selected=List.of(changes.getFirst());
        for(String kind:List.of("ROOT_PLAN","CHILD_PLAN"))for(String variant:List.of("ZERO_SUM","SOURCE_FOREIGN","MATERIAL_FOREIGN","MAKE","DUPLICATE")) {
            var point=connection.setSavepoint();insertProof(kind,guarded,"MAKE","APPROVED",false,"0.0001");
            if(variant.equals("ZERO_SUM"))db.update("UPDATE production_material_analysis_plan_links SET submitted_qty=1,public_surplus_qty=-1");
            if(variant.equals("SOURCE_FOREIGN"))db.update("UPDATE production_material_analysis_items SET analysis_id=?",UUID.randomUUID());
            if(variant.equals("MATERIAL_FOREIGN"))db.update("UPDATE production_material_analysis_materials SET analysis_id=? WHERE id=?",UUID.randomUUID(),guarded.materialId());
            var target=variant.equals("MAKE")?new MaterialAnalysisRouteBatchWriter.Change(guarded.materialId(),guarded.groupKey(),goods,"MAKE",null):guarded;
            List<MaterialAnalysisRouteBatchWriter.Change> scope=List.of(target,target);
            if(variant.equals("DUPLICATE")) {
                List<String> before=snapshot();
                for(boolean legacy:List.of(true,false)) {conflict(()->writer(legacy).apply(analysis,actor,selected,scope));assertEquals(before,snapshot());}
            }else compareWriters(selected,scope);
            connection.rollback(point);
        }
    }

    @Test void activeNodeCountNoopAuditAndExactUpdateValuesMatchIndependentOracle()throws Exception {
        seed(6);compareWriters(changes,changes);
        var writer=writer(false);assertEquals(6,writer.applyAutomatic(analysis,actor,changes).materialsChanged());
        List<String> before=snapshot();assertEquals(0,writer.applyAutomatic(analysis,actor,changes).materialsChanged());
        assertEquals(before,snapshot());assertEquals(6,db.queryForObject("SELECT count(*) FROM row_audit",Integer.class));
        db.update("UPDATE production_material_analysis_materials SET active=false WHERE id=?",changes.get(2).materialId());
        before=snapshot();conflict(()->writer.applyAutomatic(analysis,actor,changes));assertEquals(before,snapshot());
        db.update("DELETE FROM production_material_analysis_materials WHERE id=?",changes.get(2).materialId());
        before=snapshot();conflict(()->writer.applyAutomatic(analysis,actor,changes));assertEquals(before,snapshot());
    }

    @Test void mixedGoodsRetainSuggestionAndManualNoopCanStillRepairMasterSource()throws Exception {
        seed(4);var first=changes.getFirst();var mixed=List.of(new MaterialAnalysisRouteBatchWriter.Change(
                first.materialId(),first.groupKey(),goods,"MAKE","保留采购主档建议"),changes.getLast());
        compareWriters(mixed,mixed);writer(false).applyAutomatic(analysis,actor,mixed);
        assertEquals("BUY",db.queryForObject("SELECT source_suggestion FROM production_material_analysis_materials WHERE id=?",String.class,first.materialId()));
        assertEquals("采购",db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,goods));
        var selected=List.of(changes.getLast());db.update("UPDATE goods SET source_type='自制' WHERE id=?",goods);
        compareWriters(selected,selected);
        assertEquals(new MaterialAnalysisRouteBatchWriter.Result(0,1),writer(false).apply(analysis,actor,selected,selected));
    }

    @Test void fullSizeRouteInputsHaveInspectablePlansAndEquivalentCompleteWrites()throws Exception {
        int count=Integer.getInteger("uten.route-batch.profile.rows",198);
        if(Boolean.getBoolean("uten.route-batch.profile.history")) {
            UUID foreign=UUID.randomUUID();
            named.update("""
                    INSERT INTO production_material_analysis_items(id,analysis_id)
                    SELECT md5('historical-source-'||i)::uuid,:foreign FROM generate_series(1,10000) i;
                    INSERT INTO production_material_analysis_plan_links(analysis_id,analysis_item_id,allocation_status,submitted_qty,public_surplus_qty)
                    SELECT :foreign,md5('historical-source-'||i)::uuid,'APPROVED',1,0 FROM generate_series(1,10000) i
                    """,Map.of("foreign",foreign));
            db.execute("ANALYZE production_material_analysis_items; ANALYZE production_material_analysis_plan_links");
        }
        seed(count);
        var capture=connection.setSavepoint();writer(false).applyAutomatic(analysis,actor,changes);connection.rollback(capture);
        Statement guard=statements.stream().filter(s->s.sql.contains("conflicts AS")).findFirst().orElseThrow();
        Statement update=statements.stream().filter(s->s.sql.contains("changed AS MATERIALIZED")).findFirst().orElseThrow();
        var results=new ArrayList<Map<String,Object>>();
        for(String phase:List.of("guard","update"))for(boolean legacy:List.of(true,false)) {
            Statement statement=phase.equals("guard")?guard:update;
            String sql=legacy?(phase.equals("guard")?LEGACY_GUARD:LEGACY_UPDATE):statement.sql;
            var point=connection.setSavepoint();
            String plan=named.queryForObject("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) "+sql,statement.parameters,String.class);
            results.add(Map.of("phase",phase,"variant",legacy?"legacy":"candidate","rows",count,"plan",new ObjectMapper().readTree(plan)));
            connection.rollback(point);
        }
        compareWriters(changes,changes);
        Path output=Path.of(System.getProperty("uten.build.directory","target"),"route-batch-plans-"+count+".json");
        Files.createDirectories(output.getParent());new ObjectMapper().writerWithDefaultPrettyPrinter().writeValue(output.toFile(),results);
    }

    private void compareWriters(List<MaterialAnalysisRouteBatchWriter.Change> selected,List<MaterialAnalysisRouteBatchWriter.Change> scope)throws Exception {
        var point=connection.setSavepoint();var expected=writer(true).apply(analysis,actor,selected,scope);List<String> rows=snapshot();
        connection.rollback(point);var actual=writer(false).apply(analysis,actor,selected,scope);
        assertEquals(expected,actual);assertEquals(rows,snapshot(),"Complete material, goods and row-audit snapshots match the old SQL");connection.rollback(point);
    }

    private void seed(int count) {
        named.update("""
                INSERT INTO production_material_analysis_items(id,analysis_id)
                SELECT md5('source-'||i)::uuid,:analysis FROM generate_series(1,(:count+98)/99) i;
                INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_role)
                SELECT md5('material-'||i)::uuid,:analysis,md5('source-'||((i-1)/99+1))::uuid,CASE WHEN i%99=1 THEN 'ROOT_SUPPLY' ELSE 'BOM_COMPONENT' END
                FROM generate_series(1,:count) i
                """,Map.of("analysis",analysis,"count",count));
        changes=db.query("SELECT id FROM production_material_analysis_materials ORDER BY id",(rs,index)->
                new MaterialAnalysisRouteBatchWriter.Change(rs.getObject(1,UUID.class),"group-"+index,goods,"BUY",index%2==0?null:"精确路线 \"采购\"\\\n"));
    }

    private void insertProof(String kind,MaterialAnalysisRouteBatchWriter.Change row,String route,String status,boolean deleted,String quantity)throws Exception {
        if(kind.endsWith("PLAN")) {
            UUID source=db.queryForObject("SELECT analysis_item_id FROM production_material_analysis_materials WHERE id=?",UUID.class,row.materialId());
            if(kind.equals("ROOT_PLAN"))db.update("UPDATE production_material_analysis_materials SET node_role='ROOT_SUPPLY' WHERE id=?",row.materialId());
            else db.update("UPDATE production_material_analysis_items SET parent_analysis_material_id=? WHERE id=?",row.materialId(),source);
            db.update("UPDATE production_material_analysis_items SET is_deleted=? WHERE id=?",deleted,source);
            db.update("INSERT INTO production_material_analysis_plan_links(analysis_id,analysis_item_id,allocation_status,submitted_qty,public_surplus_qty) VALUES(?,?,?,0,CAST(? AS numeric))",analysis,source,status,quantity);return;
        }
        UUID action=UUID.randomUUID();db.update("INSERT INTO preplan_supply_actions VALUES(?,?,?,?,?)",action,analysis,kind.equals("GROUP")?row.groupKey():"different",route,status);
        if(kind.equals("ALLOCATION"))db.update("INSERT INTO preplan_supply_action_allocations VALUES(?,?,?)",analysis,row.materialId(),action);
        if(kind.startsWith("INTENT")) {
            UUID batch=UUID.randomUUID();String intent=new ObjectMapper().writeValueAsString(Map.of("originalMaterialLineIds",List.of(row.materialId())));
            db.update("INSERT INTO preplan_aggregate_batches VALUES(?,?,?,CAST(? AS jsonb))",batch,analysis,action,kind.equals("INTENT_FALLBACK")?intent:"{}");
            db.update("INSERT INTO preplan_aggregate_batch_events VALUES(?,'APPEND',CAST(? AS jsonb))",batch,kind.equals("INTENT_FALLBACK")?"{}":intent);
        }
    }

    private List<String> snapshot() {
        List<String> result=new ArrayList<>();
        for(String table:List.of("production_material_analysis_materials","goods","row_audit"))
            result.addAll(db.queryForList("SELECT to_jsonb(row)::text FROM "+table+" row ORDER BY to_jsonb(row)::text",String.class));
        return result;
    }

    /** Only the persistence adapter is replaced; the real writer emits and executes every SQL statement. */
    private MaterialAnalysisRouteBatchWriter writer(boolean legacy) {
        EntityManager manager=(EntityManager)Proxy.newProxyInstance(EntityManager.class.getClassLoader(),new Class<?>[]{EntityManager.class},(proxy,method,args)->{
            if(!method.getName().equals("createNativeQuery"))throw new UnsupportedOperationException(method.getName());
            String supplied=(String)args[0];String sql=legacy&&supplied.contains("conflicts AS")?LEGACY_GUARD:
                    legacy&&supplied.contains("changed AS MATERIALIZED")?LEGACY_UPDATE:supplied;
            Map<String,Object> parameters=new LinkedHashMap<>();
            return Proxy.newProxyInstance(Query.class.getClassLoader(),new Class<?>[]{Query.class},(query,operation,values)->{
                if(operation.getName().equals("setParameter")){parameters.put((String)values[0],values[1]);return query;}
                statements.add(new Statement(sql,new LinkedHashMap<>(parameters)));
                if(operation.getName().equals("executeUpdate"))return named.update(sql,parameters);
                var rows=named.query(sql,parameters,(rs,index)->{
                    int columns=rs.getMetaData().getColumnCount();if(columns==1)return rs.getObject(1);
                    Object[] row=new Object[columns];for(int col=0;col<columns;col++)row[col]=rs.getObject(col+1);return row;
                });
                if(operation.getName().equals("getResultList"))return rows;
                if(operation.getName().equals("getSingleResult"))return rows.getFirst();
                throw new UnsupportedOperationException(operation.getName());
            });
        });
        return new MaterialAnalysisRouteBatchWriter(manager);
    }

    private static String resource(String kind) {
        try(var input=MaterialAnalysisRouteBatchWriterPostgresTest.class.getResourceAsStream("/sql/material-route-batch-legacy-"+kind+".sql")) {
            assertNotNull(input);return new String(input.readAllBytes(),StandardCharsets.UTF_8);
        }catch(java.io.IOException e){throw new IllegalStateException(e);}
    }

    private static void conflict(org.junit.jupiter.api.function.Executable command) {
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,command).getCode());
    }
}
