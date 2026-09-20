package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real, separate non-superuser logins. No runtime owner/migrator membership. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class RuntimeMaintenancePrivilegePostgresTest {
    static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("runtime_maintenance").withUsername("fixture_admin");
    static final String PASSWORD=UUID.randomUUID().toString();
    static final List<String> VIEWS=List.of("finance_ar_ap_mv","production_monthly_mv","purchase_monthly_mv",
            "sales_monthly_mv","stock_monthly_mv","subcontract_monthly_mv");
    static JdbcTemplate owner,app,outsider;
    static UUID actor,ordinary;
    static String originalResetBody;
    static String ownerDatabaseUrl;

    @BeforeAll static void prepare() {
        PG.start();
        var admin=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        for(String name:List.of("uten_migrator","uten","maintenance_outsider"))
            admin.execute("CREATE ROLE "+name+" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD '"+PASSWORD+"'");
        admin.execute("ALTER DATABASE runtime_maintenance OWNER TO uten_migrator; ALTER SCHEMA public OWNER TO uten_migrator;"
                +" REVOKE ALL ON DATABASE runtime_maintenance FROM PUBLIC; REVOKE ALL ON SCHEMA public FROM PUBLIC;"
                +" GRANT CONNECT ON DATABASE runtime_maintenance TO uten,maintenance_outsider;"
                +" GRANT USAGE ON SCHEMA public TO uten,maintenance_outsider");
        owner=db("uten_migrator");app=db("uten");outsider=db("maintenance_outsider");
        var base=Flyway.configure().dataSource(PG.getJdbcUrl(),"uten_migrator",PASSWORD)
                .locations("classpath:db/migration").target("624").load();
        base.migrate();
        originalResetBody=owner.queryForObject("SELECT prosrc FROM pg_catalog.pg_proc WHERE oid='public.business_data_reset()'::regprocedure",String.class).replace("\r\n","\n");
        // Freeze a real V624 source for the supported hardener layout: old
        // objects belong to a NOLOGIN owner, the next migrator login does not
        // SET ROLE and therefore owns only its newly introduced helper.
        admin.execute("CREATE ROLE uten_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE; ALTER ROLE uten_migrator INHERIT; GRANT uten_owner TO uten_migrator");
        String controlUrl=PG.getJdbcUrl().replace("/runtime_maintenance?","/postgres?");
        new JdbcTemplate(new DriverManagerDataSource(controlUrl,PG.getUsername(),PG.getPassword()))
                .execute("CREATE DATABASE runtime_maintenance_owner TEMPLATE runtime_maintenance OWNER uten_owner");
        ownerDatabaseUrl=PG.getJdbcUrl().replace("/runtime_maintenance?","/runtime_maintenance_owner?");
        // The shipped hardener performs this ownership transfer as postgres;
        // migration and every exercised runtime call below remain non-super.
        new JdbcTemplate(new DriverManagerDataSource(ownerDatabaseUrl,PG.getUsername(),PG.getPassword()))
                .execute("REASSIGN OWNED BY uten_migrator TO uten_owner");
        assertEquals(1,Flyway.configure().dataSource(PG.getJdbcUrl(),"uten_migrator",PASSWORD)
                .locations("classpath:db/migration").target("625").load().migrate().migrationsExecuted);
        owner.execute("""
            GRANT SELECT,INSERT,UPDATE ON public.system_settings,public.report_materialized_view_refresh_state TO uten;
            GRANT SELECT,INSERT ON public.audit_log TO uten;
            GRANT USAGE ON SEQUENCE public.audit_log_id_seq TO uten;
            INSERT INTO departments(code,name,level) VALUES('V625','维护验证','一级部门');
            INSERT INTO employees(code,full_name,id_type,department_id,hire_date,status,employment_type)
              SELECT 'T0625','维护管理员','其他',id,current_date,'active','regular' FROM departments WHERE code='V625';
            INSERT INTO employees(code,full_name,id_type,department_id,hire_date,status,employment_type)
              SELECT 'T0626','普通测试员','其他',id,current_date,'active','regular' FROM departments WHERE code='V625';
            INSERT INTO users(employee_id,login_account,password_hash,must_change_password,status,is_super_admin)
              SELECT id,'maintenance-admin','synthetic-only',false,'active',true FROM employees WHERE code='T0625';
            INSERT INTO users(employee_id,login_account,password_hash,must_change_password,status,is_super_admin)
              SELECT id,'maintenance-ordinary','synthetic-only',false,'active',false FROM employees WHERE code='T0626';
            """);
        actor=owner.queryForObject("SELECT id FROM users WHERE login_account='maintenance-admin'",UUID.class);
        ordinary=owner.queryForObject("SELECT id FROM users WHERE login_account='maintenance-ordinary'",UUID.class);
    }
    @AfterAll static void stop(){PG.stop();}

    @Test void resetBodyRemainsExactAndOnlyTheSevenFixedEntriesAreElevated() {
        String body=owner.queryForObject("SELECT prosrc FROM pg_catalog.pg_proc WHERE oid='public.business_data_reset()'::regprocedure",String.class);
        assertEquals(originalResetBody,body.replace("    PERFORM public.fn_require_runtime_maintenance(true);\n",""));
        var names=owner.queryForList("SELECT proname FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND prosecdef ORDER BY proname",String.class);
        var expected=new java.util.ArrayList<>(VIEWS.stream().map(v->"refresh_"+v).toList());expected.add("business_data_reset");expected.sort(String::compareTo);
        assertEquals(expected,names);
        assertEquals(7,owner.queryForObject("SELECT count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND prosecdef AND 'search_path=pg_catalog, public, pg_temp'=ANY(proconfig)",Integer.class));
    }

    @Test void ordinaryDmlAndAuditWorkWithoutAnyPersistentDdlOrOwnerMembership() {
        assertEquals("false|false|false|false",app.queryForObject("SELECT rolsuper::text||'|'||rolcreatedb::text||'|'||rolcreaterole::text||'|'||pg_has_role(current_user,'uten_migrator','MEMBER')::text FROM pg_catalog.pg_roles WHERE rolname=current_user",String.class));
        assertFalse(app.queryForObject("SELECT has_schema_privilege(current_user,'public','CREATE')",Boolean.class));
        assertFalse(app.queryForObject("SELECT has_database_privilege(current_user,current_database(),'CREATE')",Boolean.class));
        assertEquals(0,app.queryForObject("SELECT count(*) FROM pg_catalog.pg_class WHERE relnamespace='public'::regnamespace AND relowner=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user)",Integer.class));
        String key="v625-"+UUID.randomUUID();
        app.update("INSERT INTO system_settings(key,value,value_type,category,label) VALUES(?,'one','string','business','maintenance fixture')",key);
        assertEquals(1,app.update("UPDATE system_settings SET value='two' WHERE key=?",key));
        assertTrue(owner.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='system_settings' AND target_id=?",Integer.class,key)>=2);
        assertThrows(org.springframework.dao.DataAccessException.class,()->app.execute("CREATE TABLE public.runtime_ddl_should_fail(id int)"));
        assertThrows(org.springframework.dao.DataAccessException.class,()->app.execute("ALTER TABLE public.system_settings ADD COLUMN runtime_alter_should_fail int"));
        assertThrows(org.springframework.dao.DataAccessException.class,()->app.execute("SET ROLE uten_migrator"));
    }

    @Test void retainedOwnerEntriesCanInvokeTheNewMigratorOwnedPrivateHelper() throws Exception {
        var db=new JdbcTemplate(new DriverManagerDataSource(ownerDatabaseUrl,"uten_migrator",PASSWORD));
        assertEquals("uten_owner",db.queryForObject("SELECT proowner::regrole::text FROM pg_catalog.pg_proc WHERE oid='public.business_data_reset()'::regprocedure",String.class));
        assertEquals(1,Flyway.configure().dataSource(ownerDatabaseUrl,"uten_migrator",PASSWORD)
                .locations("classpath:db/migration").target("625").load().migrate().migrationsExecuted);
        assertEquals("uten_migrator",db.queryForObject("SELECT proowner::regrole::text FROM pg_catalog.pg_proc WHERE oid='public.fn_require_runtime_maintenance(boolean)'::regprocedure",String.class));
        assertFalse(db.queryForObject("SELECT pg_has_role('uten_owner','uten_migrator','MEMBER')",Boolean.class));
        assertTrue(db.queryForObject("SELECT has_function_privilege('uten_owner','public.fn_require_runtime_maintenance(boolean)','EXECUTE')",Boolean.class));
        assertFalse(db.queryForObject("SELECT has_function_privilege('uten','public.fn_require_runtime_maintenance(boolean)','EXECUTE')",Boolean.class));
        db.execute("""
            INSERT INTO departments(code,name,level) VALUES('V625','维护验证','一级部门');
            INSERT INTO employees(code,full_name,id_type,department_id,hire_date,status,employment_type)
              SELECT 'T0625','维护管理员','其他',id,current_date,'active','regular' FROM departments WHERE code='V625';
            INSERT INTO users(employee_id,login_account,password_hash,must_change_password,status,is_super_admin)
              SELECT id,'maintenance-admin','synthetic-only',false,'active',true FROM employees WHERE code='T0625';
            """);
        UUID user=db.queryForObject("SELECT id FROM users WHERE login_account='maintenance-admin'",UUID.class);
        try(var connection=DriverManager.getConnection(ownerDatabaseUrl,"uten",PASSWORD)) {
            connection.setAutoCommit(false);
            try(var tx=new Tx(connection)) {
                assertFalse(tx.db.queryForObject("SELECT pg_has_role(current_user,'uten_owner','MEMBER') OR pg_has_role(current_user,'uten_migrator','MEMBER')",Boolean.class));
                for(String view:VIEWS)tx.db.execute("SELECT public.refresh_"+view+"()");
                bind(tx.db,user,"maintenance-admin");
                assertTrue(((Number)tx.db.queryForMap("SELECT * FROM public.business_data_reset()").get("cleared_table_count")).intValue()>0);
                assertEquals("uten",tx.db.queryForObject("SELECT current_user",String.class));
            }
        }
    }

    @Test void allSixConcurrentRefreshFunctionsWorkThroughTheActualSchedulerOnPostgres16() {
        for(String view:VIEWS) {
            assertThrows(org.springframework.dao.DataAccessException.class,()->app.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY public."+view));
            assertThrows(org.springframework.dao.DataAccessException.class,()->outsider.execute("SELECT public.refresh_"+view+"()"));
        }
        new com.uten.imp.features.reporting.MaterializedViewRefreshScheduler(
                new DriverManagerDataSource(PG.getJdbcUrl(),"uten",PASSWORD)).refreshAll();
        assertEquals(6,owner.queryForObject("SELECT count(*) FROM report_materialized_view_refresh_state WHERE status='SUCCESS' AND last_succeeded_at IS NOT NULL",Integer.class));
        assertThrows(org.springframework.dao.DataAccessException.class,()->app.execute("SELECT public.refresh_stock_monthly_mv('system_settings')"));
        assertEquals("uten",app.queryForObject("SELECT current_user",String.class));
        assertThrows(org.springframework.dao.DataAccessException.class,()->app.execute("SELECT public.fn_require_runtime_maintenance(false)"));
    }

    @Test void unknownOrdinaryDisabledOrMismatchedActorsCannotInvokeElevatedReset() throws Exception {
        assertThrows(org.springframework.dao.DataAccessException.class,()->outsider.queryForList("SELECT * FROM public.business_data_reset()"));
        try(var tx=connection("uten")) {
            assertResetDenied(tx);
            bind(tx.db,UUID.randomUUID(),"maintenance-admin");assertResetDenied(tx);
            bind(tx.db,ordinary,"maintenance-ordinary");assertResetDenied(tx);
            bind(tx.db,actor,"wrong-account");assertResetDenied(tx);
            bind(tx.db,actor,"maintenance-admin");
            tx.db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,"a".repeat(36));assertResetDenied(tx);
            bind(tx.db,actor,"maintenance-admin");
            tx.db.queryForObject("SELECT set_config('app.audit_request_id','not-an-id',true)",String.class);assertResetDenied(tx);
            bind(tx.db,actor,"maintenance-admin");
            owner.update("UPDATE users SET status='disabled' WHERE id=?",actor);
            try {assertResetDenied(tx);} finally {owner.update("UPDATE users SET status='active' WHERE id=?",actor);}
        }
    }

    @Test void temporaryCatalogAndUserShadowsCannotForgeResetAuthorityOrRetargetMaintenance() throws Exception {
        owner.execute("GRANT TEMPORARY ON DATABASE runtime_maintenance TO uten");
        try(var tx=connection("uten")) {
            tx.db.execute("CREATE TEMP TABLE users(id uuid,login_account text,is_super_admin boolean,status text,is_deleted boolean)");
            tx.db.update("INSERT INTO users VALUES(?,'maintenance-ordinary',true,'active',false)",ordinary);
            tx.db.execute("CREATE TEMP TABLE pg_roles(rolname name,rolsuper boolean); INSERT INTO pg_roles VALUES('uten',true)");
            bind(tx.db,ordinary,"maintenance-ordinary");assertResetDenied(tx);
            tx.db.execute("CREATE TEMP TABLE stock_monthly_mv(marker text); INSERT INTO stock_monthly_mv VALUES('keep-shadow')");
            tx.db.execute("SELECT public.refresh_stock_monthly_mv()");
            assertEquals("keep-shadow",tx.db.queryForObject("SELECT marker FROM pg_temp.stock_monthly_mv",String.class));
            bind(tx.db,actor,"maintenance-admin");
            tx.db.execute("CREATE TEMP TABLE reset_business_table_policy(marker text); INSERT INTO reset_business_table_policy VALUES('keep-policy')");
            assertResetDenied(tx);
            assertEquals("keep-policy",tx.db.queryForObject("SELECT marker FROM pg_temp.reset_business_table_policy",String.class));
        } finally {owner.execute("REVOKE TEMPORARY ON DATABASE runtime_maintenance FROM uten");}
    }

    @Test void persistentInternalNameIsRejectedWithoutDroppingItOrClearingBusinessRows() throws Exception {
        owner.execute("CREATE TABLE public.reset_business_table_policy(marker text); INSERT INTO public.reset_business_table_policy VALUES('keep-public')");
        try(var tx=connection("uten")) {
            bind(tx.db,actor,"maintenance-admin");assertResetDenied(tx);
            assertEquals("keep-public",owner.queryForObject("SELECT marker FROM public.reset_business_table_policy",String.class));
        } finally {owner.execute("DROP TABLE public.reset_business_table_policy");}
    }

    @Test void authorizedRuntimeResetRetainsBusinessGuardsAndInvalidatesSessionsAtomically() throws Exception {
        UUID event=UUID.randomUUID();
        owner.update("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status) VALUES(?,'V625','FIXTURE',?,0)",event,event.toString());
        long before=owner.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1",Long.class);
        long users=owner.queryForObject("SELECT count(*) FROM users",Long.class);
        try(var tx=connection("uten")) {
            bind(tx.db,actor,"maintenance-admin");
            var save=tx.connection.setSavepoint();
            var failure=assertThrows(org.springframework.dao.DataAccessException.class,()->tx.db.queryForList("SELECT * FROM public.business_data_reset()"));
            assertTrue(failure.getMessage().contains("待处理或失败事件"),"The original outbox guard must still run: "+failure.getMessage());
            tx.connection.rollback(save);
        }
        owner.update("UPDATE business_outbox SET status=1 WHERE id=?",event);
        owner.update("INSERT INTO refresh_tokens(user_id,session_id,token_hash,expires_at) VALUES(?,?,?,now()+interval '1 day')",actor,UUID.randomUUID(),UUID.randomUUID().toString());
        try(var tx=connection("uten")) {
            bind(tx.db,actor,"maintenance-admin");
            var result=tx.db.queryForMap("SELECT * FROM public.business_data_reset()");
            assertTrue(((Number)result.get("cleared_table_count")).intValue()>0);
            assertEquals(before+1,((Number)result.get("authorization_epoch_after")).longValue());
            assertEquals("uten",tx.db.queryForObject("SELECT current_user",String.class));
            tx.connection.commit();
        }
        assertEquals(users,owner.queryForObject("SELECT count(*) FROM users",Long.class));
        assertEquals(0L,owner.queryForObject("SELECT count(*) FROM refresh_tokens",Long.class));
        assertEquals(0L,owner.queryForObject("SELECT count(*) FROM business_outbox",Long.class));
        assertFalse(app.queryForObject("SELECT has_schema_privilege(current_user,'public','CREATE')",Boolean.class));
    }

    static JdbcTemplate db(String user){return new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),user,PASSWORD));}
    static Tx connection(String user) throws Exception {var c=DriverManager.getConnection(PG.getJdbcUrl(),user,PASSWORD);c.setAutoCommit(false);return new Tx(c);}
    static final class Tx implements AutoCloseable {
        final Connection connection;final JdbcTemplate db;
        Tx(Connection c){connection=c;db=new JdbcTemplate(new SingleConnectionDataSource(c,true));}
        @Override public void close() throws Exception {connection.rollback();connection.close();}
    }
    static void bind(JdbcTemplate db,UUID user,String account){
        db.queryForMap("SELECT set_config('app.actor_id',?,true),set_config('app.actor_account',?,true),set_config('app.audit_request_id',?,true)",user.toString(),account,UUID.randomUUID().toString());
    }
    static void assertResetDenied(Tx tx) throws Exception {
        var save=tx.connection.setSavepoint();
        try {
            var failure=assertThrows(org.springframework.dao.DataAccessException.class,()->tx.db.queryForList("SELECT * FROM public.business_data_reset()"));
            assertEquals("42501",((java.sql.SQLException)failure.getMostSpecificCause()).getSQLState());
        }
        finally {tx.connection.rollback(save);}
    }
}
