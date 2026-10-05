package com.uten.imp.features.notice;

import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
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
    private SystemSettingsService settings;
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
        settings = mock(SystemSettingsService.class);
        when(settings.readBool(SystemSettingKey.CELEBRATION_AUTO_ENABLED)).thenReturn(true);
        when(settings.readString(SystemSettingKey.CELEBRATION_AUTO_TYPES))
                .thenReturn("birthday,anniversary");
        when(settings.readString(SystemSettingKey.CELEBRATION_PUBLISHER_NAME))
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
        LocalDate veteranHire = hiredYearsAgoToday(5);
        LocalDate veteran2Hire = hiredYearsAgoToday(10);
        UUID veteran = insertEmployee("anniv-veteran", "active", false, null, veteranHire);
        UUID veteran2 = insertEmployee("anniv-veteran2", "active", false, null, veteran2Hire);
        insertEmployee("anniv-fresh", "active", false, null, LocalDate.now(SHANGHAI));

        scheduler.scan();

        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("anniversary"), captureSubjects(), eq("公司"));
        List<CelebrationSubject> subjects = capturedSubjects();
        // 未满 1 年不进卡；满年的逐人带自己的年数标签。年数按扫描业务日在服务端算
        // (不再用 DB 的 age()，容器会话时区不影响)，故断言精确年数。
        int year = LocalDate.now(SHANGHAI).getYear();
        assertEquals(2, subjects.size(), () -> "subjects=" + subjects);
        assertEquals("入职" + (year - veteranHire.getYear()) + "周年", labelOf(subjects, veteran));
        assertEquals("入职" + (year - veteran2Hire.getYear()) + "周年", labelOf(subjects, veteran2));
        assertTrue(yearsOf(labelOf(subjects, veteran2)) > yearsOf(labelOf(subjects, veteran)),
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

    @Test
    void leapDayBirthdaysAreCelebratedOnFeb28InCommonYearsOnly() {
        when(settings.readString(SystemSettingKey.CELEBRATION_AUTO_TYPES)).thenReturn("birthday");
        UUID leap = insertEmployee("leap-day", "active", false, "02-29", safeNonTodayDate());
        UUID feb28 = insertEmployee("feb-28", "active", false, "02-28", safeNonTodayDate());
        insertEmployee("mar-01", "active", false, "03-01", safeNonTodayDate());

        // 非闰年 2/28：2/29 生日并入当天聚合卡(与 HR 任务中心 BirthMonthDay 同口径)
        scheduler.scan(LocalDate.of(2027, 2, 28));
        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("birthday"), captureSubjects(), eq("公司"));
        assertEquals(java.util.Set.of(leap, feb28), subjectIds(capturedSubjects()));

        // 闰年 2/28 只有 2/28 本人；2/29 当天才轮到 2/29 生日
        org.mockito.Mockito.clearInvocations(noticeService);
        scheduler.scan(LocalDate.of(2028, 2, 28));
        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("birthday"), captureSubjects(), eq("公司"));
        assertEquals(java.util.Set.of(feb28), subjectIds(capturedSubjects()));

        org.mockito.Mockito.clearInvocations(noticeService);
        scheduler.scan(LocalDate.of(2028, 2, 29));
        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("birthday"), captureSubjects(), eq("公司"));
        assertEquals(java.util.Set.of(leap), subjectIds(capturedSubjects()));
    }

    @Test
    void leapDayHiresGetTheirAnniversaryOnFeb28InCommonYearsWithFullYearCount() {
        when(settings.readString(SystemSettingKey.CELEBRATION_AUTO_TYPES)).thenReturn("anniversary");
        // 固定业务日扫描：先把种子行与其他用例的入职日挪到不会命中的 6/15，免受真实运行日期影响
        jdbc.update("UPDATE employees SET hire_date = DATE '2000-06-15'");
        UUID leap = insertEmployee("hire-leap-day", "active", false, null, LocalDate.of(2024, 2, 29));
        UUID feb28 = insertEmployee("hire-feb-28", "active", false, null, LocalDate.of(2020, 2, 28));
        UUID mar01 = insertEmployee("hire-mar-01", "active", false, null, LocalDate.of(2021, 3, 1));
        insertEmployee("hire-leap-same-day", "active", false, null, LocalDate.of(2028, 2, 29));

        // 非闰年 2/28：2/29 入职并入当天聚合卡，记满 3 年(PostgreSQL age() / Period.between 此日只算 2 年)
        scheduler.scan(LocalDate.of(2027, 2, 28));
        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("anniversary"), captureSubjects(), eq("公司"));
        assertEquals(java.util.Map.of(leap, "入职3周年", feb28, "入职7周年"), labels(capturedSubjects()));

        // 非闰年 3/1 不再补发 2/29 入职
        org.mockito.Mockito.clearInvocations(noticeService);
        scheduler.scan(LocalDate.of(2027, 3, 1));
        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("anniversary"), captureSubjects(), eq("公司"));
        assertEquals(java.util.Map.of(mar01, "入职6周年"), labels(capturedSubjects()));

        // 闰年 2/28 只有 2/28 入职；2/29 当天才轮到 2/29 入职(当天新入职的未满 1 年不进卡)
        org.mockito.Mockito.clearInvocations(noticeService);
        scheduler.scan(LocalDate.of(2028, 2, 28));
        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("anniversary"), captureSubjects(), eq("公司"));
        assertEquals(java.util.Map.of(feb28, "入职8周年"), labels(capturedSubjects()));

        org.mockito.Mockito.clearInvocations(noticeService);
        scheduler.scan(LocalDate.of(2028, 2, 29));
        verify(noticeService, times(1)).publishCelebrationGroupBroadcast(
                eq("anniversary"), captureSubjects(), eq("公司"));
        assertEquals(java.util.Map.of(leap, "入职4周年"), labels(capturedSubjects()));
    }

    // ------------------------------------------------------------------

    private static java.util.Map<UUID, String> labels(List<CelebrationSubject> subjects) {
        return subjects.stream().collect(java.util.stream.Collectors.toMap(
                CelebrationSubject::employeeId, CelebrationSubject::eventLabel));
    }

    private static java.util.Set<UUID> subjectIds(List<CelebrationSubject> subjects) {
        return subjects.stream().map(CelebrationSubject::employeeId)
                .collect(java.util.stream.Collectors.toSet());
    }

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

    /**
     * Hire date exactly {@code years} before today; on Feb 29 rounds down to a leap year
     * (multiple of 4 years back, at least 4) so longer tenures still get more years.
     */
    private static LocalDate hiredYearsAgoToday(int years) {
        LocalDate today = LocalDate.now(SHANGHAI);
        if (today.getMonthValue() == 2 && today.getDayOfMonth() == 29) {
            return LocalDate.of(today.getYear() - 4 * Math.max(1, years / 4), 2, 29);
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
