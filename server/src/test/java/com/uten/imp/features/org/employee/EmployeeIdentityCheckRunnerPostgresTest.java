package com.uten.imp.features.org.employee;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.uten.imp.security.TxSessionVars;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.context.ApplicationContext;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.SQLException;
import java.sql.Savepoint;
import java.sql.Statement;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * V798 启动回填的真库证据：存量 unchecked 判定为 valid 或具体问题码；解不开的存成 unreadable、
 * 不阻止启动、以后启动不再重试；解不开的行不连累同一批里排在它后面的行；重复跑结果不变；
 * 并发修改的结果不被覆盖；日志只有一条数量汇总 (有解不开的行时为 WARN)，没有 ERROR，也没有号码。
 *
 * <p>{@code tx.tryDecrypt} 的替身和真实实现一样：解不开时在本批事务的连接上设保存点、执行一条失败的 SQL、
 * 回滚到保存点再返回空。回填任务若不是在保存点里失败，后面的 UPDATE 会因为事务已作废而失败。
 * 真实的 {@code TxSessionVars.tryDecrypt} 由业务链 {@code EmployeeIdentityReviewPostgresTest} 覆盖。</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class EmployeeIdentityCheckRunnerPostgresTest {

    private static final String VALID_ID = "11010519491231002X";
    private static final String BAD_CHECK_DIGIT = "110105194912310021";
    private static final String SHORT_ID = "11010519491231002";

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static JdbcTemplate jdbc;
    private static JdbcTransactionManager transactionManager;

    private TxSessionVars tx;
    private EmployeeIdentityCheckRunner runner;
    private ListAppender<ILoggingEvent> logs;
    private final AtomicReference<Runnable> duringDecrypt = new AtomicReference<>();

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        var dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        transactionManager = new JdbcTransactionManager(dataSource);
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @BeforeEach
    void setUp() {
        jdbc.update("DELETE FROM employee_sensitive WHERE employee_id IN "
                + "(SELECT id FROM employees WHERE code LIKE 'V798-RUNNER-%')");
        jdbc.update("DELETE FROM employees WHERE code LIKE 'V798-RUNNER-%'");

        tx = mock(TxSessionVars.class);
        when(tx.tryDecrypt(anyString())).thenAnswer(invocation -> {
            String cipher = invocation.getArgument(0, String.class);
            Runnable hook = duringDecrypt.getAndSet(null);
            if (hook != null) {
                hook.run();
            }
            if (cipher.startsWith("enc:")) {
                return Optional.of(cipher.substring("enc:".length()));
            }
            return failInsideSavepoint();
        });
        runner = new EmployeeIdentityCheckRunner(jdbc, tx, transactionManager, mock(ApplicationContext.class));

        Logger root = (Logger) LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME);
        logs = new ListAppender<>();
        logs.start();
        root.addAppender(logs);
    }

    @AfterEach
    void detachLogs() {
        Logger root = (Logger) LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME);
        root.detachAppender(logs);
        logs.stop();
    }

    @Test
    void legacyRowsBecomeValidOrTheirSpecificProblemAndUnreadableRowsAreStoredAsUnreadable() {
        UUID valid = legacyEmployee("valid", "身份证", "enc:" + VALID_ID);
        UUID lowercase = legacyEmployee("lower-x", "身份证", "enc:11010519491231002x");
        UUID badCheckDigit = legacyEmployee("check-digit", "身份证", "enc:" + BAD_CHECK_DIGIT);
        UUID shortId = legacyEmployee("short", "身份证", "enc:" + SHORT_ID);
        UUID passport = legacyEmployee("passport", "护照", "enc:E1234");
        UUID unreadable = legacyEmployee("unreadable", "身份证", "garbage-cipher");
        UUID noIdentity = employee("no-identity", "其他");

        assertThatCode(this::runCheck).as("unreadable ciphers never stop startup").doesNotThrowAnyException();

        assertThat(check(valid)).isEqualTo("valid");
        assertThat(check(lowercase)).isEqualTo("valid");
        assertThat(check(badCheckDigit)).isEqualTo("check_digit");
        assertThat(check(shortId)).isEqualTo("length:17");
        assertThat(check(passport)).isEqualTo("valid");
        assertThat(check(unreadable)).isEqualTo("unreadable");
        assertThat(count("SELECT count(*) FROM employee_sensitive WHERE employee_id = ?", noIdentity)).isZero();
        // 回填不改写密文
        assertThat(text("SELECT id_card_enc FROM employee_sensitive WHERE employee_id = ?", lowercase))
                .isEqualTo("enc:11010519491231002x");
        assertThat(text("SELECT id_card_enc FROM employee_sensitive WHERE employee_id = ?", unreadable))
                .isEqualTo("garbage-cipher");
        verify(tx, never()).decrypt(anyString());
        verify(tx, never()).decryptAll(any());
    }

    /** 同一批 (同一个事务) 里，排在解不开那一行后面的行照样判定并提交。 */
    @Test
    void anUnreadableRowDoesNotAbortTheRowsAfterItInTheSameBatch() {
        UUID first = legacyEmployee(UUID.fromString("00000000-0000-4000-8000-000000000001"),
                "order-unreadable", "身份证", "broken-first");
        UUID second = legacyEmployee(UUID.fromString("00000000-0000-4000-8000-000000000002"),
                "order-valid", "身份证", "enc:" + VALID_ID);
        UUID third = legacyEmployee(UUID.fromString("00000000-0000-4000-8000-000000000003"),
                "order-bad", "身份证", "enc:" + BAD_CHECK_DIGIT);

        runCheck();

        assertThat(check(first)).isEqualTo("unreadable");
        assertThat(check(second)).isEqualTo("valid");
        assertThat(check(third)).isEqualTo("check_digit");
    }

    @Test
    void secondRunNeverRetriesStoredRowsIncludingUnreadableOnes() {
        UUID badCheckDigit = legacyEmployee("idempotent-bad", "身份证", "enc:" + BAD_CHECK_DIGIT);
        UUID unreadable = legacyEmployee("idempotent-unreadable", "身份证", "still-garbage");
        runCheck();
        assertThat(check(badCheckDigit)).isEqualTo("check_digit");
        assertThat(check(unreadable)).isEqualTo("unreadable");
        clearInvocations(tx);
        logs.list.clear();

        runCheck();

        assertThat(check(badCheckDigit)).isEqualTo("check_digit");
        assertThat(check(unreadable)).isEqualTo("unreadable");
        verify(tx, never()).tryDecrypt(anyString());
        assertThat(runnerEvents()).as("nothing left to check, nothing logged").isEmpty();
    }

    @Test
    void aConcurrentCorrectionIsNeverOverwrittenByTheStartupSnapshot() {
        UUID corrected = legacyEmployee("concurrent", "身份证", "enc:" + VALID_ID);
        duringDecrypt.set(() -> jdbc.update(
                "UPDATE employee_sensitive SET id_card_enc = ?, id_card_check = 'check_digit' "
                        + "WHERE employee_id = ?",
                "enc:" + BAD_CHECK_DIGIT, corrected));

        runCheck();

        assertThat(check(corrected)).isEqualTo("check_digit");
        assertThat(text("SELECT id_card_enc FROM employee_sensitive WHERE employee_id = ?", corrected))
                .isEqualTo("enc:" + BAD_CHECK_DIGIT);
    }

    /** 人事在回填期间把解不开的号码重新登记了：保留人事的结果，不被 unreadable 盖掉。 */
    @Test
    void aConcurrentReentryOfAnUnreadableNumberIsNeverOverwritten() {
        UUID reentered = legacyEmployee("concurrent-unreadable", "身份证", "garbage-before-reentry");
        duringDecrypt.set(() -> jdbc.update(
                "UPDATE employee_sensitive SET id_card_enc = ?, id_card_check = 'valid' WHERE employee_id = ?",
                "enc:" + VALID_ID, reentered));

        runCheck();

        assertThat(check(reentered)).isEqualTo("valid");
        assertThat(text("SELECT id_card_enc FROM employee_sensitive WHERE employee_id = ?", reentered))
                .isEqualTo("enc:" + VALID_ID);
    }

    @Test
    void databaseRequiresAResultExactlyWhenACipherExists() {
        UUID cipherWithoutCheck = employee("cipher-no-check", "身份证");
        assertThatThrownBy(() -> jdbc.update(
                "INSERT INTO employee_sensitive(employee_id, id_card_enc) VALUES (?, 'enc:x')",
                cipherWithoutCheck))
                .hasMessageContaining("employee_sensitive_id_card_check_presence_ck");

        UUID checkWithoutCipher = employee("check-no-cipher", "身份证");
        assertThatThrownBy(() -> jdbc.update(
                "INSERT INTO employee_sensitive(employee_id, id_card_check) VALUES (?, 'valid')",
                checkWithoutCipher))
                .hasMessageContaining("employee_sensitive_id_card_check_presence_ck");
        assertThatThrownBy(() -> jdbc.update(
                "INSERT INTO employee_sensitive(employee_id, id_card_check) VALUES (?, 'unreadable')",
                checkWithoutCipher))
                .hasMessageContaining("employee_sensitive_id_card_check_presence_ck");

        UUID unknownValue = employee("unknown-value", "身份证");
        assertThatThrownBy(() -> jdbc.update(
                "INSERT INTO employee_sensitive(employee_id, id_card_enc, id_card_check) "
                        + "VALUES (?, 'enc:x', 'invalid')",
                unknownValue))
                .hasMessageContaining("employee_sensitive_id_card_check_value_ck");

        UUID unreadable = employee("stored-unreadable", "身份证");
        jdbc.update("INSERT INTO employee_sensitive(employee_id, id_card_enc, id_card_check) "
                + "VALUES (?, 'garbage', 'unreadable')", unreadable);
        assertThat(check(unreadable)).isEqualTo("unreadable");
    }

    @Test
    void oneWarnSummaryWithCountsOnlyAndNoErrorWhenSomeNumbersCannotBeRead() {
        legacyEmployee("log-valid", "身份证", "enc:" + VALID_ID);
        legacyEmployee("log-bad", "身份证", "enc:" + BAD_CHECK_DIGIT);
        legacyEmployee("log-unreadable", "身份证", "garbage-for-log");
        legacyEmployee("log-unreadable-2", "身份证", "garbage-for-log-2");

        runCheck();

        List<ILoggingEvent> runnerEvents = runnerEvents();
        assertThat(runnerEvents).as("one summary line, no per-row lines").hasSize(1);
        ILoggingEvent summary = runnerEvents.get(0);
        assertThat(summary.getLevel()).isEqualTo(Level.WARN);
        assertThat(summary.getFormattedMessage())
                .contains("valid=1", "problem=1", "unreadable=2", "changedConcurrently=0");
        assertThat(logs.list).as("no ERROR from any logger")
                .noneMatch(event -> event.getLevel().isGreaterOrEqual(Level.ERROR));
        // 运行时实际输出的级别 (INFO 及以上) 里没有号码、密文或姓名；测试自己插数据的 DEBUG 行不算。
        String all = String.join("\n", logs.list.stream()
                .filter(event -> event.getLevel().isGreaterOrEqual(Level.INFO))
                .map(ILoggingEvent::getFormattedMessage)
                .toList());
        assertThat(all).doesNotContain(VALID_ID, BAD_CHECK_DIGIT, "002X", "0021", "garbage-for-log",
                "V798-RUNNER", "V798 runner", "enc:");
    }

    @Test
    void allReadableRowsLogOneInfoSummary() {
        legacyEmployee("info-valid", "身份证", "enc:" + VALID_ID);

        runCheck();

        List<ILoggingEvent> runnerEvents = runnerEvents();
        assertThat(runnerEvents).hasSize(1);
        assertThat(runnerEvents.get(0).getLevel()).isEqualTo(Level.INFO);
        assertThat(runnerEvents.get(0).getFormattedMessage()).contains("valid=1", "unreadable=0");
    }

    private void runCheck() {
        runner.run(mock(ApplicationArguments.class));
    }

    private List<ILoggingEvent> runnerEvents() {
        return logs.list.stream()
                .filter(event -> EmployeeIdentityCheckRunner.class.getName().equals(event.getLoggerName()))
                .toList();
    }

    /** 和 TxSessionVars.tryDecrypt 一样：在当前事务的连接上设保存点，执行失败的 SQL，回滚到保存点，返回空。 */
    private static Optional<String> failInsideSavepoint() {
        return jdbc.execute((ConnectionCallback<Optional<String>>) connection -> {
            Savepoint savepoint = connection.setSavepoint();
            try (Statement statement = connection.createStatement()) {
                statement.executeQuery("SELECT 1 / 0").close();
            } catch (SQLException expected) {
                connection.rollback(savepoint);
                return Optional.empty();
            }
            throw new IllegalStateException("the failing decrypt stand-in unexpectedly succeeded");
        });
    }

    /** 照老库人事导入的方式写入：证件号密文 + unchecked。 */
    private static UUID legacyEmployee(String tag, String idType, String cipher) {
        return legacyEmployee(UUID.randomUUID(), tag, idType, cipher);
    }

    private static UUID legacyEmployee(UUID id, String tag, String idType, String cipher) {
        employee(id, tag, idType);
        jdbc.update("""
                INSERT INTO employee_sensitive (employee_id, id_card_enc, id_card_last4, id_card_check)
                VALUES (?, ?, right(CAST(? AS text), 4), 'unchecked')
                """, id, cipher, cipher);
        return id;
    }

    private static UUID employee(String tag, String idType) {
        return employee(UUID.randomUUID(), tag, idType);
    }

    private static UUID employee(UUID id, String tag, String idType) {
        jdbc.update("""
                INSERT INTO employees (
                    id, code, full_name, id_type, department_id, hire_date,
                    status, employment_type)
                SELECT ?, ?, ?, ?, department_id, DATE '2026-01-01', 'active', 'regular'
                FROM employees
                WHERE code = 'ADMIN'
                """, id, "V798-RUNNER-" + tag, "V798 runner " + tag, idType);
        return id;
    }

    private static String check(UUID employeeId) {
        return text("SELECT id_card_check FROM employee_sensitive WHERE employee_id = ?", employeeId);
    }

    private static String text(String sql, Object... args) {
        return jdbc.queryForObject(sql, String.class, args);
    }

    private static long count(String sql, Object... args) {
        Long value = jdbc.queryForObject(sql, Long.class, args);
        return value == null ? 0 : value;
    }
}
