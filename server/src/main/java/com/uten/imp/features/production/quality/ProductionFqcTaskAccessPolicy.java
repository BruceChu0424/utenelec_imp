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
 * Object scope for the pooled production-quality workbench.
 *
 * <p>There is no employee-to-inspection-lab assignment master.  The honest
 * enforceable pool is therefore the active {@code DEPT_QA} organization tree,
 * plus the super-administrator recovery path.  Action authorities are checked
 * independently by Spring Security.</p>
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
        if (employeeId == null) return false;
        Number count = (Number) em.createNativeQuery("""
                        WITH RECURSIVE quality_departments(id) AS (
                            SELECT id
                            FROM departments
                            WHERE code = 'DEPT_QA'
                              AND is_deleted = FALSE
                            UNION ALL
                            SELECT child.id
                            FROM departments child
                            JOIN quality_departments parent
                              ON child.parent_id = parent.id
                            WHERE child.is_deleted = FALSE
                        )
                        SELECT COUNT(*)
                        FROM employees employee
                        WHERE employee.id = :employeeId
                          AND employee.department_id IN (
                              SELECT id FROM quality_departments)
                          AND employee.is_deleted = FALSE
                          AND employee.status <> 'resigned'
                        """)
                .setParameter("employeeId", employeeId)
                .getSingleResult();
        return count != null && count.longValue() == 1;
    }

    public void requireQualityPool(String message) {
        if (!canAccessQualityPool()) {
            throw new ApiException(ErrorCode.FORBIDDEN, message);
        }
    }
}
