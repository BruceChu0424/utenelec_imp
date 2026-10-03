package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;
import java.sql.DriverManager;

import static org.junit.jupiter.api.Assertions.*;

/** Exercise real migration order, including an existing V748 database with template payloads. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class QuoteTemplateCandidateTruncateMigrationPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");

    @BeforeAll static void start() { POSTGRES.start(); }
    @AfterAll static void stop() { POSTGRES.stop(); }

    @Test
    void emptyDatabaseInstallsOriginalV747AndForwardCleanup() throws Exception {
        String url = createDatabase("quote_cleanup_clean");
        Flyway flyway = flyway(url, null);
        flyway.migrate();
        JdbcTemplate db = jdbc(url);
        assertOriginalHistory(db);
        assertCleanupInstalled(db);
        Fixture fixture = seed(db);
        assertExactCleanup(db, fixture);
        assertEquals(0, flyway.migrate().migrationsExecuted);
        flyway.validate();
    }

    @Test
    void v748UpgradePreservesStoredPayloadsAndHistoryThenReplaysWithoutChanges() throws Exception {
        String url = createDatabase("quote_cleanup_upgrade");
        flyway(url, "748").migrate();
        JdbcTemplate db = jdbc(url);
        assertOriginalHistory(db);
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM pg_trigger
                WHERE tgrelid='sales_quote_template_candidates'::regclass
                  AND tgname='trg_quote_template_candidates_truncate'
                """, Integer.class));
        Fixture fixture = seed(db);
        String before = payloadSnapshot(db);
        Flyway flyway = flyway(url, null);
        assertTrue(flyway.migrate().migrationsExecuted > 0);
        assertOriginalHistory(db);
        assertCleanupInstalled(db);
        assertEquals(before, payloadSnapshot(db), "forward cleanup must not rewrite existing template data");
        assertEquals(0,db.queryForObject("SELECT count(*) FROM sales_quote_template_candidates WHERE archived_at IS NOT NULL OR archived_by IS NOT NULL OR archive_reason IS NOT NULL",Integer.class),"new archive metadata does not invent historical destruction");
        assertEquals(0, db.queryForObject("SELECT count(*) FROM attachment_object_outbox", Integer.class));
        assertExactCleanup(db, fixture);
        String after = payloadSnapshot(db);
        assertEquals(0, flyway.migrate().migrationsExecuted);
        assertEquals(after, payloadSnapshot(db));
        flyway.validate();
    }

    @Test
    void v757UpgradeKeepsResetPrivilegesAndCandidateCleanupSparseAndTransactional() throws Exception {
        String url = createDatabase("quote_cleanup_sparse_upgrade");
        flyway(url, "757").migrate();
        JdbcTemplate db = jdbc(url);
        Fixture fixture = seed(db);
        String before = payloadSnapshot(db);
        String metadata = resetMetadata(db);
        // Keep the V757 -> V758 contract exact as unrelated later migrations are added.
        assertEquals(1, flyway(url, "758").migrate().migrationsExecuted);
        assertEquals(metadata, resetMetadata(db), "V758 must preserve reset owner, SECURITY DEFINER, search path and grants");
        assertEquals(before, payloadSnapshot(db), "V758 must preserve stored template data");
        Flyway flyway = flyway(url, null);
        int pendingMigrations = flyway.info().pending().length;
        assertEquals(pendingMigrations, flyway.migrate().migrationsExecuted);
        assertEquals(metadata, resetMetadata(db), "reset owner, SECURITY DEFINER, search path and grants must survive");
        assertEquals(before, payloadSnapshot(db));
        assertOriginalHistory(db);
        assertCleanupInstalled(db);

        try (var connection = DriverManager.getConnection(url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            connection.setAutoCommit(false);
            JdbcTemplate tx = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
            tx.execute("SET LOCAL jit=off");
            tx.execute("SET LOCAL statement_timeout='120s'");
            long originalFile = tx.queryForObject("SELECT pg_relation_filenode('sales_quotes'::regclass)", Long.class);
            var savepoint = connection.setSavepoint();
            assertTrue(tx.queryForObject("SELECT cleared_rows FROM business_data_reset()", Long.class) >= 4);
            assertCleanupResult(tx, fixture);
            assertNotEquals(originalFile, tx.queryForObject("SELECT pg_relation_filenode('sales_quotes'::regclass)", Long.class));
            assertTrue(tx.queryForObject("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required", Integer.class) == 0);
            connection.rollback(savepoint);
            assertEquals(before, payloadSnapshot(tx), "rollback restores candidates and adopted versions");
            assertEquals(0, tx.queryForObject("SELECT count(*) FROM attachment_object_outbox", Integer.class));
            assertTrue(tx.queryForObject("SELECT cleared_rows FROM business_data_reset()", Long.class) >= 4);
            assertCleanupResult(tx, fixture);
            connection.commit();
        }
        assertEquals(0, flyway.migrate().migrationsExecuted);
        assertCleanupResult(db, fixture);
        flyway.validate();
    }

    private static String resetMetadata(JdbcTemplate db) {
        return db.queryForObject("SELECT jsonb_build_array(proowner,prosecdef,proconfig,proacl)::text FROM pg_proc WHERE oid='public.business_data_reset()'::regprocedure", String.class);
    }

    private static String createDatabase(String name) throws Exception {
        var result = POSTGRES.execInContainer("createdb", "-U", POSTGRES.getUsername(), name);
        assertEquals(0, result.getExitCode(), result.getStderr());
        return com.uten.imp.support.MigratedSchemaBaseline.jdbcUrlFor(POSTGRES, name);
    }

    private static Flyway flyway(String url, String target) {
        var configuration = Flyway.configure()
                .dataSource(url, POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").cleanDisabled(true);
        configuration.target(target==null?"777":target); // historical truncate cleanup contract; current permanent reset is covered separately
        return configuration.load();
    }

    private static JdbcTemplate jdbc(String url) {
        return new JdbcTemplate(new DriverManagerDataSource(url, POSTGRES.getUsername(), POSTGRES.getPassword()));
    }

    private static void assertOriginalHistory(JdbcTemplate db) {
        assertEquals(910583300, db.queryForObject("""
                SELECT checksum FROM flyway_schema_history
                WHERE version='747' AND script='V747__sales_quote_template_private_storage.sql' AND success
                """, Integer.class));
    }

    private static void assertCleanupInstalled(JdbcTemplate db) {
        assertEquals(1, db.queryForObject("""
                SELECT count(*) FROM pg_trigger
                WHERE tgrelid='sales_quote_template_candidates'::regclass
                  AND tgname='trg_quote_template_candidates_truncate'
                """, Integer.class));
        assertEquals(1, db.queryForObject("""
                SELECT count(*) FROM flyway_schema_history
                WHERE version='757' AND script='V757__sales_quote_template_candidate_truncate_cleanup.sql' AND success
                """, Integer.class));
        assertEquals(1, db.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE version='758' AND success", Integer.class));
    }

    private record Fixture(String orphanKey, String preservedKey) {}

    private static Fixture seed(JdbcTemplate db) {
        UUID employee = UUID.randomUUID(), actor = UUID.randomUUID(), client = UUID.randomUUID();
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'Migration fixture','其他',id,CURRENT_DATE,'active','regular'
                FROM departments WHERE code='DEPT_FIN'
                """, employee, "MIG-" + employee);
        db.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status)
                VALUES(?,?,?,'test-only',false,'active')
                """, actor, employee, "migration-" + actor);
        db.update("""
                INSERT INTO clients(id,code,name,status,code_sequence,owner_employee_id)
                VALUES(?,?,?,'使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients),?)
                """, client, "MIG-" + client, "Migration fixture", employee);
        String orphan = "orphan-" + UUID.randomUUID(), preserved = "preserved-" + UUID.randomUUID();
        candidate(db, actor, orphan);
        candidate(db, actor, preserved);
        UUID template = UUID.randomUUID();
        db.update("""
                INSERT INTO sales_quote_customer_templates(id,client_id,name,fingerprint,features)
                VALUES(?,?,'Preserved fixture',repeat('a',64),'[]'::jsonb)
                """, template, client);
        db.update("""
                INSERT INTO sales_quote_template_versions(template_id,version,source_name,workbook_bytes,
                    mapping,payload_sha256,captured_by,storage_provider,storage_key,storage_size,storage_sha256)
                VALUES(?,1,'fixture.xlsx',NULL,'{}'::jsonb,repeat('a',64),?,'local',?,10,repeat('a',64))
                """, template, actor, preserved);
        return new Fixture(orphan, preserved);
    }

    private static void candidate(JdbcTemplate db, UUID actor, String key) {
        UUID job = UUID.randomUUID();
        db.update("""
                INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,
                    submitted_by_user,submitted_auth_version)
                VALUES(?,'SALES_DOCUMENT_INTAKE','RUNNING','fixture.xlsx','application/octet-stream','XLSX',
                    10,repeat('a',64),?,1)
                """, job, actor);
        db.update("""
                INSERT INTO sales_quote_template_candidates(job_id,actor_user_id,source_name,fingerprint,
                    workbook_bytes,mapping,features,storage_provider,storage_key,storage_size,storage_sha256)
                VALUES(?,?,'fixture.xlsx',repeat('a',64),NULL,'{}'::jsonb,'[]'::jsonb,'local',?,10,repeat('a',64))
                """, job, actor, key);
    }

    private static String payloadSnapshot(JdbcTemplate db) {
        return db.queryForObject("""
                SELECT jsonb_build_object(
                    'candidates',(SELECT jsonb_agg(to_jsonb(c)-ARRAY['archived_at','archived_by','archive_reason'] ORDER BY job_id) FROM sales_quote_template_candidates c),
                    'versions',(SELECT jsonb_agg(to_jsonb(v) ORDER BY template_id,version) FROM sales_quote_template_versions v)
                )::text
                """, String.class);
    }

    private static void assertExactCleanup(JdbcTemplate db, Fixture fixture) {
        db.execute("TRUNCATE sales_quote_template_candidates");
        assertCleanupResult(db, fixture);
        db.execute("TRUNCATE sales_quote_template_candidates");
        assertEquals(1, db.queryForObject("SELECT count(*) FROM attachment_object_outbox", Integer.class));
    }

    private static void assertCleanupResult(JdbcTemplate db, Fixture fixture) {
        assertEquals(0, db.queryForObject("SELECT count(*) FROM sales_quote_template_candidates", Integer.class));
        assertEquals(1, db.queryForObject("SELECT count(*) FROM sales_quote_template_versions", Integer.class));
        assertEquals(1, db.queryForObject("""
                SELECT count(*) FROM attachment_object_outbox
                WHERE operation='DELETE_FINAL' AND storage_provider='local' AND storage_key=? AND storage_version IS NULL
                """, Integer.class, fixture.orphanKey()));
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM attachment_object_outbox WHERE storage_key=?
                """, Integer.class, fixture.preservedKey()));
        assertEquals(1, db.queryForObject("SELECT count(*) FROM attachment_object_outbox", Integer.class));
    }
}
