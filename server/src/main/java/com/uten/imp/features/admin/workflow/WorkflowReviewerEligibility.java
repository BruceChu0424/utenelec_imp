package com.uten.imp.features.admin.workflow;

import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Set;
import java.util.Optional;
import java.util.UUID;

/**
 * 财务审批负责人资格查询（实现 {@link FinanceReviewerEligibilityPort}）。
 *
 * <p>合格人选 = 财务部门（DEPT_FIN）子树在职员工 且 账号启用，叠加个人加授
 * {@code finance_order_approval:approve} 或 {@code finance_order_approval:reject}。资格只约束审核组范围，具体动作仍要求对应权限。
 */
@Service
@RequiredArgsConstructor
public class WorkflowReviewerEligibility implements FinanceReviewerEligibilityPort {

    public static final String APPROVE_PERMISSION = "finance_order_approval:approve";
    public static final String REJECT_PERMISSION = "finance_order_approval:reject";
    private static final Set<String> REVIEW_PERMISSIONS = Set.of(APPROVE_PERMISSION, REJECT_PERMISSION);

    private final JdbcTemplate jdbc;
    private final UserAccountRepository userRepo;
    private final PermissionResolver permissionResolver;

    @Transactional(readOnly = true)
    public EligibleReviewer requireEligible(UUID userId) {
        EligibleReviewer reviewer = eligibleRows(userId).stream()
                .findFirst()
                .orElseThrow(() -> new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "审批负责人必须是财务部门在职员工且账号处于启用状态"));
        UserAccount account = userRepo.findById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "候选账号不存在"));
        if (!hasAnyReviewAction(account)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "审批负责人缺少批准或驳回订货财务审批权限");
        }
        return reviewer;
    }

    @Override
    @Transactional(readOnly = true)
    public Optional<EligibleFinanceReviewer> findEligible(UUID userId) {
        return eligibleRows(userId).stream()
                .filter(row -> userRepo.findById(row.userId())
                        .map(this::hasAnyReviewAction).orElse(false))
                .findFirst()
                .map(row -> new EligibleFinanceReviewer(
                        row.userId(), row.employeeId(), row.employeeName()));
    }

    @Override
    @Transactional(readOnly = true)
    public List<EligibleFinanceReviewer> allEligible() {
        return eligibleReviewers().stream()
                .map(row -> new EligibleFinanceReviewer(
                        row.userId(), row.employeeId(), row.employeeName()))
                .toList();
    }

    @Transactional(readOnly = true)
    public List<EligibleReviewer> eligibleReviewers() {
        return eligibleRows(null).stream()
                .filter(row -> userRepo.findById(row.userId())
                        .map(this::hasAnyReviewAction).orElse(false))
                .toList();
    }

    @Transactional(readOnly = true)
    public List<EligibleReviewer> eligibleReviewersFor(String permission) {
        if (!REVIEW_PERMISSIONS.contains(permission)) {
            throw new IllegalArgumentException("Unsupported finance review permission: " + permission);
        }
        return eligibleRows(null).stream()
                .filter(row -> userRepo.findById(row.userId())
                        .map(permissionResolver::permsOf)
                        .map(permissions -> permissions.contains(permission))
                        .orElse(false))
                .toList();
    }

    private boolean hasAnyReviewAction(UserAccount account) {
        Set<String> permissions = permissionResolver.permsOf(account);
        return permissions.contains(APPROVE_PERMISSION)
                || permissions.contains(REJECT_PERMISSION);
    }

    private List<EligibleReviewer> eligibleRows(UUID userId) {
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
                SELECT u.id AS user_id,
                       e.id AS employee_id,
                       e.full_name,
                       d.id AS department_id,
                       d.name AS department_name
                FROM users u
                JOIN employees e ON e.id = u.employee_id
                JOIN departments d ON d.id = e.department_id
                WHERE (
                        e.department_id IN (SELECT id FROM finance_departments)
                        OR u.id IN (
                            SELECT po.user_id
                            FROM user_permission_overrides po
                            JOIN permissions perm ON perm.id = po.permission_id
                            WHERE perm.code IN ('finance_order_approval:approve', 'finance_order_approval:reject')
                              AND po.effect = 'grant'
                        )
                    )
                  AND u.is_deleted = FALSE
                  AND u.status = 'active'
                  AND e.is_deleted = FALSE
                  AND e.status <> 'resigned'
                """ + userPredicate + " ORDER BY e.full_name, e.code, u.id";
        Object[] args = userId == null ? new Object[0] : new Object[]{userId};
        return jdbc.query(sql, (rs, rowNum) -> new EligibleReviewer(
                rs.getObject("user_id", UUID.class),
                rs.getObject("employee_id", UUID.class),
                rs.getString("full_name"),
                rs.getObject("department_id", UUID.class),
                rs.getString("department_name")), args);
    }

    public record EligibleReviewer(
            UUID userId,
            UUID employeeId,
            String employeeName,
            UUID departmentId,
            String departmentName) {
    }
}
