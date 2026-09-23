package com.uten.imp.features.dashboard;

import com.uten.imp.application.port.SalesDocumentReadScopePort;
import com.uten.imp.application.port.WorkbenchBadgeReadPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.dashboard.DashboardOverviewDto.MetricCard;
import com.uten.imp.features.dashboard.DashboardOverviewDto.PolicyBrief;
import com.uten.imp.features.dashboard.DashboardOverviewDto.TodoCard;
import com.uten.imp.features.dashboard.policy.PolicyAudiences;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.notice.dto.NoticeDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
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
 * 工作台「今日概览」聚合服务：通知/生产/销售指标 + 本部门待办，叠加官方政策简报
 * (按受众可见性过滤)。
 *
 * <p><b>范围口径（2026-09-12 统一）</b>：每个分区都是「**权限 ∧ 本部门**」——
 * 权限决定「能不能看这类东西」，部门决定「该不该在你的工作台上出现」。
 * 部门取当前用户主部门、**兼职部门**及各自全部祖先（递归 CTE，见
 * {@link #departmentContext}，与通知侧 ReviewNoticeAudience 的 memberships 同口径），
 * 超管与个人加授均不绕过部门展示条件。通知分区例外：它本来就是「发给本人的未读」，
 * 天然按人收敛，不需要也不应该再按部门筛。
 *
 * <p><b>本部门待办只有一套口径(permissions-08, ADR-108)</b>：待办卡片的数字 = 对应入口的
 * 红徽章数，经 {@link WorkbenchBadgeReadPort} 按当前主体只算本部门要的几个入口——同一张入口
 * 目录、同一批来源、同一资格判定(各来源原计数端点的 {@code @PreAuthorize})。此前概览按
 * 「部门 + 权限码」另写一套计数(报销 SQL 与报销模块逐字重复、履约另跑一次分页查询)，
 * 与红徽章是两套规则、两个数。来源出错由徽章服务按保存点隔离：该入口本次不出卡，其它照常。
 * 工资批次待复核不再单列计数卡：提交时已给复核人推「待复核」行动通知，在通知待办里出现。
 */
@Service
@RequiredArgsConstructor
public class DashboardOverviewService {

    private static final int POLICY_LIMIT = 6;
    private static final int NOTICE_TODO_LIMIT = 8;

    /** 生产调度入口: 既出「待排产产品」指标, 也出待办卡(带逾期细分)。 */
    private static final String PRODUCTION_SCHEDULE = "productionSchedule";

    /**
     * 本部门待办卡 ← 徽章入口。{@code countFact} 为空 = 取入口红数; 否则取该事实数
     * (财务报销入口按「待审批 / 待付款」拆成两张卡, 两张之和即该入口红数)。
     */
    private record DepartmentTodo(
            String scope,
            String entry,
            String countFact,
            String id,
            String titleSuffix,
            String route,
            String sourceType) {
    }

    private static final List<DepartmentTodo> DEPARTMENT_TODOS = List.of(
            new DepartmentTodo("WAREHOUSE", "warehouseDrawCenter", null,
                    "fulfillment-warehouse", "仓库领料与退料任务待处理", "/warehouse/tasks/draw", "FULFILLMENT"),
            new DepartmentTodo("PURCHASE", "purchaseTaskCenter", null,
                    "fulfillment-purchase", "采购任务待处理", "/operations/workbench/purchase", "FULFILLMENT"),
            new DepartmentTodo("SUBCONTRACT", "subcontractTaskCenter", null,
                    "fulfillment-subcontract", "委外任务待处理", "/operations/workbench/subcontract", "FULFILLMENT"),
            new DepartmentTodo("HR", "visitorApproval", null,
                    "visitor-approval", "访客申请待审批", "/visitor-approval", "PEOPLE"),
            new DepartmentTodo("HR", "hrProfileReview", null,
                    "profile-review", "员工资料变更待审核", "/hr/profile-changes", "PEOPLE"),
            new DepartmentTodo("FINANCE", "expenseFinance", "expense.pendingApprovalCount",
                    "expense-approval", "报销申请待审批", "/expense/approval", "FINANCE"),
            new DepartmentTodo("FINANCE", "expenseFinance", "expense.pendingPaymentCount",
                    "expense-payment", "已审批报销待付款", "/expense/approval", "FINANCE"));

    private final SecurityContextCurrentUser currentUser;
    private final JdbcTemplate jdbc;
    private final NoticeService noticeService;
    private final SalesDocumentReadScopePort salesAccess;
    private final WorkbenchBadgeReadPort badges;

    // Deliberately no encompassing transaction: each workbench query owns its
    // read transaction, so one failed partition cannot poison the aggregate.
    public DashboardOverviewDto overview() {
        AuthUser user = currentUser.get()
                .filter(candidate -> !candidate.isVisitor())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        DepartmentContext department = departmentContext(user.getEmployeeId());
        WorkbenchBadgeReadPort.Entries departmentBadges = departmentBadges(department);
        List<MetricCard> metrics = new ArrayList<>();
        List<TodoCard> todos = new ArrayList<>();

        addNoticeCards(user, metrics, todos);
        addProductionCards(departmentBadges, metrics, todos);
        addDepartmentTodos(departmentBadges, todos);
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

    /** 本部门要的徽章入口, 一次只读事务算完(无本部门入口时不查)。 */
    private WorkbenchBadgeReadPort.Entries departmentBadges(DepartmentContext department) {
        Set<String> entries = new LinkedHashSet<>();
        if (belongsTo(department, "PRODUCTION")) entries.add(PRODUCTION_SCHEDULE);
        for (DepartmentTodo todo : DEPARTMENT_TODOS) {
            if (belongsTo(department, todo.scope())) entries.add(todo.entry());
        }
        return entries.isEmpty() ? WorkbenchBadgeReadPort.Entries.NONE : badges.entries(entries);
    }

    /** 入口对当前主体可见且本次算出来了(没权 / 来源出错都不出卡, 徽章侧保留上一次的数)。 */
    private static boolean usable(WorkbenchBadgeReadPort.Entries badges, String entry) {
        return badges.todo().containsKey(entry) && !badges.staleEntries().contains(entry);
    }

    private void addProductionCards(
            WorkbenchBadgeReadPort.Entries badges,
            List<MetricCard> metrics,
            List<TodoCard> todos) {
        if (!usable(badges, PRODUCTION_SCHEDULE)) return;
        long count = badges.todo().get(PRODUCTION_SCHEDULE);
        long overdue = badges.fact("productionSchedule.overdue");
        long urgent = badges.fact("productionSchedule.urgent");
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

    private void addDepartmentTodos(
            WorkbenchBadgeReadPort.Entries badges, List<TodoCard> todos) {
        for (DepartmentTodo todo : DEPARTMENT_TODOS) {
            if (!usable(badges, todo.entry())) continue;
            long count = todo.countFact() == null
                    ? badges.todo().get(todo.entry())
                    : badges.fact(todo.countFact());
            addCountTodo(todos, todo.id(), count, todo.titleSuffix(), todo.route(), todo.sourceType());
        }
    }

    private void addSalesCards(
            AuthUser user, DepartmentContext department, List<MetricCard> metrics) {
        if (!can(user, "sales_order:view")
                || !belongsTo(department, "SALES")) return;
        var scope = salesAccess.nativeReadScope("o.owner_employee_id", "dashboardOwners");
        String predicate = scope.predicate();
        if (!scope.owners().isEmpty()) {
            predicate = predicate.replace(":" + scope.parameterName(),
                    String.join(",", java.util.Collections.nCopies(scope.owners().size(), "?")));
        }
        Long result = jdbc.queryForObject("""
                SELECT COUNT(*) FROM sales_orders o
                WHERE o.is_deleted = false AND o.status = 1
                  AND o.is_closed = false AND o.is_stopped = false AND
                """ + predicate, Long.class, scope.owners().toArray());
        long active = result == null ? 0 : result;
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
        if (can(user, "dashboard:finance_sensitive:view")) {
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
                "与模块卡红色角标同一口径，点击进入对应页面统一处理",
                count,
                0,
                "warning",
                route,
                sourceType,
                null,
                null,
                false));
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

    private static boolean belongsTo(DepartmentContext department, String audienceTag) {
        return department.audienceTags().contains(audienceTag);
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
