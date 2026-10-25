package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.SQLWarning;
import java.sql.Savepoint;
import java.sql.Statement;
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
import org.junit.jupiter.api.TestInfo;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.testcontainers.containers.Container;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.MountableFile;

import static org.junit.jupiter.api.Assertions.*;

/** Real PG16, the complete current migration catalog, and direct authenticated runtime sessions. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ScopedRuntimePrivilegesPostgresTest {
    private static final String OWNER="uten_migrator", APP="uten", TEMPLATE="uten_acl_template";
    private static final String OWNER_PASSWORD="acl-owner-"+UUID.randomUUID();
    private static final String APP_PASSWORD="acl-app-"+UUID.randomUUID();
    private static final PostgreSQLContainer POSTGRES=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("uten_acl_control");
    private static String policy;
    private String database;
    private Connection owner;
    private Connection runtime;

    @BeforeAll static void prepareFullTemplate() throws Exception {
        POSTGRES.start();
        policy=new ClassPathResource("db/local-runtime-privileges.sql").getContentAsString(StandardCharsets.UTF_8);
        assertEquals(Files.readString(Path.of("src/main/resources/db/local-runtime-privileges.sql")),policy);
        try(var admin=admin();var sql=admin.createStatement()) {
            sql.execute("CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOINHERIT PASSWORD '"+OWNER_PASSWORD+"'");
            sql.execute("CREATE ROLE uten LOGIN NOSUPERUSER NOINHERIT PASSWORD '"+APP_PASSWORD+"'");
            sql.execute("CREATE ROLE acl_observer NOLOGIN NOSUPERUSER NOINHERIT");
            sql.execute("CREATE DATABASE "+TEMPLATE+" OWNER uten_migrator TEMPLATE template0");
        }
        try(var admin=connect(TEMPLATE,POSTGRES.getUsername(),POSTGRES.getPassword());var sql=admin.createStatement()) {
            sql.execute("REVOKE EXECUTE ON FUNCTION pg_catalog.pg_control_system() FROM PUBLIC,uten");
            sql.execute("GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator");
        }
        var migrations=TestFlyway.configure().dataSource(url(TEMPLATE),OWNER,OWNER_PASSWORD)
                .locations("classpath:db/migration").defaultSchema("public").schemas("public")
                .cleanDisabled(true).load();
        assertEquals(MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT,migrations.migrate().migrationsExecuted);
        try(var migrationOwner=connect(TEMPLATE,OWNER,OWNER_PASSWORD)) {
            assertEquals(MigrationRehearsalSupport.CURRENT_HEAD_VERSION,scalar(migrationOwner,
                    "SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1"));
            assertEquals("pg_database_owner",scalar(migrationOwner,
                    "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='public'"));
        }
        assertEquals(0,POSTGRES.execInContainer("mkdir","-p","/acl/server/ops","/acl/server/src/main/resources/db").getExitCode());
        POSTGRES.copyFileToContainer(MountableFile.forHostPath(Path.of("ops/reconcile-runtime-privileges.sql")),
                "/acl/server/ops/reconcile-runtime-privileges.sql");
        POSTGRES.copyFileToContainer(MountableFile.forHostPath(Path.of("src/main/resources/db/local-runtime-privileges.sql")),
                "/acl/server/src/main/resources/db/local-runtime-privileges.sql");
    }

    @AfterAll static void stop() { POSTGRES.stop(); }

    @BeforeEach void isolatedCopy(TestInfo test) throws Exception {
        database=test.getTestMethod().orElseThrow().getName().startsWith("fixedDev")
                ?"uten_imp":"uten_acl_candidate_"+UUID.randomUUID().toString().replace("-","");
        try(var admin=admin();var sql=admin.createStatement()) {
            sql.execute("CREATE DATABASE "+identifier(database)+" OWNER uten_migrator TEMPLATE "+TEMPLATE);
        }
        owner=connect(database,OWNER,OWNER_PASSWORD);
        execute(owner,"REVOKE ALL ON DATABASE "+identifier(database)+" FROM PUBLIC,uten");
        execute(owner,"GRANT CONNECT ON DATABASE "+identifier(database)+" TO uten,uten_migrator");
        runtime=connect(database,APP,APP_PASSWORD);
        assertEquals("uten/uten",scalar(runtime,"SELECT session_user||'/'||current_user"));
        execute(owner,"REVOKE CONNECT ON DATABASE "+identifier(database)+" FROM uten");
        try(var unexpected=connect(database,APP,APP_PASSWORD)) {
            fail("A new runtime login must be refused after CONNECT is revoked: "+unexpected.isValid(1));
        } catch(SQLException denied) { assertEquals("42501",denied.getSQLState()); }
        runtime.setAutoCommit(false);
        execute(owner,"CREATE TABLE acl_business_probe(id bigserial PRIMARY KEY,value text)");
        execute(owner,"INSERT INTO acl_business_probe(value) VALUES('preserve existing fixture')");
        execute(owner,"GRANT SELECT ON goods TO acl_observer");
    }

    @AfterEach void discardOwnedCopy() throws Exception {
        if(runtime!=null)runtime.close();
        if(owner!=null)owner.close();
        if(database!=null)try(var admin=admin();var sql=admin.createStatement()) {
            sql.execute("DROP DATABASE "+identifier(database)+" WITH (FORCE)");
        }
    }

    @Test void fixedDevBoundaryAcceptsOnlyTheExistingDatabaseAndBothReviewedSchemaOwners() throws Exception {
        var before=facts(owner);
        executePolicy(owner);
        assertEquals(before,facts(owner));
        assertEquals("pg_database_owner",scalar(owner,"SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='public'"));
        execute(owner,"ALTER SCHEMA public OWNER TO uten_migrator");
        var explicitOwner=facts(owner);
        executePolicy(owner);
        assertEquals(explicitOwner,facts(owner));
        for(String privilege:List.of("SELECT","INSERT","UPDATE","DELETE")) {
            assertEquals("t",scalar(runtime,"SELECT has_table_privilege(current_user,'goods','"+privilege+"')"));
        }
    }

    @Test void pinnedWrapperGrantsRealBusinessUseWithoutChangingAnyBusinessRowsOrOwners() throws Exception {
        assertDenied(runtime,"SELECT count(*) FROM goods");
        Map<String,String> before=facts(owner);
        var result=wrapper(Map.of());
        assertEquals(0,result.getExitCode(),result.getStderr());
        assertFalse(result.getStderr().contains("WARNING"),result.getStderr());
        assertEquals(before,facts(owner));
        assertEquals("f",scalar(owner,"SELECT has_database_privilege('uten',current_database(),'CONNECT')"));
        try(var unexpected=connect(database,APP,APP_PASSWORD)) {
            fail("The wrapper must commit with new runtime login denied: "+unexpected.isValid(1));
        } catch(SQLException denied) { assertEquals("42501",denied.getSQLState()); }
        assertEquals("uten/uten",scalar(runtime,"SELECT session_user||'/'||current_user"));
        assertEquals("t",scalar(runtime,"SELECT has_table_privilege('acl_observer','goods','SELECT')"));

        UUID unit=UUID.randomUUID(),goods=UUID.randomUUID();
        execute(runtime,"INSERT INTO units(id,code,name) VALUES('"+unit+"','ACL-U-"+unit+"','ACL piece')");
        execute(runtime,"INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES('"+goods+"','ACL-G-"+goods
                +"','ACL native goods','"+unit+"',(SELECT coalesce(max(code_sequence),0)+1 FROM goods))");
        assertEquals("ACL native goods",scalar(runtime,"SELECT name FROM goods WHERE id='"+goods+"'"));
        execute(runtime,"UPDATE goods SET name='ACL updated goods' WHERE id='"+goods+"'");
        // Goods deletion is the normal retained soft-delete lifecycle, not physical evidence removal.
        execute(runtime,"UPDATE goods SET is_deleted=true WHERE id='"+goods+"'");
        assertEquals("t",scalar(runtime,"SELECT is_deleted FROM goods WHERE id='"+goods+"'"));
        execute(runtime,"INSERT INTO acl_business_probe(value) VALUES('native runtime insert')");
        execute(runtime,"UPDATE acl_business_probe SET value='native runtime update' WHERE value='native runtime insert'");
        execute(runtime,"DELETE FROM acl_business_probe WHERE value='native runtime update'");
        execute(runtime,"SELECT nextval('acl_business_probe_id_seq')");
        execute(runtime,"SELECT count(*) FROM legacy_finance_import_sources");
        execute(runtime,"SELECT count(*) FROM stock_measurement_holds");
        execute(runtime,"SELECT count(*) FROM v_stock_usable");
        execute(runtime,"SELECT refresh_stock_monthly_mv()");
        execute(runtime,"SELECT refresh_finance_ar_ap_mv()");
        execute(runtime,"INSERT INTO audit_log(actor_account,action,target_type,target_id,result,event_source,risk_level,event_category) "
                +"VALUES('runtime-acl-fixture','insert','acl_business_probe','fixture','success','business','low','data_change')");
        runtime.rollback();
        assertEquals(before,facts(owner));
    }

    @Test void proofHoldsHistoryMaintenanceAndDelegationRemainDeniedForTheRealRuntimeSession() throws Exception {
        execute(owner,"GRANT ALL ON goods,stock_measurement_holds,legacy_finance_import_sources TO PUBLIC");
        execute(owner,"GRANT UPDATE(captured_qty) ON stock_measurement_holds TO uten WITH GRANT OPTION");
        execute(owner,"GRANT ALL ON SEQUENCE acl_business_probe_id_seq TO uten WITH GRANT OPTION");
        execute(owner,"GRANT EXECUTE ON FUNCTION fn_capture_stock_measurement_holds() TO PUBLIC,uten");
        var before=facts(owner);
        var result=wrapper(Map.of());
        assertEquals(0,result.getExitCode(),result.getStderr());
        assertFalse(result.getStderr().contains("WARNING"),result.getStderr());
        assertEquals(before,facts(owner));
        execute(owner,"REVOKE CONNECT ON DATABASE "+identifier(database)+" FROM uten");
        for(String sql:List.of("SELECT * FROM flyway_schema_history", "DELETE FROM stock_measurement_holds WHERE false",
                "UPDATE stock_measurement_holds SET captured_qty=captured_qty WHERE false",
                "DELETE FROM legacy_finance_import_sources WHERE false", "UPDATE legacy_finance_import_sources SET id=id WHERE false",
                "UPDATE audit_log SET action=action WHERE false", "DELETE FROM audit_log WHERE false",
                "SELECT fn_capture_stock_measurement_holds()", "SELECT fn_verify_stock_original_measurement_basis(NULL,NULL,NULL,NULL,NULL,NULL)",
                "SELECT fn_require_runtime_refresh()", "CREATE TABLE public.acl_forbidden(id int)",
                "CREATE SCHEMA acl_forbidden", "TRUNCATE goods", "SELECT setval('acl_business_probe_id_seq',100)",
                "SELECT last_value FROM acl_business_probe_id_seq", "SET ROLE uten_migrator")) {
            assertDenied(runtime,sql);
        }
        assertEquals("f",scalar(runtime,"SELECT has_table_privilege(current_user,'goods','SELECT WITH GRANT OPTION')"));
        String beforeDelegation=aclFingerprint(runtime);
        Savepoint delegation=runtime.setSavepoint();
        try {
            // PostgreSQL can reject an unauthorized GRANT with a no-op warning,
            // rather than an error. The effective/catalog result must stay unchanged.
            try { execute(runtime,"GRANT SELECT ON goods TO PUBLIC"); }
            catch(SQLException denied) { assertEquals("42501",denied.getSQLState());runtime.rollback(delegation); }
            assertEquals(beforeDelegation,aclFingerprint(runtime));
        } finally { runtime.rollback(delegation);runtime.releaseSavepoint(delegation); }
        assertEquals("f",scalar(runtime,"SELECT has_function_privilege(current_user,'fn_capture_stock_measurement_holds()','EXECUTE')"));
        assertEquals("f",scalar(runtime,"SELECT has_table_privilege(current_user,'stock_measurement_holds','INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER')"));
        assertEquals("t",scalar(runtime,"SELECT has_table_privilege(current_user,'procurement_order_termination_sources','INSERT')"));
        assertEquals("t",scalar(runtime,"SELECT has_table_privilege(current_user,'stock_movements','INSERT')"));
        runtime.rollback();
        assertEquals(before,facts(owner));
    }

    @Test void wrongIndependentPinsAndUnboundNonstandardInvocationFailBeforeAnyAclChange() throws Exception {
        String before=aclFingerprint(owner);
        for(var wrong:List.of(Map.of("expected_database","uten_wrong_candidate"),Map.of("expected_database_oid","1"),
                Map.of("expected_system_identifier","1"),Map.of("expected_owner","postgres"),
                Map.of("runtime_acl_confirm","not approved"))) {
            var result=wrapper(wrong);
            assertNotEquals(0,result.getExitCode());
            assertFalse(result.getStderr().contains("WARNING"),result.getStderr());
            assertEquals(before,aclFingerprint(owner));
        }
        assertThrows(SQLException.class,()->executePolicy(owner));
        assertEquals(before,aclFingerprint(owner));
        assertDenied(runtime,"SELECT count(*) FROM goods");
    }

    @Test void unrelatedSchemaOwnerOrDatabaseOwnerCannotEnterThroughDatabaseOwnerAlias() throws Exception {
        try(var admin=connect(database,POSTGRES.getUsername(),POSTGRES.getPassword())) {
            execute(admin,"ALTER SCHEMA public OWNER TO "+identifier(POSTGRES.getUsername()));
            String before=aclFingerprint(owner);
            assertNotEquals(0,wrapper(Map.of()).getExitCode());
            assertEquals(before,aclFingerprint(owner));
            execute(admin,"ALTER SCHEMA public OWNER TO pg_database_owner");
            execute(admin,"ALTER DATABASE "+identifier(database)+" OWNER TO "+identifier(POSTGRES.getUsername()));
            before=aclFingerprint(owner);
            assertNotEquals(0,wrapper(Map.of()).getExitCode());
            assertEquals(before,aclFingerprint(owner));
        }
    }

    @Test void repeatReconciliationAndFutureDefaultsKeepTheSameRestrictedRuntimeProfile() throws Exception {
        assertEquals(0,wrapper(Map.of()).getExitCode());
        var before=facts(owner);
        assertEquals(0,wrapper(Map.of()).getExitCode());
        assertEquals(before,facts(owner));
        execute(owner,"REVOKE CONNECT ON DATABASE "+identifier(database)+" FROM uten");
        execute(owner,"CREATE TABLE acl_later(id bigserial PRIMARY KEY,value text)");
        execute(runtime,"INSERT INTO acl_later(value) VALUES('serial default works')");
        assertDenied(runtime,"TRUNCATE acl_later");
        assertDenied(runtime,"SELECT setval('acl_later_id_seq',1)");
        runtime.rollback();
    }

    private Container.ExecResult wrapper(Map<String,String> changes) throws Exception {
        Map<String,String> pins=new LinkedHashMap<>();
        pins.put("expected_database",database);
        pins.put("expected_database_oid",scalar(owner,"SELECT oid FROM pg_database WHERE datname=current_database()"));
        pins.put("expected_system_identifier",scalar(owner,"SELECT system_identifier FROM pg_control_system()"));
        pins.put("expected_owner",OWNER);
        pins.put("runtime_acl_confirm","RECONCILE CANDIDATE RUNTIME ACL "+database);
        pins.putAll(changes);
        List<String> command=new ArrayList<>(List.of("psql","-XqAt","-U",OWNER,"-d",database));
        pins.forEach((key,value)->command.addAll(List.of("-v",key+"="+value)));
        command.addAll(List.of("-f","/acl/server/ops/reconcile-runtime-privileges.sql"));
        return POSTGRES.execInContainer(command.toArray(String[]::new));
    }

    private static Map<String,String> facts(Connection connection) throws Exception {
        Map<String,String> result=new LinkedHashMap<>();
        List<String> tables=new ArrayList<>();
        try(var statement=connection.createStatement();var rows=statement.executeQuery("SELECT relname FROM pg_class c "
                +"JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN('r','p') ORDER BY relname")) {
            while(rows.next())tables.add(rows.getString(1));
        }
        for(String table:tables) {
            MessageDigest digest=MessageDigest.getInstance("SHA-256");
            long count=0;
            try(var statement=connection.createStatement();var rows=statement.executeQuery(
                    "SELECT to_jsonb(row)::text FROM public."+identifier(table)+" row ORDER BY to_jsonb(row)::text")) {
                while(rows.next()) { digest.update(rows.getString(1).getBytes(StandardCharsets.UTF_8));digest.update((byte)'\n');count++; }
            }
            result.put(table,count+":"+HexFormat.of().formatHex(digest.digest()));
        }
        result.put("@definitions",scalar(connection,"SELECT md5(string_agg(oid::text||':'||proowner::text||':'||pg_get_functiondef(oid),'' ORDER BY oid)) "
                +"FROM pg_proc WHERE pronamespace='public'::regnamespace AND prokind IN('f','p')"));
        result.put("@owners",scalar(connection,"SELECT md5(string_agg(oid::text||':'||relowner::text,'' ORDER BY oid)) FROM pg_class WHERE relnamespace='public'::regnamespace"));
        result.put("@schemaOwner",scalar(connection,"SELECT nspowner FROM pg_namespace WHERE nspname='public'"));
        result.put("@databaseOwner",scalar(connection,"SELECT datdba FROM pg_database WHERE datname=current_database()"));
        result.put("@roles",scalar(connection,"SELECT md5(string_agg(row_to_json(role)::text,'' ORDER BY oid)) FROM pg_roles role"));
        result.put("@memberships",scalar(connection,"SELECT coalesce(md5(string_agg(row_to_json(membership)::text,'' ORDER BY roleid,member,grantor)),md5('')) FROM pg_auth_members membership"));
        result.put("@controlFunctionAcl",scalar(connection,"SELECT coalesce(proacl::text,'default') FROM pg_proc WHERE oid='pg_catalog.pg_control_system()'::regprocedure"));
        return result;
    }

    private static String aclFingerprint(Connection connection) throws SQLException {
        return scalar(connection,"SELECT md5(string_agg(kind||value,'' ORDER BY kind,value)) FROM ("
                +"SELECT 'r' kind,oid::text||coalesce(relacl::text,'') value FROM pg_class WHERE relnamespace='public'::regnamespace "
                +"UNION ALL SELECT 'c',attrelid::text||':'||attnum::text||coalesce(attacl::text,'') FROM pg_attribute WHERE attrelid IN(SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace) "
                +"UNION ALL SELECT 'f',oid::text||coalesce(proacl::text,'') FROM pg_proc WHERE pronamespace='public'::regnamespace "
                +"UNION ALL SELECT 'd',oid::text||coalesce(defaclacl::text,'') FROM pg_default_acl "
                +"UNION ALL SELECT 'b',oid::text||coalesce(datacl::text,'') FROM pg_database WHERE datname=current_database()) inventory");
    }

    private static void executePolicy(Connection connection) throws SQLException {
        try(var statement=connection.createStatement()) {
            statement.execute(policy);
            for(SQLWarning warning=statement.getWarnings();warning!=null;warning=warning.getNextWarning()) {
                fail("Canonical ACL must not produce grant-authority warnings: "+warning.getMessage());
            }
        }
    }
    private static void assertDenied(Connection connection,String sql) throws SQLException {
        Savepoint savepoint=connection.setSavepoint();
        try { assertEquals("42501",assertThrows(SQLException.class,()->execute(connection,sql),sql).getSQLState(),sql); }
        finally { connection.rollback(savepoint);connection.releaseSavepoint(savepoint); }
    }
    private static void execute(Connection connection,String sql) throws SQLException {
        try(var statement=connection.createStatement()) { statement.execute(sql); }
    }
    private static String scalar(Connection connection,String sql) throws SQLException {
        try(var statement=connection.createStatement();var rows=statement.executeQuery(sql)) {
            assertTrue(rows.next());return rows.getString(1);
        }
    }
    private static String identifier(String value) {
        if(!value.matches("[a-z][a-z0-9_]*"))throw new IllegalArgumentException("Unexpected fixture/catalog identifier");
        return '"'+value+'"';
    }
    private static String url(String database) { return "jdbc:postgresql://"+POSTGRES.getHost()+":"+POSTGRES.getMappedPort(5432)+"/"+database; }
    private static Connection connect(String database,String user,String password) throws SQLException {
        return DriverManager.getConnection(url(database),user,password);
    }
    private static Connection admin() throws SQLException {
        return connect(POSTGRES.getDatabaseName(),POSTGRES.getUsername(),POSTGRES.getPassword());
    }
}
