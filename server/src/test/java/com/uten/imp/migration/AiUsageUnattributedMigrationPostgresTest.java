package com.uten.imp.migration;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.FlywayException;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Both upgrade entry points preserve raw NULL-owner calls and immutable V815 bytes. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AiUsageUnattributedMigrationPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("usage_v814");

    @BeforeAll static void start() {
        DB.start();
        flyway(DB.getJdbcUrl(), "814", true).migrate();
    }

    @AfterAll static void stop() { DB.stop(); }

    @Test void v814WithUnattributedLogsCrossesImmutableV815WithoutLosingTheirOwnership() throws Exception {
        try (Connection connection = MigratedSchemaBaseline.cloneConnection(DB, "usage_from_814")) {
            String url = connection.getMetaData().getURL();
            JdbcTemplate jdbc = jdbc(url);
            UUID user = UUID.randomUUID();
            addCall(jdbc, user, 10, 5);
            addCall(jdbc, null, 100, 50);
            var before = jdbc.queryForList("SELECT to_jsonb(log)::text FROM public.ai_call_logs log ORDER BY id", String.class);
            // Prove the historical failure first. PostgreSQL rolls back V815;
            // retry uses its original checksum, never repair or modified SQL.
            assertThatThrownBy(() -> flyway(url, "815", false).migrate())
                    .isInstanceOf(FlywayException.class).hasStackTraceContaining("null value in column \"user_id\"");
            assertThat(jdbc.queryForObject("SELECT to_regclass('public.ai_usage_daily') IS NULL", Boolean.class)).isTrue();
            flyway(url, "820", true).migrate();
            verify(jdbc, user, before);
            flyway(url, "820", true).validate();
        }
    }

    @Test void installedV815AlsoUpgradesAndBackfillsSystemCallsWithoutInventingAUser() throws Exception {
        try (Connection connection = MigratedSchemaBaseline.cloneConnection(DB, "usage_from_815")) {
            String url = connection.getMetaData().getURL();
            JdbcTemplate jdbc = jdbc(url);
            UUID user = UUID.randomUUID();
            addCall(jdbc, user, 10, 5);
            flyway(url, "815", true).migrate();
            int checksum = jdbc.queryForObject("SELECT checksum FROM flyway_schema_history WHERE version='815'", Integer.class);
            addCall(jdbc, null, 100, 50);
            var before = jdbc.queryForList("SELECT to_jsonb(log)::text FROM public.ai_call_logs log ORDER BY id", String.class);
            flyway(url, "820", true).migrate();
            verify(jdbc, user, before);
            assertThat(jdbc.queryForObject("SELECT checksum FROM flyway_schema_history WHERE version='815'", Integer.class))
                    .isEqualTo(checksum);
        }
    }

    @Test void failedV815TransactionRollsBackItsConnectionLocalCompatibilityView() throws Exception {
        try (Connection connection = MigratedSchemaBaseline.cloneConnection(DB, "usage_815_rollback")) {
            JdbcTemplate jdbc = jdbc(connection.getMetaData().getURL());
            addCall(jdbc, UUID.randomUUID(), 10, 5);
            addCall(jdbc, null, 100, 50);
            try (var statement = connection.createStatement()) {
                statement.execute("SET search_path = pg_catalog, public, pg_temp");
            }
            connection.setAutoCommit(false);
            var context = org.mockito.Mockito.mock(org.flywaydb.core.api.callback.Context.class);
            var migration = org.mockito.Mockito.mock(org.flywaydb.core.api.MigrationInfo.class);
            org.mockito.Mockito.when(context.getConnection()).thenReturn(connection);
            org.mockito.Mockito.when(context.getMigrationInfo()).thenReturn(migration);
            org.mockito.Mockito.when(migration.getVersion()).thenReturn(org.flywaydb.core.api.MigrationVersion.fromVersion("815"));
            new AppliedMigrationCompatibilityCallback().handle(org.flywaydb.core.api.callback.Event.BEFORE_EACH_MIGRATE, context);
            assertThat(countOn(connection, "SELECT count(*) FROM ai_call_logs")).isEqualTo(1);
            assertThat(countOn(connection, "SELECT count(*) FROM public.ai_call_logs")).isEqualTo(2);
            connection.rollback();
            connection.setAutoCommit(true);
            try (var statement = connection.createStatement(); var rows = statement.executeQuery("SHOW search_path")) {
                rows.next();
                assertThat(rows.getString(1)).isEqualTo("pg_catalog, public, pg_temp");
            }
            assertThat(countOn(connection, "SELECT count(*) FROM ai_call_logs")).isEqualTo(2);
            assertThat(countOn(connection, "SELECT count(*) FROM pg_class WHERE relnamespace=pg_my_temp_schema() AND relname='ai_call_logs'"))
                    .isZero();
        }
    }

    private static long countOn(Connection connection, String sql) throws Exception {
        try (var statement = connection.createStatement(); var rows = statement.executeQuery(sql)) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private static void verify(JdbcTemplate jdbc, UUID user, java.util.List<String> original) {
        assertThat(jdbc.queryForList("SELECT to_jsonb(log)::text FROM public.ai_call_logs log ORDER BY id", String.class))
                .isEqualTo(original);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_usage_daily", Long.class)).isEqualTo(2L);
        assertThat(jdbc.queryForObject("SELECT input_tokens + output_tokens FROM ai_usage_daily WHERE user_id IS NULL", Long.class))
                .isEqualTo(150L);
        assertThat(jdbc.queryForObject("SELECT input_tokens + output_tokens FROM ai_usage_daily WHERE user_id=?", Long.class, user))
                .isEqualTo(15L);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM users WHERE id=?", Long.class, user)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace"
                + " WHERE c.relname='ai_call_logs' AND n.nspname LIKE 'pg_temp_%'", Long.class)).isZero();
    }

    private static void addCall(JdbcTemplate jdbc, UUID user, int input, int output) {
        jdbc.update("""
                INSERT INTO public.ai_call_logs(purpose, provider_name, model, protocol, ok, input_tokens, output_tokens, user_id, latency_ms)
                VALUES ('MIGRATION_USAGE_TEST', 'Test AI', 'test-model', 'OPENAI_CHAT', true, ?, ?, ?, 5)
                """, input, output, user);
    }

    private static JdbcTemplate jdbc(String url) {
        return new JdbcTemplate(new DriverManagerDataSource(url, DB.getUsername(), DB.getPassword()));
    }

    private static Flyway flyway(String url, String target, boolean compatible) {
        var config = Flyway.configure().dataSource(url, DB.getUsername(), DB.getPassword())
                .defaultSchema("public").initSql("SET search_path = pg_catalog, public, pg_temp")
                .locations("classpath:db/migration").target(target).cleanDisabled(true);
        if (compatible) config.callbacks(new AppliedMigrationCompatibilityCallback(), new AuditFreshStartGuardCallback());
        return config.load();
    }
}
