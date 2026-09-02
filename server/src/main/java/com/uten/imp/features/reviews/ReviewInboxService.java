package com.uten.imp.features.reviews;

import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 我的待审收件台（V459）：跨业务域待审事项的聚合导航页。
 *
 * <p>section 可见性按「部门（主/兼职）× 职责权限码」资格判定（与弹卡定向同口径，
 * 方案 D3）；计数 = 当前用户名下未办结的待审通知数（notices 维度，办结撤回自动
 * 联动）。权威池数据（共享队列、认领状态）在各域任务中心——本页是弹卡之外的
 * 稳定入口，不复制业务 count 口径，避免双份 SQL 漂移。
 */
@Service
public class ReviewInboxService {

    private final JdbcTemplate jdbc;
    private final SecurityContextCurrentUser currentUser;
    private final PermissionResolver permissionResolver;
    private final com.uten.imp.features.auth.model.UserAccountRepository userAccountRepo;
    private final SalesOrderFinanceConfirmerEligibility salesOrderFinanceConfirmer;
    private final WorkflowReviewerEligibility financeReviewer;

    public ReviewInboxService(
            JdbcTemplate jdbc,
            SecurityContextCurrentUser currentUser,
            PermissionResolver permissionResolver,
            com.uten.imp.features.auth.model.UserAccountRepository userAccountRepo,
            SalesOrderFinanceConfirmerEligibility salesOrderFinanceConfirmer,
            WorkflowReviewerEligibility financeReviewer) {
        this.jdbc = jdbc;
        this.currentUser = currentUser;
        this.permissionResolver = permissionResolver;
        this.userAccountRepo = userAccountRepo;
        this.salesOrderFinanceConfirmer = salesOrderFinanceConfirmer;
        this.financeReviewer = financeReviewer;
    }

    /** 有效权限判定（PermissionResolver 合成：主部门∪兼职部门∪覆盖）。 */
    private boolean holdsPermission(UUID userId, String permissionCode) {
        return userAccountRepo.findById(userId)
                .map(permissionResolver::permsOf)
                .map(codes -> codes.contains(permissionCode))
                .orElse(false);
    }

    /** 各域 section 的固定跳转路由（与 ReviewNoticeCatalog 事件一一对应）。 */
    private static final Map<String, String> SECTION_ROUTES = Map.of(
            "ORDER_PENDING_FINANCE_CONFIRMATION", "/finance/sales-order-confirmations",
            "PROCUREMENT_ORDER_APPROVAL_PENDING", "/finance/procurement-approvals",
            "PROCUREMENT_IQC_PENDING_INSPECTION", "/quality/task-center",
            "SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP", "/sales/orders");

    @Transactional(readOnly = true)
    public List<ReviewInboxSectionDto> summary() {
        var user = currentUser.get()
                .orElseThrow(() -> new IllegalStateException("收件台需要登录会话"));
        UUID userId = user.getId();
        UUID employeeId = user.getEmployeeId();
        boolean superAdmin = user.isSuperAdmin();

        // 我的未办结待审通知计数（source_event 分组；已办结/snoozed 到期前不计）。
        Map<String, Long> myPending = new HashMap<>();
        jdbc.query(
                """
                SELECT n.source_event, COUNT(*)
                FROM notices n
                LEFT JOIN notice_user_states s
                  ON s.notice_id = n.id AND s.user_id = ?
                WHERE n.audience_user_id = ?
                  AND n.source_event IN ('SALES_ORDER_PENDING_FINANCE_CONFIRM',
                                         'PROCUREMENT_FINANCE_SUBMITTED',
                                         'PROCUREMENT_IQC_PENDING',
                                         'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP')
                  AND n.resolved_at IS NULL
                  AND (s IS NULL OR (s.deleted_at IS NULL
                       AND (s.snoozed_until IS NULL OR s.snoozed_until <= CURRENT_TIMESTAMP)))
                GROUP BY n.source_event
                """,
                (rs, i) -> {
                    myPending.put(rs.getString(1), rs.getLong(2));
                    return null;
                },
                userId, userId);

        boolean financeConfirmEligible = salesOrderFinanceConfirmer.isEligible(userId);
        boolean financeApproveEligible = employeeId != null
                && financeReviewer.findEligible(userId).isPresent();
        boolean iqcEligible = employeeId != null && !superAdmin
                ? isDepartmentMemberWithAuthority(employeeId, "DEPT_QA",
                        "procurement_inspection:handle", userId)
                : superAdmin;

        List<ReviewInboxSectionDto> sections = new ArrayList<>();
        if (financeConfirmEligible) {
            sections.add(section("ORDER_PENDING_FINANCE_CONFIRMATION",
                    "销售订单待财务确认", userId, myPending));
        }
        if (financeApproveEligible) {
            sections.add(section("PROCUREMENT_ORDER_APPROVAL_PENDING",
                    "采购/委外订货待财务审批", userId, myPending));
        }
        if (iqcEligible) {
            sections.add(section("PROCUREMENT_IQC_PENDING_INSPECTION",
                    "到货 IQC 待检处置", userId, myPending));
        }
        // 归属人线（可发货提醒）：有通知才显示，无资格判定。
        if (myPending.getOrDefault("SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP", 0L) > 0) {
            sections.add(section("SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP",
                    "订单全部完工可发货", userId, myPending));
        }
        return sections;
    }

    private ReviewInboxSectionDto section(
            String event, String title, UUID userId, Map<String, Long> myPending) {
        return new ReviewInboxSectionDto(
                event, title, myPending.getOrDefault(event, 0L),
                SECTION_ROUTES.getOrDefault(event, "/reviews/inbox"));
    }

    /**
     * 「部门（主或兼职 ∈ code 子树）且 持有权限码」——与弹卡定向资格同口径。
     * 权限判定走 PermissionResolver 的有效权限合成（兼职部门链已并入）。
     */
    private boolean isDepartmentMemberWithAuthority(
            UUID employeeId, String departmentCode, String permissionCode, UUID userId) {
        if (!holdsPermission(userId, permissionCode)) {
            return false;
        }
        Integer membership = jdbc.query(
                """
                WITH RECURSIVE subtree AS (
                    SELECT id FROM departments WHERE code = ? AND is_deleted = FALSE
                    UNION ALL
                    SELECT d.id FROM departments d
                    JOIN subtree s ON d.parent_id = s.id
                    WHERE d.is_deleted = FALSE
                )
                SELECT COUNT(*) FROM (
                    SELECT 1 FROM employees e
                    WHERE e.id = ? AND e.deleted = FALSE
                      AND e.department_id IN (SELECT id FROM subtree)
                    UNION ALL
                    SELECT 1 FROM employee_secondary_departments sd
                    WHERE sd.employee_id = ?
                      AND sd.department_id IN (SELECT id FROM subtree)
                ) membership
                """,
                (rs, i) -> rs.getInt(1),
                departmentCode, employeeId, employeeId)
                .stream().findFirst().orElse(0);
        return membership > 0;
    }

    public record ReviewInboxSectionDto(
            String key,
            String title,
            long pendingCount,
            String route) {
    }
}
