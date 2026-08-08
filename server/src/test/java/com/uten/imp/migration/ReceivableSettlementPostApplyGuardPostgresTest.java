package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.Date;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;

/** Real PostgreSQL evidence for the V236-to-V238 compensating migration path. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ReceivableSettlementPostApplyGuardPostgresTest {

    private static final int V236_CHECKSUM = -2024018731;
    private static final int V237_CHECKSUM = -454218917;
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void startPostgres() {
        POSTGRES.start();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void v238RepairsOnlyProvenHistoricalSynthesisAndPreservesMigrationHistory()
            throws Exception {
        flyway("235").migrate();

        Fixture fixture;
        try (Connection connection = connection()) {
            fixture = insertPreV236Fixture(connection);
        }

        flyway("237").migrate();

        Map<String, Integer> checksumsBeforeV238;
        try (Connection connection = connection()) {
            checksumsBeforeV238 = checksums(connection);
            assertThat(checksumsBeforeV238).containsExactlyInAnyOrderEntriesOf(Map.of(
                    "236", V236_CHECKSUM,
                    "237", V237_CHECKSUM));

            assertBreakdown(connection, fixture.activeRateOneLedger(),
                    "20", "20", "0", "0", "80");
            assertBreakdown(connection, fixture.inactiveRateOneLedger(),
                    "20", "20", "0", "0", "80");
            assertBreakdown(connection, fixture.activeRateTwoLedger(),
                    "20", "40", "0", "0", "80");
            assertBreakdown(connection, fixture.ledgerTouchedAfterV236(),
                    "20", "20", "0", "0", "80");
            assertBreakdown(connection, fixture.currencyTouchedAfterV236Ledger(),
                    "20", "20", "0", "0", "80");

            disableV236BankFee(connection);
            OffsetDateTime v236InstalledAt = v236InstalledAt(connection);
            OffsetDateTime afterV236 = v236InstalledAt.plusSeconds(1);
            touchLedgerAfterV236(
                    connection, fixture.ledgerTouchedAfterV236(), afterV236);
            touchCurrencyAfterV236(
                    connection, fixture.currencyTouchedAfterV236(), afterV236);
            assertThat(ledgerUpdatedAt(connection, fixture.ledgerTouchedAfterV236()))
                    .isAfter(v236InstalledAt);
            assertThat(currencyUpdatedAt(connection, fixture.currencyTouchedAfterV236()))
                    .isAfter(v236InstalledAt);
            assertBreakdown(connection, fixture.ledgerTouchedAfterV236(),
                    "20", "20", "0", "0", "80");
            assertBreakdown(connection, fixture.currencyTouchedAfterV236Ledger(),
                    "20", "20", "0", "0", "80");
            insertPostV236Fact(connection, fixture.postV236Ledger(), fixture.clientId(),
                    fixture.inactiveCurrencyId(), afterV236);
            assertThat(ledgerCreatedAt(connection, fixture.postV236Ledger()))
                    .isAfter(v236InstalledAt);
        }

        flyway("238").migrate();

        try (Connection connection = connection()) {
            assertBreakdown(connection, fixture.activeRateOneLedger(),
                    "20", "20", "0", "0", "80");
            assertBreakdown(connection, fixture.inactiveRateOneLedger(),
                    null, "20", null, "0", null);
            assertBreakdown(connection, fixture.activeRateTwoLedger(),
                    null, "40", null, "0", null);
            assertBreakdown(connection, fixture.ledgerTouchedAfterV236(),
                    "20", "20", "0", "0", "80");
            assertBreakdown(connection, fixture.currencyTouchedAfterV236Ledger(),
                    "20", "20", "0", "0", "80");
            assertBreakdown(connection, fixture.postV236Ledger(),
                    "30", "30", "0", "0", "120");

            assertThat(styles(connection, "手续费")).containsExactlyInAnyOrder(
                    new Style("SYS-FIN-BANK-FEE", "禁用"),
                    new Style("SYS-FIN-BANK-FEE-V238", "使用"));
            assertThat(styles(connection, "汇兑损益")).containsExactly(
                    new Style("SYS-FIN-FX-GL", "使用"));

            assertThat(checksums(connection)).isEqualTo(checksumsBeforeV238);
            assertThat(successfulMigrationCount(connection, "238")).isEqualTo(1);
        }

        assertDoesNotThrow(() -> flyway("238").validate());
    }

    private static Fixture insertPreV236Fixture(Connection connection) throws SQLException {
        UUID clientId = UUID.randomUUID();
        UUID activeCurrencyId = UUID.randomUUID();
        UUID inactiveCurrencyId = UUID.randomUUID();
        UUID rateTwoCurrencyId = UUID.randomUUID();
        UUID currencyTouchedAfterV236 = UUID.randomUUID();
        UUID activeRateOneLedger = UUID.randomUUID();
        UUID inactiveRateOneLedger = UUID.randomUUID();
        UUID activeRateTwoLedger = UUID.randomUUID();
        UUID ledgerTouchedAfterV236 = UUID.randomUUID();
        UUID currencyTouchedAfterV236Ledger = UUID.randomUUID();
        UUID postV236Ledger = UUID.randomUUID();

        try (PreparedStatement statement = connection.prepareStatement("""
                INSERT INTO clients(id,code,name,status)
                VALUES(?,?,?,'使用')
                """)) {
            statement.setObject(1, clientId);
            statement.setString(2, "V238-CLIENT-" + clientId);
            statement.setString(3, "V238 migration client");
            statement.executeUpdate();
        }
        insertCurrency(connection, activeCurrencyId, "CNY-ACTIVE-", "使用", "1");
        insertCurrency(connection, inactiveCurrencyId, "CNY-INACTIVE-", "禁用", "1");
        insertCurrency(connection, rateTwoCurrencyId, "CNY-RATE2-", "使用", "2");
        insertCurrency(connection, currencyTouchedAfterV236,
                "CNY-LATE-MASTER-", "禁用", "1");

        OffsetDateTime historical = OffsetDateTime.parse("2026-01-01T00:00:00Z");
        insertPreV236Ledger(connection, activeRateOneLedger, clientId,
                activeCurrencyId, "V238-AR-ACTIVE-1", "1", "100", "100", "20",
                historical);
        insertPreV236Ledger(connection, inactiveRateOneLedger, clientId,
                inactiveCurrencyId, "V238-AR-INACTIVE-1", "1", "100", "100", "20",
                historical.plusSeconds(1));
        insertPreV236Ledger(connection, activeRateTwoLedger, clientId,
                rateTwoCurrencyId, "V238-AR-ACTIVE-2", "2", "100", "200", "40",
                historical.plusSeconds(2));
        insertPreV236Ledger(connection, ledgerTouchedAfterV236, clientId,
                inactiveCurrencyId, "V238-AR-LATE-LEDGER", "1", "100", "100", "20",
                historical.plusSeconds(3));
        insertPreV236Ledger(connection, currencyTouchedAfterV236Ledger, clientId,
                currencyTouchedAfterV236, "V238-AR-LATE-CURRENCY", "1", "100", "100",
                "20", historical.plusSeconds(4));

        return new Fixture(clientId, inactiveCurrencyId, currencyTouchedAfterV236,
                activeRateOneLedger, inactiveRateOneLedger, activeRateTwoLedger,
                ledgerTouchedAfterV236, currencyTouchedAfterV236Ledger, postV236Ledger);
    }

    private static void insertCurrency(
            Connection connection, UUID id, String codePrefix, String status, String rate)
            throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("""
                INSERT INTO currencies(
                    id,code,name,exchange_rate,status,created_at,updated_at
                ) VALUES(
                    ?,?, '人民币', ?, ?,
                    TIMESTAMPTZ '2026-01-01 00:00:00+00',
                    TIMESTAMPTZ '2026-01-01 00:00:00+00'
                )
                """)) {
            statement.setObject(1, id);
            statement.setString(2, codePrefix + id);
            statement.setBigDecimal(3, decimal(rate));
            statement.setString(4, status);
            statement.executeUpdate();
        }
    }

    private static void insertPreV236Ledger(
            Connection connection,
            UUID id,
            UUID clientId,
            UUID currencyId,
            String billNo,
            String exchangeRate,
            String amountOriginal,
            String amountOriginalLocal,
            String amountSettled,
            OffsetDateTime createdAt) throws SQLException {
        BigDecimal originalLocal = decimal(amountOriginalLocal);
        BigDecimal settled = decimal(amountSettled);
        try (PreparedStatement statement = connection.prepareStatement("""
                INSERT INTO ar_ap_ledger(
                    id,direction,source_doc_type,source_doc_no,bill_date,
                    client_id,currency_id,exchange_rate,
                    amount_original_local,amount_settled,amount_balance,is_settled,
                    bill_no,amount_original,status,created_at,updated_at
                ) VALUES(
                    ?,'AR','DIRECT_RECEIPT',?, ?,
                    ?,?,?, ?,?,?,FALSE,
                    ?,?,1,?,?
                )
                """)) {
            int index = 1;
            statement.setObject(index++, id);
            statement.setString(index++, billNo);
            statement.setDate(index++, Date.valueOf(LocalDate.of(2026, 1, 1)));
            statement.setObject(index++, clientId);
            statement.setObject(index++, currencyId);
            statement.setBigDecimal(index++, decimal(exchangeRate));
            statement.setBigDecimal(index++, originalLocal);
            statement.setBigDecimal(index++, settled);
            statement.setBigDecimal(index++, originalLocal.subtract(settled));
            statement.setString(index++, billNo);
            statement.setBigDecimal(index++, decimal(amountOriginal));
            statement.setObject(index++, createdAt);
            statement.setObject(index, createdAt);
            statement.executeUpdate();
        }
    }

    private static void insertPostV236Fact(
            Connection connection,
            UUID id,
            UUID clientId,
            UUID currencyId,
            OffsetDateTime createdAt) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("""
                INSERT INTO ar_ap_ledger(
                    id,direction,source_doc_type,source_doc_no,bill_date,
                    client_id,currency_id,exchange_rate,
                    amount_original_local,amount_settled,amount_balance,is_settled,
                    bill_no,amount_original,status,created_at,updated_at,
                    amount_received_original,amount_received_local,
                    amount_write_off_original,amount_write_off_local,
                    amount_balance_original
                ) VALUES(
                    ?,'AR','DIRECT_RECEIPT',?,DATE '2026-08-08',
                    ?,?,1, 150,30,120,FALSE,
                    ?,150,1,?,?, 30,30,0,0,120
                )
                """)) {
            statement.setObject(1, id);
            statement.setString(2, "V238-AR-POST");
            statement.setObject(3, clientId);
            statement.setObject(4, currencyId);
            statement.setString(5, "V238-AR-POST");
            statement.setObject(6, createdAt);
            statement.setObject(7, createdAt);
            statement.executeUpdate();
        }
    }

    private static void disableV236BankFee(Connection connection) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("""
                UPDATE payment_styles
                SET status='禁用'
                WHERE code='SYS-FIN-BANK-FEE' AND is_deleted=FALSE
                """)) {
            assertThat(statement.executeUpdate()).isEqualTo(1);
        }
    }

    private static void touchLedgerAfterV236(
            Connection connection, UUID ledgerId, OffsetDateTime updatedAt)
            throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("""
                UPDATE ar_ap_ledger SET updated_at=? WHERE id=?
                """)) {
            statement.setObject(1, updatedAt);
            statement.setObject(2, ledgerId);
            assertThat(statement.executeUpdate()).isEqualTo(1);
        }
    }

    private static void touchCurrencyAfterV236(
            Connection connection, UUID currencyId, OffsetDateTime updatedAt)
            throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("""
                UPDATE currencies SET updated_at=? WHERE id=?
                """)) {
            statement.setObject(1, updatedAt);
            statement.setObject(2, currencyId);
            assertThat(statement.executeUpdate()).isEqualTo(1);
        }
    }

    private static void assertBreakdown(
            Connection connection,
            UUID ledgerId,
            String receivedOriginal,
            String receivedLocal,
            String writeOffOriginal,
            String writeOffLocal,
            String balanceOriginal) throws SQLException {
        Breakdown actual;
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT amount_received_original,amount_received_local,
                       amount_write_off_original,amount_write_off_local,
                       amount_balance_original
                FROM ar_ap_ledger WHERE id=?
                """)) {
            statement.setObject(1, ledgerId);
            try (ResultSet result = statement.executeQuery()) {
                assertThat(result.next()).isTrue();
                actual = new Breakdown(
                        result.getBigDecimal(1), result.getBigDecimal(2),
                        result.getBigDecimal(3), result.getBigDecimal(4),
                        result.getBigDecimal(5));
            }
        }
        assertDecimal(actual.receivedOriginal(), receivedOriginal);
        assertDecimal(actual.receivedLocal(), receivedLocal);
        assertDecimal(actual.writeOffOriginal(), writeOffOriginal);
        assertDecimal(actual.writeOffLocal(), writeOffLocal);
        assertDecimal(actual.balanceOriginal(), balanceOriginal);
    }

    private static void assertDecimal(BigDecimal actual, String expected) {
        if (expected == null) {
            assertThat(actual).isNull();
        } else {
            assertThat(actual).isEqualByComparingTo(expected);
        }
    }

    private static Map<String, Integer> checksums(Connection connection) throws SQLException {
        Map<String, Integer> result = new HashMap<>();
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT version,checksum
                FROM flyway_schema_history
                WHERE version IN ('236','237')
                ORDER BY installed_rank
                """); ResultSet rows = statement.executeQuery()) {
            while (rows.next()) {
                result.put(rows.getString(1), rows.getInt(2));
            }
        }
        return Map.copyOf(result);
    }

    private static OffsetDateTime v236InstalledAt(Connection connection) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT installed_on AT TIME ZONE current_setting('TimeZone')
                FROM flyway_schema_history
                WHERE version='236' AND success=TRUE
                """); ResultSet result = statement.executeQuery()) {
            assertThat(result.next()).isTrue();
            return result.getObject(1, OffsetDateTime.class);
        }
    }

    private static OffsetDateTime ledgerCreatedAt(Connection connection, UUID ledgerId)
            throws SQLException {
        return timestamp(connection,
                "SELECT created_at FROM ar_ap_ledger WHERE id=?", ledgerId);
    }

    private static OffsetDateTime ledgerUpdatedAt(Connection connection, UUID ledgerId)
            throws SQLException {
        return timestamp(connection,
                "SELECT updated_at FROM ar_ap_ledger WHERE id=?", ledgerId);
    }

    private static OffsetDateTime currencyUpdatedAt(Connection connection, UUID currencyId)
            throws SQLException {
        return timestamp(connection,
                "SELECT updated_at FROM currencies WHERE id=?", currencyId);
    }

    private static OffsetDateTime timestamp(
            Connection connection, String sql, UUID id) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet result = statement.executeQuery()) {
                assertThat(result.next()).isTrue();
                return result.getObject(1, OffsetDateTime.class);
            }
        }
    }

    private static List<Style> styles(Connection connection, String name) throws SQLException {
        List<Style> result = new ArrayList<>();
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT code,status
                FROM payment_styles
                WHERE category='EXPENSE' AND name=? AND is_deleted=FALSE
                ORDER BY code
                """)) {
            statement.setString(1, name);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) {
                    result.add(new Style(rows.getString(1), rows.getString(2)));
                }
            }
        }
        return List.copyOf(result);
    }

    private static long successfulMigrationCount(Connection connection, String version)
            throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT COUNT(*) FROM flyway_schema_history
                WHERE version=? AND success=TRUE
                """)) {
            statement.setString(1, version);
            try (ResultSet result = statement.executeQuery()) {
                result.next();
                return result.getLong(1);
            }
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static BigDecimal decimal(String value) {
        return new BigDecimal(value);
    }

    private record Fixture(
            UUID clientId,
            UUID inactiveCurrencyId,
            UUID currencyTouchedAfterV236,
            UUID activeRateOneLedger,
            UUID inactiveRateOneLedger,
            UUID activeRateTwoLedger,
            UUID ledgerTouchedAfterV236,
            UUID currencyTouchedAfterV236Ledger,
            UUID postV236Ledger) {
    }

    private record Breakdown(
            BigDecimal receivedOriginal,
            BigDecimal receivedLocal,
            BigDecimal writeOffOriginal,
            BigDecimal writeOffLocal,
            BigDecimal balanceOriginal) {
    }

    private record Style(String code, String status) {
    }
}
