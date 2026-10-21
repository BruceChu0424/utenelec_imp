package com.uten.imp.common.sql;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.sql.DriverManager;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SqlCatalogLiteralPostgresTest {
    private static PostgreSQLContainer postgres;

    @BeforeAll
    static void start() {
        postgres = new PostgreSQLContainer("postgres:16-alpine");
        postgres.start();
    }

    @AfterAll
    static void stop() {
        if (postgres != null) postgres.stop();
    }

    @Test
    void catalogTextRemainsOneValueUnderBothPostgresStringModes() throws Exception {
        List<String> values = List.of("人民币", "USD", "a'b", "a\\b", "\\'", "line\nbreak",
                "'); DROP TABLE catalog_literal_sentinel; --");
        try (var connection = DriverManager.getConnection(
                postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
             var create = connection.prepareStatement("CREATE TEMP TABLE catalog_literal_sentinel(id integer)")) {
            create.execute();
            for (String mode : List.of("on", "off")) {
                try (var config = connection.prepareStatement(
                        "SELECT set_config('standard_conforming_strings', ?, false)")) {
                    config.setString(1, mode);
                    try (var row = config.executeQuery()) {
                        assertThat(row.next()).isTrue();
                        assertThat(row.getString(1)).isEqualTo(mode);
                    }
                }
                for (String value : values) {
                    try (var query = connection.prepareStatement("SELECT " + SqlCatalogLiteral.text(value))) {
                        try (var row = query.executeQuery()) {
                            assertThat(row.next()).isTrue();
                            assertThat(row.getString(1)).isEqualTo(value);
                            assertThat(row.next()).isFalse();
                        }
                    }
                }
            }
            try (var query = connection.prepareStatement("SELECT COUNT(*) FROM catalog_literal_sentinel");
                 var row = query.executeQuery()) {
                assertThat(row.next()).isTrue();
                assertThat(row.getInt(1)).isZero();
            }
        }
    }

    @Test
    void unsupportedNulCatalogValuesFailBeforeSqlExecution() {
        assertThatThrownBy(() -> SqlCatalogLiteral.text("bad\0catalog"))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("NUL");
    }
}
