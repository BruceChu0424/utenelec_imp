package com.uten.imp.features.production.quality;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * Review-pool capability for the production-quality workbench.
 *
 * <p>Effective view and approval permissions authorize an active employee to handle the review
 * pool, regardless of department or grant source. View-only callers retain the production
 * document's existing owner scope. Spring Security also checks each endpoint's exact action.</p>
 */
@Component
@RequiredArgsConstructor
public class ProductionFqcTaskAccessPolicy {

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;

    public boolean canAccessQualityPool() {
        AuthUser actor = currentUser.get().orElse(null);
        if (actor == null || actor.isVisitor()) return false;
        if (actor.isSuperAdmin()) return true;
        UUID employeeId = actor.getEmployeeId();
        if (employeeId == null || !actor.getPermissions().containsAll(java.util.Set.of(
                "production_quality_inspection:view", "production_quality_inspection:approve"))) return false;
        Number count = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM employees employee
                        JOIN users account ON account.employee_id = employee.id
                        WHERE employee.id = :employeeId
                          AND account.id = :userId
                          AND account.is_deleted = FALSE
                          AND account.status = 'active'
                          AND employee.is_deleted = FALSE
                          AND employee.status IN ('active', 'probation', 'onLeave')
                        """)
                .setParameter("employeeId", employeeId)
                .setParameter("userId", actor.getId())
                .getSingleResult();
        return count != null && count.longValue() == 1;
    }

    public void requireQualityPool(String message) {
        if (!canAccessQualityPool()) {
            throw new ApiException(ErrorCode.FORBIDDEN, message);
        }
    }
}
