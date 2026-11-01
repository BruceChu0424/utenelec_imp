package com.uten.imp.features.admin.workflow;

import com.uten.imp.application.port.SalesManagerReviewerEligibilityPort;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.List;
import java.util.Set;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class SalesManagerReviewerEligibility implements SalesManagerReviewerEligibilityPort {
    private final JdbcTemplate jdbc;
    private final UserAccountRepository users;
    private final PermissionResolver permissions;

    private static String prefix(String kind) {
        return switch (kind) {
            case "quote" -> "sales_quote_manager:";
            case "order" -> "sales_order_manager:";
            default -> throw new IllegalArgumentException("Unknown sales review kind");
        };
    }
    @Override @Transactional(readOnly = true)
    public boolean eligible(UUID userId, String kind, String action) {
        if (userId == null || candidates(userId).isEmpty()) return false;
        String prefix = prefix(kind);
        return users.findById(userId).map(permissions::permsOf).map(p ->
                p.contains(prefix + "view") && ("claim".equals(action)
                        ? p.contains(prefix + "confirm") || p.contains(prefix + "reject")
                        : p.contains(prefix + action))).orElse(false);
    }
    @Override @Transactional(readOnly = true)
    public List<UUID> reviewers(String kind) {
        String prefix = prefix(kind);
        return permissions.usersGrantedAllAndAny(candidates(null), Set.of(prefix + "view"),
                Set.of(prefix + "confirm", prefix + "reject"));
    }
    private List<UUID> candidates(UUID userId) {
        return jdbc.query("""
                SELECT u.id FROM users u JOIN employees e ON e.id=u.employee_id
                WHERE NOT u.is_deleted AND u.status='active' AND NOT e.is_deleted
                  AND e.status <> 'resigned'
                """ + (userId == null ? "" : " AND u.id=?") + " ORDER BY u.id",
                (rs, row) -> rs.getObject(1, UUID.class), userId == null ? new Object[0] : new Object[]{userId});
    }
}
