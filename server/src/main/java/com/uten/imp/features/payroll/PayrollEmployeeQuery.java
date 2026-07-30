package com.uten.imp.features.payroll;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 生成工资时使用的只读扁平查询。一次取齐员工、部门与加密薪酬字段，
 * 避免在生成循环中触发懒加载和 N+1。
 */
@Repository
@RequiredArgsConstructor
public class PayrollEmployeeQuery {

    private static final int MAX_BATCH_EMPLOYEES = 10_000;

    private final EntityManager entityManager;

    public Optional<String> findDepartmentName(UUID departmentId) {
        if (departmentId == null) {
            return Optional.empty();
        }
        @SuppressWarnings("unchecked")
        List<String> names = entityManager.createNativeQuery("""
                        SELECT name
                        FROM departments
                        WHERE id = :id AND is_deleted = false
                        """)
                .setParameter("id", departmentId)
                .setMaxResults(1)
                .getResultList();
        return names.stream().findFirst();
    }

    /**
     * 返回部门及其全部未删除下级部门，供工资条列表按组织树筛选。
     */
    public List<UUID> findDepartmentSubtreeIds(UUID departmentId) {
        if (departmentId == null) {
            return List.of();
        }
        @SuppressWarnings("unchecked")
        List<UUID> ids = entityManager.createNativeQuery("""
                        WITH RECURSIVE subtree AS (
                            SELECT id
                            FROM departments
                            WHERE id = :departmentId AND is_deleted = false
                            UNION ALL
                            SELECT d.id
                            FROM departments d
                            JOIN subtree s ON d.parent_id = s.id
                            WHERE d.is_deleted = false
                        )
                        SELECT id FROM subtree
                        """)
                .setParameter("departmentId", departmentId)
                .getResultList();
        return ids;
    }

    public List<Candidate> findCandidates(UUID departmentId) {
        String scope = departmentId == null ? "" : """
                  AND e.department_id IN (
                      WITH RECURSIVE subtree AS (
                          SELECT id FROM departments WHERE id = :departmentId AND is_deleted = false
                          UNION ALL
                          SELECT d.id FROM departments d
                          JOIN subtree s ON d.parent_id = s.id
                          WHERE d.is_deleted = false
                      )
                      SELECT id FROM subtree
                  )
                """;
        var query = entityManager.createNativeQuery("""
                SELECT e.id,
                       e.code,
                       e.full_name,
                       d.id,
                       d.name,
                       c.base_salary_enc,
                       c.perf_salary_enc,
                       c.allowance_standard_enc
                FROM employees e
                JOIN departments d ON d.id = e.department_id AND d.is_deleted = false
                LEFT JOIN employee_compensation c ON c.employee_id = e.id
                WHERE e.is_deleted = false
                  AND e.status IN ('active', 'probation', 'onLeave')
                """ + scope + """
                ORDER BY e.code, e.id
                """);
        if (departmentId != null) {
            query.setParameter("departmentId", departmentId);
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.setMaxResults(MAX_BATCH_EMPLOYEES + 1).getResultList();
        if (rows.size() > MAX_BATCH_EMPLOYEES) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "单次工资生成最多支持 " + MAX_BATCH_EMPLOYEES + " 名员工，请按部门拆分");
        }
        return rows.stream().map(row -> new Candidate(
                (UUID) row[0],
                (String) row[1],
                (String) row[2],
                (UUID) row[3],
                (String) row[4],
                (String) row[5],
                (String) row[6],
                (String) row[7]
        )).toList();
    }

    public record Candidate(
            UUID employeeId,
            String employeeCode,
            String employeeName,
            UUID departmentId,
            String departmentName,
            String baseSalaryCipher,
            String performanceSalaryCipher,
            String allowanceCipher
    ) {
    }
}
