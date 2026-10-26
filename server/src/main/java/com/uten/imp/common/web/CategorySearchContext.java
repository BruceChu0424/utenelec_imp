package com.uten.imp.common.web;

import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.Expression;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;
import java.util.UUID;

/** List and context share the caller's specification, while grouped reads own their projection and order. */
public final class CategorySearchContext {
    private CategorySearchContext() { }

    public static <T> MasterSearchContext read(EntityManager em, Class<T> entity, Specification<T> spec,
                                              String categoryProperty, int page, int size) {
        if (page > 100_000) throw new ApiException(ErrorCode.VALIDATION_FAILED, "分类查询页码过大");
        var paging = Pageables.of(page, size);
        var cb = em.getCriteriaBuilder();
        var totals = cb.createQuery(Object[].class);
        var totalRoot = totals.from(entity);
        var totalPredicate = spec.toPredicate(totalRoot, totals, cb);
        Expression<UUID> totalCategory = totalRoot.get(categoryProperty).get("id");
        var count = cb.count(totalRoot);
        Expression<Long> nullBucket = cb.<Long>selectCase()
                .when(cb.greaterThan(count, cb.count(totalCategory)), 1L).otherwise(0L);
        totals.select(cb.array(count, cb.sum(cb.countDistinct(totalCategory), nullBucket)))
                .where(totalPredicate).orderBy(List.of());
        Object[] counts = em.createQuery(totals).getSingleResult();
        long totalMatches = ((Number) counts[0]).longValue(), totalCategories = ((Number) counts[1]).longValue();
        int totalPages = (int) Math.min(Integer.MAX_VALUE, (totalCategories + paging.getPageSize() - 1) / paging.getPageSize());
        int currentPage = Math.min(paging.getPageNumber() + 1, Math.max(1, totalPages));
        if (totalCategories == 0)
            return new MasterSearchContext(totalMatches, List.of(), currentPage, paging.getPageSize(), 0, 0);

        var groups = cb.createQuery(Object[].class);
        var root = groups.from(entity);
        var predicate = spec.toPredicate(root, groups, cb);
        Expression<UUID> category = root.get(categoryProperty).get("id");
        groups.select(cb.array(category, cb.count(root))).where(predicate).groupBy(category)
                .orderBy(cb.asc(cb.<Integer>selectCase().when(cb.isNull(category), 1).otherwise(0)), cb.asc(category));
        var rows = em.createQuery(groups).setFirstResult(Pageables.checkedOffset(currentPage, paging.getPageSize()))
                .setMaxResults(paging.getPageSize()).getResultList().stream()
                .map(row -> new MasterSearchContext.CategoryCount((UUID) row[0], ((Number) row[1]).longValue())).toList();
        return new MasterSearchContext(totalMatches, rows, currentPage, paging.getPageSize(), totalCategories, totalPages);
    }
}
