package com.uten.imp.features.dashboard;

import com.uten.imp.application.port.SalesDocumentReadScopePort;
import com.uten.imp.application.port.WorkbenchBadgeReadPort;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.mockito.ArgumentMatchers;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.ResultSetExtractor;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.HashSet;
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
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class DashboardOverviewServiceTest {

    private SecurityContextCurrentUser currentUser;
    private JdbcTemplate jdbc;
    private AuthUser user;
    private NoticeService noticeService;
    private SalesDocumentReadScopePort salesAccess;
    private WorkbenchBadgeReadPort badges;
    private DashboardOverviewService service;
    private UUID employeeId;
    private UUID userId;

    /** 模拟「徽章端口对当前主体全部放行」: 被请求的入口都给数(部门筛选是否生效由请求集合体现)。 */
    private final Map<String, Long> badgeTodo = new HashMap<>();
    private final Map<String, Long> badgeFacts = new HashMap<>();
    private final Set<String> badgeStale = new HashSet<>();
    private final List<Set<String>> badgeRequests = new java.util.ArrayList<>();

    @BeforeEach
    @SuppressWarnings({"unchecked", "rawtypes"})
    void setUp() {
        currentUser = mock(SecurityContextCurrentUser.class);
        jdbc = mock(JdbcTemplate.class);
        user = mock(AuthUser.class);
        noticeService = mock(NoticeService.class);
        salesAccess = mock(SalesDocumentReadScopePort.class);
        badges = mock(WorkbenchBadgeReadPort.class);
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
        badgeTodo.putAll(Map.of(
                "productionSchedule", 4L,
                "warehouseDrawCenter", 5L,
                "purchaseTaskCenter", 6L,
                "subcontractTaskCenter", 7L,
                "visitorApproval", 2L,
                "hrProfileReview", 1L,
                "expenseFinance", 5L));
        badgeFacts.putAll(Map.of(
                "productionSchedule.count", 4L,
                "productionSchedule.overdue", 1L,
                "productionSchedule.urgent", 2L,
                "expense.pendingApprovalCount", 3L,
                "expense.pendingPaymentCount", 2L));
        when(badges.entries(any())).thenAnswer(invocation -> {
            Set<String> wanted = invocation.getArgument(0);
            badgeRequests.add(Set.copyOf(wanted));
            Map<String, Long> todo = new HashMap<>();
            for (String entry : wanted) {
                if (badgeTodo.containsKey(entry)) todo.put(entry, badgeTodo.get(entry));
            }
            Set<String> stale = new HashSet<>(badgeStale);
            stale.retainAll(wanted);
            return new WorkbenchBadgeReadPort.Entries(todo, badgeFacts, stale);
        });

        service = new DashboardOverviewService(
                currentUser,
                jdbc,
                noticeService,
                salesAccess,
                badges);
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
    void accountViewAloneDoesNotExposeTopLevelFinanceAmounts() {
        when(user.getPermissions()).thenReturn(Set.of("account:view"));

        DashboardOverviewDto result = service.overview();

        assertThat(result.metrics())
                .extracting(DashboardOverviewDto.MetricCard::id)
                .doesNotContain("cash-balance", "ar-balance", "ap-balance");
        verify(jdbc, never()).queryForObject(
                contains("FROM accounts"), eq(BigDecimal.class));
        verify(jdbc, never()).query(
                contains("FROM ar_ap_ledger"),
                ArgumentMatchers.<ResultSetExtractor<Map<String, BigDecimal>>>any());
    }

    @Test
    void explicitSensitivePermissionsStillDoNotExposeTopLevelFinanceAmounts() {
        when(user.getPermissions()).thenReturn(Set.of(
                "account:view",
                "ar_ap_ledger:view",
                "dashboard:finance_sensitive:view"));

        DashboardOverviewDto result = service.overview();

        assertThat(result.metrics())
                .extracting(DashboardOverviewDto.MetricCard::id)
                .doesNotContain("cash-balance", "ar-balance", "ap-balance");
        verify(jdbc, never()).queryForObject(
                contains("FROM accounts"), eq(BigDecimal.class));
        verify(jdbc, never()).query(
                contains("FROM ar_ap_ledger"),
                ArgumentMatchers.<ResultSetExtractor<Map<String, BigDecimal>>>any());
    }

    @Test
    void financeUserSeesFinanceCategoriesButNotInspectionActivities()
            throws Exception {
        when(user.getPermissions())
                .thenReturn(Set.of("dashboard:finance_sensitive:view"));
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

    @Test
    void salesMetricUsesTheSameOwnerScopeAsSalesDocuments() {
        configureDepartment("DEPT_SALES", Set.of("sales_order:view"));
        when(salesAccess.nativeReadScope("o.owner_employee_id", "dashboardOwners"))
                .thenReturn(new DocumentAccessPolicy.NativeReadScope(
                        "(o.owner_employee_id IS NULL OR o.owner_employee_id IN (:dashboardOwners))",
                        "dashboardOwners", Set.of(employeeId)));
        when(jdbc.queryForObject(contains("o.owner_employee_id IN (?)"),
                eq(Long.class), eq(employeeId))).thenReturn(2L);

        assertThat(service.overview().metrics()).singleElement()
                .satisfies(metric -> {
                    assertThat(metric.id()).isEqualTo("sales-active");
                    assertThat(metric.value()).isEqualTo("2");
                });
        verify(jdbc).queryForObject(contains("o.owner_employee_id IN (?)"),
                eq(Long.class), eq(employeeId));
    }


    /**
     * 本部门待办只有一套口径(permissions-08): 卡片数字 = 对应徽章入口的红数(报销按事实数拆
     * 待审批/待付款两张卡), 概览不再自己写计数 SQL。
     */
    @Test
    void departmentTodosComeFromTheBadgeEntriesOnly() {
        configureDepartment("DEPT_FIN", Set.of("expense:approve", "expense:pay"));

        DashboardOverviewDto result = service.overview();

        assertThat(badgeRequests).containsExactly(Set.of("expenseFinance"));
        assertThat(result.todos())
                .extracting(DashboardOverviewDto.TodoCard::id, DashboardOverviewDto.TodoCard::count)
                .containsExactly(
                        org.assertj.core.groups.Tuple.tuple("expense-approval", 3L),
                        org.assertj.core.groups.Tuple.tuple("expense-payment", 2L));
        verify(jdbc, never()).queryForObject(contains("expense_claims"), eq(Long.class),
                ArgumentMatchers.<Object[]>any());
        verify(jdbc, never()).queryForObject(contains("payroll_batches"), eq(Long.class));
    }

    @ParameterizedTest
    @CsvSource({
            "SUB_WH,warehouseDrawCenter,fulfillment-warehouse,5,/warehouse/tasks/draw,你有 5 项仓库领料与退料任务待处理",
            "SUB_PURCHASE,purchaseTaskCenter,fulfillment-purchase,6,/operations/workbench/purchase,你有 6 项采购任务待处理",
            "QA_OUT,subcontractTaskCenter,fulfillment-subcontract,7,/operations/workbench/subcontract,你有 7 项委外任务待处理"
    })
    void fulfillmentDepartmentsReadTheirTaskCenterBadge(
            String departmentCode, String entry, String todoId, long count, String route, String title) {
        configureDepartment(departmentCode, Set.of());

        DashboardOverviewDto result = service.overview();

        assertThat(badgeRequests.getFirst()).contains(entry);
        assertThat(result.todos()).filteredOn(todo -> todo.id().equals(todoId))
                .singleElement()
                .satisfies(todo -> {
                    assertThat(todo.count()).isEqualTo(count);
                    assertThat(todo.title()).isEqualTo(title);
                    assertThat(todo.route()).isEqualTo(route);
                    assertThat(todo.sourceType()).isEqualTo("FULFILLMENT");
                });
    }

    @Test
    void productionMetricAndTodoUseTheScheduleBadgeFacts() {
        configureDepartment("DEPT_PROD", Set.of("production_plan:view"));

        DashboardOverviewDto result = service.overview();

        assertThat(result.metrics()).filteredOn(metric -> metric.id().equals("production-pending"))
                .singleElement()
                .satisfies(metric -> {
                    assertThat(metric.value()).isEqualTo("4");
                    assertThat(metric.subtitle()).isEqualTo("1 个已逾期");
                    assertThat(metric.tone()).isEqualTo("danger");
                });
        assertThat(result.todos()).filteredOn(todo -> todo.id().equals("production-pending"))
                .singleElement()
                .satisfies(todo -> {
                    assertThat(todo.count()).isEqualTo(4);
                    assertThat(todo.urgentCount()).isEqualTo(2);
                    assertThat(todo.summary()).contains("1 个已逾期");
                });
    }

    /** 没权(入口不出现)或来源本次没算出(残缺数)都不出卡, 其它入口照常。 */
    @Test
    void missingOrStaleBadgeEntryShowsNoCard() {
        configureDepartment("DEPT_HR", Set.of("visitor:approve"));
        badgeTodo.remove("hrProfileReview");
        badgeStale.add("visitorApproval");

        assertThat(service.overview().todos()).isEmpty();

        badgeStale.clear();
        assertThat(service.overview().todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .containsExactly("visitor-approval");
    }

    @Test
    void subcontractReportPermissionAloneDoesNotExposeTaskOverview() {
        configureDepartment("QA_OUT", Set.of("subcontract_report:view"));
        // 委外任务中心来源的 @PreAuthorize 不放行 subcontract_report:view: 入口不出现。
        badgeTodo.remove("subcontractTaskCenter");
        assertThat(service.overview().todos()).isEmpty();
    }

    /**
     * 工作台待办的口径是「**权限 ∧ 本部门**」，不是「有权限就展示」。
     *
     * <p>用户 2026-09-12 原话：「不是有权限就展示，就得需要你是这个部门，
     * 只展示这个部门的内容」。权限由徽章来源判定(端口对这些人全部放行也一样),
     * 部门决定请求哪些入口——别部门的入口根本不去算。
     */
    @ParameterizedTest
    @CsvSource({
            // 部门, 权限码, 该权限对应的待办 id
            "DEPT_PROD,visitor:approve,visitor-approval",
            "DEPT_PROD,profile:review,profile-review",
            "DEPT_PROD,expense:approve,expense-approval",
            "DEPT_PROD,expense:pay,expense-payment",
            "SUB_WH,expense:approve,expense-approval",
            "DEPT_FIN,visitor:approve,visitor-approval",
            "DEPT_HR,expense:approve,expense-approval"
    })
    void permissionAloneDoesNotSurfaceAnotherDepartmentsTodo(
            String departmentCode, String permission, String todoId) {
        configureDepartment(departmentCode, Set.of(permission));

        DashboardOverviewDto result = service.overview();

        assertThat(result.todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .as("%s 部门的人持有 %s，也不该在工作台看到 %s",
                        departmentCode, permission, todoId)
                .doesNotContain(todoId);
    }

    /** 反向：在本部门时照常出现(不能为了收窄把正主也挡掉)。 */
    @Test
    void ownDepartmentStillSeesItsTodo() {
        configureDepartment("DEPT_HR", Set.of("visitor:approve"));
        assertThat(service.overview().todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .contains("visitor-approval", "profile-review");

        configureDepartment("DEPT_FIN", Set.of("expense:approve"));
        assertThat(service.overview().todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .contains("expense-approval");
    }

    @Test
    void superAdminOnlySeesOwnDepartmentsOverview() {
        when(user.isSuperAdmin()).thenReturn(true);
        when(noticeService.pendingTodos(eq(8))).thenReturn(List.of());
        configureDepartment("DEPT_FIN", Set.of());

        DashboardOverviewDto result = service.overview();
        assertThat(badgeRequests).containsExactly(Set.of("expenseFinance"));
        assertThat(result.todos()).extracting(DashboardOverviewDto.TodoCard::id)
                .contains("expense-approval")
                .doesNotContain("visitor-approval", "production-pending", "fulfillment-warehouse");
    }

    @Test
    void unassignedSuperAdminDoesNotQueryDepartmentWork() {
        when(user.isSuperAdmin()).thenReturn(true);
        when(user.getEmployeeId()).thenReturn(null);
        when(noticeService.pendingTodos(eq(8))).thenReturn(List.of());
        DashboardOverviewDto result = service.overview();
        assertThat(result.todos()).isEmpty();
        assertThat(result.metrics()).extracting(DashboardOverviewDto.MetricCard::id)
                .containsOnly("notice-unread");
        verifyNoInteractions(badges);
    }

    /**
     * 兼职部门也是「本人的部门」：用户主部门在生产，但**兼职**在财务（depth=1 的
     * 第二行来自 employee_secondary_departments）——通知侧会给这样的用户推财务
     * 待办（ReviewNoticeAudience 的 memberships 含 secondary），工作台必须同口径，
     * 否则他在通知里看到活、工作台上却没有。
     */
    @Test
    void secondaryDepartmentMembershipSurfacesItsTodos() {
        when(user.getPermissions()).thenReturn(Set.of("expense:approve"));
        when(jdbc.queryForList(anyString(), eq(employeeId))).thenReturn(List.of(
                Map.of("code", "DEPT_PROD", "name", "生产部", "depth", 0),
                Map.of("code", "DEPT_FIN", "name", "财税部", "depth", 1)));

        DashboardOverviewDto result = service.overview();

        assertThat(badgeRequests).containsExactly(Set.of("productionSchedule", "expenseFinance"));
        assertThat(result.todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .as("兼职财务的人应照常看到财务待办")
                .contains("expense-approval");
        // 面板上显示的「本部门」仍是主部门，不因兼职改写身份表述。
        assertThat(result.departmentName()).isEqualTo("生产部");
    }

    private void configureDepartment(
            String departmentCode, Set<String> permissions) {
        badgeRequests.clear();
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
