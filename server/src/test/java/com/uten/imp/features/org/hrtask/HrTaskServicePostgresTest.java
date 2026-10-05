package com.uten.imp.features.org.hrtask;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Real PostgreSQL evidence for {@link HrTaskService} birthday reminders.
 *
 * <p>Regression guard for the empty 生日提醒: V282 moved birth dates into
 * {@code employee_sensitive.birth_date_enc} and blocks plaintext
 * {@code employees.birth_date}, so the service must match the non-sensitive
 * {@code employees.birth_month_day}. These tests run the exact service SQL
 * against the full Flyway chain, with fixtures written through the same
 * columns the application writes (birth_date stays NULL).
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class HrTaskServicePostgresTest {

    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static JdbcTemplate jdbc;

    private SecurityContextCurrentUser currentUser;
    private HrTaskService service;

    @BeforeAll
    static void open() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("hr_task_birthday");
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                database.getJdbcUrl(), database.getUsername(), database.getPassword()));
    }

    @AfterAll
    static void close() throws Exception {
        if (database != null) database.close();
    }

    @BeforeEach
    void setUp() {
        jdbc.update("DELETE FROM notice_celebration_subjects WHERE notice_id IN "
                + "(SELECT id FROM notices WHERE title LIKE 'HRTASK-TEST-%')");
        jdbc.update("DELETE FROM notices WHERE title LIKE 'HRTASK-TEST-%'");
        jdbc.update("DELETE FROM employees WHERE code LIKE 'HRTASK-TEST-%'");
        // Neutralize seed rows (e.g. ADMIN) so only this test's fixtures feed birthdays or the badge.
        jdbc.update("UPDATE employees SET birth_month_day = NULL WHERE birth_month_day IS NOT NULL");
        jdbc.update("UPDATE employees SET hire_date = ? WHERE code NOT LIKE 'HRTASK-TEST-%'",
                quietHireDate());

        HrTaskClaimService claims = mock(HrTaskClaimService.class);
        when(claims.activeClaimsByTaskKey()).thenReturn(Map.of());
        currentUser = mock(SecurityContextCurrentUser.class);
        actingAs(Set.of("employee:view", "employee:pii:view"));
        service = new HrTaskService(jdbc, claims, currentUser);
    }

    @Test
    void employeeWhoseBirthMonthDayIsTodayAppearsInBirthdayTodayAndCountsInBadge() {
        LocalDate today = BusinessTime.today();
        UUID birthdayToday = insertEmployee("today", "active", monthDay(today));
        UUID probationToday = insertEmployee("probation", "probation", monthDay(today));
        UUID inFiveDays = insertEmployee("upcoming", "active", monthDay(today.plusDays(5)));
        UUID noBirthday = insertEmployee("none", "active", null);
        UUID resigned = insertEmployee("resigned", "resigned", monthDay(today));

        // The production write path never fills the plaintext column; the reminder must not need it.
        assertEquals(0, jdbc.queryForObject(
                "SELECT count(*) FROM employees WHERE birth_date IS NOT NULL", Long.class));

        HrTaskSummary summary = service.summary();

        assertEquals(today, summary.generatedAt());
        assertEquals(Set.of(birthdayToday, probationToday), idsOf(summary.birthdayToday()));
        HrTaskSummary.Item item = itemOf(summary.birthdayToday(), birthdayToday);
        assertEquals(today, item.date());
        assertEquals(0, item.days());
        assertEquals("今日生日", item.note());
        assertFalse(item.blessed());
        assertEquals("HRTASK 测试 today", item.name());

        HrTaskSummary.Item upcoming = itemOf(summary.birthdayUpcoming(), inFiveDays);
        assertEquals(5, upcoming.days());
        assertEquals(today.plusDays(5), upcoming.date());
        assertFalse(idsOf(summary.birthdayUpcoming()).contains(noBirthday));
        assertFalse(idsOf(summary.birthdayToday()).contains(resigned));

        assertEquals(2, summary.badgeCount(), () -> "summary=" + summary);
        assertEquals(2, service.badgeCount());
    }

    @Test
    void blessedBirthdayStaysListedButLeavesTheBadge() {
        LocalDate today = BusinessTime.today();
        UUID blessed = insertEmployee("blessed", "active", monthDay(today));
        UUID pending = insertEmployee("pending", "active", monthDay(today));
        insertBirthdayNotice(blessed, today);

        HrTaskSummary summary = service.summary();

        assertEquals(Set.of(blessed, pending), idsOf(summary.birthdayToday()));
        assertTrue(itemOf(summary.birthdayToday(), blessed).blessed());
        assertFalse(itemOf(summary.birthdayToday(), pending).blessed());
        assertEquals(1, summary.badgeCount(), () -> "summary=" + summary);
    }

    @Test
    void callerWithoutPiiViewSeesNoBirthdaysAndNoBirthdayBadge() {
        LocalDate today = BusinessTime.today();
        insertEmployee("today", "active", monthDay(today));
        insertEmployee("upcoming", "active", monthDay(today.plusDays(3)));
        actingAs(Set.of("employee:view"));

        HrTaskSummary summary = service.summary();

        assertTrue(summary.birthdayToday().isEmpty());
        assertTrue(summary.birthdayUpcoming().isEmpty());
        assertEquals(0, summary.badgeCount());
    }

    // ------------------------------------------------------------------

    private void actingAs(Set<String> permissions) {
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "hr-task-pg-test", permissions, false, true, false)));
    }

    private static Set<UUID> idsOf(List<HrTaskSummary.Item> items) {
        return items.stream().map(HrTaskSummary.Item::employeeId)
                .collect(java.util.stream.Collectors.toSet());
    }

    private static HrTaskSummary.Item itemOf(List<HrTaskSummary.Item> items, UUID employeeId) {
        return items.stream().filter(it -> employeeId.equals(it.employeeId())).findFirst()
                .orElseThrow(() -> new AssertionError(employeeId + " missing from " + items));
    }

    private static String monthDay(LocalDate date) {
        return String.format("%02d-%02d", date.getMonthValue(), date.getDayOfMonth());
    }

    /**
     * Long-ago hire date whose month-day is yesterday: no 转正 today/overdue (older than the
     * 12-month tracking window), no 周年 today, not a new hire — contributes nothing to the badge.
     */
    private static LocalDate quietHireDate() {
        return BusinessTime.today().minusDays(1).withYear(2000);
    }

    private static UUID insertEmployee(String tag, String status, String birthMonthDay) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees (
                    id, code, full_name, id_type, department_id, hire_date,
                    status, employment_type, birth_month_day)
                SELECT ?, ?, ?, '其他', department_id, ?, ?, 'regular', ?
                FROM employees
                WHERE code = 'ADMIN'
                """,
                // Employee codes stay reserved after delete (global business identifier registry),
                // so every fixture gets a fresh code even when tests reuse the same tag.
                id, "HRTASK-TEST-" + tag + "-" + id.toString().substring(0, 8),
                "HRTASK 测试 " + tag, quietHireDate(), status, birthMonthDay);
        return id;
    }

    private static void insertBirthdayNotice(UUID employeeId, LocalDate publishedOn) {
        String title = "HRTASK-TEST-birthday-" + employeeId;
        jdbc.update("""
                INSERT INTO notices (title, content, type, publisher, subject_employee_id, subject_name, published_at)
                VALUES (?, '测试内容', 'birthday', '公司', ?, '寿星', ?::date AT TIME ZONE 'Asia/Shanghai')
                """,
                title, employeeId, publishedOn.toString());
        jdbc.update("""
                INSERT INTO notice_celebration_subjects (notice_id, employee_id, employee_name, event_label)
                SELECT id, subject_employee_id, subject_name, '生日快乐' FROM notices WHERE title = ?
                """,
                title);
    }
}
