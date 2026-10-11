package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

/** Nonempty pre-V840 upgrade: the baseline includes V839 when available; legacy command xmin and reset/index sets stay unchanged. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class DailyReportMaterialReviewMigrationPostgresTest {
    private static final PostgreSQLContainer<?> pg=new PostgreSQLContainer<>("postgres:16-alpine").withDatabaseName("material_review_upgrade");
    private static JdbcTemplate db;
    private static UUID actor;
    private static Map<String,Object> old;
    private static List<String> tables,indexes,resetPolicy;
    @BeforeAll static void migrate() {
        pg.start();Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").target("839").load().migrate();
        db=new JdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()));
        actor=UUID.randomUUID();UUID department=UUID.randomUUID(),employee=UUID.randomUUID(),report=UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",department,"MAT-V3-D","材料审核迁移车间");
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",employee,"MAT-V3-E","材料审核迁移员工",department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',FALSE)",actor,employee,"material-review-migration");
        db.update("INSERT INTO production_daily_reports(id,bill_no,bill_date,status,maker_id) VALUES(?,'SR20200101000001',DATE '2020-01-01',0,?)",report,employee);
        db.update("INSERT INTO production_daily_report_commands(actor_user_id,idempotency_key,request_hash,report_id,created_by,command_kind,approval_protocol_version,reviewed_row_version) VALUES(?,? ,repeat('a',64),?,?,'APPROVE',2,0)",actor,"old-reviewed-material-key",report,actor);
        old=db.queryForMap("SELECT report_id,request_hash,approval_protocol_version,reviewed_row_version,xmin::text row_xmin FROM production_daily_report_commands WHERE actor_user_id=?",actor);
        tables=tables();indexes=indexes();resetPolicy=resetPolicy();
        Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").load().migrate();
    }
    @AfterAll static void stop(){pg.stop();}
    @Test void oldApprovalBytesAndReviewMeaningStayExactlyTheSame() {
        assertEquals(old,db.queryForMap("SELECT report_id,request_hash,approval_protocol_version,reviewed_row_version,xmin::text row_xmin FROM production_daily_report_commands WHERE actor_user_id=?",actor));
        assertNull(db.queryForObject("SELECT material_review_snapshot FROM production_daily_report_commands WHERE actor_user_id=?",Object.class,actor));
        assertEquals(tables,tables());assertEquals(indexes,indexes());assertEquals(resetPolicy,resetPolicy());
    }
    @Test void incompleteV3ProofOrForeignReportSnapshotCannotBeRecorded() {
        UUID report=newReport("SR20200101000002");
        assertThrows(Exception.class,()->insertV3(report,"{\"reportId\":\""+report+"\",\"reportVersion\":0,\"fingerprint\":\""+"b".repeat(64)+"\",\"rows\":[]}",null));
        assertThrows(Exception.class,()->insertV3(report,"{}","[]"));
        assertThrows(Exception.class,()->insertV3(report,"{\"reportId\":\""+UUID.randomUUID()+"\",\"reportVersion\":0,\"fingerprint\":\""+"b".repeat(64)+"\",\"rows\":[]}","[]"));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE report_id=?",Integer.class,report));
    }
    @Test void validV3EmptyMaterialSnapshotIsAppendOnlyAndUsesExistingResetPolicy() {
        UUID report=newReport("SR20200101000003");
        insertV3(report,"{\"reportId\":\""+report+"\",\"reportVersion\":0,\"fingerprint\":\""+"b".repeat(64)+"\",\"rows\":[]}","[]");
        assertThrows(Exception.class,()->db.update("UPDATE production_daily_report_commands SET material_decisions='[]'::jsonb WHERE report_id=?",report));
        assertThrows(Exception.class,()->db.update("DELETE FROM production_daily_report_commands WHERE report_id=?",report));
        assertEquals(3,db.queryForObject("SELECT approval_protocol_version FROM production_daily_report_commands WHERE report_id=?",Integer.class,report));
        assertTrue(resetPolicy().stream().anyMatch(row->row.startsWith("production_daily_report_commands|")));
    }
    private static UUID newReport(String billNo){UUID report=UUID.randomUUID();UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);db.update("INSERT INTO production_daily_reports(id,bill_no,bill_date,status,maker_id) VALUES(?,?,DATE '2020-01-01',0,?)",report,billNo,employee);return report;}
    private static void insertV3(UUID report,String snapshot,String decisions){db.update("INSERT INTO production_daily_report_commands(actor_user_id,idempotency_key,request_hash,report_id,created_by,command_kind,approval_protocol_version,reviewed_row_version,material_review_fingerprint,material_review_snapshot,material_decisions) VALUES(?,?,repeat('b',64),?,?,'APPROVE',3,0,repeat('b',64),CAST(? AS jsonb),CAST(? AS jsonb))",actor,"new-v3-migration-"+UUID.randomUUID(),report,actor,snapshot,decisions);}
    private static List<String> tables(){return db.queryForList("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename",String.class);}
    private static List<String> indexes(){return db.queryForList("SELECT indexname||'|'||indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY indexname",String.class);}
    private static List<String> resetPolicy(){return db.queryForList("SELECT table_name||'|'||disposition FROM fn_business_reset_table_policy() ORDER BY table_name",String.class);}
}
