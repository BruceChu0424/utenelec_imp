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
import java.sql.SQLException;
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AccountBalanceAdjustmentBatchShapePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static UUID actorId;
    private static UUID currencyId;
    private static UUID accountStyleId;
    private static UUID firstAccountId;
    private static UUID secondAccountId;

    @BeforeAll
    static void migrateAndSeed() throws Exception {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        try (Connection connection = connection()) {
            actorId = uuid(connection, "SELECT id FROM employees ORDER BY id LIMIT 1");
            accountStyleId = uuid(connection, """
                    SELECT style.id FROM payment_styles style
                    WHERE style.category='ACCOUNT' AND style.status='使用'
                      AND COALESCE(style.is_deleted,FALSE)=FALSE
                      AND NOT EXISTS(SELECT 1 FROM payment_styles child
                                     WHERE child.parent_id=style.id
                                       AND COALESCE(child.is_deleted,FALSE)=FALSE)
                    ORDER BY style.id LIMIT 1
                    """);
            currencyId = UUID.randomUUID();
            try (PreparedStatement insert = connection.prepareStatement("""
                    INSERT INTO currencies(
                        id,code,name,exchange_rate,status,auto_created,is_deleted)
                    VALUES(?, 'BZ900001', '人民币测试币种', 1, '使用', FALSE, FALSE)
                    """)) {
                insert.setObject(1, currencyId);
                assertEquals(1, insert.executeUpdate());
            }
            firstAccountId = insertAccount(connection, "ZH900001", "批次形状账户一");
            secondAccountId = insertAccount(connection, "ZH900002", "批次形状账户二");
        }
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void deferredShapeRejectsMissingItemsAndLaterAppend() throws Exception {
        UUID missingBatch = UUID.randomUUID();
        SQLException missing = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection()) {
                connection.setAutoCommit(false);
                insertBatch(connection, missingBatch, "TZ20260827000001");
                connection.commit();
            }
        });
        assertEquals("23514", missing.getSQLState());

        UUID completeBatch = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            insertBatch(connection, completeBatch, "TZ20260827000002");
            insertItem(connection, completeBatch, firstAccountId, 1);
            connection.commit();
        }

        SQLException append = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection()) {
                connection.setAutoCommit(false);
                insertItem(connection, completeBatch, secondAccountId, 2);
                connection.commit();
            }
        });
        assertEquals("23514", append.getSQLState());
        try (Connection connection = connection(); PreparedStatement count = connection.prepareStatement(
                "SELECT COUNT(*) FROM account_balance_adjustment_items WHERE batch_id=?")) {
            count.setObject(1, completeBatch);
            try (ResultSet rows = count.executeQuery()) {
                assertTrue(rows.next());
                assertEquals(1, rows.getInt(1));
            }
        }
    }

    private static UUID insertAccount(Connection connection, String code, String name)
            throws SQLException {
        UUID id = UUID.randomUUID();
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO accounts(
                    id,code,name,account_type,currency_id,style_id,status,is_deleted)
                VALUES(?,?,?,'BANK',?,?,'使用',FALSE)
                """)) {
            insert.setObject(1, id);
            insert.setString(2, code);
            insert.setString(3, name);
            insert.setObject(4, currencyId);
            insert.setObject(5, accountStyleId);
            assertEquals(1, insert.executeUpdate());
        }
        return id;
    }

    private static void insertBatch(Connection connection, UUID id, String batchNo)
            throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO account_balance_adjustment_batches(
                    id,batch_no,adjustment_scope,effective_date,reason,
                    idempotency_key,request_hash,clearing_style_id,actor_id,
                    expected_item_count,changed_item_count)
                VALUES(?,?,'SELECTED',CURRENT_DATE,'测试批次形状',?,repeat('0',64),
                       '40000000-0000-4000-8100-000000000001',?,1,0)
                """)) {
            insert.setObject(1, id);
            insert.setString(2, batchNo);
            insert.setString(3, "batch-shape-" + id);
            insert.setObject(4, actorId);
            assertEquals(1, insert.executeUpdate());
        }
    }

    private static void insertItem(
            Connection connection, UUID batchId, UUID accountId, int lineNo)
            throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO account_balance_adjustment_items(
                    id,batch_id,line_no,account_id,
                    account_code_snapshot,account_name_snapshot,
                    currency_id,currency_code_snapshot,currency_name_snapshot,
                    exchange_rate_snapshot,local_amount_basis,account_style_id_snapshot,
                    expected_balance,target_balance,delta_balance,delta_local,verified)
                VALUES(gen_random_uuid(),?,?,?,'ZH-SNAPSHOT','账户快照',?,
                       '01','人民币',NULL,'NO_CHANGE',?,0,0,0,0,TRUE)
                """)) {
            insert.setObject(1, batchId);
            insert.setInt(2, lineNo);
            insert.setObject(3, accountId);
            insert.setObject(4, currencyId);
            insert.setObject(5, accountStyleId);
            assertEquals(1, insert.executeUpdate());
        }
    }

    private static UUID uuid(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next(), sql);
            return result.getObject(1, UUID.class);
        }
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
