package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Savepoint;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.MountableFile;

import static org.junit.jupiter.api.Assertions.*;

/** Owned synthetic 95-row source image, normal 855->856 Flyway upgrade, no company writes. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class StockMeasurementHoldAuditPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("hold_audit_control");
    private static final String TEMPLATE="uten_imp", PASSWORD="hold-audit-fixture-"+UUID.randomUUID();
    private static final String FN="public.fn_audit_stock_measurement_hold_columns()";
    private static final String FACTORY="public.fn_audit_track_table(text,text,text,boolean,text[],boolean,text,text)";
    private static final UUID UNIT=UUID.randomUUID(), REVIEWER=UUID.randomUUID();
    private static final List<UUID> GOODS=new ArrayList<>();
    private static UUID warehouse;
    private String database;
    private Connection owner;
    private Connection runtime;
    private Map<String,String> beforeRows,beforeFunctions,beforeTriggers,beforeAcls;
    private String beforeRoles,beforeOldHistory;

    @BeforeAll static void retainedSource() throws Exception {
        PG.start();
        try(var admin=admin();var sql=admin.createStatement()) {
            try(var password=admin.prepareStatement("SELECT set_config('uten.fixture_role_password',?,false)")) {
                password.setString(1,PASSWORD);
                password.execute();
            }
            sql.execute("""
                    DO $fixture$
                    BEGIN
                      EXECUTE format('CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOINHERIT PASSWORD %L',
                                     current_setting('uten.fixture_role_password'));
                      EXECUTE format('CREATE ROLE uten LOGIN NOSUPERUSER NOINHERIT PASSWORD %L',
                                     current_setting('uten.fixture_role_password'));
                    END $fixture$;
                    """);
            sql.execute("CREATE DATABASE uten_imp OWNER uten_migrator TEMPLATE template0");
        }
        try(var admin=connect(TEMPLATE,PG.getUsername());var sql=admin.createStatement()) {
            sql.execute("GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator");
        }
        migrate(TEMPLATE,"927");
        try(var source=connect(TEMPLATE,"uten_migrator")) {
            source.setAutoCommit(false);
            exec(source,"SELECT set_config('app.legacy_import','on',true)");
            exec(source,"INSERT INTO units(id,code,name) VALUES('"+UNIT+"','HOLD-AUDIT-UNIT','Fixture original unit')");
            String root=scalar(source,"SELECT fn_warehouse_root_id()");
            if(root==null) {
                root=UUID.randomUUID().toString();
                exec(source,"INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES('"+root+"','001','Fixture root','使用',true)");
            }
            warehouse=UUID.randomUUID();
            exec(source,"INSERT INTO warehouses(id,code,name,status,is_accountable,parent_id) VALUES('"+warehouse+"','HOLD-AUDIT-W','Fixture warehouse','使用',true,'"+root+"')");
            for(int index=0;index<95;index++) {
                UUID goods=UUID.randomUUID();GOODS.add(goods);
                exec(source,"INSERT INTO goods(id,code,name,code_sequence,unit_id) VALUES('"+goods+"','HOLD-AUDIT-"+index
                        +"','Retained source "+index+"',(SELECT coalesce(max(code_sequence),0)+1 FROM goods),NULL)");
                BigDecimal amount=new BigDecimal(index+1).multiply(new BigDecimal("23.45"));
                exec(source,"INSERT INTO stock_balances(warehouse_id,goods_id,qty,amount_local,weight,weight_estimated) VALUES('"
                        +warehouse+"','"+goods+"',"+(index==0?"0":Integer.toString(index+1))+","+amount+","+(index==0?0:index+2)+",true)");
            }
            exec(source,"INSERT INTO users(id,employee_id,login_account,password_hash) SELECT '"+REVIEWER
                    +"',id,'hold-audit-reviewer-fixture','fixture-only' FROM employees WHERE code='ADMIN'");
            source.commit();
        }
        migrate(TEMPLATE,"929");
        try(var source=connect(TEMPLATE,"uten_migrator")) {
            assertEquals("95",scalar(source,"SELECT count(*) FROM stock_measurement_holds"));
            assertEquals("855",scalar(source,"SELECT count(*) FROM flyway_schema_history WHERE success"));
            exec(source,new ClassPathResource("db/local-runtime-privileges.sql").getContentAsString(StandardCharsets.UTF_8));
            exec(source,"INSERT INTO audit_log(actor_account,action,target_type,target_id,result,event_source,risk_level,event_category) "
                    +"VALUES('retained-fixture','update','goods','synthetic-pre-v930-sentinel','success','business','low','data_change')");
        }
        assertEquals(0,PG.execInContainer("mkdir","-p","/acl/server/ops","/acl/server/src/main/resources/db").getExitCode());
        PG.copyFileToContainer(MountableFile.forHostPath(Path.of("ops/reconcile-runtime-privileges.sql")),"/acl/server/ops/reconcile-runtime-privileges.sql");
        PG.copyFileToContainer(MountableFile.forHostPath(Path.of("src/main/resources/db/local-runtime-privileges.sql")),"/acl/server/src/main/resources/db/local-runtime-privileges.sql");
    }

    @AfterAll static void stop() { PG.stop(); }

    @BeforeEach void normalForwardUpgrade() throws Exception {
        database="hold_audit_candidate_"+UUID.randomUUID().toString().replace("-","");
        try(var admin=admin()) { exec(admin,"CREATE DATABASE "+ident(database)+" OWNER uten_migrator TEMPLATE uten_imp"); }
        owner=connect(database,"uten_migrator");
        exec(owner,"REVOKE ALL ON DATABASE "+ident(database)+" FROM PUBLIC,uten");
        exec(owner,"GRANT CONNECT ON DATABASE "+ident(database)+" TO uten");
        runtime=connect(database,"uten");
        assertEquals("uten/uten",scalar(runtime,"SELECT session_user||'/'||current_user"));
        exec(owner,"REVOKE CONNECT ON DATABASE "+ident(database)+" FROM uten");
        beforeRows=rows(owner);
        beforeFunctions=catalog(owner,"SELECT oid::text,proowner::text||':'||coalesce(proacl::text,'')||':'||pg_get_functiondef(oid) "
                +"FROM pg_proc WHERE pronamespace='public'::regnamespace AND prokind IN('f','p')");
        beforeTriggers=triggers(owner);
        beforeAcls=catalog(owner,"SELECT oid::text,relowner::text||':'||coalesce(relacl::text,'') FROM pg_class WHERE relnamespace='public'::regnamespace");
        beforeRoles=scalar(owner,"SELECT md5(string_agg(row_to_json(role)::text,'' ORDER BY oid)) FROM pg_roles role");
        beforeOldHistory=scalar(owner,"SELECT md5(string_agg(row_to_json(history)::text,'' ORDER BY installed_rank)) FROM flyway_schema_history history");
        assertEquals(1,migrate(database,"930"));
        owner.setAutoCommit(false);runtime.setAutoCommit(false);
    }

    @AfterEach void discard() throws Exception {
        if(runtime!=null)runtime.close();
        if(owner!=null)owner.close();
        if(database!=null)try(var admin=admin()) { exec(admin,"DROP DATABASE "+ident(database)+" WITH (FORCE)"); }
    }

    @Test void normalForwardAddsOnlyAuditMetadataAndNeverInventsReviewOfTheExisting95Holds() throws Exception {
        assertEquals("856",scalar(owner,"SELECT count(*) FROM flyway_schema_history WHERE success"));
        assertEquals("930",scalar(owner,"SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1"));
        assertEquals(beforeOldHistory,scalar(owner,"SELECT md5(string_agg(row_to_json(history)::text,'' ORDER BY installed_rank)) "
                +"FROM flyway_schema_history history WHERE version::int<=929"));
        assertEquals(beforeRows,rows(owner),"all existing business/user/audit rows, including quantities, amounts and the95 holds, stay byte-identical");
        Map<String,String> afterFunctions=catalog(owner,"SELECT oid::text,proowner::text||':'||coalesce(proacl::text,'')||':'||pg_get_functiondef(oid) "
                +"FROM pg_proc WHERE pronamespace='public'::regnamespace AND prokind IN('f','p')");
        beforeFunctions.forEach((key,value)->assertEquals(value,afterFunctions.get(key),"old function/owner/ACL "+key));
        Map<String,String> afterTriggers=triggers(owner);
        beforeTriggers.forEach((key,value)->assertEquals(value,afterTriggers.get(key),"old audit/quantity/immutable guard "+key));
        assertEquals(beforeAcls,catalog(owner,"SELECT oid::text,relowner::text||':'||coalesce(relacl::text,'') FROM pg_class WHERE relnamespace='public'::regnamespace"));
        assertEquals(beforeRoles,scalar(owner,"SELECT md5(string_agg(row_to_json(role)::text,'' ORDER BY oid)) FROM pg_roles role"));
        assertEquals("95",scalar(owner,"SELECT count(*) FROM stock_measurement_holds WHERE released_at IS NULL"));
        assertEquals("0",scalar(owner,"SELECT count(*) FROM audit_log WHERE target_type='stock_measurement_holds'"));
    }

    @Test void anActualNewRestoreCohortCaptureIsAuditedWithoutCopyingBookValuesOrInventingApproval() throws Exception {
        UUID goods=UUID.randomUUID();
        exec(owner,"SELECT set_config('app.legacy_import','on',true)");
        exec(owner,"INSERT INTO goods(id,code,name,code_sequence,unit_id) VALUES('"+goods+"','HOLD-AUDIT-NEW','New retained cohort',"
                +"(SELECT coalesce(max(code_sequence),0)+1 FROM goods),NULL)");
        // V928 explicitly permits restore-only copying in an offline owned candidate.
        // This is fixture ingestion, not migration code or a normal stock write bypass.
        exec(owner,"ALTER TABLE stock_balances DISABLE TRIGGER trg_stock_balance_measurement_operability");
        exec(owner,"INSERT INTO stock_balances(warehouse_id,goods_id,qty,amount_local,weight,weight_estimated) VALUES('"
                +warehouse+"','"+goods+"',7.25,123456.78,90.25,true)");
        exec(owner,"SET CONSTRAINTS ALL IMMEDIATE");
        exec(owner,"ALTER TABLE stock_balances ENABLE ALWAYS TRIGGER trg_stock_balance_measurement_operability");
        exec(owner,"SET CONSTRAINTS ALL DEFERRED");
        exec(owner,"SELECT set_config('app.legacy_import','off',true)");
        assertEquals("1",scalar(owner,"SELECT fn_capture_stock_measurement_holds()"));
        String id=scalar(owner,"SELECT id FROM stock_measurement_holds WHERE goods_id='"+goods+"'");
        assertEquals("1",auditCount(id));
        String payload=scalar(owner,"SELECT \"after\"::text FROM audit_log WHERE target_type='stock_measurement_holds' AND target_id='"+id+"'");
        assertSafe(payload);
        assertTrue(payload.contains("\"released_at\": null"));
        assertTrue(payload.contains("\"verified_by\": null"));
        assertEquals("insert",scalar(owner,"SELECT action FROM audit_log WHERE target_type='stock_measurement_holds' AND target_id='"+id+"'"));
        assertEquals("0",scalar(owner,"SELECT fn_capture_stock_measurement_holds()"));
        assertEquals("1",auditCount(id));
        assertEquals("A",scalar(owner,"SELECT tgenabled FROM pg_trigger WHERE tgrelid='stock_balances'::regclass AND tgname='trg_stock_balance_measurement_operability'"));
    }

    @Test void realResolutionAuditsSixFieldsAndNeverUsesTheReviewerParameterAsTheActor() throws Exception {
        UUID goods=GOODS.getFirst();completeOwnedFixtureMaster(goods);
        String hold=scalar(owner,"SELECT id FROM stock_measurement_holds WHERE goods_id='"+goods+"'");
        String before=scalar(owner,"SELECT to_jsonb(balance)::text FROM stock_balances balance WHERE goods_id='"+goods+"'");
        exec(owner,verification(hold,"private://13800138000/COST_SECRET","PRIVATE_RESOLUTION_NOTE"));
        assertEquals("1",auditCount(hold));
        String payload=scalar(owner,"SELECT \"after\"::text FROM audit_log WHERE target_type='stock_measurement_holds' AND target_id='"+hold+"'");
        assertSafe(payload);assertTrue(payload.contains("evidence_reference"));assertTrue(payload.contains("resolution_note"));
        assertTrue(payload.contains("_redacted_changes"));assertTrue(payload.contains("a".repeat(64)));
        assertEquals("t",scalar(owner,"SELECT actor_id IS NULL FROM audit_log WHERE target_type='stock_measurement_holds' AND target_id='"+hold+"'"));
        assertEquals(scalar(owner,"SELECT fn_audit_mask_account(session_user)"),scalar(owner,
                "SELECT actor_account FROM audit_log WHERE target_type='stock_measurement_holds' AND target_id='"+hold+"'"));
        assertEquals("data_change/low/database",scalar(owner,"SELECT event_category||'/'||risk_level||'/'||event_source "
                +"FROM audit_log WHERE target_type='stock_measurement_holds' AND target_id='"+hold+"'"));
        assertEquals(before,scalar(owner,"SELECT to_jsonb(balance)::text FROM stock_balances balance WHERE goods_id='"+goods+"'"));
        exec(owner,"UPDATE stock_measurement_holds SET released_at=released_at WHERE id='"+hold+"'");
        assertEquals("1",auditCount(hold));
        reject(owner,verification(hold,"private://repeat","This may not replace the verified evidence."),"23514");
        reject(owner,"UPDATE stock_measurement_holds SET captured_qty=captured_qty+1 WHERE id='"+hold+"'","23514");
        reject(owner,"DELETE FROM stock_measurement_holds WHERE id='"+hold+"'","23514");
        assertEquals("1",auditCount(hold));
    }

    @Test void explicitlyBoundContextKeepsItsActualActorAndMasksTheAccount() throws Exception {
        UUID goods=GOODS.get(1);completeOwnedFixtureMaster(goods);
        exec(owner,"SELECT set_config('app.actor_id','"+REVIEWER+"',true),set_config('app.actor_account','13800138000',true)");
        String hold=scalar(owner,"SELECT id FROM stock_measurement_holds WHERE goods_id='"+goods+"'");
        exec(owner,verification(hold,"private://bound-context","Real bound maintenance context, without copying this text."));
        assertEquals(REVIEWER.toString(),scalar(owner,"SELECT actor_id FROM audit_log WHERE target_type='stock_measurement_holds' AND target_id='"+hold+"'"));
        assertEquals("*******8000",scalar(owner,"SELECT actor_account FROM audit_log WHERE target_type='stock_measurement_holds' AND target_id='"+hold+"'"));
    }

    @Test void runtimeStillCannotMutateOrInvokeMaintenanceEvenAfterReconciliationAndThroughDefiners() throws Exception {
        assertPrivateFunctions();
        reapplyCanonical();
        assertEquals("uten/uten",scalar(runtime,"SELECT session_user||'/'||current_user"));
        assertEquals("f",scalar(owner,"SELECT has_database_privilege('uten',current_database(),'CONNECT')"));
        assertPrivateFunctions();
        for(String sql:List.of("UPDATE stock_measurement_holds SET released_at=now() WHERE false",
                "DELETE FROM stock_measurement_holds WHERE false","INSERT INTO stock_measurement_holds DEFAULT VALUES",
                "SELECT fn_capture_stock_measurement_holds()","SELECT fn_verify_stock_original_measurement_basis(NULL,NULL,NULL,NULL,NULL,NULL)")) {
            reject(runtime,sql,"42501");
        }
        exec(runtime,"SELECT count(*) FROM goods; SELECT count(*) FROM stock_measurement_holds; SELECT refresh_stock_monthly_mv()");
        String hold=scalar(owner,"SELECT id FROM stock_measurement_holds ORDER BY id LIMIT 1");
        exec(owner,"CREATE FUNCTION hold_audit_fixture_definer() RETURNS void SECURITY DEFINER LANGUAGE plpgsql AS $$ BEGIN PERFORM "
                +verification(hold,"private://forged","A runtime session is not a trusted reviewer.").replace("SELECT ","")+"; END $$");
        owner.commit();
        reject(runtime,"SELECT hold_audit_fixture_definer()","42501");
        assertEquals("0",scalar(owner,"SELECT count(*) FROM audit_log WHERE target_type='stock_measurement_holds'"));
    }

    @Test void newFactoryIsStrictRepeatableAndLeavesOldSevenArgumentCallsUnambiguous() throws Exception {
        exec(owner,registration());exec(owner,registration());
        assertEquals("2",scalar(owner,"SELECT count(*) FROM pg_trigger WHERE tgrelid='stock_measurement_holds'::regclass AND tgfoid='"+FN+"'::regprocedure"));
        Map<String,String> before=triggers(owner);
        reject(owner,registration().replace(FN,"public.fn_audit_route_columns()"),"22023");
        reject(owner,registration().replace("ARRAY['released_at','verified_unit_id','verified_by','evidence_reference','evidence_sha256','resolution_note']",
                "ARRAY['captured_qty']"),"22023");
        reject(owner,registration().replace("'resolution_note']","'resolution_note','captured_qty']"),"22023");
        assertEquals(before,triggers(owner));
        exec(owner,"CREATE TABLE hold_audit_scope_probe(id uuid PRIMARY KEY,decision text)");
        exec(owner,"SELECT fn_audit_track_table('hold_audit_scope_probe','COLUMN_SCOPED','data_change',false,ARRAY['decision'],false,NULL::text)");
        assertEquals("1",scalar(owner,"SELECT count(*) FROM pg_trigger WHERE tgrelid='hold_audit_scope_probe'::regclass AND tgfoid='public.fn_audit()'::regprocedure"));
    }

    @Test void factoryRejectsNewProjectionOwnerAndReturnTypeDriftWithoutChangingOldFunctions() throws Exception {
        Map<String,String> before=triggers(owner);
        String projection=scalar(owner,"SELECT oid::text||':'||proowner||':'||pg_get_functiondef(oid) FROM pg_proc WHERE oid='"+FN+"'::regprocedure");
        assertEquals("0",scalar(owner,"SELECT pronargdefaults FROM pg_proc WHERE oid='"+FACTORY+"'::regprocedure"));
        try(var maintenance=connect(database,PG.getUsername())) {
            maintenance.setAutoCommit(false);
            exec(maintenance,"ALTER FUNCTION "+FN+" OWNER TO "+ident(PG.getUsername()));
            reject(maintenance,registration(),"42501");
            maintenance.rollback();
        }
        assertEquals(projection,scalar(owner,"SELECT oid::text||':'||proowner||':'||pg_get_functiondef(oid) FROM pg_proc WHERE oid='"+FN+"'::regprocedure"));
        assertEquals(before,triggers(owner));
        Savepoint original=owner.setSavepoint();
        try {
            exec(owner,"DROP TRIGGER trg_audit_stock_measurement_holds ON stock_measurement_holds");
            exec(owner,"DROP TRIGGER trg_audit_upd_stock_measurement_holds ON stock_measurement_holds");
            exec(owner,"DROP FUNCTION "+FN);
            exec(owner,"CREATE FUNCTION "+FN+" RETURNS text LANGUAGE sql AS $$ SELECT 'wrong-type'::text $$");
            reject(owner,registration(),"42501");
        } finally { owner.rollback(original);owner.releaseSavepoint(original); }
        assertEquals(projection,scalar(owner,"SELECT oid::text||':'||proowner||':'||pg_get_functiondef(oid) FROM pg_proc WHERE oid='"+FN+"'::regprocedure"));
        assertEquals(before,triggers(owner));
    }

    private void assertPrivateFunctions() throws SQLException {
        for(String function:List.of(FN,FACTORY,"public.fn_capture_stock_measurement_holds()",
                "public.fn_verify_stock_original_measurement_basis(uuid,uuid,uuid,text,text,text)")) {
            assertEquals("f",scalar(runtime,"SELECT has_function_privilege(current_user,'"+function+"','EXECUTE')"),function);
        }
    }

    private void reapplyCanonical() throws Exception {
        List<String> command=new ArrayList<>(List.of("psql","-XqAt","-U","uten_migrator","-d",database,
                "-v","expected_database="+database,"-v","expected_database_oid="+scalar(owner,"SELECT oid FROM pg_database WHERE datname=current_database()"),
                "-v","expected_system_identifier="+scalar(owner,"SELECT system_identifier FROM pg_control_system()"),
                "-v","expected_owner=uten_migrator","-v","runtime_acl_confirm=RECONCILE CANDIDATE RUNTIME ACL "+database,
                "-f","/acl/server/ops/reconcile-runtime-privileges.sql"));
        var result=PG.execInContainer(command.toArray(String[]::new));
        assertEquals(0,result.getExitCode(),result.getStderr());assertFalse(result.getStderr().contains("WARNING"),result.getStderr());
    }

    private void completeOwnedFixtureMaster(UUID goods) throws Exception {
        // Only fixture setup simulates the already reviewed original basis. V675 is not changed by V930.
        String enabled=scalar(owner,"SELECT tgenabled FROM pg_trigger WHERE tgrelid='goods'::regclass AND tgname='trg_goods_quantity_unit_immutable'");
        exec(owner,"ALTER TABLE goods DISABLE TRIGGER trg_goods_quantity_unit_immutable");
        exec(owner,"UPDATE goods SET unit_id='"+UNIT+"' WHERE id='"+goods+"'");
        exec(owner,"ALTER TABLE goods "+("A".equals(enabled)?"ENABLE ALWAYS":"ENABLE")+" TRIGGER trg_goods_quantity_unit_immutable");
    }

    private String auditCount(String hold) throws SQLException { return scalar(owner,"SELECT count(*) FROM audit_log WHERE target_type='stock_measurement_holds' AND target_id='"+hold+"'"); }
    private static String verification(String hold,String reference,String note) {
        return "SELECT fn_verify_stock_original_measurement_basis('"+hold+"','"+UNIT+"','"+REVIEWER+"','"+reference+"','"+"a".repeat(64)+"','"+note+"')";
    }
    private static String registration() { return "SELECT fn_audit_track_table('stock_measurement_holds','COLUMN_SCOPED','data_change',false,"
            +"ARRAY['released_at','verified_unit_id','verified_by','evidence_reference','evidence_sha256','resolution_note'],true,'"+FN+"','"+FN+"')"; }
    private static void assertSafe(String payload) {
        for(String key:List.of("captured_qty","captured_amount_local","captured_weight","captured_weight_estimated","PRIVATE_RESOLUTION_NOTE","COST_SECRET","13800138000"))assertFalse(payload.contains(key),key);
    }
    private static Map<String,String> rows(Connection connection) throws Exception {
        Map<String,String> result=new LinkedHashMap<>();
        List<String> tables=new ArrayList<>();
        try(var sql=connection.createStatement();var rows=sql.executeQuery("SELECT relname FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind IN('r','p') AND relname<>'flyway_schema_history' ORDER BY relname")) {
            while(rows.next())tables.add(rows.getString(1));
        }
        for(String table:tables) {
            var digest=MessageDigest.getInstance("SHA-256");long count=0;
            try(var sql=connection.createStatement();var rows=sql.executeQuery("SELECT to_jsonb(row)::text FROM public."+ident(table)+" row ORDER BY to_jsonb(row)::text")) {
                while(rows.next()) { digest.update(rows.getString(1).getBytes(StandardCharsets.UTF_8));digest.update((byte)'\n');count++; }
            }
            result.put(table,count+":"+HexFormat.of().formatHex(digest.digest()));
        }
        return result;
    }
    private static Map<String,String> triggers(Connection connection) throws SQLException {
        return catalog(connection,"SELECT oid::text,tgenabled::text||':'||tgdeferrable::text||':'||tginitdeferred::text||':'||pg_get_triggerdef(oid) "
                +"FROM pg_trigger WHERE tgrelid IN(SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace)");
    }
    private static Map<String,String> catalog(Connection connection,String query) throws SQLException {
        Map<String,String> result=new LinkedHashMap<>();try(var sql=connection.createStatement();var rows=sql.executeQuery(query)) {
            while(rows.next())result.put(rows.getString(1),rows.getString(2));
        }return result;
    }
    private static void reject(Connection connection,String query,String state) throws SQLException {
        Savepoint savepoint=connection.setSavepoint();try {
            assertEquals(state,assertThrows(SQLException.class,()->exec(connection,query)).getSQLState());
        } finally {connection.rollback(savepoint);connection.releaseSavepoint(savepoint);}
    }
    private static void exec(Connection connection,String query) throws SQLException {try(var sql=connection.createStatement()){sql.execute(query);}}
    private static String scalar(Connection connection,String query) throws SQLException {try(var sql=connection.createStatement();var rows=sql.executeQuery(query)){assertTrue(rows.next());return rows.getString(1);}}
    private static int migrate(String database,String target) { return TestFlyway.configure().dataSource(url(database),"uten_migrator",PASSWORD).locations("classpath:db/migration").target(target).load().migrate().migrationsExecuted; }
    private static String ident(String value) {if(!value.matches("[a-z][a-z0-9_]*"))throw new IllegalArgumentException("Unexpected fixture identifier");return '"'+value+'"';}
    private static String url(String database) {return "jdbc:postgresql://"+PG.getHost()+":"+PG.getMappedPort(5432)+"/"+database;}
    private static Connection connect(String database,String user) throws SQLException {return DriverManager.getConnection(url(database),user,user.equals(PG.getUsername())?PG.getPassword():PASSWORD);}
    private static Connection admin() throws SQLException {return connect(PG.getDatabaseName(),PG.getUsername());}
}
