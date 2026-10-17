package com.uten.imp.features.admin.workflow;

import com.uten.imp.application.port.SalesQuoteFinanceReviewerEligibilityPort;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * 销售报价财务核价权限(与 {@link SalesOrderFinanceConfirmerEligibility} 使用同一授权口径)。
 *
 * <p>账号启用、员工在职，且有效权限同时包含查看与核价即可办理。
 * 所有授权来源统一由 PermissionResolver 解析，不再要求财务部门或个人点名。
 */
@Service
@RequiredArgsConstructor
public class SalesQuoteFinanceReviewerEligibility implements SalesQuoteFinanceReviewerEligibilityPort {

    public static final String CONFIRM_PERMISSION = "sales_quote_finance:confirm";
    public static final String VIEW_PERMISSION = "sales_quote_finance:view";

    private final JdbcTemplate jdbc;
    private final UserAccountRepository userRepo;
    private final PermissionResolver permissionResolver;

    @Override
    @Transactional(readOnly = true)
    public boolean isEligible(UUID userId) {
        if (userId == null) return false;
        return candidateUserIds(userId).stream().anyMatch(this::hasReviewAccess);
    }

    @Override
    @Transactional(readOnly = true)
    public List<UUID> eligibleUserIds() {
        // 2026-10-09(ADR-063 追加修订): 通知接收池按「真实授出权限」解析——超管全量镜像不算
        // 任务归属; isEligible 是操作资格门, 超管仍按 permsOf 全量可操作。
        List<UUID> candidates = candidateUserIds(null);
        if (permissionResolver.supportsGrantedPermissionBatch()) {
            return permissionResolver.usersGrantedAll(candidates,
                    java.util.Set.of(VIEW_PERMISSION, CONFIRM_PERMISSION));
        }
        return candidates.stream()
                .filter(userId -> userRepo.findById(userId)
                        .map(account -> permissionResolver.grantedPermsOf(account)
                                .containsAll(java.util.Set.of(VIEW_PERMISSION, CONFIRM_PERMISSION)))
                        .orElse(false))
                .toList();
    }

    private boolean hasReviewAccess(UUID userId) {
        return userRepo.findById(userId).map(permissionResolver::permsOf)
                .map(permissions -> permissions.contains(VIEW_PERMISSION)
                        && permissions.contains(CONFIRM_PERMISSION))
                .orElse(false);
    }

    /** 候选只校验账号和员工状态；核价权限仍在 permsOf 中复核。 */
    private List<UUID> candidateUserIds(UUID userId) {
        String userPredicate = userId == null ? "" : " AND u.id = ?";
        String sql = """
                SELECT u.id
                FROM users u
                JOIN employees e ON e.id = u.employee_id
                WHERE u.is_deleted = FALSE
                  AND u.status = 'active'
                  AND e.is_deleted = FALSE
                  AND e.status <> 'resigned'
                """ + userPredicate + " ORDER BY u.id";
        Object[] args = userId == null ? new Object[0] : new Object[]{userId};
        return jdbc.query(sql, (rs, rowNum) -> rs.getObject(1, UUID.class), args);
    }
}
