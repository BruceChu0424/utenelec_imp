package com.uten.imp.features.expenseclaim;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Repository;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 报销申请人 / 部门快照查询。报销域只保存姓名和部门快照，不依赖组织域实体或仓储，
 * 部门名称与筛选桶均走原生 SQL 只读查询（全部参数化）。
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

    /**
     * 部门 id → 名称（一次查齐，供列表/详情回填「部门」列，避免逐单查询）。
     * 已删除部门仍返回名称（历史报销单的部门快照要能显示）。
     */
    public Map<UUID, String> departmentNames(Collection<UUID> departmentIds) {
        Set<UUID> ids = new LinkedHashSet<>();
        if (departmentIds != null) {
            departmentIds.stream().filter(java.util.Objects::nonNull).forEach(ids::add);
        }
        if (ids.isEmpty()) {
            return Map.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT d.id, d.name
                        FROM departments d
                        WHERE d.id IN (:ids)
                        """)
                .setParameter("ids", ids)
                .getResultList();
        Map<UUID, String> names = new LinkedHashMap<>();
        for (Object[] row : rows) {
            names.put((UUID) row[0], (String) row[1]);
        }
        return names;
    }

    /**
     * 某状态集合下报销单按申请人部门聚合（表头「部门」筛选桶）。
     * 返回 [department_id, department_name, count]，按部门名排序；无部门快照的单据不进桶。
     */
    public List<FacetRow> departmentFacets(Collection<String> statuses) {
        if (statuses == null || statuses.isEmpty()) {
            return List.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT c.applicant_department_id, d.name, COUNT(*)
                        FROM expense_claims c
                        JOIN departments d ON d.id = c.applicant_department_id
                        WHERE c.status IN (:statuses)
                        GROUP BY c.applicant_department_id, d.name
                        ORDER BY d.name, c.applicant_department_id
                        """)
                .setParameter("statuses", statuses)
                .getResultList();
        return rows.stream()
                .map(row -> new FacetRow(
                        row[0].toString(),
                        (String) row[1],
                        ((Number) row[2]).longValue()))
                .toList();
    }

    /**
     * 某状态集合下报销单按创建年月（业务时区 Asia/Shanghai，与列表 year/month 筛选口径一致）聚合
     * （表头「年月」筛选桶）。返回 [yyyy-MM, yyyy-MM, count]，最近月份在前。
     */
    public List<FacetRow> monthFacets(Collection<String> statuses) {
        if (statuses == null || statuses.isEmpty()) {
            return List.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT to_char(c.created_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM') AS ym,
                               COUNT(*)
                        FROM expense_claims c
                        WHERE c.status IN (:statuses)
                        GROUP BY ym
                        ORDER BY ym DESC
                        """)
                .setParameter("statuses", statuses)
                .getResultList();
        return rows.stream()
                .map(row -> new FacetRow(
                        (String) row[0],
                        (String) row[0],
                        ((Number) row[1]).longValue()))
                .toList();
    }

    public record ApplicantSnapshot(String name, UUID departmentId) {
    }

    /** 筛选桶行：value=回传筛选值（部门 id / yyyy-MM），label=展示名，count=命中数。 */
    public record FacetRow(String value, String label, long count) {
    }
}
