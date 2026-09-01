package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.FlywayException;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PurchaseCommercialPricePermissionDriftPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_purchase_permission_drift")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

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

    @BeforeAll
    static void migrateThroughV438AndSeedDrift() throws Exception {
        POSTGRES.start();
        flyway("438").migrate();
        UUID permissionId = UUID.randomUUID();
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            statement.executeUpdate("""
                    insert into permissions(
                        id,code,name,module,category,sort_order,action_type,
                        description,active,assignable)
                    values('%s','purchase_order:price:view',
                        '目标库人工占位','采购管理','采购订货',999,
                        'VIEW','drift fixture',false,false)
                    """.formatted(permissionId));
            statement.executeUpdate("""
                    insert into department_permissions(department_id,permission_id)
                    select id,'%s' from departments
                    where coalesce(is_deleted,false)=false
                    order by id limit 1
                    """.formatted(permissionId));
        }
    }

    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void v439RejectsPreExistingGrantedPlaceholderAndRollsBackEverything()
            throws Exception {
        assertThrows(FlywayException.class, () -> flyway("439").migrate());

        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals(0, scalar(statement, """
                    select count(*) from flyway_schema_history
                    where version='439' and success
                    """));
            assertEquals(1, scalar(statement, """
                    select count(*) from permissions
                    where code='purchase_order:price:view'
                      and active=false and assignable=false
                      and name='目标库人工占位'
                    """));
            assertEquals(1, scalar(statement, """
                    select count(*)
                    from department_permissions source
                    join permissions permission on permission.id=source.permission_id
                    where permission.code='purchase_order:price:view'
                    """));
            assertEquals(0, scalar(statement, """
                    select count(*) from permissions
                    where code in (
                        'purchase_return:price:view',
                        'purchase_report:price:view')
                    """));
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static long scalar(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }
}
