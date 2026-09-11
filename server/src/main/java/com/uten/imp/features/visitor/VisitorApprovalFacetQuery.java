package com.uten.imp.features.visitor;

import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApprovalFacets;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorFacetBucket;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Set;

/**
 * HR 访客审批列表表头筛选桶（2026-09-10）：按状态集聚合「状态」与「接待人部门」命中数。
 * 只读原生 SQL（全部参数化），不依赖组织域实体。
 */
@Repository
@RequiredArgsConstructor
public class VisitorApprovalFacetQuery {

    private final EntityManager entityManager;

    /** status 空 = 待办状态集（pending + hostReviewing），与 listForApproval 默认口径一致。 */
    @Transactional(readOnly = true)
    public VisitorApprovalFacets facets(String status) {
        Collection<String> statuses = (status == null || status.isBlank())
                ? Set.of("pending", "hostReviewing")
                : Set.of(status.trim());
        return new VisitorApprovalFacets(statusBuckets(statuses), departmentBuckets(statuses));
    }

    private List<VisitorFacetBucket> statusBuckets(Collection<String> statuses) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT v.status, COUNT(*)
                        FROM visitor_applications v
                        WHERE v.is_deleted = false
                          AND v.status IN (:statuses)
                        GROUP BY v.status
                        ORDER BY v.status
                        """)
                .setParameter("statuses", statuses)
                .getResultList();
        List<VisitorFacetBucket> buckets = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            buckets.add(new VisitorFacetBucket(
                    (String) row[0], (String) row[0], ((Number) row[1]).longValue()));
        }
        return buckets;
    }

    private List<VisitorFacetBucket> departmentBuckets(Collection<String> statuses) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT v.host_department_id, d.name, COUNT(*)
                        FROM visitor_applications v
                        JOIN departments d ON d.id = v.host_department_id
                        WHERE v.is_deleted = false
                          AND v.status IN (:statuses)
                        GROUP BY v.host_department_id, d.name
                        ORDER BY d.name, v.host_department_id
                        """)
                .setParameter("statuses", statuses)
                .getResultList();
        List<VisitorFacetBucket> buckets = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            buckets.add(new VisitorFacetBucket(
                    row[0].toString(), (String) row[1], ((Number) row[2]).longValue()));
        }
        return buckets;
    }
}
