package com.uten.imp.features.finance.receivables;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.Map;

/** Dedicated synthetic fixture only. A private identity marker prevents targeting an ERP database. */
final class SalesPressureDatabase {
    private static final PostgreSQLContainer<?> EPHEMERAL = new PostgreSQLContainer<>("postgres:16-alpine");
    private static String url;
    private static String username;
    private static String password;
    private static boolean persistent;

    private SalesPressureDatabase() {}

    static void configure(DynamicPropertyRegistry registry) {
        String configured = System.getProperty("uten.sales.pressure.databaseConfig", "");
        try {
            if (configured.isBlank()) {
                EPHEMERAL.start();
                url = EPHEMERAL.getJdbcUrl(); username = EPHEMERAL.getUsername(); password = EPHEMERAL.getPassword();
            } else {
                Map<?, ?> config = new ObjectMapper().readValue(Path.of(configured).toFile(), Map.class);
                String host = (String) config.get("host");
                String database = (String) config.get("database");
                int port = ((Number) config.get("port")).intValue();
                username = (String) config.get("user"); password = (String) config.get("password");
                String token = (String) config.get("identityToken");
                if (!"127.0.0.1".equals(host) || !"pressure_runner".equals(username)
                        || database == null || !database.matches("uten_pressure_[a-z0-9_]+")
                        || token == null || !token.matches("[a-f0-9]{64}") || port < 1024 || port > 65535) {
                    throw new IllegalArgumentException("Only an explicitly identified loopback synthetic pressure database is allowed");
                }
                url = "jdbc:postgresql://127.0.0.1:" + port + "/" + database;
                try (Connection connection = connect(); var statement = connection.prepareStatement(
                        "SELECT identity_token, purpose FROM audit_pressure.database_identity WHERE singleton=TRUE")) {
                    try (var result = statement.executeQuery()) {
                        if (!result.next() || !token.equals(result.getString(1))
                                || !"synthetic-sales-money-pressure".equals(result.getString(2)) || result.next()) {
                            throw new IllegalStateException("Synthetic pressure database identity mismatch");
                        }
                    }
                }
                persistent = true;
            }
        } catch (Exception failure) {
            throw new IllegalStateException("Unable to verify isolated pressure database; no fixture writes started", failure);
        }
        registry.add("spring.datasource.url", () -> url);
        registry.add("spring.datasource.username", () -> username);
        registry.add("spring.datasource.password", () -> password);
    }

    static Connection connect() throws java.sql.SQLException { return DriverManager.getConnection(url, username, password); }
    static boolean persistent() { return persistent; }
    static String image() { return "postgres:16-alpine"; }
}
