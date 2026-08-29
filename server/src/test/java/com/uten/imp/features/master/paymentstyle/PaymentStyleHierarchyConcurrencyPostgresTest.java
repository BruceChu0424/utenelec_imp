package com.uten.imp.features.master.paymentstyle;

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
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Duration;
import java.time.LocalDate;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Real PostgreSQL proof for the payment-style hierarchy/reference lock protocol.
 *
 * <p>Hierarchy writes take the production advisory lock explicitly. Reference writes execute only
 * the real {@code finance_expense_items} insert; V265's BEFORE trigger must take that same lock and
 * revalidate the referenced node. The two tests exercise both acquisition orders against a schema
 * built by the complete Flyway chain.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PaymentStyleHierarchyConcurrencyPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static final String HIERARCHY_LOCK_SQL =
            "SELECT pg_advisory_xact_lock(hashtextextended('PAYMENT_STYLE_HIERARCHY',0))";

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
    void hierarchyChangeBlocksReferenceWriterAndWriterRechecksLeafAfterRelease() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            Seed seed = seedExpenseLeaf("HIERARCHY-FIRST");
            CountDownLatch hierarchyChanged = new CountDownLatch(1);
            CountDownLatch releaseHierarchy = new CountDownLatch(1);
            CountDownLatch referenceInsertStarted = new CountDownLatch(1);

            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<Void> hierarchy = executor.submit(() -> {
                    addChildWhileHoldingHierarchyLock(
                            seed.styleId(), hierarchyChanged, releaseHierarchy);
                    return null;
                });
                assertTrue(hierarchyChanged.await(5, TimeUnit.SECONDS));

                Future<ReferenceAttempt> reference = executor.submit(() ->
                        insertExpenseReference(
                                seed,
                                referenceInsertStarted,
                                null,
                                null));

                assertTrue(referenceInsertStarted.await(5, TimeUnit.SECONDS));
                assertThrows(
                        TimeoutException.class,
                        () -> reference.get(500, TimeUnit.MILLISECONDS),
                        "the real insert must block inside V265 while the hierarchy transaction owns the advisory lock");

                releaseHierarchy.countDown();
                hierarchy.get(5, TimeUnit.SECONDS);
                ReferenceAttempt attempt = reference.get(5, TimeUnit.SECONDS);
                assertFalse(attempt.inserted());
                assertEquals("23514", attempt.sqlState());
                assertTrue(
                        attempt.message().contains("只能引用无子类别的叶子节点"),
                        "after the lock is released, V265 must reject the now non-leaf reference");
            } finally {
                releaseHierarchy.countDown();
            }

            assertEquals(1, childCount(seed.styleId()));
            assertEquals(0, expenseReferenceCount(seed.styleId()));
        });
    }

    @Test
    void referenceWriterBlocksHierarchyChangeAndHierarchyRechecksReferenceAfterRelease() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            Seed seed = seedExpenseLeaf("REFERENCE-FIRST");
            UUID targetParentId = insertStyle("TARGET-PARENT", "并发测试目标目录", null);
            CountDownLatch referenceInserted = new CountDownLatch(1);
            CountDownLatch releaseReference = new CountDownLatch(1);
            CountDownLatch hierarchyReachedLock = new CountDownLatch(1);
            CountDownLatch hierarchyAcquiredLock = new CountDownLatch(1);

            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<ReferenceAttempt> reference = executor.submit(() ->
                        insertExpenseReference(
                                seed,
                                null,
                                referenceInserted,
                                releaseReference));
                assertTrue(referenceInserted.await(5, TimeUnit.SECONDS));

                Future<HierarchyAttempt> hierarchy = executor.submit(() ->
                        moveStyleIfUnreferenced(
                                seed.styleId(),
                                targetParentId,
                                hierarchyReachedLock,
                                hierarchyAcquiredLock));

                assertTrue(hierarchyReachedLock.await(5, TimeUnit.SECONDS));
                assertFalse(
                        hierarchyAcquiredLock.await(500, TimeUnit.MILLISECONDS),
                        "the hierarchy transaction must wait on the lock acquired by V265 for the real insert");

                releaseReference.countDown();
                ReferenceAttempt referenceAttempt = reference.get(5, TimeUnit.SECONDS);
                assertTrue(referenceAttempt.inserted());

                HierarchyAttempt attempt = hierarchy.get(5, TimeUnit.SECONDS);
                assertEquals(1, attempt.referenceCount());
                assertFalse(
                        attempt.moved(),
                        "after acquiring the lock, hierarchy maintenance must see the committed reference and refuse the move");
            } finally {
                releaseReference.countDown();
            }

            assertEquals(1, expenseReferenceCount(seed.styleId()));
            assertNull(parentId(seed.styleId()));
        });
    }

    @Test
    void accountUuidReferenceGuardRejectsMissingOrWrongStyleAndAcceptsActiveAccountLeaf()
            throws Exception {
        UUID accountStyleId = insertStyle(
                "ACCOUNT-UUID", "并发测试账户科目", null, "ACCOUNT");
        UUID expenseStyleId = insertStyle(
                "ACCOUNT-WRONG", "并发测试错误科目", null, "EXPENSE");

        try (Connection connection = connection()) {
            SQLException missingStyle = assertThrows(
                    SQLException.class,
                    () -> insertAccount(connection, null));
            assertEquals("23514", missingStyle.getSQLState());
            assertTrue(missingStyle.getMessage().contains(
                    "active account requires an ACCOUNT leaf style_id UUID"));

            assertEquals(1, insertAccount(connection, accountStyleId));

            SQLException error = assertThrows(
                    SQLException.class,
                    () -> insertAccount(connection, expenseStyleId));
            assertEquals("23514", error.getSQLState());
            assertTrue(error.getMessage().contains("ACCOUNT"));
        }
    }

    @Test
    void legacyFinanceCleanupBreaksReverseStyleLinkBeforeDeletingAccounts()
            throws Exception {
        try (Connection connection = connection()) {
            UUID styleId = insertStyle(
                    connection, "LEGACY-CLEANUP", "旧库重跑反向关联", null, "ACCOUNT");
            UUID accountId = UUID.randomUUID();
            try (PreparedStatement account = connection.prepareStatement("""
                    INSERT INTO accounts (
                        id, code, name, account_type, style_id, currency_id)
                    VALUES (?, ?, ?, 'BANK', ?, (
                        SELECT id FROM currencies WHERE is_base_currency))
                    """)) {
                account.setObject(1, accountId);
                account.setString(2, "AC-TX-" + shortId());
                account.setString(3, "旧库重跑清理账户-" + shortId());
                account.setObject(4, styleId);
                assertEquals(1, account.executeUpdate());
            }

            try (PreparedStatement link = connection.prepareStatement("""
                    UPDATE payment_styles SET linked_account_id = ? WHERE id = ?
                    """)) {
                link.setObject(1, accountId);
                link.setObject(2, styleId);
                assertEquals(1, link.executeUpdate());
            }

            int accountCountBefore = scalar(connection, "SELECT COUNT(*) FROM accounts");
            try (Statement cleanup = connection.createStatement()) {
                assertTrue(cleanup.executeUpdate(
                        "UPDATE payment_styles SET linked_account_id=NULL "
                                + "WHERE linked_account_id IS NOT NULL") >= 1);
                assertEquals(accountCountBefore,
                        cleanup.executeUpdate("DELETE FROM accounts"));
            }
        }
    }

    @Test
    void legacyFinanceCleanupRestoresForeignKeyChecksBeforeDeletingAccounts()
            throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            UUID styleId = insertStyle(
                    connection, "LEGACY-FK-PROBE", "旧库重跑外键探针科目", null, "ACCOUNT");
            UUID accountId = UUID.randomUUID();
            try (PreparedStatement account = connection.prepareStatement("""
                    INSERT INTO accounts (
                        id, code, name, account_type, style_id, currency_id)
                    VALUES (?, ?, ?, 'BANK', ?, (
                        SELECT id FROM currencies WHERE is_base_currency))
                    """)) {
                account.setObject(1, accountId);
                account.setString(2, "AC-TX-" + shortId());
                account.setString(3, "旧库重跑外键探针-" + shortId());
                account.setObject(4, styleId);
                assertEquals(1, account.executeUpdate());
            }
            String probeTable = "account_cleanup_fk_probe_" + shortId();
            try (Statement probe = connection.createStatement()) {
                probe.execute("CREATE TABLE " + probeTable
                        + " (account_id UUID NOT NULL REFERENCES accounts(id))");
            }
            try (PreparedStatement probe = connection.prepareStatement(
                    "INSERT INTO " + probeTable + "(account_id) VALUES (?)")) {
                probe.setObject(1, accountId);
                assertEquals(1, probe.executeUpdate());
            }

            try (Statement role = connection.createStatement()) {
                role.execute("SET session_replication_role=replica");
                role.execute("UPDATE payment_styles SET linked_account_id=NULL "
                        + "WHERE linked_account_id IS NOT NULL");
                role.execute("SET session_replication_role=DEFAULT");
            }

            SQLException error = assertThrows(SQLException.class, () -> {
                try (Statement delete = connection.createStatement()) {
                    delete.executeUpdate("DELETE FROM accounts");
                }
            });
            assertEquals("23503", error.getSQLState());
            connection.rollback();
        }
    }

    @Test
    void disablingStyleBlocksNewActiveAccountBindingAndWriterRechecksStatus()
            throws Exception {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            UUID styleId = insertStyle(
                    "ACCOUNT-DISABLE-FIRST", "账户停用并发科目", null, "ACCOUNT");
            CountDownLatch styleDisabled = new CountDownLatch(1);
            CountDownLatch releaseStyle = new CountDownLatch(1);
            CountDownLatch accountInsertStarted = new CountDownLatch(1);

            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<Void> hierarchy = executor.submit(() -> {
                    disableStyleWhileHoldingHierarchyLock(
                            styleId, styleDisabled, releaseStyle);
                    return null;
                });
                assertTrue(styleDisabled.await(5, TimeUnit.SECONDS));

                Future<ReferenceAttempt> account = executor.submit(() ->
                        insertActiveAccountReference(
                                styleId, accountInsertStarted, null, null));
                assertTrue(accountInsertStarted.await(5, TimeUnit.SECONDS));
                assertThrows(TimeoutException.class,
                        () -> account.get(500, TimeUnit.MILLISECONDS));

                releaseStyle.countDown();
                hierarchy.get(5, TimeUnit.SECONDS);
                ReferenceAttempt attempt = account.get(5, TimeUnit.SECONDS);
                assertFalse(attempt.inserted());
                assertEquals("23514", attempt.sqlState());
                assertTrue(attempt.message().contains("只能引用使用中的类别"));
            } finally {
                releaseStyle.countDown();
            }
        });
    }

    @Test
    void activeAccountBindingBlocksStyleDisableAndHierarchyRechecksAfterRelease()
            throws Exception {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            UUID styleId = insertStyle(
                    "ACCOUNT-REFERENCE-FIRST", "账户引用并发科目", null, "ACCOUNT");
            CountDownLatch accountInserted = new CountDownLatch(1);
            CountDownLatch releaseAccount = new CountDownLatch(1);
            CountDownLatch hierarchyReachedLock = new CountDownLatch(1);
            CountDownLatch hierarchyAcquiredLock = new CountDownLatch(1);

            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<ReferenceAttempt> account = executor.submit(() ->
                        insertActiveAccountReference(
                                styleId, null, accountInserted, releaseAccount));
                assertTrue(accountInserted.await(5, TimeUnit.SECONDS));

                Future<HierarchyAttempt> hierarchy = executor.submit(() ->
                        disableStyleIfNoActiveAccount(
                                styleId, hierarchyReachedLock, hierarchyAcquiredLock));
                assertTrue(hierarchyReachedLock.await(5, TimeUnit.SECONDS));
                assertFalse(hierarchyAcquiredLock.await(500, TimeUnit.MILLISECONDS));

                releaseAccount.countDown();
                assertTrue(account.get(5, TimeUnit.SECONDS).inserted());
                HierarchyAttempt attempt = hierarchy.get(5, TimeUnit.SECONDS);
                assertEquals(1, attempt.referenceCount());
                assertFalse(attempt.moved());
            } finally {
                releaseAccount.countDown();
            }
        });
    }

    private static void addChildWhileHoldingHierarchyLock(
            UUID parentId,
            CountDownLatch hierarchyChanged,
            CountDownLatch releaseHierarchy) throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                lockHierarchy(connection);
                insertStyle(connection, "CHILD", "并发测试子类别", parentId);
                hierarchyChanged.countDown();
                assertTrue(releaseHierarchy.await(5, TimeUnit.SECONDS));
                connection.commit();
            } catch (Throwable error) {
                connection.rollback();
                hierarchyChanged.countDown();
                throw error;
            }
        }
    }

    /** Executes only the business insert; V265 owns locking and reference validation. */
    private static ReferenceAttempt insertExpenseReference(
            Seed seed,
            CountDownLatch insertStarted,
            CountDownLatch referenceInserted,
            CountDownLatch releaseReference) throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                try (PreparedStatement insert = connection.prepareStatement("""
                        INSERT INTO finance_expense_items (
                            id, expense_id, bill_no, bill_date, expense_style_id,
                            amount_original, amount_local, line_no, is_deleted)
                        VALUES (?, ?, ?, ?, ?, 1.0000, 1.0000, 1, false)
                        """)) {
                    insert.setObject(1, UUID.randomUUID());
                    insert.setObject(2, seed.expenseId());
                    insert.setString(3, seed.billNo());
                    insert.setObject(4, seed.billDate());
                    insert.setObject(5, seed.styleId());
                    if (insertStarted != null) insertStarted.countDown();
                    assertEquals(1, insert.executeUpdate());
                }

                if (referenceInserted != null) referenceInserted.countDown();
                if (releaseReference != null) {
                    assertTrue(releaseReference.await(5, TimeUnit.SECONDS));
                }
                connection.commit();
                return ReferenceAttempt.success();
            } catch (SQLException error) {
                connection.rollback();
                return ReferenceAttempt.rejected(error);
            } catch (Throwable error) {
                connection.rollback();
                throw error;
            }
        }
    }

    private static ReferenceAttempt insertActiveAccountReference(
            UUID styleId,
            CountDownLatch insertStarted,
            CountDownLatch accountInserted,
            CountDownLatch releaseAccount) throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                if (insertStarted != null) insertStarted.countDown();
                assertEquals(1, insertAccount(connection, styleId));
                if (accountInserted != null) accountInserted.countDown();
                if (releaseAccount != null) {
                    assertTrue(releaseAccount.await(5, TimeUnit.SECONDS));
                }
                connection.commit();
                return ReferenceAttempt.success();
            } catch (SQLException error) {
                connection.rollback();
                return ReferenceAttempt.rejected(error);
            } catch (Throwable error) {
                connection.rollback();
                throw error;
            }
        }
    }

    private static void disableStyleWhileHoldingHierarchyLock(
            UUID styleId,
            CountDownLatch styleDisabled,
            CountDownLatch releaseStyle) throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                lockHierarchy(connection);
                try (PreparedStatement update = connection.prepareStatement(
                        "UPDATE payment_styles SET status='禁用' WHERE id=?")) {
                    update.setObject(1, styleId);
                    assertEquals(1, update.executeUpdate());
                }
                styleDisabled.countDown();
                assertTrue(releaseStyle.await(5, TimeUnit.SECONDS));
                connection.commit();
            } catch (Throwable error) {
                connection.rollback();
                styleDisabled.countDown();
                throw error;
            }
        }
    }

    private static HierarchyAttempt disableStyleIfNoActiveAccount(
            UUID styleId,
            CountDownLatch reachedLock,
            CountDownLatch acquiredLock) throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                reachedLock.countDown();
                lockHierarchy(connection);
                acquiredLock.countDown();
                int references = activeAccountReferenceCount(connection, styleId);
                boolean disabled = false;
                if (references == 0) {
                    try (PreparedStatement update = connection.prepareStatement(
                            "UPDATE payment_styles SET status='禁用' WHERE id=?")) {
                        update.setObject(1, styleId);
                        disabled = update.executeUpdate() == 1;
                    }
                }
                connection.commit();
                return new HierarchyAttempt(references, disabled);
            } catch (Throwable error) {
                connection.rollback();
                throw error;
            }
        }
    }

    /** Hierarchy-write protocol: take the same lock, then re-read business references. */
    private static HierarchyAttempt moveStyleIfUnreferenced(
            UUID styleId,
            UUID targetParentId,
            CountDownLatch reachedLock,
            CountDownLatch acquiredLock) throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                reachedLock.countDown();
                lockHierarchy(connection);
                acquiredLock.countDown();

                int references = expenseReferenceCount(connection, styleId);
                boolean moved = false;
                if (references == 0) {
                    try (PreparedStatement update = connection.prepareStatement("""
                            UPDATE payment_styles
                            SET parent_id = ?
                            WHERE id = ?
                            """)) {
                        update.setObject(1, targetParentId);
                        update.setObject(2, styleId);
                        moved = update.executeUpdate() == 1;
                    }
                }
                connection.commit();
                return new HierarchyAttempt(references, moved);
            } catch (Throwable error) {
                connection.rollback();
                throw error;
            }
        }
    }

    private static Seed seedExpenseLeaf(String label) throws Exception {
        UUID styleId = insertStyle(label, "并发测试费用类别", null);
        UUID expenseId = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2042, 8, 14);
        String billNo = businessIdentifier("YF", billDate);
        try (Connection connection = connection();
             PreparedStatement insert = connection.prepareStatement("""
                     INSERT INTO finance_expenses (
                         id, bill_no, bill_date, amount_original, amount_local,
                         status, is_deleted)
                     VALUES (?, ?, ?, 1.0000, 1.0000, 0, false)
                     """)) {
            insert.setObject(1, expenseId);
            insert.setString(2, billNo);
            insert.setObject(3, billDate);
            assertEquals(1, insert.executeUpdate());
        }
        return new Seed(styleId, expenseId, billNo, billDate);
    }

    private static UUID insertStyle(String codePrefix, String name, UUID parentId)
            throws Exception {
        return insertStyle(codePrefix, name, parentId, "EXPENSE");
    }

    private static UUID insertStyle(
            String codePrefix, String name, UUID parentId, String category)
            throws Exception {
        try (Connection connection = connection()) {
            return insertStyle(connection, codePrefix, name, parentId, category);
        }
    }

    private static UUID insertStyle(
            Connection connection,
            String codePrefix,
            String name,
            UUID parentId) throws Exception {
        return insertStyle(connection, codePrefix, name, parentId, "EXPENSE");
    }

    private static UUID insertStyle(
            Connection connection,
            String codePrefix,
            String name,
            UUID parentId,
            String category) throws Exception {
        UUID id = UUID.randomUUID();
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO payment_styles (
                    id, code, name, category, parent_id, level, sort_order,
                    status, is_deleted)
                VALUES (?, ?, ?, ?, ?, ?, 0, '使用', false)
                """)) {
            insert.setObject(1, id);
            insert.setString(2, "TX-" + codePrefix + "-" + shortId());
            insert.setString(3, name);
            insert.setString(4, category);
            insert.setObject(5, parentId);
            insert.setInt(6, parentId == null ? 0 : 1);
            assertEquals(1, insert.executeUpdate());
        }
        return id;
    }

    private static int insertAccount(Connection connection, UUID styleId) throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO accounts (
                    id, code, name, account_type, style_id, currency_id)
                VALUES (?, ?, ?, 'BANK', ?, (
                    SELECT id FROM currencies WHERE is_base_currency))
                """)) {
            insert.setObject(1, UUID.randomUUID());
            insert.setString(2, "AC-TX-" + shortId());
            insert.setString(3, "并发测试账户-" + shortId());
            insert.setObject(4, styleId);
            return insert.executeUpdate();
        }
    }

    private static void lockHierarchy(Connection connection) throws Exception {
        try (Statement lock = connection.createStatement()) {
            lock.executeQuery(HIERARCHY_LOCK_SQL).close();
        }
    }

    private static int childCount(UUID styleId) throws Exception {
        try (Connection connection = connection();
             PreparedStatement statement = connection.prepareStatement("""
                     SELECT COUNT(*)
                     FROM payment_styles
                     WHERE parent_id = ? AND COALESCE(is_deleted, false) = false
                     """)) {
            statement.setObject(1, styleId);
            return scalarInt(statement);
        }
    }

    private static int expenseReferenceCount(UUID styleId) throws Exception {
        try (Connection connection = connection()) {
            return expenseReferenceCount(connection, styleId);
        }
    }

    private static int expenseReferenceCount(Connection connection, UUID styleId)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT COUNT(*)
                FROM finance_expense_items
                WHERE expense_style_id = ?
                """)) {
            statement.setObject(1, styleId);
            return scalarInt(statement);
        }
    }

    private static int activeAccountReferenceCount(Connection connection, UUID styleId)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT COUNT(*) FROM accounts
                WHERE style_id=?
                  AND status='使用'
                  AND COALESCE(is_deleted,false)=false
                """)) {
            statement.setObject(1, styleId);
            return scalarInt(statement);
        }
    }

    private static UUID parentId(UUID styleId) throws Exception {
        try (Connection connection = connection();
             PreparedStatement statement = connection.prepareStatement("""
                     SELECT parent_id
                     FROM payment_styles
                     WHERE id = ?
                     """)) {
            statement.setObject(1, styleId);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getObject(1, UUID.class);
            }
        }
    }

    private static int scalarInt(PreparedStatement statement) throws Exception {
        try (ResultSet result = statement.executeQuery()) {
            assertTrue(result.next());
            return result.getInt(1);
        }
    }

    private static int scalar(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getInt(1);
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private static String shortId() {
        return UUID.randomUUID().toString().replace("-", "").substring(0, 12);
    }

    private record Seed(UUID styleId, UUID expenseId, String billNo, LocalDate billDate) {}

    private record ReferenceAttempt(boolean inserted, String sqlState, String message) {
        private static ReferenceAttempt success() {
            return new ReferenceAttempt(true, null, null);
        }

        private static ReferenceAttempt rejected(SQLException error) {
            return new ReferenceAttempt(false, error.getSQLState(), error.getMessage());
        }
    }

    private record HierarchyAttempt(int referenceCount, boolean moved) {}
}
