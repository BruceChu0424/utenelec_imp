package com.uten.imp.features.dashboard;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.profilechange.ProfileChangeReviewService;
import com.uten.imp.features.visitor.VisitorHrApprovalService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class DashboardOverviewServiceTest {

    private SecurityContextCurrentUser currentUser;
    private JdbcTemplate jdbc;
    private AuthUser user;
    private DashboardOverviewService service;
    private UUID employeeId;

    @BeforeEach
    @SuppressWarnings({"unchecked", "rawtypes"})
    void setUp() {
        currentUser = mock(SecurityContextCurrentUser.class);
        jdbc = mock(JdbcTemplate.class);
        user = mock(AuthUser.class);
        employeeId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(user));
        when(user.isVisitor()).thenReturn(false);
        when(user.isSuperAdmin()).thenReturn(false);
        when(user.getEmployeeId()).thenReturn(employeeId);
        when(jdbc.queryForList(anyString(), eq(employeeId))).thenReturn(List.of(
                Map.of("code", "DEPT_FIN", "name", "财税部", "depth", 0)));
        when(jdbc.query(anyString(), (RowMapper) any(RowMapper.class)))
                .thenReturn(List.of());

        service = new DashboardOverviewService(
                currentUser,
                jdbc,
                new ObjectMapper(),
                mock(ProductionScheduleService.class),
                mock(FulfillmentWorkbenchQueryService.class),
                mock(VisitorHrApprovalService.class),
                mock(ProfileChangeReviewService.class),
                mock(NoticeService.class));
    }

    @Test
    void legacyAccountViewAloneDoesNotExposeSensitiveBalance() {
        when(user.getPermissions()).thenReturn(Set.of("account:view"));

        DashboardOverviewDto result = service.overview();

        assertThat(result.metrics())
                .noneMatch(metric -> metric.id().equals("cash-balance"));
        verify(jdbc, never()).queryForObject(
                contains("FROM accounts"), eq(BigDecimal.class));
    }

    @Test
    void explicitSensitivePermissionAndAccountViewExposeBalance() {
        when(user.getPermissions()).thenReturn(Set.of(
                "account:view", "dashboard:finance-sensitive:view"));
        when(jdbc.queryForObject(
                contains("FROM accounts"), eq(BigDecimal.class)))
                .thenReturn(new BigDecimal("123456.78"));

        DashboardOverviewDto result = service.overview();

        assertThat(result.metrics())
                .anySatisfy(metric -> {
                    assertThat(metric.id()).isEqualTo("cash-balance");
                    assertThat(metric.value()).isEqualTo("¥123,456.78");
                    assertThat(metric.sensitive()).isTrue();
                });
    }
}
