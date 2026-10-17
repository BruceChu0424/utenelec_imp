package com.uten.imp.features.admin.workflow;

import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer;
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
 * 财务审批权限查询(实现 {@link FinanceReviewerEligibilityPort})。
 *
 * <p>账号启用、员工在职且拥有查看和相应动作的有效权限即可处理。
 * 部门和授权来源不再限制审批资格；批准与驳回仍分别校验对应权限。
 */
@Service
@RequiredArgsConstructor
public class WorkflowReviewerEligibility implements FinanceReviewerEligibilityPort {

    public static final String APPROVE_PERMISSION = "finance_order_approval:approve";
    public static final String REJECT_PERMISSION = "finance_order_approval:reject";
    public static final String VIEW_PERMISSION = "finance_order_approval:view";
    private static final Set<String> REVIEW_PERMISSIONS = Set.of(APPROVE_PERMISSION, REJECT_PERMISSION);

    private final JdbcTemplate jdbc;
    private final UserAccountRepository userRepo;
    private final PermissionResolver permissionResolver;

    @Override
    @Transactional(readOnly = true)
    public Optional<EligibleFinanceReviewer> findEligible(UUID userId) {
        if (userId == null) return Optional.empty();
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
        // 2026-10-09(ADR-063 追加修订): allEligible 是通知接收池, 按「真实授出权限」解析——
        // 超管的全量目录码是操作授权面, 不是任务归属; findEligible/eligibleReviewers* 是操作与
        // 指派资格, 继续按 permsOf(超管可操作/可被指派)。
        List<EligibleReviewer> candidates = eligibleRows(null);
        if (permissionResolver.supportsGrantedPermissionBatch()) {
            Set<UUID> eligible = Set.copyOf(permissionResolver.usersGrantedAllAndAny(
                    candidates.stream().map(EligibleReviewer::userId).toList(),
                    Set.of(VIEW_PERMISSION), REVIEW_PERMISSIONS));
            return candidates.stream().filter(row -> eligible.contains(row.userId()))
                    .map(row -> new EligibleFinanceReviewer(row.userId(),row.employeeId(),row.employeeName())).toList();
        }
        return candidates.stream()
                .filter(row -> userRepo.findById(row.userId())
                        .map(this::hasAnyGrantedReviewAction).orElse(false))
                .map(row -> new EligibleFinanceReviewer(
                        row.userId(), row.employeeId(), row.employeeName()))
                .toList();
    }

    private boolean hasAnyGrantedReviewAction(UserAccount account) {
        Set<String> permissions = permissionResolver.grantedPermsOf(account);
        return permissions.contains(VIEW_PERMISSION) && (permissions.contains(APPROVE_PERMISSION)
                || permissions.contains(REJECT_PERMISSION));
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
                        .map(permissions -> permissions.contains(VIEW_PERMISSION) && permissions.contains(permission))
                        .orElse(false))
                .toList();
    }

    private boolean hasAnyReviewAction(UserAccount account) {
        Set<String> permissions = permissionResolver.permsOf(account);
        return permissions.contains(VIEW_PERMISSION) && (permissions.contains(APPROVE_PERMISSION)
                || permissions.contains(REJECT_PERMISSION));
    }

    private List<EligibleReviewer> eligibleRows(UUID userId) {
        String userPredicate = userId == null ? "" : " AND u.id = ?";
        String sql = """
                SELECT u.id AS user_id,
                       e.id AS employee_id,
                       e.full_name,
                       d.id AS department_id,
                       d.name AS department_name
                FROM users u
                JOIN employees e ON e.id = u.employee_id
                LEFT JOIN departments d ON d.id = e.department_id AND d.is_deleted = FALSE
                WHERE u.is_deleted = FALSE
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
