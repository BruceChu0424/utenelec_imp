package com.uten.imp.common.util;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

/**
 * Read-only department-name lookup for document snapshots and display DTOs.
 *
 * <p>This shared adapter prevents master/finance/etc. from importing the org
 * feature's repositories merely to resolve a label. It never authorizes a
 * department reference; command services must still validate business rules
 * in their own boundary.
 */
@Component
@RequiredArgsConstructor
public class DepartmentNameResolver {

    private final EntityManager entityManager;

    public String nameOf(UUID departmentId) {
        if (departmentId == null) return null;
        List<?> rows = entityManager.createNativeQuery("""
                        SELECT name
                        FROM departments
                        WHERE id = :id
                          AND COALESCE(is_deleted, false) = false
                        """)
                .setParameter("id", departmentId)
                .setMaxResults(1)
                .getResultList();
        return rows.isEmpty() ? null : String.valueOf(rows.getFirst());
    }
}
