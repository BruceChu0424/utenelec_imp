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

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractPermissionSurfacePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_subcontract_permissions")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void migrateThroughV437() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target("437")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void v437CreatesExactActiveCatalogWithoutAnyGrant() throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            assertEquals(1, scalar(statement, """
                    select count(*) from flyway_schema_history
                    where version = '437' and success
                    """));
            assertEquals(7, scalar(statement, """
                    select count(*) from permissions
                    where code in (
                        'subcontract_preparation:view',
                        'subcontract_preparation:start',
                        'subcontract_inquiry:price:view',
                        'subcontract_order:price:view',
                        'subcontract_return:price:view',
                        'subcontract_waste:suggestion:view',
                        'subcontract_report:price:view')
                      and active and assignable
                    """));
            assertEquals(2, scalar(statement, """
                    select count(*)
                    from permission_surface_permissions link
                    join permission_surfaces surface on surface.id = link.surface_id
                    join permissions permission on permission.id = link.permission_id
                    where surface.surface_key = 'subcontract.preparation'
                      and permission.code in (
                          'subcontract_preparation:view',
                          'subcontract_preparation:start')
                    """));
            assertEquals(1, linkCount(statement,
                    "subcontract.order", "subcontract_order:price:view"));
            assertEquals(1, linkCount(statement,
                    "warehouse.subcontract-outbound",
                    "subcontract_material_issue:approve"));
            assertEquals(0, scalar(statement, """
                    select count(*) from (
                        select permission_id from department_permissions
                        union all select permission_id from role_permissions
                        union all select permission_id from user_permission_overrides
                        union all select permission_id from manager_permission_delegations
                    ) grant_row
                    join permissions permission on permission.id = grant_row.permission_id
                    where permission.code in (
                        'subcontract_preparation:view',
                        'subcontract_preparation:start',
                        'subcontract_inquiry:price:view',
                        'subcontract_order:price:view',
                        'subcontract_return:price:view',
                        'subcontract_waste:suggestion:view',
                        'subcontract_report:price:view')
                    """));
            assertEquals(1, scalar(statement, """
                    select count(*) from permissions
                    where code = 'subcontract_outbound:handle'
                      and active = false and assignable = false
                    """));
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
