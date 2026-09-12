package com.uten.imp.features.dashboard;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.dashboard.DashboardOverviewDto.MetricCard;
import com.uten.imp.features.dashboard.DashboardOverviewDto.PolicyBrief;
import com.uten.imp.features.dashboard.DashboardOverviewDto.TodoCard;
import com.uten.imp.features.dashboard.policy.PolicyAudiences;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.notice.dto.NoticeDto;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchPage;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.profilechange.ProfileChangeReviewService;
import com.uten.imp.features.visitor.VisitorHrApprovalService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.AuthenticationException;
import org.springframework.stereotype.Service;

import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 生产看板聚合服务：按权限与部门合并通知/生产/履约/人资/财务/销售指标 + 待办，
 * 叠加官方政策简报（按受众可见性过滤）。
 *
 * <p><b>范围口径（2026-09-12 统一）</b>：每个分区都是「**权限 ∧ 本部门**」——
 * 权限决定「能不能看这类东西」，部门决定「该不该在你的工作台上出现」。
 * 部门取当前用户主部门、**兼职部门**及各自全部祖先（递归 CTE，见
 * {@link #departmentContext}，与通知侧 ReviewNoticeAudience 的 memberships 同口径），
 * 超管旁路。此前人事与财务两块漏了部门这一半，任何被授予相应权限码的人
 * 都会看到别部门的待办（用户 2026-09-12 反馈）。通知分区例外：它本来就是
 * 「发给本人的未读」，天然按人收敛，不需要也不应该再按部门筛。
 *
 * <p>每个分区查询各自持有读事务，单点失败仅降级该分区（{@link #addFulfillmentTodoSafely}），
 * 不污染整体看板。
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class DashboardOverviewService {

    private static final int POLICY_LIMIT = 6;
    private static final int NOTICE_TODO_LIMIT = 8;

    private final SecurityContextCurrentUser currentUser;
    private final JdbcTemplate jdbc;
    private final ProductionScheduleService productionScheduleService;
    private final FulfillmentWorkbenchQueryService fulfillmentWorkbench;
    private final VisitorHrApprovalService visitorApprovalService;
    private final ProfileChangeReviewService profileChangeReviewService;
    private final NoticeService noticeService;
    private final AuditService auditService;

    // Deliberately no encompassing transaction: each workbench query owns its
    // read transaction, so one failed partition cannot poison the aggregate.
    public DashboardOverviewDto overview() {
        AuthUser user = currentUser.get()
                .filter(candidate -> !candidate.isVisitor())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        DepartmentContext department = departmentContext(user.getEmployeeId());
        List<MetricCard> metrics = new ArrayList<>();
        List<TodoCard> todos = new ArrayList<>();

        addNoticeCards(user, metrics, todos);
        addProductionCards(user, department, metrics, todos);
        addFulfillmentCards(user, department, todos);
        addPeopleCards(user, department, todos);
        addFinanceTodos(user, department, todos);
        addSalesCards(user, department, metrics);

        return new DashboardOverviewDto(
                department.code(),
                department.name(),
                Instant.now(),
                List.copyOf(metrics),
                List.copyOf(todos),
                policyBriefs(user, department));
    }

    private void addNoticeCards(
            AuthUser user, List<MetricCard> metrics, List<TodoCard> todos) {
        if (!can(user, "notice:read")) return;
        long unread = noticeService.unreadCount();
        metrics.add(new MetricCard(
                "notice-unread",
                "未读通知",
                Long.toString(unread),
                unread == 0 ? "今天没有未读消息" : "请及时查看新消息",
                unread == 0 ? "neutral" : "info",
                "/notice",
                false));
        for (NoticeDto notice : noticeService.pendingTodos(NOTICE_TODO_LIMIT)) {
            todos.add(new TodoCard(
                    "notice-" + notice.id(),
                    notice.title(),
                    compactText(notice.content(), 90),
                    1,
                    "urgent".equals(notice.priority()) ? 1 : 0,
                    "urgent".equals(notice.priority()) ? "danger" : "info",
                    "/notice/" + notice.id(),
                    "NOTICE",
                    notice.id(),
                    notice.dueAt(),
                    true));
        }
    }

    private void addProductionCards(
            AuthUser user,
            DepartmentContext department,
            List<MetricCard> metrics,
            List<TodoCard> todos) {
        if (!can(user, "production_plan:view")
                || !belongsTo(user, department, "PRODUCTION")) return;
        Map<String, Long> counts = productionScheduleService.pendingCount();
        long count = counts.getOrDefault("count", 0L);
        long overdue = counts.getOrDefault("overdue", 0L);
        long urgent = counts.getOrDefault("urgent", 0L);
        metrics.add(new MetricCard(
                "production-pending",
                "待排产产品",
                Long.toString(count),
                overdue > 0 ? overdue + " 个已逾期" : "按销售订单需求实时汇总",
                overdue > 0 ? "danger" : "success",
                "/production/schedule",
                false));
        if (count > 0) {
            todos.add(new TodoCard(
                    "production-pending",
                    "你有 " + count + " 个产品待生产",
                    overdue > 0
                            ? "其中 " + overdue + " 个已逾期，请优先安排"
                            : "已合并同类生产需求，进入排产工作台统一处理",
                    count,
                    Math.max(overdue, urgent),
                    overdue > 0 ? "danger" : "warning",
                    "/production/schedule",
                    "PRODUCTION",
                    null,
                    null,
                    false));
        }
    }

    private void addFulfillmentCards(
            AuthUser user, DepartmentContext department, List<TodoCard> todos) {
        if (can(user, "stock_doc:view")
                && belongsTo(user, department, "WAREHOUSE")) {
            addFulfillmentTodoSafely(user, todos, "WAREHOUSE", "warehouse",
                    "项仓库备料任务待处理", "/operations/workbench/warehouse");
        }
        if (canAny(user, "purchase_request:view", "purchase_order:view")
                && belongsTo(user, department, "PURCHASE")) {
            addFulfillmentTodoSafely(user, todos, "PURCHASE", "purchase",
                    "项采购任务待处理", "/operations/workbench/purchase");
        }
        if (hasPermissionPrefix(user, "subcontract_")
                && belongsTo(user, department, "SUBCONTRACT")) {
            addFulfillmentTodoSafely(user, todos, "SUBCONTRACT", "subcontract",
                    "项委外任务待处理", "/operations/workbench/subcontract");
        }
    }

    private void addFulfillmentTodoSafely(
            AuthUser user,
            List<TodoCard> todos,
            String department,
            String id,
            String titleSuffix,
            String route) {
        try {
            addFulfillmentTodo(todos, department, id, titleSuffix, route);
        } catch (RuntimeException failure) {
            if (isAuthenticationOrAuthorizationFailure(failure)) {
                throw failure;
            }
            recordFulfillmentPartitionDegradation(user, department, failure);
            todos.add(unavailableFulfillmentTodo(department, id, route));
        }
    }

    private void recordFulfillmentPartitionDegradation(
            AuthUser user, String department, RuntimeException failure) {
        String result = failureCode(failure);
        log.warn(
                "Dashboard fulfillment partition degraded: department={}, result={}",
                department,
                result,
                failure);
        try {
            auditService.logExplicit(
                    user.getId(),
                    user.getLoginAccount(),
                    "dashboard_fulfillment_partition_degraded",
                    "fulfillment_workbench",
                    department,
                    result);
        } catch (RuntimeException auditFailure) {
            log.error(
                    "Dashboard fulfillment degradation audit failed: department={}, result={}",
                    department,
                    result,
                    auditFailure);
        }
    }

    private static boolean isAuthenticationOrAuthorizationFailure(
            RuntimeException failure) {
        if (failure instanceof AuthenticationException
                || failure instanceof AccessDeniedException) {
            return true;
        }
        return failure instanceof ApiException apiFailure
                && (apiFailure.getCode().getHttpStatus() == 401
                        || apiFailure.getCode().getHttpStatus() == 403);
    }

    private static String failureCode(RuntimeException failure) {
        if (failure instanceof ApiException apiFailure) {
            return apiFailure.getCode().name().toLowerCase(Locale.ROOT);
        }
        String simpleName = failure.getClass().getSimpleName();
        return simpleName.isBlank()
                ? "runtime_exception"
                : simpleName.toLowerCase(Locale.ROOT);
    }

    private static TodoCard unavailableFulfillmentTodo(
            String department, String id, String route) {
        String departmentName = switch (department) {
            case "WAREHOUSE" -> "仓库";
            case "PURCHASE" -> "采购";
            case "SUBCONTRACT" -> "委外";
            default -> "履约";
        };
        return new TodoCard(
                "fulfillment-" + id + "-unavailable",
                departmentName + "任务正在自动恢复",
                "其它功能可继续使用，无需退出或反复刷新",
                0,
                0,
                "warning",
                route,
                "FULFILLMENT_UNAVAILABLE",
                null,
                null,
                false);
    }

    private void addFulfillmentTodo(
            List<TodoCard> todos,
            String department,
            String id,
            String titleSuffix,
            String route) {
        FulfillmentWorkbenchPage.Summary summary =
                fulfillmentWorkbench.query(department, "", "", "", null, null, 1, 1).summary();
        if (summary.openTasks() == 0) return;
        todos.add(new TodoCard(
                "fulfillment-" + id,
                "你有 " + summary.openTasks() + titleSuffix,
                summary.overdueTasks() > 0
                        ? "其中 " + summary.overdueTasks() + " 项已逾期"
                        : "已按部门合并展示，点击进入统一处理",
                summary.openTasks(),
                summary.overdueTasks(),
                summary.overdueTasks() > 0 ? "danger" : "warning",
                route,
                "FULFILLMENT",
                null,
                null,
                false));
    }

    /**
     * 人事待办：**权限 + 本部门**（2026-09-12）。
     *
     * <p>此前只看权限码，于是任何被授予 {@code visitor:approve} / {@code profile:review}
     * 的人——哪怕在生产车间——都会在自己的工作台上看到人事待办。用户原话：
     * 「不是有权限就展示，就得需要你是这个部门，只展示这个部门的内容」。
     * 现在走 {@link #belongsToOrNamed}：**在本部门树内，或被个人点名加授**。
     * 后半段是 ADR-027 明确设计的跨部门备份路径，不能被部门过滤掐断。
     *
     * <p>注意：权限仍然是必要条件，部门只是**再收一道**。没权限的人本来就看不到，
     * 加部门不会放宽任何东西，只会收窄。
     */
    private void addPeopleCards(
            AuthUser user, DepartmentContext department, List<TodoCard> todos) {
        if (can(user, "visitor:approve")
                && belongsToOrNamed(user, department, "HR", "visitor:approve")) {
            long count = visitorApprovalService.pendingCount();
            addCountTodo(todos, "visitor-approval", count,
                    "访客申请待审批", "/visitor-approval", "PEOPLE");
        }
        if (can(user, "profile:review")
                && belongsToOrNamed(user, department, "HR", "profile:review")) {
            long count = profileChangeReviewService.pendingCount();
            addCountTodo(todos, "profile-review", count,
                    "员工资料变更待审核", "/hr/profile-changes", "PEOPLE");
        }
    }

    /**
     * 财务待办：**权限 + 本部门**（2026-09-12，同 {@link #addPeopleCards} 的理由）。
     *
     * <p>报销审批/付款/工资复核此前只看权限码，销售或生产口的人一旦被授予这些码，
     * 工作台上就会冒出财务待办。现在收敛到「财务部门 或 被点名加授」——
     * 与 ADR-027 的审批资格口径一致，不会把跨部门的备份审批人挡在门外。
     */
    private void addFinanceTodos(
            AuthUser user, DepartmentContext department, List<TodoCard> todos) {
        if (can(user, "expense:approve")
                && belongsToOrNamed(user, department, "FINANCE", "expense:approve")) {
            long count = count("""
                    SELECT COUNT(*) FROM expense_claims
                    WHERE status IN ('SUBMITTED', 'REVIEWING')
                    """);
            addCountTodo(todos, "expense-approval", count,
                    "报销申请待审批", "/expense/approval", "FINANCE");
        }
        if (can(user, "expense:pay")
                && belongsToOrNamed(user, department, "FINANCE", "expense:pay")) {
            long count = count("""
                    SELECT COUNT(*) FROM expense_claims WHERE status = 'APPROVED'
                    """);
            addCountTodo(todos, "expense-payment", count,
                    "已审批报销待付款", "/expense/approval", "FINANCE");
        }
        if (can(user, "payroll:review")
                && belongsToOrNamed(user, department, "FINANCE", "payroll:review")) {
            long count = count("""
                    SELECT COUNT(*) FROM payroll_batches WHERE status = 'SUBMITTED'
                    """);
            addCountTodo(todos, "payroll-review", count,
                    "工资批次待复核", "/payroll/review", "FINANCE");
        }
    }

    private void addSalesCards(
            AuthUser user, DepartmentContext department, List<MetricCard> metrics) {
        if (!can(user, "sales_order:view")
                || !belongsTo(user, department, "SALES")) return;
        long active = count("""
                SELECT COUNT(*) FROM sales_orders
                WHERE is_deleted = false AND status = 1
                  AND is_closed = false AND is_stopped = false
                """);
        metrics.add(new MetricCard(
                "sales-active",
                "执行中订单",
                Long.toString(active),
                "已审核且尚未结案",
                "info",
                "/sales/orders",
                false));
    }

    private List<PolicyBrief> policyBriefs(
            AuthUser user, DepartmentContext department) {
        // 可见性由分类权威映射决定（PolicyAudiences），不信任库存 audience_tags：
        // 财税类（TAX/SUBSIDY/EXPORT）= 财税部（FINANCE）+ 总经办直属（GM）；
        // 检查类（INSPECTION/SAFETY/QUALITY）与其他 = 仅总经办直属（GM）。
        // GM 标签只来自直属部门（depth=0），总经办下级部门员工不会继承。
        Set<String> audienceTags = new LinkedHashSet<>(department.audienceTags());
        if (can(user, "dashboard:finance-sensitive:view")) {
            audienceTags.add(PolicyAudiences.FINANCE);
        }

        return jdbc.query("""
                SELECT id, title, summary, category,
                       source_name, source_url, published_on, captured_at
                FROM official_policy_briefs
                WHERE status = 'ACTIVE'
                  AND (valid_until IS NULL OR valid_until >= CURRENT_DATE)
                  AND source_host IN (
                    'www.zs.gov.cn', 'guangdong.chinatax.gov.cn',
                    'www.mof.gov.cn', 'www.gov.cn')
                ORDER BY published_on DESC, captured_at DESC
                LIMIT 30
                """, (rs, rowNum) -> new PolicyRow(
                rs.getObject("id", UUID.class),
                rs.getString("title"),
                rs.getString("summary"),
                rs.getString("category"),
                rs.getString("source_name"),
                rs.getString("source_url"),
                rs.getObject("published_on", LocalDate.class),
                rs.getTimestamp("captured_at")))
                .stream()
                .filter(row -> user.isSuperAdmin()
                        || PolicyAudiences.forCategory(row.category()).stream()
                                .anyMatch(audienceTags::contains))
                .limit(POLICY_LIMIT)
                .map(PolicyRow::toDto)
                .toList();
    }

    private DepartmentContext departmentContext(UUID employeeId) {
        if (employeeId == null) {
            return new DepartmentContext("UNKNOWN", "未分配部门", Set.of());
        }
        List<Map<String, Object>> rows = jdbc.queryForList("""
                WITH RECURSIVE me(id, department_id) AS (
                    SELECT e.id, e.department_id
                    FROM employees e
                    WHERE e.id = ?
                ), ancestors(id, parent_id, code, name, depth) AS (
                    SELECT d.id, d.parent_id, d.code, d.name, 0
                    FROM departments d
                    JOIN me ON me.department_id = d.id
                    WHERE d.is_deleted = FALSE
                    UNION ALL
                    -- 兼职部门也是「本人的部门」（depth=1，同通知的 memberships 口径）：
                    -- 通知侧给兼职财务的人推财务待办，工作台却不给，就是两边口径打架。
                    SELECT d.id, d.parent_id, d.code, d.name, 1
                    FROM departments d
                    JOIN employee_secondary_departments s ON s.department_id = d.id
                    JOIN me ON me.id = s.employee_id
                    WHERE d.is_deleted = FALSE
                    UNION ALL
                    SELECT parent.id, parent.parent_id, parent.code, parent.name, a.depth + 1
                    FROM departments parent
                    JOIN ancestors a ON a.parent_id = parent.id
                    WHERE parent.is_deleted = FALSE
                )
                SELECT code, name, depth FROM ancestors ORDER BY depth
                """, employeeId);
        if (rows.isEmpty()) {
            return new DepartmentContext("UNKNOWN", "未分配部门", Set.of());
        }
        Set<String> tags = new LinkedHashSet<>();
        for (Map<String, Object> row : rows) {
            Set<String> rowTags =
                    new LinkedHashSet<>(tagsForCode(String.valueOf(row.get("code"))));
            if (((Number) row.get("depth")).intValue() > 0) {
                // GM 是全公司的共同祖先，不能把总经办监管情报下发给所有部门。
                rowTags.remove("GM");
            }
            tags.addAll(rowTags);
        }
        return new DepartmentContext(
                String.valueOf(rows.getFirst().get("code")),
                String.valueOf(rows.getFirst().get("name")),
                Set.copyOf(tags));
    }

    private static Set<String> tagsForCode(String rawCode) {
        String code = rawCode.toUpperCase(Locale.ROOT);
        Set<String> tags = new LinkedHashSet<>();
        if (code.equals("GM") || code.contains("GENERAL") || code.contains("CEO")) tags.add("GM");
        if (code.equals("DEPT_FIN")) tags.add("FINANCE");
        if (code.contains("SALES") || code.equals("DEPT_RAIL")
                || code.startsWith("SALE_") || code.startsWith("RAIL_")) {
            tags.add("SALES");
        }
        if (code.contains("PROD")) tags.add("PRODUCTION");
        if (code.contains("PMC")) tags.add("PMC");
        if (code.contains("QA") || code.contains("QUALITY")) tags.add("QA");
        if (code.equals("SUB_PURCHASE")) tags.add("PURCHASE");
        if (code.equals("SUB_WH")) tags.add("WAREHOUSE");
        if (code.equals("QA_OUT") || code.equals("DEPT_SALES")) {
            tags.add("SUBCONTRACT");
        }
        if (code.contains("HR")) tags.add("HR");
        if (code.contains("SECURITY")) tags.add("SECURITY");
        return tags;
    }

    private void addCountTodo(
            List<TodoCard> todos,
            String id,
            long count,
            String titleSuffix,
            String route,
            String sourceType) {
        if (count <= 0) return;
        todos.add(new TodoCard(
                id,
                "你有 " + count + " 项" + titleSuffix,
                "已合并展示，点击进入对应页面统一处理",
                count,
                0,
                "warning",
                route,
                sourceType,
                null,
                null,
                false));
    }

    private long count(String sql) {
        Long result = jdbc.queryForObject(sql, Long.class);
        return result == null ? 0 : result;
    }

    private static String compactText(String value, int maxLength) {
        if (value == null) return "";
        String compact = value.replaceAll("\\s+", " ").strip();
        return compact.length() <= maxLength
                ? compact
                : compact.substring(0, maxLength) + "…";
    }

    private static boolean can(AuthUser user, String permission) {
        return user.isSuperAdmin() || user.getPermissions().contains(permission);
    }

    private static boolean canAny(AuthUser user, String... permissions) {
        if (user.isSuperAdmin()) return true;
        for (String permission : permissions) {
            if (user.getPermissions().contains(permission)) return true;
        }
        return false;
    }

    private static boolean hasPermissionPrefix(AuthUser user, String prefix) {
        return user.isSuperAdmin()
                || user.getPermissions().stream().anyMatch(p -> p.startsWith(prefix));
    }

    private static boolean belongsTo(
            AuthUser user, DepartmentContext department, String audienceTag) {
        return user.isSuperAdmin() || department.audienceTags().contains(audienceTag);
    }

    /**
     * 部门归属判定的**正确形态**：在本部门树内，<b>或</b>被个人点名加授该权限。
     *
     * <p>后半段不能省。ADR-027 把财务审批设计成「财务部门树 <b>OR</b> 跨部门个人点名加授
     * （不限部门）」的混合队列（实现见
     * {@code WorkflowReviewerEligibility}：递归部门子树 ∪ 兼职部门 ∪
     * {@code user_permission_overrides}）。若工作台只按部门一刀切，被点名的**备份审批人**
     * 会在自己的工作台上看不到该待办——把一条刻意设计的兜底路径悄悄掐断。
     *
     * <p>这也正好对上用户 2026-09-12 的诉求：他要挡的是「部门/角色权限矩阵顺带给了我
     * 这个码，于是别部门的活也堆到我这」，不是「有人专门点名让我办」。
     *
     * @param permission 该待办对应的动作权限码；个人加授按这个码查
     */
    private boolean belongsToOrNamed(
            AuthUser user,
            DepartmentContext department,
            String audienceTag,
            String permission) {
        if (belongsTo(user, department, audienceTag)) return true;
        return namedIndividually(user, permission);
    }

    /** 是否被 {@code user_permission_overrides} 个人点名加授（ALLOW 且生效）。 */
    private boolean namedIndividually(AuthUser user, String permission) {
        if (user.getId() == null) return false;
        try {
            Long hit = jdbc.queryForObject("""
                    SELECT count(*)
                    FROM user_permission_overrides override
                    JOIN permissions permission ON permission.id = override.permission_id
                    WHERE override.user_id = ? AND override.active = TRUE
                      AND override.effect = 'ALLOW'
                      AND permission.code = ? AND permission.active = TRUE
                    """, Long.class, user.getId(), permission);
            return hit != null && hit > 0;
        } catch (RuntimeException unavailable) {
            // 查不动时**放行**：宁可多显示一条自己有权限办的待办，
            // 也不要因为一次查询抖动让备份审批人漏掉活。
            log.warn("个人加授判定失败，按放行处理: permission={}, error={}",
                    permission, unavailable.toString());
            return true;
        }
    }

    private record DepartmentContext(
            String code, String name, Set<String> audienceTags) {
    }

    private record PolicyRow(
            UUID id,
            String title,
            String summary,
            String category,
            String sourceName,
            String sourceUrl,
            LocalDate publishedOn,
            Timestamp capturedAt) {

        PolicyBrief toDto() {
            return new PolicyBrief(
                    id,
                    title,
                    summary,
                    category,
                    sourceName,
                    sourceUrl,
                    publishedOn,
                    capturedAt == null ? null : capturedAt.toInstant());
        }
    }
}
