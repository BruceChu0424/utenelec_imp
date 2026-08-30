package com.uten.imp.audit;

import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Component;

import java.sql.Date;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Executes the audit overview as two database queries: one conditional
 * aggregate for the overview cards and one Beijing-date GROUP BY for the
 * selected trend window. It never performs one count query per day.
 */
@Component
public class AuditSummaryAggregation {

    @PersistenceContext
    private EntityManager entityManager;

    AuditSummary summarize(
            Specification<AuditLog> base,
            Specification<AuditLog> risky,
            Specification<AuditLog> critical,
            Specification<AuditLog> failed,
            Specification<AuditLog> dataChange,
            LocalDate dateFrom,
            LocalDate dateTo) {
        Object[] totals = aggregate(base, risky, critical, failed, dataChange);
        List<AuditSummary.DailyPoint> trend = dateFrom == null || dateTo == null
                ? List.of()
                : daily(base, risky, dateFrom, dateTo);
        return new AuditSummary(
                number(totals, 0),
                number(totals, 1),
                number(totals, 2),
                number(totals, 3),
                number(totals, 4),
                trend);
    }

    private Object[] aggregate(
            Specification<AuditLog> base,
            Specification<AuditLog> risky,
            Specification<AuditLog> critical,
            Specification<AuditLog> failed,
            Specification<AuditLog> dataChange) {
        CriteriaBuilder cb = entityManager.getCriteriaBuilder();
        CriteriaQuery<Object[]> query = cb.createQuery(Object[].class);
        Root<AuditLog> root = query.from(AuditLog.class);
        Predicate basePredicate = predicate(base, root, query, cb);
        query.multiselect(
                cb.count(root),
                conditionalCount(cb, predicate(risky, root, query, cb)),
                conditionalCount(cb, predicate(critical, root, query, cb)),
                conditionalCount(cb, predicate(failed, root, query, cb)),
                conditionalCount(cb, predicate(dataChange, root, query, cb)))
                .where(basePredicate);
        return entityManager.createQuery(query).getSingleResult();
    }

    private List<AuditSummary.DailyPoint> daily(
            Specification<AuditLog> base,
            Specification<AuditLog> risky,
            LocalDate dateFrom,
            LocalDate dateTo) {
        CriteriaBuilder cb = entityManager.getCriteriaBuilder();
        CriteriaQuery<Object[]> query = cb.createQuery(Object[].class);
        Root<AuditLog> root = query.from(AuditLog.class);
        Expression<LocalDateTime> beijingTimestamp = cb.function(
                "timezone",
                LocalDateTime.class,
                cb.literal("Asia/Shanghai"),
                root.get("createdAt"));
        Expression<LocalDate> businessDate = cb.function(
                "date", LocalDate.class, beijingTimestamp);
        query.multiselect(
                businessDate,
                cb.count(root),
                conditionalCount(cb, predicate(risky, root, query, cb)))
                .where(predicate(base, root, query, cb))
                .groupBy(businessDate)
                .orderBy(cb.asc(businessDate));

        Map<LocalDate, long[]> byDate = new HashMap<>();
        for (Object[] row : entityManager.createQuery(query).getResultList()) {
            LocalDate date = localDate(row[0]);
            if (date != null) {
                byDate.put(date, new long[]{number(row, 1), number(row, 2)});
            }
        }
        List<AuditSummary.DailyPoint> result = new ArrayList<>();
        for (LocalDate date = dateFrom; !date.isAfter(dateTo); date = date.plusDays(1)) {
            long[] counts = byDate.getOrDefault(date, new long[]{0, 0});
            result.add(new AuditSummary.DailyPoint(date, counts[0], counts[1]));
        }
        return List.copyOf(result);
    }

    private Expression<Long> conditionalCount(CriteriaBuilder cb, Predicate predicate) {
        return cb.sum(cb.<Long>selectCase()
                .when(predicate, 1L)
                .otherwise(0L));
    }

    private Predicate predicate(
            Specification<AuditLog> specification,
            Root<AuditLog> root,
            CriteriaQuery<?> query,
            CriteriaBuilder cb) {
        Predicate value = specification.toPredicate(root, query, cb);
        return value == null ? cb.conjunction() : value;
    }

    private long number(Object[] row, int index) {
        return row != null && index < row.length && row[index] instanceof Number value
                ? value.longValue()
                : 0L;
    }

    private LocalDate localDate(Object value) {
        if (value instanceof LocalDate localDate) {
            return localDate;
        }
        if (value instanceof Date date) {
            return date.toLocalDate();
        }
        return value == null ? null : LocalDate.parse(value.toString());
    }
}
