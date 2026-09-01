package com.uten.imp.migration;

import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceCatalogRepository;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PermissionSurfaceCatalogPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

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
    }

    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void migrationSeedsStableSurfacesAndExactSplitCodeLinks()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            long surfaceCount = scalarLong(
                    statement, "select count(*) from permission_surfaces");
            assertTrue(surfaceCount >= 86);
            assertEquals(surfaceCount, scalarLong(statement,
                    "select count(distinct id) from permission_surfaces"));
            assertEquals(
                    "32800000-0000-4000-8000-000000000001",
                    scalarText(statement, """
                            select id::text
                            from permission_surfaces
                            where surface_key = 'basic.goods'
                            """));

            assertEquals(1, linkCount(
                    statement, "basic.goods", "goods:create"));
            assertEquals(1, linkCount(
                    statement, "basic.goods", "material_category:move"));
            assertEquals(1, linkCount(
                    statement, "basic.goods", "stock:view"));
            assertEquals(0, linkCount(
                    statement, "basic.goods", "mould:view"));

            assertEquals(1, linkCount(
                    statement, "org.department", "department:create"));
            assertEquals(1, linkCount(
                    statement, "org.department", "department:move"));
            assertEquals(1, linkCount(
                    statement, "org.department", "department:manager_assign"));
            assertEquals(1, linkCount(
                    statement, "org.department", "position:delete"));
            assertEquals(1, linkCount(
                    statement, "org.employee", "attachment:download"));
            assertEquals(0, linkCount(
                    statement, "org.employee", "attachment:reconcile:view"));
            assertEquals(1, linkCount(
                    statement,
                    "basic.payment-style",
                    "settlement_method:create"));
            assertEquals(1, linkCount(
                    statement,
                    "purchase.arrival-exception",
                    "supplier_return_task:complete"));
            assertEquals(1, linkCount(
                    statement, "purchase.hub", "supplier_return_task:view"));
            assertEquals(0, linkCount(
                    statement, "purchase.hub", "supplier_return_task:complete"));
            assertEquals(1, linkCount(
                    statement, "hr.visitor-security", "visitor:verify"));
            assertEquals(16, scalarLong(statement, """
                    select count(*)
                    from permission_surface_permissions link
                    join permission_surfaces surface
                      on surface.id = link.surface_id
                    join permissions permission
                      on permission.id = link.permission_id
                    where surface.surface_key = 'production.plan'
                      and (
                          permission.code like 'production_execution:%'
                          or permission.code like 'production_mrp:%'
                          or permission.code like 'production_planning_package:%'
                          or permission.code like 'production_material:%'
                      )
                    """));
            assertEquals(1, linkCount(
                    statement, "production.plan", "production_execution:dispatch"));
            assertEquals(1, linkCount(
                    statement, "production.plan", "production_material:close"));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from permissions
                    where code = 'production:view'
                      and active = false
                      and assignable = false
                    """));
            assertEquals(0, linkCount(
                    statement, "production.plan", "production:view"));
            assertEquals(0, linkCount(
                    statement, "production.hub", "production:view"));
            assertEquals(1, linkCount(
                    statement, "subcontract.preparation",
                    "subcontract_preparation:view"));
            assertEquals(1, linkCount(
                    statement, "subcontract.preparation",
                    "subcontract_preparation:start"));
            assertEquals(1, linkCount(
                    statement, "subcontract.order",
                    "subcontract_order:price:view"));
            assertEquals(1, linkCount(
                    statement, "warehouse.subcontract-outbound",
                    "subcontract_material_issue:approve"));
            assertEquals(1, linkCount(
                    statement, "purchase.order", "purchase_order:price:view"));
            assertEquals(1, linkCount(
                    statement, "purchase.return", "purchase_return:price:view"));
            assertEquals(1, linkCount(
                    statement, "purchase.report", "purchase_report:price:view"));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from department_permissions grant_row
                    join permissions permission
                      on permission.id = grant_row.permission_id
                    where permission.code like 'subcontract_preparation:%'
                       or permission.code in (
                           'subcontract_inquiry:price:view',
                           'subcontract_order:price:view',
                           'subcontract_return:price:view',
                           'subcontract_waste:suggestion:view',
                           'subcontract_report:price:view')
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from department_permissions grant_row
                    join permissions permission
                      on permission.id = grant_row.permission_id
                    where permission.code in (
                        'purchase_order:price:view',
                        'purchase_return:price:view',
                        'purchase_report:price:view')
                    """));


            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from permission_surfaces surface
                    where not exists (
                        select 1
                        from permission_surface_permissions link
                        where link.surface_id = surface.id
                    )
                    """));
        }
    }

    @Test
    void repositoryLoadsTheActiveCatalogAsOneExactFailClosedSnapshot() {
        DriverManagerDataSource dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
        PermissionSurfaceRegistry registry = new PermissionSurfaceRegistry(
                new PermissionSurfaceCatalogRepository(
                        new JdbcTemplate(dataSource)));

        Integer surfaceCount = new JdbcTemplate(dataSource).queryForObject(
                "select count(*) from permission_surfaces", Integer.class);
        assertEquals(surfaceCount, registry.knownKeys().size());
        assertTrue(registry.knownKeys().size() >= 86);
        assertTrue(registry.permissionsFor("basic.goods").containsAll(Set.of(
                "goods:create", "material_category:move", "stock:view")));
        assertFalse(registry.permissionsFor("basic.goods").contains("mould:view"));
        assertTrue(registry.permissionsFor("org.department").containsAll(Set.of(
                "department:create", "department:move",
                "department:manager_assign", "position:create", "position:delete")));
        assertTrue(registry.permissionsFor("purchase.arrival-exception")
                .contains("supplier_return_task:complete"));
        assertEquals(Set.of(
                        "subcontract_preparation:start",
                        "subcontract_preparation:view"),
                registry.permissionsFor("subcontract.preparation"));
        assertTrue(registry.permissionsFor("purchase.order")
                .contains("purchase_order:price:view"));
        assertTrue(registry.permissionsFor("purchase.return")
                .contains("purchase_return:price:view"));
        assertTrue(registry.permissionsFor("purchase.report")
                .contains("purchase_report:price:view"));
        assertEquals(Set.of(
                "production_daily_report:edit",
                "production_execution:assign",
                "production_execution:release_defer",
                "production_execution:dispatch",
                "production_execution:start",
                "production_material_analysis:view",
                "production_material:close",
                "production_material:reverse",
                "production_material:settle",
                "production_plan:approve",
                "production_plan:batchApprove",
                "production_plan:batchDelete",
                "production_plan:delete",
                "production_plan:edit",
                "production_plan:flags",
                "production_plan:reverse",
                "production_plan:view",
                "production_plan:view:all",
                "production_planning_package:generate",
                "production_planning_package:draft_edit",
                "production_planning_package:cancel",
                "production_planning_package:reverse"),
                registry.permissionsFor("production.plan"));
        assertEquals(Set.of(
                "production_daily_report:view",
                "production_material_analysis:view",
                "production_plan:edit",
                "production_plan:view",
                "production_report:view",
                "production_where_used:view"),
                registry.permissionsFor("production.hub"));

        assertEquals(Set.of(), registry.permissionsFor("quality.lab-test"));
    }

    @Test
    void bothCatalogTablesHaveEnabledAuditTriggersThatCaptureMutations()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            connection.setAutoCommit(false);
            UUID actorId = UUID.randomUUID();
            statement.execute("""
                    select set_config('app.actor_id', '%s', true)
                    """.formatted(actorId));

            long surfaceAuditBefore = auditCount(
                    statement, "permission_surfaces");
            long linkAuditBefore = auditCount(
                    statement, "permission_surface_permissions");

            statement.executeUpdate("""
                    update permission_surfaces
                    set sort_order = sort_order + 1000
                    where surface_key = 'sales.order'
                    """);
            statement.executeUpdate("""
                    delete from permission_surface_permissions
                    where surface_id = (
                        select id from permission_surfaces
                        where surface_key = 'sales.order'
                    )
                      and permission_id = (
                        select id from permissions
                        where code = 'sales_order:view'
                    )
                    """);

            assertTrue(auditCount(
                    statement, "permission_surfaces") > surfaceAuditBefore);
            assertTrue(auditCount(
                    statement,
                    "permission_surface_permissions") > linkAuditBefore);
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from pg_trigger trigger
                    join pg_proc function on function.oid = trigger.tgfoid
                    where trigger.tgrelid = 'permission_surfaces'::regclass
                      and trigger.tgname like 'trg_audit%%'
                      and not trigger.tgisinternal
                      and trigger.tgenabled in ('O', 'A')
                      and function.proname in ('fn_audit', 'fn_audit_redacted')
                    """));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from pg_trigger trigger
                    join pg_proc function on function.oid = trigger.tgfoid
                    where trigger.tgrelid =
                              'permission_surface_permissions'::regclass
                      and trigger.tgname like 'trg_audit%%'
                      and not trigger.tgisinternal
                      and trigger.tgenabled in ('O', 'A')
                      and function.proname in ('fn_audit', 'fn_audit_redacted')
                    """));
            connection.rollback();
        }
    }

    @Test
    void v329CreatesCurrentStaffGlobalPagingIndex() throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from pg_indexes
                    where schemaname = current_schema()
                      and tablename = 'employees'
                      and indexname = 'idx_employees_current_name_code_page'
                    """));
            String definition = scalarText(statement, """
                    select indexdef
                    from pg_indexes
                    where schemaname = current_schema()
                      and indexname = 'idx_employees_current_name_code_page'
                    """).toLowerCase();
            assertTrue(definition.contains("(full_name, code, id)"));
            assertTrue(definition.contains("include (department_id, position_id)"));
            assertTrue(definition.contains("is_deleted"));
            assertTrue(definition.contains("onleave"));
        }
    }

    private static long linkCount(
            Statement statement,
            String surfaceKey,
            String permissionCode) throws Exception {
        return scalarLong(statement, """
                select count(*)
                from permission_surface_permissions link
                join permission_surfaces surface
                  on surface.id = link.surface_id
                join permissions permission
                  on permission.id = link.permission_id
                where surface.surface_key = '%s'
                  and permission.code = '%s'
                """.formatted(surfaceKey, permissionCode));
    }

    private static long auditCount(
            Statement statement,
            String targetType) throws Exception {
        return scalarLong(statement, """
                select count(*)
                from audit_log
                where target_type = '%s'
                """.formatted(targetType));
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static long scalarLong(Statement statement, String sql)
            throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }

    private static String scalarText(Statement statement, String sql)
            throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getString(1);
        }
    }
}
