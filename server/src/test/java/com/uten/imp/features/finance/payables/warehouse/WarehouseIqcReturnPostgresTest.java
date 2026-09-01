package com.uten.imp.features.finance.payables.warehouse;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import static org.junit.jupiter.api.Assertions.assertEquals;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseIqcReturnPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    private static JdbcTemplate jdbc;

    @BeforeAll
    static void migrateCurrentHead() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword()));
    }

    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void physicalProjectionParsesAndPermissionMetadataIsInstalled() {
        String projection = WarehouseIqcReturnProjectionService.selectSql()
                + WarehouseIqcReturnProjectionService.fromSql()
                + " WHERE FALSE";
        assertEquals(0, jdbc.queryForList(projection).size());

        assertEquals(1, jdbc.queryForObject("""
                SELECT count(*)
                FROM permission_surfaces surface
                JOIN permission_surface_permissions link
                  ON link.surface_id=surface.id
                JOIN permissions permission
                  ON permission.id=link.permission_id
                WHERE surface.surface_key='warehouse.iqc-return'
                  AND permission.code='warehouse_iqc_return:view'
                """, Integer.class));
        assertEquals(1, jdbc.queryForObject("""
                SELECT count(*)
                FROM permission_surfaces surface
                JOIN permission_surface_permissions link
                  ON link.surface_id=surface.id
                JOIN permissions permission
                  ON permission.id=link.permission_id
                WHERE surface.surface_key='warehouse.iqc-return'
                  AND permission.code='procurement_iqc_rejection:record_return'
                """, Integer.class));
        assertEquals(1, jdbc.queryForObject("""
                SELECT count(*)
                FROM permissions
                WHERE code='procurement_iqc_rejection:amount:view'
                  AND sensitivity='SENSITIVE_COMMERCIAL'
                  AND bulk_assignable=FALSE
                """, Integer.class));
    }
}
