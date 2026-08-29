package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
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
class AccountBalanceNativeCurrencyUpgradePostgresTest {

    @Test
    void v401ClassifiesExistingV400RowsWithoutRewritingTheirFrozenEvidence()
            throws Exception {
        try (PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("uten_imp")
                .withUsername("uten")
                .withPassword("uten")) {
            postgres.start();
            Flyway.configure()
                    .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                    .locations("classpath:db/migration")
                    .target("400")
                    .load()
                    .migrate();

            UUID batchId = UUID.randomUUID();
            try (Connection connection = DriverManager.getConnection(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
                UUID actorId = uuid(connection, "SELECT id FROM employees ORDER BY id LIMIT 1");
                UUID clearingStyleId = uuid(connection, """
                        SELECT style_id FROM system_posting_style_roles
                        WHERE role_key='ACCOUNT_BALANCE_CLEARING'
                        """);
                UUID accountStyleId = uuid(connection, """
                        SELECT style.id FROM payment_styles style
                        WHERE style.category='ACCOUNT' AND style.status='使用'
                          AND COALESCE(style.is_deleted,FALSE)=FALSE
                          AND NOT EXISTS(
                              SELECT 1 FROM payment_styles child
                              WHERE child.parent_id=style.id
                                AND COALESCE(child.is_deleted,FALSE)=FALSE)
                        ORDER BY style.id LIMIT 1
                        """);
                UUID currencyId = UUID.randomUUID();
                UUID accountId = UUID.randomUUID();
                try (PreparedStatement insert = connection.prepareStatement("""
                        INSERT INTO currencies(
                            id,legacy_id,code,name,exchange_rate,status,auto_created,is_deleted)
                        VALUES(?,1,'001','人民币',1,'使用',FALSE,FALSE)
                        """)) {
                    insert.setObject(1, UUID.randomUUID());
                    assertEquals(1, insert.executeUpdate());
                }
                try (PreparedStatement insert = connection.prepareStatement("""
                        INSERT INTO currencies(
                            id,code,name,exchange_rate,status,auto_created,is_deleted)
                        VALUES(?,'USD-LEGACY-TEST','美元历史测试',7,'使用',FALSE,FALSE)
                        """)) {
                    insert.setObject(1, currencyId);
                    assertEquals(1, insert.executeUpdate());
                }
                try (PreparedStatement insert = connection.prepareStatement("""
                        INSERT INTO accounts(
                            id,code,name,account_type,currency_id,style_id,status,is_deleted)
                        VALUES(?,'ZH-V400-LEGACY','V400历史外币账户','BANK',?,?,'使用',FALSE)
                        """)) {
                    insert.setObject(1, accountId);
                    insert.setObject(2, currencyId);
                    insert.setObject(3, accountStyleId);
                    assertEquals(1, insert.executeUpdate());
                }
                connection.setAutoCommit(false);
                try (PreparedStatement insert = connection.prepareStatement("""
                        INSERT INTO account_balance_adjustment_batches(
                            id,batch_no,adjustment_scope,effective_date,reason,
                            idempotency_key,request_hash,clearing_style_id,actor_id,
                            expected_item_count,changed_item_count)
                        VALUES(?,'TZ20260827000901','SELECTED',CURRENT_DATE,
                               'V400历史批次兼容','v400-history-batch-1',repeat('1',64),?,?,1,1)
                        """)) {
                    insert.setObject(1, batchId);
                    insert.setObject(2, clearingStyleId);
                    insert.setObject(3, actorId);
                    assertEquals(1, insert.executeUpdate());
                }
                try (PreparedStatement insert = connection.prepareStatement("""
                        INSERT INTO account_balance_adjustment_items(
                            id,batch_id,line_no,account_id,
                            account_code_snapshot,account_name_snapshot,
                            currency_id,currency_code_snapshot,currency_name_snapshot,
                            exchange_rate_snapshot,account_style_id_snapshot,
                            expected_balance,target_balance,delta_balance,delta_local,verified)
                        VALUES(gen_random_uuid(),?,1,?,'ZH-V400-LEGACY','V400历史外币账户',
                               ?,'USD-LEGACY-TEST','美元历史测试',7,?,0,10,10,70,TRUE)
                        """)) {
                    insert.setObject(1, batchId);
                    insert.setObject(2, accountId);
                    insert.setObject(3, currencyId);
                    insert.setObject(4, accountStyleId);
                    assertEquals(1, insert.executeUpdate());
                }
                connection.commit();
            }

            Flyway.configure()
                    .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                    .locations("classpath:db/migration")
                    .load()
                    .migrate();

            try (Connection connection = DriverManager.getConnection(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
                 PreparedStatement query = connection.prepareStatement("""
                         SELECT local_amount_basis,exchange_rate_snapshot,
                                delta_balance,delta_local
                         FROM account_balance_adjustment_items
                         WHERE batch_id=?
                         """)) {
                query.setObject(1, batchId);
                try (ResultSet row = query.executeQuery()) {
                    assertTrue(row.next());
                    assertEquals("LEGACY_REFERENCE_RATE", row.getString(1));
                    assertEquals("7.000000", row.getBigDecimal(2).toPlainString());
                    assertEquals("10.0000", row.getBigDecimal(3).toPlainString());
                    assertEquals("70.0000", row.getBigDecimal(4).toPlainString());
                }

                assertEquals(1, scalar(connection, """
                        SELECT COUNT(*) FROM currencies
                        WHERE is_base_currency AND legacy_id=1
                        """));
                UUID baseCurrencyId = uuid(connection, """
                        SELECT id FROM currencies WHERE is_base_currency
                        """);
                SQLException legacyWrite = assertThrows(
                        SQLException.class,
                        () -> insertNewBasisRow(
                                connection, batchId, "LEGACY_REFERENCE_RATE",
                                "8.000000", "8.0000"));
                assertEquals("23514", legacyWrite.getSQLState());
                assertTrue(legacyWrite.getMessage().contains("LEGACY_REFERENCE_RATE"));
                SQLException foreignIdentity = assertThrows(
                        SQLException.class,
                        () -> insertNewBasisRow(
                                connection, batchId, "BASE_CURRENCY_IDENTITY",
                                "1.000000", "1.0000"));
                assertEquals("23514", foreignIdentity.getSQLState());
                assertTrue(foreignIdentity.getMessage().contains(
                        "foreign-currency balance adjustment"));
                SQLException mismatchedCurrency = assertThrows(
                        SQLException.class,
                        () -> insertMismatchedCurrencyRow(
                                connection, batchId, baseCurrencyId));
                assertEquals("23514", mismatchedCurrency.getSQLState());
                assertTrue(mismatchedCurrency.getMessage().contains(
                        "currency UUID must match the account currency UUID"));
                SQLException disableBase = assertThrows(
                        SQLException.class,
                        () -> execute(connection, """
                                UPDATE currencies SET status='禁用'
                                WHERE is_base_currency
                                """));
                assertEquals("23514", disableBase.getSQLState());
                assertTrue(disableBase.getMessage().contains(
                        "functional currency UUID cannot be disabled"));
                SQLException replaceBase = assertThrows(
                        SQLException.class,
                        () -> execute(connection, """
                                UPDATE currencies SET is_base_currency=FALSE
                                WHERE is_base_currency
                                """));
                assertEquals("23514", replaceBase.getSQLState());
                assertTrue(replaceBase.getMessage().contains(
                        "functional currency UUID authority is immutable"));
                SQLException replaceBaseId = assertThrows(
                        SQLException.class,
                        () -> execute(connection, """
                                UPDATE currencies SET id=gen_random_uuid()
                                WHERE is_base_currency
                                """));
                assertEquals("23514", replaceBaseId.getSQLState());
                assertTrue(replaceBaseId.getMessage().contains(
                        "functional currency UUID primary key is immutable"));
            }
        }
    }

    private static void insertNewBasisRow(
            Connection connection,
            UUID batchId,
            String basis,
            String rate,
            String localDelta) throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO account_balance_adjustment_items(
                    id,batch_id,line_no,account_id,
                    account_code_snapshot,account_name_snapshot,
                    currency_id,currency_code_snapshot,currency_name_snapshot,
                    exchange_rate_snapshot,local_amount_basis,account_style_id_snapshot,
                    expected_balance,target_balance,delta_balance,delta_local,verified)
                SELECT gen_random_uuid(),item.batch_id,2,item.account_id,
                       item.account_code_snapshot,item.account_name_snapshot,
                       item.currency_id,item.currency_code_snapshot,item.currency_name_snapshot,
                       ?::numeric,?,item.account_style_id_snapshot,
                       10,11,1,?::numeric,TRUE
                FROM account_balance_adjustment_items item
                WHERE item.batch_id=?
                """)) {
            insert.setString(1, rate);
            insert.setString(2, basis);
            insert.setString(3, localDelta);
            insert.setObject(4, batchId);
            insert.executeUpdate();
        }
    }

    private static void insertMismatchedCurrencyRow(
            Connection connection,
            UUID batchId,
            UUID currencyId) throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO account_balance_adjustment_items(
                    id,batch_id,line_no,account_id,
                    account_code_snapshot,account_name_snapshot,
                    currency_id,currency_code_snapshot,currency_name_snapshot,
                    exchange_rate_snapshot,local_amount_basis,account_style_id_snapshot,
                    expected_balance,target_balance,delta_balance,delta_local,verified)
                SELECT gen_random_uuid(),item.batch_id,2,item.account_id,
                       item.account_code_snapshot,item.account_name_snapshot,
                       ?,'CNY','人民币',
                       1,'BASE_CURRENCY_IDENTITY',item.account_style_id_snapshot,
                       10,11,1,1,TRUE
                FROM account_balance_adjustment_items item
                WHERE item.batch_id=?
                """)) {
            insert.setObject(1, currencyId);
            insert.setObject(2, batchId);
            insert.executeUpdate();
        }
    }

    private static int scalar(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next(), sql);
            return result.getInt(1);
        }
    }

    private static void execute(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.executeUpdate(sql);
        }
    }

    private static UUID uuid(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next(), sql);
            return result.getObject(1, UUID.class);
        }
    }
}
