package com.uten.imp.migration;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.testsupport.TestFlyway;
import org.flywaydb.core.api.exception.FlywayValidateException;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.file.Path;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Both upgrade paths own isolated clones; no development or production database is used. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MasterRecordCaptureForwardMigrationPostgresTest {
    private static final PostgreSQLContainer TEMPLATE = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("master_record_898_template");
    private static final String MIGRATIONS = "filesystem:" + Path.of("src/main/resources/db/migration").toAbsolutePath();

    @BeforeAll static void start() {
        TEMPLATE.start();
        migrate(TEMPLATE.getJdbcUrl(), "898");
    }

    @AfterAll static void stop() { TEMPLATE.stop(); }

    @Test void existingApplied898AndRecordedFactsSurviveTheForwardOnlyFunctionReplacement() throws Exception {
        try (var ignored = MigratedSchemaBaseline.cloneConnection(TEMPLATE, "master_record_899_nonempty")) {
            String url = MigratedSchemaBaseline.jdbcUrlFor(TEMPLATE, "master_record_899_nonempty");
            JdbcTemplate db = database(url);
            UUID color = UUID.randomUUID();
            db.update("INSERT INTO colors(id,code,name) VALUES(?,?,'retained before V899')", color, "V899-" + color);
            Long head = db.queryForObject("SELECT max(id) FROM master_record_versions", Long.class);
            String originalFacts = facts(db, head);
            Long originalFunction = db.queryForObject("""
                    SELECT tgfoid::bigint FROM pg_trigger WHERE tgrelid='colors'::regclass
                      AND tgname='trg_capture_master_record_version'
                    """, Long.class);
            assertEquals(-1460826661, checksum(db, "898"));

            migrate(url, "899");
            validate(url);

            assertEquals(-1460826661, checksum(db, "898"));
            assertEquals(-2044567029, checksum(db, "899"));
            assertEquals(originalFacts, facts(db, head), "forward migration cannot rewrite retained history");
            assertEquals(originalFunction, db.queryForObject("""
                    SELECT tgfoid::bigint FROM pg_trigger WHERE tgrelid='colors'::regclass
                      AND tgname='trg_capture_master_record_version'
                    """, Long.class), "CREATE OR REPLACE must preserve the original trigger attachment");
            requireNewFunction(db);
            long before = db.queryForObject("SELECT count(*) FROM master_record_versions WHERE record_id=?", Long.class, color);
            db.update("UPDATE colors SET name='recorded after V899' WHERE id=?", color);
            assertEquals(before + 1, db.queryForObject("SELECT count(*) FROM master_record_versions WHERE record_id=?", Long.class, color));
            assertEquals(originalFacts, facts(db, head));
        }
    }

    @Test void freshEmptyInstallationRunsOriginal898Then899WithoutInventingApplicationHistory() throws Exception {
        try (var ignored = MigratedSchemaBaseline.cloneConnection(TEMPLATE, "master_record_899_fresh")) {
            String url = MigratedSchemaBaseline.jdbcUrlFor(TEMPLATE, "master_record_899_fresh");
            JdbcTemplate db = database(url);
            long historyBefore = db.queryForObject("SELECT count(*) FROM master_record_versions", Long.class);
            migrate(url, "899");
            validate(url);
            assertEquals(-1460826661, checksum(db, "898"));
            assertEquals(-2044567029, checksum(db, "899"));
            assertEquals(historyBefore, db.queryForObject("SELECT count(*) FROM master_record_versions", Long.class));
            requireNewFunction(db);
        }
    }

    @Test void validatingThe899BoundaryStillRejectsAnAlteredAppliedChecksum() throws Exception {
        try (var ignored = MigratedSchemaBaseline.cloneConnection(TEMPLATE, "master_record_899_checksum")) {
            String url = MigratedSchemaBaseline.jdbcUrlFor(TEMPLATE, "master_record_899_checksum");
            JdbcTemplate db = database(url);
            migrate(url, "899");
            assertEquals(1, db.update("UPDATE flyway_schema_history SET checksum=checksum+1 WHERE version='898'"));
            assertThrows(FlywayValidateException.class, () -> validate(url),
                    "The targeted upgrade boundary must still validate every already applied migration");
        }
    }

    private static void requireNewFunction(JdbcTemplate db) {
        String function = db.queryForObject("SELECT pg_get_functiondef('fn_capture_master_record_version()'::regprocedure)", String.class);
        assertNotNull(function);
        assertTrue(function.contains("app.master_code_audit_stage"));
        assertTrue(function.contains("Final master identifier lacks frozen numbering evidence"));
        assertTrue(function.contains("WHEN 'master_goods' THEN SELECT category_id"));
    }

    private static String facts(JdbcTemplate db, long head) {
        return db.queryForObject("SELECT jsonb_agg(to_jsonb(fact) ORDER BY id)::text FROM master_record_versions fact WHERE id<=?", String.class, head);
    }

    private static int checksum(JdbcTemplate db, String version) {
        return db.queryForObject("SELECT checksum FROM flyway_schema_history WHERE version=? AND success", Integer.class, version);
    }

    private static JdbcTemplate database(String url) {
        return new JdbcTemplate(new DriverManagerDataSource(url, TEMPLATE.getUsername(), TEMPLATE.getPassword()));
    }

    private static void migrate(String url, String target) {
        TestFlyway.configure().dataSource(url, TEMPLATE.getUsername(), TEMPLATE.getPassword())
                .locations(MIGRATIONS).target(target).load().migrate();
    }

    private static void validate(String url) {
        assertEquals(899, database(url).queryForObject("SELECT max(version::integer) FROM flyway_schema_history", Integer.class));
        // This regression stops at V899; later forward migrations deliberately remain pending.
        TestFlyway.configure().dataSource(url, TEMPLATE.getUsername(), TEMPLATE.getPassword())
                .locations(MIGRATIONS).target("899").load().validate();
    }
}
