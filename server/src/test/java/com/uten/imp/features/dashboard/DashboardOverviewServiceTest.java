package com.uten.imp.features.dashboard;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.profilechange.ProfileChangeReviewService;
import com.uten.imp.features.visitor.VisitorHrApprovalService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.mockito.ArgumentMatchers;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.AuthenticationCredentialsNotFoundException;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class DashboardOverviewServiceTest {

    private SecurityContextCurrentUser currentUser;
    private JdbcTemplate jdbc;
    private AuthUser user;
    private FulfillmentWorkbenchQueryService fulfillmentWorkbench;
    private NoticeService noticeService;
    private AuditService auditService;
    private DashboardOverviewService service;
    private UUID employeeId;
    private UUID userId;

    @BeforeEach
    @SuppressWarnings({"unchecked", "rawtypes"})
    void setUp() {
        currentUser = mock(SecurityContextCurrentUser.class);
        jdbc = mock(JdbcTemplate.class);
        user = mock(AuthUser.class);
        fulfillmentWorkbench = mock(FulfillmentWorkbenchQueryService.class);
        noticeService = mock(NoticeService.class);
        auditService = mock(AuditService.class);
        employeeId = UUID.randomUUID();
        userId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(user));
        when(user.isVisitor()).thenReturn(false);
        when(user.isSuperAdmin()).thenReturn(false);
        when(user.getEmployeeId()).thenReturn(employeeId);
        when(user.getId()).thenReturn(userId);
        when(user.getLoginAccount()).thenReturn("admin");
        when(jdbc.queryForList(anyString(), eq(employeeId))).thenReturn(List.of(
                Map.of("code", "DEPT_FIN", "name", "财税部", "depth", 0)));
        when(jdbc.query(anyString(), (RowMapper) any(RowMapper.class)))
                .thenReturn(List.of());

        service = new DashboardOverviewService(
                currentUser,
                jdbc,
                mock(ProductionScheduleService.class),
                fulfillmentWorkbench,
                mock(VisitorHrApprovalService.class),
                mock(ProfileChangeReviewService.class),
                noticeService,
                auditService);
    }

    @Test
    void overviewDoesNotWrapPartitionsInSharedTransaction() throws Exception {
        assertThat(DashboardOverviewService.class.isAnnotationPresent(
                Transactional.class)).isFalse();
        assertThat(DashboardOverviewService.class
                .getDeclaredMethod("overview")
                .isAnnotationPresent(Transactional.class))
                .isFalse();
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

    @ParameterizedTest
    @CsvSource({
            "SUB_WH,stock_doc:view,WAREHOUSE,仓库任务正在自动恢复,/operations/workbench/warehouse",
            "SUB_PURCHASE,purchase_request:view,PURCHASE,采购任务正在自动恢复,/operations/workbench/purchase",
            "QA_OUT,subcontract_order:view,SUBCONTRACT,委外任务正在自动恢复,/operations/workbench/subcontract"
    })
    void fulfillmentFailureReturnsUnavailableCardAndKeepsOtherSections(
            String departmentCode,
            String permission,
            String workbenchDepartment,
            String expectedTitle,
            String expectedRoute) {
        configureDepartment(
                departmentCode,
                Set.of("notice:read", permission));
        when(noticeService.unreadCount()).thenReturn(3L);
        when(noticeService.pendingTodos(8)).thenReturn(List.of());
        when(fulfillmentWorkbench.query(
                workbenchDepartment, "", "", "", 1, 1))
                .thenThrow(new ApiException(
                        ErrorCode.CONFLICT,
                        "工作台更新时间类型异常"));

        DashboardOverviewDto result = service.overview();

        assertThat(result.metrics())
                .extracting(DashboardOverviewDto.MetricCard::id)
                .contains("notice-unread");
        assertThat(result.todos())
                .filteredOn(todo ->
                        "FULFILLMENT_UNAVAILABLE".equals(todo.sourceType()))
                .singleElement()
                .satisfies(todo -> {
                    assertThat(todo.title()).isEqualTo(expectedTitle);
                    assertThat(todo.summary()).isEqualTo(
                            "其它功能可继续使用，无需退出或反复刷新");
                    assertThat(todo.count()).isZero();
                    assertThat(todo.urgentCount()).isZero();
                    assertThat(todo.tone()).isEqualTo("warning");
                    assertThat(todo.route()).isEqualTo(expectedRoute);
                    assertThat(todo.completable()).isFalse();
                });
        verify(auditService).logExplicit(
                userId,
                "admin",
                "dashboard_fulfillment_partition_degraded",
                "fulfillment_workbench",
                workbenchDepartment,
                "conflict");
    }

    @Test
    void fulfillmentAuthenticationFailureIsNotDegraded() {
        configurePurchaseDepartment(Set.of("purchase_request:view"));
        ApiException failure = new ApiException(ErrorCode.UNAUTHORIZED);
        when(fulfillmentWorkbench.query("PURCHASE", "", "", "", 1, 1))
                .thenThrow(failure);

        assertThatThrownBy(service::overview).isSameAs(failure);
        verifyNoInteractions(auditService);
    }

    @Test
    void fulfillmentAuthorizationFailureIsNotDegraded() {
        configurePurchaseDepartment(Set.of("purchase_request:view"));
        AccessDeniedException failure = new AccessDeniedException("denied");
        when(fulfillmentWorkbench.query("PURCHASE", "", "", "", 1, 1))
                .thenThrow(failure);

        assertThatThrownBy(service::overview).isSameAs(failure);
        verifyNoInteractions(auditService);
    }

    @Test
    void springAuthenticationFailureIsNotDegraded() {
        configurePurchaseDepartment(Set.of("purchase_request:view"));
        AuthenticationCredentialsNotFoundException failure =
                new AuthenticationCredentialsNotFoundException("missing");
        when(fulfillmentWorkbench.query("PURCHASE", "", "", "", 1, 1))
                .thenThrow(failure);

        assertThatThrownBy(service::overview).isSameAs(failure);
        verifyNoInteractions(auditService);
    }

    @Test
    void auditWriteFailureDoesNotUndoFulfillmentPartitionDegradation() {
        configurePurchaseDepartment(Set.of("notice:read", "purchase_request:view"));
        when(noticeService.unreadCount()).thenReturn(2L);
        when(noticeService.pendingTodos(8)).thenReturn(List.of());
        when(fulfillmentWorkbench.query("PURCHASE", "", "", "", 1, 1))
                .thenThrow(new ApiException(ErrorCode.CONFLICT));
        doThrow(new IllegalStateException("audit unavailable"))
                .when(auditService)
                .logExplicit(
                        userId,
                        "admin",
                        "dashboard_fulfillment_partition_degraded",
                        "fulfillment_workbench",
                        "PURCHASE",
                        "conflict");

        DashboardOverviewDto result = service.overview();

        assertThat(result.metrics())
                .extracting(DashboardOverviewDto.MetricCard::id)
                .contains("notice-unread");
        assertThat(result.todos())
                .singleElement()
                .extracting(DashboardOverviewDto.TodoCard::sourceType)
                .isEqualTo("FULFILLMENT_UNAVAILABLE");
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

    private void configurePurchaseDepartment(Set<String> permissions) {
        configureDepartment("SUB_PURCHASE", permissions);
    }

    private void configureDepartment(
            String departmentCode, Set<String> permissions) {
        when(user.getPermissions()).thenReturn(permissions);
        when(jdbc.queryForList(anyString(), eq(employeeId))).thenReturn(List.of(
                Map.of(
                        "code", departmentCode,
                        "name", departmentCode,
                        "depth", 0)));
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
