package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * Object scope for production-generated warehouse tasks.
 *
 * <p>The current master data has one warehouse organization tree but no
 * employee-to-warehouse assignment table. Therefore the honest enforceable
 * scope is the active {@code SUB_WH} subtree (plus super-admin recovery), not a
 * fabricated per-warehouse rule. Action permissions remain a separate gate.</p>
 */
@Component
@RequiredArgsConstructor
public class ProductionStockTaskAccessPolicy {

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;

    public boolean canAccessWarehouseTasks() {
        AuthUser actor = currentUser.get().orElse(null);
        if (actor == null || actor.isVisitor()) return false;
        if (actor.isSuperAdmin()) return true;
        UUID employeeId = actor.getEmployeeId();
        if (employeeId == null) return false;
        Number count = (Number) em.createNativeQuery("""
                        WITH RECURSIVE warehouse_departments(id) AS (
                            SELECT id
                            FROM departments
                            WHERE code = 'SUB_WH'
                              AND is_deleted = FALSE
                            UNION ALL
                            SELECT child.id
                            FROM departments child
                            JOIN warehouse_departments parent
                              ON child.parent_id = parent.id
                            WHERE child.is_deleted = FALSE
                        )
                        SELECT COUNT(*)
                        FROM employees employee
                        WHERE employee.id = :employeeId
                          AND employee.department_id IN (
                              SELECT id FROM warehouse_departments)
                          AND employee.is_deleted = FALSE
                          AND employee.status <> 'resigned'
                        """)
                .setParameter("employeeId", employeeId)
                .getSingleResult();
        return count != null && count.longValue() == 1;
    }

    public void requireWarehouseTaskAccess(String message) {
        if (!canAccessWarehouseTasks()) {
            throw new ApiException(ErrorCode.FORBIDDEN, message);
        }
    }
}
