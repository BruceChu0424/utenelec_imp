package com.uten.imp.common.util;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Collection;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
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

    /** Operation-local bounded labels; deleted departments retain the existing unavailable semantics. */
    public Map<UUID, String> namesOf(Collection<UUID> departmentIds) {
        if (departmentIds == null || departmentIds.isEmpty()) return Map.of();
        List<UUID> ids = departmentIds.stream().filter(Objects::nonNull).distinct().toList();
        Map<UUID, String> names = new LinkedHashMap<>();
        for (int start = 0; start < ids.size(); start += EmployeeNameResolver.READ_BATCH_SIZE) {
            List<UUID> batch = ids.subList(start, Math.min(start + EmployeeNameResolver.READ_BATCH_SIZE, ids.size()));
            for (Object[] row : NativeQueryResults.objectArrayRows(entityManager.createNativeQuery("""
                    SELECT id, name FROM departments
                    WHERE id IN (:ids) AND COALESCE(is_deleted, false) = false
                    """).setParameter("ids", batch))) {
                if (row[1] != null) names.put((UUID) row[0], row[1].toString());
            }
        }
        return Collections.unmodifiableMap(names);
    }

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
