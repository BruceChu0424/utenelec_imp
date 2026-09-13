package com.uten.imp.config;

import com.zaxxer.hikari.HikariDataSource;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.config.YamlPropertiesFactoryBean;
import org.springframework.core.env.MapPropertySource;
import org.springframework.core.env.MutablePropertySources;
import org.springframework.core.env.PropertiesPropertySource;
import org.springframework.core.env.PropertySourcesPropertyResolver;
import org.springframework.core.io.ClassPathResource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Verify the actual application YAML against PostgreSQL, without modifying its global setting. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PostgresJitPolicyPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("jit_policy").withUsername("test").withPassword(UUID.randomUUID().toString());

    @BeforeAll static void start() { POSTGRES.start(); }
    @AfterAll static void stop() { POSTGRES.stop(); }

    private static String initSql(Map<String, Object> overrides) {
        var yaml = new YamlPropertiesFactoryBean();
        yaml.setResources(new ClassPathResource("application.yml"));
        var sources = new MutablePropertySources();
        sources.addFirst(new MapPropertySource("overrides", overrides));
        sources.addLast(new PropertiesPropertySource("application", yaml.getObject()));
        return new PropertySourcesPropertyResolver(sources)
                .getRequiredProperty("spring.datasource.hikari.connection-init-sql");
    }

    private static HikariDataSource pool(String sql) {
        var pool = new HikariDataSource();
        pool.setJdbcUrl(POSTGRES.getJdbcUrl());
        pool.setUsername(POSTGRES.getUsername());
        pool.setPassword(POSTGRES.getPassword());
        pool.setMaximumPoolSize(1);
        pool.setMinimumIdle(1);
        pool.setConnectionInitSql(sql);
        return pool;
    }

    private static String jit(Connection connection) throws Exception {
        try (var statement = connection.createStatement(); var rows = statement.executeQuery("SHOW jit")) {
            rows.next();
            return rows.getString(1);
        }
    }

    @Test
    void applicationDefaultIsOffAndOtherDatabaseConnectionsRemainUnchanged() throws Exception {
        String baseline;
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            baseline = jit(connection);
        }
        try (var pool = pool(initSql(Map.of()))) {
            try (var connection = pool.getConnection()) { assertThat(jit(connection)).isEqualTo("off"); }
            // Hikari returns the same configured connection for the next request.
            try (var connection = pool.getConnection()) { assertThat(jit(connection)).isEqualTo("off"); }
        }
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            assertThat(jit(connection)).isEqualTo(baseline);
        }
    }

    @Test
    void explicitDeploymentOverrideCanEnableJit() throws Exception {
        try (var pool = pool(initSql(Map.of("UTEN_DB_JIT", "true"))); var connection = pool.getConnection()) {
            assertThat(jit(connection)).isEqualTo("on");
        }
    }
}
