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
class ManualSubcontractMaterialIssueCreateRetirementPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_retire_manual_issue")
                    .withUsername("uten")
                    .withPassword("uten-test-only");
    private static long authorizationEpochBeforeV441;

    @BeforeAll
    static void migrateWithHistoricalGrant() throws Exception {
        POSTGRES.start();
        flyway("440").migrate();
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            statement.executeUpdate("""
                    insert into role_permissions(role_id, permission_id)
                    select role.id, permission.id
                    from roles role
                    join permissions permission
                      on permission.code = 'subcontract_material_issue:create'
                    where role.code = 'admin'
                    on conflict do nothing
                    """);
            authorizationEpochBeforeV441 = scalar(statement, """
                    select epoch from authorization_state
                    where singleton_id = 1
                    """);
        }
        flyway("441").migrate();
    }

    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void v441HidesManualCreateButKeepsItsHistoricalGrantAndOtherActions()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            assertEquals(1, scalar(statement, """
                    select count(*) from flyway_schema_history
                    where version = '441' and success
                    """));
            assertEquals(1, scalar(statement, """
                    select count(*) from permissions
                    where code = 'subcontract_material_issue:create'
                      and active = false and assignable = false
                    """));
            assertEquals(1, scalar(statement, """
                    select count(*)
                    from role_permissions source
                    join roles role on role.id = source.role_id
                    join permissions permission on permission.id = source.permission_id
                    where role.code = 'admin'
                      and permission.code = 'subcontract_material_issue:create'
                    """));
            assertEquals(0, scalar(statement, """
                    select count(*)
                    from permission_surface_permissions link
                    join permissions permission on permission.id = link.permission_id
                    where permission.code = 'subcontract_material_issue:create'
                      and permission.active = true
                    """));
            assertEquals(5, scalar(statement, """
                    select count(*) from permissions
                    where code in (
                        'subcontract_material_issue:view',
                        'subcontract_material_issue:edit',
                        'subcontract_material_issue:delete',
                        'subcontract_material_issue:approve',
                        'subcontract_material_issue:reverse')
                      and active and assignable
                    """));
            assertTrue(scalar(statement, """
                    select epoch from authorization_state
                    where singleton_id = 1
                    """) > authorizationEpochBeforeV441);
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static long scalar(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }
}
