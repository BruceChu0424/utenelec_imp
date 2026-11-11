package com.uten.imp.common.export;

import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Path;
import jakarta.persistence.criteria.Predicate;
import org.hibernate.query.criteria.HibernateCriteriaBuilder;

import java.util.Set;
import java.util.UUID;

/** One bounded selection predicate for every master export, inside its existing authorized query. */
final class MasterSelectionPredicate {
    private MasterSelectionPredicate() { }

    static Predicate contains(Path<UUID> identity, Set<UUID> selected, CriteriaBuilder criteria) {
        if (selected.size() <= 1024) return identity.in(selected);
        var hibernate = (HibernateCriteriaBuilder) criteria;
        // PostgreSQL can hash scalar = ANY(constant uuid[]) during planning.
        // array_contains rendered uuid[] @> ARRAY[row.id], which scanned the
        // complete selected array again for each candidate row. Keep one typed
        // array bind without changing identity, permissions or missing-ID checks.
        return criteria.isTrue(hibernate.sql("? = ANY(?)", Boolean.class,
                identity, hibernate.value(selected.toArray(UUID[]::new))));
    }
}
