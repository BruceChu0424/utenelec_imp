package com.uten.imp.features.finance.procurement;

import jakarta.persistence.criteria.CommonAbstractCriteria;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import java.util.UUID;

/** Database-side equivalents of the former whole-directory pending/latest-rejected ID sets. */
public final class ProcurementOrderApprovalPredicates {
    private ProcurementOrderApprovalPredicates() { }

    public static Predicate pending(Expression<UUID> orderId, CommonAbstractCriteria query,
            CriteriaBuilder cb, String orderType) {
        return matches(orderId, query, cb, orderType, false);
    }

    public static Predicate latestRejected(Expression<UUID> orderId, CommonAbstractCriteria query,
            CriteriaBuilder cb, String orderType) {
        return matches(orderId, query, cb, orderType, true);
    }

    private static Predicate matches(Expression<UUID> orderId, CommonAbstractCriteria query,
            CriteriaBuilder cb, String orderType, boolean latestRejected) {
        if (!java.util.Set.of("PURCHASE", "SUBCONTRACT").contains(orderType))
            throw new IllegalArgumentException("Unsupported procurement order type");
        var found = query.subquery(UUID.class);
        var row = found.from(ProcurementOrderApprovalRead.class);
        Predicate condition = cb.and(cb.equal(row.get("orderType"), orderType),
                cb.equal(row.get("orderId"), orderId), cb.equal(row.get("requestType"), "ORDER"),
                cb.equal(row.get("status"), latestRejected ? "REJECTED" : "PENDING"));
        if (latestRejected) {
            var newer = found.subquery(UUID.class);
            var next = newer.from(ProcurementOrderApprovalRead.class);
            newer.select(next.get("id")).where(cb.equal(next.get("orderType"), orderType),
                    cb.equal(next.get("orderId"), row.get("orderId")),
                    cb.equal(next.get("requestType"), "ORDER"),
                    cb.greaterThan(next.<Integer>get("attempt"), row.get("attempt")));
            condition = cb.and(condition, cb.not(cb.exists(newer)));
        }
        found.select(row.get("id")).where(condition);
        return cb.exists(found);
    }
}
