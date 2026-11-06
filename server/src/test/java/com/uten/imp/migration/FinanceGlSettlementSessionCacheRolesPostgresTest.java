package com.uten.imp.migration;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.*;
import java.util.*;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.*;

/** Actual PostgreSQL role/FK execution with the unmodified settlement triggers.
 * The lean schema isolates cache ACLs; it is not a financial-flow acceptance fixture. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceGlSettlementSessionCacheRolesPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("gl_cache_roles").withUsername("fixture_admin").withPassword("fixture-admin-only");
    private static final UUID STYLE=UUID.fromString("77300000-0000-4000-8000-000000000001");
    private static final UUID ROOT=UUID.fromString("77300000-0000-4000-8000-000000000002");
    private static final UUID VOUCHER=UUID.fromString("77300000-0000-4000-8000-000000000003");
    private static final UUID ENTRY=UUID.fromString("77300000-0000-4000-8000-000000000004");
    private static final String[] FUNCTIONS={"fn_finance_gl_settlement_lock_style(uuid,boolean)",
            "fn_finance_gl_settlement_scope_lock(uuid)","fn_finance_gl_settlement_floor()",
            "fn_finance_gl_settlement_gl_lock()","fn_finance_gl_settlement_reservation_lock()"};

    @BeforeAll static void start() throws Exception {
        PG.start();
        try(Connection connection=admin()) {
            execute(connection,"""
                CREATE ROLE cache_runtime LOGIN PASSWORD 'fixture-runtime-only' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
                CREATE ROLE cache_active NOLOGIN;
                CREATE ROLE cache_outsider NOLOGIN;
                CREATE ROLE cache_voucher_owner NOLOGIN;
                CREATE ROLE cache_entry_owner NOLOGIN;
                CREATE ROLE cache_allocation_owner NOLOGIN;
                CREATE ROLE cache_reservation_owner NOLOGIN;
                CREATE ROLE cache_legacy_owner NOLOGIN;
                CREATE ROLE cache_scope_owner NOLOGIN;
                CREATE ROLE cache_function_owner NOLOGIN;
                GRANT cache_active,cache_outsider TO cache_runtime;
                """);
        }
    }
    @AfterAll static void stop(){PG.stop();}

    @BeforeEach void schema() throws Exception {
        try(Connection connection=admin()) {
            execute(connection,"""
                DROP SCHEMA public CASCADE;
                CREATE SCHEMA public;
                GRANT USAGE ON SCHEMA public TO cache_runtime,cache_active,cache_outsider,
                  cache_voucher_owner,cache_entry_owner,cache_allocation_owner,cache_reservation_owner,
                  cache_legacy_owner,cache_scope_owner,cache_function_owner;
                CREATE TABLE cache_fk_roots(id uuid PRIMARY KEY);
                CREATE TABLE gl_vouchers(id uuid PRIMARY KEY,root_id uuid REFERENCES cache_fk_roots ON DELETE CASCADE,is_deleted boolean NOT NULL DEFAULT false);
                CREATE TABLE gl_entries(id uuid PRIMARY KEY,voucher_id uuid REFERENCES gl_vouchers ON DELETE CASCADE,
                  style_id uuid NOT NULL,entry_date date DEFAULT current_date,is_deleted boolean NOT NULL DEFAULT false,direction smallint DEFAULT 1);
                CREATE TABLE finance_gl_entry_allocations(entry_id uuid REFERENCES gl_entries ON DELETE CASCADE,allocation_no integer,
                  account_code text,auxiliary_id uuid,currency_id uuid,original_currency_id uuid,auxiliary_role text,party_id_snapshot uuid,
                  amount_local numeric,amount_original numeric,PRIMARY KEY(entry_id,allocation_no));
                CREATE TABLE finance_gl_settlement_scopes(id uuid PRIMARY KEY,style_id uuid);
                CREATE TABLE finance_gl_settlement_reservations(id uuid PRIMARY KEY,scope_id uuid,status text,as_of date);
                CREATE TABLE finance_native_legacy_opening_parts(entry_id uuid REFERENCES gl_entries ON DELETE CASCADE);
                CREATE TABLE cache_invocations(table_name text,actor text);
                CREATE FUNCTION cache_trace() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN
                  INSERT INTO public.cache_invocations VALUES(TG_TABLE_NAME,current_user); RETURN OLD; END$$;
                -- RI actions run BEFORE row callbacks while the referenced
                -- child owner is active; queued AFTER callbacks run later as
                -- the original caller. Trace the same phase as the lock.
                CREATE TRIGGER aa_cache_trace BEFORE DELETE ON gl_vouchers FOR EACH ROW EXECUTE FUNCTION cache_trace();
                CREATE TRIGGER aa_cache_trace BEFORE DELETE ON gl_entries FOR EACH ROW EXECUTE FUNCTION cache_trace();
                ALTER TABLE gl_vouchers OWNER TO cache_voucher_owner;
                ALTER TABLE gl_entries OWNER TO cache_entry_owner;
                ALTER TABLE finance_gl_entry_allocations OWNER TO cache_allocation_owner;
                ALTER TABLE finance_gl_settlement_reservations OWNER TO cache_reservation_owner;
                ALTER TABLE finance_native_legacy_opening_parts OWNER TO cache_legacy_owner;
                ALTER TABLE finance_gl_settlement_scopes OWNER TO cache_scope_owner;
                GRANT SELECT ON ALL TABLES IN SCHEMA public TO cache_runtime,cache_active,
                  cache_voucher_owner,cache_entry_owner,cache_allocation_owner,cache_reservation_owner,cache_legacy_owner;
                GRANT INSERT ON cache_invocations TO cache_runtime,cache_active,
                  cache_voucher_owner,cache_entry_owner,cache_allocation_owner,cache_reservation_owner,cache_legacy_owner;
                GRANT DELETE ON cache_fk_roots,gl_vouchers TO cache_runtime,cache_active;
                """);
            String original=resource("V1006__payroll_original_fact_payment_bridge.sql");
            for(String signature:FUNCTIONS) {
                String name=signature.substring(0,signature.indexOf('('));
                int start=original.indexOf("CREATE FUNCTION "+name+"(");
                assertTrue(start>=0,name);
                int end=original.indexOf("$$;",start);
                assertTrue(end>start,name);
                execute(connection,original.substring(start,end+3));
                execute(connection,"ALTER FUNCTION "+signature+" OWNER TO cache_function_owner");
                execute(connection,"REVOKE ALL ON FUNCTION "+signature+" FROM PUBLIC");
                execute(connection,"GRANT EXECUTE ON FUNCTION "+signature+" TO cache_runtime,cache_active,cache_voucher_owner,cache_entry_owner,cache_allocation_owner,cache_reservation_owner,cache_legacy_owner");
            }
            String partition=resource("V1017__native_and_general_gl_settlement_partitions.sql");
            String marker="$partition_existing_gl_floor$";
            int start=partition.indexOf("DO "+marker),end=partition.indexOf(marker+";",start+marker.length()+3);
            execute(connection,partition.substring(start,end+marker.length()+1));
            for(String name:List.of("finance_gl_settlement_entry_lock","finance_gl_settlement_allocation_lock",
                    "finance_gl_settlement_voucher_lock","finance_gl_settlement_entries_floor","finance_gl_settlement_allocations_floor",
                    "finance_gl_settlement_vouchers_floor","finance_gl_settlement_reservations_floor","finance_gl_settlement_reservation_lock")) {
                var matcher=Pattern.compile("(?m)^CREATE(?: CONSTRAINT)? TRIGGER "+Pattern.quote(name)+"\\b[\\s\\S]*?;").matcher(original);
                assertTrue(matcher.find(),name);execute(connection,matcher.group());
            }
            insert(connection,"INSERT INTO cache_fk_roots(id)VALUES(?)",ROOT);
            insert(connection,"INSERT INTO gl_vouchers(id,root_id)VALUES(?,?)",VOUCHER,ROOT);
            insert(connection,"INSERT INTO gl_entries(id,voucher_id,style_id)VALUES(?,?,?)",ENTRY,VOUCHER,STYLE);
            insert(connection,"INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no)VALUES(?,1)",ENTRY);
        }
    }

    @Test void oldInvokerFunctionReallyFailsInForeignKeyOwnerCallbackAndRollsBackRows() throws Exception {
        try(Connection connection=runtime()) {
            connection.setAutoCommit(false);
            SQLException failure=assertThrows(SQLException.class,()->insert(connection,"DELETE FROM gl_vouchers WHERE id=?",VOUCHER));
            assertEquals("42501",failure.getSQLState());
            assertTrue(failure.getMessage().contains("finance_gl_settlement_dirty"));
            connection.rollback();
        }
        try(Connection connection=admin()) {
            assertEquals(1,number(connection,"SELECT count(*) FROM gl_vouchers"));
            assertEquals(1,number(connection,"SELECT count(*) FROM gl_entries"));
            assertEquals(1,number(connection,"SELECT count(*) FROM finance_gl_entry_allocations"));
        }
    }

    @Test void runtimeCreatedCacheWorksThroughRealFkOwnerAndDeferredFloorWithoutChildDeletePermission() throws Exception {
        patch();
        try(Connection connection=runtime()) {
            connection.setAutoCommit(false);
            call(connection,true);
            assertEquals("cache_runtime",text(connection,"SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid='pg_temp.finance_gl_settlement_dirty'::regclass"));
            assertFalse(truth(connection,"SELECT has_table_privilege(current_user,'gl_entries','DELETE')"));
            insert(connection,"DELETE FROM gl_vouchers WHERE id=?",VOUCHER);
            execute(connection,"SET CONSTRAINTS ALL IMMEDIATE");
            assertEquals("cache_entry_owner",text(connection,"SELECT actor FROM cache_invocations WHERE table_name='gl_entries'"));
            assertEquals(0,number(connection,"SELECT count(*) FROM gl_entries"));
            assertEquals(0,number(connection,"SELECT count(*) FROM finance_gl_entry_allocations"));
            assertEquals(0,number(connection,"SELECT count(*) FROM pg_temp.finance_gl_settlement_dirty WHERE generation<>checked_generation"));
            assertCacheAcl(connection);
            connection.commit();
            assertNull(text(connection,"SELECT to_regclass('pg_temp.finance_gl_settlement_dirty')::text"));
        }
    }

    @Test void fkOwnerCreatedCacheRemainsUsableByLoginActorAndAnotherSessionCannotSeeIt() throws Exception {
        patch();
        try(Connection connection=runtime()) {
            connection.setAutoCommit(false);
            insert(connection,"DELETE FROM cache_fk_roots WHERE id=?",ROOT);
            assertEquals("cache_voucher_owner",text(connection,"SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid='pg_temp.finance_gl_settlement_dirty'::regclass"));
            assertEquals("cache_voucher_owner",text(connection,"SELECT actor FROM cache_invocations WHERE table_name='gl_vouchers'"));
            assertEquals("cache_entry_owner",text(connection,"SELECT actor FROM cache_invocations WHERE table_name='gl_entries'"));
            execute(connection,"SET CONSTRAINTS ALL IMMEDIATE");
            long generation=number(connection,"SELECT generation FROM pg_temp.finance_gl_settlement_dirty");
            call(connection,false);
            assertEquals(generation,number(connection,"SELECT generation FROM pg_temp.finance_gl_settlement_dirty"));
            call(connection,true);
            assertEquals(generation+1,number(connection,"SELECT generation FROM pg_temp.finance_gl_settlement_dirty"));
            try(Connection independent=runtime()) {
                assertNull(text(independent,"SELECT to_regclass('pg_temp.finance_gl_settlement_dirty')::text"));
            }
            connection.rollback();
            assertNull(text(connection,"SELECT to_regclass('pg_temp.finance_gl_settlement_dirty')::text"));
            assertEquals(1,number(connection,"SELECT count(*) FROM gl_entries"));
        }
    }

    @Test void pgAuthorizedSetRoleIsIncludedButUnrelatedRoleAndDirectChildDeleteStayDenied() throws Exception {
        patch();
        try(Connection connection=runtime()) {
            connection.setAutoCommit(false);
            execute(connection,"SET ROLE cache_active");
            assertEquals("cache_runtime",text(connection,"SELECT session_user"));
            assertEquals("cache_active",text(connection,"SELECT current_user"));
            insert(connection,"DELETE FROM cache_fk_roots WHERE id=?",ROOT);
            call(connection,false);
            for(String privilege:List.of("SELECT","INSERT","UPDATE")) {
                assertTrue(truth(connection,"SELECT has_table_privilege('cache_active','pg_temp.finance_gl_settlement_dirty','"+privilege+"')"),privilege);
            }
            Savepoint direct=connection.setSavepoint();
            assertEquals("42501",assertThrows(SQLException.class,()->insert(connection,"DELETE FROM gl_entries WHERE id=?",ENTRY)).getSQLState());
            connection.rollback(direct);
            execute(connection,"SET ROLE cache_outsider");
            Savepoint denied=connection.setSavepoint();
            assertEquals("42501",assertThrows(SQLException.class,()->number(connection,"SELECT count(*) FROM pg_temp.finance_gl_settlement_dirty")).getSQLState());
            connection.rollback(denied);
            execute(connection,"RESET ROLE");
            call(connection,false);
            connection.commit();
            assertNull(text(connection,"SELECT to_regclass('pg_temp.finance_gl_settlement_dirty')::text"));
        }
    }

    @Test void migrationPreservesInvokerOwnersFunctionAclsBusinessAclsAndAllOtherSettlementDefinitions() throws Exception {
        try(Connection connection=admin()) {
            String metadata=text(connection,"SELECT jsonb_agg(jsonb_build_array(proname,proowner,prosecdef,proacl) ORDER BY proname)::text FROM pg_proc WHERE proname=ANY(ARRAY['fn_finance_gl_settlement_lock_style','fn_finance_gl_settlement_scope_lock','fn_finance_gl_settlement_floor','fn_finance_gl_settlement_gl_lock','fn_finance_gl_settlement_reservation_lock'])");
            String definitions=text(connection,"SELECT jsonb_agg(pg_get_functiondef(oid) ORDER BY proname)::text FROM pg_proc WHERE proname=ANY(ARRAY['fn_finance_gl_settlement_scope_lock','fn_finance_gl_settlement_floor','fn_finance_gl_settlement_gl_lock','fn_finance_gl_settlement_reservation_lock'])");
            String tables=text(connection,"SELECT jsonb_agg(jsonb_build_array(relname,relowner,relacl) ORDER BY relname)::text FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind='r'");
            execute(connection,resource("V1073__finance_gl_settlement_session_cache_roles.sql"));
            assertEquals(metadata,text(connection,"SELECT jsonb_agg(jsonb_build_array(proname,proowner,prosecdef,proacl) ORDER BY proname)::text FROM pg_proc WHERE proname=ANY(ARRAY['fn_finance_gl_settlement_lock_style','fn_finance_gl_settlement_scope_lock','fn_finance_gl_settlement_floor','fn_finance_gl_settlement_gl_lock','fn_finance_gl_settlement_reservation_lock'])"));
            assertEquals(definitions,text(connection,"SELECT jsonb_agg(pg_get_functiondef(oid) ORDER BY proname)::text FROM pg_proc WHERE proname=ANY(ARRAY['fn_finance_gl_settlement_scope_lock','fn_finance_gl_settlement_floor','fn_finance_gl_settlement_gl_lock','fn_finance_gl_settlement_reservation_lock'])"));
            assertEquals(tables,text(connection,"SELECT jsonb_agg(jsonb_build_array(relname,relowner,relacl) ORDER BY relname)::text FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind='r'"));
        }
    }

    private static void assertCacheAcl(Connection connection) throws Exception {
        assertEquals(0,number(connection,"SELECT count(*) FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE c.oid='pg_temp.finance_gl_settlement_dirty'::regclass AND a.grantee=0"));
        assertFalse(truth(connection,"SELECT has_table_privilege('cache_scope_owner','pg_temp.finance_gl_settlement_dirty','SELECT')"));
        assertFalse(truth(connection,"SELECT has_table_privilege('cache_outsider','pg_temp.finance_gl_settlement_dirty','SELECT')"));
        for(String role:List.of("cache_voucher_owner","cache_entry_owner","cache_allocation_owner","cache_reservation_owner","cache_legacy_owner")) {
            for(String privilege:List.of("SELECT","INSERT","UPDATE","DELETE")) {
                try(PreparedStatement statement=connection.prepareStatement("SELECT has_table_privilege(?,'pg_temp.finance_gl_settlement_dirty',?)")) {
                    statement.setString(1,role);statement.setString(2,privilege);
                    try(ResultSet result=statement.executeQuery()) {
                        assertTrue(result.next());assertEquals(!privilege.equals("DELETE"),result.getBoolean(1),role+":"+privilege);
                    }
                }
            }
        }
    }
    private static void patch() throws Exception {try(Connection connection=admin()){execute(connection,resource("V1073__finance_gl_settlement_session_cache_roles.sql"));}}
    private static String resource(String name) throws Exception {
        try(var stream=FinanceGlSettlementSessionCacheRolesPostgresTest.class.getResourceAsStream("/db/migration/"+name)) {
            assertNotNull(stream,name);return new String(stream.readAllBytes(),StandardCharsets.UTF_8);
        }
    }
    private static Connection admin() throws SQLException {return DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());}
    private static Connection runtime() throws SQLException {return DriverManager.getConnection(PG.getJdbcUrl(),"cache_runtime","fixture-runtime-only");}
    private static void execute(Connection connection,String sql) throws SQLException {try(Statement statement=connection.createStatement()){statement.execute(sql);}}
    private static int insert(Connection connection,String sql,Object... parameters) throws SQLException {
        try(PreparedStatement statement=connection.prepareStatement(sql)){for(int n=0;n<parameters.length;n++)statement.setObject(n+1,parameters[n]);return statement.executeUpdate();}
    }
    private static void call(Connection connection,boolean dirty) throws SQLException {
        try(PreparedStatement statement=connection.prepareStatement("SELECT fn_finance_gl_settlement_lock_style(?,?)")){statement.setObject(1,STYLE);statement.setBoolean(2,dirty);statement.execute();}
    }
    private static String text(Connection connection,String sql) throws SQLException {try(Statement statement=connection.createStatement();ResultSet result=statement.executeQuery(sql)){assertTrue(result.next());return result.getString(1);}}
    private static long number(Connection connection,String sql) throws SQLException {try(Statement statement=connection.createStatement();ResultSet result=statement.executeQuery(sql)){assertTrue(result.next());return result.getLong(1);}}
    private static boolean truth(Connection connection,String sql) throws SQLException {try(Statement statement=connection.createStatement();ResultSet result=statement.executeQuery(sql)){assertTrue(result.next());return result.getBoolean(1);}}
}
