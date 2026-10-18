package com.uten.imp.features.org.hrtask;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.sql.Date;
import java.sql.ResultSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class HrTaskActionCountTest {
    @Test void viewingEmployeesAndBirthdaysDoesNotMakeThemPersonalWork() throws Exception {
        HrTaskSummary result = summary(Set.of("employee:view", "employee:pii:view"));
        assertThat(result.confirmToday()).hasSize(1);
        assertThat(result.birthdayToday()).hasSize(1);
        assertThat(result.badgeCount()).isZero();
        assertThat(result.taskCounts().values()).containsOnly(0L);
    }

    @Test void eachActionCountsOnlyItsOwnBucketAndPublishingStillRequiresBirthdayRead() throws Exception {
        assertThat(summary(Set.of("employee:view", "employee:pii:view", "employee:confirm")).taskCounts())
                .containsEntry("confirm", 1L).containsEntry("birthday", 0L);
        assertThat(summary(Set.of("employee:view", "employee:pii:view", "notice:publish")).taskCounts())
                .containsEntry("confirm", 0L).containsEntry("birthday", 1L);
        assertThat(summary(Set.of("employee:view", "notice:publish")).taskCounts())
                .containsEntry("confirm", 0L).containsEntry("birthday", 0L);
        assertThat(summary(Set.of("employee:view", "employee:pii:view", "employee:confirm", "notice:publish")).badgeCount())
                .isEqualTo(2L);
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private HrTaskSummary summary(Set<String> grants) throws Exception {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        HrTaskClaimService claims = mock(HrTaskClaimService.class);
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        UUID employee = UUID.randomUUID();
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employee,
                "cross-department-hr", grants, false, true, false)));
        when(current.employeeId()).thenReturn(Optional.of(employee));
        when(claims.activeClaimsByTaskKey()).thenReturn(Map.of());
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("id", UUID.class)).thenReturn(UUID.randomUUID());
        when(row.getString("code")).thenReturn("TASK-HR");
        when(row.getString("full_name")).thenReturn("任务资格员工");
        when(row.getDate("hire_date")).thenReturn(Date.valueOf(BusinessTime.today().minusMonths(3)));
        when(row.getString("birth_month_day")).thenReturn(BusinessTime.today().toString().substring(5));
        when(row.getString("id_card_check")).thenReturn("valid");
        when(jdbc.query(anyString(), any(RowMapper.class))).thenAnswer(call ->
                List.of(((RowMapper) call.getArgument(1)).mapRow(row, 0)));
        return new HrTaskService(jdbc, claims, current,
                com.uten.imp.testsupport.TaskAudienceTestSupport.direct()).summary();
    }
}
