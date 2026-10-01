package com.uten.imp.features.ai.job;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
/** Current pre-V773 database upgrade and a genuinely old writer continuing after migration. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class AiInputOriginalRollingMigrationPostgresTest {
    @Test void upgradePreservesPendingRunningLostAndConflictingHistoryThenFencesOldTerminalWriters() {
        try(var database=new PostgreSQLContainer<>("postgres:16-alpine").withDatabaseName("ai_original_pre773")) {
            database.start();Flyway.configure().dataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()).target("772").load().migrate();
            var jdbc=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
            UUID actor=UUID.randomUUID(),employee=UUID.randomUUID();
            jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'迁移测试','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"MIG-"+employee);
            jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')",actor,employee,"original-migration-"+actor);
            byte[] bytes="model,qty\r\nMODEL,1\r\n".getBytes(StandardCharsets.UTF_8);String sha=ImmutableDocumentStore.digest(bytes);
            UUID pending=insert(jdbc,actor,"PENDING",bytes,sha,bytes.length);
            UUID running=insert(jdbc,actor,"RUNNING",bytes,sha,bytes.length);
            UUID conflict=insert(jdbc,actor,"PENDING",bytes,"a".repeat(64),bytes.length+1);
            UUID lost=insert(jdbc,actor,"SUCCEEDED",null,sha,bytes.length);
            UUID disappeared=UUID.randomUUID(),doc=UUID.randomUUID();
            jdbc.update("INSERT INTO sales_document_learning_receipts(id,doc_type,doc_id,actor_user_id,request_payload,steps) VALUES(?,'quote',?,?,jsonb_build_object('intakeJobId',CAST(? AS text),'lines','[]'::jsonb,'clientFields','{}'::jsonb),'{}'::jsonb)",UUID.randomUUID(),doc,actor,disappeared.toString());
            jdbc.update("INSERT INTO sales_document_learning_receipts(id,doc_type,doc_id,actor_user_id,request_payload,steps) VALUES(?,'quote',?,?, '{\"intakeJobId\":\"bad-legacy-value\",\"additionalIntakeJobIds\":[\"also-bad\"]}'::jsonb,'{}'::jsonb)",UUID.randomUUID(),UUID.randomUUID(),actor);
            Flyway.configure().dataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()).target("773").load().migrate();
            assertThat(jdbc.queryForObject("SELECT legacy_bytes FROM ai_input_originals WHERE job_id=?",byte[].class,pending)).isEqualTo(bytes);
            assertThat(jdbc.queryForObject("SELECT legacy_bytes FROM ai_input_originals WHERE job_id=?",byte[].class,running)).isEqualTo(bytes);
            assertThat(jdbc.queryForObject("SELECT availability FROM ai_input_originals WHERE job_id=?",String.class,conflict)).isEqualTo("LEGACY_CONFLICT");
            assertThat(jdbc.queryForObject("SELECT declared_sha256 FROM ai_input_originals WHERE job_id=?",String.class,conflict)).isEqualTo("a".repeat(64));
            assertThat(jdbc.queryForObject("SELECT storage_sha256 FROM ai_input_originals WHERE job_id=?",String.class,conflict)).isEqualTo(sha);
            assertThat(jdbc.queryForObject("SELECT availability FROM ai_input_originals WHERE job_id=?",String.class,lost)).isEqualTo("LEGACY_UNAVAILABLE");
            assertThat(jdbc.queryForObject("SELECT availability FROM ai_input_originals WHERE job_id=?",String.class,disappeared)).isEqualTo("LEGACY_UNAVAILABLE");
            assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_input_original_bindings WHERE job_id=? AND doc_id=?",Integer.class,disappeared,doc)).isEqualTo(1);
            // An old server inserts another pending job after the new migration is installed.
            UUID oldNode=insert(jdbc,actor,"PENDING",bytes,sha,bytes.length);
            jdbc.update("UPDATE ai_jobs SET status='SUCCEEDED',input_bytes=NULL,finished_at=now() WHERE id IN (?,?)",running,oldNode);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_jobs WHERE id IN (?,?) AND input_bytes IS NULL",Integer.class,running,oldNode)).isEqualTo(2);
            UUID formal=UUID.randomUUID();
            jdbc.update("INSERT INTO sales_quotes(id,bill_no,bill_date,status) VALUES(?,'XB'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'888881',CURRENT_DATE,0)",formal);
            // An old service has no new Java adapter: its original destination marker still binds atomically.
            jdbc.update("UPDATE ai_jobs SET used_doc_type='quote',used_doc_id=?,used_at=now(),result=NULL WHERE id=?",formal,oldNode);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_input_original_bindings WHERE job_id=? AND doc_id=?",Integer.class,oldNode,formal)).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT temporary_until IS NULL FROM ai_input_originals WHERE job_id=?",Boolean.class,oldNode)).isTrue();
            jdbc.update("DELETE FROM ai_jobs WHERE id IN (?,?)",running,oldNode);
            assertThat(jdbc.queryForObject("SELECT legacy_bytes FROM ai_input_originals WHERE job_id=?",byte[].class,oldNode)).isEqualTo(bytes);
            assertThat(jdbc.queryForObject("SELECT legacy_bytes FROM ai_input_originals WHERE job_id=?",byte[].class,running)).isEqualTo(bytes);
            assertThatThrownBy(()->jdbc.update("UPDATE ai_input_originals SET legacy_bytes=decode('00','hex') WHERE job_id=?",pending)).hasMessageContaining("immutable");
            assertThat(jdbc.queryForObject("SELECT pg_get_functiondef('business_data_reset()'::regprocedure)",String.class)).contains("('ai_input_originals', 'PRESERVE')","('ai_input_original_bindings', 'PRESERVE')");
        }
    }
    private UUID insert(JdbcTemplate jdbc,UUID actor,String status,byte[] bytes,String sha,int size) {
        UUID id=UUID.randomUUID();jdbc.update("""
                INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,input_bytes,submitted_by_user,submitted_auth_version,finished_at)
                VALUES(?,'SALES_DOCUMENT_INTAKE',?,'original.csv','text/csv','CSV',?,?,?, ?,1,CASE WHEN ?='SUCCEEDED' THEN now() END)
                """,id,status,size,sha,bytes,actor,status);return id;
    }
}
