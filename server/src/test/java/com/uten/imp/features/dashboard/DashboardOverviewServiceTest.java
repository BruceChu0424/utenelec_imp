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
import org.springframework.jdbc.core.ResultSetExtractor;
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
    // 提成字段（2026-09-12）：部门门控的正向用例需要给它们喂非零计数，
    // 否则 addCountTodo 的 count<=0 早退会让「应该出现」的断言恒假。
    private VisitorHrApprovalService visitorApprovalService;
    private ProfileChangeReviewService profileChangeReviewService;
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
        visitorApprovalService = mock(VisitorHrApprovalService.class);
        profileChangeReviewService = mock(ProfileChangeReviewService.class);
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
                visitorApprovalService,
                profileChangeReviewService,
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
                "dashboard:finance-sensitive:view"));

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
                workbenchDepartment, "", "", "", null, null, 1, 1))
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
        when(fulfillmentWorkbench.query("PURCHASE", "", "", "", null, null, 1, 1))
                .thenThrow(failure);

        assertThatThrownBy(service::overview).isSameAs(failure);
        verifyNoInteractions(auditService);
    }

    @Test
    void fulfillmentAuthorizationFailureIsNotDegraded() {
        configurePurchaseDepartment(Set.of("purchase_request:view"));
        AccessDeniedException failure = new AccessDeniedException("denied");
        when(fulfillmentWorkbench.query("PURCHASE", "", "", "", null, null, 1, 1))
                .thenThrow(failure);

        assertThatThrownBy(service::overview).isSameAs(failure);
        verifyNoInteractions(auditService);
    }

    @Test
    void springAuthenticationFailureIsNotDegraded() {
        configurePurchaseDepartment(Set.of("purchase_request:view"));
        AuthenticationCredentialsNotFoundException failure =
                new AuthenticationCredentialsNotFoundException("missing");
        when(fulfillmentWorkbench.query("PURCHASE", "", "", "", null, null, 1, 1))
                .thenThrow(failure);

        assertThatThrownBy(service::overview).isSameAs(failure);
        verifyNoInteractions(auditService);
    }

    @Test
    void auditWriteFailureDoesNotUndoFulfillmentPartitionDegradation() {
        configurePurchaseDepartment(Set.of("notice:read", "purchase_request:view"));
        when(noticeService.unreadCount()).thenReturn(2L);
        when(noticeService.pendingTodos(8)).thenReturn(List.of());
        when(fulfillmentWorkbench.query("PURCHASE", "", "", "", null, null, 1, 1))
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

    /**
     * 工作台待办的口径是「**权限 ∧ 本部门**」，不是「有权限就展示」。
     *
     * <p>用户 2026-09-12 原话：「不是有权限就展示，就得需要你是这个部门，
     * 只展示这个部门的内容」。此前人事与财务两块只看权限码——生产车间的人
     * 一旦被授予 visitor:approve / expense:approve，工作台上就会冒出人事/财务待办。
     */
    @ParameterizedTest
    @CsvSource({
            // 部门, 权限码, 该权限对应的待办 id
            "DEPT_PROD,visitor:approve,visitor-approval",
            "DEPT_PROD,profile:review,profile-review",
            "DEPT_PROD,expense:approve,expense-approval",
            "DEPT_PROD,expense:pay,expense-payment",
            "DEPT_PROD,payroll:review,payroll-review",
            "SUB_WH,expense:approve,expense-approval",
            "DEPT_FIN,visitor:approve,visitor-approval",
            "DEPT_HR,expense:approve,expense-approval"
    })
    void permissionAloneDoesNotSurfaceAnotherDepartmentsTodo(
            String departmentCode, String permission, String todoId) {
        configureDepartment(departmentCode, Set.of(permission));
        // 没有个人点名加授（override 计数为 0）——这正是「只靠部门/角色权限矩阵
        // 顺带拿到码」的那种人，工作台不该给他别部门的活。
        when(jdbc.queryForObject(
                contains("user_permission_overrides"), eq(Long.class), any(), any()))
                .thenReturn(0L);

        DashboardOverviewDto result = service.overview();

        assertThat(result.todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .as("%s 部门的人持有 %s，也不该在工作台看到 %s",
                        departmentCode, permission, todoId)
                .doesNotContain(todoId);
    }

    /**
     * ADR-027 的跨部门备份路径不能被部门过滤掐断：被 user_permission_overrides
     * **个人点名加授**的人，即便不在财务部门，工作台也必须照常给他这条待办。
     * 否则备份审批人会在自己的工作台上看不到活，而这条兜底路径是刻意设计的。
     */
    @Test
    void individuallyNamedApproverStillSeesTodoOutsideTheDepartment() {
        configureDepartment("DEPT_PROD", Set.of("expense:approve"));
        when(jdbc.queryForObject(anyString(), eq(Long.class))).thenReturn(4L);
        when(jdbc.queryForObject(
                contains("user_permission_overrides"), eq(Long.class), any(), any()))
                .thenReturn(1L);

        assertThat(service.overview().todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .as("被点名加授的备份审批人不该被部门过滤挡掉")
                .contains("expense-approval");
    }

    /** 反向：在本部门 + 有权限时照常出现（不能为了收窄把正主也挡掉）。 */
    @Test
    void ownDepartmentWithPermissionStillSeesItsTodo() {
        // addCountTodo 对 count<=0 早退，正向用例必须喂非零计数。
        when(visitorApprovalService.pendingCount()).thenReturn(2L);
        when(jdbc.queryForObject(anyString(), eq(Long.class))).thenReturn(3L);
        when(jdbc.queryForObject(
                contains("user_permission_overrides"), eq(Long.class), any(), any()))
                .thenReturn(0L); // 靠部门进来，不靠点名

        configureDepartment("DEPT_HR", Set.of("visitor:approve"));
        assertThat(service.overview().todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .contains("visitor-approval");

        configureDepartment("DEPT_FIN", Set.of("expense:approve"));
        assertThat(service.overview().todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .contains("expense-approval");
    }

    /** 超管旁路：与生产/履约/销售三块同口径，不因新增部门门控而丢失全局视角。 */
    @Test
    void superAdminKeepsCrossDepartmentVisibility() {
        when(user.isSuperAdmin()).thenReturn(true);
        when(visitorApprovalService.pendingCount()).thenReturn(2L);
        when(jdbc.queryForObject(anyString(), eq(Long.class))).thenReturn(3L);
        configureDepartment("DEPT_PROD", Set.of("visitor:approve", "expense:approve"));

        assertThat(service.overview().todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .contains("visitor-approval", "expense-approval");
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
        when(jdbc.queryForObject(anyString(), eq(Long.class))).thenReturn(3L);
        when(jdbc.queryForObject(
                contains("user_permission_overrides"), eq(Long.class), any(), any()))
                .thenReturn(0L); // 不靠点名，纯靠兼职部门进来
        when(jdbc.queryForList(anyString(), eq(employeeId))).thenReturn(List.of(
                Map.of("code", "DEPT_PROD", "name", "生产部", "depth", 0),
                Map.of("code", "DEPT_FIN", "name", "财税部", "depth", 1)));

        DashboardOverviewDto result = service.overview();

        assertThat(result.todos())
                .extracting(DashboardOverviewDto.TodoCard::id)
                .as("兼职财务的人应照常看到财务待办")
                .contains("expense-approval");
        // 面板上显示的「本部门」仍是主部门，不因兼职改写身份表述。
        assertThat(result.departmentName()).isEqualTo("生产部");
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
