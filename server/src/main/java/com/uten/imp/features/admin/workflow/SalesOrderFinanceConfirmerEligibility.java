package com.uten.imp.features.admin.workflow;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * 销售订单财务确认权限查询(与 {@link WorkflowReviewerEligibility} 使用同一授权口径)。
 *
 * <p>账号启用、员工在职且有效权限同时包含查看与确认即可办理。
 * 部门配置、个人覆盖和负责人委派统一由 PermissionResolver 解析，不再按部门或授权来源另设门槛。
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
        if (userId == null) return false;
        return eligibleRows(userId).stream()
                .anyMatch(this::hasReviewAccess);
    }

    /** 全部合格确认人的用户账号 id（通知接收池）。 */
    @Transactional(readOnly = true)
    public List<UUID> eligibleUserIds() {
        // 2026-10-09(ADR-063 追加修订): 通知接收池按「真实授出权限」解析——超管的全量目录码
        // 是操作授权面, 不是任务归属; isEligible 是操作资格门, 超管仍按 permsOf 全量可操作。
        return permissionResolver.usersGrantedAll(eligibleRows(null),
                java.util.Set.of(VIEW_PERMISSION, CONFIRM_PERMISSION));
    }

    private boolean hasReviewAccess(UUID userId) {
        return userRepo.findById(userId).map(permissionResolver::permsOf)
                .map(permissions -> permissions.contains(VIEW_PERMISSION) && permissions.contains(CONFIRM_PERMISSION))
                .orElse(false);
    }

    /** 候选只校验账号和员工状态；操作权限由统一权限解析器复核。 */
    private List<UUID> eligibleRows(UUID userId) {
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
