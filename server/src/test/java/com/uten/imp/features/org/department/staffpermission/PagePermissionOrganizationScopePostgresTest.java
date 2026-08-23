package com.uten.imp.features.org.department.staffpermission;

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
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Real PostgreSQL coverage for the page-permission staff scope.
 *
 * <p>The test deliberately keeps organization authorization in the SQL query:
 * a stale client-side department tree or a manager replacement must not widen
 * results. It also proves that V324 generation snapshots, rather than physical
 * deletion of historical delegation rows, close manager A -&gt; B -&gt; A ABA.</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PagePermissionOrganizationScopePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    private static final UUID ROOT_A = uuid("1101");
    private static final UUID CHILD_A = uuid("1102");
    private static final UUID ROOT_B = uuid("1103");
    private static final UUID CHILD_B = uuid("1104");
    private static final UUID OUTSIDE_ROOT = uuid("1105");
    private static final UUID ABA_ROOT = uuid("1106");
    private static final UUID ABA_CHILD = uuid("1107");

    private static final UUID ORDINARY_MANAGER = uuid("2101");
    private static final UUID GM_MANAGER = uuid("2110");
    private static final UUID ABA_MANAGER_A = uuid("2120");
    private static final UUID ABA_MANAGER_B = uuid("2121");
    private static final UUID ABA_TARGET = uuid("2122");

    private static final UUID ABA_GRANTOR_USER = uuid("3101");
    private static final UUID ABA_TARGET_USER = uuid("3102");

    private static DepartmentPermissionStaffQuery staffQuery;
    private static UUID gmDepartmentId;

    @BeforeAll
    static void migrateAndSeedOrganization() throws Exception {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();

        DriverManagerDataSource dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
        staffQuery = new DepartmentPermissionStaffQuery(
                new JdbcTemplate(dataSource));

        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            UUID companyId = scalarUuid(statement,
                    "SELECT id FROM departments WHERE code='UTEN'");
            gmDepartmentId = scalarUuid(statement,
                    "SELECT id FROM departments WHERE code='GM'");

            statement.executeUpdate("""
                    INSERT INTO departments(
                        id, code, name, parent_id, level, sort_order)
                    VALUES
                    ('%s'::uuid, 'PG329_ROOT_A', 'PG 范围甲部', '%s'::uuid,
                     '一级部门', 32901),
                    ('%s'::uuid, 'PG329_CHILD_A', 'PG 范围甲组', '%s'::uuid,
                     '二级班组', 1),
                    ('%s'::uuid, 'PG329_ROOT_B', 'PG 范围乙部', '%s'::uuid,
                     '一级部门', 32902),
                    ('%s'::uuid, 'PG329_CHILD_B', 'PG 范围乙组', '%s'::uuid,
                     '二级班组', 1),
                    ('%s'::uuid, 'PG329_OUTSIDE', 'PG 范围外部', '%s'::uuid,
                     '一级部门', 32903),
                    ('%s'::uuid, 'PG329_ABA_ROOT', 'PG ABA 根', '%s'::uuid,
                     '一级部门', 32904),
                    ('%s'::uuid, 'PG329_ABA_CHILD', 'PG ABA 子组', '%s'::uuid,
                     '二级班组', 1)
                    """.formatted(
                    ROOT_A, companyId,
                    CHILD_A, ROOT_A,
                    ROOT_B, companyId,
                    CHILD_B, ROOT_B,
                    OUTSIDE_ROOT, companyId,
                    ABA_ROOT, companyId,
                    ABA_CHILD, ABA_ROOT));

            statement.executeUpdate("""
                    INSERT INTO employees(
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type, is_deleted)
                    VALUES
                    ('%s'::uuid, 'ORD329-MGR', 'Ord329 00 manager', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'ORD329-A-ROOT', 'Ord329 01 A root', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'ORD329-A-CHILD', 'Ord329 02 A child', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'ORD329-B-ROOT', 'Ord329 03 B root', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'ORD329-B-CHILD', 'Ord329 04 B child', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'ORD329-OUT', 'Ord329 05 outside', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'ORD329-RESIGNED', 'Ord329 06 resigned', '其他',
                     '%s'::uuid, current_date, 'resigned', 'regular', false),

                    ('%s'::uuid, 'COMP329-MGR', 'Comp329 00 manager', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'COMP329-GM', 'Comp329 01 gm', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'COMP329-A', 'Comp329 02 root a', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'COMP329-B', 'Comp329 03 root b', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'COMP329-OUT', 'Comp329 04 outside', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),

                    ('%s'::uuid, 'ABA329-MGR-A', 'Aba329 manager a', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'ABA329-MGR-B', 'Aba329 manager b', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false),
                    ('%s'::uuid, 'ABA329-TARGET', 'Aba329 target', '其他',
                     '%s'::uuid, current_date, 'active', 'regular', false)
                    """.formatted(
                    ORDINARY_MANAGER, ROOT_A,
                    uuid("2202"), ROOT_A,
                    uuid("2203"), CHILD_A,
                    uuid("2204"), ROOT_B,
                    uuid("2205"), CHILD_B,
                    uuid("2206"), OUTSIDE_ROOT,
                    uuid("2207"), CHILD_A,
                    GM_MANAGER, gmDepartmentId,
                    uuid("2211"), gmDepartmentId,
                    uuid("2212"), ROOT_A,
                    uuid("2213"), ROOT_B,
                    uuid("2214"), OUTSIDE_ROOT,
                    ABA_MANAGER_A, ABA_ROOT,
                    ABA_MANAGER_B, ABA_ROOT,
                    ABA_TARGET, ABA_CHILD));

            statement.executeUpdate("""
                    UPDATE departments
                    SET manager_id='%s'::uuid
                    WHERE id IN ('%s'::uuid, '%s'::uuid)
                    """.formatted(ORDINARY_MANAGER, ROOT_A, ROOT_B));
            statement.executeUpdate("""
                    UPDATE departments SET manager_id='%s'::uuid
                    WHERE id='%s'::uuid
                    """.formatted(GM_MANAGER, gmDepartmentId));
            statement.executeUpdate("""
                    UPDATE departments SET manager_id='%s'::uuid
                    WHERE id='%s'::uuid
                    """.formatted(ABA_MANAGER_A, ABA_ROOT));

            statement.executeUpdate("""
                    INSERT INTO users(
                        id, employee_id, login_account, password_hash,
                        must_change_password)
                    VALUES
                    ('%s'::uuid, '%s'::uuid, 'pg329-aba-grantor',
                     'test-only', false),
                    ('%s'::uuid, '%s'::uuid, 'pg329-aba-target',
                     'test-only', false)
                    """.formatted(
                    ABA_GRANTOR_USER, ABA_MANAGER_A,
                    ABA_TARGET_USER, ABA_TARGET));
        }
    }

    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void ordinaryManagerPagesAcrossRootsAndSelectedSubtreesWithoutLeakage() {
        var authority = new OrganizationPermissionManagementScopeService
                .StaffSearchAuthority(
                        OrganizationPermissionManagementScopeService
                                .StaffSearchScope.MANAGER_SUBTREES,
                        ORDINARY_MANAGER);

        var first = staffQuery.query(
                authority, null, ORDINARY_MANAGER, "ORD329", 1, 2);
        var second = staffQuery.query(
                authority, null, ORDINARY_MANAGER, "ORD329", 2, 2);

        assertEquals(4L, first.total());
        assertEquals(2, first.totalPages());
        assertEquals(List.of("ORD329-A-ROOT", "ORD329-A-CHILD"),
                first.staff().stream().map(row -> row.code()).toList());
        assertEquals(List.of("ORD329-B-ROOT", "ORD329-B-CHILD"),
                second.staff().stream().map(row -> row.code()).toList());
        Set<UUID> combinedDepartments = new LinkedHashSet<>();
        first.staff().forEach(row -> combinedDepartments.add(row.departmentId()));
        second.staff().forEach(row -> combinedDepartments.add(row.departmentId()));
        assertEquals(Set.of(ROOT_A, CHILD_A, ROOT_B, CHILD_B),
                combinedDepartments);
        assertFalse(first.staff().stream()
                .anyMatch(row -> row.employeeId().equals(ORDINARY_MANAGER)));

        var rootA = staffQuery.query(
                authority, ROOT_A, ORDINARY_MANAGER, "ORD329", 1, 50);
        assertEquals(2L, rootA.total());
        assertEquals(Set.of(ROOT_A, CHILD_A), rootA.staff().stream()
                .map(row -> row.departmentId())
                .collect(java.util.stream.Collectors.toSet()));

        var childA = staffQuery.query(
                authority, CHILD_A, ORDINARY_MANAGER, "ORD329", 1, 50);
        assertEquals(1L, childA.total());
        assertEquals(CHILD_A, childA.staff().getFirst().departmentId());

        var outside = staffQuery.query(
                authority, OUTSIDE_ROOT, ORDINARY_MANAGER, "ORD329", 1, 50);
        assertEquals(0L, outside.total());
        assertTrue(outside.staff().isEmpty());
    }

    @Test
    void executiveOfficeManagerSearchesCompanyByStableCodeAndIsRecheckedInSql()
            throws Exception {
        var authority = new OrganizationPermissionManagementScopeService
                .StaffSearchAuthority(
                        OrganizationPermissionManagementScopeService
                                .StaffSearchScope.EXECUTIVE_OFFICE_COMPANY,
                        GM_MANAGER);
        String originalName;
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            originalName = scalarText(statement,
                    "SELECT name FROM departments WHERE id='%s'::uuid"
                            .formatted(gmDepartmentId));
            statement.executeUpdate("""
                    UPDATE departments SET name='PG renamed executive office'
                    WHERE id='%s'::uuid
                    """.formatted(gmDepartmentId));
        }

        try {
            var company = staffQuery.query(
                    authority, null, GM_MANAGER, "COMP329", 1, 50);
            assertEquals(4L, company.total());
            assertEquals(Set.of(gmDepartmentId, ROOT_A, ROOT_B, OUTSIDE_ROOT),
                    company.staff().stream()
                            .map(row -> row.departmentId())
                            .collect(java.util.stream.Collectors.toSet()));
            assertFalse(company.staff().stream()
                    .anyMatch(row -> row.employeeId().equals(GM_MANAGER)));

            try (Connection connection = connection();
                 Statement statement = connection.createStatement()) {
                statement.executeUpdate("""
                        UPDATE departments SET manager_id=NULL
                        WHERE id='%s'::uuid
                        """.formatted(gmDepartmentId));
            }
            var revoked = staffQuery.query(
                    authority, null, GM_MANAGER, "COMP329", 1, 50);
            assertEquals(0L, revoked.total());
            assertTrue(revoked.staff().isEmpty());
        } finally {
            try (Connection connection = connection();
                 Statement statement = connection.createStatement()) {
                statement.executeUpdate("""
                        UPDATE departments
                        SET name='%s', manager_id='%s'::uuid
                        WHERE id='%s'::uuid
                        """.formatted(
                        originalName.replace("'", "''"),
                        GM_MANAGER,
                        gmDepartmentId));
            }
        }
    }

    @Test
    void v324RootAndTargetGenerationsMakeManagerReplacementAbaSafe()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            UUID permissionId = scalarUuid(statement, """
                    SELECT id FROM permissions WHERE code='sales_order:view'
                    """);
            statement.executeUpdate("""
                    INSERT INTO manager_permission_delegations(
                        user_id, permission_id, department_id, enabled,
                        surface_key, granted_by_user_id, created_by, updated_by,
                        target_user_generation,
                        target_employee_generation,
                        target_department_generation,
                        grantor_user_generation,
                        grantor_employee_generation,
                        grantor_auth_version,
                        grantor_authorization_epoch,
                        scope_source,
                        scope_department_id,
                        scope_generation)
                    SELECT
                        target_user.id,
                        '%s'::uuid,
                        target_department.id,
                        true,
                        'sales.order',
                        grantor_user.id,
                        grantor_user.id,
                        grantor_user.id,
                        target_user.permission_delegation_generation,
                        target_employee.permission_delegation_generation,
                        target_department.permission_delegation_generation,
                        grantor_user.permission_delegation_generation,
                        grantor_employee.permission_delegation_generation,
                        grantor_user.auth_version,
                        authorization_state_row.epoch,
                        'DEPARTMENT_MANAGER',
                        scope_department.id,
                        scope_department.permission_delegation_generation
                    FROM users target_user
                    JOIN employees target_employee
                      ON target_employee.id=target_user.employee_id
                    CROSS JOIN users grantor_user
                    JOIN employees grantor_employee
                      ON grantor_employee.id=grantor_user.employee_id
                    CROSS JOIN departments target_department
                    CROSS JOIN departments scope_department
                    CROSS JOIN authorization_state authorization_state_row
                    WHERE target_user.id='%s'::uuid
                      AND grantor_user.id='%s'::uuid
                      AND target_department.id='%s'::uuid
                      AND scope_department.id='%s'::uuid
                      AND authorization_state_row.singleton_id=1
                    """.formatted(
                    permissionId,
                    ABA_TARGET_USER,
                    ABA_GRANTOR_USER,
                    ABA_CHILD,
                    ABA_ROOT));

            assertEquals(1L, validDelegationSnapshotCount(statement));
            long initialScopeGeneration = scalarLong(statement, """
                    SELECT scope_generation
                    FROM manager_permission_delegations
                    WHERE user_id='%s'::uuid
                      AND permission_id='%s'::uuid
                      AND department_id='%s'::uuid
                    """.formatted(ABA_TARGET_USER, permissionId, ABA_CHILD));
            long initialTargetGeneration = scalarLong(statement, """
                    SELECT target_department_generation
                    FROM manager_permission_delegations
                    WHERE user_id='%s'::uuid
                      AND permission_id='%s'::uuid
                      AND department_id='%s'::uuid
                    """.formatted(ABA_TARGET_USER, permissionId, ABA_CHILD));

            statement.executeUpdate("""
                    UPDATE departments SET manager_id='%s'::uuid
                    WHERE id='%s'::uuid
                    """.formatted(ABA_MANAGER_B, ABA_ROOT));
            assertEquals(0L, validDelegationSnapshotCount(statement));
            assertEquals(1L, scalarLong(statement, """
                    SELECT count(*) FROM manager_permission_delegations
                    WHERE user_id='%s'::uuid AND enabled=true
                    """.formatted(ABA_TARGET_USER)));
            assertTrue(scalarLong(statement, """
                    SELECT permission_delegation_generation
                    FROM departments WHERE id='%s'::uuid
                    """.formatted(ABA_ROOT)) > initialScopeGeneration);
            assertTrue(scalarLong(statement, """
                    SELECT permission_delegation_generation
                    FROM departments WHERE id='%s'::uuid
                    """.formatted(ABA_CHILD)) > initialTargetGeneration);

            statement.executeUpdate("""
                    UPDATE departments SET manager_id='%s'::uuid
                    WHERE id='%s'::uuid
                    """.formatted(ABA_MANAGER_A, ABA_ROOT));
            assertEquals(0L, validDelegationSnapshotCount(statement));
        }
    }

    @Test
    void v329GlobalCurrentEmployeeIndexExistsAndSuppliesStableOrderPlan()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            String definition = scalarText(statement, """
                    SELECT indexdef
                    FROM pg_indexes
                    WHERE schemaname='public'
                      AND tablename='employees'
                      AND indexname='idx_employees_current_name_code_page'
                    """);
            assertTrue(definition.contains("(full_name, code, id)"));
            assertTrue(definition.contains("INCLUDE (department_id, position_id)"));
            assertTrue(definition.contains("WHERE"));
            assertFalse(scalarText(statement, """
                    SELECT COALESCE(
                        obj_description(
                            'idx_employees_current_name_code_page'::regclass,
                            'pg_class'),
                        '')
                    """).isBlank());

            statement.execute("ANALYZE employees");
            statement.execute("SET enable_seqscan=off");
            String plan = explain(statement, """
                    SELECT employee.id
                    FROM employees employee
                    WHERE employee.is_deleted=false
                      AND employee.status IN ('active', 'probation', 'onLeave')
                    ORDER BY employee.full_name, employee.code, employee.id
                    LIMIT 50
                    """);
            assertTrue(plan.contains("idx_employees_current_name_code_page"), plan);
            assertFalse(plan.contains("Sort"), plan);
        }
    }

    private static long validDelegationSnapshotCount(Statement statement)
            throws Exception {
        return scalarLong(statement, """
                SELECT count(*)
                FROM manager_permission_delegations delegation
                JOIN departments target_department
                  ON target_department.id=delegation.department_id
                JOIN departments scope_department
                  ON scope_department.id=delegation.scope_department_id
                JOIN authorization_state authorization_state_row
                  ON authorization_state_row.singleton_id=1
                WHERE delegation.user_id='%s'::uuid
                  AND delegation.enabled=true
                  AND delegation.scope_source='DEPARTMENT_MANAGER'
                  AND delegation.target_department_generation=
                      target_department.permission_delegation_generation
                  AND delegation.scope_generation=
                      scope_department.permission_delegation_generation
                  AND delegation.grantor_authorization_epoch=
                      authorization_state_row.epoch
                """.formatted(ABA_TARGET_USER));
    }

    private static String explain(Statement statement, String sql)
            throws Exception {
        StringBuilder plan = new StringBuilder();
        try (ResultSet result = statement.executeQuery(
                "EXPLAIN (COSTS OFF) " + sql)) {
            while (result.next()) {
                if (!plan.isEmpty()) {
                    plan.append('\n');
                }
                plan.append(result.getString(1));
            }
        }
        return plan.toString();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static UUID scalarUuid(Statement statement, String sql)
            throws Exception {
        return UUID.fromString(scalarText(statement, sql));
    }

    private static long scalarLong(Statement statement, String sql)
            throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getLong(1);
        }
    }

    private static String scalarText(Statement statement, String sql)
            throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getString(1);
        }
    }

    private static UUID uuid(String suffix) {
        return UUID.fromString(
                "32900000-0000-4000-8000-00000000" + suffix);
    }
}
