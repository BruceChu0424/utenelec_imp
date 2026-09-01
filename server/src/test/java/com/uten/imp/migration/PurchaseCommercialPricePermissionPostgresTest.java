package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PurchaseCommercialPricePermissionPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_purchase_permissions")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void migrateThroughV439() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target("439")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void v439CreatesThreeExactPermissionsWithoutCopyingReceiptGrants()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            assertEquals(1, scalar(statement, """
                    select count(*) from flyway_schema_history
                    where version = '439' and success
                    """));
            assertEquals(3, scalar(statement, """
                    select count(*) from permissions
                    where code in (
                        'purchase_order:price:view',
                        'purchase_return:price:view',
                        'purchase_report:price:view')
                      and active and assignable and action_type = 'VIEW'
                    """));
            assertEquals(1, linkCount(statement,
                    "purchase.order", "purchase_order:price:view"));
            assertEquals(1, linkCount(statement,
                    "purchase.return", "purchase_return:price:view"));
            assertEquals(1, linkCount(statement,
                    "purchase.report", "purchase_report:price:view"));
            assertEquals(0, scalar(statement, """
                    select count(*) from (
                        select permission_id from department_permissions
                        union all select permission_id from role_permissions
                        union all select permission_id from user_permission_overrides
                        union all select permission_id from manager_permission_delegations
                    ) source
                    join permissions permission on permission.id = source.permission_id
                    where permission.code in (
                        'purchase_order:price:view',
                        'purchase_return:price:view',
                        'purchase_report:price:view')
                    """));
            assertTrue(scalar(statement, """
                    select count(*)
                    from department_permissions source
                    join permissions permission on permission.id = source.permission_id
                    where permission.code = 'purchase_receipt:price:view'
                    """) > 0);
        }
    }

    private static long linkCount(
            Statement statement,
            String surfaceKey,
            String permissionCode) throws Exception {
        return scalar(statement, """
                select count(*)
                from permission_surface_permissions link
                join permission_surfaces surface on surface.id = link.surface_id
                join permissions permission on permission.id = link.permission_id
                where surface.surface_key = '%s'
                  and permission.code = '%s'
                """.formatted(surfaceKey, permissionCode));
    }

    private static long scalar(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }
}
