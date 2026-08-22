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
import java.time.OffsetDateTime;
import java.util.UUID;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Non-empty V327 -> V328 rehearsal for old composite authorization preservation. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PermissionGrantPreservationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    private static final UUID ROLE_ID =
            UUID.fromString("32800000-0000-4000-8100-000000000001");
    private static final UUID GRANTOR_EMPLOYEE_ID =
            UUID.fromString("32800000-0000-4000-8200-000000000001");
    private static final UUID GRANTOR_USER_ID =
            UUID.fromString("32800000-0000-4000-8300-000000000001");
    private static final UUID TARGET_EMPLOYEE_ID =
            UUID.fromString("32800000-0000-4000-8200-000000000002");
    private static final UUID TARGET_USER_ID =
            UUID.fromString("32800000-0000-4000-8300-000000000002");
    private static final UUID DENY_EMPLOYEE_ID =
            UUID.fromString("32800000-0000-4000-8200-000000000003");
    private static final UUID DENY_USER_ID =
            UUID.fromString("32800000-0000-4000-8300-000000000003");
    private static final UUID TOMBSTONE_EMPLOYEE_ID =
            UUID.fromString("32800000-0000-4000-8200-000000000004");
    private static final UUID TOMBSTONE_USER_ID =
            UUID.fromString("32800000-0000-4000-8300-000000000004");

    private static final OffsetDateTime ALREADY_REVOKED_AT =
            OffsetDateTime.parse("2026-08-01T10:15:30+08:00");

    private static String salesDepartmentId;
    private static String financeDepartmentId;
    private static long epochBefore;
    private static long grantorAuthBefore;
    private static long targetAuthBefore;
    private static int migrationsExecuted;

    @BeforeAll
    static void migrateV327SeedAndUpgrade() throws Exception {
        POSTGRES.start();
        flyway("327").migrate();

        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals(1, statement.executeUpdate("""
                    DELETE FROM permissions
                    WHERE code='production:view'
                    """));
            assertEquals(0, scalar(statement, """
                    SELECT count(*) FROM permissions
                    WHERE code='production:view'
                    """));

            salesDepartmentId = text(statement,
                    "SELECT id::text FROM departments WHERE code='DEPT_SALES'");
            financeDepartmentId = text(statement,
                    "SELECT id::text FROM departments WHERE code='DEPT_FIN'");
            String attachmentManageId = text(statement, """
                    SELECT id::text FROM permissions WHERE code='attachment:manage'
                    """);
            String inventoryViewId = text(statement, """
                    SELECT id::text FROM permissions WHERE code='inventory:view'
                    """);
            String stockViewId = text(statement, """
                    SELECT id::text FROM permissions WHERE code='stock:view'
                    """);
            String webInquiryManageId = text(statement, """
                    SELECT id::text FROM permissions WHERE code='webinquiry:manage'
                    """);
            String productionPlanEditId = text(statement, """
                    SELECT id::text FROM permissions WHERE code='production_plan:edit'
                    """);

            statement.executeUpdate("""
                    INSERT INTO roles(id, code, name, description, is_system)
                    VALUES ('%s'::uuid, 'V328_COMPAT', 'V328 compatibility role',
                            'migration test only', false)
                    """.formatted(ROLE_ID));
            statement.executeUpdate("""
                    INSERT INTO role_permissions(role_id, permission_id)
                    VALUES ('%s'::uuid, '%s'::uuid)
                    """.formatted(ROLE_ID, attachmentManageId));
            statement.executeUpdate("""
                    INSERT INTO role_permissions(role_id, permission_id)
                    VALUES ('%s'::uuid, '%s'::uuid)
                    """.formatted(ROLE_ID, productionPlanEditId));


            statement.executeUpdate("""
                    DELETE FROM department_permissions
                    WHERE department_id='%s'::uuid
                      AND permission_id='%s'::uuid
                    """.formatted(salesDepartmentId, attachmentManageId));
            statement.executeUpdate("""
                    INSERT INTO department_permissions(
                        department_id, permission_id, created_at, created_by)
                    VALUES ('%s'::uuid, '%s'::uuid,
                            '2026-07-01T08:00:00+08:00'::timestamptz,
                            '%s'::uuid)
                    """.formatted(
                    salesDepartmentId, attachmentManageId, GRANTOR_USER_ID));
            statement.executeUpdate("""
                    DELETE FROM department_permissions
                    WHERE department_id='%s'::uuid
                      AND permission_id='%s'::uuid
                    """.formatted(financeDepartmentId, productionPlanEditId));
            statement.executeUpdate("""
                    INSERT INTO department_permissions(
                        department_id, permission_id, created_at, created_by)
                    VALUES ('%s'::uuid, '%s'::uuid,
                            '2026-07-01T09:00:00+08:00'::timestamptz,
                            '%s'::uuid)
                    """.formatted(
                    financeDepartmentId, productionPlanEditId, GRANTOR_USER_ID));


            statement.executeUpdate("""
                    INSERT INTO employees(
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type
                    ) VALUES
                    ('%s'::uuid, 'V328-GRANTOR', 'V328 Grantor', '其他',
                     '%s'::uuid, current_date, 'active', 'regular'),
                    ('%s'::uuid, 'V328-TARGET', 'V328 Target', '其他',
                     '%s'::uuid, current_date, 'active', 'regular'),
                    ('%s'::uuid, 'V328-DENY', 'V328 Deny', '其他',
                     '%s'::uuid, current_date, 'active', 'regular'),
                    ('%s'::uuid, 'V328-TOMBSTONE', 'V328 Tombstone', '其他',
                     '%s'::uuid, current_date, 'active', 'regular')
                    """.formatted(
                    GRANTOR_EMPLOYEE_ID, financeDepartmentId,
                    TARGET_EMPLOYEE_ID, financeDepartmentId,
                    DENY_EMPLOYEE_ID, financeDepartmentId,
                    TOMBSTONE_EMPLOYEE_ID, financeDepartmentId));
            statement.executeUpdate("""
                    INSERT INTO users(
                        id, employee_id, login_account, password_hash,
                        must_change_password, is_super_admin
                    ) VALUES
                    ('%s'::uuid, '%s'::uuid, 'v328-grantor', 'test-only', false, true),
                    ('%s'::uuid, '%s'::uuid, 'v328-target', 'test-only', false, false),
                    ('%s'::uuid, '%s'::uuid, 'v328-deny', 'test-only', false, false),
                    ('%s'::uuid, '%s'::uuid, 'v328-tombstone', 'test-only', false, false)
                    """.formatted(
                    GRANTOR_USER_ID, GRANTOR_EMPLOYEE_ID,
                    TARGET_USER_ID, TARGET_EMPLOYEE_ID,
                    DENY_USER_ID, DENY_EMPLOYEE_ID,
                    TOMBSTONE_USER_ID, TOMBSTONE_EMPLOYEE_ID));

            statement.executeUpdate("""
                    UPDATE department_permissions
                    SET created_by='%s'::uuid
                    WHERE department_id='%s'::uuid
                      AND permission_id='%s'::uuid
                    """.formatted(
                    GRANTOR_USER_ID, salesDepartmentId, attachmentManageId));

            statement.executeUpdate("""
                    INSERT INTO user_permission_overrides(
                        user_id, permission_id, effect, authority_source,
                        source_actor_user_id, row_version, active)
                    VALUES
                    ('%s'::uuid, '%s'::uuid, 'grant',
                     'SUPER_ADMIN_CONFIRMED', '%s'::uuid, 7, true),
                    ('%s'::uuid, '%s'::uuid, 'revoke',
                     'LEGACY_UNKNOWN', null, 4, true),
                    ('%s'::uuid, '%s'::uuid, 'grant',
                     'SUPER_ADMIN_CONFIRMED', '%s'::uuid, 9, true),
                    ('%s'::uuid, '%s'::uuid, 'grant',
                     'LEGACY_UNKNOWN', null, 11, false)
                    """.formatted(
                    TARGET_USER_ID, attachmentManageId, GRANTOR_USER_ID,
                    DENY_USER_ID, inventoryViewId,
                    DENY_USER_ID, stockViewId, GRANTOR_USER_ID,
                    TOMBSTONE_USER_ID, attachmentManageId));
            statement.executeUpdate("""
                    INSERT INTO user_permission_overrides(
                        user_id, permission_id, effect, authority_source,
                        source_actor_user_id, row_version, active)
                    VALUES ('%s'::uuid, '%s'::uuid, 'grant',
                            'SUPER_ADMIN_CONFIRMED', '%s'::uuid, 13, true)
                    """.formatted(
                    TARGET_USER_ID, productionPlanEditId, GRANTOR_USER_ID));


            statement.execute("""
                    SELECT set_config('app.actor_id', '%s', false)
                    """.formatted(GRANTOR_USER_ID));
            statement.executeUpdate(managerDelegationInsert(
                    TARGET_USER_ID, attachmentManageId, true, 5));
            statement.executeUpdate(managerDelegationInsert(
                    TARGET_USER_ID, productionPlanEditId, true, 14, "production.plan"));
            statement.executeUpdate(managerDelegationInsert(
                    TARGET_USER_ID, webInquiryManageId, false, 8));
            statement.executeUpdate(managerDelegationInsert(
                    TARGET_USER_ID, inventoryViewId, true, 6));
            statement.executeUpdate(managerDelegationInsert(
                    TARGET_USER_ID, stockViewId, false, 12));

            statement.executeUpdate("""
                    INSERT INTO refresh_tokens(
                        id, user_id, token_hash, expires_at, revoked_at)
                    VALUES
                    ('32800000-0000-4000-8400-000000000001'::uuid,
                     '%s'::uuid, 'v328-active-grantor', now() + interval '30 days', null),
                    ('32800000-0000-4000-8400-000000000002'::uuid,
                     '%s'::uuid, 'v328-active-target', now() + interval '30 days', null),
                    ('32800000-0000-4000-8400-000000000003'::uuid,
                     '%s'::uuid, 'v328-already-revoked', now() + interval '30 days',
                     '%s'::timestamptz)
                    """.formatted(
                    GRANTOR_USER_ID, TARGET_USER_ID, DENY_USER_ID,
                    ALREADY_REVOKED_AT));

            epochBefore = scalar(statement, """
                    SELECT epoch FROM authorization_state WHERE singleton_id=1
                    """);
            grantorAuthBefore = authVersion(statement, GRANTOR_USER_ID);
            targetAuthBefore = authVersion(statement, TARGET_USER_ID);
        }

        migrationsExecuted = flyway("328").migrate().migrationsExecuted;
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void roleDepartmentAndActiveGrantSubjectsExpandExactly() throws Exception {
        assertEquals(1, migrationsExecuted);
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals(2, scalar(statement, """
                    SELECT count(*)
                    FROM role_permissions source
                    JOIN permissions permission ON permission.id=source.permission_id
                    WHERE source.role_id='%s'::uuid
                      AND permission.code IN ('attachment:upload', 'attachment:delete')
                    """.formatted(ROLE_ID)));
            assertEquals(2, scalar(statement, """
                    SELECT count(*)
                    FROM department_permissions source
                    JOIN permissions permission ON permission.id=source.permission_id
                    WHERE source.department_id='%s'::uuid
                      AND permission.code IN ('attachment:upload', 'attachment:delete')
                      AND source.created_at='2026-07-01T08:00:00+08:00'::timestamptz
                      AND source.created_by='%s'::uuid
                    """.formatted(salesDepartmentId, GRANTOR_USER_ID)));
            for (String code : new String[]{"attachment:upload", "attachment:delete"}) {
                assertEquals(0, scalar(statement, subjectDifferenceSql(
                        "role_permissions", "role_id", "attachment:manage", code,
                        "TRUE", "TRUE")));
                assertEquals(0, scalar(statement, subjectDifferenceSql(
                        "department_permissions", "department_id",
                        "attachment:manage", code, "TRUE", "TRUE")));
                assertEquals(0, scalar(statement, subjectDifferenceSql(
                        "user_permission_overrides", "user_id",
                        "attachment:manage", code,
                        "source.active AND source.effect='grant'",
                        "target.active AND target.effect='grant'")));
            }

            assertEquals("SUPER_ADMIN_CONFIRMED|" + GRANTOR_USER_ID + "|7|true",
                    text(statement, """
                            SELECT authority_source || '|' ||
                                   source_actor_user_id::text || '|' ||
                                   override_row.row_version || '|' ||
                                   override_row.active
                            FROM user_permission_overrides override_row
                            JOIN permissions permission
                              ON permission.id=override_row.permission_id
                            WHERE override_row.user_id='%s'::uuid
                              AND permission.code='attachment:upload'
                            """.formatted(TARGET_USER_ID)));
        }
    }

    @Test
    void missingOptionalLegacyProductionViewStillBuildsProductionSurfaces()
            throws Exception {
        assertEquals(1, migrationsExecuted);
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals(0, scalar(statement, """
                    SELECT count(*) FROM permissions
                    WHERE code='production:view'
                    """));
            assertEquals(0, scalar(statement, """
                    SELECT count(*)
                    FROM permission_surface_permissions link
                    JOIN permission_surfaces surface
                      ON surface.id=link.surface_id
                    JOIN permissions permission
                      ON permission.id=link.permission_id
                    WHERE surface.surface_key IN (
                              'production.plan', 'production.hub')
                      AND permission.code='production:view'
                    """));
        }
    }
    @Test
    void departmentEditGrantSubjectsExpandToMoveAndManagerAssignment()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            long sources = scalar(statement, """
                    SELECT count(*)
                    FROM department_permissions source
                    JOIN permissions permission ON permission.id=source.permission_id
                    WHERE permission.code='department:edit'
                    """);
            assertTrue(sources > 0);
            for (String code : List.of(
                    "department:move", "department:manager_assign")) {
                assertEquals(sources, scalar(statement, """
                        SELECT count(*)
                        FROM department_permissions source
                        JOIN permissions permission ON permission.id=source.permission_id
                        WHERE permission.code='%s'
                        """.formatted(code)));
                assertEquals(0, scalar(statement, subjectDifferenceSql(
                        "department_permissions", "department_id",
                        "department:edit", code, "TRUE", "TRUE")));
            }
        }
    }

    @Test
    void productionPlanEditExpandsAcrossAllFourAuthorizationSources()
            throws Exception {
        List<String> targets = List.of(
                "production_execution:assign",
                "production_execution:release_defer",
                "production_execution:dispatch",
                "production_execution:start",
                "production_execution:cancel",
                "production_execution:reverse",
                "production_mrp:generate_purchase",
                "production_mrp:generate_draw",
                "production_mrp:generate_finished_in",
                "production_planning_package:generate",
                "production_planning_package:draft_edit",
                "production_planning_package:cancel",
                "production_planning_package:reverse",
                "production_material:settle",
                "production_material:reverse",
                "production_material:close");

        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals(11, scalar(statement, """
                    SELECT count(*) FROM permissions
                    WHERE active=true
                      AND (
                          code LIKE 'production_execution:%'
                          OR code LIKE 'production_mrp:%'
                          OR code LIKE 'production_planning_package:%'
                          OR code LIKE 'production_material:%'
                      )
                    """));
            assertEquals(5, scalar(statement, """
                    SELECT count(*) FROM permissions
                    WHERE code IN (
                        'production_execution:cancel',
                        'production_execution:reverse',
                        'production_mrp:generate_purchase',
                        'production_mrp:generate_draw',
                        'production_mrp:generate_finished_in'
                    )
                      AND active=false
                      AND assignable=false
                    """));

            for (String code : targets) {
                assertEquals(0, scalar(statement, subjectDifferenceSql(
                        "role_permissions", "role_id",
                        "production_plan:edit", code, "TRUE", "TRUE")));
                assertEquals(0, scalar(statement, subjectDifferenceSql(
                        "department_permissions", "department_id",
                        "production_plan:edit", code, "TRUE", "TRUE")));
                assertEquals(0, scalar(statement, subjectDifferenceSql(
                        "user_permission_overrides", "user_id",
                        "production_plan:edit", code,
                        "source.active AND source.effect='grant'",
                        "target.active AND target.effect='grant'")));
                assertEquals(0, scalar(statement, subjectDifferenceSql(
                        "manager_permission_delegations", "user_id",
                        "production_plan:edit", code,
                        "source.enabled AND source.surface_key='production.plan'",
                        "target.enabled AND target.surface_key='production.plan'")));
            }
        }
    }



    @Test
    void revokeWinsPkConflictAndInactiveTombstoneNeverExpands() throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals("revoke|LEGACY_UNKNOWN||10|true", text(statement, """
                    SELECT effect || '|' || authority_source || '|' ||
                           COALESCE(source_actor_user_id::text, '') || '|' ||
                           override_row.row_version || '|' ||
                           override_row.active
                    FROM user_permission_overrides override_row
                    JOIN permissions permission
                      ON permission.id=override_row.permission_id
                    WHERE override_row.user_id='%s'::uuid
                      AND permission.code='stock:view'
                    """.formatted(DENY_USER_ID)));
            assertEquals(0, scalar(statement, """
                    SELECT count(*)
                    FROM user_permission_overrides override_row
                    JOIN permissions permission
                      ON permission.id=override_row.permission_id
                    WHERE override_row.user_id='%s'::uuid
                      AND permission.code IN ('attachment:upload', 'attachment:delete')
                    """.formatted(TOMBSTONE_USER_ID)));
            assertEquals(1, scalar(statement, """
                    SELECT count(*)
                    FROM user_permission_overrides override_row
                    JOIN permissions permission
                      ON permission.id=override_row.permission_id
                    WHERE override_row.user_id='%s'::uuid
                      AND permission.code='attachment:manage'
                      AND override_row.active=false
                      AND override_row.row_version=11
                    """.formatted(TOMBSTONE_USER_ID)));
        }
    }

    @Test
    void enabledManagerGrantCopiesSnapshotsWhileDisabledHistoryStaysClosed()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals(2, scalar(statement, """
                    SELECT count(*)
                    FROM manager_permission_delegations delegation
                    JOIN permissions permission
                      ON permission.id=delegation.permission_id
                    JOIN users target_user ON target_user.id=delegation.user_id
                    JOIN users grantor_user
                      ON grantor_user.id=delegation.granted_by_user_id
                    CROSS JOIN authorization_state auth_state
                    WHERE delegation.user_id='%s'::uuid
                      AND permission.code IN ('attachment:upload', 'attachment:delete')
                      AND delegation.enabled=true
                      AND delegation.surface_key='org.employee'
                      AND delegation.granted_by_user_id='%s'::uuid
                      AND delegation.row_version=5
                      AND delegation.target_user_generation=
                          target_user.permission_delegation_generation
                      AND delegation.target_employee_generation=0
                      AND delegation.target_department_generation=
                          (SELECT permission_delegation_generation
                           FROM departments WHERE id='%s'::uuid)
                      AND delegation.grantor_user_generation=
                          grantor_user.permission_delegation_generation
                      AND delegation.grantor_employee_generation IS NULL
                      AND delegation.grantor_auth_version=grantor_user.auth_version
                      AND delegation.grantor_authorization_epoch=auth_state.epoch
                      AND delegation.scope_source='SUPER_ADMIN'
                      AND delegation.scope_department_id IS NULL
                      AND delegation.scope_generation IS NULL
                      AND delegation.scope_assignment_id IS NULL
                      AND delegation.scope_assignment_version IS NULL
                      AND EXISTS (
                          SELECT 1
                          FROM permission_surfaces surface
                          JOIN permission_surface_permissions surface_permission
                            ON surface_permission.surface_id=surface.id
                          WHERE surface.surface_key=delegation.surface_key
                            AND surface_permission.permission_id=
                                delegation.permission_id
                      )
                    """.formatted(
                    TARGET_USER_ID, GRANTOR_USER_ID, financeDepartmentId)));
            assertEquals(1, scalar(statement, """
                    SELECT count(*)
                    FROM manager_permission_delegations delegation
                    JOIN permissions permission
                      ON permission.id=delegation.permission_id
                    WHERE delegation.user_id='%s'::uuid
                      AND permission.code='webinquiry:manage'
                      AND delegation.enabled=false
                      AND delegation.row_version=8
                    """.formatted(TARGET_USER_ID)));
            assertEquals(0, scalar(statement, """
                    SELECT count(*)
                    FROM manager_permission_delegations delegation
                    JOIN permissions permission
                      ON permission.id=delegation.permission_id
                    WHERE delegation.user_id='%s'::uuid
                      AND permission.code IN (
                          'webinquiry:claim',
                          'webinquiry:close',
                          'webinquiry:convert_client')
                    """.formatted(TARGET_USER_ID)));
            assertEquals(1, scalar(statement, """
                    SELECT count(*)
                    FROM manager_permission_delegations delegation
                    JOIN permissions permission
                      ON permission.id=delegation.permission_id
                    WHERE delegation.user_id='%s'::uuid
                      AND permission.code='stock:view'
                      AND delegation.enabled=false
                      AND delegation.row_version=12
                    """.formatted(TARGET_USER_ID)));
            assertEquals(0, scalar(statement, """
                    SELECT count(*)
                    FROM manager_permission_delegations delegation
                    JOIN permissions permission
                      ON permission.id=delegation.permission_id
                    WHERE delegation.user_id='%s'::uuid
                      AND permission.code='stock:view'
                      AND delegation.enabled=true
                    """.formatted(TARGET_USER_ID)));
        }
    }

    @Test
    void taxonomyBoundaryAdvancesVersionsAndRevokesOnlyLiveTokenFamilies()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertTrue(scalar(statement, """
                    SELECT epoch FROM authorization_state WHERE singleton_id=1
                    """) > epochBefore);
            assertTrue(authVersion(statement, GRANTOR_USER_ID) > grantorAuthBefore);
            assertTrue(authVersion(statement, TARGET_USER_ID) > targetAuthBefore);
            assertEquals(2, scalar(statement, """
                    SELECT count(*) FROM refresh_tokens
                    WHERE token_hash IN ('v328-active-grantor', 'v328-active-target')
                      AND revoked_at IS NOT NULL
                    """));
            assertEquals(1, scalar(statement, """
                    SELECT count(*) FROM refresh_tokens
                    WHERE token_hash='v328-already-revoked'
                      AND revoked_at='%s'::timestamptz
                    """.formatted(ALREADY_REVOKED_AT)));
        }
    }

    private static String managerDelegationInsert(
            UUID userId, String permissionId, boolean enabled, long rowVersion) {
        return managerDelegationInsert(
                userId, permissionId, enabled, rowVersion, "org.employee");
    }

    private static String managerDelegationInsert(
            UUID userId,
            String permissionId,
            boolean enabled,
            long rowVersion,
            String surfaceKey) {
        return """
                INSERT INTO manager_permission_delegations(
                    user_id, permission_id, department_id, enabled,
                    surface_key, granted_by_user_id, row_version,
                    created_at, updated_at, created_by, updated_by,
                    target_user_generation,
                    target_employee_generation,
                    target_department_generation,
                    grantor_user_generation,
                    grantor_employee_generation,
                    grantor_auth_version,
                    grantor_authorization_epoch,
                    scope_source,
                    scope_department_id,
                    scope_generation,
                    scope_assignment_id,
                    scope_assignment_version
                )
                SELECT
                    target_user.id,
                    '%s'::uuid,
                    target_department.id,
                    %s,
                    '%s',
                    grantor_user.id,
                    %d,
                    '2026-07-02T08:00:00+08:00'::timestamptz,
                    '2026-07-03T08:00:00+08:00'::timestamptz,
                    grantor_user.id,
                    grantor_user.id,
                    target_user.permission_delegation_generation,
                    target_employee.permission_delegation_generation,
                    target_department.permission_delegation_generation,
                    grantor_user.permission_delegation_generation,
                    null,
                    grantor_user.auth_version,
                    auth_state.epoch,
                    'SUPER_ADMIN',
                    null,
                    null,
                    null,
                    null
                FROM users target_user
                JOIN employees target_employee
                  ON target_employee.id=target_user.employee_id
                JOIN departments target_department
                  ON target_department.id=target_employee.department_id
                CROSS JOIN users grantor_user
                CROSS JOIN authorization_state auth_state
                WHERE target_user.id='%s'::uuid
                  AND grantor_user.id='%s'::uuid
                  AND auth_state.singleton_id=1
                """.formatted(
                permissionId, enabled, surfaceKey, rowVersion,
                userId, GRANTOR_USER_ID);
    }

    private static String subjectDifferenceSql(
            String table,
            String subjectColumn,
            String oldCode,
            String newCode,
            String oldPredicate,
            String newPredicate) {
        return """
                SELECT
                    (SELECT count(*) FROM (
                        (SELECT source.%s
                         FROM %s source
                         JOIN permissions permission
                           ON permission.id=source.permission_id
                         WHERE permission.code='%s' AND %s)
                        EXCEPT
                        (SELECT target.%s
                         FROM %s target
                         JOIN permissions permission
                           ON permission.id=target.permission_id
                         WHERE permission.code='%s' AND %s)
                    ) old_missing)
                    +
                    (SELECT count(*) FROM (
                        (SELECT target.%s
                         FROM %s target
                         JOIN permissions permission
                           ON permission.id=target.permission_id
                         WHERE permission.code='%s' AND %s)
                        EXCEPT
                        (SELECT source.%s
                         FROM %s source
                         JOIN permissions permission
                           ON permission.id=source.permission_id
                         WHERE permission.code='%s' AND %s)
                    ) new_extra)
                """.formatted(
                subjectColumn, table, oldCode, oldPredicate,
                subjectColumn, table, newCode, newPredicate,
                subjectColumn, table, newCode, newPredicate,
                subjectColumn, table, oldCode, oldPredicate);
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

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static long authVersion(Statement statement, UUID userId)
            throws Exception {
        return scalar(statement, """
                SELECT auth_version FROM users WHERE id='%s'::uuid
                """.formatted(userId));
    }

    private static long scalar(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next(), sql);
            return result.getLong(1);
        }
    }

    private static String text(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next(), sql);
            return result.getString(1);
        }
    }
}
