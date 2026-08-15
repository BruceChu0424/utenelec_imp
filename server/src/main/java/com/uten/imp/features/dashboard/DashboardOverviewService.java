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

import java.math.BigDecimal;
import java.math.RoundingMode;
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
        addPeopleCards(user, todos);
        addFinanceCards(user, metrics, todos);
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
                fulfillmentWorkbench.query(department, "", "", "", 1, 1).summary();
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

    private void addPeopleCards(AuthUser user, List<TodoCard> todos) {
        if (can(user, "visitor:approve")) {
            long count = visitorApprovalService.pendingCount();
            addCountTodo(todos, "visitor-approval", count,
                    "访客申请待审批", "/visitor-approval", "PEOPLE");
        }
        if (can(user, "profile:review")) {
            long count = profileChangeReviewService.pendingCount();
            addCountTodo(todos, "profile-review", count,
                    "员工资料变更待审核", "/hr/profile-changes", "PEOPLE");
        }
    }

    private void addFinanceCards(
            AuthUser user, List<MetricCard> metrics, List<TodoCard> todos) {
        boolean canSeeSensitive =
                can(user, "dashboard:finance-sensitive:view");
        if (canSeeSensitive && can(user, "account:view")) {
            BigDecimal balance = decimal("""
                    SELECT COALESCE(SUM(a.balance_current), 0)
                    FROM accounts a
                    LEFT JOIN currencies c ON c.id = a.currency_id
                    WHERE a.is_deleted = false
                      AND (
                        a.currency_id IS NULL
                        OR c.name = '人民币'
                        OR UPPER(COALESCE(c.code, '')) IN ('CNY', 'RMB', '01')
                      )
                    """);
            metrics.add(new MetricCard(
                    "cash-balance",
                    "人民币账户余额",
                    money(balance),
                    "仅统计人民币账户",
                    balance.signum() < 0 ? "danger" : "success",
                    "/basicinfo/account",
                    true));
        }
        if (canSeeSensitive && can(user, "ar_ap_ledger:view")) {
            Map<String, BigDecimal> arAp = jdbc.query("""
                    SELECT direction, COALESCE(SUM(amount_balance), 0) AS amount
                    FROM ar_ap_ledger
                    WHERE is_deleted = false AND status = 1 AND is_settled = false
                    GROUP BY direction
                    """, rs -> {
                java.util.HashMap<String, BigDecimal> result = new java.util.HashMap<>();
                while (rs.next()) {
                    result.put(rs.getString("direction"), rs.getBigDecimal("amount"));
                }
                return result;
            });
            metrics.add(new MetricCard(
                    "ar-balance", "未结应收", money(arAp.getOrDefault("AR", BigDecimal.ZERO)),
                    "已生效且尚未结清", "info", "/finance/ar-ap", true));
            metrics.add(new MetricCard(
                    "ap-balance", "未结应付", money(arAp.getOrDefault("AP", BigDecimal.ZERO)),
                    "已生效且尚未结清", "warning", "/finance/ar-ap", true));
        }
        if (can(user, "expense:approve")) {
            long count = count("""
                    SELECT COUNT(*) FROM expense_claims
                    WHERE status IN ('SUBMITTED', 'REVIEWING')
                    """);
            addCountTodo(todos, "expense-approval", count,
                    "报销申请待审批", "/expense/approval", "FINANCE");
        }
        if (can(user, "expense:pay")) {
            long count = count("""
                    SELECT COUNT(*) FROM expense_claims WHERE status = 'APPROVED'
                    """);
            addCountTodo(todos, "expense-payment", count,
                    "已审批报销待付款", "/expense/approval", "FINANCE");
        }
        if (can(user, "payroll:review")) {
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
                WITH RECURSIVE ancestors AS (
                    SELECT d.id, d.parent_id, d.code, d.name, 0 AS depth
                    FROM employees e
                    JOIN departments d ON d.id = e.department_id
                    WHERE e.id = ?
                    UNION ALL
                    SELECT parent.id, parent.parent_id, parent.code, parent.name, a.depth + 1
                    FROM departments parent
                    JOIN ancestors a ON a.parent_id = parent.id
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

    private BigDecimal decimal(String sql) {
        BigDecimal result = jdbc.queryForObject(sql, BigDecimal.class);
        return result == null ? BigDecimal.ZERO : result;
    }

    private static String money(BigDecimal value) {
        BigDecimal normalized = value.setScale(2, RoundingMode.HALF_UP);
        return "¥" + String.format(Locale.ROOT, "%,.2f", normalized);
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
