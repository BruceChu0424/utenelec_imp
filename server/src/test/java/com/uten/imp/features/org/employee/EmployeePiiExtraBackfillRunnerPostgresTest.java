package com.uten.imp.features.org.employee;

import com.uten.imp.security.TxSessionVars;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.boot.ApplicationArguments;
import org.springframework.context.ApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** Real PostgreSQL evidence for the V282 runtime backfill through V287. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class EmployeePiiExtraBackfillRunnerPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static JdbcTemplate jdbc;
    private static JdbcTransactionManager transactionManager;
    private static TransactionTemplate transactions;

    private TxSessionVars tx;
    private EmployeePiiExtraBackfillRunner runner;

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
        var dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        transactionManager = new JdbcTransactionManager(dataSource);
        transactions = new TransactionTemplate(transactionManager);
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @BeforeEach
    void setUp() {
        jdbc.update("DELETE FROM employees WHERE code LIKE 'V286-RUNNER-%'");
        normalizeAdminSeed();

        tx = mock(TxSessionVars.class);
        doAnswer(invocation -> {
            jdbc.queryForObject(
                    "SELECT set_config('app.employee_pii_extra_backfill', 'v1', true)",
                    String.class);
            return null;
        }).when(tx).bindEmployeePiiExtraBackfillV1();
        when(tx.encrypt(anyString())).thenAnswer(invocation ->
                "enc:" + invocation.getArgument(0, String.class));
        when(tx.decrypt(anyString())).thenAnswer(invocation -> {
            String cipher = invocation.getArgument(0, String.class);
            if (!cipher.startsWith("enc:")) {
                throw new IllegalStateException("test ciphertext is unreadable");
            }
            return cipher.substring("enc:".length());
        });

        runner = new EmployeePiiExtraBackfillRunner(
                jdbc,
                tx,
                transactionManager,
                mock(ApplicationContext.class));
    }

    @Test
    void freshV08AdminGetsExtensionOnlyRowAndSecondRunIsIdempotent() {
        UUID adminId = adminId();
        setLegacyValues(adminId, null, null, "admin@uten.local", null, null);

        runBackfill();

        assertThat(text("SELECT email FROM employees WHERE id = ?", adminId)).isNull();
        assertThat(text(
                "SELECT email_enc FROM employee_sensitive WHERE employee_id = ?",
                adminId)).isEqualTo("enc:admin@uten.local");
        assertThat(text(
                "SELECT id_card_enc FROM employee_sensitive WHERE employee_id = ?",
                adminId)).isNull();
        assertThat(text(
                "SELECT phone_enc FROM employee_sensitive WHERE employee_id = ?",
                adminId)).isNull();

        String firstCipher = text(
                "SELECT email_enc FROM employee_sensitive WHERE employee_id = ?",
                adminId);
        runBackfill();
        assertThat(text(
                "SELECT email_enc FROM employee_sensitive WHERE employee_id = ?",
                adminId)).isEqualTo(firstCipher);
        verify(tx).encrypt("admin@uten.local");
    }

    @Test
    void missingRowStoresOnlyPresentExtensionsAndDerivesBirthMonthDay() {
        UUID employeeId = createLegacyEmployee(
                "actual-fields",
                "Guangzhou",
                null,
                null,
                LocalDate.of(2024, 2, 29),
                "020-12345678");

        runBackfill();

        assertThat(text(
                "SELECT huji_address_enc FROM employee_sensitive WHERE employee_id = ?",
                employeeId)).isEqualTo("enc:Guangzhou");
        assertThat(text(
                "SELECT birth_date_enc FROM employee_sensitive WHERE employee_id = ?",
                employeeId)).isEqualTo("enc:2024-02-29");
        assertThat(text(
                "SELECT office_phone_enc FROM employee_sensitive WHERE employee_id = ?",
                employeeId)).isEqualTo("enc:020-12345678");
        assertThat(text(
                "SELECT residence_address_enc FROM employee_sensitive WHERE employee_id = ?",
                employeeId)).isNull();
        assertThat(text(
                "SELECT email_enc FROM employee_sensitive WHERE employee_id = ?",
                employeeId)).isNull();
        assertThat(text(
                "SELECT id_card_enc FROM employee_sensitive WHERE employee_id = ?",
                employeeId)).isNull();
        assertThat(text(
                "SELECT phone_enc FROM employee_sensitive WHERE employee_id = ?",
                employeeId)).isNull();
        assertThat(text(
                "SELECT birth_month_day FROM employees WHERE id = ?",
                employeeId)).isEqualTo("02-29");
        assertThat(number("""
                SELECT count(*) FROM employees
                WHERE id = ? AND (
                    huji_address IS NOT NULL OR residence_address IS NOT NULL
                    OR email IS NOT NULL OR birth_date IS NOT NULL
                    OR marital_status IS NOT NULL OR political_status IS NOT NULL
                    OR office_phone IS NOT NULL)
                """, employeeId)).isZero();
    }

    @Test
    void employeeWithoutLegacyPlaintextDoesNotGainSensitiveRow() {
        UUID employeeId = createEmployeeWithoutLegacyPlaintext("no-plaintext");

        runBackfill();

        assertThat(number(
                "SELECT count(*) FROM employee_sensitive WHERE employee_id = ?",
                employeeId)).isZero();
    }

    @Test
    void optionalIdentityDerivationsCannotExistWithoutTheirCiphertext() {
        UUID identityEmployeeId = createEmployeeWithoutLegacyPlaintext(
                "id-derivation-without-cipher");
        assertThatThrownBy(() -> jdbc.update(
                "INSERT INTO employee_sensitive(employee_id, id_card_last4, id_card_hash) "
                        + "VALUES (?, '1234', ?)",
                identityEmployeeId,
                "v287-id-hash-" + identityEmployeeId))
                .hasMessageContaining("employee_sensitive_id_card_derivation_ck");

        UUID phoneEmployeeId = createEmployeeWithoutLegacyPlaintext(
                "phone-derivation-without-cipher");
        assertThatThrownBy(() -> jdbc.update(
                "INSERT INTO employee_sensitive(employee_id, phone_hash) VALUES (?, ?)",
                phoneEmployeeId,
                "v287-phone-hash-" + phoneEmployeeId))
                .hasMessageContaining("employee_sensitive_phone_derivation_ck");
    }

    @Test
    void matchingCipherFromInterruptedRunIsVerifiedThenPlaintextIsCleared() {
        UUID employeeId = createLegacyEmployee(
                "matching-cipher", null, null, "same@example.test", null, null);
        jdbc.update(
                "INSERT INTO employee_sensitive(employee_id, email_enc) VALUES (?, ?)",
                employeeId,
                "enc:same@example.test");

        runBackfill();

        assertThat(text("SELECT email FROM employees WHERE id = ?", employeeId)).isNull();
        assertThat(text(
                "SELECT email_enc FROM employee_sensitive WHERE employee_id = ?",
                employeeId)).isEqualTo("enc:same@example.test");
        verify(tx, never()).encrypt("same@example.test");
    }

    @Test
    void conflictingCipherFailsClosedAndRollsBackLegacyClear() {
        UUID employeeId = createLegacyEmployee(
                "conflicting-cipher", null, null, "legacy@example.test", null, null);
        jdbc.update(
                "INSERT INTO employee_sensitive(employee_id, email_enc) VALUES (?, ?)",
                employeeId,
                "enc:newer@example.test");

        assertThatThrownBy(this::runBackfill)
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("conflicting existing email_enc")
                .hasMessageContaining(employeeId.toString());

        assertThat(text("SELECT email FROM employees WHERE id = ?", employeeId))
                .isEqualTo("legacy@example.test");
        assertThat(text(
                "SELECT email_enc FROM employee_sensitive WHERE employee_id = ?",
                employeeId)).isEqualTo("enc:newer@example.test");
    }

    private void runBackfill() {
        runner.run(mock(ApplicationArguments.class));
    }

    private static UUID createLegacyEmployee(
            String tag,
            String hujiAddress,
            String residenceAddress,
            String email,
            LocalDate birthDate,
            String officePhone) {
        UUID employeeId = UUID.randomUUID();
        transactions.executeWithoutResult(status -> {
            bindLegacyImport();
            jdbc.update("""
                    INSERT INTO employees (
                        id, code, full_name, id_type, department_id, hire_date,
                        status, employment_type, huji_address,
                        residence_address, email, birth_date, office_phone)
                    SELECT ?, ?, ?, '其他', department_id, DATE '2026-01-01',
                           'active', 'regular', ?, ?, ?, ?, ?
                    FROM employees
                    WHERE code = 'ADMIN'
                    """,
                    employeeId,
                    "V286-RUNNER-" + tag,
                    "V286 runner " + tag,
                    hujiAddress,
                    residenceAddress,
                    email,
                    birthDate,
                    officePhone);
        });
        return employeeId;
    }

    private static UUID createEmployeeWithoutLegacyPlaintext(String tag) {
        UUID employeeId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees (
                    id, code, full_name, id_type, department_id, hire_date,
                    status, employment_type)
                SELECT ?, ?, ?, '其他', department_id, DATE '2026-01-01',
                       'active', 'regular'
                FROM employees
                WHERE code = 'ADMIN'
                """,
                employeeId,
                "V286-RUNNER-" + tag,
                "V286 runner " + tag);
        return employeeId;
    }

    private static void normalizeAdminSeed() {
        UUID adminId = adminId();
        transactions.executeWithoutResult(status -> {
            bindBackfill();
            jdbc.update("""
                    UPDATE employees
                    SET huji_address = NULL,
                        residence_address = NULL,
                        email = NULL,
                        birth_date = NULL,
                        marital_status = NULL,
                        political_status = NULL,
                        office_phone = NULL,
                        birth_month_day = NULL
                    WHERE id = ?
                    """, adminId);
        });
        jdbc.update("DELETE FROM employee_sensitive WHERE employee_id = ?", adminId);
    }

    private static void setLegacyValues(
            UUID employeeId,
            String hujiAddress,
            String residenceAddress,
            String email,
            LocalDate birthDate,
            String officePhone) {
        transactions.executeWithoutResult(status -> {
            bindLegacyImport();
            jdbc.update("""
                    UPDATE employees
                    SET huji_address = ?, residence_address = ?, email = ?,
                        birth_date = ?, office_phone = ?
                    WHERE id = ?
                    """,
                    hujiAddress,
                    residenceAddress,
                    email,
                    birthDate,
                    officePhone,
                    employeeId);
        });
    }

    private static void bindLegacyImport() {
        jdbc.queryForObject(
                "SELECT set_config('app.employee_pii_extra_legacy_import', 'v1', true)",
                String.class);
    }

    private static void bindBackfill() {
        jdbc.queryForObject(
                "SELECT set_config('app.employee_pii_extra_backfill', 'v1', true)",
                String.class);
    }

    private static UUID adminId() {
        return jdbc.queryForObject(
                "SELECT id FROM employees WHERE code = 'ADMIN'",
                UUID.class);
    }

    private static String text(String sql, Object... args) {
        return jdbc.queryForObject(sql, String.class, args);
    }

    private static long number(String sql, Object... args) {
        Long value = jdbc.queryForObject(sql, Long.class, args);
        return value == null ? 0 : value;
    }
}
