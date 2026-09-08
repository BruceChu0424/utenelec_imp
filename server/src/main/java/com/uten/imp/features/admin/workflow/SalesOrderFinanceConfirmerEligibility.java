package com.uten.imp.features.admin.workflow;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * 销售订单财务确认人资格查询（V294；镜像 {@link WorkflowReviewerEligibility} 的 ADR-027 审核组模型）。
 *
 * <p>合格确认人 = 财务部门（DEPT_FIN）子树在职员工（或经 user_permission_overrides 个人加授
 * {@code sales_order_finance:confirm} 的人员）、账号启用，且最终权限集含
 * {@code sales_order_finance:confirm}。权限本身在权限设置中按部门/角色/个人配置，
 * 本类只做「部门树资格 + 权限持有」的叠加判定。
 */
@Service
@RequiredArgsConstructor
public class SalesOrderFinanceConfirmerEligibility
        implements com.uten.imp.application.port.SalesOrderFinanceReviewerEligibilityPort {

    public static final String CONFIRM_PERMISSION = "sales_order_finance:confirm";
    public static final String VIEW_PERMISSION = "sales_order_finance:view";

    private final JdbcTemplate jdbc;
    private final UserAccountRepository userRepo;
    private final PermissionResolver permissionResolver;

    /** 当前用户是否为合格确认人。 */
    @Override
    @Transactional(readOnly = true)
    public boolean isEligible(UUID userId) {
        return eligibleRows(userId).stream()
                .anyMatch(this::hasReviewAccess);
    }

    /** 全部合格确认人的用户账号 id（通知接收池）。 */
    @Transactional(readOnly = true)
    public List<UUID> eligibleUserIds() {
        return eligibleRows(null).stream()
                .filter(this::hasReviewAccess)
                .toList();
    }

    private boolean hasReviewAccess(UUID userId) {
        return userRepo.findById(userId).map(permissionResolver::permsOf)
                .map(permissions -> permissions.contains(VIEW_PERMISSION) && permissions.contains(CONFIRM_PERMISSION))
                .orElse(false);
    }

    /**
     * 候选账号 = 财务部门子树在职员工账号（启用、未删），以及财务部门外但持有
     * 个人加授 confirm 权限的启用账号（与部门树判定互补，权限仍在 permsOf 里复核）。
     */
    private List<UUID> eligibleRows(UUID userId) {
        String userPredicate = userId == null ? "" : " AND u.id = ?";
        String sql = """
                WITH RECURSIVE finance_departments(id) AS (
                    SELECT id
                    FROM departments
                    WHERE code = 'DEPT_FIN' AND is_deleted = FALSE
                    UNION ALL
                    SELECT child.id
                    FROM departments child
                    JOIN finance_departments parent ON child.parent_id = parent.id
                    WHERE child.is_deleted = FALSE
                )
                SELECT u.id
                FROM users u
                JOIN employees e ON e.id = u.employee_id
                WHERE (
                        e.department_id IN (SELECT id FROM finance_departments)
                        OR EXISTS (
                            SELECT 1 FROM employee_secondary_departments secondary
                            WHERE secondary.employee_id = e.id
                              AND secondary.department_id IN (SELECT id FROM finance_departments)
                        )
                        OR u.id IN (
                            SELECT po.user_id
                            FROM user_permission_overrides po
                            JOIN permissions perm ON perm.id = po.permission_id
                            WHERE perm.code = 'sales_order_finance:confirm'
                              AND po.effect = 'grant'
                              AND po.active = TRUE
                              AND perm.active = TRUE
                        )
                    )
                  AND u.is_deleted = FALSE
                  AND u.status = 'active'
                  AND e.is_deleted = FALSE
                  AND e.status <> 'resigned'
                """ + userPredicate + " ORDER BY u.id";
        Object[] args = userId == null ? new Object[0] : new Object[]{userId};
        return jdbc.query(sql, (rs, rowNum) -> rs.getObject(1, UUID.class), args);
    }
}
