package com.uten.imp.migration;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.DriverManager;
import java.sql.SQLException;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.config.YamlPropertiesFactoryBean;
import org.springframework.core.io.ClassPathResource;
import org.testcontainers.containers.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Migration-only NOTICE filtering must never hide a genuine SQL warning or error. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FlywayConnectionNoticePolicyPostgresTest {
    @TempDir Path migrations;

    @Test
    void migrationConnectionFiltersNoticesButRetainsWarningsErrorsAndOrdinaryConnectionDefaults() throws Exception {
        var yaml = new YamlPropertiesFactoryBean();
        yaml.setResources(new ClassPathResource("application.yml"));
        var properties = yaml.getObject();
        assertThat(properties).isNotNull();
        String initSql = properties.getProperty("spring.flyway.init-sqls[0]");
        assertThat(initSql).isEqualTo("SET client_min_messages = WARNING");
        Files.writeString(migrations.resolve("V1__notice_policy.sql"), """
                DO $$ BEGIN
                  RAISE NOTICE 'startup-policy-notice';
                  RAISE WARNING 'startup-policy-real-warning';
                END $$;
                CREATE TABLE policy_probe(id integer);
                """);
        Logger logger = (Logger) LoggerFactory.getLogger("org.flywaydb.core.internal.sqlscript.DefaultSqlScriptExecutor");
        var events = new ListAppender<ILoggingEvent>();
        events.start();
        logger.addAppender(events);
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            Flyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                    .locations("filesystem:" + migrations).initSql(initSql).load().migrate();
            assertThat(events.list.stream().map(ILoggingEvent::getFormattedMessage).toList())
                    .noneMatch(message -> message.contains("startup-policy-notice"));
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
                statement.execute(initSql);
                assertThatThrownBy(() -> statement.execute("DO $$ BEGIN RAISE EXCEPTION 'startup-policy-real-error'; END $$"))
                        .isInstanceOf(SQLException.class).hasMessageContaining("startup-policy-real-error");
            }
        } finally {
            logger.detachAppender(events);
            events.stop();
        }
    }
}
