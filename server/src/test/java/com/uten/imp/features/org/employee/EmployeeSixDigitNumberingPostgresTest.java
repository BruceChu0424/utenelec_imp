package com.uten.imp.features.org.employee;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.testsupport.TestFlyway;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual migrations, reservation/audit triggers and reviewed maintenance SQL. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class EmployeeSixDigitNumberingPostgresTest {
    static PostgreSQLContainer postgres;
    static String maintenance;
    static final ObjectMapper JSON=new ObjectMapper();
    Connection connection;
    JdbcTemplate db;
    String databaseName;
    UUID first,second,older,newer,owner;

    @BeforeAll static void migrate() throws Exception {
        postgres=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("numbering_template");
        postgres.start();
        TestFlyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                .locations("classpath:db/migration").load().migrate();
        maintenance=Files.readString(Path.of("maintenance/employee_six_digit_numbering.sql"));
    }
    @AfterAll static void stop(){if(postgres!=null)postgres.stop();}
    @BeforeEach void fixture() throws Exception {
        databaseName="numbering_"+UUID.randomUUID().toString().replace("-","");
        try(var c=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());var s=c.createStatement()) {
            s.execute("CREATE DATABASE "+databaseName+" TEMPLATE numbering_template");
        }
        connection=open();
        db=new JdbcTemplate(new SingleConnectionDataSource(connection,true));
        db.execute(maintenance);
        owner=db.queryForObject("SELECT id FROM employees WHERE code='ADMIN'",UUID.class);
        db.update("INSERT INTO users(employee_id,login_account,password_hash,status,must_change_password,is_super_admin) VALUES (?,'17665410007','synthetic-fixture-only','active',false,true)",owner);
        first=employee("UT0400","朱德洪","2005-01-01");
        second=employee("UT0300","王少春","2001-01-01");
        newer=employee("UT0001","较晚入职测试员工","2018-01-01");
        older=employee("UT0500","较早入职测试员工","2010-01-01");
        db.update("INSERT INTO employment_history(employee_id,event_type,event_date,remark) SELECT id,'onboard',hire_date,'original fixture' FROM employees WHERE id=?",owner);
    }
    @AfterEach void cleanup() throws Exception {
        if(connection!=null)connection.close();
        if(databaseName!=null)try(var c=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());var s=c.createStatement()) {
            s.execute("DROP DATABASE "+databaseName+" WITH (FORCE)");
        }
    }

    @Test void ranksFoundersThenHireDateAndOwnerLastPreservingIdentityCredentialsAndHistory() throws Exception {
        String users=db.queryForObject("SELECT jsonb_agg(to_jsonb(u) ORDER BY id)::text FROM users u",String.class);
        String history=db.queryForObject("SELECT jsonb_agg(to_jsonb(h) ORDER BY id)::text FROM employment_history h",String.class);
        String preview=plan();
        assertThat(JSON.readTree(preview).path("issues")).isEmpty();
        JsonNode entries=JSON.readTree(preview).path("entries");
        assertThat(entries.get(0).path("employeeId").asText()).isEqualTo(first.toString());
        assertThat(entries.get(1).path("employeeId").asText()).isEqualTo(second.toString());
        assertThat(entries.get(2).path("employeeId").asText()).isEqualTo(older.toString());
        assertThat(entries.get(3).path("employeeId").asText()).isEqualTo(newer.toString());
        assertThat(entries.get(4).path("employeeId").asText()).isEqualTo(owner.toString());
        apply(preview);
        assertThat(code(first)).isEqualTo("000001");
        assertThat(code(second)).isEqualTo("000002");
        assertThat(code(older)).isEqualTo("000003");
        assertThat(code(newer)).isEqualTo("000004");
        assertThat(code(owner)).isEqualTo("000005");
        assertThat(db.queryForObject("SELECT fn_employee_code_requires_identity_mapping('UT0400')",Boolean.class)).isTrue();
        assertThat(db.queryForObject("SELECT fn_employee_code_requires_identity_mapping('000001')",Boolean.class)).isFalse();
        assertThat(db.queryForObject("SELECT hire_date::text FROM employees WHERE id=?",String.class,owner)).isEqualTo("2026-10-31");
        assertThat(db.queryForObject("SELECT confirmed_at::text FROM employees WHERE id=?",String.class,owner)).isEqualTo("2026-10-31");
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(u) ORDER BY id)::text FROM users u",String.class)).isEqualTo(users);
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(h) ORDER BY id)::text FROM employment_history h WHERE event_type<>'hire_date_correction'",String.class)).isEqualTo(history);
        assertThat(db.queryForObject("SELECT count(*) FROM employment_history WHERE employee_id=? AND event_type='hire_date_correction' AND corrects_history_id IS NOT NULL",Integer.class,owner)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM business_identifier_reservation_members WHERE owner_domain='EMPLOYEE' AND entity_id=? AND normalized_identifier IN('UT0400','000001')",Integer.class,first)).isEqualTo(2);
        assertThat(JSON.readTree(apply(preview)).path("alreadyApplied").asBoolean()).isTrue();
        assertThatThrownBy(()->apply(plan())).hasMessageContaining("already complete");
        db.update("UPDATE employees SET hire_date=DATE '2000-01-01' WHERE id=?",newer);
        assertThat(code(newer)).isEqualTo("000004");
        String next=nextCode(db);
        assertThat(next).isEqualTo("000006");
        employee(next,"后续补录老员工","1999-01-01");
        assertThat(code(first)).isEqualTo("000001");
        assertThat(code(owner)).isEqualTo("000005");
    }
    @Test void stalePreviewRollsBackWithoutChangingAnyNumber() {
        String preview=plan();
        db.update("UPDATE employees SET hire_date=DATE '2008-01-01',version=version+1 WHERE id=?",newer);
        assertThatThrownBy(()->apply(preview)).hasMessageContaining("preview is stale");
        assertThat(code(first)).isEqualTo("UT0400");
        assertThat(db.queryForObject("SELECT count(*) FROM employee_code_numbering_receipts",Integer.class)).isZero();
    }
    @Test void aReservedTargetNeverMovesToAnotherIdentity() throws Exception {
        employee("000001","既有数字工号","2020-01-01");
        String preview=plan();
        assertThat(JSON.readTree(preview).path("issues")).isNotEmpty();
        assertThatThrownBy(()->apply(preview)).hasMessageContaining("preflight failed");
        assertThat(code(first)).isEqualTo("UT0400");
    }
    @Test void changingOwnerDateNeverRewritesInconsistentEmploymentFacts() {
        db.update("UPDATE employees SET confirmed_at=DATE '2020-01-01' WHERE id=?",owner);
        assertThatThrownBy(()->apply(plan())).hasMessageContaining("preflight failed");
        assertThat(code(owner)).isEqualTo("ADMIN");
    }
    @Test void wrongFounderAndWrongDatabaseAreRejected() throws Exception {
        assertThatThrownBy(()->db.queryForObject("SELECT pg_temp.employee_numbering_plan(?,?)::text",String.class,second,first))
                .hasMessageContaining("verified retained");
        var wrong=(com.fasterxml.jackson.databind.node.ObjectNode)JSON.readTree(plan());
        wrong.put("datasetId",UUID.randomUUID().toString());
        assertThatThrownBy(()->apply(wrong.toString())).hasMessageContaining("different database");
    }
    @Test void rolledBackApplicationLeavesOriginalCodesAndCanBeRetried() throws Exception {
        String preview=plan();
        connection.setAutoCommit(false);
        apply(preview);
        assertThat(code(owner)).isEqualTo("000005");
        connection.rollback();connection.setAutoCommit(true);
        assertThat(code(owner)).isEqualTo("ADMIN");
        assertThat(db.queryForObject("SELECT count(*) FROM employee_code_numbering_receipts",Integer.class)).isZero();
        apply(preview);
        assertThat(code(owner)).isEqualTo("000005");
        assertThatThrownBy(()->db.update("DELETE FROM employee_code_numbering_receipts")).hasMessageContaining("append-only");
    }
    @Test void allocatorSerializesConcurrencyAndRejectsOverflow() throws Exception {
        apply(plan());
        connection.setAutoCommit(false);
        assertThat(nextCode(db)).isEqualTo("000006");
        var waiting=CompletableFuture.supplyAsync(()->{
            try(var c=open()) { return nextCode(new JdbcTemplate(new SingleConnectionDataSource(c,true))); }
            catch(Exception failure){throw new RuntimeException(failure);}
        });
        connection.commit();connection.setAutoCommit(true);
        assertThat(waiting.get(15,TimeUnit.SECONDS)).isEqualTo("000007");
        db.update("UPDATE master_code_sequences SET last_seq=999998 WHERE prefix=''");
        assertThat(nextCode(db)).isEqualTo("999999");
        assertThatThrownBy(()->nextCode(db)).isInstanceOf(IllegalStateException.class).hasMessageContaining("exhausted");
    }
    @Test void numericImportsAdvanceOnlyTheEmployeeSequenceAndFounderSlotsAreReserved() {
        assertThat(nextCode(db)).isEqualTo("000003");
        employee("000721","已导入数字工号","2010-01-01");
        assertThat(nextCode(db)).isEqualTo("000722");
        assertThat(db.queryForObject("SELECT last_seq FROM master_code_sequences WHERE prefix='UT'",Integer.class)).isGreaterThanOrEqualTo(500);
    }
    @Test void completedNumberingRejectsOldClientWritesAndManualRenumbering() {
        apply(plan());
        assertThatThrownBy(()->employee("UT0800","过期客户端创建","2020-01-01"))
                .hasMessageContaining("six-digit number");
        assertThatThrownBy(()->db.update("UPDATE employees SET code='ADMIN' WHERE id=?",owner))
                .hasMessageContaining("numbers are fixed");
        assertThatThrownBy(()->db.update("UPDATE employees SET code='000099' WHERE id=?",newer))
                .hasMessageContaining("numbers are fixed");
        assertThat(code(owner)).isEqualTo("000005");
    }
    @Test void runtimeGuardsWorkWithoutExposingThePrivateMaintenanceReceipt() {
        apply(plan());
        db.execute("CREATE ROLE numbering_runtime_fixture NOLOGIN");
        db.execute("GRANT USAGE ON SCHEMA public TO numbering_runtime_fixture");
        db.execute("GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public TO numbering_runtime_fixture");
        db.execute("REVOKE ALL ON employee_code_numbering_receipts FROM numbering_runtime_fixture");
        db.execute("GRANT EXECUTE ON FUNCTION fn_employee_code_requires_identity_mapping(text) TO numbering_runtime_fixture");
        db.execute("SET ROLE numbering_runtime_fixture");
        try {
            assertThatThrownBy(()->db.queryForObject("SELECT count(*) FROM employee_code_numbering_receipts",Integer.class))
                    .rootCause().hasMessageContaining("permission denied");
            assertThat(db.queryForObject("SELECT fn_employee_code_requires_identity_mapping('UT0400')",Boolean.class)).isTrue();
            assertThatThrownBy(()->db.update("UPDATE employees SET code='ADMIN' WHERE id=?",owner))
                    .hasMessageContaining("numbers are fixed");
        } finally {db.execute("RESET ROLE");}
    }
    @Test void initialNumberingStartsAfterTheOwnerEvenWithAnOldHighNumericCode() {
        UUID imported=employee("900000","历史高数字工号","2019-01-01");
        apply(plan());
        assertThat(code(imported)).isEqualTo("000005");
        assertThat(code(owner)).isEqualTo("000006");
        assertThat(nextCode(db)).isEqualTo("000007");
        assertThat(db.queryForObject("SELECT count(*) FROM business_identifier_reservation_members WHERE normalized_identifier='900000' AND entity_id=?",Integer.class,imported)).isEqualTo(1);
    }
    @Test void oneShotEntryIsRetiredAndLaterServerMigrationNeverRenumbersEmployees() throws Exception {
        String preview=plan();
        connection.setAutoCommit(false);
        apply(preview);
        db.execute("DROP FUNCTION pg_temp.apply_employee_numbering(jsonb,text)");
        db.execute("DROP FUNCTION pg_temp.employee_numbering_plan(uuid,uuid,text,date)");
        connection.commit();connection.setAutoCommit(true);
        assertThat(db.queryForObject("SELECT to_regprocedure('pg_temp.apply_employee_numbering(jsonb,text)')::text",String.class)).isNull();
        assertThat(db.queryForObject("SELECT to_regprocedure('pg_temp.employee_numbering_plan(uuid,uuid,text,date)')::text",String.class)).isNull();

        String employeesBefore=db.queryForObject("SELECT jsonb_agg(to_jsonb(e) ORDER BY id)::text FROM employees e",String.class);
        String historyBefore=db.queryForObject("SELECT jsonb_agg(to_jsonb(h) ORDER BY id)::text FROM employment_history h",String.class);
        String receiptBefore=db.queryForObject("SELECT to_jsonb(r)::text FROM employee_code_numbering_receipts r",String.class);
        int sequenceBefore=db.queryForObject("SELECT last_seq FROM master_code_sequences WHERE prefix=''",Integer.class);
        var migration=TestFlyway.configure().dataSource(postgres.getJdbcUrl().replace("numbering_template",databaseName),postgres.getUsername(),postgres.getPassword())
                .locations("classpath:db/migration").load().migrate();
        assertThat(migration.migrationsExecuted).isZero();
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(e) ORDER BY id)::text FROM employees e",String.class)).isEqualTo(employeesBefore);
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(h) ORDER BY id)::text FROM employment_history h",String.class)).isEqualTo(historyBefore);
        assertThat(db.queryForObject("SELECT to_jsonb(r)::text FROM employee_code_numbering_receipts r",String.class)).isEqualTo(receiptBefore);
        assertThat(db.queryForObject("SELECT last_seq FROM master_code_sequences WHERE prefix=''",Integer.class)).isEqualTo(sequenceBefore);

        // Even a new maintenance connection cannot load the retired script again.
        try(var c=open()) {
            var later=new JdbcTemplate(new SingleConnectionDataSource(c,true));
            assertThatThrownBy(()->later.execute(maintenance)).hasMessageContaining("script is retired");
        }
        assertThat(nextCode(db)).isEqualTo("000006");
    }
    private UUID employee(String code,String name,String hireDate) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,?,'其他',department_id,?::date,'active','regular' FROM employees WHERE id=?",id,code,name,hireDate,owner);
        return id;
    }
    private String plan(){return db.queryForObject("SELECT pg_temp.employee_numbering_plan(?,?)::text",String.class,first,second);}
    private String apply(String preview){return db.queryForObject("SELECT pg_temp.apply_employee_numbering(?::jsonb,'synthetic-numbering-regression')::text",String.class,preview);}
    private String code(UUID id){return db.queryForObject("SELECT code FROM employees WHERE id=?",String.class,id);}
    private Connection open() throws Exception {return DriverManager.getConnection(postgres.getJdbcUrl().replace("numbering_template",databaseName),postgres.getUsername(),postgres.getPassword());}

    /** Execute the production allocator's SQL against PostgreSQL, including its row locks. */
    private String nextCode(JdbcTemplate jdbc) {
        EntityManager em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation->{
            String sql=invocation.getArgument(0);
            Query query=mock(Query.class);Map<String,Object> params=new HashMap<>();
            when(query.setParameter(anyString(),any())).thenAnswer(call->{params.put(call.getArgument(0),call.getArgument(1));return query;});
            when(query.getSingleResult()).thenAnswer(call->{
                var template=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(jdbc);
                return template.queryForObject(sql,params,(rs,row)->new Object[]{rs.getString(1),rs.getLong(2),rs.getBoolean(3)});
            });return query;
        });
        return new MasterCodeService(em).nextCode(MasterCodePrefix.EMPLOYEE);
    }
}
