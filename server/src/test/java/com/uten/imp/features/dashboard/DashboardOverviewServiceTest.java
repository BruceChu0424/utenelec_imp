package com.uten.imp.features.dashboard;

import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.profilechange.ProfileChangeReviewService;
import com.uten.imp.features.visitor.VisitorHrApprovalService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentMatchers;
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

    @Test
    void financeUserSeesFinanceCategoriesButNotInspectionActivities()
            throws Exception {
        when(user.getPermissions())
                .thenReturn(Set.of("dashboard:finance-sensitive:view"));
        stubPolicyRows(
                policyRow("TAX"),
                policyRow("EXPORT"),
                policyRow("INSPECTION"),
                policyRow("SAFETY"),
                policyRow("QUALITY"));

        DashboardOverviewDto result = service.overview();

        assertThat(result.intelligence())
                .extracting(DashboardOverviewDto.PolicyBrief::category)
                .containsExactly("TAX", "EXPORT");
    }

    @Test
    void gmLeaderSeesInspectionActivitiesAndFinanceCategories() throws Exception {
        when(user.getPermissions()).thenReturn(Set.of());
        when(jdbc.queryForList(anyString(), eq(employeeId))).thenReturn(List.of(
                Map.of("code", "GM", "name", "总经办", "depth", 0)));
        stubPolicyRows(
                policyRow("TAX"),
                policyRow("INSPECTION"),
                policyRow("SAFETY"),
                policyRow("QUALITY"));

        DashboardOverviewDto result = service.overview();

        assertThat(result.intelligence())
                .extracting(DashboardOverviewDto.PolicyBrief::category)
                .containsExactlyInAnyOrder("TAX", "INSPECTION", "SAFETY", "QUALITY");
    }

    @Test
    void employeeInGmSubDepartmentDoesNotInheritGmAudience() throws Exception {
        when(user.getPermissions()).thenReturn(Set.of());
        // 直属部门是总经办的下级部门；祖先链 depth>0 的 GM 标签必须被剔除。
        when(jdbc.queryForList(anyString(), eq(employeeId))).thenReturn(List.of(
                Map.of("code", "SUB_WH", "name", "仓库组", "depth", 0),
                Map.of("code", "GM", "name", "总经办", "depth", 1)));
        stubPolicyRows(policyRow("SAFETY"), policyRow("TAX"));

        DashboardOverviewDto result = service.overview();

        assertThat(result.intelligence()).isEmpty();
    }

    private void stubPolicyRows(java.sql.ResultSet... rows) {
        when(jdbc.query(
                contains("official_policy_briefs"),
                ArgumentMatchers.<RowMapper<Object>>any()))
                .thenAnswer(invocation -> {
                    RowMapper<Object> mapper = invocation.getArgument(1);
                    List<Object> mapped = new java.util.ArrayList<>();
                    for (int i = 0; i < rows.length; i++) {
                        mapped.add(mapper.mapRow(rows[i], i));
                    }
                    return mapped;
                });
    }

    private java.sql.ResultSet policyRow(String category) throws Exception {
        java.sql.ResultSet rs = mock(java.sql.ResultSet.class);
        when(rs.getObject("id", UUID.class)).thenReturn(UUID.randomUUID());
        when(rs.getString("title")).thenReturn("标题-" + category);
        when(rs.getString("summary")).thenReturn("摘要");
        when(rs.getString("category")).thenReturn(category);
        when(rs.getString("source_name")).thenReturn("官方来源");
        when(rs.getString("source_url"))
                .thenReturn("https://www.gov.cn/zhengce/" + category);
        when(rs.getObject("published_on", java.time.LocalDate.class))
                .thenReturn(java.time.LocalDate.of(2026, 4, 2));
        when(rs.getTimestamp("captured_at"))
                .thenReturn(new java.sql.Timestamp(0L));
        return rs;
    }
}
