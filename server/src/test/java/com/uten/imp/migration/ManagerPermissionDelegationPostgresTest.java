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
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ManagerPermissionDelegationPostgresTest {

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
    void delegationAndUpstreamChangesInvalidateTargetAndRemainAudited()
            throws Exception {
        UUID grantorEmployeeId = UUID.randomUUID();
        UUID targetEmployeeId = UUID.randomUUID();
        UUID grantorUserId = UUID.randomUUID();
        UUID targetUserId = UUID.randomUUID();
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            String departmentId = scalarText(statement,
                    "select id::text from departments where code = 'DEPT_SALES'");
            String permissionId = scalarText(statement,
                    "select id::text from permissions where code = 'sales_order:view'");
            statement.executeUpdate("""
                    insert into employees(
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type
                    ) values
                    ('%s'::uuid, 'V315-GRANTOR', 'Grantor', '其他', '%s'::uuid,
                     current_date, 'active', 'regular'),
                    ('%s'::uuid, 'V315-TARGET', 'Target', '其他', '%s'::uuid,
                     current_date, 'active', 'regular')
                    """.formatted(
                    grantorEmployeeId, departmentId,
                    targetEmployeeId, departmentId));
            statement.executeUpdate("""
                    insert into users(id, employee_id, login_account, password_hash, must_change_password)
                    values
                    ('%s'::uuid, '%s'::uuid, 'v315-grantor', 'test-only', false),
                    ('%s'::uuid, '%s'::uuid, 'v315-target', 'test-only', false)
                    """.formatted(
                    grantorUserId, grantorEmployeeId,
                    targetUserId, targetEmployeeId));
            statement.executeUpdate("""
                    update departments
                    set manager_id = '%s'::uuid
                    where id = '%s'::uuid
                    """.formatted(grantorEmployeeId, departmentId));

            long beforeInsert = scalarLong(statement, """
                    select auth_version from users where id = '%s'::uuid
                    """.formatted(targetUserId));
            statement.execute("""
                    select set_config('app.actor_id', '%s', false)
                    """.formatted(grantorUserId));
            statement.executeUpdate("""
                    insert into manager_permission_delegations(
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
                        scope_generation
                    )
                    select
                        '%s'::uuid, '%s'::uuid, '%s'::uuid, true,
                        'sales.order', '%s'::uuid, '%s'::uuid, '%s'::uuid,
                        target_user.permission_delegation_generation,
                        target_employee.permission_delegation_generation,
                        target_department.permission_delegation_generation,
                        grantor_user.permission_delegation_generation,
                        grantor_employee.permission_delegation_generation,
                        grantor_user.auth_version,
                        auth_state.epoch,
                        'DEPARTMENT_MANAGER',
                        target_department.id,
                        target_department.permission_delegation_generation
                    from users target_user
                    join employees target_employee
                      on target_employee.id = target_user.employee_id
                    cross join users grantor_user
                    join employees grantor_employee
                      on grantor_employee.id = grantor_user.employee_id
                    cross join departments target_department
                    cross join authorization_state auth_state
                    where target_user.id = '%s'::uuid
                      and grantor_user.id = '%s'::uuid
                      and target_department.id = '%s'::uuid
                      and auth_state.singleton_id = 1
                    """.formatted(
                    targetUserId, permissionId, departmentId,
                    grantorUserId, grantorUserId, grantorUserId,
                    targetUserId, grantorUserId, departmentId));
            assertEquals(beforeInsert + 1, scalarLong(statement, """
                    select auth_version from users where id = '%s'::uuid
                    """.formatted(targetUserId)));
            assertTrue(scalarLong(statement, """
                    select count(*)
                    from audit_log
                    where target_type = 'manager_permission_delegations'
                      and action = 'insert'
                    """) >= 1);

            long beforeGrantorOverride = scalarLong(statement, """
                    select auth_version from users where id = '%s'::uuid
                    """.formatted(targetUserId));
            long epochBeforeGrantorOverride = scalarLong(statement, """
                    select epoch from authorization_state where singleton_id = 1
                    """);
            statement.executeUpdate("""
                    insert into user_permission_overrides(user_id, permission_id, effect)
                    values ('%s'::uuid, '%s'::uuid, 'revoke')
                    """.formatted(grantorUserId, permissionId));
            assertEquals(beforeGrantorOverride, scalarLong(statement, """
                    select auth_version from users where id = '%s'::uuid
                    """.formatted(targetUserId)));
            assertTrue(scalarLong(statement, """
                    select epoch from authorization_state where singleton_id = 1
                    """) > epochBeforeGrantorOverride);

            String otherDepartmentId = scalarText(statement,
                    "select id::text from departments where code = 'DEPT_FIN'");
            statement.executeUpdate("""
                    update employees
                    set department_id = '%s'::uuid
                    where id = '%s'::uuid
                    """.formatted(otherDepartmentId, targetEmployeeId));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from manager_permission_delegations
                    where user_id = '%s'::uuid and enabled = true
                    """.formatted(targetUserId)));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from manager_permission_delegations delegation
                    join users target_user on target_user.id = delegation.user_id
                    join employees target_employee on target_employee.id = target_user.employee_id
                    where delegation.user_id = '%s'::uuid
                      and delegation.target_employee_generation =
                          target_employee.permission_delegation_generation
                    """.formatted(targetUserId)));

            statement.executeUpdate("""
                    update employees
                    set department_id = '%s'::uuid
                    where id = '%s'::uuid
                    """.formatted(departmentId, targetEmployeeId));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from manager_permission_delegations
                    where user_id = '%s'::uuid and enabled = true
                    """.formatted(targetUserId)));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from manager_permission_delegations delegation
                    join users target_user on target_user.id = delegation.user_id
                    join employees target_employee on target_employee.id = target_user.employee_id
                    where delegation.user_id = '%s'::uuid
                      and delegation.target_employee_generation =
                          target_employee.permission_delegation_generation
                    """.formatted(targetUserId)));

            statement.executeUpdate("""
                    update departments
                    set manager_id = null
                    where id = '%s'::uuid
                    """.formatted(departmentId));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from manager_permission_delegations
                    where user_id = '%s'::uuid and enabled = true
                    """.formatted(targetUserId)));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from manager_permission_delegations delegation
                    join departments scope
                      on scope.id = delegation.scope_department_id
                    where delegation.user_id = '%s'::uuid
                      and delegation.scope_generation =
                          scope.permission_delegation_generation
                    """.formatted(targetUserId)));

            statement.executeUpdate("""
                    drop trigger trg_audit_manager_permission_delegations
                    on manager_permission_delegations
                    """);
            statement.execute(Files.readString(
                    Path.of(
                            "src/main/resources/db/migration",
                            "V325__refresh_audit_trigger_coverage.sql"),
                    StandardCharsets.UTF_8));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from pg_trigger trigger
                    join pg_proc function on function.oid = trigger.tgfoid
                    where trigger.tgrelid = 'manager_permission_delegations'::regclass
                      and trigger.tgname like 'trg_audit%%'
                      and not trigger.tgisinternal
                      and function.proname in ('fn_audit', 'fn_audit_redacted')
                    """));
        }
    }

    @Test
    void firstInsertRacingManagerReplacementCannotReviveAfterAba() throws Exception {
        UUID grantorEmployeeId = UUID.randomUUID();
        UUID targetEmployeeId = UUID.randomUUID();
        UUID grantorUserId = UUID.randomUUID();
        UUID targetUserId = UUID.randomUUID();
        String departmentId;
        String permissionId;
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            departmentId = scalarText(statement,
                    "select id::text from departments where code = 'DEPT_SALES'");
            permissionId = scalarText(statement,
                    "select id::text from permissions where code = 'sales_order:view'");
            statement.executeUpdate("""
                    insert into employees(
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type
                    ) values
                    ('%s'::uuid, 'V322-RACE-GRANTOR', 'Race Grantor', '其他', '%s'::uuid,
                     current_date, 'active', 'regular'),
                    ('%s'::uuid, 'V322-RACE-TARGET', 'Race Target', '其他', '%s'::uuid,
                     current_date, 'active', 'regular')
                    """.formatted(
                    grantorEmployeeId, departmentId,
                    targetEmployeeId, departmentId));
            statement.executeUpdate("""
                    insert into users(
                        id, employee_id, login_account, password_hash,
                        must_change_password
                    ) values
                    ('%s'::uuid, '%s'::uuid, 'v322-race-grantor', 'test-only', false),
                    ('%s'::uuid, '%s'::uuid, 'v322-race-target', 'test-only', false)
                    """.formatted(
                    grantorUserId, grantorEmployeeId,
                    targetUserId, targetEmployeeId));
            statement.executeUpdate("""
                    update departments
                    set manager_id = '%s'::uuid
                    where id = '%s'::uuid
                    """.formatted(grantorEmployeeId, departmentId));
        }

        CountDownLatch grantInputsLocked = new CountDownLatch(1);
        CountDownLatch managerChangeStarted = new CountDownLatch(1);
        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            Future<?> grant = executor.submit(() -> {
                try (Connection connection = connection();
                     Statement statement = connection.createStatement()) {
                    connection.setAutoCommit(false);
                    statement.executeQuery("""
                            select id from employees
                            where id in ('%s'::uuid, '%s'::uuid)
                            order by id for update
                            """.formatted(grantorEmployeeId, targetEmployeeId)).close();
                    statement.executeQuery("""
                            select id from users
                            where id in ('%s'::uuid, '%s'::uuid)
                            order by id for update
                            """.formatted(grantorUserId, targetUserId)).close();
                    statement.executeQuery("""
                            select id from departments
                            where id = '%s'::uuid for update
                            """.formatted(departmentId)).close();
                    statement.executeQuery("""
                            select epoch from authorization_state
                            where singleton_id = 1 for update
                            """).close();
                    grantInputsLocked.countDown();
                    if (!managerChangeStarted.await(5, TimeUnit.SECONDS)) {
                        throw new IllegalStateException("manager change did not start");
                    }
                    statement.executeUpdate("""
                            insert into manager_permission_delegations(
                                user_id, permission_id, department_id, enabled,
                                surface_key, granted_by_user_id,
                                target_user_generation,
                                target_employee_generation,
                                target_department_generation,
                                grantor_user_generation,
                                grantor_employee_generation,
                                grantor_auth_version,
                                grantor_authorization_epoch,
                                scope_source,
                                scope_department_id,
                                scope_generation
                            )
                            select
                                target_user.id, '%s'::uuid, target_department.id, true,
                                'sales.order', grantor_user.id,
                                target_user.permission_delegation_generation,
                                target_employee.permission_delegation_generation,
                                target_department.permission_delegation_generation,
                                grantor_user.permission_delegation_generation,
                                grantor_employee.permission_delegation_generation,
                                grantor_user.auth_version,
                                auth_state.epoch,
                                'DEPARTMENT_MANAGER',
                                target_department.id,
                                target_department.permission_delegation_generation
                            from users target_user
                            join employees target_employee
                              on target_employee.id = target_user.employee_id
                            cross join users grantor_user
                            join employees grantor_employee
                              on grantor_employee.id = grantor_user.employee_id
                            cross join departments target_department
                            cross join authorization_state auth_state
                            where target_user.id = '%s'::uuid
                              and grantor_user.id = '%s'::uuid
                              and target_department.id = '%s'::uuid
                              and auth_state.singleton_id = 1
                            """.formatted(
                            permissionId, targetUserId, grantorUserId, departmentId));
                    connection.commit();
                } catch (Exception exception) {
                    throw new RuntimeException(exception);
                }
            });
            Future<?> managerChange = executor.submit(() -> {
                try (Connection connection = connection();
                     Statement statement = connection.createStatement()) {
                    if (!grantInputsLocked.await(5, TimeUnit.SECONDS)) {
                        throw new IllegalStateException("grant did not lock inputs");
                    }
                    connection.setAutoCommit(false);
                    managerChangeStarted.countDown();
                    statement.executeUpdate("""
                            update departments set manager_id = null
                            where id = '%s'::uuid
                            """.formatted(departmentId));
                    connection.commit();
                } catch (Exception exception) {
                    throw new RuntimeException(exception);
                }
            });
            grant.get(15, TimeUnit.SECONDS);
            managerChange.get(15, TimeUnit.SECONDS);
        } finally {
            executor.shutdownNow();
        }

        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            statement.executeUpdate("""
                    update departments
                    set manager_id = '%s'::uuid
                    where id = '%s'::uuid
                    """.formatted(grantorEmployeeId, departmentId));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from manager_permission_delegations delegation
                    join departments scope
                      on scope.id = delegation.scope_department_id
                    cross join authorization_state auth_state
                    where delegation.user_id = '%s'::uuid
                      and delegation.enabled = true
                      and (
                        delegation.scope_generation <>
                            scope.permission_delegation_generation
                        or delegation.grantor_authorization_epoch <>
                            auth_state.epoch
                      )
                    """.formatted(targetUserId)));
        }
    }

    @Test
    void temporaryLockAndCurrentEmploymentTransitionsPreserveGenerationOnly()
            throws Exception {
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            String departmentId = scalarText(statement,
                    "select id::text from departments where code = 'DEPT_FIN'");
            statement.executeUpdate("""
                    insert into employees(
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type
                    ) values ('%s'::uuid, 'V322-STATE', 'State Target', '其他',
                              '%s'::uuid, current_date, 'active', 'regular')
                    """.formatted(employeeId, departmentId));
            statement.executeUpdate("""
                    insert into users(
                        id, employee_id, login_account, password_hash,
                        must_change_password
                    ) values ('%s'::uuid, '%s'::uuid, 'v322-state',
                              'test-only', false)
                    """.formatted(userId, employeeId));

            long userGeneration = scalarLong(statement, """
                    select permission_delegation_generation
                    from users where id = '%s'::uuid
                    """.formatted(userId));
            statement.executeUpdate("""
                    update users
                    set status = 'locked', locked_until = now() + interval '15 minutes'
                    where id = '%s'::uuid
                    """.formatted(userId));
            statement.executeUpdate("""
                    update users
                    set status = 'active', locked_until = null
                    where id = '%s'::uuid
                    """.formatted(userId));
            assertEquals(userGeneration, scalarLong(statement, """
                    select permission_delegation_generation
                    from users where id = '%s'::uuid
                    """.formatted(userId)));

            statement.executeUpdate("""
                    update users
                    set status = 'locked', locked_until = now() + interval '15 minutes'
                    where id = '%s'::uuid
                    """.formatted(userId));
            long beforeManualLock = scalarLong(statement, """
                    select permission_delegation_generation
                    from users where id = '%s'::uuid
                    """.formatted(userId));
            statement.executeUpdate("""
                    update users set locked_until = null where id = '%s'::uuid
                    """.formatted(userId));
            assertEquals(beforeManualLock + 1, scalarLong(statement, """
                    select permission_delegation_generation
                    from users where id = '%s'::uuid
                    """.formatted(userId)));

            long employeeGeneration = scalarLong(statement, """
                    select permission_delegation_generation
                    from employees where id = '%s'::uuid
                    """.formatted(employeeId));
            for (String status : new String[]{"probation", "onLeave", "active"}) {
                statement.executeUpdate("""
                        update employees set status = '%s' where id = '%s'::uuid
                        """.formatted(status, employeeId));
            }
            assertEquals(employeeGeneration, scalarLong(statement, """
                    select permission_delegation_generation
                    from employees where id = '%s'::uuid
                    """.formatted(employeeId)));

            statement.executeUpdate("""
                    update employees set status = 'resigned' where id = '%s'::uuid
                    """.formatted(employeeId));
            statement.executeUpdate("""
                    update employees set status = 'active' where id = '%s'::uuid
                    """.formatted(employeeId));
            assertEquals(employeeGeneration + 2, scalarLong(statement, """
                    select permission_delegation_generation
                    from employees where id = '%s'::uuid
                    """.formatted(employeeId)));
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static long scalarLong(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }

    private static String scalarText(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getString(1);
        }
    }
}
