package com.uten.imp.responsibility;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.responsibility.dto.DataHandoverCandidate;
import com.uten.imp.responsibility.dto.DataHandoverCandidatePage;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.UUID;

/** Small, organization-scoped directory for handover pickers; it never exposes full HR profiles. */
@Service
@RequiredArgsConstructor
public class DataHandoverCandidateService {

    private final EntityManager em;
    private final EmployeeHandoverAuthorization authorization;

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public DataHandoverCandidatePage search(
            String role, String query, int requestedPage, int requestedSize) {
        String normalizedRole = role == null ? "" : role.trim().toLowerCase(Locale.ROOT);
        if (!List.of("source", "target").contains(normalizedRole)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "role 必须是 source 或 target");
        }
        String keyword = query == null ? "" : query.trim();
        if (keyword.length() > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "候选人搜索词不能超过100个字符");
        }
        int page = Math.max(1, requestedPage);
        int size = Math.max(1, Math.min(100, requestedSize));
        boolean target = "target".equals(normalizedRole);
        EmployeeHandoverAuthorization.CandidateScope scope = authorization.candidateScope();

        String where = """
                FROM employees employee
                LEFT JOIN departments department ON department.id=employee.department_id
                WHERE employee.is_deleted=false
                  AND NOT EXISTS (
                      SELECT 1 FROM users protected_account
                      WHERE protected_account.employee_id=employee.id
                        AND protected_account.is_super_admin=true
                        AND protected_account.is_deleted=false)
                  AND (:target=false OR (
                      employee.status IN ('active','probation','onLeave')
                      AND EXISTS (
                          SELECT 1 FROM users active_account
                          WHERE active_account.employee_id=employee.id
                            AND active_account.status='active'
                            AND active_account.is_deleted=false)))
                  AND (:companyScope=true OR EXISTS (
                      SELECT 1 FROM departments manager_root
                      WHERE manager_root.manager_id=:managerEmployeeId
                        AND manager_root.is_deleted=false
                        AND manager_root.code<>'GM'
                        AND manager_root.level IN ('管理中心','一级部门','二级班组','三级科室')
                        AND department.path LIKE manager_root.path || '%'))
                  AND (:keyword='' OR lower(employee.full_name) LIKE :pattern
                       OR lower(employee.code) LIKE :pattern)
                """;
        var countQuery = em.createNativeQuery("SELECT count(*) " + where);
        bind(countQuery, target, scope, keyword);
        long total = ((Number) countQuery.getSingleResult()).longValue();

        var dataQuery = em.createNativeQuery("""
                SELECT employee.id, employee.code, employee.full_name,
                       employee.department_id, department.name, employee.status
                """ + where + """
                ORDER BY CASE employee.status
                    WHEN 'active' THEN 0 WHEN 'probation' THEN 1
                    WHEN 'onLeave' THEN 2 ELSE 3 END,
                    employee.full_name, employee.code, employee.id
                """);
        bind(dataQuery, target, scope, keyword);
        dataQuery.setFirstResult((page - 1) * size);
        dataQuery.setMaxResults(size);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(dataQuery);
        List<DataHandoverCandidate> items = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            items.add(new DataHandoverCandidate(
                    uuid(row[0]), Objects.toString(row[1], ""),
                    Objects.toString(row[2], ""), uuid(row[3]),
                    row[4] == null ? null : row[4].toString(),
                    Objects.toString(row[5], "")));
        }
        return new DataHandoverCandidatePage(List.copyOf(items), page, size, total);
    }

    private static void bind(
            jakarta.persistence.Query query,
            boolean target,
            EmployeeHandoverAuthorization.CandidateScope scope,
            String keyword) {
        query.setParameter("target", target);
        query.setParameter("companyScope", scope.companyWide());
        query.setParameter("managerEmployeeId", scope.managerEmployeeId());
        query.setParameter("keyword", keyword.toLowerCase(Locale.ROOT));
        query.setParameter("pattern", "%" + keyword.toLowerCase(Locale.ROOT) + "%");
    }

    private static UUID uuid(Object value) {
        if (value == null) return null;
        return value instanceof UUID id ? id : UUID.fromString(value.toString());
    }
}
