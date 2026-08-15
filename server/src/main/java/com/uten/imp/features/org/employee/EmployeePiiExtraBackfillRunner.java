package com.uten.imp.features.org.employee;

import com.uten.imp.security.TxSessionVars;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.availability.AvailabilityChangeEvent;
import org.springframework.boot.availability.ReadinessState;
import org.springframework.context.ApplicationContext;
import org.springframework.core.annotation.Order;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.Date;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * Fail-closed V282 application-side migration for the seven employee PII
 * columns that historically lived as plaintext on {@code employees}.
 *
 * <p>A dedicated PostgreSQL advisory lock serializes this runner with every
 * other application instance and the reviewed legacy HR import scripts.  Each
 * employee is then re-read and locked in its own short transaction; the
 * matching {@code employee_sensitive} row is locked as well.  V286 permits
 * legacy/bootstrap employees without primary identity or phone ciphertext;
 * when such an employee has legacy extension plaintext, this runner creates
 * the missing row without inventing either value.  Existing ciphertext is
 * decrypted and compared before plaintext is cleared, so an online/newer
 * value can never be overwritten by a stale startup snapshot.</p>
 *
 * <p>Spring Boot remains REFUSING_TRAFFIC while runners execute.
 * Conflicting/unreadable ciphertext, a failed row creation or reload, a lost
 * conditional update, or any remaining plaintext aborts startup.</p>
 */
@Component
@Order(60)
public class EmployeePiiExtraBackfillRunner implements ApplicationRunner {

    private static final Logger log =
            LoggerFactory.getLogger(EmployeePiiExtraBackfillRunner.class);
    private static final int BATCH_SIZE = 100;
    /** ASCII "UTEN" plus the migration version; shared with HR SQL scripts. */
    private static final int ADVISORY_LOCK_NAMESPACE = 0x5554454E;
    private static final int ADVISORY_LOCK_ID = 282;

    private final JdbcTemplate jdbc;
    private final TxSessionVars tx;
    private final TransactionTemplate transactionTemplate;
    private final ApplicationContext applicationContext;

    public EmployeePiiExtraBackfillRunner(
            JdbcTemplate jdbc,
            TxSessionVars tx,
            PlatformTransactionManager transactionManager,
            ApplicationContext applicationContext) {
        this.jdbc = jdbc;
        this.tx = tx;
        this.transactionTemplate = new TransactionTemplate(transactionManager);
        this.applicationContext = applicationContext;
    }

    @Override
    public void run(ApplicationArguments args) {
        AvailabilityChangeEvent.publish(
                applicationContext, ReadinessState.REFUSING_TRAFFIC);
        withGlobalMigrationLock(this::migrateLocked);
    }

    private void migrateLocked() {
        long migrated = 0;
        while (true) {
            List<UUID> ids = nextBatch();
            if (ids.isEmpty()) {
                break;
            }
            for (UUID id : ids) {
                Boolean changed = transactionTemplate.execute(status -> backfillOne(id));
                if (Boolean.TRUE.equals(changed)) {
                    migrated++;
                }
            }
        }

        Long remaining = jdbc.queryForObject(
                "SELECT count(*) FROM employees WHERE " + pendingPredicate(),
                Long.class);
        if (remaining == null || remaining != 0) {
            Long missingSensitive = jdbc.queryForObject(
                    """
                    SELECT count(*)
                    FROM employees employee
                    LEFT JOIN employee_sensitive sensitive
                      ON sensitive.employee_id = employee.id
                    WHERE (%s)
                      AND sensitive.employee_id IS NULL
                    """.formatted(pendingPredicate("employee")),
                    Long.class);
            throw new IllegalStateException(
                    "employee PII V282 backfill did not clear every legacy plaintext row; "
                            + "remaining=" + remaining
                            + ", missingSensitive=" + missingSensitive);
        }
        if (migrated > 0) {
            log.info("Employee V282 PII backfill completed for {} employees; legacy plaintext cleared",
                    migrated);
        }
    }

    private List<UUID> nextBatch() {
        return jdbc.query(
                """
                SELECT id
                FROM employees
                WHERE %s
                ORDER BY id
                LIMIT ?
                """.formatted(pendingPredicate()),
                statement -> statement.setInt(1, BATCH_SIZE),
                (result, rowNumber) -> result.getObject("id", UUID.class));
    }

    private boolean backfillOne(UUID id) {
        tx.bindEmployeePiiExtraBackfillV1();

        List<LegacyEmployeePii> employeeRows = jdbc.query(
                """
                SELECT id, huji_address, residence_address, email, birth_date,
                       marital_status, political_status, office_phone
                FROM employees
                WHERE id = ?
                FOR UPDATE
                """,
                statement -> statement.setObject(1, id),
                (result, rowNumber) -> new LegacyEmployeePii(
                        result.getObject("id", UUID.class),
                        result.getString("huji_address"),
                        result.getString("residence_address"),
                        result.getString("email"),
                        toLocalDate(result.getDate("birth_date")),
                        result.getString("marital_status"),
                        result.getString("political_status"),
                        result.getString("office_phone")));
        if (employeeRows.isEmpty()) {
            return false;
        }
        LegacyEmployeePii employee = employeeRows.get(0);
        if (!employee.hasPlaintext()) {
            return false;
        }

        List<SensitiveCipherRow> sensitiveRows = loadSensitiveForUpdate(id);
        if (sensitiveRows.isEmpty()) {
            // The employee row is locked and the global V282 lock is held.
            // ON CONFLICT closes the race with a reviewed writer that inserted
            // the optional V286 row just before this statement.
            jdbc.update(
                    """
                    INSERT INTO employee_sensitive (employee_id)
                    VALUES (?)
                    ON CONFLICT (employee_id) DO NOTHING
                    """,
                    id);
            sensitiveRows = loadSensitiveForUpdate(id);
        }
        if (sensitiveRows.size() != 1) {
            throw new IllegalStateException(
                    "employee PII V282 backfill could not create or lock "
                            + "employee_sensitive row for " + id);
        }
        SensitiveCipherRow sensitive = sensitiveRows.get(0);

        writeOrVerify(id, "huji_address_enc",
                employee.hujiAddress(), sensitive.hujiAddressCipher());
        writeOrVerify(id, "residence_address_enc",
                employee.residenceAddress(), sensitive.residenceAddressCipher());
        writeOrVerify(id, "email_enc", employee.email(), sensitive.emailCipher());
        writeOrVerify(id, "birth_date_enc",
                employee.birthDate() == null ? null : employee.birthDate().toString(),
                sensitive.birthDateCipher());
        writeOrVerify(id, "marital_status_enc",
                employee.maritalStatus(), sensitive.maritalStatusCipher());
        writeOrVerify(id, "political_status_enc",
                employee.politicalStatus(), sensitive.politicalStatusCipher());
        writeOrVerify(id, "office_phone_enc",
                employee.officePhone(), sensitive.officePhoneCipher());

        String birthMonthDay = employee.birthDate() == null
                ? null
                : String.format(
                        "%02d-%02d",
                        employee.birthDate().getMonthValue(),
                        employee.birthDate().getDayOfMonth());
        int cleared = jdbc.update(
                """
                UPDATE employees
                SET huji_address = NULL,
                    residence_address = NULL,
                    email = NULL,
                    birth_date = NULL,
                    marital_status = NULL,
                    political_status = NULL,
                    office_phone = NULL,
                    birth_month_day = COALESCE(?, birth_month_day)
                WHERE id = ?
                  AND (%s)
                """.formatted(pendingPredicate()),
                birthMonthDay, id);
        if (cleared != 1) {
            throw new IllegalStateException(
                    "employee PII V282 backfill lost locked row ownership for " + id);
        }
        return true;
    }

    private List<SensitiveCipherRow> loadSensitiveForUpdate(UUID id) {
        return jdbc.query(
                """
                SELECT employee_id, huji_address_enc, residence_address_enc,
                       email_enc, birth_date_enc, marital_status_enc,
                       political_status_enc, office_phone_enc
                FROM employee_sensitive
                WHERE employee_id = ?
                FOR UPDATE
                """,
                statement -> statement.setObject(1, id),
                (result, rowNumber) -> new SensitiveCipherRow(
                        result.getObject("employee_id", UUID.class),
                        result.getString("huji_address_enc"),
                        result.getString("residence_address_enc"),
                        result.getString("email_enc"),
                        result.getString("birth_date_enc"),
                        result.getString("marital_status_enc"),
                        result.getString("political_status_enc"),
                        result.getString("office_phone_enc")));
    }

    private void writeOrVerify(
            UUID employeeId,
            String encryptedColumn,
            String legacyPlain,
            String existingCipher) {
        if (legacyPlain == null) {
            return;
        }
        if (existingCipher != null) {
            final String existingPlain;
            try {
                existingPlain = tx.decrypt(existingCipher);
            } catch (RuntimeException exception) {
                throw new IllegalStateException(
                        "employee PII V282 backfill cannot decrypt existing "
                                + encryptedColumn + " for " + employeeId,
                        exception);
            }
            if (!Objects.equals(existingPlain, legacyPlain)) {
                throw new IllegalStateException(
                        "employee PII V282 backfill found conflicting existing "
                                + encryptedColumn + " for " + employeeId);
            }
            return;
        }

        String cipher = tx.encrypt(legacyPlain);
        if (cipher == null) {
            if (legacyPlain.isBlank()) {
                return;
            }
            throw new IllegalStateException(
                    "employee PII V282 encryption returned no ciphertext for "
                            + encryptedColumn + " on " + employeeId);
        }
        int updated = jdbc.update(
                "UPDATE employee_sensitive SET " + encryptedColumn
                        + " = ? WHERE employee_id = ? AND " + encryptedColumn + " IS NULL",
                cipher, employeeId);
        if (updated != 1) {
            throw new IllegalStateException(
                    "employee PII V282 conditional write lost "
                            + encryptedColumn + " ownership for " + employeeId);
        }
    }

    private void withGlobalMigrationLock(Runnable action) {
        DataSource dataSource = Objects.requireNonNull(
                jdbc.getDataSource(), "JdbcTemplate has no DataSource");
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(true);
            try (PreparedStatement lock = connection.prepareStatement(
                    "SELECT pg_advisory_lock(?, ?)")) {
                lock.setInt(1, ADVISORY_LOCK_NAMESPACE);
                lock.setInt(2, ADVISORY_LOCK_ID);
                lock.executeQuery().close();
            }
            try {
                action.run();
            } finally {
                try (PreparedStatement unlock = connection.prepareStatement(
                        "SELECT pg_advisory_unlock(?, ?)")) {
                    unlock.setInt(1, ADVISORY_LOCK_NAMESPACE);
                    unlock.setInt(2, ADVISORY_LOCK_ID);
                    try (ResultSet result = unlock.executeQuery()) {
                        if (!result.next() || !result.getBoolean(1)) {
                            throw new IllegalStateException(
                                    "employee PII V282 advisory lock ownership was lost");
                        }
                    }
                }
            }
        } catch (SQLException exception) {
            throw new IllegalStateException(
                    "employee PII V282 global migration lock failed", exception);
        }
    }

    private static LocalDate toLocalDate(Date value) {
        return value == null ? null : value.toLocalDate();
    }

    private static String pendingPredicate() {
        return pendingPredicate(null);
    }

    private static String pendingPredicate(String alias) {
        String prefix = alias == null || alias.isBlank() ? "" : alias + ".";
        return prefix + "huji_address IS NOT NULL"
                + " OR " + prefix + "residence_address IS NOT NULL"
                + " OR " + prefix + "email IS NOT NULL"
                + " OR " + prefix + "birth_date IS NOT NULL"
                + " OR " + prefix + "marital_status IS NOT NULL"
                + " OR " + prefix + "political_status IS NOT NULL"
                + " OR " + prefix + "office_phone IS NOT NULL";
    }

    private record LegacyEmployeePii(
            UUID id,
            String hujiAddress,
            String residenceAddress,
            String email,
            LocalDate birthDate,
            String maritalStatus,
            String politicalStatus,
            String officePhone) {

        boolean hasPlaintext() {
            return hujiAddress != null
                    || residenceAddress != null
                    || email != null
                    || birthDate != null
                    || maritalStatus != null
                    || politicalStatus != null
                    || officePhone != null;
        }
    }

    private record SensitiveCipherRow(
            UUID employeeId,
            String hujiAddressCipher,
            String residenceAddressCipher,
            String emailCipher,
            String birthDateCipher,
            String maritalStatusCipher,
            String politicalStatusCipher,
            String officePhoneCipher) {
    }
}
