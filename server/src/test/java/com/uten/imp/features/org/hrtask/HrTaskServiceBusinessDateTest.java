package com.uten.imp.features.org.hrtask;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.sql.Date;
import java.sql.ResultSet;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class HrTaskServiceBusinessDateTest {

    private static final Set<String> PII = Set.of("employee:view", "employee:pii:view");

    @ParameterizedTest
    @CsvSource({
            "2026-10-02T15:59:59Z,2026-10-02,false",
            "2026-10-02T16:00:00Z,2026-10-03,true"
    })
    void remindersRollAtShanghaiMidnightRegardlessOfTheJvmDefaultClock(
            String instantText, String expectedDate, boolean today) throws Exception {
        HrTaskService service = service(PII, "2026-07-03", "10-03");
        for (String defaultZone : List.of("UTC", "America/Denver")) {
            HrTaskSummary result = summaryAt(service, Instant.parse(instantText), defaultZone);
            assertEquals(LocalDate.parse(expectedDate), result.generatedAt(), defaultZone);
            assertEquals(today ? 1 : 0, result.confirmToday().size(), defaultZone);
            assertEquals(today ? 0 : 1, result.confirmUpcoming().size(), defaultZone);
            assertEquals(today ? 1 : 0, result.birthdayToday().size(), defaultZone);
            assertEquals(today ? 0 : 1, result.birthdayUpcoming().size(), defaultZone);
        }
    }

    /** 生日来自 birth_month_day(无年份)：今日行 days = 0、不再派生周岁；2/29 非闰年按 2/28。 */
    @ParameterizedTest
    @CsvSource({
            "10-03,2026-10-03,today,0,2026-10-03",
            "10-08,2026-10-03,upcoming,5,2026-10-08",
            "02-29,2027-02-28,today,0,2027-02-28",
            "02-29,2028-02-28,upcoming,1,2028-02-29",
            "02-29,2028-02-29,today,0,2028-02-29",
            "02-29,2027-03-01,none,0,",
            "02-30,2026-10-03,none,0,"
    })
    void birthdaysMatchStoredMonthDayWithLeapDayFallback(
            String birthMonthDay, String today, String window, int days, String date) throws Exception {
        HrTaskService service = service(PII, "2000-06-15", birthMonthDay);
        HrTaskSummary result = summaryAt(service, shanghaiNoon(today), "UTC");

        List<HrTaskSummary.Item> hits = switch (window) {
            case "today" -> result.birthdayToday();
            case "upcoming" -> result.birthdayUpcoming();
            default -> List.of();
        };
        assertEquals("today".equals(window) ? 1 : 0, result.birthdayToday().size());
        assertEquals("upcoming".equals(window) ? 1 : 0, result.birthdayUpcoming().size());
        assertEquals("today".equals(window) ? 1 : 0, result.badgeCount());
        if (!hits.isEmpty()) {
            HrTaskSummary.Item item = hits.getFirst();
            assertEquals(days, item.days());
            assertEquals(LocalDate.parse(date), item.date());
            assertEquals("today".equals(window) ? "今日生日" : null, item.note());
        }
    }

    /** 入职周年与庆典自动发布 / 本人今日庆典同口径(WorkAnniversary)：2/29 入职非闰年 2/28 过，当天即满 N 年。 */
    @ParameterizedTest
    @CsvSource({
            "2024-02-29,2027-02-28,3",
            "2024-02-29,2027-03-01,-1",
            "2024-02-29,2028-02-28,-1",
            "2024-02-29,2028-02-29,4",
            "2020-02-28,2027-02-28,7",
            "2027-02-28,2027-02-28,-1"
    })
    void anniversariesOfLeapDayHiresFallOnFeb28InCommonYears(
            String hireDate, String today, int years) throws Exception {
        HrTaskService service = service(PII, hireDate, null);
        HrTaskSummary result = summaryAt(service, shanghaiNoon(today), "UTC");

        if (years < 0) {
            assertTrue(result.anniversaryToday().isEmpty());
        } else {
            assertEquals(1, result.anniversaryToday().size());
            HrTaskSummary.Item item = result.anniversaryToday().getFirst();
            assertEquals(years, item.days());
            assertEquals("入职满 " + years + " 年", item.note());
        }
    }

    @Test
    void callersWithoutPiiViewGetNoBirthdaysAndNoBirthdayBadge() throws Exception {
        HrTaskService service = service(Set.of("employee:view"), "2000-06-15", "10-03");
        HrTaskSummary result = summaryAt(service, shanghaiNoon("2026-10-03"), "UTC");
        assertTrue(result.birthdayToday().isEmpty());
        assertTrue(result.birthdayUpcoming().isEmpty());
        assertEquals(0, result.badgeCount());
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    private static HrTaskService service(Set<String> permissions, String hireDate, String birthMonthDay)
            throws Exception {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        HrTaskClaimService claims = mock(HrTaskClaimService.class);
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "hr-date-test", permissions, false, true, false)));
        when(claims.activeClaimsByTaskKey()).thenReturn(Map.of());
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("id", UUID.class)).thenReturn(UUID.randomUUID());
        when(row.getString("code")).thenReturn("HR-DATE-001");
        when(row.getString("full_name")).thenReturn("日期测试员工");
        when(row.getString("dept_name")).thenReturn("生产部");
        when(row.getDate("hire_date")).thenReturn(Date.valueOf(hireDate));
        when(row.getString("birth_month_day")).thenReturn(birthMonthDay);
        // V807 证件核对列：证件号已通过校验，不产生证件核对任务，不影响本用例的日期口径。
        when(row.getBoolean("id_card_missing")).thenReturn(false);
        when(row.getString("id_card_check")).thenReturn("valid");
        when(row.getBoolean("super_admin_account")).thenReturn(false);
        when(jdbc.query(anyString(), any(RowMapper.class))).thenAnswer(invocation ->
                List.of(((RowMapper) invocation.getArgument(1)).mapRow(row, 0)));
        when(jdbc.queryForList(anyString(), anyInt())).thenReturn(List.of());
        return new HrTaskService(jdbc, claims, current);
    }

    private static HrTaskSummary summaryAt(HrTaskService service, Instant instant, String defaultZone) {
        Clock fixed = Clock.fixed(instant, ZoneId.of(defaultZone));
        try (var clocks = mockStatic(Clock.class)) {
            clocks.when(Clock::systemDefaultZone).thenReturn(fixed);
            clocks.when(() -> Clock.system(any(ZoneId.class)))
                    .thenAnswer(invocation -> fixed.withZone(invocation.getArgument(0)));
            return service.summary();
        }
    }

    private static Instant shanghaiNoon(String date) {
        return LocalDate.parse(date).atTime(12, 0).atZone(ZoneId.of("Asia/Shanghai")).toInstant();
    }
}
