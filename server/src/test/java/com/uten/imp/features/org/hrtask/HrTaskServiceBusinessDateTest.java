package com.uten.imp.features.org.hrtask;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class HrTaskServiceBusinessDateTest {
    @ParameterizedTest
    @CsvSource({
            "2026-10-02T15:59:59Z,2026-10-02,false",
            "2026-10-02T16:00:00Z,2026-10-03,true"
    })
    @SuppressWarnings({"rawtypes", "unchecked"})
    void remindersRollAtShanghaiMidnightRegardlessOfTheJvmDefaultClock(
            String instantText, String expectedDate, boolean today) throws Exception {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        HrTaskClaimService claims = mock(HrTaskClaimService.class);
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "hr-date-test",
                Set.of("employee:view", "employee:pii:view"), false, true, false)));
        when(claims.activeClaimsByTaskKey()).thenReturn(Map.of());
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("id", UUID.class)).thenReturn(UUID.randomUUID());
        when(row.getString("code")).thenReturn("HR-DATE-001");
        when(row.getString("full_name")).thenReturn("日期测试员工");
        when(row.getString("dept_name")).thenReturn("生产部");
        when(row.getDate("hire_date")).thenReturn(Date.valueOf("2026-07-03"));
        when(row.getDate("birth_date")).thenReturn(Date.valueOf("1990-10-03"));
        // V798 证件核对列：证件号已通过校验，不产生证件核对任务，不影响本用例的日期口径。
        when(row.getBoolean("id_card_missing")).thenReturn(false);
        when(row.getString("id_card_check")).thenReturn("valid");
        when(row.getBoolean("super_admin_account")).thenReturn(false);
        when(jdbc.query(anyString(), any(RowMapper.class))).thenAnswer(invocation ->
                List.of(((RowMapper) invocation.getArgument(1)).mapRow(row, 0)));
        when(jdbc.queryForList(anyString(), eq(2026))).thenReturn(List.of());
        HrTaskService service = new HrTaskService(jdbc, claims, current);
        for (String defaultZone : List.of("UTC", "America/Denver")) {
            Clock fixed = Clock.fixed(Instant.parse(instantText), ZoneId.of(defaultZone));
            try (var clocks = mockStatic(Clock.class)) {
                clocks.when(Clock::systemDefaultZone).thenReturn(fixed);
                clocks.when(() -> Clock.system(any(ZoneId.class)))
                        .thenAnswer(invocation -> fixed.withZone(invocation.getArgument(0)));
                HrTaskSummary result = service.summary();
                assertEquals(LocalDate.parse(expectedDate), result.generatedAt(), defaultZone);
                assertEquals(today ? 1 : 0, result.confirmToday().size(), defaultZone);
                assertEquals(today ? 0 : 1, result.confirmUpcoming().size(), defaultZone);
                assertEquals(today ? 1 : 0, result.birthdayToday().size(), defaultZone);
                assertEquals(today ? 0 : 1, result.birthdayUpcoming().size(), defaultZone);
                assertEquals(0, result.identityReview().size(), defaultZone);
            }
        }
    }
}
