package com.uten.imp.migration;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.DriverManager;
import java.sql.SQLException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.slf4j.LoggerFactory;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Migration-only NOTICE filtering must never hide a genuine SQL warning or error. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FlywayConnectionNoticePolicyPostgresTest {
    @TempDir Path migrations;

    @Test
    void migrationConnectionFiltersNoticesButRetainsWarningsErrorsAndOrdinaryConnectionDefaults() throws Exception {
        String initSql = com.uten.imp.testsupport.TestFlyway.configure().getInitSql();
        assertThat(initSql).isEqualTo("SET client_min_messages = WARNING");
        Files.writeString(migrations.resolve("V1__notice_policy.sql"), """
                DO $$ BEGIN
                  RAISE NOTICE 'startup-policy-notice';
                  RAISE WARNING 'startup-policy-real-warning';
                END $$;
                CREATE TABLE policy_probe(id integer, migrated_by text);
                CREATE TABLE IF NOT EXISTS policy_probe(id integer);
                DROP TABLE IF EXISTS policy_probe_missing;
                CREATE TEMP TABLE policy_identifier_notice_really_long_name_for_the_postgres_sixty_three_byte_limit_probe(id integer);
                INSERT INTO policy_probe VALUES (1, current_setting('application_name'));
                """);
        Logger logger = (Logger) LoggerFactory.getLogger("org.flywaydb.core.internal.sqlscript.DefaultSqlScriptExecutor");
        var events = new ListAppender<ILoggingEvent>();
        events.start();
        logger.addAppender(events);
        try (var postgres = new PostgreSQLContainer("postgres:16-alpine")) {
            postgres.start();
            com.uten.imp.testsupport.TestFlyway.configureWithInitSql("SET application_name = 'migration-policy-fixture'")
                    .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                    .locations("filesystem:" + migrations).load().migrate();
            assertThat(events.list.stream().map(ILoggingEvent::getFormattedMessage).toList())
                    .noneMatch(message -> message.contains("startup-policy-notice")
                            || message.contains("already exists") || message.contains("does not exist")
                            || message.contains("will be truncated"));
            assertThat(events.list).anySatisfy(event -> {
                assertThat(event.getLevel()).isEqualTo(Level.WARN);
                assertThat(event.getFormattedMessage()).contains("startup-policy-real-warning");
            });
            try (var connection = DriverManager.getConnection(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
                 var statement = connection.createStatement()) {
                try (var result = statement.executeQuery("SHOW client_min_messages")) {
                    assertThat(result.next()).isTrue();
                    assertThat(result.getString(1)).isEqualTo("notice");
                }
                try (var result = statement.executeQuery("SELECT migrated_by FROM policy_probe WHERE id=1")) {
                    assertThat(result.next()).isTrue();
                    assertThat(result.getString(1)).isEqualTo("migration-policy-fixture");
                }
            }
            Files.writeString(migrations.resolve("V2__real_error.sql"),
                    "DO $$ BEGIN RAISE EXCEPTION 'startup-policy-real-error'; END $$;");
            assertThatThrownBy(() -> com.uten.imp.testsupport.TestFlyway.configure()
                    .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                    .locations("filesystem:" + migrations).load().migrate())
                    .isInstanceOf(org.flywaydb.core.api.FlywayException.class)
                    .hasMessageContaining("startup-policy-real-error").hasRootCauseInstanceOf(SQLException.class);
        } finally {
            logger.detachAppender(events);
            events.stop();
        }
    }
}
