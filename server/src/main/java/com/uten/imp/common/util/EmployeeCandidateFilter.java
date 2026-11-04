package com.uten.imp.common.util;

import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.Query;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Optional narrowing only; each candidate directory keeps its own authoritative eligibility/ACL. */
public record EmployeeCandidateFilter(String sql, Map<String, Object> parameters) {
    public static EmployeeCandidateFilter of(UUID departmentId, boolean includeSubtree, List<UUID> excluded,
            String employeeIdExpression, String employeeDepartmentExpression) {
        if (excluded != null && (excluded.size() > RequestLimits.ADMIN_SCOPE_OWNERS
                || excluded.stream().anyMatch(java.util.Objects::isNull))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "排除的员工标识不能超过1000个，且不能包含空值");
        }
        Map<String, Object> parameters = new LinkedHashMap<>();
        StringBuilder sql = new StringBuilder();
        if (departmentId != null) {
            parameters.put("candidateDepartmentId", departmentId);
            if (includeSubtree) {
                sql.append(" AND ").append(employeeDepartmentExpression).append(" IN (").append("""
                        WITH RECURSIVE selected_candidate_departments(id) AS (
                            SELECT id FROM departments WHERE id=:candidateDepartmentId AND NOT is_deleted
                            UNION
                            SELECT child.id FROM departments child
                            JOIN selected_candidate_departments parent ON child.parent_id=parent.id
                            WHERE NOT child.is_deleted
                        ) SELECT id FROM selected_candidate_departments)
                        """);
            } else {
                sql.append(" AND ").append(employeeDepartmentExpression).append("=:candidateDepartmentId\n");
            }
        }
        if (excluded != null && !excluded.isEmpty()) {
            sql.append(" AND ").append(employeeIdExpression).append(" NOT IN (:candidateExcludedEmployeeIds)\n");
            parameters.put("candidateExcludedEmployeeIds", List.copyOf(new LinkedHashSet<>(excluded)));
        }
        return new EmployeeCandidateFilter(sql.toString(), Map.copyOf(parameters));
    }

    public Query bind(Query query) {
        parameters.forEach(query::setParameter);
        return query;
    }
}
