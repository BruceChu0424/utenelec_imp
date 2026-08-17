package com.uten.imp.features.notice;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.LocalDate;
import java.time.ZoneId;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.matches;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Real PostgreSQL evidence for {@link CelebrationScheduler}.
 *
 * <p>Regression guard for the 2026-08-17 incident where text-block
 * concatenation produced {@code WHEREe.is_deleted} (BadSqlGrammarException)
 * and the daily celebration scan silently never ran. These tests execute the
 * exact SQL the scheduler emits against a real PostgreSQL 16 with the full
 * Flyway migration chain, so any future grammar/typo regression fails here
 * instead of being swallowed by the scheduler's warn-only catch block.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class CelebrationSchedulerPostgresTest {

    private static final ZoneId SHANGHAI = ZoneId.of("Asia/Shanghai");

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static JdbcTemplate jdbc;

    private NoticeService noticeService;
    private CelebrationScheduler scheduler;

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
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword()));
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @BeforeEach
    void setUp() {
        jdbc.update("DELETE FROM notices WHERE title LIKE 'CELEB-TEST-%'");
        jdbc.update("DELETE FROM employees WHERE code LIKE 'CELEB-TEST-%'");
        // Neutralize seed rows (e.g. ADMIN) so only this test's fixtures can match today.
        jdbc.update("UPDATE employees SET birth_month_day = NULL WHERE birth_month_day IS NOT NULL");
        jdbc.update("UPDATE employees SET hire_date = ? WHERE code NOT LIKE 'CELEB-TEST-%'",
                safeNonTodayDate());

        noticeService = mock(NoticeService.class);
        SystemSettingsService settings = mock(SystemSettingsService.class);
        when(settings.readBool(anyString(), anyBoolean())).thenReturn(true);
        when(settings.readString(eq("celebration.auto_types"), anyString()))
                .thenReturn("birthday,anniversary");
        when(settings.readString(eq("celebration.publisher_name"), anyString()))
                .thenReturn("公司");
        scheduler = new CelebrationScheduler(jdbc, noticeService, settings);
    }

    @Test
    void publishesBirthdayForActiveAndProbationEmployeesMatchingToday() {
        UUID active = insertEmployee("bday-active", "active", false, todayMonthDay(), safeNonTodayDate());
        UUID probation = insertEmployee("bday-probation", "probation", false, todayMonthDay(), safeNonTodayDate());
        insertEmployee("bday-empty", "active", false, null, safeNonTodayDate());

        scheduler.scan();

        verify(noticeService).publishCelebrationBroadcast(
                eq("birthday"), eq(active), eq("CELEB 测试 bday-active"), eq("生日快乐"), eq("公司"));
        verify(noticeService).publishCelebrationBroadcast(
                eq("birthday"), eq(probation), eq("CELEB 测试 bday-probation"), eq("生日快乐"), eq("公司"));
        verify(noticeService, times(2)).publishCelebrationBroadcast(
                any(), any(), any(), any(), any());
    }

    @Test
    void publishesAnniversaryOnlyForEmployeesHiredAtLeastOneFullYearAgoToday() {
        UUID veteran = insertEmployee("anniv-veteran", "active", false, null, hiredYearsAgoToday(5));
        insertEmployee("anniv-fresh", "active", false, null, LocalDate.now(SHANGHAI));

        scheduler.scan();

        verify(noticeService).publishCelebrationBroadcast(
                eq("anniversary"), eq(veteran), eq("CELEB 测试 anniv-veteran"),
                matches("入职\\d+周年"), eq("公司"));
        verify(noticeService, times(1)).publishCelebrationBroadcast(
                any(), any(), any(), any(), any());
    }

    @Test
    void excludesResignedDeletedAndAlreadyCelebratedThisYear() {
        int year = LocalDate.now(SHANGHAI).getYear();
        UUID resigned = insertEmployee("ex-resigned", "resigned", false, todayMonthDay(), safeNonTodayDate());
        UUID deleted = insertEmployee("ex-deleted", "active", true, todayMonthDay(), safeNonTodayDate());
        UUID duplicated = insertEmployee("ex-dup", "active", false, todayMonthDay(), safeNonTodayDate());
        insertCelebrationNotice(duplicated, "birthday", LocalDate.of(year, 1, 2));
        UUID lastYearOnly = insertEmployee("ex-last-year", "active", false, todayMonthDay(), safeNonTodayDate());
        insertCelebrationNotice(lastYearOnly, "birthday", LocalDate.of(year - 1, 6, 15));

        scheduler.scan();

        verify(noticeService, never()).publishCelebrationBroadcast(
                any(), eq(resigned), any(), any(), any());
        verify(noticeService, never()).publishCelebrationBroadcast(
                any(), eq(deleted), any(), any(), any());
        verify(noticeService, never()).publishCelebrationBroadcast(
                any(), eq(duplicated), any(), any(), any());
        // 去年的通知不挡今年：去年发过生日的员工今年仍应再发一次。
        verify(noticeService).publishCelebrationBroadcast(
                eq("birthday"), eq(lastYearOnly), any(), eq("生日快乐"), eq("公司"));
        verify(noticeService, times(1)).publishCelebrationBroadcast(
                any(), any(), any(), any(), any());
    }

    // ------------------------------------------------------------------

    private static String todayMonthDay() {
        LocalDate today = LocalDate.now(SHANGHAI);
        return String.format("%02d-%02d", today.getMonthValue(), today.getDayOfMonth());
    }

    /** A real date whose month-day never equals today (also valid on Feb 29 runs). */
    private static LocalDate safeNonTodayDate() {
        return LocalDate.now(SHANGHAI).minusDays(1).withYear(2000);
    }

    /** Hire date exactly {@code years} before today; on Feb 29 uses the previous leap year. */
    private static LocalDate hiredYearsAgoToday(int years) {
        LocalDate today = LocalDate.now(SHANGHAI);
        if (today.getMonthValue() == 2 && today.getDayOfMonth() == 29) {
            return LocalDate.of(today.getYear() - 4, 2, 29);
        }
        return LocalDate.of(today.getYear() - years, today.getMonthValue(), today.getDayOfMonth());
    }

    private static UUID insertEmployee(
            String tag, String status, boolean deleted, String birthMonthDay, LocalDate hireDate) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees (
                    id, code, full_name, id_type, department_id, hire_date,
                    status, employment_type, birth_month_day, is_deleted)
                SELECT ?, ?, ?, '其他', department_id, ?, ?, 'regular', ?, ?
                FROM employees
                WHERE code = 'ADMIN'
                """,
                id,
                "CELEB-TEST-" + tag,
                "CELEB 测试 " + tag,
                hireDate,
                status,
                birthMonthDay,
                deleted);
        return id;
    }

    private static void insertCelebrationNotice(UUID employeeId, String type, LocalDate publishedOn) {
        jdbc.update("""
                INSERT INTO notices (title, content, type, publisher, subject_employee_id, published_at)
                VALUES (?, '测试内容', ?, '公司', ?, ?::date AT TIME ZONE 'Asia/Shanghai')
                """,
                "CELEB-TEST-" + type + "-" + employeeId,
                type,
                employeeId,
                publishedOn.toString());
    }
}
