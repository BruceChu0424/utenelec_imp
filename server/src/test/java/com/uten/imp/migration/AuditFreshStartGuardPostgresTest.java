package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.FlywayException;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.DriverManager;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

@Testcontainers(disabledWithoutDocker = true)
class AuditFreshStartGuardPostgresTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");

    @Test
    void freshChainIsAllowedExistingV424IsBlockedAndExistingV425IsNotMisblocked()
            throws Exception {
        String fresh = database("fresh");
        guarded(fresh, null).migrate();
        assertEquals(1, scalar(fresh,
                "SELECT count(*) FROM flyway_schema_history WHERE version='425' AND success"));

        String upgrade = database("upgrade");
        unguarded(upgrade, "424").migrate();
        try (var connection = DriverManager.getConnection(
                jdbcUrl(upgrade), POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.createStatement()) {
            statement.execute("INSERT INTO audit_log(action,result,event_source) "
                    + "VALUES ('guard_probe','success','business')");
        }
        assertThrows(FlywayException.class, () -> guarded(upgrade, null).migrate());
        assertEquals(0, scalar(upgrade,
                "SELECT count(*) FROM flyway_schema_history WHERE version='425'"));
        assertEquals(1, scalar(upgrade,
                "SELECT count(*) FROM audit_log WHERE action='guard_probe'"));

        String already = database("already");
        unguarded(already, "425").migrate();
        guarded(already, null).migrate();
        assertEquals(1, scalar(already,
                "SELECT count(*) FROM flyway_schema_history WHERE version='426' AND success"));
    }

    private Flyway guarded(String schema, String target) {
        var configuration = base(schema);
        if (target != null) {
            configuration.target(target);
        }
        return configuration.callbacks(
                new AppliedMigrationCompatibilityCallback(),
                new AuditFreshStartGuardCallback()).load();
    }

    private Flyway unguarded(String schema, String target) {
        var configuration = base(schema).target(target);
        return configuration.callbacks(new AppliedMigrationCompatibilityCallback()).load();
    }

    private org.flywaydb.core.api.configuration.FluentConfiguration base(String schema) {
        return Flyway.configure()
                .dataSource(
                        jdbcUrl(schema),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .cleanDisabled(true);
    }

    private int scalar(String schema, String sql) throws Exception {
        try (var connection = DriverManager.getConnection(
                jdbcUrl(schema), POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.createStatement()) {
            try (var rows = statement.executeQuery(sql)) {
                rows.next();
                return rows.getInt(1);
            }
        }
    }

    private String database(String prefix) throws Exception {
        String name = prefix + "_" + UUID.randomUUID().toString().replace("-", "");
        try (var connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.createStatement()) {
            connection.setAutoCommit(true);
            statement.execute("CREATE DATABASE \"" + name + "\"");
        }
        return name;
    }

    private String jdbcUrl(String database) {
        String url = POSTGRES.getJdbcUrl();
        int query = url.indexOf('?');
        String suffix = query < 0 ? "" : url.substring(query);
        String base = query < 0 ? url : url.substring(0, query);
        return base.substring(0, base.lastIndexOf('/') + 1) + database + suffix;
    }
}
