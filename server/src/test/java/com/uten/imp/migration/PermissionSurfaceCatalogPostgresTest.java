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
            // V455 retired the zero-reference mrp codes (generate_draw /
            // generate_finished_in); V470 把 dispatch/start 从本面下架（工作台
            // 不再广告手动派工/开工）；V543 把停用的 execution cancel/reverse 与
            // mrp generate_purchase 从本面下架；V655(ADR-109)把计划页真实存在的
            // 「派工」按钮码 dispatch 补挂回来：10 = execution 3 + package 4 + material 3。
            assertEquals(10, scalarLong(statement, """
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
            // V655：页面权限面只挂页面上真实有按钮的码，dispatch 补挂、start 仍不挂。
            assertEquals(1, linkCount(
                    statement, "production.plan", "production_execution:dispatch"));
            assertEquals(0, linkCount(
                    statement, "production.plan", "production_execution:start"));
            // V543：生产面下架五个停用码；我的车间任务面补齐真实按钮三码。
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from permission_surface_permissions link
                    join permission_surfaces surface
                      on surface.id = link.surface_id
                    join permissions permission
                      on permission.id = link.permission_id
                    where surface.surface_key like 'production.%'
                      and permission.code in (
                          'production_execution:cancel',
                          'production_execution:reverse',
                          'production_mrp:generate_purchase',
                          'production_material_analysis:manage',
                          'planning_supply_request:view')
                    """));
            assertEquals(1, linkCount(
                    statement, "production.workshop-tasks", "production_execution:start"));
            assertEquals(1, linkCount(
                    statement, "production.workshop-tasks", "production_material:settle"));
            assertEquals(1, linkCount(
                    statement, "production.workshop-tasks", "production_material:reverse"));
            // V543：`*:view:all` 是对象范围码，退出批量三档；V655 起由 grant_policy 表达。
            assertEquals(0, scalarLong(statement, """
                    select count(*) from permissions
                    where code like '%:view:all'
                      and not (grant_policy && array['BULK_EXCLUDED','INDIVIDUAL_ONLY',
                                                     'SUPERADMIN_ONLY']::text[])
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from department_permissions grant_row
                    join departments department
                      on department.id = grant_row.department_id
                    join permissions permission
                      on permission.id = grant_row.permission_id
                    where department.code = 'DEPT_PROD'
                      and (permission.code = 'production_plan:view:all'
                           or permission.code like 'production_planning_package:%'
                           or permission.code in (
                               'production_plan:delete',
                               'production_plan:reverse', 'production_plan:flags',
                               'production_execution:overview',
                               'production_execution:assign',
                               'production_execution:dispatch',
                               'mould:create', 'mould:delete', 'mould:status'))
                    """));
            assertEquals(1, linkCount(
                    statement, "production.plan", "production_material:close"));
            // V655：停用即删除，目录里不再有软停用码。
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from permissions
                    where code = 'production:view'
                    """));
            assertEquals(0, linkCount(
                    statement, "production.plan", "production:view"));
            assertEquals(0, linkCount(
                    statement, "production.hub", "production:view"));
            // V486 停用委外准备中心；V655 删除它的两个停用码(面本身停用、不再装载)。
            assertEquals(0, linkCount(
                    statement, "subcontract.preparation",
                    "subcontract_preparation:view"));
            assertEquals(0, linkCount(
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


            // 启用中的页面权限面必须至少挂一个码；停用面(V486 委外准备中心、V493 待审收件台)
            // 的码已在 V655 随「停用即删除」一并删掉，停用面不装载、不可委派。
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from permission_surfaces surface
                    where surface.enabled
                      and not exists (
                        select 1
                        from permission_surface_permissions link
                        where link.surface_id = surface.id
                    )
                    """));
            assertEquals(1, scalarLong(statement, """
                    select count(*) from permission_surfaces
                    where surface_key='reviews.inbox' and enabled=false
                    """));
            assertEquals(0, linkCount(statement, "reviews.inbox", "review_inbox:view"));
            assertEquals(0, scalarLong(statement, """
                    select count(*) from permissions
                    where code='review_inbox:view'
                    """));
            // V655：页面权限面只允许指向能在页面上授出的码(非超管专属)。
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from permission_surface_permissions link
                    join permissions permission on permission.id = link.permission_id
                    where 'SUPERADMIN_ONLY' = any(permission.grant_policy)
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

        // V486 退役 subcontract.preparation（停用不删除）：注册表只装载启用面，
        // 总数对账改用启用口径，退役面不再可解析。
        Integer surfaceCount = new JdbcTemplate(dataSource).queryForObject(
                "select count(*) from permission_surfaces where enabled", Integer.class);
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
        assertFalse(registry.isKnown("subcontract.preparation"),
                "V486 已停用委外准备中心权限面");
        assertFalse(registry.isKnown("reviews.inbox"), "V493 已退役待审收件台权限面");
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
                "production_material_analysis:view",
                "production_material:close",
                "production_material:reverse",
                "production_material:settle",
                "production_execution:dispatch",
                "production_plan:approve",
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

        // V455: quality.lab-test 面随 lab:test 码整体退役；守卫页守卫同源面开始可装载。
        assertFalse(registry.isKnown("quality.lab-test"));
        // V456: quality.inspection 旧面退役，能力并入 task-center 专属面（严格超集）。
        assertFalse(registry.isKnown("quality.inspection"));
        // V655：超管专属的授权管理码不挂页面权限面(任何入口都授不出去)，只剩账号支持。
        assertEquals(Set.of("account:support"),
                registry.permissionsFor("admin.permission-console"));
        assertFalse(registry.isKnown("admin.system-settings"),
                "系统设置面只挂了超管专属码，摘完后停用，不再出现页面内授权入口");
        assertEquals(Set.of("audit_log:view"),
                registry.permissionsFor("admin.audit-center"));
        assertEquals(Set.of(
                        "procurement_inspection:view",
                        "procurement_inspection:handle",
                        "production_quality_inspection:view",
                        "production_quality_inspection:approve"),
                registry.permissionsFor("quality.task-center"));
        assertEquals(Set.of(
                        "production_quality_inspection:view",
                        "production_quality_inspection:approve",
                        "production_fqc_replenishment:view",
                        "production_fqc_replenishment:confirm"),
                registry.permissionsFor("quality.production-fqc"));
        assertEquals(Set.of(
                        "warehouse_iqc_stock_in:view",
                        "warehouse_iqc_stock_in:confirm",
                        // V596 先入库后质检：独立动作码，登记到品质部检查结果面。
                        "warehouse_iqc_stock_in:before_inspection",
                        "warehouse_iqc_return:view"),
                registry.permissionsFor("warehouse.quality-results"));
        assertEquals(Set.of("production_plan:view"),
                registry.permissionsFor("production.schedule"));
        assertEquals(Set.of("production_execution:overview"),
                registry.permissionsFor("production.progress"));
        assertEquals(Set.of("production_material_analysis:view"),
                registry.permissionsFor("production.chain-health"));
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
            // ADR-105 FULL 形态: 行事件一个 + 带 WHEN 的更新一个。
            assertEquals(2, scalarLong(statement, """
                    select count(*)
                    from pg_trigger trigger
                    where trigger.tgrelid = 'permission_surfaces'::regclass
                      and trigger.tgname like 'trg_audit%%'
                      and not trigger.tgisinternal
                      and trigger.tgenabled in ('O', 'A')
                      and trigger.tgfoid = 'public.fn_audit()'::regprocedure
                    """));
            assertEquals(2, scalarLong(statement, """
                    select count(*)
                    from pg_trigger trigger
                    where trigger.tgrelid =
                              'permission_surface_permissions'::regclass
                      and trigger.tgname like 'trg_audit%%'
                      and not trigger.tgisinternal
                      and trigger.tgenabled in ('O', 'A')
                      and trigger.tgfoid = 'public.fn_audit()'::regprocedure
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
