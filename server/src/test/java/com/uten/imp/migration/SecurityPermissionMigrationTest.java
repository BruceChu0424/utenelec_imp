package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Applies the complete migration chain to a clean PostgreSQL instance and verifies the
 * production security boundaries. This catches SQL that compiles in Java but cannot be deployed.
 */
@EnabledIfEnvironmentVariable(
        named = "UTEN_RUN_DB_TESTS",
        matches = "(?i)true")
class SecurityPermissionMigrationTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() {
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
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void installsNarrowPermissionsAndValidatesLedgerPartyShape()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {

            assertEquals(5, scalarLong(statement, """
                    select count(*)
                    from permissions
                    where code in (
                        'account:support',
                        'authorization:manage',
                        'finance_asset:edit',
                        'finance_post:execute',
                        'finance_shipment_audit'
                    )
                    """));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from department_permissions dp
                    join departments d on d.id = dp.department_id
                    join permissions p on p.id = dp.permission_id
                    where d.code = 'DEPT_HR'
                      and p.code = 'account:support'
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from department_permissions dp
                    join permissions p on p.id = dp.permission_id
                    where p.code in ('user:manage', 'authorization:manage')
                    """));
            assertTrue(scalarBoolean(statement, """
                    select convalidated
                    from pg_constraint
                    where conname = 'ar_ap_ledger_party_shape_chk'
                    """));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from permissions
                    where code = 'expense:pay'
                    """));
            assertEquals(2, scalarLong(statement, """
                    select count(*)
                    from permissions
                    where code in (
                        'employee:pii:edit',
                        'employee:compensation:edit'
                    )
                    """));
            assertEquals(2, scalarLong(statement, """
                    select count(*)
                    from department_permissions dp
                    join departments d on d.id = dp.department_id
                    join permissions p on p.id = dp.permission_id
                    where d.code = 'DEPT_HR'
                      and p.code in (
                          'employee:pii:edit',
                          'employee:compensation:edit'
                      )
                    """));
            assertEquals(15, scalarLong(statement, """
                    select value::bigint
                    from system_settings
                    where key = 'jwt_access_ttl_minutes'
                    """));
            assertEquals(5, scalarLong(statement, """
                    select count(*)
                    from information_schema.tables
                    where table_schema = 'public'
                      and table_name in (
                          'payroll_batches',
                          'expense_claims',
                          'legacy_migration_run_files',
                          'legacy_migration_rejects',
                          'authorization_state'
                      )
                    """));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from pg_attribute a
                    join pg_class c on c.oid = a.attrelid
                    join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public'
                      and c.relname = 'sales_monthly_mv'
                      and c.relkind = 'm'
                      and a.attname = 'owner_employee_id'
                      and a.attnum > 0
                      and not a.attisdropped
                    """));
            assertEquals(7, scalarLong(statement, """
                    select count(*)
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname in (
                          'mv_sales_monthly_uidx',
                          'mv_sales_monthly_owner_ym',
                          'idx_sq_maker_date_active',
                          'idx_so_owner_date_active',
                          'idx_ss_owner_date_active',
                          'idx_sos_owner_date_active',
                          'idx_sr_owner_date_active'
                      )
                    """));
            assertTrue(scalarString(statement, """
                    select indexdef
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname = 'mv_sales_monthly_uidx'
                    """).contains("owner_employee_id"));
            assertEquals(6, scalarLong(statement, """
                    select count(*)
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname in (
                          'idx_visitor_app_account_created_active',
                          'idx_visitor_app_account_status_created_active',
                          'idx_visitor_app_status_created_active',
                          'idx_visitor_app_host_status_created_active',
                          'idx_fixed_assets_code_active',
                          'idx_deferred_expenses_code_active'
                      )
                    """));
            assertEquals(4, scalarLong(statement, """
                    select count(*)
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname in (
                          'idx_suggestions_submitted_stable',
                          'idx_suggestions_submitter_submitted_stable',
                          'idx_suggestions_category_submitted_stable',
                          'idx_suggestion_likes_user_suggestion'
                      )
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname in (
                          'idx_suggestions_submitted',
                          'idx_suggestions_submitter',
                          'idx_suggestion_likes_user'
                      )
                    """));
            assertEquals("numeric(18,4)", scalarString(statement, """
                    select format_type(a.atttypid, a.atttypmod)
                    from pg_attribute a
                    join pg_class c on c.oid = a.attrelid
                    join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public'
                      and c.relname = 'goods'
                      and a.attname = 'price'
                      and a.attnum > 0
                      and not a.attisdropped
                    """));
            assertEquals(300, scalarLong(statement, """
                    select value::bigint
                    from system_settings
                    where key = 'login_ip_rate_limit_per_minute'
                    """));
            assertTrue(scalarBoolean(statement, """
                    select fn_audit_redact_row(
                        'employees',
                        '{"id_card_enc":"secret","phone_hash":"hash","full_name":"张三","status":"active"}'::jsonb
                    ) = '{"status":"active"}'::jsonb
                    """));
            assertEquals("147", scalarString(statement, """
                    select version
                    from flyway_schema_history
                    where success
                    order by installed_rank desc
                    limit 1
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from flyway_schema_history
                    where not success
                    """));
            statement.execute("select refresh_sales_monthly_mv()");
        }
    }

    /**
     * Verifies the PostgreSQL mutex used by SuggestionService.toggleLike.
     *
     * <p>The unit test asserts that the repository method carries PESSIMISTIC_WRITE; this
     * database test proves that two real connections cannot pass the parent-row lock together,
     * both toggles complete without a unique-key race, and two toggles restore the original state.
     */
    @Test
    void suggestionLikeParentRowLockSerializesConcurrentToggles() throws Exception {
        UUID suggestionId = UUID.randomUUID();
        String employeeCode = "SUGGESTION_LOCK_" + suggestionId.toString().replace("-", "");
        String loginAccount = "suggestion-lock-" + suggestionId;
        UUID userId;
        try (Connection connection = openConnection();
             Statement statement = connection.createStatement()) {
            statement.executeUpdate("""
                    insert into employees (
                        code,
                        full_name,
                        gender,
                        id_type,
                        hire_date,
                        status,
                        employment_type,
                        department_id
                    )
                    select
                        '%s',
                        '建议并发测试员工',
                        'male',
                        '其他',
                        current_date,
                        'active',
                        'regular',
                        department_id
                    from employees
                    where code = 'ADMIN'
                    """.formatted(employeeCode));
            statement.executeUpdate("""
                    insert into users (employee_id, login_account, password_hash)
                    select id, '%s', 'test-only-not-a-real-password'
                    from employees
                    where code = '%s'
                    """.formatted(loginAccount, employeeCode));
            userId = UUID.fromString(scalarString(statement, """
                    select id::text
                    from users
                    where login_account = '%s'
                    """.formatted(loginAccount)));
            statement.executeUpdate("""
                    insert into suggestions (
                        id, submitter_id, submitter_name, category, title, content
                    ) values (
                        '%s'::uuid,
                        '%s'::uuid,
                        '并发测试员工',
                        'process',
                        '并发点赞测试',
                        '验证数据库父行锁能够串行化同一建议的点赞切换。'
                    )
                    """.formatted(suggestionId, userId));
        }

        CountDownLatch firstLocked = new CountDownLatch(1);
        CountDownLatch releaseFirst = new CountDownLatch(1);
        CountDownLatch secondStarted = new CountDownLatch(1);
        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            Future<Boolean> first = executor.submit(() -> toggleLike(
                    suggestionId, userId, null, firstLocked, releaseFirst));
            assertTrue(firstLocked.await(5, TimeUnit.SECONDS));

            Future<Boolean> second = executor.submit(() -> toggleLike(
                    suggestionId, userId, secondStarted, null, null));
            assertTrue(secondStarted.await(5, TimeUnit.SECONDS));
            assertThrows(
                    TimeoutException.class,
                    () -> second.get(250, TimeUnit.MILLISECONDS),
                    "the second transaction must wait for the suggestion row lock");

            releaseFirst.countDown();
            assertTrue(first.get(5, TimeUnit.SECONDS));
            assertFalse(second.get(5, TimeUnit.SECONDS));

            try (Connection connection = openConnection();
                 Statement statement = connection.createStatement()) {
                assertEquals(0, scalarLong(statement, """
                        select count(*)
                        from suggestion_likes
                        where suggestion_id = '%s'::uuid
                          and user_id = '%s'::uuid
                        """.formatted(suggestionId, userId)));
            }
        } finally {
            releaseFirst.countDown();
            executor.shutdownNow();
            try (Connection connection = openConnection();
                 PreparedStatement cleanupSuggestion =
                         connection.prepareStatement("delete from suggestions where id = ?");
                 PreparedStatement cleanupEmployee =
                         connection.prepareStatement("delete from employees where code = ?")) {
                cleanupSuggestion.setObject(1, suggestionId);
                cleanupSuggestion.executeUpdate();
                cleanupEmployee.setString(1, employeeCode);
                cleanupEmployee.executeUpdate();
            }
        }
    }

    @Test
    void authorizationVersionsInvalidateDirectAndSharedPermissionSnapshots()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
            Statement statement = connection.createStatement()) {
            connection.setAutoCommit(false);
            try {
                statement.executeUpdate("""
                        insert into users(employee_id, login_account, password_hash)
                        select id, 'migration-auth-version-test', 'test-only-not-a-real-password'
                        from employees
                        where code = 'ADMIN'
                        on conflict do nothing
                        """);
                String userId = scalarString(statement, """
                        select id::text
                        from users
                        where login_account = 'migration-auth-version-test'
                        """);
                long userVersionBefore = scalarLong(statement, """
                        select auth_version from users where id = '%s'::uuid
                        """.formatted(userId));
                statement.executeUpdate("""
                        insert into user_permission_overrides(user_id, permission_id, effect)
                        select '%s'::uuid, p.id, 'grant'
                        from permissions p
                        where not exists (
                            select 1
                            from user_permission_overrides o
                            where o.user_id = '%s'::uuid
                              and o.permission_id = p.id
                        )
                        order by p.code
                        limit 1
                        """.formatted(userId, userId));
                assertEquals(userVersionBefore + 1, scalarLong(statement, """
                        select auth_version from users where id = '%s'::uuid
                        """.formatted(userId)));

                long epochBefore = scalarLong(statement, """
                        select epoch from authorization_state where singleton_id = 1
                        """);
                statement.executeUpdate("""
                        update departments
                        set parent_id = parent_id
                        where id = (select id from departments order by id limit 1)
                        """);
                assertEquals(epochBefore + 1, scalarLong(statement, """
                        select epoch from authorization_state where singleton_id = 1
                        """));
            } finally {
                connection.rollback();
            }
        }
    }

    private long scalarLong(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }

    private boolean scalarBoolean(Statement statement, String sql)
            throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getBoolean(1);
        }
    }

    private String scalarString(Statement statement, String sql)
            throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getString(1);
        }
    }

    private Connection openConnection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private boolean toggleLike(
            UUID suggestionId,
            UUID userId,
            CountDownLatch beforeLock,
            CountDownLatch afterLock,
            CountDownLatch releaseAfterMutation) throws Exception {
        try (Connection connection = openConnection()) {
            connection.setAutoCommit(false);
            try {
                if (beforeLock != null) beforeLock.countDown();
                try (PreparedStatement lock = connection.prepareStatement(
                        "select id from suggestions where id = ? for update")) {
                    lock.setObject(1, suggestionId);
                    try (ResultSet result = lock.executeQuery()) {
                        assertTrue(result.next());
                    }
                }
                if (afterLock != null) afterLock.countDown();

                boolean exists;
                try (PreparedStatement query = connection.prepareStatement("""
                        select exists (
                            select 1
                            from suggestion_likes
                            where suggestion_id = ? and user_id = ?
                        )
                        """)) {
                    query.setObject(1, suggestionId);
                    query.setObject(2, userId);
                    try (ResultSet result = query.executeQuery()) {
                        result.next();
                        exists = result.getBoolean(1);
                    }
                }
                String mutation = exists
                        ? "delete from suggestion_likes where suggestion_id = ? and user_id = ?"
                        : "insert into suggestion_likes(suggestion_id, user_id) values (?, ?)";
                try (PreparedStatement update = connection.prepareStatement(mutation)) {
                    update.setObject(1, suggestionId);
                    update.setObject(2, userId);
                    update.executeUpdate();
                }
                if (releaseAfterMutation != null
                        && !releaseAfterMutation.await(5, TimeUnit.SECONDS)) {
                    throw new IllegalStateException("timed out waiting to release first toggle");
                }
                connection.commit();
                return !exists;
            } catch (Exception exception) {
                connection.rollback();
                throw exception;
            }
        }
    }
}
