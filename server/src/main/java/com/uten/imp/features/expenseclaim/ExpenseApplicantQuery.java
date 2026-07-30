package com.uten.imp.features.expenseclaim;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 报销申请人快照查询。报销域只保存姓名和部门快照，不依赖组织域实体或仓储。
 */
@Repository
@RequiredArgsConstructor
public class ExpenseApplicantQuery {

    private final EntityManager entityManager;

    public Optional<ApplicantSnapshot> findEligible(UUID employeeId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT e.full_name, e.department_id
                        FROM employees e
                        JOIN departments d
                          ON d.id = e.department_id AND d.is_deleted = false
                        WHERE e.id = :id
                          AND e.is_deleted = false
                          AND e.status IN ('active', 'probation', 'onLeave')
                        """)
                .setParameter("id", employeeId)
                .setMaxResults(1)
                .getResultList();
        return rows.stream()
                .findFirst()
                .map(row -> new ApplicantSnapshot((String) row[0], (UUID) row[1]));
    }

    public record ApplicantSnapshot(String name, UUID departmentId) {
    }
}
