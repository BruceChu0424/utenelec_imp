package com.uten.imp.features.profilechange;

import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.web.Pageables;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.Map;
import java.util.UUID;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageImpl;
import org.springframework.stereotype.Component;

/** Filter complete aggregate batches before pagination; never filter away fields within a batch. */
@Component
@RequiredArgsConstructor
public class ProfileChangeBatchQuery {
    private final EntityManager em;

    private static final Map<String, SqlColumnSearch.Field> FIELDS = Map.of(
            "employeeName", SqlColumnSearch.Field.text("batch.employee_name"),
            "employeeCode", SqlColumnSearch.Field.text("batch.employee_code"),
            "departmentName", SqlColumnSearch.Field.text("batch.department_name"),
            "fields", SqlColumnSearch.Field.text("batch.field_labels"),
            "fieldCodes", SqlColumnSearch.Field.text("batch.field_labels || ' ' || batch.field_codes"),
            "reviewComment", SqlColumnSearch.Field.text("batch.review_comment"),
            "itemCount", SqlColumnSearch.Field.decimal("batch.item_count"),
            "submittedAt", SqlColumnSearch.Field.instant("batch.submitted_at"));
    private static final Map<String, String> SORTS = Map.of(
            "employeeName", "employee_name", "employeeCode", "employee_code",
            "departmentName", "department_name", "itemCount", "item_count", "submittedAt", "submitted_at");

    static final String BATCHES = ProfileChangeRepository.BATCH_QUERY
            .replace("SELECT p.batch_id", """
                SELECT p.batch_id,
                  MIN(e.full_name) AS employee_name, MIN(e.code) AS employee_code,
                  MIN(d.name) AS department_name,
                  COUNT(*) AS item_count, MAX(p.submitted_at) AS submitted_at,
                  string_agg(coalesce(p.field_label,''), '、' ORDER BY p.submitted_at DESC,p.id DESC) AS field_labels,
                  string_agg(coalesce(p.field_code,''), ' ' ORDER BY p.submitted_at DESC,p.id DESC) AS field_codes,
                  (array_agg(p.review_comment ORDER BY p.submitted_at DESC,p.id DESC))[1] AS review_comment
                """)
            .replace("LEFT JOIN employees e ON e.id = p.employee_id", """
                LEFT JOIN employees e ON e.id = p.employee_id
                LEFT JOIN departments d ON d.id = e.department_id
                """);

    @SuppressWarnings("unchecked")
    public Page<UUID> page(String status, UUID submittedBy, UUID employeeId, UUID departmentId,
            int page, int size, Map<String, String> columns, String sort, String order) {
        var pageable = Pageables.of(page, size);
        var criteria = SqlColumnSearch.criteria(columns, FIELDS);
        String source = " FROM (" + BATCHES + ") batch WHERE " + criteria.predicate();
        Query count = em.createNativeQuery("SELECT COUNT(*)" + source);
        bind(count, status, submittedBy, employeeId, departmentId, criteria);
        long total = ((Number) count.getSingleResult()).longValue();
        String property = SORTS.get(sort == null ? "" : sort);
        String ordering = property == null ? "batch.submitted_at DESC,batch.batch_id DESC"
                : "batch." + property + ("desc".equalsIgnoreCase(order) ? " DESC" : " ASC")
                    + ",batch.batch_id " + ("desc".equalsIgnoreCase(order) ? "DESC" : "ASC");
        Query rows = em.createNativeQuery("SELECT batch.batch_id" + source + " ORDER BY " + ordering);
        bind(rows, status, submittedBy, employeeId, departmentId, criteria);
        rows.setFirstResult((int) pageable.getOffset());
        rows.setMaxResults(pageable.getPageSize());
        return new PageImpl<>((java.util.List<UUID>) rows.getResultList(), pageable, total);
    }

    private void bind(Query query, String status, UUID submittedBy, UUID employeeId, UUID departmentId,
            SqlColumnSearch.Criteria criteria) {
        query.setParameter("status", status);
        query.setParameter("submittedBy", submittedBy);
        query.setParameter("employeeId", employeeId);
        query.setParameter("departmentId", departmentId);
        criteria.bind(query);
    }
}
