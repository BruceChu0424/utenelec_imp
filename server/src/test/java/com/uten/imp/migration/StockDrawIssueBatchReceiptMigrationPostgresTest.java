package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Forward-only receipt creation preserves existing discovery history and the reset/audit contracts. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class StockDrawIssueBatchReceiptMigrationPostgresTest {
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID ACTOR = UUID.randomUUID(), EMPLOYEE = UUID.randomUUID(), LEGACY = UUID.randomUUID();
    private static JdbcTemplate db;
    private static TransactionTemplate transactions;
    private static String legacyBefore;

    @BeforeAll static void start() {
        DATABASE.start();
        migrate("759");
        var source = new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword());
        db = new JdbcTemplate(source);
        transactions = new TransactionTemplate(new DataSourceTransactionManager(source));
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,'父回执迁移夹具','其他',(SELECT id FROM departments WHERE code='SUB_WH'),current_date,'active','regular')
                """, EMPLOYEE, "receipt-" + EMPLOYEE);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',FALSE)",
                ACTOR, EMPLOYEE, "receipt-" + ACTOR);
        db.update("""
                INSERT INTO production_draw_issue_batches(id,actor_user_id,actor_employee_id,idempotency_key,
                    request_hash,request_snapshot,response_snapshot,document_ids)
                VALUES(?,?,?,'legacy-discovery-receipt',repeat('a',64),'{"original":true}'::jsonb,
                    '{"issuedCount":1}'::jsonb,ARRAY[gen_random_uuid()])
                """, LEGACY, ACTOR, EMPLOYEE);
        legacyBefore = legacySnapshot();
        migrate("771");
    }

    @AfterAll static void stop() { DATABASE.stop(); }

    @Test void forwardMigrationPreservesOldReceiptsAndDoesNotInventParents() {
        assertEquals(legacyBefore, legacySnapshot());
        assertEquals(0, db.queryForObject("SELECT count(*) FROM stock_draw_issue_batches", Integer.class));
        assertEquals("YES", db.queryForObject("SELECT is_nullable FROM information_schema.columns WHERE table_name='stock_draw_issue_batches' AND column_name='actor_employee_id'", String.class));
        assertEquals("NO", db.queryForObject("SELECT is_nullable FROM information_schema.columns WHERE table_name='stock_draw_issue_batches' AND column_name='actor_user_id'", String.class));
        assertEquals(2, db.queryForObject("""
                SELECT count(*) FROM pg_trigger WHERE tgrelid='stock_draw_issue_batches'::regclass
                AND tgfoid='fn_audit()'::regprocedure AND tgenabled='A'
                """, Integer.class));
    }

    @Test void nullableEmployeeStillRequiresRealActorAndAppendOnlyReceiptAndAudit() {
        transactions.executeWithoutResult(status -> {
            bindActor();
            UUID id = insertReceipt("nullable-employee");
            assertNull(db.queryForObject("SELECT actor_employee_id FROM stock_draw_issue_batches WHERE id=?", UUID.class, id));
            assertEquals(1, db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='stock_draw_issue_batches' AND target_id=? AND actor_id=? AND action='insert'",
                    Integer.class, id.toString(), ACTOR));
            status.setRollbackOnly();
        });
        assertThrows(DataAccessException.class, () -> db.update("""
                INSERT INTO stock_draw_issue_batches(actor_user_id,idempotency_key,request_hash,request_snapshot,response_snapshot,document_ids)
                VALUES(NULL,'no-real-actor',repeat('a',64),'{}','{}',ARRAY[gen_random_uuid()])
                """));
        transactions.executeWithoutResult(status -> {
            UUID id = insertReceipt("immutable-delete");
            Object savepoint = status.createSavepoint();
            assertThrows(DataAccessException.class, () -> db.update("DELETE FROM stock_draw_issue_batches WHERE id=?", id));
            status.rollbackToSavepoint(savepoint);
            assertEquals(1, db.queryForObject("SELECT count(*) FROM stock_draw_issue_batches WHERE id=?", Integer.class, id));
            status.setRollbackOnly();
        });
    }

    @Test void fullBusinessResetClearsReceiptButPreservesItsAuditAndUser() {
        transactions.executeWithoutResult(status -> {
            bindActor();
            UUID id = insertReceipt("reset-classified");
            db.queryForMap("SELECT * FROM business_data_reset()");
            assertEquals(0, db.queryForObject("SELECT count(*) FROM stock_draw_issue_batches", Integer.class));
            assertEquals(1, db.queryForObject("SELECT count(*) FROM users WHERE id=?", Integer.class, ACTOR));
            assertEquals(1, db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='stock_draw_issue_batches' AND target_id=?", Integer.class, id.toString()));
            status.setRollbackOnly();
        });
        assertEquals(legacyBefore, legacySnapshot(), "the reset probe itself rolls back and leaves the upgrade sentinel intact");
    }

    private static void migrate(String target) {
        Flyway.configure().dataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword())
                .locations("classpath:db/migration").target(target).load().migrate();
    }

    private static String legacySnapshot() {
        return db.queryForObject("SELECT to_jsonb(receipt)::text FROM production_draw_issue_batches receipt WHERE id=?", String.class, LEGACY);
    }

    private void bindActor() {
        db.queryForObject("SELECT set_config('app.actor_id',?,true)", String.class, ACTOR.toString());
    }

    private UUID insertReceipt(String key) {
        return db.queryForObject("""
                INSERT INTO stock_draw_issue_batches(actor_user_id,idempotency_key,request_hash,request_snapshot,response_snapshot,document_ids)
                VALUES(?,?,repeat('a',64),'{"reason":null}'::jsonb,'{"skippedCount":1}'::jsonb,ARRAY[gen_random_uuid()])
                RETURNING id
                """, UUID.class, ACTOR, key);
    }
}
