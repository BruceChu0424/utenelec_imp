package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;
import java.util.Arrays;

import static org.assertj.core.api.Assertions.assertThat;

/** The forward index must preserve messages and keep stopped-event counts off successful history. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessOutboxDeadLetterMigrationPostgresTest {
    @Test
    void upgradingKeepsAllEventsAndIndexesOnlyStoppedRetries() {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            // Use the real compiled predecessor, preserving every applied checksum
            // including newly merged parallel migrations, then prove exactly
            // this index migration applies.
            var indexVersion = MigrationVersion.fromVersion("769");
            var predecessor = Arrays.stream(flyway(postgres, "769").info().all())
                    .map(info -> info.getVersion())
                    .filter(version -> version != null && version.compareTo(indexVersion) < 0)
                    .max(MigrationVersion::compareTo).orElseThrow();
            flyway(postgres, predecessor.toString()).migrate();
            var db = new JdbcTemplate(new DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            db.execute("""
                    INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status,attempts)
                    SELECT gen_random_uuid(),'INDEX_REHEARSAL','TEST','index-rehearsal-'||n,
                        CASE WHEN n=10001 THEN 2 WHEN n=10002 THEN 0 ELSE 1 END,
                        CASE WHEN n=10001 THEN 8 ELSE 0 END
                    FROM generate_series(1,10002) n
                    """);
            List<String> history = history(db, predecessor.toString());
            List<String> unresolved = unresolved(db);
            int total = db.queryForObject("SELECT count(*) FROM business_outbox", Integer.class);

            assertThat(flyway(postgres, "769").migrate().migrationsExecuted).isEqualTo(1);
            assertThat(history(db, predecessor.toString())).isEqualTo(history);
            assertThat(unresolved(db)).isEqualTo(unresolved);
            assertThat(db.queryForObject("SELECT count(*) FROM business_outbox", Integer.class)).isEqualTo(total);
            assertThat(db.queryForObject("SELECT count(*) FROM business_outbox WHERE status=2", Integer.class)).isEqualTo(1);
            assertThat(db.queryForObject("SELECT count(*) FROM business_outbox WHERE status=0", Integer.class)).isEqualTo(1);
            assertThat(db.queryForObject("""
                    SELECT pg_get_expr(indpred,indrelid) FROM pg_index
                    WHERE indexrelid='idx_business_outbox_dead_letter'::regclass
                    """, String.class)).contains("status = 2");
            db.execute("ANALYZE business_outbox");
            assertThat(String.join("\n", db.queryForList(
                    "EXPLAIN (COSTS OFF) SELECT count(*) FROM business_outbox WHERE status=2", String.class)))
                    .contains("idx_business_outbox_dead_letter");
            assertThat(flyway(postgres, "769").migrate().migrationsExecuted).isZero();
        }
    }

    private static List<String> history(JdbcTemplate db, String predecessor) {
        return db.queryForList("""
                SELECT version||':'||checksum FROM flyway_schema_history
                WHERE success AND version::integer<=? ORDER BY installed_rank
                """, String.class, Integer.parseInt(predecessor));
    }

    private static List<String> unresolved(JdbcTemplate db) {
        return db.queryForList("""
                SELECT id::text||':'||dedupe_key||':'||status||':'||attempts
                FROM business_outbox WHERE status IN (0,2) ORDER BY id
                """, String.class);
    }

    private static Flyway flyway(PostgreSQLContainer<?> postgres, String target) {
        return Flyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("classpath:db/migration").target(target)
                .initSql("SET client_min_messages = WARNING").load();
    }
}
