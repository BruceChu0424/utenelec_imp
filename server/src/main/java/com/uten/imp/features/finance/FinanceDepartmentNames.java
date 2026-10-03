package com.uten.imp.features.finance;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;

import java.util.Collection;
import java.util.HashMap;
import java.util.Map;
import java.util.TreeSet;
import java.util.UUID;

/** Labels of references on an already-authorized financial document, not an organization directory. */
public final class FinanceDepartmentNames {
    private FinanceDepartmentNames() {}

    public static Map<UUID, String> referenced(EntityManager em, Collection<UUID> referencedIds) {
        var ids = new TreeSet<UUID>();
        for (UUID id : referencedIds) if (id != null) ids.add(id);
        if (ids.isEmpty()) return Map.of();
        // Historical references remain readable even when their department was logically deleted.
        // Only the caller's persisted document IDs are supplied, and no employee/manager fields are read.
        var rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, name
                FROM departments
                WHERE id IN (:ids)
                """).setParameter("ids", ids));
        Map<UUID, String> result = new HashMap<>();
        for (Object[] row : rows) {
            if (row[0] instanceof UUID id && row[1] instanceof String name) result.put(id, name);
        }
        return Map.copyOf(result);
    }
}
