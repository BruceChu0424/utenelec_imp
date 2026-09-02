package com.uten.imp.features.notice;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.notice.NoticeService.CelebrationSubject;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.LocalDate;
import java.time.ZoneId;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
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
 *
 * <p>V454 semantics: each type publishes exactly ONE aggregated group card per
 * scan (all of today's uncovered subjects in a single call); per-person
 * anniversary labels are derived per subject (张三 入职5周年、李四 入职10周年).
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
    void publishesOneAggregatedBirthdayCardForAllMatchingEmployees() {
        UUID active = insertEmployee("bday-active", "active", false, todayMonthDay(), safeNonTodayDate());
        UUID probation = insertEmployee("bday-probation", "probation", false, todayMonthDay(), safeNonTodayDate());
        insertEmployee("bday-empty", "active", false, null, safeNonTodayDate());

        scheduler.scan();

        // 一张聚合卡：两位今日主角在同一次调用里，而不是每人一张卡
        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("birthday"), captureSubjects(), eq("公司"));
        List<CelebrationSubject> subjects = capturedSubjects();
        assertEquals(2, subjects.size());
        assertTrue(subjects.stream().anyMatch(s -> s.employeeId().equals(active)
                && "CELEB 测试 bday-active".equals(s.name()) && "生日快乐".equals(s.eventLabel())));
        assertTrue(subjects.stream().anyMatch(s -> s.employeeId().equals(probation)
                && "CELEB 测试 bday-probation".equals(s.name())));
        // 周年类型当天无主角 → 不发卡
        verify(noticeService, never()).publishCelebrationGroupBroadcast(
                eq("anniversary"), any(), any());
    }

    @Test
    void publishesOneAggregatedAnniversaryCardWithPerPersonLabels() {
        UUID veteran = insertEmployee("anniv-veteran", "active", false, null, hiredYearsAgoToday(5));
        UUID veteran2 = insertEmployee("anniv-veteran2", "active", false, null, hiredYearsAgoToday(10));
        insertEmployee("anniv-fresh", "active", false, null, LocalDate.now(SHANGHAI));

        scheduler.scan();

        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("anniversary"), captureSubjects(), eq("公司"));
        List<CelebrationSubject> subjects = capturedSubjects();
        // 未满 1 年不进卡；满年的逐人带自己的年数标签。
        // 注：容器 DB 会话时区可能与上海日期差一天（跨日窗口），年数允许 ±1，
        // 只断言「各自年数」且工龄更长者年数严格更大（10 年 > 5 年）。
        assertEquals(2, subjects.size(), () -> "subjects=" + subjects);
        String veteranLabel = labelOf(subjects, veteran);
        String veteran2Label = labelOf(subjects, veteran2);
        assertTrue(veteranLabel.matches("入职[45]周年"), () -> "veteran label=" + veteranLabel);
        assertTrue(veteran2Label.matches("入职(9|10)周年"),
                () -> "veteran2 label=" + veteran2Label);
        assertTrue(yearsOf(veteran2Label) > yearsOf(veteranLabel),
                "工龄 10 年者的周年数必须大于工龄 5 年者");
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

        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("birthday"), captureSubjects(), eq("公司"));
        List<CelebrationSubject> subjects = capturedSubjects();
        // 离职/已删/本年已祝福者不进卡；去年发过不挡今年
        assertEquals(1, subjects.size());
        assertEquals(lastYearOnly, subjects.getFirst().employeeId());
        assertTrue(subjects.stream().noneMatch(s -> s.employeeId().equals(resigned)));
        assertTrue(subjects.stream().noneMatch(s -> s.employeeId().equals(deleted)));
        assertTrue(subjects.stream().noneMatch(s -> s.employeeId().equals(duplicated)));
    }

    // ------------------------------------------------------------------

    @SuppressWarnings("unchecked")
    private final ArgumentCaptor<List<CelebrationSubject>> subjectCaptor =
            ArgumentCaptor.forClass(List.class);

    /** 作为 matcher 用：verify(...).publishCelebrationGroupBroadcast(eq(...), captureSubjects(), eq(...)) */
    private List<CelebrationSubject> captureSubjects() {
        return subjectCaptor.capture();
    }

    private List<CelebrationSubject> capturedSubjects() {
        return subjectCaptor.getValue();
    }

    private static String labelOf(List<CelebrationSubject> subjects, UUID employeeId) {
        return subjects.stream()
                .filter(s -> employeeId.equals(s.employeeId()))
                .findFirst()
                .map(CelebrationSubject::eventLabel)
                .orElse("（缺失）");
    }

    /** 从「入职N周年」标签提取 N（缺失/畸形 → -1）。 */
    private static int yearsOf(String label) {
        var m = java.util.regex.Pattern.compile("入职(\\d+)周年").matcher(label);
        return m.find() ? Integer.parseInt(m.group(1)) : -1;
    }

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
        // V454 去重按主角表判定 → 存量卡同时落 notice_celebration_subjects（迁移回填同口径）
        jdbc.update("""
                INSERT INTO notices (title, content, type, publisher, subject_employee_id, subject_name, published_at)
                VALUES (?, '测试内容', ?, '公司', ?, '历史寿星', ?::date AT TIME ZONE 'Asia/Shanghai')
                """,
                "CELEB-TEST-" + type + "-" + employeeId,
                type,
                employeeId,
                publishedOn.toString());
        jdbc.update("""
                INSERT INTO notice_celebration_subjects (notice_id, employee_id, employee_name, event_label)
                SELECT id, subject_employee_id, COALESCE(subject_name, '（未知）'), '生日快乐'
                FROM notices WHERE title = ?
                """,
                "CELEB-TEST-" + type + "-" + employeeId);
    }
}
